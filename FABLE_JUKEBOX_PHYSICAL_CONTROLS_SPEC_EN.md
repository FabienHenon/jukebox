# Jukebox physical controls and Acer V173 X11 software dimming

Implementation brief for Fable — 20 November 2026, revised after the successful xrandr test

Implement this in the existing jukebox repository. Inspect its adapters, supervision tree, runtime configuration, release packaging, simulator, and hardware scripts first. Reuse existing domain actions. Do not rebuild the application, change its design, introduce a database, or claim hardware testing from a Mac.

## 1. Deployment and hardware context

- Raspberry Pi 2 Model B, ARMv7 / 32-bit Raspberry Pi OS, 1 GB RAM, 16 GB microSD.
- Sources: `/home/jukebox/src/jukebox-app`; installed release: `/opt/jukebox`.
- Existing repository-provided `jukebox.service`, running as user `jukebox` and loading `/etc/jukebox/jukebox.env`. Preserve its settings and secrets.
- Console autologin on tty1 starts X11/Openbox/Chromium kiosk. No touch screen. Browser focus must not be required for hardware input.
- Acer V173 external monitor with VGA input only, connected through the existing Amazon Basics HDMI-to-VGA cable/adapter B0BSKNNPD6. DDC/CI queries failed despite being enabled in the monitor menu. Do not investigate DDC further or require a replacement adapter for this feature.
- The user successfully tested `xrandr --output HDMI-1 --brightness 0.7` with `DISPLAY=:0` and `XAUTHORITY=/home/jukebox/.Xauthority`. `HDMI-1` is active at 1280×1024, approximately 60 Hz. Use these measured X11 values, not the DRM connector name `card0-HDMI-A-1`.
- Shairport Sync receives audio from the iPhone/YouTube Music. Use the existing remote transport adapter for previous/play-pause/next. No playlist access is assumed.
- Explicit USB DAC: `plughw:CARD=Audio,DEV=0`, behind `jukebox_tap` when audio analysis is enabled. Do not change the audio path, native analyser, or its `AUDIO_*` settings.
- Preserve Shairport general settings `default_airplay_volume = -12.0;` and `volume_range_db = 30;`.
- No database. Tailwind 4 assets are built off-Pi; the release is built for ARMv7.
- Eight ordinary momentary buttons connect to a Xin-Mo USB encoder. Their 12 V lighting is electrically separate from the switch contacts. Do not assume their Linux codes, USB IDs, controller name, or input device number.
- A separate Power button connects GPIO BCM3 (physical pin 5) to GND (pin 6). It is NOT a Xin-Mo input.

## 2. Ownership and architecture

Use one supervised server-side input adapter, not Chromium Gamepad API, DOM keyboard listeners, or one reader per LiveView connection.

Recommended implementation: a small Python helper using the distribution's `python3-evdev`, started as an Elixir Port with `/usr/bin/python3 -u`. Package it under `priv/hardware/xinmo_evdev.py`; resolve it through the application's release-aware priv directory, not the source tree. stdout is newline-delimited JSON; diagnostics go to stderr. Bound line lengths, buffering and restart rates. Ensure child cleanup on application shutdown and parent death, without orphan readers. A native Elixir evdev adapter is acceptable if already present and ARMv7-compatible; preserve this contract and diagnostics.

Responsibilities:

| Component | Owns |
| --- | --- |
| Input adapter | Selected Linux input device, raw events, reconnects |
| Server action dispatcher | Debouncing, code-to-action mapping, standby gating, calls to existing domain services |
| Brightness worker | Serialised xrandr requests and verification for the selected X11 output |
| Existing power controller | GPIO3, all power GPIOs, DPMS and shutdown sequencing |
| Phoenix/LiveView | Shared application state, animation-mode selection, honest status feedback |

The root power controller must work if Phoenix or Chromium is down. Phoenix must never acquire its GPIO lines or run as root. Do not add a second service reading the same buttons or executing the same actions. Disable existing browser Gamepad listeners for this production input source, to avoid duplicate actions. Explicit simulator-only controls may remain.

## 3. Exact actions

| Action ID | Behaviour |
| --- | --- |
| `previous` | Existing Shairport remote command `previtem` |
| `play_pause` | Existing Shairport remote command `playpause` |
| `next` | Existing Shairport remote command `nextitem` |
| `disco_toggle` | Existing power client with argument array `["disco", "toggle"]`; one group contains disco ball + illuminated panel |
| `strip_toggle` | Backend selected by `JUKEBOX_STRIP_CONTROL`; see section 8 |
| `animation_next` | Call existing server-side mode-cycling function, wrap around the existing ordered mode list; broadcast to all connected displays |
| `brightness_down` | Decrease the X11 software brightness coefficient by the configured step |
| `brightness_up` | Increase the X11 software brightness coefficient by the configured step |

