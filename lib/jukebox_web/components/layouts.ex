defmodule JukeboxWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use JukeboxWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content. kiosk.html.heex is the
  # root layout of the appliance display.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  With `kiosk` set, the layout renders nothing but the content plus a small
  passive "display reconnecting" hint driven by LiveView's connection
  events. Without it (development simulator) it renders a plain header and
  the flash group.

  ## Examples

      <Layouts.app flash={@flash} kiosk>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :kiosk, :boolean, default: false, doc: "render as the passive appliance display"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%= if @kiosk do %>
      {render_slot(@inner_block)}
      <div
        id="kiosk-offline"
        class="jb-offline"
        hidden
        role="status"
        aria-live="polite"
        phx-disconnected={JS.remove_attribute("hidden")}
        phx-connected={JS.set_attribute({"hidden", ""})}
      >
        Display reconnecting…
      </div>
    <% else %>
      <header class="sim-header">
        <a href="/dev/simulator" class="sim-header__brand">Jukebox simulator</a>
        <nav class="sim-header__nav">
          <a href="/" target="_blank" rel="noopener">Open kiosk</a>
          <a href="/dev/dashboard" target="_blank" rel="noopener">Dashboard</a>
        </nav>
      </header>

      <main class="px-4 py-6 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-7xl space-y-6">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
    <% end %>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc "True when the kiosk should hide the mouse cursor (production)."
  def hide_cursor?, do: Application.get_env(:jukebox, :hide_cursor, false) == true
end
