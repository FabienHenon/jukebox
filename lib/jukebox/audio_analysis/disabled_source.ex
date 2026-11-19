defmodule Jukebox.AudioAnalysis.DisabledSource do
  @moduledoc """
  The audio-analysis source used when the feature is switched off.

  Starts nothing and publishes nothing, so the display keeps its fixed-tempo
  animation.
  """

  @behaviour Jukebox.AudioAnalysis.Source

  @impl true
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  @doc false
  def start_link(_opts), do: :ignore
end
