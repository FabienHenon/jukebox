#!/usr/bin/python3
"""Jukebox power controller: the root service that owns the Power button and
every power GPIO, and its command-line client.

This is the controller of the installation guide (phase 11) with the additions
the application needs: it publishes its state, answers the commands it
receives, and cancels a pending amplifier switch-on when a standby or a
shutdown begins. Commands, pins, press durations and the socket are unchanged.

It is independent of the Phoenix application and of Chromium: the Power
button, standby and shutdown work when either of them is down. The application
never touches these GPIO lines; it reads the state published here and asks for
light changes through the client.

    jukebox-power-controller.py --daemon        the service (root, started by systemd)

    jukebox-power-controller.py disco toggle    client commands, also: on | off
    jukebox-power-controller.py strip toggle
    jukebox-power-controller.py decor toggle
    jukebox-power-controller.py extra toggle
    jukebox-power-controller.py amp toggle
    jukebox-power-controller.py standby on|off|toggle
    jukebox-power-controller.py shutdown
    jukebox-power-controller.py status          new: prints the state, changes nothing

Power button (GPIO3, physical pin 5, to GND on pin 6):

    short press                          standby / resume
    held 3 seconds or more, on release   clean shutdown (systemctl poweroff)
    pressed while the Pi is halted       the Pi boots (a function of the Pi's
                                         firmware; this program is not involved)

Outputs, all active-high and all LOW when the service starts:

    amplifier GPIO17   requested ON    on 1.5 s after the jukebox becomes awake
    disco     GPIO27   requested OFF   \
    strip     GPIO22   requested ON     |  on when requested AND the jukebox
    decor     GPIO23   requested ON     |  is awake
    extra     GPIO24   requested ON    /

The requests above are the starting values, as in the original program. They
are kept in memory only: a command changes them, a standby keeps them and
applies them again on resume, a restart of the service or of the Pi returns to
them. A command received during standby changes the request and takes effect
on resume, also as in the original.

Modes: booting -> awake <-> standby, and shutting_down from any of them. The
service starts in "booting", with everything low, and becomes awake when the
application answers on http://127.0.0.1:4000/. The original waited for that
for ever; this one stops waiting after --ready-timeout seconds (90) and
becomes awake anyway, so that the amplifier and the lights do not depend on
Phoenix. The level of every output is computed from the mode and the requests
in one place (Controller._apply), so a late timer can never switch something
back on after a standby or a shutdown began.

The display is put to sleep and woken with `xset dpms force off|on`, exactly as
before (the kiosk keeps DPMS enabled with zero timeouts), now with a time limit
and from a thread of its own so that X can never hold up the Power button.

State file (default /run/jukebox-power/state.json, in RAM, root:jukebox 0640
in a 0750 directory), rewritten atomically on every change and at least once
per second:

    {"schema": 1,
     "instance": "…",      changes each time the service starts
     "revision": 12,       increases on every change of mode or output
     "heartbeat": 3401,    increases on every write
     "boottime": 512.37,   FRESHNESS MARKER: seconds since boot (CLOCK_BOOTTIME,
                           the first number of /proc/uptime) when this was
                           written. A reader must treat the state as stale,
                           hence unknown, when it is more than 3 seconds old.
     "pid": 431,
     "mode": "awake",
     "outputs": {"amp": {"gpio": 17, "requested": true, "applied": true}, …}}

"applied" is the level this program commanded on the GPIO and read back from
it. It is not a measurement: it cannot tell whether a lamp draws current or
whether the amplifier really has power.

Commands arrive as datagrams on /run/jukebox/power-control.sock. The client
sends {"v":1,"id":"…","cmd":["disco","toggle"]} and waits for the answer
{"id":"…","ok":true,"revision":13,…}. A request whose id was already seen is
answered again without being carried out twice. A bare text datagram such as
"disco toggle" (what the original client sent) is still accepted; it gets no
answer.

Client exit status (the original client always exited 0):

    0  the controller carried the command out
    1  wrong usage
    2  the controller refused it (it is shutting down)
    3  no answer in time: it is NOT known whether the command was applied.
       Do not send a toggle again blindly; read the state instead.
    4  the controller could not be reached; nothing was sent
"""

