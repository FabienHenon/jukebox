defmodule Jukebox.AudioAnalysis do
  @moduledoc """
  Real-time analysis of the music being played: loudness, bass, attacks,
  beats and tempo, as a stream of `Jukebox.AudioAnalysis.Frame` structs.

  The frames come from a *source* (see `Jukebox.AudioAnalysis.Source`):

    * `Jukebox.AudioAnalysis.NativeSource` - the native analyser fed by the
      ALSA tap on the Raspberry Pi (see `docs/audio-reactive-setup.md`)
    * `Jukebox.AudioAnalysis.SimulatedSource` - a deterministic fake for
      development on a machine without ALSA
    * `Jukebox.AudioAnalysis.DisabledSource` - nothing (the default)

  Whatever the source, frames are published on PubSub as
  `{:audio_frame, %Frame{}}`, at most `publish_rate` times per second. The
  kiosk LiveView forwards them to the browser as `audio-frame` events; they
  are never put in assigns, so they never cause a render.

  This module is decoration, like `Jukebox.Animation`: audio playback does not
  go through Phoenix, and nothing here may keep the application from booting
  or the display from rendering. Without frames the browser falls back to the
  fixed-tempo animation.
  """

  alias Jukebox.AudioAnalysis.{DisabledSource, Frame, NativeSource, SimulatedSource}

  @topic "audio_analysis"
  @default_publish_rate 20
  @default_visual_delay_ms 120
  @default_beat_confidence_threshold 0.45

  @type settings :: %{
          publish_rate: pos_integer(),
          visual_delay_ms: non_neg_integer(),
          beat_confidence_threshold: float()
        }

  def topic, do: @topic

  @doc "Subscribes the caller to `{:audio_frame, frame}` messages."
  def subscribe(pubsub \\ Jukebox.PubSub), do: Phoenix.PubSub.subscribe(pubsub, @topic)

  @doc "Publishes a frame to every subscriber on this node."
  @spec publish(atom(), Frame.t()) :: :ok
  def publish(pubsub \\ Jukebox.PubSub, %Frame{} = frame) do
    Phoenix.PubSub.local_broadcast(pubsub, @topic, {:audio_frame, frame})
  end

  @doc "The configured source as `{module, options}`."
  @spec source() :: {module(), keyword()}
  def source, do: Application.get_env(:jukebox, :audio_source, {DisabledSource, []})

  @doc "The configured source by name: `:native`, `:simulated`, `:disabled` or `:custom`."
  @spec source_kind() :: :native | :simulated | :disabled | :custom
  def source_kind do
    case source() do
      {NativeSource, _opts} -> :native
      {SimulatedSource, _opts} -> :simulated
      {DisabledSource, _opts} -> :disabled
      _other -> :custom
    end
  end

  @doc "False when audio-reactive animation is switched off."
  @spec enabled?() :: boolean()
  def enabled?, do: source_kind() != :disabled

  @doc """
  Display settings, with safe defaults for missing or invalid values:

    * `:publish_rate` - most frames per second sent to the browsers
    * `:visual_delay_ms` - how long the browser holds a frame before showing
      it, so the picture lines up with the sound leaving the speakers
    * `:beat_confidence_threshold` - below this confidence the detected beats
      are not trusted and the fixed tempo drives the lights
  """
  @spec settings() :: settings()
  def settings do
    config = Application.get_env(:jukebox, __MODULE__, [])

    %{
      publish_rate:
        valid(config[:publish_rate], &(is_integer(&1) and &1 in 1..20), @default_publish_rate),
      visual_delay_ms:
        valid(
          config[:visual_delay_ms],
          &(is_integer(&1) and &1 in 0..1000),
          @default_visual_delay_ms
        ),
      beat_confidence_threshold:
        valid(
          config[:beat_confidence_threshold],
          &(is_number(&1) and &1 >= 0 and &1 <= 1),
          @default_beat_confidence_threshold
        ) * 1.0
    }
  end

  defp valid(value, valid?, default), do: if(valid?.(value), do: value, else: default)
end
