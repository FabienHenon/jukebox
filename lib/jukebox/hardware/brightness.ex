defmodule Jukebox.Hardware.Brightness do
  @moduledoc """
  The two brightness buttons: software dimming of the kiosk's X11 output.

  This is `xrandr --brightness`, a scaling of the output's gamma ramp. It
  darkens the picture and nothing else: the monitor's backlight, the value in
  its own menu and its power consumption do not change, and `1.0` means "no
  software dimming", not "maximum backlight". The numbers reported here are
  that coefficient, never a reading of the hardware.

  What the worker does:

    * **Desired value.** The coefficient the user wants lives in
      `Jukebox.Hardware.Brightness.Desired`, outside this process. It starts
      at `JUKEBOX_BRIGHTNESS_DEFAULT` when the application starts, a press
      moves it by `JUKEBOX_BRIGHTNESS_STEP` between `JUKEBOX_BRIGHTNESS_MIN`
      and `JUKEBOX_BRIGHTNESS_MAX`, and nothing but a full restart of the
      application resets it. Steps are exact (thousandths, no floating-point
      drift).
    * **Applying it.** One job runs at a time. It reads what the output has
      now, and only when that differs from the desired value does it set it
      and read it back. The read value must be within #{20 / 1000} of the
      target (xrandr reports two significant digits and the ramp is
      quantised), otherwise the result is a mismatch, not a success.
      Presses that follow each other closely are merged into one job for the
      latest value.
    * **Starting before X11.** The application usually starts before the
      kiosk session. A failed job is tried again after a pause that doubles
      from one second to thirty, for as long as the jukebox is awake, and the
      desired value is applied as soon as the display answers. The reason is
      logged once, not at every attempt.
    * **Standby.** Unless the power controller says the jukebox is awake,
      presses are refused and nothing runs: what was waiting is cancelled, a
      running xrandr is stopped, and no retry is scheduled, so nothing here
      can wake the display. The desired value is kept. On wake-up it is
      applied again.
    * **Lost state.** While everything is fine the output is read again every
      ten seconds. If an X restart (or a manual xrandr command) changed it,
      the desired value is applied again; otherwise nothing is written.
  """

  use GenServer

  require Logger

  alias Jukebox.Hardware.Brightness.{Desired, Simulated, Xrandr}
  alias Jukebox.Hardware.{Config, Events}
  alias Jukebox.Hardware.Power.Monitor

  @tolerance 20
  @default_coalesce_ms 200
  @default_check_ms 10_000
  @default_retry_ms {1_000, 30_000}

  @doc "Largest difference, in thousandths, between the value set and the value read back."
  def tolerance, do: @tolerance

  @doc """
  Options:

    * `:name` - registered name (default: this module)
    * `:config` - the brightness section of `Jukebox.Hardware.Config`
    * `:desired` - the `Jukebox.Hardware.Brightness.Desired` holding the value
    * `:backend` - `{module, options}` replacing the configured backend (tests)
    * `:monitor` - the `Jukebox.Hardware.Power.Monitor` to consult
    * `:pubsub` - PubSub server
    * `:report` - two-arity function told the outcome of the presses
      (default `Jukebox.Commands.report/2`)
    * `:coalesce_ms` - pause during which presses are merged
      (default #{@default_coalesce_ms})
    * `:check_ms` - pause between two readings while everything is fine
      (default #{@default_check_ms})
    * `:retry_ms` - `{first, longest}` pause before trying again after a
      failure (default `#{inspect(@default_retry_ms)}`)
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  One press of a brightness button. Returns at once: `{:ok, :accepted}` means
  the desired value was updated, and the outcome is reported later.
  """
  @spec step(GenServer.server(), :up | :down) ::
          {:ok, :accepted} | {:error, :disabled | :not_awake}
  def step(server \\ __MODULE__, direction) when direction in [:up, :down] do
    GenServer.call(server, {:step, direction})
  end

  @doc "Backend, X11 display and output, bounds, desired and applied coefficient, last error."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # -- callbacks ---------------------------------------------------------------

  @impl true
  def init(opts) do
    # Jobs are linked: stopping this process stops a running xrandr too.
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)
    pubsub = Keyword.get(opts, :pubsub, Jukebox.PubSub)
    Monitor.subscribe(pubsub)
    {first_retry, _longest} = retry_ms = Keyword.get(opts, :retry_ms, @default_retry_ms)

    state = %{
      config: config,
      enabled?: config.status == :enabled,
      backend: Keyword.get_lazy(opts, :backend, fn -> backend(config) end),
      desired: Keyword.get(opts, :desired, Desired),
      monitor: Keyword.get(opts, :monitor, Monitor),
      pubsub: pubsub,
      report: Keyword.get(opts, :report, &Jukebox.Commands.report/2),
      coalesce_ms: Keyword.get(opts, :coalesce_ms, @default_coalesce_ms),
      check_ms: Keyword.get(opts, :check_ms, @default_check_ms),
      retry_ms: retry_ms,
      retry_in: first_retry,
      awake?: false,
      applied: nil,
      applied_at: nil,
      x11: :unknown,
      job: nil,
      timer: nil,
      # The direction of the last press that has not been answered yet.
      pressed: nil,
      last_error: nil,
      logged_error: nil
    }

    {:ok, state, {:continue, :start}}
  end

  # Also runs when the worker is restarted: the desired value is still there,
  # and it is applied again.
  @impl true
  def handle_continue(:start, %{enabled?: false} = state), do: {:noreply, state}

  def handle_continue(:start, state) do
    {:noreply, power_changed(state, Monitor.awake?(state.monitor))}
  end

  @impl true
  def handle_call({:step, _direction}, _from, %{enabled?: false} = state) do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call({:step, direction}, _from, state) do
    if Monitor.awake?(state.monitor) do
      %{min: min, max: max, step: step} = state.config

      Desired.update(state.desired, fn current ->
        case direction do
          :up -> min(current + step, max)
          :down -> max(current - step, min)
        end
      end)

      state = %{state | awake?: true, pressed: direction}

      {:reply, {:ok, :accepted},
       state |> schedule(state.coalesce_ms, :unless_planned) |> changed()}
    else
      # Not kept for later: the press is simply dropped.
      {:reply, {:error, :not_awake}, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, describe(state), state}

  @impl true
  def handle_info(:sync, state) do
    {:noreply, %{state | timer: nil} |> sync() |> changed()}
  end

  def handle_info({:job_done, ref, result}, %{job: %{ref: ref} = job} = state) do
    {:noreply, %{state | job: nil} |> finished(job, result) |> changed()}
  end

  def handle_info({:EXIT, pid, reason}, %{job: %{pid: pid} = job} = state)
      when reason != :normal do
    {:noreply,
     %{state | job: nil} |> finished(job, {:error, {:command_failed, reason}}) |> changed()}
  end

  def handle_info({:power_state, %{mode: mode}}, %{enabled?: true} = state) do
    {:noreply, state |> power_changed(mode == :awake) |> changed()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- power -------------------------------------------------------------------

  defp power_changed(%{awake?: awake?} = state, awake?), do: state

  # Awake again: apply the value that was kept, whatever the output has now.
  defp power_changed(state, true) do
    {first_retry, _longest} = state.retry_ms
    schedule(%{state | awake?: true, retry_in: first_retry}, 0, :now)
  end

  # Standby, shutdown or an unreadable power state: nothing runs from here on,
  # and nothing is left that could run later.
  defp power_changed(state, false) do
    cancel(state.timer)

    if state.job do
      # Its result would be ignored anyway; this also ends a running xrandr
      # (Jukebox.Hardware.Exec kills it when its caller is told to stop).
      Process.exit(state.job.pid, :shutdown)
    end

    %{state | awake?: false, timer: nil, job: nil, applied: nil, x11: :unknown, pressed: nil}
  end

  # -- jobs --------------------------------------------------------------------

  # `:unless_planned` leaves an earlier, sooner plan alone (the pause that
  # merges presses is counted from the first one); `:now` replaces it.
  defp schedule(%{timer: timer} = state, _delay, :unless_planned) when timer != nil do
    if Process.read_timer(timer) in [false, 0] or sooner?(timer, state.coalesce_ms),
      do: state,
      else: schedule(state, state.coalesce_ms, :now)
  end

  defp schedule(%{job: job} = state, _delay, _mode) when job != nil do
    # The running job is followed by another one if the value changed meanwhile.
    state
  end

  defp schedule(state, delay, _mode) do
    cancel(state.timer)
    %{state | timer: Process.send_after(self(), :sync, delay)}
  end

  defp sooner?(timer, delay) do
    case Process.read_timer(timer) do
      remaining when is_integer(remaining) -> remaining <= delay
      false -> true
    end
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp sync(%{awake?: true, job: nil} = state) do
    worker = self()
    ref = make_ref()
    target = Desired.get(state.desired)
    {module, options} = state.backend
    monitor = state.monitor

    pid =
      spawn_link(fn -> send(worker, {:job_done, ref, run(module, options, target, monitor)}) end)

    %{state | job: %{ref: ref, pid: pid, target: target}}
  end

  defp sync(state), do: state

  # Runs in the job process. Read; set only if needed; read back. The power
  # mode is looked at before every step: a standby stops the job between two
  # commands even if the worker could not stop it first.
  defp run(module, options, target, monitor) do
    with :ok <- awake(monitor),
         {:ok, current} <- module.query(options) do
      if near?(current, target) do
        {:ok, current, :unchanged}
      else
        with :ok <- awake(monitor),
             :ok <- module.set(target, options),
             :ok <- awake(monitor),
             {:ok, read} <- module.query(options) do
          if near?(read, target),
            do: {:ok, read, {:changed_from, current}},
            else: {:error, {:mismatch, read}}
        end
      end
    end
  end

  defp awake(monitor), do: if(Monitor.awake?(monitor), do: :ok, else: {:error, :not_awake})
  defp near?(read, target), do: abs(read - target) <= @tolerance

  defp finished(%{awake?: false} = state, _job, _result), do: state
  defp finished(state, _job, {:error, :not_awake}), do: state

  defp finished(state, job, {:ok, read, what}) do
    {first_retry, _longest} = state.retry_ms

    if state.x11 != :ready or state.logged_error != nil do
      Logger.info(
        "[brightness] X11 output #{inspect(state.config.output)} ready, " <>
          "software brightness #{Config.format_coefficient(read)}"
      )
    end

    with {:changed_from, previous} <- what,
         true <- state.applied != nil and near?(state.applied, job.target) do
      # This very value had been applied and something undid it: an X
      # restart, or a manual xrandr command.
      Logger.warning(
        "[brightness] the output was at #{Config.format_coefficient(previous)} instead of " <>
          "#{Config.format_coefficient(job.target)}; applied again"
      )
    end

    state = %{
      state
      | applied: read,
        applied_at: System.monotonic_time(:millisecond),
        x11: :ready,
        last_error: nil,
        logged_error: nil,
        retry_in: first_retry
    }

    if Desired.get(state.desired) == job.target do
      # Confirmed within the tolerance: the value asked for is the one shown.
      state |> answer({:ok, {:brightness, percent(job.target)}}) |> schedule(state.check_ms, :now)
    else
      # Pressed again meanwhile: go on to the newest value, answer after it.
      schedule(state, 0, :now)
    end
  end

  defp finished(state, _job, {:error, reason}) do
    {_first, longest} = state.retry_ms

    state =
      state
      |> log_failure(reason)
      |> answer(
        {:error,
         if(match?({:mismatch, _read}, reason), do: :unconfirmed, else: :hardware_unavailable)}
      )

    applied =
      case reason do
        {:mismatch, read} -> read
        _unknown -> nil
      end

    # Tried again later, less and less often, for as long as the jukebox is
    # awake: this is also how a display that starts after the application is
    # picked up.
    %{state | applied: applied, x11: {:unavailable, reason}, last_error: reason}
    |> schedule(state.retry_in, :now)
    |> Map.put(:retry_in, min(state.retry_in * 2, longest))
  end

  # Once per distinct reason, not once per attempt.
  defp log_failure(%{logged_error: reason} = state, reason), do: state

  defp log_failure(state, reason) do
    {_first, longest} = state.retry_ms

    Logger.warning(
      "[brightness] cannot apply software brightness on #{inspect(state.config.output)} " <>
        "(#{explain(reason)}); retrying, at most every #{div(longest, 1000)} s"
    )

    %{state | logged_error: reason}
  end

  defp explain(:xrandr_missing),
    do: "/usr/bin/xrandr is not installed: apt install x11-xserver-utils"

  defp explain(:xauthority_missing),
    do: "the X authority file does not exist or is hidden from the service"

  defp explain(:xauthority_unreadable), do: "the service user may not read the X authority file"

  defp explain(:x11_unavailable),
    do: "the X display does not answer; the kiosk session may not have started yet"

  defp explain(:x11_unauthorized), do: "the X server refused the authority file"
  defp explain(:output_missing), do: "xrandr knows no output of that name"
  defp explain(:output_inactive), do: "the output is disconnected or switched off"
  defp explain(:timeout), do: "xrandr did not finish in time and was killed"
  defp explain(:malformed_reply), do: "the answer of xrandr --verbose could not be read"

  defp explain({:mismatch, read}),
    do: "the output reports #{Config.format_coefficient(read)} after the change"

  defp explain(other), do: inspect(other)

  # Tells the display what became of the last press, if one is waiting.
  defp answer(%{pressed: nil} = state, _result), do: state

  defp answer(state, result) do
    command = if state.pressed == :up, do: :brightness_up, else: :brightness_down
    state.report.(command, result)
    %{state | pressed: nil}
  end

  defp percent(coefficient), do: round(coefficient / 10)

  # -- status ------------------------------------------------------------------

  defp describe(state) do
    config = state.config
    desired = Desired.get(state.desired)

    %{
      status: config.status,
      backend: config.backend,
      errors: config.errors,
      notices: config.notices,
      kind:
        "X11 software dimming (gamma ramp of the whole output): a coefficient, where 1.0 means " <>
          "no dimming. Not the monitor's backlight, and not a reading of the hardware",
      display: config.display,
      output: config.output,
      xauthority: config.xauthority,
      x11_ready?: state.x11 == :ready,
      availability: availability(state),
      min: Config.to_float(config.min),
      max: Config.to_float(config.max),
      step: Config.to_float(config.step),
      default: Config.to_float(config.default),
      desired_coefficient: Config.to_float(desired),
      # What xrandr last reported for the output, and how long ago: between
      # two readings (ten seconds apart while all is well) it is not re-read.
      applied_coefficient: Config.to_float(state.applied),
      applied_read_ms_ago:
        state.applied && state.applied_at &&
          System.monotonic_time(:millisecond) - state.applied_at,
      pending?:
        state.job != nil or (state.enabled? and state.awake? and not applied?(state, desired)),
      last_error: state.last_error
    }
  end

  defp applied?(%{applied: nil}, _desired), do: false
  defp applied?(%{applied: applied}, desired), do: near?(applied, desired)

  defp availability(%{config: %{status: :disabled}}), do: :disabled
  defp availability(%{config: %{status: :error}}), do: :configuration_error
  defp availability(%{awake?: false}), do: :not_awake
  defp availability(%{x11: :ready}), do: :ready
  defp availability(%{x11: {:unavailable, {:mismatch, _read}}}), do: :mismatch
  defp availability(%{x11: {:unavailable, {:command_failed, _detail}}}), do: :command_failed
  defp availability(%{x11: {:unavailable, reason}}), do: reason
  defp availability(_starting), do: :starting

  defp backend(%{backend: :xrandr} = config) do
    {Xrandr,
     [
       output: config.output,
       display: config.display,
       xauthority: config.xauthority,
       timeout_ms: config.timeout_ms
     ]}
  end

  defp backend(_config), do: {Simulated, []}

  defp changed(state) do
    Events.changed(state.pubsub, :brightness)
    state
  end
end
