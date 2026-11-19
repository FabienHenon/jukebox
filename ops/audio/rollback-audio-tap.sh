#!/bin/sh
# Puts Shairport Sync back on the DAC directly, at once.
#
#   sudo sh ops/audio/rollback-audio-tap.sh             back to direct output
#   sudo sh ops/audio/rollback-audio-tap.sh --remove    ...and remove the ALSA
#                                                       device and the socket
#                                                       directory rule as well
#
# It only changes the one line that selects the tap: every
#   output_device = "jukebox_tap";
# in the Shairport Sync configuration becomes
#   output_device = "<the DAC>";
# after a dated copy of the file has been made next to it. Then Shairport Sync
# is restarted. Anything else you tuned for the tap (output_format,
# buffer_size) is left alone: those settings are valid for the DAC as well.
#
# Settings, optional:
#
#   JUKEBOX_DAC       ALSA name of the DAC   (default plughw:CARD=Audio,DEV=0)
#   SHAIRPORT_CONF    configuration file     (default /etc/shairport-sync.conf)

set -eu

DAC="${JUKEBOX_DAC:-plughw:CARD=Audio,DEV=0}"
CONF="${SHAIRPORT_CONF:-/etc/shairport-sync.conf}"
ALSA_FILE="/etc/alsa/conf.d/60-jukebox-tap.conf"
TMPFILES_FILE="/etc/tmpfiles.d/jukebox-audio.conf"

fail() {
  echo "rollback-audio-tap: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run it with sudo"
[ -f "$CONF" ] || fail "$CONF not found (set SHAIRPORT_CONF)"

if grep -q 'output_device[[:space:]]*=[[:space:]]*"jukebox_tap"' "$CONF"; then
  backup="$CONF.$(date +%Y%m%d-%H%M%S).bak"
  cp -p "$CONF" "$backup"
  sed -i "s|output_device[[:space:]]*=[[:space:]]*\"jukebox_tap\"|output_device = \"$DAC\"|" "$CONF"
  echo "Shairport Sync now plays to $DAC (previous file kept as $backup)."
else
  echo "$CONF does not select jukebox_tap; nothing to change there."
fi

systemctl restart shairport-sync
echo "Shairport Sync restarted."

if [ "${1:-}" = "--remove" ]; then
  rm -f "$ALSA_FILE" "$TMPFILES_FILE"
  echo "Removed $ALSA_FILE and $TMPFILES_FILE."
  echo "The analyser in /opt/jukebox/bin and the group jukebox-audio are harmless and were kept."
fi

echo "Set AUDIO_REACTIVE_ENABLED=false in /etc/jukebox/jukebox.env and restart jukebox"
echo "to stop the display waiting for the analyser (optional: it falls back by itself)."