import argparse
import collections
import errno
import grp
import json
import os
import pwd
import queue
import selectors
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid

SCHEMA = 1
PROTOCOL = 1

SOCKET_PATH = "/run/jukebox/power-control.sock"
STATE_FILE = "/run/jukebox-power/state.json"

POWER_BUTTON_GPIO = 3
OUTPUTS = collections.OrderedDict(
    [("amp", 17), ("disco", 27), ("strip", 22), ("decor", 23), ("extra", 24)]
)
LIGHTS = ("disco", "strip", "decor", "extra")

# What is wanted of each output when the service starts (the original
# program's DEFAULT_STATE). In memory only.
DEFAULT_REQUESTS = {"amp": True, "disco": False, "strip": True, "decor": True, "extra": True}

HOLD_SHUTDOWN_S = 3.0
MIN_PRESS_S = 0.03
BUTTON_BOUNCE_S = 0.08
AMP_DELAY_S = 1.5
HEARTBEAT_S = 1.0
XSET_TIMEOUT_S = 3.0
MAX_DATAGRAM = 1024
REMEMBERED_REQUESTS = 64

EXIT_OK, EXIT_USAGE, EXIT_REFUSED, EXIT_NO_ANSWER, EXIT_UNREACHABLE = 0, 1, 2, 3, 4


def log(message):
    print("jukebox-power: " + message, file=sys.stderr, flush=True)


def boottime():
    """Seconds since boot, the same clock as the first field of /proc/uptime."""
    clock = getattr(time, "CLOCK_BOOTTIME", None)
    if clock is not None:
        return time.clock_gettime(clock)
    return time.monotonic()  # development machines only


def valid_command(words):
    if len(words) == 2 and words[0] in OUTPUTS and words[1] in ("toggle", "on", "off"):
        return True
    if len(words) == 2 and words[0] == "standby" and words[1] in ("toggle", "on", "off"):
        return True
    return words in (["shutdown"], ["status"])


# -- the controller: every decision, no I/O of its own -------------------------


