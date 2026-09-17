defmodule Jukebox.Playback.State do
  @moduledoc """
  Normalised playback state, independent of Shairport Sync or any adapter.

  This module is a pure reducer: `apply_event/3` takes the current state, a
  normalised event (see `Jukebox.Playback.Event`) and the current time, and
  returns the next state plus a list of side-effect *actions* for the owning
  process (`Jukebox.Playback.Server`) to run. Keeping it pure makes every
  transition unit-testable without processes or timers.

  Interpretation rules implemented here:

    * metadata arrives asynchronously and in any order, so partial maps are
      merged and never wipe fields with `nil`;
    * a new track (different `track_id`, or a different title when no id is
      known) clears all track fields so stale artwork is never paired with a
      new title;
    * artwork tagged with a track id that is not the current one is ignored;
    * progress values are validated and clamped, invalid durations are dropped;
    * the position is "frozen" when playback pauses so client interpolation
      can resume from the right point;
    * `session_ended` moves to `:ending` and asks for the idle timer; only
      the timer's `:idle_timeout` clears the screen, so a track change or a
      short flush never flashes back to idle.
  """

  alias Jukebox.Playback.{Artwork, Text}

  @type session_status :: :inactive | :connecting | :active | :ending | :error
  @type playback_status :: :unknown | :stopped | :playing | :paused
  @type remote_control :: :unknown | :available | :unavailable
  @type action :: :schedule_idle | :cancel_idle

  defstruct session_status: :inactive,
            playback_status: :unknown,
            title: nil,
            artist: nil,
            album: nil,
            genre: nil,
            artwork: nil,
            track_id: nil,
            duration_ms: nil,
            position_ms: nil,
            position_observed_at: nil,
            volume_percent: nil,
            source_name: nil,
            source_model: nil,
            remote_control: :unknown,
            metadata_connected?: false,
            last_event_at: nil

  @type t :: %__MODULE__{
          session_status: session_status(),
          playback_status: playback_status(),
          title: String.t() | nil,
          artist: String.t() | nil,
          album: String.t() | nil,
          genre: String.t() | nil,
          artwork: Artwork.t() | nil,
          track_id: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          position_ms: non_neg_integer() | nil,
          position_observed_at: DateTime.t() | nil,
          volume_percent: number() | nil,
          source_name: String.t() | nil,
          source_model: String.t() | nil,
          remote_control: remote_control(),
          metadata_connected?: boolean(),
          last_event_at: DateTime.t() | nil
        }

  @track_reset %{
    title: nil,
    artist: nil,
    album: nil,
    genre: nil,
    artwork: nil,
    track_id: nil,
    duration_ms: nil,
    position_ms: nil,
    position_observed_at: nil
  }

  @live_sessions [:connecting, :active]
  @playback_statuses [:playing, :paused, :stopped]
  @remote_values [:unknown, :available, :unavailable]
  @text_fields [:title, :artist, :album, :genre]

  @doc "Builds a state, optionally overriding fields (mostly for tests)."
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []), do: struct!(__MODULE__, attrs)

  @doc "True when the two states differ in anything but `last_event_at`."
  @spec changed?(t(), t()) :: boolean()
  def changed?(%__MODULE__{} = a, %__MODULE__{} = b) do
    Map.drop(a, [:last_event_at]) != Map.drop(b, [:last_event_at])
  end

  @doc "True when the state carries something worth showing on the Now Playing screen."
  @spec track?(t()) :: boolean()
  def track?(%__MODULE__{} = state) do
    state.title != nil or state.artist != nil or state.artwork != nil
  end

  @doc "True while an AirPlay session is live (connecting or active)."
  @spec session_live?(t()) :: boolean()
  def session_live?(%__MODULE__{session_status: status}), do: status in @live_sessions

  @doc """
  Applies one normalised event. Returns `{new_state, actions}`.

  Unknown or irrelevant events leave the state untouched and return no
  actions. Applied events always stamp `last_event_at` with `now`.
  """
  @spec apply_event(t(), term(), DateTime.t()) :: {t(), [action()]}
  def apply_event(%__MODULE__{} = state, event, %DateTime{} = now) do
    case reduce(state, event, now) do
      :ignore -> {state, []}
      {%__MODULE__{} = next, actions} -> {%{next | last_event_at: now}, actions}
      %__MODULE__{} = next -> {%{next | last_event_at: now}, []}
    end
  end

  # -- session boundaries ----------------------------------------------------

  defp reduce(state, {:session_started, attrs}, _now) when is_map(attrs) do
    source = source_attrs(attrs)

    if state.session_status in @live_sessions do
      {merge(state, source), [:cancel_idle]}
    else
      next =
        state
        |> Map.merge(@track_reset)
        |> merge(source)
        |> Map.merge(%{
          session_status: :connecting,
          playback_status: :unknown,
          volume_percent: nil
        })

      {next, [:cancel_idle]}
    end
  end

  defp reduce(state, {:source_changed, attrs}, _now) when is_map(attrs) do
    merge(state, source_attrs(attrs))
  end

  defp reduce(state, {:session_ended, _attrs}, now) do
    if state.session_status in @live_sessions do
      next =
        state
        |> freeze_position(now)
        |> Map.put(:session_status, :ending)

      {next, [:schedule_idle]}
    else
      :ignore
    end
  end

  defp reduce(%{session_status: :ending} = state, :idle_timeout, _now) do
    %__MODULE__{
      metadata_connected?: state.metadata_connected?,
      last_event_at: state.last_event_at
    }
  end

  defp reduce(_state, :idle_timeout, _now), do: :ignore

  # -- track metadata ---------------------------------------------------------

  defp reduce(state, {:metadata_changed, attrs}, _now) when is_map(attrs) do
    attrs = metadata_attrs(attrs)
    {state, actions} = ensure_active(state)
    state = if new_track?(state, attrs), do: Map.merge(state, @track_reset), else: state
    {merge(state, attrs), actions}
  end

  defp reduce(state, {:track_changed, attrs}, _now) when is_map(attrs) do
    attrs = metadata_attrs(attrs)
    {state, actions} = ensure_active(state)
    same_track? = attrs[:track_id] != nil and attrs[:track_id] == state.track_id
    state = if same_track?, do: state, else: Map.merge(state, @track_reset)
    {merge(state, attrs), actions}
  end

  defp reduce(state, {:artwork_changed, artwork}, now) do
    reduce(state, {:artwork_changed, artwork, []}, now)
  end

  defp reduce(state, {:artwork_changed, artwork, opts}, _now)
       when (is_nil(artwork) or is_struct(artwork, Artwork)) and is_list(opts) do
    for_track = Keyword.get(opts, :track_id)

    cond do
      for_track != nil and state.track_id != nil and for_track != state.track_id ->
        :ignore

      Artwork.same?(state.artwork, artwork) ->
        :ignore

      is_nil(artwork) ->
        %{state | artwork: nil}

      true ->
        {state, actions} = ensure_active(state)
        {%{state | artwork: artwork}, actions}
    end
  end

  # -- progress and playback --------------------------------------------------

  defp reduce(state, {:progress_changed, attrs}, now) when is_map(attrs) do
    duration =
      case Map.fetch(attrs, :duration_ms) do
        {:ok, d} when is_integer(d) and d > 0 -> d
        {:ok, _invalid} -> nil
        :error -> state.duration_ms
      end

    {position, observed_at} =
      case Map.fetch(attrs, :position_ms) do
        {:ok, p} when is_integer(p) -> {clamp_position(p, duration), now}
        _ -> {clamp_position(state.position_ms, duration), state.position_observed_at}
      end

    {state, actions} = ensure_active(state)

    {%{state | duration_ms: duration, position_ms: position, position_observed_at: observed_at},
     actions}
  end

  defp reduce(state, {:playback_changed, status}, now) when status in @playback_statuses do
    cond do
      status == state.playback_status ->
        :ignore

      status == :playing ->
        {state, actions} = ensure_active(state)
        observed_at = if is_integer(state.position_ms), do: now, else: nil
        {%{state | playback_status: :playing, position_observed_at: observed_at}, actions}

      state.session_status == :inactive ->
        :ignore

      true ->
        state
        |> freeze_position(now)
        |> Map.put(:playback_status, status)
    end
  end

  defp reduce(state, {:volume_changed, volume}, _now) when is_number(volume) do
    percent = volume |> max(0) |> min(100) |> round_volume()
    if percent == state.volume_percent, do: :ignore, else: %{state | volume_percent: percent}
  end

  defp reduce(state, {:remote_control_changed, value}, _now) when value in @remote_values do
    if value == state.remote_control, do: :ignore, else: %{state | remote_control: value}
  end

  defp reduce(state, {:metadata_connection_changed, status}, _now)
       when status in [:connected, :disconnected] do
    connected? = status == :connected

    if connected? == state.metadata_connected?,
      do: :ignore,
      else: %{state | metadata_connected?: connected?}
  end

  defp reduce(_state, _unknown_event, _now), do: :ignore

  # -- helpers -----------------------------------------------------------------

  # Any "positive" signal (metadata, artwork, progress, playing) proves the
  # session is live, even if the adapter never sent an explicit start.
  defp ensure_active(%{session_status: :active} = state), do: {state, []}
  defp ensure_active(state), do: {%{state | session_status: :active}, [:cancel_idle]}

  defp new_track?(state, attrs) do
    incoming_id = attrs[:track_id]
    incoming_title = attrs[:title]

    cond do
      incoming_id != nil and state.track_id != nil ->
        incoming_id != state.track_id

      incoming_id == nil and incoming_title != nil and state.title != nil ->
        incoming_title != state.title

      true ->
        false
    end
  end

  defp freeze_position(
         %{
           playback_status: :playing,
           position_ms: position,
           position_observed_at: %DateTime{} = at
         } =
           state,
         now
       )
       when is_integer(position) do
    elapsed = max(DateTime.diff(now, at, :millisecond), 0)

    %{
      state
      | position_ms: clamp_position(position + elapsed, state.duration_ms),
        position_observed_at: now
    }
  end

  defp freeze_position(state, _now), do: state

  defp clamp_position(nil, _duration), do: nil
  defp clamp_position(position, nil), do: max(position, 0)
  defp clamp_position(position, duration), do: position |> max(0) |> min(duration)

  defp round_volume(volume) when is_float(volume), do: Float.round(volume, 1)
  defp round_volume(volume), do: volume

  defp merge(state, attrs) do
    Enum.reduce(attrs, state, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp source_attrs(attrs) do
    %{
      source_name: Text.clean(attrs[:source_name], 80),
      source_model: Text.clean(attrs[:source_model], 80)
    }
  end

  defp metadata_attrs(attrs) do
    text = for field <- @text_fields, into: %{}, do: {field, Text.clean(attrs[field])}

    Map.merge(text, %{
      track_id: track_id(attrs[:track_id]),
      duration_ms: valid_duration(attrs[:duration_ms])
    })
  end

  defp track_id(nil), do: nil
  defp track_id(id) when is_integer(id), do: Integer.to_string(id)
  defp track_id(id) when is_binary(id), do: Text.clean(id, 80)
  defp track_id(_), do: nil

  defp valid_duration(d) when is_integer(d) and d > 0, do: d
  defp valid_duration(_), do: nil
end
