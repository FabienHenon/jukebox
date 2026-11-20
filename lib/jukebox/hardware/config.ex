defmodule Jukebox.Hardware.Config do
  @moduledoc """
  Parses the physical-controls environment (the `JUKEBOX_BUTTON*`,
  `JUKEBOX_BRIGHTNESS_*`, `JUKEBOX_XRANDR_OUTPUT`, `JUKEBOX_X11_*`, `JUKEBOX_POWER_*`,
  `JUKEBOX_STRIP_CONTROL` and `JUKEBOX_WLED_URL` variables, see
  `docs/physical-controls.md`).

  This is optional hardware: nothing here ever raises. A value that cannot be
  used switches off the subsystem it belongs to (and only that one) with a
  message saying which variable is wrong; it is never replaced by a guess.

  The raw strings are captured by `config/runtime.exs` when the release boots
  and parsed here when the hardware supervisor starts, so restarting the
  service is enough to apply a change.
  """

  @actions [
    :previous,
    :play_pause,
    :next,
    :disco_toggle,
    :strip_toggle,
    :animation_next,
    :brightness_down,
    :brightness_up
  ]

  # Linux KEY_MAX (include/uapi/linux/input-event-codes.h).
  @key_max 0x2FF

  @defaults %{
    "JUKEBOX_BUTTONS_ENABLED" => "false",
    "JUKEBOX_BUTTONS_SOURCE" => "evdev",
    "JUKEBOX_BUTTONS_DEBOUNCE_MS" => "80",
    "JUKEBOX_BUTTONS_DEBUG" => "false",
    "JUKEBOX_BRIGHTNESS_BACKEND" => "disabled",
    "JUKEBOX_BRIGHTNESS_MIN" => "0.3",
    "JUKEBOX_BRIGHTNESS_MAX" => "1.0",
    "JUKEBOX_BRIGHTNESS_STEP" => "0.1",
    "JUKEBOX_BRIGHTNESS_DEFAULT" => "1.0",
    "JUKEBOX_BRIGHTNESS_TIMEOUT_MS" => "3000",
    "JUKEBOX_POWER_CLIENT" => "/usr/local/sbin/jukebox-power-controller.py",
    "JUKEBOX_POWER_STATE_FILE" => "/run/jukebox-power/state.json",
    "JUKEBOX_STRIP_CONTROL" => "power"
  }

  defstruct buttons: nil, brightness: nil, power: nil, strip: nil

  @type action ::
          :previous
          | :play_pause
          | :next
          | :disco_toggle
          | :strip_toggle
          | :animation_next
          | :brightness_down
          | :brightness_up

  @type status :: :enabled | :disabled | :error

  @type buttons :: %{
          status: status(),
          source: :evdev | :simulated | nil,
          device: String.t() | nil,
          debounce_ms: non_neg_integer() | nil,
          debug?: boolean(),
          mapping: %{non_neg_integer() => action()},
          errors: [String.t()]
        }

  @typedoc """
  A brightness coefficient in thousandths: `700` is the `0.7` given to
  `xrandr --brightness`. Integers keep repeated steps exact (ten steps of 0.1
  from 0.3 land on 1.0, not on 0.9999999999999999).
  """
  @type coefficient :: 1..1000

  @type brightness :: %{
          status: status(),
          backend: :disabled | :xrandr | :simulated | nil,
          output: String.t() | nil,
          display: String.t() | nil,
          xauthority: String.t() | nil,
          min: coefficient() | nil,
          max: coefficient() | nil,
          step: coefficient() | nil,
          default: coefficient() | nil,
          timeout_ms: pos_integer() | nil,
          errors: [String.t()],
          notices: [String.t()]
        }

  @type power :: %{
          status: :enabled | :error,
          source: :controller | :simulated,
          client: String.t() | nil,
          state_file: String.t() | nil,
          errors: [String.t()]
        }

  @type strip :: %{
          status: :enabled | :error,
          control: :power | :wled | nil,
          wled_url: String.t() | nil,
          errors: [String.t()]
        }

  @type t :: %__MODULE__{
          buttons: buttons(),
          brightness: brightness(),
          power: power(),
          strip: strip()
        }

  @doc "The eight button actions, in the order of the specification."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc "Name of the variable that maps `action` to a key code."
  @spec button_variable(action()) :: String.t()
  def button_variable(action) when action in @actions do
    "JUKEBOX_BUTTON_" <> (action |> Atom.to_string() |> String.upcase())
  end

  @doc "The configuration built from the application environment."
  @spec load() :: t()
  def load do
    settings = Application.get_env(:jukebox, Jukebox.Hardware, [])

    from_env(Keyword.get(settings, :env, %{}),
      power: Keyword.get(settings, :power, :controller),
      allow_simulated: Keyword.get(settings, :allow_simulated, false)
    )
  end

  @doc """
  Parses a map of raw environment strings.

  Options:

    * `:power` - `:controller` (the state file of the power controller, the
      default) or `:simulated` (development and tests)
    * `:allow_simulated` - whether `JUKEBOX_BUTTONS_SOURCE=simulated` and
      `JUKEBOX_BRIGHTNESS_BACKEND=simulated` are accepted (development and
      tests only)
  """
  @spec from_env(%{optional(String.t()) => String.t()}, keyword()) :: t()
  def from_env(env, opts \\ []) when is_map(env) do
    %__MODULE__{
      buttons: buttons(env, Keyword.get(opts, :allow_simulated, false)),
      brightness: brightness(env, Keyword.get(opts, :allow_simulated, false)),
      power: power(env, Keyword.get(opts, :power, :controller)),
      strip: strip(env)
    }
  end

  @doc """
  The effective configuration as plain data, safe to show: no secret is read
  by this module in the first place, and credentials that someone put in the
  WLED address are removed.
  """
  @spec describe(t()) :: map()
  def describe(%__MODULE__{} = config) do
    by_action = Map.new(config.buttons.mapping, fn {code, action} -> {action, code} end)

    %{
      buttons:
        config.buttons
        |> Map.take([:status, :source, :device, :debounce_ms, :debug?, :errors])
        |> Map.put(:mapping, Map.new(@actions, &{&1, Map.get(by_action, &1)})),
      brightness: describe_brightness(config.brightness),
      power: config.power,
      strip: %{config.strip | wled_url: sanitise_url(config.strip.wled_url)}
    }
  end

  defp describe_brightness(brightness) do
    Enum.reduce([:min, :max, :step, :default], brightness, fn key, brightness ->
      Map.update!(brightness, key, &to_float/1)
    end)
  end

  @doc "Every configuration error, each one prefixed by its subsystem."
  @spec errors(t()) :: [String.t()]
  def errors(%__MODULE__{} = config) do
    for {name, section} <- [
          buttons: config.buttons,
          brightness: config.brightness,
          power: config.power,
          strip: config.strip
        ],
        error <- section.errors,
        do: "#{name}: #{error}"
  end

  # -- buttons -----------------------------------------------------------------

  defp buttons(env, allow_simulated?) do
    base = %{
      status: :disabled,
      source: nil,
      device: nil,
      debounce_ms: nil,
      debug?: false,
      mapping: %{},
      errors: []
    }

    case boolean(env, "JUKEBOX_BUTTONS_ENABLED") do
      {:ok, false} ->
        base

      {:error, message} ->
        %{base | status: :error, errors: [message]}

      {:ok, true} ->
        {source, source_errors} = collect(button_source(env, allow_simulated?))
        {device, device_errors} = collect(button_device(env, source))

        {debounce, debounce_errors} =
          collect(integer(env, "JUKEBOX_BUTTONS_DEBOUNCE_MS", 0, 1_000))

        {debug?, debug_errors} = collect(boolean(env, "JUKEBOX_BUTTONS_DEBUG"))
        {mapping, mapping_errors} = button_mapping(env)

        errors =
          source_errors ++ device_errors ++ debounce_errors ++ debug_errors ++ mapping_errors

        %{
          status: if(errors == [], do: :enabled, else: :error),
          source: source,
          device: device,
          debounce_ms: debounce,
          debug?: debug? == true,
          # With an error nothing is dispatched, so no partial mapping is kept.
          mapping: if(errors == [], do: mapping, else: %{}),
          errors: errors
        }
    end
  end

  defp button_source(env, allow_simulated?) do
    case value(env, "JUKEBOX_BUTTONS_SOURCE") do
      "evdev" ->
        {:ok, :evdev}

      "simulated" when allow_simulated? ->
        {:ok, :simulated}

      "simulated" ->
        {:error, "JUKEBOX_BUTTONS_SOURCE=simulated is for development and tests only; use evdev"}

      other ->
        {:error, "JUKEBOX_BUTTONS_SOURCE must be evdev, got #{inspect(other)}"}
    end
  end

  defp button_device(_env, :simulated), do: {:ok, nil}

  defp button_device(env, _source) do
    path = value(env, "JUKEBOX_BUTTONS_DEVICE")

    cond do
      path == "" ->
        {:error,
         "JUKEBOX_BUTTONS_DEVICE is empty: set it to the encoder's /dev/input/by-id/...-event-joystick link"}

      not String.starts_with?(path, "/dev/input/") or String.contains?(path, "/../") or
          String.ends_with?(path, "/..") ->
        {:error, "JUKEBOX_BUTTONS_DEVICE must be a path under /dev/input/, got #{inspect(path)}"}

      Regex.match?(~r{^/dev/input/(event|js|mouse)\d+$|^/dev/input/mice$}, path) ->
        {:error,
         "JUKEBOX_BUTTONS_DEVICE=#{path} is a kernel device number, which changes between boots: " <>
           "use the stable link under /dev/input/by-id/ (or by-path/) that points to it"}

      true ->
        {:ok, path}
    end
  end

  defp button_mapping(env) do
    {pairs, errors} =
      Enum.reduce(@actions, {[], []}, fn action, {pairs, errors} ->
        variable = button_variable(action)

        case key_code(value(env, variable)) do
          :unassigned -> {pairs, errors}
          {:ok, code} -> {[{code, action} | pairs], errors}
          {:error, reason} -> {pairs, ["#{variable} #{reason}" | errors]}
        end
      end)

    duplicates =
      pairs
      |> Enum.reverse()
      |> Enum.group_by(fn {code, _action} -> code end, fn {_code, action} -> action end)
      |> Enum.filter(fn {_code, actions} -> length(actions) > 1 end)
      |> Enum.sort()
      |> Enum.map(fn {code, actions} ->
        names = Enum.map_join(actions, " and ", &button_variable/1)
        "key code #{code} is assigned twice (#{names})"
      end)

    {Map.new(pairs), Enum.reverse(errors) ++ duplicates}
  end

  defp key_code(""), do: :unassigned

  defp key_code(raw) do
    cond do
      not Regex.match?(~r/^\d{1,4}$/, raw) ->
        {:error, "must be a decimal Linux EV_KEY code (for example 304), got #{inspect(raw)}"}

      String.to_integer(raw) > @key_max ->
        {:error, "must be at most #{@key_max}, got #{raw}"}

      true ->
        {:ok, String.to_integer(raw)}
    end
  end

  # -- brightness --------------------------------------------------------------

  @migration "the monitor is now dimmed through X11 (xrandr), not DDC. Replace the old brightness " <>
               "block: JUKEBOX_BRIGHTNESS_BACKEND=xrandr, JUKEBOX_XRANDR_OUTPUT, JUKEBOX_X11_DISPLAY and " <>
               "JUKEBOX_X11_XAUTHORITY; MIN/MAX/STEP are no longer percentages (10/100/5) but " <>
               "coefficients (0.3/1.0/0.1); JUKEBOX_DDC_BUS and JUKEBOX_DDC_TIMEOUT_MS are gone " <>
               "(the timeout is JUKEBOX_BRIGHTNESS_TIMEOUT_MS). See docs/physical-controls.md"

  defp brightness(env, allow_simulated?) do
    base = %{
      status: :disabled,
      backend: :disabled,
      output: nil,
      display: nil,
      xauthority: nil,
      min: nil,
      max: nil,
      step: nil,
      default: nil,
      timeout_ms: nil,
      errors: [],
      notices: []
    }

    case value(env, "JUKEBOX_BRIGHTNESS_BACKEND") do
      "disabled" ->
        base

      "xrandr" ->
        brightness(env, base, :xrandr)

      "simulated" when allow_simulated? ->
        brightness(env, base, :simulated)

      "simulated" ->
        brightness_error(
          base,
          "JUKEBOX_BRIGHTNESS_BACKEND=simulated is for development and tests only; use xrandr or disabled"
        )

      "ddcutil" ->
        brightness_error(
          base,
          "JUKEBOX_BRIGHTNESS_BACKEND=ddcutil is no longer supported: " <> @migration
        )

      other ->
        brightness_error(
          base,
          "JUKEBOX_BRIGHTNESS_BACKEND must be disabled or xrandr, got #{inspect(other)}"
        )
    end
  end

  defp brightness_error(base, message),
    do: %{base | status: :error, backend: nil, errors: [message]}

  defp brightness(env, base, backend) do
    {min, min_errors} = collect(coefficient(env, "JUKEBOX_BRIGHTNESS_MIN"))
    {max, max_errors} = collect(coefficient(env, "JUKEBOX_BRIGHTNESS_MAX"))
    {step, step_errors} = collect(coefficient(env, "JUKEBOX_BRIGHTNESS_STEP"))
    {default, default_errors} = collect(coefficient(env, "JUKEBOX_BRIGHTNESS_DEFAULT"))

    {timeout, timeout_errors} =
      collect(integer(env, "JUKEBOX_BRIGHTNESS_TIMEOUT_MS", 100, 30_000))

    {x11, x11_errors} = x11(env, backend)

    errors =
      min_errors ++
        max_errors ++
        step_errors ++
        default_errors ++
        range_errors(min, max, step, default) ++ timeout_errors ++ x11_errors

    %{
      base
      | status: if(errors == [], do: :enabled, else: :error),
        backend: backend,
        output: x11.output,
        display: x11.display,
        xauthority: x11.xauthority,
        min: min,
        max: max,
        step: step,
        default: default,
        timeout_ms: timeout,
        errors: errors,
        notices: leftovers(env)
    }
  end

  # A decimal between 0 (excluded) and 1.0, read without going through a float:
  # "0.7" is 700 thousandths. This is also what refuses NaN, infinity, an
  # exponent, a sign, and the percentages of the former DDC backend.
  defp coefficient(env, name) do
    raw = value(env, name)

    case Regex.run(~r/^(\d{1,9})(?:\.(\d{1,3}))?$/, raw) do
      [_all, whole | fraction] ->
        fraction = fraction |> List.first("") |> String.pad_trailing(3, "0")
        thousandths = String.to_integer(whole) * 1000 + String.to_integer(fraction)

        cond do
          thousandths == 0 ->
            {:error, "#{name} must be greater than 0, got #{raw}"}

          thousandths > 1000 ->
            {:error,
             "#{name} must be a coefficient of at most 1.0, got #{raw}. It is not a percentage any " <>
               "more: write 0.7 for 70 % and 1.0 for 100 %"}

          true ->
            {:ok, thousandths}
        end

      nil ->
        {:error,
         "#{name} must be a decimal coefficient between 0 and 1.0 with at most three decimals " <>
           "(for example 0.7), got #{inspect(raw)}"}
    end
  end

  defp range_errors(min, max, step, default)
       when is_integer(min) and is_integer(max) and is_integer(step) and is_integer(default) do
    [
      min >= max &&
        "JUKEBOX_BRIGHTNESS_MIN (#{format_coefficient(min)}) must be lower than " <>
          "JUKEBOX_BRIGHTNESS_MAX (#{format_coefficient(max)})",
      (min < max and (default < min or default > max)) &&
        "JUKEBOX_BRIGHTNESS_DEFAULT (#{format_coefficient(default)}) must lie between " <>
          "JUKEBOX_BRIGHTNESS_MIN and JUKEBOX_BRIGHTNESS_MAX",
      (min < max and step > max - min) &&
        "JUKEBOX_BRIGHTNESS_STEP (#{format_coefficient(step)}) must not exceed " <>
          "JUKEBOX_BRIGHTNESS_MAX - JUKEBOX_BRIGHTNESS_MIN (#{format_coefficient(max - min)})"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp range_errors(_min, _max, _step, _default), do: []

  defp x11(_env, :simulated), do: {%{output: nil, display: nil, xauthority: nil}, []}

  # All three are required and none has a built-in value: the output is never
  # "the first one", and the display and its authority file are those of the
  # kiosk session, which a systemd service does not inherit.
  defp x11(env, :xrandr) do
    {output, output_errors} = collect(xrandr_output(value(env, "JUKEBOX_XRANDR_OUTPUT")))
    {display, display_errors} = collect(x11_display(value(env, "JUKEBOX_X11_DISPLAY")))
    {xauthority, xauthority_errors} = collect(x11_authority(env))

    {%{output: output, display: display, xauthority: xauthority},
     output_errors ++ display_errors ++ xauthority_errors}
  end

  defp xrandr_output(""),
    do:
      {:error,
       "JUKEBOX_XRANDR_OUTPUT is empty: set it to the output name that `xrandr --query` shows as " <>
         "connected (for example HDMI-1)"}

  defp xrandr_output(name) do
    # A plain name: never something xrandr could read as an option.
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$/, name),
      do: {:ok, name},
      else:
        {:error,
         "JUKEBOX_XRANDR_OUTPUT must be an xrandr output name such as HDMI-1, got #{inspect(name)}"}
  end

  defp x11_display(""),
    do: {:error, "JUKEBOX_X11_DISPLAY is empty: set it to the kiosk's X display (for example :0)"}

  defp x11_display(display) do
    if Regex.match?(~r/^:\d{1,3}(\.\d{1,2})?$/, display),
      do: {:ok, display},
      else:
        {:error,
         "JUKEBOX_X11_DISPLAY must be a local X display such as :0, got #{inspect(display)}"}
  end

  defp x11_authority(env) do
    case value(env, "JUKEBOX_X11_XAUTHORITY") do
      "" ->
        {:error,
         "JUKEBOX_X11_XAUTHORITY is empty: set it to the X authority file of the kiosk session " <>
           "(for example /home/jukebox/.Xauthority)"}

      _path ->
        absolute_path(env, "JUKEBOX_X11_XAUTHORITY")
    end
  end

  # Variables of the former DDC backend still present: ignored, and said so.
  defp leftovers(env) do
    for name <- ["JUKEBOX_DDC_BUS", "JUKEBOX_DDC_TIMEOUT_MS"], value(env, name) != "" do
      "#{name} is obsolete and ignored; remove it"
    end
  end

  @doc "A coefficient in thousandths as the decimal xrandr takes: `700` is `\"0.7\"`."
  @spec format_coefficient(integer()) :: String.t()
  def format_coefficient(thousandths) when is_integer(thousandths) do
    :erlang.float_to_binary(thousandths / 1000, [{:decimals, 3}, :compact])
  end

  @doc "A coefficient in thousandths as a float, for display."
  @spec to_float(integer() | nil) :: float() | nil
  def to_float(nil), do: nil
  def to_float(thousandths) when is_integer(thousandths), do: thousandths / 1000

  # -- power -------------------------------------------------------------------

  defp power(env, source) do
    {client, client_errors} = collect(absolute_path(env, "JUKEBOX_POWER_CLIENT"))
    {state_file, state_errors} = collect(absolute_path(env, "JUKEBOX_POWER_STATE_FILE"))
    errors = client_errors ++ state_errors

    %{
      status: if(errors == [], do: :enabled, else: :error),
      source: source,
      client: client,
      state_file: state_file,
      errors: errors
    }
  end

  defp absolute_path(env, name) do
    path = value(env, name)

    if String.starts_with?(path, "/") and not String.contains?(path, ["\0", "/../"]),
      do: {:ok, path},
      else: {:error, "#{name} must be an absolute path, got #{inspect(path)}"}
  end

  # -- strip -------------------------------------------------------------------

  defp strip(env) do
    case value(env, "JUKEBOX_STRIP_CONTROL") do
      "power" ->
        %{status: :enabled, control: :power, wled_url: nil, errors: []}

      "wled" ->
        case wled_url(value(env, "JUKEBOX_WLED_URL")) do
          {:ok, url} ->
            %{status: :enabled, control: :wled, wled_url: url, errors: []}

          {:error, message} ->
            # Deliberately not a fallback to "power": the strip button stays
            # without effect until the address is fixed.
            %{status: :error, control: :wled, wled_url: nil, errors: [message]}
        end

      other ->
        %{
          status: :error,
          control: nil,
          wled_url: nil,
          errors: ["JUKEBOX_STRIP_CONTROL must be power or wled, got #{inspect(other)}"]
        }
    end
  end

  defp wled_url(""), do: {:error, "JUKEBOX_STRIP_CONTROL=wled needs JUKEBOX_WLED_URL"}

  defp wled_url(raw) do
    case URI.new(raw) do
      {:ok, %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        {:ok, String.trim_trailing(raw, "/")}

      _other ->
        {:error,
         "JUKEBOX_WLED_URL must look like http://192.168.1.50 (the address of the WLED controller, " <>
           "without a path)"}
    end
  end

  defp sanitise_url(nil), do: nil

  defp sanitise_url(url) do
    case URI.new(url) do
      {:ok, uri} -> URI.to_string(%{uri | userinfo: nil})
      {:error, _part} -> nil
    end
  end

  # -- values ------------------------------------------------------------------

  # A variable left empty (`NAME=`) means "use the default", like a missing one.
  defp value(env, name) do
    case env |> Map.get(name, "") |> to_string() |> String.trim() do
      "" -> Map.get(@defaults, name, "")
      value -> value
    end
  end

  defp boolean(env, name) do
    case String.downcase(value(env, name)) do
      v when v in ["1", "true", "yes", "on"] -> {:ok, true}
      v when v in ["0", "false", "no", "off"] -> {:ok, false}
      other -> {:error, "#{name} must be true or false, got #{inspect(other)}"}
    end
  end

  defp integer(env, name, min, max) do
    raw = value(env, name)

    with true <- Regex.match?(~r/^\d{1,9}$/, raw),
         number = String.to_integer(raw),
         true <- number >= min and number <= max do
      {:ok, number}
    else
      _invalid ->
        {:error, "#{name} must be a whole number from #{min} to #{max}, got #{inspect(raw)}"}
    end
  end

  defp collect({:ok, value}), do: {value, []}
  defp collect({:error, message}), do: {nil, [message]}
end
