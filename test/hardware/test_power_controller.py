"""Tests of ops/hardware/jukebox-power-controller.py without a Raspberry Pi.

    python3 -m unittest discover -s test/hardware -p 'test_*.py'

The controller's decisions are tested with a fake GPIO and an explicit clock;
the service loop and the client are tested over a real Unix socket in a
temporary directory.
"""

import importlib.util
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest

# The programs under test are loaded from where they ship: leave no
# __pycache__ behind in ops/ or priv/ (priv/ is copied into the release).
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
PROGRAM = os.path.join(HERE, "..", "..", "ops", "hardware", "jukebox-power-controller.py")

spec = importlib.util.spec_from_file_location("power_controller", PROGRAM)
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)


# Most tests start with every light requested off, so that what they switch
# on is what they asked for. The real starting requests have their own tests.
QUIET = {"amp": True, "disco": False, "strip": False, "decor": False, "extra": False}


class FakeHardware:
    def __init__(self, pressed=False):
        self.levels = dict((name, False) for name in pc.OUTPUTS)
        self.history = []
        self.pressed = pressed
        self.closed = False

    def set(self, name, level):
        self.levels[name] = level
        self.history.append((name, level))

    def get(self, name):
        return self.levels[name]

    def button_pressed(self):
        return self.pressed

    def close(self):
        self.closed = True

    def on(self):
        return sorted(name for name, level in self.levels.items() if level)


class FakeDisplay:
    def __init__(self):
        self.calls = []

    def set(self, on):
        self.calls.append(on)

    def close(self):
        pass


class Harness:
    def __init__(self, pressed=False, ready_timeout=0.0, requests=QUIET):
        self.hw = FakeHardware(pressed)
        self.display = FakeDisplay()
        self.published = []
        self.poweroffs = 0
        self.now = 100.0
        self.controller = pc.Controller(
            self.hw,
            self.published.append,
            self.display,
            self._poweroff,
            instance="test",
            pid=1,
            requests=requests,
        )
        self.controller.start(self.now, ready_timeout=ready_timeout, button_pressed=pressed)

    def _poweroff(self):
        self.poweroffs += 1

    def advance(self, seconds):
        self.now += seconds
        self.controller.tick(self.now)

    def press(self, seconds):
        self.controller.button_down(self.now)
        self.now += seconds
        self.controller.button_up(self.now, self.now)
        self.controller.tick(self.now)

    def command(self, *words, request_id=None):
        return self.controller.command(list(words), self.now, request_id)

    @property
    def state(self):
        return self.published[-1]


