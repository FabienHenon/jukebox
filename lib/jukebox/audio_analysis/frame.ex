defmodule Jukebox.AudioAnalysis.Frame do
  @moduledoc """
  One moment of analysed audio, already normalised for display.

    * `level` - loudness, `0.0..1.0`
    * `bass` - low-frequency energy, `0.0..1.0`
    * `onset` - strength of a musical attack in this frame, `0.0..1.0`
    * `beat_id` - counter that goes up by one on every detected beat; a beat
      is a *change* of this value, never a flag that stays true
    * `bpm` - estimated tempo, or `nil` while there is no stable estimate
    * `confidence` - how far the beat tracking can be trusted, `0.0..1.0`

  `decode/1` and `new/1` are the only way in for data coming from outside the
  application: they reject anything malformed and clamp the rest, so the rest
  of the system never has to check a frame again.
  """

  @unit_fields [:level, :bass, :onset, :confidence]
  # The native protocol sends one small JSON object per datagram.
  @max_payload_bytes 512
  @max_beat_id 0xFFFFFFFFFFFF
  @bpm_range 30..300

  @enforce_keys [:level, :bass, :onset, :beat_id, :bpm, :confidence]
  defstruct [:level, :bass, :onset, :beat_id, :bpm, :confidence]

  @type t :: %__MODULE__{
          level: float(),
          bass: float(),
          onset: float(),
          beat_id: non_neg_integer(),
          bpm: float() | nil,
          confidence: float()
        }

  @type reason ::
          :too_large
          | :invalid_json
          | :not_an_object
          | {:missing, atom()}
          | {:invalid, atom()}

  @doc "Decodes one JSON payload from the native analyser."
  @spec decode(term()) :: {:ok, t()} | {:error, reason()}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    # Jason refuses NaN, Infinity and numbers too large for a float, so a
    # decoded number is always finite.
    case Jason.decode(payload) do
      {:ok, map} when is_map(map) -> new(map)
      {:ok, _other} -> {:error, :not_an_object}
      {:error, _error} -> {:error, :invalid_json}
    end
  end

  def decode(payload) when is_binary(payload), do: {:error, :too_large}
  def decode(_other), do: {:error, :invalid_json}

  @doc """
  Builds a frame from a map with string or atom keys. Every field is
  required; `bpm` may be `nil`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, reason()}
  def new(map) when is_map(map) do
    with {:ok, [level, bass, onset, confidence]} <- units(map),
         {:ok, beat_id} <- field(map, :beat_id, &beat_id/1),
         {:ok, bpm} <- field(map, :bpm, &bpm/1) do
      {:ok,
       %__MODULE__{
         level: level,
         bass: bass,
         onset: onset,
         beat_id: beat_id,
         bpm: bpm,
         confidence: confidence
       }}
    end
  end

  def new(_other), do: {:error, :not_an_object}

  @doc "The frame as the compact map sent to the browser."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = frame) do
    %{
      level: Float.round(frame.level, 3),
      bass: Float.round(frame.bass, 3),
      onset: Float.round(frame.onset, 3),
      beat_id: frame.beat_id,
      bpm: frame.bpm && Float.round(frame.bpm, 1),
      confidence: Float.round(frame.confidence, 3)
    }
  end

  defp units(map) do
    Enum.reduce_while(@unit_fields, {:ok, []}, fn name, {:ok, values} ->
      case field(map, name, &unit/1) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, [confidence, onset, bass, level]} -> {:ok, [level, bass, onset, confidence]}
      error -> error
    end
  end

  defp field(map, name, cast) do
    case fetch(map, name) do
      {:ok, value} ->
        case cast.(value) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, {:invalid, name}}
        end

      :error ->
        {:error, {:missing, name}}
    end
  end

  defp fetch(map, name) do
    with :error <- Map.fetch(map, name), do: Map.fetch(map, Atom.to_string(name))
  end

  defp unit(value) when is_number(value),
    do: {:ok, value |> max(0.0) |> min(1.0) |> Kernel.*(1.0)}

  defp unit(_other), do: :error

  defp beat_id(value) when is_integer(value) and value >= 0 and value <= @max_beat_id,
    do: {:ok, value}

  defp beat_id(_other), do: :error

  # No estimate yet: null or zero. An estimate outside the range any music
  # is played at is treated the same way rather than shown.
  defp bpm(nil), do: {:ok, nil}

  defp bpm(value) when is_number(value) and value >= 0 do
    if value >= @bpm_range.first and value <= @bpm_range.last,
      do: {:ok, value * 1.0},
      else: {:ok, nil}
  end

  defp bpm(_other), do: :error
end
