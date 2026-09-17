defmodule Jukebox.Playback.Text do
  @moduledoc """
  Sanitises untrusted metadata strings before they enter the playback state.

  Every string coming from an AirPlay sender is treated as untrusted input:
  invalid UTF-8 is dropped, control characters become spaces, whitespace is
  collapsed and the result is truncated to a bounded number of graphemes.
  Empty results become `nil` so the UI can simply omit the field.
  """

  @default_max 200

  @doc """
  Cleans a metadata string. Returns `nil` for anything that is not a usable
  non-empty string.
  """
  @spec clean(term(), pos_integer()) :: String.t() | nil
  def clean(value, max_graphemes \\ @default_max)

  def clean(value, max_graphemes) when is_binary(value) do
    value
    |> ensure_utf8()
    |> String.replace(~r/\p{Cc}+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, max_graphemes)
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  def clean(_value, _max_graphemes), do: nil

  defp ensure_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> String.chunk(:valid)
      |> Enum.filter(&String.valid?/1)
      |> Enum.join()
    end
  end
end
