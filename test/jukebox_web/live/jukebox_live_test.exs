defmodule JukeboxWeb.JukeboxLiveTest do
  # Exercises the global playback server, so it must not run concurrently
  # with other tests touching it.
  use JukeboxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Jukebox.{Animation, AudioAnalysis, Commands}
  alias Jukebox.AudioAnalysis.{Frame, SimulatedSource}
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
    Animation.set(:waves)
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
      assert has_element?(view, "#jukebox .screen--idle")
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
      assert has_element?(view, "#jukebox .screen--connecting")
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

      assert has_element?(view, "#jukebox .screen--playing")
      assert html =~ "Neon Milkshake"
      assert html =~ "The Velvet Comets"
      assert html =~ "Saturday Chrome"

      assert has_element?(
               view,
               "#jukebox .np__art[data-palette-key=demo-1] img[src='/images/demo-artwork-1.svg']"
             )

      assert has_element?(
               view,
               "#jukebox .np__art[phx-hook=ArtworkPalette][data-palette-key=demo-1]"
             )

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
      assert has_element?(view, "#jukebox .screen--idle")

      notify([{:session_started, %{source_name: "Late iPhone"}}])
      assert has_element?(view, "#jukebox .screen--connecting")

      play_track(Catalog.track(3))
      assert has_element?(view, ".np__title", "Sunroof Confessions (Live at the Drive-In)")
      refute has_element?(view, ".np__album")

      play_track(Catalog.track(0))
      assert has_element?(view, "#jukebox .np__art[data-palette-key=demo-1]")
      refute has_element?(view, "#jukebox .np__art[data-palette-key=demo-4]")
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

  describe "elements that fade out" do
    # LiveView keeps an element with phx-remove in the DOM while it fades. A
    # new element rendered with the same id during that time is patched into
    # the leaving one and then removed with it, which blanks the screen.
    test "screens, artwork and track text never reuse a DOM id", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      ids = fn selector ->
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#jukebox " <> selector)
        |> LazyHTML.attribute("id")
      end

      snapshot = fn -> {ids.(".screen"), ids.(".np__art"), ids.(".np__meta")} end

      idle = snapshot.()
      play_track(Catalog.track(0))
      first = snapshot.()
      play_track(Catalog.track(1))
      second = snapshot.()
      play_track(Catalog.track(0))
      first_again = snapshot.()
      reset_world()
      idle_again = snapshot.()
      play_track(Catalog.track(0))
      restarted = snapshot.()

      history = [idle, first, second, first_again, idle_again, restarted]
      screens = history |> Enum.map(&elem(&1, 0)) |> Enum.dedup()
      artworks = history |> Enum.flat_map(&elem(&1, 1))
      texts = history |> Enum.flat_map(&elem(&1, 2))

      # idle -> playing -> idle -> playing: four screens, four distinct ids
      assert [[_], [_], [_], [_]] = screens
      assert screens == Enum.uniq(screens)
      # the same track and cover shown three times get three distinct ids
      assert length(artworks) == 4 and artworks == Enum.uniq(artworks)
      assert length(texts) == 4 and texts == Enum.uniq(texts)
    end

    test "the same song re-announced under another id does not replay the track change", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/")

      notify([
        {:session_started, %{source_name: "Test iPhone"}},
        {:metadata_changed, %{track_id: "provisional", title: "Thunderstruck", artist: "AC/DC"}},
        {:artwork_changed, Artwork.demo(2)}
      ])

      meta_id = view |> element("#jukebox .np__meta") |> render() |> LazyHTML.from_fragment()
      meta_id = LazyHTML.attribute(meta_id, "id")

      notify([
        {:metadata_changed,
         %{track_id: "final", title: "Thunderstruck", artist: "AC/DC", album: "The Razors Edge"}}
      ])

      assert has_element?(view, "#jukebox .np__album", "The Razors Edge")
      assert has_element?(view, "#jukebox .np__art[data-palette-key=demo-2]")

      same = view |> element("#jukebox .np__meta") |> render() |> LazyHTML.from_fragment()
      assert LazyHTML.attribute(same, "id") == meta_id
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

  describe "audio-reactive animation" do
    defp enable_audio(settings \\ []) do
      previous_source = Application.fetch_env!(:jukebox, :audio_source)
      previous_settings = Application.get_env(:jukebox, AudioAnalysis, [])

      on_exit(fn ->
        Application.put_env(:jukebox, :audio_source, previous_source)
        Application.put_env(:jukebox, AudioAnalysis, previous_settings)
      end)

      # The source process is not needed: the tests publish frames themselves.
      Application.put_env(:jukebox, :audio_source, {SimulatedSource, []})
      Application.put_env(:jukebox, AudioAnalysis, Keyword.merge(previous_settings, settings))
    end

    defp frame(overrides \\ %{}) do
      {:ok, frame} =
        %{level: 0.4204, bass: 0.71, onset: 0.83, beat_id: 127, bpm: 118.44, confidence: 0.76}
        |> Map.merge(overrides)
        |> Frame.new()

      frame
    end

    test "disabled (the default): the frame says so and frames are ignored", %{conn: conn} do
      play_track(Catalog.track(0))
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#jukebox-body[data-audio=false]")
      refute has_element?(view, "#jukebox-body[data-audio-delay-ms]")
      refute has_element?(view, "#jukebox-body[data-audio-threshold]")

      # Not subscribed: even a published frame never reaches the browser.
      AudioAnalysis.publish(frame())
      refute_push_event(view, "audio-frame", %{}, 50)
    end

    test "enabled: the hook gets its tuning values", %{conn: conn} do
      enable_audio(visual_delay_ms: 90, beat_confidence_threshold: 0.6)
      play_track(Catalog.track(0))
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#jukebox-body[data-audio=true][data-audio-delay-ms='90'][data-audio-threshold='0.6']"
             )
    end

    test "each frame becomes one browser event and never a render", %{conn: conn} do
      enable_audio()
      play_track(Catalog.track(0))
      {:ok, view, _} = live(conn, ~p"/")
      before = render(view)

      AudioAnalysis.publish(frame())

      assert_push_event(view, "audio-frame", %{
        level: 0.42,
        bass: 0.71,
        onset: 0.83,
        beat_id: 127,
        bpm: 118.4,
        confidence: 0.76
      })

      for beat <- 128..150, do: AudioAnalysis.publish(frame(%{beat_id: beat, bpm: nil}))
      assert_push_event(view, "audio-frame", %{beat_id: 150, bpm: nil})

      # Nothing about the page changed: the frames only travelled as events.
      assert render(view) == before
    end

    test "frames are not forwarded when nothing should follow them", %{conn: conn} do
      enable_audio()
      {:ok, view, _} = live(conn, ~p"/")

      # Idle screen.
      assert has_element?(view, "#jukebox-body[data-audio=false]")
      AudioAnalysis.publish(frame())
      refute_push_event(view, "audio-frame", %{}, 50)

      # A track is showing: followed, paused or not.
      play_track(Catalog.track(0), [{:playback_changed, :paused}])
      assert has_element?(view, "#jukebox-body[data-audio=true]")
      AudioAnalysis.publish(frame(%{beat_id: 1}))
      assert_push_event(view, "audio-frame", %{beat_id: 1})

      # The calm style has no motion at all.
      Animation.set(:calm)
      assert has_element?(view, "#jukebox-body[data-audio=false]")
      AudioAnalysis.publish(frame(%{beat_id: 2}))
      refute_push_event(view, "audio-frame", %{beat_id: 2}, 50)

      Animation.set(:party)
      assert has_element?(view, "#jukebox-body[data-audio=true][data-lights=party]")
      AudioAnalysis.publish(frame(%{beat_id: 3}))
      assert_push_event(view, "audio-frame", %{beat_id: 3})
    end

    test "the static render does not subscribe", %{conn: conn} do
      enable_audio()
      play_track(Catalog.track(0))
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s(data-audio="true")
      assert Registry.count_match(Jukebox.PubSub, AudioAnalysis.topic(), :_) == 0
    end
  end

  describe "animation styles" do
    test "the default style shows the waves and leaves the lights alone", %{conn: conn} do
      play_track(Catalog.track(0))
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#jukebox[data-animation=waves] .np__waves")
      assert has_element?(view, "#jukebox-body[phx-hook=JukeboxLights][data-lights=off]")
      assert has_element?(view, "#jukebox-body[data-beat-ms='500'][style='--beat:500ms']")
    end

    test "the button cycles the style on a connected kiosk", %{conn: conn} do
      play_track(Catalog.track(0))
      {:ok, view, _} = live(conn, ~p"/")

      assert Commands.dispatch(:cycle_animation) == {:ok, {:animation, :chase}}
      assert has_element?(view, "#jukebox[data-animation=chase] .np__waves")
      assert has_element?(view, "#jukebox-body[data-lights=chase][data-beating=true]")
      assert has_element?(view, ".jb-feedback[data-kind=ok]", "Animation: Chase")

      Commands.dispatch(:cycle_animation)
      assert has_element?(view, "#jukebox-body[data-lights=party][data-beating=true]")
      assert has_element?(view, ".jb-feedback", "Animation: Party")

      Commands.dispatch(:cycle_animation)
      assert has_element?(view, "#jukebox[data-animation=calm] .screen--playing")
      refute has_element?(view, ".np__waves")
      assert has_element?(view, "#jukebox-body[data-lights=off]")

      Commands.dispatch(:cycle_animation)
      assert has_element?(view, "#jukebox[data-animation=waves] .np__waves")
    end

    test "the lights hold still while paused and stay off outside Now Playing", %{conn: conn} do
      Animation.set(:party)
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#jukebox[data-mode=idle][data-animation=party]")
      assert has_element?(view, "#jukebox-body[data-lights=off]")

      play_track(Catalog.track(0), [{:playback_changed, :paused}])
      assert has_element?(view, "#jukebox-body[data-lights=party][data-beating=false]")

      notify([{:playback_changed, :playing}])
      assert has_element?(view, "#jukebox-body[data-lights=party][data-beating=true]")
    end

    test "the style works without a player and is restored on a fresh mount", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      Commands.dispatch(:cycle_animation)
      assert has_element?(view, ".jb-feedback[data-kind=ok]", "Animation: Chase")

      {:ok, fresh, _} = live(conn, ~p"/")
      assert has_element?(fresh, "#jukebox[data-animation=chase]")
    end

    test "the hook owns the pillar blocks, the bulbs and nothing else", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      for id <- ~w(pillar-left pillar-right lights-left lights-right) do
        assert has_element?(view, "##{id}[phx-update=ignore]")
      end

      assert has_element?(view, "#pillar-left .jb-seg[data-color=lemon]")
      assert has_element?(view, "#lights-right .bulb[data-color=mint]")
      assert has_element?(view, ".jb-base .jb-grille .jb-grille__wave path")
      refute has_element?(view, "#boot .jb-lights[phx-update]")
    end
  end

  describe "development keyboard shortcuts" do
    test "the A key presses the animation button", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      render_hook(view, "dev_command", %{"command" => "cycle_animation"})
      assert Animation.get() == :chase
      assert has_element?(view, "#jukebox[data-animation=chase]")
    end

    test "route through the semantic command service", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#jukebox[phx-hook=DevelopmentKeys]")

      render_hook(view, "dev_command", %{"command" => "connect"})
      Server.sync()
      assert has_element?(view, "#jukebox .screen--playing")

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