class Controller:
    """State machine of the jukebox power.

    Everything it touches is handed to it (GPIO, display, poweroff, the state
    writer), and time is passed in, so the whole behaviour can be tested
    without a Raspberry Pi. It is driven from one thread only: button edges,
    commands and timers are handled one after the other, never concurrently.
    """

    def __init__(self, hw, publish, display, poweroff, instance=None, pid=None, requests=None):
        self.hw = hw
        self._publish = publish
        self.display = display
        self._poweroff = poweroff
        self.instance = instance or uuid.uuid4().hex
        self.pid = pid if pid is not None else os.getpid()
        self.mode = "booting"
        self.requested = dict(DEFAULT_REQUESTS if requests is None else requests)
        self.amp_enabled = False
        self.revision = 0
        self.heartbeat = 0
        self.stopped = False
        self._amp_at = None
        self._ready_by = None
        self._heartbeat_at = 0.0
        self._down_at = None
        self._ignore_release = False
        self._answers = collections.OrderedDict()

    # -- life cycle ------------------------------------------------------------

    def start(self, now, ready_timeout=0.0, button_pressed=False):
        """Outputs low, mode booting. Becomes awake on app_ready() or once
        `ready_timeout` seconds have passed, whichever comes first."""
        # A button still held from the press that booted the Pi is not a press.
        self._ignore_release = button_pressed
        self._apply()
        if ready_timeout > 0:
            self._ready_by = now + ready_timeout
            self._changed(now)
        else:
            self._enter_awake(now)

    def stop(self, now):
        """The service is ending (SIGTERM, error): everything low, for good."""
        self.stopped = True
        self._amp_at = None
        self._ready_by = None
        self._apply()

    # -- events ----------------------------------------------------------------

    def app_ready(self, now):
        if self.mode == "booting" and not self.stopped:
            self._enter_awake(now)

    def button_down(self, at):
        if self._down_at is None:
            self._down_at = at

    def button_up(self, at, now):
        down_at, self._down_at = self._down_at, None
        if self._ignore_release:
            self._ignore_release = False
            return
        if down_at is None or self.stopped or self.mode == "shutting_down":
            return
        held = at - down_at
        if held >= HOLD_SHUTDOWN_S:
            self._shutdown(now)
        elif held >= MIN_PRESS_S:
            self._standby("toggle", now)

    def command(self, words, now, request_id=None):
        """Carries out a client command and returns the answer to send back."""
        if request_id is not None and request_id in self._answers:
            # Already carried out: answer again, do nothing twice.
            return dict(self._answers[request_id], duplicate=True)

        error = self._execute(words, now)
        answer = self._answer(request_id, error)
        if request_id is not None:
            self._answers[request_id] = answer
            while len(self._answers) > REMEMBERED_REQUESTS:
                self._answers.popitem(last=False)
        return answer

    def tick(self, now):
        """Runs what is due: the amplifier delay, the boot wait, the heartbeat."""
        if self._ready_by is not None and now >= self._ready_by:
            self._ready_by = None
            if self.mode == "booting" and not self.stopped:
                log("the application did not answer in time; becoming awake without it")
                self._enter_awake(now)
        if self._amp_at is not None and now >= self._amp_at:
            self._amp_at = None
            # Checked again here, and enforced by _apply: a delay that started
            # before a standby or a shutdown must not power the amplifier.
            if self.mode == "awake" and not self.stopped:
                self.amp_enabled = True
                self._apply()
                self._changed(now)
        if not self.stopped and now - self._heartbeat_at >= HEARTBEAT_S:
            self._write(now)

    def next_deadline(self):
        deadlines = [self._heartbeat_at + HEARTBEAT_S]
        if self._amp_at is not None:
            deadlines.append(self._amp_at)
        if self._ready_by is not None:
            deadlines.append(self._ready_by)
        return min(deadlines)

    # -- transitions -----------------------------------------------------------

    def _execute(self, words, now):
        if self.stopped:
            return "stopping"
        if not valid_command(words):
            return "unknown_command"
        if words == ["status"]:
            return None
        if self.mode == "shutting_down":
            return "shutting_down"
        if words == ["shutdown"]:
            self._shutdown(now)
            return None
        if words[0] == "standby":
            self._standby(words[1], now)
            return None

        # Also outside the awake mode: the request is kept and applied on
        # resume (_apply drives nothing high while the jukebox is not awake).
        name, verb = words
        wanted = {"on": True, "off": False, "toggle": not self.requested[name]}[verb]
        if wanted != self.requested[name]:
            self.requested[name] = wanted
            self._apply()
            self._changed(now)
        return None

    def _standby(self, verb, now):
        asleep = self.mode == "standby"
        want_asleep = {"on": True, "off": False, "toggle": not asleep}[verb]
        if want_asleep and not asleep:
            self._enter_standby(now)
        elif not want_asleep and self.mode != "awake":
            self._enter_awake(now)
        elif not want_asleep:
            # "standby off" while already awake: like the original, wake the
            # display again (it may have been put to sleep by other means).
            self.display.set(True)

    def _enter_awake(self, now):
        self.mode = "awake"
        self._ready_by = None
        self.amp_enabled = False
        self._amp_at = now + AMP_DELAY_S
        self._apply()
        self.display.set(True)
        self._changed(now)

    def _enter_standby(self, now):
        self.mode = "standby"
        self._ready_by = None
        self._amp_at = None
        self.amp_enabled = False
        self._apply()
        self.display.set(False)
        self._changed(now)

    def _shutdown(self, now):
        self.mode = "shutting_down"
        self._ready_by = None
        self._amp_at = None
        self.amp_enabled = False
        self._apply()
        self.display.set(False)
        self._changed(now)
        self._poweroff()

    def _levels(self):
        awake = self.mode == "awake" and not self.stopped
        # amp_enabled: the delay after becoming awake has passed.
        levels = {"amp": awake and self.amp_enabled and self.requested["amp"]}
        for name in LIGHTS:
            levels[name] = awake and self.requested[name]
        return levels

    def _apply(self):
        """The only place an output is driven. The amplifier goes off first."""
        levels = self._levels()
        for name in OUTPUTS:
            if self.hw.get(name) != levels[name]:
                self.hw.set(name, levels[name])

    # -- published state -------------------------------------------------------

    def _changed(self, now):
        self.revision += 1
        self._write(now)

    def _write(self, now):
        self.heartbeat += 1
        self._heartbeat_at = now
        self._publish(self.state())

    def state(self):
        outputs = collections.OrderedDict()
        for name, gpio in OUTPUTS.items():
            outputs[name] = {
                "gpio": gpio,
                "requested": bool(self.requested[name]),
                "applied": bool(self.hw.get(name)),
            }
        return collections.OrderedDict(
            [
                ("schema", SCHEMA),
                ("instance", self.instance),
                ("revision", self.revision),
                ("heartbeat", self.heartbeat),
                ("boottime", round(boottime(), 3)),
                ("pid", self.pid),
                ("mode", self.mode),
                ("outputs", outputs),
            ]
        )

    def _answer(self, request_id, error):
        state = self.state()
        answer = {
            "v": PROTOCOL,
            "id": request_id,
            "ok": error is None,
            "instance": state["instance"],
            "revision": state["revision"],
            "mode": state["mode"],
            "outputs": state["outputs"],
        }
        if error is not None:
            answer["error"] = error
        return answer


