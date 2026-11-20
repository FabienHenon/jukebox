#!/bin/sh
# Installs (or updates) the jukebox power controller on the Raspberry Pi:
#
#   /usr/local/sbin/jukebox-power-controller.py           root:root 0755
#   /etc/systemd/system/jukebox-power-controller.service  root:root 0644
#
#   cd /home/jukebox/src/jukebox-app
#   sudo sh ops/hardware/install-power-controller.sh             install / update
#   sudo sh ops/hardware/install-power-controller.sh --restart   install / update,
#                                                                then restart the
#                                                                controller (only it)
#   sudo sh ops/hardware/install-power-controller.sh --rollback  put the previous
#                                                                files back
#
# What it does, and no more:
#
#   * checks the two files it is about to install (Python syntax, unit syntax);
#   * keeps a dated copy of each file it replaces, next to it (*.YYYYMMDD-HHMMSS.bak);
#   * installs the two files, owned by root and not writable by anyone else;
#   * reloads systemd and enables the unit for the next boot.
#
# What it never does:
#
#   * it does NOT start or restart the controller unless you ask for it with
#     --restart. A restart drops every output for a moment, so it is your
#     decision, the first time with the power loads (amplifier, lights)
#     disconnected. Without the option:
#         sudo systemctl restart jukebox-power-controller
#   * it does not touch /etc/jukebox/jukebox.env, /boot/firmware/config.txt,
#     the audio configuration, /run/jukebox or anything in /opt/jukebox.
#     It only warns when it sees a setting that conflicts with the controller.
#
# Safe to run again: with unchanged files it changes nothing and makes no copy.

set -eu

# For the automated test of this script only: a directory used instead of /,
# in which case systemd is left alone.
ROOT="${JUKEBOX_INSTALL_ROOT:-}"

here="$(cd "$(dirname "$0")" && pwd)"
SOURCE_PROGRAM="$here/jukebox-power-controller.py"
SOURCE_UNIT="$here/jukebox-power-controller.service"
PROGRAM="$ROOT/usr/local/sbin/jukebox-power-controller.py"
UNIT="$ROOT/etc/systemd/system/jukebox-power-controller.service"
UNIT_NAME="jukebox-power-controller.service"
BOOT_CONFIG="$ROOT/boot/firmware/config.txt"
PYTHON="${PYTHON:-/usr/bin/python3}"
[ -x "$PYTHON" ] || PYTHON="$(command -v python3 || true)"

fail() {
  echo "install-power-controller: $*" >&2
  exit 1
}

warn() {
  echo "  WARNING: $*"
}

if [ -z "$ROOT" ]; then
  [ "$(uname -s)" = "Linux" ] || fail "this script is for the Raspberry Pi (Linux)"
  [ "$(id -u)" -eq 0 ] || fail "run it with sudo"
fi

# Newest dated copy of a file, or nothing.
latest_backup() {
  ls -1 "$1".*.bak 2> /dev/null | sort | tail -n 1
}

# Installs $1 as $2 with mode $3, keeping a dated copy of what it replaces.
place() {
  source="$1"
  target="$2"
  mode="$3"

  if [ -f "$target" ] && cmp -s "$source" "$target"; then
    echo "  unchanged: $target"
  else
    if [ -e "$target" ]; then
      backup="$target.$(date +%Y%m%d-%H%M%S).bak"
      cp -p "$target" "$backup"
      echo "  previous version kept as $backup"
    fi
    mkdir -p "$(dirname "$target")"
    # Written beside the target, then renamed over it: never a half-written file.
    cp "$source" "$target.new"
    chmod "$mode" "$target.new"
    [ -n "$ROOT" ] || chown root:root "$target.new"
    mv -f "$target.new" "$target"
    echo "  installed: $target"
  fi

  # Also when unchanged: the ownership and mode are part of the installation.
  chmod "$mode" "$target"
  [ -n "$ROOT" ] || chown root:root "$target"
}

reload_systemd() {
  if [ -z "$ROOT" ]; then
    systemctl daemon-reload
  fi
}

if [ "${1:-}" = "--rollback" ]; then
  restored=0
  for target in "$PROGRAM" "$UNIT"; do
    backup="$(latest_backup "$target")"
    if [ -n "$backup" ]; then
      cp -p "$backup" "$target"
      echo "restored $target from $backup"
      restored=1
    else
      echo "no previous version of $target was kept; left as it is"
    fi
  done
  reload_systemd
  if [ "$restored" -eq 1 ]; then
    echo
    echo "The running controller is still the one that was running. To switch to the"
    echo "restored version:  sudo systemctl restart jukebox-power-controller"
  fi
  exit 0
