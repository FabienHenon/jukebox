# Implementation Brief: Raspberry Pi AirPlay Jukebox

## Instructions to Fable 5.1

Act as a senior Elixir/Phoenix engineer and a product-oriented UI designer. Build the application described below inside the existing Phoenix and LiveView codebase.

Start by inspecting the repository, its Phoenix/Elixir versions, existing application structure, assets pipeline, CSS framework, test setup, and conventions. Reuse what is already present. Do not replace the project with a new scaffold and do not introduce another front-end framework.

Implement the application, not merely a plan or a visual mock-up. When hardware or AirPlay is unavailable during development, use the simulator and adapter interfaces specified below so the complete experience remains usable and testable on a normal development computer.

Make reasonable implementation decisions when a detail is not specified, while keeping the solution small, maintainable, and suitable for a Raspberry Pi 3. Explain important decisions in the project README.

---

## 1. Product context

This is a personal, homemade physical jukebox. The final application will run locally on a Raspberry Pi 3 connected to:

- a landscape display;
- a DAC or other Linux audio output connected to an amplifier and speakers;
- physical transport buttons;
- a separate physical power button.

The owner starts music in YouTube Music on an iPhone, opens the iOS AirPlay output selector, and selects the jukebox. The iPhone remains the music source and primary controller. The Raspberry Pi receives and plays the AirPlay audio and displays the current track information.

The intended user journey is:

1. The user presses the physical power button on the jukebox.
2. The Raspberry Pi boots.
3. Linux automatically starts Shairport Sync, the Phoenix application, and Chromium in kiosk mode.
4. The screen displays a short jukebox startup animation, then an idle screen explaining that the jukebox is ready for AirPlay.
5. On the iPhone, the user starts a track in YouTube Music and selects the jukebox as the AirPlay output.
6. The speakers play the audio while the screen displays the artwork, title, artist, album, playback state, and progress of the current track whenever those values are supplied by the sender.
7. Physical Previous, Play/Pause, and Next buttons on the jukebox send remote-control commands back to the iPhone when the selected AirPlay mode supports them.
8. When the AirPlay session ends, the interface returns gracefully to the idle screen.

The screen is not a touchscreen. It is a passive display only. Every production interaction must happen through physical controls or through the iPhone.

---

## 2. System boundary and key technical decision

Phoenix must not implement, decode, or emulate the AirPlay protocol.

Use Shairport Sync as a separate system service responsible for:

- advertising the Raspberry Pi as an AirPlay audio receiver;
- receiving and decoding the audio stream;
- sending audio to ALSA/the configured DAC;
- receiving metadata and cover artwork from the source;
- exposing metadata to the Phoenix application;
- relaying supported remote-control commands to the AirPlay sender.

The Phoenix application is responsible for:

- normalizing and storing the current playback state in memory;
- consuming Shairport Sync events through an adapter;
- sending commands through a remote-control adapter;
- reacting to physical button events through an input adapter;
- broadcasting state changes with Phoenix PubSub;
- rendering the kiosk UI with LiveView;
- providing a complete development simulator.

The conceptual architecture is:

```text
iPhone / YouTube Music
        |
        | AirPlay audio + metadata
        v
Shairport Sync --------------------> ALSA / DAC / amplifier / speakers
        |
        | metadata and artwork
        v
Phoenix integration adapter
        |
        v
Playback state process ---> Phoenix PubSub ---> LiveView kiosk display
        ^                                             |
        |                                             |
Physical input adapter ---> command service ----------+
        |
        +----> Shairport remote control ----> iPhone / YouTube Music
```

For the first real Raspberry Pi integration, prefer Shairport Sync's MQTT interface because it can publish parsed metadata and artwork and expose remote control. Keep the integration behind behaviours so MQTT can later be replaced by D-Bus, MPRIS, or a metadata pipe without changing the domain or LiveView code.

Remote control is a capability, not an assumption. Stable Shairport Sync remote control targets Classic AirPlay clients; AirPlay 2 remote control may depend on experimental support. The UI and application must continue working when remote control is unavailable.

---

## 3. Scope of the first version

### Required

