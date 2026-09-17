defmodule Jukebox.Inputs.FakeTest do
  use ExUnit.Case, async: true

  alias Jukebox.Inputs.Fake

  setup do
    test_pid = self()
    name = :"fake_input_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Fake,
       name: name,
       debounce_ms: 80,
       dispatch: fn command -> send(test_pid, {:dispatched, command}) end}
    )

    {:ok, name: name}
  end

  test "an accepted press is dispatched as a semantic command", %{name: name} do
    assert Fake.press(:next_track, server: name, at: 1_000) == :accepted
    assert_receive {:dispatched, :next_track}
  end

  test "switch bounce never produces repeated commands", %{name: name} do
    assert Fake.press(:toggle_playback, server: name, at: 0) == :accepted
    assert Fake.press(:toggle_playback, server: name, at: 3) == :debounced
    assert Fake.press(:toggle_playback, server: name, at: 40) == :debounced
    assert Fake.press(:toggle_playback, server: name, at: 79) == :debounced
    assert_receive {:dispatched, :toggle_playback}
    refute_receive {:dispatched, _}, 20
    assert Fake.press(:toggle_playback, server: name, at: 80) == :accepted
    assert_receive {:dispatched, :toggle_playback}
  end

  test "unknown commands are rejected", %{name: name} do
    assert Fake.press(:volume_up, server: name) == {:error, :unknown_command}
    refute_receive {:dispatched, _}, 20
  end
end
