// The jukebox's moving lights: the beat-driven "chase" and "party" styles and,
// when audio analysis is enabled, everything that follows the music.
//
// The server renders what to do on the jukebox frame (.jb-body):
//
//   data-lights            off | chase | party
//   data-beating           "true" while music is playing
//   data-beat-ms           length of one beat of the fixed tempo
//   data-audio             "true" when the display should follow the audio
//   data-audio-delay-ms    how long a frame is held before it is shown
//   data-audio-threshold   confidence needed to trust the detected beats
//
// and pushes one "audio-frame" event per analysed frame (at most 20 a second;
// never a DOM patch). The hook answers with attributes and custom properties
// on <html>, which sits outside the LiveView container and is therefore never
// patched:
//
//   data-lights="chase|party"   turns the light-show CSS on
//   data-lights-live            present while the beat runs (the grille wave
//                               pauses without it)
//   data-beat="0|1"             flips on every beat to replay the lamp flash
//   data-audio                  present while audio values are being shown
//   --audio-level, --audio-bass, --audio-onset, --audio-beat, --audio-mix
//                               0..1, smoothed here (see audio/controller.mjs)
//   --audio-bpm                 the detected tempo while it is trusted
//   --beat-live                 length of one detected beat while it is trusted
//
// Where the beat comes from:
//
//   detected   while the analyser is confident, every detected beat steps the
//              lights
//   fixed      otherwise (no analyser, no frames for half a second, low
//              confidence, a beat that stopped coming) the timer at the
//              configured tempo steps them, exactly as before audio analysis
//
// Both step the same counter, so the colours carry on from where they are
// when the source changes, and the timer skips a tick that would land right
// after a detected beat.
//
//   chase   colours travel: down the left pillar, up the right one and along
//           the bulbs, one position per beat
//   party   every block and bulb takes a random new colour on every beat, and
//           every few beats each grille wave may turn around
//
// Everything stops while the tab is hidden and for viewers who prefer reduced
// motion; leaving a style restores the original colours.

import {AnimationLoop, AudioController} from "../audio/controller.mjs"

const PARTY_BLOCKS = ["lemon", "sky", "mint", "lilac"]
const PARTY_BULBS = ["lemon", "sky", "mint", "rose", "lilac"]
// Beats between two chances for a grille wave to change direction.
const PHRASE = 4
// A reversed endless animation ends when its clock runs back to zero; every
// reversal moves the clock this many loops ahead so it never gets there.
const HEADROOM_LOOPS = 100000
// Audio values are written at most this often (about 30 times a second): each
// write restyles the page (about a hundred elements), and the Pi has better
// things to do at 60.
const RENDER_MS = 32
// Detected tempos outside this range do not retime the animations.
const MIN_BEAT_MS = 250
const MAX_BEAT_MS = 1500
// A tempo has to move this much before the animations are retimed.
const TEMPO_STEP = 0.03

const AUDIO_PROPERTIES = [
  ["--audio-level", "level"],
  ["--audio-bass", "bass"],
  ["--audio-onset", "onset"],
  ["--audio-beat", "beat"],
  ["--audio-mix", "mix"],
]

const wrap = (n, length) => ((n % length) + length) % length

const pickOther = (colors, current) => {
  const others = colors.filter((color) => color !== current)
  return others[Math.floor(Math.random() * others.length)]
}

const runningAnimation = (el) => (el.getAnimations ? el.getAnimations()[0] : null)

// Reverses a running CSS animation where it stands, without a jump.
const reverse = (el) => {
  const animation = runningAnimation(el)
  if (!animation || typeof animation.currentTime !== "number") return
  const {duration} = animation.effect.getComputedTiming()
  if (!(duration > 0)) return
  animation.currentTime = HEADROOM_LOOPS * duration + (animation.currentTime % duration)
  animation.updatePlaybackRate(-animation.playbackRate)
}