- A polished full-screen kiosk interface.
- Startup, idle, connecting, playing, paused, stopped/disconnected, and recoverable error states.
- Current title, artist, album, artwork, duration, position, playback status, source device name, and volume when available.
- Smooth transitions when the AirPlay session begins, ends, pauses, resumes, or changes track.
- A robust in-memory playback state owned by an OTP process.
- LiveView updates through Phoenix PubSub.
- A production-facing Shairport Sync MQTT metadata adapter.
- A remote-control abstraction for Previous, Play/Pause, and Next.
- A hardware-input abstraction ready for a future GPIO implementation.
- A development simulator that requires no Raspberry Pi, AirPlay sender, MQTT broker, or GPIO hardware.
- Keyboard shortcuts in development only.
- Responsive rendering for common landscape screens.
- Automated tests for state transitions, metadata normalization, command routing, and the main LiveView states.
- Documentation and deployment templates for Raspberry Pi operation.

### Explicitly out of scope

- AirPlay implementation inside Elixir.
- Video, photos, screen mirroring, YouTube video, or UxPlay.
- Google Cast or Chromecast.
- Searching or browsing YouTube Music from the jukebox.
- Reading the YouTube Music queue or showing upcoming tracks. AirPlay does not provide a reliable queue to this receiver.
- Playlist management.
- User accounts, authentication, permissions, or multi-user profiles.
- A cloud service or remote backend.
- Payments, analytics, or an administration back office.
- Multiroom audio.
- A touch interface, clickable production controls, on-screen keyboard, or mouse-driven navigation.
- A database requirement. Do not add persistence unless the existing codebase already requires it for unrelated reasons.
- A production audio visualizer that reads raw PCM. This can be considered later, but it is not part of this version.
- Automatic installation or system modification from the web application itself.

---

## 4. Target environment and constraints

- Target hardware: Raspberry Pi 3 initially.
- Target OS: a current Raspberry Pi OS/Debian-based installation.
- Runtime: Phoenix release managed by `systemd`.
- Display: Chromium launched automatically in kiosk mode against the local Phoenix endpoint.
- Network: local LAN only; the application should not require Internet access once dependencies and assets are installed.
- Audio: Shairport Sync should use ALSA or the configured Linux audio device directly.
- Performance: the UI must remain smooth on a Raspberry Pi 3.
- Screen orientation: landscape.
- Primary design target: 1920×1080 at 16:9.
- Also support 1280×720 and 1024×600 without scrolling, clipping, or overlapping text.
- The exact physical screen size is not known yet; use responsive sizing with `clamp()`, viewport units, grid/flex layouts, and sensible max dimensions.
- Production should normally bind only to localhost unless LAN access is intentionally enabled for diagnostics.

Avoid GPU-heavy techniques. Do not use WebGL, canvas particle systems, continuous blur animation, large JavaScript animation libraries, or video backgrounds. Prefer opacity and transform animations, CSS gradients, and a small number of pseudo-elements.

---

## 5. Visual direction

Create a joyful, premium, retro-modern jukebox rather than a generic music-player dashboard.

The overall visual should evoke a colorful 1950s jukebox interpreted through a soft contemporary illustration style. The screen should feel like it is part of the physical machine. It should be playful and warm, but not childish, kitsch, or visually cluttered.

The interface should include a stylized jukebox frame or arch around the content. The jukebox is primarily pink, with pastel yellow, blue, and green accent sections. Use rounded forms, soft highlights, discreet chrome-like details, layered borders, and gentle glows. The physical-looking frame must not consume so much room that the artwork and text become small.

Use this palette as the starting point:

| Role | Color | Hex |
| --- | --- | --- |
| Deep readable text | Aubergine | `#30233D` |
| Main jukebox shell | Pastel pink | `#F3A6C4` |
| Strong pink accent | Raspberry rose | `#E967A1` |
| Warm background | Vanilla cream | `#FFF5DF` |
| Yellow accent | Soft lemon | `#F7D96F` |
| Blue accent | Powder blue | `#93D5F4` |
| Green accent | Mint | `#A7E3C3` |
| Light surface | Warm white | `#FFFDF7` |

Create the colors as CSS custom properties. Minor adjustments are allowed for contrast and harmony, but pink must remain dominant. Do not use pure black for normal text or a sterile pure-white page background.

