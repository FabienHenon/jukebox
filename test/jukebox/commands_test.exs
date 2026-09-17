defmodule Jukebox.CommandsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Jukebox.Commands
  alias Jukebox.Playback.Server
  alias Jukebox.Test.FakeRemoteControl

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    server =
      start_supervised!(
        {Server, name: :"playback_#{System.unique_integer([:positive])}", pubsub: pubsub}
      )

    :ok = Commands.subscribe(pubsub)
    FakeRemoteControl.configure([])

    {:ok,
     opts: [remote_control: FakeRemoteControl, playback: server, pubsub: pubsub], server: server}
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

  test "unknown commands are rejected without feedback", %{opts: opts} do
    assert Commands.dispatch(:volume_up, opts) == {:error, :unknown_command}
    refute_receive {:command_feedback, _}
  end

  test "parse/1 maps strings to the semantic commands only" do
    assert Commands.parse("next_track") == {:ok, :next_track}
    assert Commands.parse("previous_track") == {:ok, :previous_track}
    assert Commands.parse("toggle_playback") == {:ok, :toggle_playback}
    assert Commands.parse("shutdown") == :error
    assert Commands.parse(42) == :error
  end
end
