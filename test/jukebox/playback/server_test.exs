defmodule Jukebox.Playback.ServerTest do
  use ExUnit.Case, async: true

  alias Jukebox.Playback.{Artwork, Server, State}

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    server =
      start_supervised!(
        {Server,
         name: :"playback_#{System.unique_integer([:positive])}",
         idle_timeout_ms: 30,
         pubsub: pubsub}
      )

    :ok = Server.subscribe(pubsub)
    {:ok, server: server}
  end

  test "starts inactive", %{server: server} do
    assert %State{session_status: :inactive, title: nil} = Server.get_state(server)
  end

  test "applies events and broadcasts meaningful changes", %{server: server} do
    Server.notify(server, {:metadata_changed, %{title: "Neon Milkshake"}})
    assert %State{title: "Neon Milkshake", session_status: :active} = Server.get_state(server)
    assert_receive {:playback_state, %State{title: "Neon Milkshake"}}
  end

  test "does not broadcast duplicate states", %{server: server} do
    Server.notify(server, {:metadata_changed, %{title: "Same"}})
    assert_receive {:playback_state, %State{title: "Same"}}
    Server.notify(server, {:metadata_changed, %{title: "Same"}})
    Server.sync(server)
    refute_receive {:playback_state, _}, 50
  end

  test "returns to idle after the grace period following session_ended", %{server: server} do
    Server.notify(server, {:session_started, %{source_name: "Phone"}})
    Server.notify(server, {:track_changed, %{track_id: "1", title: "A"}})
    Server.notify(server, {:session_ended, %{reason: :sender_disconnected}})
    assert_receive {:playback_state, %State{session_status: :ending, title: "A"}}

    assert_receive {:playback_state,
                    %State{session_status: :inactive, title: nil, source_name: nil}},
                   500
  end

  test "a new session cancels the pending idle transition", %{server: server} do
    Server.notify(server, {:track_changed, %{track_id: "1", title: "A"}})
    Server.notify(server, {:session_ended, %{}})
    Server.notify(server, {:session_started, %{source_name: "Phone"}})
    Server.notify(server, {:track_changed, %{track_id: "2", title: "B"}})
    assert_receive {:playback_state, %State{session_status: :ending}}
    Server.sync(server)
    refute_receive {:playback_state, %State{session_status: :inactive}}, 100
    assert %State{session_status: :active, title: "B"} = Server.get_state(server)
  end

  test "a stale idle timer message is ignored", %{server: server} do
    Server.notify(server, {:track_changed, %{track_id: "1", title: "A"}})
    send(server, {:idle_timeout, make_ref()})
    assert %State{session_status: :active} = Server.get_state(server)
  end

  test "ignores malformed events and stays alive", %{server: server} do
    Server.notify(server, :garbage)
    Server.notify(server, {:artwork_changed, "not-an-artwork"})
    Server.notify(server, {:progress_changed, "nope"})
    assert Process.alive?(server)
    assert %State{session_status: :inactive} = Server.get_state(server)
  end

  test "artwork references are stored and served to new readers", %{server: server} do
    Server.notify(server, {:artwork_changed, Artwork.demo(2)})
    assert %State{artwork: %Artwork{id: "demo-2"}} = Server.get_state(server)
  end

  test "reset returns to the initial state and broadcasts it", %{server: server} do
    Server.notify(server, {:track_changed, %{title: "A"}})
    assert_receive {:playback_state, %State{title: "A"}}
    :ok = Server.reset(server)
    assert_receive {:playback_state, %State{session_status: :inactive, title: nil}}
  end
end