# -- hardware and system access (the daemon only) ------------------------------


class GpioHardware:
    """The five outputs and the Power button, through gpiozero.

    Claiming the lines fails when another program already holds them, which is
    how a second owner of the same GPIO is refused.
    """

    def __init__(self, on_button):
        from gpiozero import Button, OutputDevice

        self._outputs = {}
        for name, gpio in OUTPUTS.items():
            self._outputs[name] = OutputDevice(gpio, active_high=True, initial_value=False)
        # GPIO3 has a fixed pull-up on the board; the button pulls it to GND.
        self._button = Button(POWER_BUTTON_GPIO, pull_up=True, bounce_time=BUTTON_BOUNCE_S)
        # The callbacks run in gpiozero's thread: they only note the time and
        # hand the edge over. No decision and no waiting happens there.
        self._button.when_pressed = lambda: on_button("down", time.monotonic())
        self._button.when_released = lambda: on_button("up", time.monotonic())

    def set(self, name, level):
        if level:
            self._outputs[name].on()
        else:
            self._outputs[name].off()

    def get(self, name):
        return bool(self._outputs[name].value)

    def button_pressed(self):
        return bool(self._button.is_pressed)

    def close(self):
        for output in self._outputs.values():
            try:
                output.off()
                output.close()
            except Exception:  # noqa: BLE001 - closing must go on for the others
                pass
        try:
            self._button.close()
        except Exception:  # noqa: BLE001
            pass


class Display:
    """Display sleep and wake through X11 DPMS, in its own thread.

    The command is the original one, `xset dpms force on|off`, run with the
    kiosk session's DISPLAY and XAUTHORITY. Nothing else is sent to X: the
    kiosk keeps DPMS enabled with zero timeouts (see its .xinitrc), so the
    screen only ever sleeps when asked to here.

    The controller only says what it wants; the newest wish replaces any that
    is still waiting. A slow or absent X server therefore never delays the
    Power button, and each xset call has a hard time limit.
    """

    def __init__(self, display, xauthority):
        self._env = os.environ.copy()
        self._env["DISPLAY"] = display
        self._env["XAUTHORITY"] = xauthority
        self._wish = None
        self._condition = threading.Condition()
        self._closed = False
        self._failed = False
        threading.Thread(target=self._work, name="display", daemon=True).start()

    def set(self, on):
        with self._condition:
            self._wish = on
            self._condition.notify()

    def close(self):
        with self._condition:
            self._closed = True
            self._condition.notify()

    def _work(self):
        while True:
            with self._condition:
                while self._wish is None and not self._closed:
                    self._condition.wait()
                if self._closed:
                    return
                on, self._wish = self._wish, None
            self._xset(["dpms", "force", "on" if on else "off"])

    def _xset(self, arguments):
        try:
            subprocess.run(
                ["/usr/bin/xset"] + arguments,
                env=self._env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=XSET_TIMEOUT_S,
                check=True,
            )
            self._failed = False
        except (OSError, subprocess.SubprocessError) as error:
            if not self._failed:
                log("xset %s failed (%s); the display state may not follow" % (" ".join(arguments), error))
            self._failed = True


class NoDisplay:
    def set(self, on):
        pass

    def close(self):
        pass


