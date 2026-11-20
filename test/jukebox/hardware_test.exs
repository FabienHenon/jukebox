defmodule Jukebox.HardwareTest do
  # Uses the application's own supervision tree (simulated input, power
  # controller and monitor, see config/test.exs), so it cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Jukebox.Test.HardwareHelpers

  alias Jukebox.{Animation, Commands, Hardware}
  alias Jukebox.Hardware.Brightness
  alias Jukebox.Hardware.Power
  alias Jukebox.Inputs.Simulated, as: Input
  alias Jukebox.MetadataSources.Demo
  alias Jukebox.Playback.Server
  alias Jukebox.RemoteControls

  # The arbitrary key codes of config/test.exs.
  @previous 704
  @play_pause 705
  @next 706
  @animation 709
  @brightness_down 710
  @brightness_up 711

  setup do
    reset()
    on_exit(&reset/0)
    Commands.subscribe()
    :ok
  end

  defp reset do
    Power.Simulated.set_available(true)
    Power.Simulated.set_mode(:awake)
    Power.Monitor.snapshot()
    Brightness.Simulated.set_available(true)
    Brightness.Desired.update(fn _current -> 1000 end)
    Demo.reset()
    RemoteControls.Demo.clear()
    Server.reset()
    Animation.set(:calm)
    # Past the debounce window of whatever a previous test pressed.
    Process.sleep(100)
  end

  defp accepted, do: Hardware.status().buttons.counts.accepted

  describe "status/0" do
    test "reports every part, without anything secret" do
      status = Hardware.status()

      assert %{
               config: config,
               buttons: buttons,
               power: power,
               lights: lights,
               brightness: brightness
             } = status

      # Sanitised effective mapping.
      assert config.buttons.mapping.previous == @previous
      assert config.buttons.mapping.brightness_up == 711
      assert buttons.mapping == config.buttons.mapping

      # Device identity and source connection.
      assert buttons.connection == :connected
      assert buttons.device.name == "Simulated button encoder"
      assert Map.has_key?(buttons, :last_accepted)
      assert %{malformed: _, unassigned: _, accepted: _, discarded_not_awake: _} = buttons.counts

      # Power mode and freshness.
      assert %{mode: :awake, fresh?: true, stale_after_ms: 3000} = power

      # Lights: requested and confirmed.
      assert %{requested: _, confirmed: _, backend: :power} = lights.disco
      assert %{requested: _, confirmed: _} = lights.strip

      # Brightness: backend, X11 display/output/readiness, bounds and default,
      # desired and applied software coefficient.
      assert %{
               backend: :simulated,
               display: _,
               output: _,
               x11_ready?: _,
               min: 0.3,
               max: 1.0,
               step: 0.1,
               default: 1.0,
               desired_coefficient: desired,
               applied_coefficient: _,
               availability: _,
               kind: kind
             } = brightness

      assert is_float(desired)
      assert kind =~ "software dimming"

      assert is_map(status.recent_error)

      text = inspect(status, limit: :infinity)
      refute text =~ "SECRET_KEY_BASE"
      refute text =~ Application.fetch_env!(:jukebox, JukeboxWeb.Endpoint)[:secret_key_base]
    end

    test "says why when the power controller cannot be read" do
      capture_log(fn ->
        Power.Simulated.set_available(false)
        status = Hardware.status()
        assert %{mode: :unknown, fresh?: false, reason: :missing} = status.power
        assert status.recent_error.power == :missing
        assert %{disco: %{requested: nil, confirmed: nil}} = status.lights
      end)
    end
  end

  describe "from a key event to an action" do
    test "the animation button walks the existing styles once each and wraps" do
      assert Animation.styles() == [:calm, :waves, :chase, :party]

      seen =
        for _ <- 1..5 do
          before = accepted()
          Input.tap(@animation)
          eventually(fn -> accepted() == before + 1 end)

          assert_receive {:command_feedback,
                          %{command: :cycle_animation, result: {:ok, {:animation, style}}}}

          # Clear of the debounce window before the next press.
          Process.sleep(100)
          style
        end

      assert seen == [:waves, :chase, :party, :calm, :waves]
      assert Animation.get() == :waves
      refute_receive {:command_feedback, _feedback}, 50
    end

    test "one press is one action however many browsers are connected" do
      # Each connected kiosk only listens; none of them reads the buttons.
      test = self()

      browsers =
        for n <- 1..3 do
          spawn_link(fn ->
            Animation.subscribe()
            Commands.subscribe()
            send(test, {:ready, n})

            receive do
              {:animation_style, style} -> send(test, {:browser, n, style})
            end

            receive do
              {:animation_style, style} -> send(test, {:browser, n, {:again, style}})
            after
              200 -> :ok
            end
          end)
        end

      for n <- 1..3, do: assert_receive({:ready, ^n})

      Input.tap(@animation)

      for n <- 1..3, do: assert_receive({:browser, ^n, :waves})
      refute_receive {:browser, _n, {:again, _style}}, 300
      assert Animation.get() == :waves
      assert length(browsers) == 3
    end

    test "transport buttons reach the remote control while a session is live" do
      Demo.start_session()
      Server.sync()

      Input.tap(@next)
      assert_receive {:command_feedback, %{command: :next_track, result: {:ok, :sent}}}
      assert RemoteControls.Demo.commands() == [:next_track]

      Input.tap(@play_pause)
      assert_receive {:command_feedback, %{command: :toggle_playback, result: {:ok, :sent}}}
      assert RemoteControls.Demo.commands() == [:toggle_playback, :next_track]
    end

    test "without a player the press is reported, sent nowhere, and never replayed" do
      # No AirPlay session: the transport is unavailable.
      Input.tap(@next)

      assert_receive {:command_feedback,
                      %{command: :next_track, result: {:error, :no_active_player}}}

      Process.sleep(100)
      Input.tap(@previous)

      assert_receive {:command_feedback,
                      %{command: :previous_track, result: {:error, :no_active_player}}}

      assert RemoteControls.Demo.commands() == []

      # The sender connects afterwards: nothing pressed earlier is sent now.
      Demo.start_session()
      Server.sync()
      Process.sleep(150)
      assert RemoteControls.Demo.commands() == []
      assert %{title: "Neon Milkshake"} = Server.get_state()
      refute_receive {:command_feedback, _feedback}, 50
    end

    test "a press does not claim a playback state before the source reports it" do
      Demo.start_session()
      Server.sync()
      assert %{playback_status: :playing} = Server.get_state()

      Input.tap(@play_pause)
      assert_receive {:command_feedback, %{result: {:ok, :sent}, playback_status: :playing}}

      # The state changes when the (demo) sender says so, not when the button
      # was pressed.
      Server.sync()
      eventually(fn -> Server.get_state().playback_status == :paused end)
    end

    test "nothing is dispatched in standby, and nothing happens on wake-up" do
      Demo.start_session()
      Server.sync()
      Power.Simulated.set_mode(:standby)

      discarded = Hardware.status().buttons.counts.discarded_not_awake

      for code <- 704..711 do
        Input.tap(code)
      end

      eventually(fn -> Hardware.status().buttons.counts.discarded_not_awake == discarded + 8 end)
      refute_receive {:command_feedback, _feedback}, 100
      assert RemoteControls.Demo.commands() == []
      assert Animation.get() == :calm

      Power.Simulated.set_mode(:awake)
      Power.Monitor.snapshot()
      refute_receive {:command_feedback, _feedback}, 150
      assert RemoteControls.Demo.commands() == []
      assert Animation.get() == :calm
    end
  end

  describe "software dimming, end to end" do
    test "a press dims the (pretend) display by one step and says what was confirmed" do
      eventually(fn -> Hardware.status().brightness.x11_ready? end)

      Input.tap(@brightness_down)

      assert_receive {:command_feedback,
                      %{command: :brightness_down, result: {:ok, {:brightness, 90}}}}

      assert %{
               desired_coefficient: 0.9,
               applied_coefficient: 0.9,
               x11_ready?: true,
               availability: :ready
             } =
               Hardware.status().brightness

      Process.sleep(100)
      Input.tap(@brightness_up)

      assert_receive {:command_feedback,
                      %{command: :brightness_up, result: {:ok, {:brightness, 100}}}}
    end

    test "the chosen brightness survives standby and an X restart, and is applied again" do
      Input.tap(@brightness_down)
      assert_receive {:command_feedback, %{result: {:ok, {:brightness, 90}}}}

      Power.Simulated.set_mode(:standby)
      Power.Monitor.snapshot()
      eventually(fn -> Hardware.status().brightness.availability == :not_awake end)
      assert %{desired_coefficient: 0.9, applied_coefficient: nil} = Hardware.status().brightness

      # Pressed during standby: dropped, the desired value does not move.
      Process.sleep(100)
      Input.tap(@brightness_down)
      Process.sleep(100)
      assert Hardware.status().brightness.desired_coefficient == 0.9

      Brightness.Simulated.reset()
      Power.Simulated.set_mode(:awake)
      Power.Monitor.snapshot()

      eventually(fn -> Hardware.status().brightness.applied_coefficient == 0.9 end)
      refute_receive {:command_feedback, _feedback}, 100
    end

    test "the desired value is held outside the worker and is first in the supervision tree" do
      [{first, _pid, _type, _modules} | _rest] =
        Jukebox.Hardware.Supervisor |> Supervisor.which_children() |> Enum.reverse()

      assert first == Brightness.Desired

      Input.tap(@brightness_down)
      assert_receive {:command_feedback, %{result: {:ok, {:brightness, 90}}}}

      # The worker crashes; everything started after it restarts with it.
      store = Process.whereis(Brightness.Desired)
      worker = Process.whereis(Brightness)
      ref = Process.monitor(worker)

      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(worker, :kill)
        assert_receive {:DOWN, ^ref, :process, ^worker, :killed}

        eventually(fn ->
          pid = Process.whereis(Brightness)
          pid != nil and pid != worker and Process.whereis(Jukebox.Hardware.Buttons) != nil
        end)
      end)

      assert Process.whereis(Brightness.Desired) == store
      eventually(fn -> Hardware.status().brightness.desired_coefficient == 0.9 end)
      eventually(fn -> match?(%{connection: :connected}, Hardware.status().buttons) end)
    end
  end

  describe "request/1" do
    test "hardware commands are accepted while awake and refused otherwise" do
      assert Hardware.request(:toggle_disco) == {:ok, :accepted}

      assert_receive {:command_feedback,
                      %{command: :toggle_disco, result: {:ok, {:light, :disco, _on?}}}}

      Power.Simulated.set_mode(:standby)
      assert Hardware.request(:toggle_disco) == {:error, :not_awake}
      assert Hardware.request(:brightness_up) == {:error, :not_awake}
    end

    test "the supervision tree is the one described" do
      children = Supervisor.which_children(Jukebox.Hardware.Supervisor)
      ids = Enum.map(children, &elem(&1, 0))

      for id <- [
            Brightness.Desired,
            Power.Simulated,
            Power.Monitor,
            Hardware.Lights,
            Hardware.Brightness,
            Hardware.Buttons,
            Input
          ] do
        assert id in ids, "#{inspect(id)} is not supervised"
      end

      # One input adapter, and one only.
      assert Enum.count(ids, &(&1 in [Input, Jukebox.Inputs.Evdev])) == 1
      assert Enum.all?(children, fn {_id, pid, _type, _modules} -> is_pid(pid) end)
    end
  end
end
