defmodule Jukebox.Hardware.Lane do
  @moduledoc """
  A small bounded queue that runs one job at a time.

  The button dispatcher must stay responsive while a remote-control command is
  being published or an external helper is running, so slow work is handed to a
  lane instead of being done where the key event arrives. Each backend has its
  own lane, which keeps a stuck one from holding up the others.

  A lane never grows without limit and never replays old work:

    * at most `:max_queue` jobs wait behind the running one; a job submitted
      beyond that is dropped;
    * a job that waited longer than `:ttl_ms` is dropped instead of being run
      late (a "next track" pressed five seconds ago is no longer wanted);
    * a job that runs longer than `:job_timeout_ms` is stopped.

  Jobs run in their own process, linked to the lane, so stopping the lane stops
  the job (and `Jukebox.Hardware.Exec` then kills what the job had started).

  A job submitted with `:reply_to` reports back with `{tag, outcome}` where the
  outcome is `{:done, result}`, `{:dropped, :overflow | :expired}` or
  `{:failed, reason}`.
  """

  use GenServer

  require Logger

  @default_max_queue 4
  @default_job_timeout_ms 10_000

  @type outcome :: {:done, term()} | {:dropped, :overflow | :expired} | {:failed, term()}

  @doc """
  Options:

    * `:name` - registered name
    * `:max_queue` - jobs allowed to wait (default #{@default_max_queue})
    * `:ttl_ms` - how long a job may wait before it is dropped (default: no limit)
    * `:job_timeout_ms` - longest a job may run (default #{@default_job_timeout_ms})
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Queues `fun`. Never blocks and never fails: when the lane is not running the
  job is simply not run (and `:reply_to`, if given, hears `{:failed, :not_running}`).
  """
  @spec submit(GenServer.server(), (-> term()), keyword()) :: :ok
  def submit(lane, fun, opts \\ []) when is_function(fun, 0) do
    reply_to = Keyword.get(opts, :reply_to)

    case GenServer.whereis(lane) do
      nil -> reply(reply_to, {:failed, :not_running})
      pid -> GenServer.cast(pid, {:submit, fun, reply_to, now()})
    end

    :ok
  end

  @doc "Counters and queue length, for diagnostics."
  @spec status(GenServer.server()) :: map() | {:error, :not_running}
  def status(lane) do
    case GenServer.whereis(lane) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :status)
    end
  catch
    :exit, _reason -> {:error, :not_running}
  end

  # -- callbacks ---------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       max_queue: Keyword.get(opts, :max_queue, @default_max_queue),
       ttl_ms: Keyword.get(opts, :ttl_ms),
       job_timeout_ms: Keyword.get(opts, :job_timeout_ms, @default_job_timeout_ms),
       queue: :queue.new(),
       running: nil,
       completed: 0,
       dropped: 0,
       expired: 0,
       failed: 0
     }}
  end

  @impl true
  def handle_cast({:submit, fun, reply_to, at}, state) do
    if :queue.len(state.queue) >= state.max_queue do
      reply(reply_to, {:dropped, :overflow})
      {:noreply, %{state | dropped: state.dropped + 1}}
    else
      {:noreply, run_next(%{state | queue: :queue.in({fun, reply_to, at}, state.queue)})}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      running?: state.running != nil,
      queued: :queue.len(state.queue),
      completed: state.completed,
      dropped: state.dropped,
      expired: state.expired,
      failed: state.failed
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:lane_done, ref, result}, %{running: %{ref: ref} = running} = state) do
    Process.cancel_timer(running.timer)
    reply(running.reply_to, {:done, result})
    {:noreply, run_next(%{state | running: nil, completed: state.completed + 1})}
  end

  def handle_info({:lane_timeout, ref}, %{running: %{ref: ref} = running} = state) do
    # :shutdown first, so a job waiting in Exec.run can kill its program.
    Process.exit(running.pid, :shutdown)
    Process.send_after(self(), {:lane_kill, running.pid}, 2_000)
    reply(running.reply_to, {:failed, :timeout})
    {:noreply, run_next(%{state | running: nil, failed: state.failed + 1})}
  end

  def handle_info({:lane_kill, pid}, state) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{running: %{pid: pid} = running} = state)
      when reason != :normal do
    Process.cancel_timer(running.timer)
    Logger.warning("[hardware] a queued action failed: #{inspect(reason)}")
    reply(running.reply_to, {:failed, reason})
    {:noreply, run_next(%{state | running: nil, failed: state.failed + 1})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- internals ---------------------------------------------------------------

  defp run_next(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, {fun, reply_to, at}}, queue} ->
        state = %{state | queue: queue}

        if state.ttl_ms != nil and now() - at > state.ttl_ms do
          reply(reply_to, {:dropped, :expired})
          run_next(%{state | expired: state.expired + 1})
        else
          lane = self()
          ref = make_ref()
          pid = spawn_link(fn -> send(lane, {:lane_done, ref, fun.()}) end)
          timer = Process.send_after(self(), {:lane_timeout, ref}, state.job_timeout_ms)
          %{state | running: %{ref: ref, pid: pid, reply_to: reply_to, timer: timer}}
        end
    end
  end

  defp run_next(state), do: state

  defp reply(nil, _outcome), do: :ok
  defp reply({pid, tag}, outcome), do: send(pid, {tag, outcome})

  defp now, do: System.monotonic_time(:millisecond)
end
