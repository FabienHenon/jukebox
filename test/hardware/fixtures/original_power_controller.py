# REFERENCE ONLY - not installed, not imported by the application.
#
# This is the power controller of the installation guide (phase 11) as it was
# before ops/hardware/jukebox-power-controller.py replaced it. It is kept here,
# unchanged below this header, so that test_power_controller_compat.py can
# drive both with the same commands and check that the outputs and the display
# behave the same.
#!/usr/bin/python3
import grp
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request

from gpiozero import Button, OutputDevice

SOCKET_PATH = "/run/jukebox/power-control.sock"
LONG_PRESS_SECONDS = 3.0
AMP_DELAY_SECONDS = 1.5

PINS = {
    "amp": 17,
    "disco": 27,
    "strip": 22,
    "decor": 23,
    "extra": 24,
}

DEFAULT_STATE = {
    "amp": True,
    "disco": False,
    "strip": True,
    "decor": True,
    "extra": True,
}

lock = threading.RLock()
stop_event = threading.Event()
desired = DEFAULT_STATE.copy()
outputs = {}
standby = False
press_started = None
server_socket = None


def set_display(on):
    env = os.environ.copy()
    env["DISPLAY"] = ":0"
    env["XAUTHORITY"] = "/home/jukebox/.Xauthority"
    command = ["/usr/bin/xset", "dpms", "force", "on" if on else "off"]
    subprocess.run(command, env=env, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)


def all_outputs_off():
    with lock:
        for output in outputs.values():
            output.off()


def apply_non_amp_outputs():
    with lock:
        if standby:
            return
        for name, output in outputs.items():
            if name != "amp":
                output.value = desired[name]


def enter_standby():
    global standby
    with lock:
        if standby:
            return
        standby = True
        outputs["amp"].off()
        for name, output in outputs.items():
            if name != "amp":
                output.off()
    set_display(False)


def leave_standby():
    global standby
    with lock:
        standby = False
    set_display(True)
    apply_non_amp_outputs()
    time.sleep(AMP_DELAY_SECONDS)
    with lock:
        if not standby:
            outputs["amp"].value = desired["amp"]


def toggle_standby():
    with lock:
        is_standby = standby
    if is_standby:
        leave_standby()
    else:
        enter_standby()


def request_shutdown():
    global standby
    with lock:
        standby = True
    all_outputs_off()
    set_display(False)
    subprocess.Popen(["/usr/bin/systemctl", "poweroff"])


def set_output(name, action):
    if name not in desired:
        return
    with lock:
        if action == "on":
            desired[name] = True
        elif action == "off":
            desired[name] = False
        elif action == "toggle":
            desired[name] = not desired[name]
        else:
            return
        if not standby:
            outputs[name].value = desired[name]


def handle_command(message):
    parts = message.strip().lower().split()
    if not parts:
        return
    if parts == ["standby", "toggle"]:
        toggle_standby()
    elif parts == ["standby", "on"]:
        enter_standby()
    elif parts == ["standby", "off"]:
        leave_standby()
    elif parts == ["shutdown"]:
        request_shutdown()
    elif len(parts) == 2:
        set_output(parts[0], parts[1])


def on_button_pressed():
    global press_started
    press_started = time.monotonic()


def on_button_released():
    global press_started
    if press_started is None:
        return
    duration = time.monotonic() - press_started
    press_started = None
    if duration >= LONG_PRESS_SECONDS:
        request_shutdown()
    else:
        toggle_standby()


def socket_loop():
    global server_socket
    os.makedirs("/run/jukebox", exist_ok=True)
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    server_socket.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o660)
    try:
        gid = grp.getgrnam("jukebox").gr_gid
        os.chown(SOCKET_PATH, -1, gid)
    except KeyError:
        pass
    server_socket.settimeout(0.5)
    while not stop_event.is_set():
        try:
            data = server_socket.recv(256)
        except socket.timeout:
            continue
        except OSError:
            break
        handle_command(data.decode("utf-8", errors="ignore"))


def wait_for_application():
    while not stop_event.is_set():
        try:
            with urllib.request.urlopen("http://127.0.0.1:4000/", timeout=2):
                break
        except Exception:
            stop_event.wait(1)
    if not stop_event.is_set():
        with lock:
            is_standby = standby
        if not is_standby:
            leave_standby()


def stop_service(signum, frame):
    stop_event.set()
    all_outputs_off()


def send_command(arguments):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        client.sendto(" ".join(arguments).encode("utf-8"), SOCKET_PATH)
    finally:
        client.close()


def run_daemon():
    global outputs
    signal.signal(signal.SIGTERM, stop_service)
    signal.signal(signal.SIGINT, stop_service)
    outputs = {
        name: OutputDevice(pin, active_high=True, initial_value=False)
        for name, pin in PINS.items()
    }
    power_button = Button(3, pull_up=True, bounce_time=0.08)
    power_button.when_pressed = on_button_pressed
    power_button.when_released = on_button_released
    threading.Thread(target=socket_loop, daemon=True).start()
    threading.Thread(target=wait_for_application, daemon=True).start()
    stop_event.wait()
    all_outputs_off()
    if server_socket is not None:
        server_socket.close()
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    power_button.close()
    for output in outputs.values():
        output.close()


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--daemon":
        run_daemon()
    elif len(sys.argv) >= 2:
        send_command(sys.argv[1:])
    else:
        print("usage: jukebox-power-controller.py --daemon | COMMAND", file=sys.stderr)
        sys.exit(2)
