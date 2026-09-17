defmodule Jukebox.Playback.Artwork do
  @moduledoc """
  A reference to the current artwork.

  The kiosk never receives binary image data over the LiveView socket. It
  receives this small struct whose `url` is either a bundled static image
  (demo and fallback art under `priv/static/images`) or an entry of the
  in-memory `Jukebox.Artwork.Store` served at `/artwork/:id`.

  The `id` doubles as a cache-busting version: a different image always has a
  different id, so the browser reloads it.
  """

  @enforce_keys [:id, :url]
  defstruct [:id, :url, content_type: "image/svg+xml"]

  @type t :: %__MODULE__{id: String.t(), url: String.t(), content_type: String.t()}

  @demo_count 4
  @fallback_url "/images/fallback-artwork.svg"

  @doc "Number of bundled abstract demo covers."
  def demo_count, do: @demo_count

  @doc "Reference to one of the bundled abstract demo covers."
  @spec demo(pos_integer()) :: t()
  def demo(n) when is_integer(n) and n in 1..@demo_count do
    %__MODULE__{id: "demo-#{n}", url: "/images/demo-artwork-#{n}.svg"}
  end

  @doc "URL of the local fallback design used when artwork is missing."
  def fallback_url, do: @fallback_url

  @doc "True when both references point at the same image (or are both nil)."
  @spec same?(t() | nil, t() | nil) :: boolean()
  def same?(nil, nil), do: true
  def same?(%__MODULE__{id: id}, %__MODULE__{id: id}), do: true
  def same?(_, _), do: false
end
