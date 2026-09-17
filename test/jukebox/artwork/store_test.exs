defmodule Jukebox.Artwork.StoreTest do
  use ExUnit.Case, async: true

  alias Jukebox.Artwork.Store
  alias Jukebox.Playback.Artwork

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, "JFIF", 0, 1, 2, 3>>
  @png <<0x89, "PNG\r\n", 0x1A, "\n", "IHDR", 1, 2, 3>>

  setup do
    name = :"artwork_store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name, max_bytes: 64, max_entries: 2})
    {:ok, store: name}
  end

  test "stores validated JPEG and PNG images and serves them by id", %{store: store} do
    assert {:ok, %Artwork{id: id, url: "/artwork/" <> id, content_type: "image/jpeg"}} =
             Store.put(store, @jpeg)

    assert Store.valid_id?(id)
    assert Store.fetch(store, id) == {:ok, "image/jpeg", @jpeg}

    assert {:ok, %Artwork{content_type: "image/png"}} = Store.put(store, @png)
  end

  test "the same image always gets the same id (stable cache URL)", %{store: store} do
    {:ok, a} = Store.put(store, @jpeg)
    {:ok, b} = Store.put(store, @jpeg)
    assert a.id == b.id
    assert Store.ids(store) == [a.id]
  end

  test "rejects empty, oversized and non-image payloads", %{store: store} do
    assert Store.put(store, "") == {:error, :empty}
    assert Store.put(store, @jpeg <> :binary.copy(<<0>>, 100)) == {:error, :too_large}
    assert Store.put(store, "GIF89a....") == {:error, :unsupported_format}

    assert Store.put(store, "<svg xmlns='http://www.w3.org/2000/svg'/>") ==
             {:error, :unsupported_format}

    assert Store.validate(:not_a_binary) == {:error, :empty}
  end

  test "keeps only the most recent entries", %{store: store} do
    {:ok, first} = Store.put(store, @jpeg)
    {:ok, second} = Store.put(store, @png)
    {:ok, third} = Store.put(store, @jpeg <> "x")
    assert Store.ids(store) == [third.id, second.id]
    assert Store.fetch(store, first.id) == :error
    assert {:ok, _, _} = Store.fetch(store, third.id)
  end

  test "fetch never accepts ids that could not have been produced by the store", %{store: store} do
    assert Store.fetch(store, "../../etc/passwd") == :error
    assert Store.fetch(store, "") == :error
    assert Store.fetch(store, nil) == :error
  end

  test "clear drops everything", %{store: store} do
    {:ok, art} = Store.put(store, @jpeg)
    :ok = Store.clear(store)
    assert Store.fetch(store, art.id) == :error
    assert Store.ids(store) == []
  end
end
