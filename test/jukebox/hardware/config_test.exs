defmodule Jukebox.Hardware.ConfigTest do
  use ExUnit.Case, async: true

  alias Jukebox.Hardware.Config

  @device "/dev/input/by-id/usb-Example_Encoder-event-joystick"

  @xrandr_env %{
    "JUKEBOX_BRIGHTNESS_BACKEND" => "xrandr",
    "JUKEBOX_XRANDR_OUTPUT" => "HDMI-1",
    "JUKEBOX_X11_DISPLAY" => ":0",
    "JUKEBOX_X11_XAUTHORITY" => "/home/jukebox/.Xauthority"
  }

  defp enabled(extra \\ %{}) do
    Map.merge(
      %{
        "JUKEBOX_BUTTONS_ENABLED" => "true",
        "JUKEBOX_BUTTONS_SOURCE" => "evdev",
        "JUKEBOX_BUTTONS_DEVICE" => @device
      },
      extra
    )
  end

  describe "defaults" do
    test "an empty environment is safe: nothing enabled, nothing guessed" do
      config = Config.from_env(%{})

      assert config.buttons.status == :disabled
      assert config.buttons.mapping == %{}
      assert config.brightness.status == :disabled
      assert config.brightness.backend == :disabled
      assert config.strip == %{status: :enabled, control: :power, wled_url: nil, errors: []}
      assert config.power.client == "/usr/local/sbin/jukebox-power-controller.py"
      assert config.power.state_file == "/run/jukebox-power/state.json"
      assert config.power.source == :controller
      assert Config.errors(config) == []
    end

    test "the example file: buttons off, and the measured xrandr setup with a neutral start" do
      env =
        "ops/jukebox.env.example"
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
        |> Map.new(fn line ->
          [name, value] = String.split(line, "=", parts: 2)
          {name, value}
        end)

      for name <-
            [
              "JUKEBOX_BUTTONS_ENABLED",
              "JUKEBOX_BRIGHTNESS_BACKEND",
              "JUKEBOX_XRANDR_OUTPUT",
              "JUKEBOX_X11_DISPLAY",
              "JUKEBOX_X11_XAUTHORITY",
              "JUKEBOX_BRIGHTNESS_MIN",
              "JUKEBOX_BRIGHTNESS_MAX",
              "JUKEBOX_BRIGHTNESS_STEP",
              "JUKEBOX_BRIGHTNESS_DEFAULT",
              "JUKEBOX_BRIGHTNESS_TIMEOUT_MS",
              "JUKEBOX_STRIP_CONTROL"
            ] ++
              Enum.map(Config.actions(), &Config.button_variable/1) do
        assert Map.has_key?(env, name), "#{name} is missing from ops/jukebox.env.example"
      end

      # The variables of the former DDC backend are gone from the example.
      refute Enum.any?(Map.keys(env), &String.starts_with?(&1, "JUKEBOX_DDC_"))
      refute File.read!("ops/jukebox.env.example") =~ "ddcutil"

      config = Config.from_env(env)
      assert Config.errors(config) == []
      assert config.buttons.status == :disabled
      assert config.buttons.mapping == %{}
      assert config.strip.control == :power

      assert config.brightness == %{
               status: :enabled,
               backend: :xrandr,
               output: "HDMI-1",
               display: ":0",
               xauthority: "/home/jukebox/.Xauthority",
               min: 300,
               max: 1000,
               step: 100,
               default: 1000,
               timeout_ms: 3000,
               errors: [],
               notices: []
             }
    end

    test "a variable left empty means its default" do
      config =
        Config.from_env(
          enabled(%{"JUKEBOX_BUTTONS_DEBOUNCE_MS" => "", "JUKEBOX_BUTTONS_DEBUG" => ""})
        )

      assert config.buttons.status == :enabled
      assert config.buttons.debounce_ms == 80
      refute config.buttons.debug?
    end
  end

  describe "buttons" do
    test "decimal codes are mapped and blank ones stay unassigned" do
      config =
        Config.from_env(
          enabled(%{
            "JUKEBOX_BUTTON_PREVIOUS" => "304",
            "JUKEBOX_BUTTON_NEXT" => " 306 ",
            "JUKEBOX_BUTTON_PLAY_PAUSE" => "",
            "JUKEBOX_BUTTON_BRIGHTNESS_UP" => "0"
          })
        )

      assert config.buttons.status == :enabled
      assert config.buttons.source == :evdev
      assert config.buttons.device == @device
      assert config.buttons.mapping == %{304 => :previous, 306 => :next, 0 => :brightness_up}

      assert Config.describe(config).buttons.mapping == %{
               previous: 304,
               play_pause: nil,
               next: 306,
               disco_toggle: nil,
               strip_toggle: nil,
               animation_next: nil,
               brightness_down: nil,
               brightness_up: 0
             }
    end

    test "enabled with no mapping at all is valid (commissioning)" do
      config = Config.from_env(enabled())
      assert config.buttons.status == :enabled
      assert config.buttons.mapping == %{}
    end

    test "only decimal integers are accepted as codes" do
      for bad <- ["0x130", "BTN_SOUTH", "304.0", "-1", "+304", "3 04", "30400", "768"] do
        config = Config.from_env(enabled(%{"JUKEBOX_BUTTON_NEXT" => bad}))
        assert config.buttons.status == :error, "#{inspect(bad)} was accepted"
        assert [error] = config.buttons.errors
        assert error =~ "JUKEBOX_BUTTON_NEXT"
        assert config.buttons.mapping == %{}, "no partial mapping survives an error"
      end
    end

    test "a code assigned to two actions disables the buttons and names both variables" do
      config =
        Config.from_env(
          enabled(%{
            "JUKEBOX_BUTTON_PREVIOUS" => "304",
            "JUKEBOX_BUTTON_NEXT" => "305",
            "JUKEBOX_BUTTON_DISCO_TOGGLE" => "304"
          })
        )

      assert config.buttons.status == :error
      assert [error] = config.buttons.errors
      assert error =~ "304"
      assert error =~ "JUKEBOX_BUTTON_PREVIOUS"
      assert error =~ "JUKEBOX_BUTTON_DISCO_TOGGLE"
      assert config.buttons.mapping == %{}
    end

    test "the device must be an explicit stable path under /dev/input" do
      for {bad, hint} <- [
            {"", "is empty"},
            {"/dev/input/event0", "changes between boots"},
            {"/dev/input/js0", "changes between boots"},
            {"/dev/input/mice", "changes between boots"},
            {"/dev/hidraw0", "under /dev/input/"},
            {"by-id/encoder", "under /dev/input/"},
            {"/dev/input/by-id/../event3", "under /dev/input/"}
          ] do
        config = Config.from_env(enabled(%{"JUKEBOX_BUTTONS_DEVICE" => bad}))
        assert config.buttons.status == :error, "#{inspect(bad)} was accepted"
        assert Enum.any?(config.buttons.errors, &(&1 =~ hint)), inspect(config.buttons.errors)
      end

      for good <- [
            @device,
            "/dev/input/by-path/platform-3f980000.usb-usb-0:1.2:1.0-event-joystick",
            "/dev/input/jukebox-buttons"
          ] do
        assert Config.from_env(enabled(%{"JUKEBOX_BUTTONS_DEVICE" => good})).buttons.device ==
                 good
      end
    end

    test "the simulated source exists only where it was allowed" do
      env = %{"JUKEBOX_BUTTONS_ENABLED" => "true", "JUKEBOX_BUTTONS_SOURCE" => "simulated"}

      refused = Config.from_env(env)
      assert refused.buttons.status == :error
      assert hd(refused.buttons.errors) =~ "development and tests only"

      allowed = Config.from_env(env, allow_simulated: true)
      assert allowed.buttons.status == :enabled
      assert allowed.buttons.source == :simulated
    end

    test "invalid booleans, sources and debounce values are errors, not defaults" do
      assert Config.from_env(%{"JUKEBOX_BUTTONS_ENABLED" => "maybe"}).buttons.status == :error

      for extra <- [
            %{"JUKEBOX_BUTTONS_SOURCE" => "gamepad"},
            %{"JUKEBOX_BUTTONS_DEBOUNCE_MS" => "fast"},
            %{"JUKEBOX_BUTTONS_DEBOUNCE_MS" => "5000"},
            %{"JUKEBOX_BUTTONS_DEBUG" => "2"}
          ] do
        assert Config.from_env(enabled(extra)).buttons.status == :error, inspect(extra)
      end
    end

    test "a button error leaves the other subsystems alone" do
      config =
        Config.from_env(Map.merge(@xrandr_env, enabled(%{"JUKEBOX_BUTTON_NEXT" => "x"})))

      assert config.buttons.status == :error
      assert config.brightness.status == :enabled
      assert config.strip.status == :enabled
      assert config.power.status == :enabled
      assert [error] = Config.errors(config)
      assert error =~ "buttons: JUKEBOX_BUTTON_NEXT"
    end
  end

  describe "brightness" do
    @xrandr @xrandr_env

    defp brightness(extra, opts \\ []),
      do: Config.from_env(Map.merge(@xrandr, extra), opts).brightness

    test "coefficients are decimals kept as exact thousandths" do
      assert %{status: :enabled, min: 300, max: 1000, step: 100, default: 1000, timeout_ms: 3000} =
               brightness(%{})

      assert %{status: :enabled, min: 250, max: 900, step: 50, default: 700} =
               brightness(%{
                 "JUKEBOX_BRIGHTNESS_MIN" => "0.25",
                 "JUKEBOX_BRIGHTNESS_MAX" => "0.9",
                 "JUKEBOX_BRIGHTNESS_STEP" => "0.05",
                 "JUKEBOX_BRIGHTNESS_DEFAULT" => "0.7"
               })

      assert %{status: :enabled, min: 125, max: 1000, default: 1000} =
               brightness(%{"JUKEBOX_BRIGHTNESS_MIN" => "0.125", "JUKEBOX_BRIGHTNESS_MAX" => "1"})

      assert Config.format_coefficient(700) == "0.7"
      assert Config.format_coefficient(1000) == "1.0"
      assert Config.format_coefficient(125) == "0.125"
      assert Config.to_float(300) == 0.3
    end

    test "the description shows them as the decimals that were written" do
      described = Config.describe(Config.from_env(@xrandr)).brightness

      assert %{min: 0.3, max: 1.0, step: 0.1, default: 1.0, output: "HDMI-1", display: ":0"} =
               described
    end

    test "zero, negatives, NaN, infinity, exponents and the old percentages are refused" do
      for name <- [
            "JUKEBOX_BRIGHTNESS_MIN",
            "JUKEBOX_BRIGHTNESS_MAX",
            "JUKEBOX_BRIGHTNESS_STEP",
            "JUKEBOX_BRIGHTNESS_DEFAULT"
          ],
          bad <- [
            "0",
            "0.0",
            "0.000",
            "-0.5",
            "-1",
            "NaN",
            "nan",
            "Infinity",
            "inf",
            "-inf",
            "1e0",
            "1e-1",
            "0x1",
            ".5",
            "1.",
            "0,7",
            "70%",
            "0.7 0.8",
            "0.1234"
          ] do
        config = brightness(%{name => bad})
        assert config.status == :error, "#{name}=#{bad} was accepted"
        assert Enum.any?(config.errors, &(&1 =~ name)), inspect(config.errors)
      end

      # The values of the former DDC block: percentages.
      for {name, old} <- [
            {"JUKEBOX_BRIGHTNESS_MIN", "10"},
            {"JUKEBOX_BRIGHTNESS_MAX", "100"},
            {"JUKEBOX_BRIGHTNESS_STEP", "5"},
            {"JUKEBOX_BRIGHTNESS_DEFAULT", "1.5"}
          ] do
        config = brightness(%{name => old})
        assert config.status == :error, "#{name}=#{old} was accepted"

        assert Enum.any?(config.errors, &(&1 =~ "not a percentage any more")),
               inspect(config.errors)
      end
    end

    test "0 < min < max <= 1, min <= default <= max, 0 < step <= max - min" do
      for {extra, expect} <- [
            {%{"JUKEBOX_BRIGHTNESS_MIN" => "0.001", "JUKEBOX_BRIGHTNESS_MAX" => "1.0"}, :enabled},
            {%{
               "JUKEBOX_BRIGHTNESS_MIN" => "0.5",
               "JUKEBOX_BRIGHTNESS_MAX" => "0.6",
               "JUKEBOX_BRIGHTNESS_DEFAULT" => "0.6"
             }, :enabled},
            {%{
               "JUKEBOX_BRIGHTNESS_MIN" => "0.5",
               "JUKEBOX_BRIGHTNESS_MAX" => "0.5",
               "JUKEBOX_BRIGHTNESS_DEFAULT" => "0.5"
             }, :error},
            {%{
               "JUKEBOX_BRIGHTNESS_MIN" => "0.8",
               "JUKEBOX_BRIGHTNESS_MAX" => "0.4",
               "JUKEBOX_BRIGHTNESS_DEFAULT" => "0.5"
             }, :error},
            {%{"JUKEBOX_BRIGHTNESS_DEFAULT" => "0.2"}, :error},
            {%{"JUKEBOX_BRIGHTNESS_MAX" => "0.8"}, :error},
            {%{"JUKEBOX_BRIGHTNESS_MAX" => "0.8", "JUKEBOX_BRIGHTNESS_DEFAULT" => "0.8"},
             :enabled},
            {%{"JUKEBOX_BRIGHTNESS_STEP" => "0.7"}, :enabled},
            {%{"JUKEBOX_BRIGHTNESS_STEP" => "0.8"}, :error},
            {%{"JUKEBOX_BRIGHTNESS_TIMEOUT_MS" => "0"}, :error},
            {%{"JUKEBOX_BRIGHTNESS_TIMEOUT_MS" => "soon"}, :error},
            {%{"JUKEBOX_BRIGHTNESS_TIMEOUT_MS" => "500"}, :enabled}
          ] do
        assert brightness(extra).status == expect, inspect(extra)
      end

      assert [error] = brightness(%{"JUKEBOX_BRIGHTNESS_DEFAULT" => "0.2"}).errors
      assert error =~ "JUKEBOX_BRIGHTNESS_DEFAULT (0.2) must lie between"
      assert [error] = brightness(%{"JUKEBOX_BRIGHTNESS_STEP" => "0.8"}).errors
      assert error =~ "must not exceed"
    end

    test "the output, the display and the authority file are explicit; none is guessed" do
      for missing <- ["JUKEBOX_XRANDR_OUTPUT", "JUKEBOX_X11_DISPLAY", "JUKEBOX_X11_XAUTHORITY"] do
        config = Config.from_env(Map.delete(@xrandr, missing)).brightness
        assert config.status == :error, "worked without #{missing}"
        assert [error] = config.errors
        assert error =~ "#{missing} is empty"
      end

      for {name, bad} <- [
            {"JUKEBOX_XRANDR_OUTPUT", "--off"},
            {"JUKEBOX_XRANDR_OUTPUT", "-HDMI-1"},
            {"JUKEBOX_XRANDR_OUTPUT", "HDMI 1"},
            {"JUKEBOX_XRANDR_OUTPUT", "HDMI-1;reboot"},
            {"JUKEBOX_XRANDR_OUTPUT", "$(id)"},
            {"JUKEBOX_XRANDR_OUTPUT", String.duplicate("H", 40)},
            {"JUKEBOX_X11_DISPLAY", "0"},
            {"JUKEBOX_X11_DISPLAY", "localhost:0"},
            {"JUKEBOX_X11_DISPLAY", ":zero"},
            {"JUKEBOX_X11_DISPLAY", ":0 -ac"},
            {"JUKEBOX_X11_XAUTHORITY", ".Xauthority"},
            {"JUKEBOX_X11_XAUTHORITY", "~/.Xauthority"},
            {"JUKEBOX_X11_XAUTHORITY", "/home/jukebox/../root/.Xauthority"}
          ] do
        config = brightness(%{name => bad})
        assert config.status == :error, "#{name}=#{inspect(bad)} was accepted"
        assert Enum.any?(config.errors, &(&1 =~ name))
      end

      for {name, good} <- [
            {"JUKEBOX_XRANDR_OUTPUT", "HDMI-A-1"},
            {"JUKEBOX_XRANDR_OUTPUT", "VGA1"},
            {"JUKEBOX_XRANDR_OUTPUT", "DP-1.2"},
            {"JUKEBOX_X11_DISPLAY", ":1"},
            {"JUKEBOX_X11_DISPLAY", ":0.0"},
            {"JUKEBOX_X11_XAUTHORITY", "/run/user/1000/.Xauthority"}
          ] do
        assert brightness(%{name => good}).status == :enabled, "#{name}=#{good} was refused"
      end
    end

    test "a leftover ddcutil backend is refused with what to change" do
      config =
        Config.from_env(%{
          "JUKEBOX_BRIGHTNESS_BACKEND" => "ddcutil",
          "JUKEBOX_DDC_BUS" => "2",
          "JUKEBOX_BRIGHTNESS_MIN" => "10",
          "JUKEBOX_BRIGHTNESS_MAX" => "100",
          "JUKEBOX_BRIGHTNESS_STEP" => "5"
        })

      assert config.brightness.status == :error
      assert config.brightness.backend == nil
      assert [error] = config.brightness.errors

      for hint <- [
            "ddcutil is no longer supported",
            "JUKEBOX_BRIGHTNESS_BACKEND=xrandr",
            "JUKEBOX_XRANDR_OUTPUT",
            "JUKEBOX_X11_DISPLAY",
            "JUKEBOX_X11_XAUTHORITY",
            "0.3/1.0/0.1",
            "JUKEBOX_DDC_BUS",
            "JUKEBOX_BRIGHTNESS_TIMEOUT_MS",
            "docs/physical-controls.md"
          ] do
        assert error =~ hint, "the migration message does not mention #{hint}"
      end

      # Only the brightness is affected.
      assert config.buttons.status == :disabled
      assert config.strip.status == :enabled
    end

    test "old DDC variables beside a valid xrandr setup are ignored, and pointed out" do
      config = brightness(%{"JUKEBOX_DDC_BUS" => "2", "JUKEBOX_DDC_TIMEOUT_MS" => "3000"})
      assert config.status == :enabled

      assert config.notices == [
               "JUKEBOX_DDC_BUS is obsolete and ignored; remove it",
               "JUKEBOX_DDC_TIMEOUT_MS is obsolete and ignored; remove it"
             ]
    end

    test "the simulated backend exists only where it was allowed" do
      env = %{"JUKEBOX_BRIGHTNESS_BACKEND" => "simulated"}

      refused = Config.from_env(env).brightness
      assert refused.status == :error
      assert hd(refused.errors) =~ "development and tests only"

      assert %{status: :enabled, backend: :simulated, output: nil, display: nil} =
               Config.from_env(env, allow_simulated: true).brightness
    end

    test "an unknown backend is an error and never a DDC or CSS stand-in" do
      for other <- ["css", "ddc", "auto", "xrandr2"] do
        config = Config.from_env(Map.put(@xrandr, "JUKEBOX_BRIGHTNESS_BACKEND", other))
        assert config.brightness.status == :error
        assert config.brightness.backend == nil
      end
    end
  end

  describe "power and strip" do
    test "paths must be absolute" do
      config = Config.from_env(%{"JUKEBOX_POWER_CLIENT" => "jukebox-power-controller.py"})
      assert config.power.status == :error
      assert config.power.client == nil
    end

    test "wled needs a plain controller address and never falls back to power" do
      assert %{status: :enabled, control: :wled, wled_url: "http://192.168.1.50"} =
               Config.from_env(%{
                 "JUKEBOX_STRIP_CONTROL" => "wled",
                 "JUKEBOX_WLED_URL" => "http://192.168.1.50/"
               }).strip

      for bad <- [
            "",
            "192.168.1.50",
            "ftp://wled.local",
            "http://",
            "http://wled.local/json/state",
            "http://wled.local?x=1"
          ] do
        strip =
          Config.from_env(%{"JUKEBOX_STRIP_CONTROL" => "wled", "JUKEBOX_WLED_URL" => bad}).strip

        assert strip.status == :error, "#{inspect(bad)} was accepted"

        assert strip.control == :wled,
               "a bad address must not turn the strip back into a power toggle"
      end

      assert Config.from_env(%{"JUKEBOX_STRIP_CONTROL" => "pwm"}).strip.status == :error
    end

    test "credentials in the WLED address stay out of the description" do
      config =
        Config.from_env(%{
          "JUKEBOX_STRIP_CONTROL" => "wled",
          "JUKEBOX_WLED_URL" => "http://admin:hunter2@wled.local"
        })

      described = inspect(Config.describe(config))
      refute described =~ "hunter2"
      assert described =~ "http://wled.local"
    end
  end
end
