defmodule Jukebox.Test.FakeXrandr do
  @moduledoc """
  A scriptable display for the brightness worker's tests.

  It records every call, can be "down" with a given error for as long as the
  test wants (an X server that has not started), can fail the next calls of a
  kind, can ignore changes (a display that keeps its own value), can quantise
  what it reports, and can hold a call until the test releases it, which is
  how overlapping presses are tested without sleeping.
  """

  @behaviour Jukebox.Hardware.Brightness.Backend

  use Agent

  def start_link(opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    Agent.start_link(fn ->
      %{
        current: Keyword.get(opts, :current, 1000),
        owner: owner,
        calls: [],
        down: Keyword.get(opts, :down),
        failures: %{query: [], set: []},
        hold: MapSet.new(),
        ignore_sets?: false,
        offset: 0
      }
    end)
  end

  @doc "Calls made so far, oldest first: `:query`, `{:set, coefficient}`."
  def calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))

  def sets(agent), do: for({:set, coefficient} <- calls(agent), do: coefficient)
  def queries(agent), do: Enum.count(calls(agent), &(&1 == :query))

  @doc "The next calls of `kind` fail with these errors, one each."
  def fail(agent, kind, errors),
    do: Agent.update(agent, &put_in(&1.failures[kind], List.wrap(errors)))

  @doc "Calls of `kind` wait for `release/1`; the owner receives `{:held, kind, pid}`."
  def hold(agent, kind), do: Agent.update(agent, &%{&1 | hold: MapSet.put(&1.hold, kind)})
  def unhold(agent, kind), do: Agent.update(agent, &%{&1 | hold: MapSet.delete(&1.hold, kind)})
  def release(pid), do: send(pid, :release)

  @doc "Changes fields: `current:`, `down:` (an error, or nil), `ignore_sets?:`, `offset:`."
  def set_state(agent, changes), do: Agent.update(agent, &Map.merge(&1, Map.new(changes)))

  def current(agent), do: Agent.get(agent, & &1.current)

  @impl true
  def query(opts) do
    with :ok <- call(opts, :query, :query) do
      {:ok, Agent.get(opts[:agent], &(&1.current + &1.offset))}
    end
  end

  @impl true
  def set(coefficient, opts) do
    with :ok <- call(opts, :set, {:set, coefficient}) do
      Agent.update(opts[:agent], fn state ->
        if state.ignore_sets?, do: state, else: %{state | current: coefficient}
      end)
    end
  end

  defp call(opts, kind, entry) do
    {failure, hold?, owner} =
      Agent.get_and_update(opts[:agent], fn state ->
        {failure, rest} =
          case {state.down, state.failures[kind]} do
            {nil, [failure | rest]} -> {failure, rest}
            {nil, []} -> {nil, []}
            {down, pending} -> {down, pending}
          end

        state = put_in(%{state | calls: [entry | state.calls]}.failures[kind], rest)
        {{failure, MapSet.member?(state.hold, kind), state.owner}, state}
      end)

    if hold? do
      send(owner, {:held, kind, self()})

      receive do
        :release -> :ok
      end
    end

    if failure, do: {:error, failure}, else: :ok
  end
end
