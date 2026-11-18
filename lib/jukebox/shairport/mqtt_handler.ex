defmodule Jukebox.Shairport.MqttHandler do
  @moduledoc """
  `Tortoise311.Handler` running inside the MQTT connection process.

  It strips the configured topic prefix, hands the rest to
  `Jukebox.Shairport.Decoder`, stores binary artwork in
  `Jukebox.Artwork.Store` and forwards the resulting normalised events to
  `Jukebox.Playback.Server`. Connection status changes become
  `metadata_connection_changed` events so the kiosk can show a discreet
  "Reconnecting…" hint.

  A track change reaches MQTT as one message per field. Shairport Sync
  brackets each metadata bundle with start/end markers, so the fields are
  collected between the markers and forwarded as a single `metadata_changed`
  event: the playback state then never sees a half-described track (a new
  track id without its title, a title without its artist). Without the
  markers (`mqtt.publish_raw` off) fields are forwarded one by one.

  Everything is wrapped so a malformed message can never take the
  connection down.
  """

  use Tortoise311.Handler

  require Logger

  alias Jukebox.Artwork
  alias Jukebox.Playback
  alias Jukebox.Shairport.Decoder

  @impl true
  def init(opts) do
    {:ok,
     %{
       prefix: opts |> Keyword.fetch!(:topic) |> String.split("/", trim: true),
       playback: Keyword.get(opts, :playback, Playback.Server),
       store: Keyword.get(opts, :store, Artwork.Store),
       # nil outside a metadata bundle, a map of collected fields inside one
       bundle: nil
     }}
  end

  @impl true
  def connection(:up, state) do
    Logger.info("[shairport] connected to MQTT broker")
    notify(state, {:metadata_connection_changed, :connected})
    {:ok, state}
  end

  def connection(:down, state) do
    Logger.warning("[shairport] MQTT connection down, reconnecting with backoff")
    notify(state, {:metadata_connection_changed, :disconnected})
    {:ok, state}
  end

  @impl true
  def subscription(:up, topic, state) do
    Logger.info("[shairport] subscribed to #{topic}")
    {:ok, state}
  end

  def subscription({:error, reason}, topic, state) do
    Logger.error("[shairport] subscription to #{topic} rejected: #{inspect(reason)}")
    {:ok, state}
  end

  def subscription(_status, _topic, state), do: {:ok, state}

  @impl true
  def handle_message(levels, payload, state) do
    {:ok, handle_levels(levels, payload, state)}
  rescue
    exception ->
      Logger.error("[shairport] failed to handle message: #{Exception.message(exception)}")
      {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    notify(state, {:metadata_connection_changed, :disconnected})
    :ok
  end

  # -- internals ---------------------------------------------------------------

  defp handle_levels(levels, payload, state) do
    case strip_prefix(levels, state.prefix) do
      {:ok, rest} ->
        case Decoder.decode(rest, payload) do
          {:ok, events} ->
            Enum.reduce(events, state, &deliver/2)

          :unknown ->
            Logger.debug("[shairport] ignoring unknown topic #{Enum.join(rest, "/")}")
            state
        end

      :error ->
        Logger.debug("[shairport] ignoring message outside configured topic")
        state
    end
  end

  # A new bundle starts: anything still collected (a missing end marker) goes
  # out first so it is never lost.
  defp deliver(:bundle_start, state), do: %{flush_bundle(state) | bundle: %{}}
  defp deliver(:bundle_end, state), do: flush_bundle(state)

  defp deliver({:metadata_changed, attrs}, %{bundle: bundle} = state) when is_map(bundle) do
    %{state | bundle: Map.merge(bundle, attrs)}
  end

  defp deliver({:artwork_binary, binary}, state) do
    case Artwork.Store.put(state.store, binary) do
      {:ok, artwork} ->
        notify(state, {:artwork_changed, artwork})

      {:error, reason} ->
        Logger.warning("[shairport] rejected artwork payload (#{reason}), using fallback")
        notify(state, {:artwork_changed, nil})
    end

    state
  end

  defp deliver(event, state) do
    notify(state, event)
    state
  end

  defp flush_bundle(%{bundle: bundle} = state) when is_map(bundle) and map_size(bundle) > 0 do
    notify(state, {:metadata_changed, bundle})
    %{state | bundle: nil}
  end

  defp flush_bundle(state), do: %{state | bundle: nil}

  defp notify(state, event) do
    Playback.Server.notify(state.playback, event)
  catch
    :exit, _reason -> :ok
  end

  defp strip_prefix(levels, []), do: {:ok, levels}
  defp strip_prefix([level | rest], [level | prefix]), do: strip_prefix(rest, prefix)
  defp strip_prefix(_levels, _prefix), do: :error
end
