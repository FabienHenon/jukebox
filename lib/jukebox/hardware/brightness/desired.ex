defmodule Jukebox.Hardware.Brightness.Desired do
  @moduledoc """
  The brightness the user asked for, kept apart from the process that talks to
  the display.

  It is a number in memory and nothing else: no browser holds it, and the
  worker that runs xrandr only reads and updates it. Reloading the page,
  restarting Chromium or the X server, or a restart of the worker therefore
  never resets it, and after a standby the worker applies this value again.

  Nothing is written to disk. A full restart of the application (or of the
  Raspberry Pi) starts again from `JUKEBOX_BRIGHTNESS_DEFAULT`.

  This process is the first child of `Jukebox.Hardware.Supervisor`, so it is
  not restarted when a process started after it is.
  """

  use Agent

  @doc "Options: `:name` and `:default`, the starting coefficient in thousandths."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    default = Keyword.get(opts, :default) || 1000
    Agent.start_link(fn -> default end, name: name)
  end

  @doc "The desired coefficient, in thousandths."
  @spec get(Agent.agent()) :: pos_integer()
  def get(server \\ __MODULE__), do: Agent.get(server, & &1)

  @doc "Changes the desired coefficient with `fun` and returns the new value."
  @spec update(Agent.agent(), (pos_integer() -> pos_integer())) :: pos_integer()
  def update(server \\ __MODULE__, fun) when is_function(fun, 1) do
    Agent.get_and_update(server, fn current ->
      new = fun.(current)
      {new, new}
    end)
  end
end
