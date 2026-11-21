-- BeamNG.Earth Location-Aware Live & Local Radio: GE extension 'beamngEarth_locationRadio'.
-- Polls player position every POLL_S (or after > MOVE_M displacement / town change),
-- requests regional + local stations from earthd (radio_stations_request -> radio_stations_result),
-- persists user preferences in PREFS_FILE, and handles auto-roam genre handoff when a local
-- station drops out of the new area's lineup. Pure apart from BeamNG globals (runs under luajit).
local M = {}

M.POLL_S = 4.0
M.MOVE_M = 2500.0
M.PREFS_FILE = '/settings/beamngEarth_radio.json'
M.VERSION = 1

local state = {
  enabled = false,
  playing = false,
  volume = 0.55,
  autoRoam = true,
  currentStationId = nil,
  currentIndex = 0,
  currentStation = nil,
  regionCode = '',
  regionLabel = '',
  country = '',
  place = '',
  source = '',
  stations = {},
  streamStatus = 'STOPPED',   -- STOPPED | BUFFERING | LIVE | UNAVAILABLE
  streamError = '',
  roamNotice = '',
  roamNoticeUntil = 0,
  lastReqLat = nil,
  lastReqLon = nil,
  lastReqPlace = '',
  lastReqRegion = '',
  lastPollAt = -math.huge,
  nextReqId = 0,
  pendingId = nil,
  clock = 0,
  prefsLoaded = false,
}

local function clampVolume(v)
  local n = tonumber(v)
  if not n or n ~= n then return state.volume end
  return math.max(0.0, math.min(1.0, math.floor(n * 100 + 0.5) / 100))
end

local function haversineM(lat1, lon1, lat2, lon2)
  local r = 6371000.0
  local p1, p2 = math.rad(lat1), math.rad(lat2)
  local dp = math.rad(lat2 - lat1)
  local dl = math.rad(lon2 - lon1)
  local a = math.sin(dp * 0.5) ^ 2 + math.cos(p1) * math.cos(p2) * math.sin(dl * 0.5) ^ 2
  return 2.0 * r * math.asin(math.min(1.0, math.sqrt(a)))
end

local function copyStation(s)
  if type(s) ~= 'table' then return nil end
  local fb = {}
  if type(s.fallbackUrls) == 'table' then
    for i = 1, #s.fallbackUrls do
      fb[i] = tostring(s.fallbackUrls[i] or '')
    end
  end
  return {
    id = tostring(s.id or ''),
    name = tostring(s.name or 'Unknown Station'),
    frequency = tostring(s.frequency or ''),
    genre = tostring(s.genre or ''),
    scope = tostring(s.scope or 'regional'),
    streamUrl = tostring(s.streamUrl or ''),
    fallbackUrls = fb,
    regionCode = tostring(s.regionCode or ''),
    city = tostring(s.city or ''),
    country = tostring(s.country or ''),
    source = tostring(s.source or 'preset'),
  }
end

local function findStationIndex(list, id)
  if not id or id == '' then return 0 end
  for i = 1, #list do
    if list[i].id == id then return i end
  end
  return 0
end

local function genreTokens(genre)
  local tokens = {}
  local g = tostring(genre or ''):lower()
  for w in g:gmatch('[a-z0-9]+') do
    if w ~= 'local' and w ~= 'radio' then tokens[w] = true end
  end
  return tokens
end

local function pickRoamMatch(prevStation, stations)
  if #stations == 0 then return 0 end
  if not prevStation then return 1 end
  local prevGenre = tostring(prevStation.genre or ''):lower()
  local prevTokens = genreTokens(prevGenre)
  local bestIdx, bestScore = 1, -1
  for i = 1, #stations do
    local st = stations[i]
    local g = tostring(st.genre or ''):lower()
    local score = 0
    if prevGenre ~= '' and g == prevGenre then
      score = score + 100
    else
      local tok = genreTokens(g)
      for w in pairs(prevTokens) do
        if tok[w] then score = score + 30 end
      end
    end
    if st.scope == 'local' then score = score + 10
    elseif st.scope == 'regional' then score = score + 5 end
    if score > bestScore then
      bestScore = score
      bestIdx = i
    end
  end
  return bestIdx
end

function M.savePrefs(path)
  local write = rawget(_G, 'jsonWriteFile')
  if not write then return false end
  local out = {
    version = M.VERSION,
    enabled = state.enabled,
    volume = state.volume,
    autoRoam = state.autoRoam,
    lastStationId = state.currentStationId or '',
  }
  local ok, err = pcall(write, path or M.PREFS_FILE, out, true)
  return ok and err ~= false
end

function M.loadPrefs(path)
  state.prefsLoaded = true
  local read = rawget(_G, 'jsonReadFile')
  if not read then return false end
  local fs = rawget(_G, 'FS')
  local target = path or M.PREFS_FILE
  if fs and fs.fileExists and not fs:fileExists(target) then return false end
  local ok, data = pcall(read, target)
  if not ok or type(data) ~= 'table' then return false end
  if data.enabled ~= nil then state.enabled = data.enabled == true end
  if data.autoRoam ~= nil then state.autoRoam = data.autoRoam == true end
  if data.volume ~= nil then state.volume = clampVolume(data.volume) end
  if type(data.lastStationId) == 'string' and data.lastStationId ~= '' then
    state.currentStationId = data.lastStationId
  end
  return true
