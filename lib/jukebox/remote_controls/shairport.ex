defmodule Jukebox.RemoteControls.Shairport do
  @moduledoc """
  Remote control through Shairport Sync's MQTT remote topic.

  With `mqtt.enable_remote = "yes"`, Shairport Sync subscribes to
  `<topic>/remote` and relays DACP commands (`previtem`, `playpause`,
  `nextitem`, ...) to the AirPlay sender. Stable remote control targets
  Classic AirPlay senders; AirPlay 2 support may be experimental depending on
  the Shairport Sync build. The kiosk keeps working either way: a command
  that cannot be delivered is reported as a safe error and shown as a subtle
  "Control unavailable" hint.

  Commands are published on the connection opened by
  `Jukebox.MetadataSources.ShairportMqtt` (same client id). When the broker
  is unreachable the publish fails quickly instead of blocking the caller.
  """

  @behaviour Jukebox.RemoteControl

  require Logger

  alias Jukebox.Shairport

  @publish_timeout_ms 1_000

  @impl true
  def capabilities do
    if Shairport.config().remote_control_enabled,
      do: MapSet.new(Shairport.v1_commands()),
      else: MapSet.new()
  end

  @impl true
  def previous_track, do: send_command(:previous_track)

  @impl true
  def toggle_playback, do: send_command(:toggle_playback)

  @impl true
  def next_track, do: send_command(:next_track)

  defp send_command(command) do
    config = Shairport.config()

    with true <- config.remote_control_enabled || {:error, :remote_control_disabled},
         {:ok, payload} <- Shairport.remote_command(command) do
      publish(config, payload)
    else
      :error -> {:error, :unsupported_command}
      {:error, _} = error -> error
    end
  end

  defp publish(config, payload) do
    topic = Shairport.remote_topic(config)

    case Tortoise311.publish(config.client_id, topic, payload,
           qos: 0,
           timeout: @publish_timeout_ms
         ) do
      :ok -> :ok
      {:ok, _ref} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:publish_failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:publish_failed, reason}}
  end
end
