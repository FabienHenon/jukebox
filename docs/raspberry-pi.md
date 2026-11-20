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

Keep `publish_raw` on. It is what publishes the bundle markers (`ssnc/mdst`
and `ssnc/mden`) that let the jukebox treat a track change as one update, plus
the track duration and persistent id. Shairport Sync replaces empty payloads
with `--` (`mqtt.empty_payload_substitute`); the jukebox expects that default.

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
| `JUKEBOX_COALESCE_MS` | `150` | how long a burst of metadata messages is buffered before the screen updates once (0 disables) |
| `JUKEBOX_ANIMATION_STYLE` | `chase` | animation style until the animation button has chosen another: `calm`, `waves`, `chase` or `party`. The last choice is saved and wins at the next boot |
| `JUKEBOX_STATE_DIR` | `/var/lib/jukebox` | where the last chosen animation style is saved (file `animation_style`). The unit creates it with `StateDirectory=jukebox`; delete the file to return to `JUKEBOX_ANIMATION_STYLE` |
| `JUKEBOX_ANIMATION_BPM` | `120` | tempo of the `chase` and `party` lights, 40 to 240, when the audio is not analysed or the beat is not clear |
| `AUDIO_REACTIVE_ENABLED` | `false` | follow the music being played; needs the ALSA tap and the native analyser, see [audio-reactive-setup.md](audio-reactive-setup.md) |
| `AUDIO_REACTIVE_SOURCE` | `native` | `native`, `simulated` (made-up music) or `disabled` |
| `AUDIO_ANALYSIS_SOCKET` | `/run/jukebox/audio-analysis.sock` | Unix datagram socket the analyser sends to |
| `AUDIO_ANALYSIS_PUBLISH_RATE` | `20` | most analysis frames per second sent to the browser, 1 to 20 |
| `AUDIO_VISUAL_DELAY_MS` | `120` | how long the browser holds a frame before showing it, 0 to 1000 (the env template sets 0; see "Calibrating" in the audio guide) |
| `AUDIO_BEAT_CONFIDENCE_THRESHOLD` | `0.45` | beat-tracking confidence, 0 to 1, below which the fixed tempo drives the lights |
| `JUKEBOX_BUTTONS_*`, `JUKEBOX_BUTTON_*`, `JUKEBOX_BRIGHTNESS_*`, `JUKEBOX_XRANDR_OUTPUT`, `JUKEBOX_X11_*`, `JUKEBOX_POWER_*`, `JUKEBOX_STRIP_CONTROL`, `JUKEBOX_WLED_URL` | buttons off | buttons, monitor brightness and lights: see [physical-controls.md](physical-controls.md#7-environment-reference) |

Invalid local values (a non-numeric port, an unknown adapter name) fail fast
at boot with a readable message. Unreachable services do not. The variables of
the physical controls are the exception: they describe optional hardware, so a
wrong value there never stops the service. It disables the buttons, the
brightness or the strip control, and says why in the journal.

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

## 6. Physical buttons, brightness and lights

The eight buttons are not wired to the GPIO header: they go to a USB button
encoder, read on the server through Linux evdev. Together with the screen
brightness (X11 software dimming with `xrandr`; the HDMI-to-VGA adapter
carries no DDC) and the lights they are described, installed and commissioned
in [physical-controls.md](physical-controls.md).

The buttons are disabled until they have been set up on the Pi itself
(`JUKEBOX_BUTTONS_ENABLED=false`): no key code or input device is assumed.
The example environment file selects the `xrandr` brightness backend with the
output measured on this jukebox (`HDMI-1`) and a neutral start (`1.0`); if X11
is not there the jukebox starts all the same.

The older boundary is still there for development and tests:
`Jukebox.Inputs.Fake` injects semantic commands into
`Jukebox.Commands.dispatch/1`, and `Jukebox.Inputs.Noop` is what production
uses for it.

## 7. Power button

The Power button (GPIO3, physical pin 5, to GND on pin 6) is handled by a
separate root service, the power controller, never by Phoenix: short press for
standby and resume, a press held three seconds for a clean shutdown, and a
press while halted to boot. The same service owns the amplifier and light
outputs. See [physical-controls.md](physical-controls.md#3-power-controller).

The controller replaces the `gpio-shutdown` overlay. Do **not** keep

```
dtoverlay=gpio-shutdown
```

in `/boot/firmware/config.txt` once the controller is installed: both would
claim GPIO3, and the overlay shuts the Pi down on a short press. Without the
controller, that overlay alone still gives a plain shutdown/boot button.

## Audio-reactive animation (optional)

The display can follow the music actually being played (loudness, bass,
beats). It needs an ALSA tap in front of the DAC and a small native analyser,
and it is off by default. Set it up only once everything above works, with
[audio-reactive-setup.md](audio-reactive-setup.md); that guide also gives the
one command that returns Shairport Sync to direct DAC output.

## 8. Troubleshooting

| Symptom | Where to look |
| --- | --- |
| "Receiving music…" flashes or the cover is missing after a track change | `publish_raw` must be `"yes"` (bundle markers); check that `ssnc/mdst` and `ssnc/mden` appear in `mosquitto_sub`; raise `JUKEBOX_COALESCE_MS` if the sender delivers its metadata slowly |
| Idle screen never changes when playing | `mosquitto_sub -t 'jukebox/shairport/#' -v`; Shairport `mqtt` block; `journalctl -u shairport-sync` |
| "Reconnecting…" on the screen | broker down or `JUKEBOX_MQTT_HOST/PORT` wrong; `journalctl -u jukebox` shows the backoff |
| Buttons show "Control unavailable" | `enable_remote` not set, `JUKEBOX_REMOTE_CONTROL_ENABLED=false`, or the sender does not support DACP |
| A physical button does nothing, or "Brightness unavailable", "… not confirmed" | [physical-controls.md, Diagnostics](physical-controls.md#8-diagnostics) |
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
- the physical buttons, the screen brightness, the lights and the power
  controller (see the checklist at the end of
  [physical-controls.md](physical-controls.md#11-tested-and-still-to-test));
- audio output through the DAC;
- boot automation, screen blanking and Chromium kiosk behaviour;
- the audio-reactive animation beyond the application itself: the ALSA tap,
  the native analyser on ARMv7 and the timing of the lights against the sound
  (see the checklist in [audio-reactive-setup.md](audio-reactive-setup.md));
- the Power button, standby and clean shutdown.
