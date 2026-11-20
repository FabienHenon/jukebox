defmodule Jukebox.Hardware.ExecTest do
  use ExUnit.Case, async: true

  import Jukebox.Test.HardwareHelpers

  alias Jukebox.Hardware.Exec

  @moduletag :tmp_dir

  test "returns the exit status and the output, standard error included", %{tmp_dir: dir} do
    script = script!(dir, "ok", "echo out; echo err >&2; echo \"$1-$LC_ALL\"; exit 7")

    assert {:ok, %{status: 7, output: output}} =
             Exec.run(script, ["arg"], env: [{"LC_ALL", "C"}])

    assert output =~ "out"
    assert output =~ "err"
    assert output =~ "arg-C"
  end

  test "arguments are passed as they are, never through a shell", %{tmp_dir: dir} do
    script = script!(dir, "args", ~s(printf '%s|' "$@"))
    marker = Path.join(dir, "created")

    assert {:ok, %{status: 0, output: output}} =
             Exec.run(script, ["a b", "; touch #{marker}", "$(touch #{marker})"])

    assert output == "a b|; touch #{marker}|$(touch #{marker})|"
    refute File.exists?(marker)
  end

  test "a missing or non-executable program is an error, not a crash", %{tmp_dir: dir} do
    assert Exec.run(Path.join(dir, "absent"), []) == {:error, :not_found}

    plain = Path.join(dir, "plain")
    File.write!(plain, "#!/bin/sh\n")
    File.chmod!(plain, 0o644)
    assert Exec.run(plain, []) == {:error, :permission_denied}
  end

  test "at the deadline the program is killed, not just abandoned", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "pid")
    script = script!(dir, "hang", "echo $$ > #{pid_file}\nexec sleep 30")

    started = System.monotonic_time(:millisecond)
    assert Exec.run(script, [], timeout_ms: 300) == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - started < 2_500

    os_pid = pid_file |> File.read!() |> String.trim()
    eventually(fn -> not os_process_alive?(os_pid) end)
  end

  test "a caller that is told to stop takes its program with it", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "pid")
    script = script!(dir, "hang", "echo $$ > #{pid_file}\nexec sleep 30")
    test = self()

    # The caller is linked to an owner, as a lane's job is linked to its lane.
    owner =
      spawn(fn ->
        job = spawn_link(fn -> Exec.run(script, [], timeout_ms: 20_000) end)
        send(test, {:job, job})
        Process.sleep(:infinity)
      end)

    assert_receive {:job, job}

    os_pid =
      eventually(fn ->
        File.exists?(pid_file) && String.trim(File.read!(pid_file)) != "" &&
          String.trim(File.read!(pid_file))
      end)

    assert os_process_alive?(os_pid)

    ref = Process.monitor(job)
    Process.exit(owner, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^job, _reason}, 3_000
    eventually(fn -> not os_process_alive?(os_pid) end)
  end

  test "the caller's trap_exit setting and mailbox are left as they were", %{tmp_dir: dir} do
    script = script!(dir, "quick", "exit 0")
    assert Process.info(self(), :trap_exit) == {:trap_exit, false}
    assert {:ok, %{status: 0}} = Exec.run(script, [])
    assert Process.info(self(), :trap_exit) == {:trap_exit, false}
    refute_receive _anything, 50
  end
end
