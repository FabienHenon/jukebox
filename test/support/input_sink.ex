defmodule Jukebox.Test.InputSink do
  @moduledoc """
  Stands in for `Jukebox.Hardware.Buttons` in the input adapters' tests: every
  event an adapter casts is forwarded to the test process as `{:input, event}`.
  """

  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_cast({:input, event}, test) do
    send(test, {:input, event})
    {:noreply, test}
  end
end
