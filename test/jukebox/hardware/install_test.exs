defmodule Jukebox.Hardware.InstallTest do
  @moduledoc """
  The power controller's installer, run against a temporary directory instead
  of `/` (`JUKEBOX_INSTALL_ROOT`): what it installs, what it keeps a copy of,
  how it rolls back, and above all what it leaves alone.
  """

  use ExUnit.Case, async: true

  import Bitwise

  @moduletag :tmp_dir
  @moduletag :python

  @root Path.expand("../../..", __DIR__)
  @installer Path.join(@root, "ops/hardware/install-power-controller.sh")
  @program "usr/local/sbin/jukebox-power-controller.py"
  @unit "etc/systemd/system/jukebox-power-controller.service"

  # Things that belong to the rest of the installation and must survive.
  @bystanders %{
    "etc/jukebox/jukebox.env" => "SECRET_KEY_BASE=do-not-touch\nJUKEBOX_BUTTONS_ENABLED=true\n",
    "opt/jukebox/bin/jukebox_audio_analyzer" => "analyser binary",
    "opt/jukebox/bin/jukebox_audio_tap" => "analyser wrapper",
    "etc/alsa/conf.d/60-jukebox-tap.conf" => "pcm.jukebox_tap {}",
    "etc/tmpfiles.d/jukebox-audio.conf" => "d /run/jukebox 2750 jukebox jukebox-audio -",
    "etc/shairport-sync.conf" =>
      "general = { default_airplay_volume = -12.0; volume_range_db = 30; };",
    "run/jukebox/audio-analysis.sock" => "socket placeholder",
    "boot/firmware/config.txt" => "dtoverlay=vc4-kms-v3d\n"
  }

  setup %{tmp_dir: root} do
    for {path, content} <- @bystanders do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    {:ok, root: root}
  end

  defp install(root, args \\ []) do
    System.cmd("sh", [@installer | args],
      env: [{"JUKEBOX_INSTALL_ROOT", root}, {"PYTHON", System.find_executable("python3")}],
      stderr_to_stdout: true
    )
  end

  defp backups(root, path), do: Path.wildcard(Path.join(root, path) <> ".*.bak")
  defp mode(path), do: File.stat!(path).mode &&& 0o777

  defp bystanders(root) do
    Map.new(@bystanders, fn {path, _content} ->
      full = Path.join(root, path)
      {path, {File.read!(full), File.stat!(full).mtime}}
    end)
  end

  test "installs the program and the unit, and nothing else", %{root: root} do
    before = bystanders(root)
    assert {output, 0} = install(root)

    assert File.read!(Path.join(root, @program)) ==
             File.read!(Path.join(@root, "ops/hardware/jukebox-power-controller.py"))

    assert File.read!(Path.join(root, @unit)) ==
             File.read!(Path.join(@root, "ops/hardware/jukebox-power-controller.service"))

    # Executable, and writable by its owner only.
    assert mode(Path.join(root, @program)) == 0o755
    assert mode(Path.join(root, @unit)) == 0o644

    assert bystanders(root) == before
    assert output =~ "Nothing was started or restarted"
    assert output =~ "--rollback"

    # No stray file: exactly two new ones.
    all =
      root |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)

    assert length(all) == map_size(@bystanders) + 2
  end

  test "running it again changes nothing and keeps no copy", %{root: root} do
    assert {_output, 0} = install(root)
    stat = File.stat!(Path.join(root, @program))

    assert {output, 0} = install(root)
    assert output =~ "unchanged"
    assert File.stat!(Path.join(root, @program)).mtime == stat.mtime
    assert backups(root, @program) == []
    assert backups(root, @unit) == []
  end

  test "replaces an existing controller after keeping a dated copy, and rolls back", %{root: root} do
    previous_program = "#!/usr/bin/python3\n# the controller installed by hand\n"
    previous_unit = "[Service]\nExecStart=/usr/local/sbin/jukebox-power-controller.py\n"

    for {path, content} <- [{@program, previous_program}, {@unit, previous_unit}] do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    before = bystanders(root)
    assert {output, 0} = install(root)
    assert output =~ "previous version kept as"

    assert [program_backup] = backups(root, @program)
    assert [unit_backup] = backups(root, @unit)
    assert Path.basename(program_backup) =~ ~r/^jukebox-power-controller\.py\.\d{8}-\d{6}\.bak$/
    assert File.read!(program_backup) == previous_program
    assert File.read!(unit_backup) == previous_unit
    assert File.read!(Path.join(root, @program)) =~ "Jukebox power controller"

    assert {output, 0} = install(root, ["--rollback"])
    assert output =~ "restored"
    assert File.read!(Path.join(root, @program)) == previous_program
    assert File.read!(Path.join(root, @unit)) == previous_unit
    # The copies are kept: rolling back is not destructive either.
    assert backups(root, @program) == [program_backup]
    assert bystanders(root) == before
  end

  test "a rollback with nothing to restore leaves the files as they are", %{root: root} do
    assert {_output, 0} = install(root)
    installed = File.read!(Path.join(root, @program))

    assert {output, 0} = install(root, ["--rollback"])
    assert output =~ "no previous version"
    assert File.read!(Path.join(root, @program)) == installed
  end

  test "warns about boot settings that take the Power button, without editing them", %{root: root} do
    config = Path.join(root, "boot/firmware/config.txt")
    content = "dtoverlay=vc4-kms-v3d\ndtoverlay=gpio-shutdown\ndtparam=i2c_arm=on\n"
    File.write!(config, content)

    assert {output, 0} = install(root)
    assert output =~ "gpio-shutdown"
    assert output =~ "i2c_arm"
    assert File.read!(config) == content
  end

  test "refuses unknown arguments and installs nothing", %{root: root} do
    for bad <- ["--force", "restart", "--rollback-all"] do
      assert {output, 1} = install(root, [bad])
      assert output =~ "unknown argument"
      refute File.exists?(Path.join(root, @program))
    end
  end

  test "--restart installs like the plain run (the restart itself needs a real system)", %{
    root: root
  } do
    before = bystanders(root)
    assert {output, 0} = install(root, ["--restart"])
    assert File.exists?(Path.join(root, @program))
    assert File.exists?(Path.join(root, @unit))
    # Against a test root systemd is left alone, and nothing claims otherwise.
    refute output =~ "was restarted"
    assert bystanders(root) == before
  end

  test "the controller is restarted only when asked, and nothing else ever is" do
    script = File.read!(@installer)

    code =
      script
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), ["#", "echo", "warn"]))
      |> Enum.join("\n")

    # The notes printed at the end tell the user what to run; they are text.
    [commands | _notes] = String.split(code, "cat << 'NOTE'")

    # One restart command, of this unit only, behind the explicit option.
    assert [restart] = Regex.scan(~r/systemctl\s+(?:re)?start[^\n]*/, commands) |> List.flatten()
    assert restart == ~s(systemctl restart "$UNIT_NAME")
    assert commands =~ ~s(if [ "$RESTART" -eq 1 ]; then\n    systemctl restart "$UNIT_NAME")
    assert commands =~ "--restart) RESTART=1"
    assert commands =~ ~s(UNIT_NAME="jukebox-power-controller.service")

    refute commands =~ "jukebox.env"
    refute commands =~ "shairport"
    refute commands =~ ~r/rm\s+-rf?\s/
    refute commands =~ "/run/jukebox"
    refute commands =~ ~r/systemctl\s+\S+\s+jukebox(\.service)?\b(?!-power)/
  end

  test "the unit runs the installed program as a watched service" do
    unit = File.read!(Path.join(@root, "ops/hardware/jukebox-power-controller.service"))

    assert unit =~
             "ExecStart=/usr/bin/python3 -u /usr/local/sbin/jukebox-power-controller.py --daemon"

    assert unit =~ "Type=notify"
    assert unit =~ "WatchdogSec="
    assert unit =~ "Restart=always"
    assert unit =~ "RuntimeDirectory=jukebox-power"
    # The Power button does not depend on the application or the browser.
    refute unit =~ ~r/^(Requires|After|BindsTo|PartOf)=.*jukebox\.service/m
    # Root: no User= line hands the GPIO to the application's account.
    refute unit =~ ~r/^User=/m
    # The application's environment file is not read as root.
    refute unit =~ "EnvironmentFile"
  end
end
