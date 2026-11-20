# Physical controls: buttons, screen brightness, lights

This guide covers the eight buttons on the USB encoder, the brightness of the
screen (X11 software dimming with `xrandr`), the lights behind the power
controller, and the power controller itself. The buttons are **off by
default** and stay off until they have been commissioned on the Raspberry Pi:
no key code, input device or USB id is assumed anywhere.

The application's code has not been run on a Raspberry Pi yet. The last
section keeps three things apart: what was verified automatically on the
development machine, the one manual test already done on the jukebox (the
`xrandr` command dims the picture), and the integration checks that remain.

- [1. Who owns what](#1-who-owns-what)
- [2. Packages and permissions](#2-packages-and-permissions)
- [3. Power controller](#3-power-controller)
- [4. Buttons](#4-buttons)
- [5. Screen brightness](#5-screen-brightness)
- [6. Lights and WLED](#6-lights-and-wled)
- [7. Environment reference](#7-environment-reference)
- [8. Diagnostics](#8-diagnostics)
- [9. How it behaves](#9-how-it-behaves)
- [10. Development without the hardware](#10-development-without-the-hardware)
- [11. Tested, and still to test](#11-tested-and-still-to-test)

## 1. Who owns what

```
USB encoder ──> xinmo_evdev.py ──> Jukebox.Inputs.Evdev ──> Jukebox.Hardware.Buttons
 (8 buttons)     (helper, port)                               │ debounce, mapping,
                                                              │ "is the jukebox awake?"
                                                              v
                                                       Jukebox.Commands
                       ┌──────────────────┬──────────────────┴──────┬──────────────────┐
                       v                  v                         v                  v
              Shairport remote     Jukebox.Animation      Jukebox.Hardware.Lights   Jukebox.Hardware.Brightness
              previtem/playpause/  (style, broadcast      │ power client   │ WLED     │ xrandr --output HDMI-1
              nextitem             to every display)      v                v          v          --brightness 0.7
                                                    power controller    WLED      X11 output (gamma ramp)

Power button (GPIO3) ──> jukebox-power-controller (root) ──> amplifier + light GPIO, DPMS, shutdown
                                   │
                                   └──> /run/jukebox-power/state.json ──> Jukebox.Hardware.Power.Monitor
```

| Component | Owns |
| --- | --- |
| `priv/hardware/xinmo_evdev.py` + `Jukebox.Inputs.Evdev` | the one selected Linux input device, its raw events, reconnection |
| `Jukebox.Hardware.Buttons` | debounce, code-to-action mapping, the standby rule, handing commands on |
| `Jukebox.Hardware.Brightness` | `xrandr` requests to the selected X11 output and their verification, one at a time |
| `Jukebox.Hardware.Lights` | light requests to the power controller or to WLED, and their confirmation |
| `jukebox-power-controller` (root, separate service) | GPIO3 and every power GPIO, display sleep, shutdown |
| Phoenix / LiveView | showing the shared state and the feedback of a press |

Consequences worth knowing:

- The buttons are read **on the server**, by one process. The browser is not
  involved: Chromium does not need the focus, and two open tabs do not double
  an action. There is no Gamepad or keyboard listener for them in the page (the
  page never had one; the development keyboard shortcuts are compiled out of
  production builds).
- The **Power button is not one of the eight** and does not go through Phoenix
  at all. Standby and shutdown work with Phoenix or Chromium stopped.
- Phoenix runs as the user `jukebox` and never opens a GPIO line.

### The eight actions

| Action | Variable | What it does |
| --- | --- | --- |
| `previous` | `JUKEBOX_BUTTON_PREVIOUS` | Shairport remote command `previtem` |
| `play_pause` | `JUKEBOX_BUTTON_PLAY_PAUSE` | Shairport remote command `playpause` |
| `next` | `JUKEBOX_BUTTON_NEXT` | Shairport remote command `nextitem` |
| `disco_toggle` | `JUKEBOX_BUTTON_DISCO_TOGGLE` | power client `disco toggle` (disco ball and illuminated panel, one group) |
| `strip_toggle` | `JUKEBOX_BUTTON_STRIP_TOGGLE` | power client `strip toggle`, or WLED (section 6) |
| `animation_next` | `JUKEBOX_BUTTON_ANIMATION_NEXT` | next animation style (calm → waves → chase → party → calm), on every display |
| `brightness_down` | `JUKEBOX_BUTTON_BRIGHTNESS_DOWN` | software brightness coefficient minus `JUKEBOX_BRIGHTNESS_STEP` |
| `brightness_up` | `JUKEBOX_BUTTON_BRIGHTNESS_UP` | software brightness coefficient plus `JUKEBOX_BRIGHTNESS_STEP` |

## 2. Packages and permissions

```sh
sudo apt install python3-evdev evtest x11-xserver-utils python3-gpiozero
```

`python3-evdev` is used by the input helper, `x11-xserver-utils` provides
`xrandr` (it is probably installed already, the kiosk uses `xset` from the same
package), `python3-gpiozero` is used by the power controller, and `evtest` is
only for checking things by hand. Brightness needs **no** DDC or I2C package,
group or kernel module; `ddcutil` and `i2c-tools` may stay installed, they are
not used.

The service user needs to read the encoder:

```sh
getent group input               # the group must exist
sudo usermod -aG input jukebox
sudo systemctl restart jukebox   # group membership is read when the service starts
```

- Narrower than the `input` group, once you know the encoder's USB ids (read
  them with `udevadm info -a /dev/input/by-id/<link>`, do not copy them from
  the internet), is a udev rule that grants only that device. Replace the
  placeholders with the values you read:

  ```
  # /etc/udev/rules.d/70-jukebox-buttons.rules
  SUBSYSTEM=="input", KERNEL=="event*", ATTRS{idVendor}=="<vvvv>", ATTRS{idProduct}=="<pppp>", GROUP="jukebox", MODE="0640"
  ```

- For brightness the service talks to **its own user's** X session: the kiosk
  runs as `jukebox`, and so does the service. It needs nothing but the X
  socket (`/tmp/.X11-unix/X0`) and the authority file
  (`/home/jukebox/.Xauthority`), both of which that user can already reach. No
  `xhost +`, no `sudo`, no world-writable device node; the application never
  changes permissions and never runs as root.
- If your installed `jukebox.service` isolates the service, give back exactly
  what is needed instead of removing the protection:

  | Setting in the unit | Effect | Narrow fix |
  | --- | --- | --- |
  | `PrivateTmp=yes` | hides `/tmp/.X11-unix` (reported as `x11_unavailable`) | `BindReadOnlyPaths=/tmp/.X11-unix` |
  | `ProtectHome=yes` or `tmpfs` | hides the authority file (reported as `xauthority_missing`) | `BindReadOnlyPaths=/home/jukebox/.Xauthority` |
  | `PrivateDevices=`, `DevicePolicy=`, `DeviceAllow=` | hides the encoder | `DeviceAllow=char-input r` |

  The unit shipped in `ops/jukebox.service.example` has none of these.
- Do not add `dtparam=i2c_arm=on` and do not wire anything of the monitor to
  the GPIO header: GPIO3 is the Power button.

## 3. Power controller

`ops/hardware/jukebox-power-controller.py` is both the root service and its
command-line client.

It is the controller of the installation guide (phase 11) with the additions
the application needs. Pins, commands, press durations, the socket and the
starting state are those of the original, and a test drives both programs
with the same random sequences of commands and button presses and compares
every output and every display command
(`test/hardware/test_power_controller_compat.py`, the original being kept in
`test/hardware/fixtures/` for that purpose only).

What it does:

| | |
| --- | --- |
| Power button, GPIO3 (pin 5) to GND (pin 6) | short press: standby / resume. Held 3 s or more **then released**: clean shutdown. Pressed while the Pi is halted: the Pi boots (firmware feature, no software involved) |
| Outputs, active-high, all low when the service starts | amplifier GPIO17, disco GPIO27, strip GPIO22, decor GPIO23, extra GPIO24 |
| Requested at start | amplifier, strip, decor and extra **on**; disco **off**. In memory only: a restart of the service or of the Pi returns to this |
| Lights | on when requested **and** awake. A standby keeps the requests and applies them again on resume; a command received during standby changes the request and takes effect on resume |
| Amplifier | on 1.5 s after the jukebox becomes awake (if requested); the delay is cancelled by a standby, a shutdown or a stop |
| Display | `xset dpms force off` / `on` in the kiosk's X session (`DISPLAY=:0`, `XAUTHORITY=/home/jukebox/.Xauthority`) and nothing else: the kiosk's `.xinitrc` keeps DPMS enabled with zero timeouts, so the screen only sleeps when told to |
| At boot | mode `booting`, everything low, until `http://127.0.0.1:4000/` answers, then `awake` |

What changed compared with the original, on purpose:

| Original | Now | Why |
| --- | --- | --- |
| no way to know its state | publishes `/run/jukebox-power/state.json` | the application must know whether the jukebox is awake, and what was really commanded |
| the client sends and exits 0 | the client waits for the controller's answer and its exit status says what happened; a plain-text datagram is still accepted | exit 0 used to prove nothing |
| `time.sleep(1.5)` before the amplifier, in the caller's thread | a timer, cancelled by a standby, a shutdown or a stop | a late wake-up could switch the amplifier on after a standby had begun; the Power button's thread no longer sleeps |
| waits for Phoenix for ever at boot | stops waiting after 90 s (`--ready-timeout`) and becomes awake | amplifier and lights must not depend on Phoenix |
| `xset` without a time limit, in the button's thread | 3 s limit, in a thread of its own | X must never hold up the Power button |
| an output command sent before Phoenix answers lights its lamp at once | the request is kept and applied when the jukebox becomes awake | one rule for every mode |
| commands after a shutdown began are silently pointless | they are refused (exit status 2) | say so |
| a second copy would delete the first one's socket | a second copy refuses to start | one owner of the GPIO lines |
| socket directory created root-owned if missing | created for the `jukebox` user if missing, left untouched if present | the audio analyser's socket lives there too |
| `After=`/`Wants=jukebox.service`, `Type=simple` | no dependency on `jukebox.service`; `Type=notify` with a 10 s watchdog | independent of Phoenix; a stuck service is restarted |

Commands (unchanged; `status` is new):

```sh
jukebox-power-controller.py disco toggle      # also: strip, decor, extra, amp; and on | off
jukebox-power-controller.py standby on|off|toggle
jukebox-power-controller.py shutdown
jukebox-power-controller.py status            # prints the state, changes nothing
```

The client now waits for the controller's answer. Its exit status says what
happened: `0` done, `2` refused (the controller is shutting down), `3` no
answer in time (**unknown** whether it was applied; do not blindly send a
toggle again), `4` controller not reachable.

### Install

Two things must be true before the controller can claim GPIO3:

1. `/boot/firmware/config.txt` must **not** contain `dtoverlay=gpio-shutdown`
   (that overlay takes GPIO3 and shuts down on a short press) nor
   `dtparam=i2c_arm=on` (which gives GPIO3 to I2C). Remove them and reboot.
2. The older `jukebox-led-power.service` must be disabled; it drives GPIO17,
   which is now the amplifier: `sudo systemctl disable --now jukebox-led-power`.

The installer warns about both and changes neither.

```sh
cd /home/jukebox/src/jukebox-app
sudo sh ops/hardware/install-power-controller.sh             # install, restart nothing
sudo sh ops/hardware/install-power-controller.sh --restart   # install, then restart the controller
```

It checks the two files, keeps a dated copy of what it replaces
(`*.YYYYMMDD-HHMMSS.bak`, next to the original: the script you pasted from the
guide and the unit you wrote by hand are kept this way), installs
`/usr/local/sbin/jukebox-power-controller.py` and
`/etc/systemd/system/jukebox-power-controller.service` owned by root and not
writable by anyone else, reloads systemd and enables the unit. It does not
touch `/etc/jukebox/jukebox.env`, the boot configuration, the audio
configuration, `/run/jukebox` or `/opt/jukebox`.

**Without `--restart` the controller that is running stays the old one.**
Restarting drops every output for a moment, so it only happens when you ask:
with `--restart`, or yourself with `systemctl restart`. Do it the first time
with the amplifier and the lights **unplugged from their supplies**:

```sh
sudo systemctl restart jukebox-power-controller      # unless --restart was used
systemctl status jukebox-power-controller --no-pager
sudo -u jukebox cat /run/jukebox-power/state.json
sudo -u jukebox /usr/local/sbin/jukebox-power-controller.py status
```

Then, still without loads: a short press (the state file shows `standby`, the
monitor sleeps), another one (`awake`; `strip`, `decor` and `extra` show
`"applied": true`, `amp` follows 1.5 s later), `disco toggle` from the client
(`"applied": true` on `disco`), and only then plug the loads back in.

### Roll back

```sh
sudo sh ops/hardware/install-power-controller.sh --rollback
sudo systemctl restart jukebox-power-controller
```

### The published state

`/run/jukebox-power/state.json` lives in RAM (`/run`), is owned by
`root:jukebox` with mode `0640` in a `0750` directory, is replaced atomically
on every change and rewritten at least once per second. It is removed when the
service stops.

```json
{"schema": 1, "instance": "9f2c…", "revision": 12, "heartbeat": 3401,
 "boottime": 512.37, "pid": 431, "mode": "awake",
 "outputs": {"amp":   {"gpio": 17, "requested": true,  "applied": true},
             "disco": {"gpio": 27, "requested": true,  "applied": true},
             "strip": {"gpio": 22, "requested": false, "applied": false},
             "decor": {"gpio": 23, "requested": false, "applied": false},
             "extra": {"gpio": 24, "requested": false, "applied": false}}}
```

- `mode` is `booting`, `awake`, `standby` or `shutting_down`.
- `instance` changes at every start of the service; `revision` increases on
  every change, `heartbeat` on every write.
- **Freshness marker:** `boottime` is the kernel's seconds-since-boot clock
  when the file was written, the same clock as the first number of
  `/proc/uptime`. It does not jump when NTP sets the time of day. A reader
  compares the two and treats a state more than **3 seconds** old as stale.
- `applied` is the level the controller commanded on the GPIO and read back
  from it. It is not a measurement: it cannot tell that a lamp draws current
  or that the amplifier really has power.

Phoenix reads this file twice a second and before every decision. It refuses a
file or directory not owned by root or writable by anyone else, a symbolic
link, an unknown `schema`, a malformed document and a stale heartbeat. In all
of those cases the power mode is *unknown*, and unknown blocks the buttons
exactly like standby. Phoenix can never wake the jukebox up: the only commands
it is able to send are `disco toggle`, `strip toggle` and, in WLED mode,
`strip on`, and it sends none of them unless the jukebox is awake.

### Standby does not pause the music

Standby cuts the amplifier and the lights and puts the monitor to sleep. It
does **not** pause the iPhone: AirPlay can keep streaming, silently, and
Shairport Sync keeps playing into a powered-down amplifier. This is the
existing behaviour and it was kept on purpose, so that the Power button never
depends on a phone answering. Pause on the phone if you want the track to wait.

## 4. Buttons

### Find the device

Plug the encoder in and list the stable links:

```sh
ls -l /dev/input/by-id/
```

Use the link that ends in `-event-joystick` (or the matching one under
`/dev/input/by-path/`). Never use `/dev/input/eventN`: that number changes
from one boot to the next, and the application refuses it.

### Read the codes

```sh
sudo -u jukebox /usr/bin/python3 /home/jukebox/src/jukebox-app/priv/hardware/xinmo_evdev.py \
  --device /dev/input/by-id/<the link> --diagnose
```

(The same file is inside the release, at
`/opt/jukebox/lib/jukebox-<version>/priv/hardware/xinmo_evdev.py`.) Running it
as `jukebox` also proves that the service user may read the device.

It prints the device's name and ids, the key codes it advertises, then one
line per press, release and repeat. It sends nothing to the jukebox. Press the
eight buttons one after the other and note the `code=` of each. On Ctrl-C it
prints a template for the environment file in which the eight action lines
are deliberately empty.

Those codes are Linux `EV_KEY` codes in decimal. They are **not** joystick
button indices, GPIO numbers or the numbers printed next to the encoder's
terminals.

### One device, eight buttons

Version one reads **one** event device.

- A Xin-Mo dual-player encoder usually shows up as a single device whose
  buttons cover both "players"; all eight buttons can then go on any button
  terminals.
- If yours shows up as **two** devices (two `-event-joystick` links), wire all
  eight buttons to terminals of the *same* player, the one whose link you put
  in `JUKEBOX_BUTTONS_DEVICE`. `--diagnose` on each link tells which terminals
  belong to which device: a button whose press prints nothing belongs to the
  other one.
- A button that makes `--diagnose` print "axis … moved" is on a
  joystick-direction terminal. Axes are ignored: move it to a button terminal.

### Configure

In `/etc/jukebox/jukebox.env` (the file is an `EnvironmentFile`: `NAME=value`,
no `export`, no quotes needed):

```ini
JUKEBOX_BUTTONS_ENABLED=true
JUKEBOX_BUTTONS_SOURCE=evdev
JUKEBOX_BUTTONS_DEVICE=/dev/input/by-id/<the link>
JUKEBOX_BUTTON_PREVIOUS=<code you read>
…
```

```sh
sudo systemctl restart jukebox
journalctl -u jukebox -b | grep -E '\[(hardware|buttons|power)\]'
```

A restart is all it takes; nothing is rebuilt. Set
`JUKEBOX_BUTTONS_DEBUG=true` for a while to see every key event and what was
decided, then set it back.

## 5. Screen brightness

The Acer V173 is connected by its VGA input through an HDMI-to-VGA adapter,
which does not carry DDC/CI: the monitor's backlight cannot be commanded from
the Pi. The brightness buttons therefore use **X11 software dimming**:

```sh
xrandr --output HDMI-1 --brightness 0.7
```

Be clear about what that is. It scales the gamma ramp of the whole output, so
the picture gets darker. It does **not** change the monitor's backlight, the
brightness shown in the monitor's own menu, or its power consumption. The
coefficient `1.0` means "the picture as it is, no dimming", not "maximum
backlight"; set the backlight once with the monitor's buttons and use these
buttons for the rest. Every number the application reports about brightness is
this coefficient. None of them is a reading of the hardware.

Nothing else is ever sent to `xrandr`: no mode, no refresh rate, no `--off`.
Sleep and wake of the display remain the power controller's business (DPMS);
the brightness is never set to 0 to stand in for standby, and it never follows
the music.

One thing to know about `xrandr` itself: `--brightness` rewrites the whole
gamma ramp, so a per-channel `--gamma` correction set by another tool would be
replaced by a neutral one. The kiosk sets none.

### The manual commands

These are the commands already tried successfully by hand on the jukebox
(output `HDMI-1`, active at 1280×1024). They are the reference if the buttons
misbehave:

```sh
DISPLAY=:0 XAUTHORITY=/home/jukebox/.Xauthority xrandr --query
DISPLAY=:0 XAUTHORITY=/home/jukebox/.Xauthority \
  xrandr --output HDMI-1 --brightness 0.7
DISPLAY=:0 XAUTHORITY=/home/jukebox/.Xauthority \
  LC_ALL=C xrandr --verbose        # "Brightness: 0.70" in the HDMI-1 block
DISPLAY=:0 XAUTHORITY=/home/jukebox/.Xauthority \
  xrandr --output HDMI-1 --brightness 1.0
```

Run them as `jukebox` (`sudo -u jukebox env DISPLAY=… XAUTHORITY=… xrandr …`)
to check that the service user reaches the display.

**While the backend is `xrandr`, the application undoes a manual change within
about ten seconds**: it reads the output regularly and puts back the value it
was asked for. To experiment by hand, set `JUKEBOX_BRIGHTNESS_BACKEND=disabled`
and restart the service first, then set it back.

### Configure

```ini
JUKEBOX_BRIGHTNESS_BACKEND=xrandr
JUKEBOX_XRANDR_OUTPUT=HDMI-1
JUKEBOX_X11_DISPLAY=:0
JUKEBOX_X11_XAUTHORITY=/home/jukebox/.Xauthority
JUKEBOX_BRIGHTNESS_MIN=0.3
JUKEBOX_BRIGHTNESS_MAX=1.0
JUKEBOX_BRIGHTNESS_STEP=0.1
JUKEBOX_BRIGHTNESS_DEFAULT=1.0
JUKEBOX_BRIGHTNESS_TIMEOUT_MS=3000
```

- `JUKEBOX_XRANDR_OUTPUT` is the name `xrandr --query` gives the connected
  output (`HDMI-1`), not the kernel's connector name (`card0-HDMI-A-1`). It is
  never guessed and never "the first output": if no output of that name is
  connected and showing a picture, nothing is applied.
- The display and the authority file are given explicitly because a systemd
  service does not inherit the graphical session's environment.
- The four coefficients are decimals with `0 < MIN < MAX <= 1.0`,
  `MIN <= DEFAULT <= MAX` and `0 < STEP <= MAX - MIN`.
- `JUKEBOX_BRIGHTNESS_DEFAULT` is what is applied when the service starts.
  To always start darker, set for example `JUKEBOX_BRIGHTNESS_DEFAULT=0.7`.

What the buttons set afterwards is kept in memory, nothing is written to the
SD card:

| Event | Brightness afterwards |
| --- | --- |
| Reloading the page, restarting Chromium | unchanged |
| X11 restarting | the chosen value, applied again within seconds |
| Standby, then resume | the chosen value, applied again on wake-up |
| `systemctl restart jukebox`, or a reboot | back to `JUKEBOX_BRIGHTNESS_DEFAULT` |

### Replacing the former DDC block

An earlier version of this integration drove the monitor over DDC/CI. If
`/etc/jukebox/jukebox.env` still has that block, replace it; the units changed,
not only the names:

| Old (DDC) | New (X11) |
| --- | --- |
| `JUKEBOX_BRIGHTNESS_BACKEND=ddcutil` | `JUKEBOX_BRIGHTNESS_BACKEND=xrandr` |
| `JUKEBOX_DDC_BUS=N` | removed. Add `JUKEBOX_XRANDR_OUTPUT=HDMI-1`, `JUKEBOX_X11_DISPLAY=:0`, `JUKEBOX_X11_XAUTHORITY=/home/jukebox/.Xauthority` |
| `JUKEBOX_BRIGHTNESS_MIN=10` (percent) | `JUKEBOX_BRIGHTNESS_MIN=0.3` (coefficient) |
| `JUKEBOX_BRIGHTNESS_MAX=100` (percent) | `JUKEBOX_BRIGHTNESS_MAX=1.0` |
| `JUKEBOX_BRIGHTNESS_STEP=5` (percentage points) | `JUKEBOX_BRIGHTNESS_STEP=0.1` |
| (none) | `JUKEBOX_BRIGHTNESS_DEFAULT=1.0` |
| `JUKEBOX_DDC_TIMEOUT_MS=3000` | `JUKEBOX_BRIGHTNESS_TIMEOUT_MS=3000` |

A leftover `ddcutil` backend, or a percentage such as `100` where a
coefficient is expected, is refused at start with a message saying what to
change; only the brightness is disabled by it. Leftover `JUKEBOX_DDC_*` lines
beside a valid new block are ignored and pointed out in the journal. The
`i2c` group membership and `i2c-dev` module of the old setup are no longer
needed.

## 6. Lights and WLED

`disco_toggle` always goes through the power controller.

`strip_toggle` depends on `JUKEBOX_STRIP_CONTROL`:

- `power` (default): the power controller switches the strip's supply
  (GPIO22). The supply is on when the jukebox starts, so the first press
  switches the strip **off**. A WLED controller on that supply is physically restarted each time
  it comes back: expect the strip to light a few seconds after the press
  (WLED's boot, plus Wi-Fi if it uses it), in whatever its boot preset says.
- `wled`: the supply stays on while the jukebox is awake (it is on from the
  start; should it have been switched off, the application asks the power
  controller for `strip on`, which is idempotent) and the button
  switches the strip through WLED's JSON API at `JUKEBOX_WLED_URL`
  (`http://<address of the WLED controller>`, on the trusted LAN). The
  application reads WLED's actual state, sends the opposite as an explicit
  `{"on": true|false}` and reads it back.

  - If WLED does not answer, the press has **no effect** and the display says
    so. It is never turned into a power toggle.
  - Standby still cuts the supply through GPIO22. On wake-up the application
    waits for WLED to come back (up to about a minute) and restores the state
    last requested with the button. That state is kept in memory only. A short
    flash at power-up may come from WLED's own boot preset; Phoenix cannot
    prevent it.

Nothing here drives a GPIO with PWM, and neither the amplifier nor a USB
supply is used to fake a reaction to the music; nor is the X11 brightness
ever driven at the rhythm of the audio analysis.

## 7. Environment reference

All of these are read when `jukebox.service` starts. A value that cannot be
used switches off the part it belongs to, and only that part, with an
`[hardware] configuration error` line in the journal; it is never replaced by
a guess, and it never stops the display or the music.

| Variable | Default | Meaning |
| --- | --- | --- |
| `JUKEBOX_BUTTONS_ENABLED` | `false` | master switch of the buttons |
| `JUKEBOX_BUTTONS_SOURCE` | `evdev` | `evdev`; `simulated` is accepted in development and tests only |
| `JUKEBOX_BUTTONS_DEVICE` | empty | the encoder's stable event link under `/dev/input/`; required, never guessed |
| `JUKEBOX_BUTTONS_DEBOUNCE_MS` | `80` | 0 to 1000 |
| `JUKEBOX_BUTTONS_DEBUG` | `false` | log every key event and decision |
| `JUKEBOX_BUTTON_<ACTION>` (eight of them) | empty | decimal `EV_KEY` code, 0 to 767; empty: no button for this action; the same code twice is an error |
| `JUKEBOX_BRIGHTNESS_BACKEND` | `disabled` if absent; the example file sets `xrandr` | `disabled` or `xrandr`; `simulated` is accepted in development and tests only; `ddcutil` is refused with a migration message |
| `JUKEBOX_XRANDR_OUTPUT` | none; the example file sets `HDMI-1` | xrandr name of the output; required for `xrandr` |
| `JUKEBOX_X11_DISPLAY` | none; the example file sets `:0` | local X display; required for `xrandr` |
| `JUKEBOX_X11_XAUTHORITY` | none; the example file sets `/home/jukebox/.Xauthority` | absolute path of the X authority file; required for `xrandr` |
| `JUKEBOX_BRIGHTNESS_MIN` / `_MAX` | `0.3` / `1.0` | coefficients, `0 < MIN < MAX <= 1.0`, at most three decimals |
| `JUKEBOX_BRIGHTNESS_STEP` | `0.1` | change per press, `0 < STEP <= MAX - MIN` |
| `JUKEBOX_BRIGHTNESS_DEFAULT` | `1.0` | coefficient applied when the service starts, `MIN <= DEFAULT <= MAX` |
| `JUKEBOX_BRIGHTNESS_TIMEOUT_MS` | `3000` | longest a single `xrandr` call may run before it is killed |
| `JUKEBOX_POWER_CLIENT` | `/usr/local/sbin/jukebox-power-controller.py` | the client used for the lights |
| `JUKEBOX_POWER_STATE_FILE` | `/run/jukebox-power/state.json` | the controller's published state |
| `JUKEBOX_STRIP_CONTROL` | `power` | `power` or `wled` |
| `JUKEBOX_WLED_URL` | empty | required for `wled` |

Only these variables are passed to the hardware code; the rest of the
environment file, and its secrets, never reach the status or the logs.

## 8. Diagnostics

Everything known about the controls, as plain data without any secret:

```sh
sudo -H -u jukebox /opt/jukebox/bin/jukebox rpc \
  'IO.inspect(Jukebox.Hardware.status(), limit: :infinity, pretty: true)'
```

- `config`: the effective configuration and mapping, and the error that
  disabled a part if there is one
- `buttons`: selected device and its identity, connection, held keys, last
  accepted code and action, mapped codes the device does not advertise,
  counters (accepted, bounces, duplicates, repeats, unassigned, malformed,
  discarded while not awake, resynchronisations)
- `power`: mode, freshness and, when unknown, the reason
- `lights`: requested and confirmed state of each light, pending requests,
  last error
- `brightness`: backend, X11 display and output and whether they are ready,
  configured bounds and default, the desired and the applied software
  coefficient (the applied one is what `xrandr` last reported, with the age of
  that reading: up to ten seconds while all is well), whether a change is
  pending, availability (`ready`,
  `not_awake`, `x11_unavailable`, `x11_unauthorized`, `xauthority_missing`,
  `output_missing`, `output_inactive`, `xrandr_missing`, `timeout`,
  `mismatch`, …), last error. The authority file's path is shown, never its
  content
- `recent_error`: the last problem of each part that has one

There is deliberately no HTTP endpoint for this, and none that triggers an
action. In development the simulator page (`/dev/simulator`) shows the same
status.

| Symptom | Look at |
| --- | --- |
| No button does anything | `power.mode`: anything but `awake` blocks them. `unknown` with `:missing` means the controller is not running; `:unsafe_ownership` or `:unsafe_permissions` that the state file is not root's; `:stale` that the controller stopped writing |
| `buttons.connection` is `{:waiting, "enoent"}` | the path in `JUKEBOX_BUTTONS_DEVICE` does not exist (unplugged, or a different link name) |
| `{:waiting, "eacces"}` | the `jukebox` user may not read the device: section 2 |
| `{:helper_down, {:exited, 3}}` | `python3-evdev` is not installed |
| A button does nothing, the others work | `buttons.missing_codes`, then `--diagnose`; `counts.unassigned` rising means its code is not in the mapping |
| A press sometimes counts twice, or not at all | raise or lower `JUKEBOX_BUTTONS_DEBOUNCE_MS`; `counts.bounces` shows what is being filtered |
| "Brightness unavailable" | `brightness.availability`: `x11_unavailable` (the kiosk session is not up, or the unit hides `/tmp/.X11-unix`), `xauthority_missing` / `xauthority_unreadable`, `x11_unauthorized` (wrong authority file), `output_missing` / `output_inactive` (check the name with `xrandr --query`), `xrandr_missing` (`apt install x11-xserver-utils`), `timeout`. Then run the manual commands of section 5 as `jukebox` |
| "Brightness not confirmed" | `availability: mismatch`: xrandr ran, but the output reports another value than the one set (more than 0.02 away). `last_error` holds the value read |
| A manual `xrandr --brightness` is undone after a few seconds | expected while the backend is `xrandr`; select `disabled` to experiment |
| "Disco lights unavailable" | `lights.disco.last_error`: `:client_missing`, `:unreachable` (controller down), `:permission_denied` (the `jukebox` user is not in the socket's group) |
| "… not confirmed" | the command left but its result was not seen in the controller's state within 2.5 s; it was **not** sent again. Look at the state file |

## 9. How it behaves

**Input.** The helper sleeps until the kernel has an event; nothing is polled.
Only `EV_KEY` events of mapped codes count. A key-down is a press only if the
key was up and at least the debounce time has passed since its last accepted
press *and* its last release, so contact bounce gives one press whether it
happens on the way down or on the way up. A key-up is always recorded, so a
filtered bounce can never leave a key stuck. Kernel auto-repeat is ignored and
there is no hold-to-repeat, including for brightness: one press, one step. A
key already held when the device connects, or found held after the kernel
dropped events (`SYN_DROPPED`), does nothing until it is released. The device
is not grabbed: a keyboard plugged in for maintenance keeps working.

**Unplugging.** A missing, unplugged or unreadable device is a status, not a
failure: the helper says so once, retries every half second to five seconds,
and reconnects by itself. If the helper itself dies it is restarted after a
pause that doubles from one second to thirty.

**Standby.** While the power mode is not `awake`, all eight actions are
dropped. They are not kept for later: nothing happens on wake-up. An
unreadable or stale power state counts as not awake.

**Music.** The transport buttons use the existing remote-control path, which
only sends while an AirPlay session is live. With no session the display says
"No active player" and nothing is sent, then or later. A command that could
not be sent within a second and a half is discarded rather than sent late. The
display never shows "paused" or the next title before the phone reports it.

**Queues.** The dispatcher hands every action to a short queue of its own kind
(music; animation and local requests; power client; WLED; brightness), so a
slow backend never delays the reading of the buttons or another backend.

**Lights.** Toggles of one backend run one at a time, in order. A toggle is
never sent twice. A light is shown on or off only after the controller's state
(or WLED's answer) shows the result; if the client cannot tell whether the
controller applied the command, the state file decides, and failing that the
display says "not confirmed".

**Brightness.** The value the user wants is a number in the application's
memory, held apart from the process that runs `xrandr` and from any browser.
It starts at `JUKEBOX_BRIGHTNESS_DEFAULT`; each accepted press moves it by one
step, in exact thousandths, between the two limits. Applying it is one job at
a time: read the output (`xrandr --verbose`, and only the block of the exact
configured output), set it only if it differs, read it back. The read value
must be within 0.02 of the target, because `xrandr` reports two significant
digits and the ramp is quantised; beyond that the display says "not
confirmed". Presses within 200 ms are merged into one job for the last value.
Each `xrandr` has a real deadline after which the process is killed.

The service usually starts before the kiosk session. Until the display
answers, the job is tried again after a pause that doubles from one second to
thirty, and the reason is logged once; the music and the page are never held
up by it. While everything is fine the output is read every ten seconds, and
written only if something (an X restart, a manual command) changed it.

In standby, during shutdown, or while the power state is unreadable, presses
are dropped and nothing runs at all: pending work is cancelled, a running
`xrandr` is stopped, no retry is scheduled, so nothing here can wake the
display. The chosen value is kept and applied again on wake-up.

## 10. Development without the hardware

`mix phx.server` starts everything in simulated form: a pretend input device,
a pretend power controller (awake) and a pretend X11 display. Open
`/dev/simulator`, card **Physical controls**: its key buttons inject raw key
events, so the mapping, the debounce, the standby rule and the queues behind
them are the production ones. The same card switches the pretend controller to
standby or makes it disappear, takes the pretend X server down, up or through
a restart, and shows `Jukebox.Hardware.status/0`.

The key codes in `config/dev.exs` and `config/test.exs` (704 to 711) are
arbitrary. They are not the encoder's.

Tests:

```sh
mix test                                                        # everything, including the Python suites
python3 -m unittest discover -s test/hardware -p 'test_*.py'    # the two Python programs alone
```

## 11. Tested, and still to test

Three different things, not to be confused.

### A. Verified automatically on the development machine (macOS, no hardware)

With fake input, transport, power and xrandr adapters:

- configuration: blank mappings, duplicate and invalid codes, unstable device
  paths, a missing WLED address; brightness coefficients (decimal parsing,
  ranges, default and step), zero, negatives, NaN, infinity, exponents and the
  old percentages all refused; a missing or unsafe output name, display or
  authority path; a leftover `ddcutil` backend refused with its migration
  message; each error disables one subsystem only; the example environment
  file parses to "buttons off, xrandr on `HDMI-1`, neutral default"
- input: one action per press; repeated downs, auto-repeat, bounce on press
  and on release, long holds; simultaneous buttons; disconnect and reconnect
  with a key held; `SYN_DROPPED` resynchronisation; unassigned codes and
  malformed messages counted, not acted on
- helper process (with stand-in scripts, and the real helper against a fake
  device): line protocol, oversized and malformed lines, restart with growing
  pauses, no process left behind when the application stops, exit when the
  parent goes away
- actions: the animation button walks the four styles and wraps, once per
  press whatever the number of connected displays; no music command is
  replayed when a session starts later; stale music commands expire; nothing
  is dispatched or kept while not awake or while the power state is unreadable
- lights: confirmation from the controller's state only; no retry after an
  uncertain result; a toggle queued when standby begins is dropped; a WLED
  failure never becomes a power toggle; WLED state restored after a wake-up
- brightness: steps and clamping without drift; merging of rapid presses, one
  request at a time; the read-back tolerance and a mismatch beyond it; the
  parser on multi-output and malformed `xrandr --verbose` listings (the value
  of another output is never taken); the exact executable, argument list and
  child environment, with no shell and nothing but `--output` and
  `--brightness`; a process killed at its deadline (checked to be gone);
  starting before X11 with bounded retries and automatic recovery; X
  authorisation failure, missing and inactive output, missing authority file;
  an X restart noticed and repaired; a worker restart keeping the chosen
  value; standby cancelling pending work, running nothing, and resume applying
  the kept value; a fresh start returning to the configured default
- power state file: owner, permissions, symbolic link, schema, staleness; the
  document written by the controller itself is accepted by the reader
- power controller (fake GPIO, explicit clock, real Unix socket): the same
  outputs and display commands as the original program on random sequences of
  commands and presses; outputs low at start, the starting requests, amplifier
  delay, standby during the delay, shutdown during boot and during the delay
  with nothing coming back on, stop on `SIGTERM`, a command kept during
  standby, duplicate request ids, refusals, the original text datagram, a
  second instance refused, a stale socket replaced, the audio analyser's
  socket and its directory left untouched, state file removed on exit, the
  exact `xset` command and its time limit, readiness on an HTTP success only
- installer (against a temporary root): files and modes, idempotence, dated
  copies, rollback, and that the environment file, the audio binaries, the
  ALSA and Shairport configuration and the boot configuration are untouched
- a production release was built and booted with default, wrong and valid
  settings, and the helper found inside it

The `xrandr` used in these tests is a stand-in script. Its `--verbose` listing
was written from the format of the real program, not captured on the Pi.

### B. Done by hand on the jukebox, by the user

- [x] `xrandr --output HDMI-1 --brightness 0.7` with `DISPLAY=:0` and
      `XAUTHORITY=/home/jukebox/.Xauthority` visibly dims the picture, and
      `--brightness 1.0` restores it. `HDMI-1` is active at 1280×1024, about
      60 Hz.

That shows the command works on this display. It says nothing yet about the
application running it: none of the lines below is covered by it.

### C. Application integration, still to do on the Raspberry Pi

Treat every line as pending until you have ticked it:

- [ ] the power controller starts under systemd on ARMv7 with `gpiozero`
      (pin factory, GPIO3 with its fixed pull-up), and its unit's watchdog
      and `Type=notify` behave
- [ ] short press: standby and resume; long press then release: shutdown;
      press while halted: boot (GPIO3)
- [ ] display sleep and wake through `xset dpms force off|on` from the
      service, now with a 3 s limit (and whether the HDMI-to-VGA adapter
      passes DPMS at all)
- [ ] after a boot, strip, decor and extra come on with the kiosk and the
      amplifier 1.5 s later, as with the original controller
- [ ] power control with Phoenix stopped (`sudo systemctl stop jukebox`)
- [ ] the real codes of all eight buttons, mapped with `--diagnose`
- [ ] the helper with the real `python3-evdev` (device capabilities, the
      monotonic event clock, `SYN_DROPPED`)
- [ ] the `jukebox` service user can read the encoder
- [ ] the `jukebox` service reaches X11: `brightness.x11_ready?` is true in
      `Jukebox.Hardware.status()` and the journal shows
      `[brightness] X11 output "HDMI-1" ready`
- [ ] the real `xrandr --verbose` listing is understood: the applied
      coefficient in the status follows the buttons (if it shows
      `malformed_reply`, send that listing back: the parser was written
      without one from the Pi)
- [ ] brightness steps of 0.1, stopping at 0.3 and 1.0, each confirmed on the
      display ("Brightness 70%")
- [ ] the service started before X11 (a reboot): the default is applied once
      the kiosk is up, without restarting anything
- [ ] X11 or the output missing (stop the kiosk session, unplug the monitor):
      "Brightness unavailable", no crash, no hang, recovery afterwards
- [ ] standby then resume: the chosen coefficient comes back, and nothing
      wakes the display during standby
- [ ] after `systemctl restart jukebox` and after a reboot: back to
      `JUKEBOX_BRIGHTNESS_DEFAULT`
- [ ] buttons work without keyboard focus on Chromium, and with two tabs open
- [ ] hot unplug and replug of the encoder
- [ ] repeated brightness changes cause no audio glitch
- [ ] disco and strip toggles end to end, confirmed on the display
- [ ] WLED mode, if used: toggle, standby, wake-up, restore
- [ ] CPU and memory of the Pi 2 with everything enabled (`top`, `free -h`),
      including the reading of the output every ten seconds
