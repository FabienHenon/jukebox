defmodule Jukebox.AudioAnalysis.RateLimiter do
  @moduledoc """
  Keeps a stream of frames at or below a number of frames per second.

  A plain "one frame per interval" rule would throw away every other frame of
  a source that publishes at exactly the allowed rate, because frames never
  arrive perfectly spaced. This limiter (a generic cell rate algorithm with
  one interval of tolerance) lets a frame through when it is at most one
  interval early, and makes up for it afterwards: the long-run rate never
  exceeds the limit, and a steady source at the limit loses nothing.
  """

  @enforce_keys [:interval]
  defstruct [:interval, :next]

  @type t :: %__MODULE__{interval: float(), next: number() | nil}

  @spec new(pos_integer()) :: t()
  def new(frames_per_second) when is_integer(frames_per_second) and frames_per_second > 0 do
    %__MODULE__{interval: 1000 / frames_per_second}
  end

  @doc "Decides whether a frame arriving at `now` (milliseconds) may pass."
  @spec allow(t(), number()) :: {:ok, t()} | :drop
  def allow(%__MODULE__{next: nil} = limiter, now) do
    {:ok, %{limiter | next: now + limiter.interval}}
  end

  def allow(%__MODULE__{next: next, interval: interval} = limiter, now) do
    if now < next - interval,
      do: :drop,
      else: {:ok, %{limiter | next: max(now, next) + interval}}
  end
end
