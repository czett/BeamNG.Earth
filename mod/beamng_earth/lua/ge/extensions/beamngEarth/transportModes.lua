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
M.DWELL_S = 3.0
M.DEFAULT_ZONE_RADIUS_M = 12.0
M.HEIGHT_TOL_M = 10.0
M.DRAW_RADIUS_M = 450.0
M.REQUEST_TIMEOUT_S = 15.0
M.SAMPLE_S = 0.2
M.HARSH_ACCEL_MPS2 = 5.5
M.HARSH_JERK_MPS3 = 18.0
M.DAMAGE_COLLISION_DELTA = 50
M.JUMP_RESET_M = 200.0
M.RADIAL_LEVEL = '/root/sandbox/other/'

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
M.readDamage = function()
  local gpv = rawget(_G, 'getPlayerVehicle')
  local veh = gpv and gpv(0)
  if not veh then return 0 end
  local id = veh.getID and veh:getID() or (veh.getId and veh:getId())
  local m = rawget(_G, 'map')
  local o = id and m and m.objects and m.objects[id]
  return o and tonumber(o.damage) or 0
end

local pending = nil       -- { id, mode, tier, sentAt }
local activeJob = nil     -- { mode, tier, title, routeRef, source, stops, stopIndex, ... }
local summary = nil       -- completed job summary until dismissed or new job starts
local lastError = nil
local nextReqId = 0
local jobSeq = 0
local gpsTarget = nil     -- { lat, lon } last set by transportModes

local function hypot(x, y) return math.sqrt(x * x + y * y) end

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

-- Pure: compute 0..100 smoothness & safety score from accumulated driving metrics.
function M.computeScore(m)
  local elapsed = math.max(1.0, tonumber(m.elapsedS) or 0)
  local harshTime = tonumber(m.harshS) or 0
  local collisions = math.max(0, tonumber(m.collisions) or 0)
  local dmg = math.max(0, tonumber(m.damageDelta) or 0)
  local harshRatio = math.min(1.0, harshTime / math.max(5.0, elapsed * 0.35))
  local smoothness = math.max(0, math.min(100, math.floor(100 - harshRatio * 45 + 0.5)))
  local collisionPen = collisions * 8 + math.min(45, dmg / 400.0)
  local score = math.max(0, math.min(100, math.floor(smoothness - collisionPen + 0.5)))
  return score, smoothness
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
    if pcall(g.setDestination, stop.lat, stop.lon, label) then
      gpsTarget = { lat = stop.lat, lon = stop.lon }
    end
  end
end

local function playerPose()
  local c = M.core()
  local st = c and c._state and c._state()
  local pl = st and st.player
  local heading = nil
  local gpv = rawget(_G, 'getPlayerVehicle')
  local veh = gpv and gpv(0)
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

