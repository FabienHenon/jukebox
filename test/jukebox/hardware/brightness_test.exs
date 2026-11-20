defmodule Jukebox.Hardware.BrightnessTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Jukebox.Test.HardwareHelpers

  alias Jukebox.Hardware.Brightness
  alias Jukebox.Hardware.Brightness.Desired
  alias Jukebox.Test.FakeXrandr

  @config %{
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

  setup do
    {:ok, power: start_power(:awake)}
  end

  # Starts the desired-value store, a fake display and the worker.
  defp start_brightness(power, display_opts \\ [], opts \\ []) do
    test = self()
    config = Keyword.get(opts, :config, @config)
    {:ok, display} = FakeXrandr.start_link(Keyword.put(display_opts, :owner, test))

    desired =
      case Keyword.get(opts, :desired) do
        nil ->
          name = :"desired_#{System.unique_integer([:positive])}"

          start_supervised!(
            Supervisor.child_spec({Desired, name: name, default: config.default}, id: name)
          )

          name

        existing ->
          existing
      end

    opts =
      Keyword.merge(
        [
          name: :"brightness_#{System.unique_integer([:positive])}",
          config: config,
          desired: desired,
          backend: {FakeXrandr, [agent: display]},
          monitor: power.monitor,
          pubsub: power.pubsub,
          report: fn command, result -> send(test, {:report, command, result}) end,
          coalesce_ms: 20,
          check_ms: 60_000,
          retry_ms: {20, 80}
        ],
        opts
      )

    worker = start_supervised!(Supervisor.child_spec({Brightness, opts}, id: opts[:name]))
    {worker, display, desired, opts[:name]}
  end

  defp ready(worker), do: eventually(fn -> Brightness.status(worker).x11_ready? end)

  defp settled(worker) do
    eventually(fn ->
      status = Brightness.status(worker)
      status.x11_ready? and not status.pending?
    end)
  end

  describe "start" do
    test "the configured default is applied once the display answers", %{power: power} do
      # Left dimmed by an earlier run: the X server keeps what it was given.
      {worker, display, _desired, _id} = start_brightness(power, current: 500)
      ready(worker)

      assert FakeXrandr.calls(display) == [:query, {:set, 1000}, :query]

      assert %{
               status: :enabled,
               backend: :xrandr,
               display: ":0",
               output: "HDMI-1",
               x11_ready?: true,
               availability: :ready,
               min: 0.3,
               max: 1.0,
               step: 0.1,
               default: 1.0,
               desired_coefficient: 1.0,
               applied_coefficient: 1.0,
               pending?: false,
               last_error: nil,
               kind: kind
             } = Brightness.status(worker)

      assert kind =~ "software dimming"
      assert kind =~ "Not the monitor's backlight"
      assert Brightness.status(worker).applied_read_ms_ago in 0..5_000
      refute_receive {:report, _command, _result}, 50
    end

    test "a display that already has the desired value is only read", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power, current: 1000)
      ready(worker)
      assert FakeXrandr.calls(display) == [:query]
    end

    test "a darker default is applied at start", %{power: power} do
      {worker, display, _desired, _id} =
        start_brightness(power, [current: 1000], config: %{@config | default: 700})

      ready(worker)
      assert FakeXrandr.sets(display) == [700]

      assert %{desired_coefficient: 0.7, applied_coefficient: 0.7, default: 0.7} =
               Brightness.status(worker)
    end

    test "starting before X11: bounded retries, then the value is applied", %{power: power} do
      log =
        capture_log(fn ->
          {worker, display, _desired, _id} =
            start_brightness(power, current: 1000, down: :x11_unavailable)

          eventually(fn -> FakeXrandr.queries(display) >= 4 end)

          assert %{
                   x11_ready?: false,
                   availability: :x11_unavailable,
                   last_error: :x11_unavailable,
                   applied_coefficient: nil
                 } =
                   Brightness.status(worker)

          # A press while the display is away is refused by nobody: it moves
          # the desired value, and says that it could not be shown.
          assert Brightness.step(worker, :down) == {:ok, :accepted}
          assert_receive {:report, :brightness_down, {:error, :hardware_unavailable}}
          assert %{desired_coefficient: 0.9} = Brightness.status(worker)

          # Pauses of 20, 40, 80, 80... ms: a handful of attempts, not a loop.
          Process.sleep(300)
          attempts = FakeXrandr.queries(display)
          assert attempts in 4..12, "#{attempts} attempts"
          assert FakeXrandr.sets(display) == []

          # The kiosk session starts.
          FakeXrandr.set_state(display, down: nil)
          ready(worker)
          assert FakeXrandr.sets(display) == [900]
          assert %{applied_coefficient: 0.9, last_error: nil} = Brightness.status(worker)
        end)

      # The reason is said once, not at every attempt.
      assert length(String.split(log, "cannot apply software brightness")) == 2
      assert log =~ "kiosk session may not have started yet"
    end
  end

  describe "presses" do
    test "each press moves the desired value by one step and is confirmed", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)

      assert Brightness.step(worker, :down) == {:ok, :accepted}
      assert_receive {:report, :brightness_down, {:ok, {:brightness, 90}}}
      assert FakeXrandr.current(display) == 900

      assert Brightness.step(worker, :up) == {:ok, :accepted}
      assert_receive {:report, :brightness_up, {:ok, {:brightness, 100}}}
      assert FakeXrandr.sets(display) == [900, 1000]
    end

    test "the value is clamped to the configured range", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)

      Brightness.step(worker, :up)
      assert_receive {:report, :brightness_up, {:ok, {:brightness, 100}}}
      assert FakeXrandr.sets(display) == [], "at the limit nothing is written"

      for expected <- [90, 80, 70, 60, 50, 40, 30, 30, 30] do
        Brightness.step(worker, :down)
        assert_receive {:report, :brightness_down, {:ok, {:brightness, ^expected}}}
      end

      assert FakeXrandr.current(display) == 300
      assert FakeXrandr.sets(display) == [900, 800, 700, 600, 500, 400, 300]
    end

    test "steps do not drift: down to the minimum and back is exactly the maximum", %{
      power: power
    } do
      {worker, display, desired, _id} = start_brightness(power, [], coalesce_ms: 1)
      ready(worker)

      for _ <- 1..7, do: Brightness.step(worker, :down)
      assert Desired.get(desired) == 300
      for _ <- 1..7, do: Brightness.step(worker, :up)
      assert Desired.get(desired) == 1000

      settled(worker)
      assert %{desired_coefficient: 1.0, applied_coefficient: 1.0} = Brightness.status(worker)
      assert FakeXrandr.current(display) == 1000
    end

    test "a burst of presses becomes one change to the last value", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)

      for _ <- 1..4, do: assert(Brightness.step(worker, :down) == {:ok, :accepted})

      assert %{desired_coefficient: 0.6, applied_coefficient: 1.0, pending?: true} =
               Brightness.status(worker)

      assert_receive {:report, :brightness_down, {:ok, {:brightness, 60}}}
      assert FakeXrandr.sets(display) == [600]
      refute_receive {:report, _command, _result}, 60
    end

    test "only one request runs at a time; a newer value follows it", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)

      FakeXrandr.hold(display, :set)
      Brightness.step(worker, :down)
      assert_receive {:held, :set, first}

      # While 0.9 is being set the button keeps being pressed.
      for _ <- 1..3, do: Brightness.step(worker, :down)
      assert %{desired_coefficient: 0.6, pending?: true} = Brightness.status(worker)
      refute_receive {:held, :set, _pid}, 60

      FakeXrandr.unhold(display, :set)
      FakeXrandr.release(first)

      assert_receive {:report, :brightness_down, {:ok, {:brightness, 60}}}
      assert FakeXrandr.sets(display) == [900, 600], "the values in between were never sent"
      refute_receive {:report, _command, _result}, 60
    end

    test "down then up inside the pause writes nothing", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)

      Brightness.step(worker, :down)
      Brightness.step(worker, :up)
      assert_receive {:report, :brightness_up, {:ok, {:brightness, 100}}}
      assert FakeXrandr.sets(display) == []
    end
  end

  describe "read-back" do
    test "a value within the tolerance is confirmed", %{power: power} do
      assert Brightness.tolerance() == 20
      # The display reports 0.02 less than it was given (ramp quantisation).
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)
      FakeXrandr.set_state(display, offset: -20)

      Brightness.step(worker, :down)
      assert_receive {:report, :brightness_down, {:ok, {:brightness, 90}}}

      assert %{desired_coefficient: 0.9, applied_coefficient: 0.88, pending?: false} =
               Brightness.status(worker)

      # Being within the tolerance, it is not written again and again.
      assert FakeXrandr.sets(display) == [900]
    end

    test "a value outside the tolerance is a mismatch, never a success", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)
      FakeXrandr.set_state(display, ignore_sets?: true)

      log =
        capture_log(fn ->
          Brightness.step(worker, :down)
          assert_receive {:report, :brightness_down, {:error, :unconfirmed}}

          assert %{
                   x11_ready?: false,
                   availability: :mismatch,
                   desired_coefficient: 0.9,
                   applied_coefficient: 1.0,
                   last_error: {:mismatch, 1000},
                   pending?: true
                 } = Brightness.status(worker)

          # Tried again later, with growing pauses, not continuously.
          Process.sleep(250)
          assert length(FakeXrandr.sets(display)) in 2..6
        end)

      assert log =~ "the output reports 1.0 after the change"

      # The display obeys again: the next attempt succeeds by itself.
      FakeXrandr.set_state(display, ignore_sets?: false)
      settled(worker)
      assert %{applied_coefficient: 0.9, last_error: nil} = Brightness.status(worker)
    end
  end

  describe "failures" do
    test "each kind of failure is reported as what it is", %{power: power} do
      for reason <- [
            :xrandr_missing,
            :xauthority_missing,
            :xauthority_unreadable,
            :x11_unauthorized,
            :x11_unavailable,
            :output_missing,
            :output_inactive,
            :timeout,
            :malformed_reply
          ] do
        capture_log(fn ->
          {worker, display, _desired, id} = start_brightness(power, down: reason)
          eventually(fn -> Brightness.status(worker).last_error == reason end)

          Brightness.step(worker, :down)
          assert_receive {:report, :brightness_down, {:error, :hardware_unavailable}}

          assert %{availability: ^reason, x11_ready?: false, applied_coefficient: nil} =
                   Brightness.status(worker)

          # Nothing is applied to an output that was not confirmed first.
          assert FakeXrandr.sets(display) == []
          stop_supervised!(id)
        end)
      end
    end

    test "a failing change is not reported as done, and is tried again later", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)
      FakeXrandr.fail(display, :set, [{:command_failed, 1}])

      capture_log(fn ->
        Brightness.step(worker, :down)
        assert_receive {:report, :brightness_down, {:error, :hardware_unavailable}}
        assert %{availability: :command_failed} = Brightness.status(worker)
      end)

      settled(worker)
      assert %{applied_coefficient: 0.9, availability: :ready} = Brightness.status(worker)
      refute_receive {:report, _command, _result}, 50
    end
  end

  describe "power state" do
    test "nothing runs and presses are refused unless awake; the value is kept", %{power: power} do
      for mode <- [:standby, :booting, :shutting_down] do
        set_mode(power, mode)

        {worker, display, desired, id} =
          start_brightness(power, [current: 400], config: %{@config | default: 700})

        Process.sleep(60)

        assert Brightness.step(worker, :up) == {:error, :not_awake}
        assert FakeXrandr.calls(display) == []
        assert Desired.get(desired) == 700

        assert %{availability: :not_awake, desired_coefficient: 0.7, applied_coefficient: nil} =
                 Brightness.status(worker)

        stop_supervised!(id)
      end

      refute_receive {:report, _command, _result}, 50
    end

    test "an unreadable power state is treated like standby", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)
      calls = FakeXrandr.calls(display)

      capture_log(fn ->
        Jukebox.Hardware.Power.Simulated.set_available(power.power, false)
        refresh(power)
        assert Brightness.step(worker, :down) == {:error, :not_awake}
        eventually(fn -> Brightness.status(worker).availability == :not_awake end)
      end)

      Process.sleep(60)
      assert FakeXrandr.calls(display) == calls
    end

    test "standby cancels what was waiting and keeps the desired value", %{power: power} do
      {worker, display, desired, _id} = start_brightness(power, [], coalesce_ms: 150)
      ready(worker)

      Brightness.step(worker, :down)
      Brightness.step(worker, :down)
      assert %{desired_coefficient: 0.8, pending?: true} = Brightness.status(worker)

      set_mode(power, :standby)
      calls = FakeXrandr.calls(display)

      assert %{
               availability: :not_awake,
               desired_coefficient: 0.8,
               applied_coefficient: nil,
               pending?: false
             } =
               Brightness.status(worker)

      Process.sleep(250)
      assert FakeXrandr.calls(display) == calls, "nothing ran during standby"
      assert Desired.get(desired) == 800
      refute_receive {:report, _command, _result}, 50
    end

    test "after standby the kept value is applied again, not the default", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)

      for _ <- 1..3, do: Brightness.step(worker, :down)
      assert_receive {:report, :brightness_down, {:ok, {:brightness, 70}}}

      set_mode(power, :standby)
      # The X server restarted meanwhile (or DPMS reset the ramp).
      FakeXrandr.set_state(display, current: 1000)
      before = length(FakeXrandr.calls(display))

      set_mode(power, :awake)
      ready(worker)

      assert Enum.drop(FakeXrandr.calls(display), before) == [:query, {:set, 700}, :query]

      assert %{desired_coefficient: 0.7, applied_coefficient: 0.7, default: 1.0} =
               Brightness.status(worker)

      refute_receive {:report, _command, _result}, 50
    end

    test "a request running when standby begins is stopped, and nothing follows it", %{
      power: power
    } do
      {worker, display, _desired, _id} = start_brightness(power)
      ready(worker)

      FakeXrandr.hold(display, :set)
      Brightness.step(worker, :down)
      assert_receive {:held, :set, job}
      ref = Process.monitor(job)

      set_mode(power, :standby)
      # The job process is told to stop (which is what kills a real xrandr).
      assert_receive {:DOWN, ^ref, :process, ^job, _reason}

      calls = FakeXrandr.calls(display)
      Process.sleep(120)
      assert FakeXrandr.calls(display) == calls, "no read-back, no retry while not awake"
      refute_receive {:report, _command, _result}, 50
    end

    test "failures are not retried during standby", %{power: power} do
      capture_log(fn ->
        {worker, display, _desired, _id} = start_brightness(power, down: :x11_unavailable)
        eventually(fn -> FakeXrandr.queries(display) >= 2 end)

        set_mode(power, :standby)
        eventually(fn -> Brightness.status(worker).availability == :not_awake end)
        calls = FakeXrandr.calls(display)
        Process.sleep(300)
        assert FakeXrandr.calls(display) == calls
      end)
    end
  end

  describe "keeping the output in the desired state" do
    test "while healthy the output is read at the check interval, and written only if it changed",
         %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power, [], check_ms: 40)
      ready(worker)

      Process.sleep(250)
      queries = FakeXrandr.queries(display)
      assert queries in 3..8, "#{queries} readings in 250 ms at one per 40 ms"
      assert FakeXrandr.sets(display) == [], "nothing is rewritten while it matches"
    end

    test "an X restart that lost the value is noticed and repaired", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power, [], check_ms: 30)
      ready(worker)
      Brightness.step(worker, :down)
      Brightness.step(worker, :down)
      assert_receive {:report, :brightness_down, {:ok, {:brightness, 80}}}

      log =
        capture_log(fn ->
          # The X server restarts: gone for a moment, then back at neutral.
          FakeXrandr.set_state(display, down: :x11_unavailable)
          eventually(fn -> not Brightness.status(worker).x11_ready? end)
          FakeXrandr.set_state(display, down: nil, current: 1000)

          eventually(fn -> FakeXrandr.current(display) == 800 end)
          settled(worker)
        end)

      assert log =~ "cannot apply software brightness"
      assert %{desired_coefficient: 0.8, applied_coefficient: 0.8} = Brightness.status(worker)
      # A repair is not a press.
      refute_receive {:report, _command, _result}, 50
    end

    test "a manual change of the output is put back, and said", %{power: power} do
      {worker, display, _desired, _id} = start_brightness(power, [], check_ms: 30)
      ready(worker)

      log =
        capture_log(fn ->
          FakeXrandr.set_state(display, current: 500)
          eventually(fn -> FakeXrandr.current(display) == 1000 end)
          settled(worker)
        end)

      assert log =~ "the output was at 0.5 instead of 1.0; applied again"
    end
  end

  describe "the desired value outlives the worker" do
    test "a restarted worker applies the value that was asked for, not the default", %{
      power: power
    } do
      {worker, display, desired, id} = start_brightness(power, [], check_ms: 30)
      ready(worker)

      for _ <- 1..4, do: Brightness.step(worker, :down)
      assert_receive {:report, :brightness_down, {:ok, {:brightness, 60}}}

      # The worker dies (taking the output back to neutral with it, for good
      # measure) and is restarted by its supervisor.
      ref = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
      FakeXrandr.set_state(display, current: 1000)

      restarted =
        eventually(fn ->
          pid = Process.whereis(id)
          pid != nil and pid != worker and pid
        end)

      # Whether the new worker read the output before or after it was reset,
      # it ends up at the value that was asked for.
      eventually(fn -> FakeXrandr.current(display) == 600 end)
      assert Desired.get(desired) == 600
      assert %{desired_coefficient: 0.6, default: 1.0} = Brightness.status(restarted)
    end

    test "a new store, as after a full restart of the application, starts from the default", %{
      power: power
    } do
      name = :"desired_#{System.unique_integer([:positive])}"
      start_supervised!(Supervisor.child_spec({Desired, name: name, default: 700}, id: name))
      Desired.update(name, fn _current -> 400 end)
      assert Desired.get(name) == 400

      stop_supervised!(name)
      start_supervised!(Supervisor.child_spec({Desired, name: name, default: 700}, id: name))
      assert Desired.get(name) == 700

      {worker, display, ^name, _id} =
        start_brightness(power, [current: 400], desired: name, config: %{@config | default: 700})

      ready(worker)
      assert FakeXrandr.sets(display) == [700]
    end
  end

  describe "configuration" do
    test "disabled or misconfigured: presses are refused and nothing is ever run", %{power: power} do
      for {config, availability} <- [
            {%{@config | status: :disabled, backend: :disabled}, :disabled},
            {%{@config | status: :error, output: nil, errors: ["JUKEBOX_XRANDR_OUTPUT is empty"]},
             :configuration_error}
          ] do
        {worker, display, _desired, id} = start_brightness(power, [], config: config)
        Process.sleep(40)

        assert Brightness.step(worker, :up) == {:error, :disabled}

        assert %{availability: ^availability, errors: errors, x11_ready?: false} =
                 Brightness.status(worker)

        assert errors == config.errors
        assert FakeXrandr.calls(display) == []
        stop_supervised!(id)
      end
    end
  end
end
