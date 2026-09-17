# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :jukebox,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :jukebox, JukeboxWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: JukeboxWeb.ErrorHTML, json: JukeboxWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Jukebox.PubSub,
  live_view: [signing_salt: "/S/v4bJ7"]

# ---------------------------------------------------------------------------
# Jukebox application settings
#
# Adapters are selected per environment (see dev.exs / test.exs / prod.exs) and
# can be overridden at runtime for releases in runtime.exs. Each adapter entry
# is a `{module, options}` tuple.
# ---------------------------------------------------------------------------

# Playback state owner. `idle_timeout_ms` is the grace period between the end
# of an AirPlay session and the return to the idle screen.
config :jukebox, Jukebox.Playback, idle_timeout_ms: 5_000

# Default adapters: demo everywhere, replaced by Shairport adapters in prod.
config :jukebox, :metadata_source, {Jukebox.MetadataSources.Demo, []}
config :jukebox, :remote_control, {Jukebox.RemoteControls.Demo, []}
config :jukebox, :input, {Jukebox.Inputs.Noop, []}

# In-memory artwork cache served at /artwork/:id.
config :jukebox, Jukebox.Artwork.Store, max_bytes: 2_000_000, max_entries: 3

# Shairport Sync MQTT integration (used by the production adapters).
config :jukebox, Jukebox.Shairport,
  host: "127.0.0.1",
  port: 1883,
  topic: "jukebox/shairport",
  client_id: "jukebox-display",
  username: nil,
  password: nil,
  remote_control_enabled: true

# Development-only conveniences. Both stay off outside dev/test.
config :jukebox, dev_keys: false, hide_cursor: false

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  jukebox: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  jukebox: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