Do not replay stale music commands after an AirPlay disconnect. Report unavailable transport without crashing. Do not optimistically claim a new playback state before the source confirms it. Multiple browser tabs must not multiply physical actions.

## 4. Runtime environment contract

Add these to the example env file and read them at runtime, not compile time. Buttons remain disabled with no guessed mappings. The example selects the user-validated xrandr backend and a neutral startup coefficient; missing X11 must not block startup. Each line is systemd EnvironmentFile syntax, not shell `export` syntax.

```ini
JUKEBOX_BUTTONS_ENABLED=false
JUKEBOX_BUTTONS_SOURCE=evdev
JUKEBOX_BUTTONS_DEVICE=
JUKEBOX_BUTTONS_DEBOUNCE_MS=80
JUKEBOX_BUTTONS_DEBUG=false

JUKEBOX_BUTTON_PREVIOUS=
JUKEBOX_BUTTON_PLAY_PAUSE=
JUKEBOX_BUTTON_NEXT=
JUKEBOX_BUTTON_DISCO_TOGGLE=
JUKEBOX_BUTTON_STRIP_TOGGLE=
JUKEBOX_BUTTON_ANIMATION_NEXT=
JUKEBOX_BUTTON_BRIGHTNESS_DOWN=
JUKEBOX_BUTTON_BRIGHTNESS_UP=

JUKEBOX_BRIGHTNESS_BACKEND=xrandr
JUKEBOX_XRANDR_OUTPUT=HDMI-1
JUKEBOX_X11_DISPLAY=:0
JUKEBOX_X11_XAUTHORITY=/home/jukebox/.Xauthority
JUKEBOX_BRIGHTNESS_MIN=0.3
JUKEBOX_BRIGHTNESS_MAX=1.0
JUKEBOX_BRIGHTNESS_STEP=0.1
JUKEBOX_BRIGHTNESS_DEFAULT=1.0
JUKEBOX_BRIGHTNESS_TIMEOUT_MS=3000

JUKEBOX_POWER_CLIENT=/usr/local/sbin/jukebox-power-controller.py
JUKEBOX_POWER_STATE_FILE=/run/jukebox-power/state.json
JUKEBOX_STRIP_CONTROL=power
JUKEBOX_WLED_URL=
```

- Input source: `evdev` in production; `simulated` in development/tests only.
- Device: one explicit, existing `/dev/input/by-id/...-event-joystick` path, or a verified equivalent event symlink under `by-path`/udev. Never select the first input device, open all keyboards, or assume `/dev/input/event0`. Support one selected event device in V1; explain how to wire all eight buttons to inputs represented by it if the Xin-Mo exposes multiple controllers.
- Button values: decimal Linux **EV_KEY codes**, e.g. `304` only if observed. These are not joystick indices, GPIO numbers or printed Xin-Mo terminal numbers. Empty means action unassigned. Accept decimal integers only and reject duplicate codes across enabled mappings. Validate the advertised device capabilities when connected.
- Brightness backend: `disabled`, `xrandr`, `simulated` (development/tests only). No silent DDC or CSS fallback. Coefficients are finite decimal numbers satisfying `0 < min < max <= 1.0`, with `min <= default <= max` and `0 < step <= max - min`. Reject zero, negative values, NaN, infinity and old percentage values such as `100`. Round target arithmetic to avoid accumulated floating-point drift.
- Validate the explicit X11 display, absolute authority-file path and output selector. Confirm the selected output is connected and active before applying anything. Never choose the first output as a substitute. Remove the obsolete `JUKEBOX_DDC_BUS` and `JUKEBOX_DDC_TIMEOUT_MS` from examples; document replacement of the old brightness block, including its old units. Reject a leftover `ddcutil` backend with an actionable migration message.
- Keep bad optional-hardware configuration from crashing the whole Phoenix/audio application. Surface explicit configuration errors and disable the affected subsystem. Do not hide them or guess substitutes.
- A restart of `jukebox.service` reloads mappings; recompiling assets must not be necessary.
- Do not expose the complete env file, arbitrary executable commands, or secrets in the browser/logs.

## 5. Input correctness and lifecycle

Read Linux evdev events in a blocking/event-driven loop, with no polling at animation frame rate. Process only the selected device and `EV_KEY`:

