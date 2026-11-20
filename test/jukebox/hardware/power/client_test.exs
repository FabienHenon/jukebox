defmodule Jukebox.Hardware.Power.ClientTest do
  use ExUnit.Case, async: true

  import Jukebox.Test.HardwareHelpers

  alias Jukebox.Hardware.Power.Client

  @moduletag :tmp_dir

  test "runs the client with the fixed arguments and reads its acknowledgement", %{tmp_dir: dir} do
    log = Path.join(dir, "calls")

    client =
      script!(dir, "client", """
      echo "$@" >> #{log}
      echo '{"v":1,"id":"x","ok":true,"instance":"abc","revision":13,"mode":"awake"}'
      """)

    assert Client.command(["disco", "toggle"], executable: client) ==
             {:ok, %{acked?: true, instance: "abc", revision: 13}}

    assert File.read!(log) == "disco toggle\n"
  end

  test "an older client that only exits 0 is 'sent', not 'confirmed'", %{tmp_dir: dir} do
    client = script!(dir, "client", "exit 0")

    assert Client.command(["strip", "toggle"], executable: client) ==
             {:ok, %{acked?: false, instance: nil, revision: nil}}
  end

  test "each exit status keeps its meaning", %{tmp_dir: dir} do
    refused = script!(dir, "refused", ~s(echo '{"ok":false,"error":"not_awake"}'; exit 2))

    assert Client.command(["disco", "toggle"], executable: refused) ==
             {:error, {:rejected, "not_awake"}}

    silent = script!(dir, "silent", "exit 3")
    assert Client.command(["disco", "toggle"], executable: silent) == {:error, :no_ack}

    down = script!(dir, "down", "exit 4")
    assert Client.command(["disco", "toggle"], executable: down) == {:error, :unreachable}

    odd = script!(dir, "odd", "exit 9")

    assert Client.command(["disco", "toggle"], executable: odd) ==
             {:error, {:failed, {:exit_status, 9}}}
  end

  test "a client that hangs is killed and the result is uncertain", %{tmp_dir: dir} do
    hang = script!(dir, "hang", "exec sleep 30")

    assert Client.command(["disco", "toggle"], executable: hang, timeout_ms: 200) ==
             {:error, :timeout}

    assert Client.uncertain?(:timeout)
    assert Client.uncertain?(:no_ack)
    refute Client.uncertain?(:unreachable)
    refute Client.uncertain?({:rejected, "not_awake"})
  end

  test "only the light commands can be sent, whatever is asked", %{tmp_dir: dir} do
    log = Path.join(dir, "calls")
    client = script!(dir, "client", ~s(echo "$@" >> #{log}))

    for args <- [
          ["shutdown"],
          ["standby", "on"],
          ["standby", "toggle"],
          ["disco", "toggle", "--socket", "/tmp/x"],
          ["decor", "toggle"],
          ["disco; reboot"],
          []
        ] do
      assert Client.command(args, executable: client) == {:error, :not_allowed}
    end

    refute File.exists?(log)
    assert Client.allowed() == [["disco", "toggle"], ["strip", "toggle"], ["strip", "on"]]
  end

  test "a missing or unusable client is an error", %{tmp_dir: dir} do
    assert Client.command(["disco", "toggle"], executable: Path.join(dir, "absent")) ==
             {:error, :client_missing}

    plain = Path.join(dir, "plain")
    File.write!(plain, "")
    assert Client.command(["disco", "toggle"], executable: plain) == {:error, :permission_denied}
  end

  test "the real client and controller understand each other", %{tmp_dir: _dir} do
    # Covered end to end, with a real socket, by test/hardware/test_power_controller.py
    # (run from Jukebox.Hardware.PythonTest). Here: the allowed commands are
    # commands the controller knows.
    program =
      File.read!(Path.expand("../../../../ops/hardware/jukebox-power-controller.py", __DIR__))

    for [light, verb] <- Client.allowed() do
      assert program =~ ~s("#{light}")
      assert program =~ ~s("#{verb}")
    end
  end
end
