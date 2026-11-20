defmodule Jukebox.Inputs.EvdevTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Jukebox.Test.HardwareHelpers

  alias Jukebox.Inputs.Evdev
  alias Jukebox.Inputs.Evdev.Protocol
  alias Jukebox.Test.InputSink, as: Sink

  @moduletag :tmp_dir

  describe "protocol" do
    test "key events" do
      assert Protocol.decode(~s({"t":"key","c":288,"v":1,"ms":123456})) ==
               {:ok, {:key, 288, 1, 123_456}}

      assert Protocol.decode(~s({"t":"key","c":0,"v":0,"ms":0})) == {:ok, {:key, 0, 0, 0}}
      assert Protocol.decode(~s({"t":"key","c":767,"v":2,"ms":9})) == {:ok, {:key, 767, 2, 9}}
    end

    test "connection, resynchronisation and device status" do
      line =
        ~s({"t":"connected","name":"Encoder","vendor":5824,"product":1505,"version":257,) <>
          ~s("phys":"usb-1/input0","path":"/dev/input/by-id/x","real":"/dev/input/event3",) <>
          ~s("keys":[288,289],"held":[289],"abs":true})

      assert {:ok, {:connected, device}} = Protocol.decode(line)

      assert device == %{
               name: "Encoder",
               vendor: 5824,
               product: 1505,
               version: 257,
               phys: "usb-1/input0",
               path: "/dev/input/by-id/x",
               real_path: "/dev/input/event3",
               abs?: true,
               keys: [288, 289],
               held: [289]
             }

      assert Protocol.decode(~s({"t":"resync","held":[288],"ms":5})) == {:ok, {:resync, [288], 5}}
      assert Protocol.decode(~s({"t":"waiting","reason":"enoent"})) == {:ok, {:waiting, "enoent"}}

      assert Protocol.decode(~s({"t":"disconnected","reason":"enodev"})) ==
               {:ok, {:disconnected, "enodev"}}

      assert Protocol.decode(~s({"t":"hello","v":1})) == :ignore
    end

    test "anything out of shape is rejected" do
      for line <- [
            "",
            "garbage",
            "[]",
            ~s({"c":288,"v":1,"ms":1}),
            ~s({"t":"key","c":"288","v":1,"ms":1}),
            ~s({"t":"key","c":288,"v":3,"ms":1}),
            ~s({"t":"key","c":768,"v":1,"ms":1}),
            ~s({"t":"key","c":-1,"v":1,"ms":1}),
            ~s({"t":"key","c":288,"v":1}),
            ~s({"t":"key","c":288,"v":1,"ms":-5}),
            ~s({"t":"connected","keys":"all","held":[]}),
            ~s({"t":"connected","keys":[288],"held":[99999]}),
            ~s({"t":"resync","held":[288]}),
            ~s({"t":"shutdown"})
          ] do
        assert {:error, _reason} = Protocol.decode(line), line
      end

      too_many = Jason.encode!(%{t: "connected", keys: Enum.map(1..800, fn _ -> 1 end), held: []})
      assert {:error, :invalid_codes} = Protocol.decode(too_many)
    end

    test "strings from the device are cut" do
      line =
        Jason.encode!(%{t: "connected", name: String.duplicate("x", 5_000), keys: [], held: []})

      assert {:ok, {:connected, %{name: name}}} = Protocol.decode(line)
      assert String.length(name) == 120
    end
  end

  describe "the helper process" do
    setup %{tmp_dir: dir} do
      {:ok, sink} = Sink.start_link(self())
      {:ok, sink: sink, sh: System.find_executable("sh"), dir: dir}
    end

    # The adapter runs "<python> -u <helper> --device <device>". Here the
    # interpreter is /bin/sh and the helper a shell script; "-u" then merely
    # makes sh treat unset variables as errors.
    defp start_adapter(context, helper, opts \\ []) do
      opts =
        Keyword.merge(
          [
            name: :"evdev_#{System.unique_integer([:positive])}",
            device: "/dev/input/by-id/test-device",
            sink: context.sink,
            python: context.sh,
            helper: helper,
            backoff_min_ms: 20,
            backoff_max_ms: 80
          ],
          opts
        )

      # The child is known to the test supervisor by its name.
      Process.put(:adapter, opts[:name])
      start_supervised!({Evdev, opts})
    end

    defp stop_adapter, do: stop_supervised!(Process.get(:adapter))

    test "forwards the helper's events and passes the device as an argument", context do
      helper =
        script!(context.dir, "helper", """
        echo '{"t":"hello","v":1}'
        printf '{"t":"waiting","reason":"%s"}\\n' "$2"
        echo '{"t":"connected","name":"Encoder","keys":[288],"held":[]}'
        echo '{"t":"key","c":288,"v":1,"ms":10}'
        echo '{"t":"key","c":288,"v":0,"ms":95}'
        exec cat > /dev/null
        """)

      start_adapter(context, helper)

      assert_receive {:input, {:helper, :started}}
      # "$2" is what followed --device: the configured path, untouched.
      assert_receive {:input, {:waiting, "/dev/input/by-id/test-device"}}
      assert_receive {:input, {:connected, %{name: "Encoder", keys: [288]}}}
      assert_receive {:input, {:key, 288, 1, 10}}
      assert_receive {:input, {:key, 288, 0, 95}}
    end

    test "malformed and oversized lines are counted as such, and the stream goes on", context do
      long = String.duplicate("x", 20_000)

      helper =
        script!(context.dir, "helper", """
        echo 'not json'
        echo '{"t":"key","c":99999,"v":1,"ms":1}'
        echo '#{long}'
        echo '{"t":"key","c":288,"v":1,"ms":10}'
        exec cat > /dev/null
        """)

      start_adapter(context, helper)

      assert_receive {:input, {:malformed, :invalid_json}}
      assert_receive {:input, {:malformed, {:unexpected, "key"}}}
      assert_receive {:input, {:malformed, :line_too_long}}
      assert_receive {:input, {:key, 288, 1, 10}}
    end

    test "stopping the adapter stops the helper: nothing is left running", context do
      pid_file = Path.join(context.dir, "pid")

      helper =
        script!(context.dir, "helper", """
        echo $$ > #{pid_file}
        echo '{"t":"hello","v":1}'
        exec sleep 300
        """)

      adapter = start_adapter(context, helper)
      os_pid = eventually(fn -> Evdev.status(adapter).os_pid end)
      eventually(fn -> File.exists?(pid_file) end)
      assert os_process_alive?(os_pid)
      assert %{running?: true, restarts: 0} = Evdev.status(adapter)

      stop_adapter()
      eventually(fn -> not os_process_alive?(os_pid) end)
    end

    test "a helper that keeps dying is restarted with growing pauses, quietly", context do
      starts = Path.join(context.dir, "starts")
      helper = script!(context.dir, "helper", "echo x >> #{starts}\nexit 3")

      log =
        capture_log(fn ->
          adapter = start_adapter(context, helper)
          assert_receive {:input, {:helper, {:exited, 3}}}, 1_000
          Process.sleep(700)

          count = starts |> File.read!() |> String.split("\n", trim: true) |> length()
          # Pauses of 20, 40, 80, 80, 80... ms: about ten starts in 700 ms. An
          # immediate restart loop would have made hundreds.
          # (The lower bound is loose on purpose: a slow machine starts fewer.)
          assert count in 3..14, "#{count} starts in 700 ms"
          assert %{last_exit: {:exited, 3}, restarts: restarts} = Evdev.status(adapter)
          assert restarts >= 2
        end)

      # The reason is logged once, not at every attempt.
      assert length(String.split(log, "cannot import the evdev module")) == 2
    end

    test "a helper that ran and then died is announced and started again", context do
      marker = Path.join(context.dir, "second")

      helper =
        script!(context.dir, "helper", """
        if [ -e #{marker} ]; then
          echo '{"t":"connected","name":"Back","keys":[],"held":[288]}'
          exec cat > /dev/null
        fi
        touch #{marker}
        echo '{"t":"connected","name":"First","keys":[],"held":[]}'
        exit 1
        """)

      capture_log(fn ->
        start_adapter(context, helper)
        assert_receive {:input, {:connected, %{name: "First"}}}
        assert_receive {:input, {:helper, {:exited, 1}}}
        assert_receive {:input, {:helper, :started}}, 1_000
        # The dispatcher is told again which keys are held.
        assert_receive {:input, {:connected, %{name: "Back", held: [288]}}}, 1_000
      end)
    end

    test "a missing interpreter or helper is a status, retried without a crash", context do
      log =
        capture_log(fn ->
          adapter = start_adapter(context, Path.join(context.dir, "absent.py"))
          assert_receive {:input, {:helper, {:unavailable, {:helper_missing, _path}}}}
          assert %{running?: false} = Evdev.status(adapter)
          stop_adapter()

          adapter = start_adapter(context, "unused", python: "/nonexistent/python3")

          assert_receive {:input,
                          {:helper, {:unavailable, {:python_missing, "/nonexistent/python3"}}}}

          assert Process.alive?(adapter)
        end)

      assert log =~ "input helper is not running"
    end
  end

  describe "the real helper" do
    test "is packaged where the release looks for it" do
      path = Evdev.helper_path()
      assert String.ends_with?(path, "priv/hardware/xinmo_evdev.py")
      assert File.regular?(path), "#{path} is missing from the application's priv directory"
      assert path =~ Application.app_dir(:jukebox)
    end

    @tag :python
    test "starts under the adapter and reports why it has no device", context do
      python = System.find_executable("python3")
      {:ok, sink} = Sink.start_link(self())

      {_output, import_status} =
        System.cmd(python, ["-c", "import evdev"], stderr_to_stdout: true)

      capture_log(fn ->
        start_supervised!(
          {Evdev,
           name: :"evdev_real_#{System.unique_integer([:positive])}",
           device: Path.join(context.tmp_dir, "no-such-device"),
           sink: sink,
           python: python,
           backoff_min_ms: 5_000}
        )

        assert_receive {:input, {:helper, :started}}

        if import_status == 0 do
          # python3-evdev is installed (the Raspberry Pi): there is no such
          # device, so the helper says so and keeps waiting for it.
          assert_receive {:input, {:waiting, "enoent"}}, 5_000
          refute_receive {:input, {:helper, {:exited, _status}}}, 300
        else
          # No python3-evdev here (a development machine): the helper ends
          # with the status reserved for that, which the adapter explains.
          assert_receive {:input, {:helper, {:exited, 3}}}, 5_000
        end
      end)
    end
  end
end