Typography should combine:

- one distinctive rounded display face for the `JUKEBOX` wordmark and track title;
- one very readable rounded sans-serif for metadata and status text.

Use local/self-hosted font files if fonts are added. The kiosk must not depend on Google Fonts or any external CDN at runtime. If the repository does not already contain appropriate licensed fonts, use a high-quality system font stack and make the styling work without downloads.

### Visual rules

- The current artwork is the main visual focus while playing.
- Title and artist must be readable from several metres away.
- Long strings must never overlap other content. Use line clamping, responsive font reduction where appropriate, and tested edge cases.
- All meaningful text must have adequate contrast against the pastel background.
- Animations must be soft and deliberate, usually 180–600 ms.
- Use longer, subtle ambient animation only for decorative lights or the idle state.
- Respect `prefers-reduced-motion` even though this is a dedicated display.
- Avoid imitating an iOS, Spotify, or YouTube Music interface.
- Do not show a large Apple logo. It is acceptable to say `AirPlay` in instructional copy.
- Do not display fake equalizer bars that imply real audio analysis.
- Do not use copyrighted album covers as bundled demo data. Create local abstract demo artwork instead.

---

## 6. Interaction model: display only

The production screen must not contain clickable controls.

Do not render buttons for Previous, Play/Pause, Next, volume, settings, or navigation. Do not show hover states, pointer cursors, touch prompts, focus rings for invisible interaction, or elements that look tappable. Do not bind production behaviour to pointer or touch events.

The interface may display small passive status indicators, for example a pause symbol next to `Paused`, but these must look like information rather than controls.

Hide the mouse cursor in production kiosk mode. Prevent text selection, scrollbars, overscroll, and accidental page movement. The root display must occupy the full viewport.

The physical controls for version one are:

| Physical control | Semantic command | Behaviour |
| --- | --- | --- |
| Previous button | `previous_track` | Ask the AirPlay sender to return to the previous track when remote control is available. |
| Play/Pause button | `toggle_playback` | Ask the sender to toggle playing/paused. |
| Next button | `next_track` | Ask the sender to skip to the next track. |
| Power button | Not an application command | Boot or safely shut down the Raspberry Pi at OS level. Phoenix must not own this button. |

Volume should remain controlled from the iPhone or the physical amplifier in version one. Design the command abstraction so `volume_up`, `volume_down`, or an absolute volume command can be added later, but do not make them required now.

Each valid physical transport press should produce a small non-interactive visual acknowledgement, such as a brief icon and label fading near the bottom of the screen for 600–900 ms. Examples: `Previous`, `Play`, `Pause`, or `Next`. This is feedback that the button was detected, not confirmation that the iPhone obeyed it.

If no AirPlay session is active or remote control is unavailable, do not falsely show that the track changed. A brief neutral message such as `No active player` or `Control unavailable` is acceptable. Keep it subtle.

Apply button debouncing at the input boundary, approximately 60–100 ms, and never allow switch bounce to send repeated commands. Keep long-press behaviour out of version one.

---

## 7. Application screens and states

The kiosk has one public LiveView route, ideally `/`, whose appearance changes according to playback state. Avoid a multi-page UI.

### 7.1 Startup state

Purpose: bridge the transition between the Linux splash and the ready screen.

Show:

- the stylized pastel jukebox frame;
- a `JUKEBOX` wordmark;
- a small animated musical motif or softly illuminating decorative lights;
- a short line such as `Starting the music…`.

Animation:

- frame fades/scales in gently;
- decorative pastel lights illuminate in sequence;
- transition automatically to idle when the application is ready.

Do not build a fake multi-step loader. The startup state should be attractive even if visible for only a second. The app must not artificially delay readiness in production.

### 7.2 Idle / ready-for-AirPlay state

This is the default state when no active AirPlay session exists.

Show:

- the `JUKEBOX` identity;
- a central abstract record/music illustration;
- the primary message `Ready to play`;
- a short instruction such as `Start music on your iPhone, then choose “Jukebox” in AirPlay.`;
- an optional small network/status line only if useful, for example `Waiting for AirPlay…`.

The instruction is informational, not a button. It should be readable without dominating the screen.

