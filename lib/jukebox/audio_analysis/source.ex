defmodule Jukebox.AudioAnalysis.Source do
  @moduledoc """
  Audio-analysis source boundary.

  A source is a supervised process that produces
  `Jukebox.AudioAnalysis.Frame` structs and hands them to
  `Jukebox.AudioAnalysis.publish/2`, no more often than the configured
  `publish_rate`. How the frames are obtained (a Unix socket fed by the native
  analyser, a formula) never leaves the source: subscribers only ever see
  normalised frames.

  A source must never take the application down. It starts under
  `Jukebox.Integrations`, after the endpoint, and has to cope on its own with
  whatever it depends on being absent.

  Implementations:

    * `Jukebox.AudioAnalysis.NativeSource` - frames from the native analyser
    * `Jukebox.AudioAnalysis.SimulatedSource` - deterministic fake frames
    * `Jukebox.AudioAnalysis.DisabledSource` - starts nothing
  """

  @doc "Returns the child spec that supervises the source process."
  @callback child_spec(keyword()) :: Supervisor.child_spec()
end
