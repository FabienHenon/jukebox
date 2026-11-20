if Application.compile_env(:jukebox, :simulator, false) do
  defmodule JukeboxWeb.SimulatorLive do
    @moduledoc """
    Development simulator (`/dev/simulator`).

    Drives the demo metadata source and the fake physical input so the whole
    kiosk experience can be exercised on a laptop: sessions, tracks, playback
    status, metadata edits, artwork, progress, delayed/partial metadata,
    metadata disconnection, remote-control availability, button presses
    (transport and animation style), the simulated audio analyser and the
    physical controls (raw key events through the real dispatcher, with a
    pretend power controller and a pretend X11 display, plus the same status
    as `Jukebox.Hardware.status/0`).
    A scaled live preview of the kiosk is embedded for the three target
    resolutions.

    This module is only compiled when `config :jukebox, simulator: true`
    (dev and test) and only routed when `dev_routes` is set (dev).
    """

    use JukeboxWeb, :live_view

    alias Jukebox.{Animation, AudioAnalysis, Commands, Hardware, Playback}
    alias Jukebox.AudioAnalysis.SimulatedSource
    alias Jukebox.Demo.Catalog
    alias Jukebox.Inputs.Fake
    alias Jukebox.MetadataSources.Demo
    alias Jukebox.RemoteControls

    # Lower-case key names: the "Physical buttons" card above keeps the
    # semantic buttons, these are the raw keys of the pretend encoder.
    @hardware_buttons [
      previous: "previous",
      play_pause: "play / pause",
      next: "next",
      disco_toggle: "disco",
      strip_toggle: "strip",
      animation_next: "animation",
      brightness_down: "brightness −",
      brightness_up: "brightness +"
    ]

    @previews %{"1920x1080" => {1920, 1080}, "1280x720" => {1280, 720}, "1024x600" => {1024, 600}}
    @preview_width 880
    @audio_profiles [
      steady: "Clear beat",
      free_tempo: "Free tempo",
      silent: "Silence",
      down: "Analyser down"
    ]
    @audio_tempos [84, 100, 112, 128, 150]

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket) do
        Playback.Server.subscribe()
        Commands.subscribe()
        Animation.subscribe()
        Hardware.Events.subscribe()
        Hardware.Power.Monitor.subscribe()
      end

      {:ok,
       socket
       |> assign(page_title: "Simulator", commands: [], preview: "1280x720")
       |> assign(animation: Animation.get())
       |> assign(audio_profiles: @audio_profiles, audio_tempos: @audio_tempos)
       |> assign(hardware_buttons: @hardware_buttons)
       |> assign_hardware()
       |> assign_audio()
       |> assign_state(Playback.Server.get_state())
       |> assign_forms()}
    end

    @impl true
    def handle_info({:playback_state, state}, socket), do: {:noreply, assign_state(socket, state)}

    def handle_info({:animation_style, style}, socket) do
      {:noreply, assign(socket, animation: style)}
    end

    def handle_info({:command_feedback, feedback}, socket) do
      {:noreply,
       socket
       |> assign(commands: Enum.take([feedback | socket.assigns.commands], 8))
       |> assign_hardware()}
    end

    def handle_info({:hardware_changed, _subsystem}, socket),
      do: {:noreply, assign_hardware(socket)}

    def handle_info({:power_state, _snapshot}, socket), do: {:noreply, assign_hardware(socket)}

    def handle_info(_message, socket), do: {:noreply, socket}

    @impl true
    def handle_event("session", %{"action" => action}, socket) do
      case action do
        "start" -> Demo.start_session()
        "start_delayed" -> Demo.start_session(delay_ms: 2_500)
        "start_partial" -> Demo.start_session(partial: [:title])
        "start_no_artwork" -> Demo.start_session(artwork: false)
        "end" -> Demo.end_session()
        _ -> :ignored
      end

      {:noreply, socket}
    end

    def handle_event("select_track", %{"index" => index}, socket) do
      Demo.select_track(String.to_integer(index))
      {:noreply, refresh_forms(socket)}
    end

    def handle_event("preset", %{"key" => key}, socket) do
      if key in Catalog.preset_keys(), do: Demo.load_preset(String.to_existing_atom(key))
      {:noreply, refresh_forms(socket)}
    end

    def handle_event("playback", %{"status" => status}, socket) do
      case status do
        "playing" -> Demo.play()
        "paused" -> Demo.pause()
        "stopped" -> Demo.stop()
        _ -> :ignored
      end

      {:noreply, socket}
    end

    def handle_event("save_track", %{"track" => params}, socket) do
      attrs =
        for field <- [:title, :artist, :album], into: %{} do
          {field, blank_to_nil(params[Atom.to_string(field)])}
        end

      Demo.update_track(attrs)
      {:noreply, socket}
    end

    def handle_event("artwork", %{"n" => "none"}, socket) do
      Demo.set_artwork(nil)
      {:noreply, socket}
    end

    def handle_event("artwork", %{"n" => n}, socket) do
      Demo.set_artwork(String.to_integer(n))
      {:noreply, socket}
    end

    def handle_event("save_progress", %{"progress" => params}, socket) do
      position = seconds_to_ms(params["position"])
      duration = seconds_to_ms(params["duration"])
      Demo.set_progress(position || 0, duration)
      {:noreply, socket}
    end

    def handle_event("connection", %{"status" => status}, socket) do
      if status in ["connected", "disconnected"],
        do: Demo.set_metadata_connection(String.to_existing_atom(status))

      {:noreply, socket}
    end

    def handle_event("remote", %{"value" => value}, socket) do
      if value in ["available", "unavailable"],
        do: Demo.set_remote_control(String.to_existing_atom(value))

      {:noreply, socket}
    end

    def handle_event("press", %{"command" => command}, socket) do
      case Commands.parse(command) do
        {:ok, command} -> Fake.press(command)
        :error -> :ignored
      end

      {:noreply, socket}
    end

    # A raw key event on the pretend input device: from here on everything is
    # the production path (mapping, debounce, power gate, queues, commands).
    def handle_event("hardware_tap", %{"action" => action}, socket) do
      with %{buttons: %{source: :simulated, mapping: mapping}} <- socket.assigns.hardware,
           {_action, code} when is_integer(code) <-
             Enum.find(mapping, fn {name, _code} -> Atom.to_string(name) == action end) do
        Jukebox.Inputs.Simulated.tap(code)
      end

      {:noreply, socket}
    end

    def handle_event("hardware_power", %{"mode" => mode}, socket) do
      if socket.assigns.hardware_simulated_power? do
        case mode do
          "awake" -> simulate_power(:awake)
          "standby" -> simulate_power(:standby)
          "shutting_down" -> simulate_power(:shutting_down)
          "down" -> Hardware.Power.Simulated.set_available(false)
          _other -> :ignored
        end
      end

      {:noreply, assign_hardware(socket)}
    end

    # The pretend X server: gone, back, or restarted with its brightness reset.
    def handle_event("hardware_display", %{"state" => state}, socket) do
      if simulated_display?(socket.assigns.hardware) do
        case state do
          "up" -> Hardware.Brightness.Simulated.set_available(true)
          "down" -> Hardware.Brightness.Simulated.set_available(false)
          "restarted" -> Hardware.Brightness.Simulated.reset()
          _other -> :ignored
        end
      end

      {:noreply, assign_hardware(socket)}
    end

    def handle_event("audio_profile", %{"profile" => profile}, socket) do
      case Enum.find(SimulatedSource.profiles(), &(Atom.to_string(&1) == profile)) do
        nil -> :ignored
        profile -> SimulatedSource.set_profile(profile)
      end

      {:noreply, assign_audio(socket)}
    end

    def handle_event("audio_bpm", %{"bpm" => bpm}, socket) do
      case Integer.parse(bpm) do
        {bpm, ""} when bpm in @audio_tempos -> SimulatedSource.set_bpm(bpm)
        _other -> :ignored
      end

      {:noreply, assign_audio(socket)}
    end

    def handle_event("preview", %{"size" => size}, socket) when is_map_key(@previews, size) do
      {:noreply, assign(socket, preview: size)}
    end

    def handle_event("reset", _params, socket) do
      if socket.assigns.hardware_simulated_power?, do: simulate_power(:awake)

      if simulated_display?(socket.assigns.hardware),
        do: Hardware.Brightness.Simulated.set_available(true)

      Demo.reset()
      Playback.Server.reset()
      RemoteControls.Demo.clear()
      Animation.set(Animation.default_style())
      SimulatedSource.reset()
      {:noreply, socket |> assign(commands: []) |> assign_audio() |> assign_hardware()}
    end

    def handle_event(_event, _params, socket), do: {:noreply, socket}

    # -- internals -------------------------------------------------------------

    defp simulate_power(mode) do
      Hardware.Power.Simulated.set_available(true)
      Hardware.Power.Simulated.set_mode(mode)
    end

    # What Jukebox.Hardware.status/0 reports, read again on every change.
    defp assign_hardware(socket) do
      status = Hardware.status()

      assign(socket,
        hardware: status,
        hardware_simulated_power?: status.config.power.source == :simulated
      )
    end

    defp connection_state(state) when is_atom(state), do: Atom.to_string(state)
    defp connection_state({state, detail}), do: "#{state} (#{inspect(detail)})"

    defp light_state(%{confirmed: true}), do: "on"
    defp light_state(%{confirmed: false}), do: "off"
    defp light_state(_unknown), do: "unknown"

    defp simulated_display?(%{brightness: %{backend: :simulated, status: :enabled}}), do: true
    defp simulated_display?(_hardware), do: false

    # The software coefficient the display confirmed, or why there is none.
    defp brightness_state(%{applied_coefficient: applied}) when is_float(applied),
      do: "#{applied} applied"

    defp brightness_state(%{availability: availability}), do: to_string(availability)
    defp brightness_state(_not_running), do: "not running"

    # The simulated analyser's settings, or nil when another source (or none)
    # is in use.
    defp assign_audio(socket) do
      simulated =
        case SimulatedSource.snapshot() do
          %{} = snapshot -> snapshot
          {:error, :not_running} -> nil
        end

      assign(socket, audio_source: AudioAnalysis.source_kind(), audio_simulated: simulated)
    end

    defp assign_state(socket, state) do
      demo =
        case Demo.snapshot() do
          {:error, :not_running} -> nil
          snapshot -> snapshot
        end

      assign(socket, state: state, demo: demo)
    end

    defp assign_forms(socket) do
      demo = socket.assigns.demo
      track = (demo && demo.track) || %{}

      assign(socket,
        track_form:
          to_form(%{
            "title" => track[:title] || "",
            "artist" => track[:artist] || "",
            "album" => track[:album] || ""
          }),
        progress_form:
          to_form(%{
            "position" => to_seconds((demo && demo.position_ms) || 0),
            "duration" => to_seconds(track[:duration_ms])
          })
      )
    end

    defp refresh_forms(socket) do
      socket |> assign_state(socket.assigns.state) |> assign_forms()
    end

    defp blank_to_nil(nil), do: nil

    defp blank_to_nil(value) do
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
    end

    defp seconds_to_ms(nil), do: nil

    defp seconds_to_ms(value) do
      case Float.parse(String.trim(value)) do
        {seconds, _} -> round(seconds * 1000)
        :error -> nil
      end
    end

    defp to_seconds(nil), do: ""
    defp to_seconds(ms), do: Integer.to_string(div(ms, 1000))

    defp preview_style(size) do
      {width, height} = Map.fetch!(@previews, size)
      scale = min(1.0, @preview_width / width)
      {width, height, scale}
    end

    defp inspect_value(nil), do: "—"
    defp inspect_value(%Jukebox.Playback.Artwork{id: id}), do: id
    defp inspect_value(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
    defp inspect_value(value) when is_binary(value), do: value
    defp inspect_value(value), do: inspect(value)

    # -- template --------------------------------------------------------------

    @impl true
    def render(assigns) do
      {width, height, scale} = preview_style(assigns.preview)
      assigns = assign(assigns, preview_w: width, preview_h: height, preview_scale: scale)

      ~H"""
      <Layouts.app flash={@flash}>
        <div class="sim">
          <div class="sim__controls">
            <section class="sim-card">
              <h2 class="sim-card__title">Session</h2>
              <div class="sim-row">
                <button class="sim-btn sim-btn--primary" phx-click="session" phx-value-action="start">
                  Start session
                </button>
                <button class="sim-btn" phx-click="session" phx-value-action="start_delayed">
                  Start, metadata after 2.5 s
                </button>
                <button class="sim-btn" phx-click="session" phx-value-action="start_partial">
                  Start with title only
                </button>
                <button class="sim-btn" phx-click="session" phx-value-action="start_no_artwork">
                  Start without artwork
                </button>
                <button class="sim-btn sim-btn--danger" phx-click="session" phx-value-action="end">
                  End session
                </button>
              </div>
            </section>

            <section class="sim-card">
              <h2 class="sim-card__title">Track</h2>
              <div class="sim-row">
                <button
                  :for={{track, index} <- Enum.with_index(Catalog.tracks())}
                  class={["sim-btn", @demo && @demo.track.id == track.id && "is-active"]}
                  phx-click="select_track"
                  phx-value-index={index}
                >
                  {index + 1}. {track.title}
                </button>
              </div>
              <p class="sim-hint">Edge cases</p>
              <div class="sim-row">
                <button
                  :for={key <- Catalog.preset_keys()}
                  class="sim-btn sim-btn--small"
                  phx-click="preset"
                  phx-value-key={key}
                >
                  {String.replace(key, "_", " ")}
                </button>
              </div>
              <.form for={@track_form} id="track-form" phx-submit="save_track" class="sim-form">
                <label class="sim-field">
                  <span>Title</span>
                  <input type="text" name="track[title]" value={@track_form[:title].value} />
                </label>
                <label class="sim-field">
                  <span>Artist</span>
                  <input type="text" name="track[artist]" value={@track_form[:artist].value} />
                </label>
                <label class="sim-field">
                  <span>Album</span>
                  <input type="text" name="track[album]" value={@track_form[:album].value} />
                </label>
                <button class="sim-btn" type="submit">Apply metadata</button>
              </.form>
            </section>

            <section class="sim-card">
              <h2 class="sim-card__title">Playback</h2>
              <div class="sim-row">
                <button class="sim-btn" phx-click="playback" phx-value-status="playing">Playing</button>
                <button class="sim-btn" phx-click="playback" phx-value-status="paused">Paused</button>
                <button class="sim-btn" phx-click="playback" phx-value-status="stopped">Stopped</button>
              </div>
              <.form for={@progress_form} id="progress-form" phx-submit="save_progress" class="sim-form">
                <label class="sim-field">
                  <span>Position (s)</span>
                  <input
                    type="number"
                    step="1"
                    name="progress[position]"
                    value={@progress_form[:position].value}
                  />
                </label>
                <label class="sim-field">
                  <span>Duration (s, empty = unknown)</span>
                  <input
                    type="number"
                    step="1"
                    name="progress[duration]"
                    value={@progress_form[:duration].value}
                  />
                </label>
                <button class="sim-btn" type="submit">Apply progress</button>
              </.form>
            </section>

            <section class="sim-card">
              <h2 class="sim-card__title">Artwork</h2>
              <div class="sim-row">
                <button
                  :for={n <- 1..4}
                  class={["sim-btn sim-btn--art", @demo && @demo.artwork == n && "is-active"]}
                  phx-click="artwork"
                  phx-value-n={n}
                >
                  <img src={"/images/demo-artwork-#{n}.svg"} alt={"Demo artwork #{n}"} />
                </button>
                <button class="sim-btn" phx-click="artwork" phx-value-n="none">No artwork</button>
              </div>
            </section>

            <section class="sim-card">
              <h2 class="sim-card__title">Physical buttons</h2>
              <p class="sim-hint">
                Debounced fake input → Jukebox.Commands → remote control or animation style
              </p>
              <div class="sim-row">
                <button class="sim-btn" phx-click="press" phx-value-command="previous_track">
                  ⏮ Previous
                </button>
                <button class="sim-btn" phx-click="press" phx-value-command="toggle_playback">
                  ⏯ Play / Pause
                </button>
                <button class="sim-btn" phx-click="press" phx-value-command="next_track">⏭ Next</button>
              </div>
              <div class="sim-row">
                <button class="sim-btn sim-btn--small" phx-click="remote" phx-value-value="available">
                  Remote available
                </button>
                <button class="sim-btn sim-btn--small" phx-click="remote" phx-value-value="unavailable">
                  Remote unavailable
                </button>
              </div>
              <div class="sim-row sim-row--center">
                <button
                  id="animation-button"
                  class="sim-btn"
                  phx-click="press"
                  phx-value-command="cycle_animation"
                >
                  ✨ Animation style
                </button>
                <ol id="animation-styles" class="sim-steps" aria-label="Animation styles">
                  <li
                    :for={style <- Animation.styles()}
                    class={["sim-step", @animation == style && "is-active"]}
                    data-style={style}
                    aria-current={@animation == style && "true"}
                  >
                    {style}
                  </li>
                </ol>
              </div>
              <ul id="command-log" class="sim-log">
                <li :for={fb <- @commands}>
                  <code>{fb.command}</code>
                  <span>{inspect(fb.result)}</span>
                </li>
                <li :if={@commands == []} class="sim-log__empty">No command received yet.</li>
              </ul>
            </section>

            <section id="hardware-card" class="sim-card">
              <h2 class="sim-card__title">Physical controls</h2>
              <p class="sim-hint">
                Raw key event → Jukebox.Hardware.Buttons (debounce, power gate) → Jukebox.Commands.
                Lights and software dimming report what was confirmed, never what was asked.
              </p>
              <%= if is_map(@hardware.buttons) and @hardware.buttons.source == :simulated do %>
                <div id="hardware-buttons" class="sim-row">
                  <button
                    :for={{action, label} <- @hardware_buttons}
                    id={"hardware-tap-#{action}"}
                    class="sim-btn sim-btn--small"
                    phx-click="hardware_tap"
                    phx-value-action={action}
                  >
                    {label}
                  </button>
                </div>
              <% else %>
                <p id="hardware-buttons-off" class="sim-hint">
                  The pretend input device is not in use (JUKEBOX_BUTTONS_SOURCE is not
                  "simulated"): presses come from the real device only.
                </p>
              <% end %>
              <div :if={@hardware_simulated_power?} id="hardware-power" class="sim-row">
                <button
                  :for={
                    {mode, label} <- [
                      {"awake", "Awake"},
                      {"standby", "Standby"},
                      {"shutting_down", "Shutting down"},
                      {"down", "Controller down"}
                    ]
                  }
                  id={"hardware-power-#{mode}"}
                  class={[
                    "sim-btn sim-btn--small",
                    mode == to_string(@hardware.power.mode) && "is-active",
                    mode == "down" && @hardware.power.mode == :unknown && "is-active"
                  ]}
                  phx-click="hardware_power"
                  phx-value-mode={mode}
                >
                  {label}
                </button>
              </div>
              <div :if={simulated_display?(@hardware)} id="hardware-display" class="sim-row">
                <button
                  :for={
                    {state, label} <- [
                      {"up", "X11 up"},
                      {"down", "X11 down"},
                      {"restarted", "X11 restarted"}
                    ]
                  }
                  id={"hardware-display-#{state}"}
                  class="sim-btn sim-btn--small"
                  phx-click="hardware_display"
                  phx-value-state={state}
                >
                  {label}
                </button>
              </div>
              <table id="hardware-status" class="sim-table">
                <tbody>
                  <tr>
                    <th>power mode</th>
                    <td id="hardware-power-mode">
                      {@hardware.power.mode}
                      <span :if={@hardware.power.reason}>({inspect(@hardware.power.reason)})</span>
                    </td>
                  </tr>
                  <%= if is_map(@hardware.lights) do %>
                    <tr :for={light <- [:disco, :strip]}>
                      <th>{light} ({@hardware.lights[light].backend})</th>
                      <td id={"hardware-light-#{light}"}>
                        {light_state(@hardware.lights[light])}
                        <span :if={@hardware.lights[light].pending > 0}>· pending</span>
                        <span :if={@hardware.lights[light].last_error}>
                          · {inspect(@hardware.lights[light].last_error)}
                        </span>
                      </td>
                    </tr>
                  <% end %>
                  <tr>
                    <th>software dimming</th>
                    <td id="hardware-brightness">
                      {brightness_state(@hardware.brightness)}
                      <%= if is_map(@hardware.brightness) do %>
                        <span>· {@hardware.brightness.desired_coefficient} desired</span>
                        <span :if={@hardware.brightness.pending?}>· pending</span>
                        <span :if={@hardware.brightness.last_error}>
                          · {inspect(@hardware.brightness.last_error)}
                        </span>
                      <% end %>
                    </td>
                  </tr>
                  <%= if is_map(@hardware.buttons) do %>
                    <tr>
                      <th>input device</th>
                      <td id="hardware-connection">
                        {connection_state(@hardware.buttons.connection)}
                        <span :if={@hardware.buttons.device}>
                          · {@hardware.buttons.device.name}
                        </span>
                      </td>
                    </tr>
                    <tr>
                      <th>last accepted</th>
                      <td id="hardware-last-accepted">
                        <%= if @hardware.buttons.last_accepted do %>
                          code {@hardware.buttons.last_accepted.code} → {@hardware.buttons.last_accepted.action}
                        <% else %>
                          —
                        <% end %>
                      </td>
                    </tr>
                    <tr>
                      <th>counters</th>
                      <td id="hardware-counts">
                        {Enum.map_join(@hardware.buttons.counts, " · ", fn {name, count} ->
                          "#{name} #{count}"
                        end)}
                      </td>
                    </tr>
                  <% end %>
                  <tr :if={@hardware.recent_error != %{}}>
                    <th>recent errors</th>
                    <td id="hardware-errors">{inspect(@hardware.recent_error)}</td>
                  </tr>
                </tbody>
              </table>
            </section>

            <section id="audio-card" class="sim-card">
              <h2 class="sim-card__title">Audio analysis</h2>
              <%= if @audio_simulated do %>
                <p class="sim-hint">
                  Simulated analyser → PubSub → "audio-frame" events. Frames flow only while a
                  track is playing, in every animation style except calm.
                </p>
                <div id="audio-profiles" class="sim-row">
                  <button
                    :for={{profile, label} <- @audio_profiles}
                    id={"audio-profile-#{profile}"}
                    class={[
                      "sim-btn sim-btn--small",
                      @audio_simulated.profile == profile && "is-active"
                    ]}
                    phx-click="audio_profile"
                    phx-value-profile={profile}
                  >
                    {label}
                  </button>
                </div>
                <div id="audio-tempos" class="sim-row">
                  <button
                    :for={bpm <- @audio_tempos}
                    id={"audio-bpm-#{bpm}"}
                    class={["sim-btn sim-btn--small", @audio_simulated.bpm == bpm && "is-active"]}
                    phx-click="audio_bpm"
                    phx-value-bpm={bpm}
                  >
                    {bpm} BPM
                  </button>
                </div>
                <p class="sim-hint">
                  Free tempo: beats below the confidence threshold, so the fixed tempo drives the
                  lights. Analyser down: no frames at all, so the display returns to its ordinary
                  animation.
                </p>
              <% else %>
                <p id="audio-source" class="sim-hint">
                  Audio source: <code>{@audio_source}</code>. The controls here need the simulated
                  source (the default in development).
                </p>
              <% end %>
            </section>

            <section class="sim-card">
              <h2 class="sim-card__title">Metadata link</h2>
              <div class="sim-row">
                <button class="sim-btn" phx-click="connection" phx-value-status="disconnected">
                  Disconnect metadata
                </button>
                <button class="sim-btn" phx-click="connection" phx-value-status="connected">
                  Reconnect metadata
                </button>
                <button class="sim-btn sim-btn--danger" phx-click="reset">Reset everything</button>
              </div>
            </section>
          </div>

          <div class="sim__preview">
            <section class="sim-card">
              <div class="sim-card__head">
                <h2 class="sim-card__title">Kiosk preview</h2>
                <div class="sim-row">
                  <button
                    :for={size <- ["1920x1080", "1280x720", "1024x600"]}
                    class={["sim-btn sim-btn--small", @preview == size && "is-active"]}
                    phx-click="preview"
                    phx-value-size={size}
                  >
                    {size}
                  </button>
                </div>
              </div>
              <div
                id="kiosk-preview-box"
                class="sim-preview"
                style={"width:#{round(@preview_w * @preview_scale)}px;height:#{round(@preview_h * @preview_scale)}px"}
              >
                <iframe
                  id="kiosk-preview"
                  src="/"
                  title="Kiosk preview"
                  style={"width:#{@preview_w}px;height:#{@preview_h}px;transform:scale(#{@preview_scale})"}
                >
                </iframe>
              </div>
              <p class="sim-hint">
                Click inside the preview, then use ← Space → and I / C / A keyboard shortcuts.
              </p>
            </section>

            <section class="sim-card">
              <h2 class="sim-card__title">Playback state</h2>
              <table id="state-table" class="sim-table">
                <tbody>
                  <tr :for={{key, value} <- @state |> Map.from_struct() |> Enum.sort()}>
                    <th>{key}</th>
                    <td>{inspect_value(value)}</td>
                  </tr>
                </tbody>
              </table>
            </section>
          </div>
        </div>
      </Layouts.app>
      """
    end
  end
end
