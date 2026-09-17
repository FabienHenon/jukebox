defmodule Jukebox.Input do
  @moduledoc """
  Physical-input boundary.

  An input adapter is a supervised process that turns hardware events into
  *semantic* commands (`:previous_track`, `:toggle_playback`, `:next_track`)
  and hands them to `Jukebox.Commands.dispatch/1`. Pin numbers, switch bounce
  and hardware libraries never leave the adapter.

  Implementations:

    * `Jukebox.Inputs.Noop` - production-safe placeholder until GPIO is wired
    * `Jukebox.Inputs.Fake` - test/dev implementation driven by `press/2`

  A future `Jukebox.Inputs.Gpio` should read its pin mapping from
  configuration, apply `Jukebox.Input.Debounce` at the boundary and call
  `Jukebox.Commands.dispatch/1` exactly like the fake input does. See
  `docs/raspberry-pi.md` for the expected mapping.
  """

  @type command :: Jukebox.Commands.command()

  @doc "Returns the child spec that supervises the input process."
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "The semantic commands an input may emit."
  def commands, do: Jukebox.Commands.commands()
end
