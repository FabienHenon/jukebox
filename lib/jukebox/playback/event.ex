defmodule Jukebox.Playback.Event do
  @moduledoc """
  The normalised event vocabulary understood by `Jukebox.Playback.Server`.

  Metadata-source adapters translate their own protocol (Shairport Sync MQTT
  topics, demo simulator actions, ...) into these tuples. Nothing
  adapter-specific may leak past this boundary.

      {:session_started, %{source_name: "Fabien's iPhone"}}
      {:source_changed, %{source_name: "Fabien's iPhone", source_model: "iPhone14,2"}}
      {:metadata_changed, %{title: "Instant Crush", artist: "Daft Punk"}}
      {:track_changed, %{track_id: "42", title: "...", duration_ms: 337_000}}
      {:artwork_changed, %Jukebox.Playback.Artwork{}}
      {:artwork_changed, %Jukebox.Playback.Artwork{}, track_id: "42"}
      {:progress_changed, %{position_ms: 134_000, duration_ms: 337_000}}
      {:playback_changed, :playing | :paused | :stopped}
      {:volume_changed, 72.0}
      {:remote_control_changed, :available | :unavailable | :unknown}
      {:session_ended, %{reason: :sender_disconnected}}
      {:metadata_connection_changed, :connected | :disconnected}
  """

  @names [
    :session_started,
    :source_changed,
    :metadata_changed,
    :track_changed,
    :artwork_changed,
    :progress_changed,
    :playback_changed,
    :volume_changed,
    :remote_control_changed,
    :session_ended,
    :metadata_connection_changed
  ]

  @type name ::
          :session_started
          | :source_changed
          | :metadata_changed
          | :track_changed
          | :artwork_changed
          | :progress_changed
          | :playback_changed
          | :volume_changed
          | :remote_control_changed
          | :session_ended
          | :metadata_connection_changed

  @type t :: {name(), term()} | {:artwork_changed, term(), keyword()}

  @doc "All event names."
  def names, do: @names

  @doc "True for well-formed events (shape only; values are validated by the reducer)."
  @spec valid?(term()) :: boolean()
  def valid?({name, _payload}) when name in @names, do: true
  def valid?({:artwork_changed, _artwork, opts}) when is_list(opts), do: true
  def valid?(_), do: false
end
