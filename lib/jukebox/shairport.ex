defmodule Jukebox.Shairport do
  @moduledoc """
  Shared configuration and vocabulary for the Shairport Sync MQTT integration.

  This is the single place that knows the MQTT topic layout and the DACP
  command strings accepted on the `<topic>/remote` topic. Both adapters
  (`Jukebox.MetadataSources.ShairportMqtt` and
  `Jukebox.RemoteControls.Shairport`) read from here, so a vocabulary change
  between Shairport Sync releases is a one-line edit.

  Tested against the Shairport Sync 4.x MQTT backend (`--with-mqtt-client`)
  with `mqtt.publish_parsed = "yes"`, `mqtt.publish_cover = "yes"`,
  `mqtt.publish_raw = "yes"` (optional, adds duration and persistent ids) and
  `mqtt.enable_remote = "yes"`. See `ops/shairport-sync.conf.example`.
  """

  @remote_commands %{
    previous_track: "previtem",
    toggle_playback: "playpause",
    next_track: "nextitem",
    volume_up: "volumeup",
    volume_down: "volumedown"
  }

  @v1_commands [:previous_track, :toggle_playback, :next_track]

  @type config :: %{
          host: String.t(),
          port: pos_integer(),
          topic: String.t(),
          client_id: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          remote_control_enabled: boolean()
        }

  @doc "Resolved configuration (application env merged with overrides)."
  @spec config(keyword()) :: config()
  def config(overrides \\ []) do
    merged = Keyword.merge(Application.get_env(:jukebox, __MODULE__, []), overrides)

    %{
      host: Keyword.get(merged, :host, "127.0.0.1"),
      port: Keyword.get(merged, :port, 1883),
      topic: merged |> Keyword.get(:topic, "jukebox/shairport") |> String.trim_trailing("/"),
      client_id: Keyword.get(merged, :client_id, "jukebox-display"),
      username: Keyword.get(merged, :username),
      password: Keyword.get(merged, :password),
      remote_control_enabled: Keyword.get(merged, :remote_control_enabled, true)
    }
  end

  @doc "MQTT topic filter covering every Shairport publication."
  def subscription_filter(%{topic: topic}), do: topic <> "/#"

  @doc "Topic Shairport Sync listens on for remote-control commands."
  def remote_topic(%{topic: topic}), do: topic <> "/remote"

  @doc "The DACP payload for a semantic command."
  @spec remote_command(atom()) :: {:ok, String.t()} | :error
  def remote_command(command), do: Map.fetch(@remote_commands, command)

  @doc "Commands relayed in version one."
  def v1_commands, do: @v1_commands
end
