// State & Lua bridge for Turn-by-Turn Navigation & Multi-Design HUD (turnByTurn.lua).
import { ref } from "vue"
import { engineLua } from "./earthSettingsStore.js"

export const navState = ref(null)
export const navError = ref("")

let timer = null
let users = 0

export function applyNavState(st) {
  if (st === undefined) return
  navState.value = st || null
  if (st && st.error) navError.value = st.error
}

export function poll() {
  engineLua("beamngEarth_settings and beamngEarth_settings.uiNavState and beamngEarth_settings.uiNavState() or nil", st => {
    if (st) applyNavState(st)
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
  navError.value = ""
  engineLua(luaExpr, res => {
    if (!res || res.ok === false) {
      if (res && res.error) navError.value = res.error
    } else if (res.state) {
      applyNavState(res.state)
    } else {
      setTimeout(poll, 80)
    }
  })
}

export function setEnabled(flag) {
  runAction(`beamngEarth_settings and beamngEarth_settings.uiNavSetEnabled and beamngEarth_settings.uiNavSetEnabled(${flag ? "true" : "false"}) or nil`)
}

export function setDesign(design) {
  runAction(`beamngEarth_settings and beamngEarth_settings.uiNavSetDesign and beamngEarth_settings.uiNavSetDesign(${JSON.stringify(String(design || "gmaps_card"))}) or nil`)
}

export function cycleDesign() {
  runAction("beamngEarth_settings and beamngEarth_settings.uiNavCycleDesign and beamngEarth_settings.uiNavCycleDesign() or nil")
}

export function setChimeEnabled(flag) {
  runAction(`beamngEarth_settings and beamngEarth_settings.uiNavSetChime and beamngEarth_settings.uiNavSetChime(${flag ? "true" : "false"}) or nil`)
}

export function setUnits(units) {
  runAction(`beamngEarth_settings and beamngEarth_settings.uiNavSetUnits and beamngEarth_settings.uiNavSetUnits(${JSON.stringify(String(units || "metric"))}) or nil`)
}

export function setHideWorldMarkers(flag) {
  runAction(`beamngEarth_settings and beamngEarth_settings.uiNavSetHideWorldMarkers and beamngEarth_settings.uiNavSetHideWorldMarkers(${flag ? "true" : "false"}) or nil`)
}

export function setNorthUp(flag) {
  runAction(`beamngEarth_settings and beamngEarth_settings.uiNavSetNorthUp and beamngEarth_settings.uiNavSetNorthUp(${flag ? "true" : "false"}) or nil`)
}
