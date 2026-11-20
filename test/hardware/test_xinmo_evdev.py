"""Tests of priv/hardware/xinmo_evdev.py without python-evdev or a real device.

    python3 -m unittest discover -s test/hardware -p 'test_*.py'

A fake device stands in for evdev.InputDevice: its "kernel side" is a pipe, so
the helper really sleeps in select() and really sees an unplug as a read error.
"""

import errno
import importlib.util
import io
import json
import os
import sys
import threading
import unittest

# The programs under test are loaded from where they ship: leave no
# __pycache__ behind in ops/ or priv/ (priv/ is copied into the release).
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "..", "priv", "hardware", "xinmo_evdev.py")

spec = importlib.util.spec_from_file_location("xinmo_evdev", HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

KEY, SYN, ABS = helper.EV_KEY, helper.EV_SYN, helper.EV_ABS
REPORT, DROPPED = helper.SYN_REPORT, helper.SYN_DROPPED


class FakeDevice:
    """Events queued with push() become readable, like on a real device."""

    def __init__(self, path, keys=(288, 289), held=(), has_axes=False):
        self.path = path
        self.keys = list(keys)
        self._held = list(held)
        self.has_axes = has_axes
        self.fd, self._feed = os.pipe()
        os.set_blocking(self.fd, False)
        self._pending = []
        self._lock = threading.Lock()
        self._fail = None
        self.closed = False

    def describe(self):
        return {
            "name": "Fake encoder",
            "vendor": 0x1234,
            "product": 0x5678,
            "version": 0x0100,
            "phys": "usb-fake/input0",
            "path": self.path,
            "real": "/dev/input/event9",
            "keys": self.keys,
            "held": self.held(),
            "abs": self.has_axes,
        }

    def held(self):
        return sorted(self._held)

    def set_held(self, codes):
        self._held = list(codes)

    def push(self, *events):
        with self._lock:
            self._pending.extend(events)
        os.write(self._feed, b"x")

    def unplug(self):
        self._fail = OSError(errno.ENODEV, "No such device")
        os.write(self._feed, b"x")

    def read(self):
        try:
            os.read(self.fd, 4096)
        except BlockingIOError:
            pass
        if self._fail:
            raise self._fail
        with self._lock:
            events, self._pending = self._pending, []
        return events

    def close(self):
        if not self.closed:
            self.closed = True
            os.close(self.fd)
            os.close(self._feed)


class Parent:
    """The application's side of the helper's standard input."""

    def __init__(self):
        self.read_fd, self.write_fd = os.pipe()
        self.watch = helper.ParentWatch(self.read_fd)

    def leave(self):
        os.close(self.write_fd)


class Output(io.StringIO):
    def __init__(self):
        super().__init__()
        self._condition = threading.Condition()

    def write(self, text):
        with self._condition:
            result = super().write(text)
            self._condition.notify_all()
            return result

    def messages(self):
        with self._condition:
            return [json.loads(line) for line in self.getvalue().splitlines() if line]

    def wait_for(self, predicate, timeout=5.0):
        with self._condition:
            found = self._condition.wait_for(
                lambda: any(
                    predicate(json.loads(line)) for line in self.getvalue().splitlines() if line
                ),
                timeout,
            )
        return found


class KeyStreamTest(unittest.TestCase):
    def feed(self, stream, *events):
        messages = []
        for etype, code, value in events:
            messages += stream.feed(etype, code, value, 1000)
        return messages

    def test_only_key_events_are_reported(self):
        stream = helper.KeyStream(lambda: [])
        messages = self.feed(
            stream,
            (KEY, 288, 1),
            (SYN, REPORT, 0),
            (ABS, 0, 127),
            (4, 4, 589825),  # EV_MSC scan code
            (KEY, 288, 2),
            (KEY, 288, 0),
            (SYN, REPORT, 0),
        )
        self.assertEqual(
            messages,
            [
                {"t": "key", "c": 288, "v": 1, "ms": 1000},
                {"t": "key", "c": 288, "v": 2, "ms": 1000},
                {"t": "key", "c": 288, "v": 0, "ms": 1000},
            ],
        )

    def test_after_syn_dropped_events_are_discarded_until_the_next_report(self):
        held = [289]
        stream = helper.KeyStream(lambda: held)
        messages = self.feed(
            stream,
            (KEY, 288, 1),
            (SYN, DROPPED, 0),
            (KEY, 290, 1),  # tail of a packet whose start was lost
            (KEY, 288, 0),
            (SYN, REPORT, 0),
            (KEY, 291, 1),
            (SYN, REPORT, 0),
        )
        self.assertEqual(
            messages,
            [
                {"t": "key", "c": 288, "v": 1, "ms": 1000},
                {"t": "resync", "held": [289], "ms": 1000},
                {"t": "key", "c": 291, "v": 1, "ms": 1000},
            ],
        )

    def test_odd_values_are_dropped(self):
        stream = helper.KeyStream(lambda: [])
        self.assertEqual(self.feed(stream, (KEY, 288, 3), (KEY, 288, -1)), [])


class RunTest(unittest.TestCase):
    def setUp(self):
        self.parent = Parent()
        self.out = Output()
        self.devices = []
        self.failures = []
        self.result = None
        self._saved = (helper.RETRY_MIN_S, helper.RETRY_MAX_S)
        helper.RETRY_MIN_S, helper.RETRY_MAX_S = 0.01, 0.02
        self.addCleanup(self.restore)

    def restore(self):
        helper.RETRY_MIN_S, helper.RETRY_MAX_S = self._saved

    def opener(self, path):
        if self.failures:
            raise self.failures.pop(0)
        device = FakeDevice(path, held=self.next_held)
        self.devices.append(device)
        return device

    next_held = ()

    def start(self):
        def target():
            self.result = helper.run(
                "/dev/input/by-id/fake", opener=self.opener, parent=self.parent.watch, out=self.out
            )

        self.thread = threading.Thread(target=target, daemon=True)
        self.thread.start()

    def finish(self):
        self.parent.leave()
        self.thread.join(5)
        self.assertFalse(self.thread.is_alive(), "the helper did not exit with its parent")
        return self.out.messages()

    def test_connects_reports_keys_and_exits_with_its_parent(self):
        self.next_held = (289,)
        self.start()
        self.assertTrue(self.out.wait_for(lambda m: m["t"] == "connected"))
        self.devices[0].push((KEY, 288, 1, 5), (SYN, REPORT, 0, 5), (KEY, 288, 0, 60))
        self.assertTrue(self.out.wait_for(lambda m: m == {"t": "key", "c": 288, "v": 0, "ms": 60}))

        messages = self.finish()
        self.assertEqual(self.result, 0)
        self.assertEqual(messages[0], {"t": "hello", "v": 1})
        connected = messages[1]
        self.assertEqual(connected["t"], "connected")
        self.assertEqual(connected["held"], [289], "a key held at connection is reported as held")
        self.assertEqual(connected["keys"], [288, 289])
        self.assertEqual(
            [m for m in messages if m["t"] == "key"],
            [{"t": "key", "c": 288, "v": 1, "ms": 5}, {"t": "key", "c": 288, "v": 0, "ms": 60}],
        )
        self.assertTrue(self.devices[0].closed)

    def test_a_missing_device_is_announced_once_and_retried(self):
        self.failures = [FileNotFoundError(errno.ENOENT, "x")] * 5 + [
            PermissionError(errno.EACCES, "x")
        ] * 3
        self.start()
        self.assertTrue(self.out.wait_for(lambda m: m["t"] == "connected"))
        messages = self.finish()
        self.assertEqual(
            [m for m in messages if m["t"] == "waiting"],
            [{"t": "waiting", "reason": "enoent"}, {"t": "waiting", "reason": "eacces"}],
            "one message per reason, not one per attempt",
        )

    def test_unplug_and_replug(self):
        self.start()
        self.assertTrue(self.out.wait_for(lambda m: m["t"] == "connected"))
        first = self.devices[0]
        first.push((KEY, 288, 1, 1))
        self.assertTrue(self.out.wait_for(lambda m: m["t"] == "key"))

        self.next_held = (288,)  # still held when it comes back
        first.unplug()
        self.assertTrue(self.out.wait_for(lambda m: m["t"] == "disconnected"))
        self.assertTrue(
            self.out.wait_for(lambda m: m["t"] == "connected" and m["held"] == [288])
        )

        messages = self.finish()
        self.assertTrue(first.closed, "the old handle is closed")
        self.assertEqual(len(self.devices), 2)
        kinds = [m["t"] for m in messages]
        self.assertEqual(kinds, ["hello", "connected", "key", "disconnected", "connected"])
        self.assertEqual(messages[3]["reason"], "enodev")

    def test_the_parent_leaving_while_the_device_is_missing_ends_the_helper(self):
        self.failures = [FileNotFoundError(errno.ENOENT, "x")] * 10_000
        self.start()
        self.assertTrue(self.out.wait_for(lambda m: m["t"] == "waiting"))
        self.finish()
        self.assertEqual(self.result, 0)

    def test_a_missing_evdev_module_has_its_own_exit_status(self):
        self.failures = [ImportError("No module named 'evdev'")]
        self.start()
        self.thread.join(5)
        self.assertEqual(self.result, 3)


class DiagnoseTest(unittest.TestCase):
    def test_prints_codes_and_an_unfilled_template(self):
        out = io.StringIO()
        device = FakeDevice("/dev/input/by-id/fake", has_axes=True)

        def read_then_stop():
            if not read_then_stop.done:
                read_then_stop.done = True
                return [(KEY, 289, 1, 1), (KEY, 289, 2, 2), (KEY, 289, 0, 3), (ABS, 0, 255, 4)]
            raise KeyboardInterrupt

        read_then_stop.done = False
        device.read = read_then_stop
        os.write(device._feed, b"x")

        self.assertEqual(helper.diagnose("/dev/input/by-id/fake", opener=lambda path: device, out=out), 0)
        text = out.getvalue()
        self.assertIn("Fake encoder", text)
        self.assertIn("vendor 0x1234  product 0x5678", text)
        self.assertIn("press    code=289", text)
        self.assertIn("release  code=289", text)
        self.assertIn("repeat   code=289", text)
        self.assertIn("axis 0 moved: ignored", text)
        self.assertIn("in order of first press: 289", text)
        self.assertIn("JUKEBOX_BUTTONS_DEVICE=/dev/input/by-id/fake", text)
        for action in helper.ACTIONS:
            # Left empty: no code is ever suggested for an action.
            self.assertIn("JUKEBOX_BUTTON_%s=\n" % action, text + "\n")
        self.assertTrue(device.closed)

    def test_device_paths_outside_dev_input_are_refused(self):
        with self.assertRaises(OSError):
            helper.check_path("/etc/passwd")
        with self.assertRaises(OSError):
            helper.check_path("/dev/null")


if __name__ == "__main__":
    unittest.main()
