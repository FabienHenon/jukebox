// Audio-reactive animation state, with no DOM, no timers and no clock of its
// own: the hook (hooks/jukebox_lights.js) feeds it frames and a timestamp and
// reads back the values to show. Keeping it pure is what makes it testable
// with plain `node --test` (see assets/test).
//
//   push(frame, now)   a frame arrived from the server; it is held in a small
//                      queue until `now + delayMs`, so the picture can be
//                      lined up with the sound leaving the speakers
//   tick(now)          applies the frames that are due, smooths every value
//                      towards its target and reports detected beats
//
// Values, all 0..1:
//
//   level, bass   follow the audio with a fast attack and a slower release
//   onset         jumps to the strength of an attack, then decays quickly
//   beat          one pulse per *trusted* detected beat, then decays
//   mix           how much the audio drives the picture: fades in when frames
//                 arrive and out when they stop, so nothing ever jumps
//
// Beats are trusted only while the analyser reports enough confidence and a
// tempo. Otherwise loudness, bass and attacks are still shown, and the hook
// keeps its fixed-tempo timer for the lights.

export const TUNING = {
  // No frame for this long: the audio is gone, fade everything out.
  staleMs: 500,
  // Frames waiting for their delay; at 20 frames per second and the longest
  // allowed delay (1 s) about twenty are queued, so this is never reached
  // unless the page stops ticking (hidden tab), and then the oldest go.
  maxQueue: 64,
  levelAttackMs: 55,
  levelReleaseMs: 280,
  bassAttackMs: 30,
  bassReleaseMs: 200,
  onsetDecayMs: 110,
  beatDecayMs: 150,
  mixInMs: 250,
  mixOutMs: 350,
  // Confidence has to stay low this long before the beat grid is given up,
  // so one doubtful frame does not hand the lights back to the fixed timer.
  trustHoldMs: 1500,
  // A trusted grid that produces no beat for this long is given up too.
  beatTimeoutMs: 2500,
  // Longest step a single tick may integrate (a tab coming back from hidden).
  maxStepMs: 250,
  // Below this a value is at rest.
  epsilon: 0.004,
}

const clamp01 = (value) => Math.min(1, Math.max(0, value))

const unit = (value) => (Number.isFinite(value) ? clamp01(value) : null)

// Moves `value` towards `target` with time constant `tau` (milliseconds).
const approach = (value, target, dt, tau) => value + (target - value) * (1 - Math.exp(-dt / tau))

const decay = (value, dt, tau) => value * Math.exp(-dt / tau)

export class AudioController {
  constructor({delayMs = 120, threshold = 0.45, tuning = {}} = {}) {
    this.tuning = {...TUNING, ...tuning}
    this.configure({delayMs, threshold})
    this.reset()
  }

  configure({delayMs, threshold}) {
    if (Number.isFinite(delayMs)) this.delayMs = Math.min(1000, Math.max(0, delayMs))
    if (Number.isFinite(threshold)) this.threshold = clamp01(threshold)
  }

  reset() {
    this.queue = []
    this.level = 0
    this.bass = 0
    this.onset = 0
    this.beat = 0
    this.mix = 0
    this.bpm = 0
    this.confidence = 0
    this.targetLevel = 0
    this.targetBass = 0
    this.lastPushAt = null
    this.lastTickAt = null
    this.lastBeatId = null
    this.detectedBeatAt = null
    this.confident = false
    this.lowSince = null
  }

  // Queues a frame received at `now`. Returns false for a frame that is not
  // usable (the server validates them too; this keeps NaN out of the CSS).
  push(frame, now) {
    const clean = this.sanitize(frame)
    if (!clean) return false
    this.lastPushAt = now
    this.queue.push({at: now + this.delayMs, frame: clean})
    if (this.queue.length > this.tuning.maxQueue) this.queue.shift()
    return true
  }

  // Stops following the audio at once (the style changed, the track ended):
  // what is queued is dropped and every value glides back to rest.
  silence() {
    this.queue = []
    this.lastPushAt = null
    this.forget()
  }

  // True while frames are arriving (or still waiting for their delay).
  live(now) {
    if (this.queue.length > 0) return true
    return this.lastPushAt !== null && now - this.lastPushAt <= this.tuning.staleMs
  }

  // True when the detected beats may drive the lights instead of the fixed
  // timer: confident, and a beat was actually detected recently.
  beatsTrusted(now) {
    return (
      this.confident &&
      this.detectedBeatAt !== null &&
      now - this.detectedBeatAt <= this.tuning.beatTimeoutMs &&
      this.live(now)
    )
  }

