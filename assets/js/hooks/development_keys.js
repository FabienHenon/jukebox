// Development-only keyboard shortcuts for the kiosk page.
//
// The hook is only attached when the server renders phx-hook="DevelopmentKeys"
// (config :jukebox, dev_keys: true, never in production). Keys are translated
// into the same semantic commands the physical buttons will send; the
// LiveView forwards them to Jukebox.Commands.
//
//   ←      previous_track      →      next_track
//   Space  toggle_playback     I      idle (end demo session)
//   C      connect (start demo session)

const KEYS = {
  ArrowLeft: "previous_track",
  ArrowRight: "next_track",
  " ": "toggle_playback",
  i: "idle",
  I: "idle",
  c: "connect",
  C: "connect",
}

const isTyping = (target) =>
  target &&
  (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable)

const DevelopmentKeys = {
  mounted() {
    this.onKey = (event) => {
      if (event.repeat || event.metaKey || event.ctrlKey || event.altKey) return
      if (isTyping(event.target)) return
      const command = KEYS[event.key]
      if (!command) return
      event.preventDefault()
      this.pushEvent("dev_command", {command})
    }
    window.addEventListener("keydown", this.onKey)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  },
}

export default DevelopmentKeys
