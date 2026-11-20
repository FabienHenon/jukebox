defmodule Jukebox.Hardware.Power.MonitorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Jukebox.Test.HardwareHelpers

  alias Jukebox.Hardware.Power.{Monitor, Simulated}

  test "follows the controller and broadcasts each change once" do
    power = start_power(:awake)

    # Read once before subscribing, so the monitor's first reading (from
    # "not read yet" to awake) is not mistaken for a change below.
    assert %{mode: :awake, fresh?: true, reason: nil} = Monitor.snapshot(power.monitor)
    assert Monitor.awake?(power.monitor)
    Monitor.subscribe(power.pubsub)

    set_mode(power, :standby)
    assert_receive {:power_state, %{mode: :standby}}
    refute Monitor.awake?(power.monitor)

    # Reading again without a change says nothing new.
    Monitor.snapshot(power.monitor)
    Monitor.snapshot(power.monitor)
    refute_receive {:power_state, _snapshot}, 50

    set_mode(power, :awake)
    assert_receive {:power_state, %{mode: :awake, outputs: %{disco: %{requested: false}}}}
  end

  test "a controller that cannot be read is unknown, and unknown is not awake" do
    power = start_power(:awake)
    assert Monitor.awake?(power.monitor)
    Monitor.subscribe(power.pubsub)

    log =
      capture_log(fn ->
        Simulated.set_available(power.power, false)

        assert %{mode: :unknown, fresh?: false, reason: :missing, outputs: %{}} =
                 Monitor.snapshot(power.monitor)

        assert_receive {:power_state, %{mode: :unknown}}
        refute Monitor.awake?(power.monitor)

        # Still unreadable: one log line, not one per read.
        for _ <- 1..20, do: Monitor.snapshot(power.monitor)
      end)

    assert length(String.split(log, "controller state unavailable")) == 2

    Simulated.set_available(power.power, true)
    assert Monitor.mode(power.monitor) == :awake
  end

  test "a reader that fails in any way gives unknown, never a crash" do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    for {reader, n} <-
          Enum.with_index([
            fn -> {:error, :stale} end,
            fn -> raise "boom" end,
            fn -> exit(:gone) end,
            fn -> :nonsense end
          ]) do
      name = :"monitor_#{n}_#{System.unique_integer([:positive])}"

      capture_log(fn ->
        start_supervised!(
          Supervisor.child_spec(
            {Monitor, name: name, reader: reader, poll_ms: nil, pubsub: pubsub},
            id: name
          )
        )

        assert %{mode: :unknown, fresh?: false} = Monitor.snapshot(name)
      end)
    end
  end

  test "a monitor that is not running answers unknown" do
    assert %{mode: :unknown, reason: :monitor_unavailable} = Monitor.snapshot(:no_such_monitor)
    refute Monitor.awake?(:no_such_monitor)
  end

  test "it polls on its own" do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    power = start_supervised!({Simulated, name: :"power_#{System.unique_integer([:positive])}"})
    Monitor.subscribe(pubsub)

    start_supervised!(
      {Monitor,
       name: :"polling_#{System.unique_integer([:positive])}",
       reader: fn -> Simulated.read(power) end,
       poll_ms: 10,
       pubsub: pubsub}
    )

    assert_receive {:power_state, %{mode: :awake}}
    Simulated.set_mode(power, :shutting_down)
    assert_receive {:power_state, %{mode: :shutting_down}}, 500
  end
end
