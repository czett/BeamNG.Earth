-- BeamNG.Earth Transport Modes (Taxi, Bus, Logistics): GE extension 'beamngEarth_transportModes'.
-- Zero overhead when inactive: update(), drawMarker(), drawUi() return immediately when no job/pending/summary exists.
-- Pure math & state-machine helpers run under plain luajit for tests (mod/tests/test_transport_modes.lua).
local M = {}

M.MODES = { taxi = true, bus = true, logistics = true, parcel = true }
M.TIERS = {
  taxi = { short = true, city = true, regional = true, long = true },
  bus = { partial = true, full = true },
  logistics = { ['local'] = true, city = true, regional = true, long = true },
  parcel = { ['local'] = true, city = true, regional = true, long = true },
}

M.STOP_SPEED_MPS = 1.5
M.DWELL_S = 2.5
M.BAY_STOP_SPEED_MPS = 1.5
M.BAY_DWELL_S = 2.5
M.BAY_LAT_TOL_M = 3.5
M.BAY_LONG_TOL_M = 5.0
M.FALLBACK_RADIUS_M = 15.0
M.FALLBACK_SPEED_MPS = 0.8
M.FALLBACK_DWELL_S = 5.0
M.DEFAULT_ZONE_RADIUS_M = 12.0
M.HEIGHT_TOL_M = 10.0
M.DRAW_RADIUS_M = 450.0
M.REQUEST_TIMEOUT_S = 15.0
M.PROBE_TIMEOUT_S = 0.6
M.SAMPLE_S = 0.2
M.HARSH_ACCEL_MPS2 = 5.5
M.HARSH_VERT_MPS2 = 16.5
M.HARSH_VERT_SPIKE_MPS2 = 22.0
M.HARSH_VERT_SUSTAIN_MPS2 = 14.5
M.HARSH_JERK_MPS3 = 22.0
M.DAMAGE_COLLISION_DELTA = 50
M.COLLISION_COOLDOWN_S = 1.25
M.COLLISION_PEN_CAP = 65
M.JUMP_RESET_M = 200.0
M.RADIAL_LEVEL = '/root/sandbox/other/'

-- Taxi fare & scoring constants
M.TAXI_BASE_FARE = 3.50
M.TAXI_PER_KM = 1.85
M.TAXI_MIN_FARE = 5.00

-- Bus capacity & passenger load constants
M.BUS_CAPACITY = 40
M.BUS_PAX_MASS_KG = 75

-- Trailer spawning & hitching constants
M.TRAILER_STAGE_DIST_M = 160.0
M.COUPLER_RANGE_M = 2.8
M.DESPAWN_DIST_M = 80.0
M.HITCH_ATTEMPTS = { 0.15, 0.35, 0.70, 1.20 }
M.TRAILER_LABELS = {
  dryvan = 'Dry Van Trailer',
  reefer = 'Reefer Trailer',
  tanker = 'Tanker Trailer',
  flatbed = 'Flatbed Trailer',
  container = 'Container Trailer',
  frameless_dump = 'Dump Trailer',
  log_trailer = 'Log Trailer',
  lowboy = 'Lowboy Trailer',
  boxtrailer = 'Box Trailer',
  boxutility = 'Utility Trailer',
  boxutility_large = 'Large Utility Trailer',
  cargotrailer = 'Cargo Trailer',
  tsfb = 'Flatbed Utility Trailer',
}
M.SEMI_TRAILER_MODELS = {
  'dryvan', 'reefer', 'tanker', 'flatbed', 'container', 'frameless_dump', 'log_trailer', 'lowboy', 'boxtrailer',
}
M.TOWHITCH_TRAILER_MODELS = { 'boxutility', 'boxutility_large', 'cargotrailer', 'tsfb' }
M.TRAILER_CANDIDATES = {
  fifthwheel = {
    fuel = { 'tanker', 'dryvan', 'container' },
    fuel_drums = { 'dryvan', 'flatbed', 'container' },
    food = { 'reefer', 'dryvan', 'container' },
    groceries = { 'reefer', 'dryvan', 'container' },
    chilled_food = { 'reefer', 'dryvan', 'container' },
    bulk_food = { 'reefer', 'dryvan', 'container' },
    beverages = { 'dryvan', 'reefer', 'container' },
    medical = { 'reefer', 'dryvan', 'container' },
    pharma = { 'reefer', 'dryvan', 'container' },
    hardware = { 'flatbed', 'container', 'dryvan' },
    timber = { 'flatbed', 'log_trailer', 'container' },
    steel = { 'flatbed', 'dryvan', 'container' },
    machinery = { 'flatbed', 'lowboy', 'dryvan', 'container' },
    industrial = { 'flatbed', 'container', 'dryvan', 'frameless_dump' },
    aggregates = { 'frameless_dump', 'flatbed', 'container' },
    retail = { 'dryvan', 'container', 'reefer', 'flatbed' },
    dry_goods = { 'dryvan', 'container', 'reefer', 'flatbed' },
    pallets = { 'dryvan', 'container', 'flatbed', 'reefer' },
    general = { 'dryvan', 'container', 'flatbed', 'reefer' },
    default = { 'dryvan', 'flatbed', 'container', 'reefer', 'frameless_dump', 'tanker' },
  },
  towhitch = {
    heavy = { 'boxutility_large', 'cargotrailer', 'boxutility', 'tsfb' },
    light = { 'boxutility', 'boxutility_large', 'tsfb', 'cargotrailer' },
  },
}
M.SOLO_CARGO_CAP_KG = {
  car = 350,
  van = 1400,
  box_truck = 8000,
  semi = 5000,
}

-- Physical 3D cargo prop constants
M.PARCEL_PROP_MODELS = { 'cardboard_box', 'cargo_load_box_M', 'cargo_load_box_S', 'woodcrate', 'cargo_load_box_L' }
M.CRATE_PROP_MODELS = { 'woodcrate', 'EuroPallet', 'cargo_load_box_L', 'cargo_load_box_M', 'cardboard_box' }
M.OPEN_TRAILER_MODELS = { boxutility = true, boxutility_large = true, tsfb = true, flatbed = true }
M.PROP_EST_MASS_KG = {
  cardboard_box = 10,
  cargo_load_box_S = 10,
  cargo_load_box_M = 16,
  cargo_load_box_L = 25,
  woodcrate = 35,
  EuroPallet = 60,
}
M.MAX_CARGO_PROPS = 8

-- Interactive OSM Fuel Stations & Career Refueling Economy
M.FUEL_QUERY_INTERVAL_S = 6.0
M.FUEL_QUERY_MOVE_M = 400.0
M.FUEL_QUERY_RADIUS_M = 1500.0
M.FUEL_PROBE_INTERVAL_S = 1.5
M.FUEL_DRAW_RADIUS_M = 140.0
M.FUEL_HIDE_NEAR_STOP_M = 25.0
M.FUEL_STOP_SPEED_MPS = 0.5
M.FUEL_STOP_HOLD_S = 1.2
M.FUEL_RATE_RATIO_PER_S = 0.18
M.FUEL_RATE_LITERS_PER_S = 1.8
M.FUEL_OVERDRAFT_LIMIT = -50.0
M.LOW_FUEL_PCT = 25
M.FUEL_RECEIPT_SHOW_S = 4.5
M.FUEL_BAY_SPEC = { width = 3.3, length = 7.2, halfW = 1.65, halfL = 3.60, latTol = 3.2, longTol = 4.5 }
M.FUEL_BAY_IDLE_CYAN = { 0.22, 0.74, 0.96, 0.48 }
M.FUEL_BAY_ACTIVE_CYAN = { 0.18, 0.88, 1.00, 0.68 }

-- Injectable dependencies for pure luajit unit tests
M.core = function() return rawget(_G, 'beamngEarth_core') end
M.gps = function() return require('beamngEarth/gps') end
M.now = function() return os.clock() end
M.say = function(text, sec)
  local um = rawget(_G, 'ui_message')
  if um then pcall(um, tostring(text), tonumber(sec) or 6, 'beamngEarthTransport') end
end
M.castRay = function(x, y, zTop, maxDist)
  local ray = rawget(_G, 'castRayStatic')
  if not ray then return nil end
  local ok, d = pcall(ray, vec3(x, y, zTop), vec3(0, 0, -1), maxDist)
  if ok and type(d) == 'number' and d < maxDist then return zTop - d end
  return nil
end
M.castRayDir = function(ox, oy, oz, dx, dy, dz, maxDist)
  local ray = rawget(_G, 'castRayStatic')
  if not ray then return nil end
  local ok, d = pcall(ray, vec3(ox, oy, oz), vec3(dx, dy, dz), maxDist)
  if ok and type(d) == 'number' and d > 0 and d < maxDist then return d end
  return nil
end
M.playerVeh = function()
  local gpv = rawget(_G, 'getPlayerVehicle')
  if gpv then
    local v = gpv(0)
    if v then return v end
  end
  local b = rawget(_G, 'be')
  if b and b.getPlayerVehicle then
    local ok, v = pcall(b.getPlayerVehicle, b, 0)
    if ok and v then return v end
  end
  return nil
end
M.readDamage = function()
  local veh = M.playerVeh()
  if not veh then return 0 end
  local id = veh.getID and veh:getID() or (veh.getId and veh:getId())
  local m = rawget(_G, 'map')
  local o = id and m and m.objects and m.objects[id]
  return o and tonumber(o.damage) or 0
end
M.modelExists = function(model)
  if type(model) ~= 'string' or model == '' then return false end
  local fs = rawget(_G, 'FS')
  if fs and fs.directoryExists then
    local ok, ex = pcall(fs.directoryExists, fs, '/vehicles/' .. model)
    if ok then return ex == true end
  end
  local cv = rawget(_G, 'core_vehicles')
  if cv and cv.getModelList then
    local ok, list = pcall(cv.getModelList)
    if ok and type(list) == 'table' and list.models then
      return list.models[model] ~= nil
    end
  end
  return true
end

local pending = nil       -- { id, mode, tier, sentAt, vehicle }
local pendingProbe = nil  -- { mode, tier, pl, heading, sentAt, geInfo, vehId }
local activeJob = nil     -- { mode, tier, title, routeRef, source, stops, stopIndex, ... }
local summary = nil       -- completed job summary until dismissed or new job starts
local lastError = nil
local nextReqId = 0
local jobSeq = 0
local gpsTarget = nil     -- { lat, lon } last set by transportModes
local vehicleProbes = {}  -- vehId -> { massKg, coupler, couplerNode, hasCouplerAttached, at }
local despawnQueue = {}   -- { { id = trailerId } } job-owned trailers awaiting > 80 m player separation
local lastDespawnCheckAt = -math.huge

M.CAREER_FILE = '/settings/beamngEarth_transport_career.json'
M.CAREER_VERSION = 1
M.CAREER_RANKS = {
  { id = 'rookie', name = 'Rookie Driver', minJobs = 0, minEarnings = 0 },
  { id = 'courier', name = 'Local Courier', minJobs = 3, minEarnings = 75 },
  { id = 'specialist', name = 'Route Specialist', minJobs = 10, minEarnings = 350 },
  { id = 'senior', name = 'Senior Fleet Operator', minJobs = 25, minEarnings = 1200 },
  { id = 'master', name = 'Master Hauler', minJobs = 50, minEarnings = 3500 },
}

local careerStats = nil
local careerLoaded = false
local careerStatsCache = nil
local vehicleMatchCache = nil -- { vehId, probeAt, at, match }
M.VEHICLE_MATCH_CACHE_S = 0.5

local scratchP0, scratchP1, scratchP2, scratchP3, scratchCol = nil, nil, nil, nil, nil
local legInfoScratch = {}
local fuel = {
  stations = {},
  reqId = 0,
  lastQueryAt = -math.huge,
  lastQueryLat = nil,
  lastQueryLon = nil,
  pendingRoute = false,
  lastProbeAt = -math.huge,
  vehId = nil,
  ratio = nil,
  capacityL = 55.0,
  volumeL = nil,
  hasTank = false,
  refuel = nil,         -- { stationId, stationName, pricePerLiter, holdS, active, done, doneAt, litersAdded, costTotal, overdraftHit, lastCmdAt, lastSaveAt }
  routedToFuel = false,
}

local function hypot(x, y) return math.sqrt(x * x + y * y) end
function M.isFinite(n)
  return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end
local isFinite = M.isFinite

local function vehIdOf(veh)
  if not veh then return nil end
  if veh.getID then return veh:getID() end
  if veh.getId then return veh:getId() end
  return nil
end

-- Pure: validate (mode, tier) -> true or false, err
function M.validateRequest(mode, tier)
  mode = type(mode) == 'string' and mode:lower() or ''
  tier = type(tier) == 'string' and tier:lower() or ''
  if mode == 'taxi' and tier == 'neighborhood' then tier = 'short' end
  if not M.MODES[mode] then return false, 'unknown transport mode' end
  if not (M.TIERS[mode] and M.TIERS[mode][tier]) then return false, 'unknown tier for ' .. mode end
  return true
end

-- Pure: great-circle distance in metres (used for fallback distance before anchor / offline)
function M.haversineM(lat1, lon1, lat2, lon2)
  local r = math.pi / 180
  local a = math.sin((lat2 - lat1) * r / 2) ^ 2
    + math.cos(lat1 * r) * math.cos(lat2 * r) * math.sin((lon2 - lon1) * r / 2) ^ 2
  return 2 * 6371008.8 * math.asin(math.min(1, math.sqrt(a)))
end

-- Pure: default dwell target (seconds) when stop.dwellTargetS is absent
function M.defaultDwellTargetS(mode, tier, stop, cargoKg, legKind)
  mode = type(mode) == 'string' and mode:lower() or ''
  tier = type(tier) == 'string' and tier:lower() or ''
  local kind = stop and tostring(stop.kind or ''):lower() or ''
  local name = stop and tostring(stop.name or ''):lower() or ''
  local lk = type(legKind) == 'string' and legKind:lower() or ''
  if mode == 'taxi' then
    local isHub = name:find('airport') or name:find('station') or name:find('terminal') or name:find('hotel') or name:find('hospital')
    if kind == 'pickup' then return isHub and 2.5 or 2.2 end
    return (isHub or tier == 'regional' or tier == 'long') and 3.0 or 2.5
  elseif mode == 'bus' then
    local isHub = name:find('station') or name:find('terminal') or name:find('hub') or name:find('central')
      or name:find('bahnhof') or name:find('gare') or name:find('airport')
    return isHub and 4.5 or 3.5
  elseif mode == 'parcel' then
    return M.BAY_DWELL_S
  elseif mode == 'logistics' then
    if lk == 'loaded_trailer' or lk == 'deadhead' or kind == 'deadhead' then
      return 2.5
    end
    local kg = math.max(0, tonumber(cargoKg) or 0)
    if lk == 'loaded_solo' then
      kg = math.min(8000, kg)
    end
    local lo, hi, frac
    if kg <= 1400 then
      lo, hi, frac = 3.5, 4.5, math.min(1, kg / 1400)
    elseif kg <= 8000 then
      lo, hi, frac = 6.0, 8.0, math.min(1, (kg - 1400) / 6600)
    else
      lo, hi, frac = 9.0, 12.0, math.min(1, (kg - 8000) / 18000)
    end
    local base = lo + (hi - lo) * frac
    if kind == 'delivery' then base = math.max(lo, base * 0.92) end
    return math.floor(base * 10 + 0.5) / 10
  end
  return M.BAY_DWELL_S
end

-- Pure: contextual dwell status label
function M.dwellStatusLabel(mode, stopKind, dwellMode, legKind, upLegKind, trailerState, stop)
  mode = type(mode) == 'string' and mode:lower() or ''
  local kind = type(stopKind) == 'string' and stopKind:lower() or ''
  local lk = type(legKind) == 'string' and legKind:lower() or ''
  local ulk = type(upLegKind) == 'string' and upLegKind:lower() or ''
  local base
  if mode == 'taxi' then
    base = (kind == 'pickup') and 'Passenger boarding' or 'Passenger alighting'
  elseif mode == 'bus' then
    base = 'Passengers boarding'
  elseif mode == 'parcel' then
    local action = stop and tostring(stop.parcelAction or ''):lower() or ''
    local rec = stop and tostring(stop.recipient or '') or ''
    if action == 'pickup_return' or kind == 'pickup' then
      base = rec ~= '' and ('Picking up return parcel · ' .. rec) or 'Picking up return parcel'
    else
      base = rec ~= '' and ('Delivering parcel · ' .. rec) or 'Delivering parcel'
    end
  elseif mode == 'logistics' then
    if kind == 'deadhead' or (lk == 'deadhead' and ulk == '') then
      base = 'Checking in at depot'
    elseif kind == 'loading' then
      if ulk == 'loaded_trailer' or trailerState == 'staged' then
        base = 'Hooking up trailer'
      else
        base = 'Loading cargo'
      end
    else
      if lk == 'loaded_trailer' then
        base = 'Unhooking trailer'
      else
        base = 'Unloading cargo'
      end
    end
  else
    base = 'Hold in bay'
  end
  if dwellMode == 'fallback' then
    return 'Kerbside · ' .. base
  end
  return base
end

-- Pure: advance dwell timer for a kerbside stop. Returns status ('approaching'|'dwelling'|'complete'), nextDwellS.
function M.stepStop(dwellS, distXY, dz, speed, zoneRadius, dtSim, paused)
  dwellS = tonumber(dwellS) or 0
  if paused or not dtSim or dtSim <= 0 then
    return dwellS > 0 and 'dwelling' or 'approaching', dwellS
  end
  local r = tonumber(zoneRadius) or M.DEFAULT_ZONE_RADIUS_M
  local heightOk = (dz == nil) or (math.abs(dz) <= M.HEIGHT_TOL_M)
  if distXY <= r and heightOk and speed < M.STOP_SPEED_MPS then
    local nxt = dwellS + dtSim
    if nxt >= M.DWELL_S then return 'complete', M.DWELL_S end
    return 'dwelling', nxt
  end
  return 'approaching', 0
end

local BAY_SPEC_LARGE = { width = 3.2, length = 11.5, halfW = 1.60, halfL = 5.75, latTol = M.BAY_LAT_TOL_M, longTol = 7.75 }
local BAY_SPEC_COMPACT = { width = 2.7, length = 6.2, halfW = 1.35, halfL = 3.10, latTol = M.BAY_LAT_TOL_M, longTol = M.BAY_LONG_TOL_M }

-- Pure: rectangular parking/loading bay dimensions & primary tolerances for mode/tier.
function M.baySpec(mode, tier)
  mode = type(mode) == 'string' and mode:lower() or ''
  tier = type(tier) == 'string' and tier:lower() or ''
  if mode == 'bus' or (mode == 'logistics' and tier ~= 'local') then
    return BAY_SPEC_LARGE
  end
  return BAY_SPEC_COMPACT
end

-- Pure: ENU forward (fx, fy) and right-hand lateral (rx, ry) unit axes for compass bearingDeg given local north (nx, ny).
function M.bayFrame(northX, northY, bearingDeg)
  local nx, ny = tonumber(northX) or 0, tonumber(northY) or 1
  local nl = math.sqrt(nx * nx + ny * ny)
  if nl < 1e-6 then nx, ny = 0, 1 else nx, ny = nx / nl, ny / nl end
  local ex, ey = ny, -nx
  local rad = math.rad(tonumber(bearingDeg) or 0)
  local c, s = math.cos(rad), math.sin(rad)
  local fx, fy = nx * c + ex * s, ny * c + ey * s
  return fx, fy, fy, -fx
end

-- Pure: signed (longitudinal, lateral) metres from bay center (sx, sy) to (px, py).
function M.bayOffsets(px, py, sx, sy, fx, fy, rx, ry)
  local dx, dy = px - sx, py - sy
  return dx * fx + dy * fy, dx * rx + dy * ry
end

-- Pure: entry direction (+1 forward, -1 reverse) and alignment check (bidirectional bays allow 0° and 180°).
function M.bayEntryDir(playerHeadingDeg, bayBearingDeg, bidirectional)
  if type(playerHeadingDeg) ~= 'number' or type(bayBearingDeg) ~= 'number' then
    return 1, true
  end
  local diff = math.abs((playerHeadingDeg - bayBearingDeg + 180) % 360 - 180)
  if bidirectional and diff > 90 then
    return -1, (180 - diff) <= 70
  end
  return 1, bidirectional and (diff <= 70) or true
end

-- Pure: format bus schedule delta in seconds -> 'On Time' | '+1m 10s' | '-25s'.
function M.formatScheduleDelta(deltaS)
  local d = math.floor((tonumber(deltaS) or 0) + 0.5)
  if math.abs(d) <= 15 then return 'On Time' end
  local sign = d > 0 and '+' or '-'
  local a = math.abs(d)
  local m = math.floor(a / 60)
  local s = a % 60
  if m > 0 then
    return string.format('%s%dm %02ds', sign, m, s)
  end
  return string.format('%s%ds', sign, s)
end

-- Pure: classify whether a 0.2s telemetry sample is harsh (rural-bump tolerant, VIP-strict).
function M.isHarshSample(ah, az, jerk, prevVertSpike, isVip)
  local scale = isVip and 0.80 or 1.0
  local horizHarsh = (ah > M.HARSH_ACCEL_MPS2 * scale) or (jerk > M.HARSH_JERK_MPS3 * scale)
  local absAz = math.abs(az or 0)
  local vertSustain = absAz > M.HARSH_VERT_SUSTAIN_MPS2
  local vertHarsh = (absAz > M.HARSH_VERT_SPIKE_MPS2) or (prevVertSpike == true and absAz > M.HARSH_VERT_MPS2 * scale)
  return (horizHarsh or vertHarsh), vertSustain
end

-- Pure: advance dwell timer with dynamic primary bay target + kerbside fallback fail-safe.
-- Returns state ('approaching'|'dwelling'|'complete'|'fallback_complete'), nextDwellS, nextDwellMode, targetDwellS.
function M.stepBayStop(dwellS, dwellMode, distXY, longOff, latOff, dz, speed, baySpec, dtSim, paused, targetDwellS)
  dwellS = tonumber(dwellS) or 0
  dwellMode = dwellMode or 'none'
  local bayTarget = math.max(1.5, tonumber(targetDwellS) or M.BAY_DWELL_S)
  local fallbackTarget = math.max(M.FALLBACK_DWELL_S, bayTarget + 2.5)
  local heightOk = (dz == nil) or (math.abs(dz) <= M.HEIGHT_TOL_M)
  local latTol = (baySpec and baySpec.latTol) or M.BAY_LAT_TOL_M
  local longTol = (baySpec and baySpec.longTol) or M.BAY_LONG_TOL_M
  local inBay = heightOk and math.abs(latOff) <= latTol and math.abs(longOff) <= longTol
  local inFallback = heightOk and distXY <= M.FALLBACK_RADIUS_M

  if paused or not dtSim or dtSim <= 0 then
    if dwellS > 0 then
      local mode = (dwellMode == 'fallback') and 'fallback' or 'bay'
      local target = (mode == 'fallback') and fallbackTarget or bayTarget
      return 'dwelling', dwellS, mode, target
    end
    return 'approaching', 0, 'none', bayTarget
  end

  if inBay and speed < M.BAY_STOP_SPEED_MPS then
    local cur = math.min(dwellS, bayTarget)
    local nxt = cur + dtSim
    if nxt >= bayTarget then
      return 'complete', bayTarget, 'bay', bayTarget
    end
    return 'dwelling', nxt, 'bay', bayTarget
  end

  if inFallback and speed < M.FALLBACK_SPEED_MPS then
    local cur = (dwellMode == 'fallback') and math.min(dwellS, fallbackTarget) or 0
    local nxt = cur + dtSim
    if nxt >= fallbackTarget then
      return 'fallback_complete', fallbackTarget, 'fallback', fallbackTarget
    end
    return 'dwelling', nxt, 'fallback', fallbackTarget
  end

  return 'approaching', 0, 'none', bayTarget
