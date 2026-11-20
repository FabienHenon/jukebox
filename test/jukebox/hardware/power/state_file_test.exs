defmodule Jukebox.Hardware.Power.StateFileTest do
  use ExUnit.Case, async: true

  alias Jukebox.Hardware.Power.StateFile

  @moduletag :tmp_dir

  @now 5_000.0

  setup %{tmp_dir: tmp} do
    dir = Path.join(tmp, "jukebox-power")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o750)
    path = Path.join(dir, "state.json")
    # In production the owner is root; here it is whoever runs the tests.
    {:ok, %File.Stat{uid: uid}} = File.stat(dir)
    {:ok, dir: dir, path: path, opts: [owner_uid: uid, uptime: fn -> {:ok, @now} end]}
  end

  defp document(changes \\ %{}) do
    Map.merge(
      %{
        "schema" => 1,
        "instance" => "abc123",
        "revision" => 12,
        "heartbeat" => 3401,
        "boottime" => @now - 0.4,
        "pid" => 431,
        "mode" => "awake",
        "outputs" => %{
          "amp" => %{"gpio" => 17, "requested" => true, "applied" => true},
          "disco" => %{"gpio" => 27, "requested" => true, "applied" => true},
          "strip" => %{"gpio" => 22, "requested" => false, "applied" => false},
          "decor" => %{"gpio" => 23, "requested" => false, "applied" => false},
          "extra" => %{"gpio" => 24, "requested" => false, "applied" => false}
        }
      },
      changes
    )
  end

  defp publish(path, content, mode \\ 0o640) do
    content = if is_binary(content), do: content, else: Jason.encode!(content)
    File.write!(path, content)
    File.chmod!(path, mode)
  end

  test "reads a fresh, well-formed state", %{path: path, opts: opts} do
    publish(path, document())

    assert {:ok, state} = StateFile.read(path, opts)
    assert state.mode == :awake
    assert state.instance == "abc123"
    assert state.revision == 12
    assert state.pid == 431
    assert state.age_ms == 400
    assert state.outputs.disco == %{requested: true, applied: true, gpio: 27}
    assert state.outputs.strip == %{requested: false, applied: false, gpio: 22}
  end

  test "every mode of the controller is understood", %{path: path, opts: opts} do
    for {text, mode} <- [
          {"booting", :booting},
          {"awake", :awake},
          {"standby", :standby},
          {"shutting_down", :shutting_down}
        ] do
      publish(path, document(%{"mode" => text}))
      assert {:ok, %{mode: ^mode}} = StateFile.read(path, opts)
    end
  end

  test "a state older than three seconds is stale", %{path: path, opts: opts} do
    publish(path, document(%{"boottime" => @now - 2.9}))
    assert {:ok, %{age_ms: 2900}} = StateFile.read(path, opts)

    publish(path, document(%{"boottime" => @now - 3.2}))
    assert StateFile.read(path, opts) == {:error, :stale}

    # A heartbeat from a clock ahead of ours cannot be a live one either.
    publish(path, document(%{"boottime" => @now + 60}))
    assert StateFile.read(path, opts) == {:error, :stale}
  end

  test "without a usable clock nothing is assumed fresh", %{path: path, opts: opts} do
    publish(path, document())

    assert StateFile.read(path, Keyword.put(opts, :uptime, fn -> :error end)) ==
             {:error, :clock_unavailable}
  end

  test "a missing file or directory is reported as missing", %{path: path, dir: dir, opts: opts} do
    assert StateFile.read(path, opts) == {:error, :missing}
    assert StateFile.read(Path.join([dir, "nowhere", "state.json"]), opts) == {:error, :missing}
  end

  test "a file or directory with the wrong owner is refused", %{path: path, opts: opts} do
    publish(path, document())
    # Production expects root (uid 0); this file belongs to the test's user.
    refute opts[:owner_uid] == 0
    assert StateFile.read(path, Keyword.delete(opts, :owner_uid)) == {:error, :unsafe_ownership}
  end

  test "a file or directory that others may write is refused", %{path: path, dir: dir, opts: opts} do
    publish(path, document(), 0o660)
    assert StateFile.read(path, opts) == {:error, :unsafe_permissions}

    publish(path, document(), 0o642)
    assert StateFile.read(path, opts) == {:error, :unsafe_permissions}

    publish(path, document())
    File.chmod!(dir, 0o770)
    assert StateFile.read(path, opts) == {:error, :unsafe_permissions}
    File.chmod!(dir, 0o750)
    assert {:ok, _state} = StateFile.read(path, opts)
  end

  test "a symbolic link is not followed", %{path: path, dir: dir, opts: opts} do
    real = Path.join(dir, "elsewhere.json")
    publish(real, document())
    File.ln_s!(real, path)
    assert StateFile.read(path, opts) == {:error, :not_a_regular_file}
  end

  test "an unknown schema is refused rather than interpreted", %{path: path, opts: opts} do
    publish(path, document(%{"schema" => 2}))
    assert StateFile.read(path, opts) == {:error, :unsupported_schema}
  end

  test "malformed documents are refused", %{path: path, opts: opts} do
    broken = [
      "",
      "not json",
      "[]",
      Jason.encode!(Map.delete(document(), "mode")),
      Jason.encode!(Map.delete(document(), "boottime")),
      Jason.encode!(document(%{"mode" => "partying"})),
      Jason.encode!(document(%{"revision" => "12"})),
      Jason.encode!(document(%{"instance" => ""})),
      Jason.encode!(document(%{"outputs" => []})),
      Jason.encode!(
        document(%{"outputs" => %{"disco" => %{"requested" => "yes", "applied" => true}}})
      ),
      Jason.encode!(document(%{"outputs" => %{"disco" => %{"requested" => true}}}))
    ]

    for content <- broken do
      publish(path, content)
      assert StateFile.read(path, opts) == {:error, :malformed}, content
    end

    publish(path, String.duplicate(" ", 9_000) <> Jason.encode!(document()))
    assert StateFile.read(path, opts) == {:error, :too_large}
  end

  test "outputs added by a newer controller are ignored", %{path: path, opts: opts} do
    outputs = Map.put(document()["outputs"], "fog", %{"requested" => true, "applied" => true})
    publish(path, document(%{"outputs" => outputs}))
    assert {:ok, state} = StateFile.read(path, opts)
    assert Map.keys(state.outputs) |> Enum.sort() == [:amp, :decor, :disco, :extra, :strip]
  end

  test "the document written by the controller itself is accepted", %{path: path, opts: opts} do
    python = System.find_executable("python3")

    if python do
      program = Path.expand("../../../../ops/hardware/jukebox-power-controller.py", __DIR__)

      code = """
      import importlib.util, json, sys
      spec = importlib.util.spec_from_file_location("pc", sys.argv[1])
      pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)
      class Hw:
          levels = {}
          def get(self, name): return self.levels.get(name, False)
          def set(self, name, level): self.levels[name] = level
      class Display:
          def set(self, on): pass
      controller = pc.Controller(Hw(), lambda state: None, Display(), lambda: None)
      controller.start(0.0)
      controller.command(["disco", "on"], 0.1, "r1")
      state = controller.state()
      state["boottime"] = float(sys.argv[3])
      pc.write_state(sys.argv[2], state)
      """

      {_output, 0} =
        System.cmd(python, ["-c", code, program, path, "#{@now - 0.1}"],
          env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
        )

      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o640
      assert {:ok, state} = StateFile.read(path, opts)
      assert state.mode == :awake
      assert state.outputs.disco == %{requested: true, applied: true, gpio: 27}
      assert state.outputs.amp.requested
      refute state.outputs.amp.applied
    end
  end
end