const isReversed = (el) => {
  const animation = runningAnimation(el)
  return Boolean(animation) && animation.playbackRate < 0
}

// Changes the speed of a running CSS animation, keeping its direction.
const setSpeed = (el, speed) => {
  const animation = runningAnimation(el)
  if (!animation) return
  animation.updatePlaybackRate(animation.playbackRate < 0 ? -speed : speed)
}

const JukeboxLights = {
  mounted() {
    this.pillars = ["left", "right"].map((side) =>
      Array.from(this.el.querySelectorAll(`.jb-pillar--${side} .jb-seg`)),
    )
    this.bulbs = Array.from(this.el.querySelectorAll(".jb-marquee .bulb"))
    this.waves = Array.from(this.el.querySelectorAll(".jb-grille__wave"))
    this.base = new Map(
      [...this.pillars.flat(), ...this.bulbs].map((el) => [el, el.dataset.color]),
    )
    this.mode = "off"
    this.beating = false
    this.step = 0
    this.timer = null
    this.lastBeatAt = -Infinity

    this.audio = new AudioController()
    this.audioOn = false
    this.loop = new AnimationLoop((now) => this.animate(now), {
      request: (callback) => requestAnimationFrame(callback),
      cancel: (handle) => cancelAnimationFrame(handle),
    })
    this.renderedAt = -Infinity
    this.written = {}
    this.audioShown = false
    this.liveBeatMs = null
    this.handleEvent("audio-frame", (frame) => this.onAudioFrame(frame))

    this.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.onChange = () => this.sync()
    document.addEventListener("visibilitychange", this.onChange)
    this.reducedMotion.addEventListener("change", this.onChange)
    this.sync()
  },

  updated() {
    this.sync()
  },

  destroyed() {
    this.stop()
    this.loop.stop()
    this.clearAudio()
    this.setMode("off")
    document.removeEventListener("visibilitychange", this.onChange)
    this.reducedMotion.removeEventListener("change", this.onChange)
  },

  sync() {
    const {lights, beating, beatMs, audio, audioDelayMs, audioThreshold} = this.el.dataset
    const still = this.reducedMotion.matches
    const show = lights === "chase" || lights === "party"
    this.setMode(show && !still ? lights : "off")

    this.audio.configure({delayMs: Number(audioDelayMs), threshold: Number(audioThreshold)})
    const audioOn = audio === "true" && !still
    if (this.audioOn && !audioOn) {
      // Stop following at once; the loop lets the values glide back to rest.
      this.audio.silence()
      this.loop.ensure()
    }
    this.audioOn = audioOn

    const period = Math.min(2000, Math.max(200, Number(beatMs) || 500))
    this.beating = this.mode !== "off" && beating === "true" && !document.hidden
    if (!this.beating) return this.stop()
    if (this.timer && period === this.period) return
    this.stop()
    this.period = period
    this.start()
  },

  // Every show starts from the colours the server rendered.
  setMode(mode) {
    if (mode === this.mode) return
    this.mode = mode
    this.step = 0
    this.base.forEach((color, el) => (el.dataset.color = color))
    this.waves.filter(isReversed).forEach(reverse)

    const root = document.documentElement
    if (mode === "off") {
      delete root.dataset.lights
      delete root.dataset.beat
    } else {
      root.dataset.lights = mode
    }
  },

  // -- the fixed-tempo timer ---------------------------------------------------

  start() {
    document.documentElement.dataset.lightsLive = ""
    this.fixedBeat()
    this.timer = setInterval(() => this.fixedBeat(), this.period)
  },

  stop() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
    this.setTempo(null)
    delete document.documentElement.dataset.lightsLive
  },

  // The fallback: steps the lights unless the detected beats are doing it, or
  // one of them just did.
  fixedBeat() {
    const now = performance.now()
    if (this.audio.beatsTrusted(now)) return
    if (now - this.lastBeatAt < this.period / 2) return
    this.beat(now)
  },

  // -- beats -------------------------------------------------------------------

  beat(now) {
    this.lastBeatAt = now
    this.step += 1
    if (this.mode === "party") this.party()
    else this.chase()
    document.documentElement.dataset.beat = String(this.step % 2)
  },

  chase() {
    const [left, right] = this.pillars
    this.shift(left, -this.step)
    this.shift(right, this.step)
    this.shift(this.bulbs, -this.step)
  },

  // Element i shows the original colour of the element `offset` places away.
  shift(elements, offset) {
    elements.forEach((el, i) => {
      el.dataset.color = this.base.get(elements[wrap(i + offset, elements.length)])
    })
  },

  party() {
    this.pillars.flat().forEach((el) => {
      el.dataset.color = pickOther(PARTY_BLOCKS, el.dataset.color)
    })
    this.bulbs.forEach((el) => {
      el.dataset.color = pickOther(PARTY_BULBS, el.dataset.color)
    })
    if (this.step % PHRASE === 0) {
      this.waves.forEach((wave) => {
        if (Math.random() < 0.5) reverse(wave)
      })
    }
  },

  // -- audio -------------------------------------------------------------------

  onAudioFrame(frame) {
    if (!this.audioOn) return
    if (this.audio.push(frame, performance.now())) this.loop.ensure()
  },

  // One frame of the loop (there is one loop at most, see AnimationLoop). It
  // asks for the next frame only while there is something left to show.
  // The arithmetic runs on every frame, so a beat is never late by more than
  // one; the page is only restyled every other frame.
  animate(now) {
    const beats = this.audio.tick(now)
    if (beats > 0 && this.beating) this.beat(now)
    if (now - this.renderedAt >= RENDER_MS - 1) {
      this.renderedAt = now
      this.setTempo(this.beating && this.audio.beatsTrusted(now) ? 60000 / this.audio.bpm : null)
      this.writeAudio()
    }
    if (this.audio.resting) this.clearAudio()
    else this.loop.ensure()
  },

  // Values are rounded to a hundredth and written only when they changed.
  writeAudio() {
    const root = document.documentElement
    if (!this.audioShown) {
      this.audioShown = true
      root.dataset.audio = ""
    }
    for (const [property, key] of AUDIO_PROPERTIES) {
      const value = Math.round(this.audio[key] * 100) / 100
      if (value !== this.written[key]) {
        this.written[key] = value
        root.style.setProperty(property, String(value))
      }
    }
  },

  clearAudio() {
    const root = document.documentElement
    delete root.dataset.audio
    for (const [property] of AUDIO_PROPERTIES) root.style.removeProperty(property)
    this.audioShown = false
    this.written = {}
    this.setTempo(null)
  },

  // Retimes the beat-length animations to the detected tempo (or back to the
  // fixed one with null): the lamp flash through --beat-live, picked up at
  // its next replay, and the grille wave through its playback rate, which
  // changes speed without a jump.
  setTempo(beatMs) {
    const root = document.documentElement
    const usable = beatMs !== null && beatMs >= MIN_BEAT_MS && beatMs <= MAX_BEAT_MS
    if (!usable) {
      if (this.liveBeatMs === null) return
      this.liveBeatMs = null
      root.style.removeProperty("--beat-live")
      root.style.removeProperty("--audio-bpm")
      this.waves.forEach((wave) => setSpeed(wave, 1))
      return
    }
    const previous = this.liveBeatMs
    if (previous !== null && Math.abs(beatMs - previous) / previous < TEMPO_STEP) return
    this.liveBeatMs = beatMs
    root.style.setProperty("--beat-live", `${Math.round(beatMs)}ms`)
    root.style.setProperty("--audio-bpm", String(Math.round(60000 / beatMs)))
    this.waves.forEach((wave) => setSpeed(wave, this.period / beatMs))
  },
}

export default JukeboxLights
