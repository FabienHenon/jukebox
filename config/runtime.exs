import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/jukebox start
#
# The systemd unit in ops/jukebox.service.example sets this variable.
if System.get_env("PHX_SERVER") do
  config :jukebox, JukeboxWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Small helpers to read and validate the jukebox environment. They fail fast
  # with a readable message for genuinely invalid local configuration, but they
  # never require MQTT or Shairport Sync to be reachable at boot.
  env = fn name, default -> System.get_env(name, default) end

  int_env = fn name, default, min, max ->
    raw = env.(name, Integer.to_string(default))

    case Integer.parse(raw) do
      {value, ""} when value >= min and value <= max ->
        value

      _ ->
        raise "environment variable #{name} must be an integer between #{min} and #{max}, got: #{inspect(raw)}"
    end
  end

  float_env = fn name, default, min, max ->
    raw = env.(name, Float.to_string(default))

    case Float.parse(raw) do
      {value, ""} when value >= min and value <= max ->
        value

      _ ->
        raise "environment variable #{name} must be a number between #{min} and #{max}, got: #{inspect(raw)}"
    end
  end

  bool_env = fn name, default ->
    case String.downcase(env.(name, default)) do
      v when v in ["1", "true", "yes", "on"] -> true
      v when v in ["0", "false", "no", "off"] -> false
      other -> raise "environment variable #{name} must be true or false, got: #{inspect(other)}"
    end
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # The kiosk is a local appliance: bind to loopback by default. Set
  # JUKEBOX_BIND=0.0.0.0 to allow LAN access for diagnostics.
  bind_ip =
    case env.("JUKEBOX_BIND", "127.0.0.1") |> String.to_charlist() |> :inet.parse_address() do
      {:ok, ip} -> ip
      {:error, _} -> raise "environment variable JUKEBOX_BIND must be an IP address"
    end

  host = env.("PHX_HOST", "localhost")
  port = int_env.("PORT", 4000, 1, 65_535)

  config :jukebox, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :jukebox, JukeboxWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: bind_ip, port: port],
    check_origin: false,
    secret_key_base: secret_key_base

  # ---------------------------------------------------------------------
  # Jukebox integration settings
  # ---------------------------------------------------------------------
  metadata_adapter = env.("JUKEBOX_METADATA_ADAPTER", "mqtt")

  unless metadata_adapter in ["mqtt", "demo"] do
    raise "environment variable JUKEBOX_METADATA_ADAPTER must be \"mqtt\" or \"demo\", got: #{inspect(metadata_adapter)}"
  end

  remote_enabled = bool_env.("JUKEBOX_REMOTE_CONTROL_ENABLED", "true")

  config :jukebox, Jukebox.Playback,
    idle_timeout_ms: int_env.("JUKEBOX_IDLE_TIMEOUT_MS", 5_000, 0, 600_000),
    coalesce_ms: int_env.("JUKEBOX_COALESCE_MS", 150, 0, 2_000)

  config :jukebox, Jukebox.Shairport,
    host: env.("JUKEBOX_MQTT_HOST", "127.0.0.1"),
    port: int_env.("JUKEBOX_MQTT_PORT", 1883, 1, 65_535),
    topic: env.("JUKEBOX_MQTT_TOPIC", "jukebox/shairport"),
    client_id: env.("JUKEBOX_MQTT_CLIENT_ID", "jukebox-display"),
    username: System.get_env("JUKEBOX_MQTT_USERNAME"),
    password: System.get_env("JUKEBOX_MQTT_PASSWORD"),
    remote_control_enabled: remote_enabled

  animation_style = env.("JUKEBOX_ANIMATION_STYLE", "chase")

  unless animation_style in ["calm", "waves", "chase", "party"] do
    raise "environment variable JUKEBOX_ANIMATION_STYLE must be \"calm\", \"waves\", \"chase\" or \"party\", got: #{inspect(animation_style)}"
  end

  config :jukebox, Jukebox.Animation,
    default_style: String.to_atom(animation_style),
    bpm: int_env.("JUKEBOX_ANIMATION_BPM", 120, 40, 240),
    # The last chosen style is saved here. The systemd unit creates the
    # directory (StateDirectory=jukebox); if it cannot be written the style is
    # simply not kept across restarts.
    state_file: Path.join(env.("JUKEBOX_STATE_DIR", "/var/lib/jukebox"), "animation_style")

  # Audio-reactive animation (docs/audio-reactive-setup.md). Off unless asked
  # for, and never a reason not to boot: the native source keeps retrying on
  # its own when its socket cannot be created or the analyser is not running.
  audio_enabled = bool_env.("AUDIO_REACTIVE_ENABLED", "false")
  audio_source = env.("AUDIO_REACTIVE_SOURCE", "native")

  unless audio_source in ["disabled", "simulated", "native"] do
    raise "environment variable AUDIO_REACTIVE_SOURCE must be \"disabled\", \"simulated\" or \"native\", got: #{inspect(audio_source)}"
  end

  config :jukebox, Jukebox.AudioAnalysis,
    publish_rate: int_env.("AUDIO_ANALYSIS_PUBLISH_RATE", 20, 1, 20),
    visual_delay_ms: int_env.("AUDIO_VISUAL_DELAY_MS", 120, 0, 1_000),
    beat_confidence_threshold: float_env.("AUDIO_BEAT_CONFIDENCE_THRESHOLD", 0.45, 0.0, 1.0)

  audio_socket = env.("AUDIO_ANALYSIS_SOCKET", "/run/jukebox/audio-analysis.sock")

  case {audio_enabled, audio_source} do
    {true, "native"} ->
      config :jukebox, :audio_source, {Jukebox.AudioAnalysis.NativeSource, socket: audio_socket}

    {true, "simulated"} ->
      config :jukebox, :audio_source, {Jukebox.AudioAnalysis.SimulatedSource, []}

    _disabled ->
      config :jukebox, :audio_source, {Jukebox.AudioAnalysis.DisabledSource, []}
  end

  case metadata_adapter do
    "mqtt" ->
      config :jukebox, :metadata_source, {Jukebox.MetadataSources.ShairportMqtt, []}
      config :jukebox, :remote_control, {Jukebox.RemoteControls.Shairport, []}

    "demo" ->
      config :jukebox, :metadata_source, {Jukebox.MetadataSources.Demo, tick_ms: 1_000}
      config :jukebox, :remote_control, {Jukebox.RemoteControls.Demo, []}
  end

  # The semantic test input is never used in production.
  config :jukebox, :input, {Jukebox.Inputs.Noop, []}

  # Physical controls (docs/physical-controls.md). The variables are only
  # collected here, as strings. Jukebox.Hardware.Config parses them when the
  # hardware supervisor starts and, unlike everything above, never raises: a
  # wrong value disables the buttons, the brightness or the strip control with
  # a logged explanation, and the display and the music carry on.
  hardware_prefixes = [
    "JUKEBOX_BUTTONS_",
    "JUKEBOX_BUTTON_",
    "JUKEBOX_BRIGHTNESS_",
    "JUKEBOX_XRANDR_",
    "JUKEBOX_X11_",
    # Obsolete (the former DDC backend): only read to say that it is ignored.
    "JUKEBOX_DDC_",
    "JUKEBOX_POWER_",
    "JUKEBOX_STRIP_",
    "JUKEBOX_WLED_"
  ]

  hardware_env =
    for {name, value} <- System.get_env(),
        String.starts_with?(name, hardware_prefixes),
        into: %{},
        do: {name, value}

  config :jukebox, Jukebox.Hardware,
    env: hardware_env,
    power: :controller,
    allow_simulated: false
end
