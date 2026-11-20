defmodule Jukebox.Hardware.Exec do
  @moduledoc """
  Runs one external helper (`xrandr`, the power client) to completion with a
  real deadline.

  The program is started from a fixed executable path and an argument list,
  never through a shell. When the deadline passes, or when the calling process
  is asked to stop, the operating-system process is killed and waited for, so
  nothing keeps running behind a timed-out caller.

  `run/3` blocks the calling process and traps exits while it waits, which is
  why it is only ever called from a short-lived job process
  (`Jukebox.Hardware.Lane`, the brightness worker's jobs), never from a
  GenServer that has to stay responsive.
  """

  @default_timeout_ms 3_000
  @max_output_bytes 65_536
  @reap_ms 1_000

  @type result ::
          {:ok, %{status: non_neg_integer(), output: binary()}}
          | {:error, :timeout | :not_found | :permission_denied | {:spawn_failed, term()}}

  @doc """
  Options:

    * `:timeout_ms` - deadline for the whole run (default #{@default_timeout_ms})
    * `:env` - extra environment variables as `{name, value}` strings

  Standard error is captured with standard output. Output beyond
  #{@max_output_bytes} bytes is dropped.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    env =
      for {name, value} <- Keyword.get(opts, :env, []),
          do: {String.to_charlist(name), String.to_charlist(value)}

    trapping? = Process.flag(:trap_exit, true)

    try do
      case open(executable, args, env) do
        {:ok, port} -> await(port, deadline(timeout), [], 0)
        {:error, _reason} = error -> error
      end
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  defp open(executable, args, env) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        env: env
      ])

    {:ok, port}
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> {:error, :not_found}
        :eacces -> {:error, :permission_denied}
        other -> {:error, {:spawn_failed, other}}
      end

    error in ArgumentError ->
      {:error, {:spawn_failed, Exception.message(error)}}
  end

  defp await(port, deadline, chunks, size) do
    receive do
      {^port, {:data, data}} ->
        if size >= @max_output_bytes,
          do: await(port, deadline, chunks, size),
          else: await(port, deadline, [data | chunks], size + byte_size(data))

      {^port, {:exit_status, status}} ->
        forget(port)
        {:ok, %{status: status, output: chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

      {:EXIT, ^port, _reason} ->
        # The port closed without reporting a status (it should not happen
        # with :exit_status, but a closed port must never leave us waiting).
        {:error, {:spawn_failed, :port_closed}}

      {:EXIT, pid, reason} when is_pid(pid) ->
        # The owner of this job is shutting down: do not leave the program
        # running behind it.
        kill(port)
        exit(reason)
    after
      remaining(deadline) ->
        kill(port)
        {:error, :timeout}
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # SIGKILL, then wait for the exit status so the process is known to be gone
  # (the Erlang runtime reaps it). The pid is only used while the port is still
  # open, which is what guarantees it still names our child.
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

        receive do
          {^port, {:exit_status, _status}} -> :ok
        after
          @reap_ms -> :ok
        end

      nil ->
        :ok
    end

    close(port)
    forget(port)
  rescue
    _error -> :ok
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # While exits are trapped, a port that closes leaves an {:EXIT, port, _}
  # message. Once unlinked no such message can arrive any more, so one already
  # in the mailbox is the last: the caller gets its mailbox back as it was.
  defp forget(port) do
    Process.unlink(port)

    receive do
      {:EXIT, ^port, _reason} -> :ok
    after
      0 -> :ok
    end
  end
end