- `value=1`: key down; dispatch only for a new accepted press.
- `value=0`: key up; update state even if close to the previous press.
- `value=2`: kernel repeat; ignore.
- Ignore axes, hats and unassigned codes in V1. Tell the user to choose button terminals if an input reports `EV_ABS` instead.
- Keep per-code pressed state and monotonic-time debounce (default 80 ms). Ignore duplicate down reports; require a release before another press. Debounce must not leave a button stuck down by discarding its release. No long-hold repeat, including brightness, in V1.
- On connect/reconnect, inspect active keys and suppress already-held keys until release; do not interpret connection as a press. Handle `SYN_DROPPED` by discarding through `SYN_REPORT` and resynchronising key state without synthesising actions.
- Device missing, unplugged or temporarily inaccessible: expose status, retry with bounded backoff, close old handles. No boot failure, busy loop or log flood. Permission failures are diagnostics, never grounds for `sudo` or broad `chmod` from application code.
- No automatic exclusive grab in V1. If added later, make it opt-in and test that emergency keyboard access is unaffected.
- While power mode is not `awake`, discard all eight actions; never queue them for resume. Unknown/unavailable power status is fail-closed. A button held across a power transition must be released before it can trigger again.
- Keep the input reader responsive while remote actions/xrandr run. Use bounded per-backend queues; expire stale music actions, serialise toggles, and coalesce brightness targets. Do not auto-retry non-idempotent toggles after an uncertain result.

## 6. Acer V173 software brightness implementation

Use `/usr/bin/xrandr` as user `jukebox`, without sudo, a shell command string, or a browser dependency. Invoke with a validated argument array, for example `["--output", "HDMI-1", "--brightness", "0.7"]`. Supply child-process environment `DISPLAY`, `XAUTHORITY` from the runtime settings and `LC_ALL=C`. Do not assume systemd inherits the graphical login environment.

This adjusts the gamma ramp of the entire X11 output; it does **not** control the monitor's backlight, change its on-screen menu value, or guarantee lower power consumption. Coefficient `1.0` means neutral software dimming, not maximum physical backlight. Label diagnostics accordingly. No CSS overlay, per-tab state or `localStorage`. Preserve resolution, refresh rate, output enablement and RGB gamma settings.

Manual reference commands, already validated for image dimming/restoration by the user:

```sh
DISPLAY=:0 XAUTHORITY=/home/jukebox/.Xauthority xrandr --query
DISPLAY=:0 XAUTHORITY=/home/jukebox/.Xauthority \
  xrandr --output HDMI-1 --brightness 0.7
DISPLAY=:0 XAUTHORITY=/home/jukebox/.Xauthority \
  LC_ALL=C xrandr --verbose
DISPLAY=:0 XAUTHORITY=/home/jukebox/.Xauthority \
  xrandr --output HDMI-1 --brightness 1.0
```

Use a dedicated asynchronous worker with the following lifecycle:

1. Initialize the desired coefficient from `JUKEBOX_BRIGHTNESS_DEFAULT` on a full Phoenix start. When Power is awake and X11 is ready, apply it. Phoenix may start before X11: use bounded backoff, recover automatically when it becomes ready, and never block the application or audio startup.
2. Keep desired brightness in shared server memory independent of LiveView and the external-command worker. A browser restart or worker restart must not reset it. No SD persistence is required in V1: a full Phoenix restart or Pi reboot returns to the configured default, initially `1.0`. Document how to set a darker startup value such as `0.7`.
3. Each accepted press adjusts the desired value by `0.1`, clamped to `0.3`–`1.0` by default. At most one xrandr process may run at a time. Coalesce rapid presses for 150–250 ms into the final target; do not create an unbounded queue or run at audio-analysis frequency.
4. Enforce a real process deadline, default 3000 ms, for queries and writes. On timeout terminate and reap the external process; timing out an Elixir Task alone is insufficient. Handle missing executable, X authorization errors, inactive/missing output and command failure separately. Do not fake success.
5. Check the exit status, then read `/usr/bin/xrandr --verbose` and parse `Brightness:` **only inside the exact selected output's block**, using the C locale. Account for gamma-ramp quantization with a documented small tolerance, e.g. 0.02. Keep requested/pending and confirmed software coefficients distinct. Never label this as a hardware brightness readback.
6. During standby, shutdown or unknown/stale Power state, discard button requests and cancel queued work; retain the last accepted desired coefficient in RAM. Stop in-flight work where practical without delaying Power transitions. No retries may wake the display or alter its power mode. Once awake and X11 is ready again, reapply the saved desired value instead of resetting to `1.0`.
7. Recover from an X11 restart or lost gamma state while awake. A lightweight availability/readback check no more often than once per 10 seconds while healthy is sufficient; serialize it with other work, skip it in standby and back off on errors. Reapply only after detecting a reset/mismatch or on an awake transition, not continuously. Bound and rate-limit repeated failures. Manual test commands can be overwritten by this reconciliation; document temporarily selecting `disabled` to isolate such tests.
8. Invalid configuration disables only this optional subsystem and reports the reason. Do not add broad bus scans, DDC fallback, root commands, `xhost +` or changes to GPIO/boot configuration. If systemd isolation hides `.Xauthority` or the X11 socket, document a narrowly scoped access fix rather than removing all sandboxing.

