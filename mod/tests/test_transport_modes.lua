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
T.check(tm.validateRequest('taxi', 'short'), 'valid taxi short tier')
T.check(tm.validateRequest('taxi', 'neighborhood'), 'legacy taxi neighborhood tier aliases to short')
T.check(tm.validateRequest('taxi', 'long'), 'valid taxi long tier')
T.check(tm.validateRequest('BUS', 'FULL'), 'case-insensitive bus tier')
T.check(tm.validateRequest('logistics', 'long'), 'valid logistics tier')
T.check(not tm.validateRequest('plane', 'city'), 'unknown mode rejected')
T.check(not tm.validateRequest('taxi', 'express'), 'wrong tier rejected')

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
  local specLocal = tm.baySpec('logistics', 'local')
  local specBus = tm.baySpec('bus', 'full')
  local specSemi = tm.baySpec('logistics', 'long')
  T.check(specTaxi.width == 2.7 and specTaxi.length == 6.2 and specTaxi.halfW == 1.35 and specTaxi.halfL == 3.10, 'taxi bay is compact 2.7 x 6.2 m')
  T.check(specLocal.width == 2.7 and specLocal.length == 6.2, 'logistics local bay is compact 2.7 x 6.2 m')
  T.check(specBus.width == 3.2 and specBus.length == 11.5 and specBus.halfW == 1.60 and specBus.halfL == 5.75, 'bus bay is compact 3.2 x 11.5 m')
  T.check(specSemi.width == 3.2 and specSemi.length == 11.5 and specSemi.longTol == 7.75, 'logistics city+ bay is 3.2 x 11.5 m with forgiving 7.75 m longTol')

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
  T.check(tm.dwellStatusLabel('logistics', 'loading', 'bay', nil, 'loaded_trailer', 'staged') == 'Hooking up trailer', 'trailer pickup dwell label')
  T.check(tm.dwellStatusLabel('logistics', 'delivery', 'bay', 'loaded_trailer') == 'Unhooking trailer', 'trailer delivery dwell label')
  T.check(tm.dwellStatusLabel('logistics', 'deadhead', 'bay', 'deadhead') == 'Checking in at depot', 'deadhead arrival dwell label')

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
  local spawnCalls = 0
  core_vehicles = { spawnNewVehicle = function() spawnCalls = spawnCalls + 1; return spawnedTrl end }
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
    legs = {
      { index = 1, fromStop = 1, toStop = 2, legKind = 'loaded_trailer', cargoType = 'dry_goods', cargoLabel = 'Containerized Dry Goods', cargoMassKg = 18000, trailerModel = 'dryvan', trailerLabel = 'Dry Van Trailer' },
    },
    stops = {
      { index = 1, kind = 'loading', stopType = 'loading_bay', name = 'Hub A', lat = 39.286, lon = -76.610, cargoDeltaKg = 18000, dwellTargetS = 10.5 },
      { index = 2, kind = 'delivery', stopType = 'loading_bay', name = 'Hub B', lat = 39.386, lon = -76.610, cargoDeltaKg = -18000, dwellTargetS = 9.7 },
    },
  })
  T.check(spawnCalls == 0, 'Phase 4: no trailer spawned at job start')
  T.check(tm.hudPayload().legKind == 'pickup_approach' and tm.hudPayload().legLabel == 'Pick up Dry Van Trailer (Containerized Dry Goods · 18.0 t)' and tm.hudPayload().cargoKg == nil, 'Phase 5: pickup approach shows trailer + cargo weight without leaking cargoKg')
  -- Approach < 160 m to Hub A -> stages trailer in bay
  local anchorLog = { geodeticToEnu = function(_, lat) return 0, (lat == 39.286) and 120 or 5000 end }
  tm.update(0.1, 0.1, anchorLog, { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0 }, false, false)
  T.check(spawnCalls == 1 and tm.hudPayload().trailerState == 'staged' and tm.hudPayload().legLabel == 'Pick up Dry Van Trailer (Containerized Dry Goods · 18.0 t)', 'Phase 5: staged trailer keeps Pick up <Trailer> (<Cargo> · <Weight>) label')
  tm.cancelJob()
  T.check(#deleted == 1 and deleted[1] == 801, 'cancelJob deletes job-owned staged trailer')
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
  local quads = tm.buildBayQuads(0, 0, 0, 1, 1, 0, tm.baySpec('bus', 'full'), function() return 10 end)
  local cornerBands, edgeBars = 0, 0
  local hasOuter, hasInner, hasTop = false, false, false
  local minZ, maxZ = math.huge, -math.huge
  local bandSeen, edgeSeen, segCoords = {}, {}, {}
  local barWidthOk, barHeightOk, shadeDiffOk = true, true, false
  local minColR, maxColR = math.huge, -math.huge
  for _, q in ipairs(quads) do
    for _, pt in ipairs({ q.p0, q.p1, q.p2, q.p3 }) do
      minZ = math.min(minZ, pt.z)
      maxZ = math.max(maxZ, pt.z)
    end
    minColR = math.min(minColR, q.r)
    maxColR = math.max(maxColR, q.r)
    if q.face == 'outer' then hasOuter = true end
    if q.face == 'inner' then hasInner = true end
    if q.face == 'top' then hasTop = true end
    if q.kind == 'corner_band' then
      cornerBands = cornerBands + 1
      if q.band then bandSeen[q.band] = true end
    elseif q.kind == 'edge_bar' then
      edgeBars = edgeBars + 1
      if q.edge then edgeSeen[q.edge] = true end
      if math.abs((q.widthM or 0) - 0.16) > 1e-5 then barWidthOk = false end
      if math.abs((q.heightM or 0) - 0.14) > 1e-5 then barHeightOk = false end
      if q.edge == 'left' and q.face == 'outer' and q.segmentId then
        segCoords[q.segmentId] = segCoords[q.segmentId] or { minY = math.huge, maxY = -math.huge }
        segCoords[q.segmentId].minY = math.min(segCoords[q.segmentId].minY, q.p0.y, q.p1.y)
        segCoords[q.segmentId].maxY = math.max(segCoords[q.segmentId].maxY, q.p0.y, q.p1.y)
      end
    end
  end
  shadeDiffOk = (maxColR - minColR) > 0.05
  -- Verify disconnected gaps between consecutive left-side bars
  local leftSegs = {}
  for _, sc in pairs(segCoords) do leftSegs[#leftSegs + 1] = sc end
  table.sort(leftSegs, function(a, b) return a.minY < b.minY end)
  local sideGapsOk = #leftSegs >= 3
  for i = 2, #leftSegs do
    if (leftSegs[i].minY - leftSegs[i - 1].maxY) < 0.25 then sideGapsOk = false end
  end
  T.check(cornerBands > 0 and bandSeen[1] and bandSeen[2] and bandSeen[3], '3D stacked corner brackets have 3 separated bands')
  T.check(edgeBars > 0 and edgeSeen.left and edgeSeen.right and edgeSeen.front and edgeSeen.rear and barWidthOk and barHeightOk and sideGapsOk, 'disconnected 0.16 x 0.14 m 3D edge bars span all 4 sides with clear gaps')
  T.check(hasOuter and hasInner and hasTop and math.abs(minZ - 10.10) < 1e-5 and math.abs(maxZ - 10.65) < 1e-5 and shadeDiffOk, '3D enclosure floats 0.10..0.65 m above terrain with inner/outer/top faces and shading')
  local cIdle = tm.bayFrameColor(false, false, 'none', nil, false)
  local cGreen = tm.bayFrameColor(true, false, 'bay', 'attached', false)
  local cAmber = tm.bayFrameColor(true, false, 'none', 'attached', true)
  local cStaged = tm.bayFrameColor(false, false, 'none', 'staged', false)
  T.check(cIdle == tm.BAY_IDLE_GREY and cGreen == tm.BAY_ALIGNED_GREEN and cAmber == tm.BAY_PARTIAL_AMBER and cStaged == tm.BAY_PARTIAL_AMBER, 'bayFrameColor transitions cleanly between cool grey, emerald green, and warm amber')
  T.check(math.abs(tm.BAY_IDLE_GREY[4] - 0.44) < 1e-5 and math.abs(tm.BAY_ALIGNED_GREEN[4] - 0.62) < 1e-5 and math.abs(tm.BAY_PARTIAL_AMBER[4] - 0.55) < 1e-5, 'bay colors use semi-transparent alpha levels')

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

-- 10. Phase 4: Auto-coupling (<= 2.8 m), deadhead cargo reset, > 80 m despawnQueue & player-owned trailer safety
do
  T.check(tm.hitchDistanceM(0, 7.0, 0, 1, 3.0, 0, 0, 0, 1, 6.2, 'fifthwheel') <= 2.8, 'hitchDistanceM detects fifthwheel coupling alignment <= 2.8 m')
  T.check(not tm.shouldDespawnTrailer(50) and tm.shouldDespawnTrailer(85), 'shouldDespawnTrailer triggers only > 80 m')

  local deleted, cmds = {}, {}
  local oldScenetree, oldCv, oldBe, oldTr = scenetree, core_vehicles, be, core_trailerRespawn
  local attachedId = nil
  local playerPos, trlPos = vec3(0, 0, 10), vec3(0, 120, 10)
  local pvObj = {
    id = 901, JBeam = 'us_semi',
    getID = function(self) return self.id end,
    getJBeamFilename = function(self) return self.JBeam end,
    getPosition = function() return playerPos end,
    getDirectionVector = function() return vec3(0, 1, 0) end,
    queueLuaCommand = function(_, cmd)
      cmds[#cmds + 1] = cmd
      if type(cmd) == 'string' and cmd:find('_onVehicleProbe') then
        tm._onVehicleProbe(901, { massKg = 8200, coupler = 'fifthwheel', couplerCid = 10, attached = false })
      end
    end,
  }
  local trlObj = {
    id = 902,
    getID = function(self) return self.id end,
    getPosition = function() return trlPos end,
    getDirectionVector = function() return vec3(0, 1, 0) end,
    queueLuaCommand = function(_, cmd) cmds[#cmds + 1] = cmd end,
    delete = function(self) deleted[#deleted + 1] = self.id end,
  }
  local origPlayerVeh = tm.playerVeh
  tm.playerVeh = function() return pvObj end
  scenetree = { findObjectById = function(id) return id == 902 and trlObj or (id == 901 and pvObj or nil) end }
  core_vehicles = { spawnNewVehicle = function() return trlObj end }
  be = { getObjectCount = function() return 0 end }
  core_trailerRespawn = { getTrailerData = function() return attachedId and { [901] = { trailerId = attachedId } } or {} end }

  tm.startJob('logistics', 'city')
  tm.update(0.05, 0.05, { geodeticToEnu = function() return 0, 0 end }, { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0 }, false, false)
  tm.onJobResult({
    id = sentReqs[#sentReqs].id,
    ok = true, mode = 'logistics', tier = 'city', vehicleClass = 'semi',
    cargo = { type = 'food', label = 'Fresh Produce', massKg = 14200, vehicleClass = 'semi' },
    legs = {
      { index = 1, fromStop = 1, toStop = 2, legKind = 'loaded_trailer', cargoType = 'food', cargoLabel = 'Fresh Produce', cargoMassKg = 14200, trailerModel = 'reefer', trailerLabel = 'Reefer Trailer' },
      { index = 2, fromStop = 2, toStop = 3, legKind = 'deadhead', cargoType = '', cargoLabel = '', cargoMassKg = 0 },
      { index = 3, fromStop = 3, toStop = 4, legKind = 'loaded_solo', cargoType = 'hardware', cargoLabel = 'Tools', cargoMassKg = 4000 },
    },
    stops = {
      { index = 1, kind = 'loading', stopType = 'loading_bay', name = 'Farm', lat = 39.286, lon = -76.610, dwellTargetS = 3.5 },
      { index = 2, kind = 'delivery', stopType = 'loading_bay', name = 'Market', lat = 39.290, lon = -76.610, dwellTargetS = 2.0 },
      { index = 3, kind = 'loading', stopType = 'loading_bay', name = 'Depot', lat = 39.295, lon = -76.610, dwellTargetS = 2.0 },
      { index = 4, kind = 'delivery', stopType = 'loading_bay', name = 'Site', lat = 39.300, lon = -76.610, dwellTargetS = 2.0 },
    },
  })

  local stopCoords = { [39.286] = { 0, 120 }, [39.290] = { 0, 500 }, [39.295] = { 0, 900 }, [39.300] = { 0, 1400 } }
  local anchor4 = { geodeticToEnu = function(_, lat) local c = stopCoords[lat] or {0,0}; return c[1], c[2] end }
  local pl4 = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0.2 }

  -- Stage at Farm (< 160 m)
  fakeNow = fakeNow + 0.6
  tm.update(0.1, 0.1, anchor4, pl4, false, false)
  T.check(tm.hudPayload().trailerState == 'staged', 'trailer staged at Farm')

  -- Back up within 2.8 m -> attachExternalCoupler & auto-advance on confirmation
  playerPos = vec3(0, 112.5, 10)
  pl4.y = 112.5
  fakeNow = fakeNow + 0.5
  tm.update(0.1, 0.1, anchor4, pl4, false, false)
  attachedId = 902
  fakeNow = fakeNow + 0.1
  tm.update(0.1, 0.1, anchor4, pl4, false, false)
  local pLeg1 = tm.hudPayload()
  T.check(pLeg1.stopIndex == 2 and pLeg1.cargoKg == 14200 and pLeg1.legLabel == 'Deliver Fresh Produce · 14.2 t', 'coupling applies 14.2 t and advances to delivery leg')

  -- Phase 5: Detached trailer at loaded_trailer delivery bay blocks completion and shows Trailer missing alert
  attachedId = nil
  playerPos = vec3(0, 500, 10)
  trlPos = vec3(0, 250, 10)
  pl4.y = 500
  for _ = 1, 4 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchor4, pl4, false, false) end
  local pMissing = tm.hudPayload()
  T.check(pMissing.stopIndex == 2 and pMissing.dwellS == 0 and pMissing.trailerMissing == true and pMissing.bayHint == 'Trailer missing · Go back & hitch your trailer', 'Phase 5: detached trailer blocks delivery dwell and shows Trailer missing alert')

  -- Re-hitching trailer clears block, shows Unhooking trailer, and completes delivery into deadhead
  attachedId = 902
  trlPos = vec3(0, 500, 10)
  fakeNow = fakeNow + 0.5
  tm.update(0.5, 0.5, anchor4, pl4, false, false)
  local pUnhook = tm.hudPayload()
  T.check(not pUnhook.trailerMissing and pUnhook.dwellLabel == 'Unhooking trailer' and pUnhook.dwellS > 0, 'Phase 5: re-hitched trailer resumes Unhooking trailer dwell')
  for _ = 1, 4 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchor4, pl4, false, false) end
  local pDead = tm.hudPayload()
  T.check(pDead.stopIndex == 3 and pDead.legKind == 'deadhead' and pDead.cargoKg == nil and pDead.cargoLabel == nil and pDead.legLabel == 'Deadhead · Empty transit (0 kg)', 'Phase 5: deadhead leg clears cargo and shows Empty transit (0 kg)')
  T.check(#deleted == 0, 'dropped trailer NOT deleted while player < 80 m away')

  -- Drive > 80 m away -> despawnQueue deletes dropped trailer
  playerPos = vec3(0, 590, 10)
  pl4.y = 590
  fakeNow = fakeNow + 0.6
  tm.update(0.1, 0.1, anchor4, pl4, false, false)
  T.check(#deleted == 1 and deleted[1] == 902, 'despawnQueue deletes job-owned trailer once player > 80 m away')
  tm.cancelJob()

  tm.playerVeh = origPlayerVeh
  scenetree, core_vehicles, be, core_trailerRespawn = oldScenetree, oldCv, oldBe, oldTr
end

-- 11. Locality & Business Sector metadata forwarding (uiState + hudPayload)
do
  tm.cancelJob()
  tm.startJob('taxi', 'short')
  local reqId = sentReqs[#sentReqs].id
  tm.onJobResult({
    id = reqId, ok = true, mode = 'taxi', tier = 'short', title = 'Test Ride',
    stops = {
      { index = 1, kind = 'pickup', stopType = 'kerbside', name = 'Edeka', address = 'Penzberger Straße', locality = 'Sindelsdorf', sectorLabel = 'Supermarket', lat = 47.713, lon = 11.383 },
      { index = 2, kind = 'dropoff', stopType = 'kerbside', name = 'Bahnhof', address = 'Bahnhofplatz', locality = 'Penzberg · Dittenried', sectorLabel = 'Train / Transit Station', lat = 47.750, lon = 11.370 },
    },
  })
  local ui = tm.uiState()
  T.check(ui.active and ui.active.stops[1].locality == 'Sindelsdorf' and ui.active.stops[1].sectorLabel == 'Supermarket', 'uiState preserves stop locality and sectorLabel')
  T.check(ui.active.stops[2].locality == 'Penzberg · Dittenried' and ui.active.stops[2].sectorLabel == 'Train / Transit Station', 'uiState preserves upcoming stop locality and sectorLabel')
  local hp = tm.hudPayload()
  T.check(hp.stopLocality == 'Sindelsdorf' and hp.stopSectorLabel == 'Supermarket', 'hudPayload forwards active stopLocality and stopSectorLabel')
  T.check(hp.nextStopLocality == 'Penzberg · Dittenried' and hp.nextStopSectorLabel == 'Train / Transit Station', 'hudPayload forwards nextStopLocality and nextStopSectorLabel')
  tm.cancelJob()
end

-- 12. Phase 6: Parcel Courier mode + Physical 3D Cargo Props (discovery, bounds, slots, dynamic despawn & cleanup)
do
  -- Validation, compact bay & fast 2.5 s dwell + recipient dwell label
  T.check(tm.validateRequest('parcel', 'local') and tm.validateRequest('parcel', 'city')
    and tm.validateRequest('parcel', 'regional') and tm.validateRequest('parcel', 'long'), 'parcel tiers validate')
  T.check(not tm.validateRequest('parcel', 'short'), 'invalid parcel tier rejected')
  local pSpec = tm.baySpec('parcel', 'city')
  T.check(pSpec.width == 2.7 and pSpec.length == 6.2, 'parcel uses compact 2.7 x 6.2 m bay')
  T.check(tm.defaultDwellTargetS('parcel', 'local', { kind = 'delivery' }) == 2.5, 'parcel dwell target is 2.5 s')
  T.check(tm.dwellStatusLabel('parcel', 'delivery', 'bay', nil, nil, nil, { parcelAction = 'deliver', recipient = 'Fam. Weber' }) == 'Delivering parcel · Fam. Weber',
    'parcel deliver dwell label includes recipient')
  T.check(tm.dwellStatusLabel('parcel', 'pickup', 'bay', nil, nil, nil, { parcelAction = 'pickup_return', recipient = 'M. Gruber' }) == 'Picking up return parcel · M. Gruber',
    'parcel return pickup dwell label includes recipient')

  -- Prop discovery, cargo bay bounds & slot packing
  local disc = tm.discoverCargoPropModels(
    function(m) return m == 'cardboard_box' or m == 'cargo_load_box_S' or m == 'cargo_load_box_M' or m == 'woodcrate' or m == 'EuroPallet' end,
    function() return { models = { cardboard_box = { Type = 'Prop' }, cargo_load_box_S = { Type = 'Prop' }, cargo_load_box_M = { Type = 'Prop' }, woodcrate = { Type = 'Prop' }, EuroPallet = { Type = 'Prop' } } } end
  )
  T.check(#disc.parcel == 3 and disc.parcel[1] == 'cardboard_box' and disc.parcel[2] == 'cargo_load_box_S' and disc.parcel[3] == 'cargo_load_box_M',
    'discoverCargoPropModels prioritizes compact boxes and excludes woodcrate from parcel')
  T.check(#disc.crate >= 2 and disc.crate[1] == 'woodcrate', 'discoverCargoPropModels finds woodcrate/EuroPallet for crates')

  local bVan = tm.computeCargoBayBounds({ jbeam = 'van', lengthM = 5.4, widthM = 2.0 })
  local bPickup = tm.computeCargoBayBounds({ jbeam = 'pickup', lengthM = 5.5, widthM = 2.0 })
  local bHatch = tm.computeCargoBayBounds({ jbeam = 'vivace', modelType = 'Hatchback', lengthM = 4.3, widthM = 1.8 })
  local bFlat = tm.computeCargoBayBounds({ jbeam = 'flatbed', isTrailer = true })
  local bUtil = tm.computeCargoBayBounds({ jbeam = 'boxutility', isTrailer = true })
  local bDry = tm.computeCargoBayBounds({ jbeam = 'dryvan', isTrailer = true })
  local bMicro = tm.computeCargoBayBounds({ jbeam = 'pigeon', lengthM = 2.6, widthM = 1.2 })
  T.check(bVan and bVan.maxProps == 6 and bPickup and bPickup.maxProps == 6, 'van & pickup cargo bounds computed')
  T.check(bVan.halfW <= 0.58 and bPickup.halfW <= 0.58, 'van & pickup halfW tightened <= 0.58 m')
  T.check(bVan.yMin >= -(5.4 * 0.5) + 0.65 and bPickup.yMin >= -(5.5 * 0.5) + 0.65,
    'van & pickup rear yMin inset >= 0.65 m inside rear bumper/doors')
  T.check(bVan.zFloor >= 0.68 and bPickup.zFloor >= 0.82, 'van & pickup zFloor lifted above floor pan')
  T.check(bHatch and bHatch.maxProps == 3, 'hatchback compact trunk bounds computed')
  T.check(bFlat and bFlat.maxProps == 8 and bUtil and bUtil.maxProps == 4, 'open trailer bounds computed')
  T.check(bDry == nil and bMicro == nil, 'enclosed trailer & tiny microcar return nil bounds (node-mass fallback)')

  local slots = tm.cargoPropSlots(bVan, 6, 0.48)
  T.check(#slots == 6, 'cargoPropSlots packs 6 slots for van')
  for _, sl in ipairs(slots) do
    T.check(math.abs(sl.lx) + 0.24 <= bVan.halfW + 1e-6 and sl.ly - 0.24 >= bVan.yMin - 1e-6 and sl.ly + 0.24 <= bVan.yMax + 1e-6,
      'slot footprint stays cleanly within van cargo bay bounds')
  end
  T.check(tm.desiredCargoPropCount(14, 14, 6) == 6 and tm.desiredCargoPropCount(7, 14, 6) == 3 and tm.desiredCargoPropCount(0, 14, 6) == 0,
    'desiredCargoPropCount maps remaining parcels monotonically to 0')

  -- End-to-end parcel run with mocked 3D props spawn, stop-by-stop despawn, return pickup & cleanup
  local nextPropId = 5000
  local liveProps, deletedProps = {}, {}
  local oldScenetree, oldCv, oldBe, origPlayerVeh, origModelExists = scenetree, core_vehicles, be, tm.playerVeh, tm.modelExists
  local vanObj = {
    id = 950, JBeam = 'van',
    getID = function(self) return self.id end,
    getJBeamFilename = function(self) return self.JBeam end,
    getPosition = function() return vec3(0, 0, 10) end,
    getDirectionVector = function() return vec3(0, 1, 0) end,
    getDirectionVectorUp = function() return vec3(0, 0, 1) end,
    queueLuaCommand = function() end,
  }
  tm.playerVeh = function() return vanObj end
  tm.modelExists = function(m) return m == 'cardboard_box' or m == 'woodcrate' or m == 'boxutility' end
  core_vehicles = {
    getModelList = function() return { models = { cardboard_box = { Type = 'Prop' }, woodcrate = { Type = 'Prop' } } } end,
    spawnNewVehicle = function(model, opts)
      nextPropId = nextPropId + 1
      local pid = nextPropId
      local obj = {
        id = pid, model = model,
        getID = function(self) return self.id end,
        getPosition = function() return opts.pos end,
        getDirectionVector = function() return vec3(0, 1, 0) end,
        queueLuaCommand = function() end,
        delete = function(self)
          liveProps[self.id] = nil
          deletedProps[#deletedProps + 1] = self.id
        end,
      }
      liveProps[pid] = obj
      return obj
    end,
  }
  scenetree = { findObjectById = function(id) return liveProps[id] or (id == 950 and vanObj or nil) end }
  be = { getObjectCount = function() return 0 end }

  tm.startJob('parcel', 'local')
  local reqId = sentReqs[#sentReqs].id
  tm.onJobResult({
    id = reqId, ok = true, mode = 'parcel', tier = 'local',
    title = 'Local Parcel Round (6 parcels · 72 kg)',
    parcel = { parcelsTotal = 6, initialMassKg = 72, returnCount = 1 },
    cargo = { type = 'parcels', label = 'Courier Parcels', massKg = 72, vehicleClass = 'van', useTrailer = false },
    stops = {
      { index = 1, kind = 'delivery', stopType = 'kerbside', name = 'Birkenweg 14', address = 'Fam. Weber · Birkenweg 14', recipient = 'Fam. Weber', parcelCount = 2, parcelAction = 'deliver', cargoDeltaKg = -24, parcelsRemaining = 4, parcelsTotal = 6, lat = 47.714, lon = 11.383, dwellTargetS = 2.5 },
      { index = 2, kind = 'pickup', stopType = 'kerbside', name = 'Hauptstraße 27a', address = 'M. Gruber · Hauptstraße 27a', recipient = 'M. Gruber', parcelCount = 1, parcelAction = 'pickup_return', cargoDeltaKg = 10, parcelsRemaining = 4, parcelsTotal = 6, lat = 47.716, lon = 11.383, dwellTargetS = 2.5 },
      { index = 3, kind = 'delivery', stopType = 'kerbside', name = 'Lindenstraße 8', address = 'Praxis Dr. König · Lindenstraße 8', recipient = 'Praxis Dr. König', parcelCount = 4, parcelAction = 'deliver', cargoDeltaKg = -48, parcelsRemaining = 0, parcelsTotal = 6, lat = 47.718, lon = 11.383, dwellTargetS = 2.5 },
    },
  })
  local hp0 = tm.hudPayload()
  T.check(hp0.mode == 'parcel' and hp0.parcelsRemaining == 6 and hp0.parcelsTotal == 6 and hp0.recipient == 'Fam. Weber', 'parcel job initializes 6/6 manifest and recipient')
  T.check(hp0.cargoPropsCount == 6, 'parcel job spawns 6 physical 3D parcel props inside van bay')

  local pCoords = { [47.714] = { 0, 0 }, [47.716] = { 0, 200 }, [47.718] = { 0, 400 } }
  local anchorP = { geodeticToEnu = function(_, lat) local c = pCoords[lat] or { 0, 0 }; return c[1], c[2] end }
  local plP = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0.2 }

  -- Complete stop 1 (deliver 2 parcels -> 4/6 remaining, 2 props deleted)
  for _ = 1, 5 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchorP, plP, false, false) end
  local hp1 = tm.hudPayload()
  T.check(hp1.stopIndex == 2 and hp1.parcelsRemaining == 4 and hp1.cargoPropsCount == 4 and #deletedProps == 2, 'delivering 2 parcels steps manifest to 4/6 and despawns 2 props')
  T.check(hp1.parcelAction == 'pickup_return' and hp1.recipient == 'M. Gruber', 'stop 2 exposes pickup_return action and recipient')

  -- Complete stop 2 (return pickup +1 parcel -> parcelsReturned == 1, cargoCurrentKg increases by +10)
  plP.y = 200
  for _ = 1, 5 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchorP, plP, false, false) end
  local hp2 = tm.hudPayload()
  T.check(hp2.stopIndex == 3 and hp2.parcelsReturned == 1 and hp2.cargoCurrentKg == 58 and hp2.cargoPropsCount == 5, 'return pickup increments parcelsReturned, mass (+10 kg) and spawns return prop')

  -- Complete stop 3 (final delivery -> summary, all remaining props cleaned up)
  plP.y = 400
  for _ = 1, 5 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchorP, plP, false, false) end
  local hpDone = tm.hudPayload()
  T.check(hpDone.state == 'summary' and hpDone.parcelsDelivered == 6 and hpDone.parcelsReturned == 1, 'parcel summary reports 6 delivered + 1 return')
  local liveCount = 0
  for _ in pairs(liveProps) do liveCount = liveCount + 1 end
  T.check(liveCount == 0, 'all 3D cargo props cleaned up on job completion')

  -- Verify cancelJob() cleans up active parcel props too
  tm.startJob('parcel', 'local')
  tm.onJobResult({
    id = sentReqs[#sentReqs].id, ok = true, mode = 'parcel', tier = 'local',
    parcel = { parcelsTotal = 4, initialMassKg = 48 },
    stops = {
      { index = 1, kind = 'delivery', name = 'Ahornweg 4', recipient = 'S. Bauer', parcelCount = 4, parcelAction = 'deliver', cargoDeltaKg = -48, lat = 47.714, lon = 11.383 },
    },
  })
  T.check(tm.hudPayload().cargoPropsCount == 4, 'second parcel job spawns 4 props')
  tm.cancelJob()
  liveCount = 0
  for _ in pairs(liveProps) do liveCount = liveCount + 1 end
  T.check(liveCount == 0, 'cancelJob cleans up all remaining 3D cargo props')

  tm.playerVeh, tm.modelExists = origPlayerVeh, origModelExists
  scenetree, core_vehicles, be = oldScenetree, oldCv, oldBe
end

-- 13. Phase 7: Career Progression, Driver Ranks, Persistence, Itemized Payout & Vehicle Match
do
  -- 13a. Rank thresholds
  T.check(tm.computeDriverRank(0, 0) == 'Rookie Driver', '0 jobs -> Rookie Driver')
  T.check(tm.computeDriverRank(3, 75) == 'Local Courier', '3 jobs + $75 -> Local Courier')
  T.check(tm.computeDriverRank(3, 74) == 'Rookie Driver', '3 jobs but < $75 stays Rookie Driver')
  T.check(tm.computeDriverRank(10, 350) == 'Route Specialist', '10 jobs + $350 -> Route Specialist')
  T.check(tm.computeDriverRank(25, 1200) == 'Senior Fleet Operator', '25 jobs + $1200 -> Senior Fleet Operator')
  T.check(tm.computeDriverRank(50, 3500) == 'Master Hauler', '50 jobs + $3500 -> Master Hauler')

  -- 13b. Vehicle match summaries
  local vmCar = tm.vehicleMatchInfo({ jbeam = 'vivace', massKg = 1350 })
  local vmVan = tm.vehicleMatchInfo({ jbeam = 'van', massKg = 2600, coupler = 'none' })
  local vmSemi = tm.vehicleMatchInfo({ jbeam = 'us_semi', coupler = 'fifthwheel', massKg = 8200 })
  local vmBus = tm.vehicleMatchInfo({ jbeam = 'citybus', massKg = 11000 })
  T.check(vmCar.class == 'car' and vmCar.vehicleLabel == 'Passenger Car', 'vehicleMatchInfo classifies passenger car')
  T.check(vmVan.class == 'van' and vmVan.summaryText:find('Parcel') ~= nil, 'vehicleMatchInfo recommends Parcel for van')
  T.check(vmSemi.class == 'semi' and vmSemi.readiness == 'Ready for Heavy Trailers', 'vehicleMatchInfo detects semi fifthwheel readiness')
  T.check(vmBus.vehicleLabel == 'City Bus' and vmBus.recommendedModes[1] == 'bus', 'vehicleMatchInfo detects citybus')

  -- 13c. Itemized payout breakdown across all 4 modes & penalty clamping
  local pTaxi = tm.computePayoutBreakdown({
    mode = 'taxi', tier = 'city', stopsCompleted = 2, stopsSkipped = 0,
    passengerOnBoard = true, fareDrivenM = 5000, fareElapsedS = 200, targetLegS = 260,
    collisions = 0, damageDelta = 0, _scoreHint = 95,
  }, 95, 92, 100, 1)
  T.check(pTaxi.basePay > 0 and pTaxi.timeBonus > 0 and pTaxi.smoothnessBonus > 0 and pTaxi.tipOrStreakBonus > 0 and pTaxi.damagePenalty == 0 and pTaxi.totalEarned > pTaxi.basePay,
    'taxi payout includes base fare, time, smoothness, and tip/streak bonuses')

  local pBus = tm.computePayoutBreakdown({
    mode = 'bus', tier = 'full', stopsCompleted = 6, stopsSkipped = 0,
    drivenM = 4500, scheduleDeltaS = 10, collisions = 0, damageDelta = 0,
  }, 90, 88, 100, 2)
  T.check(pBus.basePay > 20 and pBus.timeBonus > 0 and pBus.smoothnessBonus > 0 and pBus.tipOrStreakBonus > 0 and pBus.streakApplied == 3,
    'bus payout awards on-time, smoothness, and 3x streak bonus')

  local pLog = tm.computePayoutBreakdown({
    mode = 'logistics', tier = 'regional', stopsCompleted = 2, stopsSkipped = 0,
    drivenM = 12000, totalCargoHauledKg = 14000, useTrailer = true, collisions = 1, damageDelta = 600,
  }, 85, 84, 90, 0)
  T.check(pLog.basePay > 40 and pLog.damagePenalty > 0 and pLog.totalEarned >= 0,
    'logistics payout deducts collision/damage penalty cleanly')

  local pSkip = tm.computePayoutBreakdown({
    mode = 'parcel', tier = 'local', stopsCompleted = 0, stopsSkipped = 2,
  }, 0, 100, 100, 0)
  T.check(pSkip.totalEarned == 0 and pSkip.basePay == 0, 'zero completed stops yields $0 payout')

  -- 13d. Persistence round-trip + accumulation across modes + resetCareerStats()
  local savedFiles = {}
  local oldWrite, oldRead, oldFs = jsonWriteFile, jsonReadFile, FS
  jsonWriteFile = function(path, tbl)
    savedFiles[path] = tbl
    return true
  end
  jsonReadFile = function(path)
    return savedFiles[path]
  end
  FS = { fileExists = function(_, path) return savedFiles[path] ~= nil end }

  tm.resetCareerStats()
  local c0 = tm.getCareerStats()
  T.check(c0.completedJobs == 0 and c0.totalEarnings == 0 and c0.driverRank == 'Rookie Driver', 'resetCareerStats zeros career stats')
  T.check(savedFiles[tm.CAREER_FILE] ~= nil, 'resetCareerStats writes career file')

  -- Run 1 completed taxi job and 1 completed parcel job
  local anchor7 = { geodeticToEnu = function() return 0, 0 end }
  local pl7 = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0.2 }

  tm.startJob('taxi', 'short')
  tm.onJobResult({
    id = sentReqs[#sentReqs].id, ok = true, mode = 'taxi', tier = 'short', title = 'Career Taxi',
    stops = {
      { index = 1, kind = 'pickup', name = 'A', lat = 39.286, lon = -76.610, dwellTargetS = 2.0 },
      { index = 2, kind = 'dropoff', name = 'B', lat = 39.286, lon = -76.610, dwellTargetS = 2.0 },
    },
  })
  for _ = 1, 5 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchor7, pl7, false, false) end
  for _ = 1, 5 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchor7, pl7, false, false) end
  local sumTaxi = tm.hudPayload()
  T.check(sumTaxi.state == 'summary' and sumTaxi.totalEarned > 0 and sumTaxi.payout and sumTaxi.payout.totalEarned == sumTaxi.totalEarned,
    'completed taxi job populates summary totalEarned and payout breakdown')
  tm.dismissSummary()

  tm.startJob('parcel', 'local')
  tm.onJobResult({
    id = sentReqs[#sentReqs].id, ok = true, mode = 'parcel', tier = 'local', title = 'Career Parcel',
    parcel = { parcelsTotal = 2, initialMassKg = 24 },
    stops = {
      { index = 1, kind = 'delivery', name = 'Door 1', recipient = 'A. Test', parcelCount = 2, parcelAction = 'deliver', cargoDeltaKg = -24, lat = 39.286, lon = -76.610, dwellTargetS = 2.0 },
    },
  })
  for _ = 1, 5 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchor7, pl7, false, false) end
  tm.dismissSummary()

  local c1 = tm.getCareerStats()
  T.check(c1.completedJobs == 2 and c1.totalEarnings > 0 and c1.byMode.taxi.jobs == 1 and c1.byMode.parcel.jobs == 1 and c1.bestScore > 0 and c1.avgScore > 0,
    'career stats accumulate across taxi and parcel jobs')

  -- Reload from mocked jsonReadFile
  local cReload = tm.loadCareerStats()
  T.check(cReload.completedJobs == 2 and cReload.totalEarnings == c1.totalEarnings and cReload.byMode.parcel.jobs == 1,
    'loadCareerStats restores persisted career stats')

  -- Corrupt JSON fallback
  savedFiles[tm.CAREER_FILE] = 'not_a_table'
  local cCorrupt = tm.loadCareerStats()
  T.check(cCorrupt.completedJobs == 0 and cCorrupt.driverRank == 'Rookie Driver',
    'corrupt career JSON falls back safely to defaults')

  -- uiState exposes career and vehicleMatch
  local u7 = tm.uiState()
  T.check(type(u7.career) == 'table' and type(u7.vehicleMatch) == 'table' and type(u7.vehicleMatch.summaryText) == 'string',
    'uiState exposes career and vehicleMatch')

  tm.resetCareerStats()
  jsonWriteFile, jsonReadFile, FS = oldWrite, oldRead, oldFs
end

-- 15. Loop 3: Zero-GC hot-loop, bay quad cache invalidation, uiState vehicleMatch throttle, idle early-exit
do
  tm.reset()
  -- 15a. Idle M.update() does not even call M.now() when inactive & despawnQueue empty
  local nowCalls = 0
  local origNow = tm.now
  tm.now = function() nowCalls = nowCalls + 1; return fakeNow end
  local anchorIdle = { geodeticToEnu = function() return 0, 0 end }
  local plIdle = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0 }
  tm.update(0.016, 0.016, anchorIdle, plIdle, false, false)
  T.check(nowCalls == 0, 'idle M.update() exits before calling M.now()')
  tm.now = origNow

  -- 15b. Bay quad cache & zero steady-state vec3/ColorF allocations in drawMarker()
  local origVec3 = vec3
  local origColorF = rawget(_G, 'ColorF')
  local origDebugDrawer = rawget(_G, 'debugDrawer')
  local origBuild = tm.buildBayQuads
  local vec3Allocs, colorFAllocs, buildCalls, quadsDrawn = 0, 0, 0, 0
  vec3 = function(x, y, z) vec3Allocs = vec3Allocs + 1; return origVec3(x, y, z) end
  ColorF = function(r, g, b, a) colorFAllocs = colorFAllocs + 1; return { r = r, g = g, b = b, a = a } end
  debugDrawer = { drawQuadSolid = function() quadsDrawn = quadsDrawn + 1 end }
  tm.buildBayQuads = function(...) buildCalls = buildCalls + 1; return origBuild(...) end

  tm.startJob('taxi', 'short')
  tm.onJobResult({
    id = sentReqs[#sentReqs].id, ok = true, mode = 'taxi', tier = 'short', title = 'Perf Test',
    stops = {
      { index = 1, kind = 'pickup', name = 'Stop A', lat = 39.286, lon = -76.610, dwellTargetS = 5.0 },
      { index = 2, kind = 'dropoff', name = 'Stop B', lat = 39.295, lon = -76.605, dwellTargetS = 5.0 },
    },
  })
  local anchorM = { geodeticToEnu = function(_, lat) return 0, (lat == 39.286) and 0 or 800 end }
  local plM = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0 }
  tm.update(0.016, 0.016, anchorM, plM, false, false)

  -- First frame builds cache + lazy scratch objects
  tm.drawMarker(anchorM, plM)
  T.check(buildCalls == 1 and tm._bayCacheBuilds() == 1 and quadsDrawn > 0, 'first drawMarker builds bay quad cache once')

  -- Steady-state frames (including color transition) must have 0 rebuilds and 0 vec3/ColorF allocations
  vec3Allocs, colorFAllocs, quadsDrawn = 0, 0, 0
  for _ = 1, 30 do
    fakeNow = fakeNow + 0.016
    tm.update(0.016, 0.016, anchorM, plM, false, false)
    tm.drawMarker(anchorM, plM)
  end
  T.check(buildCalls == 1 and vec3Allocs == 0 and colorFAllocs == 0 and quadsDrawn > 0,
    'steady-state drawMarker reuses cached quads and scratch vec3/ColorF with 0 allocations')

  -- Terrain gridZ change invalidates cache
  fakeNow = fakeNow + 1.0
  fakeRayZ = 11.2
  tm.update(0.016, 0.016, anchorM, plM, false, false)
  tm.drawMarker(anchorM, plM)
  T.check(buildCalls == 2, 'bayGridZ change invalidates and rebuilds bay quad cache')

  -- onRebased() invalidates cache
  tm.onRebased()
  tm.drawMarker(anchorM, plM)
  T.check(buildCalls == 3, 'onRebased invalidates and rebuilds bay quad cache')

  -- Stop change invalidates cache
  tm.skipStop()
  local anchorM2 = { geodeticToEnu = function() return 0, 0 end }
  tm.drawMarker(anchorM2, plM)
  T.check(buildCalls == 4, 'stop advance invalidates and rebuilds bay quad cache')

  tm.reset()
  fakeRayZ = 10.0
  vec3, ColorF, debugDrawer, tm.buildBayQuads = origVec3, origColorF, origDebugDrawer, origBuild

  -- 15c. uiState() throttles inspectGeVehicle() for 0.5 s per pvId
  local origCv = rawget(_G, 'core_vehicles')
  local origGpv = rawget(_G, 'getPlayerVehicle')
  local curVid = 777
  local detCalls = 0
  getPlayerVehicle = function() return { getID = function() return curVid end, getJBeamFilename = function() return 'van' end } end
  core_vehicles = { getCurrentVehicleDetails = function() detCalls = detCalls + 1; return { model = { Type = 'Van' }, configs = { Name = 'Base' } } end }
  tm.onVehicleSwitched(nil, curVid)
  tm.uiState()
  tm.uiState()
  fakeNow = fakeNow + 0.2
  tm.uiState()
  T.check(detCalls == 1, 'uiState caches vehicleMatch within 0.5 s window')
  fakeNow = fakeNow + 0.4
  tm.uiState()
  T.check(detCalls == 2, 'uiState refreshes vehicleMatch after 0.5 s expiry')
  curVid = 778
  tm.onVehicleSwitched(777, 778)
  tm.uiState()
  T.check(detCalls == 3, 'onVehicleSwitched invalidates vehicleMatch cache immediately')
  tm._onVehicleProbe(778, { massKg = 2800, coupler = 'towhitch', attached = false })
  tm.uiState()
  T.check(detCalls == 4, '_onVehicleProbe invalidates vehicleMatch cache immediately')
  core_vehicles, getPlayerVehicle = origCv, origGpv
  tm.reset()
end

-- 16. Interactive OSM Fuel Stations, Physical Refueling, Career Deduction & -$50 Overdraft Persistence
do
  tm.reset()
  local savedCareer = nil
  local origRead, origWrite = rawget(_G, 'jsonReadFile'), rawget(_G, 'jsonWriteFile')
  local origGpv = rawget(_G, 'getPlayerVehicle')
  local origVec3, origColorF, origDd = rawget(_G, 'vec3'), rawget(_G, 'ColorF'), rawget(_G, 'debugDrawer')

  jsonReadFile = function() return savedCareer end
  jsonWriteFile = function(_, data) savedCareer = data; return true end
  tm.resetCareerStats()

  -- Seed $20.00 career balance
  local cInit = tm.getCareerStats()
  savedCareer = { version = 1, totalEarnings = 20.0, completedJobs = 2, scoreSum = 180, bestScore = 95, avgScore = 90, streak = 1 }
  tm.loadCareerStats()
  T.check(tm.getCareerStats().totalEarnings == 20.0, 'career loaded with $20.00 balance')

  -- Pure query throttling (6 s or > 400 m)
  T.check(tm.shouldQueryFuelStations(nil, nil, nil, 100, 48.135, 11.582), 'first fuel query always due')
  T.check(not tm.shouldQueryFuelStations(100, 48.135, 11.582, 103, 48.1351, 11.582), 'throttled within 6 s and < 400 m')
  T.check(tm.shouldQueryFuelStations(100, 48.135, 11.582, 106.5, 48.135, 11.582), 're-queries after 6 s')
  T.check(tm.shouldQueryFuelStations(100, 48.135, 11.582, 101, 48.140, 11.582), 're-queries after > 400 m move')

  -- Periodic query + onFuelStationsResult + _onFuelProbe
  local fuelReqs = {}
  local origReqFuel = fakeCore.requestFuelStations
  fakeCore.requestFuelStations = function(id, lat, lon, rM)
    fuelReqs[#fuelReqs + 1] = { id = id, lat = lat, lon = lon, radiusM = rM }
    return true
  end

  local queuedCmds = {}
  getPlayerVehicle = function()
    return {
      getID = function() return 42 end,
      queueLuaCommand = function(_, cmd) queuedCmds[#queuedCmds + 1] = cmd end,
    }
  end

  local anchorF = { geodeticToEnu = function(_, lat, lon) return (lat == 39.285) and 0 or 500, 0 end }
  local plF = { lat = 39.285, lon = -76.610, x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0.1 }
  fakeNow = 500.0
  tm.update(0.1, 0.1, anchorF, plF, false, false)
  T.check(#fuelReqs == 1 and fuelReqs[1].radiusM == tm.FUEL_QUERY_RADIUS_M, 'update triggers initial fuel_stations_request')
  T.check(#queuedCmds == 1 and queuedCmds[1]:find('energyStorage'), 'update probes vehicle fuel via energyStorage')

  -- Feed fuel station & low fuel probe (15% of 60 L tank)
  tm.onFuelStationsResult({
    id = fuelReqs[1].id,
    ok = true,
    stations = {
      { id = 'fuel_shell', name = 'Shell', brand = 'Shell', lat = 39.285, lon = -76.610, bearingDeg = 0, distM = 0, road = 'Main St', locality = 'Baltimore', pricePerLiter = 1.80 },
      { id = 'fuel_aral', name = 'Aral', brand = 'Aral', lat = 39.290, lon = -76.610, bearingDeg = 90, distM = 540, road = 'North Rd', locality = 'Baltimore', pricePerLiter = 1.75 },
    },
  })
  tm._onFuelProbe(42, { ratio = 0.15, capacityL = 60.0, volumeL = 9.0, hasTank = true })

  local uiF = tm.uiState()
  T.check(uiF.fuelPct == 15 and uiF.lowFuel == true, 'uiState exposes fuelPct=15 and lowFuel=true')
  T.check(uiF.nearestFuelStation and uiF.nearestFuelStation.name == 'Shell' and uiF.nearestFuelStation.pricePerLiter == 1.80,
    'uiState exposes nearestFuelStation metadata')

  -- 3D Fuel Pump Bay rendering within 140 m (and hidden < 25 m from active job stop)
  local fuelQuadDraws = 0
  vec3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0, set = function(self, a, b, c) self.x, self.y, self.z = a, b, c end } end
  ColorF = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
  debugDrawer = { drawQuadSolid = function() fuelQuadDraws = fuelQuadDraws + 1 end }
  tm.drawMarker(anchorF, plF)
  T.check(fuelQuadDraws > 0, '3D cyan fuel pump bay renders within 140 m')

  -- Hold stopped in pump bay for 1.2 s -> begins refueling & emits setRemainingRatio
  queuedCmds = {}
  for _ = 1, 3 do
    fakeNow = fakeNow + 0.5
    tm.update(0.5, 0.5, anchorF, plF, false, false)
  end
  local refHud = tm.hudPayload()
  T.check(refHud and refHud.state == 'refueling' and refHud.refueling and refHud.refueling.active == true,
    'stopped 1.2 s in pump bay activates live refueling HUD')
  T.check(#queuedCmds >= 1 and queuedCmds[#queuedCmds]:find('setRemainingRatio'),
    'active refueling emits energyStorage setRemainingRatio VE command')

  -- Refuel to full (51 L * $1.80 = $91.80, but balance $20 + $50 overdraft = $70 max -> hits overdraft limit -$50!)
  for _ = 1, 20 do
    fakeNow = fakeNow + 0.5
    tm.update(0.5, 0.5, anchorF, plF, false, false)
  end
  local afterCar = tm.getCareerStats()
  T.check(math.abs(afterCar.totalEarnings - (-50.0)) < 0.02, 'emergency overdraft caps career balance at -$50.00 (got ' .. tostring(afterCar.totalEarnings) .. ')')
  T.check(savedCareer and math.abs(savedCareer.totalEarnings - (-50.0)) < 0.02, 'saveCareerStats persists negative overdraft balance')

  -- Reloading career preserves -$50.00 overdraft
  tm.loadCareerStats()
  T.check(math.abs(tm.getCareerStats().totalEarnings - (-50.0)) < 0.02, 'loadCareerStats preserves -$50.00 overdraft')

  -- One-click routeToNearestFuel sets GPS destination
  local gpsBefore = #gpsCalls.set
  local rRes = tm.routeToNearestFuel()
  T.check(rRes.ok == true and #gpsCalls.set == gpsBefore + 1 and gpsCalls.set[#gpsCalls.set].label:find('Shell'),
    'routeToNearestFuel sets GPS destination to nearest station')

  fakeCore.requestFuelStations = origReqFuel
  jsonReadFile, jsonWriteFile, getPlayerVehicle = origRead, origWrite, origGpv
  vec3, ColorF, debugDrawer = origVec3, origColorF, origDd
  tm.reset()
end

-- 17. Loop 7 Part B: Fragile & Hazmat Cargo Physics, Integrity Telemetry, and Hazard Bonus Payout
do
  -- Gentle driving (< 0.55 G) keeps both fragile and hazmat at 100.0%
  local f1 = tm.stepCargoIntegrity(100.0, 'fragile', 0.45 * 9.81, 0.2 * 9.81, false, 0, 1.0)
  local h1 = tm.stepCargoIntegrity(100.0, 'hazmat', 0.50 * 9.81, 0.2 * 9.81, false, 0, 1.0)
  T.check(f1 == 100.0 and h1 == 100.0, 'gentle driving preserves 100% cargo integrity')

  -- 0.60 G spike leaves fragile untouched (> 0.65 G) but deducts hazmat (> 0.55 G)
  local f2 = tm.stepCargoIntegrity(100.0, 'fragile', 0.60 * 9.81, 0, false, 0, 0.5)
  local h2 = tm.stepCargoIntegrity(100.0, 'hazmat', 0.60 * 9.81, 0, false, 0, 0.5)
  T.check(f2 == 100.0 and h2 < 100.0, '0.60 G differentiates fragile (>0.65G) vs hazmat (>0.55G)')

  -- Severe G-spike + vertical jolt + collision deduct smoothly and clamp at 0
  local h3 = tm.stepCargoIntegrity(h2, 'hazmat', 1.2 * 9.81, 1.6 * 9.81, true, 600, 1.0)
  T.check(h3 < h2 and h3 >= 0.0, 'G-spike + jolt + collision deduct hazmat integrity')
  local hZero = tm.stepCargoIntegrity(5.0, 'hazmat', 2.0 * 9.81, 2.0 * 9.81, true, 1200, 2.0)
  T.check(hZero == 0.0, 'cargoIntegrity clamps cleanly at 0.0%')

  -- Payout hazardBonus scales with cargoIntegrity and hazardBonusMult
  local pFull = tm.computePayoutBreakdown({
    mode = 'logistics', tier = 'city', stopsCompleted = 4, stopsSkipped = 0,
    collisions = 0, damageDelta = 0, drivenM = 10000, cargoKg = 4000,
    cargoSensitivity = 'hazmat', hazardBonusMult = 0.50, cargoIntegrity = 100.0,
  }, 100, 100, 100, 0)
  local pHalf = tm.computePayoutBreakdown({
    mode = 'logistics', tier = 'city', stopsCompleted = 4, stopsSkipped = 0,
    collisions = 0, damageDelta = 0, drivenM = 10000, cargoKg = 4000,
    cargoSensitivity = 'hazmat', hazardBonusMult = 0.50, cargoIntegrity = 50.0,
  }, 88, 100, 100, 0)
  local pStd = tm.computePayoutBreakdown({
    mode = 'logistics', tier = 'city', stopsCompleted = 4, stopsSkipped = 0,
    collisions = 0, damageDelta = 0, drivenM = 10000, cargoKg = 4000,
    cargoSensitivity = 'standard', hazardBonusMult = 0.0, cargoIntegrity = 100.0,
  }, 100, 100, 100, 0)
  T.check(pFull.hazardBonus > 0 and math.abs(pFull.hazardBonus - pFull.basePay * 0.50) <= 0.02,
    'full integrity hazmat earns 50% basePay hazardBonus')
  T.check(math.abs(pHalf.hazardBonus - pHalf.basePay * 0.25) <= 0.02,
    '50% integrity hazmat earns half hazardBonus')
  T.check(pStd.hazardBonus == 0 and pFull.totalEarned > pStd.totalEarned,
    'standard job earns 0 hazardBonus and less than clean hazmat')

  -- Score reflects integrity loss
  local scClean = tm.computeScore({ elapsedS = 60, harshS = 0, collisions = 0, damageDelta = 0, stopsSkipped = 0, cargoSensitivity = 'fragile', cargoIntegrity = 100 })
  local scDamaged = tm.computeScore({ elapsedS = 60, harshS = 0, collisions = 0, damageDelta = 0, stopsSkipped = 0, cargoSensitivity = 'fragile', cargoIntegrity = 40 })
  T.check(scClean == 100 and scDamaged < scClean, 'computeScore penalizes lost fragile/hazmat integrity')
end

-- 18. Autobahn Rest Stop Waypoints (kind = 'rest_stop', HUD label, smooth progression & cargo continuity)
do
  tm.reset()
  T.check(tm.validateRequest('bus', 'regional') and tm.validateRequest('bus', 'long'), 'bus regional/long tiers validate')
  T.check(tm.defaultDwellTargetS('logistics', 'regional', { kind = 'rest_stop', dwellS = 8.0 }) == 8.0,
    'rest_stop default dwell target is 8.0 s')
  T.check(tm.dwellStatusLabel('logistics', 'rest_stop', 'bay', 'loaded_solo', 'loaded_solo', 'none', { name = 'Rasthof Holzkirchen' })
    == 'Rest Stop · Rasthof Holzkirchen', 'rest_stop dwellStatusLabel formats Rest Stop · <Name>')

  local anchorR = { geodeticToEnu = function() return 0, 0 end }
  local plR = { x = 0, y = 0, z = 10, vx = 0, vy = 0, vz = 0, speed = 0.1 }
  tm.startJob('logistics', 'regional')
  tm.onJobResult({
    id = sentReqs[#sentReqs].id,
    ok = true,
    mode = 'logistics',
    tier = 'regional',
    title = 'Origin -> Dest',
    cargo = { type = 'pallets', label = 'Palletized Freight', domain = 'retail', massKg = 3000, vehicleClass = 'box_truck', useTrailer = false },
    legs = {
      { index = 1, fromStop = 1, toStop = 2, legKind = 'loaded_solo', cargoType = 'pallets', cargoLabel = 'Palletized Freight', cargoDomain = 'retail', cargoMassKg = 3000 },
      { index = 2, fromStop = 2, toStop = 3, legKind = 'loaded_solo', cargoType = 'pallets', cargoLabel = 'Palletized Freight', cargoDomain = 'retail', cargoMassKg = 3000 },
    },
    stops = {
      { index = 1, kind = 'loading', stopType = 'loading_bay', name = 'Origin Depot', lat = 48.0, lon = 11.6, cargoDeltaKg = 3000, dwellTargetS = 2.0 },
      { index = 2, kind = 'rest_stop', role = 'Rest Stop', stopType = 'loading_bay', name = 'Rasthof Holzkirchen', lat = 48.0, lon = 11.6, cargoDeltaKg = 0, dwellS = 8.0, dwellTargetS = 8.0 },
      { index = 3, kind = 'delivery', stopType = 'loading_bay', name = 'Dest Warehouse', lat = 48.0, lon = 11.6, cargoDeltaKg = -3000, dwellTargetS = 2.0 },
    },
  })

  -- Complete loading stop 1 -> advances to rest_stop 2 with 3000 kg on board
  for _ = 1, 5 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchorR, plR, false, false) end
  local hRest = tm.hudPayload()
  T.check(hRest and hRest.stopIndex == 2 and hRest.stopKind == 'rest_stop' and hRest.stopRole == 'Rest Stop'
    and hRest.dwellLabel == 'Rest Stop · Rasthof Holzkirchen' and hRest.dwellTargetS == 8.0,
    'active rest_stop exposes Rest Stop HUD label, role, and 8.0 s dwell target')

  -- Complete 8.0 s rest stop -> advances smoothly to delivery stop 3 WITHOUT unloading cargo
  for _ = 1, 17 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchorR, plR, false, false) end
  local hDel = tm.hudPayload()
  T.check(hDel and hDel.stopIndex == 3 and hDel.stopKind == 'delivery' and hDel.cargoCurrentKg == 3000,
    'completing rest_stop preserves cargo mass and advances to delivery stop')

  -- Complete delivery stop 3 -> finishes job cleanly with normal payout
  for _ = 1, 5 do fakeNow = fakeNow + 0.5; tm.update(0.5, 0.5, anchorR, plR, false, false) end
  local hSum = tm.hudPayload()
  T.check(hSum and hSum.state == 'summary' and hSum.stopsCompleted == 3 and hSum.totalEarned > 0,
    'job with rest_stop completes cleanly with full payout')
  tm.reset()
end

T.done('test_transport_modes')
