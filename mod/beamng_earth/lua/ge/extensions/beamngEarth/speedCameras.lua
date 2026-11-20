-- German OSM speed cameras, mobile radar traps, screen-edge red flash overlay,
-- graduated fines (with optional transportModes career integration), and EU/DE police patrol enforcement.
-- Completely inert when `expDeStreetImmersion` is off (strict off-switch parity).

local M = {}

M.URBAN_TOLERANCE_KPH = 6
M.RURAL_TOLERANCE_KPH = 8
M.ROADWORK_TOLERANCE_KPH = 6
M.COOLDOWN_S = 15.0
M.ROADWORK_COOLDOWN_S = 20.0
M.FLASH_S = 0.55
M.LIGHT_S = 0.22
M.JOB_SCORE_PENALTY = 12
M.PATROL_SPEED_OVER_KPH = 20
M.PATROL_RADIUS_M = 45.0
M.PATROL_COLLIDE_DIST_M = 7.5
M.PATROL_COLLIDE_DV_MS = 3.5
M.PATROL_COOLDOWN_S = 25.0
M.PATROL_LIGHTBAR_S = 10.0

local tiles = {}              -- tileKey -> { gate, ... }
local roadworkTiles = {}      -- tileKey -> { zone, ... }
local cooldowns = {}          -- gate.id -> clock expiry
local roadworkCooldowns = {}  -- zone.id -> clock expiry
local roadworkWarned = {}     -- zone.id -> clock expiry
local patrolCooldowns = {}    -- vehId -> clock expiry
local activeLightbars = {}    -- vehId -> clock expiry
local previous = nil
local simClock = 0
local flashLeft = 0
local lightId, lightKey, lightLeft = nil, nil, 0
local vecs = nil
local deEnhMod = nil
local forceEnabled = nil      -- test override (nil = follow deEnhancer.isEnabled())

local stats = {
  flashes = 0,
  citations = 0,
  totalFines = 0,
  scorePenalties = 0,
  lastFine = 0,
  lastReason = nil,
}

function M._setEnabledForTest(v)
  forceEnabled = v
end

function M.isEnabled()
  if forceEnabled ~= nil then return forceEnabled == true end
  if deEnhMod == nil then
    local ok, mod = pcall(require, 'beamngEarth/deEnhancer')
    deEnhMod = (ok and type(mod) == 'table') and mod or false
  end
  return deEnhMod ~= false and type(deEnhMod.isEnabled) == 'function' and deEnhMod.isEnabled() == true
end

-- Pure: evaluate a speed camera pass.
-- Returns `fine, overKph, toleranceKph` when speeding above tolerance, else `nil`.
-- Urban tolerance: limit + 6 km/h; Rural tolerance: limit + 8 km/h. Unlimited (<= 0) never flashes.
function M.evaluate(speedKph, limitKph, isUrban)
  speedKph = tonumber(speedKph)
  limitKph = tonumber(limitKph)
  if not speedKph or not limitKph or limitKph <= 0 then return nil end
  local tol = isUrban and M.URBAN_TOLERANCE_KPH or M.RURAL_TOLERANCE_KPH
  if speedKph <= limitKph + tol then return nil end
  local over = speedKph - limitKph
  local fine
  if over <= 15 then
    fine = 35
  elseif over <= 25 then
    fine = 75
  elseif over <= 40 then
    fine = 140
  elseif over <= 60 then
    fine = 200
  else
    fine = 250
  end
  return fine, over, tol
end

-- Pure: swept segment crossing test across a camera gate.
function M.crossing(gate, before, after)
  local bx, by = before.x - gate.x, before.y - gate.y
  local ax, ay = after.x - gate.x, after.y - gate.y
  local b = bx * gate.dx + by * gate.dy
  local a = ax * gate.dx + ay * gate.dy
  if b >= 0 or a < 0 then return nil end
  local t = b / (b - a)
  local x, y = bx + t * (ax - bx), by + t * (ay - by)
  if math.abs(x * gate.dy - y * gate.dx) > gate.half then return nil end
  local z = before.z + t * (after.z - before.z) - gate.z
  if z < -1.5 or z > 4.0 then return nil end
  local vx = before.vx + t * (after.vx - before.vx)
  local vy = before.vy + t * (after.vy - before.vy)
  local vz = before.vz + t * (after.vz - before.vz)
  local horiz = math.sqrt(vx * vx + vy * vy)
  if horiz < 0.5 or (vx * gate.dx + vy * gate.dy) < 0.70 * horiz then return nil end
  return t, math.sqrt(vx * vx + vy * vy + vz * vz) * 3.6
