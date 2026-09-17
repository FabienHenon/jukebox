defmodule Jukebox.Shairport.Decoder do
  @moduledoc """
  Pure translation of Shairport Sync MQTT messages into normalised playback
  events. It never touches processes, so it is fully testable without a
  broker.

  Two topic layouts are understood (both may be enabled at once; the reducer
  de-duplicates identical information):

    * parsed topics (`mqtt.publish_parsed = "yes"`): `title`, `artist`,
      `album`, `genre`, `client_name`, `client_model`, `volume`, `progress`,
      `play_start`, `play_end`, `play_flush`, `play_resume`, `active_start`,
      `active_end`, `cover` (`mqtt.publish_cover = "yes"`)
    * raw topics (`mqtt.publish_raw = "yes"`): `core/<code>` and
      `ssnc/<code>` where `<code>` is a four-character DMAP/Shairport code
      (`minm`, `asar`, `asal`, `asgn`, `astm`, `mper`, `pbeg`, `prgr`, ...)

  Binary artwork is returned as `{:artwork_binary, bytes}` for the handler
  to validate and store; everything else is a `Jukebox.Playback.Event`.
  Malformed payloads never raise: they are dropped or reduced to whatever
  part is usable.
  """

  @rtp_rate 44_100
  @uint32 4_294_967_296

  @ignored_parsed ~w(client_ip server_ip client_device_id client_mac_address format remote songalbum songartist)

  @type event :: Jukebox.Playback.Event.t() | {:artwork_binary, binary()}

  @doc "Decodes one message. Returns `{:ok, events}` or `:unknown` for unrecognised topics."
  @spec decode([String.t()], binary()) :: {:ok, [event()]} | :unknown
  def decode(topic_levels, payload)

  # -- session and playback markers ---------------------------------------------

  def decode(["active_start"], _), do: {:ok, [{:session_started, %{}}]}
  def decode(["active_end"], _), do: {:ok, [{:session_ended, %{reason: :sender_disconnected}}]}
  def decode(["play_start"], _), do: {:ok, [{:playback_changed, :playing}]}
  def decode(["play_resume"], _), do: {:ok, [{:playback_changed, :playing}]}
  def decode(["play_flush"], _), do: {:ok, [{:playback_changed, :paused}]}
  def decode(["play_end"], _), do: {:ok, [{:playback_changed, :stopped}]}

  # -- text metadata ---------------------------------------------------------------

  def decode(["title"], payload), do: text(:title, payload)
  def decode(["artist"], payload), do: text(:artist, payload)
  def decode(["album"], payload), do: text(:album, payload)
  def decode(["genre"], payload), do: text(:genre, payload)
  def decode(["client_name"], payload), do: {:ok, [{:source_changed, %{source_name: payload}}]}
  def decode(["client_model"], payload), do: {:ok, [{:source_changed, %{source_model: payload}}]}

  # -- numeric and binary payloads ------------------------------------------------

  def decode(["volume"], payload), do: {:ok, volume(payload)}
  def decode(["progress"], payload), do: {:ok, progress(payload)}
  def decode(["cover"], payload), do: {:ok, artwork(payload)}

  def decode([parsed], _payload) when parsed in @ignored_parsed, do: {:ok, []}

  # -- raw DMAP ("core") codes --------------------------------------------------------

  def decode(["core", "minm"], payload), do: text(:title, payload)
  def decode(["core", "asar"], payload), do: text(:artist, payload)
  def decode(["core", "asal"], payload), do: text(:album, payload)
  def decode(["core", "asgn"], payload), do: text(:genre, payload)

  def decode(["core", "astm"], payload) do
    case uint32(payload) do
      {:ok, ms} when ms > 0 -> {:ok, [{:progress_changed, %{duration_ms: ms}}]}
      _ -> {:ok, []}
    end
  end

  def decode(["core", "mper"], payload) do
    case persistent_id(payload) do
      nil -> {:ok, []}
      id -> {:ok, [{:metadata_changed, %{track_id: id}}]}
    end
  end

  def decode(["core", _other], _payload), do: {:ok, []}

  # -- raw Shairport ("ssnc") codes ------------------------------------------------

  def decode(["ssnc", "pbeg"], _), do: {:ok, [{:playback_changed, :playing}]}
  def decode(["ssnc", "prsm"], _), do: {:ok, [{:playback_changed, :playing}]}
  def decode(["ssnc", "pfls"], _), do: {:ok, [{:playback_changed, :paused}]}
  def decode(["ssnc", "pend"], _), do: {:ok, [{:playback_changed, :stopped}]}
  def decode(["ssnc", "abeg"], _), do: {:ok, [{:session_started, %{}}]}
  def decode(["ssnc", "aend"], _), do: {:ok, [{:session_ended, %{reason: :sender_disconnected}}]}
  def decode(["ssnc", "snam"], payload), do: {:ok, [{:source_changed, %{source_name: payload}}]}
  def decode(["ssnc", "cmod"], payload), do: {:ok, [{:source_changed, %{source_model: payload}}]}
  def decode(["ssnc", "pvol"], payload), do: {:ok, volume(payload)}
  def decode(["ssnc", "prgr"], payload), do: {:ok, progress(payload)}
  def decode(["ssnc", "PICT"], payload), do: {:ok, artwork(payload)}

  def decode(["ssnc", code], _) when code in ["daid", "acre"],
    do: {:ok, [{:remote_control_changed, :available}]}

  def decode(["ssnc", _other], _payload), do: {:ok, []}

  def decode(_topic, _payload), do: :unknown

  # -- helpers -----------------------------------------------------------------------

  defp text(field, payload) when is_binary(payload),
    do: {:ok, [{:metadata_changed, %{field => payload}}]}

  defp text(_field, _payload), do: {:ok, []}

  defp artwork(payload) when is_binary(payload) and byte_size(payload) > 0,
    do: [{:artwork_binary, payload}]

  defp artwork(_), do: [{:artwork_changed, nil}]

  # "airplay_volume,volume,lowest_volume,highest_volume" e.g. "-15.00,-25.50,-96.30,0.00".
  # AirPlay volume ranges from -30 (silent) to 0 (max); -144 means muted.
  defp volume(payload) when is_binary(payload) do
    with [airplay | _] <- String.split(payload, ","),
         {value, _} <- Float.parse(String.trim(airplay)) do
      percent =
        cond do
          value <= -144.0 ->
            0.0

          true ->
            value |> max(-30.0) |> min(0.0) |> Kernel.+(30.0) |> Kernel./(30.0) |> Kernel.*(100.0)
        end

      [{:volume_changed, Float.round(percent, 1)}]
    else
      _ -> []
    end
  end

  defp volume(_), do: []

  # "start/current/end" RTP timestamps at 44.1 kHz, e.g. "1093250/1112185/16097000".
  defp progress(payload) when is_binary(payload) do
    with [start, current, finish] <- String.split(String.trim(payload), "/"),
         {:ok, start} <- uint32(start),
         {:ok, current} <- uint32(current),
         {:ok, finish} <- uint32(finish) do
      position_ms = frames_to_ms(Integer.mod(current - start, @uint32))
      duration_frames = Integer.mod(finish - start, @uint32)

      attrs =
        if duration_frames > 0,
          do: %{position_ms: position_ms, duration_ms: frames_to_ms(duration_frames)},
          else: %{position_ms: position_ms}

      [{:progress_changed, attrs}]
    else
      _ -> []
    end
  end

  defp progress(_), do: []

  defp frames_to_ms(frames), do: div(frames * 1000, @rtp_rate)

  defp uint32(<<n::unsigned-big-32>> = binary) do
    if ascii_digits?(binary), do: uint32_text(binary), else: {:ok, n}
  end

  defp uint32(binary) when is_binary(binary), do: uint32_text(binary)
  defp uint32(_), do: :error

  defp ascii_digits?(binary), do: binary =~ ~r/^\d+$/

  defp uint32_text(binary) do
    case Integer.parse(String.trim(binary)) do
      {n, ""} when n >= 0 and n < @uint32 -> {:ok, n}
      _ -> :error
    end
  end

  defp persistent_id(<<id::unsigned-big-64>>), do: Integer.to_string(id, 16)

  defp persistent_id(binary) when is_binary(binary) do
    case String.trim(binary) do
      "" -> nil
      id -> if String.valid?(id) and String.length(id) <= 64, do: id, else: nil
    end
  end

  defp persistent_id(_), do: nil
end
