defmodule Jukebox.AudioAnalysis.NativePipelineTest do
  # The real thing, end to end, minus ALSA: generated PCM is piped into the
  # native analyser, which sends datagrams to a NativeSource. Skipped unless
  # the analyser has been built (see test/test_helper.exs).
  use ExUnit.Case, async: true

  alias Jukebox.AudioAnalysis
  alias Jukebox.AudioAnalysis.{Frame, NativeSource}

  @moduletag :native_analyzer
  @build Path.expand("../../../native/jukebox_audio_analyzer/build", __DIR__)

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    :ok = AudioAnalysis.subscribe(pubsub)

    directory = Path.join(System.tmp_dir!(), "jb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    name = :"native_#{System.unique_integer([:positive])}"
    path = Path.join(directory, "audio.sock")
    start_supervised!({NativeSource, name: name, pubsub: pubsub, socket: path, publish_rate: 20})
    assert %{listening?: true} = NativeSource.status(name)

    {:ok, source: name, path: path}
  end

  # Runs `seconds` of a generated signal through the analyser, as ALSA would.
  defp play(context, signal, seconds) do
    command =
      ~s("#{@build}/pcm_gen" --signal #{signal} --seconds #{seconds} | ) <>
        ~s("#{@build}/jukebox_audio_analyzer" --sample-rate 44100 --channels 2 --bits 16 ) <>
        ~s(--format S16_LE --socket "#{context.path}" --publish-rate 20)

    assert {output, 0} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)
    output
  end

  test "music played through the analyser arrives as valid frames", context do
    play(context, "music", 5)

    assert_receive {:audio_frame, %Frame{} = frame}, 1_000

    for field <- [:level, :bass, :onset, :confidence] do
      value = Map.fetch!(frame, field)
      assert is_float(value) and value >= 0.0 and value <= 1.0
    end

    # The analyser is far faster than real time here, so most of its hundred
    # frames arrive at once and are rightly dropped by the rate limit; what
    # matters is that they arrived and that nothing was malformed.
    status = NativeSource.status(context.source)
    assert status.received >= 1
    assert status.rejected == 0
    assert status.published >= 1
    refute status.stale?
  end

  test "silence arrives as zeros, and the analyser says nothing", context do
    assert play(context, "silence", 3) == ""

    assert_receive {:audio_frame,
                    %Frame{level: +0.0, bass: +0.0, onset: +0.0, beat_id: 0, bpm: nil}},
                   1_000
  end
end
