Implement real-time audio-reactive animations in the existing Phoenix LiveView jukebox application.

## 1. Project context

The application is a dedicated DIY jukebox running on:

- Raspberry Pi 2 Model B;
- 1 GB RAM;
- Raspberry Pi OS 32-bit;
- Phoenix and LiveView;
- Chromium in kiosk mode;
- Shairport Sync receiving AirPlay audio from an iPhone;
- a USB DAC configured as `plughw:CARD=Audio,DEV=0`;
- an external amplifier and speakers.

Shairport Sync currently sends audio directly to the USB DAC. The Phoenix application receives metadata, but it has no access to the PCM audio.

The existing interface already contains animated jukebox lights, currently driven by a fixed timer in or around `jukebox_lights.js`.

The implementation must remain light enough for a Raspberry Pi 2. Chromium is already the most resource-intensive process, so audio analysis must not be performed in the browser.

## 2. Objective

Make the existing interface react to the music currently being played through AirPlay.

The following visual properties should be available:

- overall loudness;
- bass energy;
- musical attacks/transients;
- detected beats;
- estimated BPM;
- beat-detection confidence.

These values should drive effects such as:

- wave height;
- background and light intensity;
- subtle album-cover scaling;
- short light flashes;
- color transitions;
- beat-synchronised jukebox-light animations.

The existing fixed-tempo animation must remain available as a fallback.

This data should also be reusable later for physical LED control, but implementing physical LED control is not part of this task.

## 3. Important architectural decisions

### Do not use these approaches

Do not:

- analyse audio in Chromium;
- run FFT or beat detection in JavaScript;
- send microphone audio to the application;
- use a Phoenix or Erlang NIF for audio analysis;
- rerender the LiveView DOM 20 times per second;
- use `snd-aloop` as the first implementation;
- make Phoenix part of the critical audio playback path;
- write raw PCM data to the SD card.

### Required architecture

Use this pipeline:

```text
Shairport Sync
    |
    v
ALSA jukebox_tap PCM
    |
    +----> USB DAC --> amplifier --> speakers
    |
    +----> native audio analyser
                 |
                 v
         local Unix datagrams
                 |
                 v
        Phoenix audio adapter
                 |
                 v
          LiveView push_event
                 |
                 v
        JavaScript animation hook
```

The real USB DAC must remain the ALSA slave used for playback.

## 4. ALSA audio tap

Create an ALSA PCM wrapper based on the ALSA `file` plugin. The plugin must:

1. forward the audio to the real USB DAC;
2. pipe a copy of the raw PCM stream to the analyser.

The intended configuration is conceptually similar to:

```ini
pcm.jukebox_tap {
    type file
    slave.pcm "plughw:CARD=Audio,DEV=0"
    file "|/opt/jukebox/bin/jukebox_audio_analyzer --sample-rate %r --channels %c --bits %b --format %f --socket /run/jukebox/audio-analysis.sock"
    format "raw"
}
```

Shairport Sync will then use:

```ini
alsa = {
    output_device = "jukebox_tap";
};
```

Adapt the final syntax if required by the ALSA version available on Raspberry Pi OS.

Do not automatically overwrite `/etc/asound.conf` or the Shairport Sync configuration during application deployment. Provide:

- a documented configuration file;
- an installation script or exact installation commands;
- a backup procedure;
- a rollback procedure restoring direct output to `plughw:CARD=Audio,DEV=0`.

The analyser must continue consuming PCM even when Phoenix is stopped or the Unix socket does not exist. Failure to send analysis results must never make the analyser stop reading its input.

## 5. Native audio analyser

Create a small native executable named:

```text
jukebox_audio_analyzer
```

Preferred implementation:

- C;
- `libaubio` for onset, tempo and beat detection;
- no Python runtime;
- no Node.js runtime;
- no permanent audio recording;
- optimized for ARMv7 and Raspberry Pi 2;
- compiled with ordinary optimization such as `-O2`.

The executable reads raw interleaved PCM from standard input.

It must accept at least:

```text
--sample-rate
--channels
--bits
--format
--socket
--publish-rate
```

Initially support:

