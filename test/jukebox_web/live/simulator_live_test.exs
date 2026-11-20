defmodule JukeboxWeb.SimulatorLiveTest do
  # The simulator is compiled in test (config :jukebox, simulator: true) but,
  # exactly like production, it is not routed, so it is mounted in isolation.
  use JukeboxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Jukebox.Test.HardwareHelpers, only: [eventually: 1]

  alias Jukebox.Animation
  alias Jukebox.AudioAnalysis.SimulatedSource
  alias Jukebox.MetadataSources.Demo
  alias Jukebox.Playback.Server
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
    Jukebox.Hardware.Power.Simulated.set_available(true)
    Jukebox.Hardware.Power.Simulated.set_mode(:awake)
    Jukebox.Hardware.Brightness.Simulated.set_available(true)
    Jukebox.Hardware.Brightness.Desired.update(fn _current -> 1000 end)
  end

  test "drives a complete session from the controls", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, JukeboxWeb.SimulatorLive)
    assert html =~ "Kiosk preview"
    assert has_element?(view, "#kiosk-preview[src='/']")

    view |> element("button", "Start session") |> render_click()
    Server.sync()
    assert %{session_status: :active, title: "Neon Milkshake"} = Server.get_state()
    assert render(view) =~ "Neon Milkshake"

    view |> element("button", "Paused") |> render_click()
    Server.sync()
    assert %{playback_status: :paused} = Server.get_state()

    view |> element("button", "2. Paper Moon Parade") |> render_click()
    Server.sync()
    assert %{title: "Paper Moon Parade"} = Server.get_state()

    view |> element("button", "No artwork") |> render_click()
    Server.sync()
    assert %{artwork: nil} = Server.get_state()

    view
    |> form("#track-form", track: %{title: "Edited title", artist: "", album: "LP"})
    |> render_submit()

    Server.sync()
    assert %{title: "Edited title", artist: nil, album: "LP"} = Server.get_state()

    view
    |> form("#progress-form", progress: %{position: "30", duration: "120"})
    |> render_submit()

    Server.sync()
    assert %{position_ms: 30_000, duration_ms: 120_000} = Server.get_state()

    view |> element("button", "Disconnect metadata") |> render_click()
    Server.sync()
    assert %{metadata_connected?: false} = Server.get_state()
    view |> element("button", "Reconnect metadata") |> render_click()
    Server.sync()
    assert %{metadata_connected?: true} = Server.get_state()

    view |> element("button", "Remote unavailable") |> render_click()
    Server.sync()
    assert %{remote_control: :unavailable} = Server.get_state()

    view |> element("button", "End session") |> render_click()
    Server.sync()
    assert %{session_status: :ending} = Server.get_state()
  end

  test "physical button presses go through the fake input and are logged", %{conn: conn} do
    {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)
    view |> element("button", "Start session") |> render_click()
    view |> element("button", "⏭ Next") |> render_click()
    assert RemoteControls.Demo.last_command() == :next_track
    assert has_element?(view, "#command-log code", "next_track")
    Server.sync()
    assert %{title: "Paper Moon Parade"} = Server.get_state()
  end

  test "the animation button cycles the style through the fake input", %{conn: conn} do
    {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)
    assert has_element?(view, "#animation-styles .is-active[data-style=waves]")

    view |> element("#animation-button") |> render_click()
    assert Animation.get() == :chase
    assert has_element?(view, "#animation-styles .is-active[data-style=chase]")
    assert has_element?(view, "#command-log code", "cycle_animation")

    # A second press inside the debounce window would be swallowed, exactly
    # like switch bounce on the real button.
    Process.sleep(100)
    view |> element("#animation-button") |> render_click()
    assert Animation.get() == :party
    assert has_element?(view, "#animation-styles .is-active[data-style=party]")

    view |> element("button", "Reset everything") |> render_click()
    assert Animation.get() == :chase
    assert has_element?(view, "#animation-styles .is-active[data-style=chase]")
  end

  describe "physical controls card" do
    setup do
      # The pretend encoder is shared by these tests: stay clear of the
      # debounce window of a key the previous test has just released.
      Process.sleep(100)
    end

    test "a raw key press goes through the real dispatcher, once", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)
      assert has_element?(view, "#hardware-power-mode", "awake")
      assert has_element?(view, "#hardware-connection", "Simulated button encoder")

      view |> element("#hardware-tap-animation_next") |> render_click()

      eventually(fn -> Animation.get() == :chase end)
      eventually(fn -> has_element?(view, "#hardware-last-accepted", "animation_next") end)
      assert has_element?(view, "#animation-styles .is-active[data-style=chase]")
      assert has_element?(view, "#command-log code", "cycle_animation")
    end

    test "lights and software dimming show what was confirmed", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)
      before = Jukebox.Hardware.status().lights.disco.confirmed

      view |> element("#hardware-tap-disco_toggle") |> render_click()
      eventually(fn -> Jukebox.Hardware.status().lights.disco.confirmed == not before end)
      state = if before, do: "off", else: "on"
      eventually(fn -> has_element?(view, "#hardware-light-disco", state) end)
      eventually(fn -> has_element?(view, "#command-log code", "toggle_disco") end)

      # Software dimming starts at the neutral 1.0: one press down is 0.9.
      view |> element("#hardware-tap-brightness_down") |> render_click()
      eventually(fn -> Jukebox.Hardware.status().brightness.applied_coefficient == 0.9 end)
      eventually(fn -> has_element?(view, "#hardware-brightness", "0.9 applied") end)
      assert has_element?(view, "#hardware-brightness", "0.9 desired")
      eventually(fn -> has_element?(view, "#command-log code", "brightness_down") end)
    end

    test "the pretend X server can go away and come back", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)
      eventually(fn -> Jukebox.Hardware.status().brightness.x11_ready? end)

      ExUnit.CaptureLog.capture_log(fn ->
        view |> element("#hardware-display-down") |> render_click()
        view |> element("#hardware-tap-brightness_down") |> render_click()

        # The press is taken (the desired value moves) but nothing is applied.
        eventually(fn -> has_element?(view, "#hardware-brightness", "x11_unavailable") end)
        assert has_element?(view, "#hardware-brightness", "0.9 desired")

        view |> element("#hardware-display-up") |> render_click()
        eventually(fn -> has_element?(view, "#hardware-brightness", "0.9 applied") end)
      end)
    end

    test "in standby, or without the controller, the keys do nothing", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)

      view |> element("#hardware-power-standby") |> render_click()
      assert has_element?(view, "#hardware-power-mode", "standby")
      assert has_element?(view, "#hardware-power-standby.is-active")

      discarded = Jukebox.Hardware.status().buttons.counts.discarded_not_awake
      view |> element("#hardware-tap-animation_next") |> render_click()

      eventually(fn ->
        Jukebox.Hardware.status().buttons.counts.discarded_not_awake == discarded + 1
      end)

      assert Animation.get() == :waves

      ExUnit.CaptureLog.capture_log(fn ->
        view |> element("#hardware-power-down") |> render_click()
        assert has_element?(view, "#hardware-power-mode", "unknown")
        assert has_element?(view, "#hardware-errors", "missing")

        # A different key: the previous one was released moments ago, and a
        # press that close to it would be taken for contact bounce.
        view |> element("#hardware-tap-next") |> render_click()

        eventually(fn ->
          Jukebox.Hardware.status().buttons.counts.discarded_not_awake == discarded + 2
        end)
      end)

      view |> element("button", "Reset everything") |> render_click()
      assert has_element?(view, "#hardware-power-mode", "awake")
      assert Animation.get() == :chase
    end
  end

  test "without the simulated analyser the audio card only names the source", %{conn: conn} do
    {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)
    assert has_element?(view, "#audio-card #audio-source code", "disabled")
    refute has_element?(view, "#audio-profiles")
  end

  test "the audio card drives the simulated analyser", %{conn: conn} do
    start_supervised!({SimulatedSource, tick_ms: nil})
    {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)

    assert has_element?(view, "#audio-profile-steady.is-active")
    assert has_element?(view, "#audio-bpm-112.is-active")

    view |> element("#audio-profile-free_tempo") |> render_click()
    assert %{profile: :free_tempo} = SimulatedSource.snapshot()
    assert has_element?(view, "#audio-profile-free_tempo.is-active")
    refute has_element?(view, "#audio-profile-steady.is-active")

    view |> element("#audio-profile-down") |> render_click()
    assert %{profile: :down} = SimulatedSource.snapshot()

    view |> element("#audio-bpm-150") |> render_click()
    assert %{bpm: 150} = SimulatedSource.snapshot()
    assert has_element?(view, "#audio-bpm-150.is-active")

    # Values the page never offers are ignored.
    render_hook(view, "audio_profile", %{"profile" => "disco"})
    render_hook(view, "audio_bpm", %{"bpm" => "9000"})
    assert %{profile: :down, bpm: 150} = SimulatedSource.snapshot()

    view |> element("button", "Reset everything") |> render_click()
    assert %{profile: :steady, bpm: 112, index: 0} = SimulatedSource.snapshot()
    assert has_element?(view, "#audio-profile-steady.is-active")
  end

  test "edge-case presets and preview sizes", %{conn: conn} do
    {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)
    view |> element("button", "Start session") |> render_click()
    view |> element("button[phx-value-key=emoji]") |> render_click()
    Server.sync()
    assert %{title: "Rocket Summer 🚀☀️🌈"} = Server.get_state()

    view |> element("button", "1024x600") |> render_click()
    assert has_element?(view, "#kiosk-preview[style*='width:1024px']")
  end

  test "reset clears everything", %{conn: conn} do
    {:ok, view, _} = live_isolated(conn, JukeboxWeb.SimulatorLive)
    view |> element("button", "Start session") |> render_click()
    view |> element("button", "Reset everything") |> render_click()
    Server.sync()
    assert %{session_status: :inactive, title: nil} = Server.get_state()
  end
end
