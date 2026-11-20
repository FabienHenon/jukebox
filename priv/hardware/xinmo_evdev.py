#!/usr/bin/python3
"""Reads ONE Linux input device and reports its key events.

Started by the jukebox (Jukebox.Inputs.Evdev) as:

    /usr/bin/python3 -u xinmo_evdev.py --device /dev/input/by-id/...-event-joystick

It then writes one JSON object per line on standard output (diagnostics go to
standard error) and takes no decision at all: which code does what, debounce
and the standby rule all live in the application.

    {"t":"hello","v":1}
    {"t":"connected","name":...,"vendor":...,"product":...,"version":...,
     "phys":...,"path":...,"real":...,"keys":[...],"held":[...],"abs":true}
    {"t":"key","c":CODE,"v":1|0|2,"ms":MONOTONIC_MS}     1 down, 0 up, 2 repeat
    {"t":"resync","held":[...],"ms":MONOTONIC_MS}        after SYN_DROPPED
    {"t":"waiting","reason":"enoent"}                    device missing, retrying
    {"t":"disconnected","reason":"enodev"}

To find out which codes the buttons send, run it by hand:

    /usr/bin/python3 xinmo_evdev.py --device /dev/input/by-id/... --diagnose

That mode prints the device, its key codes and every press, release and
repeat in plain text, and ends (Ctrl-C) with a template for the environment
file. It triggers nothing in the jukebox.

Rules this helper keeps:

  * It opens the one path it is given, never another device, and does not
    grab it: a keyboard plugged in for maintenance keeps working.
  * It sleeps in select() until the kernel has an event; there is no polling.
  * Only EV_KEY events are reported. Axes and hats are ignored.
  * After SYN_DROPPED everything up to the next SYN_REPORT is discarded and
    the keys actually held are read from the device, without inventing a
    press or a release.
  * When the device is missing, unplugged or not readable it says so once and
    retries with a pause that grows to five seconds. It never tries to change
    permissions.
  * It exits when its standard input is closed, which is what happens when the
    application stops, so it is never left running on its own.

Needs the distribution package python3-evdev. Exit status: 0 normal end,
2 wrong arguments, 3 the evdev module is missing.
"""

import argparse
import errno
import json
import os
import select
import signal
import stat
import struct
import sys
import time

PROTOCOL_VERSION = 1

EV_SYN = 0x00
EV_KEY = 0x01
EV_ABS = 0x03
SYN_REPORT = 0
SYN_DROPPED = 3

# _IOW('E', 0xa0, int): ask the kernel to timestamp events with the monotonic
# clock instead of the time of day, which NTP moves on a Pi without a clock.
EVIOCSCLOCKID = 0x400445A0
CLOCK_MONOTONIC = 1

MAX_REPORTED_CODES = 768
RETRY_MIN_S = 0.5
RETRY_MAX_S = 5.0

ACTIONS = (
    "PREVIOUS",
    "PLAY_PAUSE",
    "NEXT",
    "DISCO_TOGGLE",
    "STRIP_TOGGLE",
    "ANIMATION_NEXT",
    "BRIGHTNESS_DOWN",
    "BRIGHTNESS_UP",
)


def log(message):
    print("xinmo_evdev: " + message, file=sys.stderr, flush=True)


def emit(message, out=None):
    out = out or sys.stdout
    out.write(json.dumps(message, separators=(",", ":")) + "\n")
    out.flush()


def monotonic_ms():
    return int(time.monotonic() * 1000)


class KeyStream:
    """Turns raw input events into protocol messages.

    `held` is a function returning the key codes the device reports as down
    right now; it is only called to resynchronise after SYN_DROPPED.
    """

    def __init__(self, held):
        self._held = held
        self._dropping = False

    def feed(self, etype, code, value, ms):
        if etype == EV_SYN:
            if code == SYN_DROPPED:
                # The kernel buffer overflowed: what follows, up to the next
                # SYN_REPORT, is the tail of a packet whose start was lost.
                self._dropping = True
                return []
            if code == SYN_REPORT and self._dropping:
                self._dropping = False
                return [{"t": "resync", "held": sorted(self._held()), "ms": ms}]
            return []
        if self._dropping:
            return []
        if etype == EV_KEY and value in (0, 1, 2):
            return [{"t": "key", "c": code, "v": value, "ms": ms}]
        return []


def error_name(error):
    code = getattr(error, "errno", None)
    return errno.errorcode.get(code, "error").lower() if code else "error"


