defmodule Jukebox.Hardware.ButtonsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Jukebox.Test.HardwareHelpers

  alias Jukebox.Hardware.{Buttons, Lane}
  alias Jukebox.Hardware.Power.Simulated

  @mapping %{
    304 => :previous,
    305 => :play_pause,
    306 => :next,
    307 => :disco_toggle,
    308 => :strip_toggle,
    309 => :animation_next,
    310 => :brightness_down,
    311 => :brightness_up
  }

  @config %{
    status: :enabled,
    source: :simulated,
    device: nil,
    debounce_ms: 80,
    debug?: false,
    mapping: @mapping,
    errors: []
  }

  @device %{
    name: "Test encoder",
    vendor: 0x1234,
    product: 0x5678,
    version: 1,
    phys: "usb-test/input0",
    path: "/dev/input/by-id/test-event-joystick",
    real_path: "/dev/input/event3",
    abs?: true,
    keys: Enum.to_list(304..311),
    held: []
  }

  setup do
    {:ok, power: start_power(:awake)}
  end

  defp start_buttons(power, opts \\ []) do
    test = self()
    id = System.unique_integer([:positive])
    transport = :"transport_#{id}"
    local = :"local_#{id}"

    start_supervised!(
      Supervisor.child_spec({Lane, name: transport, max_queue: 3, ttl_ms: 1_500}, id: transport)
    )

    start_supervised!(
      Supervisor.child_spec({Lane, name: local, max_queue: 8, ttl_ms: 1_500}, id: local)
    )

    opts =
      Keyword.merge(
        [
          name: :"buttons_#{id}",
          config: @config,
          monitor: power.monitor,
          pubsub: power.pubsub,
          transport_lane: transport,
          local_lane: local,
          dispatch: fn command -> send(test, {:dispatched, command}) end
        ],
        opts
      )

    buttons = start_supervised!({Buttons, opts})
    capture_log(fn -> connect(buttons) end)
    buttons
  end

  defp connect(buttons, changes \\ %{}) do
    Buttons.input(buttons, {:connected, Map.merge(@device, changes)})
    Buttons.status(buttons)
  end

  # Feeds `{code, value, ms}` key events and waits until they were handled.
  defp keys(buttons, events) do
    for {code, value, ms} <- events, do: Buttons.input(buttons, {:key, code, value, ms})
    Buttons.status(buttons)
  end

  defp tap(buttons, code, at), do: keys(buttons, [{code, 1, at}, {code, 0, at + 100}])

  describe "one press, one action" do
    test "each mapped code gives its command", %{power: power} do
      buttons = start_buttons(power)

      expected = [
        {304, :previous_track},
        {305, :toggle_playback},
        {306, :next_track},
        {307, :toggle_disco},
        {308, :toggle_strip},
        {309, :cycle_animation},
        {310, :brightness_down},
        {311, :brightness_up}
      ]

      for {{code, command}, n} <- Enum.with_index(expected) do
        tap(buttons, code, n * 1_000)
        assert_receive {:dispatched, ^command}
      end

      refute_receive {:dispatched, _command}, 50

      status = Buttons.status(buttons)
      assert status.counts.accepted == 8
      assert %{code: 311, action: :brightness_up, at: %DateTime{}} = status.last_accepted
      assert status.held == []
    end

    test "repeated downs, kernel repeats, bounce and a long hold do not duplicate it", %{
      power: power
    } do
      buttons = start_buttons(power)

      status =
        keys(buttons, [
          {306, 1, 0},
          # bounce
          {306, 0, 3},
          {306, 1, 6},
          # duplicate down reports while held
          {306, 1, 20},
          {306, 1, 500},
          # kernel auto-repeat during a long hold
          {306, 2, 750},
          {306, 2, 783},
          {306, 2, 816},
          {306, 2, 9_000},
          {306, 0, 10_000},
          # bounce on release
          {306, 1, 10_004},
          {306, 0, 10_008}
        ])

      assert_receive {:dispatched, :next_track}
      refute_receive {:dispatched, _command}, 50

      assert %{accepted: 1, bounces: 2, duplicates: 2, repeats: 4} = status.counts
      assert status.held == []

      # Released for real: the next press counts.
      tap(buttons, 306, 11_000)
      assert_receive {:dispatched, :next_track}
    end

    test "buttons pressed together are independent", %{power: power} do
      buttons = start_buttons(power)

      status = keys(buttons, [{307, 1, 0}, {309, 1, 5}, {311, 1, 9}])
      assert status.held == [307, 309, 311]

      assert_receive {:dispatched, :toggle_disco}
      assert_receive {:dispatched, :cycle_animation}
      assert_receive {:dispatched, :brightness_up}

      keys(buttons, [{309, 0, 300}, {309, 1, 600}])
      assert_receive {:dispatched, :cycle_animation}
      refute_receive {:dispatched, _command}, 50
    end

    test "axes, unassigned codes and other values are ignored and counted", %{power: power} do
      buttons = start_buttons(power)

      status = keys(buttons, [{288, 1, 0}, {288, 0, 50}, {700, 1, 100}])
      assert status.counts.unassigned == 2
      assert status.counts.accepted == 0

      log =
        capture_log(fn ->
          Buttons.input(buttons, {:key, 306, 7, 0})
          Buttons.input(buttons, {:key, "306", 1, 0})
          Buttons.input(buttons, {:abs, 0, 127})
          Buttons.input(buttons, {:malformed, :invalid_json})
          Buttons.input(buttons, :garbage)
          assert Buttons.status(buttons).counts.malformed == 5
        end)

      # Five bad messages, one log line.
      assert length(String.split(log, "malformed input message")) == 2
      refute_receive {:dispatched, _command}, 50
    end
  end

  describe "power mode" do
    test "while not awake every action is discarded, and none is kept for later", %{power: power} do
      buttons = start_buttons(power)

      for {mode, round} <- Enum.with_index([:standby, :booting, :shutting_down]) do
        set_mode(power, mode)

        for {code, n} <- Enum.with_index(304..311) do
          tap(buttons, code, round * 10_000 + n * 1_000)
        end
      end

      assert Buttons.status(buttons).counts.discarded_not_awake == 24
      refute_receive {:dispatched, _command}, 50

      set_mode(power, :awake)
      refute_receive {:dispatched, _command}, 100

      tap(buttons, 306, 60_000)
      assert_receive {:dispatched, :next_track}
    end

    test "an unreadable power state blocks the buttons (fail closed)", %{power: power} do
      buttons = start_buttons(power)
      Simulated.set_available(power.power, false)

      capture_log(fn ->
        tap(buttons, 306, 0)
        tap(buttons, 309, 1_000)
      end)

      assert Buttons.status(buttons).counts.discarded_not_awake == 2
      refute_receive {:dispatched, _command}, 50
    end

    test "without a power monitor at all nothing is dispatched", %{power: power} do
      buttons = start_buttons(power, name: :orphan_buttons, monitor: :no_such_monitor)
      tap(buttons, 306, 0)
      refute_receive {:dispatched, _command}, 50
    end

    test "a button held across standby and wake-up must be released first", %{power: power} do
      buttons = start_buttons(power)

      # Pressed while awake: one action.
      keys(buttons, [{309, 1, 0}])
      assert_receive {:dispatched, :cycle_animation}

      # Still held through a standby and back.
      set_mode(power, :standby)
      keys(buttons, [{309, 2, 500}, {309, 1, 900}])
      set_mode(power, :awake)
      keys(buttons, [{309, 2, 1_500}, {309, 1, 1_600}])
      refute_receive {:dispatched, _command}, 50

      keys(buttons, [{309, 0, 2_000}, {309, 1, 2_500}])
      assert_receive {:dispatched, :cycle_animation}
    end

    test "a button pressed during standby and still held at wake-up does nothing", %{power: power} do
      buttons = start_buttons(power)
      set_mode(power, :standby)
      keys(buttons, [{307, 1, 0}])
      set_mode(power, :awake)
      keys(buttons, [{307, 2, 400}, {307, 2, 433}])
      refute_receive {:dispatched, _command}, 50

      keys(buttons, [{307, 0, 1_000}, {307, 1, 1_300}])
      assert_receive {:dispatched, :toggle_disco}
    end
  end

  describe "device connection" do
    test "the device identity and connection are reported", %{power: power} do
      buttons = start_buttons(power)
      status = Buttons.status(buttons)

      assert status.connection == :connected
      assert status.device.name == "Test encoder"
      assert status.device.vendor == 0x1234
      assert status.device.real_path == "/dev/input/event3"
      refute Map.has_key?(status.device, :keys)
      assert status.mapping.next == 306
      assert status.missing_codes == []
    end

    test "connecting with a key held is not a press", %{power: power} do
      buttons = start_buttons(power)

      capture_log(fn ->
        Buttons.input(buttons, {:disconnected, "enodev"})
        status = connect(buttons, %{held: [306, 999]})
        assert status.held == [306]
      end)

      keys(buttons, [{306, 1, 10}, {306, 2, 260}])
      refute_receive {:dispatched, _command}, 50

      keys(buttons, [{306, 0, 1_000}, {306, 1, 1_400}])
      assert_receive {:dispatched, :next_track}
      refute_receive {:dispatched, _command}, 50
    end

    test "unplugging with a key down and plugging back replays nothing", %{power: power} do
      buttons = start_buttons(power)
      keys(buttons, [{305, 1, 0}])
      assert_receive {:dispatched, :toggle_playback}

      log =
        capture_log(fn ->
          Buttons.input(buttons, {:disconnected, "enodev"})
          status = Buttons.status(buttons)
          assert status.connection == {:disconnected, "enodev"}
          assert status.held == []
          assert status.last_problem == "enodev"

          # Released while unplugged; plugged back in.
          assert connect(buttons).connection == :connected
        end)

      assert log =~ "disconnected"
      refute_receive {:dispatched, _command}, 50

      tap(buttons, 305, 5_000)
      assert_receive {:dispatched, :toggle_playback}
    end

    test "a missing device is a status, said once", %{power: power} do
      buttons = start_buttons(power)

      log =
        capture_log(fn ->
          for _ <- 1..10, do: Buttons.input(buttons, {:waiting, "enoent"})
          assert Buttons.status(buttons).connection == {:waiting, "enoent"}
          Buttons.input(buttons, {:waiting, "eacces"})
          assert Buttons.status(buttons).connection == {:waiting, "eacces"}
        end)

      assert length(String.split(log, "not available")) == 3
    end

    test "lost events (SYN_DROPPED) resynchronise the keys without any action", %{power: power} do
      buttons = start_buttons(power)
      keys(buttons, [{304, 1, 0}])
      assert_receive {:dispatched, :previous_track}

      log =
        capture_log(fn ->
          # While events were lost, 304 was released and 306 pressed.
          Buttons.input(buttons, {:resync, [306], 1_000})
          status = Buttons.status(buttons)
          assert status.held == [306]
          assert status.counts.resyncs == 1
        end)

      assert log =~ "no action taken"
      refute_receive {:dispatched, _command}, 50

      # 306 has to be released before it can act; 304 is free again.
      keys(buttons, [{306, 1, 1_050}, {306, 0, 1_500}, {306, 1, 1_900}, {304, 1, 2_000}])
      assert_receive {:dispatched, :next_track}
      assert_receive {:dispatched, :previous_track}
      refute_receive {:dispatched, _command}, 50
    end

    test "mapped codes the device does not advertise are pointed out", %{power: power} do
      buttons = start_buttons(power)

      log =
        capture_log(fn ->
          status = connect(buttons, %{keys: [304, 305, 306, 307, 308, 309]})
          assert status.missing_codes == [310, 311]
        end)

      assert log =~ "310, 311"
      assert log =~ "brightness_down, brightness_up"
    end

    test "a device with axes and no key is explained", %{power: power} do
      buttons = start_buttons(power)
      log = capture_log(fn -> connect(buttons, %{keys: [], abs?: true}) end)
      assert log =~ "button terminals"
    end

    test "a helper that is down is reported and forgets held keys", %{power: power} do
      buttons = start_buttons(power)
      keys(buttons, [{304, 1, 0}])
      Buttons.input(buttons, {:helper, {:exited, 3}})

      status = Buttons.status(buttons)
      assert status.connection == {:helper_down, {:exited, 3}}
      assert status.held == []
    end
  end

  describe "queues" do
    test "a slow command never blocks the reading of the buttons", %{power: power} do
      test = self()

      slow = fn command ->
        send(test, {:started, command, self()})

        receive do
          :go -> :ok
        end
      end

      buttons = start_buttons(power, dispatch: slow)

      tap(buttons, 306, 0)
      assert_receive {:started, :next_track, music}

      # The music command is stuck; the dispatcher still answers and the other
      # backend still works.
      tap(buttons, 309, 1_000)
      assert_receive {:started, :cycle_animation, local}
      assert Buttons.status(buttons).counts.accepted == 2

      send(music, :go)
      send(local, :go)
    end

    test "music commands that waited too long are dropped, not sent late", %{power: power} do
      test = self()
      id = System.unique_integer([:positive])
      transport = :"short_transport_#{id}"

      start_supervised!(
        Supervisor.child_spec({Lane, name: transport, max_queue: 3, ttl_ms: 40}, id: transport)
      )

      stuck = fn command ->
        send(test, {:started, command, self()})

        receive do
          :go -> :ok
        end
      end

      buttons =
        start_buttons(power,
          name: :"buttons_ttl_#{id}",
          dispatch: stuck,
          transport_lane: transport
        )

      tap(buttons, 306, 0)
      assert_receive {:started, :next_track, first}
      tap(buttons, 304, 1_000)
      tap(buttons, 305, 2_000)

      Process.sleep(80)
      send(first, :go)

      refute_receive {:started, _command, _pid}, 100
      assert %{expired: 2} = Lane.status(transport)
    end
  end

  describe "configuration" do
    test "disabled buttons dispatch nothing even if events arrive", %{power: power} do
      config = %{@config | status: :disabled, mapping: %{}}
      buttons = start_buttons(power, config: config)

      tap(buttons, 306, 0)
      refute_receive {:dispatched, _command}, 50
      assert Buttons.status(buttons).status == :disabled
    end

    test "debug mode logs each decision", %{power: power} do
      # The decisions are logged at info level, which the test configuration
      # normally filters out.
      Logger.put_module_level(Buttons, :info)
      on_exit(fn -> Logger.delete_module_level(Buttons) end)
      buttons = start_buttons(power, config: %{@config | debug?: true})

      log = capture_log(fn -> keys(buttons, [{306, 1, 0}, {306, 0, 100}, {288, 1, 200}]) end)

      assert log =~ "code 306 value 1 (next): press"
      assert log =~ "code 306 value 0 (next): release"
      assert log =~ "code 288 value 1: not assigned"
    end
  end
end
