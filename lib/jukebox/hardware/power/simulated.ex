defmodule Jukebox.Hardware.Power.Simulated do
  @moduledoc """
  A stand-in for the power controller, for development and tests: no GPIO, no
  root service, no state file.

  It keeps the same state the real controller publishes (mode, requested and
  applied outputs, instance and revision), starts with the same requests
  (amplifier, strip, decor and extra on, disco off) and takes commands the
  same way (a light command during standby is kept and applied on resume), so
  `Jukebox.Hardware.Power.Monitor` and the lights behave as they do on the
  Raspberry Pi. `set_mode/2` plays the part of the power button and
  `set_available/2` makes the controller disappear.
  """

  use GenServer

  # The starting requests of the real controller (its DEFAULT_REQUESTS).
  @default_requests %{amp: true, disco: false, strip: true, decor: true, extra: true}
  @lights %{"disco" => :disco, "strip" => :strip, "decor" => :decor, "extra" => :extra}
  @modes [:booting, :awake, :standby, :shutting_down]

  @doc """
  Options: `:name`, `:mode` (default `:awake`) and `:requested`, a map of
  output requests replacing the starting ones (for example `%{strip: false}`).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "What `Jukebox.Hardware.Power.StateFile.read/2` would return."
  def read(server \\ __MODULE__), do: GenServer.call(server, :read)

  @doc "Runs a client command such as `[\"disco\", \"toggle\"]`."
  def command(server \\ __MODULE__, args), do: GenServer.call(server, {:command, args})

  @doc "Changes the mode, as the power button would."
  def set_mode(server \\ __MODULE__, mode) when mode in @modes,
    do: GenServer.call(server, {:set_mode, mode})

  @doc "Makes the controller unreachable (`false`) or reachable again."
  def set_available(server \\ __MODULE__, available?) when is_boolean(available?),
    do: GenServer.call(server, {:set_available, available?})

  @doc "Commands received, most recent first."
  def commands(server \\ __MODULE__), do: GenServer.call(server, :commands)

  # -- callbacks ---------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       instance: "simulated-#{System.unique_integer([:positive])}",
       revision: 1,
       heartbeat: 0,
       mode: Keyword.get(opts, :mode, :awake),
       available?: true,
       requested: Map.merge(@default_requests, Map.new(Keyword.get(opts, :requested, %{}))),
       commands: []
     }}
  end

  @impl true
  def handle_call(:read, _from, %{available?: false} = state),
    do: {:reply, {:error, :missing}, state}

  def handle_call(:read, _from, state) do
    state = %{state | heartbeat: state.heartbeat + 1}
    {:reply, {:ok, published(state)}, state}
  end

  def handle_call({:command, args}, _from, state) do
    state = %{state | commands: Enum.take([args | state.commands], 20)}

    case {state.available?, state.mode, args} do
      {false, _mode, _args} ->
        {:reply, {:error, :unreachable}, state}

      {true, :shutting_down, [light, _verb]} when is_map_key(@lights, light) ->
        {:reply, {:error, {:rejected, "shutting_down"}}, state}

      # In any other mode, standby included: the request changes now and is
      # applied when the jukebox is awake.
      {true, _mode, [light, verb]}
      when is_map_key(@lights, light) and verb in ["toggle", "on", "off"] ->
        name = Map.fetch!(@lights, light)

        value =
          case verb do
            "toggle" -> not state.requested[name]
            "on" -> true
            "off" -> false
          end

        state = %{
          state
          | requested: Map.put(state.requested, name, value),
            revision: state.revision + 1
        }

        {:reply, {:ok, %{acked?: true, instance: state.instance, revision: state.revision}},
         state}

      _other ->
        {:reply, {:error, {:rejected, "unknown_command"}}, state}
    end
  end

  def handle_call({:set_mode, mode}, _from, state) do
    {:reply, :ok, %{state | mode: mode, revision: state.revision + 1}}
  end

  def handle_call({:set_available, available?}, _from, state),
    do: {:reply, :ok, %{state | available?: available?}}

  def handle_call(:commands, _from, state), do: {:reply, state.commands, state}

  defp published(state) do
    awake? = state.mode == :awake

    %{
      instance: state.instance,
      revision: state.revision,
      heartbeat: state.heartbeat,
      pid: nil,
      mode: state.mode,
      age_ms: 0,
      outputs:
        Map.new(state.requested, fn {name, requested} ->
          {name, %{requested: requested, applied: requested and awake?, gpio: nil}}
        end)
    }
  end
end