fi

RESTART=0
case "${1:-}" in
  "") ;;
  --restart) RESTART=1 ;;
  *) fail "unknown argument: $1 (the options are --restart and --rollback)" ;;
esac
[ -f "$SOURCE_PROGRAM" ] || fail "$SOURCE_PROGRAM not found"
[ -f "$SOURCE_UNIT" ] || fail "$SOURCE_UNIT not found"
[ -n "$PYTHON" ] || fail "python3 not found"

echo "1/4  checking the files to install"
"$PYTHON" -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$SOURCE_PROGRAM" ||
  fail "$SOURCE_PROGRAM is not valid Python; nothing was installed"
grep -q '^ExecStart=.*/usr/local/sbin/jukebox-power-controller.py --daemon' "$SOURCE_UNIT" ||
  fail "$SOURCE_UNIT does not start the controller; nothing was installed"
if [ -z "$ROOT" ]; then
  "$PYTHON" -c 'import gpiozero' 2> /dev/null ||
    fail "the Python module gpiozero is missing: sudo apt install python3-gpiozero"
  id jukebox > /dev/null 2>&1 ||
    fail "user jukebox does not exist (install the Phoenix release first)"
fi

echo "2/4  looking for settings that conflict with the controller (nothing is changed)"
if [ -f "$BOOT_CONFIG" ]; then
  if grep -Eq '^[[:space:]]*dtoverlay=gpio-shutdown' "$BOOT_CONFIG"; then
    warn "$BOOT_CONFIG has dtoverlay=gpio-shutdown. That overlay also takes GPIO3 and"
    warn "shuts the Pi down on a short press. Remove the line and reboot before"
    warn "starting the controller, or the controller cannot claim the Power button."
  fi
  if grep -Eq '^[[:space:]]*dtparam=i2c_arm=on' "$BOOT_CONFIG"; then
    warn "$BOOT_CONFIG has dtparam=i2c_arm=on, which gives GPIO2/GPIO3 to I2C."
    warn "GPIO3 is the Power button: remove that line. Nothing in the jukebox uses"
    warn "the GPIO header's I2C."
  fi
fi
if [ -z "$ROOT" ] && systemctl is-enabled --quiet jukebox-led-power.service 2> /dev/null; then
  warn "jukebox-led-power.service is enabled and drives GPIO17, which the controller"
  warn "uses for the amplifier. Disable it first:"
  warn "    sudo systemctl disable --now jukebox-led-power"
fi

echo "3/4  installing"
place "$SOURCE_PROGRAM" "$PROGRAM" 0755
place "$SOURCE_UNIT" "$UNIT" 0644

echo "4/4  systemd"
if [ -z "$ROOT" ]; then
  systemctl daemon-reload
  if command -v systemd-analyze > /dev/null 2>&1; then
    systemd-analyze verify "$UNIT" || warn "systemd-analyze reported the lines above"
  fi
  systemctl enable "$UNIT_NAME" > /dev/null
  echo "  enabled for the next boot"
  if [ "$RESTART" -eq 1 ]; then
    # Asked for explicitly. Only this unit: nothing else is restarted.
    systemctl restart "$UNIT_NAME"
    echo "  restarted, as asked with --restart"
  elif systemctl is-active --quiet "$UNIT_NAME"; then
    echo "  the controller that is running now is still the PREVIOUS version"
  else
    echo "  the controller is not running"
  fi
else
  echo "  skipped (test root)"
fi

if [ "$RESTART" -eq 1 ] && [ -z "$ROOT" ]; then
  cat << 'NOTE'

Done. The controller was restarted (and nothing else). Check it:

    systemctl status jukebox-power-controller --no-pager
    sudo -u jukebox cat /run/jukebox-power/state.json
    sudo -u jukebox /usr/local/sbin/jukebox-power-controller.py status

To go back to the previous version:

    sudo sh ops/hardware/install-power-controller.sh --rollback
    sudo systemctl restart jukebox-power-controller

See docs/physical-controls.md.
NOTE
  exit 0
fi

cat << 'NOTE'

Done. Nothing was started or restarted.

Next, as an explicit step, the first time with the amplifier and the lights
unplugged from their supplies (or run this script again with --restart):

    sudo systemctl restart jukebox-power-controller
    systemctl status jukebox-power-controller --no-pager
    sudo -u jukebox cat /run/jukebox-power/state.json
    sudo -u jukebox /usr/local/sbin/jukebox-power-controller.py status

To go back to the previous version:

    sudo sh ops/hardware/install-power-controller.sh --rollback
    sudo systemctl restart jukebox-power-controller

See docs/physical-controls.md.
NOTE
