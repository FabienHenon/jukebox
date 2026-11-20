defmodule Jukebox.Hardware.Brightness.Backend do
  @moduledoc """
  What the brightness worker needs from the display: the software brightness
  coefficient currently applied to one output, and a way to set it.

  Coefficients are integers in thousandths (`700` is `0.7`), see
  `t:Jukebox.Hardware.Config.coefficient/0`.

  Each function may block for as long as the display server takes (bounded by
  the backend's own deadline) and is only called from a job process.

  Implementations: `Jukebox.Hardware.Brightness.Xrandr` (the kiosk's X11
  output) and `Jukebox.Hardware.Brightness.Simulated`.
  """

  @type error ::
          :xrandr_missing
          | :xauthority_missing
          | :xauthority_unreadable
          | :x11_unavailable
          | :x11_unauthorized
          | :output_missing
          | :output_inactive
          | :malformed_reply
          | :timeout
          | {:command_failed, term()}

  @doc """
  The coefficient applied to the selected output right now. An error when the
  display server cannot be reached, or when the output does not exist, is not
  connected or is switched off: nothing may be applied in those cases.
  """
  @callback query(keyword()) :: {:ok, non_neg_integer()} | {:error, error()}

  @doc "Sets the coefficient. Success means the command ran, not that it took effect."
  @callback set(pos_integer(), keyword()) :: :ok | {:error, error()}
end
