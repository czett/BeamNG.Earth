-- luajit mod/tests/test_overtake.lua  (overtaking on multi-lane highways: the pure decisions)
local T = dofile((arg[0]:match('^(.*)[/\\]') or '.') .. '/testlib.lua')
local O = require('beamngEarth/overtake')

T.check(O.lanesMyWay('++', true) == 2 and O.lanesMyWay('-++', true) == 2 and O.lanesMyWay('-++', false) == 1,
  'lanes my way: the + lanes along, the - lanes against')
T.check(O.lanesMyWay(nil, true) == 0, 'no lanes string: none')

-- a 2-lane carriageway 7.2 m wide (radius 3.6): the right lane's centre at +1.8, the left's at -1.8 (as on I-94)
local k, w = O.laneOf(1.8, 3.6, 2)
T.check(k == 1 and math.abs(w - 3.6) < 1e-9, 'right lane: index 1, 3.6 m wide')
T.check(O.laneOf(-1.5, 3.6, 2) == 0, 'left lane: index 0')
T.check(O.laneOf(9, 3.6, 2) == 1 and O.laneOf(-9, 3.6, 2) == 0, 'past the edges: the outer lanes')
T.check(O.laneOf(0, 0, 2) == nil, 'no width: nil')

T.check(O.passShift(1, 2, 3.6, false) == -3.6, 'right-hand traffic: from the right lane, one lane left')
T.check(O.passShift(0, 2, 3.6, false) == nil, '... from the left lane: nowhere to pass')
T.check(O.passShift(0, 2, 3.6, true) == 3.6, 'left-hand traffic: from the left lane, one lane right')
T.check(O.passShift(0, 1, 3.6, false) == nil, 'one lane: no passing')

-- held: behind a truck at 42 mph (18.8 m/s) on an 80 mph road (35.8 m/s), 30 m ahead, the car at 19 m/s
T.check(O.isHeld(19, 35.8, 30, 18.8), 'held behind a slow truck')
T.check(not O.isHeld(19, 35.8, 90, 18.8), 'not held: the truck 90 m ahead')
T.check(not O.isHeld(33, 35.8, 30, 32), 'not held: the one ahead near the limit')
T.check(not O.isHeld(10, 35.8, 30, 20), 'not held: the one ahead pulling away')

-- the left lane clear? others in the car's frame (ahead m, side m right of it, speed)
local shift = -3.6
T.check(O.laneClear({ { ahead = 30, side = 0, v = 18 } }, shift, 25, 70, 19), 'the truck in our lane does not block the left one')
T.check(not O.laneClear({ { ahead = 40, side = -3.5, v = 30 } }, shift, 25, 70, 19), 'a car in the left lane 40 m ahead: not clear')
T.check(not O.laneClear({ { ahead = -20, side = -3.6, v = 20 } }, shift, 25, 70, 19), 'one beside us, 20 m back: not clear')
T.check(O.laneClear({ { ahead = -60, side = -3.6, v = 20 } }, shift, 25, 70, 19), 'one 60 m back at our speed: clear')
T.check(not O.laneClear({ { ahead = -60, side = -3.6, v = 36 } }, shift, 25, 70, 19),
  'one 60 m back closing at 17 m/s: not clear (it needs the room)')

-- Loop 8: Rechtsfahrgebot keep-right lane shift logic
T.check(O.rechtsfahrgebotShift(0, 2, 3.6, false, 'truck', false) == 3.6, 'RHT truck in left lane merges right')
T.check(O.rechtsfahrgebotShift(1, 2, 3.6, false, 'truck', false) == nil, 'RHT truck in rightmost lane stays')
T.check(O.rechtsfahrgebotShift(0, 3, 3.6, false, 'bus', false) == 3.6, 'RHT bus in passing lane merges right')
T.check(O.rechtsfahrgebotShift(1, 3, 3.6, false, 'courier', false) == nil, 'RHT courier allowed in middle lane')
T.check(O.rechtsfahrgebotShift(0, 3, 3.6, false, 'courier', false) == 3.6, 'RHT courier leaves leftmost passing lane')
T.check(O.rechtsfahrgebotShift(0, 2, 3.6, false, 'speeder', false) == 3.6, 'RHT speeder merges right when not passing')
T.check(O.rechtsfahrgebotShift(0, 2, 3.6, false, 'speeder', true) == nil, 'RHT speeder stays left while passing')
T.check(O.rechtsfahrgebotShift(1, 2, 3.6, true, 'truck', false) == -3.6, 'LHT truck in outer passing lane merges left')

-- Polish Pass: dynamic speed-scaled overtake lookahead & 2.0 s post-lane-change cooldown
T.check(O.lookaheadFor(25) == 80, 'lookaheadFor: floors at 80 m at moderate speed')
T.check(math.abs(O.lookaheadFor(50) - 110) < 1e-6, 'lookaheadFor: scales to 110 m at 180 km/h (50 m/s)')
T.check(O.lookaheadFor(56.94) > 125, 'lookaheadFor: > 125 m at 205 km/h Autobahn speed')
T.check(O.laneChangeReady(nil, 100), 'laneChangeReady: true with no prior change')
T.check(not O.laneChangeReady(100, 101.5), 'laneChangeReady: blocked within 2.0 s cooldown')
T.check(O.laneChangeReady(100, 102.0), 'laneChangeReady: ready at >= 2.0 s cooldown')

