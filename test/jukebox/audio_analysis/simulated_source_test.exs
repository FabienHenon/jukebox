defmodule Jukebox.AudioAnalysis.SimulatedSourceTest do
  use ExUnit.Case, async: true

  alias Jukebox.AudioAnalysis
  alias Jukebox.AudioAnalysis.{Frame, SimulatedSource}
  alias Jukebox.Playback

  # Ten seconds at 20 frames per second.
  @frames 0..199

  defp frames(opts \\ []), do: Enum.map(@frames, &SimulatedSource.frame_at(&1, opts))

  describe "frame_at/2" do
    test "the same counter always gives the same frame" do
      assert frames() == frames()
      assert SimulatedSource.frame_at(37) == SimulatedSource.frame_at(37)

      assert SimulatedSource.frame_at(37) == %Frame{
               level: SimulatedSource.frame_at(37).level,
               bass: SimulatedSource.frame_at(37).bass,
               onset: +0.0,
               beat_id: 4,
               bpm: 112.0,
               confidence: SimulatedSource.frame_at(37).confidence
             }
    end

    test "every value stays within bounds, in every profile" do
      for profile <- [:steady, :free_tempo, :silent],
          bpm <- [40, 112, 240],
          frame <- frames(profile: profile, bpm: bpm) do
        for field <- [:level, :bass, :onset, :confidence] do
          value = Map.fetch!(frame, field)
          assert is_float(value) and value >= 0.0 and value <= 1.0, "#{field} = #{value}"
        end

        assert is_integer(frame.beat_id) and frame.beat_id >= 0
        assert frame.bpm == nil or frame.bpm == bpm * 1.0
      end
    end

    test "steady music has a regular beat at the configured tempo" do
      beats = frames(bpm: 120) |> Enum.map(& &1.beat_id)
      # 120 BPM is one beat every ten frames.
      assert Enum.at(beats, 0) == 1
      assert Enum.at(beats, 9) == 1
      assert Enum.at(beats, 10) == 2
      assert List.last(beats) == 20
      assert beats == Enum.sort(beats)
      assert Enum.all?(frames(bpm: 120), &(&1.bpm == 120.0 and &1.confidence > 0.6))

      assert frames(bpm: 60) |> List.last() |> Map.fetch!(:beat_id) == 10
    end

    test "bass pulses on the beat and the loudness keeps moving" do
      steady = frames(bpm: 120)
      on_beat = for {frame, n} <- Enum.with_index(steady), rem(n, 10) == 0, do: frame.bass
      between = for {frame, n} <- Enum.with_index(steady), rem(n, 10) == 7, do: frame.bass
      assert Enum.min(on_beat) > 0.7
      assert Enum.max(between) < 0.2

      levels = Enum.map(steady, & &1.level)
      assert Enum.max(levels) - Enum.min(levels) > 0.3
      assert length(Enum.uniq(levels)) > 150
    end

    test "attacks land on the beat, with a few in between" do
      steady = frames(bpm: 120)
      onsets = for {frame, n} <- Enum.with_index(steady), frame.onset > 0, do: n
      on_beat = Enum.filter(onsets, &(rem(&1, 10) == 0))
      assert length(on_beat) == 20
      assert length(onsets) > length(on_beat)
      assert length(onsets) < 60
    end

    test "free tempo has irregular beats, no tempo and low confidence" do
      free = frames(profile: :free_tempo, bpm: 120)
      assert Enum.all?(free, &(&1.bpm == nil and &1.confidence < 0.45))

      beat_frames =
        free
        |> Enum.map(& &1.beat_id)
        |> Enum.with_index()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(fn [{before, _}, {later, _}] -> later > before end)
        |> Enum.map(fn [_before, {_id, n}] -> n end)

      gaps = beat_frames |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
      assert length(gaps) > 10
      assert length(Enum.uniq(gaps)) > 1
    end

    test "silence is silence, and a downed analyser sends nothing" do
      assert Enum.all?(frames(profile: :silent), fn frame ->
               frame.level == 0.0 and frame.bass == 0.0 and frame.onset == 0.0 and
                 frame.beat_id == 0 and frame.bpm == nil and frame.confidence == 0.0
             end)

      assert Enum.all?(frames(profile: :down), &is_nil/1)
    end

    test "the publication rate changes the time between frames, not the music" do
      # Frame 40 at 20 per second and frame 20 at 10 per second are both 2 s in.
      at_20 = SimulatedSource.frame_at(40, publish_rate: 20, bpm: 120)
      at_10 = SimulatedSource.frame_at(20, publish_rate: 10, bpm: 120)
      assert at_20.beat_id == at_10.beat_id
      assert_in_delta at_20.level, at_10.level, 0.0001
    end
  end

  describe "the source process" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      :ok = AudioAnalysis.subscribe(pubsub)
      {:ok, pubsub: pubsub}
    end

    defp start_source(context, opts \\ []) do
      name = :"simulated_#{System.unique_integer([:positive])}"
      defaults = [name: name, pubsub: context.pubsub, tick_ms: nil, playback: nil, bpm: 120]
      start_supervised!({SimulatedSource, Keyword.merge(defaults, opts)}, id: name)
      [server: name]
    end

    test "each tick publishes the next frame of the sequence", context do
      source = start_source(context)

      for index <- 0..25 do
        expected = SimulatedSource.frame_at(index, bpm: 120)
        assert SimulatedSource.tick(source) == expected
        assert_receive {:audio_frame, ^expected}
      end

      assert %{index: 26, profile: :steady, bpm: 120, playing?: true} =
               SimulatedSource.snapshot(source)
    end

    test "the timer publishes on its own at the configured rate", context do
      start_source(context, tick_ms: 5)
      first = SimulatedSource.frame_at(0, bpm: 120)
      second = SimulatedSource.frame_at(1, bpm: 120)
      assert_receive {:audio_frame, ^first}, 500
      assert_receive {:audio_frame, ^second}, 500
    end

    test "profile and tempo can be changed while running, and reset", context do
      source = start_source(context)
      assert SimulatedSource.set_profile(:free_tempo, source) == :ok
      assert %Frame{bpm: nil} = SimulatedSource.tick(source)

      assert SimulatedSource.set_profile(:down, source) == :ok
      assert SimulatedSource.tick(source) == nil
      refute_receive {:audio_frame, %Frame{bpm: 120.0}}, 20

      assert SimulatedSource.set_profile(:steady, source) == :ok
      assert SimulatedSource.set_bpm(90, source) == :ok
      assert %Frame{bpm: 90.0} = SimulatedSource.tick(source)

      assert SimulatedSource.reset(source) == :ok
      assert %{index: 0, profile: :steady, bpm: 120} = SimulatedSource.snapshot(source)
    end

    test "frames flow only while music is playing", context do
      playback = :"playback_#{System.unique_integer([:positive])}"
      start_supervised!({Playback.Server, name: playback, pubsub: context.pubsub, coalesce_ms: 0})
      source = start_source(context, playback: playback)

      assert %{playing?: false} = SimulatedSource.snapshot(source)
      assert SimulatedSource.tick(source) == nil
      refute_receive {:audio_frame, _frame}, 20

      Playback.Server.notify(playback, {:session_started, %{source_name: "Test"}})
      Playback.Server.notify(playback, {:playback_changed, :playing})
      Playback.Server.sync(playback)
      assert %{playing?: true} = SimulatedSource.snapshot(source)
      assert %Frame{beat_id: 1} = SimulatedSource.tick(source)
      assert_receive {:audio_frame, %Frame{beat_id: 1}}

      Playback.Server.notify(playback, {:playback_changed, :paused})
      Playback.Server.sync(playback)
      assert %{playing?: false, index: 1} = SimulatedSource.snapshot(source)
      assert SimulatedSource.tick(source) == nil

      # Resuming carries on from where the music stopped.
      Playback.Server.notify(playback, {:playback_changed, :playing})
      Playback.Server.sync(playback)
      expected = SimulatedSource.frame_at(1, bpm: 120)
      assert SimulatedSource.tick(source) == expected
    end

    test "the simulator API is safe when the source is not running" do
      opts = [server: :no_such_simulated_source]
      assert SimulatedSource.snapshot(opts) == {:error, :not_running}
      assert SimulatedSource.set_profile(:silent, opts) == {:error, :not_running}
      assert SimulatedSource.set_bpm(100, opts) == {:error, :not_running}
      assert SimulatedSource.tick(opts) == {:error, :not_running}
      assert SimulatedSource.reset(opts) == {:error, :not_running}
    end
  end
end
