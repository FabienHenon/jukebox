defmodule JukeboxWeb.PresenterTest do
  use ExUnit.Case, async: true

  alias Jukebox.Playback.{Artwork, State}
  alias JukeboxWeb.Presenter

  @now ~U[2026-09-15 10:00:00Z]

  describe "mode/1" do
    test "idle when inactive" do
      assert Presenter.mode(State.new()) == :idle
      assert Presenter.mode(State.new(session_status: :ending)) == :idle
    end

    test "connecting while a session has no track yet" do
      assert Presenter.mode(State.new(session_status: :connecting)) == :connecting
      assert Presenter.mode(State.new(session_status: :active)) == :connecting
    end

    test "now playing as soon as a title, artist or artwork exists" do
      assert Presenter.mode(State.new(session_status: :active, title: "A")) == :now_playing

      assert Presenter.mode(State.new(session_status: :active, artwork: Artwork.demo(1))) ==
               :now_playing

      assert Presenter.mode(State.new(session_status: :ending, artist: "B")) == :now_playing
    end
  end

  describe "present/2" do
    test "idle copy" do
      view = Presenter.present(State.new(), @now)
      assert view.heading == "Ready to play"
      assert view.status_line == "Waiting for AirPlay…"
      assert view.progress == nil
      refute view.reconnecting?
    end

    test "connecting copy includes the source" do
      view =
        Presenter.present(
          State.new(session_status: :connecting, source_name: "Phone", metadata_connected?: true),
          @now
        )

      assert view.heading == "Receiving music…"
      assert view.status_line == "Connecting to Phone…"
    end

    test "fallback title only when the title is missing" do
      view = Presenter.present(State.new(session_status: :active, artist: "Band"), @now)
      assert view.title == "Unknown track"
      assert view.artist == "Band"
    end

    test "album is omitted when it repeats the title or artist" do
      base = State.new(session_status: :active, title: "Static Bloom", artist: "Ada")
      assert Presenter.present(%{base | album: "static bloom"}, @now).album == nil
      assert Presenter.present(%{base | album: "Ada"}, @now).album == nil
      assert Presenter.present(%{base | album: "Other"}, @now).album == "Other"
    end

    test "artwork falls back to the bundled design and keys change per track" do
      a = Presenter.present(State.new(session_status: :active, title: "A"), @now)
      b = Presenter.present(State.new(session_status: :active, title: "B"), @now)
      assert a.artwork_url == Artwork.fallback_url()
      assert a.artwork_fallback?
      assert a.artwork_key != b.artwork_key
      assert a.track_key != b.track_key

      with_art =
        Presenter.present(
          State.new(session_status: :active, title: "A", artwork: Artwork.demo(2)),
          @now
        )

      assert with_art.artwork_url == "/images/demo-artwork-2.svg"
      assert with_art.artwork_key == "demo-2"
    end

    test "the track key follows what is displayed, not the sender's id or the album" do
      base = State.new(session_status: :active, title: "Thunderstruck", artist: "AC/DC")
      key = Presenter.present(%{base | track_id: "provisional"}, @now).track_key

      assert Presenter.present(%{base | track_id: "final", album: "The Razors Edge"}, @now).track_key ==
               key

      assert Presenter.present(%{base | artist: "Other"}, @now).track_key != key

      id_only = Presenter.present(State.new(session_status: :active, track_id: "a"), @now)
      assert id_only.track_key != Presenter.present(State.new(track_id: "b"), @now).track_key
    end

    test "progress is only shown with a valid duration and interpolates while playing" do
      base =
        State.new(
          session_status: :active,
          title: "A",
          playback_status: :playing,
          position_ms: 10_000,
          duration_ms: 60_000,
          position_observed_at: DateTime.add(@now, -5, :second)
        )

      view = Presenter.present(base, @now)

      assert %{
               position_ms: 15_000,
               duration_ms: 60_000,
               playing?: true,
               elapsed: "0:15",
               total: "1:00"
             } = view.progress

      paused = Presenter.present(%{base | playback_status: :paused}, @now)
      assert %{position_ms: 10_000, playing?: false} = paused.progress

      assert Presenter.present(%{base | duration_ms: nil}, @now).progress == nil
      assert Presenter.present(%{base | position_ms: nil}, @now).progress == nil

      clamped =
        Presenter.present(%{base | position_observed_at: DateTime.add(@now, -600, :second)}, @now)

      assert clamped.progress.position_ms == 60_000
    end

    test "status pills and lines" do
      playing =
        State.new(
          session_status: :active,
          title: "A",
          playback_status: :playing,
          source_name: "Phone",
          metadata_connected?: true
        )

      assert Presenter.present(playing, @now).status_pill == %{label: "Playing", kind: :playing}
      assert Presenter.present(playing, @now).status_line == "From Phone"

      paused = %{playing | playback_status: :paused}
      view = Presenter.present(paused, @now)
      assert view.status_pill == %{label: "Paused", kind: :paused}
      assert view.paused?

      ending = %{playing | session_status: :ending}

      assert Presenter.present(ending, @now).status_pill == %{
               label: "Session ended",
               kind: :ending
             }

      assert Presenter.present(ending, @now).status_line == "Session ended"

      degraded = %{playing | metadata_connected?: false}
      view = Presenter.present(degraded, @now)
      assert view.reconnecting?
      assert view.status_line == "Reconnecting…"
    end

    test "volume is rounded" do
      assert Presenter.present(State.new(volume_percent: 72.4), @now).volume == 72
      assert Presenter.present(State.new(), @now).volume == nil
    end

    test "wave amplitude follows the reported volume and defaults to full" do
      assert Presenter.present(State.new(volume_percent: 100), @now).wave_level == 1.0
      assert Presenter.present(State.new(volume_percent: 0), @now).wave_level == 0.45
      assert Presenter.present(State.new(volume_percent: 50), @now).wave_level == 0.73
      assert Presenter.present(State.new(), @now).wave_level == 1.0
    end
  end

  describe "lights/2 and beating?/1" do
    setup do
      playing =
        State.new(session_status: :active, title: "A", playback_status: :playing)

      {:ok, playing: playing}
    end

    test "only the beat-driven styles light the frame, and only on Now Playing", %{
      playing: playing
    } do
      view = Presenter.present(playing, @now)
      assert Presenter.lights(view, :chase) == :chase
      assert Presenter.lights(view, :party) == :party
      assert Presenter.lights(view, :waves) == :off
      assert Presenter.lights(view, :calm) == :off

      idle = Presenter.present(State.new(), @now)
      assert Presenter.lights(idle, :party) == :off

      connecting = Presenter.present(State.new(session_status: :connecting), @now)
      assert Presenter.lights(connecting, :chase) == :off
    end

    test "the audio is followed on Now Playing, in every style but calm", %{playing: playing} do
      view = Presenter.present(playing, @now)
      assert Presenter.audio_reactive?(view, :waves)
      assert Presenter.audio_reactive?(view, :chase)
      assert Presenter.audio_reactive?(view, :party)
      refute Presenter.audio_reactive?(view, :calm)

      refute Presenter.audio_reactive?(Presenter.present(State.new(), @now), :party)

      connecting = Presenter.present(State.new(session_status: :connecting), @now)
      refute Presenter.audio_reactive?(connecting, :waves)
    end

    test "the beat runs only while music is playing", %{playing: playing} do
      assert Presenter.beating?(Presenter.present(playing, @now))
      refute Presenter.beating?(Presenter.present(%{playing | playback_status: :paused}, @now))
      refute Presenter.beating?(Presenter.present(%{playing | session_status: :ending}, @now))
      refute Presenter.beating?(Presenter.present(State.new(), @now))
    end
  end

  describe "feedback/1" do
    test "names the animation style the button selected" do
      for {style, label} <- [calm: "Calm", waves: "Waves", chase: "Chase", party: "Party"] do
        assert %{label: "Animation: " <> ^label, icon: :animation, kind: :ok} =
                 Presenter.feedback(%{
                   id: 1,
                   command: :cycle_animation,
                   result: {:ok, {:animation, style}},
                   playback_status: :unknown
                 })
      end
    end

    test "labels sent commands by intent" do
      assert %{label: "Next", icon: :next, kind: :ok} =
               Presenter.feedback(%{
                 id: 1,
                 command: :next_track,
                 result: {:ok, :sent},
                 playback_status: :playing
               })

      assert %{label: "Previous", icon: :previous} =
               Presenter.feedback(%{
                 id: 1,
                 command: :previous_track,
                 result: {:ok, :sent},
                 playback_status: :playing
               })

      assert %{label: "Pause", icon: :pause} =
               Presenter.feedback(%{
                 id: 1,
                 command: :toggle_playback,
                 result: {:ok, :sent},
                 playback_status: :playing
               })

      assert %{label: "Play", icon: :play} =
               Presenter.feedback(%{
                 id: 1,
                 command: :toggle_playback,
                 result: {:ok, :sent},
                 playback_status: :paused
               })
    end

    test "neutral labels for failures" do
      assert %{label: "No active player", kind: :muted} =
               Presenter.feedback(%{
                 id: 1,
                 command: :next_track,
                 result: {:error, :no_active_player},
                 playback_status: :unknown
               })

      assert %{label: "Control unavailable"} =
               Presenter.feedback(%{
                 id: 1,
                 command: :next_track,
                 result: {:error, :control_unavailable},
                 playback_status: :playing
               })

      assert %{label: "Command not delivered"} =
               Presenter.feedback(%{
                 id: 1,
                 command: :next_track,
                 result: {:error, :failed},
                 playback_status: :playing
               })
    end
  end

  test "format_time/1" do
    assert Presenter.format_time(0) == "0:00"
    assert Presenter.format_time(65_000) == "1:05"
    assert Presenter.format_time(3_725_000) == "1:02:05"
    assert Presenter.format_time(-5) == "0:00"
  end
end
