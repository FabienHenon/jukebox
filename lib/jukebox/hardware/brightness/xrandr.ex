defmodule Jukebox.Hardware.Brightness.Xrandr do
  @moduledoc """
  Software dimming of one X11 output with `/usr/bin/xrandr`.

  `xrandr --brightness` scales the gamma ramp of the whole output. It darkens
  the picture; it does **not** touch the monitor's backlight, the value in the
  monitor's own menu or its power consumption. `1.0` means "no software
  dimming", not "maximum backlight".

  Two commands are used, each one process started from a fixed executable
  path and an argument list (no shell, no `sudo`), with a real deadline after
  which it is killed (`Jukebox.Hardware.Exec`):

      xrandr --verbose                              read the applied coefficient
      xrandr --output <OUTPUT> --brightness <0.7>   set it

  The child gets `DISPLAY` and `XAUTHORITY` from the configuration (a systemd
  service does not inherit the kiosk session's environment) and `LC_ALL=C`
  so the output can be parsed. Nothing else is ever passed to xrandr: no mode,
  no rate, no `--off`, no `--auto`, no DPMS.

  Reading comes first and decides everything: the `Brightness:` line is taken
  only from the block of the exact configured output, and that output must be
  connected and showing a picture. xrandr itself merely warns and exits 0
  when asked to change an output that does not exist, so an exit status is
  never taken as proof.
  """

  @behaviour Jukebox.Hardware.Brightness.Backend

  alias Jukebox.Hardware.{Config, Exec}

  @executable "/usr/bin/xrandr"
  @default_timeout_ms 3_000

  @impl true
  def query(opts) do
    with :ok <- authority(opts) do
      case run(opts, ["--verbose"]) do
        {:ok, %{status: 0, output: output}} ->
          parse_verbose(output, Keyword.fetch!(opts, :output))

        other ->
          failure(other)
      end
    end
  end

  @impl true
  def set(coefficient, opts) when is_integer(coefficient) and coefficient > 0 do
    with :ok <- authority(opts) do
      case run(opts, set_arguments(Keyword.fetch!(opts, :output), coefficient)) do
        {:ok, %{status: 0, output: output}} ->
          # "warning: output X not found; ignoring", with exit status 0.
          if output =~ "not found", do: {:error, :output_missing}, else: :ok

        other ->
          failure(other)
      end
    end
  end

  @doc "The complete argument list of a change: the output and its brightness, nothing else."
  @spec set_arguments(String.t(), pos_integer()) :: [String.t()]
  def set_arguments(output, coefficient) do
    ["--output", output, "--brightness", Config.format_coefficient(coefficient)]
  end

  @doc "The environment given to xrandr, on top of the service's own."
  @spec environment(keyword()) :: [{String.t(), String.t()}]
  def environment(opts) do
    [
      {"DISPLAY", Keyword.fetch!(opts, :display)},
      {"XAUTHORITY", Keyword.fetch!(opts, :xauthority)},
      {"LC_ALL", "C"}
    ]
  end

  @doc """
  Finds `output` in the text printed by `xrandr --verbose` and returns its
  software brightness in thousandths.

  An output block starts at a line that is not indented, such as
  `HDMI-1 connected primary 1280x1024+0+0 (0x45) normal (...)`, and runs to
  the next one. Only the block whose name is exactly `output` is read, so the
  `Brightness:` of another output can never be taken for it.

    * no such block: `:output_missing`
    * `disconnected`, or connected without a `WIDTHxHEIGHT+X+Y` geometry (the
      output is switched off): `:output_inactive`
    * no usable `Brightness:` line in the block: `:malformed_reply`
  """
  @spec parse_verbose(String.t(), String.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :output_missing | :output_inactive | :malformed_reply}
  def parse_verbose(text, output) do
    lines = String.split(text, "\n")

    case Enum.split_while(lines, &(not header?(&1, output))) do
      {_before, []} ->
        {:error, :output_missing}

      {_before, [header | rest]} ->
        block = Enum.take_while(rest, &indented?/1)

        if active?(header, output),
          do: brightness(block),
          else: {:error, :output_inactive}
    end
  end

  defp header?(line, output) do
    String.starts_with?(line, output <> " ") and
      line
      |> String.replace_prefix(output <> " ", "")
      |> String.starts_with?(["connected", "disconnected", "unknown connection"])
  end

  defp indented?(line), do: line == "" or String.starts_with?(line, [" ", "\t"])

  defp active?(header, output) do
    rest = String.replace_prefix(header, output <> " ", "")
    String.starts_with?(rest, "connected") and Regex.match?(~r/\s\d+x\d+\+\d+\+\d+(\s|$)/, rest)
  end

  defp brightness(block) do
    with [line] <- Enum.filter(block, &Regex.match?(~r/^\s+Brightness:/, &1)),
         [_line, value] <- Regex.run(~r/^\s+Brightness:\s+(\d{1,2}(?:\.\d{1,6})?)\s*$/, line),
         {coefficient, ""} <- Float.parse(value) do
      {:ok, round(coefficient * 1000)}
    else
      _unusable -> {:error, :malformed_reply}
    end
  end

  # Checked first: without the authority file xrandr only says that it cannot
  # open the display, which would hide the real reason. The file's content is
  # never read here.
  defp authority(opts) do
    case File.stat(Keyword.fetch!(opts, :xauthority)) do
      {:ok, %File.Stat{type: :regular, access: access}} when access in [:read, :read_write] -> :ok
      {:ok, %File.Stat{}} -> {:error, :xauthority_unreadable}
      {:error, :eacces} -> {:error, :xauthority_unreadable}
      {:error, _reason} -> {:error, :xauthority_missing}
    end
  end

  defp run(opts, args) do
    Exec.run(Keyword.get(opts, :executable, @executable), args,
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      env: environment(opts)
    )
  end

  defp failure({:error, :timeout}), do: {:error, :timeout}
  defp failure({:error, :not_found}), do: {:error, :xrandr_missing}
  defp failure({:error, reason}), do: {:error, {:command_failed, reason}}

  defp failure({:ok, %{status: status, output: output}}) do
    cond do
      output =~ ~r/Authorization required|No protocol specified|Invalid MIT-MAGIC-COOKIE/i ->
        {:error, :x11_unauthorized}

      output =~ ~r/Can't open display/i ->
        {:error, :x11_unavailable}

      true ->
        {:error, {:command_failed, status}}
    end
  end
end
