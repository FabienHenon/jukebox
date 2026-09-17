// Smooth progress interpolation for the Now Playing screen.
//
// The server renders the authoritative anchor (position, duration, playing?)
// as data attributes whenever the playback state changes. Between updates the
// hook advances the bar locally at a low, fixed rate instead of asking the
// server for a render per frame. It stops while paused and while the tab is
// hidden. The children live inside a phx-update="ignore" wrapper so LiveView
// never overwrites what the hook draws.

const TICK_MS = 250

const formatTime = (ms) => {
  const total = Math.floor(Math.max(ms, 0) / 1000)
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = total % 60
  const pad = (n) => (n < 10 ? `0${n}` : `${n}`)
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(seconds)}` : `${minutes}:${pad(seconds)}`
}

const JukeboxProgress = {
  mounted() {
    this.fill = this.el.querySelector("[data-progress-fill]")
    this.elapsed = this.el.querySelector("[data-progress-elapsed]")
    this.total = this.el.querySelector("[data-progress-total]")
    this.onVisibility = () => (document.hidden ? this.stop() : this.start())
    document.addEventListener("visibilitychange", this.onVisibility)
    this.sync()
  },

  updated() {
    this.sync()
  },

  destroyed() {
    this.stop()
    document.removeEventListener("visibilitychange", this.onVisibility)
  },

  sync() {
    const data = this.el.dataset
    this.duration = Number(data.duration) || 0
    this.position = Number(data.position) || 0
    this.playing = data.playing === "true"
    this.anchor = performance.now()
    this.lastSecond = -1
    if (this.total && data.total) this.total.textContent = data.total
    this.render()
    this.playing ? this.start() : this.stop()
  },

  current() {
    const extra = this.playing ? performance.now() - this.anchor : 0
    return Math.min(this.duration, Math.max(0, this.position + extra))
  },

  render() {
    const position = this.current()
    const ratio = this.duration > 0 ? position / this.duration : 0
    if (this.fill) this.fill.style.transform = `scaleX(${ratio.toFixed(4)})`
    const second = Math.floor(position / 1000)
    if (second !== this.lastSecond && this.elapsed) {
      this.lastSecond = second
      this.elapsed.textContent = formatTime(position)
    }
  },

  start() {
    if (this.timer || !this.playing || document.hidden) return
    this.timer = setInterval(() => this.render(), TICK_MS)
  },

  stop() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  },
}

export default JukeboxProgress