-- Autobahn stability: suppress forced ai.laneChange impulses on highways and >= 90 km/h (25 m/s) / >= 100 km/h limit
T.check(O.shouldSuppressLaneChange(15, 22, { highway = true }),
  'shouldSuppressLaneChange: suppressed on highway regardless of speed')
T.check(O.shouldSuppressLaneChange(15, 22, { unlimited = true }),
  'shouldSuppressLaneChange: suppressed on unlimited Autobahn')
T.check(O.shouldSuppressLaneChange(25.0, 22, { highway = false }),
  'shouldSuppressLaneChange: suppressed at >= 25 m/s (90 km/h)')
T.check(O.shouldSuppressLaneChange(18.0, 27.7, { highway = false }),
  'shouldSuppressLaneChange: suppressed when road limit >= 27.7 m/s (100 km/h)')
T.check(not O.shouldSuppressLaneChange(16.0, 22.2, { highway = false, unlimited = false }),
  'shouldSuppressLaneChange: active on non-highway rural/urban roads < 90 km/h')

-- End-to-end overtake.update: highway & >= 90 km/h suppress ai.laneChange and enforce ai.driveInLane("on"),
-- while rural/urban < 90 km/h passing remains intact.
do
  local sg = { map = rawget(_G, 'map'), getObjectByID = rawget(_G, 'getObjectByID'), vec3 = rawget(_G, 'vec3') }
  local vecMt
  vecMt = {
    __sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = (a.z or 0) - (b.z or 0) }, vecMt) end,
    __index = {
      length = function(s) return math.sqrt(s.x * s.x + s.y * s.y + (s.z or 0) * (s.z or 0)) end,
      dot = function(a, b) return a.x * b.x + a.y * b.y + (a.z or 0) * (b.z or 0) end,
      normalized = function(s)
        local l = s:length()
        if l < 1e-9 then return setmetatable({ x = 0, y = 0, z = 0 }, vecMt) end
        return setmetatable({ x = s.x / l, y = s.y / l, z = (s.z or 0) / l }, vecMt)
      end,
    },
  }
  vec3 = function(x, y, z) return setmetatable({ x = x, y = y, z = z or 0 }, vecMt) end

  local function runScenario(edgeOpts, passerV, leadV)
    O.reset()
    local edge = {
      inNode = 'a', outNode = 'b', oneWay = true, lanes = '++',
      speedLimit = edgeOpts.limit, inRadius = 3.6, outRadius = 3.6,
      highway = edgeOpts.highway, unlimited = edgeOpts.unlimited,
    }
    local nodes = {
      a = { pos = vec3(0, 0, 0), radius = 3.6, links = { b = edge } },
      b = { pos = vec3(500, 0, 0), radius = 3.6, links = { a = edge } },
    }
    map = {
      getMap = function() return { nodes = nodes } end,
      findClosestRoad = function() return 'a', 'b' end,
    }
    local cmds = {}
    -- Eastbound road (dir = +x, right = -y): right lane centre at y = -1.8 (lat = +1.8)
    local objs = {
      [1] = {
        getActive = function() return true end,
        getPosition = function() return vec3(100, -1.8, 0) end,
        getDirectionVector = function() return vec3(1, 0, 0) end,
        getVelocity = function() return vec3(passerV, 0, 0) end,
        queueLuaCommand = function(_, c) cmds[#cmds + 1] = c end,
      },
      [2] = {
        getActive = function() return true end,
        getPosition = function() return vec3(125, -1.8, 0) end,
        getDirectionVector = function() return vec3(1, 0, 0) end,
        getVelocity = function() return vec3(leadV, 0, 0) end,
        queueLuaCommand = function() end,
      },
    }
    getObjectByID = function(id) return objs[id] end
    O.update(10.0, { [1] = true, [2] = true }, nil, nil, false, nil, nil)
    O.update(13.0, { [1] = true, [2] = true }, nil, nil, false, nil, nil)
    local laneChangeCount, driveInLaneCount = 0, 0
    for _, c in ipairs(cmds) do
      if c:find('ai.laneChange', 1, true) then laneChangeCount = laneChangeCount + 1 end
      if c:find('ai.driveInLane("on")', 1, true) then driveInLaneCount = driveInLaneCount + 1 end
    end
    return laneChangeCount, driveInLaneCount
  end

  local hwyLC, hwyHold = runScenario({ highway = true, unlimited = true, limit = 36.11 }, 20, 15)
  T.check(hwyLC == 0 and hwyHold == 1,
    'overtake.update (highway): suppresses ai.laneChange and enforces ai.driveInLane("on")')

  local fastLC, fastHold = runScenario({ highway = false, unlimited = false, limit = 22.2 }, 26, 16)
  T.check(fastLC == 0 and fastHold == 1,
    'overtake.update (>= 90 km/h): suppresses ai.laneChange and enforces ai.driveInLane("on")')

  local highLimLC, highLimHold = runScenario({ highway = false, unlimited = false, limit = 27.8 }, 20, 15)
  T.check(highLimLC == 0 and highLimHold == 1,
    'overtake.update (limit >= 100 km/h): suppresses ai.laneChange and enforces ai.driveInLane("on")')

  local urbanLC, urbanHold = runScenario({ highway = false, unlimited = false, limit = 22.2 }, 16, 10)
  T.check(urbanLC == 1 and urbanHold == 0,
    'overtake.update (rural/urban < 90 km/h, non-highway): keeps controlled passing intact')

  O.reset()
  for k, val in pairs(sg) do _G[k] = val end
end

T.done('test_overtake')