end

local function findTransportModes()
  return rawget(_G, 'transportModes')
    or rawget(_G, 'beamngEarth_transportModes')
    or package.loaded['beamngEarth/transportModes']
    or package.loaded['transportModes']
    or nil
end

-- Check whether an active VIP / emergency transport run exempts the player from enforcement.
function M.isExemptRun()
  local tm = findTransportModes()
  if type(tm) ~= 'table' then return false end
  if type(tm.isEmergencyRun) == 'function' then
    local ok, res = pcall(tm.isEmergencyRun)
    if ok and res == true then return true end
  end
  if type(tm.isExemptFromEnforcement) == 'function' then
    local ok, res = pcall(tm.isExemptFromEnforcement)
    if ok and res == true then return true end
  end
  if type(tm.getActiveJob) == 'function' then
    local ok, job = pcall(tm.getActiveJob)
    if ok and type(job) == 'table' then
      local kind = tostring(job.kind or job.mode or job.type or ''):lower()
      if job.exempt == true or job.isEmergency == true or job.isVip == true
          or kind == 'emergency' or kind == 'vip' or kind == 'ambulance' or kind == 'police' then
        return true
      end
    end
  end
  return false
end

-- Deduct fine from transportModes career balance (or stock career attributes) and apply job score penalty.
function M.applyPenalty(fine, reason, scorePts)
  fine = tonumber(fine) or 0
  scorePts = tonumber(scorePts) or M.JOB_SCORE_PENALTY
  local deducted = false
  local scored = false
  local tm = findTransportModes()
  if type(tm) == 'table' then
    if fine > 0 then
      if type(tm.deductFine) == 'function' then
        deducted = pcall(tm.deductFine, fine, reason)
      elseif type(tm.chargeFine) == 'function' then
        deducted = pcall(tm.chargeFine, fine, reason)
      elseif type(tm.addMoney) == 'function' then
        deducted = pcall(tm.addMoney, -fine, reason)
      end
    end
    local hasJob = false
    if type(tm.hasActiveJob) == 'function' then
      local ok, r = pcall(tm.hasActiveJob)
      hasJob = ok and r == true
    elseif type(tm.isJobActive) == 'function' then
      local ok, r = pcall(tm.isJobActive)
      hasJob = ok and r == true
    elseif type(tm.getActiveJob) == 'function' then
      local ok, j = pcall(tm.getActiveJob)
      hasJob = ok and type(j) == 'table'
    end
    if hasJob and scorePts > 0 then
      if type(tm.applyScorePenalty) == 'function' then
        scored = pcall(tm.applyScorePenalty, scorePts, reason)
      elseif type(tm.adjustJobScore) == 'function' then
        scored = pcall(tm.adjustJobScore, -scorePts, reason)
      end
    end
  end
  if not deducted and fine > 0 then
    local cpa = rawget(_G, 'career_modules_playerAttributes')
    if type(cpa) == 'table' and type(cpa.addAttributes) == 'function' then
      deducted = pcall(cpa.addAttributes, { money = -fine }, { label = reason or 'Speed camera fine' })
    end
  end
  stats.totalFines = stats.totalFines + fine
  stats.lastFine = fine
  stats.lastReason = reason
  if scored then stats.scorePenalties = stats.scorePenalties + scorePts end
  return deducted, scored
end

local function playShutterSound()
  local eng = rawget(_G, 'Engine')
  if type(eng) == 'table' and type(eng.Audio) == 'table' and type(eng.Audio.playOnce) == 'function' then
    pcall(eng.Audio.playOnce, 'AudioGui', 'event:>UI>Generic>select')
  end
end

local function stopLight()
  local light = lightId and scenetree and scenetree.findObjectById and scenetree.findObjectById(lightId)
  if light then light:setField('isEnabled', 0, 'false') end
  lightKey, lightLeft = nil, 0
end

