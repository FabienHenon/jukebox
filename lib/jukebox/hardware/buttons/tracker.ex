defmodule Jukebox.Hardware.Buttons.Tracker do
  @moduledoc """
  Pure bookkeeping of which keys are held, deciding which key-down events are
  real presses.

  Time is passed in explicitly, in monotonic milliseconds, so the rules can be
  tested without waiting:

    * A key-down is a **press** only when the key was up, and at least
      `debounce_ms` have passed since both its last accepted press and its
      last release. Contact bounce on the way down or on the way up therefore
      gives exactly one press.
    * A key-down for a key already held is a **duplicate** and is ignored: a
      key has to be released before it can be pressed again. This is also what
      keeps a long hold from repeating, and what makes a key held when the
      device connects (or across a standby) harmless until it is let go.
    * A key-up always marks the key as released, however close it is to the
      press. A bounce can be ignored as a press, never leave a key stuck down.
    * A kernel auto-repeat (value 2) changes nothing.
  """

  defstruct debounce_ms: 80, keys: %{}

  @type decision :: :press | :bounce | :duplicate | :release | :repeat
  @type t :: %__MODULE__{debounce_ms: non_neg_integer(), keys: %{integer() => map()}}

  @spec new(non_neg_integer()) :: t()
  def new(debounce_ms \\ 80) when is_integer(debounce_ms) and debounce_ms >= 0 do
    %__MODULE__{debounce_ms: debounce_ms}
  end

  @doc "Applies one key event (`value` 1 down, 0 up, 2 repeat) seen at `ms`."
  @spec key(t(), integer(), 0 | 1 | 2, integer()) :: {decision(), t()}
  def key(%__MODULE__{} = tracker, _code, 2, _ms), do: {:repeat, tracker}

  def key(%__MODULE__{} = tracker, code, 0, ms) do
    {:release, put(tracker, code, %{entry(tracker, code) | down?: false, released_at: ms})}
  end

  def key(%__MODULE__{} = tracker, code, 1, ms) do
    entry = entry(tracker, code)

    cond do
      entry.down? ->
        {:duplicate, tracker}

      recent?(entry.accepted_at, ms, tracker) or recent?(entry.released_at, ms, tracker) ->
        {:bounce, put(tracker, code, %{entry | down?: true})}

      true ->
        {:press, put(tracker, code, %{entry | down?: true, accepted_at: ms})}
    end
  end

  @doc """
  The device (re)connected with `held` keys down. They count as held, so they
  do nothing until released: connecting is never a press.
  """
  @spec connected(t(), [integer()]) :: t()
  def connected(%__MODULE__{} = tracker, held) do
    keys = Map.new(tracker.keys, fn {code, entry} -> {code, %{entry | down?: false}} end)
    Enum.reduce(held, %{tracker | keys: keys}, &hold(&2, &1))
  end

  @doc "The device went away: nothing is known to be held any more."
  @spec disconnected(t()) :: t()
  def disconnected(%__MODULE__{} = tracker), do: connected(tracker, [])

  @doc """
  Events were lost (`SYN_DROPPED`) and `held` is what the device reports now.
  The bookkeeping is brought in line with it without inventing a press: a key
  found down is simply held, a key found up was released at `ms`.
  """
  @spec resync(t(), [integer()], integer()) :: t()
  def resync(%__MODULE__{} = tracker, held, ms) do
    released =
      for {code, %{down?: true}} <- tracker.keys, code not in held, do: code

    tracker =
      Enum.reduce(released, tracker, fn code, tracker -> elem(key(tracker, code, 0, ms), 1) end)

    Enum.reduce(held, tracker, &hold(&2, &1))
  end

  @doc "Codes currently held, sorted."
  @spec held(t()) :: [integer()]
  def held(%__MODULE__{keys: keys}) do
    keys
    |> Enum.filter(fn {_code, entry} -> entry.down? end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp hold(tracker, code), do: put(tracker, code, %{entry(tracker, code) | down?: true})

  defp entry(tracker, code) do
    Map.get(tracker.keys, code, %{down?: false, accepted_at: nil, released_at: nil})
  end

  defp put(tracker, code, entry), do: %{tracker | keys: Map.put(tracker.keys, code, entry)}

  defp recent?(nil, _ms, _tracker), do: false
  defp recent?(at, ms, tracker), do: ms - at < tracker.debounce_ms
end
