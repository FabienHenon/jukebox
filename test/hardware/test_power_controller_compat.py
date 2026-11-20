"""The new power controller against the original one.

Both are driven with the same random sequences of commands and Power-button
presses; after every step the level of every output and the commands sent to
the display must be the same. The original (fixtures/) runs with gpiozero,
subprocess and sleep replaced by stand-ins.

Known, deliberate differences, left out of the comparison:

  * a repeated identical display command ("on" when already on) is not
    always repeated by the new controller;
  * an output command received before the application has answered lights
    its lamp at once in the original; the new controller keeps the request
    and applies it when the jukebox becomes awake;
  * the amplifier delay is a cancellable timer instead of a sleep, so levels
    are compared once the delay has passed.
"""

import importlib.util
import os
import random
import sys
import types
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
ORIGINAL = os.path.join(HERE, "fixtures", "original_power_controller.py")
PROGRAM = os.path.join(HERE, "..", "..", "ops", "hardware", "jukebox-power-controller.py")

spec = importlib.util.spec_from_file_location("power_controller_new", PROGRAM)
new = importlib.util.module_from_spec(spec)
spec.loader.exec_module(new)


class StubOutput:
    def __init__(self, pin, active_high=True, initial_value=False):
        self.value = bool(initial_value)

    def on(self):
        self.value = True

    def off(self):
        self.value = False

    def close(self):
        pass


class StubButton:
    def __init__(self, *args, **kwargs):
        pass


def load_original():
    """A fresh copy of the original module, with its hardware stubbed."""
    sys.modules["gpiozero"] = types.SimpleNamespace(Button=StubButton, OutputDevice=StubOutput)
    try:
        original_spec = importlib.util.spec_from_file_location("power_controller_original", ORIGINAL)
        module = importlib.util.module_from_spec(original_spec)
        original_spec.loader.exec_module(module)
    finally:
        del sys.modules["gpiozero"]

    module.calls = []
    module.subprocess = types.SimpleNamespace(
        run=lambda argv, **options: module.calls.append(argv),
        Popen=lambda argv, **options: module.calls.append(argv),
        DEVNULL=None,
    )
    module.clock = [1000.0]
    module.time = types.SimpleNamespace(sleep=lambda seconds: None, monotonic=lambda: module.clock[0])
    module.outputs = dict((name, StubOutput(pin)) for name, pin in module.PINS.items())
    return module


class Hardware:
    def __init__(self):
        self.levels = dict((name, False) for name in new.OUTPUTS)

    def set(self, name, level):
        self.levels[name] = level

    def get(self, name):
        return self.levels[name]


class Display:
    def __init__(self):
        self.calls = []

    def set(self, on):
        self.calls.append(on)


STEPS = ["%s %s" % (name, verb) for name in new.OUTPUTS for verb in ("toggle", "on", "off")]
STEPS += ["standby on", "standby off", "standby toggle", "press", "press"]
STEPS += ["DISCO Toggle", "nonsense x", "decor", "amp blink", ""]
BEFORE_READY = ["press", "standby on", "standby off", "standby toggle"]


def squash(calls):
    return [call for index, call in enumerate(calls) if index == 0 or call != calls[index - 1]]


class CompatibilityTest(unittest.TestCase):
    def run_sequence(self, seed):
        rng = random.Random(seed)
        original = load_original()
        hardware, display, powered_off = Hardware(), Display(), []
        controller = new.Controller(hardware, lambda state: None, display, lambda: powered_off.append(1))
        now = [100.0]
        controller.start(now[0], ready_timeout=90.0)

        def compare(step):
            now[0] += 2.0  # past the amplifier delay
            controller.tick(now[0])
            expected = dict((name, bool(output.value)) for name, output in original.outputs.items())
            self.assertEqual(hardware.levels, expected, "seed %d, after %r" % (seed, step))
            expected_display = [argv[-1] == "on" for argv in original.calls if argv[0].endswith("xset")]
            self.assertEqual(
                squash(display.calls), squash(expected_display), "seed %d, after %r" % (seed, step)
            )

        compare("start")
        ready_at = rng.randint(0, 4)
        for index in range(rng.randint(5, 40)):
            if index == ready_at:
                # What the original does when Phoenix answers.
                if not original.standby:
                    original.leave_standby()
                controller.app_ready(now[0])
                compare("application ready")

            step = rng.choice(BEFORE_READY if index < ready_at else STEPS)
            if step == "press":
                original.on_button_pressed()
                original.clock[0] += 0.2
                original.on_button_released()
                controller.button_down(now[0])
                now[0] += 0.2
                controller.button_up(now[0], now[0])
            else:
                original.handle_command(step)
                words, _request_id = new.parse_request(step.encode())
                if words is not None:
                    controller.command(words, now[0])
            compare(step)

        # A long press ends both the same way.
        original.on_button_pressed()
        original.clock[0] += 3.5
        original.on_button_released()
        controller.button_down(now[0])
        now[0] += 3.5
        controller.button_up(now[0], now[0])
        compare("long press")
        self.assertEqual(powered_off, [1])
        self.assertEqual(original.calls[-1], ["/usr/bin/systemctl", "poweroff"])
        self.assertTrue(all(level is False for level in hardware.levels.values()))

    def test_same_outputs_and_display_as_the_original_on_random_sequences(self):
        saved = new.log
        new.log = lambda message: None
        self.addCleanup(setattr, new, "log", saved)
        for seed in range(400):
            self.run_sequence(seed)

    def test_the_fixed_points_of_the_original_are_unchanged(self):
        original = load_original()
        self.assertEqual(dict(new.OUTPUTS), original.PINS)
        self.assertEqual(new.DEFAULT_REQUESTS, original.DEFAULT_STATE)
        self.assertEqual(new.SOCKET_PATH, original.SOCKET_PATH)
        self.assertEqual(new.HOLD_SHUTDOWN_S, original.LONG_PRESS_SECONDS)
        self.assertEqual(new.AMP_DELAY_S, original.AMP_DELAY_SECONDS)


if __name__ == "__main__":
    unittest.main()
