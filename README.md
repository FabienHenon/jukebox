# Jukebox

A homemade AirPlay jukebox display for a Raspberry Pi 3. An iPhone streams
YouTube Music to the Pi through Shairport Sync; this Phoenix LiveView
application turns the attached landscape screen into a colourful pastel
jukebox that shows the current track, artwork, playback state and progress,
and relays the physical Previous / Play-Pause / Next buttons back to the
phone.

The screen is a passive display: there are no clickable controls on the kiosk
route. Everything is driven by the iPhone, the physical buttons, and (in
development) a simulator page and keyboard shortcuts.

## Quick start (development, no hardware)

```sh
mix setup            # deps + assets (first time)
mix phx.server       # or: iex -S mix phx.server
```

- Kiosk: <http://localhost:4000/>
- Simulator: <http://localhost:4000/dev/simulator>

The development environment uses demo adapters: a fake AirPlay sender with
four fictional tracks and original abstract artwork, a demo remote control,
and a fake physical input. No Raspberry Pi, MQTT broker, AirPlay sender or
GPIO hardware is needed.

Keyboard shortcuts on the kiosk page (development only; the page must have
focus):

| Key | Action |
| --- | --- |
| `←` | Previous track |
| `Space` | Toggle play / pause |
| `→` | Next track |
| `C` | Start a demo AirPlay session |
| `I` | End the demo session (return to idle) |

The transport keys go through the same semantic command service that the
physical buttons will use.

## Verification

```sh
mix precommit        # compile --warnings-as-errors, deps.unlock --unused, format, test
mix test             # 144 tests
```

## Architecture

```text
iPhone / YouTube Music
        │  AirPlay audio + metadata
        ▼
Shairport Sync ────────────────────────────► ALSA / DAC / amplifier
        │  metadata, cover art, session events (MQTT, local broker)
        ▼
Jukebox.MetadataSources.ShairportMqtt   (adapter; Demo in dev/test)
        │  normalised events (Jukebox.Playback.Event)
        ▼
Jukebox.Playback.Server ──── Phoenix PubSub ────► JukeboxWeb.JukeboxLive (kiosk)
        ▲                                                 │ command feedback
        │ state                                           ▼
Jukebox.Commands ◄──── Jukebox.Inputs.* (GPIO later, Fake now, dev keys)
        │
        ▼
Jukebox.RemoteControls.Shairport ──► MQTT remote topic ──► Shairport Sync ──► iPhone
```

### Modules

| Module | Role |
| --- | --- |
| `Jukebox.Playback.State` | Pure reducer: merges partial metadata, detects new tracks, validates and clamps progress, freezes position on pause, drives the ending → idle transition. |
| `Jukebox.Playback.Server` | GenServer owning the state; broadcasts `{:playback_state, state}` on changed states only; schedules the configurable idle grace period. |
| `Jukebox.Playback.Event` | The normalised event vocabulary every adapter must speak. |
| `Jukebox.Playback.Artwork` | Small artwork reference (id + versioned URL); binary images never cross the socket. |
| `Jukebox.Artwork.Store` | Bounded in-memory (ETS) image cache with JPEG/PNG signature and size validation, served at `/artwork/:id`. |
| `Jukebox.MetadataSource` / `Jukebox.MetadataSources.{Demo, ShairportMqtt}` | Metadata-source boundary and its two implementations. |
| `Jukebox.Shairport`, `Jukebox.Shairport.Decoder`, `Jukebox.Shairport.MqttHandler` | Configuration + command vocabulary, pure MQTT payload decoding, and the connection handler. |
| `Jukebox.RemoteControl` / `Jukebox.RemoteControls.{Demo, Shairport}` | Remote-control capability boundary. |
| `Jukebox.Commands` | Semantic command service: checks the state, calls the adapter safely, broadcasts feedback. |
| `Jukebox.Input`, `Jukebox.Input.Debounce`, `Jukebox.Inputs.{Noop, Fake}` | Physical-input boundary, per-command debouncing, and the two shipped adapters. |
| `Jukebox.Integrations` | Supervisor for the adapters, started after the endpoint. |
| `JukeboxWeb.JukeboxLive` + `JukeboxWeb.JukeboxComponents` + `JukeboxWeb.Presenter` | The kiosk: one LiveView, function components per screen, a presenter that turns the domain state into a flat view model. |
| `JukeboxWeb.SimulatorLive` | Development simulator (compiled and routed in dev only). |

