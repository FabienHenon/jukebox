defmodule Jukebox.Hardware.Events do
  @moduledoc """
  PubSub notifications that some part of the hardware status changed
  (`{:hardware_changed, :buttons | :lights | :brightness}`). They carry no
  data: a subscriber that shows the status reads `Jukebox.Hardware.status/0`
  again.
  """

  @topic "hardware"

  def topic, do: @topic

  def subscribe(pubsub \\ Jukebox.PubSub), do: Phoenix.PubSub.subscribe(pubsub, @topic)

  def changed(pubsub \\ Jukebox.PubSub, subsystem) do
    Phoenix.PubSub.local_broadcast(pubsub, @topic, {:hardware_changed, subsystem})
  end
end