def check_path(path):
    """Refuses anything that is not a character device under /dev/input."""
    real = os.path.realpath(path)
    if not real.startswith("/dev/input/"):
        raise OSError(errno.EINVAL, "not under /dev/input")
    if not stat.S_ISCHR(os.stat(real).st_mode):
        raise OSError(errno.ENOTTY, "not a character device")
    return real


class Device:
    """The one input device, opened read-only with python-evdev."""

    def __init__(self, path):
        import evdev  # deferred: --help and the tests work without it

        self.path = path
        self.real = check_path(path)
        self._device = evdev.InputDevice(path)
        self.fd = self._device.fd
        self.monotonic = self._use_monotonic_clock()

    def _use_monotonic_clock(self):
        try:
            import fcntl

            fcntl.ioctl(self.fd, EVIOCSCLOCKID, struct.pack("i", CLOCK_MONOTONIC))
            return True
        except OSError:
            return False

    def describe(self):
        capabilities = self._device.capabilities(absinfo=False)
        info = self._device.info
        keys = sorted(capabilities.get(EV_KEY, []))[:MAX_REPORTED_CODES]
        return {
            "name": self._device.name,
            "vendor": info.vendor,
            "product": info.product,
            "version": info.version,
            "phys": self._device.phys,
            "path": self.path,
            "real": self.real,
            "keys": keys,
            "held": self.held(),
            "abs": EV_ABS in capabilities,
        }

    def held(self):
        return sorted(self._device.active_keys())

    def read(self):
        """Events available now, as (type, code, value, ms)."""
        events = []
        for event in self._device.read():
            if self.monotonic:
                ms = event.sec * 1000 + event.usec // 1000
            else:
                ms = monotonic_ms()
            events.append((event.type, event.code, event.value, ms))
        return events

    def close(self):
        try:
            self._device.close()
        except OSError:
            pass


class ParentWatch:
    """Notices that the application is gone: its end of our stdin is closed."""

    def __init__(self, stdin_fd):
        # Run by hand from a terminal there is no parent to watch.
        self.fd = None if stdin_fd is None or os.isatty(stdin_fd) else stdin_fd

    def fds(self):
        return [] if self.fd is None else [self.fd]

    def gone(self, readable):
        if self.fd is None or self.fd not in readable:
            return False
        try:
            return os.read(self.fd, 4096) == b""
        except OSError:
            return True

    def sleep(self, seconds):
        """Waits; True when the parent went away meanwhile."""
        if self.fd is None:
            time.sleep(seconds)
            return False
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            readable, _, _ = select.select([self.fd], [], [], remaining)
            if self.gone(readable):
                return True


def pump(device, parent, out):
    """Reports events until the device or the parent goes away.

    Returns the reason the device was lost, or None when the parent is gone.
    """
    stream = KeyStream(device.held)
    while True:
        readable, _, _ = select.select([device.fd] + parent.fds(), [], [])
        if parent.gone(readable):
            return None
        if device.fd not in readable:
            continue
        try:
            events = device.read()
        except BlockingIOError:
            continue
        except OSError as error:
            return error_name(error)
        for etype, code, value, ms in events:
            for message in stream.feed(etype, code, value, ms):
                emit(message, out)


def run(path, opener=Device, parent=None, out=None):
    """The normal mode: connect, report, reconnect, until the parent is gone."""
    out = out or sys.stdout
    parent = parent or ParentWatch(sys.stdin.fileno())
    emit({"t": "hello", "v": PROTOCOL_VERSION}, out)
    pause = RETRY_MIN_S
    last_reason = None

    while True:
        try:
            device = opener(path)
        except ImportError:
            log("the Python module 'evdev' is missing: sudo apt install python3-evdev")
            return 3
        except OSError as error:
            reason = error_name(error)
            if reason != last_reason:
                # Said once per reason, not once per attempt.
                log("cannot open %s (%s); retrying" % (path, reason))
                emit({"t": "waiting", "reason": reason}, out)
                last_reason = reason
            if parent.sleep(pause):
                return 0
            pause = min(pause * 2, RETRY_MAX_S)
            continue

        pause = RETRY_MIN_S
        last_reason = None
        try:
            emit(dict(device.describe(), t="connected"), out)
            reason = pump(device, parent, out)
        except OSError as error:
            reason = error_name(error)
        finally:
            device.close()

        if reason is None:
            return 0
        log("lost %s (%s); waiting for it to come back" % (path, reason))
        emit({"t": "disconnected", "reason": reason}, out)
        if parent.sleep(RETRY_MIN_S):
            return 0


# -- diagnose mode -------------------------------------------------------------