Use slow, low-cost ambient animation: a slight record rotation, glow breathing, or a few stationary decorative notes with tiny vertical movement. Pause continuous decorative animation when the tab is hidden.

### 7.3 Connecting / session-start state

An AirPlay session may become active before all metadata and artwork arrive.

Show:

- `Connecting…` or `Receiving music…`;
- the source device name when supplied;
- the artwork placeholder;
- skeleton-like content areas only if they match the visual style.

Do not flash blank values or the literal strings `null`, `undefined`, `0:00 / 0:00`, or internal metadata codes.

Transition progressively into Now Playing as fields arrive. Do not wait for every field before rendering useful information.

### 7.4 Now Playing state

This is the main screen.

Required hierarchy:

1. Large square album artwork.
2. Track title.
3. Artist.
4. Album, if present and distinct from the title/artist.
5. Progress line with elapsed and total time, when duration is known.
6. Small status/source information only if it does not compete with the music.

Recommended landscape composition:

- artwork occupies the left or central-left area;
- metadata occupies the right area;
- the pastel jukebox arch/frame surrounds both;
- on narrower landscape screens, reduce gaps and frame thickness before reducing legibility.

The exact composition may be refined after inspecting it at all target resolutions. A centred composition is also acceptable if it produces a stronger jukebox identity, but title and artwork must remain large.

Artwork treatment:

- square aspect ratio;
- rounded corners;
- subtle layered pastel shadow;
- no extreme glossy reflection;
- use a local fallback design when artwork is missing;
- use an image cache URL or a Phoenix-served local endpoint, never embed unbounded binary image data directly into every LiveView render.

Track-change animation:

- old artwork fades and scales down slightly;
- metadata moves/fades out by a few pixels;
- new artwork and text fade/slide in;
- surrounding accent colors may shift subtly, but the base palette must remain consistent;
- do not perform expensive real-time color extraction on every frame. If palette extraction is implemented, run it once per artwork and cache the result. It is optional.

Progress:

- display elapsed time and total duration only when reliable;
- interpolate progress smoothly on the client while playing;
- stop interpolation while paused;
- periodically resynchronise from server metadata rather than sending a LiveView update every animation frame;
- clamp values between zero and duration;
- hide the progress display if duration is missing or invalid.

### 7.5 Paused state

Keep the current artwork and metadata visible. Stop progress interpolation and any spinning record animation. Add a restrained passive `Paused` label or symbol. Do not dim the entire interface so much that it looks disconnected.

### 7.6 Session ended / disconnected state

When playback ends or the AirPlay session becomes inactive:

- do not instantly flash back to idle on a momentary flush or track change;
- distinguish track transitions from session termination;
- retain the last current track briefly if that avoids flicker;
- after a configurable grace period, fade to the idle screen;
- clear stale source/remote-control capability information.

The grace period should be configurable and should work with Shairport Sync's active session events.

### 7.7 Error and degraded states

The jukebox should be resilient, not alarmist.

- If Phoenix temporarily loses the metadata connection, keep the last known track and show a small `Reconnecting…` status.
- If artwork is malformed or unavailable, use the fallback artwork.
- If only some metadata is available, render only those fields.
- If remote commands are unavailable, playback display must still function.
- If LiveView reconnects, request/render the current authoritative state from the playback process immediately.
- Never expose stack traces, broker credentials, IP addresses, raw MQTT topics, or system errors on the public kiosk screen.

---

## 8. Domain model and state ownership

Define a normalized playback state independent of Shairport Sync. The exact module names may follow the repository's application namespace, but use this conceptual model:

```elixir
%PlaybackState{
  session_status: :inactive | :connecting | :active | :ending | :error,
  playback_status: :unknown | :stopped | :playing | :paused,
  title: nil | String.t(),
  artist: nil | String.t(),
  album: nil | String.t(),
  genre: nil | String.t(),
  artwork: nil | ArtworkReference.t(),
  track_id: nil | String.t(),
  duration_ms: nil | non_neg_integer(),
  position_ms: nil | non_neg_integer(),
  position_observed_at: nil | DateTime.t(),
  volume_percent: nil | number(),
  source_name: nil | String.t(),
  source_model: nil | String.t(),
  remote_control: :unknown | :available | :unavailable,
  metadata_connected?: boolean(),
  last_event_at: nil | DateTime.t()
}
```