local function triggerWorldFlash(key, gate)
  if not (scenetree and scenetree.MissionGroup and createObject) then return end
  local light = lightId and scenetree.findObjectById and scenetree.findObjectById(lightId)
  if not light then
    light = createObject('SpotLight')
    if not light then return end
    light.canSave = false
    light:setField('range', 0, '28')
    light:setField('innerAngle', 0, '60')
    light:setField('outerAngle', 0, '120')
    light:setField('brightness', 0, '56')
    light:setField('color', 0, '1 0.14 0.08 1')
    light:setField('castShadows', 0, 'false')
    light:setField('isEnabled', 0, 'false')
    light:registerObject('')
    scenetree.MissionGroup:addObject(light)
    lightId = light:getID()
  end
  local x, y, z = gate.camX, gate.camY, gate.camZ
  if vec3 and quatFromDir then
    local dir = vec3(gate.x - x + gate.dx * 5, gate.y - y + gate.dy * 5, gate.z + 0.7 - z)
    local q = quatFromDir(dir, vec3(0, 0, 1))
    light:setPosRot(x, y, z, q.x, q.y, q.z, q.w)
  end
  light:setField('isEnabled', 0, 'true')
  lightKey, lightLeft = key, M.LIGHT_S
end

function M.onRows(key, rows)
  local gates = {}
  for _, row in ipairs(rows or {}) do
    local heading = math.rad(tonumber(row[5]) or 0)
    gates[#gates + 1] = {
      id = tostring(row[1]),
      x = tonumber(row[2]) or 0,
      y = tonumber(row[3]) or 0,
      z = tonumber(row[4]) or 0,
      dx = math.cos(heading),
      dy = math.sin(heading),
      half = tonumber(row[6]) or 3.0,
      limit = tonumber(row[7]) or 0,
      camX = tonumber(row[8]) or tonumber(row[2]) or 0,
      camY = tonumber(row[9]) or tonumber(row[3]) or 0,
      camZ = tonumber(row[10]) or tonumber(row[4]) or 0,
      urban = (tonumber(row[11]) or 0) ~= 0,
      mobile = (tonumber(row[12]) or 0) ~= 0,
    }
  end
  tiles[key] = #gates > 0 and gates or nil
end

function M.onRoadworks(key, rows)
  local zones = {}
  for _, row in ipairs(rows or {}) do
    local x0, y0 = tonumber(row[2]) or 0, tonumber(row[3]) or 0
    local x1, y1 = tonumber(row[4]) or 0, tonumber(row[5]) or 0
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 1e-3 then
      zones[#zones + 1] = {
        id = tostring(row[1]),
        x0 = x0,
        y0 = y0,
        dx = dx / len,
        dy = dy / len,
        len = len,
        halfW = tonumber(row[6]) or 4.0,
        limit = tonumber(row[7]) or 30,
      }
    end
  end
  roadworkTiles[key] = #zones > 0 and zones or nil
end

-- Pure: check whether (px, py) lies inside a roadwork corridor [0..len] x [-halfW..halfW].
function M.pointInRoadwork(zone, px, py)
  if type(zone) ~= 'table' or not px or not py then return false end
  local rx, ry = px - zone.x0, py - zone.y0
  local along = rx * zone.dx + ry * zone.dy
  if along < 0 or along > zone.len then return false end
  local perp = math.abs(rx * zone.dy - ry * zone.dx)
  return perp <= zone.halfW
end

function M.activeRoadworkLimit(px, py)
  if not M.isEnabled() or not px or not py then return nil end
  for _, zones in pairs(roadworkTiles) do
    for _, zone in ipairs(zones) do
      if M.pointInRoadwork(zone, px, py) then
        return zone.limit, zone
      end
    end
  end
  return nil
end

function M.dropKey(key)
  tiles[key] = nil
  roadworkTiles[key] = nil
  if key == lightKey then stopLight() end
end

function M.resetMotion()
  previous = nil
  if lightKey then stopLight() end
end

function M.clear()
  M.resetMotion()
  local light = lightId and scenetree and scenetree.findObjectById and scenetree.findObjectById(lightId)
  if light then light:delete() end
  lightId, tiles, roadworkTiles, cooldowns, roadworkCooldowns, roadworkWarned, patrolCooldowns, activeLightbars =
    nil, {}, {}, {}, {}, {}, {}, {}
  flashLeft, simClock = 0, 0
  stats = { flashes = 0, citations = 0, totalFines = 0, scorePenalties = 0, lastFine = 0, lastReason = nil }
