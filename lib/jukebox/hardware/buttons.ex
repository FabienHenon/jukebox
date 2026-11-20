defmodule Jukebox.Hardware.Buttons do
  @moduledoc """
  The server-side dispatcher of the physical buttons.

  One input adapter (`Jukebox.Inputs.Evdev` on the Raspberry Pi,
  `Jukebox.Inputs.Simulated` in development) reads the selected Linux input
  device and sends its raw key events here. This process is the only place
  that turns them into actions, so the number of browsers showing the kiosk
  changes nothing: one press, one action.

  For each key event it:

    1. ignores everything but the mapped `EV_KEY` codes;
    2. decides whether a key-down is a real press
       (`Jukebox.Hardware.Buttons.Tracker`: debounce, release required before
       a new press, held keys ignored after a connection or a lost-event
       resynchronisation);
    3. drops the press unless the power controller says the jukebox is awake.
       Dropped means dropped: nothing is kept for later, and an unreadable or
       stale power state counts as "not awake";
    4. hands the matching semantic command to `Jukebox.Commands` through a
       bounded queue, so this process never waits for MQTT, a helper program
       or the monitor. A music command that could not be sent within a moment
       is discarded instead of being sent late.

  | Action            | Command            |
  | ----------------- | ------------------ |
  | `previous`        | `:previous_track`  |
  | `play_pause`      | `:toggle_playback` |
  | `next`            | `:next_track`      |
  | `disco_toggle`    | `:toggle_disco`    |
  | `strip_toggle`    | `:toggle_strip`    |
  | `animation_next`  | `:cycle_animation` |
  | `brightness_down` | `:brightness_down` |
  | `brightness_up`   | `:brightness_up`   |
  """

  use GenServer

  require Logger

  alias Jukebox.Hardware.Buttons.Tracker
  alias Jukebox.Hardware.{Events, Lane}
  alias Jukebox.Hardware.Power.Monitor

  @commands %{
    previous: :previous_track,
    play_pause: :toggle_playback,
    next: :next_track,
    disco_toggle: :toggle_disco,
    strip_toggle: :toggle_strip,
    animation_next: :cycle_animation,
    brightness_down: :brightness_down,
    brightness_up: :brightness_up
  }
  @transport [:previous, :play_pause, :next]
  # Problems with the input stream are reported at most this often.
  @report_ms 30_000

  @type event ::
          {:key, code :: integer(), value :: 0 | 1 | 2, ms :: integer()}
          | {:connected, map()}
          | {:disconnected, term()}
          | {:waiting, term()}
          | {:resync, held :: [integer()], ms :: integer()}
          | {:malformed, term()}
          | {:helper, term()}

  @doc "The semantic command each action stands for."
  def commands, do: @commands

  @doc """
  Options:

    * `:name` - registered name (default: this module)
    * `:config` - the buttons section of `Jukebox.Hardware.Config`
    * `:monitor` - the `Jukebox.Hardware.Power.Monitor` to consult
    * `:transport_lane`, `:local_lane` - the `Jukebox.Hardware.Lane`s that run
      music commands and everything else
    * `:dispatch` - one-arity function carrying out a semantic command
      (default `Jukebox.Commands.dispatch/1`)
    * `:pubsub` - PubSub server
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Called by the input adapter for every event of the selected device."
  @spec input(GenServer.server(), event()) :: :ok
  def input(server \\ __MODULE__, event), do: GenServer.cast(server, {:input, event})

  @doc "Mapping, device, connection, held keys, last accepted press and counters."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # -- callbacks ---------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    {:ok,
     %{
       config: config,
       mapping: config.mapping,
       tracker: Tracker.new(config.debounce_ms || 80),
       monitor: Keyword.get(opts, :monitor, Monitor),
       transport_lane: Keyword.fetch!(opts, :transport_lane),
       local_lane: Keyword.fetch!(opts, :local_lane),
       dispatch: Keyword.get(opts, :dispatch, &Jukebox.Commands.dispatch/1),
       pubsub: Keyword.get(opts, :pubsub, Jukebox.PubSub),
       connection: if(config.status == :enabled, do: :starting, else: :disabled),
       device: nil,
       missing_codes: [],
       last_accepted: nil,
       last_problem: nil,
       reported_at: nil,
       unreported: 0,
       counts: %{
         accepted: 0,
         bounces: 0,
         duplicates: 0,
         repeats: 0,
         unassigned: 0,
         malformed: 0,
         discarded_not_awake: 0,
         resyncs: 0
       }
     }}
  end

  @impl true
  def handle_cast({:input, event}, state), do: {:noreply, handle_event(event, state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, describe(state), state}

  # -- events ------------------------------------------------------------------

  defp handle_event({:key, code, value, ms}, state)
       when is_integer(code) and value in [0, 1, 2] and is_integer(ms) do
    case Map.fetch(state.mapping, code) do
      {:ok, action} ->
        {decision, tracker} = Tracker.key(state.tracker, code, value, ms)
        debug(state, "code #{code} value #{value} (#{action}): #{decision}")
        decided(%{state | tracker: tracker}, decision, code, action)

      :error ->
        debug(state, "code #{code} value #{value}: not assigned")
        if value == 1, do: count(state, :unassigned), else: state
    end
  end

  defp handle_event({:connected, device}, state) when is_map(device) do
    held = for code <- Map.get(device, :held, []), is_map_key(state.mapping, code), do: code
    advertised = MapSet.new(Map.get(device, :keys, []))

    missing =
      state.mapping |> Map.keys() |> Enum.reject(&MapSet.member?(advertised, &1)) |> Enum.sort()

    Logger.info(
      "[buttons] connected to #{inspect(device[:name])} " <>
        "(#{hex(device[:vendor])}:#{hex(device[:product])}) at #{device[:real_path] || device[:path]}"
    )

    if missing != [] do
      Logger.error(
        "[buttons] the device does not advertise the mapped key code(s) #{Enum.join(missing, ", ")} " <>
          "(#{missing |> Enum.map(&state.mapping[&1]) |> Enum.join(", ")}): those buttons cannot work. " <>
          "Check the mapping with the --diagnose mode of xinmo_evdev.py."
      )
    end

    if device[:abs?] == true and MapSet.size(advertised) == 0 do
      Logger.error(
        "[buttons] the device reports axes (EV_ABS) and no keys: wire the buttons to the encoder's " <>
          "button terminals, not to its joystick-direction terminals"
      )
    end

    if held != [] do
      Logger.info(
        "[buttons] held at connection, ignored until released: #{Enum.join(held, ", ")}"
      )
    end

    changed(%{
      state
      | tracker: Tracker.connected(state.tracker, held),
        connection: :connected,
        device: Map.drop(device, [:keys, :held]),
        missing_codes: missing,
        last_problem: nil
    })
  end

  defp handle_event({:disconnected, reason}, state) do
    if state.connection == :connected do
      Logger.warning("[buttons] input device disconnected: #{inspect(reason)}")
    end

    changed(%{
      state
      | tracker: Tracker.disconnected(state.tracker),
        connection: {:disconnected, reason},
        last_problem: reason
    })
  end

  defp handle_event({:waiting, reason}, state) do
    if state.connection != {:waiting, reason} do
      Logger.warning("[buttons] input device not available (#{inspect(reason)}); retrying")
    end

    changed(%{
      state
      | tracker: Tracker.disconnected(state.tracker),
        connection: {:waiting, reason},
        last_problem: reason
    })
  end

  defp handle_event({:resync, held, ms}, state) when is_list(held) and is_integer(ms) do
    held = Enum.filter(held, &is_map_key(state.mapping, &1))

    Logger.warning(
      "[buttons] the kernel dropped input events; key state re-read, no action taken"
    )

    count(%{state | tracker: Tracker.resync(state.tracker, held, ms)}, :resyncs)
  end

  defp handle_event({:helper, status}, state) do
    case status do
      :started ->
        %{state | connection: :starting}

      other ->
        changed(%{
          state
          | tracker: Tracker.disconnected(state.tracker),
            connection: {:helper_down, other},
            last_problem: other
        })
    end
  end

  defp handle_event({:malformed, reason}, state), do: malformed(state, reason)
  defp handle_event(other, state), do: malformed(state, {:unknown_event, other})

  defp decided(state, :press, code, action) do
    case Monitor.mode(state.monitor) do
      :awake ->
        command = Map.fetch!(@commands, action)
        dispatch = state.dispatch
        lane = if action in @transport, do: state.transport_lane, else: state.local_lane
        Lane.submit(lane, fn -> dispatch.(command) end)

        changed(
          count(
            %{state | last_accepted: %{code: code, action: action, at: DateTime.utc_now()}},
            :accepted
          )
        )

      mode ->
        debug(state, "#{action} discarded, power mode is #{mode}")
        count(state, :discarded_not_awake)
    end
  end

  defp decided(state, :bounce, _code, _action), do: count(state, :bounces)
  defp decided(state, :duplicate, _code, _action), do: count(state, :duplicates)
  defp decided(state, :repeat, _code, _action), do: count(state, :repeats)
  defp decided(state, :release, _code, _action), do: state

  defp malformed(state, reason) do
    state =
      count(
        %{state | unreported: state.unreported + 1, last_problem: {:malformed, reason}},
        :malformed
      )

    now = System.monotonic_time(:millisecond)

    if state.reported_at == nil or now - state.reported_at >= @report_ms do
      Logger.warning(
        "[buttons] ignored #{state.unreported} malformed input message(s), last: #{inspect(reason)}"
      )

      %{state | reported_at: now, unreported: 0}
    else
      state
    end
  end

  defp count(state, key), do: %{state | counts: Map.update!(state.counts, key, &(&1 + 1))}

  defp debug(%{config: %{debug?: true}}, message), do: Logger.info("[buttons] " <> message)
  defp debug(_state, _message), do: :ok

  defp hex(number) when is_integer(number),
    do: number |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase()

  defp hex(_other), do: "????"

  defp describe(state) do
    by_action = Map.new(state.mapping, fn {code, action} -> {action, code} end)

    %{
      status: state.config.status,
      source: state.config.source,
      configured_device: state.config.device,
      errors: state.config.errors,
      debounce_ms: state.config.debounce_ms,
      connection: state.connection,
      device: state.device,
      mapping: Map.new(Map.keys(@commands), &{&1, Map.get(by_action, &1)}),
      missing_codes: state.missing_codes,
      held: Tracker.held(state.tracker),
      last_accepted: state.last_accepted,
      last_problem: state.last_problem,
      counts: state.counts
    }
  end

  defp changed(state) do
    Events.changed(state.pubsub, :buttons)
    state
  end
end
