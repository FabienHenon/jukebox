defmodule Jukebox.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JukeboxWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:jukebox, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Jukebox.PubSub},
      # Bounded in-memory artwork cache served at /artwork/:id.
      Jukebox.Artwork.Store,
      # Single owner of the playback state; started before the endpoint so
      # every LiveView mount can read it, and outside the integrations
      # supervisor so an adapter crash never discards the last known track.
      Jukebox.Playback.Server,
      JukeboxWeb.Endpoint,
      # External integrations (metadata source, remote control, physical
      # input) start last: a missing broker or Shairport Sync never delays or
      # blocks the kiosk screen.
      Jukebox.Integrations
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Jukebox.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    JukeboxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
