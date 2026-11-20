defmodule Jukebox.Hardware.Power.StateFile do
  @moduledoc """
  Reads the state published by the power controller
  (`ops/hardware/jukebox-power-controller.py`), by default
  `/run/jukebox-power/state.json`.

  The controller is a separate root service that owns the power button and
  every power GPIO. This file is the only thing the application knows about
  it: which mode the jukebox is in and what the controller last commanded on
  each output. It is read, never written, and never trusted blindly:

    * the file and its directory must belong to the expected owner (root) and
      must not be writable by anyone else, so another process cannot make the
      application believe the jukebox is awake;
    * the document must be the schema this module knows;
    * it must be fresh. The controller rewrites the file at least once per
      second with `boottime`, the kernel's seconds-since-boot clock at that
      moment. That clock is shared by every process and, unlike the time of
      day, is not moved by NTP. The reader compares it with `/proc/uptime`;
      a file older than three seconds means the controller stopped, and is
      reported as `:stale`.

  Every failure is an `{:error, reason}`; the caller treats all of them as
  "power state unknown", which blocks the buttons.
  """

  import Bitwise

  @schema 1
  @max_age_ms 3_000
  @max_bytes 8_192
  @modes %{
    "booting" => :booting,
    "awake" => :awake,
    "standby" => :standby,
    "shutting_down" => :shutting_down
  }
  @outputs %{
    "amp" => :amp,
    "disco" => :disco,
    "strip" => :strip,
    "decor" => :decor,
    "extra" => :extra
  }

  @type output :: %{requested: boolean(), applied: boolean(), gpio: integer() | nil}

  @type state :: %{
          instance: String.t(),
          revision: non_neg_integer(),
          heartbeat: non_neg_integer(),
          pid: integer() | nil,
          mode: :booting | :awake | :standby | :shutting_down,
          outputs: %{optional(atom()) => output()},
          age_ms: non_neg_integer()
        }

  @type reason ::
          :missing
          | :not_a_regular_file
          | :unsafe_ownership
          | :unsafe_permissions
          | :too_large
          | :malformed
          | :unsupported_schema
          | :stale
          | :clock_unavailable
          | {:unreadable, File.posix()}

  @doc "Age after which a state file no longer counts as live."
  def max_age_ms, do: @max_age_ms

  @doc """
  Options:

    * `:owner_uid` - user the file and its directory must belong to (default 0)
    * `:uptime` - zero-arity function returning `{:ok, seconds_since_boot}`
      (default: `/proc/uptime`)
    * `:max_age_ms` - default #{@max_age_ms}
  """
  @spec read(Path.t(), keyword()) :: {:ok, state()} | {:error, reason()}
  def read(path, opts \\ []) do
    owner = Keyword.get(opts, :owner_uid, 0)
    uptime = Keyword.get(opts, :uptime, &proc_uptime/0)
    max_age = Keyword.get(opts, :max_age_ms, @max_age_ms)

    with :ok <- safe?(Path.dirname(path), :directory, owner),
         :ok <- safe?(path, :regular, owner),
         {:ok, content} <- read_bounded(path),
         {:ok, document} <- decode(content),
         {:ok, state, boottime} <- validate(document),
         {:ok, age_ms} <- age(boottime, uptime, max_age) do
      {:ok, Map.put(state, :age_ms, age_ms)}
    end
  end

  @doc "Seconds since boot, from `/proc/uptime` (Linux only)."
  @spec proc_uptime() :: {:ok, float()} | :error
  def proc_uptime do
    with {:ok, content} <- File.read("/proc/uptime"),
         [first | _rest] <- String.split(content),
         {seconds, ""} <- Float.parse(first) do
      {:ok, seconds}
    else
      _other -> :error
    end
  end

  # -- checks ------------------------------------------------------------------

  # lstat, not stat: a symbolic link is refused rather than followed.
  defp safe?(path, type, owner) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^type, uid: ^owner, mode: mode}} ->
        if (mode &&& 0o022) == 0, do: :ok, else: {:error, :unsafe_permissions}

      {:ok, %File.Stat{type: ^type}} ->
        {:error, :unsafe_ownership}

      {:ok, %File.Stat{}} ->
        {:error, :not_a_regular_file}

      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, {:unreadable, reason}}
    end
  end

  defp read_bounded(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) <= @max_bytes -> {:ok, content}
      {:ok, _content} -> {:error, :too_large}
      # Replaced between the checks and the read: the next poll sees the new one.
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp decode(content) do
    case Jason.decode(content) do
      {:ok, %{} = document} -> {:ok, document}
      _other -> {:error, :malformed}
    end
  end

  defp validate(%{"schema" => @schema} = document) do
    with %{
           "instance" => instance,
           "revision" => revision,
           "heartbeat" => heartbeat,
           "boottime" => boottime,
           "mode" => mode,
           "outputs" => %{} = outputs
         } <- document,
         true <- is_binary(instance) and instance != "" and byte_size(instance) <= 64,
         true <- is_integer(revision) and revision >= 0,
         true <- is_integer(heartbeat) and heartbeat >= 0,
         true <- is_number(boottime) and boottime >= 0,
         {:ok, mode} <- Map.fetch(@modes, mode),
         {:ok, outputs} <- outputs(outputs) do
      pid = document["pid"]

      {:ok,
       %{
         instance: instance,
         revision: revision,
         heartbeat: heartbeat,
         pid: if(is_integer(pid), do: pid),
         mode: mode,
         outputs: outputs
       }, boottime}
    else
      _invalid -> {:error, :malformed}
    end
  end

  defp validate(%{"schema" => _other}), do: {:error, :unsupported_schema}
  defp validate(_document), do: {:error, :malformed}

  defp outputs(outputs) do
    Enum.reduce_while(outputs, {:ok, %{}}, fn
      {name, %{"requested" => requested, "applied" => applied} = output}, {:ok, acc}
      when is_map_key(@outputs, name) and is_boolean(requested) and is_boolean(applied) ->
        gpio = output["gpio"]

        entry = %{requested: requested, applied: applied, gpio: if(is_integer(gpio), do: gpio)}
        {:cont, {:ok, Map.put(acc, Map.fetch!(@outputs, name), entry)}}

      {name, _output}, acc when not is_map_key(@outputs, name) ->
        # An output this version does not know: ignored, not an error.
        {:cont, acc}

      _invalid, _acc ->
        {:halt, {:error, :malformed}}
    end)
  end

  defp age(boottime, uptime, max_age) do
    case uptime.() do
      {:ok, now} ->
        age_ms = round((now - boottime) * 1000)

        # A file "from the future" cannot be a live heartbeat either.
        if age_ms >= -1_000 and age_ms <= max_age,
          do: {:ok, max(age_ms, 0)},
          else: {:error, :stale}

      _unavailable ->
        {:error, :clock_unavailable}
    end
  end
end
