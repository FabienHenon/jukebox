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

  describe "coalescing a burst of events" do
    setup do
      pubsub = :"pubsub_c_#{System.unique_integer([:positive])}"
      start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: pubsub}, id: pubsub))

      server =
        start_supervised!(
          {Server,
           name: :"playback_c_#{System.unique_integer([:positive])}",
           coalesce_ms: 40,
           pubsub: pubsub}
        )

      :ok = Server.subscribe(pubsub)
      {:ok, burst: server}
    end

    test "the burst is applied as one batch and broadcast once", %{burst: server} do
      Server.notify(server, {:track_changed, %{track_id: "1", title: "A", artist: "X"}})
      Server.notify(server, {:artwork_changed, Artwork.demo(1), track_id: "1"})
      Server.notify(server, {:progress_changed, %{position_ms: 1_000, duration_ms: 60_000}})
      Server.notify(server, {:playback_changed, :playing})

      assert_receive {:playback_state,
                      %State{
                        title: "A",
                        artwork: %Artwork{id: "demo-1"},
                        duration_ms: 60_000,
                        playback_status: :playing
                      }},
                     500

      refute_receive {:playback_state, _}, 80
    end

    test "get_state does not cut a burst short, sync applies it", %{burst: server} do
      Server.notify(server, {:metadata_changed, %{title: "A"}})
      assert %State{title: nil} = Server.get_state(server)
      :ok = Server.sync(server)
      assert %State{title: "A"} = Server.get_state(server)
      assert_receive {:playback_state, %State{title: "A"}}
      refute_receive {:playback_state, _}, 80
    end

    test "consecutive metadata fragments form one bundle", %{burst: server} do
      Server.notify(server, {:track_changed, %{track_id: "a", title: "Song", artist: "X"}})
      Server.notify(server, {:artwork_changed, Artwork.demo(2)})
      Server.sync(server)

      # The same song re-announced field by field under another id: applied one
      # by one, the bare id would look like a new track and drop the artwork.
      Server.notify(server, {:metadata_changed, %{track_id: "b"}})
      Server.notify(server, {:metadata_changed, %{album: "LP"}})
      Server.notify(server, {:metadata_changed, %{artist: "X"}})
      Server.notify(server, {:metadata_changed, %{title: "Song"}})
      Server.sync(server)

      assert %State{track_id: "b", title: "Song", album: "LP", artwork: %Artwork{id: "demo-2"}} =
               Server.get_state(server)
    end

    test "fragments naming two different tracks are not merged", %{burst: server} do
      Server.notify(server, {:metadata_changed, %{track_id: "a", title: "One", album: "LP"}})
      Server.notify(server, {:metadata_changed, %{track_id: "b", title: "Two"}})
      Server.sync(server)
      assert %State{track_id: "b", title: "Two", album: nil} = Server.get_state(server)
    end

    test "each event keeps its own arrival time", %{burst: server} do
      Server.notify(server, {:progress_changed, %{position_ms: 5_000, duration_ms: 60_000}})
      Server.notify(server, {:playback_changed, :playing})
      Process.sleep(1)
      sent_by = DateTime.utc_now()
      Process.sleep(25)
      Server.sync(server)
      state = Server.get_state(server)
      assert DateTime.compare(state.position_observed_at, sent_by) == :lt
    end

    test "the idle timeout applies pending events first", %{burst: server} do
      Server.notify(server, {:track_changed, %{track_id: "1", title: "A"}})
      send(server, :flush_pending)
      assert_receive {:playback_state, %State{title: "A"}}, 500
    end
  end
end
