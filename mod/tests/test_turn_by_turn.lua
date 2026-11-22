-- luajit mod/tests/test_turn_by_turn.lua
-- Unit tests for Turn-by-Turn Navigation & Highway-Exit Engine (turnByTurn.lua) + hudapps.lua nav serialization.
local T = dofile((arg[0]:match('^(.*)[/\\]') or '.') .. '/testlib.lua')
local N = require('beamngEarth/turnByTurn')
local H = require('beamngEarth/hudapps')
local G = require('beamngEarth/gps')

N._resetForTest()

------------------------------------------------------------------------------------------
-- 1. Signed turn angle & standard maneuver classification
------------------------------------------------------------------------------------------
do
  -- ENU: North (0,1) -> East (1,0) is right (+90 deg)
  local degR = N.signedTurnDeg(0, 1, 1, 0)
  T.check(math.abs(degR - 90) < 0.01, 'North->East is +90 deg right turn')
  local degL = N.signedTurnDeg(0, 1, -1, 0)
  T.check(math.abs(degL + 90) < 0.01, 'North->West is -90 deg left turn')

  T.check(N.classifyTurnAngle(90) == 'turn_right', '90 deg -> turn_right')
  T.check(N.classifyTurnAngle(-90) == 'turn_left', '-90 deg -> turn_left')
  T.check(N.classifyTurnAngle(30) == 'slight_right', '30 deg -> slight_right')
  T.check(N.classifyTurnAngle(-30) == 'slight_left', '-30 deg -> slight_left')
  T.check(N.classifyTurnAngle(130) == 'sharp_right', '130 deg -> sharp_right')
  T.check(N.classifyTurnAngle(-130) == 'sharp_left', '-130 deg -> sharp_left')
  T.check(N.classifyTurnAngle(172) == 'uturn', '172 deg -> uturn')
  T.check(N.classifyTurnAngle(-165) == 'uturn', '-165 deg -> uturn')
  T.check(N.classifyTurnAngle(15) == 'straight', '15 deg (< 22) -> straight')
end

