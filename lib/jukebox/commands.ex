defmodule Jukebox.Commands do
  @moduledoc """
  Semantic command service.

  Every physical or development input (GPIO buttons, the fake input used in
  tests, development keyboard shortcuts, the simulator) ends up here with one
  of `:previous_track`, `:toggle_playback` or `:next_track`. The service
  decides whether the command can be honoured, forwards it to the configured
  `Jukebox.RemoteControl` adapter and broadcasts a small feedback message on
  PubSub (`{:command_feedback, map}`) so the kiosk can acknowledge the press.

  Failures in the adapter are logged and converted into a safe `{:error, _}`
  outcome; they never propagate to the caller or the playback state process.
  """

  require Logger

  alias Jukebox.Playback

  @topic "commands"
  @commands [:previous_track, :toggle_playback, :next_track]

  @type command :: :previous_track | :toggle_playback | :next_track
  @type outcome :: {:ok, :sent} | {:error, :no_active_player | :control_unavailable | :failed}
  @type feedback :: %{
          id: pos_integer(),
          command: command(),
          result: outcome(),
          playback_status: Playback.State.playback_status()
        }

  @doc "The semantic transport commands supported in version one."
  def commands, do: @commands

  def topic, do: @topic

  @doc "Subscribes the caller to `{:command_feedback, feedback}` messages."
  def subscribe(pubsub \\ Jukebox.PubSub), do: Phoenix.PubSub.subscribe(pubsub, @topic)

  @doc """
  Routes a semantic command to the remote-control adapter.

  Options (mainly for tests):

    * `:remote_control` - adapter module (default: configured adapter)
    * `:playback` - playback server (default `Jukebox.Playback.Server`)
    * `:pubsub` - PubSub server for feedback (default `Jukebox.PubSub`)
  """
  @spec dispatch(command(), keyword()) :: outcome() | {:error, :unknown_command}
  def dispatch(command, opts \\ [])

  def dispatch(command, opts) when command in @commands do
    remote = Keyword.get_lazy(opts, :remote_control, &configured_remote_control/0)
    playback = Keyword.get(opts, :playback, Playback.Server)
    pubsub = Keyword.get(opts, :pubsub, Jukebox.PubSub)

    state = Playback.Server.get_state(playback)
    result = route(command, state, remote)

    feedback = %{
      id: System.unique_integer([:positive, :monotonic]),
      command: command,
      result: result,
      playback_status: state.playback_status
    }

    Phoenix.PubSub.broadcast(pubsub, @topic, {:command_feedback, feedback})
    result
  end

  def dispatch(_command, _opts), do: {:error, :unknown_command}

  @doc "Converts a string (keyboard / simulator) into a command atom."
  @spec parse(String.t()) :: {:ok, command()} | :error
  def parse(string) when is_binary(string) do
    Enum.find_value(@commands, :error, fn command ->
      if Atom.to_string(command) == string, do: {:ok, command}
    end)
  end

  def parse(_), do: :error

  # -- internals ---------------------------------------------------------------

  defp configured_remote_control do
    {module, _opts} = Application.fetch_env!(:jukebox, :remote_control)
    module
  end

  defp route(command, state, remote) do
    cond do
      not Playback.State.session_live?(state) -> {:error, :no_active_player}
      state.remote_control == :unavailable -> {:error, :control_unavailable}
      not supported?(remote, command) -> {:error, :control_unavailable}
      true -> invoke(remote, command)
    end
  end

  defp supported?(remote, command) do
    MapSet.member?(remote.capabilities(), command)
  rescue
    exception ->
      Logger.warning(
        "[commands] #{inspect(remote)}.capabilities/0 failed: #{Exception.message(exception)}"
      )

      false
  catch
    :exit, reason ->
      Logger.warning("[commands] #{inspect(remote)}.capabilities/0 exited: #{inspect(reason)}")
      false
  end

  defp invoke(remote, command) do
    case apply(remote, command, []) do
      :ok ->
        {:ok, :sent}

      {:error, reason} ->
        Logger.warning("[commands] #{command} rejected by #{inspect(remote)}: #{inspect(reason)}")
        {:error, :failed}

      other ->
        Logger.warning("[commands] #{command} returned unexpected #{inspect(other)}")
        {:error, :failed}
    end
  rescue
    exception ->
      Logger.error(
        "[commands] #{command} raised in #{inspect(remote)}: #{Exception.message(exception)}"
      )

      {:error, :failed}
  catch
    :exit, reason ->
      Logger.error("[commands] #{command} exited in #{inspect(remote)}: #{inspect(reason)}")
      {:error, :failed}
  end
end