def code_name(code):
    try:
        import evdev

        name = evdev.ecodes.bytype[EV_KEY].get(code)
    except (ImportError, AttributeError, KeyError):
        return "?"
    if isinstance(name, (list, tuple)):
        return "/".join(name)
    return name or "?"


def env_template(path, pressed):
    lines = [
        "",
        "# ---------------------------------------------------------------------",
        "# Template for /etc/jukebox/jukebox.env. The eight action lines are left",
        "# EMPTY on purpose: write after each '=' the decimal code printed above",
        "# when you pressed the button meant for that action.",
    ]
    if pressed:
        lines.append(
            "# Codes pressed during this session, in order of first press: "
            + ", ".join(str(code) for code in pressed)
        )
    else:
        lines.append("# No button was pressed during this session.")
    lines += [
        "# ---------------------------------------------------------------------",
        "JUKEBOX_BUTTONS_ENABLED=true",
        "JUKEBOX_BUTTONS_SOURCE=evdev",
        "JUKEBOX_BUTTONS_DEVICE=" + path,
        "JUKEBOX_BUTTONS_DEBOUNCE_MS=80",
    ]
    lines += ["JUKEBOX_BUTTON_%s=" % action for action in ACTIONS]
    return "\n".join(lines)


def diagnose(path, opener=Device, out=None):
    """Shows what the device is and what its buttons send. Dispatches nothing."""
    out = out or sys.stdout

    def say(text=""):
        out.write(text + "\n")
        out.flush()

    try:
        device = opener(path)
    except ImportError:
        log("the Python module 'evdev' is missing: sudo apt install python3-evdev")
        return 3
    except OSError as error:
        log("cannot open %s: %s" % (path, error))
        if getattr(error, "errno", None) == errno.EACCES:
            log(
                "the current user may not read it; the service user needs the group "
                "that owns the device (see docs/physical-controls.md)"
            )
        return 1

    pressed = []
    axes_seen = set()
    try:
        info = device.describe()
        say("Device   %s" % info["name"])
        say("Path     %s -> %s" % (info["path"], info["real"]))
        say(
            "USB id   vendor 0x%04x  product 0x%04x  version 0x%04x"
            % (info["vendor"], info["product"], info["version"])
        )
        say("Phys     %s" % info["phys"])
        say("Key codes advertised (%d):" % len(info["keys"]))
        for code in info["keys"]:
            say("  %4d  %s" % (code, code_name(code)))
        if info["abs"]:
            say("The device also has axes (EV_ABS). The jukebox ignores them: wire the")
            say("eight buttons to BUTTON terminals of the encoder, not to the joystick")
            say("direction terminals.")
        if not info["keys"]:
            say("This device advertises NO key code. If the encoder shows up as several")
            say("devices, try the other /dev/input/by-id/ entries.")
        if info["held"]:
            say("Held right now: %s" % ", ".join(str(code) for code in info["held"]))
        say()
        say("Press each button once. Nothing is sent to the jukebox. Ctrl-C to finish.")
        say()

        stream = KeyStream(device.held)
        labels = {1: "press  ", 0: "release", 2: "repeat "}
        while True:
            select.select([device.fd], [], [])
            for etype, code, value, ms in device.read():
                if etype == EV_ABS and code not in axes_seen:
                    axes_seen.add(code)
                    say("  axis %d moved: ignored (this input is not a button terminal)" % code)
                for message in stream.feed(etype, code, value, ms):
                    if message["t"] == "resync":
                        say("  events were dropped by the kernel; held now: %s" % message["held"])
                        continue
                    code = message["c"]
                    if message["v"] == 1 and code not in pressed:
                        pressed.append(code)
                    say("  %s  code=%d  (%s)" % (labels[message["v"]], code, code_name(code)))
    except KeyboardInterrupt:
        pass
    except OSError as error:
        log("lost the device: %s" % error)
    finally:
        device.close()

    say(env_template(path, pressed))
    return 0


def die_with_parent():
    """Linux: have the kernel send SIGTERM if the parent process dies."""
    try:
        import ctypes

        ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Report the key events of one Linux input device (see the top of this file)."
    )
    parser.add_argument(
        "--device",
        required=True,
        help="the event device, by its stable link: /dev/input/by-id/...-event-joystick",
    )
    parser.add_argument(
        "--diagnose",
        action="store_true",
        help="print the device, its codes and each press in plain text; dispatch nothing",
    )
    args = parser.parse_args(argv)

    try:
        if args.diagnose:
            return diagnose(args.device)
        die_with_parent()
        return run(args.device)
    except BrokenPipeError:
        # The reader of our output is gone.
        return 0
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
