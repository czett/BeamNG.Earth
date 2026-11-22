-- BeamNG.Earth Turn-by-Turn Navigation & Highway-Exit Engine: GE extension 'beamngEarth_turnByTurn'.
-- Deterministic maneuver extraction, OSM street/ref resolution, high-speed Autobahn early-warning scaling,
-- audio chime triggers, and multi-design HUD state ('gmaps_card', 'round_minimap', 'ets_advisor').
-- Pure apart from optional BeamNG globals (runs standalone under plain luajit for unit tests).
local M = {}

M.VERSION = 1
M.PREFS_FILE = '/settings/beamngEarth_nav.json'

M.DESIGNS = { 'gmaps_card', 'round_minimap', 'ets_advisor' }
M.VALID_DESIGNS = { gmaps_card = true, round_minimap = true, ets_advisor = true }
M.VALID_UNITS = { metric = true, imperial = true }

-- Maneuver extraction thresholds
M.MIN_TURN_DEG = 22.0           -- micro-kinks < 22 deg on same street are suppressed
M.COALESCE_DIST_M = 25.0        -- consecutive short kinks within 25 m are coalesced
M.ROAD_MATCH_M = 35.0           -- max perpendicular distance to snap a route segment to an OSM road polyline

-- High-speed / Autobahn early-warning scaling
M.HIGH_SPEED_KPH = 100.0
M.HIGH_SPEED_MPS = 100.0 / 3.6
M.APPROACH_HIGHWAY_M = 1500.0
M.APPROACH_STANDARD_M = 350.0

-- Chime distance thresholds (metres)
M.CHIME_EXIT_FAR_M = 1000.0
M.CHIME_EXIT_NEAR_M = 250.0
M.CHIME_TURN_NEAR_M = 150.0
M.CHIME_ARRIVE_M = 60.0

-- Minimap canvas sampling caps (for 'round_minimap' design)
M.MINI_ROUTE_M = 650.0
M.MINI_ROUTE_BACK_M = 60.0
M.MINI_ROUTE_MAX_PTS = 70
M.MINI_ROAD_RADIUS_M = 460.0
M.MINI_ROAD_MAX_SEGS = 450
M.MINI_ROAD_REFRESH_M = 60.0
M.POSE_HZ_INTERVAL = 1.0 / 60.0

local HIGH_CLASS = { motorway = true, trunk = true }
local LINK_CLASS = { motorway_link = true, trunk_link = true }

local state = {
  enabled = true,
  navDesign = 'gmaps_card',
  chimeEnabled = true,
  units = 'metric',
  hideWorldMarkers = false,
  northUp = false,
  prefsLoaded = false,

  -- Cached route & maneuvers
  routeKey = nil,
  routeVersion = 0,
  maneuvers = {},
  routeX = nil,
  routeY = nil,
  routeCum = nil,
  routeTotalM = 0,

  -- Live tracking
  active = false,
  source = 'none',       -- 'gps' | 'transport' | 'groundMarkers' | 'manual' | 'none'
  destName = '',
  maneuver = 'straight',
  streetName = '',
  roadRef = '',
  roadClass = '',
  destinations = '',
  exitNum = nil,
  isHighwayExit = false,
  distToTurnM = 0,
  approachWindowM = 350,
  approachProgress = 0,
  remainingM = 0,
  etaSec = 0,
  nextManeuver = nil,
  nextStreetName = '',
  currentStreet = '',
  currentPlace = '',
  currentHighway = '',

  -- Vehicle / cockpit telemetry
  playerX = 0,
  playerY = 0,
  headingRad = 0,
  headingDeg = 0,
  speedMs = 0,
  speedKph = 0,
  speedLimitKph = nil,
  speedLimitUnit = 'kmh',
  speedLimitUnlimited = false,
  coordsLabel = '',

  -- Chime state
  chimeSeq = 0,
  chimeKind = nil,
  firedChimes = {},

  -- Round minimap world-space geometry & 60 Hz pose cadence
  miniRoute = nil,
  miniRoads = nil,
  roadsSeq = 0,
  roadsAtX = nil,
  roadsAtY = nil,
  roadsGraph = nil,
  lastPoseClock = -math.huge,
  lastUpdateClock = -math.huge,
}

------------------------------------------------------------------------------------------
-- Pure geometry, street formatting & road-class helpers

local function isFinite(n)
  return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

local function trim(s)
  if type(s) ~= 'string' then return '' end
  return s:match('^%s*(.-)%s*$') or ''
end

function M.isHighClass(hw)
  return type(hw) == 'string' and HIGH_CLASS[hw] == true
end

function M.isLinkClass(hw)
  return type(hw) == 'string' and LINK_CLASS[hw] == true
end

-- Pure: combine OSM ref (e.g. "A 95", "B 472") and name (e.g. "Sindelsdorf", "Hauptstraße") cleanly.
function M.formatStreetName(name, ref, destinations)
  local n = trim(name)
  local r = trim(ref)
  local d = trim(destinations)
  -- Strip semicolon-separated duplicate refs (keep first 2 at most)
  if r:find(';', 1, true) then
    local parts = {}
    for p in r:gmatch('[^;]+') do
      p = trim(p)
      if p ~= '' and #parts < 2 then parts[#parts + 1] = p end
    end
    r = table.concat(parts, ' / ')
  end
  if d:find(';', 1, true) then
    local parts = {}
    for p in d:gmatch('[^;]+') do
      p = trim(p)
      if p ~= '' and #parts < 2 then parts[#parts + 1] = p end
    end
    d = table.concat(parts, ' · ')
  end

  local primary = ''
  if r ~= '' and n ~= '' then
    if n:lower():find(r:lower(), 1, true) then
      primary = n
    else
      primary = r .. ' · ' .. n
    end
  elseif r ~= '' then
    primary = r
  elseif n ~= '' then
    primary = n
  end

  if d ~= '' then
    if primary == '' then return d end
    if not primary:lower():find(d:lower(), 1, true) then
      return primary .. ' · ' .. d
    end
  end
  return primary
end

