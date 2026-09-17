defmodule JukeboxWeb.ArtworkControllerTest do
  use JukeboxWeb.ConnCase, async: false

  alias Jukebox.Artwork.Store

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, "JFIF", 0, 1, 2, 3>>

  setup do
    on_exit(fn -> Store.clear() end)
    :ok
  end

  test "serves a cached image with immutable caching", %{conn: conn} do
    {:ok, artwork} = Store.put(@jpeg)
    conn = get(conn, artwork.url)
    assert conn.status == 200
    assert conn.resp_body == @jpeg
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "redirects unknown or malformed ids to the fallback artwork", %{conn: conn} do
    conn = get(conn, ~p"/artwork/doesnotexist1")
    assert redirected_to(conn) == "/images/fallback-artwork.svg"

    conn = get(build_conn(), "/artwork/..%2F..%2Fetc")
    assert redirected_to(conn) == "/images/fallback-artwork.svg"
  end
end
