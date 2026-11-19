/*
 * jukebox_audio_analyzer
 *
 * Reads the raw PCM that Shairport Sync is playing (piped in by the ALSA
 * "file" plugin, see docs/audio-reactive-setup.md) and sends a few numbers
 * about it, 20 times a second, to the jukebox display:
 *
 *   {"level":0.42,"bass":0.71,"onset":0.83,"beat_id":127,"bpm":118.4,"confidence":0.76}
 *
 * one JSON object per Unix datagram, to the socket the Phoenix application
 * listens on.
 *
 * The one rule everything else follows from: THIS PROCESS SITS ON THE AUDIO
 * PATH. ALSA writes every sample that is played into our standard input, and
 * that write blocks the player when the pipe is full. So, whatever happens,
 * standard input is always read:
 *
 *   - sending never blocks and never waits for an answer; when the display is
 *     not listening the frame is dropped and forgotten;
 *   - nothing is queued, nothing is written to disk;
 *   - a stream format we cannot analyse, a socket we cannot create, an
 *     analysis library that refuses to start: each is reported once and the
 *     input is then read and thrown away for as long as it lasts;
 *   - the program ends when its input ends (ALSA waits for that when the
 *     player closes the device).
 *
 * Standard output is never written to, unless --print asks for it: that
 * option is for testing by hand and must not be used in the ALSA
 * configuration. Problems go to standard error, each kind at most once a
 * minute.
 *
 * Tuning constants live in config.h.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifdef HAVE_AUBIO
#include <aubio/aubio.h>
#endif

#include "config.h"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0 /* macOS: SIGPIPE is ignored instead (see main) */
#endif

#define PROGRAM "jukebox_audio_analyzer"
#define PI 3.14159265358979323846
#define READ_BUFFER_BYTES 16384
#define MAX_CHANNELS 8
#define MIN_SAMPLE_RATE 8000
#define MAX_SAMPLE_RATE 192000

/* -- reporting ---------------------------------------------------------------- */

/* One kind of problem, reported at most once per ERROR_REPORT_INTERVAL_S. */
typedef struct {
  time_t last;
  unsigned long suppressed;
} report_t;

static void report(report_t *r, const char *format, ...) {
  time_t now = time(NULL);
  if (r->last != 0 && now - r->last < ERROR_REPORT_INTERVAL_S) {
    r->suppressed++;
    return;
  }

  va_list args;
  fprintf(stderr, PROGRAM ": ");
  va_start(args, format);
  vfprintf(stderr, format, args);
  va_end(args);
  if (r->suppressed > 0) fprintf(stderr, " (%lu more like this since the last report)", r->suppressed);
  fputc('\n', stderr);

  r->last = now;
  r->suppressed = 0;
}

static void say(const char *format, ...) {
  va_list args;
  fprintf(stderr, PROGRAM ": ");
  va_start(args, format);
  vfprintf(stderr, format, args);
  va_end(args);
  fputc('\n', stderr);
}

/* -- sample formats ----------------------------------------------------------- */

typedef enum { FORMAT_UNKNOWN, FORMAT_S16_LE, FORMAT_S24_LE, FORMAT_S24_3LE, FORMAT_S32_LE } format_t;

/* ALSA format names, as the "file" plugin substitutes them for %f. */
static format_t format_from_name(const char *name) {
  if (strcmp(name, "S16_LE") == 0) return FORMAT_S16_LE;
  if (strcmp(name, "S24_LE") == 0) return FORMAT_S24_LE;
  if (strcmp(name, "S24_3LE") == 0) return FORMAT_S24_3LE;
  if (strcmp(name, "S32_LE") == 0) return FORMAT_S32_LE;
  return FORMAT_UNKNOWN;
}

/* Used when only --bits is given (%b is the size of one sample in bits). */
static format_t format_from_bits(int bits) {
  switch (bits) {
    case 16: return FORMAT_S16_LE;
    case 24: return FORMAT_S24_3LE;
    case 32: return FORMAT_S32_LE;
    default: return FORMAT_UNKNOWN;
  }
}