-- Pure: signed turn angle in degrees (-180 .. +180) from vector (ax, ay) to (bx, by) in ENU (+x East, +y North).
-- Positive = right turn (clockwise), negative = left turn (counter-clockwise).
function M.signedTurnDeg(ax, ay, bx, by)
  local la = math.sqrt(ax * ax + ay * ay)
  local lb = math.sqrt(bx * bx + by * by)
  if la < 1e-6 or lb < 1e-6 then return 0 end
  local dot = (ax * bx + ay * by) / (la * lb)
  local cross = (ax * by - ay * bx) / (la * lb)
  -- ENU: North (0,1) -> East (1,0) has cross = -1 -> right turn (+90)
  return math.deg(math.atan2(-cross, dot))
end

-- Pure: classify a signed turn angle (degrees) into a standard maneuver token.
function M.classifyTurnAngle(deltaDeg)
  local a = math.abs(deltaDeg or 0)
  if a >= 150 then return 'uturn' end
  if a >= 115 then return deltaDeg >= 0 and 'sharp_right' or 'sharp_left' end
  if a >= 45 then return deltaDeg >= 0 and 'turn_right' or 'turn_left' end
  if a >= M.MIN_TURN_DEG then return deltaDeg >= 0 and 'slight_right' or 'slight_left' end
  return 'straight'
end

