// Tests for the audio-reactive controller. No framework and no dependency:
//
//   node --test assets/test/        (or: mix test.js)
//
// The controller takes its time from the caller, so every test drives a
// made-up clock.

import assert from "node:assert/strict"
import {test} from "node:test"
import {AnimationLoop, AudioController, TUNING} from "../js/audio/controller.mjs"

const frame = (overrides = {}) => ({
  level: 0.5,
  bass: 0.5,
  onset: 0,
  beat_id: 1,
  bpm: 120,
  confidence: 0.9,
  ...overrides,
})

// Feeds one frame every 50 ms (20 frames per second) and ticks every 16 ms,
// from `from` to `to`. `make(n)` builds the nth frame. Returns the beats seen.
const run = (controller, from, to, make) => {
  let beats = 0
  let n = 0
  let nextFrame = from
  for (let now = from; now <= to; now += 16) {
    while (make && nextFrame <= now) {
      controller.push(make(n), nextFrame)
      n += 1
      nextFrame += 50
    }
    beats += controller.tick(now)
  }
  return beats
}

test("starts at rest", () => {
  const controller = new AudioController()
  assert.equal(controller.resting, true)
  assert.equal(controller.tick(0), 0)
  assert.equal(controller.level, 0)
  assert.equal(controller.mix, 0)
})

test("loudness rises quickly and falls slowly", () => {
  const controller = new AudioController({delayMs: 0})
  run(controller, 0, 60, () => frame({level: 1}))
  const afterAttack = controller.level
  assert.ok(afterAttack > 0.55, `attack too slow: ${afterAttack}`)

  run(controller, 76, 136, () => frame({level: 0}))
  const afterRelease = controller.level
  assert.ok(afterRelease > afterAttack * 0.6, `release too fast: ${afterRelease}`)
  assert.ok(afterRelease < afterAttack, "the level must come down")

  run(controller, 152, 1500, () => frame({level: 0}))
  assert.ok(controller.level < 0.02, `still up after a second: ${controller.level}`)
})

test("bass attacks faster than loudness and both stay within 0..1", () => {
  const controller = new AudioController({delayMs: 0})
  controller.push(frame({level: 1, bass: 1}), 0)
  controller.tick(0)
  controller.tick(32)
  assert.ok(controller.bass > controller.level)
  run(controller, 48, 2000, () => frame({level: 7, bass: -3, onset: 2}))
  for (const key of ["level", "bass", "onset", "beat", "mix"]) {
    assert.ok(controller[key] >= 0 && controller[key] <= 1, `${key} = ${controller[key]}`)
  }
  assert.ok(controller.level > 0.95)
  assert.ok(controller.bass < 0.01)
})

test("an attack jumps up at once and decays quickly", () => {
  const controller = new AudioController({delayMs: 0})
  controller.push(frame({onset: 0.8}), 0)
  controller.tick(0)
  assert.equal(controller.onset, 0.8)
  controller.push(frame({onset: 0}), 50)
  controller.tick(50)
  controller.tick(300)
  controller.tick(550)
  assert.ok(controller.onset < 0.02, `onset lingers: ${controller.onset}`)
})

test("a beat is a beat_id that went up, exactly once", () => {
  const controller = new AudioController({delayMs: 0})
  controller.push(frame({beat_id: 7}), 0)
  assert.equal(controller.tick(0), 0, "the first frame only sets the baseline")

  controller.push(frame({beat_id: 7}), 50)
  assert.equal(controller.tick(50), 0, "same id: no beat")

  controller.push(frame({beat_id: 8}), 100)
  assert.equal(controller.tick(100), 1)
  assert.equal(controller.beat, 1, "the pulse starts at full strength")

  controller.push(frame({beat_id: 8}), 150)
  assert.equal(controller.tick(150), 0, "a beat is a pulse, not a state")
  assert.ok(controller.beat < 1 && controller.beat > 0)

  controller.push(frame({beat_id: 11}), 200)
  assert.equal(controller.tick(200), 1, "skipped ids are one beat, not three")
})

test("a beat_id that goes down is a restarted analyser, not a beat", () => {
  const controller = new AudioController({delayMs: 0})
  controller.push(frame({beat_id: 40}), 0)
  controller.tick(0)
  controller.push(frame({beat_id: 1}), 50)
  assert.equal(controller.tick(50), 0)
  controller.push(frame({beat_id: 2}), 100)
  assert.equal(controller.tick(100), 1)
})