Keep DPMS separate: the existing Power controller owns sleep/wake. Do not substitute brightness `0`, `xrandr --off`, or monitor power commands for standby. Software dimming must not flash/pulse in response to music; leave audio-reactive effects inside the application. This change does not require new screen wiring, DDC/I2C packages or permissions, or GPIO allocation. Existing DDC packages may remain installed but are unused.

## 7. Bridge to the existing independent Power controller

The installation guide's phase 11 currently supplies a root-owned Python daemon at `/usr/local/sbin/jukebox-power-controller.py`, service `jukebox-power-controller.service`, and a local UNIX datagram socket `/run/jukebox/power-control.sock`.

It accepts `disco toggle`, `strip toggle`, `decor toggle`, `extra toggle`, `standby on|off|toggle`, and `shutdown`. Its CLI only sends a datagram: a zero exit status does **not** currently prove the GPIO changed. It has no queryable standby state. Do not pretend this missing state API exists; implement it as a required part of this integration.

Import/refactor that controller into `ops/hardware/jukebox-power-controller.py` and ship its systemd unit and an idempotent installer `ops/hardware/install-power-controller.sh`. Keep the public CLI commands and Power semantics compatible:

- Short press: standby/resume.
- Hold at least 3 seconds **then release**: clean shutdown.
- GPIO3 hardware press after HALT: full boot, independent of Phoenix.
- Active-high outputs remain amp GPIO17, disco GPIO27, strip GPIO22, decor GPIO23, extra GPIO24. Initial outputs off; amplifier resumes after a cancellable 1.5-second delay.

Required additions/hardening:

- Publish controller state atomically to `/run/jukebox-power/state.json`, root-owned and readable by group `jukebox` (directory 0750, file 0640), including schema version, instance ID, increasing revision, controller PID, `mode` (`booting|awake|standby|shutting_down`), requested output states and applied GPIO levels. Publish a heartbeat at most once per second in `/run` (RAM), so stale files cannot look live indefinitely. Include a documented freshness marker and treat state stale after 3 seconds. No writes to the microSD for heartbeats.
- Phoenix reads/watches this state independently of LiveView. Verify safe ownership and schema. Unknown/stale state blocks ordinary controls; it never wakes the machine automatically. Delete/invalidate state on clean daemon exit. Reconcile after daemon restart.
- Readback means the daemon commanded the GPIO, not proof of lamp current or physical amplifier power; label that distinction honestly.
- Return command errors clearly. Do not report lights confirmed until the controller's resulting state is observed. Avoid retrying an unacknowledged `toggle`; if implementing acknowledgements, include request IDs and duplicate suppression.
- Serialize state transitions in the controller. Delayed startup/wake callbacks must be cancelled on standby, SIGTERM or shutdown; they must never re-enable outputs after shutdown starts. Do not sleep in the button input callback.
- Keep GPIO3 detection responsive when Phoenix, X11 or xrandr fails. Bound xset and application-readiness waits. A failed socket worker must not leave a silently broken daemon considered healthy.
- Safely create the existing socket directory without changing the audio analyser's `/run/jukebox` permissions/ownership or deleting its socket. Use a separate runtime directory for new power state; preserve the legacy socket path and group access.
- Root executable, unit and installer-installed helpers must be root-owned and not writable by `jukebox`. Do not source the application's user-editable env as root shell code. Never execute arbitrary browser-provided commands.
- Installer validates syntax, saves dated backups, replaces only its own files, leaves audio/env/boot configuration untouched, and documents rollback. Restart controller only as an explicit deployment step, with power loads disconnected for initial validation.

Do not silently add a new audio pause-on-standby policy: currently standby mutes via amplifier power while AirPlay can continue. Explain this behaviour; independent Power operation must not depend on an iPhone responding.

## 8. Lights and WLED

Default `JUKEBOX_STRIP_CONTROL=power`: call the existing power client's `strip toggle`. WLED is physically restarted when the rail comes back; document the delay. `disco_toggle` always uses the power controller.

