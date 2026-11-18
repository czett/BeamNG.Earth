-- BeamNG.Earth Transport Modes (Taxi, Bus, Logistics): GE extension 'beamngEarth_transportModes'.
-- Zero overhead when inactive: update(), drawMarker(), drawUi() return immediately when no job/pending/summary exists.
-- Pure math & state-machine helpers run under plain luajit for tests (mod/tests/test_transport_modes.lua).
local M = {}

M.MODES = { taxi = true, bus = true, logistics = true }
M.TIERS = {
  taxi = { neighborhood = true, city = true, regional = true },
  bus = { partial = true, full = true },
  logistics = { ['local'] = true, city = true, regional = true, long = true },
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
function M.defaultDwellTargetS(mode, tier, stop, cargoKg)
  mode = type(mode) == 'string' and mode:lower() or ''
  tier = type(tier) == 'string' and tier:lower() or ''
  local kind = stop and tostring(stop.kind or ''):lower() or ''
  local name = stop and tostring(stop.name or ''):lower() or ''
  if mode == 'taxi' then
    local isHub = name:find('airport') or name:find('station') or name:find('terminal') or name:find('hotel') or name:find('hospital')
    if kind == 'pickup' then return isHub and 2.5 or 2.2 end
    return (isHub or tier == 'regional') and 3.0 or 2.5
  elseif mode == 'bus' then
    local isHub = name:find('station') or name:find('terminal') or name:find('hub') or name:find('central')
      or name:find('bahnhof') or name:find('gare') or name:find('airport')
    return isHub and 4.5 or 3.5
  elseif mode == 'logistics' then
    local kg = math.max(0, tonumber(cargoKg) or 0)
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
function M.dwellStatusLabel(mode, stopKind, dwellMode)
  mode = type(mode) == 'string' and mode:lower() or ''
  local kind = type(stopKind) == 'string' and stopKind:lower() or ''
  local base
  if mode == 'taxi' then
    base = (kind == 'pickup') and 'Passenger boarding' or 'Passenger alighting'
  elseif mode == 'bus' then
    base = 'Passengers boarding'
  elseif mode == 'logistics' then
    base = (kind == 'loading') and 'Loading cargo' or 'Unloading cargo'
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

-- Pure: rectangular parking/loading bay dimensions & primary tolerances for mode/tier.
function M.baySpec(mode, tier)
  mode = type(mode) == 'string' and mode:lower() or ''
  tier = type(tier) == 'string' and tier:lower() or ''
  if mode == 'bus' or (mode == 'logistics' and tier ~= 'local') then
    return { width = 3.8, length = 14.0, halfW = 1.9, halfL = 7.0, latTol = M.BAY_LAT_TOL_M, longTol = 7.75 }
  end
  return { width = 3.4, length = 8.5, halfW = 1.7, halfL = 4.25, latTol = M.BAY_LAT_TOL_M, longTol = M.BAY_LONG_TOL_M }
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
  local targetId = j.trailerId or vehIdOf(M.playerVeh())
  if not targetId then return end
  if applyCargoMassToId(targetId, kg) then
    j.cargoAppliedKg = kg
  elseif j.trailerId then
    local pvId = vehIdOf(M.playerVeh())
    if pvId and applyCargoMassToId(pvId, kg) then
      j.cargoAppliedKg = kg
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
  M.say(string.format('%s staged at %s — back up to hitch', j.trailerLabel, stop.name or 'loading bay'), 5)
  return true
end

local function tickStagedCoupling(j, now, player)
  if not j or j.trailerState ~= 'staged' or not j.trailerId then return false end
  local pv = M.playerVeh()
  local pvId = vehIdOf(pv)
  local trl = rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(j.trailerId)
  if not pv or not pvId or not trl then return false end

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

-- Pure: format weight in kg or metric tonnes.
local function fmtCargoWt(kg)
  kg = math.max(0, tonumber(kg) or 0)
  if kg >= 1000 then
    return string.format('%.1f t', kg / 1000)
  end
  return string.format('%d kg', math.floor(kg + 0.5))
end

-- Pure: compute active leg task & cargo display state for Logistics jobs.
function M.activeLegInfo(j)
  if not j or j.mode ~= 'logistics' then return nil end
  local legs = j.legs or {}
  local stopIdx = j.stopIndex or 1
  local curLeg = (stopIdx >= 2) and legs[stopIdx - 1] or nil
  local upLeg = legs[stopIdx]

  if stopIdx == 1 or (curLeg and curLeg.legKind == 'deadhead') then
    if j.trailerState == 'staged' and upLeg and upLeg.legKind == 'loaded_trailer' then
      local tLbl = j.trailerLabel or upLeg.trailerLabel or 'Trailer'
      return {
        legKind = 'deadhead',
        legLabel = 'Hook up ' .. tLbl,
        cargoLabel = nil,
        cargoKg = nil,
        trailerLabel = tLbl,
        trailerModel = upLeg.trailerModel,
      }
    end
    return {
      legKind = 'deadhead',
      legLabel = 'Deadhead · Drive to pickup',
      cargoLabel = nil,
      cargoKg = nil,
      trailerLabel = upLeg and upLeg.trailerLabel or nil,
      trailerModel = upLeg and upLeg.trailerModel or nil,
    }
  end

  if curLeg and curLeg.legKind == 'loaded_trailer' then
    local kg = (tonumber(j.cargoCurrentKg) or 0) > 0 and j.cargoCurrentKg or (tonumber(curLeg.cargoMassKg) or 0)
    local lbl = (curLeg.cargoLabel and curLeg.cargoLabel ~= '') and curLeg.cargoLabel or 'Freight'
    return {
      legKind = 'loaded_trailer',
      legLabel = string.format('Deliver %s · %s', lbl, fmtCargoWt(kg)),
      cargoLabel = lbl,
      cargoKg = kg > 0 and kg or nil,
      trailerLabel = j.trailerLabel or curLeg.trailerLabel,
      trailerModel = curLeg.trailerModel,
    }
  end

  local kg = (tonumber(j.cargoCurrentKg) or 0) > 0 and j.cargoCurrentKg or (curLeg and tonumber(curLeg.cargoMassKg) or 0)
  local lbl = (curLeg and curLeg.cargoLabel and curLeg.cargoLabel ~= '') and curLeg.cargoLabel or (j.cargoLabel ~= '' and j.cargoLabel or 'Cargo')
  local vc = tostring(j.vehicleClass or 'van')
  local vName = vc == 'car' and 'Car' or (vc == 'van' and 'Van' or (vc == 'box_truck' and 'Box Truck' or 'Truck'))
  return {
    legKind = 'loaded_solo',
    legLabel = string.format('Solo %s Cargo · %s', vName, fmtCargoWt(kg)),
    cargoLabel = lbl,
    cargoKg = kg > 0 and kg or nil,
    trailerLabel = nil,
    trailerModel = nil,
  }
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
  local mode = tostring(msg.mode or req.mode)
  local tier = tostring(msg.tier or req.tier)

  local stops = {}
  for _, s in ipairs(msg.stops) do
    local lat, lon = tonumber(s.lat), tonumber(s.lon)
    if lat and lon then
      local stObj = {
        index = tonumber(s.index) or (#stops + 1),
        kind = tostring(s.kind or 'stop'),
        stopType = tostring(s.stopType or 'kerbside'),
        name = tostring(s.name or ('Stop ' .. (#stops + 1))),
        address = tostring(s.address or ''),
        lat = lat,
        lon = lon,
        road = tostring(s.road or ''),
        roadClass = tostring(s.roadClass or ''),
        bidirectional = s.bidirectional == true,
        bearing = tonumber(s.bearing) or 0,
        zoneRadius = math.max(8, math.min(20, tonumber(s.zoneRadius) or M.DEFAULT_ZONE_RADIUS_M)),
        cargoDeltaKg = tonumber(s.cargoDeltaKg) or 0,
        paxBoard = tonumber(s.paxBoard) or 0,
        paxAlight = tonumber(s.paxAlight) or 0,
        targetArrivalS = tonumber(s.targetArrivalS),
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
  }
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
    rideArchetype = j.mode == 'taxi' and j.rideArchetype or nil,
    rideLabel = j.mode == 'taxi' and j.rideLabel or nil,
    paxCount = j.mode == 'taxi' and j.taxiPaxCount or (j.mode == 'bus' and j.paxCount or nil),
    cargoLabel = j.cargoLabel,
    cargoKg = (j.totalCargoHauledKg and j.totalCargoHauledKg > 0) and j.totalCargoHauledKg or j.cargoKg,
  }
  activeJob = nil
  clearOwnedGps()
  local prefix = fallbackFinal and 'Kerbside / Fallback Dropoff · ' or ''
  if summary.mode == 'taxi' and summary.totalFare > 0 then
    M.say(string.format('%sTaxi complete! Fare $%.2f · Score %d/100', prefix, summary.totalFare, summary.score), 8)
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
      local spd = (j.tier == 'regional') and 19.0 or 12.5
      j.targetLegS = math.max(35.0, ((legM * 1.25) / spd) * (j.targetMult or 1.0))
    elseif j.mode == 'bus' and doneStop then
      local cap = j.paxCapacity or M.BUS_CAPACITY
      local cur = j.paxCount or 0
      local alight = math.min(cur, math.max(0, tonumber(doneStop.paxAlight) or 0))
      local board = math.max(0, tonumber(doneStop.paxBoard) or 0)
      j.paxCount = math.max(0, math.min(cap, cur - alight + board))
      applyCargoMassToJob(j, j.paxCount * (j.paxMassPerPaxKg or M.BUS_PAX_MASS_KG))
    elseif j.mode == 'logistics' and doneStop then
      if doneStop.kind == 'loading' then
        local loadKg = nextLeg and (tonumber(nextLeg.cargoMassKg) or 0) or (j.cargoKg or 0)
        j.cargoCurrentKg = loadKg
        j.totalCargoHauledKg = (j.totalCargoHauledKg or 0) + loadKg
        applyCargoMassToJob(j, loadKg)
        if nextLeg and nextLeg.legKind == 'loaded_trailer' and j.trailerId then
          j.trailerState = 'attached'
        end
      else
        local nxtStop = j.stops[doneIdx + 1]
        if nextLeg and nextLeg.legKind ~= 'deadhead' and nxtStop and nxtStop.kind == 'delivery' then
          local remKg = tonumber(nextLeg.cargoMassKg) or math.max(0, (j.cargoCurrentKg or 0) + (doneStop.cargoDeltaKg or 0))
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
  j.stopZ = nil
  j.bayCornersZ = nil
  j.bayGridZ = nil
  j.stopZAnchorId = nil
  j.stopZAt = -math.huge
  j.visGreen = 0
  if j.stopIndex >= #j.stops then
    finishJob(isFallback)
    return
  end
  j.stopIndex = j.stopIndex + 1
  local nxt = j.stops[j.stopIndex]
  j.dwellTargetS = nxt.dwellTargetS or M.defaultDwellTargetS(j.mode, j.tier, nxt, j.cargoKg)
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
  local tier = (summary and summary.mode == 'taxi' and summary.tier) or 'neighborhood'
  summary = nil
  return M.startJob('taxi', tier)
end

function M.onVehicleSwitched(oldId, newId, player)
  if activeJob then
    activeJob.trackedVehId = newId
    activeJob.prevDamage = M.readDamage()
    activeJob.lastSample = nil
  end
end

function M.onRebased()
  if not activeJob then return end
  activeJob.lastTrack = nil
  activeJob.lastSample = nil
  activeJob.stopZ = nil
  activeJob.bayCornersZ = nil
  activeJob.bayGridZ = nil
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
        j.lastSample = nil
      end
    end
    j.lastTrack = { x = px, y = py }
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
      j.lastSample = nil
      return
    end
    local ls = j.lastSample
    if ls then
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
      j.lastSample = { vx = vx, vy = vy, vz = vz, ax = ax, ay = ay }
    else
      j.lastSample = { vx = vx, vy = vy, vz = vz }
    end
  end
end

function M.update(dtReal, dtSim, anchor, player, paused, rebasing)
  local now = M.now()
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

  local sx, sy = anchor:geodeticToEnu(stop.lat, stop.lon, 0)
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
  local nx, ny = 0, 1
  if anchor.northAt then
    local okN, ax, ay = pcall(anchor.northAt, anchor, sx, sy)
    if okN and tonumber(ax) and tonumber(ay) then nx, ny = ax, ay end
  end
  local fx, fy, rx, ry = M.bayFrame(nx, ny, stop.bearing)

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
      j.stopZ = gz
      j.stopZAt = now
      local hl, hw = spec.halfL, spec.halfW
      local function rayC(al, ac)
        return M.castRay(sx + al * fx + ac * rx, sy + al * fy + ac * ry, gz + 12, 36) or gz
      end
      local grid = {}
      local nu, nv = 5, 3
      for iu = 1, nu do
        local u = (iu - 1) / (nu - 1)
        local al = -hl + u * (2 * hl)
        grid[iu] = {}
        for iv = 1, nv do
          local v = (iv - 1) / (nv - 1)
          local ac = -hw + v * (2 * hw)
          grid[iu][iv] = rayC(al, ac)
        end
      end
      j.bayGridZ = grid
      j.bayCornersZ = {
        fl = grid[nu][nv],
        fr = grid[nu][1],
        bl = grid[1][nv],
        br = grid[1][1],
      }
    end
  end
  local dz = j.stopZ and ((player.z or 0) - j.stopZ) or nil
  local longOff, latOff = M.bayOffsets(player.x, player.y, sx, sy, fx, fy, rx, ry)
  local heightOk = (dz == nil) or (math.abs(dz) <= M.HEIGHT_TOL_M)
  j.inBay = heightOk and math.abs(latOff) <= spec.latTol and math.abs(longOff) <= spec.longTol
  j.inFallback = (not j.inBay) and heightOk and distXY <= M.FALLBACK_RADIUS_M

  local stopTarget = stop.dwellTargetS or M.defaultDwellTargetS(j.mode, j.tier, stop, j.cargoKg)
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

local MODE_RGBA = {
  taxi = { 0.96, 0.75, 0.22 },
  bus = { 0.24, 0.74, 0.96 },
  logistics = { 0.94, 0.58, 0.22 },
}
local BAY_GREEN = { 0.22, 0.88, 0.50 }
local FALLBACK_AMBER = { 0.58, 0.86, 0.36 }

local function lerp(a, b, t) return a + (b - a) * t end

-- Pure: smooth distance fade-out for floating 3D target beacon as player enters < 18 m.
function M.beaconAlpha(distXY)
  local d = tonumber(distXY)
  if not d or d ~= d then return 0 end
  if d >= 18.0 then return 1.0 end
  if d <= 8.0 then return 0.0 end
  return (d - 8.0) / 10.0
end

-- Pure: compact floating 3D target beacon (~2.0 m above bay center: slender vertical stem + thin ring).
function M.buildBayBeacon(sx, sy, zCenter, now, distXY, col)
  local fade = M.beaconAlpha(distXY)
  if fade <= 0.02 then return nil end
  local alpha = (col[4] or 0.78) * fade
  local bob = 0.07 * math.sin((tonumber(now) or 0) * 2.2)
  local zRing = zCenter + 2.0 + bob
  local radius = 0.55
  local segs = 16
  local ring = {}
  for i = 1, segs do
    local a0 = ((i - 1) / segs) * 2 * math.pi
    local a1 = (i / segs) * 2 * math.pi
    ring[i] = {
      p0 = { x = sx + math.cos(a0) * radius, y = sy + math.sin(a0) * radius, z = zRing },
      p1 = { x = sx + math.cos(a1) * radius, y = sy + math.sin(a1) * radius, z = zRing },
    }
  end
  return {
    alpha = alpha,
    r = col[1], g = col[2], b = col[3],
    stem = {
      p0 = { x = sx, y = sy, z = zCenter + 0.15 },
      p1 = { x = sx, y = sy, z = zRing - 0.18 },
    },
    ring = ring,
  }
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

-- Pure: build RLS-inspired sleek (~0.11 m) asphalt-style ground markings, soft ~14% floor tint, & guide chevrons.
function M.buildBayQuads(sx, sy, fx, fy, rx, ry, spec, zFn, entryDir, now, colBorder, colBracket, colChevron, colFill)
  local hl, hw = spec.halfL, spec.halfW
  local dir = (entryDir == -1) and -1 or 1
  local quads = {}
  local lineW = 0.11

  local function pt(along, across, lift)
    local z = zFn(along, across) + (lift or 0.05)
    return { x = sx + along * fx + across * rx, y = sy + along * fy + across * ry, z = z }
  end

  local function addStrip(a0, c0, a1, c1, widthM, col, kind, lift)
    local da, dc = a1 - a0, c1 - c0
    local len = math.sqrt(da * da + dc * dc)
    if len < 1e-4 then return end
    local na, nc = -dc / len * (widthM * 0.5), da / len * (widthM * 0.5)
    quads[#quads + 1] = {
      kind = kind or 'rail',
      widthM = widthM,
      p0 = pt(a0 + na, c0 + nc, lift),
      p1 = pt(a1 + na, c1 + nc, lift),
      p2 = pt(a1 - na, c1 - nc, lift),
      p3 = pt(a0 - na, c0 - nc, lift),
      r = col[1], g = col[2], b = col[3], a = col[4],
    }
  end

  -- 1. Soft, low-alpha interior floor tint (~14% opacity) subdivided 4x2 to conform cleanly to terrain grid
  local fillCol = colFill or { colBorder[1], colBorder[2], colBorder[3], 0.14 }
  local nL, nW = 4, 2
  for il = 1, nL do
    local a0 = -hl + ((il - 1) / nL) * (2 * hl)
    local a1 = -hl + (il / nL) * (2 * hl)
    for iw = 1, nW do
      local c0 = -hw + ((iw - 1) / nW) * (2 * hw)
      local c1 = -hw + (iw / nW) * (2 * hw)
      quads[#quads + 1] = {
        kind = 'floor_tint',
        p0 = pt(a0, c0, 0.045),
        p1 = pt(a1, c0, 0.045),
        p2 = pt(a1, c1, 0.045),
        p3 = pt(a0, c1, 0.045),
        r = fillCol[1], g = fillCol[2], b = fillCol[3], a = fillCol[4],
      }
    end
  end

  -- 2. Subtle front stop line (+dir * (hl - 0.06), 0.12 m wide)
  addStrip(dir * (hl - 0.06), -hw + 0.12, dir * (hl - 0.06), hw - 0.12, 0.12, colBracket, 'stop_bar', 0.055)

  -- 3. Thin dashed side border lines (0.11 m wide)
  local armL = math.min(1.45, hl * 0.28)
  local dashLen, gapLen = 1.5, 0.95
  local stepLen = dashLen + gapLen
  local cur = -hl + armL + 0.45
  local railEnd = hl - armL - 0.45
  while cur < railEnd do
    local segEnd = math.min(cur + dashLen, railEnd)
    if segEnd - cur >= 0.35 then
      addStrip(cur, -hw, segEnd, -hw, lineW, colBorder, 'side_rail', 0.05)
      addStrip(cur, hw, segEnd, hw, lineW, colBorder, 'side_rail', 0.05)
    end
    cur = cur + stepLen
  end

  -- 4. Crisp, thin corner L-brackets (0.11 m wide)
  local armW = math.min(0.95, hw * 0.44)
  for _, sl in ipairs({ -1, 1 }) do
    for _, sw in ipairs({ -1, 1 }) do
      addStrip(sl * hl, sw * hw, sl * (hl - armL), sw * hw, lineW, colBracket, 'bracket', 0.055)
      addStrip(sl * hl, sw * hw, sl * hl, sw * (hw - armW), lineW, colBracket, 'bracket', 0.055)
    end
  end

  -- 5. Subtle forward-moving guide chevrons (0.11 m wide)
  local chevSpan = hw * 0.42
  local chevDepth = math.min(0.85, hl * 0.16)
  local phase = ((tonumber(now) or 0) * 1.5) % 1.0
  local fracs = { -0.55, -0.15, 0.25 }
  for idx, frac in ipairs(fracs) do
    local wave = 0.5 + 0.5 * math.cos((phase - (idx - 1) / 3.0) * 2.0 * math.pi)
    local cChev = { colChevron[1], colChevron[2], colChevron[3], math.min(1, colChevron[4] * (0.35 + 0.65 * wave)) }
    local tipAlong = dir * (hl * frac + chevDepth * 0.5)
    local wingAlong = tipAlong - dir * chevDepth
    addStrip(wingAlong, -chevSpan, tipAlong, 0, lineW, cChev, 'chevron', 0.055)
    addStrip(wingAlong, chevSpan, tipAlong, 0, lineW, cChev, 'chevron', 0.055)
  end

  return quads
end

function M.drawMarker(anchor, player)
  if not activeJob or not anchor or not player then return end
  local dd = rawget(_G, 'debugDrawer')
  if not dd or not ColorF then return end
  local j = activeJob
  local stop = j.stops[j.stopIndex]
  if not stop then return end
  local sx, sy = anchor:geodeticToEnu(stop.lat, stop.lon, 0)
  local distXY = hypot(sx - player.x, sy - player.y)
  if distXY > M.DRAW_RADIUS_M then return end

  local spec = M.baySpec(j.mode, j.tier)
  local nx, ny = 0, 1
  if anchor.northAt then
    local okN, ax, ay = pcall(anchor.northAt, anchor, sx, sy)
    if okN and tonumber(ax) and tonumber(ay) then nx, ny = ax, ay end
  end
  local fx, fy, rx, ry = M.bayFrame(nx, ny, stop.bearing)

  local zCenter = j.stopZ or player.z or 0
  local hl, hw = spec.halfL, spec.halfW
  local function bayZ(along, across)
    local u = math.max(0, math.min(1, (along + hl) / (2 * hl)))
    local v = math.max(0, math.min(1, (across + hw) / (2 * hw)))
    local z = M.sampleBayGridZ(j.bayGridZ, u, v, zCenter)
    return math.max(z, zCenter - 0.25)
  end

  local now = M.now()
  local dtVis = j.visAt and math.max(0, math.min(0.25, now - j.visAt)) or 0.05
  j.visAt = now
  local dwellFrac = (j.dwellTargetS and j.dwellTargetS > 0) and math.min(1, math.max(0, j.dwellS / j.dwellTargetS)) or 0
  local targetGreen = 0
  if j.inBay or j.dwellMode == 'bay' then
    targetGreen = 0.45 + 0.55 * dwellFrac
  elseif j.dwellMode == 'fallback' then
    targetGreen = 0.35 * dwellFrac
  end
  j.visGreen = lerp(j.visGreen or 0, targetGreen, math.min(1, dtVis * 8.0))

  local base = MODE_RGBA[j.mode] or MODE_RGBA.taxi
  local tgt = (j.dwellMode == 'fallback') and FALLBACK_AMBER or BAY_GREEN
  local g = j.visGreen
  local rCol = lerp(base[1], tgt[1], g)
  local gCol = lerp(base[2], tgt[2], g)
  local bCol = lerp(base[3], tgt[3], g)

  -- Determine bidirectional approach alignment from player velocity or vector toward bay
  local entryDir = 1
  if stop.bidirectional then
    local pvx, pvy = tonumber(player.vx) or 0, tonumber(player.vy) or 0
    local ax, ay = (hypot(pvx, pvy) > 1.0) and pvx or (sx - player.x), (hypot(pvx, pvy) > 1.0) and pvy or (sy - player.y)
    if (ax * fx + ay * fy) < 0 then entryDir = -1 end
  end

  local fillAlpha = j.inBay and 0.20 or 0.14
  local quads = M.buildBayQuads(
    sx, sy, fx, fy, rx, ry, spec, bayZ, entryDir, now,
    { rCol, gCol, bCol, 0.64 },
    { rCol, gCol, bCol, 0.88 },
    { rCol, gCol, bCol, 0.52 + 0.28 * g },
    { rCol, gCol, bCol, fillAlpha }
  )

  if dd.drawQuadSolid then
    for _, q in ipairs(quads) do
      local col = ColorF(q.r, q.g, q.b, q.a)
      dd:drawQuadSolid(
        vec3(q.p0.x, q.p0.y, q.p0.z),
        vec3(q.p1.x, q.p1.y, q.p1.z),
        vec3(q.p2.x, q.p2.y, q.p2.z),
        vec3(q.p3.x, q.p3.y, q.p3.z),
        col
      )
    end
  elseif dd.drawTriSolid then
    for _, q in ipairs(quads) do
      local col = ColorF(q.r, q.g, q.b, q.a)
      local p0, p1 = vec3(q.p0.x, q.p0.y, q.p0.z), vec3(q.p1.x, q.p1.y, q.p1.z)
      local p2, p3 = vec3(q.p2.x, q.p2.y, q.p2.z), vec3(q.p3.x, q.p3.y, q.p3.z)
      dd:drawTriSolid(p0, p1, p2, col)
      dd:drawTriSolid(p0, p2, p3, col)
    end
  elseif dd.drawLineInstance then
    for _, q in ipairs(quads) do
      if q.kind ~= 'floor_tint' then
        dd:drawLineInstance(vec3(q.p0.x, q.p0.y, q.p0.z), vec3(q.p1.x, q.p1.y, q.p1.z), 3, ColorF(q.r, q.g, q.b, q.a))
      end
    end
  end

  local beacon = M.buildBayBeacon(sx, sy, bayZ(0, 0), now, distXY, { rCol, gCol, bCol, 0.75 })
  if beacon and dd.drawLineInstance then
    local bColObj = ColorF(beacon.r, beacon.g, beacon.b, beacon.alpha)
    local sColObj = ColorF(beacon.r, beacon.g, beacon.b, beacon.alpha * 0.55)
    dd:drawLineInstance(
      vec3(beacon.stem.p0.x, beacon.stem.p0.y, beacon.stem.p0.z),
      vec3(beacon.stem.p1.x, beacon.stem.p1.y, beacon.stem.p1.z),
      2, sColObj
    )
    for _, seg in ipairs(beacon.ring) do
      dd:drawLineInstance(
        vec3(seg.p0.x, seg.p0.y, seg.p0.z),
        vec3(seg.p1.x, seg.p1.y, seg.p1.z),
        3, bColObj
      )
    end
  end
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
      elseif activeJob.mode == 'logistics' then
        local leg = M.activeLegInfo(activeJob)
        if leg and leg.legLabel then
          im.TextUnformatted(leg.legLabel)
        end
      end
      if activeJob.distM then im.TextUnformatted(string.format('Distance: %.0f m', activeJob.distM)) end
      if activeJob.dwellS > 0 then
        local targetS = activeJob.dwellTargetS or M.BAY_DWELL_S
        local rem = math.max(0, targetS - activeJob.dwellS)
        local lbl = M.dwellStatusLabel(activeJob.mode, stop and stop.kind, activeJob.dwellMode)
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
  if not activeJob and not summary and not pending and not pendingProbe then return nil end
  local metric = isMetric()
  if activeJob then
    local stop = activeJob.stops[activeJob.stopIndex]
    local score = M.computeScore(activeJob)
    local targetS = activeJob.dwellTargetS or M.BAY_DWELL_S
    local fare = activeJob.mode == 'taxi' and M.computeTaxiFare(activeJob) or nil
    local nextStop = activeJob.stops[activeJob.stopIndex + 1]
    local legInfo = activeJob.mode == 'logistics' and M.activeLegInfo(activeJob) or nil
    return {
      state = 'active',
      mode = activeJob.mode,
      tier = activeJob.tier,
      title = activeJob.title,
      stopIndex = activeJob.stopIndex,
      stopCount = #activeJob.stops,
      stopName = stop and stop.name or '',
      stopAddress = stop and stop.address or '',
      stopKind = stop and stop.kind or '',
      stopType = stop and stop.stopType or 'kerbside',
      nextStopName = nextStop and nextStop.name or nil,
      distM = activeJob.distM and math.floor(activeJob.distM + 0.5) or nil,
      etaS = activeJob.etaS and math.floor(activeJob.etaS + 0.5) or nil,
      dwellS = activeJob.dwellS,
      dwellTargetS = targetS,
      dwellRemainingS = math.max(0, targetS - activeJob.dwellS),
      dwellMode = activeJob.dwellMode or 'none',
      dwellLabel = M.dwellStatusLabel(activeJob.mode, stop and stop.kind, activeJob.dwellMode),
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
      collisions = activeJob.collisions,
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
      rideArchetype = summary.rideArchetype,
      rideLabel = summary.rideLabel,
      paxCount = summary.paxCount,
      cargoLabel = summary.cargoLabel,
      cargoKg = summary.cargoKg,
      collisions = summary.collisions,
      damageDelta = summary.damageDelta,
      metric = metric,
    }
  end
  local p = pending or pendingProbe
  return { state = 'pending', mode = p.mode, tier = p.tier, metric = metric }
end

function M.status()
  return M.hudPayload()
end

function M.uiState()
  local c = M.core()
  local st = c and c._state and c._state()
  local activeTarget = activeJob and (activeJob.dwellTargetS or M.BAY_DWELL_S) or M.BAY_DWELL_S
  local activeStop = activeJob and activeJob.stops[activeJob.stopIndex] or nil
  local activeFare = (activeJob and activeJob.mode == 'taxi') and M.computeTaxiFare(activeJob) or nil
  local p = pending or pendingProbe
  local nextStop = activeJob and activeJob.stops[activeJob.stopIndex + 1] or nil
  local legInfo = (activeJob and activeJob.mode == 'logistics') and M.activeLegInfo(activeJob) or nil
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
      dwellLabel = M.dwellStatusLabel(activeJob.mode, activeStop and activeStop.kind, activeJob.dwellMode),
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
      collisions = activeJob.collisions,
    } or nil,
    summary = summary,
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

M.onExtensionLoaded = function() M.onQuickAccessLoaded() end

return M
