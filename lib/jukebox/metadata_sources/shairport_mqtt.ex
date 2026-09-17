defmodule Jukebox.MetadataSources.ShairportMqtt do
  @moduledoc """
  Production metadata source: Shairport Sync publishing to a local MQTT
  broker (Mosquitto on the Raspberry Pi).

  The child is a `Tortoise311.Connection` whose handler is
  `Jukebox.Shairport.MqttHandler`. The connection process itself owns the
  broker reconnection logic with bounded exponential backoff, so a broker or
  Shairport Sync that is not running yet never prevents the application from
  booting and never crash-loops the supervision tree.

  The same connection (identified by the configured `client_id`) is used by
  `Jukebox.RemoteControls.Shairport` to publish remote commands.
  """

  @behaviour Jukebox.MetadataSource

  alias Jukebox.Shairport

  @impl true
  def child_spec(opts) do
    config = Shairport.config(opts)

    handler_opts = [
      topic: config.topic,
      playback: Keyword.get(opts, :playback, Jukebox.Playback.Server),
      store: Keyword.get(opts, :store, Jukebox.Artwork.Store)
    ]

    Tortoise311.Connection.child_spec(
      name: __MODULE__,
      restart: :permanent,
      client_id: config.client_id,
      server: {Tortoise311.Transport.Tcp, host: config.host, port: config.port},
      user_name: config.username,
      password: config.password,
      keep_alive: 30,
      subscriptions: [{Shairport.subscription_filter(config), 0}],
      handler: {Shairport.MqttHandler, handler_opts},
      backoff: [min_interval: 500, max_interval: 30_000],
      first_connect_delay: 250
    )
  end
end