### Key decisions

- **Phoenix never speaks AirPlay.** Shairport Sync is a separate system
  service; the application consumes its MQTT output through an adapter. The
  raw topic names, four-character codes and image formats stay inside
  `Jukebox.Shairport.*`.
- **MQTT client.** `tortoise311` (pure Elixir, MQTT 3.1.1, built-in
  reconnection with backoff) is the only new dependency. The connection process
  lives under `Jukebox.Integrations`, which starts after the endpoint and has
  generous restart limits, so an unavailable broker can never delay or take
  down the display.
- **State ownership.** `Jukebox.Playback.Server` is the single source of
  truth. LiveViews read it on every mount and subscribe on connected mount, so
  a browser refresh, a LiveView reconnect or an adapter crash never loses the
  current screen. The reducer is pure and covered by unit tests.
- **Track identity and stale artwork.** A different track id (or a different
  title when no id is known) clears every track field, and artwork tagged with
  an old track id is ignored. Stale text is never paired with stale artwork.
- **Session end vs. track change.** `session_ended` moves to `:ending`,
  keeps the last track visible and starts the configurable idle grace period
  (`JUKEBOX_IDLE_TIMEOUT_MS`). Flushes and play-end markers only change the
  playback status; they never flash back to idle.
- **Artwork in memory.** Images are validated (2 MB limit, JPEG/PNG magic
  bytes), cached in ETS (last three), and served with immutable cache headers
  from a content-hash URL. Nothing is written to the SD card.
- **Palette extraction.** The `ArtworkPalette` hook samples each cover once
  (24×24 offscreen canvas, cached per artwork id) and derives two pastel
  accents that tint the plates behind the artwork, the progress fill, the
  waves and a soft glow on the screen window (lightness pinned at 91% via
  `--glow-l`, so text contrast never changes).
  Running it in the browser avoids a native image library on the Pi; the
  pink shell, cream screen and text colours never change, and fallback
  artwork restores the defaults.
- **Waves.** The Now Playing screen shows three pastel wave layers that
  scroll while playing, freeze while paused or stopped and scale with the
  reported volume. They are driven by playback state only: the application
  never reads audio, so this is deliberately motion, not a visualiser, and the
  markup is decorative (`aria-hidden`). A real PCM-driven visualiser would need
  an ALSA loopback on the Pi and is left for a later version.
- **Progress interpolation.** The server renders the anchor (position,
  duration, playing?) as data attributes; a small hook interpolates locally
  four times a second, stops while paused or hidden, and re-syncs whenever the
  state changes. No render per animation frame, no polling.
- **Animations for a Pi 3.** Only `opacity`/`transform` are animated: CSS
  keyframes for enter transitions, `phx-remove` JS transitions for leave
  transitions, a dozen small bulbs and lamps for ambient life. Ambient
  animations pause when the document is hidden, and `prefers-reduced-motion`
  removes movement while keeping every state readable.
- **Fonts.** The `Jukebox` wordmark uses Pacifico, a 1950s/60s brush-script
  face under the SIL Open Font License, self-hosted from `priv/static/fonts`
  (license file alongside). Everything else uses a rounded system stack
  (`ui-rounded`, SF Pro Rounded, Arial Rounded, Nunito/Quicksand/Varela Round
  where installed). Nothing is loaded from the network at runtime; to change a
  face, drop a `.woff2` in `priv/static/fonts` and edit the `@font-face` rule
  in `assets/css/jukebox.css`.
- **Development tooling is compiled out of production.** The simulator
  module and route exist only when `config :jukebox, simulator: true` /
  `dev_routes: true` (dev; the module is also compiled in test so it can be
  tested in isolation, but it is not routed there). Keyboard shortcuts require
  `dev_keys: true`, checked at compile time.
