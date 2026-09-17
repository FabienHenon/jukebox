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
  alias Jukebox.MetadataSources.Demo
  alias JukeboxWeb.Presenter

  @dev_keys Application.compile_env(:jukebox, :dev_keys, false)
  @feedback_ms 900

  @impl true
  def mount(_params, _session, socket) do
    state = Playback.Server.get_state()

    if connected?(socket) do
      Playback.Server.subscribe()
      Commands.subscribe()
    end

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

  @impl true
  def handle_event("dev_command", %{"command" => command}, socket) do
    if @dev_keys, do: dev_command(command)
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # -- internals ---------------------------------------------------------------

  defp assign_view(socket, state), do: assign(socket, view: Presenter.present(state))

  # Transport keys go through the semantic command service; the two session
  # keys drive the demo metadata source directly (no-ops when it is not running).
  defp dev_command("connect"), do: Demo.start_session()
  defp dev_command("idle"), do: Demo.end_session()

  defp dev_command(command) do
    case Commands.parse(command) do
      {:ok, command} -> Commands.dispatch(command)
      :error -> :ignored
    end
  end
end