function M.isActive()
  return activeJob ~= nil or pending ~= nil
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
  local stops = {}
  for i, s in ipairs(msg.stops) do
    local lat, lon = tonumber(s.lat), tonumber(s.lon)
    if lat and lon then
      stops[#stops + 1] = {
        index = tonumber(s.index) or (#stops + 1),
        kind = tostring(s.kind or 'stop'),
        name = tostring(s.name or ('Stop ' .. (#stops + 1))),
        address = tostring(s.address or ''),
        lat = lat,
        lon = lon,
        road = tostring(s.road or ''),
        bearing = tonumber(s.bearing) or 0,
        zoneRadius = math.max(8, math.min(20, tonumber(s.zoneRadius) or M.DEFAULT_ZONE_RADIUS_M)),
      }
    end
  end
  if #stops == 0 then
    lastError = 'Job returned no valid stops'
    return
  end
  lastError = nil
  summary = nil
  activeJob = {
    mode = tostring(msg.mode or req.mode),
    tier = tostring(msg.tier or req.tier),
    title = tostring(msg.title or ''),
    routeRef = tostring(msg.routeRef or ''),
    source = tostring(msg.source or ''),
    estimatedKm = tonumber(msg.estimatedKm) or 0,
    stops = stops,
    stopIndex = 1,
    stopsCompleted = 0,
    stopsSkipped = 0,
    dwellS = 0,
    distM = nil,
    etaS = nil,
    drivenM = 0,
    elapsedS = 0,
    harshS = 0,
    collisions = 0,
    damageDelta = 0,
    prevDamage = M.readDamage(),
    lastTrack = nil,
    sampleAcc = 0,
    lastSample = nil,
    stopZ = nil,
    stopZAnchorId = nil,
    stopZAt = -math.huge,
  }
  syncGpsToStop(stops[1], 1, #stops)
  M.say(string.format('Job started: %s (%d stops)', activeJob.title ~= '' and activeJob.title or activeJob.mode, #stops), 6)
end

local function finishJob()
  if not activeJob then return end
  local j = activeJob
  local score, smooth = M.computeScore(j)
  summary = {
    mode = j.mode,
    tier = j.tier,
    title = j.title,
    stopsCompleted = j.stopsCompleted,
    stopsSkipped = j.stopsSkipped,
    stopCount = #j.stops,
    drivenM = math.floor(j.drivenM + 0.5),
    elapsedS = math.floor(j.elapsedS + 0.5),
    score = score,
    smoothnessPct = smooth,
    collisions = j.collisions,
    damageDelta = math.floor(j.damageDelta + 0.5),
  }
  activeJob = nil
  clearOwnedGps()
  M.say(string.format('Job complete! %d/%d stops · Score %d/100', summary.stopsCompleted, summary.stopCount, summary.score), 8)
end

local function advanceStop(completed)
  if not activeJob then return end
  if completed then activeJob.stopsCompleted = activeJob.stopsCompleted + 1
  else activeJob.stopsSkipped = activeJob.stopsSkipped + 1 end
  activeJob.dwellS = 0
  activeJob.stopZ = nil
  activeJob.stopZAnchorId = nil
  activeJob.stopZAt = -math.huge
  if activeJob.stopIndex >= #activeJob.stops then
    finishJob()
    return
  end
  activeJob.stopIndex = activeJob.stopIndex + 1
  local nxt = activeJob.stops[activeJob.stopIndex]
  syncGpsToStop(nxt, activeJob.stopIndex, #activeJob.stops)
  M.say(string.format('Stop %d/%d: %s', activeJob.stopIndex, #activeJob.stops, nxt.name), 5)
end

function M.skipStop()
  if not activeJob then return { ok = false, error = 'No active job' } end
  advanceStop(false)
  return { ok = true }
end

function M.cancelJob()
  if not activeJob and not pending then return { ok = false, error = 'No active job' } end
  activeJob = nil
  pending = nil
  clearOwnedGps()
  M.say('Transport job cancelled', 4)
  return { ok = true }
end

function M.dismissSummary()
  summary = nil
  return { ok = true }
end

function M.onRebased()
  if not activeJob then return end
  activeJob.lastTrack = nil
  activeJob.lastSample = nil
  activeJob.stopZ = nil
  activeJob.stopZAnchorId = nil
  activeJob.stopZAt = -math.huge
end

function M.reset()
  activeJob = nil
  pending = nil
  summary = nil
  lastError = nil
  clearOwnedGps()
end

local function updateMetrics(j, dtSim, player)
  j.elapsedS = j.elapsedS + dtSim
  -- Driven distance (same anchor only; onRebased clears lastTrack)
  if j.lastTrack then
    local step = hypot(player.x - j.lastTrack.x, player.y - j.lastTrack.y)
    if step <= M.JUMP_RESET_M then
      j.drivenM = j.drivenM + step
    else
      j.lastSample = nil
    end
  end
  j.lastTrack = { x = player.x, y = player.y }

  -- Vehicle damage / collision tracking
  local dmg = M.readDamage()
  if dmg > j.prevDamage then
    local delta = dmg - j.prevDamage
    j.damageDelta = j.damageDelta + delta
    if delta >= M.DAMAGE_COLLISION_DELTA then
      j.collisions = j.collisions + 1
    end
  end
  j.prevDamage = dmg

  -- Smoothness sampling (0.2 s sim interval)
  j.sampleAcc = j.sampleAcc + dtSim
  if j.sampleAcc >= M.SAMPLE_S then
    local sdt = j.sampleAcc
    j.sampleAcc = 0
    local vx, vy, vz = player.vx or 0, player.vy or 0, player.vz or 0
    local ls = j.lastSample
    if ls then
      local ax = (vx - ls.vx) / sdt
      local ay = (vy - ls.vy) / sdt
      local az = (vz - ls.vz) / sdt
      local ah = hypot(ax, ay)
      local jerk = ls.ax and math.sqrt(((ax - ls.ax) / sdt) ^ 2 + ((ay - ls.ay) / sdt) ^ 2) or 0
      if ah > M.HARSH_ACCEL_MPS2 or math.abs(az) > 8.0 or jerk > M.HARSH_JERK_MPS3 then
        j.harshS = j.harshS + sdt
      end
      j.lastSample = { vx = vx, vy = vy, vz = vz, ax = ax, ay = ay }
    else
      j.lastSample = { vx = vx, vy = vy, vz = vz }
    end
  end
end

function M.update(dtReal, dtSim, anchor, player, paused, rebasing)
  if pending and M.now() - pending.sentAt > M.REQUEST_TIMEOUT_S then
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

  -- Ground height near stop for bridge/overpass protection
  local now = M.now()
  if distXY <= M.DRAW_RADIUS_M and (j.stopZ == nil or now - j.stopZAt >= 0.75) then
    local gz = M.castRay(sx, sy, (player.z or 0) + 40, 120)
    if gz then
      j.stopZ = gz
      j.stopZAt = now
    end
  end
  local dz = j.stopZ and ((player.z or 0) - j.stopZ) or nil
  local state, nextDwell = M.stepStop(j.dwellS, distXY, dz, player.speed or 0, stop.zoneRadius, dtSim, paused)
  j.dwellS = nextDwell
  if state == 'complete' then
    advanceStop(true)
  end
end

local MODE_RGBA = {
  taxi = { 1.0, 0.78, 0.12, 0.9 },
  bus = { 0.22, 0.68, 1.0, 0.9 },
  logistics = { 0.95, 0.48, 0.18, 0.9 },
}
local DWELL_RGBA = { 0.24, 0.86, 0.48, 0.95 }

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

  local z = j.stopZ or player.z or 0
  local c = j.dwellS > 0 and DWELL_RGBA or (MODE_RGBA[j.mode] or MODE_RGBA.taxi)
  local col = ColorF(c[1], c[2], c[3], c[4])
  local r = stop.zoneRadius or M.DEFAULT_ZONE_RADIUS_M
  local segs = 20
  local zRing = z + 0.18
  for i = 0, segs - 1 do
    local a0 = (i / segs) * math.pi * 2
    local a1 = ((i + 1) / segs) * math.pi * 2
    dd:drawLineInstance(
      vec3(sx + r * math.cos(a0), sy + r * math.sin(a0), zRing),
      vec3(sx + r * math.cos(a1), sy + r * math.sin(a1), zRing),
      4, col
    )
  end
  if dd.drawCylinder and dd.drawSphere then
    local base = vec3(sx, sy, z)
    local h = 4.0 + 2.0 * (j.dwellS / M.DWELL_S)
    dd:drawCylinder(base, base + vec3(0, 0, h), 0.18, col)
    dd:drawSphere(base + vec3(0, 0, h), 0.55, col)
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
      im.TextUnformatted(string.format('%s | Stop %d/%d', activeJob.mode:upper(), activeJob.stopIndex, #activeJob.stops))
      im.TextUnformatted(stop and stop.name or '')
      if stop and stop.address ~= '' then im.TextUnformatted(stop.address) end
      if activeJob.distM then im.TextUnformatted(string.format('Distance: %.0f m', activeJob.distM)) end
      if activeJob.dwellS > 0 then
        im.TextUnformatted(string.format('Hold stop: %.1f / %.1f s', activeJob.dwellS, M.DWELL_S))
      end
      if im.Button('Skip Stop') then M.skipStop() end
      im.SameLine()
      if im.Button('Cancel') then M.cancelJob() end
    elseif summary then
      im.TextUnformatted(string.format('Job Complete (%s)', summary.mode:upper()))
      im.TextUnformatted(string.format('Stops: %d/%d · Score: %d/100', summary.stopsCompleted, summary.stopCount, summary.score))
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
  if not activeJob and not summary and not pending then return nil end
  local metric = isMetric()
  if activeJob then
    local stop = activeJob.stops[activeJob.stopIndex]
    local score = M.computeScore(activeJob)
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
      distM = activeJob.distM and math.floor(activeJob.distM + 0.5) or nil,
      etaS = activeJob.etaS and math.floor(activeJob.etaS + 0.5) or nil,
      dwellFrac = math.min(1, math.max(0, activeJob.dwellS / M.DWELL_S)),
      score = score,
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
      stopCount = summary.stopCount,
      drivenM = summary.drivenM,
      elapsedS = summary.elapsedS,
      score = summary.score,
      smoothnessPct = summary.smoothnessPct,
      collisions = summary.collisions,
      damageDelta = summary.damageDelta,
      metric = metric,
    }
  end
  return { state = 'pending', mode = pending.mode, tier = pending.tier, metric = metric }
end

function M.status()
  return M.hudPayload()
end

function M.uiState()
  local c = M.core()
  local st = c and c._state and c._state()
  return {
    pending = pending and { mode = pending.mode, tier = pending.tier } or nil,
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
      dwellFrac = math.min(1, math.max(0, activeJob.dwellS / M.DWELL_S)),
      drivenM = math.floor(activeJob.drivenM + 0.5),
      elapsedS = math.floor(activeJob.elapsedS + 0.5),
      score = select(1, M.computeScore(activeJob)),
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
