defmodule Jukebox.Playback.Server do
  @moduledoc """
  Single owner of the in-memory playback state.

  Adapters push normalised events with `notify/2`; the server folds them
  through the pure `Jukebox.Playback.State` reducer, runs the resulting
  actions (idle timer scheduling) and broadcasts every *meaningful* change on
  Phoenix PubSub as `{:playback_state, %State{}}`. Newly mounted LiveViews
  read the complete current state with `get_state/1`, so a browser refresh
  never loses the screen.

  ## Coalescing

  Adapters deliver a track change as a burst of small events (track id, each
  text field, artwork, progress), a few milliseconds apart. Applying and
  broadcasting them one at a time shows every half-updated state on screen.
  So events are buffered for `coalesce_ms` (from the first event of a burst),
  consecutive metadata fragments are merged into one bundle, the whole batch
  is folded through the reducer, and a single state is broadcast. Each event
  keeps its own arrival time, so progress stays accurate. `get_state/1`
  returns the last applied state without cutting a burst short (subscribers
  get the result of the burst as a broadcast), `sync/1` flushes the buffer,
  and `coalesce_ms: 0` disables buffering (test default).

  The reducer is wrapped defensively: a malformed event is logged and
  dropped, it never crashes the process (which would discard the state).
  """

  use GenServer
  require Logger

  alias Jukebox.Playback.{Event, State}

  @topic "playback"
  @default_idle_timeout_ms 5_000
  @default_coalesce_ms 150

  # -- client API --------------------------------------------------------------

  @doc """
  Options:

    * `:name` - process name (default `#{inspect(__MODULE__)}`)
    * `:idle_timeout_ms` - grace period after a session ends before the idle
      screen returns; defaults to `config :jukebox, Jukebox.Playback`
    * `:coalesce_ms` - how long a burst of events is buffered before it is
      applied as one batch (0 disables); same config key, default #{@default_coalesce_ms}
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

  @doc "Blocks until every previously sent event has been applied (tests)."
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
       coalesce_ms:
         Keyword.get(
           opts,
           :coalesce_ms,
           Keyword.get(configured, :coalesce_ms, @default_coalesce_ms)
         ),
       pending: [],
       flush_timer: nil,
       pubsub: Keyword.get(opts, :pubsub, Jukebox.PubSub)
     }}
  end

  @impl true
  def handle_call(:get_state, _from, server), do: {:reply, server.playback, server}

  def handle_call(:sync, _from, server), do: {:reply, :ok, flush(server)}

  def handle_call(:reset, _from, server) do
    server = cancel_idle(%{cancel_flush(server) | pending: []})
    playback = %State{metadata_connected?: server.playback.metadata_connected?}
    broadcast(server, playback)
    {:reply, :ok, %{server | playback: playback}}
  end

  @impl true
  def handle_cast({:event, event}, server), do: {:noreply, enqueue(server, event)}

  @impl true
  def handle_info(:flush_pending, server), do: {:noreply, flush(%{server | flush_timer: nil})}

  def handle_info({:idle_timeout, ref}, %{idle_ref: ref} = server) do
    server = flush(%{server | idle_timer: nil, idle_ref: nil})
    {:noreply, apply_batch(server, [{:idle_timeout, DateTime.utc_now()}])}
  end

  def handle_info({:idle_timeout, _stale_ref}, server), do: {:noreply, server}

  def handle_info(message, server) do
    Logger.debug("[playback] ignoring message #{inspect(message)}")
    {:noreply, server}
  end

  # -- internals ---------------------------------------------------------------

  # -- coalescing ---------------------------------------------------------------

  defp enqueue(%{coalesce_ms: 0} = server, event) do
    apply_batch(server, [{event, DateTime.utc_now()}])
  end

  defp enqueue(server, event) do
    pending = push(server.pending, {event, DateTime.utc_now()})

    timer =
      server.flush_timer || Process.send_after(self(), :flush_pending, server.coalesce_ms)

    %{server | pending: pending, flush_timer: timer}
  end

  # Consecutive metadata fragments become one bundle, unless they name two
  # different track ids (two distinct announcements must stay distinct).
  defp push(
         [{{:metadata_changed, earlier}, _} | rest] = pending,
         {{:metadata_changed, later}, at}
       )
       when is_map(earlier) and is_map(later) do
    if conflicting_ids?(earlier, later),
      do: [{{:metadata_changed, later}, at} | pending],
      else: [{{:metadata_changed, merge_fragments(earlier, later)}, at} | rest]
  end

  defp push(pending, entry), do: [entry | pending]

  defp conflicting_ids?(%{track_id: a}, %{track_id: b}) when a != nil and b != nil, do: a != b
  defp conflicting_ids?(_earlier, _later), do: false

  defp merge_fragments(earlier, later) do
    Map.merge(earlier, later, fn _key, old, new -> if new in [nil, ""], do: old, else: new end)
  end

  defp flush(%{pending: []} = server), do: cancel_flush(server)

  defp flush(server) do
    entries = Enum.reverse(server.pending)
    apply_batch(%{cancel_flush(server) | pending: []}, entries)
  end

  defp cancel_flush(%{flush_timer: nil} = server), do: server

  defp cancel_flush(%{flush_timer: timer} = server) do
    Process.cancel_timer(timer)
    %{server | flush_timer: nil}
  end

  # Folds a batch through the reducer and broadcasts the result once.
  defp apply_batch(server, entries) do
    before = server.playback
    server = Enum.reduce(entries, server, fn {event, at}, acc -> apply_event(acc, event, at) end)
    if State.changed?(before, server.playback), do: broadcast(server, server.playback)
    server
  end

  defp apply_event(server, event, at) do
    if event == :idle_timeout or Event.valid?(event) do
      try do
        {playback, actions} = State.apply_event(server.playback, event, at)
        server = Enum.reduce(actions, server, &run_action/2)
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
