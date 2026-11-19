# Audio-reactive animation: Raspberry Pi setup

This guide makes the jukebox display follow the music that Shairport Sync is
playing: waves that rise with the loudness, a cover that pulses with the bass,
lights that step on the detected beat.

**Status: nothing in this guide has been run on a Raspberry Pi yet.** The
application, the browser code and the native analyser are tested on a
development Mac (see [What was tested where](#what-was-tested-where)). The
ALSA tap, the permissions, the timing and the CPU cost can only be checked on
the Pi; the [validation checklist](#hardware-validation-checklist) lists what
has to pass before the feature counts as working.

Audio playback always comes first. Every step can be undone, and one command
puts Shairport Sync back on the DAC directly:

```sh
sudo sh /opt/jukebox-src/ops/audio/rollback-audio-tap.sh
```

The guide assumes the installation described in
[raspberry-pi.md](raspberry-pi.md): the source in `/opt/jukebox-src`, the
release in `/opt/jukebox` running as the user `jukebox`, Shairport Sync
playing to the USB DAC `plughw:CARD=Audio,DEV=0`. If your DAC has another
name, use it wherever that one appears.

## How it fits together

```text
Shairport Sync
    |
    v
ALSA device "jukebox_tap"            /etc/alsa/conf.d/60-jukebox-tap.conf
    |
    +----> USB DAC --> amplifier --> speakers        (unchanged audio)
    |
    +----> jukebox_audio_tap --> jukebox_audio_analyzer        /opt/jukebox/bin
                                        |
                                        v  one small JSON datagram, 20 a second
                          /run/jukebox/audio-analysis.sock
                                        |
                                        v
                          Phoenix (Jukebox.AudioAnalysis.NativeSource)
                                        |
                                        v  "audio-frame" events, no page render
                                 Chromium (kiosk)
```

Three things keep this from ever harming playback:

- **Phoenix is not on the audio path.** Stop it, restart it, crash it: the
  analyser drops its frames and carries on, and finds the socket again by
  itself when Phoenix is back.
- **The analyser always reads the audio.** ALSA writes a copy of every sample
  into it, and a pipe nobody reads would stall the player. The analyser never
  waits for anything, and the `jukebox_audio_tap` wrapper around it keeps
  reading even if the analyser is missing or crashes.
- **Nothing is recorded.** No audio is written to the SD card or sent
  anywhere; only six numbers per frame leave the analyser.

Without frames (feature off, analyser not running, silence) the display is
exactly what it was before: the fixed-tempo animation.

## Before you start

Check that playback works as it is, and keep a copy of the two files this
guide asks you to edit by hand:

```sh
# 1. AirPlay something from the iPhone and listen. Then:
grep -n 'output_device' /etc/shairport-sync.conf
aplay -L | grep -B1 -A2 'CARD=Audio'

# 2. Copies to return to
sudo cp -p /etc/shairport-sync.conf /etc/shairport-sync.conf.before-jukebox-tap
sudo cp -p /etc/jukebox/jukebox.env /etc/jukebox/jukebox.env.before-jukebox-tap
```

`/etc/asound.conf` is never modified by this guide.

## 1. Install the build tools and aubio

```sh
sudo apt update
sudo apt install -y build-essential pkg-config libaubio-dev alsa-utils
```

`libaubio-dev` is the beat-tracking library; `alsa-utils` provides `aplay`
and `speaker-test`, used below.

## 2. Build and test the analyser

As your own user, not root:

```sh
cd /opt/jukebox-src/native/jukebox_audio_analyzer
make
make test
```

`make test` needs no audio hardware: it generates test signals, runs them
through the analyser and ends with a line such as `55 passed`. On a Pi 2 it
takes a few minutes, most of them in "the socket" section, which analyses ten
minutes of audio in one go. Do not go further if a test fails; the output
names the check that failed.

```sh
build/jukebox_audio_analyzer --version
# jukebox_audio_analyzer 1.0 (level, bass, onset, beat and tempo; aubio)
```

On a Raspberry Pi 2 (`uname -m` prints `armv7l`) the Makefile adds
`-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard`. If the compiler refuses
those flags, build with `make ARCH_CFLAGS=`.

## 3. Install the analyser, the group, the socket directory and the ALSA device

```sh
cd /opt/jukebox-src
sudo sh ops/audio/install-audio-tap.sh
```

The script does four things and changes nothing about how audio is played
today (Shairport Sync still uses the DAC directly afterwards):

| Step | What | Equivalent commands |
| --- | --- | --- |
| 1 | Copies the analyser and its wrapper to `/opt/jukebox/bin/` | `sudo make -C native/jukebox_audio_analyzer install` |
| 2 | Creates the group `jukebox-audio` and adds the Shairport Sync user to it | `sudo groupadd --system jukebox-audio`<br>`sudo usermod -a -G jukebox-audio shairport-sync` |
| 3 | Creates `/run/jukebox`, now and at every boot | `sudo cp ops/audio/jukebox-audio.tmpfiles.conf.example /etc/tmpfiles.d/jukebox-audio.conf`<br>`sudo systemd-tmpfiles --create /etc/tmpfiles.d/jukebox-audio.conf` |
| 4 | Installs the ALSA device as a file of its own | `sudo cp ops/audio/jukebox-tap.conf.example /etc/alsa/conf.d/60-jukebox-tap.conf` |

Why a group: the analyser is started by ALSA inside Shairport Sync, so it
runs as the Shairport Sync user, while the socket belongs to `jukebox`. The
directory is owned by `jukebox`, readable by the group `jukebox-audio` and
closed to everyone else (mode `2750`); Phoenix makes the socket writable by
that group (`0660`). No other permission is widened.

If Shairport Sync runs as another user than `shairport-sync`
(`systemctl show -p User shairport-sync` tells), or the DAC has another name:

```sh
sudo SHAIRPORT_USER=someuser JUKEBOX_DAC='plughw:CARD=Other,DEV=0' sh ops/audio/install-audio-tap.sh
```

Check the result:

```sh
aplay -L | grep -A1 '^jukebox_tap'
# jukebox_tap
#     Jukebox: USB DAC with a copy of the audio for the display
ls -ld /run/jukebox
# drwxr-s--- 2 jukebox jukebox-audio ... /run/jukebox
id shairport-sync
# ... groups=...,jukebox-audio
```

Shairport Sync only gets its new group when it restarts; that happens in
step 6.

### If /etc/alsa/conf.d is missing

On a system whose ALSA does not read `/etc/alsa/conf.d`, the script stops at
step 4. Add the device to `/etc/asound.conf` by hand instead, after a copy:

```sh
[ -f /etc/asound.conf ] && sudo cp -p /etc/asound.conf /etc/asound.conf.before-jukebox-tap
sed -n '/^pcm.jukebox_tap/,$p' ops/audio/jukebox-tap.conf.example | sudo tee -a /etc/asound.conf
```

To undo it, restore the copy (or delete the `pcm.jukebox_tap { ... }` block).

## 4. Enable the display side

Edit `/etc/jukebox/jukebox.env` (`sudo nano /etc/jukebox/jukebox.env`) and
set, adding the lines if your file predates them (they are in
`ops/jukebox.env.example`):

```sh
AUDIO_REACTIVE_ENABLED=true
AUDIO_REACTIVE_SOURCE=native
AUDIO_ANALYSIS_SOCKET=/run/jukebox/audio-analysis.sock
AUDIO_ANALYSIS_PUBLISH_RATE=20
AUDIO_VISUAL_DELAY_MS=0
AUDIO_BEAT_CONFIDENCE_THRESHOLD=0.45
```

```sh
sudo systemctl restart jukebox
journalctl -u jukebox -n 20 --no-pager | grep audio
# [audio] listening for analysis frames on /run/jukebox/audio-analysis.sock
sudo ls -l /run/jukebox
# srw-rw---- 1 jukebox jukebox-audio 0 ... audio-analysis.sock
```

Nothing changes on screen yet: no frames arrive, so the display keeps its
fixed-tempo animation. That is also what it does whenever this socket cannot
be created; the journal then says `[audio] cannot listen on ...` once and the
application keeps retrying on its own.

## 5. Test the tap without AirPlay

Make sure nothing is playing over AirPlay (the DAC accepts one player at a
time), turn the amplifier down, and play a two-second test tone through the
tap **as the Shairport Sync user**, which is who will use it:

```sh
sudo -u shairport-sync speaker-test -D jukebox_tap -c 2 -r 44100 -F S16_LE -t sine -f 440 -l 1
```

Expected:

- you hear the tone on both speakers;
- the command prints nothing from `jukebox_audio_analyzer` or
  `jukebox_audio_tap`. A line such as
  `cannot send to /run/jukebox/audio-analysis.sock (Permission denied)` means
  the group or the socket is not right (see [Troubleshooting](#troubleshooting));
  the tone must play even then.

Then confirm that Phoenix received frames:

```sh
sudo -H -u jukebox /opt/jukebox/bin/jukebox rpc 'IO.inspect(Jukebox.AudioAnalysis.NativeSource.status())'
# %{listening?: true, received: 40, published: 40, rejected: 0, dropped: 0,
#   last_frame: %Jukebox.AudioAnalysis.Frame{level: 1.0, ...}, ...}
```

`received` must be greater than zero and `rejected` must be zero.

The direct device must still work too:

```sh
sudo -u shairport-sync speaker-test -D plughw:CARD=Audio,DEV=0 -c 2 -r 44100 -F S16_LE -t sine -f 440 -l 1
```

## 6. Switch Shairport Sync to the tap

Edit the `alsa` section of `/etc/shairport-sync.conf`
(`sudo nano /etc/shairport-sync.conf`). You made a copy of this file in
"Before you start".

```ini
alsa = {
    output_device = "jukebox_tap";   // was "plughw:CARD=Audio,DEV=0"
    output_format = "S16";
    buffer_size = 8820;
};
```

- `output_device` is the only line that selects the tap.
- `output_format = "S16"` keeps the stream in the format the analyser is
  tested with (it also reads S24 and S32, at twice the data).
- `buffer_size = 8820` (0.2 s of audio) is **required**. Left alone, ALSA
  gives Shairport Sync the largest buffer the DAC offers, several seconds on
  a USB DAC, and the tap hands each sample to the analyser one whole buffer
  after it was queued: the display would react seconds late. See
  [Calibrating](#calibrating).
- If you use a hardware volume control (`mixer_control_name`), also set
  `mixer_device = "hw:CARD=Audio";`: the tap has no mixer of its own.

```sh
sudo systemctl restart shairport-sync
systemctl is-active shairport-sync
journalctl -u shairport-sync -n 30 --no-pager
```

If Shairport Sync does not start, or AirPlay gives no sound, go back at once
(`sudo sh /opt/jukebox-src/ops/audio/rollback-audio-tap.sh`) and read the
journal lines above before trying again.

## 7. Test with AirPlay

Play music from the iPhone. On the kiosk, with the animation style on `chase`
(the default; the animation button cycles the styles):

- the waves under the track title rise and fall with the loudness;
- the cover swells slightly on bass hits (the screen background stays still);
- the bulb rows are dimmer in quiet passages;
- on music with a clear beat the lamps step on that beat instead of the
  steady 120 BPM.

While it plays:

```sh
# The analyser is running (one process per playback session)
pgrep -af jukebox_audio_analyzer

# The buffer Shairport Sync obtained: buffer_size must be 8820 (or close)
cat /proc/asound/card*/pcm*p/sub*/hw_params

# What the analyser currently reports (confidence, bpm, ...)
sudo -H -u jukebox /opt/jukebox/bin/jukebox rpc 'IO.inspect(Jukebox.AudioAnalysis.NativeSource.status())'
```

Pause on the iPhone: the lights hold still and the audio effects fade out.
Resume: they come back.

## Calibrating

### Why the lights can only be late, and what to do about it

Reading the source of the ALSA `file` plugin (alsa-lib 1.2.8, the version in
Raspberry Pi OS 12) shows that it does not hand a sample to the analyser when
Shairport Sync writes it, but one full ALSA buffer later. Shairport Sync keeps
about 0.15 s of audio queued in front of the DAC (0.2 s in some versions;
`audio_backend_buffer_desired_length_in_seconds`). So:

```text
lights behind the sound  ≈  buffer_size / 44100  −  0.15 s   (the tap)
                          +  about 0.05 to 0.1 s             (analysis and display)
```

With `buffer_size = 8820` that is roughly a tenth of a second. This is
derived from the source code, not measured: the first thing to do on the Pi is
to look.

1. Play something with a sharp, regular click (a metronome app or video) and
   watch the lamp flash in the `chase` style.
2. **Lights after the click:** lower `buffer_size` in
   `/etc/shairport-sync.conf` step by step (8820 → 8000 → 7400), restarting
   Shairport Sync each time. Do not go below about 7350: Shairport Sync needs
   its 0.15 s plus a little room and refuses to start otherwise (go back up
   if it does, or if the sound stutters). Leave `AUDIO_VISUAL_DELAY_MS=0`.
3. **Lights before the click** (not expected, but the hardware decides): raise
   `AUDIO_VISUAL_DELAY_MS` in `/etc/jukebox/jukebox.env` in steps of 20 and
   `sudo systemctl restart jukebox`. The kiosk reconnects by itself within a
   few seconds and uses the new value; nothing is recompiled.

A delay that cannot be removed this way would need the lights to anticipate
the next beat from the tempo. That is not implemented.

### Beat confidence

The analyser reports how sure it is of the beat, from 0 to 1. Below
`AUDIO_BEAT_CONFIDENCE_THRESHOLD` the lights keep the fixed tempo
(`JUKEBOX_ANIMATION_BPM`); loudness, bass and attacks are followed either way.

The scale was set from a handful of loops on the development Mac (drum
patterns and full mixes land near 0.9, pads and sustained bass near 0), not
from real albums. While a track plays, read the value:

```sh
sudo -H -u jukebox /opt/jukebox/bin/jukebox rpc 'IO.inspect(Jukebox.AudioAnalysis.NativeSource.status().last_frame)'
```

- Lights stay on the fixed tempo although the beat is obvious: lower the
  threshold (for example `0.3`).
- Lights stumble on music without a steady beat: raise it (for example `0.6`).

If the values are wrong across the board, the two constants to change are
`CONFIDENCE_FLOOR` and `CONFIDENCE_FULL_SCALE` in
`native/jukebox_audio_analyzer/src/config.h`, followed by `make` and
`sudo make install`. All other tuning constants of the analysis are in that
file as well.

The tempo itself comes from aubio. It sometimes locks onto two thirds or
double the real tempo (a 140 BPM pattern was reported as 94 in testing). The
lights are then regular, but not on every beat.

## Logs

| What | Where |
| --- | --- |
| The analyser and the tap wrapper | `journalctl -u shairport-sync -f` (they are started by Shairport Sync; their messages begin with `jukebox_audio_`) |
| Shairport Sync itself (underruns, resynchronisation) | `journalctl -u shairport-sync --since "1 hour ago" \| grep -i -E "underrun\|xrun\|resync\|sync error"` |
| The Phoenix side | `journalctl -u jukebox -f \| grep audio` |

The analyser is quiet by design. It writes one line when something is wrong
(an unsupported format, a socket it cannot reach) and repeats a given problem
at most once a minute.

## Monitoring CPU and memory

Targets on the Raspberry Pi 2: the analyser below 10 % of one core and below
30 MB of memory, and no growth over time.

```sh
# The analyser: %CPU, memory in kB (RSS), running time
ps -o pid,pcpu,rss,etime,cmd -p "$(pgrep -n -f /opt/jukebox/bin/jukebox_audio_analyzer)"

# The same every 5 seconds for a minute
top -b -d 5 -n 12 -p "$(pgrep -n -f /opt/jukebox/bin/jukebox_audio_analyzer)" | grep jukebox

# The whole machine: memory and swap (si/so must stay at 0)
free -m
vmstat 5

# Who uses the CPU (Chromium is expected at the top)
top -o %CPU
```

On the development Mac the analyser used 1 s of CPU for 10 minutes of audio
and 2 MB of memory. That says the work is small; it does not say what a
Cortex-A7 will show.

If Chromium struggles, lower `AUDIO_ANALYSIS_PUBLISH_RATE` (and
`--publish-rate` in `/etc/alsa/conf.d/60-jukebox-tap.conf`) to 10.

## Reverting

Immediately, back to direct DAC output (the display falls back to its
fixed-tempo animation by itself):

```sh
sudo sh /opt/jukebox-src/ops/audio/rollback-audio-tap.sh
```

It replaces `output_device = "jukebox_tap"` with
`output_device = "plughw:CARD=Audio,DEV=0"` in `/etc/shairport-sync.conf`
(keeping a dated copy of the file) and restarts Shairport Sync. By hand, the
same thing is:

```sh
sudo cp -p /etc/shairport-sync.conf.before-jukebox-tap /etc/shairport-sync.conf
sudo systemctl restart shairport-sync
```

To remove everything else as well:

```sh
sudo sh /opt/jukebox-src/ops/audio/rollback-audio-tap.sh --remove   # ALSA device, /run/jukebox rule
sudo nano /etc/jukebox/jukebox.env                                  # AUDIO_REACTIVE_ENABLED=false
sudo systemctl restart jukebox
```

## Troubleshooting

| Symptom | Likely cause and what to do |
| --- | --- |
| No sound after switching to `jukebox_tap` | Roll back first. Then `journalctl -u shairport-sync -n 50`: an ALSA error naming `jukebox_tap` means the device file is wrong or missing (`aplay -L`); `Broken configuration` means `buffer_size` is too small, raise it. |
| Sound, but no reaction on screen | `status` (step 5) shows `received: 0`: the analyser cannot reach the socket. Look for `cannot send to` in `journalctl -u shairport-sync`. `Permission denied`: Shairport Sync was not restarted after joining the group, or `/run/jukebox` is not `jukebox:jukebox-audio` mode `2750`. `No such file or directory`: Phoenix is not listening (`AUDIO_REACTIVE_ENABLED`, `journalctl -u jukebox`). |
| `status` shows frames, screen does not react | The animation style is `calm` (press the animation button), or the kiosk shows the idle screen. Reload Chromium once after the first deployment so it runs the new JavaScript. |
| `unsupported sample format` in the Shairport journal | Set `output_format = "S16";` in the `alsa` section. Playback is not affected, only the analysis. |
| `jukebox_audio_tap: ... is missing or not executable` | `/opt/jukebox/bin/jukebox_audio_analyzer` is gone (for instance after replacing `/opt/jukebox`). Run `sudo make -C /opt/jukebox-src/native/jukebox_audio_analyzer install`. Playback is not affected. |
| Reaction arrives seconds late | `buffer_size` is not set or was not accepted: check `cat /proc/asound/card*/pcm*p/sub*/hw_params` while playing. |
| Clicks, dropouts, `underrun` in the journal | Raise `buffer_size` (for example 11025). If it persists, roll back: playback matters more than the animation. |
| Lights step on the fixed tempo only | Confidence below the threshold: see [Beat confidence](#beat-confidence). |
| `rejected` grows in `status` | The analyser and the application disagree on the format of the frames: rebuild and reinstall the analyser from the same source as the release. |

## Hardware validation checklist

The feature is validated on the Raspberry Pi only when every line passes.

| # | Check | How |
| --- | --- | --- |
| 1 | Direct DAC playback still works | Second `speaker-test` of step 5; or roll back and AirPlay |
| 2 | AirPlay plays through `jukebox_tap` | Step 7: sound, and `pgrep -af jukebox_audio_analyzer` shows the process |
| 3 | Loudness drives the animation | Waves and bulb brightness follow quiet and loud passages |
| 4 | Bass pulses look natural | The cover moves on bass hits, not constantly |
| 5 | Beats are followed on music with a clear beat | Lamps step with the music; `last_frame` shows a plausible `bpm` and `confidence` above the threshold |
| 6 | Quiet or free-tempo music falls back | Lamps keep the steady fixed tempo; waves still follow the loudness |
| 7 | One hour of uninterrupted audio | Play an hour; no click or dropout by ear |
| 8 | No recurring underruns or resynchronisation | `journalctl -u shairport-sync --since "1 hour ago" \| grep -i -E "underrun\|xrun\|resync\|sync error"` shows nothing recurring |
| 9 | Restarting Phoenix does not stop the music | `sudo systemctl restart jukebox` while playing: sound continues, the screen comes back and reacts again |
| 10 | A missing receiver does not block the audio | `sudo systemctl stop jukebox` while playing for a minute: sound continues; start it again |
| 11 | CPU, memory and swap stay stable | Commands of [Monitoring](#monitoring-cpu-and-memory) at the start and after the hour: analyser under 10 % and 30 MB, `si`/`so` at 0 |
| 12 | The visual delay can be calibrated | [Calibrating](#calibrating): changing `buffer_size` or `AUDIO_VISUAL_DELAY_MS` visibly moves the lights relative to the sound |
| 13 | A crashed analyser does not stop the music | While playing: `sudo pkill -f /opt/jukebox/bin/jukebox_audio_analyzer`. Sound continues, the display returns to the fixed tempo, and the journal shows one `jukebox_audio_tap: the analyser stopped` line. Analysis resumes at the next playback session. |
| 14 | Everything survives a reboot | Reboot, AirPlay: `/run/jukebox` exists again and the screen reacts |

## What was tested where

| | Tested on the development Mac | Simulated on the Mac | Only the Raspberry Pi can tell |
| --- | --- | --- | --- |
| Phoenix: frame decoding, socket, rate limit, fallback when the socket cannot be created | Automated tests, with real Unix datagram sockets | | Socket permissions across two system users |
| Browser: smoothing, delay queue, beat detection, fallback to the fixed tempo, single animation loop | Automated tests (`mix test.js`) and a run in headless Chrome | The frames came from the simulated source, not from audio | Smoothness and CPU cost in Chromium on the Pi 2 |
| Analyser: PCM formats, loudness, bass, attacks, beats, tempo, never blocking on its input | `make test` (generated signals), plus a handful of real loops for the confidence scale | | Building for ARMv7 with the distribution's aubio; CPU and memory; behaviour on real albums |
| Analyser to Phoenix | Generated PCM piped through the analyser into the application | | The same through ALSA and Shairport Sync |
| ALSA tap (`jukebox_tap`) | | | Everything: the device file has never been loaded by ALSA |
| Timing of lights against sound | | | Everything: the figures in [Calibrating](#calibrating) come from reading source code |
| Install and rollback scripts | Shell syntax only | | They have never been executed |
