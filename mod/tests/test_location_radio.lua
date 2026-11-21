-- luajit mod/tests/test_location_radio.lua  (Location-aware radio: switching, auto-roam handoff, persistence, hudapps)
local T = dofile((arg[0]:match('^(.*)[/\\]') or '.') .. '/testlib.lua')
local LR = require('beamngEarth/locationRadio')
local H = require('beamngEarth/hudapps')

local savedFiles = {}
jsonWriteFile = function(path, data)
  savedFiles[path] = data
  return true
end
jsonReadFile = function(path)
  return savedFiles[path]
end
FS = {
  fileExists = function(_, path) return savedFiles[path] ~= nil end
}

local sentReqs = {}
beamngEarth_core = {
  requestRadioStations = function(id, lat, lon, place, region, country, online)
    sentReqs[#sentReqs + 1] = { id = id, lat = lat, lon = lon, place = place, region = region, country = country, online = online }
    return true
  end,
  _state = function()
    return { player = { lat = 51.5136, lon = 7.4653 } }
  end,
}

LR._resetForTest()

-- 0. Opt-in only: defaults to hidden (visible == false / enabled == false) and does not poll or render
do
  local st0 = LR.uiState()
  T.check(st0.enabled == false and st0.visible == false, 'radio defaults to hidden / opt-in (enabled == false, visible == false)')
  T.check(LR.hudPayload() == nil, 'hudPayload returns nil while radio is hidden/disabled')
  T.check(not LR.update(0.1, { lat = 51.5136, lon = 7.4653 }, 5.0) and #sentReqs == 0, 'does not poll while hidden/disabled')
  T.check(not LR.refresh() and #sentReqs == 0, 'refresh does not poll while hidden/disabled')
  T.check(LR.togglePlay() == false and LR.uiState().playing == false, 'togglePlay does not start playback while hidden/disabled')

  local sentHiddenHud = {}
  guihooks = { trigger = function(name, p) sentHiddenHud[#sentHiddenHud + 1] = { name = name, p = p } end }
  H._reset()
  H.setMounted('radio', true)
  local hiddenGet = function()
    return { status = '', credits = '', banner = { text = '', level = 'info', visible = false }, radio = LR.hudPayload() }
  end
  T.check(H.update(0.5, hiddenGet) and #sentHiddenHud == 1 and sentHiddenHud[1].p.radio == nil, 'hudapps omits radio payload while disabled')
  H._reset()
  guihooks = nil
end

-- Explicitly enable radio before testing polling, switching, and HUD forwarding
T.check(LR.setEnabled(true) == true, 'setEnabled(true) opts in')
T.check(LR.uiState().enabled == true and LR.uiState().visible == true, 'enabled and visible after opt-in')
T.check(LR.hudPayload() ~= nil and LR.hudPayload().visible == true, 'hudPayload populated with visible=true once enabled')

-- 1. Polling cadence: initial fix triggers request, within 4 s throttled, < 2.5 km skipped, > 2.5 km triggers
T.check(LR.update(0.1, { lat = 51.5136, lon = 7.4653 }, 10.0) and #sentReqs == 1, 'initial position sends radio_stations_request')
T.check(not LR.update(0.1, { lat = 51.6000, lon = 7.6000 }, 11.0) and #sentReqs == 1, 'throttled within POLL_S (4 s)')
T.check(not LR.update(0.1, { lat = 51.5150, lon = 7.4660 }, 15.0) and #sentReqs == 1, 'small move < 2.5 km does not re-request')
T.check(LR.update(0.1, { lat = 51.5500, lon = 7.4653 }, 20.0) and #sentReqs == 2, 'move > 2.5 km triggers new request')

-- 2. Station lineup, switching, wrap-around, volume clamping
local dortmundMsg = {
  id = 1,
  ok = true,
  regionCode = 'DE-NW-DO',
  regionLabel = 'Dortmund · NRW',
  country = 'DE',
  place = 'Dortmund',
  source = 'preset',
  stations = {
    { id = 'do-r912', name = 'Radio 91.2', frequency = '91.2 MHz', genre = 'Pop / Local', scope = 'local', streamUrl = 'https://stream.lokalradio.nrw/444z27c' },
    { id = 'do-1live', name = '1LIVE', frequency = '106.7 MHz', genre = 'Pop / Charts', scope = 'regional', streamUrl = 'https://wdr-1live-live.icecastssl.wdr.de/wdr/1live/live/mp3/128/stream.mp3' },
    { id = 'do-wdr4', name = 'WDR 4', frequency = '101.3 MHz', genre = 'Oldies / Classic Hits', scope = 'regional', streamUrl = 'https://wdr-wdr4-live.icecastssl.wdr.de/wdr/wdr4/live/mp3/128/stream.mp3' },
  },
}
T.check(LR.onStationsResult(dortmundMsg), 'Dortmund lineup accepted')
local st = LR.uiState()
T.check(st.currentStationId == 'do-r912' and st.currentIndex == 1, 'defaults to first station')
T.check(LR.togglePlay() == true and LR.uiState().playing == true, 'togglePlay starts playback')
T.check(LR.nextStation() and LR.uiState().currentStationId == 'do-1live', 'nextStation advances')
T.check(LR.nextStation() and LR.uiState().currentStationId == 'do-wdr4', 'nextStation advances to 3rd')
T.check(LR.nextStation() and LR.uiState().currentStationId == 'do-r912', 'nextStation wraps around')
T.check(LR.prevStation() and LR.uiState().currentStationId == 'do-wdr4', 'prevStation wraps backward')
T.check(LR.selectStation('do-r912') and LR.uiState().currentStationId == 'do-r912', 'selectStation picks local station')
T.check(LR.setVolume(1.5) == 1.0 and LR.setVolume(-0.2) == 0.0 and LR.setVolume(0.72) == 0.72, 'volume clamped 0..1')

-- 3. Auto-roam local drop-out handoff to matching-genre station in Munich
local munichMsg = {
  id = 2,
  ok = true,
  regionCode = 'DE-BY-M',
  regionLabel = 'Munich · Bavaria',
  country = 'DE',
  place = 'Munich',
  source = 'preset',
  stations = {
    { id = 'muc-br24', name = 'BR24', frequency = '90.0 MHz', genre = 'News / Talk', scope = 'regional', streamUrl = 'https://dispatcher.rndfnk.com/br/br24/live/mp3/mid' },
    { id = 'muc-gong', name = 'Radio Gong 96.3', frequency = '96.3 MHz', genre = 'Pop / Local', scope = 'local', streamUrl = 'https://radiogong-live.cast.addradio.de/radiogong/live/mp3/high' },
  },
}
T.check(LR.onStationsResult(munichMsg), 'Munich lineup accepted')
st = LR.uiState()
T.check(st.currentStationId == 'muc-gong', 'auto-roam matches Pop / Local genre when Dortmund local drops out')
T.check(st.roamNotice:find('Radio Gong 96.3', 1, true) ~= nil, 'roamNotice set on handoff')

-- 4. Manual lock (autoRoam = false) preserves active station when moving back
LR.setAutoRoam(false)
T.check(LR.onStationsResult(dortmundMsg), 'Dortmund lineup accepted with autoRoam=false')
T.check(LR.uiState().currentStationId == 'muc-gong', 'autoRoam=false preserves currently playing station')

-- 5. Persistence round-trip
LR.setAutoRoam(true)
LR.selectStation('do-1live')
LR.setVolume(0.64)
T.check(savedFiles[LR.PREFS_FILE] ~= nil, 'prefs written to /settings/beamngEarth_radio.json')
LR._resetForTest()
T.check(LR.loadPrefs(), 'prefs loaded back')
local reloaded = LR.uiState()
T.check(reloaded.volume == 0.64 and reloaded.autoRoam == true and reloaded.currentStationId == 'do-1live', 'persisted volume, autoRoam, and station restored')

-- 6. hudapps.lua forwarding & radioKey() change detection
local sentHud = {}
guihooks = { trigger = function(name, p) sentHud[#sentHud + 1] = { name = name, p = p } end }
H._reset()
T.check(H.setMounted('radio', true) and H.mounted('radio'), 'radio HUD app mounted')
LR.onStationsResult(dortmundMsg)
local hudGet = function()
  return {
    status = '', credits = '', banner = { text = '', level = 'info', visible = false },
    radio = LR.hudPayload(),
  }
end
T.check(H.update(1.0, hudGet) and #sentHud == 1 and sentHud[1].p.radio.currentStationId == 'do-1live', 'hudapps forwards radio payload')
T.check(not H.update(1.5, hudGet) and #sentHud == 1, 'hudapps skips unchanged radio state')
LR.nextStation()
T.check(H.update(2.0, hudGet) and #sentHud == 2 and sentHud[2].p.radio.currentStationId == 'do-wdr4', 'hudapps re-emits when radio station changes')

-- 7. Disabling hides HUD, stops playback, and halts polling
T.check(LR.setEnabled(false) == false, 'setEnabled(false) disables radio')
T.check(LR.uiState().visible == false and LR.uiState().playing == false and LR.uiState().streamStatus == 'STOPPED', 'disabling stops playback and hides HUD')
T.check(LR.hudPayload() == nil, 'hudPayload returns nil after disabling')
local reqsBefore = #sentReqs
T.check(not LR.update(0.1, { lat = 52.5200, lon = 13.4050 }, 30.0) and #sentReqs == reqsBefore, 'polling stops after disabling')

T.done('test_location_radio')