- `S16_LE`;
- stereo;
- 44,100 Hz;
- 48,000 Hz.

If an unsupported format is received, report the problem once, but avoid producing an endless log loop.

### Audio analysis

Downmix stereo to mono for analysis.

Calculate:

1. `level`
   - RMS loudness;
   - represented as a normalized value from `0.0` to `1.0`;
   - use logarithmic/dB scaling rather than raw linear RMS.

2. `bass`
   - normalized energy in approximately the 40–180 Hz range;
   - represented from `0.0` to `1.0`.

3. `onset`
   - transient or musical-attack strength;
   - represented from `0.0` to `1.0`.

4. `beat`
   - a discrete beat event;
   - increment a monotonically increasing `beat_id` for every detected beat.

5. `bpm`
   - current estimated tempo;
   - null or zero until a sufficiently stable estimate exists.

6. `confidence`
   - confidence in beat/tempo tracking;
   - represented from `0.0` to `1.0`.

Reasonable initial aubio settings are:

- buffer size: 1024 samples;
- hop size: 512 samples;
- onset method: `specflux` or another method suitable for mixed music;
- maximum publication rate: 20 frames per second.

These values must be configurable constants rather than scattered magic numbers.

### Native output protocol

Send one compact JSON object per Unix datagram:

```json
{
  "level": 0.42,
  "bass": 0.71,
  "onset": 0.83,
  "beat_id": 127,
  "bpm": 118.4,
  "confidence": 0.76
}
```

Requirements:

- do not wait for an acknowledgment;
- use non-blocking socket transmission;
- silently drop a frame if the receiver is unavailable;
- never block PCM consumption while sending;
- rate-limit errors written to stderr;
- never write audio or continuous debug output to stdout;
- never accumulate an unbounded queue;
- drop analysis frames rather than delaying audio consumption.

## 6. Unix socket and permissions

Use this default socket:

```text
/run/jukebox/audio-analysis.sock
```

The solution must work when:

- Phoenix runs as user `jukebox`;
- Shairport Sync and the spawned analyser may run as another system user.

Document a shared-group solution, for example `jukebox-audio`, instead of granting unnecessarily broad permissions.

Both relevant users must be able to access the socket directory.

If the socket disappears because Phoenix restarts, the analyser must continue running and resume sending automatically when the socket becomes available again.

## 7. Phoenix architecture

Follow the conventions already used by the existing metadata adapters.

Create an audio-analysis abstraction with at least:

```elixir
Jukebox.AudioAnalysis.Source
Jukebox.AudioAnalysis.NativeSource
Jukebox.AudioAnalysis.SimulatedSource
```

Adapt the namespace to the existing application name if necessary.

### Source behaviour

The source must expose normalized audio frames independently of how they are produced.

Use a structure similar to:

```elixir
%Jukebox.AudioAnalysis.Frame{
  level: 0.42,
  bass: 0.71,
  onset: 0.83,
  beat_id: 127,
  bpm: 118.4,
  confidence: 0.76
}
```

### Native source

`NativeSource` must:

- create and listen on the Unix datagram socket;
- decode incoming JSON;
- reject malformed payloads;
- clamp normalized values to `0.0..1.0`;
- reject invalid numbers, NaN and infinity;
- track the last received frame time;
- publish valid frames through Phoenix PubSub;
- never crash the application because of a malformed native message;
- recreate the socket after a supervised restart.

Use a PubSub topic such as:

```text
audio_analysis
```

### Simulated source

`SimulatedSource` must make development possible on macOS without ALSA or aubio.

It should produce deterministic but natural-looking values:

- continuously changing loudness;
- stronger bass pulses;
- regular beat events;
- configurable BPM;
- occasional onsets.

It must be usable in development and automated tests.

### Configuration

Add runtime configuration through environment variables:

```text
AUDIO_REACTIVE_ENABLED=true
AUDIO_REACTIVE_SOURCE=native
AUDIO_ANALYSIS_SOCKET=/run/jukebox/audio-analysis.sock
AUDIO_ANALYSIS_PUBLISH_RATE=20
AUDIO_VISUAL_DELAY_MS=120
AUDIO_BEAT_CONFIDENCE_THRESHOLD=0.45
```

