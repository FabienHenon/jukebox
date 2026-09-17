defmodule Jukebox.MetadataSources.DemoTest do
  use ExUnit.Case, async: true

  alias Jukebox.Demo.Catalog
  alias Jukebox.MetadataSources.Demo
  alias Jukebox.Playback.{Artwork, Server, State}

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    server =
      start_supervised!(
        {Server,
         name: :"playback_#{System.unique_integer([:positive])}",
         pubsub: pubsub,
         idle_timeout_ms: 20}
      )

    demo = :"demo_#{System.unique_integer([:positive])}"
    start_supervised!({Demo, name: demo, playback: server, tick_ms: nil})
    :ok = Server.subscribe(pubsub)
    {:ok, server: server, demo: demo}
  end

  defp state(server) do
    Server.sync(server)
    Server.get_state(server)
  end

  test "marks the metadata link connected on start", %{server: server} do
    assert state(server).metadata_connected?
  end

  test "reports not running when the demo source is absent" do
    assert Demo.start_session(server: :no_such_demo) == {:error, :not_running}
  end

  test "a full session: start, next, pause, resume, end", %{server: server, demo: demo} do
    assert :ok = Demo.start_session(server: demo)
    first = Catalog.track(0)

    assert %State{
             session_status: :active,
             playback_status: :playing,
             title: "Neon Milkshake",
             artist: "The Velvet Comets",
             album: "Saturday Chrome",
             track_id: "demo-1",
             duration_ms: 227_000,
             position_ms: 0,
             artwork: %Artwork{id: "demo-1"},
             source_name: "Fabien's iPhone",
             remote_control: :available
           } = state(server)

    assert first.duration_ms == 227_000

    assert :ok = Demo.next_track(server: demo)

    assert %State{title: "Paper Moon Parade", track_id: "demo-2", artwork: %Artwork{id: "demo-2"}} =
             state(server)

    assert :ok = Demo.previous_track(server: demo)
    assert %State{track_id: "demo-1"} = state(server)

    assert :ok = Demo.pause(server: demo)
    assert %State{playback_status: :paused} = state(server)
    assert :ok = Demo.toggle(server: demo)
    assert %State{playback_status: :playing} = state(server)

    assert :ok = Demo.end_session(server: demo)
    assert %State{session_status: :ending, title: "Neon Milkshake"} = state(server)
    assert_receive {:playback_state, %State{session_status: :inactive}}, 500
  end

  test "transport commands need a session", %{demo: demo} do
    assert Demo.next_track(server: demo) == {:error, :no_session}
    assert Demo.play(server: demo) == {:error, :no_session}
  end

  test "partial metadata and missing artwork", %{server: server, demo: demo} do
    :ok = Demo.start_session(server: demo, partial: [:title], artwork: false)

    assert %State{
             title: "Neon Milkshake",
             artist: nil,
             album: nil,
             duration_ms: nil,
             artwork: nil
           } = state(server)
  end

  test "delayed metadata: the session connects first, the track arrives later", %{
    server: server,
    demo: demo
  } do
    :ok = Demo.start_session(server: demo, delay_ms: 20)
    assert %State{session_status: :connecting, title: nil} = state(server)

    assert_receive {:playback_state, %State{session_status: :active, title: "Neon Milkshake"}},
                   500
  end

  test "artwork can be swapped or removed for the current track", %{server: server, demo: demo} do
    :ok = Demo.start_session(server: demo)
    :ok = Demo.set_artwork(3, server: demo)
    assert %State{artwork: %Artwork{id: "demo-3"}, title: "Neon Milkshake"} = state(server)
    :ok = Demo.set_artwork(nil, server: demo)
    assert %State{artwork: nil, title: "Neon Milkshake"} = state(server)
  end

  test "editing metadata produces a new track identity and resends artwork", %{
    server: server,
    demo: demo
  } do
    :ok = Demo.start_session(server: demo)
    :ok = Demo.update_track(%{title: "Edited", album: nil}, server: demo)

    assert %State{
             title: "Edited",
             artist: "The Velvet Comets",
             album: nil,
             track_id: "demo-1-v1",
             artwork: %Artwork{id: "demo-1"}
           } = state(server)
  end

  test "progress and duration can be set, including an unknown duration", %{
    server: server,
    demo: demo
  } do
    :ok = Demo.start_session(server: demo)
    :ok = Demo.set_progress(30_000, 90_000, server: demo)
    assert %State{position_ms: 30_000, duration_ms: 90_000} = state(server)
    :ok = Demo.set_progress(5_000, nil, server: demo)
    assert %State{position_ms: 5_000, duration_ms: nil} = state(server)
  end

  test "remote-control availability is forwarded", %{server: server, demo: demo} do
    :ok = Demo.start_session(server: demo)
    :ok = Demo.set_remote_control(:unavailable, server: demo)
    assert %State{remote_control: :unavailable} = state(server)
  end

  test "a metadata disconnection drops events until reconnection, which resends everything", %{
    server: server,
    demo: demo
  } do
    :ok = Demo.start_session(server: demo)
    :ok = Demo.set_metadata_connection(:disconnected, server: demo)
    assert %State{metadata_connected?: false, title: "Neon Milkshake"} = state(server)

    :ok = Demo.next_track(server: demo)
    assert %State{title: "Neon Milkshake"} = state(server)

    :ok = Demo.set_metadata_connection(:connected, server: demo)
    assert %State{metadata_connected?: true, title: "Paper Moon Parade"} = state(server)
  end

  test "presets load edge-case tracks", %{server: server, demo: demo} do
    :ok = Demo.start_session(server: demo)
    :ok = Demo.load_preset(:no_title, server: demo)
    assert %State{title: nil, artist: "Nameless Ensemble"} = state(server)
    assert Demo.load_preset(:nope, server: demo) == {:error, :unknown_preset}
  end

  test "selecting a track while idle is remembered for the next session", %{
    server: server,
    demo: demo
  } do
    :ok = Demo.select_track(2, server: demo)
    assert %State{session_status: :inactive} = state(server)
    :ok = Demo.start_session(server: demo)
    assert %State{title: "Static Bloom"} = state(server)
  end

  test "the tick advances progress and moves to the next track at the end" do
    pubsub = :"pubsub_tick_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: pubsub}, id: pubsub))

    server =
      start_supervised!(
        {Server, name: :"playback_tick_#{System.unique_integer([:positive])}", pubsub: pubsub}
      )

    demo = :"demo_tick_#{System.unique_integer([:positive])}"
    start_supervised!({Demo, name: demo, playback: server, tick_ms: 5})
    :ok = Server.subscribe(pubsub)

    :ok = Demo.start_session(server: demo)
    :ok = Demo.set_progress(0, 40, server: demo)
    assert_receive {:playback_state, %State{title: "Paper Moon Parade"}}, 1_000
  end
end
