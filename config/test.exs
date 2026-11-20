import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :jukebox, JukeboxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "JIr329R7XbzLV7+3RhZii0Ar38ma4uPj4biqvfTjKDn/4vJrOqTd3cbB37Jvwdjd",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Deterministic fake adapters: no timers unless a test controls them, no
# broker, no filesystem. The simulator route stays unrouted (dev_routes is
# not set), which mirrors production.
config :jukebox, dev_keys: true, simulator: true

config :jukebox, Jukebox.Playback, idle_timeout_ms: 60_000, coalesce_ms: 0
config :jukebox, :metadata_source, {Jukebox.MetadataSources.Demo, tick_ms: nil}
config :jukebox, :remote_control, {Jukebox.RemoteControls.Demo, []}
config :jukebox, :input, {Jukebox.Inputs.Fake, debounce_ms: 80}

# Physical controls: everything simulated, as in development, so the whole
# path from a raw key event to a command runs in tests without any hardware.
# The key codes are arbitrary.
config :jukebox, Jukebox.Hardware,
  power: :simulated,
  allow_simulated: true,
  env: %{
    "JUKEBOX_BUTTONS_ENABLED" => "true",
    "JUKEBOX_BUTTONS_SOURCE" => "simulated",
    "JUKEBOX_BUTTON_PREVIOUS" => "704",
    "JUKEBOX_BUTTON_PLAY_PAUSE" => "705",
    "JUKEBOX_BUTTON_NEXT" => "706",
    "JUKEBOX_BUTTON_DISCO_TOGGLE" => "707",
    "JUKEBOX_BUTTON_STRIP_TOGGLE" => "708",
    "JUKEBOX_BUTTON_ANIMATION_NEXT" => "709",
    "JUKEBOX_BUTTON_BRIGHTNESS_DOWN" => "710",
    "JUKEBOX_BUTTON_BRIGHTNESS_UP" => "711",
    "JUKEBOX_BRIGHTNESS_BACKEND" => "simulated"
  }
