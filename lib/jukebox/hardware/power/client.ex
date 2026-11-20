defmodule Jukebox.Hardware.Power.Client do
  @moduledoc """
  Sends light commands to the power controller through its command-line
  client (`JUKEBOX_POWER_CLIENT`, by default
  `/usr/local/sbin/jukebox-power-controller.py`).

  The application runs as an ordinary user and never touches a GPIO: it asks
  the root controller, with one of a handful of fixed argument lists. Nothing
  coming from a browser or from the environment ends up in those arguments,
  and the standby and shutdown commands are deliberately not in the list:
  they belong to the physical power button.

  What the result means:

    * `{:ok, %{acked?: true, instance: _, revision: _}}` - the controller
      answered that it carried the command out; its state file shows the
      result from that revision on.
    * `{:ok, %{acked?: false}}` - the client exited successfully without an
      acknowledgement (an older controller). The command was sent; whether it
      was applied is only known from the state file.
    * `{:error, :no_ack | :timeout}` - *uncertain*: the command may or may
      not have been applied. A toggle is never sent again after this.
    * any other error - the command was not applied.
  """

  alias Jukebox.Hardware.Exec

  @allowed [["disco", "toggle"], ["strip", "toggle"], ["strip", "on"]]
  @default_timeout_ms 2_500

  @type ack :: %{acked?: boolean(), instance: String.t() | nil, revision: integer() | nil}
  @type error ::
          :not_allowed
          | :client_missing
          | :permission_denied
          | :unreachable
          | :no_ack
          | :timeout
          | {:rejected, String.t()}
          | {:failed, term()}

  @doc "The argument lists the application may send."
  def allowed, do: @allowed

  @doc "True when a failure leaves it unknown whether the command was applied."
  @spec uncertain?(term()) :: boolean()
  def uncertain?(reason), do: reason in [:no_ack, :timeout]

  @doc """
  Runs the client with `args`. Options: `:executable` (required) and
  `:timeout_ms` (default #{@default_timeout_ms}).
  """
  @spec command([String.t()], keyword()) :: {:ok, ack()} | {:error, error()}
  def command(args, opts) do
    executable = Keyword.fetch!(opts, :executable)

    cond do
      args not in @allowed ->
        {:error, :not_allowed}

      not File.regular?(executable) ->
        {:error, :client_missing}

      true ->
        executable
        |> Exec.run(args, timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms))
        |> result()
    end
  end

  # Exit statuses of the client (see its --help): 0 done, 2 refused by the
  # controller, 3 no acknowledgement in time, 4 controller not reachable.
  defp result({:ok, %{status: 0, output: output}}), do: {:ok, ack(output)}
  defp result({:ok, %{status: 2, output: output}}), do: {:error, {:rejected, rejection(output)}}
  defp result({:ok, %{status: 3}}), do: {:error, :no_ack}
  defp result({:ok, %{status: 4}}), do: {:error, :unreachable}
  defp result({:ok, %{status: status}}), do: {:error, {:failed, {:exit_status, status}}}
  defp result({:error, :timeout}), do: {:error, :timeout}
  defp result({:error, :not_found}), do: {:error, :client_missing}
  defp result({:error, :permission_denied}), do: {:error, :permission_denied}
  defp result({:error, reason}), do: {:error, {:failed, reason}}

  defp ack(output) do
    case reply(output) do
      %{"ok" => true, "instance" => instance, "revision" => revision}
      when is_binary(instance) and is_integer(revision) ->
        %{acked?: true, instance: instance, revision: revision}

      _other ->
        %{acked?: false, instance: nil, revision: nil}
    end
  end

  defp rejection(output) do
    case reply(output) do
      %{"error" => error} when is_binary(error) -> String.slice(error, 0, 80)
      _other -> "rejected"
    end
  end

  # The client prints the controller's reply as one JSON line.
  defp reply(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = reply} -> reply
        _other -> nil
      end
    end)
  end
end