static size_t format_bytes(format_t format) {
  switch (format) {
    case FORMAT_S16_LE: return 2;
    case FORMAT_S24_3LE: return 3;
    case FORMAT_S24_LE:
    case FORMAT_S32_LE: return 4;
    default: return 0;
  }
}

/* One little-endian sample as a float in -1..1. */
static inline float decode_sample(const uint8_t *p, format_t format) {
  switch (format) {
    case FORMAT_S16_LE: {
      int16_t value = (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
      return (float)value / 32768.0f;
    }
    case FORMAT_S24_LE: /* 24 significant bits in the low three bytes of four */
    case FORMAT_S24_3LE: {
      uint32_t raw = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
      int32_t value = (raw & 0x800000u) ? (int32_t)(raw | 0xFF000000u) : (int32_t)raw;
      return (float)value / 8388608.0f;
    }
    case FORMAT_S32_LE: {
      uint32_t raw = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
      return (float)((double)(int32_t)raw / 2147483648.0);
    }
    default:
      return 0.0f;
  }
}

/* -- small maths ---------------------------------------------------------------- */

static double clamp01(double value) {
  if (!(value > 0.0)) return 0.0; /* also catches NaN */
  if (value > 1.0) return 1.0;
  return value;
}

static double to_db(double mean_square) {
  if (!(mean_square > 1e-20)) return -200.0;
  return 10.0 * log10(mean_square);
}

/* Second-order filter (RBJ cookbook), transposed direct form II. */
typedef struct {
  double b0, b1, b2, a1, a2, z1, z2;
} biquad_t;

static void biquad_set(biquad_t *f, double b0, double b1, double b2, double a0, double a1, double a2) {
  f->b0 = b0 / a0;
  f->b1 = b1 / a0;
  f->b2 = b2 / a0;
  f->a1 = a1 / a0;
  f->a2 = a2 / a0;
  f->z1 = 0.0;
  f->z2 = 0.0;
}

static void biquad_highpass(biquad_t *f, double sample_rate, double frequency) {
  double w = 2.0 * PI * frequency / sample_rate;
  double alpha = sin(w) / (2.0 * 0.7071);
  double c = cos(w);
  biquad_set(f, (1.0 + c) / 2.0, -(1.0 + c), (1.0 + c) / 2.0, 1.0 + alpha, -2.0 * c, 1.0 - alpha);
}

static void biquad_lowpass(biquad_t *f, double sample_rate, double frequency) {
  double w = 2.0 * PI * frequency / sample_rate;
  double alpha = sin(w) / (2.0 * 0.7071);
  double c = cos(w);
  biquad_set(f, (1.0 - c) / 2.0, 1.0 - c, (1.0 - c) / 2.0, 1.0 + alpha, -2.0 * c, 1.0 - alpha);
}

static inline double biquad_run(biquad_t *f, double x) {
  double y = f->b0 * x + f->z1;
  f->z1 = f->b1 * x - f->a1 * y + f->z2;
  f->z2 = f->b2 * x - f->a2 * y;
  return y;
}

/* After a long silence the filter memory decays into denormal numbers, which
 * some processors handle very slowly. */
static void biquad_flush(biquad_t *f) {
  if (fabs(f->z1) < 1e-25) f->z1 = 0.0;
  if (fabs(f->z2) < 1e-25) f->z2 = 0.0;
}

/* A level in dB turned into 0..1 between two references that follow the
 * recent maximum and minimum (see config.h). */
typedef struct {
  double high_db;
  double low_db;
  double floor_db;
} normaliser_t;

static void normaliser_init(normaliser_t *n, double floor_db) {
  n->high_db = floor_db;
  n->low_db = floor_db - REFERENCE_MIN_RANGE_DB;
  n->floor_db = floor_db;
}

static double normalise(normaliser_t *n, double db, double seconds) {
  n->high_db -= REFERENCE_DECAY_DB_PER_S * seconds;
  if (n->high_db < n->floor_db) n->high_db = n->floor_db;
  /* Silence says nothing about the music's own quiet moments. */
  if (db < SILENCE_DB) return 0.0;

  if (db > n->high_db) n->high_db = db;
  n->low_db += REFERENCE_RISE_DB_PER_S * seconds;
  if (db < n->low_db) n->low_db = db;
  if (n->low_db < n->high_db - REFERENCE_MAX_RANGE_DB) n->low_db = n->high_db - REFERENCE_MAX_RANGE_DB;
  if (n->low_db > n->high_db - REFERENCE_MIN_RANGE_DB) n->low_db = n->high_db - REFERENCE_MIN_RANGE_DB;

  return clamp01((db - n->low_db) / (n->high_db - n->low_db));
}

/* -- the analyser ----------------------------------------------------------------- */

typedef struct {
  /* stream */
  int sample_rate;
  int channels;
  format_t format;
  size_t frame_bytes;

  /* output */
  const char *socket_path;
  int socket_fd;
  struct sockaddr_un address;
  socklen_t address_length;
  int can_send;
  int print;
  report_t send_problem;

  /* one hop of mono samples being filled */
  float hop[ANALYSIS_HOP_SIZE];
  int hop_fill;

  /* what was measured since the last published frame */
  double window_square_sum;
  double window_bass_square_sum;
  long window_samples;
  double window_onset;

  /* publication clock, in samples */
  uint64_t clock;
  uint64_t next_publish;
  double publish_interval;
  double publish_remainder;

  biquad_t bass_highpass;
  biquad_t bass_lowpass;
  normaliser_t level_normaliser;
  normaliser_t bass_normaliser;

  /* beats */
  unsigned long beat_id;
  int beat_pending;
  uint64_t last_beat_clock;
  double beat_intervals[BEAT_HISTORY];
  int beat_interval_count;
  int beat_interval_next;
  double raw_bpm;
  double raw_confidence;
  double confidence;

  /* attacks: loudness per hop against its recent average */
  double loudness_average_db;
  double loudness_average_rate;
  double jump_db;
  double jump_hold;

#ifdef HAVE_AUBIO
  aubio_onset_t *onset;
  aubio_tempo_t *tempo;
  fvec_t *input;
  fvec_t *onset_output;
  fvec_t *tempo_output;
#endif
} analyser_t;

/* -- output -------------------------------------------------------------------- */

static void open_socket(analyser_t *a) {
  a->can_send = 0;
  a->socket_fd = -1;

  size_t length = strlen(a->socket_path);
  if (length == 0 || length >= sizeof(a->address.sun_path)) {
    say("socket path is empty or too long (%zu bytes, limit %zu): analysis frames will not be sent",
        length, sizeof(a->address.sun_path) - 1);
    return;
  }

  memset(&a->address, 0, sizeof(a->address));
  a->address.sun_family = AF_UNIX;
  memcpy(a->address.sun_path, a->socket_path, length + 1);
  a->address_length = (socklen_t)sizeof(a->address);

  /* Unconnected on purpose: the path is looked up again on every send, so a
   * receiver that restarts and recreates its socket is found again at once. */
  int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (fd < 0) {
    say("cannot create a socket (%s): analysis frames will not be sent", strerror(errno));
    return;
  }

  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
    say("cannot make the socket non-blocking (%s): analysis frames will not be sent", strerror(errno));
    close(fd);
    return;
  }
  (void)fcntl(fd, F_SETFD, FD_CLOEXEC);

  a->socket_fd = fd;
  a->can_send = 1;
}