test("beats below the confidence threshold are shown as audio but not trusted", () => {
  const controller = new AudioController({delayMs: 0, threshold: 0.45})
  const beats = run(controller, 0, 3000, (n) =>
    frame({beat_id: Math.floor(n / 10), confidence: 0.2, level: 0.8}),
  )
  assert.equal(beats, 0)
  assert.equal(controller.beatsTrusted(3000), false)
  assert.equal(controller.beat, 0)
  assert.ok(controller.level > 0.7, "loudness is still followed")
  assert.equal(controller.bpm, 0)
})

test("a tempo is required to trust the beats", () => {
  const controller = new AudioController({delayMs: 0})
  const beats = run(controller, 0, 2000, (n) => frame({beat_id: Math.floor(n / 10), bpm: null}))
  assert.equal(beats, 0)
  assert.equal(controller.beatsTrusted(2000), false)
})

test("confident beats are trusted, and trust survives a short dip", () => {
  const controller = new AudioController({delayMs: 0, threshold: 0.45})
  const steady = (n) => frame({beat_id: Math.floor(n / 10), confidence: 0.8})
  const beats = run(controller, 0, 2000, steady)
  assert.equal(beats, 4)
  assert.equal(controller.beatsTrusted(2000), true)
  assert.equal(controller.bpm, 120)

  // Half a second of doubt: shorter than the hold, so the grid is kept.
  const dip = run(controller, 2016, 2500, (n) =>
    frame({beat_id: 4 + Math.floor(n / 10), confidence: 0.1}),
  )
  assert.equal(controller.beatsTrusted(2500), true)
  assert.equal(dip, 0)
})

test("lasting low confidence hands the beat back to the fixed timer", () => {
  const controller = new AudioController({delayMs: 0, threshold: 0.45})
  run(controller, 0, 2000, (n) => frame({beat_id: Math.floor(n / 10), confidence: 0.8}))
  assert.equal(controller.beatsTrusted(2000), true)

  const beats = run(controller, 2016, 2016 + TUNING.trustHoldMs + 600, (n) =>
    frame({beat_id: 4 + Math.floor(n / 10), confidence: 0.1}),
  )
  assert.equal(controller.beatsTrusted(2016 + TUNING.trustHoldMs + 600), false)
  // Beats that arrive during the hold are still honoured; none afterwards.
  assert.ok(beats <= 3, `beats after losing confidence: ${beats}`)
  assert.equal(controller.bpm, 0)
})

test("a trusted grid that stops producing beats is given up", () => {
  const controller = new AudioController({delayMs: 0})
  run(controller, 0, 1000, (n) => frame({beat_id: Math.floor(n / 10)}))
  assert.equal(controller.beatsTrusted(1000), true)
  // Frames keep coming, confident, but the beat counter no longer moves.
  run(controller, 1016, 1016 + TUNING.beatTimeoutMs + 600, () => frame({beat_id: 2}))
  assert.equal(controller.beatsTrusted(1016 + TUNING.beatTimeoutMs + 600), false)
})

test("without frames for half a second everything glides back to rest", () => {
  const controller = new AudioController({delayMs: 0})
  run(controller, 0, 1000, (n) => frame({level: 0.9, bass: 0.8, beat_id: Math.floor(n / 10)}))
  assert.ok(controller.mix > 0.9)
  assert.equal(controller.live(1000), true)

  // Still live just before the limit, and nothing has dropped yet.
  run(controller, 1016, 1400, null)
  assert.equal(controller.live(1400), true)
  assert.ok(controller.level > 0.8)

  run(controller, 1416, 1700, null)
  assert.equal(controller.live(1700), false)
  assert.equal(controller.beatsTrusted(1700), false)
  assert.ok(controller.level > 0.05, "the fall is smooth, not a cut")
  assert.equal(controller.resting, false)

  run(controller, 1716, 6000, null)
  assert.equal(controller.resting, true)
  for (const key of ["level", "bass", "onset", "beat", "mix"]) assert.equal(controller[key], 0)
})

test("frames after a gap fade back in without a beat", () => {
  const controller = new AudioController({delayMs: 0})
  run(controller, 0, 500, (n) => frame({beat_id: 10 + Math.floor(n / 10)}))
  run(controller, 516, 4000, null)
  assert.equal(controller.resting, true)

  controller.push(frame({beat_id: 99, level: 1}), 4016)
  assert.equal(controller.tick(4016), 0, "a new baseline, not a beat")
  assert.ok(controller.mix < 0.2, "the audio fades back in")
  run(controller, 4032, 5000, () => frame({beat_id: 99, level: 1}))
  assert.ok(controller.mix > 0.9)
})

