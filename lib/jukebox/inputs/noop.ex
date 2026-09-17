defmodule Jukebox.Inputs.Noop do
  @moduledoc """
  Production-safe placeholder input adapter.

  Starts nothing and emits nothing. It keeps the supervision tree and the
  configuration shape ready for a real GPIO adapter without adding an
  unverified native dependency.
  """

  @behaviour Jukebox.Input

  @impl true
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  @doc false
  def start_link(_opts), do: :ignore
end
