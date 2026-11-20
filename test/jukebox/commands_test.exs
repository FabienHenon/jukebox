defmodule Jukebox.CommandsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Jukebox.{Animation, Commands}
  alias Jukebox.Playback.Server
  alias Jukebox.Test.FakeRemoteControl

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    server =
      start_supervised!(
        {Server, name: :"playback_#{System.unique_integer([:positive])}", pubsub: pubsub}
      )

    animation =
      start_supervised!(
        {Animation,
         name: :"animation_#{System.unique_integer([:positive])}", pubsub: pubsub, style: :waves}
      )

    :ok = Commands.subscribe(pubsub)
    FakeRemoteControl.configure([])

    {:ok,
     opts: [
       remote_control: FakeRemoteControl,
       playback: server,
       pubsub: pubsub,
       animation: animation
     ],
     server: server,
     animation: animation}
  end

  defp activate(server, remote \\ :available) do
    Server.notify(server, {:track_changed, %{track_id: "1", title: "A"}})
    Server.notify(server, {:remote_control_changed, remote})
    Server.notify(server, {:playback_changed, :playing})
    Server.sync(server)
  end

  test "routes a command to the remote-control adapter when a session is active", %{
    opts: opts,
    server: server
  } do
    activate(server)
    assert Commands.dispatch(:next_track, opts) == {:ok, :sent}
    assert_receive {:remote_control, :next_track}

    assert_receive {:command_feedback,
                    %{
                      command: :next_track,
                      result: {:ok, :sent},
                      playback_status: :playing,
                      id: id
                    }}

    assert is_integer(id)
  end

  test "refuses commands without an active player and still emits feedback", %{opts: opts} do
    assert Commands.dispatch(:toggle_playback, opts) == {:error, :no_active_player}
    refute_receive {:remote_control, _}

    assert_receive {:command_feedback,
                    %{command: :toggle_playback, result: {:error, :no_active_player}}}
  end

  test "treats a session in connecting state as an active player", %{opts: opts, server: server} do
    Server.notify(server, {:session_started, %{}})
    Server.sync(server)
    assert Commands.dispatch(:previous_track, opts) == {:ok, :sent}
    assert_receive {:remote_control, :previous_track}
  end

  test "reports control unavailable when the state says so", %{opts: opts, server: server} do
    activate(server, :unavailable)
    assert Commands.dispatch(:next_track, opts) == {:error, :control_unavailable}
    refute_receive {:remote_control, _}
    assert_receive {:command_feedback, %{result: {:error, :control_unavailable}}}
  end

  test "reports control unavailable when the adapter lacks the capability", %{
    opts: opts,
    server: server
  } do
    activate(server)
    FakeRemoteControl.configure(capabilities: MapSet.new([:toggle_playback]))
    assert Commands.dispatch(:next_track, opts) == {:error, :control_unavailable}
    assert Commands.dispatch(:toggle_playback, opts) == {:ok, :sent}
  end

  test "converts adapter errors, raises and exits into a safe failure", %{
    opts: opts,
    server: server
  } do
    activate(server)

    for outcome <- [{:error, :timeout}, :raise, :exit, :weird] do
      FakeRemoteControl.configure(result: outcome)

      log =
        capture_log(fn ->
          assert Commands.dispatch(:next_track, opts) == {:error, :failed}
        end)

      assert log =~ "next_track"
      assert_receive {:command_feedback, %{result: {:error, :failed}}}
    end

    assert Process.alive?(server)
  end

  test "the animation button changes the style without a player or a remote control", %{
    opts: opts,
    animation: animation
  } do
    FakeRemoteControl.configure(capabilities: MapSet.new())

    assert Commands.dispatch(:cycle_animation, opts) == {:ok, {:animation, :chase}}
    assert Animation.get(animation) == :chase
    refute_receive {:remote_control, _}

    assert_receive {:command_feedback,
                    %{
                      command: :cycle_animation,
                      result: {:ok, {:animation, :chase}},
                      playback_status: :unknown
                    }}

    assert Commands.dispatch(:cycle_animation, opts) == {:ok, {:animation, :party}}
  end

  test "a missing animation server is a safe failure", %{opts: opts} do
    opts = Keyword.put(opts, :animation, :animation_server_that_does_not_exist)

    log =
      capture_log(fn ->
        assert Commands.dispatch(:cycle_animation, opts) == {:error, :failed}
      end)

    assert log =~ "cycle_animation"
    assert_receive {:command_feedback, %{command: :cycle_animation, result: {:error, :failed}}}
  end

  test "unknown commands are rejected without feedback", %{opts: opts} do
    assert Commands.dispatch(:volume_up, opts) == {:error, :unknown_command}
    refute_receive {:command_feedback, _}
  end

  test "parse/1 maps strings to the semantic commands only" do
    assert Commands.parse("next_track") == {:ok, :next_track}
    assert Commands.parse("previous_track") == {:ok, :previous_track}
    assert Commands.parse("toggle_playback") == {:ok, :toggle_playback}
    assert Commands.parse("cycle_animation") == {:ok, :cycle_animation}
    assert Commands.parse("shutdown") == :error
    assert Commands.parse(42) == :error
  end

  describe "hardware commands" do
    test "are part of the one command vocabulary" do
      for command <- [:toggle_disco, :toggle_strip, :brightness_down, :brightness_up] do
        assert command in Commands.commands()
        assert Commands.parse(Atom.to_string(command)) == {:ok, command}
      end

      assert Jukebox.Hardware.commands() -- Commands.commands() == []
    end

    test "an accepted request says nothing yet: the outcome is reported later", %{opts: opts} do
      test = self()

      hardware = fn command ->
        send(test, {:hardware, command})
        {:ok, :accepted}
      end

      assert Commands.dispatch(:toggle_disco, [hardware: hardware] ++ opts) == {:ok, :accepted}
      assert_receive {:hardware, :toggle_disco}
      refute_receive {:command_feedback, _feedback}, 50

      # ...by the worker, once the hardware confirmed it.
      assert Commands.report(:toggle_disco, {:ok, {:light, :disco, true}}, opts) ==
               {:ok, {:light, :disco, true}}

      assert_receive {:command_feedback,
                      %{command: :toggle_disco, result: {:ok, {:light, :disco, true}}, id: id}}

      assert is_integer(id)
    end

    test "a refused request is fed back at once", %{opts: opts} do
      for reason <- [:not_awake, :hardware_unavailable, :busy] do
        hardware = fn _command -> {:error, reason} end

        assert Commands.dispatch(:brightness_up, [hardware: hardware] ++ opts) == {:error, reason}
        assert_receive {:command_feedback, %{command: :brightness_up, result: {:error, ^reason}}}
      end
    end

    test "they need no AirPlay session and never reach the remote control", %{opts: opts} do
      hardware = fn _command -> {:ok, :accepted} end
      assert Commands.dispatch(:brightness_down, [hardware: hardware] ++ opts) == {:ok, :accepted}
      refute_receive {:remote_control, _command}, 20
    end

    test "an outcome is reported even when the playback server is away", %{opts: opts} do
      opts = Keyword.put(opts, :playback, :no_such_playback_server)

      assert Commands.report(:brightness_up, {:ok, {:brightness, 55}}, opts) ==
               {:ok, {:brightness, 55}}

      assert_receive {:command_feedback,
                      %{result: {:ok, {:brightness, 55}}, playback_status: :stopped}}
    end
  end
end
