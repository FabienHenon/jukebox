defmodule Jukebox.Inputs.Fake do
  @moduledoc """
  Fake physical input for development and tests.

  `press/2` simulates a button press. Presses go through
  `Jukebox.Input.Debounce` exactly like a hardware adapter would, then reach
  `Jukebox.Commands.dispatch/1` (or the `:dispatch` function given in the
  options). Returns `:accepted` or `:debounced`.
  """

  @behaviour Jukebox.Input

  use GenServer

  alias Jukebox.Input.Debounce

  @impl Jukebox.Input
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Options: `:name`, `:debounce_ms` (default 80) and `:dispatch`, a one-arity
  function receiving the command (default `&Jukebox.Commands.dispatch/1`).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Simulates a press. Options: `:server` (default `#{inspect(__MODULE__)}`) and
  `:at`, the press time in monotonic milliseconds (default: now).
  """
  @spec press(Jukebox.Input.command(), keyword()) ::
          :accepted | :debounced | {:error, :unknown_command}
  def press(command, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    at = Keyword.get_lazy(opts, :at, fn -> System.monotonic_time(:millisecond) end)
    GenServer.call(server, {:press, command, at})
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       debounce: Debounce.new(Keyword.get(opts, :debounce_ms, 80)),
       dispatch: Keyword.get(opts, :dispatch, &Jukebox.Commands.dispatch/1)
     }}
  end

  @impl GenServer
  def handle_call({:press, command, at}, _from, state) do
    if command in Jukebox.Input.commands() do
      case Debounce.press(state.debounce, command, at) do
        {:accept, debounce} ->
          state.dispatch.(command)
          {:reply, :accepted, %{state | debounce: debounce}}

        {:reject, debounce} ->
          {:reply, :debounced, %{state | debounce: debounce}}
      end
    else
      {:reply, {:error, :unknown_command}, state}
    end
  end
end
