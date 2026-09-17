defmodule Jukebox.MetadataSource do
  @moduledoc """
  Metadata-source boundary.

  A metadata source is a supervised process that observes the AirPlay
  receiver (Shairport Sync) and pushes normalised `Jukebox.Playback.Event`
  tuples to `Jukebox.Playback.Server.notify/2`. Raw protocol details (MQTT
  topics, four-character Shairport codes, binary artwork formats, broker
  reconnection) must stay inside the adapter.

  Implementations:

    * `Jukebox.MetadataSources.Demo` - simulator used in development and tests
    * `Jukebox.MetadataSources.ShairportMqtt` - Shairport Sync over a local
      MQTT broker (Raspberry Pi)
  """

  @doc "Returns the child spec that supervises the source process."
  @callback child_spec(keyword()) :: Supervisor.child_spec()
end