Optional `JUKEBOX_STRIP_CONTROL=wled`: keep the strip/controller rail powered while awake; use the configured trusted LAN `JUKEBOX_WLED_URL` and WLED JSON state API for normal on/off. Read actual WLED state and send an explicit boolean target, serialize requests, bound timeouts, and reconcile after restart. General standby still removes power through GPIO22. Never automatically fall back to power toggling when WLED times out. After wake wait for WLED to reconnect and restore the last requested state in RAM; a brief boot flash may depend on WLED's configured boot preset and cannot be prevented purely by Phoenix. No new music-driven LED feature is required here.

Never use GPIO PWM on amplifier or USB gadget supplies to simulate music reactivity. Leave their internal effects alone; do not drive X11 brightness at music-analysis frequency either.

## 9. Permissions, diagnostics and delivery

Use Debian packages `python3-evdev`, `evtest`, `x11-xserver-utils` (provides xrandr and may already be installed). No DDC/I2C packages or permissions are required for brightness. User `jukebox` needs access to the selected input device and its own existing X11 session. Prefer a specific udev grant where practical; documented membership of `input` is acceptable for this dedicated appliance. No world-writable device nodes, `xhost +`, or passwordless arbitrary sudo. Respect existing systemd sandbox settings and diagnose unavailable X sockets/authority files rather than disabling protections wholesale.

Provide these stable public diagnostics (use this module name or clearly update the guide if repository naming requires a different one):

```elixir
Jukebox.Hardware.status()
```

Return sanitised effective mapping, selected device identity, source connection, last accepted code/action, malformed/unassigned counts, power mode/freshness, confirmed/requested light states, brightness backend, X11 display/output/readiness, configured bounds/default, desired/applied software coefficient and recent error. No secrets or X authority contents. Expose the same useful state in the existing simulator/admin diagnostics without a public unauthenticated hardware command endpoint.

Provide a diagnostic helper mode:

```sh
/usr/bin/python3 priv/hardware/xinmo_evdev.py --device /actual/event/symlink --diagnose
```

It prints names, numeric codes and press/release/repeat events and dispatches **no actions**. Include a copyable env-mapping template, without pretending example values are measured hardware values.

Deliver application code, helpers packaged in the release, the controller migration/installer/unit, simulator adapters, unit tests, updated env example and installation instructions. Physical buttons remain disabled until commissioning; the brightness example uses the validated xrandr configuration with a neutral default. Separate automated development tests, the user's successful manual dimming test, and the integration tests still required on the Pi.

## 10. Acceptance tests

Automated with fake input/transport/power/xrandr adapters:

- env parsing, blank mappings, duplicates, invalid codes and unavailable optional dependencies;
- press/release yields one action; repeated downs, value 2, contact bounce and long holds do not duplicate it;
- independent simultaneous buttons, disconnect/reconnect with a held key, SYN_DROPPED resync;
- animation wraps through existing modes once, irrespective of browser count;
- no music command replay after reconnect; no uncontrolled retry of toggles;
- brightness decimal parsing/clamping, invalid old percentages/NaN/infinity, malformed multi-output replies, selected-output readback tolerance/mismatch, process timeout/cleanup and rapid-press coalescing;
- exact executable/argument-array/child-env construction with no shell execution; no root commands or changes to resolution, output enablement or DPMS;
- Phoenix starts before X11, X authorization failure, output missing/inactive, X11 restart, worker restart, standby/resume retains the desired factor, full Phoenix restart restores the configured default;
- stale power state, standby mid-command, shutdown during startup/amplifier delay: no late output re-enable;
- Power daemon still works without Phoenix; no duplicate GPIO owner;
- WLED failure never changes power backend implicitly;
- install/rollback and release packaging do not delete audio binaries/sockets or replace env secrets.

The user has already confirmed visible dimming with the manual xrandr command. On-device **application integration** checks remain pending until performed: map all eight real codes, brightness steps/clamps/readback, service-user X11 access, startup before X11, keyboard focus independence, two browser tabs, hot unplug/replug Xin-Mo, missing X11/output, standby/resume coefficient restoration, default after Phoenix restart/reboot, long-press shutdown and GPIO3 restart, power control with Phoenix stopped, no audio glitches during repeated brightness changes, and acceptable Pi 2 CPU/RAM usage. Do not claim these checks passed based on the manual test alone.

## Primary references

- xrandr manual, especially software-only `--brightness`: https://manpages.debian.org/testing/x11-xserver-utils/xrandr.1.en.html
- Linux input event semantics: https://docs.kernel.org/input/event-codes.html
- python-evdev: https://python-evdev.readthedocs.io/en/stable/tutorial.html
- WLED JSON API: https://kno.wled.ge/interfaces/json-api/
