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
M.PROBE_TIMEOUT_S = 0.25
M.SAMPLE_S = 0.2
M.HARSH_ACCEL_MPS2 = 5.5
M.HARSH_VERT_MPS2 = 10.0
M.HARSH_JERK_MPS3 = 18.0
M.DAMAGE_COLLISION_DELTA = 50
M.COLLISION_COOLDOWN_S = 1.25
M.JUMP_RESET_M = 200.0
M.RADIAL_LEVEL = '/root/sandbox/other/'

-- Taxi fare & scoring constants
M.TAXI_BASE_FARE = 3.50
M.TAXI_PER_KM = 1.85
M.TAXI_MIN_FARE = 5.00

-- Trailer spawning & hitching constants
M.HITCH_ATTEMPTS = { 0.15, 0.35, 0.70, 1.20 }
M.TRAILER_CANDIDATES = {
  fifthwheel = {
    steel = { 'flatbed', 'dryvan', 'container' },
    machinery = { 'flatbed', 'dryvan', 'container' },
    default = { 'dryvan', 'flatbed', 'container', 'frameless_dump' },
  },
  towhitch = {
    heavy = { 'boxutility_large', 'cargotrailer', 'boxutility', 'tsfb' },
    light = { 'boxutility', 'boxutility_large', 'tsfb' },
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
  local meter = math.max(M.TAXI_MIN_FARE, M.TAXI_BASE_FARE + fareKm * M.TAXI_PER_KM)
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
    tip = math.floor(meter * ((scoreHint - 60) / 40.0) * 0.25 * 100 + 0.5) / 100
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
  local collisionPen = collisions * 8 + math.min(45, dmg / 400.0)
  local skipPen = skipped * 20

  local mode = type(m.mode) == 'string' and m.mode:lower() or ''
  if mode == 'taxi' and m.passengerOnBoard == true then
    local fElapsed = math.max(1.0, tonumber(m.fareElapsedS) or elapsed)
    local fHarsh = math.max(0, tonumber(m.fareHarshS) or 0)
    if not isFinite(fHarsh) then fHarsh = 0 end
    local fRatio = math.min(1.0, fHarsh / math.max(5.0, fElapsed * 0.35))
    local paxComfort = math.max(0, math.min(100, math.floor(100 - fRatio * 50 + 0.5)))
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

-- Pure: pick best installed trailer JBeam model for coupler + cargo type/tier.
function M.pickTrailerModel(coupler, cargoType, tier, existsFn)
  existsFn = existsFn or M.modelExists
  local list
  if coupler == 'fifthwheel' then
    local fw = M.TRAILER_CANDIDATES.fifthwheel
    list = fw[cargoType] or fw.default
  elseif coupler == 'towhitch' then
    local tw = M.TRAILER_CANDIDATES.towhitch
    list = (tier == 'city' or tier == 'regional' or tier == 'long') and tw.heavy or tw.light
  else
    return nil
  end
  for _, m in ipairs(list) do
    if existsFn(m) then return m end
  end
  return nil
end

-- Pure: generate candidate trailer spawn positions behind player vehicle.
function M.trailerSpawnCandidates(px, py, pz, fx, fy, playerHalfLen, trailerHalfLen)
  local l = math.sqrt(fx * fx + fy * fy)
  if l < 1e-6 then fx, fy = 0, 1 else fx, fy = fx / l, fy / l end
  local backDist = (tonumber(playerHalfLen) or 2.6) + (tonumber(trailerHalfLen) or 3.5) + 1.4
  local out = {}
  for _, deg in ipairs({ 0, 15, -15, 25, -25 }) do
    local rad = math.rad(deg)
    local c, s = math.cos(rad), math.sin(rad)
    local dfx, dfy = fx * c - fy * s, fx * s + fy * c
    out[#out + 1] = {
      x = px - dfx * backDist,
      y = py - dfy * backDist,
      z = pz,
      dirX = dfx,
      dirY = dfy,
      backDist = backDist,
      angleDeg = deg,
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

local PROBE_VE = [[
local totalMass, coupler, couplerCid = 0, 'none', -1
if v and v.data and type(v.data.nodes) == 'table' and obj and obj.getNodeMass then
  for _, nd in pairs(v.data.nodes) do
    if type(nd) == 'table' and tonumber(nd.cid) then
      local ok, m = pcall(obj.getNodeMass, obj, tonumber(nd.cid))
      if ok and type(m) == 'number' and m > 0 and m < 1e5 then totalMass = totalMass + m end
      if type(nd.couplerTag) == 'string' then
        local tag = nd.couplerTag:lower()
        if tag:find('fifthwheel') then
          coupler, couplerCid = 'fifthwheel', tonumber(nd.cid)
        elseif coupler == 'none' and (tag:find('towhitch') or tag:find('pintle')) then
          coupler, couplerCid = 'towhitch', tonumber(nd.cid)
        end
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
  local mtype, cfgName = '', ''
  local cv = rawget(_G, 'core_vehicles')
  if cv and cv.getCurrentVehicleDetails then
    local okD, det = pcall(cv.getCurrentVehicleDetails)
    if okD and type(det) == 'table' then
      mtype = det.model and tostring(det.model.Type or '') or ''
      cfgName = det.configs and tostring(det.configs.Name or '') or ''
      if jbeam == '' and det.model and det.model.key then jbeam = tostring(det.model.key) end
    end
  end
  local attId = id and findAttachedTrailerId(id) or nil
  return {
    vehId = id,
    jbeam = jbeam,
    modelType = mtype,
    configName = cfgName,
    lengthM = lenM,
    hasTrailer = attId ~= nil,
    attachedTrailerId = attId,
  }
end

local function applyCargoMassToJob(j, kg)
  if not j then return end
  kg = math.max(0, tonumber(kg) or 0)
  local targetId = j.trailerId or vehIdOf(M.playerVeh())
  if not targetId then return end
  local obj = rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(targetId)
  if not obj and j.trailerId then
    obj = rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(vehIdOf(M.playerVeh()))
  end
  if obj and obj.queueLuaCommand then
    pcall(obj.queueLuaCommand, obj, M.buildCargoVeScript(kg))
    j.cargoAppliedKg = kg
  end
end

local function cleanupJobTrailer(j)
  if not j then return end
  applyCargoMassToJob(j, 0)
  if j.trailerOwnedByJob and j.trailerId then
    local pv = M.playerVeh()
    if pv and pv.queueLuaCommand then
      pcall(pv.queueLuaCommand, pv, 'if beamstate and beamstate.detachCouplers then beamstate.detachCouplers() end')
    end
    local trl = (rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(j.trailerId))
      or (rawget(_G, 'be') and be.getObjectByID and be:getObjectByID(j.trailerId))
    if trl and trl.delete then
      pcall(function() trl:delete() end)
    end
  end
  j.trailerId = nil
  j.trailerOwnedByJob = false
  j.hitchPlan = nil
end

local function trySpawnTrailerForJob(j)
  if not j or j.mode ~= 'logistics' then return end
  local vinfo = j.vehicleInfo or {}
  if vinfo.attachedTrailerId then
    j.trailerId = vinfo.attachedTrailerId
    j.trailerOwnedByJob = false
    j.trailerState = 'attached'
    return
  end
  local coupler = vinfo.coupler or 'none'
  if coupler ~= 'towhitch' and coupler ~= 'fifthwheel' then
    j.trailerState = 'none'
    return
  end
  local model = M.pickTrailerModel(coupler, j.cargoType, j.tier)
  local cv = rawget(_G, 'core_vehicles')
  local pv = M.playerVeh()
  if not model or not cv or not cv.spawnNewVehicle or not pv then
    j.trailerState = 'solo'
    return
  end
  local p = pv:getPosition()
  local d = pv:getDirectionVector()
  local pHalf = math.max(2.0, ((vinfo.lengthM or 5.5) * 0.5))
  local tHalf = (coupler == 'fifthwheel') and 6.2 or 2.4
  local cands = M.trailerSpawnCandidates(p.x, p.y, p.z, d.x, d.y, pHalf, tHalf)

  local chosen = nil
  for _, c in ipairs(cands) do
    local gz = M.castRay(c.x, c.y, p.z + 12, 36)
    if gz and math.abs(gz - p.z) <= 4.5 then
      local clear = true
      local hitD = M.castRayDir(p.x, p.y, p.z + 1.0, -c.dirX, -c.dirY, 0, c.backDist + tHalf + 1.2)
      if hitD and hitD < c.backDist + tHalf + 0.8 then clear = false end
      if clear and rawget(_G, 'be') and be.getObjectCount then
        local pvId = vehIdOf(pv)
        for i = 0, be:getObjectCount() - 1 do
          local o = be:getObject(i)
          if o and o.getPosition and vehIdOf(o) ~= pvId then
            local op = o:getPosition()
            if hypot(op.x - c.x, op.y - c.y) < (tHalf + 2.8) then clear = false break end
          end
        end
      end
      if clear then
        chosen = { x = c.x, y = c.y, z = gz + 0.55, dirX = c.dirX, dirY = c.dirY }
        break
      end
    end
  end

  if not chosen then
    local cap = M.SOLO_CARGO_CAP_KG[j.vehicleClass or 'van'] or 1400
    if (j.cargoKg or 0) > cap then
      j.cargoKg = cap
    end
    j.trailerState = 'tight_space_solo'
    M.say('Space too tight for a trailer — running solo cargo', 5)
    return
  end

  local rot = quatFromDir(vec3(chosen.dirX, chosen.dirY, 0):normalized(), vec3(0, 0, 1))
  local ok, trl = pcall(cv.spawnNewVehicle, model, {
    pos = vec3(chosen.x, chosen.y, chosen.z),
    rot = rot,
    autoEnterVehicle = false,
    vehicleName = 'bne_transport_trailer',
  })
  if not ok or not trl then
    j.trailerState = 'solo'
    return
  end
  j.trailerId = vehIdOf(trl)
  j.trailerOwnedByJob = true
  j.trailerModel = model
  j.trailerState = 'spawning'
  j.hitchPlan = { t0 = M.now(), next = 1, coupler = coupler, trailerId = j.trailerId }
  pcall(trl.queueLuaCommand, trl, 'input.event("parkingbrake", 0, 2)')
end

local function tickHitchPlan(j, now)
  local hp = j and j.hitchPlan
  if not hp then return end
  local pv = M.playerVeh()
  local trl = rawget(_G, 'scenetree') and scenetree.findObjectById and scenetree.findObjectById(hp.trailerId)
  if not pv or not trl then j.hitchPlan = nil return end
  local attId = findAttachedTrailerId(vehIdOf(pv))
  if attId == hp.trailerId then
    j.trailerState = 'attached'
    j.hitchPlan = nil
    return
  end
  if hp.next > #M.HITCH_ATTEMPTS then
    j.hitchPlan = nil
    j.trailerState = 'ready'
    return
  end
  if now - hp.t0 < M.HITCH_ATTEMPTS[hp.next] then return end
  hp.next = hp.next + 1
  local couplerTag = hp.coupler == 'fifthwheel' and 'fifthwheel' or 'towhitch'
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
  obj:attachExternalCoupler(myNode, %d, 0, nd.couplerStrength or 10000000, math.max(nd.couplerRadius or 1.2, 1.2),
    nd.couplerLockRadius or 0.15, nd.couplerLatchSpeed or 1.5, 0)
end]], couplerTag, hp.trailerId)
  pcall(pv.queueLuaCommand, pv, cmd)
  pcall(trl.queueLuaCommand, trl, 'input.event("parkingbrake", 0, 2)')
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
  local merged = {
    jbeam = ge.jbeam,
    modelType = ge.modelType,
    configName = ge.configName,
    lengthM = ge.lengthM,
    massKg = prb and prb.massKg or nil,
    coupler = prb and prb.coupler or 'none',
    hasTrailer = ge.hasTrailer or (prb and prb.attached == true) or false,
    attachedTrailerId = ge.attachedTrailerId,
  }
  local classified = M.classifyVehicle(merged)
  classified.lengthM = ge.lengthM
  classified.attachedTrailerId = ge.attachedTrailerId

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
  pending = { id = nextReqId, mode = pr.mode, tier = pr.tier, sentAt = M.now(), vehicle = classified }
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
        bearing = tonumber(s.bearing) or 0,
        zoneRadius = math.max(8, math.min(20, tonumber(s.zoneRadius) or M.DEFAULT_ZONE_RADIUS_M)),
        cargoDeltaKg = tonumber(s.cargoDeltaKg) or 0,
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
  lastError = nil
  summary = nil
  local firstTarget = stops[1].dwellTargetS or M.BAY_DWELL_S
  activeJob = {
    mode = mode,
    tier = tier,
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
    stopZAnchorId = nil,
    stopZAt = -math.huge,
    visGreen = 0,
    visAt = nil,
    -- Taxi leg & fare state
    passengerOnBoard = false,
    fareDrivenM = 0,
    fareElapsedS = 0,
    fareHarshS = 0,
    targetLegS = 0,
    -- Logistics cargo & trailer state
    vehicleClass = tostring(msg.vehicleClass or (cargo and cargo.vehicleClass) or (req.vehicle and req.vehicle.class) or ''),
    vehicleInfo = req.vehicle,
    cargoType = cargo and tostring(cargo.type or '') or '',
    cargoLabel = cargo and tostring(cargo.label or '') or '',
    cargoKg = cargoKg,
    cargoCurrentKg = 0,
    cargoAppliedKg = 0,
    trailerId = nil,
    trailerOwnedByJob = false,
    trailerState = 'none',
    hitchPlan = nil,
  }
  if mode == 'logistics' then
    trySpawnTrailerForJob(activeJob)
  end
  syncGpsToStop(stops[1], 1, #stops)
  M.say(string.format('Job started: %s (%d stops)', activeJob.title ~= '' and activeJob.title or activeJob.mode, #stops), 6)
end

local function finishJob(fallbackFinal)
  if not activeJob then return end
  local j = activeJob
  cleanupJobTrailer(j)
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
    cargoLabel = j.cargoLabel,
    cargoKg = j.cargoKg,
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
  local doneStop = j.stops[j.stopIndex]
  if completed then
    j.stopsCompleted = j.stopsCompleted + 1
    if isFallback then j.fallbackCount = (j.fallbackCount or 0) + 1 end
    if j.mode == 'taxi' and doneStop and doneStop.kind == 'pickup' then
      j.passengerOnBoard = true
      local nextStop = j.stops[j.stopIndex + 1]
      local legM = nextStop and M.haversineM(doneStop.lat, doneStop.lon, nextStop.lat, nextStop.lon) or (j.estimatedKm * 1000)
      local spd = (j.tier == 'regional') and 19.0 or 12.5
      j.targetLegS = math.max(45.0, (legM * 1.25) / spd)
    elseif j.mode == 'logistics' and doneStop and doneStop.cargoDeltaKg ~= 0 then
      local cap = (j.cargoKg and j.cargoKg > 0) and j.cargoKg or 0
      if doneStop.kind == 'loading' then
        j.cargoCurrentKg = cap
      else
        j.cargoCurrentKg = math.max(0, (j.cargoCurrentKg or 0) + doneStop.cargoDeltaKg)
      end
      applyCargoMassToJob(j, j.cargoCurrentKg)
    end
  else
    j.stopsSkipped = j.stopsSkipped + 1
  end
  j.dwellS = 0
  j.dwellMode = 'none'
  j.inBay = false
  j.inFallback = false
  j.stopZ = nil
  j.bayCornersZ = nil
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
      j.targetLegS = gs.eta * 1.20
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
      if ah > M.HARSH_ACCEL_MPS2 or math.abs(az) > M.HARSH_VERT_MPS2 or jerk > M.HARSH_JERK_MPS3 then
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
  if j.hitchPlan then tickHitchPlan(j, now) end
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

  local spec = M.baySpec(j.mode, j.tier)
  local nx, ny = 0, 1
  if anchor.northAt then
    local okN, ax, ay = pcall(anchor.northAt, anchor, sx, sy)
    if okN and tonumber(ax) and tonumber(ay) then nx, ny = ax, ay end
  end
  local fx, fy, rx, ry = M.bayFrame(nx, ny, stop.bearing)

  -- Ground height near stop & bay corners for bridge/overpass protection + slope-hugging marker
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
      j.bayCornersZ = {
        fl = rayC(hl, hw),
        fr = rayC(hl, -hw),
        bl = rayC(-hl, hw),
        br = rayC(-hl, -hw),
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
  taxi = { 1.0, 0.76, 0.14 },
  bus = { 0.16, 0.76, 1.0 },
  logistics = { 0.96, 0.56, 0.16 },
}
local BAY_GREEN = { 0.18, 0.92, 0.48 }
local FALLBACK_AMBER = { 0.58, 0.88, 0.34 }

local function lerp(a, b, t) return a + (b - a) * t end

function M.drawMarker(anchor, player)
  if not activeJob or not anchor or not player then return end
  local dd = rawget(_G, 'debugDrawer')
  if not dd or not dd.drawLineInstance or not ColorF then return end
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
  local cz = j.bayCornersZ
  local zfl = (cz and cz.fl) or zCenter
  local zfr = (cz and cz.fr) or zCenter
  local zbl = (cz and cz.bl) or zCenter
  local zbr = (cz and cz.br) or zCenter
  local hl, hw = spec.halfL, spec.halfW

  local function bayPt(along, across)
    local u = math.max(0, math.min(1, (along + hl) / (2 * hl)))
    local v = math.max(0, math.min(1, (across + hw) / (2 * hw)))
    local zB = lerp(zbr, zbl, v)
    local zF = lerp(zfr, zfl, v)
    local z = math.max(lerp(zB, zF, u), zCenter - 0.15) + 0.08
    return vec3(sx + along * fx + across * rx, sy + along * fy + across * ry, z)
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

  local colBorder = ColorF(rCol, gCol, bCol, 0.72)
  local colBracket = ColorF(rCol, gCol, bCol, 0.96)
  local colChevron = ColorF(rCol, gCol, bCol, 0.55 + 0.40 * g)

  -- Solid front stop-bar (+hl)
  dd:drawLineInstance(bayPt(hl, -hw), bayPt(hl, hw), 4, colBracket)

  -- Dashed left/right bay side borders
  local dashLen, gapLen = 1.25, 0.85
  local stepLen = dashLen + gapLen
  local cur = -hl + 0.9
  while cur < hl - 0.9 do
    local segEnd = math.min(cur + dashLen, hl - 0.9)
    dd:drawLineInstance(bayPt(cur, -hw), bayPt(segEnd, -hw), 3, colBorder)
    dd:drawLineInstance(bayPt(cur, hw), bayPt(segEnd, hw), 3, colBorder)
    cur = cur + stepLen
  end

  -- Subtle rear entry dashes (-hl)
  dd:drawLineInstance(bayPt(-hl, -hw * 0.65), bayPt(-hl, -hw * 0.2), 2.5, colBorder)
  dd:drawLineInstance(bayPt(-hl, hw * 0.2), bayPt(-hl, hw * 0.65), 2.5, colBorder)

  -- Crisp L-shaped corner brackets
  local armL, armW = math.min(1.3, hl * 0.3), math.min(0.85, hw * 0.45)
  for _, sl in ipairs({ -1, 1 }) do
    for _, sw in ipairs({ -1, 1 }) do
      local cPt = bayPt(sl * hl, sw * hw)
      dd:drawLineInstance(cPt, bayPt(sl * (hl - armL), sw * hw), 6, colBracket)
      dd:drawLineInstance(cPt, bayPt(sl * hl, sw * (hw - armW)), 6, colBracket)
    end
  end

  -- Directional entry chevrons pointing forward along stop.bearing
  local chevSpan = hw * 0.48
  local chevDepth = math.min(1.0, hl * 0.18)
  for _, frac in ipairs({ -0.58, -0.18, 0.22 }) do
    local tipAlong = hl * frac + chevDepth * 0.5
    local wingAlong = tipAlong - chevDepth
    local tip = bayPt(tipAlong, 0)
    dd:drawLineInstance(bayPt(wingAlong, -chevSpan), tip, 4, colChevron)
    dd:drawLineInstance(bayPt(wingAlong, chevSpan), tip, 4, colChevron)
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
        im.TextUnformatted(activeJob.passengerOnBoard and string.format('On board · Meter: $%.2f', fare) or 'En route to pickup')
      elseif activeJob.mode == 'logistics' and activeJob.cargoKg and activeJob.cargoKg > 0 then
        im.TextUnformatted(string.format('%s · %d kg (Loaded: %d kg)', activeJob.cargoLabel, activeJob.cargoKg, activeJob.cargoCurrentKg or 0))
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
      cargoLabel = activeJob.cargoLabel ~= '' and activeJob.cargoLabel or nil,
      cargoKg = (activeJob.cargoKg and activeJob.cargoKg > 0) and activeJob.cargoKg or nil,
      cargoCurrentKg = activeJob.cargoCurrentKg or 0,
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
      vehicleClass = activeJob.vehicleClass ~= '' and activeJob.vehicleClass or nil,
      cargoLabel = activeJob.cargoLabel ~= '' and activeJob.cargoLabel or nil,
      cargoKg = (activeJob.cargoKg and activeJob.cargoKg > 0) and activeJob.cargoKg or nil,
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
