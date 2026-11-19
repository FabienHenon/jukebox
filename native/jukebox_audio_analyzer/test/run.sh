#!/bin/sh
# Tests of jukebox_audio_analyzer. No audio hardware and no audio file: the
# signals come from pcm_gen and the display is played by dgram_dump.
#
#   make test            (or: BUILD=build sh test/run.sh)
#
# Works for both builds: with aubio (beats and tempo are checked) and without
# (make AUBIO=0: only loudness, bass and attacks).

set -u

BUILD="${BUILD:-build}"
ANALYZER="$BUILD/jukebox_audio_analyzer"
GEN="$BUILD/pcm_gen"
DUMP="$BUILD/dgram_dump"
TAP="./jukebox_audio_tap"

# Unix socket paths are short: keep the scratch directory directly in /tmp.
TMP="$(mktemp -d /tmp/jbaa.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

NOWHERE="$TMP/nobody-listens.sock"
FRAME='^\{"level":[01]\.[0-9]{3},"bass":[01]\.[0-9]{3},"onset":[01]\.[0-9]{3},"beat_id":[0-9]+,"bpm":[0-9]+\.[0-9],"confidence":[01]\.[0-9]{3}\}$'

passed=0
failed=0

ok() {
  passed=$((passed + 1))
  echo "  ok    $1"
}

