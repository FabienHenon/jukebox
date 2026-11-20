defmodule Jukebox.Commands do
  @moduledoc """
  Semantic command service.

  Every physical or development input (GPIO buttons, the fake input used in
  tests, development keyboard shortcuts, the simulator) ends up here with one
  of the semantic commands:

    * `:previous_track`, `:toggle_playback`, `:next_track` - transport
      commands. The service decides whether they can be honoured and forwards
      them to the configured `Jukebox.RemoteControl` adapter.
    * `:cycle_animation` - a display command. It never leaves the jukebox: it
      moves `Jukebox.Animation` to its next style, with or without a player.
    * `:toggle_disco`, `:toggle_strip`, `:brightness_down`, `:brightness_up` -
      hardware commands, handed to `Jukebox.Hardware` (lights behind the power
      controller, software dimming of the X11 output). They take a moment and
      their result has to be observed on the hardware, so `dispatch/2` only
      answers `{:ok, :accepted}` and the outcome arrives later through
      `report/3`.

  Either way a small feedback message is broadcast on PubSub
  (`{:command_feedback, map}`) so the kiosk can acknowledge the press. For a
  hardware command it is broadcast once the result is known, and it only ever
  states what was confirmed.

  Failures are logged and converted into a safe `{:error, _}` outcome; they
  never propagate to the caller or the playback state process.
  """

  require Logger

  alias Jukebox.{Animation, Playback}

  @topic "commands"
  @hardware_commands [:toggle_disco, :toggle_strip, :brightness_down, :brightness_up]
  @commands [:previous_track, :toggle_playback, :next_track, :cycle_animation] ++
              @hardware_commands

  @type command ::
          :previous_track
          | :toggle_playback
          | :next_track
          | :cycle_animation
          | :toggle_disco
          | :toggle_strip
          | :brightness_down
          | :brightness_up
  @type outcome ::
          {:ok, :sent}
          | {:ok, {:animation, Animation.style()}}
          | {:ok, :accepted}
          | {:ok, {:light, :disco | :strip, boolean()}}
          | {:ok, {:brightness, 0..100}}
          | {:error,
             :no_active_player
             | :control_unavailable
             | :failed
             | :not_awake
             | :busy
             | :hardware_unavailable
             | :unconfirmed}
  @type feedback :: %{
          id: pos_integer(),
          command: command(),
          result: outcome(),
          playback_status: Playback.State.playback_status()
        }

  @doc "The semantic commands an input may emit."
  def commands, do: @commands

  def topic, do: @topic

  @doc "Subscribes the caller to `{:command_feedback, feedback}` messages."
  def subscribe(pubsub \\ Jukebox.PubSub), do: Phoenix.PubSub.subscribe(pubsub, @topic)

  @doc """
  Carries out a semantic command: transport commands go to the remote-control
  adapter, `:cycle_animation` to the animation style owner.

  Options (mainly for tests):

    * `:remote_control` - adapter module (default: configured adapter)
    * `:playback` - playback server (default `Jukebox.Playback.Server`)
    * `:animation` - animation server (default `Jukebox.Animation`)
    * `:hardware` - one-arity function carrying out a hardware command
      (default `Jukebox.Hardware.request/1`)
    * `:pubsub` - PubSub server for feedback (default `Jukebox.PubSub`)
  """
  @spec dispatch(command(), keyword()) :: outcome() | {:error, :unknown_command}
  def dispatch(command, opts \\ [])

  def dispatch(command, opts) when command in @hardware_commands do
    hardware = Keyword.get(opts, :hardware, &Jukebox.Hardware.request/1)

    case hardware.(command) do
      # Nothing to show yet: the worker reports once the hardware confirmed.
      {:ok, :accepted} -> {:ok, :accepted}
      {:error, _reason} = refused -> report(command, refused, opts)
    end
  end

  def dispatch(command, opts) when command in @commands do
    playback = Keyword.get(opts, :playback, Playback.Server)
    state = Playback.Server.get_state(playback)
    result = perform(command, state, opts)
    broadcast(command, result, state.playback_status, opts)
    result
  end

  def dispatch(_command, _opts), do: {:error, :unknown_command}

  @doc """
  Broadcasts the outcome of a hardware command once it is known: the light
  state the power controller confirmed, the brightness the monitor reported
  back, or the reason nothing could be confirmed. Called by the workers of
  `Jukebox.Hardware`. Returns `result`.
  """
  @spec report(command(), outcome(), keyword()) :: outcome()
  def report(command, result, opts \\ []) when command in @hardware_commands do
    broadcast(command, result, playback_status(opts), opts)
    result
  end

  defp broadcast(command, result, playback_status, opts) do
    feedback = %{
      id: System.unique_integer([:positive, :monotonic]),
      command: command,
      result: result,
      playback_status: playback_status
    }

    pubsub = Keyword.get(opts, :pubsub, Jukebox.PubSub)
    Phoenix.PubSub.broadcast(pubsub, @topic, {:command_feedback, feedback})
  end

  # Only there to complete the feedback message; a hardware outcome must be
  # reported even if the playback server cannot be asked.
  defp playback_status(opts) do
    Playback.Server.get_state(Keyword.get(opts, :playback, Playback.Server)).playback_status
  catch
    :exit, _reason -> :stopped
  end

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

  defp perform(:cycle_animation, _state, opts) do
    cycle_animation(Keyword.get(opts, :animation, Animation))
  end

  defp perform(command, state, opts) do
    remote = Keyword.get_lazy(opts, :remote_control, &configured_remote_control/0)
    route(command, state, remote)
  end

  defp cycle_animation(server) do
    {:ok, {:animation, Animation.cycle(server)}}
  catch
    :exit, reason ->
      Logger.error("[commands] cycle_animation exited: #{inspect(reason)}")
      {:error, :failed}
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