Supported source values:

```text
disabled
simulated
native
```

Production must not fail to boot when audio analysis is disabled or unavailable.

## 8. LiveView integration

The relevant LiveView must subscribe to audio-analysis PubSub messages only when connected.

Do not store every audio frame in assigns in a way that causes a LiveView DOM diff.

Instead, send a compact browser event:

```elixir
push_event(socket, "audio-frame", %{
  level: frame.level,
  bass: frame.bass,
  onset: frame.onset,
  beat_id: frame.beat_id,
  bpm: frame.bpm,
  confidence: frame.confidence
})
```

The browser event rate must not exceed the configured publication rate.

Only the LiveView displaying the active jukebox interface should subscribe.

## 9. JavaScript animation controller

Create or extend a LiveView hook responsible for audio-reactive animation.

The hook must:

- listen for `audio-frame`;
- keep target and currently rendered values separately;
- interpolate values with `requestAnimationFrame`;
- update CSS custom properties;
- detect changes to `beat_id`;
- preserve the existing fixed-tempo animation as fallback;
- stop its animation loop when destroyed;
- avoid creating multiple animation loops after LiveView reconnects.

Suggested CSS properties:

```css
--audio-level
--audio-bass
--audio-onset
--audio-beat
--audio-bpm
```

Example uses:

```css
.album-cover {
  transform: scale(calc(1 + var(--audio-bass) * 0.035));
}

.audio-wave {
  transform: scaleY(calc(0.2 + var(--audio-level) * 0.8));
}

.jukebox-light {
  opacity: calc(0.25 + var(--audio-level) * 0.65);
}
```

Use separate smoothing characteristics:

- loudness attack: approximately 40–70 ms;
- loudness release: approximately 200–350 ms;
- bass attack: fast;
- bass release: approximately 150–250 ms;
- onset: short decay;
- beat: one discrete pulse, not a continuously true boolean.

Avoid expensive Raspberry Pi 2 rendering operations:

- no full-screen animated blur;
- no large animated box shadows;
- no continuous CSS filters;
- no layout-changing width or height animation;
- no WebGL requirement;
- no DOM creation on every frame.

Prefer:

- `transform`;
- `opacity`;
- CSS custom properties;
- a lightweight Canvas 2D renderer if waves cannot be implemented efficiently with CSS.

## 10. Visual delay compensation

The analyser receives samples when they are written to ALSA, slightly before those samples become audible through the DAC and speakers.

Implement a configurable visual delay:

```text
AUDIO_VISUAL_DELAY_MS=120
```

Apply it in the JavaScript controller using a small timestamped queue based on `performance.now()`.

Do not create one unmanaged `setTimeout` per animation property.

The delay must be adjustable without recompiling the application.

A value of 120 ms is only an initial default. The real value will be calibrated on the Raspberry Pi.

## 11. Fallback behaviour

The application must remain visually functional in all failure cases.

Required behaviour:

- if no native frame is received for 500 ms, smoothly return audio values toward zero;
- if native analysis remains unavailable, use the existing fixed-tempo animation;
- if beat confidence is below the configured threshold, continue using loudness, bass and onset but do not trust the detected beat grid;
- when confidence is low, the existing fixed timer may continue to drive periodic beat animations;
- when confidence becomes reliable again, transition back without a visible jump;
- when playback stops, fade to the existing idle state;
- when the native analyser crashes, Phoenix and Chromium must continue working;
- whenever possible, audio playback must continue even if the analyser fails.

Do not replace the current fallback animation. Integrate it as part of the new controller.

## 12. Performance requirements

Target performance on the Raspberry Pi 2:

- no more than 20 browser updates per second from the server;
- native analyser preferably below 10% of one CPU core during normal playback;
- native analyser preferably below 30 MB resident memory;
- no unbounded memory growth;
- no raw PCM storage;
- no growing event queue;
- no additional LiveView render loop;
- no progressive swap growth caused by this feature;
- no audible clicks, dropouts or timing drift.

Audio quality and playback stability take priority over animation accuracy.

## 13. Tests

Add automated tests for:

### Elixir

