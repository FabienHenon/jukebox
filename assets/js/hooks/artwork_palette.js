// Artwork palette extraction.
//
// Runs once per artwork (cached by artwork id), on the client, with a 24x24
// offscreen sample of the image: cheap enough for a Raspberry Pi 3 and it
// needs no native image library on the server. Two accent hues are picked
// (dominant saturated colour and the most distinct second hue), pushed toward
// the pastel range, and exposed as CSS custom properties on the <html> element:
//
//   --plate-a / --plate-b   the two plates behind the artwork
//   --accent / --accent-soft the progress fill and waves
//   --glow-h / --glow-s / --glow-a  hue and saturation of the soft glow on the
//                            screen window (lightness is bounded in CSS)
//
// The base palette (pink shell, cream screen, text colours) never changes.
// Fallback artwork clears the properties so the defaults apply again.

const SAMPLE = 24
const CACHE_LIMIT = 12
const cache = new Map()

const rgbToHsl = (r, g, b) => {
  r /= 255
  g /= 255
  b /= 255
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const l = (max + min) / 2
  if (max === min) return [0, 0, l]
  const d = max - min
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
  let h
  if (max === r) h = (g - b) / d + (g < b ? 6 : 0)
  else if (max === g) h = (b - r) / d + 2
  else h = (r - g) / d + 4
  return [h * 60, s, l]
}

const hsl = (h, s, l) => `hsl(${Math.round(h)} ${Math.round(s * 100)}% ${Math.round(l * 100)}%)`

const hueDistance = (a, b) => {
  const d = Math.abs(a - b) % 360
  return d > 180 ? 360 - d : d
}

// Returns [{h, s, weight}] buckets sorted by weight, or [] when the image
// has no usable saturated colour (mostly grey, white or black).
const extract = (img) => {
  const canvas = document.createElement("canvas")
  canvas.width = SAMPLE
  canvas.height = SAMPLE
  const ctx = canvas.getContext("2d", {willReadFrequently: true})
  ctx.drawImage(img, 0, 0, SAMPLE, SAMPLE)
  const {data} = ctx.getImageData(0, 0, SAMPLE, SAMPLE)

  const buckets = new Map()
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] < 128) continue
    const [h, s, l] = rgbToHsl(data[i], data[i + 1], data[i + 2])
    if (s < 0.18 || l < 0.12 || l > 0.94) continue
    const key = Math.round(h / 20) * 20
    const bucket = buckets.get(key) || {h: 0, s: 0, n: 0, weight: 0}
    bucket.h += h
    bucket.s += s
    bucket.n += 1
    bucket.weight += 0.4 + s
    buckets.set(key, bucket)
  }

  return [...buckets.values()]
    .map((b) => ({h: b.h / b.n, s: b.s / b.n, weight: b.weight}))
    .sort((a, b) => b.weight - a.weight)
}

const paletteFor = (img) => {
  const colours = extract(img)
  if (colours.length === 0 || colours[0].weight < 6) return null

  const primary = colours[0]
  const secondary =
    colours.find((c) => hueDistance(c.h, primary.h) >= 45 && c.weight >= 3) || {
      h: (primary.h + 150) % 360,
      s: primary.s,
    }

  // Pastel treatment: moderate saturation, high lightness for the plates;
  // a deeper tone of the primary hue for the progress fill.
  const plate = (c) => hsl(c.h, Math.min(Math.max(c.s, 0.45), 0.7), 0.78)
  return {
    plateA: plate(primary),
    plateB: plate(secondary),
    accent: hsl(primary.h, Math.min(Math.max(primary.s, 0.5), 0.75), 0.56),
    accentSoft: hsl(primary.h, Math.min(Math.max(primary.s, 0.45), 0.7), 0.7),
    glowHue: Math.round(primary.h),
    glowSaturation: `${Math.round(primary.s * 100)}%`,
  }
}

const PROPS = ["--plate-a", "--plate-b", "--accent", "--accent-soft", "--glow-h", "--glow-s", "--glow-a"]

// Properties go on <html>: it sits outside the LiveView container, so a
// LiveView patch never strips the inline style, and the values still cascade
// down to the artwork plates and the progress fill.
const apply = (palette) => {
  const root = document.documentElement
  if (!palette) {
    PROPS.forEach((p) => root.style.removeProperty(p))
    return
  }
  root.style.setProperty("--plate-a", palette.plateA)
  root.style.setProperty("--plate-b", palette.plateB)
  root.style.setProperty("--accent", palette.accent)
  root.style.setProperty("--accent-soft", palette.accentSoft)
  root.style.setProperty("--glow-h", palette.glowHue)
  root.style.setProperty("--glow-s", palette.glowSaturation)
  root.style.setProperty("--glow-a", "1")
}

const remember = (key, palette) => {
  if (cache.size >= CACHE_LIMIT) cache.delete(cache.keys().next().value)
  cache.set(key, palette)
}

const ArtworkPalette = {
  mounted() {
    const key = this.el.dataset.paletteKey
    const img = this.el.querySelector("img")
    if (this.el.dataset.fallback === "true" || !img) {
      apply(null)
      return
    }
    if (cache.has(key)) {
      apply(cache.get(key))
      return
    }

    const run = () => {
      if (this.el.dataset.paletteKey !== key) return
      let palette = null
      try {
        palette = paletteFor(img)
      } catch (_error) {
        palette = null
      }
      remember(key, palette)
      apply(palette)
    }

    if (img.complete && img.naturalWidth > 0) run()
    else img.addEventListener("load", run, {once: true})
  },
}

export default ArtworkPalette
