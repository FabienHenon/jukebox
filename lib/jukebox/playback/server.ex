defmodule Jukebox.Playback.Server do
  @moduledoc """
  Single owner of the in-memory playback state.

  Adapters push normalised events with `notify/2`; the server folds them
  through the pure `Jukebox.Playback.State` reducer, runs the resulting
  actions (idle timer scheduling) and broadcasts every *meaningful* change on
  Phoenix PubSub as `{:playback_state, %State{}}`. Newly mounted LiveViews
  read the complete current state with `get_state/1`, so a browser refresh
  never loses the screen.

  The reducer is wrapped defensively: a malformed event is logged and
  dropped, it never crashes the process (which would discard the state).
  """

  use GenServer
  require Logger

  alias Jukebox.Playback.{Event, State}

  @topic "playback"
  @default_idle_timeout_ms 5_000

  # -- client API --------------------------------------------------------------

  @doc """
  Options:

    * `:name` - process name (default `#{inspect(__MODULE__)}`)
    * `:idle_timeout_ms` - grace period after a session ends before the idle
      screen returns; defaults to `config :jukebox, Jukebox.Playback`
    * `:pubsub` - PubSub server to broadcast on (default `Jukebox.PubSub`)
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Returns the complete current state."
  @spec get_state(GenServer.server()) :: State.t()
  def get_state(server \\ __MODULE__), do: GenServer.call(server, :get_state)

  @doc "Sends a normalised event (asynchronous)."
  @spec notify(GenServer.server(), Event.t()) :: :ok
  def notify(server \\ __MODULE__, event), do: GenServer.cast(server, {:event, event})

  @doc "Blocks until every previously sent event has been processed (tests)."
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  @doc "Resets to the initial inactive state and broadcasts it (tests, simulator)."
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @doc "Subscribes the caller to `{:playback_state, state}` broadcasts."
  def subscribe(pubsub \\ Jukebox.PubSub), do: Phoenix.PubSub.subscribe(pubsub, @topic)

  def topic, do: @topic

  # -- callbacks ---------------------------------------------------------------

  @impl true
  def init(opts) do
    configured = Application.get_env(:jukebox, Jukebox.Playback, [])

    {:ok,
     %{
       playback: State.new(),
       idle_timeout_ms:
         Keyword.get(opts, :idle_timeout_ms) ||
           Keyword.get(configured, :idle_timeout_ms, @default_idle_timeout_ms),
       idle_timer: nil,
       idle_ref: nil,
       pubsub: Keyword.get(opts, :pubsub, Jukebox.PubSub)
     }}
  end

  @impl true
  def handle_call(:get_state, _from, server), do: {:reply, server.playback, server}
  def handle_call(:sync, _from, server), do: {:reply, :ok, server}

  def handle_call(:reset, _from, server) do
    server = cancel_idle(server)
    playback = %State{metadata_connected?: server.playback.metadata_connected?}
    broadcast(server, playback)
    {:reply, :ok, %{server | playback: playback}}
  end

  @impl true
  def handle_cast({:event, event}, server), do: {:noreply, apply_event(server, event)}

  @impl true
  def handle_info({:idle_timeout, ref}, %{idle_ref: ref} = server) do
    {:noreply, apply_event(%{server | idle_timer: nil, idle_ref: nil}, :idle_timeout)}
  end

  def handle_info({:idle_timeout, _stale_ref}, server), do: {:noreply, server}

  def handle_info(message, server) do
    Logger.debug("[playback] ignoring message #{inspect(message)}")
    {:noreply, server}
  end

  # -- internals ---------------------------------------------------------------

  defp apply_event(server, event) do
    if event == :idle_timeout or Event.valid?(event) do
      try do
        {playback, actions} = State.apply_event(server.playback, event, DateTime.utc_now())
        server = Enum.reduce(actions, server, &run_action/2)
        if State.changed?(server.playback, playback), do: broadcast(server, playback)
        %{server | playback: playback}
      rescue
        exception ->
          Logger.error(
            "[playback] failed to apply #{inspect(event, limit: 8, printable_limit: 80)}: " <>
              Exception.message(exception)
          )

          server
      end
    else
      Logger.warning("[playback] ignoring unknown event #{inspect(event, limit: 8)}")
      server
    end
  end

  defp run_action(:cancel_idle, server), do: cancel_idle(server)

  defp run_action(:schedule_idle, server) do
    server = cancel_idle(server)
    ref = make_ref()
    timer = Process.send_after(self(), {:idle_timeout, ref}, server.idle_timeout_ms)
    %{server | idle_timer: timer, idle_ref: ref}
  end

  defp cancel_idle(%{idle_timer: nil} = server), do: server

  defp cancel_idle(%{idle_timer: timer} = server) do
    Process.cancel_timer(timer)
    %{server | idle_timer: nil, idle_ref: nil}
  end

  defp broadcast(%{pubsub: pubsub}, playback) do
    Phoenix.PubSub.broadcast(pubsub, @topic, {:playback_state, playback})
  end
end
