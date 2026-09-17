defmodule JukeboxWeb.SimulatorLiveTest do
  # The simulator is compiled in test (config :jukebox, simulator: true) but,
  # exactly like production, it is not routed, so it is mounted in isolation.
  use JukeboxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
