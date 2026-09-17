# Running the Jukebox on a Raspberry Pi 3

This guide covers the Raspberry Pi side of the project: the operating-system
services around the Phoenix release, the expected service ordering, and the
integration points that are still hardware dependent. The application itself is
described in the [README](../README.md).

Nothing here is applied automatically by the web application. Every step is a
template you review and install yourself.

## Service layout

```
power button ──> Raspberry Pi OS boot
                    │
                    ├── mosquitto        local MQTT broker, loopback only
                    ├── shairport-sync   AirPlay receiver -> ALSA/DAC, metadata -> MQTT
                    ├── jukebox          Phoenix release (this repository), 127.0.0.1:4000
                    └── kiosk session    Chromium in kiosk mode on the local URL
```

Expected ordering: network → `mosquitto` → `shairport-sync` → `jukebox` →
kiosk session. The ordering is only a nicety. Each service is independent:

- **Audio never depends on the display.** Shairport Sync plays audio to the
  DAC whether or not Phoenix or Chromium are running. Restarting the jukebox
  service or the browser does not interrupt playback.
- **The jukebox never depends on the broker or Shairport Sync.** If they are
  down or start later, the kiosk shows the idle screen and reconnects with
  bounded exponential backoff (0.5 s → 30 s). It logs at warning level, never
  crash-loops, and never shows an error page.
- **Phoenix and Chromium are independently restartable.** The Chromium
  launcher waits for Phoenix, and LiveView reconnects on its own when Phoenix
  restarts; the OTP process keeps the playback state, so the screen comes back
  where it was.

## 1. System packages

```sh
sudo apt update
sudo apt install mosquitto chromium-browser unclutter
```

Shairport Sync from the Debian repository may be built without the MQTT
backend. Check with `shairport-sync -V`; the output must list `mqtt` and
`metadata`. If it does not, build it from source with
`./configure --with-alsa --with-avahi --with-ssl=openssl --with-metadata --with-mqtt-client --with-systemd`
(see the upstream BUILD guide for the full dependency list).

## 2. Mosquitto (local broker)

```sh
sudo cp ops/mosquitto.conf.example /etc/mosquitto/conf.d/jukebox.conf
sudo systemctl enable --now mosquitto
```

The broker binds to `127.0.0.1` only and does not persist anything, so no
metadata is ever written to the SD card.

## 3. Shairport Sync

Merge the sections of `ops/shairport-sync.conf.example` into
`/etc/shairport-sync.conf`. The important parts are the `metadata` block
(cover art enabled, no cover-art cache directory) and the `mqtt` block with
`publish_parsed`, `publish_cover`, `publish_raw` and `enable_remote` all set
to `"yes"`, publishing under the topic `jukebox/shairport`.

Pick the ALSA device for your DAC with `aplay -l` and set `alsa.output_device`.

```sh
sudo systemctl enable --now shairport-sync
```

Verify metadata reaches the broker (play something from the iPhone):

```sh
mosquitto_sub -h 127.0.0.1 -t 'jukebox/shairport/#' -v | cut -c1-120
```

### Remote control caveat

`enable_remote` makes Shairport Sync subscribe to `jukebox/shairport/remote`
and relay DACP commands (`previtem`, `playpause`, `nextitem`) to the sender.
Stable remote control targets Classic AirPlay senders; with AirPlay 2 it may
depend on the Shairport Sync build. The kiosk treats remote control as a
capability: when a command cannot be delivered it shows a subtle "Control
unavailable" hint and playback display keeps working. Set
`JUKEBOX_REMOTE_CONTROL_ENABLED=false` to disable the feature entirely.

The command vocabulary lives in one place, `lib/jukebox/shairport.ex`. If a
future Shairport release renames a command, change it there.

## 4. Building and installing the Phoenix release

Build on the Pi itself (or on a machine with the same architecture and OTP
version). With Elixir and Erlang installed:

```sh
git clone <this repository> /opt/jukebox-src && cd /opt/jukebox-src
export MIX_ENV=prod
mix deps.get --only prod
mix assets.deploy
mix release
sudo mkdir -p /opt/jukebox /etc/jukebox
sudo useradd --system --home /opt/jukebox --shell /usr/sbin/nologin jukebox 2>/dev/null || true
sudo cp -r _build/prod/rel/jukebox/. /opt/jukebox/
sudo chown -R jukebox:jukebox /opt/jukebox
```

Configuration is read from environment variables at boot
(`config/runtime.exs`). Copy and edit the template:

