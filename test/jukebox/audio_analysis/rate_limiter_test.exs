defmodule Jukebox.AudioAnalysis.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Jukebox.AudioAnalysis.RateLimiter

  # Feeds arrival times through a limiter and returns the ones that passed.
  defp passed(limiter, times) do
    {_limiter, kept} =
      Enum.reduce(times, {limiter, []}, fn time, {limiter, kept} ->
        case RateLimiter.allow(limiter, time) do
          {:ok, limiter} -> {limiter, [time | kept]}
          :drop -> {limiter, kept}
        end
      end)

    Enum.reverse(kept)
  end

  test "a source exactly at the limit loses nothing" do
    times = Enum.map(0..199, &(&1 * 50))
    assert passed(RateLimiter.new(20), times) == times
  end

  test "a source at the limit with uneven arrival loses nothing" do
    # 20 frames per second, each up to 15 ms early or late.
    jitter = [0, 12, -9, 15, -15, 7, -3, 10, -12, 4]

    times =
      for n <- 0..199, do: n * 50 + Enum.at(jitter, rem(n, 10))

    assert passed(RateLimiter.new(20), times) == times
  end

  test "a faster source is cut down to the limit" do
    # 100 frames per second for ten seconds.
    times = Enum.map(0..999, &(&1 * 10))
    kept = passed(RateLimiter.new(20), times)

    # One frame of tolerance on top of 20 per second.
    assert length(kept) in 200..201

    for second <- 0..9 do
      in_second = Enum.count(kept, &(&1 >= second * 1000 and &1 < (second + 1) * 1000))
      assert in_second <= 21, "#{in_second} frames in second #{second}"
    end
  end

  test "a burst after a pause does not earn extra frames" do
    limiter = RateLimiter.new(20)
    # Nothing for ten seconds, then fifty frames in the same millisecond.
    assert passed(limiter, [0 | List.duplicate(10_000, 50)]) == [0, 10_000, 10_000]
  end

  test "lower rates are honoured" do
    times = Enum.map(0..999, &(&1 * 10))
    assert length(passed(RateLimiter.new(5), times)) in 50..51
  end
end
