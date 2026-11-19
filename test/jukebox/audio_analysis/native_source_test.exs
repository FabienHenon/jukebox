defmodule Jukebox.AudioAnalysis.NativeSourceTest do
  # Real Unix datagram sockets, exactly what the native analyser uses.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Jukebox.AudioAnalysis
  alias Jukebox.AudioAnalysis.{Frame, NativeSource}

  @valid ~s({"level":0.42,"bass":0.71,"onset":0.83,"beat_id":127,"bpm":118.4,"confidence":0.76})

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    :ok = AudioAnalysis.subscribe(pubsub)

    # Unix socket paths are limited to about a hundred bytes, so the socket
    # lives directly in the system temporary directory, not in ExUnit's.
    directory = Path.join(System.tmp_dir!(), "jb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, sender} = :gen_udp.open(0, [:binary, :local])
    on_exit(fn -> :gen_udp.close(sender) end)

    {:ok,
     pubsub: pubsub,
     directory: directory,
     path: Path.join(directory, "audio.sock"),
     sender: sender}
  end

  defp start_source(context, opts \\ []) do
    name = :"native_#{System.unique_integer([:positive])}"
    defaults = [name: name, pubsub: context.pubsub, socket: context.path, publish_rate: 20]
    start_supervised!({NativeSource, Keyword.merge(defaults, opts)}, id: name)
    # status/1 is a call, so the socket has been opened (or has failed) by now.
    NativeSource.status(name)
    name
  end

  # Datagrams are handed to the source one at a time, a moment after they are
  # sent: wait until it has counted `count` of them.
  defp await_received(source, count) do
    assert Enum.any?(1..500, fn _attempt ->
             NativeSource.status(source).received >= count or (Process.sleep(1) && false)
           end),
           "the source never received #{count} datagram(s)"
  end

  defp send_datagram(context, payload),
    do: :gen_udp.send(context.sender, {:local, context.path}, 0, payload)

  test "publishes a valid frame from the analyser", context do
    source = start_source(context)

    assert %{listening?: true, stale?: true, last_frame_ms_ago: nil, last_frame: nil} =
             NativeSource.status(source)

    assert send_datagram(context, @valid) == :ok

    assert_receive {:audio_frame,
                    %Frame{
                      level: 0.42,
                      bass: 0.71,
                      onset: 0.83,
                      beat_id: 127,
                      bpm: 118.4,
                      confidence: 0.76
                    }}

    assert %{
             received: 1,
             published: 1,
             rejected: 0,
             stale?: false,
             last_frame: %Frame{beat_id: 127, confidence: 0.76}
           } = NativeSource.status(source)
  end

  test "the socket is writable by its group and by nobody else", context do
    start_source(context)
    stat = File.stat!(context.path)
    assert stat.type == :other
    assert Bitwise.band(stat.mode, 0o777) == 0o660
  end

  test "malformed messages are counted and dropped, and never stop the source", context do
    source = start_source(context)

    log =
      capture_log(fn ->
        for {payload, count} <-
              Enum.with_index(
                [
                  "",
                  "garbage",
                  ~s({"level":0.4}),
                  ~s({"level":NaN,"bass":0,"onset":0,"beat_id":1,"bpm":0,"confidence":0}),
                  ~s({"level":"loud","bass":0,"onset":0,"beat_id":1,"bpm":0,"confidence":0}),
                  String.duplicate("x", 1500),
                  <<0, 255, 1, 254>>
                ],
                1
              ) do
          assert send_datagram(context, payload) == :ok
          await_received(source, count)
        end

        assert %{received: 7, rejected: 7, published: 0, stale?: true} =
                 NativeSource.status(source)
      end)

    refute_receive {:audio_frame, _frame}, 20
    # One line for the whole burst, not one per message.
    assert length(String.split(log, "malformed analyser message")) == 2

    assert send_datagram(context, @valid) == :ok
    assert_receive {:audio_frame, %Frame{beat_id: 127}}
    assert %{received: 8, rejected: 7, published: 1} = NativeSource.status(source)
  end

  test "out-of-range values are clamped before they are published", context do
    start_source(context)

    send_datagram(
      context,
      ~s({"level":3.5,"bass":-1,"onset":1.0001,"beat_id":2,"bpm":9000,"confidence":-0.5})
    )

    assert_receive {:audio_frame,
                    %Frame{level: 1.0, bass: +0.0, onset: 1.0, bpm: nil, confidence: +0.0}}
  end

  test "frames faster than the publication rate are dropped, not queued", context do
    source = start_source(context, publish_rate: 5)

    # Each datagram is handled before the next is sent, so the kernel buffer
    # never decides the outcome; the whole burst still takes a few milliseconds.
    for beat <- 1..40 do
      assert send_datagram(context, String.replace(@valid, "127", Integer.to_string(beat))) == :ok

      await_received(source, beat)
    end

    %{received: received, published: published, dropped: dropped} = NativeSource.status(source)
    assert received == 40
    # Forty frames at once at 5 per second: the first and one of tolerance.
    assert published == 2
    assert dropped == 38
    assert_receive {:audio_frame, %Frame{beat_id: 1}}
    assert_receive {:audio_frame, %Frame{beat_id: 2}}
    refute_receive {:audio_frame, _frame}, 20
  end

  test "reports itself stale when frames stop", context do
    source = start_source(context, stale_ms: 40)
    assert NativeSource.stale?(source)

    send_datagram(context, @valid)
    assert_receive {:audio_frame, _frame}
    refute NativeSource.stale?(source)
    assert %{last_frame_ms_ago: age} = NativeSource.status(source)
    assert age < 40

    Process.sleep(60)
    assert NativeSource.stale?(source)

    send_datagram(context, @valid)
    assert_receive {:audio_frame, _frame}
    refute NativeSource.stale?(source)
  end

  test "a source that is not running counts as stale" do
    assert NativeSource.stale?(:no_such_audio_source)
    assert NativeSource.status(:no_such_audio_source) == {:error, :not_running}
  end

  test "the socket is recreated after a supervised restart", context do
    source = start_source(context)
    first = Process.whereis(source)

    # A crash leaves the socket file behind: the next start must replace it.
    Process.exit(first, :kill)
    assert File.exists?(context.path)

    second =
      Enum.find_value(1..100, fn _attempt ->
        case Process.whereis(source) do
          pid when is_pid(pid) and pid != first -> pid
          _other -> Process.sleep(10) && nil
        end
      end)

    assert is_pid(second)
    assert %{listening?: true} = NativeSource.status(source)

    # The analyser keeps sending to the same path and is heard again.
    assert send_datagram(context, @valid) == :ok
    assert_receive {:audio_frame, %Frame{beat_id: 127}}
  end

  test "the socket file is removed on a clean stop, and senders are simply refused", context do
    source = start_source(context)
    assert File.exists?(context.path)

    stop_supervised!(source)
    refute File.exists?(context.path)
    assert {:error, _reason} = send_datagram(context, @valid)
  end

  test "a missing directory does not stop the application: it keeps retrying", context do
    path = Path.join([context.directory, "not-created-yet", "audio.sock"])

    log =
      capture_log(fn ->
        source = start_source(context, socket: path, retry_ms: 20)
        assert %{listening?: false, stale?: true} = NativeSource.status(source)
        assert Process.alive?(Process.whereis(source))

        # Several retries later it is still alive and has complained once.
        Process.sleep(90)
        assert %{listening?: false} = NativeSource.status(source)

        # The directory appears (tmpfiles, an operator): the next retry binds.
        File.mkdir_p!(Path.dirname(path))

        assert Enum.any?(1..100, fn _attempt ->
                 NativeSource.status(source).listening? or (Process.sleep(10) && false)
               end)

        assert :gen_udp.send(context.sender, {:local, path}, 0, @valid) == :ok
        assert_receive {:audio_frame, %Frame{beat_id: 127}}
      end)

    assert length(String.split(log, "cannot listen on")) == 2
  end

  test "a regular file at the socket path is left alone", context do
    File.write!(context.path, "precious")

    capture_log(fn ->
      source = start_source(context, retry_ms: 20)
      assert %{listening?: false} = NativeSource.status(source)
    end)

    assert File.read!(context.path) == "precious"
  end
end
