defmodule Jukebox.Demo.Catalog do
  @moduledoc """
  Fictional demo tracks and edge-case presets used by the development
  simulator and the test suite. Artwork numbers refer to the original abstract
  covers bundled under `priv/static/images/demo-artwork-*.svg`.
  """

  @tracks [
    %{
      id: "demo-1",
      title: "Neon Milkshake",
      artist: "The Velvet Comets",
      album: "Saturday Chrome",
      genre: "Retro pop",
      duration_ms: 227_000,
      artwork: 1
    },
    %{
      id: "demo-2",
      title: "Paper Moon Parade",
      artist: "Juniper & the Late Bloomers",
      album: "Postcards From Nowhere",
      genre: "Indie folk",
      duration_ms: 252_000,
      artwork: 2
    },
    %{
      id: "demo-3",
      title: "Static Bloom",
      artist: "Ada Marlowe",
      album: "Static Bloom",
      genre: "Dream pop",
      duration_ms: 303_000,
      artwork: 3
    },
    %{
      id: "demo-4",
      title: "Sunroof Confessions (Live at the Drive-In)",
      artist: "Ferris & Wheeler",
      album: nil,
      genre: "Soul",
      duration_ms: 178_000,
      artwork: 4
    }
  ]

  @presets [
    long: %{
      id: "preset-long",
      title: "The Extraordinarily Long Title Of A Song That Keeps Going On And On Forever",
      artist: "An Orchestra With A Very Long Name And Several Guest Performers",
      album: "A Concept Album Whose Title Also Refuses To Fit On A Single Line Of Text",
      genre: "Progressive",
      duration_ms: 1_146_000,
      artwork: 2
    },
    unicode: %{
      id: "preset-unicode",
      title: "夜明けのメロディー (Ночная серенада)",
      artist: "Élodie Marchand-Ōkubo & Θεόδωρος",
      album: "Über die Straßen – ليلة صيف",
      genre: "World",
      duration_ms: 214_000,
      artwork: 3
    },
    emoji: %{
      id: "preset-emoji",
      title: "Rocket Summer 🚀☀️🌈",
      artist: "DJ Ünicorn 🦄",
      album: "🎧 Mixtape Vol. 1",
      genre: "Electronic",
      duration_ms: 195_000,
      artwork: 1
    },
    no_title: %{
      id: "preset-no-title",
      title: nil,
      artist: "Nameless Ensemble",
      album: "Untitled Sessions",
      genre: nil,
      duration_ms: 240_000,
      artwork: 4
    },
    no_artist: %{
      id: "preset-no-artist",
      title: "Untitled Session #4",
      artist: nil,
      album: nil,
      genre: nil,
      duration_ms: nil,
      artwork: nil
    }
  ]

  @doc "The fictional demo tracks, in playlist order."
  def tracks, do: @tracks

  @doc "Number of demo tracks."
  def count, do: length(@tracks)

  @doc "A demo track by zero-based index (wraps around)."
  def track(index) when is_integer(index) do
    Enum.at(@tracks, Integer.mod(index, count()))
  end

  @doc "Edge-case presets as an ordered keyword list."
  def presets, do: @presets

  @doc "One preset by key."
  def preset(key) when is_atom(key), do: Keyword.get(@presets, key)

  @doc "Preset keys as strings, for the simulator UI."
  def preset_keys, do: Enum.map(@presets, fn {key, _} -> Atom.to_string(key) end)
end