- **Adapters by configuration.** `config :jukebox, :metadata_source`,
  `:remote_control` and `:input` are `{module, opts}` tuples selected per
  environment and overridable at runtime through environment variables in
  production (see below).

## Visual states

| State | What is shown |
| --- | --- |
| Startup | Pink jukebox frame fading in, bulbs lighting in sequence, `JUKEBOX` wordmark, "Starting the music…"; crossfades to the current state as soon as the LiveView connects. |
| Idle | Slowly spinning abstract record, floating notes, "Ready to play" and the AirPlay instruction; "Waiting for AirPlay…" in the base. |
| Connecting | Pulsing artwork placeholder, "Receiving music…", the source device name and two skeleton lines. |
| Now playing | Large square artwork on pastel plates (left), title / artist / album, progress line with elapsed and total time, status pill, volume and scrolling pastel waves (right). Plates, progress fill and waves take their tint from the cover. Track changes fade the old artwork out and the new one in. |
| Paused | Same content, "Paused" pill, progress interpolation stopped, softer plates and slower bulbs. |
| Ending | Last track kept with a "Session ended" pill, then a fade back to idle after the grace period. |
| Degraded | Last known track kept, a pulsing "Reconnecting…" pill in the base; a separate "Display reconnecting…" hint when the LiveView socket itself drops. |
| Command feedback | Non-interactive pill at the bottom of the screen for ~0.9 s: Previous / Play / Pause / Next, or "No active player" / "Control unavailable" / "Command not delivered". |

## Simulator

`/dev/simulator` (development only) drives the demo adapters and embeds a
scaled live preview of the kiosk at 1920×1080, 1280×720 and 1024×600:

- start a session (normal, metadata delayed by 2.5 s, title only, without
  artwork) or end it;
- pick one of the four demo tracks or the edge-case presets (80-character
  strings, non-Latin Unicode, emoji, missing title, missing artist and
  duration);
- set playing / paused / stopped, edit title, artist and album, change
  position and duration, swap or remove artwork;
- disconnect / reconnect the metadata link, toggle remote-control
  availability;
- press the fake physical buttons and inspect the last semantic commands and
  the full playback state.

## Configuration

Development and test select the demo adapters in `config/dev.exs` and
`config/test.exs`. Production defaults (`config/prod.exs`) are the Shairport
MQTT adapters; `config/runtime.exs` reads the environment:

```text
SECRET_KEY_BASE, PHX_SERVER=true, JUKEBOX_BIND=127.0.0.1, PORT=4000
JUKEBOX_METADATA_ADAPTER=mqtt|demo
JUKEBOX_MQTT_HOST=127.0.0.1  JUKEBOX_MQTT_PORT=1883  JUKEBOX_MQTT_TOPIC=jukebox/shairport
JUKEBOX_MQTT_CLIENT_ID=jukebox-display  JUKEBOX_MQTT_USERNAME  JUKEBOX_MQTT_PASSWORD
JUKEBOX_REMOTE_CONTROL_ENABLED=true
JUKEBOX_IDLE_TIMEOUT_MS=5000
```

Invalid local values fail fast at boot; unreachable services do not.

## Raspberry Pi deployment

See [docs/raspberry-pi.md](docs/raspberry-pi.md) and the templates under
[ops/](ops/):

- `ops/jukebox.service.example` – systemd unit for the release
- `ops/jukebox.env.example` – environment file for the unit
- `ops/shairport-sync.conf.example` – Shairport Sync metadata/MQTT/remote fragment
- `ops/mosquitto.conf.example` – loopback-only local broker
- `ops/chromium-kiosk.example` – Chromium kiosk launcher with auto-restart

## Project layout

```text
lib/jukebox/            domain, adapters, supervisors
lib/jukebox_web/        kiosk LiveView, components, presenter, simulator, artwork controller
assets/css/jukebox.css  kiosk design (custom properties, clamp(), container units)
assets/js/hooks/        progress interpolation, development keyboard shortcuts
priv/static/images/     original abstract demo covers and fallback artwork
ops/, docs/             Raspberry Pi templates and documentation
test/                   reducer, server, decoder, commands, inputs, store, LiveView tests
```
