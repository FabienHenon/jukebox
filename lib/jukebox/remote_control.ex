defmodule Jukebox.RemoteControl do
  @moduledoc """
  Remote-control boundary towards the AirPlay sender.

  Remote control is a *capability*, not an assumption: `capabilities/0`
  reports which commands the adapter can currently relay, and the command
  service only calls the corresponding function when it is supported. Every
  function returns `:ok` when the command was handed to the sender and
  `{:error, reason}` otherwise; it must never raise for expected failures.

  Implementations:

    * `Jukebox.RemoteControls.Demo` - drives the demo metadata source
    * `Jukebox.RemoteControls.Shairport` - publishes DACP commands through
      Shairport Sync's MQTT remote topic

  `child_spec/1` is optional: adapters that need a process (like the demo)
  implement it and are started under `Jukebox.Integrations`.
  """

  @callback previous_track() :: :ok | {:error, term()}
  @callback toggle_playback() :: :ok | {:error, term()}
  @callback next_track() :: :ok | {:error, term()}
  @callback capabilities() :: MapSet.t(atom())
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @optional_callbacks child_spec: 1

  @doc "Every command an adapter may report in `capabilities/0` (v1 plus future volume commands)."
  def known_capabilities do
    MapSet.new([:previous_track, :toggle_playback, :next_track, :volume_up, :volume_down])
  end
end
