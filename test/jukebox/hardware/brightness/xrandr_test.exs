defmodule Jukebox.Hardware.Brightness.XrandrTest do
  use ExUnit.Case, async: true

  import Jukebox.Test.HardwareHelpers

  alias Jukebox.Hardware.Brightness.Xrandr

  @moduletag :tmp_dir

  # Shaped like `LC_ALL=C xrandr --verbose` on a KMS driver: the kiosk's
  # output, dimmed, and a second connector with nothing on it.
  @verbose """
  Screen 0: minimum 320 x 200, current 1280 x 1024, maximum 2048 x 2048
  HDMI-1 connected primary 1280x1024+0+0 (0x45) normal (normal left inverted right x axis y axis) 338mm x 270mm
  \tIdentifier: 0x42
  \tTimestamp:  20541
  \tSubpixel:   unknown
  \tGamma:      1.0:1.0:1.0
  \tBrightness: 0.70
  \tClones:    
  \tCRTC:       0
  \tCRTCs:      0 1 2
  \tTransform:  1.000000 0.000000 0.000000
  \t            0.000000 1.000000 0.000000
  \t            0.000000 0.000000 1.000000
  \t           filter: 
  \tEDID: 
  \t\t00ffffffffffff000472ad0000000000
  \t\t2d12010368221b78ea5ec5a4554e9b26
  \tnon-desktop: 0 
  \t\trange: (0, 1)
    1280x1024 (0x45) 108.000MHz +HSync +VSync *current +preferred
          h: width  1280 start 1328 end 1440 total 1688 skew    0 clock  63.98KHz
          v: height 1024 start 1025 end 1028 total 1066           clock  60.02Hz
    1024x768 (0x46) 65.000MHz -HSync -VSync
          h: width  1024 start 1048 end 1184 total 1344 skew    0 clock  48.36KHz
          v: height  768 start  771 end  777 total  806           clock  60.00Hz
  HDMI-2 disconnected (normal left inverted right x axis y axis)
  \tIdentifier: 0x43
  \tTimestamp:  20541
  \tSubpixel:   unknown
  \tClones:    
  \tCRTCs:      0 1 2
  """

  describe "parse_verbose/2" do
    test "the brightness of the selected, active output" do
      assert Xrandr.parse_verbose(@verbose, "HDMI-1") == {:ok, 700}
    end

    test "other ways xrandr writes a coefficient" do
      for {text, expected} <- [
            {"1.0", 1000},
            {"0.30", 300},
            {"0.5", 500},
            {"1", 1000},
            {"0.69", 690},
            {"0.0", 0}
          ] do
        verbose = String.replace(@verbose, "Brightness: 0.70", "Brightness: #{text}")
        assert Xrandr.parse_verbose(verbose, "HDMI-1") == {:ok, expected}, text
      end
    end

    test "the value is taken from the selected output's block only" do
      two =
        @verbose <>
          """
          VGA-1 connected 1024x768+1280+0 (0x46) normal (normal left inverted right x axis y axis) 300mm x 230mm
          \tIdentifier: 0x44
          \tGamma:      1.0:1.0:1.0
          \tBrightness: 0.40
          \tCRTC:       1
          HDMI-10 connected 800x600+0+0 (0x47) normal (normal left inverted right x axis y axis) 0mm x 0mm
          \tBrightness: 0.20
          """

      assert Xrandr.parse_verbose(two, "HDMI-1") == {:ok, 700}
      assert Xrandr.parse_verbose(two, "VGA-1") == {:ok, 400}
      # A name that merely starts the same is another output.
      assert Xrandr.parse_verbose(two, "HDMI-10") == {:ok, 200}
      assert Xrandr.parse_verbose(two, "HDMI") == {:error, :output_missing}
      assert Xrandr.parse_verbose(two, "VGA") == {:error, :output_missing}
    end

    test "an output that is not there, not connected or switched off is not usable" do
      assert Xrandr.parse_verbose(@verbose, "DP-1") == {:error, :output_missing}
      assert Xrandr.parse_verbose(@verbose, "Screen") == {:error, :output_missing}
      assert Xrandr.parse_verbose("", "HDMI-1") == {:error, :output_missing}
      # The DRM connector name is not an xrandr output name.
      assert Xrandr.parse_verbose(@verbose, "card0-HDMI-A-1") == {:error, :output_missing}

      assert Xrandr.parse_verbose(@verbose, "HDMI-2") == {:error, :output_inactive}

      # Connected, but with no mode set (xrandr --off): no geometry on the line.
      off =
        String.replace(
          @verbose,
          "HDMI-1 connected primary 1280x1024+0+0 (0x45) normal (normal left inverted right x axis y axis) 338mm x 270mm",
          "HDMI-1 connected primary (normal left inverted right x axis y axis)"
        )

      assert Xrandr.parse_verbose(off, "HDMI-1") == {:error, :output_inactive}

      unknown = String.replace(@verbose, "HDMI-1 connected primary", "HDMI-1 unknown connection")
      assert Xrandr.parse_verbose(unknown, "HDMI-1") == {:error, :output_inactive}
    end

    test "a block without one readable Brightness line is malformed, never a guess" do
      for replacement <- [
            "Brightness: ",
            "Brightness: bright",
            "Brightness: nan",
            "Brightness: inf",
            "Brightness: -0.5",
            "Brightness: 0.7 0.8",
            "Brightness: 0.70\n\tBrightness: 0.90",
            "Luminosity: 0.70"
          ] do
        verbose = String.replace(@verbose, "Brightness: 0.70", replacement)
        assert Xrandr.parse_verbose(verbose, "HDMI-1") == {:error, :malformed_reply}, replacement
      end

      # Cut off before the line.
      [head | _rest] = String.split(@verbose, "\tBrightness")
      assert Xrandr.parse_verbose(head, "HDMI-1") == {:error, :malformed_reply}

      # The Brightness line of the next output does not fill the gap.
      shifted =
        @verbose
        |> String.replace("\tBrightness: 0.70\n", "")
        |> String.replace("HDMI-2 disconnected", "HDMI-2 connected 800x600+0+0")
        |> Kernel.<>("\tBrightness: 0.50\n")

      assert Xrandr.parse_verbose(shifted, "HDMI-1") == {:error, :malformed_reply}
      assert Xrandr.parse_verbose(shifted, "HDMI-2") == {:ok, 500}
    end
  end

  describe "what is run" do
    test "a change is the output and its brightness, and nothing else" do
      assert Xrandr.set_arguments("HDMI-1", 700) == ["--output", "HDMI-1", "--brightness", "0.7"]
      assert Xrandr.set_arguments("HDMI-1", 1000) == ["--output", "HDMI-1", "--brightness", "1.0"]
      assert Xrandr.set_arguments("HDMI-1", 300) == ["--output", "HDMI-1", "--brightness", "0.3"]
      assert Xrandr.set_arguments("HDMI-1", 750) == ["--output", "HDMI-1", "--brightness", "0.75"]

      assert Xrandr.set_arguments("HDMI-1", 125) == [
               "--output",
               "HDMI-1",
               "--brightness",
               "0.125"
             ]
    end

    test "the environment comes from the configuration, in the C locale" do
      assert Xrandr.environment(display: ":0", xauthority: "/home/jukebox/.Xauthority") == [
               {"DISPLAY", ":0"},
               {"XAUTHORITY", "/home/jukebox/.Xauthority"},
               {"LC_ALL", "C"}
             ]
    end

    test "the module names no command that changes anything but the gamma ramp" do
      source = File.read!("lib/jukebox/hardware/brightness/xrandr.ex")
      [_doc, code] = String.split(source, "@behaviour", parts: 2)

      for forbidden <-
            ~w(--off --auto --mode --rate --pos --rotate --primary --gamma --scale dpms sudo xhost xset ddcutil sh\ -c) do
        refute code =~ forbidden, "#{forbidden} appears in the xrandr backend"
      end

      assert code =~ ~s(@executable "/usr/bin/xrandr")
    end
  end

  describe "with a stand-in xrandr" do
    setup %{tmp_dir: dir} do
      authority = Path.join(dir, "Xauthority")
      File.write!(authority, "cookie")
      {:ok, dir: dir, authority: authority}
    end

    # Behaves like xrandr for one output: keeps the coefficient in a file,
    # prints a --verbose listing, and logs its arguments and environment.
    defp fake_xrandr(dir, extra \\ "") do
      File.write!(Path.join(dir, "value"), "1.0")

      script!(dir, "xrandr", """
      printf 'DISPLAY=%s XAUTHORITY=%s LC_ALL=%s ARGC=%s ARGS=%s\\n' "$DISPLAY" "$XAUTHORITY" "$LC_ALL" "$#" "$*" >> #{dir}/calls
      #{extra}
      if [ "$1" = "--verbose" ]; then
        printf 'Screen 0: minimum 320 x 200, current 1280 x 1024, maximum 2048 x 2048\\n'
        printf 'HDMI-1 connected primary 1280x1024+0+0 (0x45) normal (normal left) 338mm x 270mm\\n'
        printf '\\tGamma:      1.0:1.0:1.0\\n\\tBrightness: %s\\n\\tCRTC:       0\\n' "$(cat #{dir}/value)"
        printf 'HDMI-2 disconnected (normal left inverted right x axis y axis)\\n'
      elif [ "$1" = "--output" ] && [ "$2" = "HDMI-1" ] && [ "$3" = "--brightness" ]; then
        echo "$4" > #{dir}/value
      elif [ "$1" = "--output" ]; then
        echo "warning: output $2 not found; ignoring" >&2
      else
        exit 64
      fi
      """)
    end

    defp opts(context, executable, extra \\ []) do
      Keyword.merge(
        [
          executable: executable,
          output: "HDMI-1",
          display: ":0",
          xauthority: context.authority,
          timeout_ms: 2_000
        ],
        extra
      )
    end

    defp calls(dir),
      do: dir |> Path.join("calls") |> File.read!() |> String.split("\n", trim: true)

    test "reads, sets and reads back with exactly these arguments and this environment",
         context do
      xrandr = fake_xrandr(context.dir)

      assert Xrandr.query(opts(context, xrandr)) == {:ok, 1000}
      assert Xrandr.set(700, opts(context, xrandr)) == :ok
      assert Xrandr.query(opts(context, xrandr)) == {:ok, 700}

      env = "DISPLAY=:0 XAUTHORITY=#{context.authority} LC_ALL=C"

      assert calls(context.dir) == [
               "#{env} ARGC=1 ARGS=--verbose",
               "#{env} ARGC=4 ARGS=--output HDMI-1 --brightness 0.7",
               "#{env} ARGC=1 ARGS=--verbose"
             ]
    end

    test "the display and the authority file given are the ones used, whatever the service inherited",
         context do
      xrandr = fake_xrandr(context.dir)
      System.put_env("DISPLAY", ":77")
      on_exit(fn -> System.delete_env("DISPLAY") end)

      assert {:ok, 1000} = Xrandr.query(opts(context, xrandr, display: ":1"))
      assert hd(calls(context.dir)) =~ "DISPLAY=:1 "
    end

    test "nothing goes through a shell", context do
      xrandr = fake_xrandr(context.dir)
      marker = Path.join(context.dir, "created")
      hostile = "HDMI-1; touch #{marker}"

      # The configuration refuses such a name; even if one got here it would
      # reach xrandr as a single argument.
      assert Xrandr.set(700, opts(context, xrandr, output: hostile)) == {:error, :output_missing}
      refute File.exists?(marker)
      assert List.last(calls(context.dir)) =~ "ARGC=4 ARGS=--output #{hostile} --brightness 0.7"
    end

    test "an output xrandr does not know is an error although xrandr exits 0", context do
      xrandr = fake_xrandr(context.dir)
      wrong = opts(context, xrandr, output: "HDMI-3")

      assert Xrandr.query(wrong) == {:error, :output_missing}
      assert Xrandr.set(700, wrong) == {:error, :output_missing}
      assert Xrandr.query(opts(context, xrandr, output: "HDMI-2")) == {:error, :output_inactive}
      assert File.read!(Path.join(context.dir, "value")) == "1.0"
    end

    test "X not started, X refusing the authority, and other failures are told apart", context do
      down = script!(context.dir, "down", "echo \"Can't open display :0\" >&2; exit 1")
      assert Xrandr.query(opts(context, down)) == {:error, :x11_unavailable}
      assert Xrandr.set(700, opts(context, down)) == {:error, :x11_unavailable}

      refused =
        script!(
          context.dir,
          "refused",
          "echo 'Authorization required, but no authorization protocol specified' >&2; echo \"Can't open display :0\" >&2; exit 1"
        )

      assert Xrandr.query(opts(context, refused)) == {:error, :x11_unauthorized}

      cookie =
        script!(
          context.dir,
          "cookie",
          "echo 'Invalid MIT-MAGIC-COOKIE-1 key' >&2; echo \"Can't open display :0\" >&2; exit 1"
        )

      assert Xrandr.query(opts(context, cookie)) == {:error, :x11_unauthorized}

      broken =
        script!(context.dir, "broken", "echo 'xrandr: Configure crtc 0 failed' >&2; exit 1")

      assert Xrandr.set(700, opts(context, broken)) == {:error, {:command_failed, 1}}

      garbage =
        script!(
          context.dir,
          "garbage",
          "echo 'HDMI-1 connected 1280x1024+0+0'; echo '  nothing useful'"
        )

      assert Xrandr.query(opts(context, garbage)) == {:error, :malformed_reply}
    end

    test "xrandr not installed", context do
      absent = Path.join(context.dir, "absent")
      assert Xrandr.query(opts(context, absent)) == {:error, :xrandr_missing}
      assert Xrandr.set(700, opts(context, absent)) == {:error, :xrandr_missing}
    end

    test "a missing or unreadable authority file is named, and xrandr is not even run", context do
      xrandr = fake_xrandr(context.dir)
      missing = opts(context, xrandr, xauthority: Path.join(context.dir, "nowhere/.Xauthority"))

      assert Xrandr.query(missing) == {:error, :xauthority_missing}
      assert Xrandr.set(700, missing) == {:error, :xauthority_missing}

      File.chmod!(context.authority, 0o000)
      on_exit(fn -> File.chmod(context.authority, 0o600) end)
      assert Xrandr.query(opts(context, xrandr)) == {:error, :xauthority_unreadable}

      assert Xrandr.query(opts(context, xrandr, xauthority: context.dir)) ==
               {:error, :xauthority_unreadable}

      refute File.exists?(Path.join(context.dir, "calls"))
    end

    test "a hanging xrandr is killed at the deadline, for a query and for a change", context do
      pid_file = Path.join(context.dir, "pid")
      hang = script!(context.dir, "hang", "echo $$ > #{pid_file}\nexec sleep 30")

      for call <- [&Xrandr.query/1, &Xrandr.set(700, &1)] do
        started = System.monotonic_time(:millisecond)
        assert call.(opts(context, hang, timeout_ms: 250)) == {:error, :timeout}
        assert System.monotonic_time(:millisecond) - started < 2_500

        os_pid = pid_file |> File.read!() |> String.trim()
        eventually(fn -> not os_process_alive?(os_pid) end)
      end
    end
  end
end
