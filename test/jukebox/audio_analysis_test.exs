defmodule Jukebox.AudioAnalysisTest do
  # Reads and changes application and system environment.
  use ExUnit.Case, async: false

  alias Jukebox.AudioAnalysis
  alias Jukebox.AudioAnalysis.{DisabledSource, Frame, NativeSource, SimulatedSource}

  @audio_variables ~w(
    AUDIO_REACTIVE_ENABLED AUDIO_REACTIVE_SOURCE AUDIO_ANALYSIS_SOCKET
    AUDIO_ANALYSIS_PUBLISH_RATE AUDIO_VISUAL_DELAY_MS AUDIO_BEAT_CONFIDENCE_THRESHOLD
  )

  defp put_app_env(key, value) do
    previous = Application.fetch_env(:jukebox, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jukebox, key, value)
        :error -> Application.delete_env(:jukebox, key)
      end
    end)

    Application.put_env(:jukebox, key, value)
  end

  # Evaluates config/runtime.exs as the production release does at boot, with
  # the given environment variables, and returns the :jukebox configuration.
  defp production_config(variables) do
    names = ["SECRET_KEY_BASE" | @audio_variables]
    previous = Map.new(names, &{&1, System.get_env(&1)})

    try do
      Enum.each(@audio_variables, &System.delete_env/1)
      System.put_env("SECRET_KEY_BASE", String.duplicate("x", 64))
      System.put_env(variables)
      Config.Reader.read!("config/runtime.exs", env: :prod)[:jukebox]
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  describe "publish/2 and subscribe/1" do
    test "subscribers receive the frame as {:audio_frame, frame}" do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      :ok = AudioAnalysis.subscribe(pubsub)

      {:ok, frame} =
        Frame.new(%{level: 0.5, bass: 0.4, onset: 0, beat_id: 1, bpm: 120, confidence: 0.9})

      assert AudioAnalysis.publish(pubsub, frame) == :ok
      assert_receive {:audio_frame, ^frame}
      assert AudioAnalysis.topic() == "audio_analysis"
    end
  end

  describe "the configured source" do
    test "is disabled in the test environment, and the application runs without it" do
      assert AudioAnalysis.source() == {DisabledSource, []}
      assert AudioAnalysis.source_kind() == :disabled
      refute AudioAnalysis.enabled?()

      # The running application was started with the feature disabled: the
      # disabled source is part of the tree and started nothing.
      assert DisabledSource in Enum.map(Jukebox.Integrations.children(), & &1.id)
      assert DisabledSource.start_link([]) == :ignore
      assert Process.whereis(NativeSource) == nil
      assert Process.whereis(SimulatedSource) == nil
      assert Process.alive?(Process.whereis(Jukebox.Integrations))
      assert Process.alive?(Process.whereis(JukeboxWeb.Endpoint))
    end

    test "is recognised by kind" do
      put_app_env(:audio_source, {NativeSource, socket: "/run/jukebox/audio-analysis.sock"})
      assert AudioAnalysis.source_kind() == :native
      assert AudioAnalysis.enabled?()

      put_app_env(:audio_source, {SimulatedSource, []})
      assert AudioAnalysis.source_kind() == :simulated
      assert AudioAnalysis.enabled?()
    end

    test "becomes a supervised child built by the source itself" do
      put_app_env(:audio_source, {NativeSource, socket: "/tmp/somewhere.sock"})
      spec = Enum.find(Jukebox.Integrations.children(), &(&1.id == NativeSource))
      assert {NativeSource, :start_link, [[socket: "/tmp/somewhere.sock"]]} = spec.start

      put_app_env(:audio_source, {SimulatedSource, []})
      assert SimulatedSource in Enum.map(Jukebox.Integrations.children(), & &1.id)
    end
  end

  describe "source selection from the environment (config/runtime.exs)" do
    test "audio analysis is off unless asked for" do
      config = production_config(%{})
      assert config[:audio_source] == {DisabledSource, []}

      assert config[AudioAnalysis] == [
               publish_rate: 20,
               visual_delay_ms: 120,
               beat_confidence_threshold: 0.45
             ]
    end

    test "enabled, the native source is the default, on the default socket" do
      config = production_config(%{"AUDIO_REACTIVE_ENABLED" => "true"})

      assert config[:audio_source] ==
               {NativeSource, socket: "/run/jukebox/audio-analysis.sock"}
    end

    test "every documented variable is read" do
      config =
        production_config(%{
          "AUDIO_REACTIVE_ENABLED" => "true",
          "AUDIO_REACTIVE_SOURCE" => "native",
          "AUDIO_ANALYSIS_SOCKET" => "/run/elsewhere/a.sock",
          "AUDIO_ANALYSIS_PUBLISH_RATE" => "12",
          "AUDIO_VISUAL_DELAY_MS" => "80",
          "AUDIO_BEAT_CONFIDENCE_THRESHOLD" => "0.6"
        })

      assert config[:audio_source] == {NativeSource, socket: "/run/elsewhere/a.sock"}

      assert config[AudioAnalysis] == [
               publish_rate: 12,
               visual_delay_ms: 80,
               beat_confidence_threshold: 0.6
             ]
    end

    test "the simulated source can be selected" do
      config =
        production_config(%{
          "AUDIO_REACTIVE_ENABLED" => "true",
          "AUDIO_REACTIVE_SOURCE" => "simulated"
        })

      assert config[:audio_source] == {SimulatedSource, []}
    end

    test "either switch disables it" do
      for variables <- [
            %{"AUDIO_REACTIVE_ENABLED" => "false", "AUDIO_REACTIVE_SOURCE" => "native"},
            %{"AUDIO_REACTIVE_ENABLED" => "true", "AUDIO_REACTIVE_SOURCE" => "disabled"},
            %{"AUDIO_REACTIVE_SOURCE" => "simulated"}
          ] do
        assert production_config(variables)[:audio_source] == {DisabledSource, []}
      end
    end

    test "invalid values fail at boot with a readable message" do
      assert_raise RuntimeError, ~r/AUDIO_REACTIVE_SOURCE must be/, fn ->
        production_config(%{"AUDIO_REACTIVE_SOURCE" => "microphone"})
      end

      assert_raise RuntimeError,
                   ~r/AUDIO_ANALYSIS_PUBLISH_RATE must be an integer between 1 and 20/,
                   fn ->
                     production_config(%{"AUDIO_ANALYSIS_PUBLISH_RATE" => "60"})
                   end

      assert_raise RuntimeError, ~r/AUDIO_VISUAL_DELAY_MS must be an integer/, fn ->
        production_config(%{"AUDIO_VISUAL_DELAY_MS" => "soon"})
      end

      assert_raise RuntimeError, ~r/AUDIO_BEAT_CONFIDENCE_THRESHOLD must be a number/, fn ->
        production_config(%{"AUDIO_BEAT_CONFIDENCE_THRESHOLD" => "1.5"})
      end

      assert_raise RuntimeError, ~r/AUDIO_REACTIVE_ENABLED must be true or false/, fn ->
        production_config(%{"AUDIO_REACTIVE_ENABLED" => "maybe"})
      end
    end
  end

  describe "settings/0" do
    test "returns the configured values" do
      put_app_env(AudioAnalysis,
        publish_rate: 10,
        visual_delay_ms: 0,
        beat_confidence_threshold: 1
      )

      assert AudioAnalysis.settings() == %{
               publish_rate: 10,
               visual_delay_ms: 0,
               beat_confidence_threshold: 1.0
             }
    end

    test "falls back to safe defaults for missing or invalid values" do
      defaults = %{publish_rate: 20, visual_delay_ms: 120, beat_confidence_threshold: 0.45}

      put_app_env(AudioAnalysis, [])
      assert AudioAnalysis.settings() == defaults

      put_app_env(AudioAnalysis,
        publish_rate: 500,
        visual_delay_ms: -1,
        beat_confidence_threshold: "high"
      )

      assert AudioAnalysis.settings() == defaults
    end
  end
end