def write_state(path, state, group_id=None):
    """Atomic replacement: a reader sees the old document or the new one."""
    directory = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".state-", dir=directory)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(state, handle, separators=(",", ":"))
        os.chmod(temporary, 0o640)
        if group_id is not None:
            os.chown(temporary, 0, group_id)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def notify_systemd(message):
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notifier:
            notifier.sendto(message.encode(), address)
    except OSError:
        pass


def wait_for_application(port, stop, post):
    """Tells the controller when the application serves its page, as the
    original did: a successful HTTP answer on the local port."""
    url = "http://127.0.0.1:%d/" % port
    while not stop.is_set():
        try:
            with urllib.request.urlopen(url, timeout=2):
                pass
            post(("app_ready",))
            return
        except Exception:  # noqa: BLE001 - refused, timed out, HTTP error: not ready
            stop.wait(1.0)


def poweroff():
    for systemctl in ("/usr/bin/systemctl", "/bin/systemctl"):
        if os.path.exists(systemctl):
            subprocess.Popen([systemctl, "poweroff"], stdin=subprocess.DEVNULL)
            return
    log("systemctl not found: cannot power off")


class Daemon:
    """Wires the controller to the socket, the GPIO, the timers and signals."""

    def __init__(self, options, hw=None, display=None, poweroff_fn=None, requests=None):
        self.options = options
        self._events = queue.SimpleQueue()
        self._wake_r, self._wake_w = os.pipe()
        os.set_blocking(self._wake_r, False)
        os.set_blocking(self._wake_w, False)
        self._stop_waiting = threading.Event()
        self._hw = hw
        self._display = display
        self._poweroff = poweroff_fn or poweroff
        self._requests = requests
        self._group_id = None
        self.controller = None
        self.ready = threading.Event()

    def post(self, event):
        """Hands an event to the main loop; safe from any thread or signal handler."""
        self._events.put(event)
        try:
            os.write(self._wake_w, b"!")
        except OSError:
            pass

    def request_stop(self):
        self.post(("terminate",))

    def run(self):
        options = self.options
        if options.group:
            self._group_id = grp.getgrnam(options.group).gr_gid

        # The socket first: it is what tells that another controller is
        # already running, before anything of its is touched.
        server = self._open_socket()
        try:
            self._prepare_state_directory()
            # Fails when another program holds one of the GPIO lines: there is
            # only ever one owner.
            hw = self._hw or GpioHardware(lambda edge, at: self.post(("button", edge, at)))
        except BaseException:
            server.close()
            self._remove(options.socket)
            raise
        display = self._display or self._make_display()
        controller = Controller(hw, self._publish, display, self._poweroff, requests=self._requests)
        self.controller = controller

        selector = selectors.DefaultSelector()
        selector.register(server, selectors.EVENT_READ, "socket")
        selector.register(self._wake_r, selectors.EVENT_READ, "wake")

        try:
            controller.start(
                time.monotonic(),
                ready_timeout=options.ready_timeout if options.ready_port else 0.0,
                button_pressed=hw.button_pressed(),
            )
            if options.ready_port and options.ready_timeout > 0:
                threading.Thread(
                    target=wait_for_application,
                    args=(options.ready_port, self._stop_waiting, self.post),
                    name="ready",
                    daemon=True,
                ).start()

            notify_systemd("READY=1")
            self.ready.set()
            log("started, instance %s" % controller.instance)
            self._loop(controller, selector, server)
        finally:
            # Whatever ended the loop: outputs low, no state left looking live.
            self._stop_waiting.set()
            controller.stop(time.monotonic())
            hw.close()
            display.close()
            self._remove(options.state_file)
            server.close()
            self._remove(options.socket)
            log("stopped")
        return 0

    def _loop(self, controller, selector, server):
        while True:
            now = time.monotonic()
            controller.tick(now)
            notify_systemd("WATCHDOG=1")
            timeout = max(0.0, min(controller.next_deadline() - time.monotonic(), HEARTBEAT_S))
            for key, _mask in selector.select(timeout):
                if key.data == "wake":
                    try:
                        os.read(self._wake_r, 4096)
                    except OSError:
                        pass
                else:
                    # An error here ends the service (and systemd restarts it):
                    # a controller that no longer hears commands must not go on
                    # looking healthy.
                    self._serve(controller, server)
            if not self._drain(controller):
                return

    def _drain(self, controller):
        while True:
            try:
                event = self._events.get_nowait()
            except queue.Empty:
                return True
            now = time.monotonic()
            if event[0] == "terminate":
                return False
            if event[0] == "button":
                if event[1] == "down":
                    controller.button_down(event[2])
                else:
                    controller.button_up(event[2], now)
            elif event[0] == "app_ready":
                controller.app_ready(now)

    def _serve(self, controller, server):
        while True:
            try:
                data, address = server.recvfrom(MAX_DATAGRAM + 1)
            except BlockingIOError:
                return
            except InterruptedError:
                continue
            words, request_id = parse_request(data)
            if words is None:
                log("ignored a malformed command datagram")
                continue
            answer = controller.command(words, time.monotonic(), request_id)
            if not answer["ok"]:
                log("refused %r: %s" % (" ".join(words)[:40], answer.get("error")))
            if request_id is not None and address:
                try:
                    server.sendto(json.dumps(answer, separators=(",", ":")).encode(), address)
                except OSError:
                    pass  # the client left; its problem, not ours

    def _publish(self, state):
        write_state(self.options.state_file, state, self._group_id)

    def _make_display(self):
        options = self.options
        if options.no_display:
            return NoDisplay()
        return Display(options.display, options.xauthority)

    def _prepare_state_directory(self):
        """Our own directory: root-owned, readable by the application's group."""
        directory = os.path.dirname(self.options.state_file)
        os.makedirs(directory, mode=0o750, exist_ok=True)
        if os.geteuid() == 0:
            os.chown(directory, 0, self._group_id if self._group_id is not None else 0)
            os.chmod(directory, 0o750)
        self._remove(self.options.state_file)

    def _open_socket(self):
        """Binds the command socket at its historical path.

        /run/jukebox also holds the audio analyser's socket and is set up by
        the audio installation (owner jukebox, group jukebox-audio, setgid).
        If it exists it is used exactly as it is. It is created only when
        missing, owned by the application's user so that the application can
        still create its own socket there. Nothing but our own socket is ever
        removed from it.
        """
        path = self.options.socket
        directory = os.path.dirname(path)
        if not os.path.isdir(directory):
            os.makedirs(directory, mode=0o750)
            if os.geteuid() == 0 and self.options.socket_dir_owner:
                owner = pwd.getpwnam(self.options.socket_dir_owner)
                os.chown(directory, owner.pw_uid, owner.pw_gid)

        try:
            mode = os.lstat(path).st_mode
        except FileNotFoundError:
            mode = None
        if mode is not None:
            if not stat.S_ISSOCK(mode):
                raise SystemExit("%s exists and is not a socket; not touching it" % path)
            if socket_alive(path):
                raise SystemExit("another power controller already listens on %s" % path)
            os.unlink(path)  # left behind by a controller that was killed

        server = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        previous = os.umask(0o177)
        try:
            server.bind(path)
        finally:
            os.umask(previous)
        if os.geteuid() == 0:
            os.chown(path, 0, self._group_id if self._group_id is not None else 0)
        os.chmod(path, 0o660)
        server.setblocking(False)
        return server

    @staticmethod
    def _remove(path):
        try:
            os.unlink(path)
        except OSError:
            pass