/* Sends one frame, or drops it. Never blocks, never retries. */
static void send_frame(analyser_t *a, const char *json, size_t length) {
  if (a->print) {
    fputs(json, stdout);
    fputc('\n', stdout);
    fflush(stdout);
  }

  if (!a->can_send) return;

  ssize_t sent = sendto(a->socket_fd, json, length, MSG_NOSIGNAL, (const struct sockaddr *)&a->address, a->address_length);
  if (sent < 0) {
    /* Nobody listening (ENOENT, ECONNREFUSED), no permission (EACCES) or a
     * receiver that is not reading fast enough (EAGAIN, ENOBUFS): all the
     * same to us. The next frame tries again. */
    report(&a->send_problem, "cannot send to %s (%s); frames are dropped until it is reachable", a->socket_path,
           strerror(errno));
  }
}

/* -- beats ------------------------------------------------------------------------ */

#ifdef HAVE_AUBIO
static void note_beat(analyser_t *a) {
  a->beat_id++;
  a->beat_pending = 1;

  if (a->last_beat_clock != 0) {
    a->beat_intervals[a->beat_interval_next] = (double)(a->clock - a->last_beat_clock);
    a->beat_interval_next = (a->beat_interval_next + 1) % BEAT_HISTORY;
    if (a->beat_interval_count < BEAT_HISTORY) a->beat_interval_count++;
  }
  a->last_beat_clock = a->clock;
}
#endif

