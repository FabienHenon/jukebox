defmodule JukeboxWeb.JukeboxLiveTest do
  # Exercises the global playback server, so it must not run concurrently
  # with other tests touching it.
  use JukeboxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Jukebox.Commands
  alias Jukebox.Demo.Catalog
  alias Jukebox.MetadataSources.Demo
  alias Jukebox.Playback.{Artwork, Server}
  alias Jukebox.RemoteControls

  setup do
    reset_world()
    on_exit(&reset_world/0)
    :ok
  end

  defp reset_world do
    Demo.reset()
    RemoteControls.Demo.clear()
    Server.reset()
  end

  defp notify(events) do
    Enum.each(events, &Server.notify/1)
    Server.sync()
  end

  defp play_track(track, extra \\ []) do
    notify(
      [
        {:session_started, %{source_name: "Test iPhone"}},
        {:track_changed, Map.put(track, :track_id, track.id)},
        {:artwork_changed, track.artwork && Artwork.demo(track.artwork), track_id: track.id},
        {:progress_changed, %{position_ms: 12_000, duration_ms: track.duration_ms}},
        {:playback_changed, :playing},
        {:remote_control_changed, :available}
      ] ++ extra
    )
  end

  describe "idle state" do
    test "renders the ready screen with the startup overlay in the static render", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)
      assert html =~ "Starting the music…"
      assert html =~ "Ready to play"
      assert html =~ "Waiting for AirPlay…"
      assert html =~ "jb-wordmark__letter"
      assert html =~ ~s(class="kiosk")
      refute html =~ "is-done"

      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#boot.is-done")
      assert has_element?(view, "h1.jb-wordmark .jb-wordmark__letter[style='--i:6']", "x")
      assert has_element?(view, "#screen-idle")
      assert has_element?(view, "#jukebox[data-mode=idle]")
    end

    test "contains no clickable controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "<button"
      refute html =~ "phx-click"
      refute html =~ "<a "
    end
  end

  describe "connecting state" do
    test "shows the source and never shows blank progress", %{conn: conn} do
      notify([{:session_started, %{source_name: "Test iPhone"}}])
      {:ok, view, html} = live(conn, ~p"/")
      assert has_element?(view, "#screen-connecting")
      assert html =~ "Receiving music…"
      assert html =~ "from Test iPhone"
      assert html =~ "Connecting to Test iPhone…"
      refute html =~ "0:00"
      refute html =~ "null"
    end
  end

  describe "now playing state" do
    test "renders artwork, title, artist, album, progress and status", %{conn: conn} do
      play_track(Catalog.track(0))
      {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#screen-playing")
      assert html =~ "Neon Milkshake"
      assert html =~ "The Velvet Comets"
      assert html =~ "Saturday Chrome"
      assert has_element?(view, "#art-demo-1 img[src='/images/demo-artwork-1.svg']")
      assert has_element?(view, "#art-demo-1[phx-hook=ArtworkPalette][data-palette-key=demo-1]")

      assert has_element?(
               view,
               ~s([phx-hook=JukeboxProgress][data-playing=true][data-duration="227000"])
             )

      assert html =~ "3:47"
      assert has_element?(view, ".pill[data-kind=playing]", "Playing")
      assert has_element?(view, "h1.jb-wordmark .jb-wordmark__text[data-text=Jukebox]")
      refute has_element?(view, "h1.jb-wordmark .jb-wordmark__letter")

      assert has_element?(
               view,
               ".np__waves[aria-hidden=true][style*='--wave-level: 1.0'] .np__wave--3"
             )

      assert html =~ "From Test iPhone"
      assert has_element?(view, "#jukebox[data-playback=playing]")
    end

    test "omits the album when it repeats the title and falls back for a missing title", %{
      conn: conn
    } do
      play_track(Catalog.track(2))
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, ".np__title", "Static Bloom")
      refute has_element?(view, ".np__album")

      play_track(Catalog.preset(:no_title))
      assert has_element?(view, ".np__title", "Unknown track")
      assert has_element?(view, ".np__artist", "Nameless Ensemble")
    end

    test "hides progress when the duration is unknown and uses the fallback artwork", %{
      conn: conn
    } do
      play_track(Catalog.preset(:no_artist))
      {:ok, view, html} = live(conn, ~p"/")
      refute has_element?(view, "[phx-hook=JukeboxProgress]")

      assert has_element?(
               view,
               ".np__art[data-fallback=true] img[src='/images/fallback-artwork.svg']"
             )

      refute html =~ "0:00"
    end

    test "renders long, unicode and emoji metadata without breaking", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      for key <- [:long, :unicode, :emoji] do
        track = Catalog.preset(key)
        play_track(track)
        html = render(view)
        assert html =~ Phoenix.HTML.html_escape(track.title) |> Phoenix.HTML.safe_to_string()
        assert html =~ Phoenix.HTML.html_escape(track.artist) |> Phoenix.HTML.safe_to_string()
      end
    end
  end

  describe "paused, ending and degraded states" do
    test "paused keeps the track and stops interpolation", %{conn: conn} do
      play_track(Catalog.track(1), [{:playback_changed, :paused}])
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#jukebox[data-playback=paused]")
      assert has_element?(view, ".pill[data-kind=paused]", "Paused")
      assert has_element?(view, "[phx-hook=JukeboxProgress][data-playing=false]")
      assert has_element?(view, ".np__title", "Paper Moon Parade")
    end

    test "session end keeps the last track visible until the grace period elapses", %{conn: conn} do
      play_track(Catalog.track(1), [{:session_ended, %{reason: :sender_disconnected}}])
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, ".np__title", "Paper Moon Parade")
      assert has_element?(view, ".pill[data-kind=ending]", "Session ended")
    end

    test "a lost metadata connection shows a discreet reconnecting hint", %{conn: conn} do
      play_track(Catalog.track(0), [{:metadata_connection_changed, :disconnected}])
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#status-line[data-reconnecting=true]", "Reconnecting…")
      assert has_element?(view, ".np__title", "Neon Milkshake")
    end
  end

  describe "live updates and restoration" do
    test "receives PubSub updates after mount", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#screen-idle")

      notify([{:session_started, %{source_name: "Late iPhone"}}])
      assert has_element?(view, "#screen-connecting")

      play_track(Catalog.track(3))
      assert has_element?(view, ".np__title", "Sunroof Confessions (Live at the Drive-In)")
      refute has_element?(view, ".np__album")

      play_track(Catalog.track(0))
      assert has_element?(view, "#art-demo-1")
      refute has_element?(view, "#art-demo-4")
    end

    test "a fresh mount restores the authoritative state (browser refresh during playback)", %{
      conn: conn
    } do
      play_track(Catalog.track(2))
      {:ok, _first, _} = live(conn, ~p"/")
      {:ok, second, _} = live(conn, ~p"/")
      assert has_element?(second, ".np__title", "Static Bloom")
      assert has_element?(second, "#jukebox[data-mode=now_playing]")
    end
  end

  describe "command feedback" do
    test "shows a neutral hint when there is no active player", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      Commands.dispatch(:next_track)
      assert has_element?(view, ".jb-feedback[data-kind=muted]", "No active player")
    end

    test "acknowledges a delivered command", %{conn: conn} do
      :ok = Demo.start_session()
      {:ok, view, _} = live(conn, ~p"/")
      Commands.dispatch(:next_track)
      assert has_element?(view, ".jb-feedback[data-kind=ok]", "Next")
      assert RemoteControls.Demo.last_command() == :next_track
      Server.sync()
      assert has_element?(view, ".np__title", "Paper Moon Parade")
    end

    test "shows control unavailable when the sender cannot be controlled", %{conn: conn} do
      :ok = Demo.start_session()
      :ok = Demo.set_remote_control(:unavailable)
      {:ok, view, _} = live(conn, ~p"/")
      Commands.dispatch(:toggle_playback)
      assert has_element?(view, ".jb-feedback[data-kind=muted]", "Control unavailable")
    end

    test "the feedback disappears after the acknowledgement window", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      Commands.dispatch(:previous_track)
      assert has_element?(view, ".jb-feedback")
      Process.sleep(1_000)
      refute has_element?(view, ".jb-feedback")
    end
  end

  describe "development keyboard shortcuts" do
    test "route through the semantic command service", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#jukebox[phx-hook=DevelopmentKeys]")

      render_hook(view, "dev_command", %{"command" => "connect"})
      Server.sync()
      assert has_element?(view, "#screen-playing")

      render_hook(view, "dev_command", %{"command" => "next_track"})
      assert RemoteControls.Demo.last_command() == :next_track
      assert has_element?(view, ".jb-feedback", "Next")

      render_hook(view, "dev_command", %{"command" => "toggle_playback"})
      assert RemoteControls.Demo.last_command() == :toggle_playback
      Server.sync()
      assert has_element?(view, "#jukebox[data-playback=paused]")

      render_hook(view, "dev_command", %{"command" => "idle"})
      Server.sync()
      assert has_element?(view, ".pill[data-kind=ending]")

      render_hook(view, "dev_command", %{"command" => "shutdown"})
      assert Process.alive?(view.pid)
    end
  end
end