- valid native frame decoding;
- malformed JSON;
- missing fields;
- out-of-range values;
- NaN/infinity rejection where applicable;
- PubSub publication;
- source selection from configuration;
- stale-source detection;
- deterministic simulated-source output;
- application startup with the feature disabled.

### JavaScript

If the repository already has a JavaScript test setup, test:

- frame smoothing;
- beat detection through changing `beat_id`;
- stale-data fallback;
- confidence threshold;
- prevention of duplicate animation loops;
- visual-delay queue behaviour.

Do not introduce a disproportionately heavy JavaScript testing framework solely for this feature.

### Native analyser

Provide a way to feed a raw PCM or WAV-derived fixture into the analyser and verify that:

- frames are generated;
- values remain within bounds;
- silence approaches zero;
- a periodic test signal produces repeatable events;
- an unavailable Unix socket does not block input consumption.

Do not commit a large audio fixture.

## 14. Raspberry Pi installation documentation

Create a dedicated document such as:

```text
docs/audio-reactive-setup.md
```

It must include exact commands for:

1. installing build dependencies and aubio;
2. compiling the native analyser on 32-bit Raspberry Pi OS;
3. installing it under `/opt/jukebox/bin/`;
4. configuring the shared group and socket permissions;
5. installing the ALSA configuration;
6. changing the Shairport Sync output device to `jukebox_tap`;
7. restarting the relevant services;
8. testing the analyser without AirPlay;
9. testing with AirPlay;
10. inspecting logs;
11. monitoring CPU and memory;
12. reverting immediately to direct DAC output.

The documentation must assume that the operator is not an ALSA expert.

Do not assume commands tested on macOS will behave identically on the Raspberry Pi.

## 15. Hardware validation procedure

Provide a checklist for the user to run on the actual Raspberry Pi.

The implementation is not hardware-validated until all of these pass:

1. Direct DAC playback still works.
2. AirPlay playback works through `jukebox_tap`.
3. Loudness-driven animations react correctly.
4. Bass pulses appear natural.
5. Beat detection works on music with a clear beat.
6. Quiet or free-tempo music falls back gracefully.
7. Audio remains uninterrupted for at least one hour.
8. No recurring ALSA underruns or Shairport resynchronization errors appear.
9. Restarting Phoenix does not stop audio playback.
10. Disconnecting the analyser receiver does not block PCM consumption.
11. CPU, RAM and swap remain stable.
12. `AUDIO_VISUAL_DELAY_MS` can be calibrated.

Clearly distinguish in the final report between:

- code tested on the development Mac;
- functionality simulated on the development Mac;
- functionality that still requires Raspberry Pi validation.

## 16. Delivery phases

Implement in this order:

### Phase 1 — Application and simulator

- source behaviour;
- simulated source;
- PubSub integration;
- LiveView events;
- JavaScript hook;
- CSS variables;
- fixed-tempo fallback;
- automated tests.

This phase must work entirely on macOS.

### Phase 2 — Loudness analyser

- native executable;
- PCM parsing;
- RMS level;
- bass energy;
- Unix datagram transport;
- installation documentation.

Do not add aubio beat tracking until level and bass work reliably.

### Phase 3 — Beat analysis

- aubio onset detection;
- beat detection;
- BPM;
- confidence;
- fallback threshold;
- visual-delay calibration.

### Phase 4 — Raspberry Pi validation support

- ALSA tap configuration;
- setup and rollback instructions;
- diagnostic commands;
- hardware validation checklist.

## 17. Definition of done

The task is complete when:

- the simulator works on macOS;
- the application boots with analysis enabled, disabled or unavailable;
- the browser uses audio data without LiveView DOM rerenders;
- the existing fixed animation remains as fallback;
- the native analyser builds for 32-bit ARMv7;
- ALSA and Shairport configuration examples are provided;
- rollback is documented;
- automated tests pass;
- no generated binaries or large audio files are committed;
- hardware-only steps are clearly identified;
- the final response lists every added or modified file;
- the final response provides the exact commands the user must run next on the Raspberry Pi.

Do not silently simplify the feature to random browser animation. The production objective is to react to the PCM audio actually being played by Shairport Sync.