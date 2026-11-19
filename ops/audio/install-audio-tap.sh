#!/bin/sh
# Installs the audio tap on the Raspberry Pi: the analyser, the shared group,
# the socket directory and the ALSA device "jukebox_tap".
#
#   cd /opt/jukebox-src
#   make -C native/jukebox_audio_analyzer        # as your own user, first
#   sudo sh ops/audio/install-audio-tap.sh
#
# It does NOT touch /etc/asound.conf and it does NOT change the Shairport Sync
# configuration: after this script, audio still goes straight to the DAC.
# Switching Shairport Sync to "jukebox_tap" is a separate, manual step (see
# docs/audio-reactive-setup.md), undone by ops/audio/rollback-audio-tap.sh.
#
# Safe to run again. Settings, all optional:
#
#   JUKEBOX_DAC       ALSA name of the DAC      (default plughw:CARD=Audio,DEV=0)
#   JUKEBOX_USER      user of the Phoenix release              (default jukebox)
#   SHAIRPORT_USER    user Shairport Sync runs as    (default: asked of systemd)
#   PREFIX            where the release lives             (default /opt/jukebox)

set -eu

DAC="${JUKEBOX_DAC:-plughw:CARD=Audio,DEV=0}"
APP_USER="${JUKEBOX_USER:-jukebox}"
PREFIX="${PREFIX:-/opt/jukebox}"
GROUP="jukebox-audio"
ALSA_DIR="/etc/alsa/conf.d"
ALSA_FILE="$ALSA_DIR/60-jukebox-tap.conf"
TMPFILES_FILE="/etc/tmpfiles.d/jukebox-audio.conf"

here="$(cd "$(dirname "$0")" && pwd)"
source_root="$(cd "$here/../.." && pwd)"
native="$source_root/native/jukebox_audio_analyzer"

fail() {
  echo "install-audio-tap: $*" >&2
  exit 1
}

[ "$(uname -s)" = "Linux" ] || fail "this script is for the Raspberry Pi (Linux)"
[ "$(id -u)" -eq 0 ] || fail "run it with sudo"
[ -x "$native/build/jukebox_audio_analyzer" ] ||
  fail "the analyser is not built yet. Run first, without sudo: make -C $native"
id "$APP_USER" > /dev/null 2>&1 || fail "user $APP_USER does not exist (install the Phoenix release first, or set JUKEBOX_USER)"

SHAIRPORT_USER="${SHAIRPORT_USER:-$(systemctl show -p User --value shairport-sync 2> /dev/null || true)}"
[ -n "$SHAIRPORT_USER" ] || SHAIRPORT_USER="shairport-sync"
id "$SHAIRPORT_USER" > /dev/null 2>&1 ||
  fail "user $SHAIRPORT_USER does not exist. Find the user Shairport Sync runs as (systemctl show -p User shairport-sync) and set SHAIRPORT_USER"

echo "1/4  analyser and wrapper -> $PREFIX/bin"
make -C "$native" install PREFIX="$PREFIX" > /dev/null
"$PREFIX/bin/jukebox_audio_analyzer" --version

echo "2/4  group $GROUP, with $SHAIRPORT_USER as a member"
getent group "$GROUP" > /dev/null || groupadd --system "$GROUP"
usermod -a -G "$GROUP" "$SHAIRPORT_USER"

echo "3/4  socket directory /run/jukebox (recreated at every boot by $TMPFILES_FILE)"
sed -e "s/  jukebox  jukebox-audio  /  $APP_USER  $GROUP  /" \
  "$here/jukebox-audio.tmpfiles.conf.example" > "$TMPFILES_FILE"
systemd-tmpfiles --create "$TMPFILES_FILE"

echo "4/4  ALSA device jukebox_tap -> $DAC"
if [ ! -d "$ALSA_DIR" ]; then
  echo
  echo "     $ALSA_DIR does not exist on this system, so the device was NOT installed."
  echo "     Add the pcm.jukebox_tap block of ops/audio/jukebox-tap.conf.example to"
  echo "     /etc/asound.conf by hand, after making a copy of that file"
  echo "     (docs/audio-reactive-setup.md, \"If /etc/alsa/conf.d is missing\")."
  exit 1
fi
if [ -f "$ALSA_FILE" ]; then
  cp -p "$ALSA_FILE" "$ALSA_FILE.$(date +%Y%m%d-%H%M%S).bak"
fi
sed -e "s|slave.pcm \"plughw:CARD=Audio,DEV=0\"|slave.pcm \"$DAC\"|" \
  -e "s|/opt/jukebox/bin/|$PREFIX/bin/|" \
  "$here/jukebox-tap.conf.example" > "$ALSA_FILE"
chmod 0644 "$ALSA_FILE"

echo
if aplay -L 2> /dev/null | grep -q '^jukebox_tap$'; then
  echo "Done. ALSA knows the device jukebox_tap."
else
  echo "Installed, but 'aplay -L' does not list jukebox_tap: see the troubleshooting"
  echo "section of docs/audio-reactive-setup.md before going further."
fi
echo "Shairport Sync still plays straight to the DAC. Next: section 6 of"
echo "docs/audio-reactive-setup.md (test the device, then switch Shairport Sync)."
