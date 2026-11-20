defmodule Jukebox.Hardware do
  @moduledoc """
  The physical controls of the jukebox: eight buttons on a USB encoder,
  software dimming of the X11 output (xrandr), and the lights behind the
  power controller. See `docs/physical-controls.md`.

      USB encoder -> Jukebox.Inputs.Evdev -> Jukebox.Hardware.Buttons
                                                  |  (awake? debounce, mapping)
                                                  v
                                           Jukebox.Commands
                         .------------------------+-----------------------.
                         v                        v                       v
                  remote control          Jukebox.Animation      Jukebox.Hardware.Lights
                  (previous, play,        (animation style)      Jukebox.Hardware.Brightness
                   next)

  `status/0` is the one place to look when a button does not do what it
  should. From a shell on the Raspberry Pi:

      /opt/jukebox/bin/jukebox rpc 'IO.inspect(Jukebox.Hardware.status(), limit: :infinity)'
  """

  alias Jukebox.Hardware.{Brightness, Buttons, Config, Lights}
  alias Jukebox.Hardware.Power.Monitor

  @hardware_commands [:toggle_disco, :toggle_strip, :brightness_down, :brightness_up]

  @doc "The semantic commands carried out by this part of the application."
  def commands, do: @hardware_commands

  @doc """
  Asks for a hardware command to be carried out. Returns at once with
  `{:ok, :accepted}` (the outcome is reported later through
  `Jukebox.Commands.report/2`) or with the reason it was refused.
  """
  @spec request(atom()) ::
          {:ok, :accepted} | {:error, :not_awake | :hardware_unavailable | :busy}
  def request(command) when command in @hardware_commands do
    case perform(command) do
      {:ok, :accepted} -> {:ok, :accepted}
      {:error, :not_awake} -> {:error, :not_awake}
      {:error, :busy} -> {:error, :busy}
      {:error, _disabled_or_unavailable} -> {:error, :hardware_unavailable}
    end
  catch
    :exit, _reason -> {:error, :hardware_unavailable}
  end

  defp perform(:toggle_disco), do: Lights.toggle(:disco)
  defp perform(:toggle_strip), do: Lights.toggle(:strip)
  defp perform(:brightness_down), do: Brightness.step(:down)
  defp perform(:brightness_up), do: Brightness.step(:up)

  @doc """
  Everything known about the physical controls, as plain data without any
  secret:

    * `:config` - the effective configuration, with the error that disabled a
      subsystem if there is one
    * `:buttons` - mapping, selected device and its identity, connection,
      held keys, last accepted code and action, counters (malformed,
      unassigned, bounces, discarded while not awake, ...)
    * `:power` - mode and freshness of the power controller's state
    * `:lights` - requested and confirmed state of each light
    * `:brightness` - backend, X11 display and output and whether they are
      ready, configured bounds and default, the desired and the applied
      software coefficient (this is dimming of the picture, not the
      monitor's backlight)
    * `:recent_error` - the last problem of each subsystem that has one

  A part that is not running is reported as `{:error, :not_running}`.
  """
  @spec status() :: map()
  def status do
    config = Config.load()
    buttons = safe(fn -> Buttons.status() end)
    lights = safe(fn -> Lights.status() end)
    brightness = safe(fn -> Brightness.status() end)
    power = Monitor.snapshot()

    %{
      config: Config.describe(config),
      buttons: buttons,
      power: Map.put(power, :stale_after_ms, Jukebox.Hardware.Power.StateFile.max_age_ms()),
      lights: lights,
      brightness: brightness,
      recent_error: recent_errors(config, buttons, power, lights, brightness)
    }
  end

  defp recent_errors(config, buttons, power, lights, brightness) do
    [
      configuration: if(Config.errors(config) != [], do: Config.errors(config)),
      buttons: is_map(buttons) && buttons.last_problem,
      power: power.reason,
      disco: is_map(lights) && lights.disco.last_error,
      strip: is_map(lights) && lights.strip.last_error,
      brightness: is_map(brightness) && brightness.last_error
    ]
    |> Enum.filter(fn {_subsystem, error} -> error not in [nil, false] end)
    |> Map.new()
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :not_running}
  end
end
