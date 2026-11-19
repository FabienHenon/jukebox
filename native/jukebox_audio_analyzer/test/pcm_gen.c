/*
 * pcm_gen: writes a synthetic test signal as raw PCM on standard output, so
 * the analyser can be tested without committing any audio file.
 *
 *   pcm_gen --signal music --seconds 30 --bpm 120 | jukebox_audio_analyzer --print
 *
 * Signals:
 *
 *   silence   digital silence
 *   sine      a steady 440 Hz tone
 *   music     a drum-machine pattern at --bpm: a kick on every beat, a hi-hat
 *             on the off-beats, a bass note and a quiet pad
 *   drift     noise and a wandering tone whose loudness swells slowly: sound
 *             with no beat at all
 *
 * Everything is computed from a fixed seed: the same options always produce
 * exactly the same bytes.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PI 3.14159265358979323846

static uint32_t seed = 0x1234ABCDu;

/* Uniform noise in -1..1 from a small linear congruential generator. */
static double noise(void) {
  seed = seed * 1664525u + 1013904223u;
  return (double)(int32_t)seed / 2147483648.0;
}

static void write_sample(double value, const char *format) {
  if (value > 1.0) value = 1.0;
  if (value < -1.0) value = -1.0;

  uint8_t bytes[4];
  size_t count;

  if (strcmp(format, "S16_LE") == 0) {
    int16_t v = (int16_t)lrint(value * 32767.0);
    bytes[0] = (uint8_t)(v & 0xFF);
    bytes[1] = (uint8_t)((v >> 8) & 0xFF);
    count = 2;
  } else if (strcmp(format, "S24_3LE") == 0 || strcmp(format, "S24_LE") == 0) {
    int32_t v = (int32_t)lrint(value * 8388607.0);
    bytes[0] = (uint8_t)(v & 0xFF);
    bytes[1] = (uint8_t)((v >> 8) & 0xFF);
    bytes[2] = (uint8_t)((v >> 16) & 0xFF);
    bytes[3] = 0;
    count = strcmp(format, "S24_LE") == 0 ? 4 : 3;
  } else {
    int32_t v = (int32_t)lrint(value * 2147483647.0);
    bytes[0] = (uint8_t)(v & 0xFF);
    bytes[1] = (uint8_t)((v >> 8) & 0xFF);
    bytes[2] = (uint8_t)((v >> 16) & 0xFF);
    bytes[3] = (uint8_t)((v >> 24) & 0xFF);
    count = 4;
  }
  fwrite(bytes, 1, count, stdout);
}

int main(int argc, char **argv) {
  const char *signal = "music";
  const char *format = "S16_LE";
  double seconds = 10.0;
  double bpm = 120.0;
  double amplitude = 0.5;
  int rate = 44100;
  int channels = 2;

  for (int i = 1; i + 1 < argc; i += 2) {
    const char *option = argv[i];
    const char *value = argv[i + 1];
    if (strcmp(option, "--signal") == 0) signal = value;
    else if (strcmp(option, "--format") == 0) format = value;
    else if (strcmp(option, "--seconds") == 0) seconds = atof(value);
    else if (strcmp(option, "--bpm") == 0) bpm = atof(value);
    else if (strcmp(option, "--amplitude") == 0) amplitude = atof(value);
    else if (strcmp(option, "--rate") == 0) rate = atoi(value);
    else if (strcmp(option, "--channels") == 0) channels = atoi(value);
    else {
      fprintf(stderr, "pcm_gen: unknown option %s\n", option);
      return 2;
    }
  }

  if (strcmp(format, "S16_LE") != 0 && strcmp(format, "S24_3LE") != 0 && strcmp(format, "S24_LE") != 0 &&
      strcmp(format, "S32_LE") != 0) {
    fprintf(stderr, "pcm_gen: unknown format %s\n", format);
    return 2;
  }

  long total = (long)(seconds * rate);
  double beat_samples = 60.0 / bpm * rate;
  double tone_phase = 0.0;

  for (long n = 0; n < total; n++) {
    double t = (double)n / rate;
    double value = 0.0;

    if (strcmp(signal, "sine") == 0) {
      value = sin(2.0 * PI * 440.0 * t);
    } else if (strcmp(signal, "music") == 0) {
      double position = (double)n / beat_samples;
      long beat = (long)position;
      double since_beat = (position - (double)beat) * beat_samples / rate;
      double since_half = since_beat - 30.0 / bpm;

      /* Kick: a low thump whose pitch drops, on every beat. */
      double kick = sin(2.0 * PI * (48.0 * since_beat + 40.0 * (1.0 - exp(-since_beat * 30.0)) / 30.0)) * exp(-since_beat * 9.0);
      /* Hi-hat: a short burst of noise on every off-beat. */
      double hat = since_half >= 0.0 ? noise() * exp(-since_half * 60.0) : 0.0;
      /* Bass note that changes every bar, and a quiet pad. */
      double note = 55.0 * (1.0 + 0.25 * (double)((beat / 4) % 3));
      double bass = sin(2.0 * PI * note * t) * 0.35 * (0.6 + 0.4 * exp(-since_beat * 3.0));
      double pad = (sin(2.0 * PI * 220.0 * t) + sin(2.0 * PI * 277.2 * t) + sin(2.0 * PI * 329.6 * t)) * 0.05;

      value = kick * 0.9 + hat * 0.25 + bass + pad;
    } else if (strcmp(signal, "drift") == 0) {
      double swell = 0.35 + 0.3 * sin(2.0 * PI * t / 7.3) + 0.2 * sin(2.0 * PI * t / 3.1 + 1.0);
      tone_phase += 2.0 * PI * (300.0 + 120.0 * sin(2.0 * PI * t / 5.7)) / rate;
      value = (noise() * 0.5 + sin(tone_phase) * 0.5) * swell;
    } else if (strcmp(signal, "silence") != 0) {
      fprintf(stderr, "pcm_gen: unknown signal %s\n", signal);
      return 2;
    }

    for (int c = 0; c < channels; c++) write_sample(value * amplitude, format);
  }

  return 0;
}