/* 1.0 when the recent beats sit on the grid of the estimated tempo, falling
 * to 0.0 as they wander off it. An interval of two or three beats (the
 * tracker stays quiet in quiet moments) is on the grid too. */
static double beat_regularity(const analyser_t *a) {
  int n = a->beat_interval_count;
  if (n < 3 || !(a->raw_bpm > 0.0)) return 0.0;

  double period = 60.0 / a->raw_bpm * a->sample_rate;
  double error = 0.0;
  for (int i = 0; i < n; i++) {
    double beats = a->beat_intervals[i] / period;
    double whole = floor(beats + 0.5);
    error += whole < 1.0 ? 1.0 : fabs(beats - whole);
  }
  return clamp01(1.0 - (error / n) / BEAT_GRID_TOLERANCE);
}

static void forget_beats(analyser_t *a) {
  a->beat_interval_count = 0;
  a->beat_interval_next = 0;
  a->last_beat_clock = 0;
  a->raw_bpm = 0.0;
  a->raw_confidence = 0.0;
}

/* -- one published frame ----------------------------------------------------------- */

static void publish(analyser_t *a) {
  if (a->window_samples <= 0) return;

  double seconds = (double)a->window_samples / a->sample_rate;
  double level_db = to_db(a->window_square_sum / (double)a->window_samples);
  double bass_db = to_db(a->window_bass_square_sum / (double)a->window_samples);

  double level = normalise(&a->level_normaliser, level_db, seconds);
  double bass = normalise(&a->bass_normaliser, bass_db, seconds);
  /* Silence overall is silence in every band, whatever the filters still hold. */
  if (level_db < SILENCE_DB) bass = 0.0;
  double onset = level > 0.0 ? clamp01(a->window_onset) : 0.0;

  /* A tracker that stopped producing beats is not tracking any more. */
  if (a->last_beat_clock != 0 && (double)(a->clock - a->last_beat_clock) > BEAT_TIMEOUT_S * a->sample_rate) {
    forget_beats(a);
  }

  double stretched = (a->raw_confidence - CONFIDENCE_FLOOR) / (CONFIDENCE_FULL_SCALE - CONFIDENCE_FLOOR);
  double target = clamp01(stretched) * beat_regularity(a);
  a->confidence += (target - a->confidence) * CONFIDENCE_SMOOTHING;
  if (a->confidence < 0.001) a->confidence = 0.0;

  double bpm = 0.0;
  if (a->beat_interval_count + 1 >= BPM_MIN_BEATS && a->raw_bpm >= BPM_MIN && a->raw_bpm <= BPM_MAX) bpm = a->raw_bpm;

  char json[192];
  int length = snprintf(json, sizeof(json),
                        "{\"level\":%.3f,\"bass\":%.3f,\"onset\":%.3f,\"beat_id\":%lu,\"bpm\":%.1f,\"confidence\":%.3f}", level,
                        bass, onset, a->beat_id, bpm, clamp01(a->confidence));
  if (length > 0 && (size_t)length < sizeof(json)) send_frame(a, json, (size_t)length);

  a->window_square_sum = 0.0;
  a->window_bass_square_sum = 0.0;
  a->window_samples = 0;
  a->window_onset = 0.0;
  a->beat_pending = 0;
}

/* -- one hop of analysis ------------------------------------------------------------ */

