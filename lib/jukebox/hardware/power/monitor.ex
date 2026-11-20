defmodule Jukebox.Hardware.Power.Monitor do
  @moduledoc """
  The application's view of the power controller: which mode the jukebox is
  in (`:awake`, `:standby`, ...) and what the controller commanded on each
  output.

  It lives in the supervision tree, independently of any browser, and reads
  the controller's state through a reader function (the state file in
  production, `Jukebox.Hardware.Power.Simulated` in development). It only
  ever observes: it cannot wake the jukebox up.

  Anything that keeps the state from being read and trusted (missing file,
  wrong owner, stale heartbeat, unknown schema) gives the mode `:unknown`,
  and `:unknown` blocks the buttons exactly like standby does.

  The state is read on a short timer, and again on every `snapshot/1`, so a
  decision is never taken on a remembered value. Changes are broadcast on
  PubSub as `{:power_state, snapshot}`.
  """

  use GenServer

  require Logger

  @topic "hardware:power"
  @default_poll_ms 500

  @type mode :: :booting | :awake | :standby | :shutting_down | :unknown

  @type snapshot :: %{
          mode: mode(),
          fresh?: boolean(),
          reason: term() | nil,
          instance: String.t() | nil,
          revision: non_neg_integer() | nil,
          pid: integer() | nil,
          age_ms: non_neg_integer() | nil,
          outputs: map()
        }

  def topic, do: @topic

  @doc "Subscribes the caller to `{:power_state, snapshot}` messages."
  def subscribe(pubsub \\ Jukebox.PubSub), do: Phoenix.PubSub.subscribe(pubsub, @topic)

  @doc """
  Options:

    * `:name` - registered name (default: this module)
    * `:reader` - zero-arity function returning `{:ok, state}` or
      `{:error, reason}` (see `Jukebox.Hardware.Power.StateFile.read/2`)
    * `:poll_ms` - how often the state is read (default #{@default_poll_ms})
    * `:pubsub` - PubSub server to broadcast on
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The current state, read now. When the monitor is not running or does not
  answer in time the mode is `:unknown`.
  """
  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot, 1_000)
  catch
    :exit, _reason -> unknown(:monitor_unavailable)
  end

  @doc "The current mode, read now."
  @spec mode(GenServer.server()) :: mode()
  def mode(server \\ __MODULE__), do: snapshot(server).mode

  @doc "True only when the controller is known, right now, to be awake."
  @spec awake?(GenServer.server()) :: boolean()
  def awake?(server \\ __MODULE__), do: mode(server) == :awake

  # -- callbacks ---------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      reader: Keyword.fetch!(opts, :reader),
      poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
      pubsub: Keyword.get(opts, :pubsub, Jukebox.PubSub),
      snapshot: unknown(:not_read_yet),
      logged: nil
    }

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, state |> refresh() |> schedule()}

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh(state)
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_info(:poll, state), do: {:noreply, state |> refresh() |> schedule()}
  def handle_info(_message, state), do: {:noreply, state}

  # -- internals ---------------------------------------------------------------

  defp schedule(%{poll_ms: nil} = state), do: state

  defp schedule(state) do
    Process.send_after(self(), :poll, state.poll_ms)
    state
  end

  defp refresh(state) do
    snapshot = read(state.reader)

    if significant(snapshot) != significant(state.snapshot) do
      Phoenix.PubSub.broadcast(state.pubsub, @topic, {:power_state, snapshot})
    end

    log(%{state | snapshot: snapshot})
  end

  defp read(reader) do
    case reader.() do
      {:ok, %{mode: mode} = power} ->
        %{
          mode: mode,
          fresh?: true,
          reason: nil,
          instance: power.instance,
          revision: power.revision,
          pid: Map.get(power, :pid),
          age_ms: Map.get(power, :age_ms),
          outputs: power.outputs
        }

      {:error, reason} ->
        unknown(reason)

      other ->
        unknown({:invalid_reader_result, other})
    end
  rescue
    exception -> unknown({:reader_raised, Exception.message(exception)})
  catch
    :exit, reason -> unknown({:reader_exited, reason})
  end

  defp unknown(reason) do
    %{
      mode: :unknown,
      fresh?: false,
      reason: reason,
      instance: nil,
      revision: nil,
      pid: nil,
      age_ms: nil,
      outputs: %{}
    }
  end

  # What subscribers care about; the age changes at every read and is left out.
  defp significant(snapshot),
    do: Map.take(snapshot, [:mode, :reason, :instance, :revision, :outputs])

  # One line per change of mode or of failure reason, never one per poll.
  defp log(state) do
    key = {state.snapshot.mode, state.snapshot.reason}

    cond do
      key == state.logged ->
        state

      state.snapshot.mode == :unknown ->
        Logger.warning(
          "[power] controller state unavailable (#{inspect(state.snapshot.reason)}); " <>
            "buttons, lights and brightness stay blocked until it is readable again"
        )

        %{state | logged: key}

      true ->
        Logger.info("[power] mode #{state.snapshot.mode}")
        %{state | logged: key}
    end
  end
end
