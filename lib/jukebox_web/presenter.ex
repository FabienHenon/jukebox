defmodule JukeboxWeb.Presenter do
  @moduledoc """
  Turns the domain `Jukebox.Playback.State` into a flat view model for the
  kiosk template, keeping presentation decisions (which screen to show,
  fallback copy, what to omit, how to format time) out of HEEx.
  """

  alias Jukebox.Commands
  alias Jukebox.Playback.{Artwork, State}

  @unknown_track "Unknown track"

  defstruct mode: :idle,
            playback: :unknown,
            session: :inactive,
            title: nil,
            artist: nil,
            album: nil,
            artwork_url: Artwork.fallback_url(),
            artwork_key: "fallback",
            artwork_fallback?: true,
            track_key: "none",
            progress: nil,
            source_name: nil,
            volume: nil,
            paused?: false,
            ending?: false,
            reconnecting?: false,
            status_pill: nil,
            status_line: "",
            heading: nil,
            wave_level: 1.0

  @type mode :: :idle | :connecting | :now_playing

  @type progress :: %{
          position_ms: non_neg_integer(),
          duration_ms: pos_integer(),
          playing?: boolean(),
          elapsed: String.t(),
          total: String.t()
        }

  @type t :: %__MODULE__{}

  @doc "Builds the view model for a playback state."
  @spec present(State.t(), DateTime.t()) :: t()
  def present(%State{} = state, now \\ DateTime.utc_now()) do
    mode = mode(state)

    %__MODULE__{
      mode: mode,
      playback: state.playback_status,
      session: state.session_status,
      title: title(state, mode),
      artist: state.artist,
      album: album(state),
      artwork_url: artwork_url(state),
      artwork_key: artwork_key(state),
      artwork_fallback?: is_nil(state.artwork),
      track_key: track_key(state),
      progress: progress(state, now),
      source_name: state.source_name,
      volume: volume(state),
      paused?: state.playback_status == :paused,
      ending?: state.session_status == :ending,
      reconnecting?: not state.metadata_connected? and mode != :idle,
      status_pill: status_pill(state, mode),
      status_line: status_line(state, mode),
      heading: heading(mode),
      wave_level: wave_level(state)
    }
  end

  @doc "Which screen to show."
  @spec mode(State.t()) :: mode()
  def mode(%State{} = state) do
    cond do
      state.session_status in [:active, :ending] and State.track?(state) -> :now_playing
      state.session_status in [:connecting, :active] -> :connecting
      true -> :idle
    end
  end

  @doc "Presentation of a command acknowledgement (see `Jukebox.Commands`)."
  @spec feedback(Commands.feedback()) :: %{
          id: pos_integer(),
          kind: :ok | :muted,
          icon: atom(),
          label: String.t()
        }
  def feedback(%{id: id, command: command, result: result, playback_status: playback}) do
    case result do
      {:ok, :sent} ->
        %{id: id, kind: :ok, icon: icon(command, playback), label: label(command, playback)}

      {:error, :no_active_player} ->
        %{id: id, kind: :muted, icon: :info, label: "No active player"}

      {:error, :control_unavailable} ->
        %{id: id, kind: :muted, icon: :info, label: "Control unavailable"}

      {:error, _other} ->
        %{id: id, kind: :muted, icon: :info, label: "Command not delivered"}
    end
  end

  @doc "Formats milliseconds as m:ss or h:mm:ss."
  @spec format_time(integer()) :: String.t()
  def format_time(ms) when is_integer(ms) do
    total = div(max(ms, 0), 1000)
    hours = div(total, 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    if hours > 0,
      do: "#{hours}:#{pad(minutes)}:#{pad(seconds)}",
      else: "#{minutes}:#{pad(seconds)}"
  end

  # -- internals ---------------------------------------------------------------

  defp title(%{title: nil}, :now_playing), do: @unknown_track
  defp title(state, _mode), do: state.title

  # Omit the album when it just repeats the title or the artist.
  defp album(%{album: nil}), do: nil

  defp album(state) do
    album = String.downcase(state.album)

    if album in Enum.map([state.title, state.artist], &(&1 && String.downcase(&1))),
      do: nil,
      else: state.album
  end

  defp artwork_url(%{artwork: %Artwork{url: url}}), do: url
  defp artwork_url(_state), do: Artwork.fallback_url()

  defp artwork_key(%{artwork: %Artwork{id: id}}), do: id
  defp artwork_key(state), do: "fallback-" <> track_key(state)

  defp track_key(%{track_id: id}) when is_binary(id),
    do: "id-" <> Base.url_encode64(id, padding: false)

  defp track_key(state),
    do: "h" <> Integer.to_string(:erlang.phash2({state.title, state.artist, state.album}))

  defp progress(%{duration_ms: duration, position_ms: position} = state, now)
       when is_integer(duration) and duration > 0 and is_integer(position) do
    playing? = state.playback_status == :playing and state.session_status == :active

    age =
      case {playing?, state.position_observed_at} do
        {true, %DateTime{} = at} -> max(DateTime.diff(now, at, :millisecond), 0)
        _ -> 0
      end

    position = position |> Kernel.+(age) |> max(0) |> min(duration)

    %{
      position_ms: position,
      duration_ms: duration,
      playing?: playing?,
      elapsed: format_time(position),
      total: format_time(duration)
    }
  end

  defp progress(_state, _now), do: nil

  defp volume(%{volume_percent: v}) when is_number(v), do: round(v)
  defp volume(_), do: nil

  # Amplitude of the decorative waves: driven by the reported volume only (the
  # waves reflect playback state, never audio analysis). Unknown volume = full.
  defp wave_level(%{volume_percent: v}) when is_number(v) do
    Float.round(0.45 + 0.55 * (v / 100), 2)
  end

  defp wave_level(_state), do: 1.0

  defp status_pill(_state, mode) when mode != :now_playing, do: nil

  defp status_pill(state, _mode) do
    cond do
      state.session_status == :ending -> %{label: "Session ended", kind: :ending}
      state.playback_status == :paused -> %{label: "Paused", kind: :paused}
      state.playback_status == :stopped -> %{label: "Stopped", kind: :stopped}
      state.playback_status == :playing -> %{label: "Playing", kind: :playing}
      true -> nil
    end
  end

  defp status_line(state, mode) do
    cond do
      mode != :idle and not state.metadata_connected? -> "Reconnecting…"
      mode == :idle -> "Waiting for AirPlay…"
      mode == :connecting and state.source_name -> "Connecting to #{state.source_name}…"
      mode == :connecting -> "Connecting…"
      state.session_status == :ending -> "Session ended"
      state.source_name -> "From #{state.source_name}"
      true -> "AirPlay"
    end
  end

  defp heading(:idle), do: "Ready to play"
  defp heading(:connecting), do: "Receiving music…"
  defp heading(_), do: nil

  defp label(:previous_track, _), do: "Previous"
  defp label(:next_track, _), do: "Next"
  defp label(:toggle_playback, :playing), do: "Pause"
  defp label(:toggle_playback, _), do: "Play"

  defp icon(:previous_track, _), do: :previous
  defp icon(:next_track, _), do: :next
  defp icon(:toggle_playback, :playing), do: :pause
  defp icon(:toggle_playback, _), do: :play

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)
end
