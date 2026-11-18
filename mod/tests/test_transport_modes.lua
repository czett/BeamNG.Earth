-- luajit mod/tests/test_transport_modes.lua  (Transport Modes extension: dwell, bridge guard, rebase, scoring, GPS sync)
local dir = (arg[0]:match('^(.*)[/\\]') or '.')
local T = dofile(dir .. '/testlib.lua')
dofile(dir .. '/stubs.lua')

local gpsCalls = { set = {}, cleared = 0 }
local fakeGpsStatus = nil
local fakeGps = {
  setDestination = function(lat, lon, label)
    gpsCalls.set[#gpsCalls.set + 1] = { lat = lat, lon = lon, label = label }
    fakeGpsStatus = { lat = lat, lon = lon, remaining = 420, eta = 35 }
    return true
  end,
  clear = function()
    gpsCalls.cleared = gpsCalls.cleared + 1
    fakeGpsStatus = nil
  end,
  status = function() return fakeGpsStatus end,
  metric = function() return true end,
}

local sentReqs = {}
local fakeCore = {
  _state = function()
    return {
      inOurLevel = true,
      active = true,
      player = { lat = 39.285, lon = -76.610, x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0 },
    }
  end,
  requestTransportJob = function(id, mode, tier, lat, lon, heading, seed)
    sentReqs[#sentReqs + 1] = { id = id, mode = mode, tier = tier, lat = lat, lon = lon, heading = heading, seed = seed }
    return true
  end,
}

local tm = require('beamngEarth/transportModes')
local fakeNow = 100.0
local fakeRayZ = 10.0
local rayCalls = 0
local fakeDamage = 0
tm.core = function() return fakeCore end
tm.gps = function() return fakeGps end
tm.now = function() return fakeNow end
tm.say = function() end
tm.castRay = function(x, y, zTop, maxDist) rayCalls = rayCalls + 1; return fakeRayZ end
tm.readDamage = function() return fakeDamage end

-- 1. Pure request validation
T.check(tm.validateRequest('taxi', 'neighborhood'), 'valid taxi tier')
T.check(tm.validateRequest('BUS', 'FULL'), 'case-insensitive bus tier')
T.check(tm.validateRequest('logistics', 'long'), 'valid logistics tier')
T.check(not tm.validateRequest('plane', 'city'), 'unknown mode rejected')
T.check(not tm.validateRequest('taxi', 'long'), 'wrong tier rejected')

-- 2. Pure stop dwell & bridge height guard
do
  local st, dw = tm.stepStop(0, 25, 0, 0.2, 12, 0.5, false)
  T.check(st == 'approaching' and dw == 0, 'outside zone: approaching')

  st, dw = tm.stepStop(1.0, 5, 0, 3.0, 12, 0.5, false)
  T.check(st == 'approaching' and dw == 0, 'too fast in zone: dwell resets')

  st, dw = tm.stepStop(1.0, 5, 18.0, 0.1, 12, 0.5, false)
  T.check(st == 'approaching' and dw == 0, 'bridge/overpass |dz| > 10 m: ignored')

  st, dw = tm.stepStop(1.0, 5, -2.0, 0.5, 12, 0.5, true)
  T.check(st == 'dwelling' and dw == 1.0, 'paused: holds dwell without advancing')

  st, dw = tm.stepStop(2.6, 4, 1.0, 0.2, 12, 0.5, false)
  T.check(st == 'complete' and dw == tm.DWELL_S, '2.5 s inside zone at low speed: complete')
end

-- 2b. Rectangular bay projection & guaranteed completable fail-safe (primary 2.5 s vs 15 m fallback 5.0 s)
do
  local specTaxi = tm.baySpec('taxi', 'neighborhood')
  local specBus = tm.baySpec('bus', 'full')
  T.check(specTaxi.width == 3.4 and specTaxi.length == 8.5, 'taxi bay is 3.4 x 8.5 m')
  T.check(specBus.width == 3.8 and specBus.length == 14.0, 'bus bay is 3.8 x 14.0 m')

  local fx, fy, rx, ry = tm.bayFrame(0, 1, 90)
  local longOff, latOff = tm.bayOffsets(4, -2, 0, 0, fx, fy, rx, ry)
  T.check(math.abs(longOff - 4) < 1e-6 and math.abs(latOff - 2) < 1e-6, 'bayOffsets projects along east-facing bay')

  -- Inside primary bay tolerances (<= 3.5 m lat, <= 5.0 m long), speed < 1.5 m/s -> 2.5 s completes
  local st, dw, dm = tm.stepBayStop(2.1, 'bay', 3.2, 3.0, 1.0, 0.0, 1.1, specTaxi, 0.5, false)
  T.check(st == 'complete' and dw == tm.BAY_DWELL_S and dm == 'bay', 'primary bay 2.5 s dwell completes')

  -- Outside tight bay (> 5.0 m long) but within 15 m fallback radius: speed 1.0 m/s (> 0.8) does not dwell fallback
  st, dw, dm = tm.stepBayStop(0, 'none', 11.0, 10.0, 4.5, 0.0, 1.0, specTaxi, 0.5, false)
  T.check(st == 'approaching' and dw == 0 and dm == 'none', 'fallback requires speed < 0.8 m/s')

  -- Within 15 m fallback radius and speed < 0.8 m/s -> 5.0 s completes as fallback_complete
  st, dw, dm = tm.stepBayStop(4.6, 'fallback', 11.0, 10.0, 4.5, 0.0, 0.5, specTaxi, 0.5, false)
  T.check(st == 'fallback_complete' and dw == tm.FALLBACK_DWELL_S and dm == 'fallback', 'fallback 5.0 s dwell completes within 15 m')

  -- Bridge guard blocks fallback too
  st, dw, dm = tm.stepBayStop(2.0, 'fallback', 8.0, 7.0, 3.0, 15.0, 0.2, specTaxi, 0.5, false)
  T.check(st == 'approaching' and dw == 0, 'bridge |dz| > 10 m blocks fallback dwell')
end

-- 3. Pure score computation
do
  local s1, sm1 = tm.computeScore({ elapsedS = 120, harshS = 0, collisions = 0, damageDelta = 0 })
  T.check(s1 == 100 and sm1 == 100, 'clean drive scores 100')
  local s2, sm2 = tm.computeScore({ elapsedS = 60, harshS = 20, collisions = 2, damageDelta = 1200 })
  T.check(s2 < s1 and sm2 < sm1 and s2 >= 0, 'harsh drive + collisions penalized cleanly')
end

-- 4. Zero overhead when idle
do
  local anchor = { geodeticToEnu = function(_, lat, lon) return 0, 0 end }
  local player = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0 }
  tm.update(0.016, 0.016, anchor, player, false, false)
  tm.drawMarker(anchor, player)
  tm.drawUi(false)
  T.check(rayCalls == 0 and #gpsCalls.set == 0 and tm.hudPayload() == nil, 'idle: zero work and nil hudPayload')
end

-- 5. Full job lifecycle: start -> job result -> dwell stop 1 -> rebase -> skip/complete -> summary -> dismiss
do
  local startRes = tm.startJob('taxi', 'neighborhood')
  T.check(startRes.ok and #sentReqs == 1 and tm.isActive(), 'startJob sends request and marks pending')
  T.check(tm.hudPayload().state == 'pending', 'pending hudPayload')

  tm.onJobResult({
    id = sentReqs[1].id,
    ok = true,
    mode = 'taxi',
    tier = 'neighborhood',
    title = 'Central Cafe -> Harbor St',
    estimatedKm = 2.1,
    stops = {
      { index = 1, kind = 'pickup', name = 'Central Cafe', address = 'Pratt St', lat = 39.286, lon = -76.610, zoneRadius = 12 },
      { index = 2, kind = 'dropoff', name = 'Harbor St', address = 'Pier 4', lat = 39.295, lon = -76.605, zoneRadius = 12 },
    },
  })

  T.check(#gpsCalls.set == 1 and gpsCalls.set[1].lat == 39.286, 'stop 1 synced to GPS')
  local p = tm.hudPayload()
  T.check(p.state == 'active' and p.stopIndex == 1 and p.stopCount == 2 and p.stopName == 'Central Cafe', 'active hudPayload')

  local stopPos = { [39.286] = { 0, 0 }, [39.295] = { 0, 950 } }
  local anchor = {
    geodeticToEnu = function(_, lat, lon)
      local c = stopPos[lat] or { 0, 0 }
      return c[1], c[2]
    end,
  }
  local pl = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0.2 }

  -- Bridge guard: player at z=28 (18 m above ground rayZ=10) must not dwell
  pl.z = 28
  tm.update(0.5, 0.5, anchor, pl, false, false)
  T.check(tm.hudPayload().dwellFrac == 0, 'bridge height difference blocks dwell')

  -- Ground level: dwell 2.5 s completes stop 1 and routes GPS to stop 2
  pl.z = 10
  for _ = 1, 5 do
    fakeNow = fakeNow + 0.5
    tm.update(0.5, 0.5, anchor, pl, false, false)
  end
  T.check(#gpsCalls.set == 2 and gpsCalls.set[2].lat == 39.295, 'completing stop 1 advances GPS to stop 2')
  T.check(tm.hudPayload().stopIndex == 2, 'active stopIndex is 2')

  -- Rebase resets frame-local tracking so anchor shift does not add phantom driven distance
  tm.onRebased()
  pl.x, pl.y = 5000, -5000
  fakeNow = fakeNow + 0.5
  tm.update(0.5, 0.5, anchor, pl, false, false)
  T.check(tm.uiState().active.drivenM < 100, 'onRebased ignores anchor coordinate jump')

  -- Fallback completion inside 15 m outside primary bay (5.0 s at < 0.8 m/s) finishes job
  pl.x, pl.y = 11, 950
  for _ = 1, 10 do
    fakeNow = fakeNow + 0.5
    tm.update(0.5, 0.5, anchor, pl, false, false)
  end
  local sum = tm.hudPayload()
  T.check(sum.state == 'summary' and sum.stopsCompleted == 2 and sum.fallbackCount == 1, 'fallback completion finishes job and records fallbackCount')
  T.check(gpsCalls.cleared == 1 and not tm.isActive(), 'job completion clears owned GPS and returns inactive')

  tm.dismissSummary()
  T.check(tm.hudPayload() == nil, 'dismissSummary clears summary')
end

-- 6. Skip stop + cancel job clears state and owned GPS
do
  local res = tm.startJob('logistics', 'local')
  T.check(res.ok, 'logistics job started')
  tm.onJobResult({
    id = sentReqs[#sentReqs].id,
    ok = true,
    mode = 'logistics',
    tier = 'local',
    stops = {
      { index = 1, kind = 'loading', stopType = 'loading_bay', name = 'Dock A', lat = 39.286, lon = -76.610 },
      { index = 2, kind = 'delivery', stopType = 'kerbside', name = 'Shop B', lat = 39.289, lon = -76.610 },
    },
  })
  T.check(tm.hudPayload().stopType == 'loading_bay', 'stopType exposed in hudPayload')
  tm.skipStop()
  T.check(tm.hudPayload().stopType == 'kerbside', 'skipStop advances to stop 2 kerbside')
  local cRes = tm.cancelJob()
  T.check(cRes.ok and not tm.isActive() and tm.hudPayload() == nil and gpsCalls.cleared == 2, 'cancelJob clears active job & GPS')
end

-- 7. Phase 2: Taxi score stability (debounced collisions, NaN guards) + fare/tip + dynamic dwell
do
  local sNan = tm.computeScore({ mode = 'taxi', elapsedS = 0/0, harshS = 0/0, collisions = 0, damageDelta = 0 })
  T.check(sNan == 100, 'NaN inputs do not collapse Taxi score to 0')

  local meter0 = tm.computeTaxiFare({ passengerOnBoard = false, fareDrivenM = 0 })
  T.check(meter0 == 0, 'Taxi meter is 0 before pickup')
  local meter1, tip1, tot1, time1 = tm.computeTaxiFare({
    passengerOnBoard = true, fareDrivenM = 2500, fareElapsedS = 180, targetLegS = 200, _scoreHint = 92,
  })
  T.check(meter1 > 7.5 and tip1 > 0 and tot1 > meter1 and time1 == 100, 'Taxi fare, tip, and timeliness computed cleanly')

  -- Dynamic dwell target on stepBayStop
  local stD, dwD, dmD, tgtD = tm.stepBayStop(7.6, 'bay', 2.0, 1.0, 0.5, 0.0, 0.2, tm.baySpec('logistics', 'city'), 0.5, false, 8.0)
  T.check(stD == 'complete' and dwD == 8.0 and dmD == 'bay' and tgtD == 8.0, 'stepBayStop honors 8.0 s dynamic dwellTargetS')
  T.check(tm.dwellStatusLabel('taxi', 'pickup', 'bay') == 'Passenger boarding', 'taxi pickup dwell label')
  T.check(tm.dwellStatusLabel('logistics', 'delivery', 'fallback') == 'Kerbside · Unloading cargo', 'logistics fallback dwell label')

  -- Collision debounce: rapid multi-frame damage spikes within 1.25 s count as 1 collision, not 5
  fakeDamage = 0
  local rT = tm.startJob('taxi', 'neighborhood')
  T.check(rT.ok, 'taxi job started for collision debounce test')
  tm.onJobResult({
    id = sentReqs[#sentReqs].id,
    ok = true,
    mode = 'taxi',
    tier = 'neighborhood',
    estimatedKm = 2.0,
    stops = {
      { index = 1, kind = 'pickup', name = 'Cafe', lat = 39.286, lon = -76.610, dwellTargetS = 2.0 },
      { index = 2, kind = 'dropoff', name = 'Station', lat = 39.295, lon = -76.605, dwellTargetS = 3.0 },
    },
  })
  local anchor = { geodeticToEnu = function() return 0, 500 end }
  local pl = { x = 0, y = 0, z = 10, vx = 5, vy = 0, vz = 0, speed = 5 }
  for k = 1, 5 do
    fakeDamage = fakeDamage + 80
    fakeNow = fakeNow + 0.1
    tm.update(0.1, 0.1, anchor, pl, false, false)
  end
  local pDeb = tm.hudPayload()
  T.check(pDeb.collisions == 1 and pDeb.score > 50, 'multi-frame impact debounced to 1 collision; Taxi score stays > 50')
  tm.cancelJob()
end

-- 8. Phase 2: Vehicle classification, cargo VE script, trailer selection & cleanup invariants
do
  T.check(tm.classifyVehicle({ jbeam = 'vivace', massKg = 1350 }).class == 'car', 'vivace classified as car')
  T.check(tm.classifyVehicle({ jbeam = 'van', massKg = 2600, coupler = 'towhitch' }).class == 'van', 'van classified as van')
  T.check(tm.classifyVehicle({ jbeam = 'md_series', massKg = 5400 }).class == 'box_truck', 'md_series classified as box_truck')
  T.check(tm.classifyVehicle({ jbeam = 'us_semi', coupler = 'fifthwheel', massKg = 8200 }).class == 'semi', 'us_semi classified as semi')

  T.check(tm.pickTrailerModel('fifthwheel', 'steel', 'long', function() return true end) == 'flatbed', 'fifthwheel steel picks flatbed')
  T.check(tm.pickTrailerModel('fifthwheel', 'dry_goods', 'long', function() return true end) == 'dryvan', 'fifthwheel dry_goods picks dryvan')
  T.check(tm.pickTrailerModel('towhitch', 'groceries', 'local', function() return true end) == 'boxutility', 'towhitch local picks boxutility')

  local cands = tm.trailerSpawnCandidates(0, 0, 10, 0, 1, 3.0, 6.0)
  T.check(#cands >= 5 and cands[1].y < -9.0, 'trailer spawn candidates placed safely behind player')

  local veLoad = tm.buildCargoVeScript(4500)
  local veReset = tm.buildCargoVeScript(0)
  T.check(veLoad:find('bngeCargoBase') ~= nil and veLoad:find('setNodeMass') ~= nil, 'cargo VE script caches baseline and sets node mass')
  T.check(veReset:find('local targetKg = 0.000') ~= nil, 'cargo VE reset script restores 0 kg')

  -- Player-owned trailer is never deleted on cancel, while job-owned trailer is deleted
  local deleted = {}
  local oldScenetree, oldCv, oldBe = scenetree, core_vehicles, be
  local playerVehObj = {
    id = 701, JBeam = 'us_semi',
    getID = function(self) return self.id end,
    getJBeamFilename = function(self) return self.JBeam end,
    getPosition = function() return vec3(0, 0, 10) end,
    getDirectionVector = function() return vec3(0, 1, 0) end,
    queueLuaCommand = function(_, cmd)
      if type(cmd) == 'string' and cmd:find('_onVehicleProbe') then
        tm._onVehicleProbe(701, { massKg = 8200, coupler = 'fifthwheel', couplerCid = 10, attached = false })
      end
    end,
  }
  local spawnedTrl = {
    id = 801,
    getID = function(self) return self.id end,
    queueLuaCommand = function() end,
    delete = function(self) deleted[#deleted + 1] = self.id end,
  }
  local origPlayerVeh = tm.playerVeh
  tm.playerVeh = function() return playerVehObj end
  scenetree = { findObjectById = function(id) return id == 801 and spawnedTrl or (id == 701 and playerVehObj or nil) end }
  core_vehicles = { spawnNewVehicle = function() return spawnedTrl end }
  be = { getObjectCount = function() return 0 end }
  local rLog = tm.startJob('logistics', 'long')
  T.check(rLog.ok, 'logistics job started with probed semi')
  -- Flush probe immediately
  tm.update(0.05, 0.05, { geodeticToEnu = function() return 0, 0 end }, { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0 }, false, false)
  tm.onJobResult({
    id = sentReqs[#sentReqs].id,
    ok = true,
    mode = 'logistics',
    tier = 'long',
    vehicleClass = 'semi',
    cargo = { type = 'dry_goods', label = 'Containerized Dry Goods', massKg = 18000, vehicleClass = 'semi' },
    stops = {
      { index = 1, kind = 'loading', stopType = 'loading_bay', name = 'Hub A', lat = 39.286, lon = -76.610, cargoDeltaKg = 18000, dwellTargetS = 10.5 },
      { index = 2, kind = 'delivery', stopType = 'loading_bay', name = 'Hub B', lat = 39.386, lon = -76.610, cargoDeltaKg = -18000, dwellTargetS = 9.7 },
    },
  })
  T.check(tm.hudPayload().cargoKg == 18000 and tm.hudPayload().dwellTargetS == 10.5, 'logistics hudPayload exposes cargoKg and dynamic dwellTargetS')
  tm.cancelJob()
  T.check(#deleted == 1 and deleted[1] == 801, 'cancelJob deletes job-owned spawned trailer')
  tm.playerVeh = origPlayerVeh
  scenetree, core_vehicles, be = oldScenetree, oldCv, oldBe
end

-- 9. Phase 3: Probe timeout, trailer discovery/domain matching, bidirectional bays, crash cap, rural jerk, Taxi/Bus depth
do
  T.check(tm.PROBE_TIMEOUT_S == 0.6, 'coupler probe timeout extended to 0.6 s')
  T.check(tm.PROBE_VE:find('v%.config%.parts') ~= nil, 'PROBE_VE inspects v.config.parts slot names')

  local disc = tm.discoverTrailerModels(
    function(m) return m == 'tanker' or m == 'reefer' or m == 'flatbed' or m == 'boxutility' or m == 'mod_semi' end,
    function() return { models = { mod_semi = { Type = 'Trailer' } } } end
  )
  T.check(#disc.fifthwheel >= 4 and #disc.towhitch >= 1, 'discoverTrailerModels finds base + modded trailers')
  T.check(tm.pickTrailerModel('fifthwheel', 'fuel', 'long', function(m) return m == 'tanker' or m == 'dryvan' end, 'fuel') == 'tanker', 'fuel picks tanker')
  T.check(tm.pickTrailerModel('fifthwheel', 'groceries', 'city', function(m) return m == 'reefer' or m == 'dryvan' end, 'food') == 'reefer', 'food picks reefer')

  local cands = tm.trailerSpawnCandidates(0, 0, 10, 0, 1, 3.0, 6.0)
  T.check(#cands == 8 and cands[1].mode == 'rear' and cands[6].mode == 'front' and cands[7].mode == 'lane', 'trailerSpawnCandidates includes rear, front, and lane fallbacks')

  -- Crash cap at 65 & rural vertical bump tolerance
  local sCrash, smCrash = tm.computeScore({ elapsedS = 180, harshS = 0, collisions = 12, damageDelta = 25000 })
  T.check(sCrash == 35 and smCrash == 100, 'severe multi-crash caps collisionPen at 65 -> score 35')
  local hBump, susp = tm.isHarshSample(1.2, 13.5, 4.0, false, false)
  T.check(not hBump and not susp, 'isolated 13.5 m/s^2 rural bump is not harsh')
  local hVip = tm.isHarshSample(4.6, 0, 2.0, false, true)
  T.check(hVip, 'VIP ride enforces stricter horizontal smoothness threshold')

  -- Taxi archetype bonuses (+40% express fare, +35% vip tip)
  local mExp = tm.computeTaxiFare({ passengerOnBoard = true, fareDrivenM = 3000, fareMult = 1.40, _scoreHint = 90 })
  local mStd, tStd = tm.computeTaxiFare({ passengerOnBoard = true, fareDrivenM = 3000, fareMult = 1.0, tipMult = 1.0, _scoreHint = 90 })
  local _, tVip = tm.computeTaxiFare({ passengerOnBoard = true, fareDrivenM = 3000, fareMult = 1.0, tipMult = 1.35, _scoreHint = 90 })
  T.check(mExp > mStd * 1.35 and tVip > tStd * 1.30, 'Express +40% fare and VIP +35% tip applied')

  -- Bidirectional bay entry & 3x5 terrain-conforming thick quads
  local dFwd, okFwd = tm.bayEntryDir(0, 0, true)
  local dRev, okRev = tm.bayEntryDir(180, 0, true)
  T.check(dFwd == 1 and okFwd and dRev == -1 and okRev, 'bidirectional bay allows 0 deg and 180 deg entry')
  local grid = {
    { 10, 10, 10 }, { 10.2, 10.2, 10.2 }, { 10.5, 10.5, 10.5 }, { 10.8, 10.8, 10.8 }, { 11.0, 11.0, 11.0 }
  }
  T.check(math.abs(tm.sampleBayGridZ(grid, 0.5, 0.5, 0) - 10.5) < 1e-6, 'sampleBayGridZ bilinearly interpolates terrain')
  local quads = tm.buildBayQuads(0, 0, 0, 1, 1, 0, tm.baySpec('bus', 'full'), function() return 10 end, 1, 1.0, {1,1,1,0.7}, {1,1,1,0.9}, {1,1,1,0.8})
  T.check(#quads >= 15, 'buildBayQuads emits stop bar, brackets, pads, side rails, and 3 chevrons')

  -- Bus live passenger load, schedule text, nextStopName & Taxi nextPassenger() chaining
  T.check(tm.formatScheduleDelta(10) == 'On Time' and tm.formatScheduleDelta(70) == '+1m 10s', 'formatScheduleDelta formats On Time and +1m 10s')
  local rBus = tm.startJob('bus', 'partial')
  T.check(rBus.ok, 'bus job started')
  tm.onJobResult({
    id = sentReqs[#sentReqs].id,
    ok = true,
    mode = 'bus',
    tier = 'partial',
    bus = { capacity = 40, paxMassPerPaxKg = 75 },
    stops = {
      { index = 1, kind = 'bus_stop', name = 'Central', lat = 39.286, lon = -76.610, paxBoard = 10, paxAlight = 0, targetArrivalS = 30, dwellTargetS = 2.0 },
      { index = 2, kind = 'bus_stop', name = 'North Gate', lat = 39.290, lon = -76.610, paxBoard = 6, paxAlight = 2, targetArrivalS = 80, dwellTargetS = 2.0 },
      { index = 3, kind = 'bus_stop', name = 'Terminus', lat = 39.295, lon = -76.610, paxBoard = 0, paxAlight = 14, targetArrivalS = 140, dwellTargetS = 2.0 },
    },
  })
  T.check(tm.hudPayload().nextStopName == 'North Gate' and tm.hudPayload().paxCount == 0, 'bus hudPayload exposes nextStopName and initial 0 pax')
  local anchorB = { geodeticToEnu = function(_, lat) return 0, lat == 39.286 and 0 or 500 end }
  local plB = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0.2 }
  for _ = 1, 4 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchorB, plB, false, false) end
  local pB2 = tm.hudPayload()
  T.check(pB2.stopIndex == 2 and pB2.paxCount == 10 and pB2.nextStopName == 'Terminus', 'completing bus stop 1 updates paxCount=10 and nextStopName=Terminus')
  tm.cancelJob()

  -- Taxi nextPassenger() chains directly from summary
  local rTx = tm.startJob('taxi', 'city')
  T.check(rTx.ok, 'taxi city started')
  tm.onJobResult({
    id = sentReqs[#sentReqs].id,
    ok = true,
    mode = 'taxi',
    tier = 'city',
    taxi = { archetype = 'express', label = 'Airport / Station Express', fareMult = 1.4, tipMult = 1.0, targetMult = 0.8, paxCount = 2, paxMassKg = 160 },
    stops = {
      { index = 1, kind = 'pickup', name = 'Hotel', lat = 39.286, lon = -76.610, dwellTargetS = 2.0 },
      { index = 2, kind = 'dropoff', name = 'Airport', lat = 39.320, lon = -76.610, dwellTargetS = 2.0 },
    },
  })
  local anchorT = { geodeticToEnu = function(_, lat) return 0, lat == 39.286 and 0 or 3800 end }
  local plT = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0.2 }
  for _ = 1, 4 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchorT, plT, false, false) end
  T.check(tm.hudPayload().passengerOnBoard and tm.hudPayload().paxCount == 2, 'taxi pickup boards 2 pax')
  plT.y = 3800
  for _ = 1, 4 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchorT, plT, false, false) end
  T.check(tm.hudPayload().state == 'summary', 'taxi dropoff reaches summary')
  local rNext = tm.nextPassenger()
  T.check(rNext.ok and tm.hudPayload().state == 'pending' and sentReqs[#sentReqs].tier == 'city', 'nextPassenger chains into a new city taxi job')
  tm.cancelJob()
end

T.done('test_transport_modes')
