defmodule Jukebox.Hardware.Buttons.TrackerTest do
  use ExUnit.Case, async: true

  alias Jukebox.Hardware.Buttons.Tracker

  # Applies `{code, value, ms}` events and returns the decisions.
  defp run(tracker, events) do
    Enum.map_reduce(events, tracker, fn {code, value, ms}, tracker ->
      Tracker.key(tracker, code, value, ms)
    end)
  end

  test "press then release is one press" do
    {decisions, tracker} = run(Tracker.new(80), [{304, 1, 1_000}, {304, 0, 1_120}])
    assert decisions == [:press, :release]
    assert Tracker.held(tracker) == []
  end

  test "repeated key-down reports and kernel repeats of a held key do nothing" do
    {decisions, tracker} =
      run(Tracker.new(80), [
        {304, 1, 0},
        {304, 1, 5},
        {304, 2, 250},
        {304, 2, 283},
        {304, 1, 900},
        {304, 2, 5_000}
      ])

    assert decisions == [:press, :duplicate, :repeat, :repeat, :duplicate, :repeat]
    assert Tracker.held(tracker) == [304]
  end

  test "contact bounce on the way down gives one press and leaves nothing stuck" do
    {decisions, tracker} =
      run(Tracker.new(80), [
        {304, 1, 0},
        {304, 0, 3},
        {304, 1, 6},
        {304, 0, 9},
        {304, 1, 12},
        {304, 0, 150}
      ])

    assert decisions == [:press, :release, :bounce, :release, :bounce, :release]
    assert Tracker.held(tracker) == []

    # A release right after the press is honoured: the next real press works.
    assert {:press, _tracker} = Tracker.key(tracker, 304, 1, 400)
  end

  test "contact bounce on the way up after a long hold is not a second press" do
    {decisions, tracker} =
      run(Tracker.new(80), [{304, 1, 0}, {304, 0, 3_000}, {304, 1, 3_004}, {304, 0, 3_009}])

    assert decisions == [:press, :release, :bounce, :release]
    assert Tracker.held(tracker) == []
  end

  test "a long hold is one press, and the key must be released before the next" do
    tracker = Tracker.new(80)
    {:press, tracker} = Tracker.key(tracker, 304, 1, 0)

    tracker =
      Enum.reduce(1..300, tracker, fn i, tracker ->
        {:repeat, tracker} = Tracker.key(tracker, 304, 2, 250 + i * 33)
        tracker
      end)

    {:release, tracker} = Tracker.key(tracker, 304, 0, 12_000)
    assert {:press, _tracker} = Tracker.key(tracker, 304, 1, 12_500)
  end

  test "buttons held together are independent" do
    {decisions, tracker} =
      run(Tracker.new(80), [{304, 1, 0}, {305, 1, 10}, {306, 1, 20}, {305, 0, 200}, {305, 1, 400}])

    assert decisions == [:press, :press, :press, :release, :press]
    assert Tracker.held(tracker) == [304, 305, 306]
  end

  test "the debounce window is per key and configurable" do
    {decisions, _tracker} =
      run(Tracker.new(80), [{304, 1, 0}, {304, 0, 20}, {304, 1, 79}, {304, 0, 90}, {304, 1, 170}])

    assert decisions == [:press, :release, :bounce, :release, :press]

    {decisions, _tracker} = run(Tracker.new(0), [{304, 1, 0}, {304, 0, 1}, {304, 1, 2}])
    assert decisions == [:press, :release, :press]
  end

  test "a key held when the device connects does nothing until released" do
    tracker = Tracker.connected(Tracker.new(80), [305])
    assert Tracker.held(tracker) == [305]

    {decisions, tracker} =
      run(tracker, [{305, 1, 10}, {305, 2, 300}, {304, 1, 400}, {305, 0, 1_000}, {305, 1, 1_500}])

    assert decisions == [:duplicate, :repeat, :press, :release, :press]
    assert Tracker.held(tracker) == [304, 305]
  end

  test "a disconnection forgets what was held; reconnecting with it still down is not a press" do
    {:press, tracker} = Tracker.key(Tracker.new(80), 304, 1, 0)
    tracker = Tracker.disconnected(tracker)
    assert Tracker.held(tracker) == []

    tracker = Tracker.connected(tracker, [304])
    assert {:duplicate, tracker} = Tracker.key(tracker, 304, 1, 5_000)
    {:release, tracker} = Tracker.key(tracker, 304, 0, 5_100)
    assert {:press, _tracker} = Tracker.key(tracker, 304, 1, 5_400)
  end

  test "a resynchronisation adopts the device's state without a press or a stuck key" do
    {:press, tracker} = Tracker.key(Tracker.new(80), 304, 1, 0)

    # Events were lost: 304 was released and 305 pressed in the meantime.
    tracker = Tracker.resync(tracker, [305], 1_000)
    assert Tracker.held(tracker) == [305]

    # 305 is held, so its lost press is not replayed...
    assert {:duplicate, tracker} = Tracker.key(tracker, 305, 1, 1_010)
    # ...and 304 works again, once clear of the release that was just inferred.
    assert {:bounce, tracker} = Tracker.key(tracker, 304, 1, 1_020)
    {:release, tracker} = Tracker.key(tracker, 304, 0, 1_030)
    assert {:press, _tracker} = Tracker.key(tracker, 304, 1, 1_200)
  end
end
