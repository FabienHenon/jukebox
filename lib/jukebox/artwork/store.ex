defmodule Jukebox.Artwork.Store do
  @moduledoc """
  Bounded in-memory cache for artwork received from the AirPlay sender.

  Images are validated (size limit, JPEG/PNG magic bytes) before they are
  accepted, stored in a protected ETS table and served by
  `JukeboxWeb.ArtworkController` at `/artwork/:id`. The id is derived from
  the content hash, so a new image always gets a new URL and the browser
  never shows a stale cached picture. Only the last few images are kept and
  nothing is ever written to the SD card.
  """

  use GenServer

  alias Jukebox.Playback.Artwork

  @default_max_bytes 2_000_000
  @default_max_entries 3
  @id_pattern ~r/^[A-Za-z0-9_-]{8,32}$/

  @type reason :: :empty | :too_large | :unsupported_format

  # -- client API --------------------------------------------------------------

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Validates and stores an image, returning an artwork reference."
  @spec put(GenServer.server(), binary()) :: {:ok, Artwork.t()} | {:error, reason()}
  def put(store \\ __MODULE__, binary), do: GenServer.call(store, {:put, binary})

  @doc "Looks an image up by id. Safe to call from any process."
  @spec fetch(atom(), String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch(store \\ __MODULE__, id) do
    with true <- valid_id?(id),
         [{^id, content_type, binary}] <- :ets.lookup(store, id) do
      {:ok, content_type, binary}
    else
      _ -> :error
    end
  end

  @doc "Ids currently cached, most recent first."
  def ids(store \\ __MODULE__), do: GenServer.call(store, :ids)

  @doc "Drops every cached image."
  def clear(store \\ __MODULE__), do: GenServer.call(store, :clear)

  @doc "True when the id has the shape produced by this store."
  def valid_id?(id) when is_binary(id), do: Regex.match?(@id_pattern, id)
  def valid_id?(_), do: false

  @doc "Validates an image payload without storing it."
  @spec validate(term(), pos_integer()) :: {:ok, String.t()} | {:error, reason()}
  def validate(binary, max_bytes \\ @default_max_bytes)

  def validate(binary, max_bytes) when is_binary(binary) do
    cond do
      byte_size(binary) == 0 -> {:error, :empty}
      byte_size(binary) > max_bytes -> {:error, :too_large}
      true -> detect_content_type(binary)
    end
  end

  def validate(_not_binary, _max_bytes), do: {:error, :empty}

  # -- callbacks ---------------------------------------------------------------

  @impl true
  def init(opts) do
    configured = Application.get_env(:jukebox, __MODULE__, [])
    table = Keyword.fetch!(opts, :name)
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])

    {:ok,
     %{
       table: table,
       order: [],
       max_bytes: opts[:max_bytes] || configured[:max_bytes] || @default_max_bytes,
       max_entries: opts[:max_entries] || configured[:max_entries] || @default_max_entries
     }}
  end

  @impl true
  def handle_call({:put, binary}, _from, state) do
    case validate(binary, state.max_bytes) do
      {:ok, content_type} ->
        id = id_for(binary)
        :ets.insert(state.table, {id, content_type, binary})
        {keep, evict} = Enum.split([id | List.delete(state.order, id)], state.max_entries)
        Enum.each(evict, &:ets.delete(state.table, &1))
        artwork = %Artwork{id: id, url: "/artwork/#{id}", content_type: content_type}
        {:reply, {:ok, artwork}, %{state | order: keep}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:ids, _from, state), do: {:reply, state.order, state}

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | order: []}}
  end

  # -- internals ---------------------------------------------------------------

  defp detect_content_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp detect_content_type(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, "image/png"}
  defp detect_content_type(_), do: {:error, :unsupported_format}

  defp id_for(binary) do
    :crypto.hash(:sha256, binary)
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end
end
