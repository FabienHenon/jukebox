defmodule JukeboxWeb.Router do
  use JukeboxWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JukeboxWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The kiosk: a single public LiveView whose appearance follows the playback
  # state. It uses a dedicated root layout (full-viewport appliance display).
  scope "/", JukeboxWeb do
    pipe_through :browser

    live_session :kiosk, root_layout: {JukeboxWeb.Layouts, :kiosk} do
      live "/", JukeboxLive, :index
    end
  end

  # Artwork received from the AirPlay sender, served from the in-memory store.
  scope "/", JukeboxWeb do
    get "/artwork/:id", ArtworkController, :show
  end

  # Development-only routes: LiveDashboard and the jukebox simulator. They are
  # neither compiled nor routed unless `dev_routes` is set (dev only).
  if Application.compile_env(:jukebox, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: JukeboxWeb.Telemetry
      live "/simulator", JukeboxWeb.SimulatorLive, :index
    end
  end
end
