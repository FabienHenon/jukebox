defmodule Jukebox.Inputs.Simulated do
  @moduledoc """
  A pretend input device for development and tests
  (`JUKEBOX_BUTTONS_SOURCE=simulated`).

  Where `Jukebox.Inputs.Fake` injects semantic commands, this adapter injects
  raw key events (code, down/up/repeat), exactly what the evdev helper would
  report, so everything behind it is the real thing: mapping, debounce, the
  standby gate and the queues of `Jukebox.Hardware.Buttons`.
  """

  @behaviour Jukebox.Input

  use GenServer

  alias Jukebox.Hardware.Buttons

  @impl Jukebox.Input
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Options: `:name`, `:sink` (the buttons dispatcher) and `:keys`, the key
  codes the pretend device advertises.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Key down."
  def press(server \\ __MODULE__, code), do: GenServer.call(server, {:key, code, 1})

  @doc "Key up."
  def release(server \\ __MODULE__, code), do: GenServer.call(server, {:key, code, 0})

  @doc "Kernel auto-repeat of a held key."
  def repeat(server \\ __MODULE__, code), do: GenServer.call(server, {:key, code, 2})

  @doc "A complete press: down, then up."
  def tap(server \\ __MODULE__, code) do
    press(server, code)
    release(server, code)
  end

  @doc "Unplugs the pretend device."
  def disconnect(server \\ __MODULE__), do: GenServer.call(server, :disconnect)

  @doc "Plugs it back in, with `held` keys down."
  def connect(server \\ __MODULE__, held \\ []), do: GenServer.call(server, {:connect, held})

  @impl GenServer
  def init(opts) do
    state = %{sink: Keyword.get(opts, :sink, Buttons), keys: Keyword.get(opts, :keys, [])}
    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    announce(state, [])
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:key, code, value}, _from, state) do
    Buttons.input(state.sink, {:key, code, value, System.monotonic_time(:millisecond)})
    {:reply, :ok, state}
  end

  def handle_call(:disconnect, _from, state) do
    Buttons.input(state.sink, {:disconnected, "simulated"})
    {:reply, :ok, state}
  end

  def handle_call({:connect, held}, _from, state) do
    announce(state, held)
    {:reply, :ok, state}
  end

  defp announce(state, held) do
    Buttons.input(
      state.sink,
      {:connected,
       %{
         name: "Simulated button encoder",
         vendor: nil,
         product: nil,
         version: nil,
         phys: nil,
         path: nil,
         real_path: nil,
         abs?: false,
         keys: state.keys,
         held: held
       }}
    )
  end
end
