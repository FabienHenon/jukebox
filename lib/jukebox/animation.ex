defmodule Jukebox.Animation do
  @moduledoc """
  Owner of the kiosk's animation style, the one thing the physical "animation"
  button changes.

  Styles, in the order the button cycles through them:

    * `:calm`  - the player without the scrolling waves
    * `:waves` - the player with the scrolling waves
    * `:chase` - waves, plus the pillar blocks and marquee bulbs passing their
      colours along on every beat and a wave travelling through the base grilles
      (the default)
    * `:party` - like `:chase`, but colours and wave directions are random

  The style is display state, not playback state: it survives sessions and
  track changes, and it is broadcast on PubSub (`{:animation_style, style}`) so
  every connected kiosk follows the button.

  The last chosen style is also written to a small file (`state_file` in the
  configuration) and read back at boot, so the jukebox comes back the way it
  was switched off. The file is a convenience, never a requirement: without a
  configured path nothing is saved, and an unreadable or unwritable file only
  logs a warning and leaves the configured default in charge.

  The beat is a fixed tempo (`bpm` in the configuration): the lights keep a
  steady pace while music plays. When audio analysis is enabled and sure of
  the beat (`Jukebox.AudioAnalysis`), the browser steps the lights on the
  detected beats instead and comes back to this tempo whenever it is not.
  """

  use GenServer

  require Logger

  @topic "animation"
  @styles [:calm, :waves, :chase, :party]
  @default_style :chase
  @default_bpm 120

  @type style :: :calm | :waves | :chase | :party

  @doc "Every style, in cycling order."
  @spec styles() :: [style()]
  def styles, do: @styles

  def topic, do: @topic

  @doc "Subscribes the caller to `{:animation_style, style}` messages."
  def subscribe(pubsub \\ Jukebox.PubSub), do: Phoenix.PubSub.subscribe(pubsub, @topic)

  @doc "The style used until one has been chosen (`default_style` in the configuration)."
  @spec default_style() :: style()
  def default_style do
    case Keyword.get(config(), :default_style, @default_style) do
      style when style in @styles -> style
      _other -> @default_style
    end
  end

  @doc "Length of one beat in milliseconds, from the configured `bpm`."
  @spec beat_ms() :: pos_integer()
  def beat_ms do
    case Keyword.get(config(), :bpm, @default_bpm) do
      bpm when is_number(bpm) and bpm > 0 -> round(60_000 / bpm)
      _other -> round(60_000 / @default_bpm)
    end
  end

  @doc "The style that follows `style` when the button is pressed."
  @spec next(style()) :: style()
  def next(style) when style in @styles do
    index = Enum.find_index(@styles, &(&1 == style))
    Enum.at(@styles, rem(index + 1, length(@styles)))
  end

  @doc "Converts a string (configuration, simulator) into a style."
  @spec parse(term()) :: {:ok, style()} | :error
  def parse(string) when is_binary(string) do
    Enum.find_value(@styles, :error, fn style ->
      if Atom.to_string(style) == string, do: {:ok, style}
    end)
  end

  def parse(_other), do: :error

  @doc """
  Options:

    * `:name` - registered name (default: this module)
    * `:style` - starting style; overrides both the saved and the default one
    * `:state_file` - where the chosen style is kept (default: configured;
      `nil` keeps it in memory only)
    * `:pubsub` - PubSub server to broadcast on
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The current style. Falls back to the default when the server is not running:
  a decorative setting must never keep the display from rendering.
  """
  @spec get(GenServer.server()) :: style()
  def get(server \\ __MODULE__) do
    GenServer.call(server, :get)
  catch
    :exit, _reason -> default_style()
  end

  @doc "Moves to the next style and returns it."
  @spec cycle(GenServer.server()) :: style()
  def cycle(server \\ __MODULE__), do: GenServer.call(server, :cycle)

  @doc "Selects a style directly."
  @spec set(GenServer.server(), style()) :: :ok
  def set(server \\ __MODULE__, style) when style in @styles do
    GenServer.call(server, {:set, style})
  end

  # -- server --------------------------------------------------------------------

  @impl true
  def init(opts) do
    state_file = Keyword.get_lazy(opts, :state_file, fn -> Keyword.get(config(), :state_file) end)

    {:ok,
     %{
       style:
         Keyword.get_lazy(opts, :style, fn -> saved_style(state_file) || default_style() end),
       state_file: state_file,
       pubsub: Keyword.get(opts, :pubsub, Jukebox.PubSub)
     }}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.style, state}

  def handle_call(:cycle, _from, state) do
    state = change(state, next(state.style))
    {:reply, state.style, state}
  end

  def handle_call({:set, style}, _from, state), do: {:reply, :ok, change(state, style)}

  defp change(%{style: style} = state, style), do: state

  defp change(state, style) do
    save_style(state.state_file, style)
    Phoenix.PubSub.broadcast(state.pubsub, @topic, {:animation_style, style})
    %{state | style: style}
  end

  # -- saved choice ----------------------------------------------------------------

  defp saved_style(nil), do: nil

  defp saved_style(path) do
    with {:ok, content} <- File.read(path),
         {:ok, style} <- parse(String.trim(content)) do
      style
    else
      {:error, :enoent} ->
        nil

      {:error, reason} ->
        Logger.warning("[animation] cannot read #{path}: #{inspect(reason)}")
        nil

      :error ->
        Logger.warning("[animation] ignoring unknown style saved in #{path}")
        nil
    end
  end

  defp save_style(nil, _style), do: :ok

  # Written beside the target and renamed over it, so a power cut (the usual
  # way a jukebox is switched off) leaves either the old choice or the new one.
  defp save_style(path, style) do
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, Atom.to_string(style) <> "\n", [:sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[animation] cannot save the style to #{path}: #{inspect(reason)}")
    end
  end

  defp config, do: Application.get_env(:jukebox, __MODULE__, [])
end
