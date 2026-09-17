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
    idle_timeout_ms: int_env.("JUKEBOX_IDLE_TIMEOUT_MS", 5_000, 0, 600_000)

  config :jukebox, Jukebox.Shairport,
    host: env.("JUKEBOX_MQTT_HOST", "127.0.0.1"),
    port: int_env.("JUKEBOX_MQTT_PORT", 1883, 1, 65_535),
    topic: env.("JUKEBOX_MQTT_TOPIC", "jukebox/shairport"),
    client_id: env.("JUKEBOX_MQTT_CLIENT_ID", "jukebox-display"),
    username: System.get_env("JUKEBOX_MQTT_USERNAME"),
    password: System.get_env("JUKEBOX_MQTT_PASSWORD"),
    remote_control_enabled: remote_enabled

  case metadata_adapter do
    "mqtt" ->
      config :jukebox, :metadata_source, {Jukebox.MetadataSources.ShairportMqtt, []}
      config :jukebox, :remote_control, {Jukebox.RemoteControls.Shairport, []}

    "demo" ->
      config :jukebox, :metadata_source, {Jukebox.MetadataSources.Demo, tick_ms: 1_000}
      config :jukebox, :remote_control, {Jukebox.RemoteControls.Demo, []}
  end

  # Physical buttons: the no-op adapter until a GPIO implementation is wired
  # in. See docs/raspberry-pi.md for the expected pin mapping and boundary.
  config :jukebox, :input, {Jukebox.Inputs.Noop, []}
end
