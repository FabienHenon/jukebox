defmodule Jukebox.Hardware.Supervisor do
  @moduledoc """
  Supervises everything behind the physical controls, in dependency order:

      desired brightness  ->  power state  ->  queues  ->  lights, brightness
                                                      ->  buttons  ->  input adapter

  The strategy is `:rest_for_one`: when a process stops, the ones after it
  are restarted with it. In particular the input adapter restarts whenever the
  dispatcher does, so the dispatcher always learns again which keys are held
  instead of assuming none. The desired brightness comes first for the
  opposite reason: nothing that restarts after it can reset it.

  The configuration (`Jukebox.Hardware.Config`) is read here, once, when the
  supervisor starts. A subsystem whose configuration is wrong still gets its
  process, in a disabled state that explains itself in
  `Jukebox.Hardware.status/0`; only the input adapter is left out when the
  buttons are disabled.
  """

  use Supervisor

  require Logger

  alias Jukebox.Hardware.{Brightness, Buttons, Config, Lane, Lights}
  alias Jukebox.Hardware.Power

  @transport_lane Jukebox.Hardware.Lane.Transport
  @local_lane Jukebox.Hardware.Lane.Local

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.load/0)
    report(config)

    children =
      [{Brightness.Desired, default: config.brightness.default}] ++
        power(config) ++
        [
          # Music commands: short queue, and a command that waited too long is
          # dropped rather than sent late.
          Supervisor.child_spec({Lane, name: @transport_lane, max_queue: 3, ttl_ms: 1_500},
            id: @transport_lane
          ),
          # Everything answered inside the application (animation style,
          # requests to the lights and brightness workers).
          Supervisor.child_spec({Lane, name: @local_lane, max_queue: 8, ttl_ms: 1_500},
            id: @local_lane
          ),
          {Lights, strip: config.strip, power_command: power_command(config)}
        ] ++
        brightness(config) ++
        [
          {Buttons,
           config: config.buttons, transport_lane: @transport_lane, local_lane: @local_lane}
        ] ++ input(config.buttons)

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp power(%{power: %{source: :simulated}}) do
    [Power.Simulated, {Power.Monitor, reader: &Power.Simulated.read/0}]
  end

  defp power(%{power: %{status: :enabled, state_file: path}}) do
    [{Power.Monitor, reader: fn -> Power.StateFile.read(path) end}]
  end

  defp power(_misconfigured) do
    [{Power.Monitor, reader: fn -> {:error, :configuration_error} end, poll_ms: nil}]
  end

  defp power_command(%{power: %{source: :simulated}}), do: &Power.Simulated.command/1

  defp power_command(%{power: %{status: :enabled, client: client}}),
    do: &Power.Client.command(&1, executable: client)

  defp power_command(_misconfigured), do: fn _args -> {:error, :client_missing} end

  defp brightness(%{brightness: %{backend: :simulated, status: :enabled} = config}),
    do: [Brightness.Simulated, {Brightness, config: config}]

  defp brightness(%{brightness: config}), do: [{Brightness, config: config}]

  defp input(%{status: :enabled, source: :evdev, device: device}),
    do: [Jukebox.Inputs.Evdev.child_spec(device: device)]

  defp input(%{status: :enabled, source: :simulated, mapping: mapping}),
    do: [Jukebox.Inputs.Simulated.child_spec(keys: Map.keys(mapping))]

  defp input(_disabled), do: []

  # Said once at start-up: what is off because of its configuration, and why.
  defp report(config) do
    for error <- Config.errors(config) do
      Logger.error("[hardware] configuration error, subsystem disabled - #{error}")
    end

    for notice <- config.brightness.notices do
      Logger.warning("[hardware] brightness: #{notice}")
    end

    if config.buttons.status == :enabled and config.buttons.mapping == %{} do
      Logger.warning("[hardware] buttons are enabled but no JUKEBOX_BUTTON_* code is assigned")
    end

    :ok
  end
end