  // Nothing left to animate: the hook can stop its loop.
  get resting() {
    const {epsilon} = this.tuning
    return (
      this.queue.length === 0 &&
      this.lastPushAt === null &&
      this.level < epsilon &&
      this.bass < epsilon &&
      this.onset < epsilon &&
      this.beat < epsilon &&
      this.mix < epsilon
    )
  }

  // Advances to `now`. Returns the number of trusted beats that became due.
  tick(now) {
    const t = this.tuning
    const dt = this.lastTickAt === null ? 0 : Math.min(t.maxStepMs, Math.max(0, now - this.lastTickAt))
    this.lastTickAt = now

    // Impulses decay first, so one that lands on this tick shows in full.
    this.onset = decay(this.onset, dt, t.onsetDecayMs)
    this.beat = decay(this.beat, dt, t.beatDecayMs)

    let beats = 0
    while (this.queue.length > 0 && this.queue[0].at <= now) {
      beats += this.apply(this.queue.shift().frame, now)
    }

    const live = this.live(now)
    if (!live) {
      this.lastPushAt = null
      this.forget()
    }

    this.level = approach(
      this.level,
      this.targetLevel,
      dt,
      this.targetLevel > this.level ? t.levelAttackMs : t.levelReleaseMs,
    )
    this.bass = approach(
      this.bass,
      this.targetBass,
      dt,
      this.targetBass > this.bass ? t.bassAttackMs : t.bassReleaseMs,
    )
    this.mix = approach(this.mix, live ? 1 : 0, dt, live ? t.mixInMs : t.mixOutMs)

    if (!live) this.settle()
    return beats
  }

  // -- internals -------------------------------------------------------------

  apply(frame, now) {
    this.targetLevel = frame.level
    this.targetBass = frame.bass
    if (frame.onset > this.onset) this.onset = frame.onset
    this.confidence = frame.confidence

    if (frame.confidence >= this.threshold && frame.bpm > 0) {
      this.confident = true
      this.lowSince = null
      this.bpm = frame.bpm
    } else if (this.confident) {
      if (this.lowSince === null) this.lowSince = now
      if (now - this.lowSince >= this.tuning.trustHoldMs) {
        this.confident = false
        this.lowSince = null
        this.bpm = 0
      }
    }

    // A beat is a beat_id that went up. The first frame only sets the
    // baseline, and so does an id that went down (the analyser restarted).
    let beats = 0
    if (this.lastBeatId !== null && frame.beat_id > this.lastBeatId) {
      this.detectedBeatAt = now
      if (this.confident) {
        this.beat = 1
        beats = 1
      }
    }
    this.lastBeatId = frame.beat_id
    return beats
  }

  // Forgets what the analyser said; the shown values glide to rest by themselves.
  forget() {
    this.targetLevel = 0
    this.targetBass = 0
    this.lastBeatId = null
    this.detectedBeatAt = null
    this.confident = false
    this.lowSince = null
    this.bpm = 0
    this.confidence = 0
  }

  // An exponential never reaches zero: snap the tail so the loop can stop.
  settle() {
    const {epsilon} = this.tuning
    for (const key of ["level", "bass", "onset", "beat", "mix"]) {
      if (this[key] < epsilon) this[key] = 0
    }
  }

  sanitize(frame) {
    if (!frame || typeof frame !== "object") return null
    const level = unit(frame.level)
    const bass = unit(frame.bass)
    const onset = unit(frame.onset)
    const confidence = unit(frame.confidence)
    const beatId = frame.beat_id
    if (level === null || bass === null || onset === null || confidence === null) return null
    if (!Number.isInteger(beatId) || beatId < 0) return null
    const bpm = Number.isFinite(frame.bpm) && frame.bpm > 0 ? frame.bpm : 0
    return {level, bass, onset, confidence, beat_id: beatId, bpm}
  }
}

// A requestAnimationFrame loop that cannot be started twice. The callback
// runs once per requested frame and asks for the next one itself (with
// `ensure()`) for as long as there is something to animate, so an idle page
// has no loop at all. `request` and `cancel` are injected for the tests.
export class AnimationLoop {
  constructor(callback, {request, cancel}) {
    this.callback = callback
    this.request = request
    this.cancel = cancel
    this.handle = null
  }

  get running() {
    return this.handle !== null
  }

  ensure() {
    if (this.handle !== null) return
    this.handle = this.request((now) => {
      this.handle = null
      this.callback(now)
    })
  }

  stop() {
    if (this.handle === null) return
    this.cancel(this.handle)
    this.handle = null
  }
}
