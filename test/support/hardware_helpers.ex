defmodule Jukebox.Test.HardwareHelpers do
  @moduledoc """
  Building blocks for the hardware tests: an isolated PubSub with a simulated
  power controller and its monitor, and small executable scripts standing in
  for external programs.
  """

  import ExUnit.Callbacks

  alias Jukebox.Hardware.Power

  @doc """
  Starts a PubSub, a simulated power controller and a monitor reading it.
  Returns `%{pubsub:, power:, monitor:}`. Options go to the controller, for
  example `requested: %{strip: false}`.
  """
  def start_power(mode \\ :awake, opts \\ []) do
    id = System.unique_integer([:positive])
    pubsub = :"hw_pubsub_#{id}"
    power = :"hw_power_#{id}"
    monitor = :"hw_monitor_#{id}"

    # Unique child ids, so a test may start a second set beside the first.
    start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: pubsub}, id: pubsub))

    start_supervised!(
      Supervisor.child_spec({Power.Simulated, [name: power, mode: mode] ++ opts}, id: power)
    )

    start_supervised!(
      Supervisor.child_spec(
        {Power.Monitor,
         name: monitor,
         reader: fn -> Power.Simulated.read(power) end,
         poll_ms: nil,
         pubsub: pubsub},
        id: monitor
      )
    )

    %{pubsub: pubsub, power: power, monitor: monitor}
  end

  @doc "Changes the simulated power mode and lets the monitor notice (and broadcast) it."
  def set_mode(%{power: power, monitor: monitor}, mode) do
    Power.Simulated.set_mode(power, mode)
    Power.Monitor.snapshot(monitor)
  end

  @doc "Makes the monitor read the controller now, broadcasting any change."
  def refresh(%{monitor: monitor}), do: Power.Monitor.snapshot(monitor)

  @doc "Writes an executable `/bin/sh` script and returns its path."
  def script!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  @doc "True while an operating-system process with this pid exists."
  def os_process_alive?(os_pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  @doc "Waits until `fun` returns a truthy value, or fails after `timeout` ms."
  def eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(fun, deadline)
  end

  defp wait(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          ExUnit.Assertions.flunk("condition not met in time")
        else
          Process.sleep(10)
          wait(fun, deadline)
        end

      truthy ->
        truthy
    end
  end
end
