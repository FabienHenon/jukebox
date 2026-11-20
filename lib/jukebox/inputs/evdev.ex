defmodule Jukebox.Inputs.Evdev do
  @moduledoc """
  The production input adapter: one Linux input device, read by a small Python
  helper (`priv/hardware/xinmo_evdev.py`, on top of the distribution's
  `python3-evdev`) that this process runs as a port.

  The helper opens the one device named by `JUKEBOX_BUTTONS_DEVICE`, never
  another, and prints one JSON object per event on its standard output (see
  `Jukebox.Inputs.Evdev.Protocol`). Its diagnostics go to standard error,
  which ends up in the service's journal. This process decodes the lines and
  forwards the events to `Jukebox.Hardware.Buttons`; it knows nothing about
  actions.

  The helper itself waits for the device and reconnects when it is unplugged,
  so it normally runs for as long as the application does. When it does exit
  (Python or `python3-evdev` missing, a crash) it is started again after a
  pause that doubles from one second up to thirty, which keeps a permanent
  failure from becoming a busy loop or a flood of log lines.

  Nothing is left behind: closing the port closes the helper's standard
  input, which is its signal to exit, and it is sent `SIGTERM` as well. The
  helper also exits by itself if this application disappears.
  """

  @behaviour Jukebox.Input

  use GenServer

  require Logger

  alias Jukebox.Hardware.Buttons
  alias Jukebox.Inputs.Evdev.Protocol

  @python "/usr/bin/python3"
  # Longest protocol line accepted. A "connected" line lists every key code a
  # device advertises; this is ample for a device with several hundred keys.
  @max_line 8_192
  @backoff_min_ms 1_000
  @backoff_max_ms 30_000
  @stable_ms 60_000

  @impl Jukebox.Input
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Options:

    * `:name` - registered name (default: this module)
    * `:device` - the input device path (required)
    * `:sink` - the `Jukebox.Hardware.Buttons` process to feed
    * `:python` - interpreter (default `#{@python}`)
    * `:helper` - helper script (default: the one shipped in `priv/hardware`)
    * `:backoff_min_ms`, `:backoff_max_ms` - restart pauses
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Path of the helper inside the running release (or the build, in development)."
  def helper_path, do: Application.app_dir(:jukebox, "priv/hardware/xinmo_evdev.py")

  @doc "Whether the helper is running, and how often it had to be restarted."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # -- callbacks ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # So terminate/2 runs on shutdown and the helper is stopped.
    Process.flag(:trap_exit, true)

    state = %{
      device: Keyword.fetch!(opts, :device),
      sink: Keyword.get(opts, :sink, Buttons),
      python: Keyword.get(opts, :python, @python),
      helper: Keyword.get_lazy(opts, :helper, &helper_path/0),
      backoff_min: Keyword.get(opts, :backoff_min_ms, @backoff_min_ms),
      backoff_max: Keyword.get(opts, :backoff_max_ms, @backoff_max_ms),
      backoff: nil,
      port: nil,
      os_pid: nil,
      started_at: nil,
      overflow?: false,
      restarts: 0,
      last_exit: nil
    }

    {:ok, %{state | backoff: state.backoff_min}, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state), do: {:noreply, start(state)}

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running?: state.port != nil,
       os_pid: state.os_pid,
       restarts: state.restarts,
       last_exit: state.last_exit
     }, state}
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    if state.overflow? do
      # The end of a line that was too long: all of it is discarded.
      Buttons.input(state.sink, {:malformed, :line_too_long})
      {:noreply, %{state | overflow?: false}}
    else
      forward(state, line)
      {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, _chunk}}}, %{port: port} = state) do
    {:noreply, %{state | overflow?: true}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, stopped(state, {:exited, status})}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:noreply, stopped(state, {:port_closed, reason})}
  end

  def handle_info(:start, %{port: nil} = state), do: {:noreply, start(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, state) do
    close(state.port)

    # Closing its standard input already tells the helper to exit; SIGTERM
    # covers a helper that is stuck. The pid was read while the port was open.
    if state.os_pid do
      System.cmd("kill", ["-TERM", Integer.to_string(state.os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _error -> :ok
  end

  # -- helper process ----------------------------------------------------------

  defp start(state) do
    cond do
      not File.regular?(state.python) ->
        unavailable(state, {:python_missing, state.python})

      not File.regular?(state.helper) ->
        unavailable(state, {:helper_missing, state.helper})

      true ->
        open(state)
    end
  end

  defp open(state) do
    port =
      Port.open({:spawn_executable, state.python}, [
        :binary,
        :exit_status,
        :hide,
        {:line, @max_line},
        args: ["-u", state.helper, "--device", state.device]
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    Buttons.input(state.sink, {:helper, :started})

    %{
      state
      | port: port,
        os_pid: os_pid,
        started_at: System.monotonic_time(:millisecond),
        overflow?: false
    }
  rescue
    error -> unavailable(state, {:cannot_start, Exception.message(error)})
  end

  defp unavailable(state, reason) do
    report(state, reason)
    Buttons.input(state.sink, {:helper, {:unavailable, reason}})
    retry(%{state | last_exit: reason})
  end

  defp stopped(state, reason) do
    close(state.port)
    report(state, reason)
    Buttons.input(state.sink, {:helper, reason})

    # A helper that ran for a while earns a quick restart; one that keeps
    # dying is restarted more and more slowly.
    ran_ms = System.monotonic_time(:millisecond) - (state.started_at || 0)
    backoff = if ran_ms >= @stable_ms, do: state.backoff_min, else: state.backoff

    retry(%{state | port: nil, os_pid: nil, backoff: backoff, last_exit: reason})
  end

  defp retry(state) do
    Process.send_after(self(), :start, state.backoff)
    %{state | backoff: min(state.backoff * 2, state.backoff_max), restarts: state.restarts + 1}
  end

  # Once per distinct reason, not once per attempt.
  defp report(%{last_exit: reason}, reason), do: :ok

  defp report(state, {:exited, 3}) do
    Logger.error(
      "[buttons] the input helper cannot import the evdev module: install python3-evdev " <>
        "(sudo apt install python3-evdev). Retrying, at most every #{div(state.backoff_max, 1000)} s."
    )
  end

  defp report(state, reason) do
    Logger.error(
      "[buttons] the input helper is not running (#{inspect(reason)}). " <>
        "Retrying, at most every #{div(state.backoff_max, 1000)} s."
    )
  end

  defp forward(state, line) do
    case Protocol.decode(line) do
      {:ok, event} -> Buttons.input(state.sink, event)
      :ignore -> :ok
      {:error, reason} -> Buttons.input(state.sink, {:malformed, reason})
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
