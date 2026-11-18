defmodule JukeboxWeb.JukeboxLive do
  @moduledoc """
  The kiosk. One LiveView whose appearance follows the playback state owned
  by `Jukebox.Playback.Server`.

  On every mount the complete current state is loaded *before* rendering, and
  on connected mount the view subscribes to playback and command feedback
  broadcasts. The socket never becomes the source of truth: a browser refresh
  or a LiveView reconnect simply re-reads the OTP process.

  Development keyboard shortcuts (`dev_keys` config, compile-time) route
  through `Jukebox.Commands`, the same path future GPIO buttons use.
  """

  use JukeboxWeb, :live_view

  import JukeboxWeb.JukeboxComponents

  alias Jukebox.{Commands, Playback}
  alias JukeboxWeb.Presenter

  @dev_keys Application.compile_env(:jukebox, :dev_keys, false)
  @feedback_ms 900

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe before reading: a state broadcast between the two would
    # otherwise be missed, and a duplicate is harmless.
    if connected?(socket) do
      Playback.Server.subscribe()
      Commands.subscribe()
    end

    state = Playback.Server.get_state()

    {:ok,
     socket
     |> assign(
       page_title: "Jukebox",
       dev_keys?: @dev_keys,
       ready?: connected?(socket),
       feedback: nil
     )
     |> assign_view(state)}
  end

  @impl true
  def handle_info({:playback_state, state}, socket), do: {:noreply, assign_view(socket, state)}

  def handle_info({:command_feedback, feedback}, socket) do
    presented = Presenter.feedback(feedback)
    Process.send_after(self(), {:clear_feedback, presented.id}, @feedback_ms)
    {:noreply, assign(socket, feedback: presented)}
  end

  def handle_info({:clear_feedback, id}, %{assigns: %{feedback: %{id: id}}} = socket) do
    {:noreply, assign(socket, feedback: nil)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Development keyboard shortcuts. The flag is a compile-time constant, so the
  # handler is defined (or not) at module level instead of being checked at
  # runtime: production builds do not contain it at all, and no branch is dead
  # code for the compiler or Dialyzer.
  @impl true
  if @dev_keys do
    def handle_event("dev_command", %{"command" => command}, socket) do
      dev_command(command)
      {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # -- internals ---------------------------------------------------------------

  defp assign_view(socket, state) do
    view = Presenter.present(state)
    assign(socket, view: view, gen: next_gen(socket.assigns[:gen], socket.assigns[:view], view))
  end

  # Generation counters behind the DOM ids of the screen, the artwork and the
  # track text. Each one is bumped when what it identifies changes, so a newly
  # rendered element never shares an id with one that is still fading out
  # (see `JukeboxWeb.JukeboxComponents`).
  defp next_gen(nil, _previous, _view), do: %{screen: 0, art: 0, meta: 0}

  defp next_gen(gen, previous, view) do
    gen
    |> bump(:screen, previous.mode != view.mode)
    |> bump(:art, previous.artwork_key != view.artwork_key)
    |> bump(:meta, previous.track_key != view.track_key)
  end

  defp bump(gen, key, true), do: Map.update!(gen, key, &(&1 + 1))
  defp bump(gen, _key, false), do: gen

  if @dev_keys do
    # Transport keys go through the semantic command service; the two session
    # keys drive the demo metadata source directly (no-ops when it is not running).
    defp dev_command("connect"), do: Jukebox.MetadataSources.Demo.start_session()
    defp dev_command("idle"), do: Jukebox.MetadataSources.Demo.end_session()

    defp dev_command(command) do
      case Commands.parse(command) do
        {:ok, command} -> Commands.dispatch(command)
        :error -> :ignored
      end
    end
  end
end
