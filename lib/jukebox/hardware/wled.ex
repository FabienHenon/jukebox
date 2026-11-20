defmodule Jukebox.Hardware.Wled do
  @moduledoc """
  The two calls the jukebox makes to a WLED controller on the local network,
  through its JSON API (`/json/state`): read whether the strip is on, and set
  it on or off.

  The target is always an explicit boolean, never WLED's own toggle (`"t"`),
  so sending the same request twice cannot undo it. Requests are short-lived
  and never retried here; the caller decides what a failure means.
  """

  @connect_timeout_ms 1_500
  @receive_timeout_ms 2_500

  @type error :: :timeout | :unreachable | {:http_status, integer()} | :malformed_reply

  @doc "Whether the strip is on, as WLED reports it."
  @spec get_on(String.t(), keyword()) :: {:ok, boolean()} | {:error, error()}
  def get_on(base_url, opts \\ []) do
    case request(:get, base_url, opts) do
      {:ok, %{"on" => on}} when is_boolean(on) -> {:ok, on}
      {:ok, _body} -> {:error, :malformed_reply}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Sets the strip on or off. `"v": true` asks WLED to answer with its state,
  which is returned as the value it now reports.
  """
  @spec set_on(String.t(), boolean(), keyword()) :: {:ok, boolean()} | {:error, error()}
  def set_on(base_url, on, opts \\ []) when is_boolean(on) do
    case request(:post, base_url, Keyword.put(opts, :json, %{on: on, v: true})) do
      {:ok, %{"on" => reported}} when is_boolean(reported) -> {:ok, reported}
      {:ok, _body} -> {:error, :malformed_reply}
      {:error, _reason} = error -> error
    end
  end

  defp request(method, base_url, opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    options =
      [
        method: method,
        url: base_url <> "/json/state",
        retry: false,
        redirect: false,
        connect_options: [timeout: @connect_timeout_ms],
        receive_timeout: @receive_timeout_ms
      ]
      |> Keyword.merge(Keyword.take(opts, [:json]))
      |> Keyword.merge(req_options)

    case Req.request(options) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: 200}} -> {:error, :malformed_reply}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, %{reason: :timeout}} -> {:error, :timeout}
      {:error, _exception} -> {:error, :unreachable}
    end
  rescue
    _exception -> {:error, :unreachable}
  end
end
