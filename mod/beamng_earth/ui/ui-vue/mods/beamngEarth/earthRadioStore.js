// State & Lua bridge for Location-Aware Live & Local Radio.
// Used by EarthRadio.vue (both inside the Pause Menu's Radio tab and the 2D Map's Radio drawer).
import { ref } from "vue"
import { engineLua } from "./earthSettingsStore.js"

export const radioState = ref(null)
export const radioError = ref("")

let timer = null
let users = 0

export function toArray(v) {
  if (Array.isArray(v)) return v
  if (v && typeof v === "object") return Object.keys(v).sort((a, b) => Number(a) - Number(b)).map(k => v[k])
  return []
}

export function applyRadioState(st) {
  if (st === undefined) return
  radioState.value = st || null
  if (st && st.error) radioError.value = st.error
}

export function poll() {
  engineLua("beamngEarth_settings and beamngEarth_settings.uiRadioState and beamngEarth_settings.uiRadioState() or nil", st => {
    if (st) applyRadioState(st)
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

function runAction(luaExpr) {
  radioError.value = ""
  engineLua(luaExpr, res => {
    if (!res || res.ok === false) {
      if (res && res.error) radioError.value = res.error
    } else if (res.state) {
      applyRadioState(res.state)
    } else {
      setTimeout(poll, 80)
    }
  })
}

export function togglePlay() {
  runAction("beamngEarth_settings and beamngEarth_settings.uiRadioTogglePlay and beamngEarth_settings.uiRadioTogglePlay() or nil")
}

export function nextStation() {
  runAction("beamngEarth_settings and beamngEarth_settings.uiRadioNext and beamngEarth_settings.uiRadioNext() or nil")
}

export function prevStation() {
  runAction("beamngEarth_settings and beamngEarth_settings.uiRadioPrev and beamngEarth_settings.uiRadioPrev() or nil")
}

export function selectStation(id) {
  runAction(`beamngEarth_settings and beamngEarth_settings.uiRadioSelect and beamngEarth_settings.uiRadioSelect(${JSON.stringify(String(id || ""))}) or nil`)
}

export function setVolume(v) {
  const n = Math.max(0, Math.min(1, Number(v) || 0))
  runAction(`beamngEarth_settings and beamngEarth_settings.uiRadioSetVolume and beamngEarth_settings.uiRadioSetVolume(${n}) or nil`)
}

export function setAutoRoam(flag) {
  runAction(`beamngEarth_settings and beamngEarth_settings.uiRadioSetAutoRoam and beamngEarth_settings.uiRadioSetAutoRoam(${flag ? "true" : "false"}) or nil`)
}

export function setEnabled(flag) {
  runAction(`beamngEarth_settings and beamngEarth_settings.uiRadioSetEnabled and beamngEarth_settings.uiRadioSetEnabled(${flag ? "true" : "false"}) or nil`)
}

export function refreshStations() {
  runAction("beamngEarth_settings and beamngEarth_settings.uiRadioRefresh and beamngEarth_settings.uiRadioRefresh() or nil")
}