static void analyse_hop(analyser_t *a) {
  double square_sum = 0.0;
  double bass_square_sum = 0.0;

  for (int i = 0; i < ANALYSIS_HOP_SIZE; i++) {
    double x = a->hop[i];
    square_sum += x * x;
    double low = biquad_run(&a->bass_lowpass, biquad_run(&a->bass_highpass, x));
    bass_square_sum += low * low;
  }
  biquad_flush(&a->bass_highpass);
  biquad_flush(&a->bass_lowpass);

  a->window_square_sum += square_sum;
  a->window_bass_square_sum += bass_square_sum;
  a->window_samples += ANALYSIS_HOP_SIZE;
  a->clock += ANALYSIS_HOP_SIZE;

  /* How far this hop's loudness stands above the recent average; the
   * largest recent jump is kept for a moment (see config.h). */
  double hop_db = to_db(square_sum / ANALYSIS_HOP_SIZE);
  if (hop_db < SILENCE_DB) hop_db = SILENCE_DB;
  double jump = hop_db - a->loudness_average_db;
  a->jump_db *= a->jump_hold;
  if (jump > a->jump_db) a->jump_db = jump;
  a->loudness_average_db += (hop_db - a->loudness_average_db) * a->loudness_average_rate;

#ifdef HAVE_AUBIO
  for (int i = 0; i < ANALYSIS_HOP_SIZE; i++) a->input->data[i] = a->hop[i];

  aubio_onset_do(a->onset, a->input, a->onset_output);
  if (a->onset_output->data[0] != 0.0f) {
    double strength = clamp01(a->jump_db / ONSET_FULL_SCALE_DB);
    if (strength < ONSET_MIN_STRENGTH) strength = ONSET_MIN_STRENGTH;
    if (strength > a->window_onset) a->window_onset = strength;
  }

  aubio_tempo_do(a->tempo, a->input, a->tempo_output);
  if (a->tempo_output->data[0] != 0.0f) {
    note_beat(a);
    double bpm = aubio_tempo_get_bpm(a->tempo);
    double confidence = aubio_tempo_get_confidence(a->tempo);
    a->raw_bpm = isfinite(bpm) ? bpm : 0.0;
    a->raw_confidence = isfinite(confidence) && confidence > 0.0 ? confidence : 0.0;
  }
#else
  /* No aubio: the jump in loudness is the attack. No beats, no tempo. */
  if (jump > FLUX_MIN_DB) {
    double strength = clamp01(jump / ONSET_FULL_SCALE_DB);
    if (strength > a->window_onset) a->window_onset = strength;
  }
#endif

  int due = a->clock >= a->next_publish;
  int early = a->beat_pending && (double)a->clock + a->publish_interval * EARLY_BEAT_FRACTION >= (double)a->next_publish;
  if (due || early) {
    publish(a);
    /* The publication grid does not move: an early frame takes the place of
     * the next one, so the rate never exceeds the limit. Fractions of a
     * sample are carried over so the average rate is exact. */
    a->publish_remainder += a->publish_interval;
    uint64_t step = (uint64_t)a->publish_remainder;
    a->publish_remainder -= (double)step;
    a->next_publish += step;
    if (a->next_publish <= a->clock) a->next_publish = a->clock + 1;
  }
}

static void feed(analyser_t *a, const uint8_t *bytes, size_t frames) {
  size_t sample_bytes = a->frame_bytes / (size_t)a->channels;
  float scale = 1.0f / (float)a->channels;

  for (size_t i = 0; i < frames; i++) {
    const uint8_t *frame = bytes + i * a->frame_bytes;
    float mono = 0.0f;
    for (int c = 0; c < a->channels; c++) mono += decode_sample(frame + (size_t)c * sample_bytes, a->format);
    a->hop[a->hop_fill++] = mono * scale;
    if (a->hop_fill == ANALYSIS_HOP_SIZE) {
      analyse_hop(a);
      a->hop_fill = 0;
    }
  }
}

/* -- setup ---------------------------------------------------------------------------- */

