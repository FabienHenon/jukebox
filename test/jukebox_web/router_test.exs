defmodule JukeboxWeb.RouterTest do
  use JukeboxWeb.ConnCase, async: true

  alias JukeboxWeb.Router

  test "the kiosk and artwork routes exist" do
    assert %{plug: Phoenix.LiveView.Plug, phoenix_live_view: {JukeboxWeb.JukeboxLive, _, _, _}} =
             Phoenix.Router.route_info(Router, "GET", "/", "localhost")

    assert %{plug: JukeboxWeb.ArtworkController} =
             Phoenix.Router.route_info(Router, "GET", "/artwork/abc", "localhost")
  end

  test "the development simulator is not routed when dev_routes is off (test mirrors production)" do
    refute Application.get_env(:jukebox, :dev_routes)
    assert Phoenix.Router.route_info(Router, "GET", "/dev/simulator", "localhost") == :error
    assert Phoenix.Router.route_info(Router, "GET", "/dev/dashboard", "localhost") == :error
  end

  test "requesting the simulator returns 404", %{conn: conn} do
    assert get(conn, "/dev/simulator").status == 404
  end
end