end

function M.flashAlpha()
  if flashLeft <= 0 or M.FLASH_S <= 0 then return 0 end
  local u = math.max(0, math.min(1, flashLeft / M.FLASH_S))
  -- Crisp camera-flash punch then smooth exponential-like fade
  return u * u
end

function M.stats()
  return {
    flashes = stats.flashes,
    citations = stats.citations,
    totalFines = stats.totalFines,
    scorePenalties = stats.scorePenalties,
    lastFine = stats.lastFine,
    lastReason = stats.lastReason,
    flashAlpha = M.flashAlpha(),
  }
end

-- Identify whether a traffic entry is an active police/polizei patrol unit.
function M.isPoliceVehicle(entry)
  if type(entry) ~= 'table' then return false end
  if entry.state and entry.state ~= 'active' then return false end
  if type(entry.role) == 'table' and tostring(entry.role.name or ''):lower() == 'police' then
    return true
  end
  local model = tostring(entry.model or entry.jbeam or ''):lower()
  local cfg = tostring(entry.config or entry.partConfig or entry.name or ''):lower()
  if model:find('police', 1, true) or model:find('polizei', 1, true)
      or cfg:find('police', 1, true) or cfg:find('polizei', 1, true) then
    return true
  end
  return false
end

local function activatePatrolSiren(vehId, obj)
  if obj and obj.queueLuaCommand then
    pcall(obj.queueLuaCommand, obj, 'if electrics and electrics.set_lightbar_signal then electrics.set_lightbar_signal(2) end')
  end
  local gp = rawget(_G, 'gameplay_police')
  if type(gp) == 'table' and type(gp.setPursuitMode) == 'function' then
    pcall(gp.setPursuitMode, 1, nil, vehId)
  end
  activeLightbars[vehId] = simClock + M.PATROL_LIGHTBAR_S
end

-- Check active police patrols for extreme speeding (> limit + 20 km/h) or direct collision beside a patrol.
function M.updatePatrols(player, before, dtReal, limitKph, trafficData)
  for vid, untilT in pairs(activeLightbars) do
    if simClock >= untilT then
      activeLightbars[vid] = nil
      local obj = getObjectByID and getObjectByID(vid)
      if obj and obj.queueLuaCommand then
        pcall(obj.queueLuaCommand, obj, 'if electrics and electrics.set_lightbar_signal then electrics.set_lightbar_signal(0) end')
      end
    end
  end

  if not M.isEnabled() or not player or not player.vehicleId then return false end
  if M.isExemptRun() then return false end

  local data = trafficData
  if data == nil then
    local gt = rawget(_G, 'gameplay_traffic')
    if type(gt) == 'table' and type(gt.getTrafficData) == 'function' then
      local ok, got = pcall(gt.getTrafficData)
      if ok and type(got) == 'table' then data = got end
    end
  end
  if type(data) ~= 'table' then return false end

  local speedKph = (tonumber(player.speed) or 0) * 3.6
  local dv = 0
  if before and before.vehicleId == player.vehicleId then
    local dvx = (player.vx or 0) - (before.vx or 0)
    local dvy = (player.vy or 0) - (before.vy or 0)
    dv = math.sqrt(dvx * dvx + dvy * dvy)
  end

  for vid, entry in pairs(data) do
    if vid ~= player.vehicleId and M.isPoliceVehicle(entry) then
      local cd = patrolCooldowns[vid]
      if not cd or simClock >= cd then
        local obj = entry.obj or (getObjectByID and getObjectByID(vid))
        local px, py, pz
        if entry.pos then
          px, py, pz = entry.pos.x or entry.pos[1], entry.pos.y or entry.pos[2], entry.pos.z or entry.pos[3] or player.z
        elseif obj and obj.getPosition then
          local ok, p = pcall(obj.getPosition, obj)
          if ok and p then px, py, pz = p.x, p.y, p.z end
        end
        if px and py then
          local d = math.sqrt((player.x - px) ^ 2 + (player.y - py) ^ 2)
          local dz = math.abs((player.z or 0) - (pz or player.z or 0))
          if dz <= 4.0 then
            local collided = (d <= M.PATROL_COLLIDE_DIST_M and (dv >= M.PATROL_COLLIDE_DV_MS or entry.collidedWithPlayer == true))
            local speeding = (limitKph and limitKph > 0 and d <= M.PATROL_RADIUS_M and speedKph > limitKph + M.PATROL_SPEED_OVER_KPH)
            if collided or speeding then
              patrolCooldowns[vid] = simClock + M.PATROL_COOLDOWN_S
              activatePatrolSiren(vid, obj)
              local fine = collided and 150 or math.min(250, math.max(100, math.floor((speedKph - limitKph) * 4)))
              local reason = collided and 'police_collision' or 'police_speeding'
              M.applyPenalty(fine, reason, M.JOB_SCORE_PENALTY)
              stats.citations = stats.citations + 1
              if ui_message then
                if collided then
                  ui_message(string.format('Police patrol collision! Citation $%d (-%d pts on active job).', fine, M.JOB_SCORE_PENALTY),
                    6, 'beamngEarthPolicePatrol')
                else
                  ui_message(string.format('Police patrol citation! %d km/h in a %d km/h zone. Fine $%d.',
                    math.floor(speedKph + 0.5), math.floor(limitKph + 0.5), fine),
                    6, 'beamngEarthPolicePatrol')
                end
              end
              return true
            end
          end
        end
      end
    end
  end
  return false