Use an OTP process, normally a GenServer, as the single owner of this state. It should:

- receive normalized domain events from a metadata-source adapter;
- merge partial metadata safely;
- recognize new tracks and session boundaries;
- validate and clamp progress values;
- preserve the previous state during harmless transient events;
- broadcast meaningful changes over Phoenix PubSub;
- return the complete current state to newly mounted LiveViews;
- schedule the configurable idle transition after a session ends;
- avoid broadcasting duplicate states unnecessarily.

Example normalized events:

```elixir
{:session_started, %{source_name: "Fabien's iPhone"}}
{:metadata_changed, %{title: "Instant Crush", artist: "Daft Punk"}}
{:artwork_changed, artwork_reference}
{:progress_changed, %{position_ms: 134_000, duration_ms: 337_000}}
{:playback_changed, :playing}
{:volume_changed, 72.0}
{:session_ended, %{reason: :sender_disconnected}}
{:metadata_connection_changed, :disconnected}
```

Do not make the LiveView the authoritative playback state and do not store critical state only in socket assigns. A browser refresh must restore the current screen from the OTP process.

No Postgres table is needed for current playback. Avoid writing frequent playback events or artwork to the database or SD card unnecessarily.

---

## 9. Adapter design

Use Elixir behaviours and application configuration to select implementations.

### 9.1 Metadata source behaviour

Define a behaviour conceptually equivalent to:

```elixir
@callback child_spec(keyword()) :: Supervisor.child_spec()
```

The source process sends normalized events to the playback state owner. Provide at least:

- `DemoMetadataSource` for local development and automated tests;
- `ShairportMqttMetadataSource` for the Raspberry Pi environment.

Do not let raw MQTT topic names, four-character Shairport metadata codes, binary artwork formats, or broker reconnection logic leak into LiveView modules.

### 9.2 Remote-control behaviour

Define operations equivalent to:

```elixir
@callback previous_track() :: :ok | {:error, term()}
@callback toggle_playback() :: :ok | {:error, term()}
@callback next_track() :: :ok | {:error, term()}
@callback capabilities() :: MapSet.t(atom())
```

Provide:

- `DemoRemoteControl`, which updates simulated state and records commands;
- `ShairportRemoteControl`, which uses the configured Shairport Sync interface, preferably MQTT for this version.

Command failures must be logged and converted into safe UI feedback. They must not crash the playback state process or LiveView.

### 9.3 Physical-input behaviour

Define a process that emits semantic commands, not pin numbers:

```elixir
@type command :: :previous_track | :toggle_playback | :next_track
```

Provide:

- a no-op production-safe input implementation until GPIO is installed;
- a fake/test implementation;
- clearly documented integration points for a future GPIO implementation.

If a GPIO library is already present and compatible with the target Elixir/Raspberry Pi environment, a GPIO adapter may be added. Otherwise, do not add an unverified native dependency merely to pretend the hardware is complete. Keep the boundary ready and document the expected mapping separately.

The future GPIO mapping must be configurable and must never be hard-coded throughout the application.

---

## 10. Shairport Sync integration requirements

The application should be ready to consume Shairport Sync metadata through a local MQTT broker. Do not assume every music application provides every metadata field.

Use configuration values such as:

```text
JUKEBOX_METADATA_ADAPTER=mqtt
JUKEBOX_MQTT_HOST=127.0.0.1
JUKEBOX_MQTT_PORT=1883
JUKEBOX_MQTT_TOPIC=jukebox/shairport
JUKEBOX_REMOTE_CONTROL_ENABLED=true
JUKEBOX_IDLE_TIMEOUT_MS=5000
```

Follow the repository's existing configuration style and validate production configuration at startup. Never commit broker passwords or secrets.

The adapter should handle, where available:

- active session start/end;
- play start/end, flush, and resume;
- title;
- artist;
- album;
- genre;
- source device name/model;
- play status;
- duration/song time;
- progress timestamps;
- artwork as JPEG or PNG;
- volume;
- DACP/remote-control identifiers or capability information.

Important interpretation rules:

- Metadata arrives asynchronously and fields may arrive in any order.
- A flush can mean a skip or seek and is not necessarily the end of the AirPlay session.
- Artwork may arrive after the text metadata.
- A source may omit album, genre, duration, progress, artwork, or even title.
- Never display stale artwork for a clearly identified new track while waiting for the new artwork; switch to the fallback if necessary.
- Ignore unknown MQTT topics safely and log them at debug level.
- Reconnect to the local broker with bounded exponential backoff.
- Do not crash on invalid UTF-8, empty payloads, unexpected numeric formats, malformed images, or events received out of order.
- Set reasonable artwork-size limits before accepting or storing a payload.
- Store current artwork in a bounded cache or temporary application-managed location and clean up obsolete files. Do not allow unbounded SD-card growth.

If the exact remote MQTT command vocabulary differs between the installed Shairport Sync release and this brief, isolate that difference in the adapter and document the required Shairport version/configuration. Do not spread version-specific strings across the codebase.

Create a sample Shairport Sync configuration fragment under an `ops/` or `docs/` directory. It should demonstrate metadata, cover-art, MQTT publishing, a local broker, and remote-control enablement, without overwriting a user's system configuration.

---

## 11. Development simulator

The application must be pleasant to develop before any Raspberry Pi hardware is connected.

In the development environment, default to demo adapters. Provide a dedicated development-only route such as `/dev/simulator`. It must not be compiled or routed in production.

The simulator should allow a developer to:

- start and end an AirPlay-like session;
- choose among at least three fictional demo tracks;
- set playing, paused, or stopped;
- change title, artist, and album;
- select local abstract artwork or remove artwork;
- change position and duration;
- simulate delayed metadata arrival;
- simulate missing artwork or partial metadata;
- simulate metadata disconnection/reconnection;
- set remote-control availability;
- inspect the last semantic physical/remote command received.

Use only local, original abstract artwork bundled with the project. Demo titles and artists should be fictional.

Provide development keyboard shortcuts while the kiosk page has focus:

| Key | Action |
| --- | --- |
| Left arrow | Previous track |
| Space | Toggle play/pause |
| Right arrow | Next track |
| `I` | Return to idle / end demo session |
| `C` | Start/connect demo session |

Implement keyboard handling through a small LiveView JavaScript hook or an equally lightweight existing mechanism. Do not add a front-end framework. Keyboard shortcuts are development tools only and must be disabled in production. Do not display them on the production kiosk screen.

The demo source may optionally advance progress on a timer, but the timer must be deterministic enough for tests and must not create excessive process/message load.

---

## 12. LiveView implementation details

- Use a single main LiveView for the kiosk and split meaningful visual parts into function components.
- Subscribe to the playback PubSub topic on connected mount.
- Load the current playback state on every mount before subscribing/rendering.
- Keep presentation logic out of templates where practical.
- Use semantic HTML even though the screen is passive.
- Include ARIA-hidden attributes for purely decorative elements.
- Do not make passive transport symbols focusable.
- Let LiveView own state transitions, but use a small JavaScript hook for smooth progress interpolation and visibility-aware animation if necessary.
- Recover cleanly from LiveView disconnects without resetting the OTP playback state.
- Version artwork URLs or otherwise force the browser to update when a new image replaces the previous one.
- Avoid pushing base64 artwork repeatedly over the LiveView websocket.
- Do not poll the server from the browser when PubSub updates are available.
- Avoid one server render per progress-animation frame.

The page should set an explicit title and theme color but otherwise behave like an appliance display, not a website.

---

## 13. Animation requirements

Animations are important to the product experience, but they must be efficient.

Required transitions:

- startup frame reveal;
- startup-to-idle crossfade;
- idle-to-connecting transition;
- connecting-to-playing reveal;
- artwork and metadata transition on track change;
- playing-to-paused state change;
- session-ended fade back to idle;
- brief command-feedback overlay.

Implementation rules:

- Prefer `transform` and `opacity`.
- Avoid animating large blur radii, box-shadow values, layout dimensions, or filters continuously.
- Avoid excessive DOM elements.
- Target smooth output on a Raspberry Pi 3 rather than desktop-only visual complexity.
- Cancel or pause timers and ambient animation when the document is hidden.
- Provide a reduced-motion variant that keeps state changes clear without movement.
- Do not delay application state changes simply to finish an animation.