end

local function ensurePrefs()
  if not state.prefsLoaded then M.loadPrefs() end
end

local function cachedStatusLocation()
  local ok, sb = pcall(require, 'beamngEarth/statusbar')
  if ok and sb and type(sb.location) == 'function' then
    local l = sb.location()
    if type(l) == 'table' then return l end
  end
  return nil
end

local function sendRequest(lat, lon, loc)
  local core = rawget(_G, 'beamngEarth_core')
  if not core or not core.requestRadioStations then return false end
  state.nextReqId = state.nextReqId + 1
  local id = state.nextReqId
  local place = loc and tostring(loc.place or '') or ''
  local region = loc and tostring(loc.region or '') or ''
  local country = loc and tostring(loc.country or '') or ''
  if core.requestRadioStations(id, lat, lon, place, region, country, true) then
    state.pendingId = id
    state.lastReqLat = lat
    state.lastReqLon = lon
    state.lastReqPlace = place
    state.lastReqRegion = region
    state.lastPollAt = state.clock
    return true
  end
  return false
end

function M.update(dtReal, player, clock)
  ensurePrefs()
  state.clock = tonumber(clock) or (state.clock + (tonumber(dtReal) or 0))
  if not state.enabled then return false end
  if not player or not player.lat or not player.lon then return false end
  local lat, lon = tonumber(player.lat), tonumber(player.lon)
  if not lat or not lon then return false end
  if state.clock - state.lastPollAt < M.POLL_S then return false end

  local loc = cachedStatusLocation()
  local place = loc and tostring(loc.place or '') or ''
  local region = loc and tostring(loc.region or '') or ''

  local need = false
  if state.lastReqLat == nil or state.lastReqLon == nil then
    need = true
  elseif haversineM(state.lastReqLat, state.lastReqLon, lat, lon) > M.MOVE_M then
    need = true
  elseif place ~= '' and place ~= state.lastReqPlace then
    need = true
  elseif region ~= '' and region ~= state.lastReqRegion then
    need = true
  end

  if not need then
    state.lastPollAt = state.clock
    return false
  end
  return sendRequest(lat, lon, loc)
end

function M.refresh()
  ensurePrefs()
  if not state.enabled then return false end
  local core = rawget(_G, 'beamngEarth_core')
  local st = core and core._state and core._state() or nil
  local pl = st and st.player
  if not pl or not pl.lat or not pl.lon then return false end
  return sendRequest(tonumber(pl.lat), tonumber(pl.lon), cachedStatusLocation())
end

