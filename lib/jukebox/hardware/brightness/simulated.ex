defmodule Jukebox.Hardware.Brightness.Simulated do
  @moduledoc """
  A display that only exists in memory, for development and tests
  (`JUKEBOX_BRIGHTNESS_BACKEND=simulated`). It answers like the xrandr backend
  and changes nothing on the screen: no CSS dimming stands in for it.

  `set_available/2` plays an X server that is not there (yet), and `reset/1`
  one that restarted and lost its gamma ramp.
  """

  @behaviour Jukebox.Hardware.Brightness.Backend

  use Agent

  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{coefficient: 1000, available?: true} end, name: name)
  end

  @doc "Makes the pretend X server unreachable (`false`) or reachable again."
  def set_available(server \\ __MODULE__, available?) when is_boolean(available?),
    do: Agent.update(server, &%{&1 | available?: available?})

  @doc "The pretend X server restarted: its brightness is back to neutral."
  def reset(server \\ __MODULE__), do: Agent.update(server, &%{&1 | coefficient: 1000})

  @impl true
  def query(opts) do
    case Agent.get(server(opts), & &1) do
      %{available?: true, coefficient: coefficient} -> {:ok, coefficient}
      %{available?: false} -> {:error, :x11_unavailable}
    end
  end

  @impl true
  def set(coefficient, opts) do
    Agent.get_and_update(server(opts), fn
      %{available?: true} = state -> {:ok, %{state | coefficient: coefficient}}
      state -> {{:error, :x11_unavailable}, state}
    end)
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
end