------------------------------------------------------------------------------------------
-- 2. Street / ref formatting & polyline maneuver detection (turns + uturn + arrive)
------------------------------------------------------------------------------------------
do
  T.check(N.formatStreetName('Hauptstraße', '', '') == 'Hauptstraße', 'plain street name')
  T.check(N.formatStreetName('Sindelsdorf', 'B 472', '') == 'B 472 · Sindelsdorf', 'ref + name combined')
  T.check(N.formatStreetName('', 'A 95', 'München') == 'A 95 · München', 'ref + destinations combined')

  -- Route: North -> Right (East) -> Slight Left (NE) -> Sharp Left (NW) -> U-turn (SE) -> Arrive
  local pts = {
    { 0, 0 },
    { 0, 100 },            -- turn_right (+90) onto Hauptstraße
    { 100, 100 },          -- slight_left (-30) onto Ringstraße
    { 186.6, 150 },        -- turn_left (-90) onto Bahnhofstraße
    { 136.6, 236.6 },      -- uturn (~175) back SE
    { 186.6, 150 },
  }
  local roads = {
    { x1 = 0, y1 = 0, x2 = 0, y2 = 100, name = 'Startweg', highway = 'residential' },
    { x1 = 0, y1 = 100, x2 = 100, y2 = 100, name = 'Hauptstraße', highway = 'secondary' },
    { x1 = 100, y1 = 100, x2 = 186.6, y2 = 150, name = 'Ringstraße', highway = 'secondary' },
    { x1 = 186.6, y1 = 150, x2 = 136.6, y2 = 236.6, name = 'Bahnhofstraße', highway = 'tertiary' },
    { x1 = 136.6, y1 = 236.6, x2 = 186.6, y2 = 150, name = 'Bahnhofstraße', highway = 'tertiary' },
  }
  local mans = N.extractManeuvers(pts, roads, { destName = 'Central Station' })
  T.check(#mans == 5, 'expected 4 turns + 1 arrive, got ' .. tostring(#mans))
  T.check(mans[1].type == 'turn_right' and mans[1].streetName == 'Hauptstraße', 'first maneuver: turn_right onto Hauptstraße')
  T.check(mans[2].type == 'slight_left' and mans[2].streetName == 'Ringstraße', 'second maneuver: slight_left onto Ringstraße')
  T.check(mans[3].type == 'turn_left' and mans[3].streetName == 'Bahnhofstraße', 'third maneuver: turn_left onto Bahnhofstraße')
  T.check(mans[4].type == 'uturn', 'fourth maneuver: uturn')
  T.check(mans[5].type == 'arrive' and mans[5].streetName == 'Central Station', 'final maneuver: arrive at Central Station')
end

------------------------------------------------------------------------------------------
-- 3. Motorway exit detection (motorway -> motorway_link -> exit_right) + 1500m scaling
------------------------------------------------------------------------------------------
do
  local pts = {
    { 0, 0 },
    { 0, 1800 },       -- motorway A 95 heading North
    { 80, 2000 },      -- gentle 21.8 deg off-ramp (motorway_link) to the right
    { 260, 2050 },     -- onto B 472 Sindelsdorf
  }
  local roads = {
    { x1 = 0, y1 = 0, x2 = 0, y2 = 1800, ref = 'A 95', highway = 'motorway', oneway = true },
    { x1 = 0, y1 = 1800, x2 = 80, y2 = 2000, highway = 'motorway_link', oneway = true },
    { x1 = 80, y1 = 2000, x2 = 260, y2 = 2050, ref = 'B 472', name = 'Sindelsdorf', highway = 'primary' },
  }
  local mans, _, _, cum = N.extractManeuvers(pts, roads, { destName = 'Sindelsdorf' })
  T.check(#mans >= 2, 'motorway exit route produces exit + arrive')
  T.check(mans[1].type == 'exit_right' and mans[1].isHighwayExit == true, 'motorway -> motorway_link classified as exit_right')
  T.check(mans[1].streetName == 'B 472 · Sindelsdorf', 'unnamed link resolves target road B 472 · Sindelsdorf, got: ' .. tostring(mans[1].streetName))

  -- Approach scaling: 1500 m on motorway / high-speed >= 100 km/h vs 350 m urban
  T.check(N.approachWindow(130 / 3.6, 'motorway', 'exit_right') == 1500, '1500 m approach window on Autobahn')
  T.check(N.approachWindow(110 / 3.6, 'primary', 'turn_right') == 1500, '1500 m approach window at >= 100 km/h')
  T.check(N.approachWindow(50 / 3.6, 'residential', 'turn_right') == 350, '350 m approach window on urban street')

  -- Evaluate progress & chime thresholds along Autobahn exit
  local fired = {}
  local evFar = N.evaluateProgress(mans, 1050, cum[#cum], 140 / 3.6, 'motorway', nil, nil, fired)
  T.check(evFar.maneuver == 'exit_right' and evFar.distToTurnM == 750, '750 m to exit_right')
  T.check(math.abs(evFar.approachProgress - 0.5) < 0.01, '750 m / 1500 m -> 0.50 approach progress')
  T.check(evFar.chimeKind == 'exit_far', 'chime fires exit_far within 1000 m')

  local evFarRepeat = N.evaluateProgress(mans, 1100, cum[#cum], 140 / 3.6, 'motorway', nil, nil, fired)
  T.check(evFarRepeat.chimeKind == nil, 'exit_far chime does not refire')

  local evNear = N.evaluateProgress(mans, 1600, cum[#cum], 120 / 3.6, 'motorway', nil, nil, fired)
  T.check(evNear.distToTurnM == 200 and evNear.chimeKind == 'exit_near', 'chime fires exit_near within 250 m')
  T.check(evNear.nextManeuver ~= nil, 'next-after-next preview populated')
end

------------------------------------------------------------------------------------------
-- 4. Curve micro-kink suppression (< 22 deg on same street)
------------------------------------------------------------------------------------------
do
  -- Gentle winding rural road: 10 deg right, 12 deg left, 14 deg right on same street
  local pts = {
    { 0, 0 },
    { 0, 60 },
    { 10.4, 119.1 },     -- ~10 deg right
    { 8.3, 179.0 },      -- ~12 deg left
    { 20.8, 237.7 },     -- ~14 deg right
  }
  local roads = {
    { points = pts, name = 'Landstraße 12', highway = 'secondary' },
  }
  local mans = N.extractManeuvers(pts, roads, { destName = 'Dorfplatz' })
  T.check(#mans == 1 and mans[1].type == 'arrive', 'gentle curves < 22 deg on same street produce zero false turns, got ' .. tostring(#mans))
end

------------------------------------------------------------------------------------------
-- 5. OSRM route.steps extraction (exit, roundabout, turn, arrive)
------------------------------------------------------------------------------------------
do
  local steps = {
    { type = 'depart', name = 'A 95', offset = 0, distance = 1200 },
    { type = 'off ramp', modifier = 'slight right', ref = 'B 472', destinations = 'Sindelsdorf', offset = 1200, distance = 300 },
    { type = 'roundabout', exit = 2, name = 'Hauptstraße', offset = 1500, distance = 250 },
    { type = 'turn', modifier = 'left', name = 'Marktplatz', offset = 1750, distance = 120 },
    { type = 'arrive', name = 'Marktplatz', offset = 1870, distance = 0 },
  }
  local mans = N.extractFromSteps(steps, 'Rathaus')
  T.check(#mans == 4, 'OSRM steps -> 4 maneuvers (depart filtered), got ' .. tostring(#mans))
  T.check(mans[1].type == 'exit_right' and mans[1].isHighwayExit == true and mans[1].streetName == 'B 472 · Sindelsdorf', 'OSRM off ramp -> exit_right')
  T.check(mans[2].type == 'roundabout' and mans[2].exitNum == 2 and mans[2].streetName == 'Hauptstraße', 'OSRM roundabout with exitNum=2')
  T.check(mans[3].type == 'turn_left' and mans[3].streetName == 'Marktplatz', 'OSRM turn left')
  T.check(mans[4].type == 'arrive' and mans[4].streetName == 'Rathaus', 'OSRM arrive uses destName')
end

------------------------------------------------------------------------------------------
-- 6. Multi-design cycling, persistence, hideWorldMarkers & hudapps.lua serialization
------------------------------------------------------------------------------------------
do
  N._resetForTest()
  local saved = nil
  jsonWriteFile = function(path, tbl) saved = { path = path, tbl = tbl }; return true end
  jsonReadFile = function() return saved and saved.tbl or nil end

  T.check(N.uiState().navDesign == 'gmaps_card', 'default design is gmaps_card')
  local d2, idx2 = N.cycleDesign()
  T.check(d2 == 'round_minimap' and idx2 == 2, 'cycle 1 -> round_minimap')
  local d3, idx3 = N.cycleDesign()
  T.check(d3 == 'ets_advisor' and idx3 == 3, 'cycle 2 -> ets_advisor')
  local d1, idx1 = N.cycleDesign()
  T.check(d1 == 'gmaps_card' and idx1 == 1, 'cycle 3 wraps -> gmaps_card')

  local _, badOk = N.setDesign('invalid_style')
  T.check(badOk == false and N.uiState().navDesign == 'gmaps_card', 'invalid design rejected')
  local _, goodOk = N.setDesign('ets_advisor')
  T.check(goodOk == true and saved and saved.tbl.navDesign == 'ets_advisor', 'setDesign persisted')

  N.setChimeEnabled(false)
  N.setUnits('imperial')
  N.setHideWorldMarkers(true)
  T.check(G.worldArrowsEnabled() == false, 'hideWorldMarkers disables gps 3D world arrows')

  -- Reload from saved prefs into fresh state
  N._resetForTest()
  T.check(N.loadPrefs() == true, 'loadPrefs succeeds')
  local st = N.uiState()
  T.check(st.navDesign == 'ets_advisor' and st.chimeEnabled == false and st.units == 'imperial' and st.hideWorldMarkers == true,
    'prefs round-trip preserved')
  N.setHideWorldMarkers(false)
  T.check(G.worldArrowsEnabled() == true, 'disabling hideWorldMarkers restores gps 3D world arrows')

  -- hudapps.lua nav mounting & payload serialization + change detection
  local sent = {}
  guihooks = { trigger = function(name, p) sent[#sent + 1] = { name = name, p = p } end }
  H._reset()
  T.check(H.setMounted('nav', true) and H.mounted('nav'), 'hudapps mounts nav')
  local step = 0
  local function getHud()
    step = step + 1
    return {
      status = '', credits = '', banner = { text = '', level = 'info', visible = false },
      nav = {
        enabled = true, active = true, navDesign = step == 1 and 'gmaps_card' or 'ets_advisor',
        maneuver = 'exit_right', streetName = 'B 472 · Sindelsdorf', isHighwayExit = true,
        distToTurnM = step == 1 and 900 or 450, approachProgress = step == 1 and 0.4 or 0.7,
        remainingM = 4200, etaSec = 240, chimeEnabled = true, chimeSeq = step,
      },
    }
  end
  T.check(H.update(1.0, getHud) and #sent == 1 and sent[1].p.nav.maneuver == 'exit_right' and sent[1].p.nav.navDesign == 'gmaps_card',
    'hudapps forwards nav payload')
  T.check(H.update(1.4, getHud) and #sent == 2 and sent[2].p.nav.navDesign == 'ets_advisor' and sent[2].p.nav.distToTurnM == 450,
    'hudapps re-emits when navDesign or distToTurnM changes')
  H.setMounted('nav', false)
  jsonWriteFile, jsonReadFile = nil, nil
end

------------------------------------------------------------------------------------------
-- 7. Always-visible idle state, true forward-vector heading (no reverse flip) & 60 Hz pose
------------------------------------------------------------------------------------------
do
  N._resetForTest()
  -- Idle payload is always enabled with cruise telemetry even when active == false
  local idle = N.hudPayload()
  T.check(idle.enabled == true and idle.active == false, 'always-visible idle state: enabled=true, active=false')
  T.check(idle.playerX == 0 and idle.playerY == 0 and idle.headingRad == 0 and idle.roadsSeq == 0,
    'idle payload exposes playerX, playerY, headingRad, roadsSeq')

  -- Vehicle facing North (0, 1) while reversing South (vx=0, vy=-12) MUST keep heading 0 deg (North)
  local revVeh = { getDirectionVector = function() return { x = 0, y = 1, z = 0 } end }
  local rRad, rDeg = N.computeHeading(revVeh, { vx = 0, vy = -12, speed = 12 }, math.rad(180))
  T.check(rDeg == 0 and math.abs(rRad) < 1e-4, 'reversing car keeps true chassis forward heading (0 deg, not 180)')

  -- Vehicle facing East (1, 0) at 0 km/h produces 90 deg
  local idleVeh = { getDirectionVector = function() return { x = 1, y = 0, z = 0 } end }
  local eRad, eDeg = N.computeHeading(idleVeh, { vx = 0, vy = 0, speed = 0 }, 0)
  T.check(eDeg == 90 and math.abs(eRad - math.pi * 0.5) < 1e-4, 'idle car facing East produces 90 deg')

  -- Missing direction vector retains previous heading instead of flipping to reverse velocity
  local keepRad, keepDeg = N.computeHeading(nil, { vx = 0, vy = -8, speed = 8 }, math.rad(45))
  T.check(keepDeg == 45 and math.abs(keepRad - math.rad(45)) < 1e-4, 'no forward vector retains previous heading, never velocity')

  -- 60-Hz pose hook (BeamNGEarthNavPose) emission, camera-pan heading vs vehicle heading & throttling
  local poses = {}
  guihooks = { trigger = function(name, p) if name == 'BeamNGEarthNavPose' then poses[#poses + 1] = p end end }
  getPlayerVehicle = function() return revVeh end
  -- Camera panned East (1, 0 -> +pi/2) while car faces North (0, 1 -> 0)
  core_camera = { getForwardXYZ = function() return 1, 0, 0 end }
  T.check(math.abs(N.computeCameraHeading(core_camera, 0) - math.pi * 0.5) < 1e-4, 'computeCameraHeading reads core_camera.getForwardXYZ()')
  T.check(N.onFrame({ x = 100.5, y = 200.25, vx = 0, vy = -10, speed = 10 }, 1.000) == true, 'onFrame emits first 60 Hz pose')
  T.check(#poses == 1 and poses[1].x == 100.5 and poses[1].y == 200.25 and poses[1].headingDeg == 0 and poses[1].speedKph == 36,
    'BeamNGEarthNavPose carries exact x, y, true forward headingDeg=0, speedKph=36')
  T.check(math.abs(poses[1].vehHeadingRad) < 1e-4 and math.abs(poses[1].camHeadingRad - math.pi * 0.5) < 1e-4,
    'BeamNGEarthNavPose separates vehHeadingRad (0) from panned camHeadingRad (pi/2)')
  T.check(N.onFrame({ x = 101, y = 200, vx = 0, vy = -10, speed = 10 }, 1.005) == false and #poses == 1,
    'onFrame throttles within 1/60 s')
  -- When northUp is enabled, camHeadingRad locks to 0 while vehHeadingRad stays true
  N.setNorthUp(true)
  T.check(N.onFrame({ x = 101, y = 199, vx = 0, vy = -10, speed = 10 }, 1.020) == true and #poses == 2,
    'onFrame emits again after 1/60 s')
  T.check(poses[2].camHeadingRad == 0 and math.abs(poses[2].vehHeadingRad) < 1e-4,
    'northUp locks camHeadingRad to 0 while preserving vehHeadingRad')
  N.setNorthUp(false)
  -- Fallback when core_camera is absent: camHeadingRad falls back to vehHeadingRad
  core_camera = nil
  getPlayerVehicle = function() return idleVeh end
  T.check(N.onFrame({ x = 102, y = 199, vx = 0, vy = 0, speed = 0 }, 1.040) == true and #poses == 3,
    'onFrame emits fallback pose without core_camera')
  T.check(math.abs(poses[3].vehHeadingRad - math.pi * 0.5) < 1e-4 and math.abs(poses[3].camHeadingRad - math.pi * 0.5) < 1e-4,
    'without core_camera, camHeadingRad falls back to vehHeadingRad')
  getPlayerVehicle = nil

  -- hudapps.lua re-emits when currentPlace or roadsSeq updates
  local sent = {}
  guihooks = { trigger = function(name, p) sent[#sent + 1] = { name = name, p = p } end }
  H._reset()
  H.setMounted('nav', true)
  local seq = 0
  local function getIdle()
    seq = seq + 1
    return {
      status = '', credits = '', banner = { text = '', level = 'info', visible = false },
      nav = {
        enabled = true, active = false, navDesign = 'round_minimap',
        currentStreet = 'Hauptstraße', currentPlace = seq == 1 and 'Sindelsdorf' or 'Penzberg',
        roadsSeq = seq, playerX = 100, playerY = 200, headingRad = 0,
      },
    }
  end
  T.check(H.update(1.0, getIdle) and #sent == 1 and sent[1].p.nav.currentPlace == 'Sindelsdorf' and sent[1].p.nav.roadsSeq == 1,
    'hudapps forwards idle cruise currentPlace and roadsSeq')
  T.check(H.update(1.4, getIdle) and #sent == 2 and sent[2].p.nav.currentPlace == 'Penzberg' and sent[2].p.nav.roadsSeq == 2,
    'hudapps re-emits when currentPlace or roadsSeq changes')
  H.setMounted('nav', false)
end

T.done('test_turn_by_turn')
