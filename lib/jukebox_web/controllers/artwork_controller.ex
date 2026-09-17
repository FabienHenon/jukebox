defmodule JukeboxWeb.ArtworkController do
  @moduledoc """
  Serves artwork from the in-memory `Jukebox.Artwork.Store`.

  Ids are content hashes, so responses are immutable and cacheable. An
  unknown or expired id redirects to the bundled fallback design, which keeps
  the kiosk `<img>` valid even if the cache was evicted.
  """

  use JukeboxWeb, :controller

  alias Jukebox.Artwork.Store
  alias Jukebox.Playback.Artwork

  def show(conn, %{"id" => id}) do
    case Store.fetch(id) do
      {:ok, content_type, binary} ->
        conn
        |> put_resp_content_type(content_type, nil)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> send_resp(200, binary)

      :error ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> redirect(to: Artwork.fallback_url())
    end
  end
end