class ControllerTest(unittest.TestCase):
    def test_outputs_start_low_and_the_amplifier_follows_after_its_delay(self):
        h = Harness()
        self.assertEqual(h.state["mode"], "awake")
        self.assertEqual(h.hw.on(), [])
        h.advance(1.4)
        self.assertEqual(h.hw.on(), [])
        h.advance(0.2)
        self.assertEqual(h.hw.on(), ["amp"])
        self.assertEqual(h.state["outputs"]["amp"], {"gpio": 17, "requested": True, "applied": True})

    def test_boot_waits_for_the_application_but_not_for_ever(self):
        h = Harness(ready_timeout=90.0)
        self.assertEqual(h.state["mode"], "booting")
        h.advance(30)
        self.assertEqual(h.hw.on(), [])
        h.controller.app_ready(h.now)
        self.assertEqual(h.state["mode"], "awake")
        h.advance(2)
        self.assertEqual(h.hw.on(), ["amp"])

        late = Harness(ready_timeout=90.0)
        late.advance(91)
        self.assertEqual(late.state["mode"], "awake")

    def test_light_commands_and_their_published_state(self):
        h = Harness()
        answer = h.command("disco", "toggle", request_id="a")
        self.assertTrue(answer["ok"])
        self.assertEqual(answer["revision"], h.state["revision"])
        self.assertEqual(h.hw.on(), ["disco"])
        self.assertEqual(h.state["outputs"]["disco"], {"gpio": 27, "requested": True, "applied": True})

        self.assertTrue(h.command("strip", "on")["ok"])
        revision = h.state["revision"]
        self.assertTrue(h.command("strip", "on")["ok"])
        self.assertEqual(h.state["revision"], revision, "an idempotent command changes nothing")
        self.assertTrue(h.command("disco", "off")["ok"])
        self.assertEqual(h.hw.on(), ["strip"])

    def test_a_repeated_request_id_is_answered_without_being_run_again(self):
        h = Harness()
        first = h.command("disco", "toggle", request_id="same")
        again = h.command("disco", "toggle", request_id="same")
        self.assertTrue(first["ok"] and again["ok"])
        self.assertTrue(again["duplicate"])
        self.assertEqual(h.hw.on(), ["disco"], "toggled once, not twice")
        self.assertEqual(again["revision"], first["revision"])

    def test_unknown_and_malformed_commands_are_refused(self):
        h = Harness()
        for words in (["disco"], ["disco", "blink"], ["lamp", "on"], ["rm", "-rf"], [], ["disco", "on", "now"]):
            answer = h.controller.command(words, h.now, "x" + "".join(words))
            self.assertFalse(answer["ok"])
            self.assertEqual(answer["error"], "unknown_command")
        self.assertEqual(h.hw.on(), [])

    def test_short_press_is_standby_and_resume(self):
        h = Harness()
        h.command("disco", "on")
        h.advance(2)
        self.assertEqual(h.hw.on(), ["amp", "disco"])

        h.press(0.2)
        self.assertEqual(h.state["mode"], "standby")
        self.assertEqual(h.hw.on(), [])
        self.assertEqual(h.hw.history[-2:], [("amp", False), ("disco", False)], "amplifier first")
        self.assertTrue(h.state["outputs"]["disco"]["requested"], "the request is kept")
        self.assertFalse(h.state["outputs"]["disco"]["applied"])
        self.assertEqual(h.display.calls[-1], False)

        h.press(0.2)
        self.assertEqual(h.state["mode"], "awake")
        self.assertEqual(h.hw.on(), ["disco"], "lights at once, amplifier after its delay")
        self.assertEqual(h.display.calls[-1], True)
        h.advance(1.6)
        self.assertEqual(h.hw.on(), ["amp", "disco"])

    def test_the_starting_requests_are_those_of_the_original_program(self):
        self.assertEqual(
            pc.DEFAULT_REQUESTS,
            {"amp": True, "disco": False, "strip": True, "decor": True, "extra": True},
        )
        h = Harness(requests=None, ready_timeout=90.0)
        self.assertEqual(h.hw.on(), [], "everything low until the application is ready")
        self.assertEqual(
            [name for name, output in h.state["outputs"].items() if output["requested"]],
            ["amp", "strip", "decor", "extra"],
        )

        h.controller.app_ready(h.now)
        self.assertEqual(h.hw.on(), ["decor", "extra", "strip"], "the lights, not yet the amplifier")
        h.advance(1.6)
        self.assertEqual(h.hw.on(), ["amp", "decor", "extra", "strip"])

        # The strip button's first press therefore switches the strip OFF.
        h.command("strip", "toggle")
        self.assertEqual(h.hw.on(), ["amp", "decor", "extra"])
        h.command("disco", "toggle")
        self.assertEqual(h.hw.on(), ["amp", "decor", "disco", "extra"])

    def test_requests_are_restored_after_standby_not_reset(self):
        h = Harness(requests=None)
        h.advance(2)
        h.command("strip", "off")
        h.command("disco", "on")
        h.press(0.2)
        self.assertEqual(h.hw.on(), [])
        h.press(0.2)
        h.advance(2)
        self.assertEqual(h.hw.on(), ["amp", "decor", "disco", "extra"])

    def test_a_command_during_standby_is_kept_and_applied_on_resume(self):
        h = Harness()
        h.advance(2)
        h.press(0.2)
        self.assertEqual(h.state["mode"], "standby")

        answer = h.command("disco", "toggle", request_id="in-standby")
        self.assertTrue(answer["ok"])
        self.assertEqual(h.hw.on(), [], "nothing is driven while in standby")
        self.assertEqual(h.state["outputs"]["disco"], {"gpio": 27, "requested": True, "applied": False})

        h.press(0.2)
        self.assertEqual(h.hw.on(), ["disco"])

    def test_a_command_during_boot_is_kept_and_applied_when_awake(self):
        h = Harness(ready_timeout=90.0)
        self.assertTrue(h.command("disco", "on")["ok"])
        self.assertEqual(h.hw.on(), [])
        h.controller.app_ready(h.now)
        self.assertEqual(h.hw.on(), ["disco"])

    def test_the_amplifier_can_be_commanded_like_in_the_original(self):
        h = Harness()
        h.advance(2)
        self.assertEqual(h.hw.on(), ["amp"])

        self.assertTrue(h.command("amp", "off")["ok"])
        self.assertEqual(h.hw.on(), [])
        self.assertEqual(h.state["outputs"]["amp"], {"gpio": 17, "requested": False, "applied": False})

        # Requested off: a resume does not switch it on behind the user's back.
        h.press(0.2)
        h.press(0.2)
        h.advance(2)
        self.assertEqual(h.hw.on(), [])

        self.assertTrue(h.command("amp", "toggle")["ok"])
        self.assertEqual(h.hw.on(), ["amp"], "at once: the delay after waking has passed")

        # Asked for during the delay, it still waits for the delay.
        h.command("amp", "off")
        h.press(0.2)
        h.press(0.2)
        h.command("amp", "on")
        self.assertEqual(h.hw.on(), [])
        h.advance(1.6)
        self.assertEqual(h.hw.on(), ["amp"])

    def test_the_display_follows_the_mode(self):
        h = Harness()
        self.assertEqual(h.display.calls, [True])
        h.press(0.2)
        h.press(0.2)
        self.assertEqual(h.display.calls, [True, False, True])
        h.command("shutdown")
        self.assertEqual(h.display.calls, [True, False, True, False], "off for the shutdown too")

    def test_standby_during_the_amplifier_delay_cancels_it(self):
        h = Harness()
        h.advance(1.0)
        h.press(0.2)
        self.assertEqual(h.state["mode"], "standby")
        h.advance(10)
        self.assertEqual(h.hw.on(), [])
        self.assertNotIn(("amp", True), h.hw.history)

    def test_long_press_shuts_down_on_release_only(self):
        h = Harness()
        h.command("disco", "on")
        h.advance(2)
        h.controller.button_down(h.now)
        h.advance(5)
        self.assertEqual(h.poweroffs, 0, "nothing happens while the button is still held")
        self.assertEqual(h.state["mode"], "awake")
        h.controller.button_up(h.now, h.now)
        self.assertEqual(h.poweroffs, 1)
        self.assertEqual(h.state["mode"], "shutting_down")
        self.assertEqual(h.hw.on(), [])

    def test_nothing_comes_back_on_after_shutdown_started(self):
        h = Harness()
        h.advance(0.5)  # the amplifier delay is running
        self.assertTrue(h.command("shutdown")["ok"])
        self.assertEqual(h.poweroffs, 1)
        h.advance(10)
        h.press(0.2)
        h.controller.app_ready(h.now)
        self.assertEqual(h.command("disco", "on")["error"], "shutting_down")
        self.assertEqual(h.command("standby", "off")["error"], "shutting_down")
        self.assertEqual(h.hw.on(), [])
        self.assertEqual(h.poweroffs, 1)
        self.assertEqual(h.state["mode"], "shutting_down")

    def test_shutdown_during_boot_never_switches_anything_on(self):
        h = Harness(ready_timeout=90.0)
        h.controller.button_down(h.now)
        h.now += 3.5
        h.controller.button_up(h.now, h.now)
        self.assertEqual(h.state["mode"], "shutting_down")
        h.controller.app_ready(h.now)
        h.advance(120)
        self.assertEqual(h.hw.history, [])

    def test_sigterm_drops_everything_and_cancels_pending_timers(self):
        h = Harness()
        h.command("strip", "on")
        h.advance(0.5)
        h.controller.stop(h.now)
        self.assertEqual(h.hw.on(), [])
        written = len(h.published)
        h.advance(10)
        h.press(0.2)
        self.assertEqual(h.command("strip", "on")["error"], "stopping")
        self.assertEqual(h.hw.on(), [])
        self.assertEqual(len(h.published), written, "no heartbeat after the stop")

    def test_a_button_held_at_start_is_not_a_press(self):
        h = Harness(pressed=True)
        h.now += 5
        h.controller.button_up(h.now, h.now)
        self.assertEqual(h.state["mode"], "awake")
        self.assertEqual(h.poweroffs, 0)
        h.press(0.2)
        self.assertEqual(h.state["mode"], "standby")

    def test_a_glitch_is_ignored(self):
        h = Harness()
        h.press(0.005)
        self.assertEqual(h.state["mode"], "awake")

    def test_standby_commands(self):
        h = Harness()
        h.command("standby", "on")
        self.assertEqual(h.state["mode"], "standby")
        h.command("standby", "on")
        self.assertEqual(h.state["mode"], "standby")
        h.command("standby", "toggle")
        self.assertEqual(h.state["mode"], "awake")
        h.command("standby", "off")
        self.assertEqual(h.state["mode"], "awake")

    def test_heartbeat_at_most_once_per_second_and_revision_only_on_change(self):
        h = Harness()
        h.advance(2)  # amplifier on
        revision, writes = h.state["revision"], len(h.published)
        for _ in range(40):
            h.advance(0.25)
        self.assertEqual(h.state["revision"], revision)
        self.assertIn(len(h.published) - writes, (9, 10, 11))
        self.assertGreater(h.state["heartbeat"], writes)
        self.assertEqual(h.command("status")["revision"], revision)

    def test_state_document(self):
        h = Harness()
        state = h.state
        self.assertEqual(state["schema"], 1)
        self.assertEqual(state["instance"], "test")
        self.assertEqual(state["pid"], 1)
        self.assertIsInstance(state["boottime"], float)
        self.assertEqual(list(state["outputs"]), ["amp", "disco", "strip", "decor", "extra"])
        self.assertEqual(
            [output["gpio"] for output in state["outputs"].values()], [17, 27, 22, 23, 24]
        )
        json.dumps(state)


