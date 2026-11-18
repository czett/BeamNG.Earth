// State & Lua bridge for Transport Modes (Taxi, Bus, Logistics).
// Used by EarthTransport.vue (both inside the Pause Menu's Transport tab and the 2D Map's Jobs drawer).
import { ref, computed } from "vue"
import { engineLua } from "./earthSettingsStore.js"

export const TRANSPORT_MODES = [
  { id: "taxi", label: "Taxi", desc: "Pick up a passenger nearby and drop them off at a real place in the chosen distance band." },
  { id: "bus", label: "Bus", desc: "Follow a real OSM bus line (or local transit corridor) stop by stop with kerbside dwell." },
  { id: "logistics", label: "Logistics", desc: "Deliver freight from a loading dock or depot across local retail stops or regional hubs." },
]

export const TRANSPORT_TIERS = {
  taxi: [
    { id: "neighborhood", label: "Neighborhood (1-3 km)" },
    { id: "city", label: "City (4-12 km)" },
    { id: "regional", label: "Regional (20-60 km)" },
  ],
  bus: [
    { id: "partial", label: "Partial Route (4-6 stops)" },
    { id: "full", label: "Full Line (complete OSM route=bus)" },
  ],
  logistics: [
    { id: "local", label: "Local Van (3 km, 3-4 stops)" },
    { id: "city", label: "City Delivery (10 km, 5-8 stops)" },
    { id: "regional", label: "Regional Haul (50 km, 2-3 stops)" },
    { id: "long", label: "Long Haul (100 km+)" },
  ],
}

export const selectedMode = ref("taxi")
export const selectedTiers = ref({ taxi: "neighborhood", bus: "partial", logistics: "local" })
export const transportState = ref(null)
export const busy = ref(false)
export const actionError = ref("")

let timer = null
let users = 0

export const currentTiers = computed(() => TRANSPORT_TIERS[selectedMode.value] || [])
export const selectedTier = computed(() => {
  const list = currentTiers.value
  const picked = selectedTiers.value[selectedMode.value]
  return list.some(t => t.id === picked) ? picked : (list[0] ? list[0].id : "")
})

export function setMode(mode) {
  if (TRANSPORT_TIERS[mode]) selectedMode.value = mode
}

export function setTier(tier) {
  selectedTiers.value = { ...selectedTiers.value, [selectedMode.value]: tier }
}

export function applyTransportState(st) {
  if (st === undefined) return
  transportState.value = st || null
  if (!st || !st.pending) busy.value = false
  if (st && st.error) actionError.value = ""
}

export function poll() {
  engineLua("beamngEarth_settings and beamngEarth_settings.uiTransportState and beamngEarth_settings.uiTransportState() or nil", st => {
    if (st) applyTransportState(st)
  })
}

export function start() {
  if (users++ === 0) {
    poll()
    timer = setInterval(poll, 700)
  }
}

export function stop() {
  if (--users <= 0) {
    users = 0
    if (timer) clearInterval(timer)
    timer = null
  }
}

export function startJob() {
  const mode = selectedMode.value
  const tier = selectedTier.value
  if (!mode || !tier) return
  actionError.value = ""
  busy.value = true
  engineLua(
    `beamngEarth_settings and beamngEarth_settings.uiTransportStart and beamngEarth_settings.uiTransportStart(${JSON.stringify(mode)}, ${JSON.stringify(tier)}) or nil`,
    res => {
      if (!res || res.ok === false) {
        busy.value = false
        actionError.value = (res && res.error) || "Could not start transport job"
      } else {
        setTimeout(poll, 120)
      }
    }
  )
}

export function skipStop() {
  actionError.value = ""
  engineLua("beamngEarth_settings and beamngEarth_settings.uiTransportSkip and beamngEarth_settings.uiTransportSkip() or nil", res => {
    if (res && res.ok === false) actionError.value = res.error || "Could not skip stop"
    setTimeout(poll, 100)
  })
}

export function cancelJob() {
  actionError.value = ""
  busy.value = false
  engineLua("beamngEarth_settings and beamngEarth_settings.uiTransportCancel and beamngEarth_settings.uiTransportCancel() or nil", () => {
    setTimeout(poll, 100)
  })
}

export function dismissSummary() {
  actionError.value = ""
  engineLua("beamngEarth_settings and beamngEarth_settings.uiTransportDismiss and beamngEarth_settings.uiTransportDismiss() or nil", () => {
    setTimeout(poll, 100)
  })
}

export function nextPassenger() {
  actionError.value = ""
  busy.value = true
  engineLua("beamngEarth_settings and beamngEarth_settings.uiTransportNextPassenger and beamngEarth_settings.uiTransportNextPassenger() or nil", res => {
    if (!res || res.ok === false) {
      busy.value = false
      actionError.value = (res && res.error) || "Could not start next passenger ride"
    } else {
      setTimeout(poll, 120)
    }
  })
}

export function modeLabel(m) {
  const f = TRANSPORT_MODES.find(x => x.id === m)
  return f ? f.label : String(m || "").toUpperCase()
}

export function stopTypeLabel(stopType) {
  return stopType === "loading_bay" ? "Loading Bay" : "Kerbside Stop"
}

export function stopKindLabel(kind) {
  const map = {
    pickup: "Pickup",
    dropoff: "Drop-off",
    bus_stop: "Bus Stop",
    loading: "Loading",
    delivery: "Delivery",
  }
  return map[kind] || String(kind || "Stop")
}

export function tierLabel(m, t) {
  const list = TRANSPORT_TIERS[m] || []
  const f = list.find(x => x.id === t)
  return f ? f.label : String(t || "")
}

export function formatDist(m, metric) {
  if (m == null || !Number.isFinite(Number(m))) return "-"
  const v = Number(m)
  if (metric) {
    return v < 1000 ? `${Math.round(v / 10) * 10} m` : `${(v / 1000).toFixed(v < 10000 ? 1 : 0)} km`
  }
  const mi = v / 1609.344
  return mi < 0.1 ? `${Math.round(v * 3.28084)} ft` : `${mi.toFixed(mi < 10 ? 1 : 0)} mi`
}

export function formatDur(s) {
  if (s == null || !Number.isFinite(Number(s))) return "-"
  const sec = Math.max(0, Math.round(Number(s)))
  const m = Math.floor(sec / 60)
  const r = sec % 60
  if (m >= 60) return `${Math.floor(m / 60)}h ${m % 60}m`
  return m > 0 ? `${m}m ${String(r).padStart(2, "0")}s` : `${r}s`
}

export function toArray(v) {
  if (Array.isArray(v)) return v
  if (v && typeof v === "object") return Object.keys(v).sort((a, b) => Number(a) - Number(b)).map(k => v[k])
  return []
}
