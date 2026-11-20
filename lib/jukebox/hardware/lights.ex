defmodule Jukebox.Hardware.Lights do
  @moduledoc """
  The two light buttons: the disco group (disco ball and illuminated panel)
  and the LED strip.

  The disco group always goes through the power controller
  (`["disco", "toggle"]`). The strip depends on `JUKEBOX_STRIP_CONTROL`:

    * `power` (default) - the power controller switches the strip's supply
      (`["strip", "toggle"]`). A WLED controller on that supply restarts each
      time it comes back.
    * `wled` - the supply stays on while the jukebox is awake and the strip is
      switched on and off through WLED's JSON API. The application reads the
      actual state, sends the opposite as an explicit boolean and reads it
      back. When WLED does not answer, the press has no effect: it is *never*
      turned into a power toggle behind the user's back.

  Rules that hold for both:

    * Requests are refused unless the power controller says the jukebox is
      awake, and a request that was waiting when it went to standby is dropped.
      (The controller itself takes a command during standby and applies it on
      resume, as it always did for its command line. The buttons never get
      that far.)
    * Each backend has its own short queue; toggles of one backend run one at
      a time, in the order they were pressed.
    * A toggle is never sent twice. When the client cannot tell whether the
      controller applied it, the answer is looked for in the controller's
      state and, failing that, reported as unconfirmed.
    * A light is reported on or off only once the result has been observed:
      in the controller's state file, or in what WLED answers. For the power
      controller this means "the GPIO was commanded", not "the lamp is lit".

  After a restart nothing is replayed: the current state is simply read again.
  In WLED mode the last state requested with the button is remembered (in
  memory only) and restored when WLED comes back after a standby.
  """

  use GenServer

  require Logger

  alias Jukebox.Hardware.{Events, Lane, Wled}
  alias Jukebox.Hardware.Power.{Client, Monitor}

  @lights [:disco, :strip]
  @commands %{disco: :toggle_disco, strip: :toggle_strip}
  @max_pending 2
  @default_confirm_ms 2_500
  @default_wled_sync_ms 2_000
  @wled_sync_attempts 30
  @rail_attempts 3
  @rail_retry_ms 5_000

  @type light :: :disco | :strip

  @doc """
  Options:

    * `:name` - registered name (default: this module)
    * `:strip` - the strip section of `Jukebox.Hardware.Config`
    * `:power_command` - one-arity function running a power-client command
      (`Jukebox.Hardware.Power.Client.command/2` or the simulated controller)
    * `:monitor` - the `Jukebox.Hardware.Power.Monitor` to consult
    * `:pubsub` - PubSub server
    * `:report` - two-arity function told the final outcome of each press
      (default `Jukebox.Commands.report/2`)
    * `:wled_req_options` - extra `Req` options for the WLED calls (tests)
    * `:confirm_ms`, `:wled_sync_ms` - timings (tests)
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Asks for a light to be toggled. Returns at once: `{:ok, :accepted}` means
  the request is queued, and its outcome is reported later.
  """
  @spec toggle(GenServer.server(), light()) ::
          {:ok, :accepted} | {:error, :not_awake | :unavailable | :busy}
  def toggle(server \\ __MODULE__, light) when light in @lights do
    GenServer.call(server, {:toggle, light})
  end

  @doc "Requested and confirmed state of both lights, for diagnostics."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # -- callbacks ---------------------------------------------------------------

  @impl true
  def init(opts) do
    strip = Keyword.fetch!(opts, :strip)
    pubsub = Keyword.get(opts, :pubsub, Jukebox.PubSub)
    monitor = Keyword.get(opts, :monitor, Monitor)

    # Linked: a lane that dies takes this process with it and both are
    # restarted together, instead of leaving presses without an answer.
    {:ok, power_lane} = Lane.start_link(max_queue: 4, job_timeout_ms: 5_000)
    {:ok, wled_lane} = Lane.start_link(max_queue: 3, job_timeout_ms: 10_000)
    Monitor.subscribe(pubsub)

    state = %{
      strip: if(strip.status == :enabled, do: strip.control, else: :unavailable),
      strip_errors: strip.errors,
      wled_url: strip.wled_url,
      wled_req_options: Keyword.get(opts, :wled_req_options, []),
      power_command: Keyword.fetch!(opts, :power_command),
      monitor: monitor,
      pubsub: pubsub,
      report: Keyword.get(opts, :report, &Jukebox.Commands.report/2),
      confirm_ms: Keyword.get(opts, :confirm_ms, @default_confirm_ms),
      wled_sync_ms: Keyword.get(opts, :wled_sync_ms, @default_wled_sync_ms),
      power_lane: power_lane,
      wled_lane: wled_lane,
      pending: %{disco: 0, strip: 0},
      awaiting: [],
      errors: %{disco: nil, strip: nil},
      power: nil,
      wled: %{requested: nil, confirmed: nil, sync: nil},
      rail: %{attempts: 0, pending?: false, instance: nil}
    }

    {:ok, state, {:continue, :reconcile}}
  end

  # Nothing is replayed after a restart: the state is read again, that is all.
  @impl true
  def handle_continue(:reconcile, state) do
    {:noreply, power_changed(state, Monitor.snapshot(state.monitor))}
  end

  @impl true
  def handle_call({:toggle, light}, _from, state) do
    snapshot = Monitor.snapshot(state.monitor)

    cond do
      snapshot.mode != :awake ->
        {:reply, {:error, :not_awake}, state}

      backend(state, light) == :unavailable ->
        {:reply, {:error, :unavailable}, state}

      state.pending[light] >= @max_pending ->
        {:reply, {:error, :busy}, state}

      true ->
        state = submit_toggle(state, light, backend(state, light), snapshot)
        {:reply, {:ok, :accepted}, changed(state)}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, describe(state, Monitor.snapshot(state.monitor)), state}
  end

  @impl true
  def handle_info({:power_state, snapshot}, state) do
    {:noreply, state |> power_changed(snapshot) |> changed()}
  end

  # -- power-controller toggles --------------------------------------------------

  def handle_info({{:power_toggle, light, id, before}, {:done, {:ok, ack}}}, state) do
    {:noreply, state |> await(light, id, ack, before) |> check_awaiting() |> changed()}
  end

  def handle_info({{:power_toggle, light, id, before}, {:done, {:error, reason}}}, state) do
    if Client.uncertain?(reason) do
      # Sent, maybe applied. It is not sent again; the state file will tell.
      Logger.warning(
        "[lights] #{light}: no answer from the power controller (#{inspect(reason)}); " <>
          "not retried, waiting for its state"
      )

      ack = %{acked?: false, instance: nil, revision: nil}
      {:noreply, state |> await(light, id, ack, before) |> check_awaiting() |> changed()}
    else
      {:noreply, state |> finish(light, {:error, reason}) |> changed()}
    end
  end

  def handle_info({{:power_toggle, light, _id, _before}, outcome}, state) do
    {:noreply, state |> finish(light, {:error, lane_error(outcome)}) |> changed()}
  end

  def handle_info({:confirm_timeout, id}, state) do
    case Enum.split_with(state.awaiting, &(&1.id == id)) do
      {[entry], rest} ->
        {:noreply,
         %{state | awaiting: rest} |> finish(entry.light, {:error, :unconfirmed}) |> changed()}

      {[], _rest} ->
        {:noreply, state}
    end
  end

  # -- keeping the strip supply on in WLED mode ----------------------------------

  def handle_info({:rail, outcome}, state) do
    state = put_in(state.rail.pending?, false)

    case outcome do
      {:done, {:ok, _ack}} ->
        {:noreply, state}

      other ->
        Logger.warning("[lights] could not switch the strip supply on: #{inspect(other)}")
        Process.send_after(self(), :rail_check, @rail_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(:rail_check, state) do
    {:noreply, ensure_rail(state, Monitor.snapshot(state.monitor))}
  end

  # -- WLED ------------------------------------------------------------------------

  def handle_info({{:wled_toggle, _id}, {:done, {:ok, %{target: target, on: on}}}}, state) do
    state = %{state | wled: %{state.wled | requested: target, confirmed: on}}

    result =
      if on == target, do: {:ok, {:light, :strip, on}}, else: {:error, :readback_mismatch}

    {:noreply, state |> finish(:strip, result) |> changed()}
  end

  def handle_info({{:wled_toggle, _id}, {:done, {:error, reason}}}, state) do
    {:noreply, state |> finish(:strip, {:error, reason}) |> changed()}
  end

  def handle_info({{:wled_toggle, _id}, outcome}, state) do
    {:noreply, state |> finish(:strip, {:error, lane_error(outcome)}) |> changed()}
  end

  def handle_info({{:wled_sync, gen}, outcome}, %{wled: %{sync: %{gen: gen} = sync}} = state) do
    case outcome do
      {:done, {:ok, on}} ->
        state = %{state | wled: %{state.wled | confirmed: on, sync: nil}}
        state = %{state | errors: %{state.errors | strip: nil}}
        {:noreply, state |> restore_wled(on) |> changed()}

      {:done, {:error, :not_awake}} ->
        {:noreply, put_in(state.wled.sync, nil)}

      _failed when sync.attempt < @wled_sync_attempts ->
        Process.send_after(self(), {:wled_sync_retry, gen}, state.wled_sync_ms)
        {:noreply, state}

      failed ->
        Logger.warning("[lights] WLED did not answer after the wake-up: #{inspect(failed)}")
        state = %{state | errors: %{state.errors | strip: :wled_unreachable}}
        {:noreply, changed(put_in(state.wled.sync, nil))}
    end
  end

  def handle_info({:wled_sync_retry, gen}, %{wled: %{sync: %{gen: gen} = sync}} = state) do
    {:noreply, submit_wled_sync(state, %{sync | attempt: sync.attempt + 1})}
  end

  def handle_info({:wled_restore, outcome}, state) do
    case outcome do
      {:done, {:ok, on}} ->
        {:noreply, changed(put_in(state.wled.confirmed, on))}

      other ->
        Logger.warning("[lights] could not restore the strip state in WLED: #{inspect(other)}")
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- requests ----------------------------------------------------------------

  defp backend(_state, :disco), do: :power
  defp backend(state, :strip), do: state.strip

  defp submit_toggle(state, light, :power, snapshot) do
    %{monitor: monitor, power_command: command} = state
    before = get_in(snapshot.outputs, [light, :requested])
    args = [Atom.to_string(light), "toggle"]

    Lane.submit(
      state.power_lane,
      fn -> if Monitor.awake?(monitor), do: command.(args), else: {:error, :not_awake} end,
      reply_to: {self(), {:power_toggle, light, make_ref(), before}}
    )

    pending(state, light, +1)
  end

  defp submit_toggle(state, :strip, :wled, _snapshot) do
    %{monitor: monitor, wled_url: url, wled_req_options: req_options} = state
    options = [req_options: req_options]

    Lane.submit(
      state.wled_lane,
      fn ->
        with true <- Monitor.awake?(monitor) || {:error, :not_awake},
             {:ok, on} <- Wled.get_on(url, options),
             target = not on,
             {:ok, _reported} <- Wled.set_on(url, target, options),
             {:ok, now} <- Wled.get_on(url, options) do
          {:ok, %{target: target, on: now}}
        end
      end,
      reply_to: {self(), {:wled_toggle, make_ref()}}
    )

    pending(state, :strip, +1)
  end

  defp pending(state, light, change) do
    %{state | pending: Map.update!(state.pending, light, &max(&1 + change, 0))}
  end

  # The command was sent: its result is now looked for in the controller's state.
  defp await(state, light, id, ack, before) do
    timer = Process.send_after(self(), {:confirm_timeout, id}, state.confirm_ms)
    entry = %{id: id, light: light, ack: ack, before: before, timer: timer}
    %{state | awaiting: state.awaiting ++ [entry]}
  end

  defp check_awaiting(%{awaiting: []} = state), do: state

  defp check_awaiting(state) do
    snapshot = Monitor.snapshot(state.monitor)
    {confirmed, awaiting} = Enum.split_with(state.awaiting, &observed?(&1, snapshot))

    Enum.reduce(confirmed, %{state | awaiting: awaiting, power: snapshot}, fn entry, state ->
      Process.cancel_timer(entry.timer)

      if snapshot.mode == :awake do
        applied = snapshot.outputs[entry.light].applied
        finish(state, entry.light, {:ok, {:light, entry.light, applied}})
      else
        # The controller took the command just as the jukebox left the awake
        # mode: it keeps the request for the resume and drives nothing now.
        # There is no light state to announce, and nobody to announce it to.
        finish(state, entry.light, {:error, :not_awake})
      end
    end)
  end

  defp observed?(_entry, %{fresh?: false}), do: false

  defp observed?(%{light: light, ack: %{acked?: true} = ack}, snapshot) do
    is_map_key(snapshot.outputs, light) and snapshot.instance == ack.instance and
      snapshot.revision >= ack.revision
  end

  # No acknowledgement: only a visible change of the requested state counts.
  defp observed?(%{light: light, before: before}, snapshot) when is_boolean(before) do
    case snapshot.outputs do
      %{^light => %{requested: requested}} -> requested != before
      _other -> false
    end
  end

  defp observed?(_entry, _snapshot), do: false

  # One press is over: free its slot, remember a failure, tell the display.
  defp finish(state, light, result) do
    state = pending(state, light, -1)

    case result do
      {:ok, _light} ->
        state.report.(@commands[light], result)
        %{state | errors: Map.put(state.errors, light, nil)}

      {:error, reason}
      when reason in [:not_awake, {:rejected, "not_awake"}, {:rejected, "shutting_down"}] ->
        # Went to standby while the request was waiting or on its way: the
        # press is dropped, which is not a fault of the hardware.
        state

      {:error, reason} ->
        Logger.warning("[lights] #{light} toggle failed: #{inspect(reason)}")

        outcome =
          if reason in [:unconfirmed, :readback_mismatch],
            do: :unconfirmed,
            else: :hardware_unavailable

        state.report.(@commands[light], {:error, outcome})
        %{state | errors: Map.put(state.errors, light, reason)}
    end
  end

  defp lane_error({:dropped, reason}), do: {:dropped, reason}
  defp lane_error({:failed, reason}), do: {:failed, reason}
  defp lane_error(other), do: {:failed, other}

  # -- power transitions ---------------------------------------------------------

  defp power_changed(state, snapshot) do
    previous = state.power
    was_awake? = previous != nil and previous.mode == :awake
    state = %{state | power: snapshot}

    state =
      cond do
        snapshot.mode == :awake and not was_awake? -> woke_up(state)
        snapshot.mode != :awake and was_awake? -> went_down(state)
        true -> state
      end

    state |> check_awaiting() |> ensure_rail(snapshot)
  end

  defp woke_up(%{strip: :wled} = state) do
    state = put_in(state.rail.attempts, 0)
    submit_wled_sync(state, %{gen: make_ref(), attempt: 1})
  end

  defp woke_up(state), do: state

  # The strip supply is cut in standby, so nothing is known about WLED any more.
  defp went_down(%{strip: :wled} = state) do
    %{state | wled: %{state.wled | confirmed: nil, sync: nil}}
  end

  defp went_down(state), do: state

  defp submit_wled_sync(state, sync) do
    %{monitor: monitor, wled_url: url, wled_req_options: req_options} = state

    Lane.submit(
      state.wled_lane,
      fn ->
        if Monitor.awake?(monitor),
          do: Wled.get_on(url, req_options: req_options),
          else: {:error, :not_awake}
      end,
      reply_to: {self(), {:wled_sync, sync.gen}}
    )

    put_in(state.wled.sync, sync)
  end

  # WLED is back after a standby: put the strip in the state last asked for.
  defp restore_wled(%{wled: %{requested: requested}} = state, on)
       when is_boolean(requested) and requested != on do
    %{monitor: monitor, wled_url: url, wled_req_options: req_options} = state
    options = [req_options: req_options]

    Lane.submit(
      state.wled_lane,
      fn ->
        with true <- Monitor.awake?(monitor) || {:error, :not_awake},
             {:ok, _reported} <- Wled.set_on(url, requested, options) do
          Wled.get_on(url, options)
        end
      end,
      reply_to: {self(), :wled_restore}
    )

    state
  end

  defp restore_wled(state, _on), do: state

  # In WLED mode the strip's supply must be on whenever the jukebox is awake.
  # "strip on" is idempotent, so unlike a toggle it may be sent again.
  defp ensure_rail(%{strip: :wled} = state, %{mode: :awake, fresh?: true} = snapshot) do
    rail =
      if snapshot.instance == state.rail.instance,
        do: state.rail,
        else: %{state.rail | attempts: 0}

    rail = %{rail | instance: snapshot.instance}
    off? = match?(%{strip: %{requested: false}}, snapshot.outputs)

    if off? and not rail.pending? and rail.attempts < @rail_attempts do
      %{monitor: monitor, power_command: command} = state

      Lane.submit(
        state.power_lane,
        fn ->
          if Monitor.awake?(monitor), do: command.(["strip", "on"]), else: {:error, :not_awake}
        end,
        reply_to: {self(), :rail}
      )

      %{state | rail: %{rail | pending?: true, attempts: rail.attempts + 1}}
    else
      %{state | rail: rail}
    end
  end

  defp ensure_rail(state, _snapshot), do: state

  # -- status --------------------------------------------------------------------

  defp describe(state, snapshot) do
    %{
      disco: power_light(state, snapshot, :disco),
      strip: strip_light(state, snapshot),
      meaning_of_confirmed:
        "the level the power controller commanded on the GPIO, or the state WLED reports; " <>
          "not a measurement of lamp current"
    }
  end

  defp power_light(state, snapshot, light) do
    output = if snapshot.fresh?, do: snapshot.outputs[light]

    %{
      backend: :power,
      requested: output && output.requested,
      confirmed: output && output.applied,
      pending: state.pending[light],
      last_error: state.errors[light]
    }
  end

  defp strip_light(%{strip: :wled} = state, snapshot) do
    rail = power_light(state, snapshot, :strip)

    %{
      backend: :wled,
      requested: state.wled.requested,
      confirmed: state.wled.confirmed,
      pending: state.pending.strip,
      last_error: state.errors.strip,
      waiting_for_wled?: state.wled.sync != nil,
      supply: %{requested: rail.requested, confirmed: rail.confirmed}
    }
  end

  defp strip_light(%{strip: :unavailable} = state, _snapshot) do
    %{
      backend: :unavailable,
      requested: nil,
      confirmed: nil,
      pending: 0,
      last_error: {:configuration, state.strip_errors}
    }
  end

  defp strip_light(state, snapshot), do: power_light(state, snapshot, :strip)

  defp changed(state) do
    Events.changed(state.pubsub, :lights)
    state
  end
end
