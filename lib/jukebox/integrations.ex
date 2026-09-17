defmodule Jukebox.Integrations do
  @moduledoc """
  Supervisor for the external-integration adapters: remote control (when it
  needs a process), metadata source and physical input.

  It is started *after* the Phoenix endpoint so a slow or failing integration
  never delays the kiosk screen, and it has generous restart limits so a
  misbehaving adapter cannot escalate into taking the whole application (and
  the display) down. The playback state lives outside this supervisor, so an
  adapter restart never discards the last known track.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one, max_restarts: 20, max_seconds: 60)
  end

  @doc "Child specs built from the configured adapters."
  def children do
    [remote_control_child(), metadata_source_child(), input_child()]
    |> Enum.reject(&is_nil/1)
  end

  defp metadata_source_child do
    {module, opts} = Application.fetch_env!(:jukebox, :metadata_source)
    module.child_spec(opts)
  end

  defp input_child do
    {module, opts} = Application.fetch_env!(:jukebox, :input)
    module.child_spec(opts)
  end

  defp remote_control_child do
    {module, opts} = Application.fetch_env!(:jukebox, :remote_control)

    if Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1),
      do: module.child_spec(opts),
      else: nil
  end
end