static int analyser_init(analyser_t *a, int publish_rate) {
  a->frame_bytes = format_bytes(a->format) * (size_t)a->channels;
  a->publish_interval = (double)a->sample_rate / publish_rate;
  a->next_publish = (uint64_t)a->publish_interval;
  if (a->next_publish == 0) a->next_publish = 1;

  biquad_highpass(&a->bass_highpass, a->sample_rate, BASS_LOW_HZ);
  biquad_lowpass(&a->bass_lowpass, a->sample_rate, BASS_HIGH_HZ);
  normaliser_init(&a->level_normaliser, LEVEL_REFERENCE_FLOOR_DB);
  normaliser_init(&a->bass_normaliser, BASS_REFERENCE_FLOOR_DB);

  double hop_ms = 1000.0 * ANALYSIS_HOP_SIZE / a->sample_rate;
  a->loudness_average_db = SILENCE_DB;
  a->loudness_average_rate = 1.0 - exp(-hop_ms / ONSET_AVERAGE_MS);
  a->jump_hold = exp(-hop_ms / ONSET_HOLD_MS);

#ifdef HAVE_AUBIO
  a->input = new_fvec(ANALYSIS_HOP_SIZE);
  a->onset_output = new_fvec(1);
  a->tempo_output = new_fvec(1);
  a->onset = new_aubio_onset(ONSET_METHOD, ANALYSIS_BUFFER_SIZE, ANALYSIS_HOP_SIZE, (uint_t)a->sample_rate);
  a->tempo = new_aubio_tempo(TEMPO_METHOD, ANALYSIS_BUFFER_SIZE, ANALYSIS_HOP_SIZE, (uint_t)a->sample_rate);
  if (!a->input || !a->onset_output || !a->tempo_output || !a->onset || !a->tempo) {
    say("the analysis library (aubio) could not be started for %d Hz", a->sample_rate);
    return -1;
  }
  aubio_onset_set_threshold(a->onset, (smpl_t)ONSET_THRESHOLD);
  aubio_onset_set_minioi_ms(a->onset, (smpl_t)ONSET_MIN_INTERVAL_MS);
  aubio_onset_set_silence(a->onset, (smpl_t)ONSET_SILENCE_DB);
  aubio_tempo_set_silence(a->tempo, (smpl_t)TEMPO_SILENCE_DB);
#endif

  return 0;
}

/* Reads standard input to its end and throws it away. Used whenever analysis
 * is impossible: the player must still be able to write. */
static int drain(void) {
  static uint8_t buffer[READ_BUFFER_BYTES];
  for (;;) {
    ssize_t n = read(STDIN_FILENO, buffer, sizeof(buffer));
    if (n == 0) return 0;
    if (n < 0 && errno != EINTR) return 0;
  }
}

static int run(analyser_t *a) {
  static uint8_t buffer[READ_BUFFER_BYTES];
  size_t held = 0;

  for (;;) {
    ssize_t n = read(STDIN_FILENO, buffer + held, sizeof(buffer) - held);
    if (n == 0) return 0;
    if (n < 0) {
      if (errno == EINTR) continue;
      return 0;
    }

    held += (size_t)n;
    size_t frames = held / a->frame_bytes;
    feed(a, buffer, frames);

    /* Keep the bytes of a frame that has not fully arrived yet. */
    size_t used = frames * a->frame_bytes;
    held -= used;
    if (held > 0) memmove(buffer, buffer + used, held);
  }
}

static void usage(FILE *out) {
  fprintf(out,
          "Usage: " PROGRAM " [options] < raw-pcm\n"
          "\n"
          "Reads raw interleaved PCM from standard input and sends loudness, bass,\n"
          "attack, beat and tempo measurements as JSON datagrams to a Unix socket.\n"
          "\n"
          "  --sample-rate HZ     sample rate of the input (default 44100)\n"
          "  --channels N         number of interleaved channels (default 2)\n"
          "  --format NAME        ALSA sample format: S16_LE, S24_LE, S24_3LE or S32_LE\n"
          "  --bits N             size of one sample in bits; used when --format is absent\n"
          "  --socket PATH        Unix datagram socket of the display\n"
          "                       (default " DEFAULT_SOCKET_PATH ")\n"
          "  --publish-rate N     frames sent per second, %d to %d (default %d)\n"
          "  --print              also print every frame on standard output; for testing\n"
          "                       by hand, never in the ALSA configuration\n"
          "  --version            print the version and the analysis features built in\n"
          "  --help               this text\n",
          MIN_PUBLISH_RATE, MAX_PUBLISH_RATE, DEFAULT_PUBLISH_RATE);
}

