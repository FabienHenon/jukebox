defmodule Jukebox.Test.FakeRemoteControl do
  @moduledoc """
  Remote-control adapter for tests. `Jukebox.Commands.dispatch/2` invokes the
  adapter in the calling process, so behaviour is configured through the
  test process dictionary and every command sends a message back to the test.
  """

  @behaviour Jukebox.RemoteControl

  @default_capabilities MapSet.new([:previous_track, :toggle_playback, :next_track])

  @doc "Configure capabilities and the result every command returns."
  def configure(opts) do
    Process.put(:fake_rc_capabilities, Keyword.get(opts, :capabilities, @default_capabilities))
    Process.put(:fake_rc_result, Keyword.get(opts, :result, :ok))
  end

  @impl true
  def capabilities, do: Process.get(:fake_rc_capabilities, @default_capabilities)

  @impl true
  def previous_track, do: command(:previous_track)

  @impl true
  def toggle_playback, do: command(:toggle_playback)

  @impl true
  def next_track, do: command(:next_track)

  defp command(name) do
    send(self(), {:remote_control, name})

    case Process.get(:fake_rc_result, :ok) do
      :raise -> raise "boom"
      :exit -> exit(:boom)
      result -> result
    end
  end
end
