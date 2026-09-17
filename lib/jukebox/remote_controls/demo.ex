defmodule Jukebox.RemoteControls.Demo do
  @moduledoc """
  Demo remote control: forwards transport commands to the demo metadata
  source (so the simulated "iPhone" reacts) and records every command it
  received for inspection in the simulator and in tests.

  `set_failure/1` makes subsequent commands fail with the given reason, which
  is how tests exercise the command-error path.
  """

  @behaviour Jukebox.RemoteControl

  use GenServer

  alias Jukebox.MetadataSources.Demo

  @capabilities MapSet.new([:previous_track, :toggle_playback, :next_track])
  @history_limit 20

  @impl Jukebox.RemoteControl
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Jukebox.RemoteControl
  def capabilities, do: @capabilities

  @impl Jukebox.RemoteControl
  def previous_track, do: send_command(:previous_track)

  @impl Jukebox.RemoteControl
  def toggle_playback, do: send_command(:toggle_playback)

  @impl Jukebox.RemoteControl
  def next_track, do: send_command(:next_track)

  @doc "Commands received, most recent first."
  def commands(server \\ __MODULE__), do: GenServer.call(server, :commands)

  @doc "The last semantic command received, or nil."
  def last_command(server \\ __MODULE__), do: server |> commands() |> List.first()

  @doc "Makes every following command fail with `reason` (nil restores success)."
  def set_failure(server \\ __MODULE__, reason),
    do: GenServer.call(server, {:set_failure, reason})

  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  defp send_command(command) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:command, command})
    end
  end

  @impl GenServer
  def init(opts) do
    {:ok, %{commands: [], failure: nil, demo: Keyword.get(opts, :demo_source, Demo)}}
  end

  @impl GenServer
  def handle_call({:command, command}, _from, state) do
    state = %{state | commands: Enum.take([command | state.commands], @history_limit)}

    result =
      case state.failure do
        nil -> forward(command, state.demo)
        reason -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call(:commands, _from, state), do: {:reply, state.commands, state}

  def handle_call({:set_failure, reason}, _from, state),
    do: {:reply, :ok, %{state | failure: reason}}

  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | commands: [], failure: nil}}

  defp forward(:previous_track, demo), do: Demo.previous_track(server: demo)
  defp forward(:next_track, demo), do: Demo.next_track(server: demo)
  defp forward(:toggle_playback, demo), do: Demo.toggle(server: demo)
end