end

-- Pure: Taxi fare, tip, totalFare, and timelinessPct from job metrics.
function M.computeTaxiFare(m)
  if type(m) ~= 'table' then return 0, 0, 0, 100 end
  local onBoard = m.passengerOnBoard == true or (tonumber(m.fareDrivenM) or 0) > 0
  if not onBoard then
    return 0, 0, 0, 100
  end
  local fareKm = math.max(0, (tonumber(m.fareDrivenM) or 0) / 1000.0)
  if not isFinite(fareKm) then fareKm = 0 end
  local fareMult = tonumber(m.fareMult) or (m.taxi and tonumber(m.taxi.fareMult)) or 1.0
  local tipMult = tonumber(m.tipMult) or (m.taxi and tonumber(m.taxi.tipMult)) or 1.0
  local baseMeter = math.max(M.TAXI_MIN_FARE, M.TAXI_BASE_FARE + fareKm * M.TAXI_PER_KM)
  local meter = baseMeter * fareMult
  local fareElapsed = math.max(0, tonumber(m.fareElapsedS) or 0)
  local targetS = tonumber(m.targetLegS) or 0
  local timeliness = 100
  if targetS > 0 and fareElapsed > targetS * 1.15 then
    local ratio = (fareElapsed - targetS * 1.15) / math.max(15.0, targetS)
    timeliness = math.max(40, math.min(100, math.floor(100 - ratio * 45 + 0.5)))
  end
  meter = math.floor(meter * 100 + 0.5) / 100
  local tip = 0
  local scoreHint = tonumber(m._scoreHint)
  if scoreHint and scoreHint > 60 then
    tip = math.floor(meter * ((scoreHint - 60) / 40.0) * 0.25 * tipMult * 100 + 0.5) / 100
  end
  local total = math.floor((meter + tip) * 100 + 0.5) / 100
  return meter, tip, total, timeliness
end

-- Pure: compute 0..100 smoothness, safety, and (for Taxi) comfort/timeliness score.
function M.computeScore(m)
  if type(m) ~= 'table' then return 100, 100, 100 end
  local elapsed = tonumber(m.elapsedS) or 0
  if not isFinite(elapsed) then elapsed = 0 end
  elapsed = math.max(1.0, elapsed)
  local harshTime = tonumber(m.harshS) or 0
  if not isFinite(harshTime) or harshTime < 0 then harshTime = 0 end
  local collisions = math.max(0, tonumber(m.collisions) or 0)
  if not isFinite(collisions) then collisions = 0 end
  local dmg = math.max(0, tonumber(m.damageDelta) or 0)
  if not isFinite(dmg) then dmg = 0 end
  local skipped = math.max(0, tonumber(m.stopsSkipped) or 0)

  local harshRatio = math.min(1.0, harshTime / math.max(5.0, elapsed * 0.35))
  local smoothness = math.max(0, math.min(100, math.floor(100 - harshRatio * 45 + 0.5)))
  local collisionPen = math.min(M.COLLISION_PEN_CAP, collisions * 8 + math.min(45, dmg / 400.0))
  local skipPen = skipped * 20

  local mode = type(m.mode) == 'string' and m.mode:lower() or ''
  if mode == 'taxi' and m.passengerOnBoard == true then
    local fElapsed = math.max(1.0, tonumber(m.fareElapsedS) or elapsed)
    local fHarsh = math.max(0, tonumber(m.fareHarshS) or 0)
    if not isFinite(fHarsh) then fHarsh = 0 end
    local isVip = (m.rideArchetype == 'vip') or (m.taxi and m.taxi.archetype == 'vip')
    local fRatio = math.min(1.0, fHarsh / math.max(5.0, fElapsed * 0.35))
    local comfortDrop = isVip and 62 or 50
    local paxComfort = math.max(0, math.min(100, math.floor(100 - fRatio * comfortDrop + 0.5)))
    local _, _, _, timeliness = M.computeTaxiFare(m)
    local blended = paxComfort * 0.65 + smoothness * 0.10 + timeliness * 0.25
    local score = math.max(0, math.min(100, math.floor(blended - collisionPen - skipPen + 0.5)))
    return score, paxComfort, timeliness
  end

  local score = math.max(0, math.min(100, math.floor(smoothness - collisionPen - skipPen + 0.5)))
  return score, smoothness, 100
end

local function round2(v)
  v = tonumber(v) or 0
  if not isFinite(v) then return 0 end
  return math.floor(v * 100 + 0.5) / 100
end

-- Pure: derive driver rank and next-rank threshold from completedJobs & totalEarnings.
function M.computeDriverRank(completedJobs, totalEarnings)
  local jobs = math.max(0, math.floor(tonumber(completedJobs) or 0))
  local earn = math.max(0, tonumber(totalEarnings) or 0)
  local rankIdx = 1
  for i, r in ipairs(M.CAREER_RANKS) do
    if jobs >= r.minJobs and earn >= r.minEarnings then
      rankIdx = i
    end
  end
  local cur = M.CAREER_RANKS[rankIdx]
  local nxt = M.CAREER_RANKS[rankIdx + 1]
  return cur.name, {
    index = rankIdx,
    id = cur.id,
    name = cur.name,
    nextName = nxt and nxt.name or nil,
    nextMinJobs = nxt and nxt.minJobs or nil,
    nextMinEarnings = nxt and nxt.minEarnings or nil,
  }
end

local function defaultCareerStats()
  local byMode = {}
  for m in pairs(M.MODES) do
    byMode[m] = { jobs = 0, earnings = 0 }
  end
  local rankName = M.computeDriverRank(0, 0)
  return {
    version = M.CAREER_VERSION,
    totalEarnings = 0,
    totalDistanceKm = 0,
    completedJobs = 0,
    scoreSum = 0,
    bestScore = 0,
    avgScore = 0,
    streak = 0,
    driverRank = rankName,
    byMode = byMode,
  }
end

local function sanitizeCareerStats(raw)
  local c = defaultCareerStats()
  if type(raw) ~= 'table' then return c end
  c.totalEarnings = math.max(M.FUEL_OVERDRAFT_LIMIT, round2(raw.totalEarnings))
  c.totalDistanceKm = math.max(0, round2(raw.totalDistanceKm))
  c.completedJobs = math.max(0, math.floor(tonumber(raw.completedJobs) or 0))
  c.scoreSum = math.max(0, math.floor((tonumber(raw.scoreSum) or 0) + 0.5))
  c.bestScore = math.max(0, math.min(100, math.floor((tonumber(raw.bestScore) or 0) + 0.5)))
  c.streak = math.max(0, math.floor(tonumber(raw.streak) or 0))
  if c.completedJobs > 0 then
    if c.scoreSum == 0 and tonumber(raw.avgScore) and tonumber(raw.avgScore) > 0 then
      c.scoreSum = math.floor(tonumber(raw.avgScore) * c.completedJobs + 0.5)
    end
    c.avgScore = math.max(0, math.min(100, math.floor((c.scoreSum / c.completedJobs) + 0.5)))
  else
    c.scoreSum = 0
    c.avgScore = 0
  end
  if type(raw.byMode) == 'table' then
    for m in pairs(M.MODES) do
      local bm = raw.byMode[m]
      if type(bm) == 'table' then
        c.byMode[m] = {
          jobs = math.max(0, math.floor(tonumber(bm.jobs) or 0)),
          earnings = math.max(0, round2(bm.earnings)),
        }
      end
    end
  end
  c.driverRank = M.computeDriverRank(c.completedJobs, c.totalEarnings)
  return c
end

local function ensureCareerLoaded()
  if not careerLoaded then
    M.loadCareerStats()
  end
  return careerStats
end

function M.loadCareerStats(path)
  local target = path or M.CAREER_FILE
  local data = nil
  local read = rawget(_G, 'jsonReadFile')
  local fs = rawget(_G, 'FS')
  if type(read) == 'function' and (not fs or not fs.fileExists or fs:fileExists(target)) then
    local ok, res = pcall(read, target)
    if ok and type(res) == 'table' then data = res end
  end
  careerStats = sanitizeCareerStats(data)
  careerLoaded = true
  careerStatsCache = nil
  return M.getCareerStats()
end

function M.saveCareerStats(path)
  local c = ensureCareerLoaded()
  local write = rawget(_G, 'jsonWriteFile')
  if type(write) ~= 'function' then return false end
  local ok, res = pcall(write, path or M.CAREER_FILE, c, true)
  return ok and res ~= false
end

function M.getCareerStats()
  local c = ensureCareerLoaded()
  if careerStatsCache then return careerStatsCache end
  local _, rankMeta = M.computeDriverRank(c.completedJobs, c.totalEarnings)
  local byModeCopy = {}
  for m in pairs(M.MODES) do
    local bm = c.byMode[m] or { jobs = 0, earnings = 0 }
    byModeCopy[m] = { jobs = bm.jobs, earnings = bm.earnings }
  end
  careerStatsCache = {
    version = c.version,
    totalEarnings = c.totalEarnings,
    totalDistanceKm = c.totalDistanceKm,
    completedJobs = c.completedJobs,
    bestScore = c.bestScore,
    avgScore = c.avgScore,
    streak = c.streak,
    driverRank = rankMeta.name,
    rankMeta = rankMeta,
    byMode = byModeCopy,
  }
  return careerStatsCache
end

function M.resetCareerStats(path)
  careerStats = defaultCareerStats()
  careerLoaded = true
  careerStatsCache = nil
  M.saveCareerStats(path)
  return { ok = true, career = M.getCareerStats() }
end

local LOGISTICS_TIER_MULT = { ['local'] = 1.0, city = 1.15, regional = 1.35, long = 1.60 }
local PARCEL_TIER_MULT = { ['local'] = 1.0, city = 1.10, regional = 1.25, long = 1.45 }

-- Pure: itemized payout breakdown across all 4 transport modes.
function M.computePayoutBreakdown(j, score, smooth, timeliness, streak)
  if type(j) ~= 'table' or (tonumber(j.stopsCompleted) or 0) <= 0 then
    return {
      basePay = 0,
      timeBonus = 0,
      smoothnessBonus = 0,
      tipOrStreakBonus = 0,
      damagePenalty = 0,
      totalEarned = 0,
      streakApplied = 0,
    }
  end
  local mode = type(j.mode) == 'string' and j.mode:lower() or ''
  local tier = type(j.tier) == 'string' and j.tier:lower() or ''
  local sc = math.max(0, math.min(100, tonumber(score) or 100))
  local sm = math.max(0, math.min(100, tonumber(smooth) or 100))
  local tl = math.max(0, math.min(100, tonumber(timeliness) or 100))
  local stopsDone = math.max(0, tonumber(j.stopsCompleted) or 0)
  local skipped = math.max(0, tonumber(j.stopsSkipped) or 0)
  local collisions = math.max(0, tonumber(j.collisions) or 0)
  local dmg = math.max(0, tonumber(j.damageDelta) or 0)
  local drivenKm = math.max(0, (tonumber(j.drivenM) or 0) / 1000.0)
  if not isFinite(drivenKm) then drivenKm = 0 end
  local curStreak = math.max(0, math.floor(tonumber(streak) or 0))
  local cleanRun = (skipped == 0 and sc >= 80)
  local streakApplied = cleanRun and math.min(5, curStreak + 1) or 0

  local basePay, timeBonus, smoothnessBonus, tipOrStreakBonus = 0, 0, 0, 0
  if mode == 'taxi' then
    local meter, tip = M.computeTaxiFare(j)
    if skipped > 0 then meter, tip = 0, 0 end
    basePay = round2(meter)
    if skipped == 0 and meter > 0 and tl >= 90 then
      timeBonus = round2(meter * ((tl - 85) / 15.0) * 0.12)
    end
    if skipped == 0 and meter > 0 and sm >= 75 then
      smoothnessBonus = round2(meter * ((sm - 75) / 25.0) * 0.10)
    end
    local streakBonus = (skipped == 0 and meter > 0 and streakApplied >= 2) and round2(streakApplied * 1.25) or 0
    tipOrStreakBonus = round2((tip or 0) + streakBonus)
  elseif mode == 'bus' then
    local tierMult = (tier == 'full') and 1.25 or 1.0
    basePay = round2((10.0 + stopsDone * 4.50 + drivenKm * 1.45) * tierMult)
    local schedAbs = math.abs(tonumber(j.scheduleDeltaS) or 0)
    if skipped == 0 and schedAbs <= 30 then
      timeBonus = round2(basePay * 0.15)
    elseif skipped == 0 and schedAbs <= 90 then
      timeBonus = round2(basePay * 0.06)
    end
    if sm >= 75 then
      smoothnessBonus = round2(basePay * ((sm - 75) / 25.0) * 0.12)
    end
    if cleanRun and streakApplied >= 2 then
      tipOrStreakBonus = round2(streakApplied * 2.00)
    end
  elseif mode == 'logistics' then
    local tierMult = LOGISTICS_TIER_MULT[tier] or 1.0
    local hauledT = math.max(0, (tonumber(j.totalCargoHauledKg) or tonumber(j.cargoKg) or 0) / 1000.0)
    local trailerBonus = (j.trailerOwnedByJob or j.playerOwnedTrailer or j.useTrailer) and 14.0 or 0.0
    basePay = round2((16.0 + trailerBonus + stopsDone * 6.0 + drivenKm * 1.85 + hauledT * 1.40) * tierMult)
    if skipped == 0 and tl >= 85 then
      timeBonus = round2(basePay * 0.10)
    end
    if sm >= 75 then
      smoothnessBonus = round2(basePay * ((sm - 75) / 25.0) * 0.14)
    end
    if cleanRun and streakApplied >= 2 then
      tipOrStreakBonus = round2(streakApplied * 3.00)
    end
  elseif mode == 'parcel' then
    local tierMult = PARCEL_TIER_MULT[tier] or 1.0
    local deliv = math.max(0, tonumber(j.parcelsDelivered) or 0)
    local ret = math.max(0, tonumber(j.parcelsReturned) or 0)
    basePay = round2((8.0 + deliv * 2.40 + ret * 2.80 + drivenKm * 1.35) * tierMult)
    if skipped == 0 then
      timeBonus = round2(basePay * 0.10)
    end
    if sm >= 75 then
      smoothnessBonus = round2(basePay * ((sm - 75) / 25.0) * 0.12)
    end
    if cleanRun and streakApplied >= 2 then
      tipOrStreakBonus = round2(streakApplied * 1.75)
    end
  end

  local rawGross = basePay + timeBonus + smoothnessBonus + tipOrStreakBonus
  local damagePenalty = round2(math.min(rawGross, collisions * 4.50 + math.min(25.0, dmg / 300.0) + skipped * 6.00))
  local totalEarned = round2(math.max(0, rawGross - damagePenalty))
  return {
    basePay = basePay,
    timeBonus = timeBonus,
    smoothnessBonus = smoothnessBonus,
    tipOrStreakBonus = tipOrStreakBonus,
    damagePenalty = damagePenalty,
    totalEarned = totalEarned,
    streakApplied = streakApplied,
  }
end

-- Pure: classify BeamNG vehicle into 'car'|'van'|'box_truck'|'semi' from GE/VE inspection metadata.
function M.classifyVehicle(info)
  info = type(info) == 'table' and info or {}
  local jb = type(info.jbeam) == 'string' and info.jbeam:lower() or ''
  local cfg = type(info.configName) == 'string' and info.configName:lower() or ''
  local mtype = type(info.modelType) == 'string' and info.modelType:lower() or ''
  local coupler = type(info.coupler) == 'string' and info.coupler:lower() or 'none'
  local massKg = tonumber(info.massKg)
  local lenM = tonumber(info.lengthM)
  local hasTrailer = info.hasTrailer == true

  if coupler ~= 'fifthwheel' and coupler ~= 'towhitch' then coupler = 'none' end

  local vclass = 'car'
  if jb == 'us_semi' or jb == 't_series' or coupler == 'fifthwheel'
      or (massKg and massKg >= 7000 and (lenM == nil or lenM >= 6.2)) then
    vclass = 'semi'
  elseif jb == 'md_series' or jb == 'citybus'
      or (jb == 'van' and ((massKg and massKg >= 3600) or cfg:find('box') or cfg:find('upfit') or cfg:find('ambulance')))
      or (massKg and massKg >= 3800) or (lenM and lenM >= 6.2) then
    vclass = 'box_truck'
  elseif jb == 'van' or jb == 'pickup' or jb == 'lansdale' or jb == 'stambecco'
      or mtype == 'van' or mtype == 'pickup' or mtype == 'truck'
      or (massKg and massKg >= 2200) or (lenM and lenM >= 4.85) then
    vclass = 'van'
  end

  return {
    class = vclass,
    massKg = massKg and math.floor(massKg + 0.5) or nil,
    coupler = coupler,
    hasTrailer = hasTrailer,
  }
end

-- Pure: human-readable vehicle match & coupler readiness summary for the job launcher.
function M.vehicleMatchInfo(info)
  info = type(info) == 'table' and info or {}
  local jb = type(info.jbeam) == 'string' and info.jbeam:lower() or ''
  local cl = M.classifyVehicle(info)
  local vehicleLabel = 'Passenger Car'
  local readiness = 'Ideal for Taxi & Light Parcel'
  local recommendedModes = { 'taxi', 'parcel' }

  if jb == 'citybus' then
    vehicleLabel = 'City Bus'
    readiness = 'Ideal for Bus Routes'
    recommendedModes = { 'bus' }
  elseif cl.class == 'semi' then
    if cl.hasTrailer then
      vehicleLabel = 'Semi Tractor + Trailer'
      readiness = 'Trailer Hitched · Ready for Heavy Freight'
    elseif cl.coupler == 'fifthwheel' then
      vehicleLabel = 'Semi Tractor (Fifth Wheel)'
      readiness = 'Ready for Heavy Trailers'
    else
      vehicleLabel = 'Heavy Commercial Truck'
      readiness = 'Ready for Regional Logistics'
    end
    recommendedModes = { 'logistics' }
  elseif cl.class == 'box_truck' then
    vehicleLabel = 'Box Truck / Medium Duty'
    readiness = cl.coupler == 'towhitch' and 'Tow Hitch · City & Regional Logistics' or 'Ideal for City Logistics & Parcel'
    recommendedModes = { 'logistics', 'parcel' }
  elseif cl.class == 'van' then
    vehicleLabel = 'Van / Pickup'
    if cl.hasTrailer then
      readiness = 'Trailer Hitched · Ready for Local Logistics'
    elseif cl.coupler == 'towhitch' then
      readiness = 'Tow Hitch · Parcel & Local Logistics'
    else
      readiness = 'Ideal for Parcel & Local Logistics'
    end
    recommendedModes = { 'parcel', 'logistics' }
  elseif cl.coupler == 'towhitch' then
    vehicleLabel = 'Passenger Car (Tow Hitch)'
    readiness = 'Taxi, Parcel & Light Utility Trailers'
    recommendedModes = { 'taxi', 'parcel', 'logistics' }
  end

  return {
    class = cl.class,
    coupler = cl.coupler,
    hasTrailer = cl.hasTrailer,
    vehicleLabel = vehicleLabel,
    readiness = readiness,
    recommendedModes = recommendedModes,
    summaryText = vehicleLabel .. ' · ' .. readiness,
  }
end

