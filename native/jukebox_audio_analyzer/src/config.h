/*
 * Tuning constants of jukebox_audio_analyzer.
 *
 * Everything that shapes the analysis is here, in one place. Command-line
 * options only cover what ALSA knows at run time (the stream format) and
 * where the results go.
 */
#ifndef JUKEBOX_AUDIO_ANALYZER_CONFIG_H
#define JUKEBOX_AUDIO_ANALYZER_CONFIG_H

/* -- analysis frames ------------------------------------------------------- */

/* Window and hop of the spectral analysis (aubio), in mono samples. The
 * loudness and bass measurements advance by the same hop. */
#define ANALYSIS_BUFFER_SIZE 1024
#define ANALYSIS_HOP_SIZE 512

/* -- publication ------------------------------------------------------------ */

#define DEFAULT_SOCKET_PATH "/run/jukebox/audio-analysis.sock"
/* Frames per second sent to the socket; --publish-rate overrides it. */
#define DEFAULT_PUBLISH_RATE 20
#define MIN_PUBLISH_RATE 1
#define MAX_PUBLISH_RATE 20
/* A frame carrying a new beat may leave up to this fraction of a publication
 * interval early, taking the place of the frame that was due next, so a beat
 * is never held back by more than about half an interval. */
#define EARLY_BEAT_FRACTION 0.5
/* A given problem (socket unreachable, ...) is written to stderr at most once
 * per this many seconds: stderr ends up in the Shairport Sync journal. */
#define ERROR_REPORT_INTERVAL_S 60

/* -- loudness and bass ------------------------------------------------------- */

/* Below this the input is silence and every value is exactly zero. */
#define SILENCE_DB (-70.0)

/* Loudness and bass are shown relative to what the music has been doing
 * lately, so the picture is as lively at a low listening volume as at a high
 * one, and for heavily compressed music as for dynamic music. Two references
 * are kept, in dB:
 *
 *   high   jumps up to every new maximum and drifts down slowly
 *   low    drops to every new minimum and drifts up a little faster
 *
 * A value is 1.0 at the high reference and 0.0 at the low one. The distance
 * between them is kept within a minimum (so the ripple of a steady sound is
 * not blown up to full scale) and a maximum (so one quiet moment does not
 * flatten everything else). The high reference never goes below its floor,
 * which keeps faint noise from reading as loud music. */
#define REFERENCE_DECAY_DB_PER_S 1.5
#define REFERENCE_RISE_DB_PER_S 3.0
#define REFERENCE_MIN_RANGE_DB 10.0
#define REFERENCE_MAX_RANGE_DB 36.0

#define LEVEL_REFERENCE_FLOOR_DB (-40.0)

/* The bass band, cut out with two second-order filters. */
#define BASS_LOW_HZ 40.0
#define BASS_HIGH_HZ 180.0
#define BASS_REFERENCE_FLOOR_DB (-46.0)

/* -- attacks (onsets) --------------------------------------------------------- */

/* aubio onset detection: method, peak-picking threshold, shortest time
 * between two attacks and the level below which nothing is an attack. */
#define ONSET_METHOD "specflux"
#define ONSET_THRESHOLD 0.3
#define ONSET_MIN_INTERVAL_MS 60.0
#define ONSET_SILENCE_DB (-60.0)
/* aubio says *when* there is an attack; how strong it is comes from how far
 * the loudness jumped above its recent average (over ONSET_AVERAGE_MS). A
 * jump of ONSET_FULL_SCALE_DB reads as 1.0, and a detected attack never reads
 * lower than ONSET_MIN_STRENGTH. aubio reports an attack a few hops after it
 * happened, so the largest recent jump is remembered for ONSET_HOLD_MS. */
#define ONSET_AVERAGE_MS 150.0
#define ONSET_HOLD_MS 80.0
#define ONSET_FULL_SCALE_DB 9.0
#define ONSET_MIN_STRENGTH 0.25

/* Without aubio (make AUBIO=0) the jump in loudness is also what detects the
 * attack: anything above this many dB counts. */
#define FLUX_MIN_DB 3.0

/* -- beats and tempo ---------------------------------------------------------- */

#define TEMPO_METHOD "default"
#define TEMPO_SILENCE_DB (-70.0)

/* aubio's own confidence has no fixed scale. Measured on a handful of loops
 * (see docs/audio-reactive-setup.md, "Calibrating"): about 0.10 for sound
 * without a beat (pads, sustained bass), about 0.3 for a full mix with a
 * clear beat, 1 to 8 for drums alone. It is turned into 0..1 in two steps:
 * stretched from the floor (0.0) to the full-scale value (1.0), then
 * multiplied by how well the last beats sit on the tracker's own grid. */
#define CONFIDENCE_FLOOR 0.12
#define CONFIDENCE_FULL_SCALE 0.30
/* Number of recent beat-to-beat intervals looked at. Each should be a whole
 * number of beats long (the tracker skips beats in quiet moments); the grid
 * factor reaches zero when they are off by this fraction of a beat on
 * average. */
#define BEAT_HISTORY 8
#define BEAT_GRID_TOLERANCE 0.25
/* No tempo is reported before this many beats, nor outside this range. */
#define BPM_MIN_BEATS 4
#define BPM_MIN 40.0
#define BPM_MAX 240.0
/* Without a beat for this long the confidence falls to zero and the tempo is
 * withdrawn. */
#define BEAT_TIMEOUT_S 3.0
/* Confidence moves towards its new value by this fraction per published
 * frame, so one odd estimate does not flip the display's choice of beat. */
#define CONFIDENCE_SMOOTHING 0.25

#endif
