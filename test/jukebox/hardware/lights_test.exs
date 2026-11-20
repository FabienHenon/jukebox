defmodule Jukebox.Hardware.LightsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Jukebox.Test.HardwareHelpers

  alias Jukebox.Hardware.Lights
  alias Jukebox.Hardware.Power.Simulated

  @power_strip %{status: :enabled, control: :power, wled_url: nil, errors: []}
  @wled_strip %{status: :enabled, control: :wled, wled_url: "http://wled.test", errors: []}

  setup do
    {:ok, power: start_power(:awake)}
  end

  defp start_lights(power, opts \\ []) do
    test = self()
    simulated = power.power

    opts =
      Keyword.merge(
        [
          name: :"lights_#{System.unique_integer([:positive])}",
          strip: @power_strip,
          power_command: fn args -> Simulated.command(simulated, args) end,
          monitor: power.monitor,
          pubsub: power.pubsub,
          report: fn command, result -> send(test, {:report, command, result}) end,
          confirm_ms: 150,
          wled_sync_ms: 10
        ],
        opts
      )

    start_supervised!({Lights, opts})
  end

  # A WLED controller made of a Plug: state in an Agent, requests logged.
  defp start_wled(initial \\ %{on: false, mode: :ok}) do
    {:ok, agent} =
      Agent.start_link(fn -> Map.merge(%{on: false, mode: :ok, requests: []}, initial) end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = if body == "", do: nil, else: Jason.decode!(body)

      state =
        Agent.get_and_update(agent, fn state ->
          state = %{state | requests: [{conn.method, conn.request_path, body} | state.requests]}

          state =
            if conn.method == "POST" and state.mode == :ok,
              do: %{state | on: body["on"]},
              else: state

          {state, state}
        end)

      case state.mode do
        :ok -> Req.Test.json(conn, %{"on" => state.on, "bri" => 128})
        :down -> Req.Test.transport_error(conn, :econnrefused)
        :slow -> Req.Test.transport_error(conn, :timeout)
        :error -> Plug.Conn.send_resp(conn, 500, "oops")
      end
    end

    {agent, [plug: plug]}
  end

  defp wled_requests(agent), do: Agent.get(agent, &Enum.reverse(&1.requests))
  defp wled_set(agent, changes), do: Agent.update(agent, &Map.merge(&1, Map.new(changes)))

  describe "power-controller lights" do
    test "a toggle is reported only once the controller's state shows it", %{power: power} do
      lights = start_lights(power)

      assert Lights.toggle(lights, :disco) == {:ok, :accepted}
      assert_receive {:report, :toggle_disco, {:ok, {:light, :disco, true}}}
      assert Simulated.commands(power.power) == [["disco", "toggle"]]

      assert %{
               disco: %{
                 backend: :power,
                 requested: true,
                 confirmed: true,
                 pending: 0,
                 last_error: nil
               }
             } =
               Lights.status(lights)

      assert Lights.toggle(lights, :disco) == {:ok, :accepted}
      assert_receive {:report, :toggle_disco, {:ok, {:light, :disco, false}}}
      assert %{disco: %{requested: false, confirmed: false}} = Lights.status(lights)
    end

    test "the strip uses the power controller by default", %{power: power} do
      lights = start_lights(power)

      # The controller starts with the strip requested on (and the disco group
      # off): the strip button's first press switches it off.
      assert %{
               strip: %{backend: :power, requested: true, confirmed: true},
               disco: %{confirmed: false}
             } =
               Lights.status(lights)

      assert Lights.toggle(lights, :strip) == {:ok, :accepted}
      assert_receive {:report, :toggle_strip, {:ok, {:light, :strip, false}}}
      assert Simulated.commands(power.power) == [["strip", "toggle"]]
      assert %{strip: %{backend: :power, confirmed: false}} = Lights.status(lights)

      assert Lights.toggle(lights, :strip) == {:ok, :accepted}
      assert_receive {:report, :toggle_strip, {:ok, {:light, :strip, true}}}
    end

    test "a command the controller takes just as standby begins is not announced", %{power: power} do
      test = self()
      simulated = power.power

      held = fn args ->
        send(test, {:client, args, self()})

        receive do
          :go -> Simulated.command(simulated, args)
        end
      end

      lights = start_lights(power, power_command: held)
      assert Lights.toggle(lights, :disco) == {:ok, :accepted}
      assert_receive {:client, ["disco", "toggle"], client}

      # Standby begins while the client is on its way. The controller, as it
      # always did, keeps the request for the resume and lights nothing.
      set_mode(power, :standby)
      send(client, :go)

      eventually(fn -> Lights.status(lights).disco.pending == 0 end)
      refute_receive {:report, _command, _result}, 100

      assert %{disco: %{requested: true, confirmed: false, last_error: nil}} =
               Lights.status(lights)

      # On resume the controller applies what it kept.
      set_mode(power, :awake)
      assert %{disco: %{requested: true, confirmed: true}} = Lights.status(lights)
    end

    test "nothing is sent unless the jukebox is awake", %{power: power} do
      lights = start_lights(power)

      for mode <- [:standby, :booting, :shutting_down] do
        set_mode(power, mode)
        assert Lights.toggle(lights, :disco) == {:error, :not_awake}
        assert Lights.toggle(lights, :strip) == {:error, :not_awake}
      end

      Simulated.set_available(power.power, false)
      capture_log(fn -> assert Lights.toggle(lights, :disco) == {:error, :not_awake} end)

      assert Simulated.commands(power.power) == []
      refute_receive {:report, _command, _result}, 50
    end

    test "a toggle waiting when standby begins is dropped, not run later", %{power: power} do
      test = self()
      simulated = power.power

      # The first command is held inside the client until released.
      command = fn args ->
        send(test, {:client, args, self()})

        receive do
          :go -> Simulated.command(simulated, args)
        end
      end

      lights = start_lights(power, power_command: command)

      assert Lights.toggle(lights, :disco) == {:ok, :accepted}
      assert_receive {:client, ["disco", "toggle"], first}
      assert Lights.toggle(lights, :strip) == {:ok, :accepted}

      set_mode(power, :standby)
      send(first, :go)

      # The strip toggle was still queued: it never reaches the client. The
      # disco toggle that was already on its way is refused by the controller.
      # Neither is a hardware fault, and neither is shown as one.
      refute_receive {:client, ["strip", "toggle"], _pid}, 150
      refute_receive {:report, _command, _result}, 50

      set_mode(power, :awake)
      refute_receive {:client, _args, _pid}, 100
      assert %{strip: %{pending: 0}} = Lights.status(lights)
    end

    test "a rejected or unreachable controller is reported, without another attempt", %{
      power: power
    } do
      test = self()

      for reason <- [
            :unreachable,
            :client_missing,
            :permission_denied,
            {:rejected, "unknown_command"}
          ] do
        command = fn args ->
          send(test, {:client, args})
          {:error, reason}
        end

        lights = start_lights(power, power_command: command)

        log =
          capture_log(fn ->
            assert Lights.toggle(lights, :disco) == {:ok, :accepted}
            assert_receive {:report, :toggle_disco, {:error, :hardware_unavailable}}
          end)

        assert log =~ "disco toggle failed"
        assert_receive {:client, ["disco", "toggle"]}
        refute_receive {:client, _args}, 100
        assert %{disco: %{last_error: ^reason, pending: 0}} = Lights.status(lights)
        stop_supervised!(Lights)
      end
    end

    test "an uncertain result is never retried: the state decides", %{power: power} do
      test = self()
      simulated = power.power

      # The command IS applied, but the client never hears back.
      applied_silently = fn args ->
        send(test, {:client, args})
        Simulated.command(simulated, args)
        {:error, :no_ack}
      end

      lights = start_lights(power, power_command: applied_silently)

      capture_log(fn ->
        assert Lights.toggle(lights, :disco) == {:ok, :accepted}
        assert_receive {:report, :toggle_disco, {:ok, {:light, :disco, true}}}
      end)

      assert_receive {:client, ["disco", "toggle"]}
      refute_receive {:client, _args}, 200
      stop_supervised!(Lights)

      # The command is lost: nothing changes, so nothing is confirmed, and it
      # is still not sent a second time.
      lost = fn args ->
        send(test, {:client, args})
        {:error, :timeout}
      end

      lights = start_lights(power, power_command: lost)

      capture_log(fn ->
        assert Lights.toggle(lights, :disco) == {:ok, :accepted}
        assert_receive {:report, :toggle_disco, {:error, :unconfirmed}}, 1_000
      end)

      assert_receive {:client, ["disco", "toggle"]}
      refute_receive {:client, _args}, 200
      assert %{disco: %{confirmed: true, last_error: :unconfirmed}} = Lights.status(lights)
    end

    test "an acknowledgement from a controller that restarted meanwhile is not a confirmation", %{
      power: power
    } do
      stale_ack = fn _args ->
        {:ok, %{acked?: true, instance: "previous-instance", revision: 99}}
      end

      lights = start_lights(power, power_command: stale_ack)

      capture_log(fn ->
        assert Lights.toggle(lights, :disco) == {:ok, :accepted}
        assert_receive {:report, :toggle_disco, {:error, :unconfirmed}}, 1_000
      end)

      assert %{disco: %{confirmed: false}} = Lights.status(lights)
    end

    test "presses beyond the short queue are refused as busy", %{power: power} do
      test = self()

      held = fn args ->
        send(test, {:client, args, self()})

        receive do
          :go -> {:error, :unreachable}
        end
      end

      lights = start_lights(power, power_command: held)

      assert Lights.toggle(lights, :disco) == {:ok, :accepted}
      assert Lights.toggle(lights, :disco) == {:ok, :accepted}
      assert Lights.toggle(lights, :disco) == {:error, :busy}
      # The other light has its own count.
      assert Lights.toggle(lights, :strip) == {:ok, :accepted}

      capture_log(fn ->
        for _ <- 1..3 do
          assert_receive {:client, _args, pid}
          send(pid, :go)
        end

        for _ <- 1..3, do: assert_receive({:report, _command, {:error, :hardware_unavailable}})
      end)
    end

    test "status without a readable controller confirms nothing", %{power: power} do
      lights = start_lights(power)
      assert Lights.toggle(lights, :disco) == {:ok, :accepted}
      assert_receive {:report, :toggle_disco, {:ok, _light}}

      Simulated.set_available(power.power, false)

      capture_log(fn ->
        assert %{disco: %{requested: nil, confirmed: nil}, meaning_of_confirmed: meaning} =
                 Lights.status(lights)

        assert meaning =~ "not a measurement"
      end)
    end

    test "in standby the request is kept by the controller but nothing is confirmed on", %{
      power: power
    } do
      lights = start_lights(power)
      Lights.toggle(lights, :disco)
      assert_receive {:report, :toggle_disco, {:ok, {:light, :disco, true}}}

      set_mode(power, :standby)
      assert %{disco: %{requested: true, confirmed: false}} = Lights.status(lights)
    end
  end

  describe "strip through WLED" do
    test "with the supply already on, as the controller starts, nothing is asked of it", %{
      power: power
    } do
      {wled, req_options} = start_wled()
      lights = start_lights(power, strip: @wled_strip, wled_req_options: req_options)

      eventually(fn -> wled_requests(wled) != [] end)
      Process.sleep(50)
      assert Simulated.commands(power.power) == []
      assert %{strip: %{supply: %{requested: true, confirmed: true}}} = Lights.status(lights)
    end

    test "reads the state, sends the opposite as an explicit boolean and reads it back", %{
      power: power
    } do
      {wled, req_options} = start_wled(%{on: true})
      lights = start_lights(power, strip: @wled_strip, wled_req_options: req_options)

      assert Lights.toggle(lights, :strip) == {:ok, :accepted}
      assert_receive {:report, :toggle_strip, {:ok, {:light, :strip, false}}}

      posts = for {"POST", path, body} <- wled_requests(wled), do: {path, body}
      assert posts == [{"/json/state", %{"on" => false, "v" => true}}]

      assert Enum.all?(wled_requests(wled), fn {_method, path, _body} -> path == "/json/state" end)

      assert Lights.toggle(lights, :strip) == {:ok, :accepted}
      assert_receive {:report, :toggle_strip, {:ok, {:light, :strip, true}}}

      assert %{strip: %{backend: :wled, requested: true, confirmed: true, last_error: nil}} =
               Lights.status(lights)

      # The strip toggle never went to the power controller.
      refute ["strip", "toggle"] in Simulated.commands(power.power)
    end

    test "a WLED failure has no effect and is NEVER turned into a power toggle", %{power: power} do
      for mode <- [:down, :slow, :error] do
        {wled, req_options} = start_wled(%{on: true, mode: mode})
        lights = start_lights(power, strip: @wled_strip, wled_req_options: req_options)
        # Let the initial synchronisation attempts pass.
        eventually(fn -> wled_requests(wled) != [] end)

        log =
          capture_log(fn ->
            assert Lights.toggle(lights, :strip) == {:ok, :accepted}
            assert_receive {:report, :toggle_strip, {:error, :hardware_unavailable}}, 1_000
          end)

        assert log =~ "strip toggle failed"
        refute ["strip", "toggle"] in Simulated.commands(power.power)
        assert Enum.all?(wled_requests(wled), fn {method, _path, _body} -> method == "GET" end)

        assert %{strip: %{backend: :wled, last_error: error}} = Lights.status(lights)
        assert error != nil
        stop_supervised!(Lights)
      end
    end

    test "a WLED that keeps its own state is reported as unconfirmed", %{power: power} do
      # It answers every request, and stays on whatever it is asked.
      plug = fn conn -> Req.Test.json(conn, %{"on" => true}) end
      lights = start_lights(power, strip: @wled_strip, wled_req_options: [plug: plug])

      capture_log(fn ->
        assert Lights.toggle(lights, :strip) == {:ok, :accepted}
        assert_receive {:report, :toggle_strip, {:error, :unconfirmed}}
      end)

      assert %{strip: %{requested: false, confirmed: true, last_error: :readback_mismatch}} =
               Lights.status(lights)
    end

    test "the strip supply is switched on (idempotently) if it was off", %{power: _power} do
      # The controller starts with the supply on; here someone switched it off
      # (`strip off` on the command line, or the button in "power" mode before
      # the configuration was changed to WLED).
      power = start_power(:awake, requested: %{strip: false})
      {_wled, req_options} = start_wled()
      lights = start_lights(power, strip: @wled_strip, wled_req_options: req_options)

      eventually(fn -> ["strip", "on"] in Simulated.commands(power.power) end)

      eventually(fn ->
        match?(%{strip: %{supply: %{requested: true, confirmed: true}}}, Lights.status(lights))
      end)

      # Once it is on, it is not asked again.
      refresh(power)
      Process.sleep(50)
      assert Enum.count(Simulated.commands(power.power), &(&1 == ["strip", "on"])) == 1
    end

    test "after a standby, waits for WLED and restores the state last asked for", %{power: power} do
      {wled, req_options} = start_wled(%{on: false})
      lights = start_lights(power, strip: @wled_strip, wled_req_options: req_options)

      assert Lights.toggle(lights, :strip) == {:ok, :accepted}
      assert_receive {:report, :toggle_strip, {:ok, {:light, :strip, true}}}

      set_mode(power, :standby)
      assert %{strip: %{requested: true, confirmed: nil}} = Lights.status(lights)

      # The controller lost power: it is unreachable, and comes back switched
      # off (its boot preset).
      wled_set(wled, mode: :down, on: false, requests: [])
      set_mode(power, :awake)

      eventually(fn -> length(wled_requests(wled)) >= 3 end)
      assert %{strip: %{waiting_for_wled?: true, confirmed: nil}} = Lights.status(lights)
      assert Enum.all?(wled_requests(wled), fn {method, _path, _body} -> method == "GET" end)

      wled_set(wled, mode: :ok)

      eventually(fn ->
        match?(%{strip: %{confirmed: true, waiting_for_wled?: false}}, Lights.status(lights))
      end)

      assert {"POST", "/json/state", %{"on" => true, "v" => true}} in wled_requests(wled)
      refute ["strip", "toggle"] in Simulated.commands(power.power)
      # A restore is not a press: nothing is announced on the display.
      refute_receive {:report, _command, _result}, 50
    end

    test "after a restart nothing is replayed: the state is only read", %{power: power} do
      {wled, req_options} = start_wled(%{on: true})
      lights = start_lights(power, strip: @wled_strip, wled_req_options: req_options)

      eventually(fn -> match?(%{strip: %{confirmed: true}}, Lights.status(lights)) end)
      assert %{strip: %{requested: nil}} = Lights.status(lights)
      assert Enum.all?(wled_requests(wled), fn {method, _path, _body} -> method == "GET" end)
    end

    test "a misconfigured strip is unavailable, and the disco group still works", %{power: power} do
      strip = %{
        status: :error,
        control: :wled,
        wled_url: nil,
        errors: ["JUKEBOX_STRIP_CONTROL=wled needs JUKEBOX_WLED_URL"]
      }

      lights = start_lights(power, strip: strip)

      assert Lights.toggle(lights, :strip) == {:error, :unavailable}

      assert %{strip: %{backend: :unavailable, last_error: {:configuration, [_message]}}} =
               Lights.status(lights)

      assert Simulated.commands(power.power) == []

      assert Lights.toggle(lights, :disco) == {:ok, :accepted}
      assert_receive {:report, :toggle_disco, {:ok, {:light, :disco, true}}}
    end
  end
end