```sh
sudo cp ops/jukebox.env.example /etc/jukebox/jukebox.env
sudo chmod 600 /etc/jukebox/jukebox.env
# set SECRET_KEY_BASE to the output of: mix phx.gen.secret
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `SECRET_KEY_BASE` | required | Phoenix secret |
| `PHX_SERVER` | unset | set to `true` to start the HTTP server |
| `JUKEBOX_BIND` | `127.0.0.1` | bind address (`0.0.0.0` to allow LAN diagnostics) |
| `PORT` | `4000` | HTTP port |
| `JUKEBOX_METADATA_ADAPTER` | `mqtt` | `mqtt` or `demo` |
| `JUKEBOX_MQTT_HOST` / `JUKEBOX_MQTT_PORT` | `127.0.0.1` / `1883` | broker address |
| `JUKEBOX_MQTT_TOPIC` | `jukebox/shairport` | Shairport `mqtt.topic` |
| `JUKEBOX_MQTT_CLIENT_ID` | `jukebox-display` | MQTT client id |
| `JUKEBOX_MQTT_USERNAME` / `JUKEBOX_MQTT_PASSWORD` | unset | optional credentials |
| `JUKEBOX_REMOTE_CONTROL_ENABLED` | `true` | relay transport commands |
| `JUKEBOX_IDLE_TIMEOUT_MS` | `5000` | grace period before the idle screen |

Invalid local values (a non-numeric port, an unknown adapter name) fail fast
at boot with a readable message. Unreachable services do not.

Install the unit:

```sh
sudo cp ops/jukebox.service.example /etc/systemd/system/jukebox.service
sudo systemctl daemon-reload
sudo systemctl enable --now jukebox
journalctl -u jukebox -f
curl -s http://127.0.0.1:4000/ | head -c 300
```

## 5. Chromium kiosk session

Configure Raspberry Pi OS to auto-login into the desktop session
(`raspi-config` → System Options → Boot / Auto Login → Desktop Autologin).
Then install the launcher:

```sh
sudo cp ops/chromium-kiosk.example /usr/local/bin/jukebox-kiosk
sudo chmod +x /usr/local/bin/jukebox-kiosk
```

Start it from the graphical session with the systemd *user* unit or the
`.desktop` autostart entry documented at the top of that file. The launcher:

- waits until Phoenix answers, so the first thing on screen is the jukebox
  startup animation rather than a browser error;
- opens Chromium with `--kiosk`, no info bars, no translate prompts, no
  session-restore bubble, no pinch/overscroll gestures;
- disables screen blanking with `xset` (X11) and hides the cursor with
  `unclutter` as a second line of defence (the page itself hides the cursor
  and prevents selection and scrolling in production);
- relaunches Chromium automatically if it exits.

On the default Wayland (labwc) session of recent Raspberry Pi OS releases,
screen blanking is configured in `~/.config/labwc/rc.xml` (or through
`raspi-config` → Display Options → Screen Blanking → No) and the cursor can be
hidden with the compositor's cursor settings; `xset`/`unclutter` are simply
skipped when `DISPLAY` is not set.

Landscape orientation and resolution are set at the OS level (Screen
Configuration tool or `/boot/firmware/cmdline.txt` `video=` parameter). The
page is fluid and tested at 1920×1080, 1280×720 and 1024×600.

## 6. Physical buttons (GPIO)

Version one ships with the no-op input adapter (`Jukebox.Inputs.Noop`). The
boundary for the real buttons is ready:

- `Jukebox.Input` – the behaviour (`child_spec/1`); the adapter is a
  supervised process under `Jukebox.Integrations`.
- `Jukebox.Input.Debounce` – pure per-command debouncer (80 ms default) that
  the GPIO adapter must apply at the edge, exactly like `Jukebox.Inputs.Fake`.
- `Jukebox.Commands.dispatch/1` – the single entry point for the semantic
  commands `:previous_track`, `:toggle_playback`, `:next_track`.

A future `Jukebox.Inputs.Gpio` (for example on top of `circuits_gpio`, not
added yet because it was not verifiable without the hardware) should read its
mapping from configuration rather than hard-coding pins:

```elixir
# config/runtime.exs (prod), example only
config :jukebox, :input,
  {Jukebox.Inputs.Gpio,
   pins: [previous_track: 17, toggle_playback: 27, next_track: 22],
   pull: :up, active: :low, debounce_ms: 80}
```

Suggested wiring (BCM numbering): buttons between the pin and ground with the
internal pull-up enabled; a press reads as a falling edge. Long presses are out
of scope for version one.

## 7. Power button

The physical power button is handled by the OS, not by Phoenix. Raspberry Pi
OS supports a wake/shutdown button on GPIO 3 (pin 5) through the
`gpio-shutdown` device-tree overlay:

```
# /boot/firmware/config.txt
dtoverlay=gpio-shutdown,gpio_pin=3,active_low=1,gpio_pull=up
```

Shorting GPIO 3 to ground powers the Pi on from halt and triggers a clean
shutdown while running. The application never touches this button.

## 8. Troubleshooting

| Symptom | Where to look |
| --- | --- |
| Idle screen never changes when playing | `mosquitto_sub -t 'jukebox/shairport/#' -v`; Shairport `mqtt` block; `journalctl -u shairport-sync` |
| "Reconnecting…" on the screen | broker down or `JUKEBOX_MQTT_HOST/PORT` wrong; `journalctl -u jukebox` shows the backoff |
| Buttons show "Control unavailable" | `enable_remote` not set, `JUKEBOX_REMOTE_CONTROL_ENABLED=false`, or the sender does not support DACP |
| Artwork missing | sender did not send cover art, or the image exceeded 2 MB / was not JPEG/PNG (logged as a warning) |
| Browser shows a Chromium error page | Phoenix not up yet; the launcher retries, or check `systemctl status jukebox` |

## 9. What has not been verified on hardware

This repository was developed and tested on a workstation with the demo
adapters and the simulator. The following remain to be verified on the
Raspberry Pi with real hardware:

- Shairport Sync → Mosquitto → Phoenix metadata flow with a real iPhone and
  YouTube Music (topic names and payload formats follow the Shairport Sync
  4.x MQTT backend documentation and source);
- DACP remote control through `jukebox/shairport/remote`;
- GPIO button input (no adapter shipped yet);
- audio output through the DAC;
- boot automation, screen blanking and Chromium kiosk behaviour;
- the power button overlay and clean shutdown.