-- Pure: normalize a list of road polylines or segments into flat segment records.
-- Accepts either:
--   { x1, y1, x2, y2, name, ref, highway, oneway, maxspeed, junction, destinations }
-- or polyline form:
--   { points = { {x, y} | {x=..., y=...}, ... }, name, ref, highway, oneway, maxspeed, junction, destinations }
function M.flattenRoadSegments(roads)
  if type(roads) ~= 'table' or #roads == 0 then return {} end
  local out = {}
  for i = 1, #roads do
    local r = roads[i]
    if type(r) == 'table' then
      if type(r.points) == 'table' and #r.points >= 2 then
        for j = 1, #r.points - 1 do
          local p1, p2 = r.points[j], r.points[j + 1]
          local x1 = tonumber(p1.x or p1[1])
          local y1 = tonumber(p1.y or p1[2])
          local x2 = tonumber(p2.x or p2[1])
          local y2 = tonumber(p2.y or p2[2])
          if x1 and y1 and x2 and y2 then
            out[#out + 1] = {
              x1 = x1, y1 = y1, x2 = x2, y2 = y2,
              name = r.name, ref = r.ref, highway = r.highway or r.roadClass or r.class,
              oneway = r.oneway, maxspeed = r.maxspeed, junction = r.junction,
              destinations = r.destinations,
            }
          end
        end
      elseif r.x1 ~= nil and r.y1 ~= nil and r.x2 ~= nil and r.y2 ~= nil then
        out[#out + 1] = r
      end
    end
  end
  return out
end

-- Pure: match a point (px, py) with optional direction (dx, dy) against flattened OSM road segments.
function M.resolveRoadSegment(px, py, dx, dy, segments, maxDistM)
  if type(segments) ~= 'table' or #segments == 0 then return nil end
  local limit = maxDistM or M.ROAD_MATCH_M
  local limitSq = limit * limit
  local hasDir = isFinite(dx) and isFinite(dy) and (dx * dx + dy * dy) > 1e-6
  local dLen = hasDir and math.sqrt(dx * dx + dy * dy) or 1

  local best, bestScore, bestDistSq = nil, math.huge, math.huge
  for i = 1, #segments do
    local s = segments[i]
    local ax, ay, bx, by = s.x1, s.y1, s.x2, s.y2
    local sx, sy = bx - ax, by - ay
    local l2 = sx * sx + sy * sy
    local t = l2 > 1e-9 and math.max(0, math.min(1, ((px - ax) * sx + (py - ay) * sy) / l2)) or 0
    local qx, qy = ax + t * sx - px, ay + t * sy - py
    local distSq = qx * qx + qy * qy
    if distSq <= limitSq then
      local score = math.sqrt(distSq)
      if hasDir and l2 > 1e-9 then
        local sl = math.sqrt(l2)
        local cosA = (sx * dx + sy * dy) / (sl * dLen)
        if s.oneway == true or s.oneway == 1 or s.oneway == 'yes' then
          if cosA < -0.25 then
            score = score + 60.0 -- penalize wrong-way oneway segment heavily
          else
            score = score + (1 - math.max(0, cosA)) * 12.0
          end
        else
          score = score + (1 - math.abs(cosA)) * 10.0
        end
      end
      if score < bestScore then
        best, bestScore, bestDistSq = s, score, distSq
      end
    end
  end
  if not best then return nil end
  return {
    streetName = M.formatStreetName(best.name, best.ref, best.destinations),
    name = trim(best.name),
    ref = trim(best.ref),
    highway = trim(best.highway or best.roadClass or best.class),
    maxspeed = tonumber(best.maxspeed),
    oneway = best.oneway,
    junction = trim(best.junction),
    destinations = trim(best.destinations),
    dist = math.sqrt(bestDistSq),
  }
end

------------------------------------------------------------------------------------------
-- Pure Maneuver Extraction: from ENU polyline + OSM road segments

local function normalizePolyline(pts)
  local xs, ys, cum = {}, {}, { 0 }
  if type(pts) ~= 'table' then return xs, ys, cum end
  for i = 1, #pts do
    local p = pts[i]
    local x = tonumber(type(p) == 'table' and (p.x or p[1]))
    local y = tonumber(type(p) == 'table' and (p.y or p[2]))
    if x and y then
      local n = #xs
      if n == 0 or (x - xs[n]) ^ 2 + (y - ys[n]) ^ 2 > 0.04 then
        xs[n + 1] = x
        ys[n + 1] = y
        if n >= 1 then
          cum[n + 1] = cum[n] + math.sqrt((x - xs[n]) ^ 2 + (y - ys[n]) ^ 2)
        end
      end
    end
  end
  return xs, ys, cum
end

-- Pure: extract ordered maneuvers from an ENU route polyline + optional OSM road segments.
-- Returns { { type, streetName, ref, roadClass, destinations, s, x, y, angleDeg, isHighwayExit, exitNum } ... }
function M.extractManeuvers(routePoints, roadSegments, opts)
  opts = opts or {}
  local xs, ys, cum
  if type(routePoints) == 'table' and type(routePoints.x) == 'table' and type(routePoints.y) == 'table' then
    xs, ys = routePoints.x, routePoints.y
    cum = routePoints.cum
    if not cum or #cum ~= #xs then
      cum = { 0 }
      for i = 2, #xs do
        cum[i] = cum[i - 1] + math.sqrt((xs[i] - xs[i - 1]) ^ 2 + (ys[i] - ys[i - 1]) ^ 2)
      end
    end
  else
    xs, ys, cum = normalizePolyline(routePoints)
  end

  local n = #xs
  if n < 2 then return {}, xs, ys, cum end

  local flatRoads = M.flattenRoadSegments(roadSegments)
  local segMeta = {}
  for i = 1, n - 1 do
    local mx = (xs[i] + xs[i + 1]) * 0.5
    local my = (ys[i] + ys[i + 1]) * 0.5
    local dx = xs[i + 1] - xs[i]
    local dy = ys[i + 1] - ys[i]
    local r = #flatRoads > 0 and M.resolveRoadSegment(mx, my, dx, dy, flatRoads) or nil
    segMeta[i] = r or { streetName = '', name = '', ref = '', highway = '', destinations = '', junction = '' }
  end

  -- Helper: look ahead past an unnamed *_link ramp to pick up the target road's streetName/ref/destinations
  local function lookAheadName(startSeg)
    for k = startSeg, math.min(n - 1, startSeg + 8) do
      local m = segMeta[k]
      if m and m.streetName ~= '' then
        return m.streetName, m.ref, m.destinations
      end
    end
    return '', '', ''
  end

  local rawEvents = {}
  local i = 2
  while i <= n - 1 do
    local ax, ay = xs[i] - xs[i - 1], ys[i] - ys[i - 1]
    local bx, by = xs[i + 1] - xs[i], ys[i + 1] - ys[i]
    local delta = M.signedTurnDeg(ax, ay, bx, by)
    local prevM = segMeta[i - 1]
    local nextM = segMeta[i]

    local prevHw = prevM.highway or ''
    local nextHw = nextM.highway or ''
    local sameStreet = (prevM.streetName ~= '' and prevM.streetName == nextM.streetName)
      or (prevM.streetName == '' and nextM.streetName == '' and prevHw == nextHw)

    -- Coalesce consecutive short segments (< COALESCE_DIST_M) into one turn if they bend the same way
    -- and neither is a highway class transition.
    local endIdx = i
    local totalDelta = delta
    local isTransition = (M.isHighClass(prevHw) and M.isLinkClass(nextHw))
      or (M.isLinkClass(prevHw) and M.isHighClass(nextHw))
      or (nextM.junction == 'roundabout' or nextHw == 'roundabout')

    if not isTransition then
      while endIdx < n - 1 and (cum[endIdx + 1] - cum[i]) < M.COALESCE_DIST_M do
        local nAx, nAy = xs[endIdx + 1] - xs[endIdx], ys[endIdx + 1] - ys[endIdx]
        local nBx, nBy = xs[endIdx + 2] - xs[endIdx + 1], ys[endIdx + 2] - ys[endIdx + 1]
        local d2 = M.signedTurnDeg(nAx, nAy, nBx, nBy)
        local m2 = segMeta[endIdx + 1]
        local tr2 = (M.isHighClass(segMeta[endIdx].highway) and M.isLinkClass(m2.highway))
          or (M.isLinkClass(segMeta[endIdx].highway) and M.isHighClass(m2.highway))
        if tr2 then break end
        -- Only accumulate if same turn direction or tiny intermediate wiggle
        if (totalDelta * d2 >= 0) or math.abs(d2) < 10 then
          totalDelta = totalDelta + d2
          endIdx = endIdx + 1
          nextM = m2
          nextHw = nextM.highway or ''
          sameStreet = (prevM.streetName ~= '' and prevM.streetName == nextM.streetName)
            or (prevM.streetName == '' and nextM.streetName == '' and prevHw == nextHw)
        else
          break
        end
      end
    end

    local mType = nil
    local isHighwayExit = false
    if M.isHighClass(prevHw) and M.isLinkClass(nextHw) then
      mType = (totalDelta < -10) and 'exit_left' or 'exit_right'
      isHighwayExit = true
    elseif M.isLinkClass(prevHw) and M.isHighClass(nextHw) then
      mType = (totalDelta > 10) and 'merge_right' or 'merge_left'
    elseif (nextM.junction == 'roundabout' or nextHw == 'roundabout')
      and prevM.junction ~= 'roundabout' and prevHw ~= 'roundabout' then
      mType = 'roundabout'
    else
      local absD = math.abs(totalDelta)
      if absD >= M.MIN_TURN_DEG then
        -- Suppress gentle curve micro-kinks on the same street if spread over short wiggle < MIN_TURN_DEG
        mType = M.classifyTurnAngle(totalDelta)
      elseif not sameStreet and absD >= 18 then
        mType = M.classifyTurnAngle(totalDelta >= 0 and M.MIN_TURN_DEG or -M.MIN_TURN_DEG)
      end
    end

    if mType and mType ~= 'straight' then
      local sName = nextM.streetName
      local sRef = nextM.ref
      local sDest = nextM.destinations
      if sName == '' then
        sName, sRef, sDest = lookAheadName(endIdx)
      end
      rawEvents[#rawEvents + 1] = {
        type = mType,
        streetName = sName,
        ref = sRef or '',
        roadClass = nextHw,
        destinations = sDest or '',
        s = cum[i],
        x = xs[i],
        y = ys[i],
        angleDeg = math.floor(totalDelta * 10 + 0.5) / 10,
        isHighwayExit = isHighwayExit,
      }
    end

    i = endIdx + 1
  end

  -- Append final arrival maneuver
  local destName = trim(opts.destName)
  if destName == '' then
    destName = segMeta[n - 1] and segMeta[n - 1].streetName or 'Destination'
  end
  rawEvents[#rawEvents + 1] = {
    type = 'arrive',
    streetName = destName ~= '' and destName or 'Destination',
    ref = segMeta[n - 1] and segMeta[n - 1].ref or '',
    roadClass = segMeta[n - 1] and segMeta[n - 1].highway or '',
    destinations = '',
    s = cum[n],
    x = xs[n],
    y = ys[n],
    angleDeg = 0,
    isHighwayExit = false,
  }

  return rawEvents, xs, ys, cum
end

------------------------------------------------------------------------------------------
-- Pure Maneuver Extraction: from OSRM steps (server/routing.py route.steps)

local function mapOsrmStep(step)
  local stype = tostring(step.type or ''):lower()
  local mod = tostring(step.modifier or ''):lower()
  if stype == 'depart' then return nil, false end
  if stype == 'arrive' then return 'arrive', false end
  if stype == 'off ramp' then
    local isLeft = mod:find('left', 1, true) ~= nil
    return isLeft and 'exit_left' or 'exit_right', true
  end
  if stype == 'on ramp' or stype == 'merge' then
    local isRight = mod:find('right', 1, true) ~= nil
    return isRight and 'merge_right' or 'merge_left', false
  end
  if stype == 'roundabout' or stype == 'rotary' or stype == 'roundabout turn' then
    return 'roundabout', false
  end
  if stype == 'exit roundabout' or stype == 'exit rotary' then
    return nil, false
  end
  if stype == 'continue' or stype == 'new name' or stype == 'notification' then
    if mod == '' or mod == 'straight' then return nil, false end
  end

  if mod == 'uturn' then return 'uturn', false end
  if mod == 'sharp left' then return 'sharp_left', false end
  if mod == 'sharp right' then return 'sharp_right', false end
  if mod == 'left' then return 'turn_left', false end
  if mod == 'right' then return 'turn_right', false end
  if mod == 'slight left' then return 'slight_left', false end
  if mod == 'slight right' then return 'slight_right', false end
  if mod == 'straight' then return nil, false end

  -- Fallback from bearings if modifier was omitted
  if isFinite(step.bearingBefore) and isFinite(step.bearingAfter) then
    local d = ((step.bearingAfter - step.bearingBefore + 540) % 360) - 180
    if math.abs(d) >= M.MIN_TURN_DEG then
      return M.classifyTurnAngle(d), false
    end
  end
  return nil, false
end

function M.extractFromSteps(steps, destName)
  if type(steps) ~= 'table' or #steps == 0 then return {} end
  local out = {}
  local prevStreet = ''
  local prevOffset = -1e9
  for i = 1, #steps do
    local s = steps[i]
    if type(s) == 'table' then
      local mType, isExit = mapOsrmStep(s)
      local sName = M.formatStreetName(s.name, s.ref, s.destinations)
      local off = tonumber(s.offset) or 0
      if mType then
        -- Suppress micro-kinks on same street within COALESCE_DIST_M
        local skip = false
        if not isExit and mType ~= 'arrive' and mType ~= 'roundabout' and sName ~= '' and sName == prevStreet
          and (off - prevOffset) < M.COALESCE_DIST_M
          and (mType == 'slight_left' or mType == 'slight_right') then
          skip = true
        end
        if not skip then
          if mType == 'arrive' and trim(destName) ~= '' then
            sName = trim(destName)
          elseif sName == '' and mType == 'arrive' then
            sName = 'Destination'
          end
          out[#out + 1] = {
            type = mType,
            streetName = sName,
            ref = trim(s.ref),
            roadClass = isExit and 'motorway_link' or '',
            destinations = trim(s.destinations),
            exitNum = tonumber(s.exit),
            s = off,
            lat = s.location and tonumber(s.location.lat) or nil,
            lon = s.location and tonumber(s.location.lon) or nil,
            isHighwayExit = isExit,
          }
          prevStreet = sName
          prevOffset = off
        end
      else
        if sName ~= '' then prevStreet = sName end
      end
    end
  end
  return out
end

------------------------------------------------------------------------------------------
-- Pure High-Speed Approach Scaling & Live Maneuver Evaluation

function M.approachWindow(speedMs, currentHighway, maneuverType)
  local v = tonumber(speedMs) or 0
  local isHigh = v >= M.HIGH_SPEED_MPS
    or M.isHighClass(currentHighway)
    or maneuverType == 'exit_right'
    or maneuverType == 'exit_left'
  return isHigh and M.APPROACH_HIGHWAY_M or M.APPROACH_STANDARD_M
end

function M.approachProgress(distToTurnM, windowM)
  local d = math.max(0, tonumber(distToTurnM) or 0)
  local w = math.max(1, tonumber(windowM) or M.APPROACH_STANDARD_M)
  return math.max(0, math.min(1, 1.0 - (d / w)))
end

-- Pure: evaluate next maneuver, next-after-next preview, approach scaling, and chime threshold.
function M.evaluateProgress(maneuvers, sNow, totalM, speedMs, currentHighway, remainingM, etaSec, firedChimes)
  if type(maneuvers) ~= 'table' or #maneuvers == 0 then
    return nil
  end
  local s = math.max(0, tonumber(sNow) or 0)
  local idx = #maneuvers
  for i = 1, #maneuvers do
    if (tonumber(maneuvers[i].s) or 0) >= s - 8.0 then
      idx = i
      break
    end
  end

  local cur = maneuvers[idx]
  local nxt = maneuvers[idx + 1]
  local distToTurn = math.max(0, (tonumber(cur.s) or 0) - s)
  local windowM = M.approachWindow(speedMs, currentHighway, cur.type)
  local progress = M.approachProgress(distToTurn, windowM)
  local rem = tonumber(remainingM)
  if not rem then rem = math.max(0, (tonumber(totalM) or 0) - s) end
  local eta = tonumber(etaSec)
  if not eta then
    local v = math.max(8.0, tonumber(speedMs) or 13.8)
    eta = rem / v
  end

  -- Determine chime trigger (each maneuver+stage fires once)
  local chimeKind = nil
  if type(firedChimes) == 'table' then
    local isExit = cur.isHighwayExit == true or cur.type == 'exit_right' or cur.type == 'exit_left'
    if cur.type == 'arrive' then
      local k = idx .. ':arrive'
      if distToTurn <= M.CHIME_ARRIVE_M and not firedChimes[k] then
        firedChimes[k] = true
        chimeKind = 'arrive'
      end
    elseif isExit then
      local kNear = idx .. ':exit_near'
      local kFar = idx .. ':exit_far'
      if distToTurn <= M.CHIME_EXIT_NEAR_M and not firedChimes[kNear] then
        firedChimes[kNear] = true
        firedChimes[kFar] = true
        chimeKind = 'exit_near'
      elseif distToTurn <= M.CHIME_EXIT_FAR_M and not firedChimes[kFar] then
        firedChimes[kFar] = true
        chimeKind = 'exit_far'
      end
    else
      local kTurn = idx .. ':turn_near'
      if distToTurn <= M.CHIME_TURN_NEAR_M and not firedChimes[kTurn] then
        firedChimes[kTurn] = true
        chimeKind = 'turn_near'
      end
    end
  end

  return {
    maneuverIndex = idx,
    maneuver = cur.type or 'straight',
    streetName = cur.streetName or '',
    roadRef = cur.ref or '',
    roadClass = cur.roadClass or '',
    destinations = cur.destinations or '',
    exitNum = cur.exitNum,
    isHighwayExit = cur.isHighwayExit == true or cur.type == 'exit_right' or cur.type == 'exit_left',
    distToTurnM = math.floor(distToTurn + 0.5),
    approachWindowM = windowM,
    approachProgress = math.floor(progress * 1000 + 0.5) / 1000,
    remainingM = math.floor(math.max(0, rem) + 0.5),
    etaSec = math.floor(math.max(0, eta) + 0.5),
    nextManeuver = nxt and nxt.type or nil,
    nextStreetName = nxt and (nxt.streetName or '') or '',
    chimeKind = chimeKind,
  }
end

------------------------------------------------------------------------------------------
-- Persistence & Multi-Design Settings API

function M.savePrefs(path)
  local write = rawget(_G, 'jsonWriteFile')
  if not write then return false end
  local out = {
    version = M.VERSION,
    enabled = state.enabled,
    navDesign = state.navDesign,
    chimeEnabled = state.chimeEnabled,
    units = state.units,
    hideWorldMarkers = state.hideWorldMarkers,
    northUp = state.northUp,
  }
  local ok, res = pcall(write, path or M.PREFS_FILE, out, true)
  return ok and res ~= false
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
  if type(data.navDesign) == 'string' and M.VALID_DESIGNS[data.navDesign] then
    state.navDesign = data.navDesign
  end
  if data.chimeEnabled ~= nil then state.chimeEnabled = data.chimeEnabled == true end
  if type(data.units) == 'string' and M.VALID_UNITS[data.units] then
    state.units = data.units
  end
  if data.hideWorldMarkers ~= nil then state.hideWorldMarkers = data.hideWorldMarkers == true end
  if data.northUp ~= nil then state.northUp = data.northUp == true end
  -- Apply world marker preference to gps.lua if loaded
  local okG, gps = pcall(require, 'beamngEarth/gps')
  if okG and gps and gps.setWorldArrows then
    gps.setWorldArrows(not state.hideWorldMarkers)
  end
  return true
end

local function ensurePrefs()
  if not state.prefsLoaded then M.loadPrefs() end
end

function M.setEnabled(flag)
  ensurePrefs()
  state.enabled = flag ~= false
  M.savePrefs()
  return state.enabled
end

function M.setDesign(design)
  ensurePrefs()
  if type(design) ~= 'string' or not M.VALID_DESIGNS[design] then
    return state.navDesign, false
  end
  state.navDesign = design
  M.savePrefs()
  return state.navDesign, true
end

function M.cycleDesign()
  ensurePrefs()
  local curIdx = 1
  for i = 1, #M.DESIGNS do
    if M.DESIGNS[i] == state.navDesign then curIdx = i; break end
  end
  local nextIdx = (curIdx % #M.DESIGNS) + 1
  state.navDesign = M.DESIGNS[nextIdx]
  M.savePrefs()
  return state.navDesign, nextIdx
end

function M.setChimeEnabled(flag)
  ensurePrefs()
  state.chimeEnabled = flag ~= false
  M.savePrefs()
  return state.chimeEnabled
end

function M.setUnits(units)
  ensurePrefs()
  if type(units) ~= 'string' or not M.VALID_UNITS[units] then
    return state.units, false
  end
  state.units = units
  M.savePrefs()
  return state.units, true
end

function M.setHideWorldMarkers(flag)
  ensurePrefs()
  state.hideWorldMarkers = flag == true
  local okG, gps = pcall(require, 'beamngEarth/gps')
  if okG and gps and gps.setWorldArrows then
    gps.setWorldArrows(not state.hideWorldMarkers)
  end
  M.savePrefs()
  return state.hideWorldMarkers
end

function M.setNorthUp(flag)
  ensurePrefs()
  state.northUp = flag == true
  M.savePrefs()
  return state.northUp
end

------------------------------------------------------------------------------------------
-- Minimap Canvas Data Builders (world-space ENU coordinates for 60-FPS smooth rendering)

local function buildMiniRoute(xs, ys, cum, sNow)
  if not xs or #xs < 2 then return nil end
  local out = {}
  local n = #xs
  local sStart = math.max(0, sNow - M.MINI_ROUTE_BACK_M)
  local sEnd = math.min(cum[n], sNow + M.MINI_ROUTE_M)
  local step = math.max(10, (sEnd - sStart) / M.MINI_ROUTE_MAX_PTS)
  local k = 1
  while k < n - 1 and cum[k + 1] < sStart do k = k + 1 end
  local s = sStart
  while #out < M.MINI_ROUTE_MAX_PTS * 2 do
    while k < n - 1 and cum[k + 1] < s do k = k + 1 end
    local seg = cum[k + 1] - cum[k]
    local f = seg > 0 and math.max(0, math.min(1, (s - cum[k]) / seg)) or 0
    local rx = xs[k] + f * (xs[k + 1] - xs[k])
    local ry = ys[k] + f * (ys[k + 1] - ys[k])
    out[#out + 1] = math.floor(rx * 10 + 0.5) / 10
    out[#out + 1] = math.floor(ry * 10 + 0.5) / 10
    if s >= sEnd - 0.5 then break end
    s = math.min(s + step, sEnd)
  end
  return out
end

local function buildMiniRoads(px, py, force)
  -- Primary: reuse minimaproads.lua's already-indexed spatial grid (all roads + tunnels)
  local okM, mr = pcall(require, 'beamngEarth/minimaproads')
  local okN, ng = pcall(require, 'beamngEarth/navgraph')
  local curGraph = (okN and ng and ng.currentGraph) and ng.currentGraph() or nil

  if not force and state.miniRoads and state.roadsAtX and state.roadsGraph == curGraph then
    local dx, dy = px - state.roadsAtX, py - state.roadsAtY
    if dx * dx + dy * dy < M.MINI_ROAD_REFRESH_M * M.MINI_ROAD_REFRESH_M then
      return state.miniRoads
    end
  end

  local out = nil
  if okM and mr and type(mr.queryWorld) == 'function' then
    local q, qGraph = mr.queryWorld(px, py, M.MINI_ROAD_RADIUS_M, M.MINI_ROAD_MAX_SEGS)
    if q and #q > 0 then
      out = q
      curGraph = qGraph or curGraph
    end
  end

  if not out and curGraph and curGraph.nodes and curGraph.edges then
    local r = M.MINI_ROAD_RADIUS_M
    local r2 = r * r
    local cap = M.MINI_ROAD_MAX_SEGS * 5
    out = {}
    local seen = {}
    for i = 1, #curGraph.edges do
      local e = curGraph.edges[i]
      local a, b = curGraph.nodes[e[1]], curGraph.nodes[e[2]]
      if a and b and e[1] ~= e[2] then
        local dx1, dy1 = a[1] - px, a[2] - py
        local dx2, dy2 = b[1] - px, b[2] - py
        if (dx1 * dx1 + dy1 * dy1 <= r2) or (dx2 * dx2 + dy2 * dy2 <= r2) then
          local pk = e[1] < e[2] and (e[1] .. '|' .. e[2]) or (e[2] .. '|' .. e[1])
          if not seen[pk] then
            seen[pk] = true
            local d = e[7] or 1
            local cls = (e[13] == 1 or e[13] == 2) and 0 or (d >= 0.85 and 1 or (d > 0.25 and 2 or 3))
            local n = #out
            out[n + 1] = math.floor(a[1] * 10 + 0.5) / 10
            out[n + 2] = math.floor(a[2] * 10 + 0.5) / 10
            out[n + 3] = math.floor(b[1] * 10 + 0.5) / 10
            out[n + 4] = math.floor(b[2] * 10 + 0.5) / 10
            out[n + 5] = cls
            if #out >= cap then break end
          end
        end
      end
    end
  end

  state.roadsAtX, state.roadsAtY, state.roadsGraph = px, py, curGraph
  state.roadsSeq = state.roadsSeq + 1
  return out
end

-- Pure: true chassis forward heading (radians clockwise from North +y, and 0..359 degrees).
-- Uses vehicle forward vector strictly (getDirectionVector / player.fwdX,fwdY), NEVER velocity,
-- so reversing (R) or idling at 0 km/h never flips or jitters the minimap/compass.
function M.computeHeading(veh, player, prevHeadingRad)
  local fx, fy = nil, nil
  if veh and veh.getDirectionVector then
    local ok, d = pcall(function() return veh:getDirectionVector() end)
    if ok and d and isFinite(d.x) and isFinite(d.y) and (d.x * d.x + d.y * d.y) > 1e-4 then
      fx, fy = d.x, d.y
    end
  end
  if not fx and type(player) == 'table' and isFinite(player.fwdX) and isFinite(player.fwdY) then
    if (player.fwdX * player.fwdX + player.fwdY * player.fwdY) > 1e-4 then
      fx, fy = player.fwdX, player.fwdY
    end
  end
  local rad = nil
  if fx and fy then
    rad = math.atan2(fx, fy)
    if rad < 0 then rad = rad + math.pi * 2 end
  elseif type(player) == 'table' and isFinite(player.heading) then
    rad = math.rad((player.heading % 360 + 360) % 360)
  else
    rad = isFinite(prevHeadingRad) and prevHeadingRad or 0
  end
  local deg = math.floor((math.deg(rad) % 360) + 0.5) % 360
  return rad, deg
end

-- High-rate (60 Hz) pose emitter called every frame from core.lua while BeamNGEarthNav is mounted.
function M.onFrame(player, clock)
  if not state.enabled or not player then return false end
  local now = tonumber(clock) or os.clock()
  if now - state.lastPoseClock < M.POSE_HZ_INTERVAL then return false end
  state.lastPoseClock = now

  local px = tonumber(player.x) or state.playerX or 0
  local py = tonumber(player.y) or state.playerY or 0
  local vx = tonumber(player.vx) or 0
  local vy = tonumber(player.vy) or 0
  local speedMs = tonumber(player.speed) or math.sqrt(vx * vx + vy * vy)
  local veh = rawget(_G, 'getPlayerVehicle') and getPlayerVehicle(0) or nil
  local hRad, hDeg = M.computeHeading(veh, player, state.headingRad)

  state.playerX, state.playerY = px, py
  state.headingRad, state.headingDeg = hRad, hDeg
  state.speedMs = speedMs
  state.speedKph = math.floor(speedMs * 3.6 + 0.5)

  local gh = rawget(_G, 'guihooks')
  if gh and gh.trigger then
    gh.trigger('BeamNGEarthNavPose', {
      x = px,
      y = py,
      headingRad = hRad,
      headingDeg = hDeg,
      speedMs = speedMs,
      speedKph = state.speedKph,
      t = now,
    })
  end
  return true
end

------------------------------------------------------------------------------------------
-- Live Frame Update & Route Ingestion

local function clearLiveRoute()
  state.active = false
  state.source = 'none'
  state.routeKey = nil
  state.maneuvers = {}
  state.routeX, state.routeY, state.routeCum = nil, nil, nil
  state.routeTotalM = 0
  state.destName = ''
  state.maneuver = 'straight'
  state.streetName = ''
  state.roadRef = ''
  state.roadClass = ''
  state.destinations = ''
  state.exitNum = nil
  state.isHighwayExit = false
  state.distToTurnM = 0
  state.approachProgress = 0
  state.remainingM = 0
  state.etaSec = 0
  state.nextManeuver = nil
  state.nextStreetName = ''
  state.miniRoute = nil
  state.firedChimes = {}
end

local function readTelemetry(player)
  local px = player and tonumber(player.x) or 0
  local py = player and tonumber(player.y) or 0
  local vx = player and tonumber(player.vx) or 0
  local vy = player and tonumber(player.vy) or 0
  local speedMs = tonumber(player and player.speed) or math.sqrt(vx * vx + vy * vy)
  state.playerX, state.playerY = px, py
  state.speedMs = speedMs
  state.speedKph = math.floor(speedMs * 3.6 + 0.5)

  -- True chassis forward heading (never flips on reverse or idle)
  local veh = rawget(_G, 'getPlayerVehicle') and getPlayerVehicle(0) or nil
  local hRad, hDeg = M.computeHeading(veh, player, state.headingRad)
  state.headingRad = hRad
  state.headingDeg = hDeg

  -- Current street, town & coordinates
  local okS, sb = pcall(require, 'beamngEarth/statusbar')
  if okS and sb and sb.location then
    local loc = sb.location()
    if type(loc) == 'table' then
      state.currentStreet = trim(loc.street)
      state.currentPlace = trim(loc.place)
    end
  end
  if player and isFinite(player.lat) and isFinite(player.lon) then
    state.coordsLabel = string.format('%.4f° %s, %.4f° %s',
      math.abs(player.lat), player.lat >= 0 and 'N' or 'S',
      math.abs(player.lon), player.lon >= 0 and 'E' or 'W')
  end

  -- Speed limit & highway class from api.speedLimit() / navgraph
  local api = rawget(_G, 'beamngEarth_api')
  if api and type(api.speedLimit) == 'function' then
    local okL, lim = pcall(api.speedLimit)
    if okL and type(lim) == 'table' and tonumber(lim.ms) then
      state.speedLimitKph = math.floor(tonumber(lim.ms) * 3.6 + 0.5)
      state.speedLimitUnit = lim.unit or 'kmh'
    end
  end
  local okN, ng = pcall(require, 'beamngEarth/navgraph')
  if okN and ng and type(ng.roadProfileAt) == 'function' then
    local okP, prof = pcall(ng.roadProfileAt, px, py)
    if okP and type(prof) == 'table' then
      state.speedLimitUnlimited = prof.unlimited == true
      if prof.highway == true then
        state.currentHighway = 'motorway'
      else
        state.currentHighway = ''
      end
    end
  end

  return px, py, speedMs
end

-- Called from core.lua onUpdate (throttled to ~4 Hz to match HUD update cadence).
function M.update(dtReal, anchor, player, clock)
  ensurePrefs()
  local now = tonumber(clock) or os.clock()
  if now - state.lastUpdateClock < 0.2 then return end
  state.lastUpdateClock = now

  local px, py, speedMs = readTelemetry(player)

  -- 1. Primary source: gps.lua active route (covers Transport Modes, map GPS, and manual waypoints)
  local okG, gps = pcall(require, 'beamngEarth/gps')
  local enu = okG and gps and gps.currentEnu and gps.currentEnu() or nil
  local gpsStatus = okG and gps and gps.status and gps.status() or nil

  if enu and enu.x and #enu.x >= 2 then
    local rKey = 'gps:' .. tostring(enu.version or 0) .. ':' .. tostring(#enu.x) .. ':' .. tostring(enu.destName or '')
    if rKey ~= state.routeKey then
      state.routeKey = rKey
      state.routeVersion = enu.version or 0
      state.routeX, state.routeY, state.routeCum = enu.x, enu.y, enu.cum
      state.routeTotalM = enu.cum[#enu.cum] or 0
      state.firedChimes = {}
      if type(enu.steps) == 'table' and #enu.steps > 0 then
        state.maneuvers = M.extractFromSteps(enu.steps, enu.destName)
      else
        state.maneuvers = M.extractManeuvers(enu, nil, { destName = enu.destName })
      end
    end
    state.active = true
    state.source = (gpsStatus and gpsStatus.managed) and 'transport' or 'gps'
    state.destName = enu.destName or ''

    local sNow = tonumber(enu.progressS) or 0
    local ev = M.evaluateProgress(
      state.maneuvers, sNow, state.routeTotalM, speedMs,
      state.currentHighway, enu.remaining, enu.eta, state.firedChimes
    )
    if ev then
      state.maneuver = ev.maneuver
      state.streetName = ev.streetName
      state.roadRef = ev.roadRef
      state.roadClass = ev.roadClass
      state.destinations = ev.destinations
      state.exitNum = ev.exitNum
      state.isHighwayExit = ev.isHighwayExit
      state.distToTurnM = ev.distToTurnM
      state.approachWindowM = ev.approachWindowM
      state.approachProgress = ev.approachProgress
      state.remainingM = ev.remainingM
      state.etaSec = ev.etaSec
      state.nextManeuver = ev.nextManeuver
      state.nextStreetName = ev.nextStreetName
      if ev.chimeKind and state.chimeEnabled then
        state.chimeSeq = state.chimeSeq + 1
        state.chimeKind = ev.chimeKind
      end
    end

    if state.navDesign == 'round_minimap' then
      state.miniRoute = buildMiniRoute(enu.x, enu.y, enu.cum, sNow)
      state.miniRoads = buildMiniRoads(px, py)
    else
      state.miniRoute = nil
      state.miniRoads = nil
    end
    return
  end

  -- 2. Fallback: active GPS destination before OSRM route returns (or offline straight-line guidance)
  if gpsStatus and gpsStatus.dist then
    state.active = true
    state.source = gpsStatus.managed and 'transport' or 'gps'
    state.destName = gpsStatus.name or 'Destination'
    state.maneuver = 'straight'
    state.streetName = state.destName
    state.roadRef = ''
    state.roadClass = ''
    state.destinations = ''
    state.exitNum = nil
    state.isHighwayExit = false
    state.distToTurnM = math.floor((tonumber(gpsStatus.dist) or 0) + 0.5)
    state.remainingM = math.floor((tonumber(gpsStatus.remaining) or tonumber(gpsStatus.dist) or 0) + 0.5)
    local v = math.max(8.0, speedMs)
    state.etaSec = math.floor((tonumber(gpsStatus.eta) or (state.remainingM / v)) + 0.5)
    state.approachWindowM = M.approachWindow(speedMs, state.currentHighway, 'straight')
    state.approachProgress = M.approachProgress(state.distToTurnM, state.approachWindowM)
    state.nextManeuver = 'arrive'
    state.nextStreetName = state.destName
    if state.navDesign == 'round_minimap' then
      state.miniRoute = nil
      state.miniRoads = buildMiniRoads(px, py)
    end
    return
  end

  -- 3. Fallback: stock core_groundMarkers routePlanner path (if set by another mod/mission)
  local gm = rawget(_G, 'core_groundMarkers')
  local rp = gm and gm.routePlanner
  if rp and type(rp.path) == 'table' and #rp.path >= 2 then
    local pts = {}
    for i = 1, #rp.path do
      local p = rp.path[i] and rp.path[i].pos
      if p and p.x and p.y then pts[#pts + 1] = { p.x, p.y } end
    end
    if #pts >= 2 then
      local rKey = 'gm:' .. tostring(#pts) .. ':' .. math.floor(pts[#pts][1]) .. ':' .. math.floor(pts[#pts][2])
      if rKey ~= state.routeKey then
        state.routeKey = rKey
        state.firedChimes = {}
        local mans, xs, ys, cum = M.extractManeuvers(pts, nil, { destName = 'Waypoint' })
        state.maneuvers, state.routeX, state.routeY, state.routeCum = mans, xs, ys, cum
        state.routeTotalM = cum[#cum] or 0
      end
      state.active = true
      state.source = 'groundMarkers'
      state.destName = 'Waypoint'
      local rem = tonumber(rp.path[1] and rp.path[1].distToTarget) or state.routeTotalM
      local sNow = math.max(0, state.routeTotalM - rem)
      local ev = M.evaluateProgress(
        state.maneuvers, sNow, state.routeTotalM, speedMs,
        state.currentHighway, rem, nil, state.firedChimes
      )
      if ev then
        state.maneuver = ev.maneuver
        state.streetName = ev.streetName
        state.distToTurnM = ev.distToTurnM
        state.approachWindowM = ev.approachWindowM
        state.approachProgress = ev.approachProgress
        state.remainingM = ev.remainingM
        state.etaSec = ev.etaSec
        state.nextManeuver = ev.nextManeuver
        state.nextStreetName = ev.nextStreetName
        if ev.chimeKind and state.chimeEnabled then
          state.chimeSeq = state.chimeSeq + 1
          state.chimeKind = ev.chimeKind
        end
      end
      if state.navDesign == 'round_minimap' then
        state.miniRoute = buildMiniRoute(state.routeX, state.routeY, state.routeCum, sNow)
        state.miniRoads = buildMiniRoads(px, py)
      end
      return
    end
  end

  -- No active route
  if state.active then clearLiveRoute() end
  if state.navDesign == 'round_minimap' then
    state.miniRoads = buildMiniRoads(px, py)
  else
    state.miniRoads = nil
  end
end

------------------------------------------------------------------------------------------
-- Payloads for HUD App (hudapps.lua) and Vue Settings Card (EarthNav.vue)

function M.hudPayload()
  ensurePrefs()
  return {
    enabled = state.enabled,
    active = state.active,
    source = state.source,
    navDesign = state.navDesign,
    chimeEnabled = state.chimeEnabled,
    units = state.units,
    hideWorldMarkers = state.hideWorldMarkers,
    northUp = state.northUp,
    maneuver = state.maneuver,
    streetName = state.streetName,
    roadRef = state.roadRef,
    roadClass = state.roadClass,
    destinations = state.destinations,
    exitNum = state.exitNum,
    isHighwayExit = state.isHighwayExit,
    distToTurnM = state.distToTurnM,
    approachWindowM = state.approachWindowM,
    approachProgress = state.approachProgress,
    remainingM = state.remainingM,
    etaSec = state.etaSec,
    nextManeuver = state.nextManeuver,
    nextStreetName = state.nextStreetName,
    destName = state.destName,
    currentStreet = state.currentStreet,
    currentPlace = state.currentPlace,
    playerX = state.playerX,
    playerY = state.playerY,
    headingRad = state.headingRad,
    headingDeg = state.headingDeg,
    speedMs = state.speedMs,
    speedKph = state.speedKph,
    speedLimitKph = state.speedLimitKph,
    speedLimitUnit = state.speedLimitUnit,
    speedLimitUnlimited = state.speedLimitUnlimited,
    coordsLabel = state.coordsLabel,
    chimeSeq = state.chimeSeq,
    chimeKind = state.chimeKind,
    roadsSeq = state.roadsSeq,
    miniRoute = state.miniRoute,
    miniRoads = state.miniRoads,
  }
end

function M.uiState()
  ensurePrefs()
  local p = M.hudPayload()
  p.designs = M.DESIGNS
  return p
end

function M.reset()
  clearLiveRoute()
  state.lastUpdateClock = -math.huge
  state.lastPoseClock = -math.huge
  state.miniRoads = nil
  state.roadsAtX, state.roadsAtY, state.roadsGraph = nil, nil, nil
end

function M._resetForTest()
  M.reset()
  state.enabled = true
  state.navDesign = 'gmaps_card'
  state.chimeEnabled = true
  state.units = 'metric'
  state.hideWorldMarkers = false
  state.northUp = false
  state.prefsLoaded = true
  state.chimeSeq = 0
  state.chimeKind = nil
  state.playerX = 0
  state.playerY = 0
  state.headingRad = 0
  state.headingDeg = 0
  state.speedMs = 0
  state.speedKph = 0
  state.speedLimitKph = nil
  state.speedLimitUnlimited = false
  state.currentStreet = ''
  state.currentPlace = ''
  state.currentHighway = ''
  state.roadsSeq = 0
end

return M