not_ok() {
  failed=$((failed + 1))
  echo "  FAIL  $1"
  [ $# -gt 1 ] && echo "        $2"
}

# check DESCRIPTION CONDITION...   (the condition is a test(1) expression)
check() {
  description="$1"
  shift
  if [ "$@" ]; then ok "$description"; else not_ok "$description" "condition: $*"; fi
}

# The numbers of every frame as "level,bass,onset,beat_id,bpm,confidence".
numbers() {
  sed 's/[^0-9.,-]//g' "$1"
}

lines() {
  wc -l < "$1" | tr -d ' '
}

# Seconds since the epoch.
now() {
  date +%s
}

# analyse OUTPUT-NAME GENERATOR-OPTIONS -- ANALYSER-OPTIONS
analyse() {
  name="$1"
  shift
  generator=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    generator="$generator $1"
    shift
  done
  [ $# -gt 0 ] && shift
  # shellcheck disable=SC2086
  "$GEN" $generator | "$ANALYZER" --socket "$NOWHERE" --print "$@" > "$TMP/$name.out" 2> "$TMP/$name.err"
}

wait_for_socket() {
  tries=0
  while [ ! -S "$1" ] && [ "$tries" -lt 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -S "$1" ]
}

if "$ANALYZER" --version | grep -q "; aubio)"; then
  AUBIO=1
  echo "jukebox_audio_analyzer tests (built with aubio)"
else
  AUBIO=0
  echo "jukebox_audio_analyzer tests (built WITHOUT aubio: no beat or tempo checks)"
fi

# -- frames ------------------------------------------------------------------------
echo "frames"

analyse music --signal music --seconds 20 --bpm 120
count="$(lines "$TMP/music.out")"
check "20 s of audio give about 400 frames at 20 per second (got $count)" "$count" -ge 396 -a "$count" -le 400

malformed="$(grep -c -v -E "$FRAME" "$TMP/music.out")"
check "every frame is one JSON object of the documented shape" "$malformed" -eq 0

out_of_bounds="$(numbers "$TMP/music.out" | awk -F, '
  $1 < 0 || $1 > 1 || $2 < 0 || $2 > 1 || $3 < 0 || $3 > 1 || $6 < 0 || $6 > 1 { bad++ }
  $4 < previous { bad++ }
  $5 != 0 && ($5 < 40 || $5 > 240) { bad++ }
  { previous = $4 }
  END { print bad + 0 }')"
check "values stay within bounds and the beat counter never goes back" "$out_of_bounds" -eq 0

analyse music-again --signal music --seconds 20 --bpm 120
if cmp -s "$TMP/music.out" "$TMP/music-again.out"; then
  ok "the same signal gives exactly the same frames"
else
  not_ok "the same signal gives exactly the same frames"
fi

analyse rate5 --signal music --seconds 20 -- --publish-rate 5
count="$(lines "$TMP/rate5.out")"
check "--publish-rate 5 gives about 100 frames (got $count)" "$count" -ge 98 -a "$count" -le 100

analyse rate-high --signal music --seconds 20 -- --publish-rate 500
count="$(lines "$TMP/rate-high.out")"
check "the publication rate is capped at 20 per second (got $count)" "$count" -le 400

# -- loudness and bass ----------------------------------------------------------------
echo "loudness and bass"

analyse silence --signal silence --seconds 10
count="$(lines "$TMP/silence.out")"
not_zero="$(grep -c -v -F '{"level":0.000,"bass":0.000,"onset":0.000,"beat_id":0,"bpm":0.0,"confidence":0.000}' "$TMP/silence.out")"
check "silence still produces frames (got $count)" "$count" -ge 196
check "silence is zero in every field" "$not_zero" -eq 0

swing="$(numbers "$TMP/music.out" | awk -F, 'NR > 100 { if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 }
  END { print (max >= 0.9 && min <= 0.5) ? "yes" : "no: min " min " max " max }')"
check "loudness moves with the music" "$swing" = yes

bass_swing="$(numbers "$TMP/music.out" | awk -F, 'NR > 100 { if (min == "" || $2 < min) min = $2; if ($2 > max) max = $2 }
  END { print (max >= 0.9 && min <= 0.5) ? "yes" : "no: min " min " max " max }')"
check "bass pulses with the kick" "$bass_swing" = yes

analyse quiet --signal music --seconds 20 --bpm 120 --amplitude 0.01
quiet="$(numbers "$TMP/quiet.out" | awk -F, 'NR > 100 { if ($1 > max) max = $1 } END { print (max >= 0.6) ? "yes" : "no: max " max }')"
check "music played 34 dB quieter is still shown" "$quiet" = yes

analyse hiss --signal drift --seconds 10 --amplitude 0.0001
hiss="$(numbers "$TMP/hiss.out" | awk -F, '$1 > 0 { loud++ } END { print loud + 0 }')"
check "sound below the silence threshold reads as silence" "$hiss" -eq 0

analyse fade --signal music --seconds 6 --bpm 120
"$GEN" --signal music --seconds 6 > "$TMP/then-silence.raw"
"$GEN" --signal silence --seconds 6 >> "$TMP/then-silence.raw"
"$ANALYZER" --socket "$NOWHERE" --print < "$TMP/then-silence.raw" > "$TMP/then-silence.out" 2> /dev/null
tail="$(tail -n 60 "$TMP/then-silence.out" | numbers /dev/stdin | awk -F, '$1 > 0 || $2 > 0 || $3 > 0 { bad++ } END { print bad + 0 }')"
check "when the music stops the values return to zero" "$tail" -eq 0

# -- attacks, beats, tempo ---------------------------------------------------------------
echo "attacks, beats and tempo"

analyse beat --signal music --seconds 40 --bpm 120
onsets="$(numbers "$TMP/beat.out" | awk -F, '$3 > 0 { n++ } END { print n + 0 }')"
check "attacks are detected in music (got $onsets in 40 s)" "$onsets" -ge 40

analyse steady --signal sine --seconds 20
onsets="$(numbers "$TMP/steady.out" | awk -F, 'NR > 40 && $3 > 0 { n++ } END { print n + 0 }')"
check "a steady tone has no attacks after it starts (got $onsets)" "$onsets" -le 2

if [ "$AUBIO" -eq 1 ]; then
  beats="$(numbers "$TMP/beat.out" | awk -F, 'NR == 400 { first = $4 } END { print $4 - first }')"
  check "a 120 BPM pattern gives about 40 beats in 20 s (got $beats)" "$beats" -ge 37 -a "$beats" -le 43

  bpm="$(numbers "$TMP/beat.out" | awk -F, 'END { print ($5 >= 116 && $5 <= 124) ? "yes" : "no: " $5 }')"
  check "the tempo is found" "$bpm" = yes

  confident="$(numbers "$TMP/beat.out" | awk -F, 'NR > 400 && $6 >= 0.45 { n++ } NR > 400 { total++ } END { print (n >= total * 0.9) ? "yes" : "no: " n + 0 " of " total }')"
  check "a clear beat is tracked with confidence" "$confident" = yes

  early="$(numbers "$TMP/beat.out" | awk -F, 'NR <= 20 && $5 != 0 { n++ } END { print n + 0 }')"
  check "no tempo is claimed in the first second" "$early" -eq 0

  analyse slow --signal music --seconds 40 --bpm 90
  bpm="$(numbers "$TMP/slow.out" | awk -F, 'END { print ($5 >= 87 && $5 <= 93) ? "yes" : "no: " $5 }')"
  check "a different tempo is followed (90 BPM)" "$bpm" = yes

  analyse drift --signal drift --seconds 40
  doubtful="$(numbers "$TMP/drift.out" | awk -F, 'NR > 200 && $6 >= 0.45 { n++ } END { print n + 0 }')"
  check "sound without a beat is never tracked with confidence" "$doubtful" -eq 0

  doubtful="$(numbers "$TMP/steady.out" | awk -F, '$6 >= 0.45 { n++ } END { print n + 0 }')"
  check "neither is a steady tone" "$doubtful" -eq 0

  after="$(tail -n 20 "$TMP/then-silence.out" | numbers /dev/stdin | awk -F, '$5 != 0 || $6 != 0 { bad++ } END { print bad + 0 }')"
  check "tempo and confidence are withdrawn when the music stops" "$after" -eq 0
else
  beats="$(numbers "$TMP/beat.out" | awk -F, '$4 != 0 || $5 != 0 || $6 != 0 { n++ } END { print n + 0 }')"
  check "without aubio no beat, tempo or confidence is ever reported" "$beats" -eq 0
fi

# -- stream formats ------------------------------------------------------------------------
echo "stream formats"

mean_level() {
  numbers "$1" | awk -F, '{ sum += $1 } END { printf "%d", sum / NR * 1000 }'
}

reference="$(mean_level "$TMP/music.out")"
for format in S32_LE S24_3LE S24_LE; do
  analyse "format-$format" --signal music --seconds 20 --bpm 120 --format "$format" -- --format "$format"
  mean="$(mean_level "$TMP/format-$format.out")"
  difference=$((mean - reference))
  check "$format reads like S16_LE (mean level $mean vs $reference)" "$difference" -ge -3 -a "$difference" -le 3
done

analyse bits24 --signal music --seconds 20 --bpm 120 --format S24_3LE -- --bits 24
mean="$(mean_level "$TMP/bits24.out")"
difference=$((mean - reference))
check "--bits alone selects the format" "$difference" -ge -3 -a "$difference" -le 3

analyse mono --signal music --seconds 20 --bpm 120 --channels 1 -- --channels 1
mean="$(mean_level "$TMP/mono.out")"
difference=$((mean - reference))
check "mono reads like stereo" "$difference" -ge -3 -a "$difference" -le 3

analyse rate48 --signal music --seconds 20 --bpm 120 --rate 48000 -- --sample-rate 48000
count="$(lines "$TMP/rate48.out")"
mean="$(mean_level "$TMP/rate48.out")"
difference=$((mean - reference))
check "48 kHz gives the same number of frames (got $count)" "$count" -ge 396 -a "$count" -le 400
check "48 kHz reads like 44.1 kHz (mean level $mean vs $reference)" "$difference" -ge -30 -a "$difference" -le 30

for bad in "--format FLOAT_LE" "--channels 0" "--sample-rate 12" "--format S16_BE --channels 2"; do
  # shellcheck disable=SC2086
  "$GEN" --signal music --seconds 30 | "$ANALYZER" --socket "$NOWHERE" --print $bad > "$TMP/bad.out" 2> "$TMP/bad.err"
  status=$?
  reports="$(grep -c "unsupported" "$TMP/bad.err")"
  check "unsupported input ($bad): all of it is read, exit 0" "$status" -eq 0
  check "unsupported input ($bad): reported once, no frames" "$reports" -eq 1 -a "$(lines "$TMP/bad.out")" -eq 0 -a "$(lines "$TMP/bad.err")" -eq 1
done

"$GEN" --signal music --seconds 5 | "$ANALYZER" --socket "$NOWHERE" --print --frobnicate yes --sample-rate > "$TMP/odd.out" 2> "$TMP/odd.err"
check "unknown or incomplete options are ignored, not fatal" "$(lines "$TMP/odd.out")" -ge 90

# -- the socket -----------------------------------------------------------------------------
echo "the socket"

# Ten minutes of audio, nobody listening: 12000 frames that cannot be sent.
# The analyser repeats a report after a minute of real time, and on a small
# machine these ten minutes take longer than that to analyse: the number of
# reports allowed follows from how long the run took.
started="$(now)"
"$GEN" --signal music --seconds 600 | "$ANALYZER" --socket "$NOWHERE" > "$TMP/unreachable.out" 2> "$TMP/unreachable.err"
status=$?
elapsed=$(($(now) - started))
reports="$(lines "$TMP/unreachable.err")"
check "an unreachable socket never blocks the input (10 min of audio read in about $elapsed s, exit 0)" "$status" -eq 0
check "nothing is written to standard output without --print" "$(lines "$TMP/unreachable.out")" -eq 0
check "the problem is reported once a minute at most, not 12000 times (got $reports in $elapsed s)" \
  "$reports" -ge 1 -a "$reports" -le "$((1 + elapsed / 60))"

"$GEN" --signal music --seconds 60 | "$ANALYZER" --socket "$TMP/this/path/is/far/too/long/$(printf '%0200d' 0).sock" --print > "$TMP/long.out" 2> "$TMP/long.err"
check "a socket path that is too long does not stop the analysis" "$?" -eq 0 -a "$(lines "$TMP/long.out")" -ge 1190

# A receiver that exists but does not read: its buffer fills, frames are dropped.
# It stays there, silent, for the whole run and is stopped afterwards.
"$DUMP" --socket "$TMP/held.sock" --hold-ms 3600000 2> /dev/null &
held=$!
wait_for_socket "$TMP/held.sock"
started="$(now)"
"$GEN" --signal music --seconds 120 | "$ANALYZER" --socket "$TMP/held.sock" 2> "$TMP/held.err"
status=$?
elapsed=$(($(now) - started))
reports="$(lines "$TMP/held.err")"
kill "$held" 2> /dev/null
wait "$held" 2> /dev/null
check "a receiver that does not read never blocks the input" "$status" -eq 0
check "dropped frames are reported once a minute at most (got $reports in $elapsed s)" \
  "$reports" -le "$((1 + elapsed / 60))"

# A receiver that reads: frames arrive, each one valid and one that was sent.
# (The receiver waits as long as it takes for the first frame, then stops
# 700 ms after the last one.)
"$DUMP" --socket "$TMP/live.sock" --idle-ms 700 > "$TMP/received.out" 2> /dev/null &
live=$!
wait_for_socket "$TMP/live.sock"
"$GEN" --signal music --seconds 10 | "$ANALYZER" --socket "$TMP/live.sock" --print > "$TMP/sent.out" 2> "$TMP/sent.err"
wait "$live"
received="$(lines "$TMP/received.out")"
check "frames reach a listening socket (got $received datagrams)" "$received" -ge 1
check "each datagram is one valid frame" "$(grep -c -v -E "$FRAME" "$TMP/received.out")" -eq 0
check "each datagram is a frame that was sent" "$(grep -c -v -x -F -f "$TMP/sent.out" "$TMP/received.out")" -eq 0

# The receiver appears while the analyser is already running (Phoenix restarted).
# The audio goes through a named pipe so that the steps happen in a known
# order whatever the speed of the machine: two seconds of audio with nobody
# listening, then the receiver, then two more seconds.
mkfifo "$TMP/late.pcm"
"$ANALYZER" --socket "$TMP/late.sock" < "$TMP/late.pcm" 2> "$TMP/late.err" &
analyser=$!
exec 9> "$TMP/late.pcm"
"$GEN" --signal music --seconds 2 >&9
# The generator has returned, so at most one pipe buffer (a fraction of a
# second of audio) is still to be analysed.
sleep 1
# (9>&-: the receiver must not hold the pipe open, or the analyser would
# never see the end of the audio.)
"$DUMP" --socket "$TMP/late.sock" --idle-ms 700 > "$TMP/late.out" 2> /dev/null 9>&- &
late=$!
wait_for_socket "$TMP/late.sock"
"$GEN" --signal music --seconds 2 >&9
exec 9>&-
wait "$analyser"
wait "$late"
check "a socket that appears later is found without restarting the analyser" "$(lines "$TMP/late.out")" -ge 1
check "the earlier failure was reported once" "$(lines "$TMP/late.err")" -eq 1

# -- the tap wrapper --------------------------------------------------------------------------
echo "the tap wrapper"

"$GEN" --signal music --seconds 60 | JUKEBOX_AUDIO_ANALYZER="$TMP/missing" sh "$TAP" --socket "$NOWHERE" > "$TMP/tap.out" 2> "$TMP/tap.err"
check "a missing analyser: the audio is still read to the end" "$?" -eq 0
check "a missing analyser: said once on standard error, nothing on standard output" "$(lines "$TMP/tap.err")" -eq 1 -a "$(lines "$TMP/tap.out")" -eq 0

printf '#!/bin/sh\nhead -c 1000 > /dev/null\nexit 3\n' > "$TMP/crasher"
chmod +x "$TMP/crasher"
"$GEN" --signal music --seconds 60 | JUKEBOX_AUDIO_ANALYZER="$TMP/crasher" sh "$TAP" > "$TMP/tap.out" 2> "$TMP/tap.err"
check "an analyser that dies mid-stream: the audio is still read to the end" "$?" -eq 0
check "an analyser that dies mid-stream: said once" "$(grep -c "status 3" "$TMP/tap.err")" -eq 1

"$GEN" --signal music --seconds 5 | JUKEBOX_AUDIO_ANALYZER="$ANALYZER" sh "$TAP" --socket "$NOWHERE" --print > "$TMP/tap.out" 2> /dev/null
check "the options are passed through to the analyser" "$(lines "$TMP/tap.out")" -ge 96

# -- result -------------------------------------------------------------------------------------
echo
if [ "$failed" -eq 0 ]; then
  echo "$passed passed"
else
  echo "$passed passed, $failed FAILED"
  exit 1
fi
