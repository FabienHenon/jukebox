defmodule Jukebox.Input.DebounceTest do
  use ExUnit.Case, async: true

  alias Jukebox.Input.Debounce

  test "accepts the first press and rejects bounce inside the window" do
    debounce = Debounce.new(80)
    assert {:accept, debounce} = Debounce.press(debounce, :next_track, 1_000)
    assert {:reject, debounce} = Debounce.press(debounce, :next_track, 1_005)
    assert {:reject, debounce} = Debounce.press(debounce, :next_track, 1_079)
    assert {:accept, _} = Debounce.press(debounce, :next_track, 1_080)
  end

  test "rejected presses do not extend the window" do
    debounce = Debounce.new(80)
    {:accept, debounce} = Debounce.press(debounce, :next_track, 0)
    {:reject, debounce} = Debounce.press(debounce, :next_track, 70)
    assert {:accept, _} = Debounce.press(debounce, :next_track, 85)
  end

  test "commands are debounced independently" do
    debounce = Debounce.new(80)
    {:accept, debounce} = Debounce.press(debounce, :next_track, 0)
    assert {:accept, _} = Debounce.press(debounce, :previous_track, 1)
  end

  test "a zero window accepts everything" do
    debounce = Debounce.new(0)
    {:accept, debounce} = Debounce.press(debounce, :next_track, 0)
    assert {:accept, _} = Debounce.press(debounce, :next_track, 0)
  end
end
