defmodule Jukebox.MetadataSources.Demo do
  @moduledoc """
  Demo metadata source: a fake AirPlay sender for development and tests.

  It keeps a tiny simulated player (session flag, current track, playback
  status, position) and emits the same normalised events a real adapter
  would, in the same order Shairport Sync produces them: track identity and
  text first, artwork afterwards, then progress and play status.

  The optional tick timer (`:tick_ms`) advances the position while playing,
  emits a progress resync every few ticks and moves to the next track at the
  end. It is disabled (`tick_ms: nil`) in the test environment so tests stay
  deterministic.

  Every public function returns `{:error, :not_running}` when the demo
  source is not part of the current supervision tree (production).
  """

  @behaviour Jukebox.MetadataSource

  use GenServer

  alias Jukebox.Demo.Catalog
  alias Jukebox.Playback
  alias Jukebox.Playback.Artwork

  @metadata_fields [:title, :artist, :album, :genre, :duration_ms]
  @progress_every_ticks 5
  @default_source_name "Fabien's iPhone"

  @impl Jukebox.MetadataSource
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Options: `:name`, `:playback` (playback server, default
  `Jukebox.Playback.Server`), `:tick_ms` (nil disables the timer),
  `:auto_connect` (emit a connected metadata link on start, default true).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # -- simulator API -----------------------------------------------------------

  @doc """
  Starts a demo AirPlay session. Options:

    * `:server` - demo process (default `#{inspect(__MODULE__)}`)
    * `:source_name` - device name announced by the fake sender
    * `:delay_ms` - deliver track metadata only after this delay
    * `:partial` - list of metadata fields to send (subset of
      `#{inspect(@metadata_fields)}`); everything else is withheld
    * `:artwork` - send artwork (default true)
  """
  def start_session(opts \\ []), do: call(opts, {:start_session, opts})

  def end_session(opts \\ []), do: call(opts, :end_session)
  def play(opts \\ []), do: call(opts, {:set_status, :playing})
  def pause(opts \\ []), do: call(opts, {:set_status, :paused})
  def stop(opts \\ []), do: call(opts, {:set_status, :stopped})
  def toggle(opts \\ []), do: call(opts, :toggle)
  def next_track(opts \\ []), do: call(opts, {:step, 1})
  def previous_track(opts \\ []), do: call(opts, {:step, -1})
  def select_track(index, opts \\ []) when is_integer(index), do: call(opts, {:select, index})
  def load_preset(key, opts \\ []) when is_atom(key), do: call(opts, {:preset, key})

  @doc "Edits title/artist/album of the current track (becomes a new track identity)."
  def update_track(attrs, opts \\ []) when is_map(attrs), do: call(opts, {:update_track, attrs})

  @doc "Selects a bundled demo cover (1..4) or removes artwork with nil."
  def set_artwork(artwork, opts \\ []) when is_nil(artwork) or is_integer(artwork),
    do: call(opts, {:set_artwork, artwork})

  def set_progress(position_ms, duration_ms, opts \\ []),
    do: call(opts, {:set_progress, position_ms, duration_ms})

  def set_remote_control(value, opts \\ []) when value in [:available, :unavailable],
    do: call(opts, {:set_remote_control, value})

  def set_metadata_connection(value, opts \\ []) when value in [:connected, :disconnected],
    do: call(opts, {:set_metadata_connection, value})

  @doc "Current simulated player state (for the simulator UI)."
  def snapshot(opts \\ []), do: call(opts, :snapshot)

  @doc "Ends any session and restores the defaults (first track, artwork, remote available, link connected)."
  def reset(opts \\ []), do: call(opts, :reset)

  defp call(opts, message) do
    server = Keyword.get(opts, :server, __MODULE__)

    case GenServer.whereis(server) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, message)
    end
  end

  # -- callbacks ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      playback: Keyword.get(opts, :playback, Playback.Server),
      tick_ms: Keyword.get(opts, :tick_ms),
      timer: nil,
      session?: false,
      source_name: @default_source_name,
      source_model: "iPhone",
      index: 0,
      track: Catalog.track(0),
      artwork: Catalog.track(0).artwork,
      status: :stopped,
      position_ms: 0,
      ticks: 0,
      edits: 0,
      remote: :available,
      connected?: true,
      partial: @metadata_fields,
      send_artwork?: true
    }

    if Keyword.get(opts, :auto_connect, true) do
      emit(state, {:metadata_connection_changed, :connected})
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:start_session, opts}, _from, state) do
    partial =
      Keyword.get(opts, :partial, @metadata_fields) |> Enum.filter(&(&1 in @metadata_fields))

    state = %{
      state
      | session?: true,
        status: :playing,
        position_ms: 0,
        ticks: 0,
        source_name: Keyword.get(opts, :source_name, state.source_name),
        partial: partial,
        send_artwork?: Keyword.get(opts, :artwork, true)
    }

    emit(
      state,
      {:session_started, %{source_name: state.source_name, source_model: state.source_model}}
    )

    emit(state, {:remote_control_changed, state.remote})

    state =
      case Keyword.get(opts, :delay_ms) do
        delay when is_integer(delay) and delay > 0 ->
          Process.send_after(self(), :deliver_track, delay)
          state

        _ ->
          deliver_track(state)
      end

    {:reply, :ok, schedule_tick(state)}
  end

  def handle_call(:end_session, _from, state) do
    state = %{state | session?: false, status: :stopped}
    emit(state, {:session_ended, %{reason: :sender_disconnected}})
    {:reply, :ok, cancel_tick(state)}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  def handle_call(:reset, _from, state) do
    state = cancel_tick(state)
    if state.session?, do: emit(%{state | connected?: true}, {:session_ended, %{reason: :reset}})

    state = %{
      state
      | session?: false,
        status: :stopped,
        index: 0,
        track: Catalog.track(0),
        artwork: Catalog.track(0).artwork,
        position_ms: 0,
        ticks: 0,
        edits: 0,
        remote: :available,
        connected?: true,
        partial: @metadata_fields,
        send_artwork?: true,
        source_name: @default_source_name
    }

    emit(state, {:metadata_connection_changed, :connected})
    {:reply, :ok, state}
  end

  def handle_call({:set_remote_control, value}, _from, state) do
    state = %{state | remote: value}
    emit(state, {:remote_control_changed, value})
    {:reply, :ok, state}
  end

  def handle_call({:set_metadata_connection, value}, _from, state) do
    state =
      case value do
        :disconnected ->
          state = %{state | connected?: true}
          emit(state, {:metadata_connection_changed, :disconnected})
          %{state | connected?: false}

        :connected ->
          state = %{state | connected?: true}
          emit(state, {:metadata_connection_changed, :connected})
          if state.session?, do: resend_snapshot(state), else: state
      end

    {:reply, :ok, state}
  end

  def handle_call({:select, index}, _from, state) do
    track = Catalog.track(index)
    {:reply, :ok, load_track(state, Integer.mod(index, Catalog.count()), track)}
  end

  def handle_call({:step, delta}, _from, state) do
    if state.session? do
      index = Integer.mod(state.index + delta, Catalog.count())
      {:reply, :ok, load_track(state, index, Catalog.track(index))}
    else
      {:reply, {:error, :no_session}, state}
    end
  end

  def handle_call({:preset, key}, _from, state) do
    case Catalog.preset(key) do
      nil -> {:reply, {:error, :unknown_preset}, state}
      track -> {:reply, :ok, load_track(state, state.index, track)}
    end
  end

  def handle_call({:update_track, attrs}, _from, state) do
    edits = state.edits + 1
    base_id = state.track.id |> String.split("-v") |> hd()

    track =
      state.track
      |> Map.merge(Map.take(attrs, [:title, :artist, :album, :genre]))
      |> Map.put(:id, "#{base_id}-v#{edits}")

    state = %{state | track: track, edits: edits}
    {:reply, :ok, if(state.session?, do: deliver_track(state), else: state)}
  end

  def handle_call({:set_artwork, artwork}, _from, state) do
    state = %{state | artwork: artwork}

    if state.session?,
      do: emit(state, {:artwork_changed, artwork_ref(state), track_id: state.track.id})

    {:reply, :ok, state}
  end

  def handle_call({:set_progress, position_ms, duration_ms}, _from, state) do
    track = Map.put(state.track, :duration_ms, duration_ms)
    state = %{state | track: track, position_ms: position_ms, ticks: 0}

    if state.session?,
      do: emit(state, {:progress_changed, %{position_ms: position_ms, duration_ms: duration_ms}})

    {:reply, :ok, state}
  end

  def handle_call(:toggle, from, state) do
    target = if state.status == :playing, do: :paused, else: :playing
    handle_call({:set_status, target}, from, state)
  end

  def handle_call({:set_status, status}, _from, state) do
    cond do
      not state.session? ->
        {:reply, {:error, :no_session}, state}

      status == state.status ->
        {:reply, :ok, state}

      true ->
        state = %{state | status: status}
        state = if status == :stopped, do: %{state | position_ms: 0, ticks: 0}, else: state

        if status == :playing do
          emit(state, {:progress_changed, progress_of(state)})
        end

        emit(state, {:playback_changed, status})
        {:reply, :ok, schedule_tick(state)}
    end
  end

  @impl GenServer
  def handle_info(:deliver_track, state) do
    {:noreply, if(state.session?, do: deliver_track(state), else: state)}
  end

  def handle_info(:tick, %{session?: true, status: :playing} = state) do
    position = state.position_ms + state.tick_ms
    duration = state.track.duration_ms
    ticks = state.ticks + 1
    state = %{state | timer: nil, position_ms: position, ticks: ticks}

    state =
      cond do
        is_integer(duration) and position >= duration ->
          index = Integer.mod(state.index + 1, Catalog.count())
          load_track(state, index, Catalog.track(index))

        rem(ticks, @progress_every_ticks) == 0 ->
          emit(state, {:progress_changed, progress_of(state)})
          state

        true ->
          state
      end

    {:noreply, schedule_tick(state)}
  end

  def handle_info(:tick, state), do: {:noreply, %{state | timer: nil}}

  # -- internals ---------------------------------------------------------------

  defp load_track(state, index, track) do
    state = %{
      state
      | index: index,
        track: track,
        artwork: track.artwork,
        position_ms: 0,
        ticks: 0
    }

    if state.session? do
      state = %{state | status: :playing}
      state |> deliver_track() |> schedule_tick()
    else
      state
    end
  end

  # Emits the metadata bundle for the current track in Shairport order:
  # identity + text, then artwork, then progress, then play status.
  defp deliver_track(state) do
    track = state.track
    fields = track |> Map.take(state.partial) |> Map.put(:track_id, track.id)
    emit(state, {:track_changed, fields})

    artwork = if state.send_artwork?, do: artwork_ref(state), else: nil
    emit(state, {:artwork_changed, artwork, track_id: track.id})

    if :duration_ms in state.partial do
      emit(state, {:progress_changed, progress_of(state)})
    end

    emit(state, {:playback_changed, state.status})
    state
  end

  defp resend_snapshot(state) do
    emit(
      state,
      {:session_started, %{source_name: state.source_name, source_model: state.source_model}}
    )

    emit(state, {:remote_control_changed, state.remote})
    deliver_track(state)
  end

  defp artwork_ref(%{artwork: n}) when is_integer(n) and n in 1..4, do: Artwork.demo(n)
  defp artwork_ref(_state), do: nil

  defp progress_of(state) do
    %{position_ms: state.position_ms, duration_ms: state.track.duration_ms}
  end

  defp emit(%{connected?: false}, _event), do: :dropped
  defp emit(state, event), do: Playback.Server.notify(state.playback, event)

  defp schedule_tick(%{tick_ms: nil} = state), do: state
  defp schedule_tick(%{timer: timer} = state) when timer != nil, do: state

  defp schedule_tick(%{session?: true, status: :playing} = state) do
    %{state | timer: Process.send_after(self(), :tick, state.tick_ms)}
  end

  defp schedule_tick(state), do: state

  defp cancel_tick(%{timer: nil} = state), do: state

  defp cancel_tick(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp snapshot_of(state) do
    %{
      session?: state.session?,
      status: state.status,
      index: state.index,
      track: state.track,
      artwork: state.artwork,
      position_ms: state.position_ms,
      remote: state.remote,
      connected?: state.connected?,
      source_name: state.source_name
    }
  end
end
