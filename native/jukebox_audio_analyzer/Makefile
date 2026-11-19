# jukebox_audio_analyzer: the native audio analyser of the jukebox display.
#
#   make            build build/jukebox_audio_analyzer (needs libaubio-dev)
#   make test       build and run the tests (no audio hardware needed)
#   make install    copy the analyser and the tap wrapper to $(PREFIX)/bin
#   make clean
#
#   make AUBIO=0    build without aubio: loudness, bass and a simple attack
#                   measure only; no beats, no tempo. For checking the audio
#                   tap on its own.
#
# On the Raspberry Pi see docs/audio-reactive-setup.md. Nothing built here
# belongs in git: build/ is ignored.

CC ?= cc
PREFIX ?= /opt/jukebox
BUILD ?= build
AUBIO ?= 1

# Ordinary optimisation, and every warning: this runs on the audio path.
CFLAGS ?= -O2
WARNINGS := -std=c99 -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wno-sign-conversion

# Raspberry Pi 2 (32-bit ARMv7, Cortex-A7): use its floating-point unit fully.
# Raspberry Pi OS otherwise builds for the first Pi. Override with ARCH_CFLAGS=
ifeq ($(shell uname -m),armv7l)
ARCH_CFLAGS ?= -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard
endif

ifeq ($(AUBIO),1)
AUBIO_CFLAGS ?= $(shell pkg-config --cflags aubio 2>/dev/null)
AUBIO_LIBS ?= $(shell pkg-config --libs aubio 2>/dev/null || echo -laubio)
CPPFLAGS += -DHAVE_AUBIO $(AUBIO_CFLAGS)
LDLIBS += $(AUBIO_LIBS)
endif
LDLIBS += -lm

ANALYZER := $(BUILD)/jukebox_audio_analyzer
TOOLS := $(BUILD)/pcm_gen $(BUILD)/dgram_dump

.PHONY: all test install clean

all: $(ANALYZER)

$(BUILD):
	mkdir -p $(BUILD)

$(ANALYZER): src/jukebox_audio_analyzer.c src/config.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(ARCH_CFLAGS) $(WARNINGS) -o $@ src/jukebox_audio_analyzer.c $(LDFLAGS) $(LDLIBS)

$(BUILD)/pcm_gen: test/pcm_gen.c | $(BUILD)
	$(CC) $(CFLAGS) -std=c99 -Wall -Wextra -o $@ $< -lm

$(BUILD)/dgram_dump: test/dgram_dump.c | $(BUILD)
	$(CC) $(CFLAGS) -std=c99 -Wall -Wextra -o $@ $<

test: $(ANALYZER) $(TOOLS)
	BUILD=$(BUILD) sh test/run.sh

install: $(ANALYZER)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(ANALYZER) $(DESTDIR)$(PREFIX)/bin/jukebox_audio_analyzer
	install -m 0755 jukebox_audio_tap $(DESTDIR)$(PREFIX)/bin/jukebox_audio_tap

clean:
	rm -rf $(BUILD)
