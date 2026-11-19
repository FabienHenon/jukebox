defmodule Jukebox.AudioAnalysis.NativeSource do
  @moduledoc """
  Frames from the native analyser (`jukebox_audio_analyzer`).

  The analyser is started by ALSA, not by this application: it reads the PCM
  that Shairport Sync plays and sends one small JSON object per Unix datagram
  to the socket this process listens on. Nothing is acknowledged and nothing
  is queued on the other side: when this process is away the analyser drops
  its frames and carries on, and it finds the socket again by itself when
  this process comes back.

  This source therefore owns the socket file. It removes a stale one, binds,
  and makes it writable by the group, so the analyser, which runs as the
  Shairport Sync user, can reach it through a shared group (see
  `docs/audio-reactive-setup.md`). When the socket cannot be created (missing
  directory, permissions) it keeps retrying quietly: the display then simply
  uses its fixed-tempo animation.

  Incoming payloads are validated by `Jukebox.AudioAnalysis.Frame`; malformed
  ones are counted and dropped. Frames arriving faster than the publication
  rate are dropped too, and the socket is read one datagram at a time, so the
  mailbox cannot grow.
  """

  @behaviour Jukebox.AudioAnalysis.Source

  use GenServer

  require Logger

  alias Jukebox.AudioAnalysis
  alias Jukebox.AudioAnalysis.{Frame, RateLimiter}

  @default_socket "/run/jukebox/audio-analysis.sock"
  @default_stale_ms 500
  @default_retry_ms 5_000
  # Rejected payloads are reported at most this often, with a count.
  @reject_log_ms 30_000

  @impl Jukebox.AudioAnalysis.Source
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Options:

    * `:name` - registered name (default: this module)
    * `:socket` - path of the Unix datagram socket (default `#{@default_socket}`)
    * `:pubsub` - PubSub server to publish on
    * `:publish_rate` - most frames per second published (default: configured)
    * `:stale_ms` - silence after which the source counts as stale
      (default #{@default_stale_ms})
    * `:retry_ms` - pause before trying again to create the socket
      (default #{@default_retry_ms})
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  What the source is doing, for diagnostics:

    * `:socket` - the socket path
    * `:listening?` - whether the socket exists and is being read
    * `:stale?` - true when no valid frame arrived within `stale_ms`
    * `:last_frame_ms_ago` - age of the last valid frame, `nil` before the first
    * `:last_frame` - that frame (useful to read the confidence the analyser
      reports on a given piece of music)
    * `:received`, `:published`, `:rejected`, `:dropped` - counters
  """
  @spec status(GenServer.server()) :: map() | {:error, :not_running}
  def status(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc "True when no valid frame arrived recently (or the source is not running)."
  @spec stale?(GenServer.server()) :: boolean()
  def stale?(server \\ __MODULE__) do
    case status(server) do
      %{stale?: stale?} -> stale?
      {:error, :not_running} -> true
    end
  end

  # -- callbacks ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # So terminate/2 runs on shutdown and the socket file is removed.
    Process.flag(:trap_exit, true)

    rate = Keyword.get_lazy(opts, :publish_rate, fn -> AudioAnalysis.settings().publish_rate end)

    state = %{
      path: Keyword.get(opts, :socket, @default_socket),
      pubsub: Keyword.get(opts, :pubsub, Jukebox.PubSub),
      stale_ms: Keyword.get(opts, :stale_ms, @default_stale_ms),
      retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
      limiter: RateLimiter.new(rate),
      socket: nil,
      open_error: nil,
      last_frame_at: nil,
      last_frame: nil,
      received: 0,
      published: 0,
      rejected: 0,
      dropped: 0,
      rejects_reported_at: nil,
      rejects_unreported: 0
    }

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, state), do: {:noreply, open(state)}

  @impl GenServer
  def handle_call(:status, _from, state) do
    age = state.last_frame_at && now() - state.last_frame_at

    status = %{
      socket: state.path,
      listening?: state.socket != nil,
      stale?: age == nil or age > state.stale_ms,
      last_frame_ms_ago: age,
      last_frame: state.last_frame,
      received: state.received,
      published: state.published,
      rejected: state.rejected,
      dropped: state.dropped
    }

    {:reply, status, state}
  end

  @impl GenServer
  def handle_info({:udp, socket, _address, _port, payload}, %{socket: socket} = state) do
    state = receive_payload(state, payload)
    # One datagram at a time: whatever arrives faster than it is handled waits
    # in the (bounded) kernel buffer, not in this process's mailbox.
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:udp_closed, socket}, %{socket: socket} = state) do
    {:noreply, retry(%{state | socket: nil})}
  end

  def handle_info({:udp_error, socket, _reason}, %{socket: socket} = state) do
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info(:open, %{socket: nil} = state), do: {:noreply, open(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{socket: nil}), do: :ok

  def terminate(_reason, state) do
    :gen_udp.close(state.socket)
    remove_socket_file(state.path)
    :ok
  end

  # -- frames ------------------------------------------------------------------

  defp receive_payload(state, payload) do
    state = %{state | received: state.received + 1}

    case Frame.decode(payload) do
      {:ok, frame} -> publish(%{state | last_frame_at: now(), last_frame: frame}, frame)
      {:error, reason} -> reject(state, reason)
    end
  end

  defp publish(state, frame) do
    case RateLimiter.allow(state.limiter, now()) do
      {:ok, limiter} ->
        AudioAnalysis.publish(state.pubsub, frame)
        %{state | limiter: limiter, published: state.published + 1}

      :drop ->
        %{state | dropped: state.dropped + 1}
    end
  end

  defp reject(state, reason) do
    state = %{
      state
      | rejected: state.rejected + 1,
        rejects_unreported: state.rejects_unreported + 1
    }

    reported_at = state.rejects_reported_at

    if reported_at == nil or now() - reported_at >= @reject_log_ms do
      Logger.warning(
        "[audio] ignored #{state.rejects_unreported} malformed analyser message(s), " <>
          "last reason: #{inspect(reason)}"
      )

      %{state | rejects_reported_at: now(), rejects_unreported: 0}
    else
      state
    end
  end

  # -- socket ------------------------------------------------------------------

  defp open(state) do
    with :ok <- remove_socket_file(state.path),
         {:ok, socket} <- bind(state.path) do
      # The directory decides the group (it is setgid on the Pi); the group
      # needs write access to send datagrams here.
      _ = File.chmod(state.path, 0o660)
      Logger.info("[audio] listening for analysis frames on #{state.path}")
      %{state | socket: socket, open_error: nil}
    else
      {:error, reason} ->
        # Reported once per distinct reason, not on every retry.
        if reason != state.open_error do
          Logger.warning(
            "[audio] cannot listen on #{state.path} (#{inspect(reason)}); " <>
              "retrying every #{state.retry_ms} ms, the display keeps its fixed-tempo animation"
          )
        end

        retry(%{state | open_error: reason})
    end
  end

  defp retry(state) do
    Process.send_after(self(), :open, state.retry_ms)
    state
  end

  defp bind(path) do
    :gen_udp.open(0, [:binary, {:ifaddr, {:local, path}}, {:active, :once}, {:recbuf, 65_536}])
  end

  # A socket left behind by a previous run (a crash, a power cut) would make
  # the bind fail. Only a socket is ever removed: any other kind of file at
  # this path is a configuration mistake and is left alone.
  defp remove_socket_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :other}} -> File.rm(path)
      {:ok, %File.Stat{}} -> {:error, :not_a_socket}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
