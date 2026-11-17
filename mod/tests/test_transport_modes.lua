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

T.done('test_transport_modes')