end

local function currentLimitKph()
  local api = rawget(_G, 'beamngEarth_api')
  if type(api) == 'table' and type(api.speedLimit) == 'function' then
    local ok, info = pcall(api.speedLimit)
    if ok and type(info) == 'table' and tonumber(info.ms) then
      return tonumber(info.ms) * 3.6
    end
  end
  return nil
end

function M.update(player, dtSim, dtReal, opts)
  dtReal = tonumber(dtReal) or 0
  dtSim = tonumber(dtSim) or 0
  if dtReal > 0 then simClock = simClock + dtReal end

  if flashLeft > 0 then
    flashLeft = math.max(0, flashLeft - dtReal)
  end
  if lightKey then
    lightLeft = lightLeft - dtReal
    if lightLeft <= 0 then stopLight() end
  end

  if not M.isEnabled() then
    previous = nil
    flashLeft = 0
    return false
  end

  if not player or not player.vehicleId or dtSim <= 0 then
    previous = nil
    return false
  end

  local before = previous
  previous = player

  -- Patrol check runs even on tiles without fixed speed cameras
  local rwLimit, rwZone = M.activeRoadworkLimit(player.x, player.y)
  local limitKph = (type(opts) == 'table' and opts.limitKph) or rwLimit or currentLimitKph()
  M.updatePatrols(player, before, dtReal, limitKph, type(opts) == 'table' and opts.trafficData or nil)

  -- Roadwork temporary speed-limit caution & enforcement
  if rwZone and not M.isExemptRun() then
    local speedKph = (tonumber(player.speed) or 0) * 3.6
    local cd = roadworkCooldowns[rwZone.id]
    local warned = roadworkWarned[rwZone.id]
    if speedKph > rwZone.limit + M.ROADWORK_TOLERANCE_KPH and (not cd or simClock >= cd) then
      local fine = M.evaluate(speedKph, rwZone.limit, true)
      if fine then
        roadworkCooldowns[rwZone.id] = simClock + M.ROADWORK_COOLDOWN_S
        roadworkWarned[rwZone.id] = simClock + M.ROADWORK_COOLDOWN_S
        stats.citations = stats.citations + 1
        local _, scored = M.applyPenalty(fine, 'roadworks_speeding', M.JOB_SCORE_PENALTY)
        if ui_message then
          local scoreSuffix = scored and string.format(' (-%d pts)', M.JOB_SCORE_PENALTY) or ''
          ui_message(string.format('Roadworks speed violation! %d km/h in %d km/h work zone. Fine $%d%s.',
            math.floor(speedKph + 0.5), math.floor(rwZone.limit + 0.5), fine, scoreSuffix),
            6, 'beamngEarthRoadworks')
        end
        return true
      end
    elseif not warned or simClock >= warned then
      roadworkWarned[rwZone.id] = simClock + M.ROADWORK_COOLDOWN_S
      if ui_message then
        ui_message(string.format('Roadworks ahead · Temporary %d km/h limit', math.floor(rwZone.limit + 0.5)),
          4, 'beamngEarthRoadworks')
      end
    end
  end

  if next(tiles) == nil or not before or before.vehicleId ~= player.vehicleId or dtSim > 0.35 then
    return false
  end

  local dx, dy, dz = player.x - before.x, player.y - before.y, player.z - before.z
  local reach = math.max(4, 1.8 * math.max(player.speed or 0, before.speed or 0) * dtSim + 1.5)
  if dx * dx + dy * dy + dz * dz > reach * reach then return false end

  local best, bestT, bestKey, bestSpeed, bestFine
  for tileKey, gates in pairs(tiles) do
    for _, gate in ipairs(gates) do
      local cd = cooldowns[gate.id]
      if not cd or simClock >= cd then
        local t, speedKph = M.crossing(gate, before, player)
        if t and (not bestT or t < bestT or (t == bestT and gate.id < best.id)) then
          local fine = M.evaluate(speedKph, gate.limit, gate.urban)
          if fine then
            best, bestT, bestKey, bestSpeed, bestFine = gate, t, tileKey, speedKph, fine
          end
        end
      end
    end
  end

  if best then
    cooldowns[best.id] = simClock + M.COOLDOWN_S
    if M.isExemptRun() then return false end
    flashLeft = M.FLASH_S
    stats.flashes = stats.flashes + 1
    local _, scored = M.applyPenalty(bestFine, best.mobile and 'mobile_radar' or 'speed_camera', M.JOB_SCORE_PENALTY)
    playShutterSound()
    pcall(triggerWorldFlash, bestKey, best)
    if ui_message then
      local label = best.mobile and 'Mobile radar trap!' or 'Speed camera flash!'
      local scoreSuffix = scored and string.format(' (-%d pts)', M.JOB_SCORE_PENALTY) or ''
      ui_message(string.format('%s %d km/h in %d km/h zone. Fine $%d%s.',
        label, math.floor(bestSpeed + 0.5), math.floor(best.limit + 0.5), bestFine, scoreSuffix),
        6, 'beamngEarthSpeedCamera')
    end
    return true
  end
  return false
