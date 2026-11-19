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
| `A` | Animation button: switch to the next animation style |

The transport and animation keys go through the same semantic command service
that the physical buttons will use.

## Verification

```sh
mix precommit        # compile --warnings-as-errors, deps.unlock --unused, format, test
mix test             # 256 tests (2 need the native analyser built, and are skipped without it)
mix test.js          # 20 tests of the browser-side audio controller (Node 20+, no dependency)
make -C native/jukebox_audio_analyzer test   # 55 tests of the native analyser (needs libaubio)
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
| `Jukebox.Animation` | Owner of the animation style (`:calm`, `:waves`, `:chase`, `:party`) that the animation button cycles through; broadcasts changes. |
| `Jukebox.Input`, `Jukebox.Input.Debounce`, `Jukebox.Inputs.{Noop, Fake}` | Physical-input boundary, per-command debouncing, and the two shipped adapters. |
| `Jukebox.AudioAnalysis`, `Jukebox.AudioAnalysis.Frame`, `Jukebox.AudioAnalysis.Source` / `Jukebox.AudioAnalysis.{NativeSource, SimulatedSource, DisabledSource}` | Audio-analysis boundary: validated frames (loudness, bass, attacks, beats, tempo, confidence) published on PubSub, from the native analyser's Unix socket, from a deterministic simulation, or not at all. |
| `native/jukebox_audio_analyzer` | The native analyser (C, aubio): reads the PCM that Shairport Sync plays, through an ALSA tap, and sends the frames. Not part of the release; built on the Pi. |
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
- **Track identity and stale artwork.** A new track clears every track
  field, and artwork tagged with an old track id is ignored, so stale text is
  never paired with stale artwork. Identity follows what is displayed: the
  same title by the same artist is the same track even under a new id, because
  senders re-announce a song (YouTube Music publishes a provisional id with
  partial fields, then another id with the complete ones). The id only decides
  when titles cannot be compared.
- **Track changes arrive as bursts.** Shairport Sync publishes one MQTT
  message per field. Three things keep the screen from showing the half-updated
  states in between: the MQTT handler collects the fields between Shairport's
  bundle markers (`ssnc/mdst` … `ssnc/mden`, needs `publish_raw`) into one
  event; the playback server buffers a burst for `coalesce_ms` (150 ms,
  `JUKEBOX_COALESCE_MS`) and broadcasts a single state; and Shairport's
  empty-payload substitute (`--`) is treated as "no value" instead of text.
- **Fading elements never reuse a DOM id.** LiveView keeps an element with
  `phx-remove` in the DOM while it fades, and patches a new element with the
  same id into the leaving one, which then disappears with it. Screens,
  artwork and track text take their ids from generation counters held by the
  LiveView, so rapid changes cannot blank the display.
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
  reported volume. Without audio analysis (the default) they are driven by
  playback state only: motion, not a visualiser. The markup is decorative
  (`aria-hidden`) either way.
- **Audio-reactive animation (optional).** With audio analysis enabled the
  display follows the music actually being played: the waves rise with the
  loudness, the cover pulses with the bass, the bulbs dim in quiet passages
  and the `chase` / `party` lights step on the detected beat. The pipeline is `Shairport Sync → ALSA "file" plugin → native analyser
  → Unix datagrams → Jukebox.AudioAnalysis.NativeSource → PubSub → LiveView
  push_event → JukeboxLights hook`. Three rules shaped it: the analysis runs
  outside the browser (Chromium is already the heaviest process on the Pi)
  and outside the BEAM (no NIF); Phoenix is never on the audio path (the
  analyser drops frames nobody reads and never waits); and a frame never
  touches the LiveView assigns, so 20 frames a second cost 20 small events
  and no render. The hook keeps targets and shown values apart, smooths them
  per animation frame and writes three custom properties on `<html>`
  (`--audio-level`, `--audio-bass`, `--audio-mix`) that the CSS turns into transforms and opacities. Without
  frames for half a second, or below the confidence threshold, the fixed
  tempo takes over again, on the same step counter, so nothing jumps. See
  [docs/audio-reactive-setup.md](docs/audio-reactive-setup.md); the ALSA side
  has not been run on hardware yet.
- **Animation styles.** One button (`:cycle_animation`, a semantic command
  like the transport ones, but handled locally and available without a
  player) cycles through four styles held by `Jukebox.Animation`: `calm` (no
  waves), `waves`, `chase` (the default) and `party`. In the last two the
  `JukeboxLights` hook runs one timer at the beat rate while music plays: in
  `chase` the colours travel down the left pillar, up the right one and along
  the marquee bulbs; in `party` every block and bulb takes a random colour on
  each beat and the grille waves change direction at random. The base grilles
  ripple with a wave that crosses them once per beat. The beat is a fixed
  tempo (`JUKEBOX_ANIMATION_BPM`, 120 by default) unless audio analysis is
  enabled and sure of the beat (see above). The last chosen style is saved to a one-line file
  (`animation_style` in `JUKEBOX_STATE_DIR`, `tmp/` in development) and read
  back at boot, so the jukebox comes back the way it was switched off;
  `JUKEBOX_ANIMATION_STYLE` only applies until the button has been pressed.
  The file lives beside the server rather than in the browser's local storage
  because the kiosk's Chromium profile is in `/tmp`, which does not survive a
  reboot.
- **Progress interpolation.** The server renders the anchor (position,
  duration, playing?) as data attributes; a small hook interpolates locally
  four times a second, stops while paused or hidden, and re-syncs whenever the
  state changes. No render per animation frame, no polling.
- **Animations for a Pi 3.** Only `opacity`/`transform` are animated: CSS
  keyframes for enter transitions, `phx-remove` JS transitions for leave
  transitions, a dozen small bulbs and lamps for ambient life. Ambient
  animations pause when the document is hidden, and `prefers-reduced-motion`
  removes movement while keeping every state readable. The beat-driven styles
  keep to the same budget: the colour changes are a few small repaints per
  beat rather than an animation, the lamp flash is opacity and scale, and each
  grille wave is a single strip sliding behind a static mask.
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
| Command feedback | Non-interactive pill at the bottom of the screen for ~0.9 s: Previous / Play / Pause / Next, "Animation: Calm / Waves / Chase / Party", or "No active player" / "Control unavailable" / "Command not delivered". |

The Now Playing screen follows the animation style: `calm` drops the waves,
`chase` and `party` add the beat-driven pillar blocks, bulbs and grilles while
music is playing (they hold still while paused and stay ambient on the other
screens).

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
- press the fake physical buttons (Previous, Play / Pause, Next and the
  animation-style button, with the current style highlighted next to it) and
  inspect the last semantic commands and the full playback state;
- drive the simulated audio analyser: a clear beat at five tempos, free tempo
  (beats below the confidence threshold), silence, or no analyser at all, to
  see each fallback of the audio-reactive animation.

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
JUKEBOX_COALESCE_MS=150
JUKEBOX_ANIMATION_STYLE=calm|waves|chase|party  JUKEBOX_ANIMATION_BPM=120
JUKEBOX_STATE_DIR=/var/lib/jukebox
AUDIO_REACTIVE_ENABLED=false  AUDIO_REACTIVE_SOURCE=native|simulated|disabled
AUDIO_ANALYSIS_SOCKET=/run/jukebox/audio-analysis.sock  AUDIO_ANALYSIS_PUBLISH_RATE=20
AUDIO_VISUAL_DELAY_MS=120  AUDIO_BEAT_CONFIDENCE_THRESHOLD=0.45
```

