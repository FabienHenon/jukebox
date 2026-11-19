defmodule Jukebox.AudioAnalysis.SimulatedSource do
  @moduledoc """
  A deterministic stand-in for the native analyser, for development on a
  machine without ALSA and for tests.

  Frames are a pure function of a frame counter (`frame_at/2`): the same
  counter always gives the same frame, so a test can state exactly what it
  expects. The values are shaped like music rather than noise: loudness that
  drifts, a bass pulse on every beat, a steady beat counter and a few
  off-beat attacks.

  Profiles (`set_profile/2`) reproduce the situations the display has to
  cope with:

    * `:steady` - music with a clear beat (the default)
    * `:free_tempo` - music the beat tracker cannot follow: irregular beats,
      no tempo, low confidence
    * `:silent` - the analyser is running on silence
    * `:down` - no frames at all, as when the analyser is not running

  Like the real analyser, which only receives sound while Shairport Sync is
  playing, the source publishes only while playback is running (see the
  `:playback` option). `tick_ms: nil` disables the timer so tests can step
  it with `tick/1`.
  """

  @behaviour Jukebox.AudioAnalysis.Source

  use GenServer

  alias Jukebox.AudioAnalysis
  alias Jukebox.AudioAnalysis.Frame
  alias Jukebox.Playback

  @profiles [:steady, :free_tempo, :silent, :down]
  @default_bpm 112
  @bpm_range 40..240

  @type profile :: :steady | :free_tempo | :silent | :down

  @impl Jukebox.AudioAnalysis.Source
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Options:

    * `:name` - registered name (default: this module)
    * `:pubsub` - PubSub server to publish on
    * `:publish_rate` - frames per second (default: configured)
    * `:tick_ms` - timer period; `:auto` (default) derives it from the rate,
      `nil` disables the timer
    * `:bpm` - tempo of the simulated music (default #{@default_bpm})
    * `:profile` - one of `#{inspect(@profiles)}` (default `:steady`)
    * `:playback` - playback server to follow, so frames stop while nothing
      plays (default `Jukebox.Playback.Server`); `nil` publishes regardless
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Every profile, in the order the simulator shows them."
  def profiles, do: @profiles

  @doc "Selects what kind of audio is simulated."
  def set_profile(profile, opts \\ []) when profile in @profiles,
    do: call(opts, {:set_profile, profile})

  @doc "Changes the tempo of the simulated music."
  def set_bpm(bpm, opts \\ []) when is_integer(bpm) and bpm in @bpm_range,
    do: call(opts, {:set_bpm, bpm})

  @doc "Publishes the next frame now (when one is due) and returns it."
  def tick(opts \\ []), do: call(opts, :tick)

  @doc "Back to the first frame of the default profile and tempo."
  def reset(opts \\ []), do: call(opts, :reset)

  @doc "Current settings: `:profile`, `:bpm`, `:playing?` and the frame counter `:index`."
  def snapshot(opts \\ []), do: call(opts, :snapshot)

  defp call(opts, message) do
    server = Keyword.get(opts, :server, __MODULE__)

    case GenServer.whereis(server) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, message)
    end
  end

  # -- the simulated music -----------------------------------------------------

  @doc """
  The frame for counter `index`, or `nil` when the profile publishes nothing.

  Options: `:publish_rate` (frames per second, default 20), `:bpm` (default
  #{@default_bpm}) and `:profile` (default `:steady`).
  """
  @spec frame_at(non_neg_integer(), keyword()) :: Frame.t() | nil
  def frame_at(index, opts \\ []) when is_integer(index) and index >= 0 do
    rate = Keyword.get(opts, :publish_rate, 20)
    bpm = Keyword.get(opts, :bpm, @default_bpm)
    frame_ms = 1000 / rate
    simulate(Keyword.get(opts, :profile, :steady), index * frame_ms, frame_ms, 60_000 / bpm, bpm)
  end

  defp simulate(:down, _t, _frame_ms, _period, _bpm), do: nil

  defp simulate(:silent, _t, _frame_ms, _period, _bpm) do
    %Frame{level: 0.0, bass: 0.0, onset: 0.0, beat_id: 0, bpm: nil, confidence: 0.0}
  end

  defp simulate(:steady, t, frame_ms, period, bpm) do
    beat = floor(t / period)
    phase = t / period - beat
    # The first beat of every bar hits harder.
    accent = if rem(beat, 4) == 0, do: 1.0, else: 0.78
    kick = accent * :math.exp(-6 * phase)
    # The width of one frame, as a fraction of a beat.
    window = frame_ms / period

    onset =
      cond do
        phase < window -> 0.9 * accent
        rem(beat, 2) == 1 and within?(phase, 0.5, window) -> 0.42
        rem(beat * 7 + 3, 11) < 2 and within?(phase, 0.75, window) -> 0.6
        true -> 0.0
      end

    %Frame{
      level: unit(0.44 + 0.14 * wave(t, 9000) + 0.07 * wave(t + 600, 2300) + 0.3 * kick),
      bass: unit(0.06 + 0.92 * kick),
      onset: onset,
      beat_id: beat + 1,
      bpm: bpm * 1.0,
      confidence: unit(0.82 + 0.1 * wave(t, 6100))
    }
  end

  # Beats land on a clock that speeds up and slows down, as a beat tracker
  # guessing its way through rubato does, and nothing claims to know the tempo.
  defp simulate(:free_tempo, t, frame_ms, period, _bpm) do
    warped = t + 180 * wave(t, 3700) + 90 * wave(t, 1300)
    previous = t - frame_ms
    beat = floor(warped / period)

    previous_beat =
      floor((previous + 180 * wave(previous, 3700) + 90 * wave(previous, 1300)) / period)

    %Frame{
      level: unit(0.4 + 0.2 * wave(t, 5300) + 0.08 * wave(t, 1900)),
      bass: unit(0.26 + 0.2 * wave(t, 1700)),
      onset: if(beat != previous_beat and rem(beat, 3) != 0, do: 0.5, else: 0.0),
      beat_id: max(beat, 0) + 1,
      bpm: nil,
      confidence: unit(0.18 + 0.08 * wave(t, 4100))
    }
  end

  defp wave(t, period_ms), do: :math.sin(2 * :math.pi() * t / period_ms)
  defp within?(phase, start, window), do: phase >= start and phase < start + window
  defp unit(value), do: value |> max(0.0) |> min(1.0)

  # -- callbacks ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    rate = Keyword.get_lazy(opts, :publish_rate, fn -> AudioAnalysis.settings().publish_rate end)

    tick_ms =
      case Keyword.get(opts, :tick_ms, :auto) do
        :auto -> round(1000 / rate)
        other -> other
      end

    pubsub = Keyword.get(opts, :pubsub, Jukebox.PubSub)
    playback = Keyword.get(opts, :playback, Playback.Server)

    state = %{
      pubsub: pubsub,
      publish_rate: rate,
      tick_ms: tick_ms,
      bpm: Keyword.get(opts, :bpm, @default_bpm),
      profile: Keyword.get(opts, :profile, :steady),
      defaults: {Keyword.get(opts, :profile, :steady), Keyword.get(opts, :bpm, @default_bpm)},
      playback: playback,
      playing?: playback == nil,
      index: 0
    }

    if playback, do: Playback.Server.subscribe(pubsub)
    if tick_ms, do: :timer.send_interval(tick_ms, :tick)

    {:ok, state, {:continue, :read_playback}}
  end

  @impl GenServer
  def handle_continue(:read_playback, %{playback: nil} = state), do: {:noreply, state}

  def handle_continue(:read_playback, state) do
    {:noreply, %{state | playing?: playing?(read_playback(state.playback))}}
  end

  @impl GenServer
  def handle_call({:set_profile, profile}, _from, state),
    do: {:reply, :ok, %{state | profile: profile}}

  def handle_call({:set_bpm, bpm}, _from, state), do: {:reply, :ok, %{state | bpm: bpm}}

  def handle_call(:tick, _from, state) do
    {frame, state} = step(state)
    {:reply, frame, state}
  end

  def handle_call(:reset, _from, %{defaults: {profile, bpm}} = state),
    do: {:reply, :ok, %{state | profile: profile, bpm: bpm, index: 0}}

  def handle_call(:snapshot, _from, state),
    do: {:reply, Map.take(state, [:profile, :bpm, :playing?, :index]), state}

  @impl GenServer
  def handle_info(:tick, state) do
    {_frame, state} = step(state)
    {:noreply, state}
  end

  def handle_info({:playback_state, playback}, state),
    do: {:noreply, %{state | playing?: playing?(playback)}}

  def handle_info(_message, state), do: {:noreply, state}

  # The counter only advances while music plays: a paused track resumes where
  # it stopped.
  defp step(%{playing?: false} = state), do: {nil, state}

  defp step(state) do
    frame =
      frame_at(state.index,
        publish_rate: state.publish_rate,
        bpm: state.bpm,
        profile: state.profile
      )

    if frame, do: AudioAnalysis.publish(state.pubsub, frame)
    {frame, %{state | index: state.index + 1}}
  end

  defp read_playback(server) do
    Playback.Server.get_state(server)
  catch
    :exit, _reason -> nil
  end

  defp playing?(%Playback.State{session_status: :active, playback_status: :playing}), do: true
  defp playing?(_other), do: false
end
