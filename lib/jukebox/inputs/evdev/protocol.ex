defmodule Jukebox.Inputs.Evdev.Protocol do
  @moduledoc """
  The line protocol between `priv/hardware/xinmo_evdev.py` and
  `Jukebox.Inputs.Evdev`: one JSON object per line on the helper's standard
  output.

      {"t":"hello","v":1}
      {"t":"connected","name":"...","vendor":5824,"product":1505,"version":257,
       "phys":"usb-...","path":"/dev/input/by-id/...","real":"/dev/input/event3",
       "keys":[288,289],"held":[],"abs":true}
      {"t":"key","c":288,"v":1,"ms":123456}      v: 1 down, 0 up, 2 repeat
      {"t":"resync","held":[288],"ms":123460}    after SYN_DROPPED
      {"t":"waiting","reason":"enoent"}          device missing, retrying
      {"t":"disconnected","reason":"enodev"}

  `decode/1` turns a line into an event for `Jukebox.Hardware.Buttons`, or
  rejects it. Nothing from the helper is trusted beyond its shape: numbers are
  range-checked, lists are bounded and strings are cut.
  """

  @key_max 0x2FF
  @max_codes 768
  @max_string 120

  @spec decode(binary()) :: {:ok, Jukebox.Hardware.Buttons.event()} | :ignore | {:error, term()}
  def decode(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"t" => type} = message} when is_binary(type) -> event(type, message)
      {:ok, _other} -> {:error, :not_an_event}
      {:error, _error} -> {:error, :invalid_json}
    end
  end

  defp event("key", %{"c" => code, "v" => value, "ms" => ms})
       when is_integer(code) and code >= 0 and code <= @key_max and value in [0, 1, 2] and
              is_integer(ms) and ms >= 0,
       do: {:ok, {:key, code, value, ms}}

  defp event("connected", message) do
    with {:ok, keys} <- codes(message["keys"]),
         {:ok, held} <- codes(message["held"]) do
      {:ok,
       {:connected,
        %{
          name: string(message["name"]),
          vendor: integer(message["vendor"]),
          product: integer(message["product"]),
          version: integer(message["version"]),
          phys: string(message["phys"]),
          path: string(message["path"]),
          real_path: string(message["real"]),
          abs?: message["abs"] == true,
          keys: keys,
          held: held
        }}}
    end
  end

  defp event("resync", %{"held" => held, "ms" => ms}) when is_integer(ms) and ms >= 0 do
    with {:ok, held} <- codes(held), do: {:ok, {:resync, held, ms}}
  end

  defp event("waiting", message), do: {:ok, {:waiting, reason(message)}}
  defp event("disconnected", message), do: {:ok, {:disconnected, reason(message)}}
  defp event("hello", _message), do: :ignore
  defp event(type, _message), do: {:error, {:unexpected, String.slice(type, 0, 20)}}

  defp codes(list) when is_list(list) and length(list) <= @max_codes do
    if Enum.all?(list, &(is_integer(&1) and &1 >= 0 and &1 <= @key_max)),
      do: {:ok, list},
      else: {:error, :invalid_codes}
  end

  defp codes(_other), do: {:error, :invalid_codes}

  defp reason(message), do: string(message["reason"]) || "unknown"

  defp string(value) when is_binary(value), do: String.slice(value, 0, @max_string)
  defp string(_other), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_other), do: nil
end