Development uses the simulated audio source; production has audio analysis
off until `AUDIO_REACTIVE_ENABLED=true`.

Invalid local values fail fast at boot; unreachable services do not.

## Raspberry Pi deployment

See [docs/raspberry-pi.md](docs/raspberry-pi.md) and the templates under
[ops/](ops/):

- `ops/jukebox.service.example` – systemd unit for the release
- `ops/jukebox.env.example` – environment file for the unit
- `ops/shairport-sync.conf.example` – Shairport Sync metadata/MQTT/remote fragment
- `ops/mosquitto.conf.example` – loopback-only local broker
- `ops/chromium-kiosk.example` – Chromium kiosk launcher with auto-restart
- `ops/audio/` – audio-reactive animation: the ALSA `jukebox_tap` device, the
  socket directory rule, and the install and rollback scripts
  ([docs/audio-reactive-setup.md](docs/audio-reactive-setup.md))

## Project layout

```text
lib/jukebox/            domain, adapters, supervisors
lib/jukebox_web/        kiosk LiveView, components, presenter, simulator, artwork controller
assets/css/jukebox.css  kiosk design (custom properties, clamp(), container units)
assets/js/hooks/        progress interpolation, artwork palette, beat-driven and audio-reactive lights, development keyboard shortcuts
assets/js/audio/        the audio-reactive controller (pure, tested with node --test in assets/test/)
native/                 the native audio analyser (C), its tests and the ALSA tap wrapper
priv/static/images/     original abstract demo covers and fallback artwork
ops/, docs/             Raspberry Pi templates and documentation
test/                   reducer, server, decoder, commands, inputs, store, LiveView tests
```