test("frames are shown only after the visual delay, in order", () => {
  const controller = new AudioController({delayMs: 120})
  controller.push(frame({level: 1, beat_id: 1}), 0)
  controller.push(frame({level: 1, beat_id: 2}), 50)

  controller.tick(0)
  controller.tick(100)
  assert.equal(controller.level, 0, "nothing is shown before the delay")
  assert.equal(controller.queue.length, 2)

  assert.equal(controller.tick(125), 0)
  assert.ok(controller.level > 0, "the first frame is due")
  assert.equal(controller.queue.length, 1)

  assert.equal(controller.tick(175), 1, "the second frame brings its beat 120 ms late")
  assert.equal(controller.queue.length, 0)
})

test("the delay can be changed while running and is kept within bounds", () => {
  const controller = new AudioController({delayMs: 0})
  controller.configure({delayMs: 300})
  controller.push(frame({level: 1}), 0)
  controller.tick(200)
  assert.equal(controller.level, 0)
  controller.tick(300)
  assert.ok(controller.level > 0)

  controller.configure({delayMs: 99999, threshold: 7})
  assert.equal(controller.delayMs, 1000)
  assert.equal(controller.threshold, 1)
  controller.configure({delayMs: NaN, threshold: undefined})
  assert.equal(controller.delayMs, 1000)
})

test("the queue is bounded when nothing ticks", () => {
  const controller = new AudioController({delayMs: 120})
  for (let n = 0; n < 5000; n += 1) controller.push(frame({beat_id: n}), n * 50)
  assert.equal(controller.queue.length, TUNING.maxQueue)
  // Coming back: one tick drains the queue; the beats it held count once each.
  const beats = controller.tick(5000 * 50 + 200)
  assert.equal(controller.queue.length, 0)
  assert.ok(beats <= TUNING.maxQueue)
})

test("unusable frames are refused", () => {
  const controller = new AudioController()
  for (const bad of [
    null,
    "frame",
    {},
    frame({level: NaN}),
    frame({bass: Infinity}),
    frame({onset: "0.5"}),
    frame({confidence: undefined}),
    frame({beat_id: 1.5}),
    frame({beat_id: -1}),
  ]) {
    assert.equal(controller.push(bad, 0), false)
  }
  assert.equal(controller.queue.length, 0)
  assert.equal(controller.resting, true)
})

test("silence() stops following at once and lets the values glide out", () => {
  const controller = new AudioController({delayMs: 120})
  run(controller, 0, 1000, (n) => frame({level: 1, beat_id: Math.floor(n / 10)}))
  controller.silence()
  assert.equal(controller.queue.length, 0)
  assert.equal(controller.beatsTrusted(1000), false)
  assert.ok(controller.level > 0.5)
  run(controller, 1016, 5000, null)
  assert.equal(controller.resting, true)
})

test("the animation loop never runs twice", () => {
  const pending = new Map()
  let nextHandle = 1
  let cancelled = 0
  let calls = 0
  const loop = new AnimationLoop(() => (calls += 1), {
    request: (callback) => {
      pending.set(nextHandle, callback)
      return nextHandle++
    },
    cancel: (handle) => {
      cancelled += 1
      pending.delete(handle)
    },
  })
  const runFrame = () => {
    const callbacks = [...pending.values()]
    pending.clear()
    callbacks.forEach((callback) => callback(0))
  }

  // A burst of frames, a reconnect, a style change: all ask for the loop.
  loop.ensure()
  loop.ensure()
  loop.ensure()
  assert.equal(pending.size, 1)
  assert.equal(loop.running, true)

  runFrame()
  assert.equal(calls, 1)
  assert.equal(loop.running, false, "the loop does not continue by itself")
  assert.equal(pending.size, 0)

  loop.ensure()
  loop.stop()
  loop.stop()
  assert.equal(cancelled, 1)
  assert.equal(pending.size, 0)
  runFrame()
  assert.equal(calls, 1, "a stopped loop never calls back")
})

test("a callback that asks for the next frame gets exactly one", () => {
  const pending = []
  let calls = 0
  const loop = new AnimationLoop(
    () => {
      calls += 1
      loop.ensure()
      loop.ensure()
    },
    {request: (callback) => pending.push(callback), cancel: () => {}},
  )
  loop.ensure()
  for (let frame = 0; frame < 5; frame += 1) {
    const callbacks = pending.splice(0)
    assert.equal(callbacks.length, 1)
    callbacks[0](frame * 16)
  }
  assert.equal(calls, 5)
})
