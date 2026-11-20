defmodule Jukebox.Input do
  @moduledoc """
  Physical-input boundary.

  An input adapter is a supervised process that turns hardware events into
  *semantic* commands (`:previous_track`, `:toggle_playback`, `:next_track`,
  `:cycle_animation`) and hands them to `Jukebox.Commands.dispatch/1`. Pin numbers, switch bounce
  and hardware libraries never leave the adapter.

  Implementations:

    * `Jukebox.Inputs.Noop` - starts nothing (production default for this
      boundary)
    * `Jukebox.Inputs.Fake` - test/dev implementation driven by `press/2`,
      which injects semantic commands directly

  The real buttons do not arrive here as commands but as raw key events, and
  they have more to respect than a debounce (the power mode, held keys, lost
  events). Their two adapters are selected by `JUKEBOX_BUTTONS_SOURCE` and
  started by `Jukebox.Hardware.Supervisor`, in front of the dispatcher
  `Jukebox.Hardware.Buttons`:

    * `Jukebox.Inputs.Evdev` - one Linux input device (the USB button
      encoder), read by `priv/hardware/xinmo_evdev.py`
    * `Jukebox.Inputs.Simulated` - the same raw events, injected by hand

  See `docs/physical-controls.md`.
  """

  @type command :: Jukebox.Commands.command()

  @doc "Returns the child spec that supervises the input process."
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "The semantic commands an input may emit."
  def commands, do: Jukebox.Commands.commands()
end