---

## 14. Responsive and edge-case requirements

Test the kiosk at 1920×1080, 1280×720, and 1024×600.

At every target resolution:

- no page scrolling;
- no horizontal overflow;
- no content behind the decorative frame;
- artwork remains square;
- elapsed and duration labels remain aligned;
- essential metadata remains readable;
- the idle instruction fits without clipping;
- command feedback is inside the safe area.

Test metadata edge cases:

- 80-character title;
- 60-character artist;
- 80-character album;
- non-Latin Unicode;
- emoji;
- missing title;
- missing artist;
- missing album;
- missing artwork;
- portrait and landscape artwork supplied accidentally;
- zero or missing duration;
- position greater than duration;
- negative or malformed numeric data;
- rapid next/previous track changes;
- artwork arriving after a track change;
- short MQTT disconnection;
- LiveView browser refresh during playback.

Define sensible fallback copy, for example `Unknown track` only when absolutely necessary. Prefer omitting secondary missing fields over filling the screen with repeated `Unknown` labels.

---

## 15. Supervision and resilience

Add integration processes to the existing OTP supervision tree in a sensible order.

The application should remain alive if:

- MQTT is temporarily unavailable;
- Shairport Sync is not yet started;
- malformed metadata is received;
- a remote command fails;
- Chromium refreshes or reconnects.

Use process isolation appropriately. A metadata-adapter crash should be restarted without discarding the last known playback state if practical. Log useful diagnostics without spamming on every progress interpolation tick.

Do not allow a failed external integration to create a restart loop that takes down the Phoenix endpoint.

---

## 16. Security and local appliance behaviour

- Treat all metadata strings and binary artwork as untrusted input.
- Escape text through normal Phoenix rendering.
- Validate artwork MIME signatures and size.
- Do not allow MQTT payloads to choose arbitrary filesystem paths.
- Do not expose the development simulator in production.
- Do not show secrets or raw diagnostics on the kiosk route.
- Bind the MQTT broker locally where possible.
- Do not add telemetry sent to third parties.
- Do not load runtime assets from external hosts.

---

## 17. Raspberry Pi deployment artifacts

Add documented templates, but do not write an installer that blindly changes the host machine.

Provide:

1. A Phoenix release configuration suitable for production.
2. An example `systemd` unit for the Phoenix release with restart-on-failure.
3. Documentation stating that Shairport Sync runs as its own independent service.
4. A sample Shairport Sync MQTT/metadata configuration fragment.
5. A Chromium kiosk launch example pointing to the local Phoenix URL.
6. Notes for hiding the cursor, disabling screen sleep, preventing browser chrome, and recovering Chromium if it exits.
7. The expected service ordering: network/local broker, Shairport Sync, Phoenix, then kiosk session as appropriate.
8. A statement that audio must continue through Shairport Sync even if Chromium or Phoenix restarts.
9. A note that the Pi 3 physical power button uses OS/GPIO configuration and is outside the Phoenix application.

Do not make the Phoenix service depend on Chromium. They must be independently restartable.

---

## 18. Testing requirements

Use the existing test framework and conventions.

At minimum, add tests for:

- initial inactive state;
- partial metadata merging;
- active session start and end;
- track change detection;
- play/pause transitions;
- progress validation and clamping;
- missing metadata and artwork fallbacks;
- stale/late artwork protection where track identity is known;
- metadata adapter normalization;
- malformed payload handling;
- command routing from semantic input to remote-control adapter;
- remote-control unavailable and command-error behaviour;
- input debouncing;
- main LiveView rendering for idle, connecting, playing, paused, and degraded states;
- LiveView receiving PubSub state updates;
- current state restoration on mount;
- development simulator not being routed in production.

Tests must not require a real MQTT broker, Shairport Sync, iPhone, GPIO pins, or network access. Use fakes and injectable adapters.

Run formatting, compilation with warnings treated seriously, and the complete test suite before considering the task complete.

---

## 19. Suggested project structure

Adapt names to the existing OTP application namespace. A structure similar to this is desirable:

