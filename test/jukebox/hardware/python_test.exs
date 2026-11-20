defmodule Jukebox.Hardware.PythonTest do
  @moduledoc """
  Runs the Python test suites of the two programs that are not Elixir: the
  power controller (`ops/hardware/jukebox-power-controller.py`) and the input
  helper (`priv/hardware/xinmo_evdev.py`). They use fakes for the GPIO and
  for the input device, so they run on any machine with Python 3; without it
  this test is skipped.
  """

  use ExUnit.Case, async: true

  @moduletag :python
  @root Path.expand("../../..", __DIR__)

  test "the Python suites pass" do
    python = System.find_executable("python3")

    {output, status} =
      System.cmd(python, ["-m", "unittest", "discover", "-s", "test/hardware", "-p", "test_*.py"],
        cd: @root,
        env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ ~r/Ran \d+ tests/
    refute output =~ "Ran 0 tests"
  end

  test "both programs compile with the interpreter at hand" do
    python = System.find_executable("python3")

    for program <- ["ops/hardware/jukebox-power-controller.py", "priv/hardware/xinmo_evdev.py"] do
      code = ~S|import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")|
      assert {_output, 0} = System.cmd(python, ["-c", code, Path.join(@root, program)])
    end
  end

  test "the input helper explains itself and refuses to run without a device" do
    python = System.find_executable("python3")
    helper = Path.join(@root, "priv/hardware/xinmo_evdev.py")

    assert {help, 0} = System.cmd(python, [helper, "--help"], stderr_to_stdout: true)
    assert help =~ "--device"
    assert help =~ "--diagnose"

    assert {_usage, 2} = System.cmd(python, [helper], stderr_to_stdout: true)
  end

  test "the power client refuses commands it does not know before sending anything" do
    python = System.find_executable("python3")
    client = Path.join(@root, "ops/hardware/jukebox-power-controller.py")

    assert {_output, 1} =
             System.cmd(python, [client, "--socket", "/nonexistent/socket", "fog", "on"],
               stderr_to_stdout: true
             )

    # A known command with no controller: "unreachable", not "done".
    assert {_output, 4} =
             System.cmd(python, [client, "--socket", "/nonexistent/socket", "disco", "toggle"],
               stderr_to_stdout: true
             )

    # The daemon is not started by anyone but root.
    if System.cmd("id", ["-u"]) != {"0\n", 0} do
      assert {output, 1} = System.cmd(python, [client, "--daemon"], stderr_to_stdout: true)
      assert output =~ "root"
    end
  end
end