class RequestParsingTest(unittest.TestCase):
    def test_json_and_legacy_requests(self):
        self.assertEqual(
            pc.parse_request(b'{"v":1,"id":"abc","cmd":["disco","toggle"]}'),
            (["disco", "toggle"], "abc"),
        )
        self.assertEqual(pc.parse_request(b"disco toggle\n"), (["disco", "toggle"], None))
        self.assertEqual(pc.parse_request(b"shutdown"), (["shutdown"], None))
        # The original lower-cased what it received.
        self.assertEqual(pc.parse_request(b"  DISCO Toggle "), (["disco", "toggle"], None))

    def test_unusable_requests(self):
        for data in (
            b"",
            b"a b c",
            b"\xff\xfe",
            b"{not json",
            b'{"id":"abc"}',
            b'{"id":"abc","cmd":"disco toggle"}',
            b'{"id":7,"cmd":["status"]}',
            b'{"cmd":["status"]}',
            b"x" * 2000,
        ):
            self.assertEqual(pc.parse_request(data), (None, None), data[:20])


class DaemonTest(unittest.TestCase):
    """The service loop and the client, over a real socket."""

    def setUp(self):
        # Unix socket paths are short: not under the (long) default temp dir.
        self.root = tempfile.mkdtemp(prefix="jbpw", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.socket_dir = os.path.join(self.root, "jukebox")
        self.socket_path = os.path.join(self.socket_dir, "power-control.sock")
        self.state_file = os.path.join(self.root, "jukebox-power", "state.json")
        self.hw = FakeHardware()
        self.poweroffs = []
        self.thread = None
        self.daemon = None

    def start(self):
        options = types.SimpleNamespace(
            socket=self.socket_path,
            state_file=self.state_file,
            group="",
            socket_dir_owner="",
            display=":0",
            xauthority="/nonexistent/.Xauthority",
            no_display=True,
            ready_port=0,
            ready_timeout=0.0,
        )
        self.daemon = pc.Daemon(
            options,
            hw=self.hw,
            display=FakeDisplay(),
            poweroff_fn=lambda: self.poweroffs.append(1),
            requests=QUIET,
        )
        self.thread = threading.Thread(target=self.daemon.run, daemon=True)
        self.thread.start()
        self.assertTrue(self.daemon.ready.wait(5), "the service did not start")
        self.addCleanup(self.stop)

    def stop(self):
        if self.thread and self.thread.is_alive():
            self.daemon.request_stop()
            self.thread.join(5)

    def run_client(self, *words, timeout="2"):
        result = subprocess.run(
            [sys.executable, PROGRAM, "--socket", self.socket_path, "--timeout", timeout] + list(words),
            capture_output=True,
            text=True,
            timeout=10,
        )
        answer = json.loads(result.stdout) if result.stdout.strip() else None
        return result.returncode, answer

    def read_state(self):
        with open(self.state_file) as handle:
            return json.load(handle)

    def test_client_commands_are_acknowledged_and_published(self):
        self.start()
        code, answer = self.run_client("disco", "toggle")
        self.assertEqual(code, pc.EXIT_OK)
        self.assertTrue(answer["ok"])
        self.assertEqual(self.hw.on(), ["disco"])

        state = self.read_state()
        self.assertEqual(state["instance"], answer["instance"])
        self.assertGreaterEqual(state["revision"], answer["revision"])
        self.assertTrue(state["outputs"]["disco"]["applied"])

        code, answer = self.run_client("status")
        self.assertEqual((code, answer["mode"]), (pc.EXIT_OK, "awake"))

    def test_a_refused_command_has_its_own_exit_status(self):
        self.start()
        # In standby a light command is accepted and kept for the resume...
        self.assertEqual(self.run_client("standby", "on")[0], pc.EXIT_OK)
        code, answer = self.run_client("disco", "toggle")
        self.assertEqual(code, pc.EXIT_OK)
        self.assertEqual(answer["outputs"]["disco"], {"gpio": 27, "requested": True, "applied": False})
        self.assertEqual(self.hw.on(), [])

        # ...but once a shutdown has begun, nothing is.
        self.assertEqual(self.run_client("shutdown")[0], pc.EXIT_OK)
        code, answer = self.run_client("disco", "toggle")
        self.assertEqual((code, answer["error"]), (pc.EXIT_REFUSED, "shutting_down"))
        self.assertEqual(self.hw.on(), [])
        self.assertEqual(self.poweroffs, [1])

    def test_wrong_usage_reaches_nothing(self):
        self.start()
        self.assertEqual(self.run_client("disco", "explode")[0], pc.EXIT_USAGE)
        self.assertEqual(self.hw.history, [])

    def test_no_controller_is_reported_as_unreachable(self):
        os.makedirs(self.socket_dir)
        self.assertEqual(self.run_client("disco", "toggle")[0], pc.EXIT_UNREACHABLE)

    def test_a_controller_that_does_not_answer_gives_the_uncertain_status(self):
        os.makedirs(self.socket_dir)
        mute = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        mute.bind(self.socket_path)
        self.addCleanup(mute.close)
        self.assertEqual(self.run_client("disco", "toggle", timeout="0.3")[0], pc.EXIT_NO_ANSWER)

    def test_the_former_text_datagram_still_works(self):
        self.start()
        legacy = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        legacy.sendto(b"Strip TOGGLE\n", self.socket_path)
        legacy.close()
        deadline = time.time() + 3
        while self.hw.on() != ["strip"] and time.time() < deadline:
            time.sleep(0.02)
        self.assertEqual(self.hw.on(), ["strip"])

    def test_the_state_file_is_private_and_removed_on_exit(self):
        self.start()
        mode = stat.S_IMODE(os.stat(self.state_file).st_mode)
        self.assertEqual(mode, 0o640)
        self.assertEqual(stat.S_IMODE(os.stat(self.socket_path).st_mode), 0o660)
        self.assertEqual(
            [name for name in os.listdir(os.path.dirname(self.state_file)) if name != "state.json"],
            [],
            "no temporary file left behind",
        )
        self.run_client("disco", "on")
        self.stop()
        self.assertFalse(os.path.exists(self.state_file))
        self.assertFalse(os.path.exists(self.socket_path))
        self.assertEqual(self.hw.on(), [], "outputs low on exit")
        self.assertTrue(self.hw.closed)

    def test_the_socket_directory_and_other_sockets_are_left_alone(self):
        # As prepared by the audio installation, with the analyser's socket in it.
        os.makedirs(self.socket_dir, mode=0o750)
        analyser = os.path.join(self.socket_dir, "audio-analysis.sock")
        other = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        other.bind(analyser)
        self.addCleanup(other.close)
        before = os.stat(self.socket_dir)

        self.start()
        self.stop()

        after = os.stat(self.socket_dir)
        self.assertEqual((before.st_mode, before.st_uid, before.st_gid), (after.st_mode, after.st_uid, after.st_gid))
        self.assertTrue(stat.S_ISSOCK(os.lstat(analyser).st_mode), "the analyser's socket is still there")

    def test_a_second_controller_refuses_to_start(self):
        self.start()
        options = self.daemon.options
        second = pc.Daemon(options, hw=FakeHardware(), display=FakeDisplay(), poweroff_fn=lambda: None)
        with self.assertRaises(SystemExit):
            second.run()
        self.assertTrue(os.path.exists(self.state_file), "the first one's state is untouched")
        self.assertEqual(self.run_client("status")[0], pc.EXIT_OK, "and it still answers")

    def test_a_stale_socket_is_replaced_but_another_file_is_not(self):
        os.makedirs(self.socket_dir)
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        stale.bind(self.socket_path)
        stale.close()
        self.start()
        self.assertEqual(self.run_client("status")[0], pc.EXIT_OK)
        self.stop()

        with open(self.socket_path, "w") as handle:
            handle.write("not a socket")
        blocked = pc.Daemon(self.daemon.options, hw=FakeHardware(), display=FakeDisplay(), poweroff_fn=lambda: None)
        with self.assertRaises(SystemExit):
            blocked.run()
        self.assertTrue(os.path.isfile(self.socket_path))

    def test_power_button_edges_reach_the_controller(self):
        self.start()
        now = time.monotonic()
        self.daemon.post(("button", "down", now - 0.3))
        self.daemon.post(("button", "up", now))
        deadline = time.time() + 3
        while self.read_state()["mode"] != "standby" and time.time() < deadline:
            time.sleep(0.02)
        self.assertEqual(self.read_state()["mode"], "standby")


class SystemAccessTest(unittest.TestCase):
    """What the service runs and asks of the system, without running it."""

    def test_the_display_is_driven_with_the_original_xset_command_and_a_time_limit(self):
        calls = []
        done = threading.Event()

        def fake_run(argv, **options):
            calls.append((argv, options))
            if len(calls) == 2:
                done.set()

        original, pc.subprocess.run = pc.subprocess.run, fake_run
        self.addCleanup(setattr, pc.subprocess, "run", original)

        display = pc.Display(":0", "/home/jukebox/.Xauthority")
        self.addCleanup(display.close)
        display.set(False)
        time.sleep(0.1)
        display.set(True)
        self.assertTrue(done.wait(3))

        self.assertEqual(
            [argv for argv, _options in calls],
            [["/usr/bin/xset", "dpms", "force", "off"], ["/usr/bin/xset", "dpms", "force", "on"]],
        )
        for _argv, options in calls:
            self.assertEqual(options["env"]["DISPLAY"], ":0")
            self.assertEqual(options["env"]["XAUTHORITY"], "/home/jukebox/.Xauthority")
            self.assertEqual(options["timeout"], pc.XSET_TIMEOUT_S)
            self.assertNotIn("shell", options)

    def test_a_slow_x_server_never_blocks_the_caller_and_only_the_last_wish_runs(self):
        calls = []
        release = threading.Event()

        def slow_run(argv, **options):
            calls.append(argv[-1])
            release.wait(3)

        original, pc.subprocess.run = pc.subprocess.run, slow_run
        self.addCleanup(setattr, pc.subprocess, "run", original)

        display = pc.Display(":0", "/x")
        self.addCleanup(display.close)
        started = time.monotonic()
        display.set(False)
        time.sleep(0.1)
        for on in (True, False, True, False, True):
            display.set(on)
        self.assertLess(time.monotonic() - started, 1.0, "set() returns at once")
        release.set()
        deadline = time.time() + 3
        while len(calls) < 2 and time.time() < deadline:
            time.sleep(0.02)
        self.assertEqual(calls, ["off", "on"], "the wishes in between were replaced")

    def test_the_application_is_ready_on_a_successful_http_answer_only(self):
        import http.server

        answers = {"status": 503}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(answers["status"])
                self.end_headers()
                self.wfile.write(b"ok")

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)

        stop = threading.Event()
        self.addCleanup(stop.set)
        events = []
        ready = threading.Event()

        def post(event):
            events.append(event)
            ready.set()

        threading.Thread(
            target=pc.wait_for_application, args=(server.server_address[1], stop, post), daemon=True
        ).start()

        # Listening, but answering an error: Phoenix is not serving its page yet.
        self.assertFalse(ready.wait(1.5))
        answers["status"] = 200
        self.assertTrue(ready.wait(5))
        self.assertEqual(events, [("app_ready",)])

    def test_the_gpio_and_button_settings_of_the_original_are_kept(self):
        self.assertEqual(dict(pc.OUTPUTS), {"amp": 17, "disco": 27, "strip": 22, "decor": 23, "extra": 24})
        self.assertEqual(pc.POWER_BUTTON_GPIO, 3)
        self.assertEqual(pc.BUTTON_BOUNCE_S, 0.08)
        self.assertEqual(pc.HOLD_SHUTDOWN_S, 3.0)
        self.assertEqual(pc.AMP_DELAY_S, 1.5)
        self.assertEqual(pc.SOCKET_PATH, "/run/jukebox/power-control.sock")


if __name__ == "__main__":
    unittest.main()