static int parse_int(const char *text, int *out) {
  char *end = NULL;
  errno = 0;
  long value = strtol(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value < -1000000 || value > 1000000) return -1;
  *out = (int)value;
  return 0;
}

int main(int argc, char **argv) {
  static analyser_t analyser;
  analyser_t *a = &analyser;

  int sample_rate = 44100;
  int channels = 2;
  int bits = 0;
  int publish_rate = DEFAULT_PUBLISH_RATE;
  const char *format_name = NULL;
  int usable = 1;

  a->socket_path = DEFAULT_SOCKET_PATH;

  /* A receiver that goes away must never kill us. */
  signal(SIGPIPE, SIG_IGN);

  for (int i = 1; i < argc; i++) {
    const char *option = argv[i];
    const char *value = i + 1 < argc ? argv[i + 1] : NULL;

    if (strcmp(option, "--help") == 0) {
      usage(stdout);
      return 0;
    } else if (strcmp(option, "--version") == 0) {
#ifdef HAVE_AUBIO
      puts(PROGRAM " 1.0 (level, bass, onset, beat and tempo; aubio)");
#else
      puts(PROGRAM " 1.0 (level and bass only; built without aubio)");
#endif
      return 0;
    } else if (strcmp(option, "--print") == 0) {
      a->print = 1;
    } else if (value == NULL) {
      /* Never a reason to stop: we may already be on the audio path. */
      say("option %s needs a value; ignored", option);
    } else if (strcmp(option, "--sample-rate") == 0) {
      if (parse_int(value, &sample_rate) < 0) sample_rate = -1;
      i++;
    } else if (strcmp(option, "--channels") == 0) {
      if (parse_int(value, &channels) < 0) channels = -1;
      i++;
    } else if (strcmp(option, "--bits") == 0) {
      if (parse_int(value, &bits) < 0) bits = -1;
      i++;
    } else if (strcmp(option, "--format") == 0) {
      format_name = value;
      i++;
    } else if (strcmp(option, "--socket") == 0) {
      a->socket_path = value;
      i++;
    } else if (strcmp(option, "--publish-rate") == 0) {
      if (parse_int(value, &publish_rate) < 0) publish_rate = DEFAULT_PUBLISH_RATE;
      i++;
    } else {
      say("unknown option %s; ignored", option);
    }
  }

  if (publish_rate < MIN_PUBLISH_RATE) publish_rate = MIN_PUBLISH_RATE;
  if (publish_rate > MAX_PUBLISH_RATE) publish_rate = MAX_PUBLISH_RATE;

  a->format = format_name ? format_from_name(format_name) : format_from_bits(bits ? bits : 16);
  a->sample_rate = sample_rate;
  a->channels = channels;

  /* Said once, then the input is drained for as long as it lasts. */
  if (a->format == FORMAT_UNKNOWN) {
    say("unsupported sample format %s (supported: S16_LE, S24_LE, S24_3LE, S32_LE); "
        "the audio is not analysed. Set output_format = \"S16\" in the alsa section of shairport-sync.conf",
        format_name ? format_name : "(from --bits)");
    usable = 0;
  } else if (channels < 1 || channels > MAX_CHANNELS) {
    say("unsupported channel count %d (supported: 1 to %d); the audio is not analysed", channels, MAX_CHANNELS);
    usable = 0;
  } else if (sample_rate < MIN_SAMPLE_RATE || sample_rate > MAX_SAMPLE_RATE) {
    say("unsupported sample rate %d Hz (supported: %d to %d); the audio is not analysed", sample_rate, MIN_SAMPLE_RATE,
        MAX_SAMPLE_RATE);
    usable = 0;
  }

  if (usable && analyser_init(a, publish_rate) < 0) usable = 0;
  if (!usable) return drain();

  open_socket(a);
  return run(a);
}