```text
lib/
  jukebox/
    playback/
      state.ex
      server.ex
      event.ex
    metadata_source.ex
    metadata_sources/
      demo.ex
      shairport_mqtt.ex
    remote_control.ex
    remote_controls/
      demo.ex
      shairport.ex
    input.ex
    inputs/
      noop.ex
      fake.ex
  jukebox_web/
    live/
      jukebox_live.ex
      jukebox_live.html.heex
      simulator_live.ex
    components/
      jukebox_components.ex
assets/
  css/
    app.css
  js/
    hooks/
      jukebox_progress.js
      development_keys.js
  static/
    images/
      demo-artwork-*.svg
      fallback-artwork.svg
ops/
  jukebox.service.example
  shairport-sync.conf.example
  chromium-kiosk.example
docs/
  raspberry-pi.md
```

This is guidance, not a requirement to ignore the repository's conventions.

---

## 20. Configuration modes

Support clear environment-based modes:

### Development

- demo metadata source;
- demo remote control;
- simulator route enabled;
- keyboard commands enabled;
- normal browser cursor allowed on the simulator route;
- kiosk page still visually matches production.

### Test

- deterministic fake adapters;
- no timers unless explicitly controlled by the test;
- no broker or filesystem dependency outside test temp directories.

### Production

- Shairport MQTT metadata source;
- Shairport remote-control adapter when enabled;
- no simulator route;
- no keyboard control;
- no clickable elements;
- hidden cursor and full-viewport kiosk CSS;
- safe fallbacks if the external services are unavailable.

Fail fast only for truly invalid local configuration. Do not refuse to boot merely because MQTT or Shairport Sync is temporarily unavailable.

---

## 21. Acceptance criteria

The implementation is complete when all of the following are true:

1. Running the Phoenix app in development immediately shows a polished idle jukebox screen without requiring hardware.
2. The simulator can reproduce a full session: idle → connecting → playing → paused → next track → disconnected → idle.
3. Track changes animate smoothly and never show stale text paired with stale artwork for an obviously different track.
4. The screen has a dominant pastel-pink jukebox identity with pastel yellow, blue, and green accents.
5. There are no clickable transport controls on the production kiosk screen.
6. Development keyboard shortcuts route through the same semantic command service that future GPIO buttons will use.
7. Previous, Play/Pause, and Next commands are isolated behind a remote-control behaviour.
8. The playback state is owned outside LiveView and survives a browser refresh.
9. Partial/missing metadata never breaks the layout.
10. The layout works without scrolling at 1920×1080, 1280×720, and 1024×600.
11. The UI remains usable when MQTT or remote control is unavailable.
12. No external runtime font, image, script, stylesheet, or CDN is required.
13. Automated tests cover the important state and integration boundaries.
14. The repository contains clear local-development and Raspberry Pi deployment documentation.
15. Formatting, compilation, and tests succeed.

---

## 22. Implementation order

Use this order to reduce rework:

1. Inspect the existing application and document relevant conventions.
2. Implement the playback domain state, state owner, PubSub contract, and tests.
3. Implement demo adapters and the development simulator.
4. Build and polish all kiosk visual states using simulated data.
5. Add progress interpolation and efficient animations.
6. Implement semantic command routing and development keyboard input.
7. Implement the Shairport MQTT metadata and remote-control adapters.
8. Add resilience, validation, artwork cache limits, and error handling.
9. Add Raspberry Pi configuration examples and deployment documentation.
10. Run the complete verification suite and review every target resolution and edge case.

Do not postpone the simulator until the end. It is the tool that makes the UI and domain behaviour verifiable before the hardware exists.

---

## 23. Final handoff expected from Fable

At the end of the implementation, provide:

- a concise summary of what was implemented;
- the important architectural choices;
- a list of files added or modified;
- exact commands to run the application in demo mode;
- the URL for the kiosk and simulator routes;
- exact commands used to format, compile, and test;
- the result of those checks;
- any remaining hardware-dependent step that cannot be verified without the Raspberry Pi, clearly separated from completed application work;
- screenshots or a short description of each visual state if the environment supports them.

Do not claim that real AirPlay, DACP remote control, GPIO input, audio output, boot automation, or shutdown behaviour has been physically verified unless it was actually tested on the Raspberry Pi with the relevant hardware.