function M.onStationsResult(msg)
  if type(msg) ~= 'table' or msg.ok == false then return false end
  local list = {}
  if type(msg.stations) == 'table' then
    for i = 1, #msg.stations do
      local c = copyStation(msg.stations[i])
      if c and c.id ~= '' and c.streamUrl ~= '' then
        list[#list + 1] = c
      end
    end
  end

  local prevStation = state.currentStation
  local prevId = state.currentStationId
  state.regionCode = tostring(msg.regionCode or '')
  state.regionLabel = tostring(msg.regionLabel or '')
  state.country = tostring(msg.country or '')
  state.place = tostring(msg.place or '')
  state.source = tostring(msg.source or '')
  state.stations = list

  if #list == 0 then
    state.currentIndex = 0
    if not state.playing or state.autoRoam then
      state.currentStation = nil
      state.currentStationId = nil
    end
    return true
  end

  local idx = findStationIndex(list, prevId)
  if idx > 0 then
    state.currentIndex = idx
    state.currentStation = list[idx]
    state.currentStationId = list[idx].id
  elseif prevStation and not state.autoRoam and state.playing then
    -- Manual lock: keep current playing station alive even outside its local cell
    state.currentIndex = 0
  elseif prevStation and state.autoRoam and (prevStation.scope == 'local' or state.playing) then
    local picked = pickRoamMatch(prevStation, list)
    state.currentIndex = picked
    state.currentStation = list[picked]
    state.currentStationId = list[picked].id
    if state.currentStation.id ~= prevId then
      state.roamNotice = 'Tuned to ' .. state.currentStation.name .. ' (' .. (state.regionLabel ~= '' and state.regionLabel or state.regionCode) .. ')'
      state.roamNoticeUntil = state.clock + 6.0
      if state.playing then
        state.streamStatus = 'BUFFERING'
      end
    end
  else
    state.currentIndex = 1
    state.currentStation = list[1]
    state.currentStationId = list[1].id
  end
  return true
end

function M.selectStation(id)
  ensurePrefs()
  if not state.enabled then return false end
  local idx = findStationIndex(state.stations, tostring(id or ''))
  if idx <= 0 then return false end
  state.currentIndex = idx
  state.currentStation = state.stations[idx]
  state.currentStationId = state.currentStation.id
  state.streamError = ''
  state.roamNotice = ''
  if state.playing then
    state.streamStatus = 'BUFFERING'
  else
    state.playing = true
    state.streamStatus = 'BUFFERING'
  end
  M.savePrefs()
  return true
end

function M.nextStation()
  ensurePrefs()
  local n = #state.stations
  if n == 0 then return false end
  local idx = (state.currentIndex >= 1 and state.currentIndex < n) and (state.currentIndex + 1) or 1
  return M.selectStation(state.stations[idx].id)
end

function M.prevStation()
  ensurePrefs()
  local n = #state.stations
  if n == 0 then return false end
  local idx = (state.currentIndex > 1 and state.currentIndex <= n) and (state.currentIndex - 1) or n
  return M.selectStation(state.stations[idx].id)
end

function M.togglePlay()
  ensurePrefs()
  if not state.enabled then return false end
  if not state.currentStation and #state.stations > 0 then
    state.currentIndex = 1
    state.currentStation = state.stations[1]
    state.currentStationId = state.currentStation.id
  end
  state.playing = not state.playing
  if state.playing then
    state.streamStatus = state.currentStation and 'BUFFERING' or 'UNAVAILABLE'
    state.streamError = ''
  else
    state.streamStatus = 'STOPPED'
  end
  M.savePrefs()
  return state.playing
end

function M.setVolume(v)
  ensurePrefs()
  state.volume = clampVolume(v)
  M.savePrefs()
  return state.volume
end

function M.setAutoRoam(flag)
  ensurePrefs()
  state.autoRoam = flag == true
  M.savePrefs()
  return state.autoRoam
end

function M.setEnabled(flag)
  ensurePrefs()
  state.enabled = flag == true
  if not state.enabled then
    state.playing = false
    state.streamStatus = 'STOPPED'
  end
  M.savePrefs()
  return state.enabled
end

function M.reportStreamStatus(status, stationId, errText)
  if stationId and state.currentStationId and tostring(stationId) ~= state.currentStationId then
    return false
  end
  local s = tostring(status or ''):upper()
  if s ~= 'STOPPED' and s ~= 'BUFFERING' and s ~= 'LIVE' and s ~= 'UNAVAILABLE' then
    return false
  end
  state.streamStatus = s
  state.streamError = tostring(errText or '')
  return true
end

function M.hudPayload()
  ensurePrefs()
  if not state.enabled then return nil end
  local notice = (state.roamNotice ~= '' and state.clock <= state.roamNoticeUntil) and state.roamNotice or ''
  local list = {}
  for i = 1, #state.stations do
    local s = state.stations[i]
    list[i] = {
      id = s.id,
      name = s.name,
      frequency = s.frequency,
      genre = s.genre,
      scope = s.scope,
      streamUrl = s.streamUrl,
      fallbackUrls = s.fallbackUrls,
      city = s.city,
    }
  end
  return {
    enabled = state.enabled,
    visible = state.enabled,
    playing = state.playing,
    volume = state.volume,
    autoRoam = state.autoRoam,
    currentStationId = state.currentStationId or '',
    currentIndex = state.currentIndex,
    currentStation = state.currentStation,
    regionCode = state.regionCode,
    regionLabel = state.regionLabel,
    streamStatus = state.streamStatus,
    streamError = state.streamError,
    roamNotice = notice,
    stations = list,
  }
end

function M.uiState()
  ensurePrefs()
  local p = M.hudPayload() or {
    enabled = state.enabled,
    visible = state.enabled,
    playing = false,
    volume = state.volume,
    autoRoam = state.autoRoam,
    currentStationId = state.currentStationId or '',
    currentIndex = state.currentIndex,
    currentStation = state.currentStation,
    regionCode = state.regionCode,
    regionLabel = state.regionLabel,
    streamStatus = state.streamStatus,
    streamError = state.streamError,
    roamNotice = '',
    stations = {},
  }
  p.source = state.source
  return p
end

function M.onExtensionLoaded()
  M.loadPrefs()
end

function M.reset()
  state.playing = false
  state.streamStatus = 'STOPPED'
  state.streamError = ''
  state.roamNotice = ''
  state.roamNoticeUntil = 0
  state.lastReqLat = nil
  state.lastReqLon = nil
  state.lastReqPlace = ''
  state.lastReqRegion = ''
  state.lastPollAt = -math.huge
  state.pendingId = nil
end

function M._resetForTest()
  state.enabled = false
  state.playing = false
  state.volume = 0.55
  state.autoRoam = true
  state.currentStationId = nil
  state.currentIndex = 0
  state.currentStation = nil
  state.regionCode = ''
  state.regionLabel = ''
  state.country = ''
  state.place = ''
  state.source = ''
  state.stations = {}
  state.streamStatus = 'STOPPED'
  state.streamError = ''
  state.roamNotice = ''
  state.roamNoticeUntil = 0
  state.lastReqLat = nil
  state.lastReqLon = nil
  state.lastReqPlace = ''
  state.lastReqRegion = ''
  state.lastPollAt = -math.huge
  state.nextReqId = 0
  state.pendingId = nil
  state.clock = 0
  state.prefsLoaded = false
end

return M
