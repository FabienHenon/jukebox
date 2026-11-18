// Beat-driven lights for the "chase" and "party" animation styles.
//
// The server renders what to do on the jukebox frame (.jb-body):
//
//   data-lights    off | chase | party
//   data-beating   "true" while music is playing
//   data-beat-ms   length of one beat (a fixed tempo: no audio is analysed)
//
// and the hook answers with one timer at the beat rate. On every beat it
// writes a new data-color on the pillar blocks and the marquee bulbs (their
// rows are phx-update="ignore", so LiveView leaves those colours alone) and
// updates three attributes on <html>, which sits outside the LiveView
// container and is therefore never patched:
//
//   data-lights="chase|party"   turns the light-show CSS on
//   data-lights-live            present while the beat runs (the grille wave
//                               pauses without it)
//   data-beat="0|1"             flips on every beat to replay the lamp flash
//
//   chase   colours travel: down the left pillar, up the right one and along
//           the bulbs, one position per beat
//   party   every block and bulb takes a random new colour on every beat, and
//           every few beats each grille wave may turn around
//
// The beat stops while paused, while the tab is hidden and for viewers who
// prefer reduced motion; leaving the style restores the original colours.

const PARTY_BLOCKS = ["lemon", "sky", "mint", "lilac"]
const PARTY_BULBS = ["lemon", "sky", "mint", "rose", "lilac"]
// Beats between two chances for a grille wave to change direction.
const PHRASE = 4
// A reversed endless animation ends when its clock runs back to zero; every
// reversal moves the clock this many loops ahead so it never gets there.
const HEADROOM_LOOPS = 100000

const wrap = (n, length) => ((n % length) + length) % length

const pickOther = (colors, current) => {
  const others = colors.filter((color) => color !== current)
  return others[Math.floor(Math.random() * others.length)]
}

// Reverses a running CSS animation where it stands, without a jump.
const reverse = (el) => {
  const animation = el.getAnimations ? el.getAnimations()[0] : null
  if (!animation || typeof animation.currentTime !== "number") return
  const {duration} = animation.effect.getComputedTiming()
  if (!(duration > 0)) return
  animation.currentTime = HEADROOM_LOOPS * duration + (animation.currentTime % duration)
  animation.updatePlaybackRate(-animation.playbackRate)
}

const isReversed = (el) => {
  const animation = el.getAnimations ? el.getAnimations()[0] : null
  return Boolean(animation) && animation.playbackRate < 0
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
    this.step = 0
    this.timer = null

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
    this.setMode("off")
    document.removeEventListener("visibilitychange", this.onChange)
    this.reducedMotion.removeEventListener("change", this.onChange)
  },

  sync() {
    const {lights, beating, beatMs} = this.el.dataset
    const show = lights === "chase" || lights === "party"
    this.setMode(show && !this.reducedMotion.matches ? lights : "off")

    const period = Math.min(2000, Math.max(200, Number(beatMs) || 500))
    if (this.mode === "off" || beating !== "true" || document.hidden) return this.stop()
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

  start() {
    document.documentElement.dataset.lightsLive = ""
    this.beat()
    this.timer = setInterval(() => this.beat(), this.period)
  },

  stop() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
    delete document.documentElement.dataset.lightsLive
  },

  beat() {
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
}

export default JukeboxLights