def socket_alive(path):
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        probe.connect(path)
        return True
    except OSError as error:
        return error.errno not in (errno.ECONNREFUSED, errno.ENOENT)
    finally:
        probe.close()


def parse_request(data):
    """Returns (words, request_id), or (None, None) for something unusable."""
    if len(data) > MAX_DATAGRAM:
        return None, None
    try:
        text = data.decode("utf-8").strip()
    except UnicodeDecodeError:
        return None, None
    if text.startswith("{"):
        try:
            request = json.loads(text)
        except ValueError:
            return None, None
        words = request.get("cmd") if isinstance(request, dict) else None
        request_id = request.get("id") if isinstance(request, dict) else None
        if not isinstance(words, list) or not all(isinstance(word, str) for word in words):
            return None, None
        if not isinstance(request_id, str) or not 1 <= len(request_id) <= 64:
            return None, None
        return words, request_id
    # The original client: plain words, in any case, no answer expected.
    words = text.lower().split()
    return (words, None) if 1 <= len(words) <= 2 else (None, None)


# -- the client ----------------------------------------------------------------


def client(words, socket_path, timeout, wait=True):
    if not valid_command(words):
        print("unknown command: %s" % " ".join(words), file=sys.stderr)
        return EXIT_USAGE

    request_id = uuid.uuid4().hex
    request = json.dumps({"v": PROTOCOL, "id": request_id, "cmd": words}).encode()
    sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    reply_path = None
    try:
        if wait:
            # The answer needs an address to come back to. On Linux the kernel
            # assigns one that is not a file; elsewhere a temporary file is used.
            if sys.platform.startswith("linux"):
                sender.bind("")
            else:
                reply_path = tempfile.mktemp(prefix="jbpw-", dir="/tmp")
                sender.bind(reply_path)
        try:
            sender.sendto(request, socket_path)
        except OSError as error:
            print("cannot reach the power controller at %s: %s" % (socket_path, error), file=sys.stderr)
            return EXIT_UNREACHABLE
        if not wait:
            return EXIT_OK

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(
                    "no answer from the power controller: the command may or may not "
                    "have been applied",
                    file=sys.stderr,
                )
                return EXIT_NO_ANSWER
            sender.settimeout(remaining)
            try:
                data = sender.recv(65536)
            except socket.timeout:
                continue
            try:
                answer = json.loads(data.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if isinstance(answer, dict) and answer.get("id") == request_id:
                print(json.dumps(answer, separators=(",", ":")))
                return EXIT_OK if answer.get("ok") else EXIT_REFUSED
    finally:
        sender.close()
        if reply_path:
            try:
                os.unlink(reply_path)
            except OSError:
                pass


def build_parser():
    parser = argparse.ArgumentParser(
        description="Jukebox power controller: service (--daemon) and client.",
        epilog="Commands: disco|strip|decor|extra|amp toggle|on|off, standby on|off|toggle, "
        "shutdown, status. Exit status: 0 done, 1 usage, 2 refused, 3 no answer "
        "(unknown result), 4 controller unreachable.",
    )
    parser.add_argument("--daemon", action="store_true", help="run the service (root)")
    parser.add_argument("--socket", default=SOCKET_PATH, help="command socket (default %(default)s)")
    parser.add_argument("--state-file", default=STATE_FILE, help="daemon: published state (default %(default)s)")
    parser.add_argument("--group", default="jukebox", help="daemon: group allowed to read the state and send commands")
    parser.add_argument("--socket-dir-owner", default="jukebox", help="daemon: owner given to the socket directory if it has to be created")
    parser.add_argument("--display", default=":0", help="daemon: X display of the kiosk (default %(default)s)")
    parser.add_argument("--xauthority", default="/home/jukebox/.Xauthority", help="daemon: its X authority file (default %(default)s)")
    parser.add_argument("--no-display", action="store_true", help="daemon: leave the display alone (no xset)")
    parser.add_argument("--ready-port", type=int, default=4000, help="daemon: local port of the application, waited for at boot (0: do not wait)")
    parser.add_argument("--ready-timeout", type=float, default=90.0, help="daemon: longest wait for the application at boot, in seconds")
    parser.add_argument("--timeout", type=float, default=2.0, help="client: seconds to wait for the answer")
    parser.add_argument("--no-wait", action="store_true", help="client: send and exit without waiting for the answer")
    parser.add_argument("command", nargs="*", help="client command, for example: disco toggle")
    return parser


def main(argv=None):
    parser = build_parser()
    options = parser.parse_args(argv)

    if not options.daemon:
        if not options.command:
            parser.print_usage(sys.stderr)
            return EXIT_USAGE
        return client(options.command, options.socket, options.timeout, wait=not options.no_wait)

    if options.command:
        parser.error("--daemon takes no command")
    if os.geteuid() != 0:
        print("the daemon must run as root (it owns the GPIO lines)", file=sys.stderr)
        return EXIT_USAGE

    daemon = Daemon(options)
    signal.signal(signal.SIGTERM, lambda *_: daemon.request_stop())
    signal.signal(signal.SIGINT, lambda *_: daemon.request_stop())
    return daemon.run()


if __name__ == "__main__":
    sys.exit(main())