-- Pure: discover installed trailer models by coupler class ('fifthwheel' / 'towhitch').
function M.discoverTrailerModels(existsFn, modelListFn)
  existsFn = existsFn or M.modelExists
  local out = { fifthwheel = {}, towhitch = {}, seen = {} }
  local function add(kind, m)
    if type(m) ~= 'string' or m == '' or out.seen[kind .. ':' .. m] then return end
    if existsFn(m) then
      out.seen[kind .. ':' .. m] = true
      table.insert(out[kind], m)
    end
  end
  for _, m in ipairs(M.SEMI_TRAILER_MODELS) do add('fifthwheel', m) end
  for _, m in ipairs(M.TOWHITCH_TRAILER_MODELS) do add('towhitch', m) end

  local list = nil
  if type(modelListFn) == 'function' then
    local ok, res = pcall(modelListFn)
    if ok and type(res) == 'table' then list = res end
  else
    local cv = rawget(_G, 'core_vehicles')
    if cv and cv.getModelList then
      local ok, res = pcall(cv.getModelList)
      if ok and type(res) == 'table' then list = res end
    end
  end
  local models = list and (list.models or list)
  if type(models) == 'table' then
    local keys = {}
    for k, info in pairs(models) do
      if type(info) == 'table' and tostring(info.Type or ''):lower() == 'trailer' then
        keys[#keys + 1] = tostring(k)
      end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local kl = k:lower()
      if kl:find('dryvan') or kl:find('reefer') or kl:find('tanker') or kl:find('flatbed')
          or kl:find('container') or kl:find('dump') or kl:find('semi') or kl:find('lowboy')
          or kl:find('log') or kl:find('boxtrailer') then
        add('fifthwheel', k)
      elseif kl:find('utility') or kl:find('cargo') or kl:find('tsfb') or kl:find('hitch') then
        add('towhitch', k)
      end
    end
  end
  return out
end

-- Pure: discover installed BeamNG 3D cargo prop models (parcel boxes + crates/pallets).
function M.discoverCargoPropModels(existsFn, modelListFn)
  existsFn = existsFn or M.modelExists
  local out = { parcel = {}, crate = {}, seen = {} }
  local function add(bucket, m)
    if type(m) ~= 'string' or m == '' or out.seen[bucket .. ':' .. m] then return end
    if existsFn(m) then
      out.seen[bucket .. ':' .. m] = true
      table.insert(out[bucket], m)
    end
  end
  for _, m in ipairs(M.PARCEL_PROP_MODELS) do add('parcel', m) end
  for _, m in ipairs(M.CRATE_PROP_MODELS) do add('crate', m) end

  local list = nil
  if type(modelListFn) == 'function' then
    local ok, res = pcall(modelListFn)
    if ok and type(res) == 'table' then list = res end
  else
    local cv = rawget(_G, 'core_vehicles')
    if cv and cv.getModelList then
      local ok, res = pcall(cv.getModelList)
      if ok and type(res) == 'table' then list = res end
    end
  end
  local models = list and (list.models or list)
  if type(models) == 'table' then
    local keys = {}
    for k, info in pairs(models) do
      if type(info) == 'table' then
        local tp = tostring(info.Type or ''):lower()
        local kl = tostring(k):lower()
        if tp == 'prop' or kl:find('cardboard') or kl:find('woodcrate') or kl:find('cargo_load_box') or kl:find('pallet') then
          keys[#keys + 1] = tostring(k)
        end
      end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local kl = k:lower()
      if kl:find('cardboard') or kl:find('cargo_load_box') then
        add('parcel', k)
        add('crate', k)
      elseif kl:find('woodcrate') or kl:find('pallet') or kl:find('crate') then
        add('crate', k)
      end
    end
  end
  return out
end

-- Pure: compute safe interior/bed local cargo volume bounds for a vehicle or open trailer.
-- Local coordinates: +x = right, +y = forward, +z = up relative to vehicle center/floor.
-- Returns nil when vehicle has no safe interior/bed clearance (triggers pure node-mass fallback).
function M.computeCargoBayBounds(info)
  if type(info) ~= 'table' then return nil end
  local jb = type(info.jbeam) == 'string' and info.jbeam:lower() or ''
  local mtype = type(info.modelType) == 'string' and info.modelType:lower() or ''
  local cfg = type(info.configName) == 'string' and info.configName:lower() or ''
  local lenM = tonumber(info.lengthM)
  local widM = tonumber(info.widthM)
  local halfL = lenM and (lenM * 0.5) or nil
  local halfW = widM and math.max(0.45, widM * 0.5 - 0.28) or nil

  -- Open trailers
  if jb == 'boxutility' then
    return { halfW = 0.60, yMin = -0.95, yMax = 0.80, zFloor = 0.48, maxProps = 4, layers = 1, kind = 'crate' }
  elseif jb == 'boxutility_large' then
    return { halfW = 0.78, yMin = -1.45, yMax = 1.25, zFloor = 0.52, maxProps = 6, layers = 1, kind = 'crate' }
  elseif jb == 'tsfb' then
    return { halfW = 0.86, yMin = -1.90, yMax = 1.55, zFloor = 0.60, maxProps = 6, layers = 1, kind = 'crate' }
  elseif jb == 'flatbed' then
    return { halfW = 1.02, yMin = -4.80, yMax = 4.20, zFloor = 1.30, maxProps = 8, layers = 1, kind = 'crate' }
  end
  if info.isTrailer then return nil end

  -- Vans & box trucks
  if jb == 'md_series' or (jb == 'van' and (cfg:find('box') or cfg:find('upfit') or (lenM and lenM >= 6.0))) then
    local hl = halfL or 3.3
    return { halfW = math.min(0.88, halfW or 0.85), yMin = -hl + 0.55, yMax = 0.35, zFloor = 0.78, maxProps = 8, layers = 2, kind = 'parcel' }
  elseif jb == 'van' or jb == 'stambecco' or mtype == 'van' then
    local hl = halfL or 2.65
    return { halfW = math.min(0.72, halfW or 0.70), yMin = -hl + 0.48, yMax = -0.20, zFloor = 0.58, maxProps = 6, layers = 2, kind = 'parcel' }
  end

  -- Pickups (open bed)
  if jb == 'pickup' or jb == 'dseries' or mtype == 'pickup' or mtype == 'truck' then
    local hl = halfL or 2.75
    return { halfW = math.min(0.68, halfW or 0.66), yMin = -hl + 0.42, yMax = -0.45, zFloor = 0.76, maxProps = 6, layers = 1, kind = 'parcel' }
  end

  -- Hatchbacks, wagons, SUVs, vans/MPVs (compact trunk/cargo bay)
  if jb == 'lansdale' or jb == 'roamer' or jb == 'vivace' or jb == 'covet' or jb == 'legran' or jb == 'pessima'
      or mtype == 'hatchback' or mtype == 'wagon' or mtype == 'suv' or (lenM and lenM >= 4.0) then
    local hl = halfL or 2.25
    return { halfW = math.min(0.48, halfW or 0.46), yMin = -hl + 0.45, yMax = -hl + 1.15, zFloor = 0.56, maxProps = 3, layers = 1, kind = 'parcel' }
  end

  return nil
end

-- Pure: generate local-frame { lx, ly, lz } slots ordered front-to-rear / bottom-to-top
-- (so despawning from the tail removes rearmost/topmost props first).
function M.cargoPropSlots(bounds, count, itemSize)
  if type(bounds) ~= 'table' then return {} end
  count = math.min(math.max(0, math.floor(tonumber(count) or 0)), math.min(bounds.maxProps or M.MAX_CARGO_PROPS, M.MAX_CARGO_PROPS))
  if count <= 0 then return {} end
  local sz = tonumber(itemSize) or 0.52
  local margin = 0.14
  local xSpan = math.max(0.0, (bounds.halfW or 0.6) - sz * 0.5)
  local nCols = (xSpan >= sz * 0.42) and 2 or 1
  local yMin = bounds.yMin or -1.2
  local yMax = bounds.yMax or 0.0
  local yLen = math.max(0.2, yMax - yMin)
  local nRows = math.max(1, math.floor((yLen + margin) / (sz + margin)))
  local maxLayers = math.max(1, tonumber(bounds.layers) or 1)
  local zBase = bounds.zFloor or 0.55

  local slots = {}
  for layer = 0, maxLayers - 1 do
    for r = 0, nRows - 1 do
      local ty = (nRows == 1) and 0.5 or (r / (nRows - 1))
      -- Front-to-rear so tail removal unloads from the tailgate/doors first
      local ly = yMax - ty * (yMax - yMin)
      for c = 0, nCols - 1 do
        local lx = (nCols == 1) and 0.0 or ((c == 0 and -1 or 1) * math.min(xSpan, sz * 0.55))
        slots[#slots + 1] = {
          lx = lx,
          ly = ly,
          lz = zBase + layer * (sz + 0.06),
        }
        if #slots >= count then return slots end
      end
    end
  end
  return slots
end

-- Pure: map remaining parcel/cargo units to desired visible 3D prop count in [0..initialProps].
function M.desiredCargoPropCount(remaining, total, initialProps)
  local init = math.max(0, math.floor(tonumber(initialProps) or 0))
  local rem = math.max(0, tonumber(remaining) or 0)
  local tot = math.max(0, tonumber(total) or 0)
  if init == 0 or rem <= 0 or tot <= 0 then return 0 end
  if rem >= tot then return init end
  return math.max(1, math.min(init, math.ceil((rem / tot) * init)))
end

-- Pure: pick best installed trailer JBeam model for coupler + cargo domain/type/tier.
function M.pickTrailerModel(coupler, cargoType, tier, existsFn, cargoDomain, seed, discovered)
  existsFn = existsFn or M.modelExists
  local list
  if coupler == 'fifthwheel' then
    local fw = M.TRAILER_CANDIDATES.fifthwheel
    list = fw[cargoType] or fw[cargoDomain] or fw.default
    local avail = {}
    for _, m in ipairs(list) do
      if existsFn(m) then avail[#avail + 1] = m end
    end
    if #avail == 0 and discovered and type(discovered.fifthwheel) == 'table' then
      for _, m in ipairs(discovered.fifthwheel) do
        if existsFn(m) then avail[#avail + 1] = m end
      end
    end
    if #avail == 0 then return nil end
    -- Prefer primary domain match; when multiple match and seed is given, vary among top 2
    if seed and #avail > 1 and not (cargoType == 'fuel' or cargoDomain == 'fuel') then
      local idx = (math.floor(tonumber(seed) or 0) % math.min(2, #avail)) + 1
      return avail[idx]
    end
    return avail[1]
  elseif coupler == 'towhitch' then
    local tw = M.TRAILER_CANDIDATES.towhitch
    list = (tier == 'city' or tier == 'regional' or tier == 'long') and tw.heavy or tw.light
    local avail = {}
    for _, m in ipairs(list) do
      if existsFn(m) then avail[#avail + 1] = m end
    end
    if #avail == 0 and discovered and type(discovered.towhitch) == 'table' then
      for _, m in ipairs(discovered.towhitch) do
        if existsFn(m) then avail[#avail + 1] = m end
      end
    end
    if #avail == 0 then return nil end
    if seed then
      local idx = (math.floor(tonumber(seed) or 0) % #avail) + 1
      return avail[idx]
    end
    return avail[1]
  end
  return nil
end

-- Pure: generate candidate station-bay trailer spawn poses oriented along stop bearing.
function M.stationTrailerPose(sx, sy, gz, fx, fy, rx, ry, tHalf)
  local l = math.sqrt(fx * fx + fy * fy)
  if l < 1e-6 then fx, fy = 0, 1 else fx, fy = fx / l, fy / l end
  if not rx or not ry then rx, ry = fy, -fx end
  tHalf = tonumber(tHalf) or 3.5
  local offsets = {
    { 0.0, 0.0, 'bay' },
    { -1.2, 0.0, 'bay_back' },
    { 2.0, 0.0, 'bay_fwd' },
    { 0.0, 3.6, 'bay_right' },
    { 0.0, -3.6, 'bay_left' },
  }
  local out = {}
  for _, o in ipairs(offsets) do
    out[#out + 1] = {
      mode = o[3],
      x = sx + fx * o[1] + rx * o[2],
      y = sy + fy * o[1] + ry * o[2],
      z = gz,
      dirX = fx,
      dirY = fy,
      halfL = tHalf,
    }
  end
  return out
end

-- Pure: distance (m) between player rear hitch/fifthwheel and trailer front kingpin/tongue.
function M.hitchDistanceM(px, py, pfx, pfy, pHalf, tx, ty, tfx, tfy, tHalf, coupler)
  local pl = math.sqrt(pfx * pfx + pfy * pfy)
  if pl < 1e-6 then pfx, pfy = 0, 1 else pfx, pfy = pfx / pl, pfy / pl end
  local tl = math.sqrt(tfx * tfx + tfy * tfy)
  if tl < 1e-6 then tfx, tfy = 0, 1 else tfx, tfy = tfx / tl, tfy / tl end
  local hitchFrac = (coupler == 'fifthwheel') and 0.60 or 0.90
  local hx = px - pfx * ((tonumber(pHalf) or 2.6) * hitchFrac)
  local hy = py - pfy * ((tonumber(pHalf) or 2.6) * hitchFrac)
  local kx = tx + tfx * ((tonumber(tHalf) or 3.5) * 0.85)
  local ky = ty + tfy * ((tonumber(tHalf) or 3.5) * 0.85)
  return math.sqrt((hx - kx) ^ 2 + (hy - ky) ^ 2)
end

-- Pure: true when a dropped job-owned trailer is far enough (> 80 m) to despawn cleanly.
function M.shouldDespawnTrailer(distM)
  return type(distM) == 'number' and distM == distM and distM > M.DESPAWN_DIST_M
end

-- Pure: generate candidate trailer spawn positions (rear primary + forward/lane-aligned fallbacks).
function M.trailerSpawnCandidates(px, py, pz, fx, fy, playerHalfLen, trailerHalfLen)
  local l = math.sqrt(fx * fx + fy * fy)
  if l < 1e-6 then fx, fy = 0, 1 else fx, fy = fx / l, fy / l end
  local pHalf = tonumber(playerHalfLen) or 2.6
  local tHalf = tonumber(trailerHalfLen) or 3.5
  local backDist = pHalf + tHalf + 1.4
  local out = {}
  for _, deg in ipairs({ 0, 15, -15, 30, -30 }) do
    local rad = math.rad(deg)
    local c, s = math.cos(rad), math.sin(rad)
    local dfx, dfy = fx * c - fy * s, fx * s + fy * c
    out[#out + 1] = {
      mode = 'rear',
      x = px - dfx * backDist,
      y = py - dfy * backDist,
      z = pz,
      dirX = dfx,
      dirY = dfy,
      dist = backDist,
      backDist = backDist,
      angleDeg = deg,
    }
  end
  -- Forward & adjacent-lane fallback spots when rear space is tight
  local rx, ry = fy, -fx
  local frontDist = pHalf + tHalf + 2.4
  out[#out + 1] = {
    mode = 'front',
    x = px + fx * frontDist,
    y = py + fy * frontDist,
    z = pz,
    dirX = fx,
    dirY = fy,
    dist = frontDist,
    backDist = frontDist,
    angleDeg = 0,
  }
  for _, latOff in ipairs({ 3.8, -3.8 }) do
    out[#out + 1] = {
      mode = 'lane',
      x = px + rx * latOff,
      y = py + ry * latOff,
      z = pz,
      dirX = fx,
      dirY = fy,
      dist = math.abs(latOff),
      backDist = math.abs(latOff),
      angleDeg = 0,
    }
  end
  return out
end

-- Pure: Vehicle Lua command to apply or restore cargo mass on non-wheel structural nodes.
function M.buildCargoVeScript(targetKg)
  targetKg = math.max(0, tonumber(targetKg) or 0)
  return string.format([[
local targetKg = %.3f
local function initCargoBase()
  local ex = rawget(_G, 'bngeCargoBase')
  if type(ex) == 'table' and ex.count and ex.count > 0 then return ex end
  if not (v and v.data and type(v.data.nodes) == 'table' and obj and obj.getNodeMass) then return nil end
  local wheelNodes = {}
  if wheels and type(wheels.wheels) == 'table' then
    for _, wd in pairs(wheels.wheels) do
      if type(wd) == 'table' then
        if tonumber(wd.node1) then wheelNodes[tonumber(wd.node1)] = true end
        if tonumber(wd.node2) then wheelNodes[tonumber(wd.node2)] = true end
        for _, tblName in ipairs({ 'nodes', 'treadNodes', 'sideNodes' }) do
          if type(wd[tblName]) == 'table' then
            for k, val in pairs(wd[tblName]) do
              local nid = tonumber(type(val) == 'table' and (val.cid or val.nodeId or val.id) or val)
              if not nid and type(val) == 'boolean' then nid = tonumber(k) end
              if nid then wheelNodes[nid] = true end
            end
          end
        end
      end
    end
  end
  local function collect(minMass)
    local base, sum, count = {}, 0, 0
    for _, nd in pairs(v.data.nodes) do
      if type(nd) == 'table' and tonumber(nd.cid) then
        local cid = tonumber(nd.cid)
        if not wheelNodes[cid] and not nd.couplerTag then
          local ok, m0 = pcall(obj.getNodeMass, obj, cid)
          if ok and type(m0) == 'number' and m0 >= minMass and m0 < 1e5 then
            base[cid] = m0
            sum = sum + m0
            count = count + 1
          end
        end
      end
    end
    return base, sum, count
  end
  local base, sum, count = collect(3.0)
  if count < 6 then base, sum, count = collect(1.5) end
  if count == 0 then return nil end
  local rec = { base = base, sum = sum, count = count }
  rawset(_G, 'bngeCargoBase', rec)
  return rec
end
local rec = initCargoBase()
if rec and rec.sum > 0 then
  for cid, m0 in pairs(rec.base) do
    local m = m0
    if targetKg > 0 then
      local add = targetKg * (m0 / rec.sum)
      m = math.min(m0 * 12.0, m0 + add)
    end
    pcall(obj.setNodeMass, obj, cid, m)
  end
end]], targetKg)
end
M.CARGO_MASS_VE = M.buildCargoVeScript

local PROBE_VE = [[
local totalMass, coupler, couplerCid = 0, 'none', -1
if v and v.data and type(v.data.nodes) == 'table' and obj and obj.getNodeMass then
  for _, nd in pairs(v.data.nodes) do
    if type(nd) == 'table' and tonumber(nd.cid) then
      local ok, m = pcall(obj.getNodeMass, obj, tonumber(nd.cid))
      if ok and type(m) == 'number' and m > 0 and m < 1e5 then totalMass = totalMass + m end
      if type(nd.couplerTag) == 'string' then
        local tag = nd.couplerTag:lower()
        if tag:find('fifthwheel') or tag:find('fifth_wheel') or tag:find('semitrailer') then
          coupler, couplerCid = 'fifthwheel', tonumber(nd.cid)
        elseif coupler == 'none' and (tag:find('towhitch') or tag:find('tow_hitch') or tag:find('pintle') or tag:find('hitch')) then
          coupler, couplerCid = 'towhitch', tonumber(nd.cid)
        end
      end
    end
  end
end
if coupler == 'none' and v and v.config and type(v.config.parts) == 'table' then
  for slot, part in pairs(v.config.parts) do
    local s = tostring(slot or ''):lower()
    local p = tostring(part or ''):lower()
    if p ~= '' and p ~= 'none' and p ~= 'empty' then
      if s:find('fifthwheel') or p:find('fifthwheel') or p:find('fifth_wheel') then
        coupler = 'fifthwheel'
        break
      elseif s:find('towhitch') or p:find('towhitch') or p:find('pintle') or p:find('_hitch') then
        coupler = 'towhitch'
      end
    end
  end
end
local att = (beamstate and beamstate.isCouplerAttached and beamstate.isCouplerAttached())
  or (extensions and extensions.couplings and extensions.couplings.isCouplerAttached and extensions.couplings.isCouplerAttached())
  or false
local payload = string.format('{massKg=%.1f,coupler=%q,couplerCid=%d,attached=%s}', totalMass, coupler, couplerCid, tostring(att == true))
obj:queueGameEngineLua('if beamngEarth_transportModes and beamngEarth_transportModes._onVehicleProbe then beamngEarth_transportModes._onVehicleProbe(' .. obj:getID() .. ',' .. payload .. ') end')
]]
M.PROBE_VE = PROBE_VE

-- Vehicle Lua snippet: read live liquid fuel ratio & tank capacity via energyStorage (with electrics fallback).
local FUEL_READ_VE = [[
local ratio, capL, volL, hasTank = -1, 0, 0, false
if energyStorage and energyStorage.getStorages then
  local ok, storages = pcall(energyStorage.getStorages)
  if ok and type(storages) == 'table' then
    for _, s in pairs(storages) do
      if type(s) == 'table' then
        local et = tostring(s.energyType or ''):lower()
        if et == 'gasoline' or et == 'diesel' or et == 'kerosine' then
          local c = tonumber(s.capacity) or 0
          local v = tonumber(s.remainingVolume)
          local r = tonumber(s.remainingRatio)
          if c > 0 then
            capL = capL + c
            volL = volL + (v or (r and (r * c) or 0))
            hasTank = true
          end
        end
      end
    end
  end
end
if hasTank and capL > 0 then
  ratio = math.max(0, math.min(1, volL / capL))
elseif electrics and electrics.values and type(electrics.values.fuel) == 'number' then
  ratio = math.max(0, math.min(1, electrics.values.fuel))
  capL = tonumber(electrics.values.fuelCapacity) or 55.0
  volL = tonumber(electrics.values.fuelVolume) or (ratio * capL)
  hasTank = true
end
local payload = string.format('{ratio=%.5f,capacityL=%.2f,volumeL=%.2f,hasTank=%s}', ratio, capL, volL, tostring(hasTank))
obj:queueGameEngineLua('if beamngEarth_transportModes and beamngEarth_transportModes._onFuelProbe then beamngEarth_transportModes._onFuelProbe(' .. obj:getID() .. ',' .. payload .. ') end')
]]
M.FUEL_READ_VE = FUEL_READ_VE

-- Pure: Vehicle Lua command to set liquid energyStorage fuel ratio smoothly.
function M.buildRefuelVeScript(targetRatio)
  local r = math.max(0.0, math.min(1.0, tonumber(targetRatio) or 0.0))
  return string.format([[
local targetRatio = %.5f
local applied = false
if energyStorage and energyStorage.getStorages then
  local ok, storages = pcall(energyStorage.getStorages)
  if ok and type(storages) == 'table' then
    for _, s in pairs(storages) do
      if type(s) == 'table' then
        local et = tostring(s.energyType or ''):lower()
        if et == 'gasoline' or et == 'diesel' or et == 'kerosine' then
          if type(s.setRemainingRatio) == 'function' then
            pcall(s.setRemainingRatio, s, targetRatio)
            applied = true
          elseif type(s.setRemainingVolume) == 'function' and tonumber(s.capacity) then
            pcall(s.setRemainingVolume, s, tonumber(s.capacity) * targetRatio)
            applied = true
          end
        end
      end
    end
  end
end
if not applied and electrics and electrics.values then
  electrics.values.fuel = targetRatio
end]], r)
end

-- Pure: true when nearby fuel stations should be re-queried (>= 6 s or > 400 m movement).
function M.shouldQueryFuelStations(lastAt, lastLat, lastLon, now, lat, lon)
  if not (isFinite(lat) and isFinite(lon)) then return false end
  if not lastAt or not lastLat or not lastLon then return true end
  if (now - lastAt) >= M.FUEL_QUERY_INTERVAL_S then return true end
  return M.haversineM(lastLat, lastLon, lat, lon) > M.FUEL_QUERY_MOVE_M
end

-- Pure: compass bearing (0 = N, 90 = E) from (lat1, lon1) to (lat2, lon2).
function M.bearingDeg(lat1, lon1, lat2, lon2)
  local k = math.max(0.05, math.cos(math.rad((lat1 + lat2) * 0.5)))
  local dx = (lon2 - lon1) * 111320.0 * k
  local dy = (lat2 - lat1) * 111320.0
  if math.abs(dx) < 1e-9 and math.abs(dy) < 1e-9 then return 0 end
  return math.floor(((math.deg(math.atan2(dx, dy)) + 360) % 360) * 10 + 0.5) / 10
end

local CARDINALS = { 'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW' }
function M.cardinalOf(deg)
  local idx = (math.floor(((tonumber(deg) or 0) % 360) / 45 + 0.5) % 8) + 1
  return CARDINALS[idx] or 'N'
end

-- Pure: find nearest fuel station to (lat, lon) with live distM & compass bearingDeg.
function M.nearestFuelStation(stations, lat, lon)
  if type(stations) ~= 'table' or #stations == 0 then return nil end
  local hasPos = isFinite(lat) and isFinite(lon)
  local best, bestD = nil, math.huge
  for i = 1, #stations do
    local s = stations[i]
    if s and isFinite(s.lat) and isFinite(s.lon) then
      local d = hasPos and M.haversineM(lat, lon, s.lat, s.lon) or (tonumber(s.distM) or math.huge)
      if d < bestD then
        bestD = d
        best = s
      end
    end
  end
  if not best then return nil end
  local brg = hasPos and M.bearingDeg(lat, lon, best.lat, best.lon) or (tonumber(best.bearingDeg) or 0)
  return {
    id = best.id,
    name = best.name or 'Local Fuel Station',
    brand = best.brand or '',
    lat = best.lat,
    lon = best.lon,
    distM = math.floor(bestD + 0.5),
    bearingDeg = brg,
    cardinal = M.cardinalOf(brg),
    pricePerLiter = tonumber(best.pricePerLiter) or 1.79,
    locality = best.locality or '',
  }
end

-- Pure: advance pump-bay hold & smooth refueling + career overdraft protection.
-- Returns state, deltaLiters, deltaCost, newRatio, event ('idle'|'holding'|'refueling'|'full'|'overdraft'|'stopped').
function M.stepFuelRefuel(state, inPumpBay, speed, fuelRatio, tankCapL, pricePerLiter, careerEarnings, dtSim, paused)
  state = state or { holdS = 0, active = false, done = false, litersAdded = 0, costTotal = 0, overdraftHit = false }
  local ratio = math.max(0.0, math.min(1.0, tonumber(fuelRatio) or 0.0))
  local cap = math.max(10.0, tonumber(tankCapL) or 55.0)
  local price = math.max(0.5, tonumber(pricePerLiter) or 1.79)
  local earn = tonumber(careerEarnings) or 0.0

  if paused or not dtSim or dtSim <= 0 then
    return state, 0, 0, ratio, state.active and 'refueling' or (state.holdS > 0 and 'holding' or 'idle')
  end

  if not inPumpBay or (tonumber(speed) or 0) >= M.FUEL_STOP_SPEED_MPS then
    local wasActive = state.active
    state.holdS = 0
    state.active = false
    if wasActive then
      state.done = true
      return state, 0, 0, ratio, 'stopped'
    end
    return state, 0, 0, ratio, 'idle'
  end

  if ratio >= 0.995 then
    local wasActive = state.active
    state.holdS = 0
    state.active = false
    if wasActive then
      state.done = true
      return state, 0, 0, 1.0, 'full'
    end
    return state, 0, 0, ratio, 'idle'
  end

  if not state.active then
    state.holdS = (state.holdS or 0) + dtSim
    if state.holdS < M.FUEL_STOP_HOLD_S then
      return state, 0, 0, ratio, 'holding'
    end
    state.active = true
    state.done = false
    state.overdraftHit = false
  end

  local avail = earn - M.FUEL_OVERDRAFT_LIMIT
  if avail <= 1e-4 then
    state.active = false
    state.done = true
    state.overdraftHit = true
    return state, 0, 0, ratio, 'overdraft'
  end

  local dRatio = math.min(1.0 - ratio, M.FUEL_RATE_RATIO_PER_S * dtSim)
  local dLiters = math.max(dRatio * cap, math.min((1.0 - ratio) * cap, M.FUEL_RATE_LITERS_PER_S * dtSim))
  -- Keep ratio and liters synchronized to tank capacity
  dRatio = math.min(1.0 - ratio, dLiters / cap)
  dLiters = dRatio * cap
  local dCost = dLiters * price
  local hitOverdraft = false
  if dCost > avail then
    local scale = avail / dCost
    dLiters = dLiters * scale
    dRatio = dRatio * scale
    dCost = avail
    hitOverdraft = true
  end

  local newRatio = math.min(1.0, ratio + dRatio)
  state.litersAdded = (state.litersAdded or 0) + dLiters
  state.costTotal = (state.costTotal or 0) + dCost

  if hitOverdraft then
    state.active = false
    state.done = true
    state.overdraftHit = true
    return state, dLiters, dCost, newRatio, 'overdraft'
  end
  if newRatio >= 0.999 then
    state.active = false
    state.done = true
    return state, dLiters, dCost, 1.0, 'full'
  end
  return state, dLiters, dCost, newRatio, 'refueling'
end

local function clearOwnedGps()
  if not gpsTarget then return end
  local ok, g = pcall(M.gps)
  if ok and g and g.status and g.clear then
    local s = g.status()
    if s and s.lat and s.lon
        and math.abs(s.lat - gpsTarget.lat) < 1e-4 and math.abs(s.lon - gpsTarget.lon) < 1e-4 then
      pcall(g.clear)
    end
  end
  gpsTarget = nil
end

local function syncGpsToStop(stop, idx, total)
  if not stop then return end
  local ok, g = pcall(M.gps)
  if ok and g and g.setDestination then
    local label = string.format('[%d/%d] %s', idx, total, stop.name or 'Stop')
    if pcall(g.setDestination, stop.lat, stop.lon, label, { managed = true }) then
      gpsTarget = { lat = stop.lat, lon = stop.lon }
    end
  end
end

local function playerPose()
  local c = M.core()
  local st = c and c._state and c._state()
  local pl = st and st.player
  local heading = nil
  local veh = M.playerVeh()
  if veh and veh.getDirectionVector then
    local ok, dir = pcall(function() return veh:getDirectionVector() end)
    if ok and dir and math.abs(dir.x) + math.abs(dir.y) >= 1e-6 then
      heading = (math.deg(math.atan2(dir.x, dir.y)) + 360) % 360
      local a = st and st.anchor
      if a and a.northAt and pl then
        local okN, nx, ny = pcall(a.northAt, a, pl.x or 0, pl.y or 0)
        if okN and tonumber(nx) and tonumber(ny) then
          heading = (heading - math.deg(math.atan2(nx, ny)) + 360) % 360
        end
      end
    end
  end
  return st, pl, heading
end

local function findAttachedTrailerId(vehId)
  local tr = rawget(_G, 'core_trailerRespawn')
  if type(tr) == 'table' and type(tr.getTrailerData) == 'function' then
    local ok, reg = pcall(tr.getTrailerData)
    if ok and type(reg) == 'table' and type(reg[vehId]) == 'table' then
      local tid = tonumber(reg[vehId].trailerId)
      if tid and rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(tid) then
        return tid
      end
    end
  end
  return nil
end

local function inspectGeVehicle()
  local veh = M.playerVeh()
  if not veh then return {} end
  local id = vehIdOf(veh)
  local jbeam = (veh.getJBeamFilename and veh:getJBeamFilename()) or veh.JBeam or ''
  local lenM = nil
  if veh.getSpawnWorldOOBB then
    local okO, oobb = pcall(veh.getSpawnWorldOOBB, veh)
    if okO and oobb and oobb.getHalfExtents then
      local okE, ext = pcall(oobb.getHalfExtents, oobb)
      if okE and ext then lenM = math.max(tonumber(ext.x) or 0, tonumber(ext.y) or 0) * 2 end
    end
  end
  local mtype, cfgName, geCoupler = '', '', 'none'
  local cv = rawget(_G, 'core_vehicles')
  if cv and cv.getCurrentVehicleDetails then
    local okD, det = pcall(cv.getCurrentVehicleDetails)
    if okD and type(det) == 'table' then
      mtype = det.model and tostring(det.model.Type or '') or ''
      cfgName = det.configs and tostring(det.configs.Name or '') or ''
      if jbeam == '' and det.model and det.model.key then jbeam = tostring(det.model.key) end
      local parts = (det.current and det.current.parts) or (det.configs and det.configs.parts)
      if type(parts) == 'table' then
        for slot, part in pairs(parts) do
          local s = tostring(slot or ''):lower()
          local p = tostring(part or ''):lower()
          if p ~= '' and p ~= 'none' and p ~= 'empty' then
            if s:find('fifthwheel') or p:find('fifthwheel') then
              geCoupler = 'fifthwheel'
              break
            elseif s:find('towhitch') or p:find('towhitch') or p:find('pintle') then
              geCoupler = 'towhitch'
            end
          end
        end
      end
    end
  end
  local attId = id and findAttachedTrailerId(id) or nil
  return {
    vehId = id,
    jbeam = jbeam,
    modelType = mtype,
    configName = cfgName,
    lengthM = lenM,
    coupler = geCoupler,
    hasTrailer = attId ~= nil,
    attachedTrailerId = attId,
  }
end

local function applyCargoMassToId(targetId, kg)
  if not targetId then return false end
  kg = math.max(0, tonumber(kg) or 0)
  local obj = rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(targetId)
  if obj and obj.queueLuaCommand then
    pcall(obj.queueLuaCommand, obj, M.buildCargoVeScript(kg))
    return true
  end
  return false
end

local function applyCargoMassToJob(j, kg)
  if not j then return end
  kg = math.max(0, tonumber(kg) or 0)
  local propKg = 0
  if type(j.cargoProps) == 'table' then
    for _, pr in ipairs(j.cargoProps) do
      propKg = propKg + (tonumber(pr.estMassKg) or 0)
    end
  end
  local nodeKg = math.max(0, kg - propKg)
  local targetId = j.trailerId or vehIdOf(M.playerVeh())
  if not targetId then return end
  if applyCargoMassToId(targetId, nodeKg) then
    j.cargoAppliedKg = nodeKg
  elseif j.trailerId then
    local pvId = vehIdOf(M.playerVeh())
    if pvId and applyCargoMassToId(pvId, nodeKg) then
      j.cargoAppliedKg = nodeKg
    end
  end
end

local function deleteObjectById(id)
  if not id then return false end
  local trl = (rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(id))
    or (rawget(_G, 'be') and be.getObjectByID and be:getObjectByID(id))
  if trl and trl.delete then
    pcall(function() trl:delete() end)
    return true
  end
  return false
end

local function cleanupCargoProps(j)
  if not j or type(j.cargoProps) ~= 'table' then return end
  for i = #j.cargoProps, 1, -1 do
    local pr = j.cargoProps[i]
    if pr and pr.id then
      deleteObjectById(pr.id)
    end
    j.cargoProps[i] = nil
  end
  j.cargoPropsInitial = 0
end

local function despawnCargoProps(j, removeCount)
  if not j or type(j.cargoProps) ~= 'table' then return 0 end
  local n = math.max(0, math.floor(tonumber(removeCount) or 0))
  local removed = 0
  while removed < n and #j.cargoProps > 0 do
    local pr = table.remove(j.cargoProps)
    if pr and pr.id then deleteObjectById(pr.id) end
    removed = removed + 1
  end
  return removed
end

local function syncCargoPropCount(j, targetCount)
  if not j or type(j.cargoProps) ~= 'table' then return 0 end
  local want = math.max(0, math.floor(tonumber(targetCount) or 0))
  if #j.cargoProps <= want then return 0 end
  return despawnCargoProps(j, #j.cargoProps - want)
end

local function spawnCargoPropsForTarget(j, targetVeh, count, propBucket, isTrailer, modelOverride)
  if not j or not targetVeh then return 0 end
  local cv = rawget(_G, 'core_vehicles')
  if not (cv and cv.spawnNewVehicle) then return 0 end
  local jb = modelOverride or (targetVeh.getJBeamFilename and targetVeh:getJBeamFilename()) or targetVeh.JBeam or ''
  local lenM, widM = nil, nil
  local center, fwd, right, up = nil, nil, nil, nil
  if targetVeh.getSpawnWorldOOBB then
    local okO, oobb = pcall(targetVeh.getSpawnWorldOOBB, targetVeh)
    if okO and oobb then
      if oobb.getHalfExtents then
        local okE, ext = pcall(oobb.getHalfExtents, oobb)
        if okE and ext then
          local ex, ey = math.abs(tonumber(ext.x) or 0), math.abs(tonumber(ext.y) or 0)
          lenM = math.max(ex, ey) * 2
          widM = math.min(ex, ey) * 2
        end
      end
      if oobb.getCenter then
        local okC, c = pcall(oobb.getCenter, oobb)
        if okC and c then center = c end
      end
    end
  end
  if not center and targetVeh.getPosition then
    local okP, p = pcall(targetVeh.getPosition, targetVeh)
    if okP and p then center = p end
  end
  if targetVeh.getDirectionVector then
    local okD, d = pcall(targetVeh.getDirectionVector, targetVeh)
    if okD and d then fwd = d end
  end
  if targetVeh.getDirectionVectorUp then
    local okU, u = pcall(targetVeh.getDirectionVectorUp, targetVeh)
    if okU and u then up = u end
  end
  if not center or not fwd then return 0 end
  if not up then up = vec3(0, 0, 1) end
  local fLen = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
  if fLen < 1e-6 then return 0 end
  local fx, fy, fz = fwd.x / fLen, fwd.y / fLen, fwd.z / fLen
  local ux, uy, uz = up.x, up.y, up.z
  local rx, ry, rz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
  local rLen = math.sqrt(rx * rx + ry * ry + rz * rz)
  if rLen < 1e-6 then rx, ry, rz = fy, -fx, 0 else rx, ry, rz = rx / rLen, ry / rLen, rz / rLen end

  local ge = (not isTrailer) and inspectGeVehicle() or {}
  local bounds = M.computeCargoBayBounds({
    jbeam = jb,
    modelType = ge.modelType,
    configName = ge.configName,
    lengthM = lenM or ge.lengthM,
    widthM = widM,
    isTrailer = isTrailer == true,
  })
  if not bounds then return 0 end

  local disc = M.discoverCargoPropModels()
  local bucket = propBucket or bounds.kind or 'parcel'
  local models = disc[bucket]
  if not models or #models == 0 then
    models = (bucket == 'parcel') and disc.crate or disc.parcel
  end
  if not models or #models == 0 then return 0 end

  local itemSz = (bucket == 'crate') and 0.65 or 0.48
  local slots = M.cargoPropSlots(bounds, count, itemSz)
  if #slots == 0 then return 0 end

  j.cargoProps = j.cargoProps or {}
  local rot = quatFromDir(vec3(fx, fy, 0):normalized(), vec3(0, 0, 1))
  local spawned = 0
  for idx, sl in ipairs(slots) do
    if #j.cargoProps >= M.MAX_CARGO_PROPS then break end
    local model = models[((idx - 1) % #models) + 1]
    local wx = center.x + rx * sl.lx + fx * sl.ly + ux * sl.lz
    local wy = center.y + ry * sl.lx + fy * sl.ly + uy * sl.lz
    local wz = center.z + rz * sl.lx + fz * sl.ly + uz * sl.lz
    local okS, obj = pcall(cv.spawnNewVehicle, model, {
      pos = vec3(wx, wy, wz),
      rot = rot,
      autoEnterVehicle = false,
      vehicleName = 'bne_cargo_prop',
    })
    if okS and obj then
      local pid = vehIdOf(obj)
      if pid then
        j.cargoProps[#j.cargoProps + 1] = {
          id = pid,
          model = model,
          estMassKg = M.PROP_EST_MASS_KG[model] or 12,
        }
        spawned = spawned + 1
      end
    end
  end
  j.cargoPropsInitial = #j.cargoProps
  j.cargoPropsMax = bounds.maxProps or M.MAX_CARGO_PROPS
  return spawned
end

local function flushDespawnQueue()
  for i = #despawnQueue, 1, -1 do
    local entry = despawnQueue[i]
    if entry and entry.id then
      deleteObjectById(entry.id)
    end
    despawnQueue[i] = nil
  end
end

local function tickDespawnQueue(now)
  if #despawnQueue == 0 then return end
  if now - lastDespawnCheckAt < 0.5 then return end
  lastDespawnCheckAt = now
  local pv = M.playerVeh()
  if not pv or not pv.getPosition then return end
  local pPos = pv:getPosition()
  local st = rawget(_G, 'scenetree')
  local beObj = rawget(_G, 'be')
  for i = #despawnQueue, 1, -1 do
    local entry = despawnQueue[i]
    local trl = entry and entry.id and (
      (st and st.findObjectById and st.findObjectById(entry.id))
      or (beObj and beObj.getObjectByID and beObj:getObjectByID(entry.id))
    )
    if not trl or not trl.getPosition then
      table.remove(despawnQueue, i)
    else
      local tPos = trl:getPosition()
      local d = hypot(pPos.x - tPos.x, pPos.y - tPos.y)
      if M.shouldDespawnTrailer(d) then
        pcall(function() trl:delete() end)
        table.remove(despawnQueue, i)
      end
    end
  end
end

local function detachAndQueueDespawn(j)
  if not j then return end
  cleanupCargoProps(j)
  if j.trailerId then
    applyCargoMassToId(j.trailerId, 0)
  end
  j.cargoAppliedKg = 0
  j.cargoCurrentKg = 0
  if j.trailerOwnedByJob and j.trailerId then
    local pv = M.playerVeh()
    if pv and pv.queueLuaCommand then
      pcall(pv.queueLuaCommand, pv, 'if beamstate and beamstate.detachCouplers then beamstate.detachCouplers() end; if extensions and extensions.couplings and extensions.couplings.detachAll then extensions.couplings.detachAll() end')
    end
    local trl = rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(j.trailerId)
    if trl and trl.queueLuaCommand then
      pcall(trl.queueLuaCommand, trl, 'if beamstate and beamstate.detachCouplers then beamstate.detachCouplers() end; if input and input.event then input.event("parkingbrake", 1, 2) end')
    end
    despawnQueue[#despawnQueue + 1] = { id = j.trailerId }
    j.trailerId = nil
    j.trailerOwnedByJob = false
  end
  j.trailerState = j.playerOwnedTrailer and 'attached' or 'none'
  j.hitchPlan = nil
end

local function cleanupJobTrailer(j)
  if not j then
    flushDespawnQueue()
    return
  end
  cleanupCargoProps(j)
  applyCargoMassToJob(j, 0)
  if j.trailerOwnedByJob and j.trailerId then
    local pv = M.playerVeh()
    if pv and pv.queueLuaCommand then
      pcall(pv.queueLuaCommand, pv, 'if beamstate and beamstate.detachCouplers then beamstate.detachCouplers() end')
    end
    deleteObjectById(j.trailerId)
  end
  j.trailerId = nil
  j.trailerOwnedByJob = false
  j.hitchPlan = nil
  flushDespawnQueue()
end

local function stageTrailerAtBay(j, stop, sx, sy, fx, fy, rx, ry, leg, playerZ)
  if not j or not stop or not leg or leg.legKind ~= 'loaded_trailer' then return false end
  if j.playerOwnedTrailer or j.trailerId then return false end
  local vinfo = j.vehicleInfo or {}
  local coupler = vinfo.coupler or 'none'
  if coupler ~= 'towhitch' and coupler ~= 'fifthwheel' then
    leg.legKind = 'loaded_solo'
    return false
  end
  local discovered = M.discoverTrailerModels()
  local model = leg.trailerModel
  if type(model) ~= 'string' or model == '' or not M.modelExists(model) then
    model = M.pickTrailerModel(coupler, leg.cargoType, j.tier, nil, leg.cargoDomain, (j.seed or 0) + (leg.index or 1), discovered)
  end
  local cv = rawget(_G, 'core_vehicles')
  local pv = M.playerVeh()
  if not model or not cv or not cv.spawnNewVehicle or not pv then
    leg.legKind = 'loaded_solo'
    local cap = M.SOLO_CARGO_CAP_KG[j.vehicleClass or 'van'] or 1400
    if (leg.cargoMassKg or 0) > cap then leg.cargoMassKg = cap end
    j.trailerState = 'tight_space_solo'
    return false
  end

  local zTop = (j.stopZ or playerZ or 0) + 20
  local gzCenter = M.castRay(sx, sy, zTop, 60)
  if not gzCenter then return false end -- terrain not streamed yet; retry next tick

  local tHalf = (coupler == 'fifthwheel') and 6.2 or 2.4
  local cands = M.stationTrailerPose(sx, sy, gzCenter, fx, fy, rx, ry, tHalf)
  local pvId = vehIdOf(pv)
  local chosen = nil

  for _, c in ipairs(cands) do
    local gzC = M.castRay(c.x, c.y, gzCenter + 12, 36)
    local gzF = M.castRay(c.x + c.dirX * (tHalf * 0.8), c.y + c.dirY * (tHalf * 0.8), gzCenter + 12, 36)
    local gzB = M.castRay(c.x - c.dirX * (tHalf * 0.8), c.y - c.dirY * (tHalf * 0.8), gzCenter + 12, 36)
    if gzC and gzF and gzB and math.abs(gzF - gzB) <= 2.5 and math.abs(gzC - gzCenter) <= 3.0 then
      local clear = true
      local hitF = M.castRayDir(c.x, c.y, gzC + 1.2, c.dirX, c.dirY, 0, tHalf + 0.6)
      local hitB = M.castRayDir(c.x, c.y, gzC + 1.2, -c.dirX, -c.dirY, 0, tHalf + 0.6)
      if (hitF and hitF < tHalf + 0.4) or (hitB and hitB < tHalf + 0.4) then
        clear = false
      end
      if clear and rawget(_G, 'be') and be.getObjectCount then
        for i = 0, be:getObjectCount() - 1 do
          local o = be:getObject(i)
          if o and o.getPosition then
            local op = o:getPosition()
            local minSep = (vehIdOf(o) == pvId) and (tHalf + 2.5) or (tHalf + 2.0)
            if hypot(op.x - c.x, op.y - c.y) < minSep then clear = false break end
          end
        end
      end
      if clear then
        local zSpawn = math.max(gzC, 0.5 * (gzF + gzB)) + 0.55
        chosen = { x = c.x, y = c.y, z = zSpawn, dirX = c.dirX, dirY = c.dirY }
        break
      end
    end
  end

  j.stagedAttempted[j.stopIndex] = true
  if not chosen then
    leg.legKind = 'loaded_solo'
    local cap = M.SOLO_CARGO_CAP_KG[j.vehicleClass or 'van'] or 1400
    if (leg.cargoMassKg or 0) > cap then leg.cargoMassKg = cap end
    j.trailerState = 'tight_space_solo'
    j.dwellTargetS = M.defaultDwellTargetS('logistics', j.tier, stop, leg.cargoMassKg, 'loaded_solo')
    M.say('Bay too tight for trailer — running solo cargo', 5)
    return false
  end

  local rot = quatFromDir(vec3(chosen.dirX, chosen.dirY, 0):normalized(), vec3(0, 0, 1))
  local ok, trl = pcall(cv.spawnNewVehicle, model, {
    pos = vec3(chosen.x, chosen.y, chosen.z),
    rot = rot,
    autoEnterVehicle = false,
    vehicleName = 'bne_transport_trailer',
  })
  if not ok or not trl then
    leg.legKind = 'loaded_solo'
    j.trailerState = 'tight_space_solo'
    return false
  end
  j.trailerId = vehIdOf(trl)
  j.trailerOwnedByJob = true
  j.trailerModel = model
  j.trailerLabel = leg.trailerLabel or M.TRAILER_LABELS[model] or 'Trailer'
  j.trailerState = 'staged'
  j.lastCoupleTryAt = -math.huge
  pcall(trl.queueLuaCommand, trl, 'if input and input.event then input.event("parkingbrake", 0, 2) end')
  if M.OPEN_TRAILER_MODELS[tostring(model):lower()] then
    local crateCount = math.max(2, math.min(M.MAX_CARGO_PROPS, math.ceil((tonumber(leg.cargoMassKg) or 800) / 450)))
    spawnCargoPropsForTarget(j, trl, crateCount, 'crate', true, model)
  end
  M.say(string.format('%s staged at %s — back up to hitch', j.trailerLabel, stop.name or 'loading bay'), 5)
  return true
end

local function tryCoupleToTrailer(j, now, player, pv, pvId, trl)
  local attId = findAttachedTrailerId(pvId)
  if attId == j.trailerId then
    return true
  end

  local pPos = pv.getPosition and pv:getPosition()
  local pDir = pv.getDirectionVector and pv:getDirectionVector()
  local tPos = trl.getPosition and trl:getPosition()
  local tDir = trl.getDirectionVector and trl:getDirectionVector()
  if not (pPos and pDir and tPos and tDir) then return false end

  local vinfo = j.vehicleInfo or {}
  local coupler = vinfo.coupler or 'none'
  local pHalf = math.max(2.0, ((vinfo.lengthM or 5.5) * 0.5))
  local tHalf = (coupler == 'fifthwheel') and 6.2 or 2.4
  local hDist = M.hitchDistanceM(pPos.x, pPos.y, pDir.x, pDir.y, pHalf, tPos.x, tPos.y, tDir.x, tDir.y, tHalf, coupler)

  if hDist <= M.COUPLER_RANGE_M and (player.speed or 0) < 3.5 and (now - (j.lastCoupleTryAt or -math.huge)) >= 0.35 then
    j.lastCoupleTryAt = now
    local couplerTag = coupler == 'fifthwheel' and 'fifthwheel' or 'towhitch'
    local cmd = string.format([[
local tagMatch = %q
local myNode = nil
if v and v.data and type(v.data.nodes) == 'table' then
  for _, nd in pairs(v.data.nodes) do
    if type(nd) == 'table' and type(nd.couplerTag) == 'string' and nd.couplerTag:lower():find(tagMatch) then
      myNode = tonumber(nd.cid)
      break
    end
  end
end
if myNode then
  local nd = v.data.nodes[myNode]
  obj:attachExternalCoupler(myNode, %d, 0, nd.couplerStrength or 10000000, math.max(nd.couplerRadius or 1.2, %.2f),
    nd.couplerLockRadius or 0.15, nd.couplerLatchSpeed or 1.5, 0)
end]], couplerTag, j.trailerId, M.COUPLER_RANGE_M)
    pcall(pv.queueLuaCommand, pv, cmd)
    pcall(trl.queueLuaCommand, trl, 'if input and input.event then input.event("parkingbrake", 0, 2) end')
  end
  return false
end

local function tickStagedCoupling(j, now, player)
  if not j or j.trailerState ~= 'staged' or not j.trailerId then return false end
  local pv = M.playerVeh()
  local pvId = vehIdOf(pv)
  local trl = rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(j.trailerId)
  if not pv or not pvId or not trl then return false end
  return tryCoupleToTrailer(j, now, player, pv, pvId, trl)
end

-- Verify that the job's required trailer is physically attached to the player vehicle.
function M.isTrailerAttachedToJob(j, pvId)
  if not j or j.mode ~= 'logistics' then return true end
  local stopIdx = j.stopIndex or 1
  local curLeg = (stopIdx >= 2) and j.legs and j.legs[stopIdx - 1] or nil
  if not (curLeg and curLeg.legKind == 'loaded_trailer') then return true end
  if not j.trailerId then return false end
  local attId = pvId and findAttachedTrailerId(pvId) or nil
  return attId == j.trailerId
end

-- Pure: format weight in kg or metric tonnes.
local function fmtCargoWt(kg)
  kg = math.max(0, tonumber(kg) or 0)
  if kg >= 1000 then
    return string.format('%.1f t', kg / 1000)
  end
  return string.format('%d kg', math.floor(kg + 0.5))
end

-- Pure: compute active leg task & cargo display state for Logistics jobs (strictly active-leg-only).
function M.activeLegInfo(j, out)
  if not j or j.mode ~= 'logistics' then return nil end
  local r = out or {}
  r.legKind, r.legLabel, r.cargoLabel, r.cargoKg, r.trailerLabel, r.trailerModel = nil, nil, nil, nil, nil, nil
  local legs = j.legs or {}
  local stopIdx = j.stopIndex or 1
  local curStop = j.stops and j.stops[stopIdx] or nil
  local curLeg = (stopIdx >= 2) and legs[stopIdx - 1] or nil
  local upLeg = legs[stopIdx]

  if curLeg and curLeg.legKind == 'deadhead' and j.trailerState ~= 'staged' then
    r.legKind = 'deadhead'
    r.legLabel = 'Deadhead · Empty transit (0 kg)'
    return r
  end

  if stopIdx == 1 or (curStop and curStop.kind == 'loading' and j.trailerState == 'staged') then
    if upLeg and upLeg.legKind == 'loaded_trailer' then
      local tLbl = j.trailerLabel or upLeg.trailerLabel or 'Trailer'
      local cLbl = (upLeg.cargoLabel and upLeg.cargoLabel ~= '') and upLeg.cargoLabel or 'Freight'
      local upKg = tonumber(upLeg.cargoMassKg) or 0
      r.legKind = 'pickup_approach'
      r.legLabel = string.format('Pick up %s (%s · %s)', tLbl, cLbl, fmtCargoWt(upKg))
      r.trailerLabel = tLbl
      r.trailerModel = upLeg.trailerModel
      return r
    elseif upLeg then
      local cLbl = (upLeg.cargoLabel and upLeg.cargoLabel ~= '') and upLeg.cargoLabel or 'Cargo'
      local upKg = tonumber(upLeg.cargoMassKg) or 0
      r.legKind = 'pickup_approach'
      r.legLabel = string.format('Pick up %s (%s)', cLbl, fmtCargoWt(upKg))
      return r
    end
    r.legKind = 'deadhead'
    r.legLabel = 'Deadhead · Empty transit (0 kg)'
    return r
  end

  if curLeg and (curLeg.legKind == 'loaded_trailer' or curLeg.legKind == 'loaded_solo') then
    local kg = (tonumber(j.cargoCurrentKg) or 0) > 0 and j.cargoCurrentKg or (tonumber(curLeg.cargoMassKg) or 0)
    local lbl = (curLeg.cargoLabel and curLeg.cargoLabel ~= '') and curLeg.cargoLabel or 'Freight'
    local isTrl = curLeg.legKind == 'loaded_trailer'
    r.legKind = curLeg.legKind
    r.legLabel = string.format('Deliver %s · %s', lbl, fmtCargoWt(kg))
    r.cargoLabel = lbl
    r.cargoKg = kg > 0 and kg or nil
    r.trailerLabel = isTrl and (j.trailerLabel or curLeg.trailerLabel) or nil
    r.trailerModel = isTrl and curLeg.trailerModel or nil
    return r
  end

  r.legKind = 'deadhead'
  r.legLabel = 'Deadhead · Empty transit (0 kg)'
  return r
end

function M._onVehicleProbe(vehId, info)
  if type(vehId) ~= 'number' or type(info) ~= 'table' then return end
  vehicleProbes[vehId] = {
    massKg = tonumber(info.massKg),
    coupler = tostring(info.coupler or 'none'),
    couplerCid = tonumber(info.couplerCid) or -1,
    attached = info.attached == true,
    at = M.now(),
  }
  vehicleMatchCache = nil
end

function M._onFuelProbe(vehId, info)
  if type(info) ~= 'table' then return end
  -- Do not overwrite smooth GE ramp while actively refueling
  if fuel.refuel and fuel.refuel.active then return end
  local hasTank = info.hasTank == true
  local ratio = tonumber(info.ratio)
  fuel.vehId = tonumber(vehId) or fuel.vehId
  fuel.hasTank = hasTank and ratio ~= nil and ratio >= 0
  if fuel.hasTank then
    fuel.ratio = math.max(0.0, math.min(1.0, ratio))
    local cap = tonumber(info.capacityL)
    if cap and cap >= 5.0 then fuel.capacityL = cap end
    fuel.volumeL = tonumber(info.volumeL) or (fuel.ratio * fuel.capacityL)
  else
    fuel.ratio = nil
    fuel.volumeL = nil
  end
end

function M.onFuelStationsResult(msg)
  if type(msg) ~= 'table' or msg.ok ~= true or type(msg.stations) ~= 'table' then return end
  local list = {}
  for i = 1, #msg.stations do
    local s = msg.stations[i]
    if type(s) == 'table' and isFinite(tonumber(s.lat)) and isFinite(tonumber(s.lon)) then
      list[#list + 1] = {
        id = tostring(s.id or ('fuel_' .. i)),
        name = tostring(s.name or 'Local Fuel Station'),
        brand = tostring(s.brand or ''),
        lat = tonumber(s.lat),
        lon = tonumber(s.lon),
        bearingDeg = tonumber(s.bearingDeg) or 0,
        distM = tonumber(s.distM) or 0,
        road = tostring(s.road or ''),
        locality = tostring(s.locality or ''),
        pricePerLiter = tonumber(s.pricePerLiter) or 1.79,
      }
    end
  end
  fuel.stations = list
  if fuel.pendingRoute then
    fuel.pendingRoute = false
    if #list > 0 then
      M.routeToNearestFuel()
    else
      M.say('No fuel stations found nearby', 5)
    end
  end
end

function M.routeToNearestFuel()
  local _, pl = playerPose()
  local lat = pl and pl.lat or nil
  local lon = pl and pl.lon or nil
  local st = M.nearestFuelStation(fuel.stations, lat, lon)
  if st then
    local ok, g = pcall(M.gps)
    if ok and g and g.setDestination then
      local label = string.format('Fuel: %s ($%.2f/L)', st.name, st.pricePerLiter)
      pcall(g.setDestination, st.lat, st.lon, label)
      fuel.routedToFuel = true
    end
    M.say(string.format('Routing to %s (%d m %s · $%.2f/L)', st.name, st.distM or 0, st.cardinal or 'N', st.pricePerLiter), 6)
    return { ok = true, station = st }
  end
  local c = M.core()
  if c and c.requestFuelStations and isFinite(lat) and isFinite(lon) then
    fuel.reqId = fuel.reqId + 1
    fuel.pendingRoute = true
    if c.requestFuelStations(fuel.reqId, lat, lon, 4500.0) then
      fuel.lastQueryAt = M.now()
      fuel.lastQueryLat = lat
      fuel.lastQueryLon = lon
      M.say('Searching for nearest fuel station...', 4)
      return { ok = true, searching = true }
    end
    fuel.pendingRoute = false
  end
  local fnd = rawget(_G, 'beamngEarth_finder')
  if fnd and fnd.nearest then
    pcall(fnd.nearest)
    return { ok = true, finder = true }
  end
  return { ok = false, error = 'No fuel stations found nearby' }
end

local function fuelSnapshot(pl)
  local pct = (fuel.hasTank and fuel.ratio ~= nil) and math.floor(fuel.ratio * 100 + 0.5) or nil
  local low = pct ~= nil and pct < M.LOW_FUEL_PCT
  local nfs = M.nearestFuelStation(fuel.stations, pl and pl.lat, pl and pl.lon)
  local rf = nil
  local r = fuel.refuel
  if r and (r.active or r.done or (r.holdS or 0) > 0) then
    rf = {
      active = r.active == true,
      done = r.done == true,
      holdS = round2(r.holdS or 0),
      holdTargetS = M.FUEL_STOP_HOLD_S,
      stationName = r.stationName or 'Local Fuel Station',
      pricePerLiter = r.pricePerLiter or 1.79,
      litersAdded = math.floor((r.litersAdded or 0) * 10 + 0.5) / 10,
      costTotal = round2(r.costTotal or 0),
      fuelPct = pct,
      overdraftHit = r.overdraftHit == true,
    }
  end
  return pct, low, nfs, rf
end

local function tickFuel(dtSim, anchor, player, paused, rebasing, now)
  if rebasing or not anchor or not player then return end

  -- Expire completed receipt banner after FUEL_RECEIPT_SHOW_S
  if fuel.refuel and fuel.refuel.done and fuel.refuel.doneAt and (now - fuel.refuel.doneAt) >= M.FUEL_RECEIPT_SHOW_S then
    fuel.refuel = nil
  end

  -- 1. Periodic nearby fuel station query (every 6 s or > 400 m movement)
  local c = M.core()
  if c and c.requestFuelStations and isFinite(player.lat) and isFinite(player.lon) then
    if M.shouldQueryFuelStations(fuel.lastQueryAt, fuel.lastQueryLat, fuel.lastQueryLon, now, player.lat, player.lon) then
      fuel.reqId = fuel.reqId + 1
      if c.requestFuelStations(fuel.reqId, player.lat, player.lon, M.FUEL_QUERY_RADIUS_M) then
        fuel.lastQueryAt = now
        fuel.lastQueryLat = player.lat
        fuel.lastQueryLon = player.lon
      end
    end
  end

  -- 2. Periodic live vehicle fuel probe (paused while actively refueling)
  local pv = M.playerVeh()
  if pv and pv.queueLuaCommand and not (fuel.refuel and fuel.refuel.active) then
    if (now - fuel.lastProbeAt) >= M.FUEL_PROBE_INTERVAL_S then
      fuel.lastProbeAt = now
      pcall(pv.queueLuaCommand, pv, M.FUEL_READ_VE)
    end
  end

  -- 3. Pump bay proximity & physical refueling
  if #fuel.stations == 0 or not fuel.hasTank or fuel.ratio == nil then
    if fuel.refuel and fuel.refuel.active then
      fuel.refuel.active = false
      fuel.refuel.done = true
      fuel.refuel.doneAt = now
      M.saveCareerStats()
    end
    return
  end

  local inBayStation = nil
  local spec = M.FUEL_BAY_SPEC
  for i = 1, #fuel.stations do
    local s = fuel.stations[i]
    if s._anchor ~= anchor then
      local sx, sy = anchor:geodeticToEnu(s.lat, s.lon, 0)
      local nx, ny = 0, 1
      if anchor.northAt then
        local okN, ax, ay = pcall(anchor.northAt, anchor, sx, sy)
        if okN and tonumber(ax) and tonumber(ay) then nx, ny = ax, ay end
      end
      local fx, fy, rx, ry = M.bayFrame(nx, ny, s.bearingDeg)
      s._anchor, s._sx, s._sy, s._fx, s._fy, s._rx, s._ry = anchor, sx, sy, fx, fy, rx, ry
      s._gz = nil
      s._gzAt = -math.huge
      s._quads = nil
    end
    local distXY = hypot(s._sx - player.x, s._sy - player.y)
    s._distXY = distXY
    if distXY <= 22.0 then
      if s._gz == nil or (now - (s._gzAt or -math.huge)) >= 1.5 then
        local gz = M.castRay(s._sx, s._sy, (player.z or 0) + 40, 120)
        if gz then
          s._gz = gz
          s._gzAt = now
        end
      end
      local dz = s._gz and ((player.z or 0) - s._gz) or 0
      local longOff, latOff = M.bayOffsets(player.x, player.y, s._sx, s._sy, s._fx, s._fy, s._rx, s._ry)
      if math.abs(dz) <= M.HEIGHT_TOL_M and math.abs(latOff) <= spec.latTol and math.abs(longOff) <= spec.longTol then
        inBayStation = s
        break
      end
    end
  end

  if not inBayStation and not (fuel.refuel and (fuel.refuel.active or (fuel.refuel.holdS or 0) > 0)) then
    return
  end

  if inBayStation then
    if not fuel.refuel or fuel.refuel.done or fuel.refuel.stationId ~= inBayStation.id then
      fuel.refuel = {
        stationId = inBayStation.id,
        stationName = inBayStation.name or 'Local Fuel Station',
        pricePerLiter = inBayStation.pricePerLiter or 1.79,
        holdS = 0,
        active = false,
        done = false,
        doneAt = nil,
        litersAdded = 0,
        costTotal = 0,
        overdraftHit = false,
        lastCmdAt = -math.huge,
        lastSaveAt = now,
      }
    end
  end

  local r = fuel.refuel
  if not r then return end
  local career = ensureCareerLoaded()
  local _, dLiters, dCost, newRatio, ev = M.stepFuelRefuel(
    r, inBayStation ~= nil, player.speed or 0, fuel.ratio, fuel.capacityL,
    r.pricePerLiter, career.totalEarnings, dtSim, paused
  )
  if dLiters > 0 then
    fuel.ratio = newRatio
    fuel.volumeL = newRatio * (fuel.capacityL or 55.0)
    career.totalEarnings = math.max(M.FUEL_OVERDRAFT_LIMIT, round2(career.totalEarnings - dCost))
    careerStatsCache = nil
    if pv and pv.queueLuaCommand and ((now - (r.lastCmdAt or -math.huge)) >= 0.15 or ev == 'full' or ev == 'overdraft') then
      r.lastCmdAt = now
      pcall(pv.queueLuaCommand, pv, M.buildRefuelVeScript(newRatio))
    end
    if (now - (r.lastSaveAt or -math.huge)) >= 1.0 then
      r.lastSaveAt = now
      M.saveCareerStats()
    end
  end
  if ev == 'full' or ev == 'overdraft' or ev == 'stopped' then
    if pv and pv.queueLuaCommand and dLiters > 0 then
      pcall(pv.queueLuaCommand, pv, M.buildRefuelVeScript(newRatio))
    end
    r.done = true
    r.doneAt = now
    M.saveCareerStats()
    fuel.lastProbeAt = -math.huge
    if r.litersAdded and r.litersAdded > 0.05 then
      if ev == 'overdraft' then
        M.say(string.format('Overdraft limit (-$50) at %s · +%.1f L · -$%.2f', r.stationName, r.litersAdded, r.costTotal), 6)
      else
        M.say(string.format('Refueled at %s · +%.1f L · -$%.2f', r.stationName, r.litersAdded, r.costTotal), 6)
      end
    end
    -- If player detoured to fuel during an active job, restore GPS back to the active stop
    if fuel.routedToFuel and activeJob and activeJob.stops and activeJob.stops[activeJob.stopIndex] then
      fuel.routedToFuel = false
      syncGpsToStop(activeJob.stops[activeJob.stopIndex], activeJob.stopIndex, #activeJob.stops)
    end
  elseif ev == 'idle' and not r.done then
    fuel.refuel = nil
  end
end

local function dispatchPendingProbe(pr)
  local ge = pr.geInfo or {}
  local prb = pr.vehId and vehicleProbes[pr.vehId] or nil
  local probeCoupler = prb and prb.coupler or 'none'
  if probeCoupler == 'none' and ge.coupler and ge.coupler ~= 'none' then
    probeCoupler = ge.coupler
  end
  local merged = {
    jbeam = ge.jbeam,
    modelType = ge.modelType,
    configName = ge.configName,
    lengthM = ge.lengthM,
    massKg = prb and prb.massKg or nil,
    coupler = probeCoupler,
    hasTrailer = ge.hasTrailer or (prb and prb.attached == true) or false,
    attachedTrailerId = ge.attachedTrailerId,
  }
  local classified = M.classifyVehicle(merged)
  classified.lengthM = ge.lengthM
  classified.attachedTrailerId = ge.attachedTrailerId
  local disc = M.discoverTrailerModels()
  classified.trailerModels = { fifthwheel = disc.fifthwheel, towhitch = disc.towhitch }

  local c = M.core()
  if not (c and c.requestTransportJob) then
    lastError = 'BeamNG.Earth core is not ready'
    return { ok = false, error = lastError }
  end
  nextReqId = nextReqId + 1
  jobSeq = jobSeq + 1
  lastError = nil
  summary = nil
  if not c.requestTransportJob(nextReqId, pr.mode, pr.tier, pr.pl.lat, pr.pl.lon, pr.heading, jobSeq, classified) then
    lastError = 'Companion server not connected'
    return { ok = false, error = lastError }
  end
  pending = { id = nextReqId, mode = pr.mode, tier = pr.tier, sentAt = M.now(), vehicle = classified, seed = jobSeq }
  return { ok = true, id = nextReqId }
end

function M.isActive()
  return activeJob ~= nil or pending ~= nil or pendingProbe ~= nil
end

function M.startJob(mode, tier)
  local okV, errV = M.validateRequest(mode, tier)
  if not okV then
    lastError = errV
    return { ok = false, error = errV }
  end
  mode, tier = mode:lower(), tier:lower()
  if mode == 'taxi' and tier == 'neighborhood' then tier = 'short' end
  local st, pl, heading = playerPose()
  if not (st and st.inOurLevel and pl and pl.lat and pl.lon) then
    lastError = 'Load into the BeamNG.Earth world first'
    return { ok = false, error = lastError }
  end
  local c = M.core()
  if not (c and c.requestTransportJob) then
    lastError = 'BeamNG.Earth core is not ready'
    return { ok = false, error = lastError }
  end

  if mode == 'logistics' then
    local ge = inspectGeVehicle()
    local veh = M.playerVeh()
    if veh and veh.queueLuaCommand and ge.vehId then
      vehicleProbes[ge.vehId] = nil
      pcall(veh.queueLuaCommand, veh, PROBE_VE)
      pendingProbe = {
        mode = mode,
        tier = tier,
        pl = { lat = pl.lat, lon = pl.lon },
        heading = heading,
        sentAt = M.now(),
        geInfo = ge,
        vehId = ge.vehId,
      }
      lastError = nil
      summary = nil
      return { ok = true, probing = true }
    end
    return dispatchPendingProbe({
      mode = mode, tier = tier, pl = { lat = pl.lat, lon = pl.lon },
      heading = heading, geInfo = ge, vehId = ge.vehId,
    })
  end

  nextReqId = nextReqId + 1
  jobSeq = jobSeq + 1
  lastError = nil
  summary = nil
  if not c.requestTransportJob(nextReqId, mode, tier, pl.lat, pl.lon, heading, jobSeq) then
    lastError = 'Companion server not connected'
    return { ok = false, error = lastError }
  end
  pending = { id = nextReqId, mode = mode, tier = tier, sentAt = M.now() }
  return { ok = true, id = nextReqId }
end

function M.onJobResult(msg)
  if type(msg) ~= 'table' or not pending or msg.id ~= pending.id then return end
  local req = pending
  pending = nil
  if msg.ok ~= true or type(msg.stops) ~= 'table' or #msg.stops == 0 then
    lastError = tostring(msg.error or 'Could not generate transport job')
    M.say('Transport: ' .. lastError, 6)
    return
  end
  local cargo = type(msg.cargo) == 'table' and msg.cargo or nil
  local cargoKg = cargo and tonumber(cargo.massKg) or 0
  local taxiMeta = type(msg.taxi) == 'table' and msg.taxi or nil
  local busMeta = type(msg.bus) == 'table' and msg.bus or nil
  local parcelMeta = type(msg.parcel) == 'table' and msg.parcel or nil
  local mode = tostring(msg.mode or req.mode)
  local tier = tostring(msg.tier or req.tier)

  local stops = {}
  local sumDeliverParcels = 0
  local sumDeliverKg = 0
  for _, s in ipairs(msg.stops) do
    local lat, lon = tonumber(s.lat), tonumber(s.lon)
    if lat and lon then
      local pAction = s.parcelAction and tostring(s.parcelAction) or (mode == 'parcel' and 'deliver' or nil)
      local pCount = tonumber(s.parcelCount)
      local cDelta = tonumber(s.cargoDeltaKg) or 0
      if mode == 'parcel' and pAction == 'deliver' then
        sumDeliverParcels = sumDeliverParcels + math.max(1, pCount or 1)
        sumDeliverKg = sumDeliverKg + math.abs(cDelta)
      end
      local stObj = {
        index = tonumber(s.index) or (#stops + 1),
        kind = tostring(s.kind or 'stop'),
        stopType = tostring(s.stopType or 'kerbside'),
        name = tostring(s.name or ('Stop ' .. (#stops + 1))),
        address = tostring(s.address or ''),
        locality = tostring(s.locality or ''),
        sectorLabel = tostring(s.sectorLabel or ''),
        lat = lat,
        lon = lon,
        road = tostring(s.road or ''),
        roadClass = tostring(s.roadClass or ''),
        bidirectional = s.bidirectional == true,
        bearing = tonumber(s.bearing) or 0,
        zoneRadius = math.max(8, math.min(20, tonumber(s.zoneRadius) or M.DEFAULT_ZONE_RADIUS_M)),
        cargoDeltaKg = cDelta,
        paxBoard = tonumber(s.paxBoard) or 0,
        paxAlight = tonumber(s.paxAlight) or 0,
        targetArrivalS = tonumber(s.targetArrivalS),
        recipient = s.recipient and tostring(s.recipient) or nil,
        parcelCount = pCount,
        parcelAction = pAction,
        parcelsRemaining = tonumber(s.parcelsRemaining),
        parcelsTotal = tonumber(s.parcelsTotal),
      }
      local dtgt = tonumber(s.dwellTargetS)
      if not dtgt or dtgt <= 0 then
        dtgt = M.defaultDwellTargetS(mode, tier, stObj, cargoKg)
      end
      stObj.dwellTargetS = dtgt
      stops[#stops + 1] = stObj
    end
  end
  if #stops == 0 then
    lastError = 'Job returned no valid stops'
    return
  end
  local legs = {}
  if mode == 'logistics' then
    if type(msg.legs) == 'table' and #msg.legs > 0 then
      for _, lg in ipairs(msg.legs) do
        legs[#legs + 1] = {
          index = tonumber(lg.index) or (#legs + 1),
          fromStop = tonumber(lg.fromStop) or (#legs + 1),
          toStop = tonumber(lg.toStop) or (#legs + 2),
          legKind = tostring(lg.legKind or 'loaded_solo'),
          cargoType = tostring(lg.cargoType or ''),
          cargoLabel = tostring(lg.cargoLabel or ''),
          cargoDomain = tostring(lg.cargoDomain or 'general'),
          cargoMassKg = tonumber(lg.cargoMassKg) or 0,
          trailerModel = lg.trailerModel and tostring(lg.trailerModel) or nil,
          trailerLabel = lg.trailerLabel and tostring(lg.trailerLabel) or nil,
        }
      end
    elseif #stops >= 2 then
      local coupler = req.vehicle and req.vehicle.coupler or 'none'
      local useTrl = (cargo and cargo.useTrailer ~= nil) and (cargo.useTrailer == true) or (coupler == 'fifthwheel')
      local lk = (useTrl and (coupler == 'fifthwheel' or coupler == 'towhitch')) and 'loaded_trailer' or 'loaded_solo'
      local trlModel = (lk == 'loaded_trailer' and not (req.vehicle and req.vehicle.hasTrailer))
        and M.pickTrailerModel(coupler, cargo and cargo.type or '', tier, nil, cargo and cargo.domain or 'general', req.seed or jobSeq, M.discoverTrailerModels())
        or nil
      for i = 1, #stops - 1 do
        legs[#legs + 1] = {
          index = i,
          fromStop = i,
          toStop = i + 1,
          legKind = lk,
          cargoType = cargo and tostring(cargo.type or '') or '',
          cargoLabel = cargo and tostring(cargo.label or '') or '',
          cargoDomain = cargo and tostring(cargo.domain or 'general') or 'general',
          cargoMassKg = cargoKg,
          trailerModel = trlModel,
          trailerLabel = trlModel and (M.TRAILER_LABELS[trlModel] or 'Trailer') or nil,
        }
      end
    end
  end
  local preAttachedId = (mode == 'logistics' and req.vehicle and req.vehicle.attachedTrailerId) or nil
  lastError = nil
  summary = nil
  local firstTarget = stops[1].dwellTargetS or M.BAY_DWELL_S
  local taxiArch = taxiMeta and tostring(taxiMeta.archetype or 'standard') or 'standard'
  local taxiLabel = taxiMeta and tostring(taxiMeta.label or 'Standard Ride') or 'Standard Ride'
  local busCap = busMeta and tonumber(busMeta.capacity) or M.BUS_CAPACITY
  local busPaxKg = busMeta and tonumber(busMeta.paxMassPerPaxKg) or M.BUS_PAX_MASS_KG
  activeJob = {
    mode = mode,
    tier = tier,
    seed = req.seed or jobSeq,
    title = tostring(msg.title or ''),
    routeRef = tostring(msg.routeRef or ''),
    source = tostring(msg.source or ''),
    estimatedKm = tonumber(msg.estimatedKm) or 0,
    stops = stops,
    stopIndex = 1,
    stopsCompleted = 0,
    stopsSkipped = 0,
    fallbackCount = 0,
    dwellS = 0,
    dwellMode = 'none',
    dwellTargetS = firstTarget,
    inBay = false,
    inFallback = false,
    distM = nil,
    etaS = nil,
    drivenM = 0,
    elapsedS = 0,
    harshS = 0,
    prevVertSpike = false,
    collisions = 0,
    damageDelta = 0,
    prevDamage = M.readDamage(),
    trackedVehId = vehIdOf(M.playerVeh()),
    lastCollisionAt = -math.huge,
    lastTrack = nil,
    sampleAcc = 0,
    lastSample = nil,
    stopZ = nil,
    bayCornersZ = nil,
    bayGridZ = nil,
    stopZAnchorId = nil,
    stopZAt = -math.huge,
    visGreen = 0,
    visAt = nil,
    -- Taxi leg, archetype & fare state
    passengerOnBoard = false,
    fareDrivenM = 0,
    fareElapsedS = 0,
    fareHarshS = 0,
    targetLegS = 0,
    rideArchetype = taxiArch,
    rideLabel = taxiLabel,
    fareMult = taxiMeta and tonumber(taxiMeta.fareMult) or 1.0,
    tipMult = taxiMeta and tonumber(taxiMeta.tipMult) or 1.0,
    targetMult = taxiMeta and tonumber(taxiMeta.targetMult) or 1.0,
    taxiPaxCount = taxiMeta and tonumber(taxiMeta.paxCount) or 1,
    paxMassKg = taxiMeta and tonumber(taxiMeta.paxMassKg) or 80,
    -- Bus passenger load & schedule state
    paxCount = (mode == 'bus') and 0 or (taxiMeta and tonumber(taxiMeta.paxCount) or 0),
    paxCapacity = (mode == 'bus') and busCap or nil,
    paxMassPerPaxKg = busPaxKg,
    scheduleDeltaS = 0,
    scheduleText = 'On Time',
    -- Logistics cargo & trailer state
    vehicleClass = tostring(msg.vehicleClass or (cargo and cargo.vehicleClass) or (req.vehicle and req.vehicle.class) or ''),
    vehicleInfo = req.vehicle,
    legs = legs,
    stagedAttempted = {},
    cargoType = cargo and tostring(cargo.type or '') or '',
    cargoLabel = cargo and tostring(cargo.label or '') or '',
    cargoDomain = cargo and tostring(cargo.domain or 'general') or 'general',
    useTrailer = (cargo and cargo.useTrailer ~= nil) and (cargo.useTrailer == true) or nil,
    cargoKg = cargoKg,
    cargoCurrentKg = 0,
    cargoAppliedKg = 0,
    totalCargoHauledKg = 0,
    playerOwnedTrailer = preAttachedId ~= nil,
    trailerId = preAttachedId,
    trailerOwnedByJob = false,
    trailerModel = nil,
    trailerLabel = nil,
    trailerState = preAttachedId and 'attached' or ((mode == 'logistics' and 'en_route_pickup') or 'none'),
    lastCoupleTryAt = -math.huge,
    hitchPlan = nil,
    -- Parcel Courier & 3D Cargo Props state
    parcelsTotal = (mode == 'parcel') and ((parcelMeta and tonumber(parcelMeta.parcelsTotal)) or sumDeliverParcels) or nil,
    parcelsRemaining = (mode == 'parcel') and ((parcelMeta and tonumber(parcelMeta.parcelsTotal)) or sumDeliverParcels) or nil,
    parcelsDelivered = (mode == 'parcel') and 0 or nil,
    parcelsReturned = (mode == 'parcel') and 0 or nil,
    cargoProps = {},
    cargoPropsInitial = 0,
    cargoPropsMax = M.MAX_CARGO_PROPS,
  }
  if mode == 'parcel' then
    local initKg = (parcelMeta and tonumber(parcelMeta.initialMassKg)) or (cargoKg > 0 and cargoKg) or sumDeliverKg
    activeJob.cargoKg = initKg
    activeJob.cargoCurrentKg = initKg
    activeJob.totalCargoHauledKg = initKg
    local pv = M.playerVeh()
    if pv and (activeJob.parcelsTotal or 0) > 0 then
      spawnCargoPropsForTarget(activeJob, pv, activeJob.parcelsTotal, 'parcel', false)
    end
    applyCargoMassToJob(activeJob, initKg)
  end
  syncGpsToStop(stops[1], 1, #stops)
  M.say(string.format('Job started: %s (%d stops)', activeJob.title ~= '' and activeJob.title or activeJob.mode, #stops), 6)
end

local function finishJob(fallbackFinal)
  if not activeJob then return end
  local j = activeJob
  detachAndQueueDespawn(j)
  local score, smooth, timeliness = M.computeScore(j)
  j._scoreHint = score
  local fare, tip, totalFare = 0, 0, 0
  if j.mode == 'taxi' then
    fare, tip, totalFare = M.computeTaxiFare(j)
    if j.stopsSkipped and j.stopsSkipped > 0 then
      fare, tip, totalFare = 0, 0, 0
    end
  end

  local c = ensureCareerLoaded()
  local payout = M.computePayoutBreakdown(j, score, smooth, timeliness, c.streak)
  if (j.stopsCompleted or 0) > 0 then
    c.completedJobs = c.completedJobs + 1
    c.totalEarnings = round2(c.totalEarnings + payout.totalEarned)
    c.totalDistanceKm = round2(c.totalDistanceKm + ((tonumber(j.drivenM) or 0) / 1000.0))
    c.scoreSum = (c.scoreSum or 0) + score
    if score > (c.bestScore or 0) then c.bestScore = score end
    c.avgScore = math.max(0, math.min(100, math.floor((c.scoreSum / c.completedJobs) + 0.5)))
    c.streak = payout.streakApplied or 0
    local bm = c.byMode[j.mode]
    if not bm then
      bm = { jobs = 0, earnings = 0 }
      c.byMode[j.mode] = bm
    end
    bm.jobs = bm.jobs + 1
    bm.earnings = round2(bm.earnings + payout.totalEarned)
    c.driverRank = M.computeDriverRank(c.completedJobs, c.totalEarnings)
    careerStatsCache = nil
    M.saveCareerStats()
  end

  summary = {
    mode = j.mode,
    tier = j.tier,
    title = j.title,
    stopsCompleted = j.stopsCompleted,
    stopsSkipped = j.stopsSkipped,
    fallbackCount = j.fallbackCount or 0,
    stopCount = #j.stops,
    drivenM = math.floor(j.drivenM + 0.5),
    elapsedS = math.floor(j.elapsedS + 0.5),
    score = score,
    smoothnessPct = smooth,
    timelinessPct = timeliness,
    collisions = j.collisions,
    damageDelta = math.floor(j.damageDelta + 0.5),
    fare = fare,
    tip = tip,
    totalFare = totalFare,
    payout = payout,
    totalEarned = payout.totalEarned,
    driverRank = c.driverRank,
    rideArchetype = j.mode == 'taxi' and j.rideArchetype or nil,
    rideLabel = j.mode == 'taxi' and j.rideLabel or nil,
    paxCount = j.mode == 'taxi' and j.taxiPaxCount or (j.mode == 'bus' and j.paxCount or nil),
    cargoLabel = j.cargoLabel,
    cargoKg = (j.totalCargoHauledKg and j.totalCargoHauledKg > 0) and j.totalCargoHauledKg or nil,
    parcelsTotal = j.mode == 'parcel' and j.parcelsTotal or nil,
    parcelsDelivered = j.mode == 'parcel' and (j.parcelsDelivered or 0) or nil,
    parcelsReturned = j.mode == 'parcel' and (j.parcelsReturned or 0) or nil,
  }
  activeJob = nil
  clearOwnedGps()
  local prefix = fallbackFinal and 'Kerbside / Fallback Dropoff · ' or ''
  if summary.mode == 'taxi' and summary.totalFare > 0 then
    M.say(string.format('%sTaxi complete! Earned $%.2f · Score %d/100', prefix, summary.totalEarned, summary.score), 8)
  elseif summary.totalEarned > 0 then
    M.say(string.format('%sJob complete! %d/%d stops · +$%.2f · Score %d/100', prefix, summary.stopsCompleted, summary.stopCount, summary.totalEarned, summary.score), 8)
  else
    M.say(string.format('%sJob complete! %d/%d stops · Score %d/100', prefix, summary.stopsCompleted, summary.stopCount, summary.score), 8)
  end
end

local function advanceStop(completed, isFallback)
  if not activeJob then return end
  local j = activeJob
  local doneIdx = j.stopIndex
  local doneStop = j.stops[doneIdx]
  local nextLeg = j.legs and j.legs[doneIdx] or nil
  if completed then
    j.stopsCompleted = j.stopsCompleted + 1
    if isFallback then j.fallbackCount = (j.fallbackCount or 0) + 1 end
    if j.mode == 'taxi' and doneStop and doneStop.kind == 'pickup' then
      j.passengerOnBoard = true
      applyCargoMassToJob(j, j.paxMassKg or 80)
      local nextStop = j.stops[doneIdx + 1]
      local legM = nextStop and M.haversineM(doneStop.lat, doneStop.lon, nextStop.lat, nextStop.lon) or (j.estimatedKm * 1000)
      local spd = (j.tier == 'regional' or j.tier == 'long') and 19.0 or 12.5
      j.targetLegS = math.max(35.0, ((legM * 1.25) / spd) * (j.targetMult or 1.0))
    elseif j.mode == 'bus' and doneStop then
      local cap = j.paxCapacity or M.BUS_CAPACITY
      local cur = j.paxCount or 0
      local alight = math.min(cur, math.max(0, tonumber(doneStop.paxAlight) or 0))
      local board = math.max(0, tonumber(doneStop.paxBoard) or 0)
      j.paxCount = math.max(0, math.min(cap, cur - alight + board))
      applyCargoMassToJob(j, j.paxCount * (j.paxMassPerPaxKg or M.BUS_PAX_MASS_KG))
    elseif j.mode == 'parcel' and doneStop then
      local pCnt = math.max(1, tonumber(doneStop.parcelCount) or 1)
      if doneStop.parcelAction == 'pickup_return' or doneStop.kind == 'pickup' then
        j.parcelsReturned = (j.parcelsReturned or 0) + pCnt
        j.cargoCurrentKg = math.max(0, (j.cargoCurrentKg or 0) + math.abs(tonumber(doneStop.cargoDeltaKg) or 10))
        local pv = M.playerVeh()
        if pv and #(j.cargoProps or {}) < (j.cargoPropsMax or M.MAX_CARGO_PROPS) then
          spawnCargoPropsForTarget(j, pv, 1, 'parcel', false)
        end
      else
        j.parcelsDelivered = (j.parcelsDelivered or 0) + pCnt
        j.parcelsRemaining = math.max(0, (j.parcelsRemaining or 0) - pCnt)
        local dropKg = math.abs(tonumber(doneStop.cargoDeltaKg) or 12)
        j.cargoCurrentKg = math.max(0, (j.cargoCurrentKg or 0) - dropKg)
        local wantProps = M.desiredCargoPropCount(j.parcelsRemaining, j.parcelsTotal, j.cargoPropsInitial)
        syncCargoPropCount(j, wantProps)
      end
      applyCargoMassToJob(j, j.cargoCurrentKg)
    elseif j.mode == 'logistics' and doneStop then
      if doneStop.kind == 'loading' then
        local loadKg = nextLeg and (tonumber(nextLeg.cargoMassKg) or 0) or (j.cargoKg or 0)
        j.cargoCurrentKg = loadKg
        j.totalCargoHauledKg = (j.totalCargoHauledKg or 0) + loadKg
        if nextLeg and nextLeg.legKind == 'loaded_solo' then
          local pv = M.playerVeh()
          if pv then
            cleanupCargoProps(j)
            local propCnt = math.max(2, math.min(M.MAX_CARGO_PROPS, math.ceil(loadKg / 350)))
            spawnCargoPropsForTarget(j, pv, propCnt, 'crate', false)
          end
        end
        applyCargoMassToJob(j, loadKg)
        if nextLeg and nextLeg.legKind == 'loaded_trailer' and j.trailerId then
          j.trailerState = 'attached'
        end
      else
        local nxtStop = j.stops[doneIdx + 1]
        if nextLeg and nextLeg.legKind ~= 'deadhead' and nxtStop and nxtStop.kind == 'delivery' then
          local remKg = tonumber(nextLeg.cargoMassKg) or math.max(0, (j.cargoCurrentKg or 0) + (doneStop.cargoDeltaKg or 0))
          local wantProps = M.desiredCargoPropCount(remKg, math.max(1, j.cargoCurrentKg or remKg), j.cargoPropsInitial)
          syncCargoPropCount(j, wantProps)
          j.cargoCurrentKg = remKg
          applyCargoMassToJob(j, remKg)
        else
          detachAndQueueDespawn(j)
          if not j.playerOwnedTrailer then
            applyCargoMassToJob(j, 0)
          end
          if nextLeg and nextLeg.legKind == 'deadhead' then
            j.trailerState = j.playerOwnedTrailer and 'attached' or 'en_route_pickup'
          end
        end
      end
    end
  else
    j.stopsSkipped = j.stopsSkipped + 1
    if j.mode == 'logistics' then
      if j.trailerOwnedByJob and j.trailerId and j.trailerState == 'staged' then
        detachAndQueueDespawn(j)
      elseif nextLeg and nextLeg.legKind == 'deadhead' then
        detachAndQueueDespawn(j)
      end
    end
  end
  j.dwellS = 0
  j.dwellMode = 'none'
  j.inBay = false
  j.inFallback = false
  j.trailerDetached = false
  j.trailerMissing = false
  j.bayHint = nil
  j.lastMissingSayAt = -math.huge
  j.stopZ = nil
  j.bayCornersZ = nil
  j.bayGridZ = nil
  j.bayGridVersion = (j.bayGridVersion or 0) + 1
  j._bayCache = nil
  j.stopEnuIdx = nil
  j.stopEnuAnchor = nil
  j.stopZAnchorId = nil
  j.stopZAt = -math.huge
  j.visGreen = 0
  if j.stopIndex >= #j.stops then
    finishJob(isFallback)
    return
  end
  j.stopIndex = j.stopIndex + 1
  local nxt = j.stops[j.stopIndex]
  local nxtLeg = j.legs and j.legs[j.stopIndex - 1] or nil
  local nxtUpLeg = j.legs and j.legs[j.stopIndex] or nil
  local nxtLk = (nxt.kind == 'loading') and (nxtUpLeg and nxtUpLeg.legKind) or (nxtLeg and nxtLeg.legKind)
  j.dwellTargetS = nxt.dwellTargetS or M.defaultDwellTargetS(j.mode, j.tier, nxt, j.cargoKg, nxtLk)
  syncGpsToStop(nxt, j.stopIndex, #j.stops)
  -- Capture GPS ETA for taxi dropoff target time if available
  if j.mode == 'taxi' and j.passengerOnBoard then
    local okG, g = pcall(M.gps)
    local gs = okG and g and g.status and g.status()
    if gs and type(gs.eta) == 'number' and gs.eta > 5 then
      j.targetLegS = gs.eta * 1.20 * (j.targetMult or 1.0)
    end
  end
  local note = isFallback and 'Kerbside / Fallback Dropoff · ' or ''
  M.say(string.format('%sStop %d/%d: %s', note, j.stopIndex, #j.stops, nxt.name), 5)
end

function M.skipStop()
  if not activeJob then return { ok = false, error = 'No active job' } end
  advanceStop(false)
  return { ok = true }
end

function M.cancelJob()
  if not activeJob and not pending and not pendingProbe then return { ok = false, error = 'No active job' } end
  if activeJob then cleanupJobTrailer(activeJob) end
  activeJob = nil
  pending = nil
  pendingProbe = nil
  clearOwnedGps()
  M.say('Transport job cancelled', 4)
  return { ok = true }
end

function M.dismissSummary()
  summary = nil
  return { ok = true }
end

function M.nextPassenger()
  local tier = (summary and summary.mode == 'taxi' and summary.tier) or 'short'
  summary = nil
  return M.startJob('taxi', tier)
end

function M.onVehicleSwitched(oldId, newId, player)
  vehicleMatchCache = nil
  fuel.vehId = newId
  fuel.ratio = nil
  fuel.volumeL = nil
  fuel.hasTank = false
  fuel.lastProbeAt = -math.huge
  if fuel.refuel and fuel.refuel.active then
    fuel.refuel.active = false
    fuel.refuel.done = true
    M.saveCareerStats()
  end
  if activeJob then
    activeJob.trackedVehId = newId
    activeJob.prevDamage = M.readDamage()
    if activeJob.lastSample then activeJob.lastSample.valid = false end
  end
end

function M.onRebased()
  for i = 1, #fuel.stations do
    local s = fuel.stations[i]
    s._anchor, s._gz, s._quads = nil, nil, nil
  end
  if not activeJob then return end
  activeJob.lastTrack = nil
  if activeJob.lastSample then activeJob.lastSample.valid = false end
  activeJob.stopZ = nil
  activeJob.bayCornersZ = nil
  activeJob.bayGridZ = nil
  activeJob.bayGridVersion = (activeJob.bayGridVersion or 0) + 1
  activeJob._bayCache = nil
  activeJob.stopEnuIdx = nil
  activeJob.stopEnuAnchor = nil
  activeJob.stopZAnchorId = nil
  activeJob.stopZAt = -math.huge
end

function M.reset()
  if activeJob then cleanupJobTrailer(activeJob) end
  activeJob = nil
  pending = nil
  pendingProbe = nil
  summary = nil
  lastError = nil
  vehicleMatchCache = nil
  fuel.stations = {}
  fuel.lastQueryAt = -math.huge
  fuel.lastQueryLat = nil
  fuel.lastQueryLon = nil
  fuel.pendingRoute = false
  fuel.lastProbeAt = -math.huge
  fuel.ratio = nil
  fuel.volumeL = nil
  fuel.hasTank = false
  fuel.refuel = nil
  fuel.routedToFuel = false
  clearOwnedGps()
end

local function updateMetrics(j, dtSim, player)
  if not isFinite(dtSim) or dtSim <= 0 then return end
  j.elapsedS = j.elapsedS + dtSim
  if j.mode == 'taxi' and j.passengerOnBoard then
    j.fareElapsedS = j.fareElapsedS + dtSim
  end

  -- Driven distance (same anchor only; onRebased clears lastTrack)
  local px, py = tonumber(player.x) or 0, tonumber(player.y) or 0
  if isFinite(px) and isFinite(py) then
    if j.lastTrack then
      local step = hypot(px - j.lastTrack.x, py - j.lastTrack.y)
      if isFinite(step) and step <= M.JUMP_RESET_M then
        j.drivenM = j.drivenM + step
        if j.mode == 'taxi' and j.passengerOnBoard then
          j.fareDrivenM = j.fareDrivenM + step
        end
      else
        if j.lastSample then j.lastSample.valid = false end
      end
      j.lastTrack.x = px
      j.lastTrack.y = py
    else
      j.lastTrack = { x = px, y = py }
    end
  end

  -- Vehicle damage / collision tracking (debounced + re-baselined on vehicle switch/reset)
  local curVehId = vehIdOf(M.playerVeh())
  local dmg = tonumber(M.readDamage()) or 0
  if not isFinite(dmg) or dmg < 0 then dmg = 0 end
  if curVehId ~= j.trackedVehId or dmg < (j.prevDamage or 0) then
    j.trackedVehId = curVehId
    j.prevDamage = dmg
  elseif dmg > (j.prevDamage or 0) then
    local delta = dmg - j.prevDamage
    j.damageDelta = j.damageDelta + delta
    if delta >= M.DAMAGE_COLLISION_DELTA and (j.elapsedS - (j.lastCollisionAt or -math.huge)) >= M.COLLISION_COOLDOWN_S then
      j.collisions = j.collisions + 1
      j.lastCollisionAt = j.elapsedS
    end
    j.prevDamage = dmg
  end

  -- Smoothness sampling (0.2 s sim interval)
  j.sampleAcc = j.sampleAcc + dtSim
  if j.sampleAcc >= M.SAMPLE_S then
    local sdt = math.max(0.05, j.sampleAcc)
    j.sampleAcc = 0
    local vx, vy, vz = tonumber(player.vx) or 0, tonumber(player.vy) or 0, tonumber(player.vz) or 0
    if not (isFinite(vx) and isFinite(vy) and isFinite(vz)) then
      if j.lastSample then j.lastSample.valid = false end
      return
    end
    local ls = j.lastSample
    if ls and ls.valid then
      local ax = (vx - ls.vx) / sdt
      local ay = (vy - ls.vy) / sdt
      local az = (vz - ls.vz) / sdt
      local ah = hypot(ax, ay)
      local jerk = ls.ax and math.sqrt(((ax - ls.ax) / sdt) ^ 2 + ((ay - ls.ay) / sdt) ^ 2) or 0
      local isVip = (j.mode == 'taxi' and j.rideArchetype == 'vip')
      local harsh, vertSustain = M.isHarshSample(ah, az, jerk, j.prevVertSpike, isVip)
      j.prevVertSpike = vertSustain
      if harsh then
        j.harshS = j.harshS + sdt
        if j.mode == 'taxi' and j.passengerOnBoard then
          j.fareHarshS = j.fareHarshS + sdt
        end
      end
      ls.vx, ls.vy, ls.vz, ls.ax, ls.ay, ls.valid = vx, vy, vz, ax, ay, true
    else
      if not ls then
        ls = {}
        j.lastSample = ls
      end
      ls.vx, ls.vy, ls.vz, ls.ax, ls.ay, ls.valid = vx, vy, vz, nil, nil, true
    end
  end
end

function M.update(dtReal, dtSim, anchor, player, paused, rebasing)
  local hasFuelWork = (not rebasing and anchor and player)
    and (#fuel.stations > 0 or fuel.refuel ~= nil or (isFinite(player.lat) and isFinite(player.lon)))
  if not hasFuelWork and not activeJob and not pending and not pendingProbe and #despawnQueue == 0 then return end
  local now = M.now()
  if hasFuelWork then
    tickFuel(dtSim, anchor, player, paused, rebasing, now)
  end
  if not activeJob and not pending and not pendingProbe and #despawnQueue == 0 then return end
  if not rebasing then
    tickDespawnQueue(now)
  end
  if pendingProbe then
    local prb = pendingProbe.vehId and vehicleProbes[pendingProbe.vehId]
    if prb or (now - pendingProbe.sentAt >= M.PROBE_TIMEOUT_S) then
      local pr = pendingProbe
      pendingProbe = nil
      dispatchPendingProbe(pr)
    end
  end
  if pending and now - pending.sentAt > M.REQUEST_TIMEOUT_S then
    pending = nil
    lastError = 'Job request timed out'
  end
  if not activeJob or rebasing or not anchor or not player then return end
  local j = activeJob
  local stop = j.stops[j.stopIndex]
  if not stop then finishJob() return end

  local sx, sy, fx, fy, rx, ry
  if j.stopEnuIdx == j.stopIndex and j.stopEnuAnchor == anchor then
    sx, sy, fx, fy, rx, ry = j.stopEnuX, j.stopEnuY, j.stopFx, j.stopFy, j.stopRx, j.stopRy
  else
    sx, sy = anchor:geodeticToEnu(stop.lat, stop.lon, 0)
    local nx, ny = 0, 1
    if anchor.northAt then
      local okN, ax, ay = pcall(anchor.northAt, anchor, sx, sy)
      if okN and tonumber(ax) and tonumber(ay) then nx, ny = ax, ay end
    end
    fx, fy, rx, ry = M.bayFrame(nx, ny, stop.bearing)
    j.stopEnuIdx, j.stopEnuAnchor = j.stopIndex, anchor
    j.stopEnuX, j.stopEnuY, j.stopFx, j.stopFy, j.stopRx, j.stopRy = sx, sy, fx, fy, rx, ry
  end
  local distXY = hypot(sx - player.x, sy - player.y)
  j.distM = distXY

  -- Use GPS road remaining distance & ETA when GPS is tracking this stop
  local okG, g = pcall(M.gps)
  local gs = okG and g and g.status and g.status()
  if gs and gs.lat and gs.lon and math.abs(gs.lat - stop.lat) < 1e-4 and math.abs(gs.lon - stop.lon) < 1e-4 then
    if type(gs.remaining) == 'number' and gs.remaining > distXY * 0.5 then
      j.distM = gs.remaining
    end
    j.etaS = type(gs.eta) == 'number' and gs.eta or nil
  else
    j.etaS = nil
  end

  if not paused and dtSim and dtSim > 0 then
    updateMetrics(j, dtSim, player)
  end
  if j.mode == 'bus' and stop.targetArrivalS then
    j.scheduleDeltaS = math.floor((j.elapsedS - stop.targetArrivalS) + 0.5)
    j.scheduleText = M.formatScheduleDelta(j.scheduleDeltaS)
  end

  local spec = M.baySpec(j.mode, j.tier)

  -- Station-staged trailer spawning (< 160 m) & hitch auto-coupling (<= 2.8 m)
  if j.mode == 'logistics' then
    local upLeg = j.legs and j.legs[j.stopIndex] or nil
    if stop.kind == 'loading' and upLeg and upLeg.legKind == 'loaded_trailer'
        and not j.playerOwnedTrailer and not j.trailerId
        and not (j.stagedAttempted and j.stagedAttempted[j.stopIndex])
        and distXY <= M.TRAILER_STAGE_DIST_M then
      stageTrailerAtBay(j, stop, sx, sy, fx, fy, rx, ry, upLeg, player.z)
    end
    if j.trailerState == 'staged' and tickStagedCoupling(j, now, player) then
      local nextStop = j.stops[j.stopIndex + 1]
      local legInfo = upLeg and upLeg.cargoLabel or 'freight'
      advanceStop(true, false)
      if nextStop then
        M.say(string.format('Trailer hitched! Deliver %s to %s', legInfo, nextStop.name or 'destination'), 5)
      end
      return
    end
  end

  -- Ground height near stop & 3x5 bay terrain grid for bridge/overpass protection + slope-hugging marker
  if distXY <= M.DRAW_RADIUS_M and (j.stopZ == nil or now - j.stopZAt >= 0.75) then
    local zTop = (player.z or 0) + 40
    local gz = M.castRay(sx, sy, zTop, 120)
    if gz then
      local gridChanged = (j.stopZ == nil) or (math.abs(gz - j.stopZ) > 1e-3)
      j.stopZ = gz
      j.stopZAt = now
      local hl, hw = spec.halfL, spec.halfW
      local grid = j.bayGridZ
      local nu, nv = 5, 3
      if not grid then
        grid = {}
        for iu = 1, nu do grid[iu] = {} end
        j.bayGridZ = grid
        gridChanged = true
      end
      local zProbeTop = gz + 12
      for iu = 1, nu do
        local u = (iu - 1) / (nu - 1)
        local al = -hl + u * (2 * hl)
        local row = grid[iu]
        for iv = 1, nv do
          local v = (iv - 1) / (nv - 1)
          local ac = -hw + v * (2 * hw)
          local zVal = M.castRay(sx + al * fx + ac * rx, sy + al * fy + ac * ry, zProbeTop, 36) or gz
          if row[iv] == nil or math.abs(zVal - row[iv]) > 1e-3 then
            gridChanged = true
          end
          row[iv] = zVal
        end
      end
      if gridChanged then
        j.bayGridVersion = (j.bayGridVersion or 0) + 1
      end
      local cornersZ = j.bayCornersZ
      if not cornersZ then
        cornersZ = {}
        j.bayCornersZ = cornersZ
      end
      cornersZ.fl = grid[nu][nv]
      cornersZ.fr = grid[nu][1]
      cornersZ.bl = grid[1][nv]
      cornersZ.br = grid[1][1]
    end
  end
  local dz = j.stopZ and ((player.z or 0) - j.stopZ) or nil
  local longOff, latOff = M.bayOffsets(player.x, player.y, sx, sy, fx, fy, rx, ry)
  local heightOk = (dz == nil) or (math.abs(dz) <= M.HEIGHT_TOL_M)
  j.inBay = heightOk and math.abs(latOff) <= spec.latTol and math.abs(longOff) <= spec.longTol
  j.inFallback = (not j.inBay) and heightOk and distXY <= M.FALLBACK_RADIUS_M

  -- Enforce trailer presence on loaded_trailer deliveries & block premature dwell while staged
  local curLeg = (j.stopIndex >= 2) and j.legs and j.legs[j.stopIndex - 1] or nil
  local upLeg = j.legs and j.legs[j.stopIndex] or nil
  local blockDwell = false
  if j.mode == 'logistics' then
    if stop.kind == 'loading' and j.trailerState == 'staged' then
      blockDwell = true
    elseif stop.kind == 'delivery' and curLeg and curLeg.legKind == 'loaded_trailer' then
      local pv = M.playerVeh()
      local pvId = vehIdOf(pv)
      local attachedOk = M.isTrailerAttachedToJob(j, pvId)
      if not attachedOk and j.trailerId and pv and pvId then
        local trl = rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(j.trailerId)
        if trl and tryCoupleToTrailer(j, now, player, pv, pvId, trl) then
          attachedOk = true
        end
      end
      j.trailerDetached = not attachedOk
      if not attachedOk and (j.inBay or j.inFallback) then
        blockDwell = true
        j.trailerMissing = true
        j.bayHint = 'Trailer missing · Go back & hitch your trailer'
        if (now - (j.lastMissingSayAt or -math.huge)) >= 8.0 then
          j.lastMissingSayAt = now
          M.say('Trailer missing · Go back & hitch your trailer', 5)
        end
      else
        j.trailerMissing = false
        j.bayHint = nil
      end
    else
      j.trailerDetached = false
      j.trailerMissing = false
      j.bayHint = nil
    end
  end

  if blockDwell then
    j.dwellS = 0
    j.dwellMode = 'none'
    return
  end

  local lkForDwell = (stop.kind == 'loading') and (upLeg and upLeg.legKind) or (curLeg and curLeg.legKind)
  local stopTarget = stop.dwellTargetS or M.defaultDwellTargetS(j.mode, j.tier, stop, j.cargoKg, lkForDwell)
  local state, nextDwell, nextMode, targetS = M.stepBayStop(
    j.dwellS, j.dwellMode, distXY, longOff, latOff, dz, player.speed or 0, spec, dtSim, paused, stopTarget
  )
  j.dwellS = nextDwell
  j.dwellMode = nextMode
  j.dwellTargetS = targetS
  if state == 'complete' then
    advanceStop(true, false)
  elseif state == 'fallback_complete' then
    advanceStop(true, true)
  end
end

M.BAY_FLOAT_H = 0.10
M.BAY_TOP_H = 0.65
M.BAY_CORNER_R = 0.55
M.BAY_CORNER_SEGS = 6
M.BAY_CORNER_W = 0.12
M.BAY_BAR_W = 0.16
M.BAY_BAR_H = 0.14
M.BAY_CORNER_BANDS = {
  { 0.10, 0.24 },
  { 0.305, 0.445 },
  { 0.51, 0.65 },
}
M.BAY_IDLE_GREY = { 0.78, 0.80, 0.84, 0.44 }
M.BAY_ALIGNED_GREEN = { 0.25, 0.85, 0.52, 0.62 }
M.BAY_PARTIAL_AMBER = { 0.92, 0.68, 0.28, 0.55 }

local function lerp(a, b, t) return a + (b - a) * t end

-- Pure: select subtle grey / soft emerald green / soft warm amber RGBA for the floating park box.
function M.bayFrameColor(inBay, inFallback, dwellMode, trailerState, trailerMissing)
  if trailerMissing or dwellMode == 'fallback' or inFallback or trailerState == 'staged' then
    return M.BAY_PARTIAL_AMBER
  end
  if inBay or dwellMode == 'bay' then
    return M.BAY_ALIGNED_GREEN
  end
  return M.BAY_IDLE_GREY
end

-- Pure: bilinearly sample 3x5 bay terrain height grid at normalized (u, v) in [0, 1]^2.
function M.sampleBayGridZ(grid, u, v, zFallback)
  if type(grid) ~= 'table' or #grid < 2 then return zFallback end
  local nu = #grid
  local nv = type(grid[1]) == 'table' and #grid[1] or 0
  if nv < 2 then return zFallback end
  u = math.max(0, math.min(1, tonumber(u) or 0.5))
  v = math.max(0, math.min(1, tonumber(v) or 0.5))
  local fu = u * (nu - 1) + 1
  local fv = v * (nv - 1) + 1
  local iu0 = math.min(nu - 1, math.floor(fu))
  local iv0 = math.min(nv - 1, math.floor(fv))
  local tu, tv = fu - iu0, fv - iv0
  local z00 = grid[iu0][iv0] or zFallback
  local z01 = grid[iu0][iv0 + 1] or zFallback
  local z10 = grid[iu0 + 1][iv0] or zFallback
  local z11 = grid[iu0 + 1][iv0 + 1] or zFallback
  return lerp(lerp(z00, z01, tv), lerp(z10, z11, tv), tu)
end

-- Pure: build compact 3D stacked corner-bracket + segmented floating enclosure suspended >= 0.10 m above terrain.
function M.buildBayQuads(sx, sy, fx, fy, rx, ry, spec, zFn, col, radiusM, cornerW)
  local hl, hw = spec.halfL, spec.halfW
  local r = math.min(tonumber(radiusM) or M.BAY_CORNER_R, hw - 0.15, hl - 0.15)
  local cw = tonumber(cornerW) or M.BAY_CORNER_W
  local segs = M.BAY_CORNER_SEGS
  local c = col or M.BAY_IDLE_GREY
  local ihl, ihw = hl - r, hw - r

  local function clamp01(v) return math.max(0, math.min(1, v)) end
  local function pt(along, across, z)
    return { x = sx + along * fx + across * rx, y = sy + along * fy + across * ry, z = z }
  end

  local quads = {}
  local function emitQuad(p0, p1, p2, p3, kind, face, shade, meta)
    quads[#quads + 1] = {
      kind = kind,
      face = face,
      shade = shade,
      band = meta.band,
      corner = meta.corner,
      edge = meta.edge,
      segmentId = meta.segmentId,
      widthM = meta.widthM,
      heightM = meta.heightM,
      liftM = meta.liftM,
      topM = meta.topM,
      p0 = p0,
      p1 = p1,
      p2 = p2,
      p3 = p3,
      r = clamp01(c[1] * shade),
      g = clamp01(c[2] * shade),
      b = clamp01(c[3] * shade),
      a = c[4],
    }
  end

  local function extrudeStrip(pts, widthM, z0, z1, kind, baseShade, meta)
    local n = #pts
    if n < 2 then return end
    local halfT = widthM * 0.5
    local ob, ot, ib, it = {}, {}, {}, {}
    for i = 1, n do
      local p = pts[i]
      local gz = zFn(p.a, p.c)
      local zb, zt = gz + z0, gz + z1
      ob[i] = pt(p.a + p.na * halfT, p.c + p.nc * halfT, zb)
      ot[i] = pt(p.a + p.na * halfT, p.c + p.nc * halfT, zt)
      ib[i] = pt(p.a - p.na * halfT, p.c - p.nc * halfT, zb)
      it[i] = pt(p.a - p.na * halfT, p.c - p.nc * halfT, zt)
    end
    meta.widthM = widthM
    meta.heightM = z1 - z0
    meta.liftM = z0
    meta.topM = z1
    for i = 1, n - 1 do
      local j = i + 1
      emitQuad(ob[i], ob[j], ot[j], ot[i], kind, 'outer', baseShade, meta)
      emitQuad(ib[j], ib[i], it[i], it[j], kind, 'inner', baseShade * 0.86, meta)
      emitQuad(ot[i], ot[j], it[j], it[i], kind, 'top', baseShade * 1.08, meta)
    end
    emitQuad(ib[1], ob[1], ot[1], it[1], kind, 'cap', baseShade * 0.92, meta)
    emitQuad(ob[n], ib[n], it[n], ot[n], kind, 'cap', baseShade * 0.92, meta)
  end

  -- 1. Four rounded 3D corner posts with 3 stacked bands (0.10 m -> 0.65 m)
  local corners = {
    { id = 'fl', ca = ihl,  cc = ihw,  ang0 = 0,              ang1 = math.pi * 0.5 },
    { id = 'bl', ca = -ihl, cc = ihw,  ang0 = math.pi * 0.5,  ang1 = math.pi },
    { id = 'br', ca = -ihl, cc = -ihw, ang0 = math.pi,        ang1 = math.pi * 1.5 },
    { id = 'fr', ca = ihl,  cc = -ihw, ang0 = math.pi * 1.5,  ang1 = math.pi * 2.0 },
  }
  local bandShades = { 0.92, 1.00, 1.06 }
  for _, cn in ipairs(corners) do
    local pts = {}
    for i = 0, segs do
      local ang = cn.ang0 + (i / segs) * (cn.ang1 - cn.ang0)
      local nx, nc = math.cos(ang), math.sin(ang)
      pts[i + 1] = { a = cn.ca + r * nx, c = cn.cc + r * nc, na = nx, nc = nc }
    end
    for bi, bnd in ipairs(M.BAY_CORNER_BANDS) do
      extrudeStrip(pts, cw, bnd[1], bnd[2], 'corner_band', bandShades[bi] or 1.0, {
        band = bi,
        corner = cn.id,
        segmentId = cn.id .. '_b' .. bi,
      })
    end
  end

  -- 2. Disconnected segmented 3D bars along left, right, front, and rear edges
  local edges = {
    { id = 'left',  a0 = ihl,  c0 = hw,   a1 = -ihl, c1 = hw,   na = 0,  nc = 1 },
    { id = 'rear',  a0 = -hl,  c0 = ihw,  a1 = -hl,  c1 = -ihw, na = -1, nc = 0 },
    { id = 'right', a0 = -ihl, c0 = -hw,  a1 = ihl,  c1 = -hw,  na = 0,  nc = -1 },
    { id = 'front', a0 = hl,   c0 = -ihw, a1 = hl,   c1 = ihw,  na = 1,  nc = 0 },
  }
  local barW = M.BAY_BAR_W
  local barZ0 = M.BAY_FLOAT_H
  local barZ1 = M.BAY_FLOAT_H + M.BAY_BAR_H
  for _, ed in ipairs(edges) do
    local da, dc = ed.a1 - ed.a0, ed.c1 - ed.c0
    local edgeLen = math.sqrt(da * da + dc * dc)
    local cornerGap = math.min(0.42, edgeLen * 0.22)
    local avail = edgeLen - 2 * cornerGap
    if avail >= 0.45 then
      local nBars = math.max(1, math.floor((avail + 0.42) / 1.50))
      local gap = (nBars > 1) and math.min(0.45, (avail * 0.36) / (nBars - 1)) or 0
      local barLen = (avail - gap * (nBars - 1)) / nBars
      if barLen >= 0.35 then
        for bi = 1, nBars do
          local s0 = cornerGap + (bi - 1) * (barLen + gap)
          local s1 = s0 + barLen
          local t0, t1 = s0 / edgeLen, s1 / edgeLen
          local nSub = barLen > 1.2 and 2 or 1
          local pts = {}
          for k = 0, nSub do
            local t = t0 + (t1 - t0) * (k / nSub)
            pts[k + 1] = {
              a = ed.a0 + da * t,
              c = ed.c0 + dc * t,
              na = ed.na,
              nc = ed.nc,
            }
          end
          extrudeStrip(pts, barW, barZ0, barZ1, 'edge_bar', 0.96, {
            edge = ed.id,
            segmentId = ed.id .. '_' .. bi,
          })
        end
      end
    end
  end

  return quads
end

-- Pure: update quad RGBA colors in-place without rebuilding 3D vertices.
function M.recolorBayQuads(quads, col)
  if type(quads) ~= 'table' or type(col) ~= 'table' then return end
  local r0, g0, b0, a0 = col[1], col[2], col[3], col[4]
  for i = 1, #quads do
    local q = quads[i]
    local sh = q.shade or 1.0
    local r = r0 * sh; if r < 0 then r = 0 elseif r > 1 then r = 1 end
    local g = g0 * sh; if g < 0 then g = 0 elseif g > 1 then g = 1 end
    local b = b0 * sh; if b < 0 then b = 0 elseif b > 1 then b = 1 end
    q.r, q.g, q.b, q.a = r, g, b, a0
  end
end

function M._bayCacheBuilds()
  return activeJob and activeJob._bayCacheBuilds or 0
end

-- Pure: build compact, subtle 3D Fuel Pump Bay corner brackets (cyan-tinted, no edge bars).
function M.buildFuelBayQuads(sx, sy, fx, fy, rx, ry, spec, zFn, col)
  local all = M.buildBayQuads(sx, sy, fx, fy, rx, ry, spec or M.FUEL_BAY_SPEC, zFn, col or M.FUEL_BAY_IDLE_CYAN)
  local out = {}
  for i = 1, #all do
    if all[i].kind == 'corner_band' then
      out[#out + 1] = all[i]
    end
  end
  return out
end

local function emitQuads(dd, quads)
  if not scratchP0 then
    scratchP0 = vec3(0, 0, 0)
    scratchP1 = vec3(0, 0, 0)
    scratchP2 = vec3(0, 0, 0)
    scratchP3 = vec3(0, 0, 0)
    scratchCol = ColorF(1, 1, 1, 1)
  end
  if dd.drawQuadSolid then
    for i = 1, #quads do
      local q = quads[i]
      scratchP0:set(q.p0.x, q.p0.y, q.p0.z)
      scratchP1:set(q.p1.x, q.p1.y, q.p1.z)
      scratchP2:set(q.p2.x, q.p2.y, q.p2.z)
      scratchP3:set(q.p3.x, q.p3.y, q.p3.z)
      scratchCol.r, scratchCol.g, scratchCol.b, scratchCol.a = q.r, q.g, q.b, q.a
      dd:drawQuadSolid(scratchP0, scratchP1, scratchP2, scratchP3, scratchCol)
    end
  elseif dd.drawTriSolid then
    for i = 1, #quads do
      local q = quads[i]
      scratchP0:set(q.p0.x, q.p0.y, q.p0.z)
      scratchP1:set(q.p1.x, q.p1.y, q.p1.z)
      scratchP2:set(q.p2.x, q.p2.y, q.p2.z)
      scratchP3:set(q.p3.x, q.p3.y, q.p3.z)
      scratchCol.r, scratchCol.g, scratchCol.b, scratchCol.a = q.r, q.g, q.b, q.a
      dd:drawTriSolid(scratchP0, scratchP1, scratchP2, scratchCol)
      dd:drawTriSolid(scratchP0, scratchP2, scratchP3, scratchCol)
    end
  elseif dd.drawLineInstance then
    for i = 1, #quads do
      local q = quads[i]
      scratchP0:set(q.p0.x, q.p0.y, q.p0.z)
      scratchP1:set(q.p1.x, q.p1.y, q.p1.z)
      scratchCol.r, scratchCol.g, scratchCol.b, scratchCol.a = q.r, q.g, q.b, q.a
      dd:drawLineInstance(scratchP0, scratchP1, 3, scratchCol)
    end
  end
end

local function drawFuelMarkers(dd, anchor, player, hideNearJobStop)
  if #fuel.stations == 0 or hideNearJobStop then return end
  local now = M.now()
  local spec = M.FUEL_BAY_SPEC
  local activeSid = fuel.refuel and (fuel.refuel.active or (fuel.refuel.holdS or 0) > 0) and fuel.refuel.stationId or nil
  for i = 1, #fuel.stations do
    local s = fuel.stations[i]
    if s._anchor ~= anchor then
      local sx, sy = anchor:geodeticToEnu(s.lat, s.lon, 0)
      local nx, ny = 0, 1
      if anchor.northAt then
        local okN, ax, ay = pcall(anchor.northAt, anchor, sx, sy)
        if okN and tonumber(ax) and tonumber(ay) then nx, ny = ax, ay end
      end
      local fx, fy, rx, ry = M.bayFrame(nx, ny, s.bearingDeg)
      s._anchor, s._sx, s._sy, s._fx, s._fy, s._rx, s._ry = anchor, sx, sy, fx, fy, rx, ry
      s._gz = nil
      s._gzAt = -math.huge
      s._quads = nil
    end
    local distXY = hypot(s._sx - player.x, s._sy - player.y)
    if distXY <= M.FUEL_DRAW_RADIUS_M then
      if s._gz == nil or (now - (s._gzAt or -math.huge)) >= 1.5 then
        local gz = M.castRay(s._sx, s._sy, (player.z or 0) + 40, 120)
        if gz then
          if s._gz == nil or math.abs(gz - s._gz) > 0.05 then
            s._quads = nil
          end
          s._gz = gz
          s._gzAt = now
        end
      end
      local zCenter = s._gz or player.z or 0
      local col = (activeSid == s.id) and M.FUEL_BAY_ACTIVE_CYAN or M.FUEL_BAY_IDLE_CYAN
      if not s._quads then
        local function flatZ() return zCenter end
        s._quads = M.buildFuelBayQuads(s._sx, s._sy, s._fx, s._fy, s._rx, s._ry, spec, flatZ, col)
      else
        M.recolorBayQuads(s._quads, col)
      end
      emitQuads(dd, s._quads)
    end
  end
end

function M.drawMarker(anchor, player)
  if not anchor or not player then return end
  if not activeJob and #fuel.stations == 0 then return end
  local dd = rawget(_G, 'debugDrawer')
  if not dd or not ColorF then return end

  local hideFuelNearStop = false
  if activeJob then
    local j = activeJob
    local stop = j.stops[j.stopIndex]
    if stop then
      local sx, sy, fx, fy, rx, ry
      if j.stopEnuIdx == j.stopIndex and j.stopEnuAnchor == anchor then
        sx, sy, fx, fy, rx, ry = j.stopEnuX, j.stopEnuY, j.stopFx, j.stopFy, j.stopRx, j.stopRy
      else
        sx, sy = anchor:geodeticToEnu(stop.lat, stop.lon, 0)
        local nx, ny = 0, 1
        if anchor.northAt then
          local okN, ax, ay = pcall(anchor.northAt, anchor, sx, sy)
          if okN and tonumber(ax) and tonumber(ay) then nx, ny = ax, ay end
        end
        fx, fy, rx, ry = M.bayFrame(nx, ny, stop.bearing)
        j.stopEnuIdx, j.stopEnuAnchor = j.stopIndex, anchor
        j.stopEnuX, j.stopEnuY, j.stopFx, j.stopFy, j.stopRx, j.stopRy = sx, sy, fx, fy, rx, ry
      end

      local distXY = hypot(sx - player.x, sy - player.y)
      if distXY < M.FUEL_HIDE_NEAR_STOP_M then
        hideFuelNearStop = true
      end
      if distXY <= M.DRAW_RADIUS_M then
        local spec = M.baySpec(j.mode, j.tier)
        local zCenter = j.stopZ or player.z or 0
        local hl, hw = spec.halfL, spec.halfW

        local now = M.now()
        local dtVis = j.visAt and math.max(0, math.min(0.25, now - j.visAt)) or 0.05
        j.visAt = now
        local tgtCol = M.bayFrameColor(j.inBay, j.inFallback, j.dwellMode, (distXY <= 25 and j.trailerState or nil), j.trailerMissing)
        local curCol = j.visCol
        if not curCol then
          local g = M.BAY_IDLE_GREY
          curCol = { g[1], g[2], g[3], g[4] }
          j.visCol = curCol
        end
        local tBlend = math.min(1, dtVis * 8.0)
        curCol[1] = lerp(curCol[1], tgtCol[1], tBlend)
        curCol[2] = lerp(curCol[2], tgtCol[2], tBlend)
        curCol[3] = lerp(curCol[3], tgtCol[3], tBlend)
        curCol[4] = lerp(curCol[4], tgtCol[4], tBlend)

        local gridVer = j.bayGridVersion or 0
        local cache = j._bayCache
        if not cache
            or cache.stopIndex ~= j.stopIndex
            or cache.gridVer ~= gridVer
            or cache.spec ~= spec
            or math.abs((cache.zCenter or 0) - zCenter) > 1e-3
            or math.abs((cache.sx or 0) - sx) > 1e-3
            or math.abs((cache.sy or 0) - sy) > 1e-3 then
          local function bayZ(along, across)
            local u = math.max(0, math.min(1, (along + hl) / (2 * hl)))
            local v = math.max(0, math.min(1, (across + hw) / (2 * hw)))
            local z = M.sampleBayGridZ(j.bayGridZ, u, v, zCenter)
            return math.max(z, zCenter - 0.25)
          end
          local quads = M.buildBayQuads(sx, sy, fx, fy, rx, ry, spec, bayZ, curCol)
          cache = {
            stopIndex = j.stopIndex,
            gridVer = gridVer,
            spec = spec,
            zCenter = zCenter,
            sx = sx,
            sy = sy,
            quads = quads,
          }
          j._bayCache = cache
          j._bayCacheBuilds = (j._bayCacheBuilds or 0) + 1
        else
          M.recolorBayQuads(cache.quads, curCol)
        end
        emitQuads(dd, cache.quads)
      end
    end
  end

  drawFuelMarkers(dd, anchor, player, hideFuelNearStop)
end

-- ImGui fallback HUD only when BeamNGEarthTransport app is not mounted
function M.drawUi(hiddenByUi)
  if (not activeJob and not summary) or hiddenByUi then return end
  local im = rawget(_G, 'ui_imgui')
  if not im or not im.Begin then return end
  local vp = im.GetMainViewport and im.GetMainViewport()
  if vp then
    im.SetNextWindowPos(im.ImVec2(vp.Pos.x + vp.Size.x - 16, vp.Pos.y + 110), im.Cond_Always, im.ImVec2(1, 0))
  end
  local flags = im.WindowFlags_AlwaysAutoResize + im.WindowFlags_NoCollapse + im.WindowFlags_NoSavedSettings
  if im.Begin('Transport Job##beamngEarthTransport', nil, flags) then
    if activeJob then
      local stop = activeJob.stops[activeJob.stopIndex]
      local stype = (stop and stop.stopType == 'loading_bay') and 'Loading Bay' or 'Kerbside Stop'
      im.TextUnformatted(string.format('%s · %s | Stop %d/%d', activeJob.mode:upper(), stype, activeJob.stopIndex, #activeJob.stops))
      im.TextUnformatted(stop and stop.name or '')
      if stop and stop.address ~= '' then im.TextUnformatted(stop.address) end
      if activeJob.mode == 'taxi' then
        local fare = M.computeTaxiFare(activeJob)
        local rLbl = activeJob.rideLabel or 'Standard Ride'
        local pax = activeJob.taxiPaxCount or 1
        im.TextUnformatted(string.format('%s · %d pax', rLbl, pax))
        im.TextUnformatted(activeJob.passengerOnBoard and string.format('On board · Meter: $%.2f', fare) or 'En route to pickup')
      elseif activeJob.mode == 'bus' then
        local nextStop = activeJob.stops[activeJob.stopIndex + 1]
        im.TextUnformatted(string.format('Load: %d/%d pax · %s', activeJob.paxCount or 0, activeJob.paxCapacity or M.BUS_CAPACITY, activeJob.scheduleText or 'On Time'))
        if nextStop then im.TextUnformatted('Next Stop after this: ' .. nextStop.name) end
      elseif activeJob.mode == 'parcel' then
        local actLbl = (stop and stop.parcelAction == 'pickup_return') and 'Return pickup' or 'Deliver'
        local rec = (stop and stop.recipient) and (' · ' .. stop.recipient) or ''
        im.TextUnformatted(string.format('%s %dx%s', actLbl, (stop and stop.parcelCount) or 1, rec))
        im.TextUnformatted(string.format('Manifest: %d/%d parcels left · %.0f kg', activeJob.parcelsRemaining or 0, activeJob.parcelsTotal or 0, activeJob.cargoCurrentKg or 0))
      elseif activeJob.mode == 'logistics' then
        local leg = M.activeLegInfo(activeJob, legInfoScratch)
        if leg and leg.legLabel then
          im.TextUnformatted(leg.legLabel)
        end
        if activeJob.bayHint then
          im.TextUnformatted(activeJob.bayHint)
        end
      end
      if activeJob.distM then im.TextUnformatted(string.format('Distance: %.0f m', activeJob.distM)) end
      if activeJob.dwellS > 0 then
        local targetS = activeJob.dwellTargetS or M.BAY_DWELL_S
        local rem = math.max(0, targetS - activeJob.dwellS)
        local curLeg = (activeJob.stopIndex >= 2) and activeJob.legs and activeJob.legs[activeJob.stopIndex - 1] or nil
        local upLeg = activeJob.legs and activeJob.legs[activeJob.stopIndex] or nil
        local lbl = M.dwellStatusLabel(activeJob.mode, stop and stop.kind, activeJob.dwellMode, curLeg and curLeg.legKind, upLeg and upLeg.legKind, activeJob.trailerState, stop)
        im.TextUnformatted(string.format('%s: %.1f / %.1f s (%.1f s left)', lbl, activeJob.dwellS, targetS, rem))
      end
      if im.Button('Skip Stop') then M.skipStop() end
      im.SameLine()
      if im.Button('Cancel') then M.cancelJob() end
    elseif summary then
      im.TextUnformatted(string.format('Job Complete (%s)', summary.mode:upper()))
      im.TextUnformatted(string.format('Stops: %d/%d · Score: %d/100', summary.stopsCompleted, summary.stopCount, summary.score))
      if summary.mode == 'taxi' and summary.totalFare and summary.totalFare > 0 then
        im.TextUnformatted(string.format('Fare: $%.2f + Tip $%.2f = $%.2f', summary.fare or 0, summary.tip or 0, summary.totalFare))
      end
      im.TextUnformatted(string.format('Distance: %.2f km · Time: %d s', summary.drivenM / 1000, summary.elapsedS))
      if summary.mode == 'taxi' then
        if im.Button('Next Passenger') then M.nextPassenger() end
        im.SameLine()
      end
      if im.Button('Dismiss') then M.dismissSummary() end
    end
  end
  im.End()
end

local function isMetric()
  local ok, g = pcall(M.gps)
  return ok and g and g.metric and g.metric() == true or false
end

function M.hudPayload()
  local c = M.core()
  local st = c and c._state and c._state()
  local pl = st and st.player or nil
  local fuelPct, lowFuel, nearestFuel, refuelInfo = fuelSnapshot(pl)
  if not activeJob and not summary and not pending and not pendingProbe then
    if refuelInfo then
      return {
        state = 'refueling',
        fuelPct = fuelPct,
        lowFuel = lowFuel,
        nearestFuelStation = nearestFuel,
        refueling = refuelInfo,
        metric = isMetric(),
      }
    end
    return nil
  end
  local metric = isMetric()
  if activeJob then
    local stop = activeJob.stops[activeJob.stopIndex]
    local score = M.computeScore(activeJob)
    local targetS = activeJob.dwellTargetS or M.BAY_DWELL_S
    local fare = activeJob.mode == 'taxi' and M.computeTaxiFare(activeJob) or nil
    local nextStop = activeJob.stops[activeJob.stopIndex + 1]
    local legInfo = activeJob.mode == 'logistics' and M.activeLegInfo(activeJob, legInfoScratch) or nil
    local curLeg = (activeJob.stopIndex >= 2) and activeJob.legs and activeJob.legs[activeJob.stopIndex - 1] or nil
    local upLeg = activeJob.legs and activeJob.legs[activeJob.stopIndex] or nil
    local dLbl = M.dwellStatusLabel(activeJob.mode, stop and stop.kind, activeJob.dwellMode, curLeg and curLeg.legKind, upLeg and upLeg.legKind, activeJob.trailerState, stop)
    return {
      state = 'active',
      mode = activeJob.mode,
      tier = activeJob.tier,
      title = activeJob.title,
      stopIndex = activeJob.stopIndex,
      stopCount = #activeJob.stops,
      stopName = stop and stop.name or '',
      stopAddress = stop and stop.address or '',
      stopLocality = stop and stop.locality or '',
      stopSectorLabel = stop and stop.sectorLabel or '',
      stopKind = stop and stop.kind or '',
      stopType = stop and stop.stopType or 'kerbside',
      nextStopName = nextStop and nextStop.name or nil,
      nextStopLocality = nextStop and nextStop.locality or nil,
      nextStopSectorLabel = nextStop and nextStop.sectorLabel or nil,
      distM = activeJob.distM and math.floor(activeJob.distM + 0.5) or nil,
      etaS = activeJob.etaS and math.floor(activeJob.etaS + 0.5) or nil,
      dwellS = activeJob.dwellS,
      dwellTargetS = targetS,
      dwellRemainingS = math.max(0, targetS - activeJob.dwellS),
      dwellMode = activeJob.dwellMode or 'none',
      dwellLabel = dLbl,
      dwellFrac = math.min(1, math.max(0, activeJob.dwellS / targetS)),
      inBay = activeJob.inBay == true,
      inFallback = activeJob.inFallback == true,
      score = score,
      fare = fare,
      passengerOnBoard = activeJob.passengerOnBoard == true,
      rideArchetype = activeJob.mode == 'taxi' and activeJob.rideArchetype or nil,
      rideLabel = activeJob.mode == 'taxi' and activeJob.rideLabel or nil,
      fareMult = activeJob.mode == 'taxi' and activeJob.fareMult or nil,
      tipMult = activeJob.mode == 'taxi' and activeJob.tipMult or nil,
      paxCount = (activeJob.mode == 'bus' and (activeJob.paxCount or 0)) or (activeJob.mode == 'taxi' and (activeJob.taxiPaxCount or 1)) or nil,
      paxCapacity = activeJob.mode == 'bus' and (activeJob.paxCapacity or M.BUS_CAPACITY) or nil,
      scheduleDeltaS = activeJob.mode == 'bus' and (activeJob.scheduleDeltaS or 0) or nil,
      scheduleText = activeJob.mode == 'bus' and (activeJob.scheduleText or 'On Time') or nil,
      cargoLabel = legInfo and legInfo.cargoLabel or nil,
      cargoKg = legInfo and legInfo.cargoKg or nil,
      cargoCurrentKg = activeJob.cargoCurrentKg or 0,
      legKind = legInfo and legInfo.legKind or nil,
      legLabel = legInfo and legInfo.legLabel or nil,
      trailerLabel = legInfo and legInfo.trailerLabel or nil,
      trailerState = activeJob.trailerState ~= 'none' and activeJob.trailerState or nil,
      trailerDetached = activeJob.trailerDetached == true,
      trailerMissing = activeJob.trailerMissing == true,
      bayHint = activeJob.bayHint or nil,
      recipient = (activeJob.mode == 'parcel' and stop and stop.recipient) or nil,
      parcelCount = (activeJob.mode == 'parcel' and stop and stop.parcelCount) or nil,
      parcelAction = (activeJob.mode == 'parcel' and stop and stop.parcelAction) or nil,
      parcelsRemaining = activeJob.mode == 'parcel' and (activeJob.parcelsRemaining or 0) or nil,
      parcelsTotal = activeJob.mode == 'parcel' and (activeJob.parcelsTotal or 0) or nil,
      parcelsDelivered = activeJob.mode == 'parcel' and (activeJob.parcelsDelivered or 0) or nil,
      parcelsReturned = activeJob.mode == 'parcel' and (activeJob.parcelsReturned or 0) or nil,
      cargoPropsCount = activeJob.cargoProps and #activeJob.cargoProps or 0,
      collisions = activeJob.collisions,
      fuelPct = fuelPct,
      lowFuel = lowFuel,
      nearestFuelStation = nearestFuel,
      refueling = refuelInfo,
      metric = metric,
    }
  elseif summary then
    return {
      state = 'summary',
      mode = summary.mode,
      tier = summary.tier,
      title = summary.title,
      stopsCompleted = summary.stopsCompleted,
      stopsSkipped = summary.stopsSkipped,
      fallbackCount = summary.fallbackCount or 0,
      stopCount = summary.stopCount,
      drivenM = summary.drivenM,
      elapsedS = summary.elapsedS,
      score = summary.score,
      smoothnessPct = summary.smoothnessPct,
      timelinessPct = summary.timelinessPct,
      fare = summary.fare,
      tip = summary.tip,
      totalFare = summary.totalFare,
      payout = summary.payout,
      totalEarned = summary.totalEarned,
      driverRank = summary.driverRank,
      rideArchetype = summary.rideArchetype,
      rideLabel = summary.rideLabel,
      paxCount = summary.paxCount,
      cargoLabel = summary.cargoLabel,
      cargoKg = summary.cargoKg,
      parcelsTotal = summary.parcelsTotal,
      parcelsDelivered = summary.parcelsDelivered,
      parcelsReturned = summary.parcelsReturned,
      collisions = summary.collisions,
      damageDelta = summary.damageDelta,
      fuelPct = fuelPct,
      lowFuel = lowFuel,
      nearestFuelStation = nearestFuel,
      refueling = refuelInfo,
      metric = metric,
    }
  end
  local p = pending or pendingProbe
  return {
    state = 'pending', mode = p.mode, tier = p.tier,
    fuelPct = fuelPct, lowFuel = lowFuel, nearestFuelStation = nearestFuel, refueling = refuelInfo,
    metric = metric,
  }
end

function M.status()
  return M.hudPayload()
end

local function getCachedVehicleMatch()
  local pv = M.playerVeh()
  local pvId = vehIdOf(pv)
  local prb = pvId and vehicleProbes[pvId] or nil
  local probeAt = prb and prb.at or nil
  local now = M.now()
  if vehicleMatchCache
      and vehicleMatchCache.vehId == pvId
      and vehicleMatchCache.probeAt == probeAt
      and (now - vehicleMatchCache.at) < M.VEHICLE_MATCH_CACHE_S then
    return vehicleMatchCache.match
  end
  local ge = inspectGeVehicle()
  if prb then
    if (ge.coupler == nil or ge.coupler == 'none') and prb.coupler and prb.coupler ~= 'none' then
      ge.coupler = prb.coupler
    end
    if prb.massKg then ge.massKg = prb.massKg end
    if prb.attached then ge.hasTrailer = true end
  end
  local match = M.vehicleMatchInfo(ge)
  vehicleMatchCache = { vehId = pvId, probeAt = probeAt, at = now, match = match }
  return match
end

function M.uiState()
  local c = M.core()
  local st = c and c._state and c._state()
  local activeTarget = activeJob and (activeJob.dwellTargetS or M.BAY_DWELL_S) or M.BAY_DWELL_S
  local activeStop = activeJob and activeJob.stops[activeJob.stopIndex] or nil
  local activeFare = (activeJob and activeJob.mode == 'taxi') and M.computeTaxiFare(activeJob) or nil
  local p = pending or pendingProbe
  local nextStop = activeJob and activeJob.stops[activeJob.stopIndex + 1] or nil
  local legInfo = (activeJob and activeJob.mode == 'logistics') and M.activeLegInfo(activeJob, legInfoScratch) or nil
  local curLeg = (activeJob and activeJob.stopIndex >= 2) and activeJob.legs and activeJob.legs[activeJob.stopIndex - 1] or nil
  local upLeg = activeJob and activeJob.legs and activeJob.legs[activeJob.stopIndex] or nil
  local dLbl = activeJob and M.dwellStatusLabel(activeJob.mode, activeStop and activeStop.kind, activeJob.dwellMode, curLeg and curLeg.legKind, upLeg and upLeg.legKind, activeJob.trailerState, activeStop) or nil
  return {
    pending = p and { mode = p.mode, tier = p.tier } or nil,
    active = activeJob and {
      mode = activeJob.mode,
      tier = activeJob.tier,
      title = activeJob.title,
      routeRef = activeJob.routeRef,
      source = activeJob.source,
      estimatedKm = activeJob.estimatedKm,
      stopIndex = activeJob.stopIndex,
      stopCount = #activeJob.stops,
      stops = activeJob.stops,
      nextStopName = nextStop and nextStop.name or nil,
      distM = activeJob.distM and math.floor(activeJob.distM + 0.5) or nil,
      etaS = activeJob.etaS and math.floor(activeJob.etaS + 0.5) or nil,
      dwellS = activeJob.dwellS,
      dwellTargetS = activeTarget,
      dwellRemainingS = math.max(0, activeTarget - activeJob.dwellS),
      dwellMode = activeJob.dwellMode or 'none',
      dwellLabel = dLbl,
      dwellFrac = math.min(1, math.max(0, activeJob.dwellS / activeTarget)),
      inBay = activeJob.inBay == true,
      inFallback = activeJob.inFallback == true,
      drivenM = math.floor(activeJob.drivenM + 0.5),
      elapsedS = math.floor(activeJob.elapsedS + 0.5),
      score = select(1, M.computeScore(activeJob)),
      fare = activeFare,
      passengerOnBoard = activeJob.passengerOnBoard == true,
      rideArchetype = activeJob.mode == 'taxi' and activeJob.rideArchetype or nil,
      rideLabel = activeJob.mode == 'taxi' and activeJob.rideLabel or nil,
      fareMult = activeJob.mode == 'taxi' and activeJob.fareMult or nil,
      tipMult = activeJob.mode == 'taxi' and activeJob.tipMult or nil,
      paxCount = (activeJob.mode == 'bus' and (activeJob.paxCount or 0)) or (activeJob.mode == 'taxi' and (activeJob.taxiPaxCount or 1)) or nil,
      paxCapacity = activeJob.mode == 'bus' and (activeJob.paxCapacity or M.BUS_CAPACITY) or nil,
      scheduleDeltaS = activeJob.mode == 'bus' and (activeJob.scheduleDeltaS or 0) or nil,
      scheduleText = activeJob.mode == 'bus' and (activeJob.scheduleText or 'On Time') or nil,
      vehicleClass = activeJob.vehicleClass ~= '' and activeJob.vehicleClass or nil,
      legs = activeJob.legs,
      legKind = legInfo and legInfo.legKind or nil,
      legLabel = legInfo and legInfo.legLabel or nil,
      trailerLabel = legInfo and legInfo.trailerLabel or nil,
      cargoLabel = legInfo and legInfo.cargoLabel or nil,
      cargoKg = legInfo and legInfo.cargoKg or nil,
      cargoCurrentKg = activeJob.cargoCurrentKg or 0,
      trailerState = activeJob.trailerState ~= 'none' and activeJob.trailerState or nil,
      trailerDetached = activeJob.trailerDetached == true,
      trailerMissing = activeJob.trailerMissing == true,
      bayHint = activeJob.bayHint or nil,
      recipient = (activeJob.mode == 'parcel' and activeStop and activeStop.recipient) or nil,
      parcelCount = (activeJob.mode == 'parcel' and activeStop and activeStop.parcelCount) or nil,
      parcelAction = (activeJob.mode == 'parcel' and activeStop and activeStop.parcelAction) or nil,
      parcelsRemaining = activeJob.mode == 'parcel' and (activeJob.parcelsRemaining or 0) or nil,
      parcelsTotal = activeJob.mode == 'parcel' and (activeJob.parcelsTotal or 0) or nil,
      parcelsDelivered = activeJob.mode == 'parcel' and (activeJob.parcelsDelivered or 0) or nil,
      parcelsReturned = activeJob.mode == 'parcel' and (activeJob.parcelsReturned or 0) or nil,
      cargoPropsCount = activeJob.cargoProps and #activeJob.cargoProps or 0,
      collisions = activeJob.collisions,
    } or nil,
    summary = summary,
    career = M.getCareerStats(),
    vehicleMatch = getCachedVehicleMatch(),
    fuelPct = select(1, fuelSnapshot(st and st.player)),
    lowFuel = select(2, fuelSnapshot(st and st.player)),
    nearestFuelStation = select(3, fuelSnapshot(st and st.player)),
    refueling = select(4, fuelSnapshot(st and st.player)),
    error = lastError,
    metric = isMetric(),
    ready = st ~= nil and st.inOurLevel == true and st.player ~= nil,
  }
end

function M.onQuickAccessLoaded()
  local qa = rawget(_G, 'core_quickAccess')
  if not (qa and qa.addEntry) then return end
  qa.addEntry({
    level = M.RADIAL_LEVEL,
    uniqueID = 'beamngEarthTransport',
    generator = function(entries)
      if not activeJob then return end
      table.insert(entries, {
        title = 'Transport: Skip stop',
        icon = 'fastForward',
        uniqueID = 'beamngEarthTransportSkip',
        desc = 'Skip the current transport stop and advance to the next',
        onSelect = function() M.skipStop() return { 'hide' } end,
      })
      table.insert(entries, {
        title = 'Transport: Cancel job',
        icon = 'close',
        uniqueID = 'beamngEarthTransportCancel',
        desc = 'Cancel the active transport job',
        onSelect = function() M.cancelJob() return { 'hide' } end,
      })
    end,
  })
end

M.onExtensionLoaded = function()
  M.loadCareerStats()
  M.onQuickAccessLoaded()
end

return M