end

-- Screen-edge red camera flash overlay via ImGui background draw list (zero allocations per frame).
function M.drawFlash(im)
  if not M.isEnabled() then return false end
  local alpha = M.flashAlpha()
  if alpha <= 0.005 then return false end
  im = im or rawget(_G, 'ui_imgui')
  if not im or not im.GetMainViewport or not im.GetBackgroundDrawList1 then return false end
  local vp = im.GetMainViewport()
  if not vp then return false end
  local dl = im.GetBackgroundDrawList1()
  if not dl then return false end
  if not vecs then
    vecs = { im.ImVec2(0, 0), im.ImVec2(0, 0) }
  end
  local a, b = vecs[1], vecs[2]
  local x0, y0 = vp.Pos.x, vp.Pos.y
  local w, h = vp.Size.x, vp.Size.y
  local bandX = math.max(24, w * 0.08)
  local bandY = math.max(20, h * 0.09)

  local edgeCol = im.GetColorU322(im.ImVec4(0.95, 0.08, 0.06, 0.58 * alpha))
  local washCol = im.GetColorU322(im.ImVec4(0.92, 0.06, 0.06, 0.18 * alpha))

  -- Subtle full-screen crimson wash
  a.x, a.y = x0, y0
  b.x, b.y = x0 + w, y0 + h
  im.ImDrawList_AddRectFilled(dl, a, b, washCol, 0)

  -- Top & bottom screen-edge red flash borders
  a.x, a.y = x0, y0
  b.x, b.y = x0 + w, y0 + bandY
  im.ImDrawList_AddRectFilled(dl, a, b, edgeCol, 0)

  a.x, a.y = x0, y0 + h - bandY
  b.x, b.y = x0 + w, y0 + h
  im.ImDrawList_AddRectFilled(dl, a, b, edgeCol, 0)

  -- Left & right screen-edge red flash borders
  a.x, a.y = x0, y0 + bandY
  b.x, b.y = x0 + bandX, y0 + h - bandY
  im.ImDrawList_AddRectFilled(dl, a, b, edgeCol, 0)

  a.x, a.y = x0 + w - bandX, y0 + bandY
  b.x, b.y = x0 + w, y0 + h - bandY
  im.ImDrawList_AddRectFilled(dl, a, b, edgeCol, 0)
  return true
end

return M
