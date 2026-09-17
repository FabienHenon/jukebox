defmodule Jukebox.Input.Debounce do
  @moduledoc """
  Pure per-command debouncer for physical buttons.

  A press is accepted when at least `window_ms` have elapsed since the last
  *accepted* press of the same command. Switch bounce (a burst of edges within
  a few milliseconds) therefore produces exactly one command. Time is passed
  in explicitly (monotonic milliseconds) so the logic is deterministic in
  tests and reusable by any hardware adapter.
  """

  @default_window_ms 80

  defstruct window_ms: @default_window_ms, last_accepted: %{}

  @type t :: %__MODULE__{window_ms: non_neg_integer(), last_accepted: %{atom() => integer()}}

  @spec new(non_neg_integer()) :: t()
  def new(window_ms \\ @default_window_ms) when is_integer(window_ms) and window_ms >= 0 do
    %__MODULE__{window_ms: window_ms}
  end

  @doc "Registers a press at `now_ms`; returns `{:accept | :reject, debounce}`."
  @spec press(t(), atom(), integer()) :: {:accept | :reject, t()}
  def press(%__MODULE__{} = debounce, command, now_ms) when is_integer(now_ms) do
    case Map.fetch(debounce.last_accepted, command) do
      {:ok, last} when now_ms - last < debounce.window_ms ->
        {:reject, debounce}

      _ ->
        {:accept, %{debounce | last_accepted: Map.put(debounce.last_accepted, command, now_ms)}}
    end
  end
end
