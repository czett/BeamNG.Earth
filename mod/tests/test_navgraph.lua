-- luajit mod/tests/test_navgraph.lua  (the server's road graph as the stock map's custom node table)
local T = dofile((arg[0]:match('^(.*)[/\\]') or '.') .. '/testlib.lua')
function vec3(x, y, z) return { x = x, y = y, z = z } end
local N = require('beamngEarth/navgraph')

T.check(N.lanes(2, 1, false) == '-++' and N.lanes(2, 1, true) == '++-' and N.lanes(1, 0, false) == '+',
  'lanes: against first for right-hand traffic')
-- A sub-metre seam on the same carriageway must not force a separate lane adjustment.
do
  local function seam()
    return { nodes = { a = { 0, 0, 0, 10 }, b = { 50, 0, 0, 10 }, c = { 50.34, 0, 0, 10 },
      d = { 100, 0, 0, 10 } }, edges = { { 'a', 'b', 1, 5, 0, 20.62, 1, 10, 10, 30.6 },
      { 'b', 'c', 1, 5, 0, 19.44, 1, 10, 10 }, { 'c', 'd', 1, 5, 0, 19.44, 1, 10, 10 } } }
  end
  local g = seam()
  local ns, count, edges = N.toNodes(g, nil, 0, false)
  T.check(count == 3 and edges == 2 and not ns.b and ns.a.links.c == ns.c.links.a,
    'an isolated short same-lane seam is contracted without disconnecting the road')
  local e = ns.a.links.c
  T.check(e and e.inNode == 'a' and e.outNode == 'c' and e.outPos == ns.c.pos
    and e.outRadius == 10 and e.posted == 30.6 and e.speedLimit == 20.62,
    'the joined incoming edge retains its direction, widths and speed metadata')
  T.check(g.nodes.b ~= nil and g.edges[1][2] == 'b', 'compaction leaves the cached raw graph unchanged')
  local variants = {
    { 'a real junction', function(g) g.nodes.x = { 50, 50, 0, 4 }; g.edges[4] = { 'b', 'x', 1, 1, 0, 10, 1, 4 } end },
    { 'a clipped junction arm', function(g) g.nodes.x = { 500, 50, 0, 4 }; g.edges[4] = { 'b', 'x', 1, 1, 0, 10, 1, 4 } end },
    { 'a signalled junction', function(g) g.signals = { { j = 'b', app = {} } } end },
    { 'a signal approach', function(g) g.signals = { { j = 'd', app = { { 'c' } } } } end },
    { 'a lane-count change', function(g) g.edges[3][4] = 4 end },
    { 'a tapered seam', function(g) g.edges[2][9] = 8 end },
    { 'an isolated speed restriction', function(g) g.edges[2][6] = 5 end },
    { 'an isolated posted limit', function(g) g.edges[2][10] = 5 end },
    { 'a rough segment', function(g) g.edges[2][11] = true end },
    { 'a blocked segment', function(g) g.edges[2][7] = 0 end },
    { 'opposed one-way edges', function(g) g.edges[3][1], g.edges[3][2] = 'd', 'c' end },
    { 'a one-way restriction change', function(g) g.edges[3][3] = 1 - g.edges[3][3] end },
    { 'a genuine corner', function(g) g.nodes.d[2] = 50 end },
    { 'a longer segment', function(g) g.nodes.c[1] = 51.1 end },
  }
  for _, twoWay in ipairs({false, true}) do
    for _, case in ipairs(variants) do
      local g = seam()
      if twoWay then for _, e in ipairs(g.edges) do e[3], e[4], e[5] = 0, 3, 2 end end
      case[2](g)
      local ns = N.toNodes(g, { -100, -100, 200, 200 }, 0, false)
      T.check(ns.b and ns.c and ns.b.links.c, 'preserve ' .. case[1] .. (twoWay and ' on a two-way road' or ''))
    end
  end
  local reversed = seam()
  reversed.edges[1], reversed.edges[3] = reversed.edges[3], reversed.edges[1]
  local ns = N.toNodes(reversed, nil, 0, false)
  T.check(not ns.b and ns.a.links.c and ns.c.links.d, 'edge input order does not change the retained node')
  -- Both driving directions remain legal, including asymmetric lane counts and reversed stored edge direction.
  for _, reverse in ipairs({false, true}) do
    for _, leftHand in ipairs({false, true}) do
      local g = seam()
      for _, e in ipairs(g.edges) do
        e[3], e[4], e[5], e[6], e[10] = 0, 3, 2, 20, nil
        if reverse then e[1], e[2], e[4], e[5] = e[2], e[1], e[5], e[4] end
      end
      local ns, count, edges = N.toNodes(g, nil, 0, leftHand)
      local middle = reverse and 'b' or 'c'
      local e = ns.a and ns.a.links[middle]
      T.check(count == 3 and edges == 2 and e and ns[middle].links.a == e and ns[middle].links.d,
        'a two-way seam preserves connections in both driving directions')
      T.check(e and not e.oneWay and e.lanes == N.lanes(reverse and 2 or 3, reverse and 3 or 2, leftHand)
        and e.inNode == (reverse and middle or 'a') and e.outNode == (reverse and 'a' or middle),
        'two-way lane orientation and stored edge direction survive compaction')
    end
  end
  -- Recorded natural stop: a 1.4 cm rounded seam made the stock AI plan a 0.33 m/s corner on a clear highway.
  local tiny = { nodes = { a = {-2098.96,-2504.48,654.36,3.8}, b = {-2129.23,-2527.20,652.39,3.8},
      c = {-2129.24,-2527.21,652.39,3.8}, d = {-2176.95,-2561.65,649.75,3.8} },
    edges = {{'a','b',0,1,1,27.75,1,3.8},{'b','c',0,1,1,27.78,1,3.8},{'c','d',0,1,1,27.78,1,3.8}} }
  local ns, count, edges = N.toNodes(tiny, nil, 0, false)
  T.check(count == 3 and edges == 2 and not ns.b and ns.a.links.c and ns.c.links.d,
    'the captured two-way rounding seam no longer reaches the vehicle AI')
  -- Changing origin can round that seam to coincident points or an arbitrary centimetre-scale heading.
  for _, twoWay in ipairs({false, true}) do
    for _, offset in ipairs({{0,0,0}, {0,0.01,0}, {0,0.04,0}, {0.01,-0.01,0.01}}) do
      local g = seam(); g.nodes.c = {50+offset[1],offset[2],offset[3],10}
      if twoWay then for _, e in ipairs(g.edges) do e[3],e[4],e[5] = 0,3,2 end end
      local ns, count = N.toNodes(g, nil, 0, false)
      T.check(count == 3 and not ns.b and ns.a.links.c and ns.c.links.d,
        'centimetre-scale rounding cannot turn a continuous road into an AI corner')
    end
    local g = seam(); g.nodes.c = {50,0.06,0,10}
    if twoWay then for _, e in ipairs(g.edges) do e[3],e[4],e[5] = 0,3,2 end end
    T.check(N.toNodes(g,nil,0,false).b ~= nil, 'larger lateral geometry retains the existing heading checks')
    g.nodes.c = {50,0,0,10}; g.nodes.d[2] = 50
    T.check(N.toNodes(g,nil,0,false).b ~= nil, 'coincident points do not remove a genuine road corner')
  end
end
do
  local rg = { nodes = { a = { 0, 0, 0, 4 }, b = { 40, 0, 0, 4 } },
    edges = { { 'a', 'b', 0, 1, 1, 20, 1, 4, nil, nil, false, true } } }
  local rn = N.toNodes(rg, nil, 60, false)
  T.check(rn.a.links.b.rumble == true, 'rumble-line eligibility survives graph decoding')
end

local g = {
  nodes = { a = { 0, 0, 1, 4 }, b = { 50, 0, 1, 4 }, c = { 100, 0, 1, 3 }, far = { 5000, 0, 1, 3 } },
  edges = { { 'a', 'b', 0, 1, 1, 11.2, 0.8, 4 }, { 'b', 'c', 1, 1, 0, 8.9, 0.8, 3 }, { 'c', 'far', 0, 1, 1, 11.2, 1, 3 },
            { 'b', 'a', 0, 1, 1, 11.2, 0.8, 4 } },
}
local nodes, nn, ne, cuts = N.toNodes(g, { -500, -500, 500, 500 }, 60, false)
T.check(nn == 3 and ne == 2 and not nodes.far, 'clipped to the block: the far node and its edge left out')
T.check(#cuts == 1 and cuts[1][1] == 100 and cuts[1][2] == 0, 'the cut: c, whose road to the far node was left out')
-- GitHub #131: a link 6.4 m up in 8 m (a bridge's first node over its junction) is left out; a steep real street not
local steep = { nodes = { j = { 0, 0, 22.7, 4 }, d = { 8, 0, 29.1, 3 }, h = { 0, 30, 33.7, 3 } },
  edges = { { 'j', 'd', 0, 1, 1, 11.2, 1, 3 }, { 'j', 'h', 0, 1, 1, 11.2, 1, 3 } } }
local sn, _, sne = N.toNodes(steep, { -500, -500, 500, 500 }, 60, false)
T.check(sne == 1 and sn.j.links.h and not sn.j.links.d, 'a link steeper than MAX_GRADE left out; 37 % kept: ' .. sne)
-- a halo (route planning past the box): the far node kept, the cut still at the box's edge
do
  local hn, hnn, hne, hcuts = N.toNodes(g, { -500, -500, 500, 500 }, 60, false, nil, 5000)
  T.check(hnn == 4 and hne == 3 and hn.far ~= nil, 'halo: the node past the box kept, its road too')
  T.check(#hcuts == 1 and hcuts[1][1] == 100, 'halo: the cut stays where the box ends (c)')
end
-- the fast roads' halo (Montana's I-94 / I-90, 2026-11-05): a motorway's nodes kept past the box, a street's not
do
  local fg = {
    nodes = { a = { 0, 0, 1, 4 }, b = { 400, 0, 1, 4 }, m = { 700, 0, 1, 4 }, m2 = { 1200, 0, 1, 4 },
              s = { 400, 300, 1, 3 }, s2 = { 700, 300, 1, 3 } },
    edges = { { 'a', 'b', 1, 2, 0, 29.1, 1, 4 }, { 'b', 'm', 1, 2, 0, 29.1, 1, 4 }, { 'm', 'm2', 1, 2, 0, 29.1, 1, 4 },
              { 'b', 's', 0, 1, 1, 11.2, 0.8, 3 }, { 's', 's2', 0, 1, 1, 11.2, 0.8, 3 } },
  }
  local box = { -500, -500, 500, 500 }
  local fn, _, _, fcuts = N.toNodes(fg, box, 60, false, nil, 0, 650)   -- (the halo when on: FAST_HALO_M is 0 by default)
  T.check(fn.m ~= nil and fn.m2 == nil, 'fast halo: the motorway node 200 m past the box kept, not one 700 m past')
  T.check(fn.b.links.m ~= nil, 'fast halo: its road too')
  T.check(fn.s2 == nil, 'fast halo: a street node past the box left out')
  local bn = N.toNodes(fg, box, 60, false, nil, 0, 0)
  T.check(bn.m == nil, 'no fast halo: the motorway ends at the box')
  T.check(#fcuts >= 1 and fcuts[1][1] <= 440, 'fast halo: the cut stays at the box')
end
-- a respawned car launched (PR #728's spawn velocity): at LAUNCH_SHARE of its road's limit, along a one-way road only
-- its way, not at a junction, not facing off the road, not on a slow street
T.check(math.abs(N.launchSpeed(29, 1.0, true, false) - 29 * N.LAUNCH_SHARE) < 1e-9, 'launch: 90 % of 65 mph')
T.check(N.launchSpeed(29, -1.0, true, false) == nil, 'launch: not against a one-way road')
T.check(N.launchSpeed(29, -1.0, false, false) ~= nil, 'launch: either way on a two-way road')
T.check(N.launchSpeed(29, 0.5, false, false) == nil, 'launch: not when facing off the road (60 degrees)')
T.check(N.launchSpeed(29, 1.0, true, true) == nil, 'launch: not at a junction')
T.check(N.launchSpeed(6.7, 1.0, false, false) == nil, 'launch: not on a 15 mph street')
local cmd = N.spawnVelocityCommand(26.1)
T.check(cmd and cmd:find('thrusters.applyVelocity', 1, true) and cmd:find('beamngEarth_spawnMotion', 1, true)
  and cmd:find('26.100', 1, true), 'launch: the vehicle command pushes the car and spins its wheels')
T.check(N.spawnVelocityCommand(0) == nil and N.spawnVelocityCommand(120) == nil, 'launch: no command for 0 or 120 m/s')
-- oncoming traffic (I-94, 2026-11-05): a respawn spot on the other carriageway, 26 m left of an eastbound player
do
  local function divided(x, y)          -- eastbound carriageway at y = 0, westbound at y = 26 (one-way roads)
    if math.abs(y) <= math.abs(y - 26) then return { dist = math.abs(y), dx = 1, dy = 0, oneWay = true } end
    return { dist = math.abs(y - 26), dx = -1, dy = 0, oneWay = true }
  end
  local box = { -600, -600, 600, 600 }
  local x, y, dx, dy = N.oncomingSpot(0, 0, 1, 0, box, false, divided)
  T.check(x and x > 100 and math.abs(y - 26) <= N.ONCOMING_ON_M and dx == -1 and dy == 0,
    'oncoming: a spot on the westbound carriageway ahead, facing the player: ' .. tostring(x) .. ',' .. tostring(y))
  local function undivided(x, y) return { dist = math.abs(y), dx = 1, dy = 0, oneWay = false } end
  T.check(N.oncomingSpot(0, 0, 1, 0, box, false, undivided) == nil, 'oncoming: no other carriageway, none')
  T.check(N.oncomingSpot(0, 0, 1, 0, { -100, -600, 150, 600 }, false, divided) == nil,
    'oncoming: none past the block\'s edge')
  local lx, ly = N.oncomingSpot(0, 0, 1, 0, box, true, function(x, y)
    if math.abs(y) <= math.abs(y + 26) then return { dist = math.abs(y), dx = 1, dy = 0, oneWay = true } end
    return { dist = math.abs(y + 26), dx = -1, dy = 0, oneWay = true }
  end)
  T.check(lx and math.abs(ly + 26) <= N.ONCOMING_ON_M, 'oncoming, left-hand traffic: the other carriageway is to the right')
end
-- GitHub #353: a car ahead of a player on the move, going its way, is not respawned for the cut ahead
T.check(N.followsPlayer({ x = 200, y = 0 }, { x = 1, y = 0 }, { x = 0, y = 0 }, { x = 30, y = 0 }), 'ahead, same way')
T.check(not N.followsPlayer({ x = -200, y = 0 }, { x = 1, y = 0 }, { x = 0, y = 0 }, { x = 30, y = 0 }), 'behind: not')
T.check(not N.followsPlayer({ x = 200, y = 0 }, { x = -1, y = 0 }, { x = 0, y = 0 }, { x = 30, y = 0 }), 'oncoming: not')
T.check(not N.followsPlayer({ x = 200, y = 0 }, { x = 1, y = 0 }, { x = 0, y = 0 }, { x = 2, y = 0 }), 'player slow: not')
T.check(N.followsPlayer({ x = 200, y = 0 }, { x = 1, y = 0 }, { x = 0, y = 0 }, { x = 30, y = 0 }, 31),
  'ahead, as fast: follows')
T.check(not N.followsPlayer({ x = 200, y = 0 }, { x = 1, y = 0 }, { x = 0, y = 0 }, { x = 25, y = 0 }, 31),
  'ahead and faster: outruns the graph, not following (GitHub #855)')
T.check(N.stopReach(31) > 200 and N.stopReach(10) < 60 + 1, 'a dead end seen as far as the car needs to stop')
T.check(N.headingToCut(60, 0, 1, 0, cuts, 60), 'a car 40 m from the cut, heading for it')
T.check(not N.headingToCut(60, 0, -1, 0, cuts, 60), '... heading away from it: not')
T.check(not N.headingToCut(60, 0, 0, 1, cuts, 60), '... across: not')
T.check(not N.headingToCut(-20, 0, 1, 0, cuts, 60), '... 120 m from it: not yet')
T.check(N.headingToCut(-20, 0, 1, 0, cuts, 30 * N.CUT_S), '... at 67 mph: from 120 m')
-- GitHub #855: a car that reached the cut no longer heads for it — stopped at the dead end at an angle, or turning
-- round across the road — and is respawned at once, not after STUCK_S
T.check(N.nearCut(95, 3, cuts, N.CUT_NEAR_M), 'a car 6 m from the cut is near it, whichever way it points')
T.check(not N.nearCut(0, 0, cuts, N.CUT_NEAR_M), '... 100 m away: not')
T.check(N.cutStopped(0.2, 0, 0.98, false, true), 'stopped facing the dead end')
T.check(N.cutStopped(0.2, 0, 0.1, false, false), 'stopped mid-turn, across its road')
T.check(N.cutStopped(0.3, 0, -0.9, true, false), 'stood turned round on a one-way road')
T.check(not N.cutStopped(0.2, 0, 0.98, false, false),
  'stopped aligned with its road, facing past the cut (a red light on a through road): left alone')
T.check(not N.cutStopped(0.2, 0, nil, nil, false), 'stopped off any road the map knows, not facing a cut: left alone')
T.check(not N.cutStopped(0.3, 0, -0.9, false, false),
  'stood turned round on a two-way road: reads as ordinary oncoming traffic (uncaught, by design)')
T.check(N.cutStopped(2.0, 1.9, 0.2, false, false), 'crawling through the turn, across its road')
T.check(N.cutStopped(4, -3.8, nil, nil, false), 'backing through it')
T.check(N.cutStopped(6, 5.5, 0.2, false, false), 'turning across the road at speed (78 degrees off its axis)')
T.check(N.cutStopped(6, 5.5, -0.9, true, false), 'driving along a one-way road against it')
T.check(not N.cutStopped(8, 7.9, 0.95, false, false), 'driving on along the road: left alone')
T.check(not N.cutStopped(8, 7.9, -0.95, false, false), 'back the other way on a two-way road: left alone')
-- a long frame (0.3-5 s hitches in session logs) widens the window by the missed time at the car's speed
T.near(N.cutReach(15, false, 0), 75, 1e-9, 'reach at 15 m/s: the stopping distance')
T.near(N.cutReach(15, false, 4.5), 142.5, 1e-9, 'a 5 s frame: widened by the missed 4.5 s at 15 m/s')
T.near(N.cutReach(0, true, 0), N.CUT_FRESH_M, 1e-9, 'a fresh car standing: CUT_FRESH_M as before')
T.check(not N.headingToCut(-40, 0, 1, 0, cuts, N.cutReach(20, false, 0)),
  'a car 140 m from the cut at 20 m/s: outside the normal window')
T.check(N.headingToCut(-40, 0, 1, 0, cuts, N.cutReach(20, false, 2)),
  '... after a 2.5 s frame: the widened window still catches it')
-- built over several frames (navgraph's buildNodes: a coroutine pausing every yieldEvery items): the same tables
do
  local co = coroutine.create(function() return { N.toNodes(g, { -500, -500, 500, 500 }, 60, false, 2) } end)
  local pauses, res = 0, nil
  while true do
    local ok, r = coroutine.resume(co)
    T.check(ok, 'resumes cleanly')
    if coroutine.status(co) == 'dead' then res = r break end
    pauses = pauses + 1
  end
  T.check(pauses >= 3, 'it paused along the way: ' .. pauses)
  T.check(res[2] == nn and res[3] == ne and #res[4] == #cuts and res[1].a.links.b.speedLimit == 11.2
    and not res[1].far, 'the same nodes, edges and cuts as in one go')
end
local ab = nodes.a.links.b
T.check(ab and nodes.b.links.a == ab, 'one edge table shared by both ends (double-sided)')
T.check(ab.inNode == 'a' and ab.outNode == 'b' and ab.inPos == nodes.a.pos and ab.outPos == nodes.b.pos, 'in / out nodes and positions')
T.check(ab.speedLimit == 11.2 and ab.lanes == '-+' and not ab.oneWay and ab.inRadius == 4 and ab.outRadius == 4, 'edge fields')
local bc = nodes.b.links.c
do      -- a road narrowing to a tunnel's portal: the edge's end radii (e[8] at its in node, e[9] at its out node)
  local g2 = { nodes = { p = { 0, 0, 0, 6 }, q = { 50, 0, 0, 3 } }, edges = { { 'p', 'q', 0, 1, 1, 20, 1, 6, 3 } } }
  local n2 = N.toNodes(g2, nil, 60, false)
  local pq = n2.p.links.q
  T.check(pq.inRadius == 6 and pq.outRadius == 3, 'per-end radii: ' .. tostring(pq.inRadius) .. ' ' .. tostring(pq.outRadius))
end
T.check(bc.oneWay and bc.lanes == '+' and bc.inNode == 'b', 'one-way: in -> out is the allowed direction')
T.check(N.inside(nil, 1e9, 0, 60) and not N.inside({ 0, 0, 100, 100 }, 50, 50, 60), 'inside')

-- a new signals table keeps the junctions a car may still remember (ai.lua reads them unchecked)
local got
mapmgr = { signalsData = { j1 = { a = { { action = 2 } } }, j2 = { b = { { action = 0 } }, c = { { action = 1 } } } },
           setSignals = function(d) got = d; mapmgr.signalsData = d end }
local f = loadstring(N.setSignalsLua('{ j2 = { b = { { action = 3 } } }, j3 = { d = { { action = 0 } } } }'))
f()
T.check(got.j3.d[1].action == 0 and got.j2.b[1].action == 3, 'the new signals')
T.check(got.j1.a[1].action == 2 and got.j2.c[1].action == 1, 'old junctions / approaches kept')
mapmgr = { setSignals = function(d) got = d end }
loadstring(N.setSignalsLua('{ j9 = {} }'))()
T.check(got.j9 and not got.j1, 'no old table: the new one as is')
T.check(not N.stuck(nil, 100, 500), 'moving: not stuck')
T.check(not N.stuck(60, 100, 500), 'still 40 s: a long signal, not stuck yet')
T.check(N.stuck(50, 100, 500) and not N.stuck(50, 100, 20), 'still 50 s: stuck, unless next to the player')
local o = { trafficMode = 'enabled', trafficParked = 'enabled', trafficPolice = 'disabled', trafficAmount = -1,
            trafficParkedAmount = 10 }
local c = N.takeChoice(o)
T.check(c.traffic and c.parked and not c.police and c.parkedAmount == 10, 'the configurator choice taken')
T.check(o.trafficMode == 'disabled' and o.trafficParked == 'disabled', 'freeroam spawns nothing before our roads')
T.check(N.takeChoice(o).traffic, 'taken twice (level start runs twice): the first choice kept')
N.restoreChoice()
T.check(o.trafficMode == 'enabled' and o.trafficParked == 'enabled', 'the player\'s options back afterwards')
T.check(not N.takeChoice({ trafficMode = 'fromSetting', trafficParked = 'disabled' }).traffic, 'fromSetting: off')
T.check(not N.takeChoice(nil).parked, 'no freeroam: off (the radial menu still works)')
settings = { getValue = function(k) if k == 'trafficParkedVehicles' then return false end end }
T.check(not N.takeChoice({ trafficMode = 'enabled', trafficParked = 'enabled' }).parked,
  'traffic and parked chosen, the parked vehicles setting off: none (as stock freeroam, GitHub #320)')
N.restoreChoice()
T.check(N.takeChoice({ trafficMode = 'disabled', trafficParked = 'enabled' }).parked, 'parked only: the setting does not apply')
N.restoreChoice()
settings = nil
T.check(math.abs(N.boxMoved({ -708, -452, 196, 452 }, { -1092, -452, -188, 452 }) - 384) < 1e-9,
  'the block moved 384 m: measured between the boxes\' centres')
T.check(N.boxMoved(nil, { 0, 0, 1, 1 }) == 0 and N.boxMoved({}, { 0, 0, 1, 1 }) == 0, 'no box yet: not moved')
T.check(384 >= N.RECLIP_M and 128 < N.RECLIP_M, 'a 384 m move re-clips the graph, one step of 128 m does not')
-- GitHub #353: at motorway speed a respawned car goes ahead, short of the block's edge guard; slower: behind (nil)
do
  local box = { -256, -256, 256, 256 }
  local x, y, dx, dy, lo, hi = N.aheadSpot(0, 0, 30, 0, box)
  T.check(x == 0 and dx == 1 and dy == 0 and lo == N.AHEAD_M[1] and hi == math.min(N.AHEAD_M[2], 256 - N.GUARD_M - 20),
    'aheadSpot: 67 mph east, ahead along the way: ' .. tostring(hi))
  T.check(N.aheadSpot(0, 0, 10, 0, box) == nil, 'aheadSpot: 22 mph: behind the camera as before')
  T.check(N.aheadSpot(150, 0, 30, 0, box) == nil, 'aheadSpot: near the block edge ahead: no room, behind')
  local _, _, _, _, _, h2 = N.aheadSpot(0, 0, 0, -30, box)
  T.check(h2 and h2 <= 256 - N.GUARD_M - 20, 'aheadSpot: south, limited by the box too')
end

-- a rebase moves the graph into the new anchor (core finishRebase): kept and applied again at once
do
  N.enabled = true
  local jd, rf = rawget(_G, 'jsonDecode'), rawget(_G, 'readFile')
  jsonDecode = function() return { nodes = { a = { 100, 200, 5, 3 }, b = { 150, 200, 5, 3 } },
                                   edges = { { 'a', 'b', 0, 1, 1, 13, 1, 3 } }, lines = { { 10, 20, 30, 40, 1 } } } end
  readFile = function() return '{}' end
  T.check(N.onMessage({ anchorId = 7, path = 'x', serial = 1 }, 7), 'a graph for anchor 7')
  local xf = { apply = function(_, x, y, z) return x - 1000, y + 50, z - 2 end }
  T.check(N.transform(xf, 8), 'moved into anchor 8')
  local g = N.currentGraph()
  T.check(g.anchor == 8 and g.nodes.a[1] == -900 and g.nodes.a[2] == 250 and g.nodes.a[3] == 3 and g.nodes.a[4] == 3,
    'its nodes in the new frame, radius kept')
  T.check(g.lines and g.lines[1][1] == -990 and g.lines[1][2] == 70 and g.lines[1][3] == -970 and g.lines[1][5] == 1,
    'its tunnel lines (the minimap) too')
  T.check(not N.transform(nil, 9) and N.currentGraph().anchor == 8, 'no transform: nothing')
  jsonDecode, readFile = jd, rf
end

-- adaptive traffic amount (PR #728 / #773): the graph's trafficProfile kept through a rebase; the target capped at the
-- player's amount, whole cars, one car a step; off by default
do
  T.check(N.ADAPTIVE == false, 'adaptive traffic off by default')
  T.check(N.adaptiveTarget(4.4, 10) == 4 and N.adaptiveTarget(4.6, 10) == 5 and N.adaptiveTarget(64, 12) == 12
    and N.adaptiveTarget(-1, 10) == 0 and N.adaptiveTarget(nil, 10) == nil and N.adaptiveTarget(0 / 0, 10) == nil,
    'adaptive target: rounded, capped at the player\'s amount, never negative')
  T.check(N.adaptiveStep(12, 7) == 11 and N.adaptiveStep(3, 8) == 4 and N.adaptiveStep(5, 5) == 5,
    'adaptive step: one car at a time')
  local jd, rf = rawget(_G, 'jsonDecode'), rawget(_G, 'readFile')
  jsonDecode = function() return { nodes = { a = { 0, 0, 5, 3 }, b = { 50, 0, 5, 3 } },
    edges = { { 'a', 'b', 0, 1, 1, 13, 1, 3, nil, nil, true } }, trafficProfile = { target = 6.5, band = 'suburban' } } end
  readFile = function() return '{}' end
  T.check(N.onMessage({ anchorId = 3, path = 'x', serial = 2 }, 3) and N.currentGraph().trafficProfile.target == 6.5,
    'the graph keeps its traffic profile')
  local roughNodes = N.toNodes(jsonDecode(), nil, 60, false)
  T.check(roughNodes.a.links.b.rough == true, 'the graph keeps the rough-road traffic speed flag')
  N.transform({ apply = function(_, x, y, z) return x, y, z end }, 4)
  T.check(N.currentGraph().trafficProfile.band == 'suburban', '... through a rebase')
  local st = N.trafficStatus()
  T.check(st.enabled == false and st.profile and st.profile.target == 6.5, 'traffic status: off, the profile shown')
  N.setAdaptive(true)
  T.check(N.ADAPTIVE == true and N.trafficStatus().enabled, 'the setting turns it on')
  N.setAdaptive(false)
  -- the stock traffic's ceiling moved toward the profile's 6.5 -> 7 cars, one every ADAPTIVE_STEP_S
  local gt0, log0 = rawget(_G, 'gameplay_traffic'), rawget(_G, 'log')
  local vars = { activeAmount = 10 }
  gameplay_traffic = { getState = function() return 'on' end, getTrafficVars = function() return vars end,
    getNumOfTraffic = function() return 10 end, setActiveAmount = function(n) vars.activeAmount = n end,
    getTrafficData = function() return {} end }
  if not log0 then log = function() end end
  N.takeChoice({ trafficMode = 'enabled', trafficParked = 'disabled' })
  N._startTraffic()
  N._adaptiveTick(100)
  T.check(vars.activeAmount == 10, 'off: the player\'s amount untouched')
  N.setAdaptive(true)
  N._adaptiveTick(101)
  T.check(vars.activeAmount == 9, 'on: one car down toward the target: ' .. tostring(vars.activeAmount))
  N._adaptiveTick(103)
  T.check(vars.activeAmount == 9, '... not again within ADAPTIVE_STEP_S')
  for t = 106, 140, 5 do N._adaptiveTick(t) end
  T.check(vars.activeAmount == 7 and N.trafficStatus().target == 7, 'settled at the target: ' .. tostring(vars.activeAmount))
  vars.activeAmount = 0                       -- (the player toggled the traffic off)
  for t = 146, 170, 5 do N._adaptiveTick(t) end
  T.check(vars.activeAmount == 0 and N.trafficStatus().paused, 'toggled off: left off')
  vars.activeAmount = 4                       -- (on again with another amount: theirs now, under the target)
  for t = 176, 200, 5 do N._adaptiveTick(t) end
  T.check(vars.activeAmount == 4 and N.trafficStatus().base == 4, 'the player\'s new amount caps it: ' ..
    tostring(vars.activeAmount))
  vars.activeAmount = 10
  for t = 206, 230, 5 do N._adaptiveTick(t) end
  T.check(vars.activeAmount == 7, 'raised again: back down to the target')
  N.setAdaptive(false)
  N._adaptiveTick(240)
  T.check(vars.activeAmount == 10, 'off again: the player\'s amount back: ' .. tostring(vars.activeAmount))
  N._adaptiveTick(245)
  T.check(vars.activeAmount == 10 and N.trafficStatus().base == nil, 'and left alone')
  N.reset()
  gameplay_traffic = gt0
  if not log0 then log = nil end
  jsonDecode, readFile = jd, rf
end

-- regional traffic vehicles: the road rules' country -> the stock levels' region, the game's own filters; none
-- elsewhere or without smart selections (the game's own group then)
do
  T.check(N.regionOf('US') == 'northAmerica' and N.regionOf('de') == 'europe' and N.regionOf('JP') == 'asiaPacific'
    and N.regionOf('BR') == nil and N.regionOf(nil) == nil, 'regions by country')
  local set = { trafficSmartSelections = true, trafficSimpleVehicles = false, trafficAllowMods = false }
  local get = function(k) return set[k] end
  local p, region = N.regionalGroupParams('DE', get)
  T.check(region == 'europe' and p.filters.Region.europe == 1 and p.filters.Region.default == 1
    and p.filters['Config Type'].Police == 0 and p.country == 'Germany' and p.minPop == 50, 'europe group params')
  T.check(N.regionalGroupParams('NL', get).country == 'default', 'a country the game has no name for: default')
  T.check(N.regionalGroupParams('BR', get) == nil, 'no region: the game\'s own group')
  set.trafficSmartSelections = false
  T.check(N.regionalGroupParams('US', get) == nil, 'smart selections off: the game\'s own group')
  set.trafficSmartSelections, set.trafficSimpleVehicles = true, true
  local ps, rs = N.regionalGroupParams('US', get)
  T.check(rs == 'northAmerica' and ps.filters.Type.proptraffic == 1 and ps.filters.Type.car == nil
    and ps.filters.Region.northAmerica == 1 and ps.minPop == 0 and ps.allConfigs, 'simple vehicles: of the region too')
  set.trafficSimpleVehicles, set.trafficAllowMods = false, true
  local pm = N.regionalGroupParams('US', get)
  T.check(pm.allMods and pm.filters.Type.automation == 1 and pm.minPop == 0, 'mods allowed: as the game')
end

-- GitHub #855 / #72 / #279 end to end: the guard respawns a car stopped or turning at a cut at once, honours
-- COOLDOWN_S, leaves cars far from cuts alone, and a long frame cannot carry a car past the catch window
do
  N.reset()
  N.takeChoice(nil)
  N.enabled = true
  local names = { 'jsonDecode', 'readFile', 'writeFile', 'jsonEncode', 'map', 'be', 'path',
                  'getObjectByID', 'gameplay_traffic' }
  local sg = {}
  for _, k in ipairs(names) do sg[k] = rawget(_G, k) end
  local log0 = rawget(_G, 'log')
  if not log0 then log = function() end end
  local clock0 = os.clock
  local now = 1000
  os.clock = function() return now end
  local function v(x, y, z)
    return { x = x, y = y, z = z or 0, length = function(s) return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) end }
  end
  -- c is a junction: the a-b-c road loses its leg to `far` (the cut), and the c-s road runs through north
  jsonDecode = function() return { nodes = { a = { 0, 0, 1, 4 }, b = { 50, 0, 1, 4 }, c = { 100, 0, 1, 3 },
      far = { 5000, 0, 1, 3 }, s = { 100, 200, 1, 4 } },
    edges = { { 'a', 'b', 0, 1, 1, 11.2, 0.8, 4 }, { 'b', 'c', 0, 1, 1, 11.2, 0.8, 3 },
              { 'c', 'far', 0, 1, 1, 11.2, 1, 3 }, { 'c', 's', 0, 1, 1, 11.2, 0.8, 4 } } } end
  readFile = function() return '{}' end
  writeFile = function() end
  jsonEncode = function() return '{}' end
  path = { getPathLevelInfo = function() return '' end }
  local world = {}
  map = { reset = function(n) world.nodes = n end, getMap = function() return world end,
          findClosestRoad = function(p) if p.x > 97 and p.y > 5 then return 'c', 's' end return 'b', 'c' end }
  be = { getPlayerVehicleID = function() return -1 end, queueAllObjectLua = function() end,
         sendToMailbox = function() end }
  local cars, ports = {}, {}
  getObjectByID = function(id)
    local c = cars[id]
    if not c then return nil end
    return { getActive = function() return true end, getPosition = function() return c.pos end,
             getVelocity = function() return c.vel end, getDirectionVector = function() return c.dir end }
  end
  gameplay_traffic = {
    getState = function() return 'on' end,
    getTrafficData = function()
      local d = {}
      for id in pairs(cars) do d[id] = { isAi = true } end
      return d
    end,
    getTrafficList = function()
      local l = {}
      for id in pairs(cars) do l[#l + 1] = id end
      return l
    end,
    forceTeleport = function(id) ports[id] = (ports[id] or 0) + 1 end,
  }
  local box = { -500, -500, 500, 500 }
  T.check(N.onMessage({ anchorId = 1, path = 'x', serial = 1 }, 1), 'guard: a graph whose clip cuts c at (100, 0)')
  N.update(1, box)              -- applies the graph; the guard runs from the next frame on
  T.check(N.status().cuts == 1, 'guard: applied, one cut')
  cars[101] = { pos = v(95, 2), vel = v(0, 0), dir = v(0, 1) }      -- stopped at the dead end, turned off it
  cars[102] = { pos = v(92, -2), vel = v(-3, 0), dir = v(1, 0) }    -- backing through its turn, nose at the cut
  cars[103] = { pos = v(0, 0), vel = v(0, 0), dir = v(1, 0) }       -- stopped far from any cut (a signal queue)
  now = 1001
  N.update(1, box)
  T.check(ports[101] == nil and ports[102] == nil, 'guard: both just placed (FRESH_S): not yet')
  now = 1007                    -- past FRESH_S; stood 6 s, far less than STUCK_S = 45
  N.update(1, box)
  T.check(ports[101] == 1, 'guard: stopped at the cut, turned off it: respawned at once, not after STUCK_S')
  T.check(ports[102] == 1, 'guard: turning round at the cut (backing): respawned at once')
  T.check(ports[103] == nil, 'guard: a car stopped far from any cut: untouched')
  now = 1009                    -- within COOLDOWN_S of those respawns
  N.update(1, box)
  T.check(ports[101] == 1 and ports[102] == 1, 'guard: the same car within COOLDOWN_S: not again')
  now = 1016                    -- past COOLDOWN_S, still wedged at the cut
  N.update(1, box)
  T.check(ports[101] == 2, 'guard: still at the cut past COOLDOWN_S: again')
  -- a long frame: a car outside the window drives to the cut, stops and turns during the 5 s the guard missed.
  -- Before the lag widening, the 110 m it covered read as a respawn's jump (JUMP_M = 30): seenAt reset, the car
  -- "fresh" and uncaught for FRESH_S more, and headingToCut false once turned — it stood blocking the road.
  cars[104] = { pos = v(-30, 0), vel = v(20, 0), dir = v(1, 0) }
  now = 1017
  N.update(1, box)              -- first seen: 130 m from the cut, outside cutReach(20 m/s) = 110 m (+ a frame's lag)
  T.check(ports[104] == nil, 'guard: a car 130 m from the cut at 20 m/s: outside the window')
  cars[104].pos, cars[104].vel, cars[104].dir = v(80, 0), v(0.3, 0.4), v(0, 1)
  now = 1022                    -- one 5 s frame later: it reached the cut, stopped and began its turn meanwhile
  N.update(1, box)
  T.check(ports[104] == 1, 'guard: a 5 s frame carried it to the cut, stopped and turning: still caught at once')
  -- a car braking for a red light on the THROUGH road of the cut junction, aligned with its road and facing past
  -- the dead end, is not the cut's and stays put
  cars[105] = { pos = v(100, 25), vel = v(0, 8), dir = v(0, 1) }   -- northbound on the c -> s road, at the stop line
  now = 1023
  N.update(1, box)              -- first seen
  now = 1029                    -- past FRESH_S
  N.update(1, box)
  T.check(ports[105] == nil, 'guard: driving the through road past the cut junction: untouched')
  cars[105].vel = v(0, 2)       -- braking for the light, under CUT_NEAR_MS
  now = 1030
  N.update(1, box)
  cars[105].vel = v(0, 0)       -- stopped at the light, 25 m from the cut node
  now = 1031
  N.update(1, box)
  T.check(ports[105] == nil, 'guard: stopped at a red light on the through road, facing past the dead end: stays')
  -- a car stopped FACING the dead end is still taken at once (headingToCut's facing fallback, as before)
  cars[106] = { pos = v(93, 0), vel = v(0, 0), dir = v(1, 0) }
  now = 1032
  N.update(1, box)
  T.check(ports[106] == 1, 'guard: stopped facing the dead end: respawned at once')
  -- paused: nothing is taken while the player sits in the menu (as the stuck and launch paths)
  local tc0 = rawget(table, 'clear')
  table.clear = tc0 or function(t) for k in pairs(t) do t[k] = nil end end
  simTimeAuthority = { getPause = function() return true end }
  local p101 = ports[101]
  now = 1047                    -- car 101 still wedged at the cut, past COOLDOWN_S of its last respawn
  N.update(1, box)
  T.check(ports[101] == p101, 'guard: paused: the car wedged at the cut is left alone')
  simTimeAuthority = nil
  now = 1048
  N.update(1, box)
  T.check(ports[101] == p101 + 1, 'guard: unpaused: taken again')
  table.clear = tc0
  for _, k in ipairs(names) do _G[k] = sg[k] end
  if not log0 then log = nil end
  os.clock = clock0
  N.reset()
end

-- Loop 8: Smart Regional Traffic Overhaul tests
-- 1. Highway & unlimited Autobahn edge metadata decoding + compaction boundary preservation
do
  local hg = {
    nodes = { a = { 0, 0, 0, 7 }, b = { 50, 0, 0, 7 }, c = { 50.3, 0, 0, 7 }, d = { 100, 0, 0, 7 } },
    edges = {
      { 'a', 'b', 1, 3, 0, 36.11, 1, 7, nil, nil, false, false, 2 },
      { 'b', 'c', 1, 3, 0, 36.11, 1, 7, nil, nil, false, false, 1 },
      { 'c', 'd', 1, 3, 0, 36.11, 1, 7, nil, nil, false, false, 1 },
    },
  }
  local hn = N.toNodes(hg, nil, 0, false)
  T.check(hn.a.links.b.highway == true and hn.a.links.b.unlimited == true and hn.a.links.b.lanesOut == 3,
    'autobahn unlimited flag (e[13]==2) and lanesOut survive decoding')
  T.check(hn.b and hn.b.links.c and hn.b.links.c.highway == true and hn.b.links.c.unlimited == false,
    'posted highway flag (e[13]==1) preserved and unlimited/posted boundary is not compacted')
end

-- 2. Deterministic regional vehicle archetype & livery roster builder
do
  local pool = {
    { model = 'citybus', config = 'hero', name = 'Hero JATO Bus' },
    { model = 'citybus', config = 'city', name = 'City Transit Bus' },
    { model = 'wentward', config = 'metro_shuttle', name = 'Metro Shuttle' },
    { model = 'van', config = 'h15_cargo', name = 'H15 Cargo Van' },
    { model = 'van', config = 'h25_delivery', name = 'H25 Delivery' },
    { model = 'md_series', config = 'box_courier', name = 'MD Courier Box' },
    { model = 'boxtruck', config = 'parcel_upfit', name = 'Parcel Box Truck' },
    { model = 'semi', config = 't75_hauler', name = 'T75 Hauler' },
    { model = 'md_series', config = 'md70_flatbed', name = 'MD70 Flatbed' },
    { model = 'etk800', config = '856_ttsport', name = 'ETK 856 ttSport' },
    { model = 'etkc', config = 'kc6t_sport', name = 'ETK K-Series Sport' },
    { model = 'scintilla', config = 'gt_coupe', name = 'Scintilla GT' },
    { model = 'etk800', config = 'polizei', name = 'ETK 800 Polizei' },
    { model = 'vivace', config = 'police', name = 'Vivace Police' },
    { model = 'etk800', config = '854d_wagon', name = 'ETK 854d' },
    { model = 'vivace', config = '160_diesel', name = 'Vivace 160d' },
    { model = 'covet', config = 'dx_hatch', name = 'Covet DX' },
    { model = 'pessima', config = 'lx_sedan', name = 'Pessima LX' },
  }
  local rOff = N.buildTrafficRoster('europe', pool, false, { size = 16, urban = true })
  local rOff2 = N.buildTrafficRoster('DE', pool, false, { size = 16, urban = true })
  T.check(#rOff == #rOff2 and rOff[1].model == rOff2[1].model and rOff[1].config == rOff2[1].config,
    'buildTrafficRoster: deterministic across region/country alias calls')
  T.check(rOff.counts.police == 0, 'buildTrafficRoster: strict Police == 0 when deEnabled == false')
  T.check(rOff.counts.bus >= 1 and rOff.counts.bus <= 2, 'buildTrafficRoster: 1-2 city buses in urban pool')
  T.check(rOff.counts.courier >= 2, 'buildTrafficRoster: courier/delivery vans populated')
  T.check(rOff.counts.truck >= 1, 'buildTrafficRoster: commercial trucks populated')
  T.check(rOff.counts.speeder >= 1 and rOff.counts.speeder <= 2, 'buildTrafficRoster: 1-2 speeders assigned')
  T.check(rOff.counts.commuter >= 2, 'buildTrafficRoster: commuters fill remaining pool')
  local sawHero, sawTransitBus, sawCourierLivery, sawPolice = false, false, false, false
  for _, e in ipairs(rOff) do
    if e.config == 'hero' then sawHero = true end
    if e.archetype == 'bus' and (e.config == 'city' or e.config == 'metro_shuttle') then sawTransitBus = true end
    if e.archetype == 'courier' and e.liveryTag ~= nil and e.hasDeliveryLivery == true and e.paint == nil then
      sawCourierLivery = true
    end
    if e.archetype == 'police' or tostring(e.config):find('poliz') or tostring(e.config):find('police') then
      sawPolice = true
    end
  end
  T.check(not sawHero and sawTransitBus, 'buildTrafficRoster: prefers transit/city bus liveries and excludes hero/jato')
  T.check(sawCourierLivery, 'buildTrafficRoster: preserves vanilla delivery liveries (paint == nil) on delivery vans')
  T.check(not sawPolice, 'buildTrafficRoster: zero police entries leak when deEnabled == false')

  local rOn = N.buildTrafficRoster('europe', pool, true, { size = 16, urban = true })
  T.check(rOn.counts.police >= 1, 'buildTrafficRoster: includes EU police patrols when deEnabled == true')
end

-- 2b. Mod-Aware Delivery Vehicles & 3-Tier Vanilla Livery Fallbacks
do
  -- Tier 1: Full mod environment (scout, evvan/ecv, hhl/bps/rrt/nile/postit/fdc skins)
  local modPool = {
    { model = 'scout', config = 'scout_hhl', name = 'Gavril Scout HHL Delivery' },
    { model = 'scout', config = 'scout_postit', name = 'Gavril Scout Post-It' },
    { model = 'evvan', config = 'ecv_nile', name = 'Bruckell ECV Nile Delivery' },
    { model = 'ecv', config = 'ecv_bps', name = 'Bruckell ECV BPS' },
    { model = 'van', config = 'h25_rrt', name = 'H25 RRT Parcel' },
    { model = 'pickup', config = 'd45_fdc_delivery', name = 'D45 FDC Delivery' },
    { model = 't_series', config = 't75_hhl_freight', name = 'T75 HHL Freight' },
    { model = 'van', config = 'deliverytruck', name = 'H45 Delivery Truck' },
    { model = 'van', config = 'h15_cargo', name = 'H15 Cargo Van' },
    { model = 't_series', config = 't75_hauler', name = 'T75 Hauler' },
    { model = 'pickup', config = 'd15_v8_4wd', name = 'D15 V8 4WD' },
    { model = 'etk800', config = 'polizei', name = 'ETK 800 Polizei' },
    { model = 'vivace', config = '160_diesel', name = 'Vivace 160d' },
    { model = 'etk800', config = '854d_wagon', name = 'ETK 854d' },
  }
  T.check(N.classifyVehicle('scout', 'scout_base') == 'courier', 'classifyVehicle: Gavril Scout -> courier')
  T.check(N.classifyVehicle('evvan', 'ecv_base') == 'courier', 'classifyVehicle: Bruckell ECV (evvan) -> courier')
  T.check(N.classifyVehicle('ecv', 'ecv_base') == 'courier', 'classifyVehicle: Bruckell ECV (ecv) -> courier')
  T.check(N.classifyVehicle('pickup', 'd45_fdc_delivery') == 'courier', 'classifyVehicle: delivery-skinned pickup -> courier')
  T.check(N.classifyVehicle('pickup', 'd15_v8_4wd') == 'commuter', 'classifyVehicle: plain pickup -> commuter')
  T.check(N.classifyVehicle('t_series', 't75_hhl_freight') == 'courier', 'classifyVehicle: delivery-skinned t_series -> courier')
  T.check(N.classifyVehicle('t_series', 't75_hauler') == 'truck', 'classifyVehicle: plain t_series -> truck')
  T.check(N.classifyVehicle('pickup', 'd15_pickups_base') == 'commuter', 'classifyVehicle: token boundary avoids ups false positive')

  local rEuMod = N.buildTrafficRoster('DE', modPool, false, { size = 16, urban = true })
  T.check(rEuMod.counts.police == 0, 'Tier 1 (EU mods): strict Police == 0 when deEnabled == false')
  local euCouriers = {}
  for _, e in ipairs(rEuMod) do
    if e.archetype == 'courier' then euCouriers[#euCouriers + 1] = e end
  end
  T.check(#euCouriers == 2, 'Tier 1 (EU mods): fills courier quota (max 2 at size >= 14) from mod delivery pool')
  local euAllModPreserved = true
  local euSawScoutOrEvvan = false
  for _, e in ipairs(euCouriers) do
    if e.deliveryTier ~= 1 or e.hasDeliveryLivery ~= true or e.paint ~= nil then euAllModPreserved = false end
    if e.model == 'scout' or e.model == 'evvan' or e.model == 'ecv' then euSawScoutOrEvvan = true end
  end
  T.check(euAllModPreserved and euSawScoutOrEvvan,
    'Tier 1 (EU mods): scout/evvan + hhl/postit/nile selected first with paint == nil')

  local rNaMod = N.buildTrafficRoster('US', modPool, false, { size = 16, urban = true })
  T.check(rNaMod.counts.police == 0, 'Tier 1 (NA mods): strict Police == 0')
  local naTopCourier = nil
  for _, e in ipairs(rNaMod) do
    if e.archetype == 'courier' then naTopCourier = e; break end
  end
  T.check(naTopCourier ~= nil and (naTopCourier.model == 'evvan' or naTopCourier.model == 'ecv')
    and naTopCourier.hasDeliveryLivery == true and naTopCourier.paint == nil,
    'Tier 1 (NA mods): prioritizes regional NA evvan/ecv + bps/nile/hhl with paint == nil')

  -- Tier 2: Vanilla-only environment (zero mods -> built-in vanilla delivery/commercial/cargobox liveries with paint == nil)
  local vanillaPool = {
    { model = 'van', config = 'h15_vanster', name = 'H15 Vanster' },
    { model = 'van', config = 'h15_cargo', name = 'H15 Cargo Van' },
    { model = 'van', config = 'deliverytruck', name = 'H45 Delivery Truck' },
    { model = 'van', config = 'h25_commercial', name = 'H25 Commercial Fleet' },
    { model = 'md_series', config = 'md_60_cargobox', name = 'MD60 CargoBox' },
    { model = 't_series', config = 't83s_cargobox', name = 'T83s CargoBox' },
    { model = 'md_series', config = 'md70_flatbed', name = 'MD70 Flatbed' },
    { model = 't_series', config = 't83_longhaul', name = 'T83 Longhaul' },
    { model = 'etk800', config = 'polizei', name = 'ETK 800 Polizei' },
    { model = 'vivace', config = '160_diesel', name = 'Vivace 160d' },
    { model = 'etk800', config = '854d_wagon', name = 'ETK 854d' },
  }
  local rVanilla = N.buildTrafficRoster('europe', vanillaPool, false, { size = 16, urban = true })
  T.check(rVanilla.counts.police == 0, 'Tier 2 (vanilla-only): strict Police == 0 when deEnabled == false')
  local vCouriers = {}
  for _, e in ipairs(rVanilla) do
    if e.archetype == 'courier' then vCouriers[#vCouriers + 1] = e end
  end
  T.check(#vCouriers == 2, 'Tier 2 (vanilla-only): populates courier quota (max 2 at size >= 14) from vanilla delivery liveries')
  local allVanillaLiveryPreserved = true
  for _, e in ipairs(vCouriers) do
    if e.deliveryTier ~= 2 or e.hasDeliveryLivery ~= true or e.paint ~= nil or e.liveryTag ~= 'vanilla_delivery' then
      allVanillaLiveryPreserved = false
    end
  end
  T.check(allVanillaLiveryPreserved,
    'Tier 2 (vanilla-only): prioritizes vanilla delivery/commercial/cargobox liveries with paint == nil')

  -- Tier 3: Bare/plain fallback environment (only unskinned cargo/panel vans -> receive regional M.COURIER_PAINTS)
  local plainPool = {
    { model = 'van', config = 'h15_cargo', name = 'H15 Cargo Van' },
    { model = 'van', config = 'h15_vanster', name = 'H15 Vanster' },
    { model = 'van', config = 'h25_panel', name = 'H25 Panel Van' },
    { model = 't_series', config = 't83_longhaul', name = 'T83 Longhaul' },
    { model = 'etk800', config = 'polizei', name = 'ETK 800 Polizei' },
    { model = 'vivace', config = '160_diesel', name = 'Vivace 160d' },
    { model = 'etk800', config = '854d_wagon', name = 'ETK 854d' },
  }
  local rPlainEu = N.buildTrafficRoster('europe', plainPool, false, { size = 16, urban = true })
  T.check(rPlainEu.counts.police == 0, 'Tier 3 (plain fallback): strict Police == 0 when deEnabled == false')
  local plainCouriers = {}
  for _, e in ipairs(rPlainEu) do
    if e.archetype == 'courier' then plainCouriers[#plainCouriers + 1] = e end
  end
  T.check(#plainCouriers == 2, 'Tier 3 (plain fallback): fills courier quota (max 2 at size >= 14) from plain vans')
  local allPlainPainted = true
  for _, e in ipairs(plainCouriers) do
    if e.deliveryTier ~= 3 or e.hasDeliveryLivery ~= false or type(e.paint) ~= 'table' or e.paintName == nil then
      allPlainPainted = false
    end
  end
  T.check(allPlainPainted and plainCouriers[1].liveryTag == 'dhl_amber',
    'Tier 3 (plain fallback EU): unskinned cargo vans receive regional M.COURIER_PAINTS starting with dhl_amber')

  local rPlainNa = N.buildTrafficRoster('US', plainPool, false, { size = 16, urban = true })
  local firstNaPlain = nil
  for _, e in ipairs(rPlainNa) do
    if e.archetype == 'courier' then firstNaPlain = e; break end
  end
  T.check(firstNaPlain ~= nil and firstNaPlain.liveryTag == 'commercial_white' and type(firstNaPlain.paint) == 'table',
    'Tier 3 (plain fallback NA): unskinned cargo vans receive NA regional M.COURIER_PAINTS')
end

-- 3. AI Driving Personas (risk, highway cruise speeds, Autobahn speeders, Rechtsfahrgebot lane bias)
do
  local pTruck = N.assignVehiclePersona(10, 'semi', 't75_hauler', true)
  T.check(pTruck.persona == 'truck' and pTruck.risk >= 0.22 and pTruck.risk <= 0.32,
    'persona truck: calm risk in [0.22, 0.32]')
  T.check(pTruck.highwayCruiseKph >= 82 and pTruck.highwayCruiseKph <= 92 and pTruck.laneBias == 'right'
    and pTruck.overtakeAllowed == false, 'persona truck: 82-92 km/h & strict right lane')

  local pBus = N.assignVehiclePersona(11, 'citybus', 'city', true)
  T.check(pBus.persona == 'bus' and pBus.risk >= 0.22 and pBus.risk <= 0.32
    and pBus.highwayCruiseKph >= 82 and pBus.highwayCruiseKph <= 92 and pBus.laneBias == 'right',
    'persona bus: calm risk, 82-92 km/h, strict right lane')

  local pCourier = N.assignVehiclePersona(12, 'van', 'h25_delivery', true)
  T.check(pCourier.persona == 'courier' and pCourier.risk >= 0.40 and pCourier.risk <= 0.45
    and pCourier.highwayCruiseKph >= 95 and pCourier.highwayCruiseKph <= 110
    and pCourier.laneBias == 'right_or_middle', 'persona courier: ~0.42 risk, 95-110 km/h, right/middle lanes')

  local pScout = N.assignVehiclePersona(20, 'scout', 'scout_hhl', true)
  T.check(pScout.persona == 'courier' and pScout.risk >= 0.40 and pScout.risk <= 0.45
    and pScout.highwayCruiseKph >= 95 and pScout.highwayCruiseKph <= 110
    and pScout.laneBias == 'right_or_middle', 'persona courier: Gavril Scout gets courier persona')

  local pEvvan = N.assignVehiclePersona(21, 'evvan', 'ecv_nile', true)
  local pEcv = N.assignVehiclePersona(22, 'ecv', 'ecv_base', true)
  T.check(pEvvan.persona == 'courier' and pEcv.persona == 'courier'
    and pEvvan.highwayCruiseKph >= 95 and pEvvan.highwayCruiseKph <= 110,
    'persona courier: Bruckell ECV (evvan/ecv) gets courier persona')

  local pDeliveryPickup = N.assignVehiclePersona(23, 'pickup', 'd45_bps_delivery', true)
  T.check(pDeliveryPickup.persona == 'courier' and pDeliveryPickup.laneBias == 'right_or_middle',
    'persona courier: delivery-skinned pickup gets courier persona')

  local pDeliverySemi = N.assignVehiclePersona(24, 't_series', 't75_hhl_freight', true)
  local pDeliverySemiRoster = N.assignVehiclePersona(25, 'us_semi', 't83s_cargobox', true, 'courier')
  T.check(pDeliverySemi.persona == 'truck' and pDeliverySemi.laneBias == 'right'
    and pDeliverySemi.overtakeAllowed == false and pDeliverySemi.highwayCruiseKph <= 92,
    'persona truck: heavy delivery-skinned t_series keeps truck persona')
  T.check(pDeliverySemiRoster.persona == 'truck' and pDeliverySemiRoster.laneBias == 'right',
    'persona truck: heavy delivery-skinned us_semi keeps truck persona even with courier rosterArchetype')

  local pComm = N.assignVehiclePersona(13, 'vivace', '160_diesel', false)
  T.check(pComm.persona == 'commuter' and pComm.risk >= 0.38 and pComm.risk <= 0.52
    and pComm.urbanDeltaKph >= -4 and pComm.urbanDeltaKph <= 4 and pComm.laneBias == 'right',
    'persona commuter: balanced risk, posted +/-4 km/h, right lane bias')

  local pSpeed = N.assignVehiclePersona(14, 'etk800', '856_ttsport', true)
  T.check(pSpeed.persona == 'speeder' and pSpeed.risk >= 0.48 and pSpeed.risk <= 0.55
    and pSpeed.aggression <= 0.58
    and pSpeed.highwayCruiseKph >= 165 and pSpeed.highwayCruiseKph <= 185
    and pSpeed.highwayDeltaKph >= 15 and pSpeed.highwayDeltaKph <= 28
    and pSpeed.laneBias == 'overtake_left',
    'persona speeder: capped risk <= 0.55, aggression <= 0.58, 165-185 km/h Autobahn')

  for _, p in ipairs({ pTruck, pBus, pCourier, pComm, pSpeed }) do
    T.check(p.risk <= 0.55 and p.aggression <= 0.58,
      'persona traction cap: risk <= 0.55 and aggression <= 0.58 for ' .. tostring(p.persona))
  end

  local cmd = N.personaAiCommand(pSpeed)
  T.check(cmd and cmd:find('ai.setAggression', 1, true) and cmd:find('ai.driveInLane("on")', 1, true)
    and cmd:find('ai.setAvoidCars("on")', 1, true)
    and cmd:find('trafficWaitTime = 1.20', 1, true) and cmd:find('turnForceCoef = 0.85', 1, true),
    'personaAiCommand emits smooth capped AI setup (trafficWaitTime=1.20, turnForceCoef=0.85)')
end

-- 4. OSM Bus Stop pull-over, dwell, release & 45 s per-stop cooldown state machine
do
  N.reset()
  local count = N.onBusStops('tile1', { { id = 'stop_main', x = 100, y = 4, z = 0, yaw = 0 } })
  T.check(count == 1 and N.status().busStopsLoaded == 1, 'onBusStops registers tile stops')
  local cmds = {}
  local busObj = { queueLuaCommand = function(_, c) cmds[#cmds + 1] = c end }

  -- Too fast (>= 14 m/s): must not trigger stop
  local stFast = N.stepBusStop(50, 90, 0, 1, 0, 15.0, 100, busObj)
  T.check(stFast == 'none' and not N.isBusDwelling(50) and #cmds == 0, 'bus stop: ignored at >= 14 m/s')

  -- Approaching within 18 m at 8 m/s along heading: triggers smooth stop + hazard signal + curbside pull-over offset
  local stStop = N.stepBusStop(50, 90, 0, 1, 0, 8.0, 100, busObj)
  T.check(stStop == 'stopped' and N.isBusDwelling(50), 'bus stop: triggers dwell within 18 m')
  T.check(#cmds == 1 and cmds[1]:find('electrics.set_warn_signal(1)', 1, true) and cmds[1]:find('ai.setSpeed(0)', 1, true)
    and cmds[1]:find('ai.driveInLane("off")', 1, true) and cmds[1]:find('ai.laneChange(nil, 10.0, 0.85)', 1, true),
    'bus stop: commands hazard lights, right-curb pull-over offset, and smooth stop')

  -- Still dwelling at +2.0 s (< 3.5 s)
  local stDwell = N.stepBusStop(50, 95, 0, 1, 0, 0.0, 102, busObj)
  T.check(stDwell == 'dwelling' and N.isBusDwelling(50) and #cmds == 1, 'bus stop: holds dwell during 3.5-4.5 s window')

  -- Released after 4.6 s (> 4.5 s max dwell)
  local stRel = N.stepBusStop(50, 95, 0, 1, 0, 0.0, 104.6, busObj)
  T.check(stRel == 'released' and not N.isBusDwelling(50), 'bus stop: releases after dwell completes')
  T.check(#cmds == 2 and cmds[2]:find('electrics.set_warn_signal(0)', 1, true) and cmds[2]:find('ai.setMode("traffic")', 1, true)
    and cmds[2]:find('ai.driveInLane("on")', 1, true) and cmds[2]:find('ai.laneChange(nil, 12.0, -0.85)', 1, true),
    'bus stop: clears hazard signal, resets curb offset, and resumes traffic flow')

  -- Within 45 s per-stop cooldown: another bus (or same bus) cannot re-trigger
  local stCd = N.stepBusStop(51, 90, 0, 1, 0, 6.0, 130, busObj)
  T.check(stCd == 'none' and not N.isBusDwelling(51), 'bus stop: 45 s per-stop cooldown blocks immediate re-trigger')

  -- After 45 s cooldown expires (104.6 + 45 = 149.6 -> test at 150.0): triggers again
  local stAfter = N.stepBusStop(51, 90, 0, 1, 0, 6.0, 150.0, busObj)
  T.check(stAfter == 'stopped' and N.isBusDwelling(51), 'bus stop: triggers again after 45 s cooldown')

  N.dropBusStops('tile1')
  T.check(N.status().busStopsLoaded == 0, 'dropBusStops clears tile stops')
  N.reset()
end

-- 5. Forward-biased horizon spawn/despawn recycling window & throttled director tick
do
  T.check(N.shouldRecycleBehind(-450, 0, 0, 0, 1, 0), 'shouldRecycleBehind: > 420 m behind player recycles')
  T.check(not N.shouldRecycleBehind(-400, 0, 0, 0, 1, 0), 'shouldRecycleBehind: <= 420 m behind stays')
  T.check(not N.shouldRecycleBehind(200, 0, 0, 0, 1, 0), 'shouldRecycleBehind: ahead of player stays')

  local bigBox = { -600, -600, 600, 600 }
  local x, y, hx, hy, lo, hi = N.horizonSpawnWindow(0, 0, 1, 0, bigBox, 0, 0)
  T.check(x == 0 and y == 0 and hx == 1 and hy == 0 and lo == 160 and hi == 340,
    'horizonSpawnWindow: [160, 340] forward cone in large box')

  -- Camera ahead of player at +120 m: lo must stay >= 95 m past camera (>= 215 m)
  local _, _, _, _, loCam, hiCam = N.horizonSpawnWindow(0, 0, 1, 0, bigBox, 120, 0)
  T.check(loCam >= 215 - 1e-6 and hiCam == 340, 'horizonSpawnWindow: never pops in within < 95 m of camera')

  -- Tiny box leaving < 95 m ahead: returns nil rather than popping in close
  T.check(N.horizonSpawnWindow(0, 0, 1, 0, { -100, -100, 120, 100 }, 0, 0) == nil,
    'horizonSpawnWindow: returns nil when box cannot guarantee >= 95 m clearance')

  -- End-to-end updateTrafficDirector: 4 Hz throttle, persona assignment, and behind-player recycling
  N.reset()
  N.enabled = true
  local sg = { gameplay_traffic = rawget(_G, 'gameplay_traffic'), getObjectByID = rawget(_G, 'getObjectByID'),
               be = rawget(_G, 'be'), core_camera = rawget(_G, 'core_camera'), map = rawget(_G, 'map') }
  local clock0 = os.clock
  local now = 2000
  os.clock = function() return now end
  local function v(ax, ay, az)
    return { x = ax, y = ay, z = az or 0, length = function(s) return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) end }
  end
  local dirCmds, teleports = {}, {}
  local aiObj = {
    getActive = function() return true end,
    getPosition = function() return v(-500, 0, 0) end,
    getVelocity = function() return v(10, 0, 0) end,
    getDirectionVector = function() return v(1, 0, 0) end,
    queueLuaCommand = function(_, c) dirCmds[#dirCmds + 1] = c end,
  }
  getObjectByID = function(id) return id == 201 and aiObj or nil end
  be = { getPlayerVehicleID = function() return 1 end }
  core_camera = { getPosition = function() return v(0, 0, 0) end }
  map = nil
  gameplay_traffic = {
    getState = function() return 'on' end,
    getTrafficData = function()
      return { [201] = { isAi = true, model = 'semi', config = 't75_hauler', respawnCount = 0, risk = 0.5 } }
    end,
    forceTeleport = function(id, pos, dir, dmin, dmax)
      teleports[#teleports + 1] = { id = id, pos = pos, dir = dir, dmin = dmin, dmax = dmax }
    end,
  }
  local player = { x = 0, y = 0, z = 0, vx = 25, vy = 0 }
  T.check(N.updateTrafficDirector(0.10, player, bigBox) == false, 'director: throttled below 0.25 s')
  T.check(N.updateTrafficDirector(0.16, player, bigBox) == true, 'director: ticks at >= 0.25 s (~4 Hz)')
  T.check(N.getVehiclePersona(201) ~= nil and N.getVehiclePersona(201).persona == 'truck',
    'director: assigns persona on first sight')
  T.check(#dirCmds == 1 and dirCmds[1]:find('ai.setAggression', 1, true) ~= nil,
    'director: sends persona AI command once')
  T.check(#teleports == 1 and teleports[1].id == 201 and teleports[1].dmin == 160 and teleports[1].dmax == 340,
    'director: recycles vehicle > 420 m behind into [160, 340] m forward cone')

  os.clock = clock0
  for k, val in pairs(sg) do _G[k] = val end
  N.reset()
end

-- 6. Polish Pass: 140 m horizon spawn spacing & dark/rain headlight sync
do
  local recent = { { x = 250, y = 0, at = 100 } }
  T.check(not N.horizonSpawnClear(300, 0, recent, 102), 'horizonSpawnClear: blocks spawn within < 140 m of recent spawn')
  T.check(N.horizonSpawnClear(400, 0, recent, 102), 'horizonSpawnClear: allows spawn >= 140 m away')
  T.check(N.horizonSpawnClear(260, 0, recent, 115), 'horizonSpawnClear: allows spawn after TTL expires')

  -- Headlight sync during night and rain
  local env0, weather0 = rawget(_G, 'core_environment'), rawget(_G, 'beamngEarth_weather')
  core_environment = { getLightState = function() return { isNight = false } end,
                       getTimeOfDay = function() return { time = 0.0 } end }
  beamngEarth_weather = { isRaining = false, precipitation = 0 }
  T.check(not N.needsHeadlights(), 'needsHeadlights: false at clear midday')

  core_environment = { getLightState = function() return { isNight = true } end }
  T.check(N.needsHeadlights(), 'needsHeadlights: true at night')

  core_environment = { getLightState = function() return { isNight = false } end,
                       getTimeOfDay = function() return { time = 0.0 } end }
  beamngEarth_weather = { isRaining = true }
  T.check(N.needsHeadlights(), 'needsHeadlights: true during rain')

  local pComm = N.assignVehiclePersona(99, 'vivace', '160_diesel', false)
  local cmdDay = N.personaAiCommand(pComm, false)
  local cmdRain = N.personaAiCommand(pComm, true)
  T.check(cmdDay:find('setLightsState', 1, true) == nil, 'personaAiCommand: no forced lights in clear day')
  T.check(cmdRain:find('electrics.setLightsState(1)', 1, true) ~= nil, 'personaAiCommand: enables low-beams in dark/rain')

  -- Two behind-player vehicles recycled on same tick: second is skipped by 140 m corridor spacing
  N.reset()
  N.enabled = true
  local sg = { gameplay_traffic = rawget(_G, 'gameplay_traffic'), getObjectByID = rawget(_G, 'getObjectByID'),
               be = rawget(_G, 'be'), core_camera = rawget(_G, 'core_camera'), map = rawget(_G, 'map') }
  local clock0 = os.clock
  os.clock = function() return 3000 end
  local function v(ax, ay, az)
    return { x = ax, y = ay, z = az or 0, length = function(s) return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) end }
  end
  local cmds301, cmds302, teleports = {}, {}, {}
  local objs = {
    [301] = { getActive = function() return true end, getPosition = function() return v(-500, 0, 0) end,
              getVelocity = function() return v(10, 0, 0) end, getDirectionVector = function() return v(1, 0, 0) end,
              queueLuaCommand = function(_, c) cmds301[#cmds301 + 1] = c end },
    [302] = { getActive = function() return true end, getPosition = function() return v(-520, 0, 0) end,
              getVelocity = function() return v(10, 0, 0) end, getDirectionVector = function() return v(1, 0, 0) end,
              queueLuaCommand = function(_, c) cmds302[#cmds302 + 1] = c end },
  }
  getObjectByID = function(id) return objs[id] end
  be = { getPlayerVehicleID = function() return 1 end }
  core_camera = { getPosition = function() return v(0, 0, 0) end }
  map = nil
  gameplay_traffic = {
    getState = function() return 'on' end,
    getTrafficData = function()
      return {
        [301] = { isAi = true, model = 'citybus', config = 'city', respawnCount = 0 },
        [302] = { isAi = true, model = 'etk800', config = '856_ttsport', respawnCount = 0 },
      }
    end,
    forceTeleport = function(id) teleports[#teleports + 1] = id end,
  }
  local bigBox = { -600, -600, 600, 600 }
  N.updateTrafficDirector(0.30, { x = 0, y = 0, z = 0, vx = 25, vy = 0 }, bigBox)
  T.check(#teleports == 1, 'director: 140 m spacing prevents two vehicles clumping into the same corridor slot')
  T.check((cmds301[1] and cmds301[1]:find('electrics.setLightsState(1)', 1, true) ~= nil)
    and (cmds302[1] and cmds302[1]:find('electrics.setLightsState(1)', 1, true) ~= nil),
    'director: syncs low-beam headlights on newly initialized vehicles during rain')

  os.clock = clock0
  core_environment, beamngEarth_weather = env0, weather0
  for k, val in pairs(sg) do _G[k] = val end
  N.reset()
end

-- 7. Natural Traffic Proportions, Simple-Traffic Roster Inclusion & AI Courier Curbside Delivery Stops
do
  -- Build a realistic large vehicle pool with ~40 everyday commuters + buses, mod couriers, trucks, speeders, police
  local bigPool = {
    { model = 'citybus', config = 'city', name = 'City Transit Bus' },
    { model = 'wentward', config = 'metro_shuttle', name = 'Metro Shuttle' },
    { model = 'scout', config = 'scout_hhl', name = 'Gavril Scout HHL' },
    { model = 'evvan', config = 'ecv_nile', name = 'Bruckell ECV Nile' },
    { model = 'van', config = 'h25_delivery', name = 'H25 Delivery' },
    { model = 'semi', config = 't75_hauler', name = 'T75 Hauler' },
    { model = 'md_series', config = 'md70_flatbed', name = 'MD70 Flatbed' },
    { model = 'etk800', config = '856_ttsport', name = 'ETK 856 ttSport' },
    { model = 'etkc', config = 'kc6t_sport', name = 'ETK K Sport' },
    { model = 'etk800', config = 'polizei', name = 'ETK 800 Polizei' },
  }
  for i = 1, 36 do
    bigPool[#bigPool + 1] = { model = 'vivace', config = 'commuter_' .. tostring(i), name = 'Vivace ' .. tostring(i) }
  end

  -- Standard 8-vehicle and 10-vehicle urban pools: 1 bus, 1 courier, >= 75% commuters, strict Police == 0
  local r8 = N.buildTrafficRoster('DE', bigPool, false, { size = 8, urban = true })
  T.check(r8.counts.bus == 1 and r8.counts.courier == 1 and r8.counts.police == 0
    and r8.counts.commuter == 6,
    'natural mix (size 8): 1 bus, 1 courier, 6 commuters (75%), 0 police')

  local r10 = N.buildTrafficRoster('DE', bigPool, false, { size = 10, urban = true })
  T.check(r10.counts.bus == 1 and r10.counts.courier == 1 and r10.counts.police == 0
    and r10.counts.commuter == 8,
    'natural mix (size 10): 1 bus, 1 courier, 8 commuters (80%), 0 police')

  -- Larger 14-vehicle and 40-vehicle pools: still 1 bus, at most 2 couriers, ~75-85% commuters
  local r14 = N.buildTrafficRoster('DE', bigPool, false, { size = 14, urban = true })
  T.check(r14.counts.bus == 1 and r14.counts.courier == 2 and r14.counts.police == 0,
    'natural mix (size 14): 1 bus and at most 2 couriers when size >= 14')

  local r40 = N.buildTrafficRoster('DE', bigPool, false, { size = 40, urban = true })
  T.check(r40.counts.bus == 1 and r40.counts.courier == 2 and r40.counts.police == 0
    and r40.counts.commuter >= 30 and r40.counts.commuter <= 35,
    'natural mix (size 40): 1 bus, 2 couriers, ~75-85% commuters, 0 police')

  -- Rural >= 6 pool gets 1 bus (falls back to citybus/wentward when no H-Series minibus is in pool); tiny rural < 6 gets 0
  local rRural4 = N.buildTrafficRoster('DE', bigPool, false, { size = 4, urban = false })
  local rRural8 = N.buildTrafficRoster('DE', bigPool, false, { size = 8, urban = false })
  local rRural10 = N.buildTrafficRoster('DE', bigPool, false, { size = 10, urban = false })
  T.check(rRural4.counts.bus == 0 and rRural8.counts.bus == 1 and rRural10.counts.bus == 1,
    'natural mix (rural): 0 buses on <6 rural pool, 1 bus on >=6 pool')

  -- Simple-traffic bypass prevention: regionalGroup() runs buildTrafficRoster even when trafficSimpleVehicles == true
  -- and falls back to simple createGroup only if core_vehicles.getConfigList() returns empty.
  N.reset()
  local sg = {
    settings = rawget(_G, 'settings'),
    core_multiSpawn = rawget(_G, 'core_multiSpawn'),
    core_vehicles = rawget(_G, 'core_vehicles'),
    readFile = rawget(_G, 'readFile'),
    jsonDecode = rawget(_G, 'jsonDecode'),
    log = rawget(_G, 'log'),
  }
  log = function() end
  readFile = function() return '{}' end
  jsonDecode = function()
    return { nodes = { a = { 0, 0, 0, 4 } }, edges = {}, rules = { country = 'DE' }, trafficProfile = { band = 'urban' } }
  end
  N.onMessage({ anchorId = 1, path = 'x', serial = 1 }, 1)
  local cfgMap = {
    trafficSmartSelections = true,
    trafficSimpleVehicles = true,
    trafficAllowMods = true,
  }
  settings = { getValue = function(k) return cfgMap[k] end }
  local simpleGroup = {}
  for i = 1, 20 do
    simpleGroup[i] = { model = 'simple_traffic', config = 'eu_sedan_' .. tostring(i), name = 'Simple EU ' .. tostring(i) }
  end
  core_multiSpawn = { createGroup = function() return simpleGroup end }
  core_vehicles = {
    getConfigList = function()
      return {
        { model_key = 'citybus', key = 'city', Name = 'City Transit Bus' },
        { model_key = 'scout', key = 'scout_hhl', Name = 'Gavril Scout HHL' },
        { model_key = 'evvan', key = 'ecv_nile', Name = 'Bruckell ECV Nile' },
        { model_key = 'etk800', key = 'polizei', Name = 'ETK 800 Polizei' },
      }
    end,
  }
  local gSimpleRoster = N._regionalGroup()
  local sawBus, sawModCourier, sawPol = false, false, false
  for _, e in ipairs(gSimpleRoster or {}) do
    if e.archetype == 'bus' then sawBus = true end
    if e.archetype == 'courier' and (e.model == 'scout' or e.model == 'evvan') then sawModCourier = true end
    if e.archetype == 'police' or tostring(e.config):find('poliz') then sawPol = true end
  end
  T.check(sawBus and sawModCourier and not sawPol,
    'regionalGroup: buildTrafficRoster active with trafficSimpleVehicles=true (includes bus + mod courier, 0 police)')

  -- Fallback when core_vehicles.getConfigList() returns empty under trafficSimpleVehicles == true
  core_vehicles = { getConfigList = function() return {} end }
  local gFallback = N._regionalGroup()
  T.check(gFallback == simpleGroup,
    'regionalGroup: falls back to simple traffic group when core_vehicles.getConfigList() is empty')

  for k, val in pairs(sg) do _G[k] = val end
  N.reset()

  -- roads.extractDeliveryPoints: building footprints, addresses, well-spaced deduplication, 20-point cap
  local R = require('beamngEarth/roads')
  local denseBld = {}
  for i = 1, 30 do
    -- Space 40 m apart so each is eligible, verify cap at 20
    local bx = i * 40
    denseBld[i] = { bx - 5, 10, 0, bx + 5, 20, 8 }
  end
  -- Add a clustered duplicate right next to building 1 (within 35 m -> must be skipped)
  denseBld[31] = { 38, 12, 0, 44, 18, 8 }
  local pts = R.extractDeliveryPoints('tile_deliv', { colliders = { bld = denseBld } }, nil)
  T.check(#pts == 20, 'extractDeliveryPoints: caps at 20 well-spaced building points per tile')
  local allSpaced = true
  for i = 1, #pts do
    for j = i + 1, #pts do
      local dx, dy = pts[i].x - pts[j].x, pts[i].y - pts[j].y
      if dx * dx + dy * dy < 35.0 * 35.0 - 1e-6 then allSpaced = false end
    end
  end
  T.check(allSpaced, 'extractDeliveryPoints: enforces >= 35 m spacing between delivery points')

  -- AI Courier curbside delivery stop lifecycle: pull-over, hazard lights, 4-6 s dwell, release & 45 s cooldown
  N.reset()
  local dCount = N.onDeliveryPoints('tile_deliv', { { id = 'drop_1', x = 100, y = 4, z = 0, yaw = 0 } })
  T.check(dCount == 1 and N.status().deliveryPointsLoaded == 1, 'onDeliveryPoints registers tile drop points')
  local cCmds = {}
  local cObj = { queueLuaCommand = function(_, c) cCmds[#cCmds + 1] = c end }

  -- Too fast (>= 15 m/s): must not trigger stop
  local stFast = N.stepCourierStop(60, 90, 0, 1, 0, 15.0, 100, cObj)
  T.check(stFast == 'none' and not N.isCourierDwelling(60) and #cCmds == 0,
    'courier stop: ignored at >= 15 m/s')

  -- Out of range (> 16 m): must not trigger stop
  local stFar = N.stepCourierStop(60, 80, 0, 1, 0, 8.0, 100, cObj)
  T.check(stFar == 'none' and not N.isCourierDwelling(60) and #cCmds == 0,
    'courier stop: ignored when > 16 m away')

  -- Approaching within <= 16 m at 8 m/s: triggers right-curb pull-over (0.85 m) + hazards + 0 m/s dwell
  local stStop = N.stepCourierStop(60, 90, 0, 1, 0, 8.0, 100, cObj)
  T.check(stStop == 'stopped' and N.isCourierDwelling(60),
    'courier stop: triggers dwell within <= 16 m at < 15 m/s')
  T.check(#cCmds == 1
    and cCmds[1]:find('electrics.set_warn_signal(1)', 1, true)
    and cCmds[1]:find('ai.setSpeed(0)', 1, true)
    and cCmds[1]:find('ai.driveInLane("off")', 1, true)
    and cCmds[1]:find('ai.laneChange(nil, 10.0, 0.85)', 1, true),
    'courier stop: activates hazards, 0.85 m right curb pull-over, and holds at 0 m/s')

  -- Still dwelling at +3.5 s (< 4.0 s minimum dwell)
  local stHold = N.stepCourierStop(60, 95, 0, 1, 0, 0.0, 103.5, cObj)
  T.check(stHold == 'dwelling' and N.isCourierDwelling(60) and #cCmds == 1,
    'courier stop: holds dwell during 4.0-6.0 s package delivery window')

  -- Released after 6.1 s (> 6.0 s maximum dwell)
  local stRel = N.stepCourierStop(60, 95, 0, 1, 0, 0.0, 106.1, cObj)
  T.check(stRel == 'released' and not N.isCourierDwelling(60),
    'courier stop: releases smoothly after dwell completes')
  T.check(#cCmds == 2
    and cCmds[2]:find('electrics.set_warn_signal(0)', 1, true)
    and cCmds[2]:find('ai.setMode("traffic")', 1, true)
    and cCmds[2]:find('ai.driveInLane("on")', 1, true)
    and cCmds[2]:find('ai.laneChange(nil, 12.0, -0.85)', 1, true),
    'courier stop: clears hazards, resets curb offset, and resumes traffic')

  -- 45 s per-point cooldown blocks re-trigger at +30 s, allows again after +45 s (106.1 + 45 = 151.1)
  local stCd = N.stepCourierStop(61, 90, 0, 1, 0, 6.0, 136.0, cObj)
  T.check(stCd == 'none' and not N.isCourierDwelling(61),
    'courier stop: 45 s per-point cooldown blocks immediate re-trigger')
  local stAfter = N.stepCourierStop(61, 90, 0, 1, 0, 6.0, 152.0, cObj)
  T.check(stAfter == 'stopped' and N.isCourierDwelling(61),
    'courier stop: triggers again after 45 s cooldown expires')

  -- Dwelling courier is excluded from behind-player horizon recycling in updateTrafficDirector
  N.enabled = true
  local sg2 = { gameplay_traffic = rawget(_G, 'gameplay_traffic'), getObjectByID = rawget(_G, 'getObjectByID'),
                be = rawget(_G, 'be'), core_camera = rawget(_G, 'core_camera'), map = rawget(_G, 'map') }
  local clock0 = os.clock
  os.clock = function() return 153.0 end
  local function v(ax, ay, az)
    return { x = ax, y = ay, z = az or 0, length = function(s) return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) end }
  end
  local recycles = {}
  local dwellingCourierObj = {
    getActive = function() return true end,
    getPosition = function() return v(-500, 0, 0) end,
    getVelocity = function() return v(0, 0, 0) end,
    getDirectionVector = function() return v(1, 0, 0) end,
    queueLuaCommand = function() end,
  }
  getObjectByID = function(id) return id == 61 and dwellingCourierObj or nil end
  be = { getPlayerVehicleID = function() return 1 end }
  core_camera = { getPosition = function() return v(0, 0, 0) end }
  map = nil
  gameplay_traffic = {
    getState = function() return 'on' end,
    getTrafficData = function()
      return { [61] = { isAi = true, model = 'scout', config = 'scout_hhl', respawnCount = 0 } }
    end,
    forceTeleport = function(id) recycles[#recycles + 1] = id end,
  }
  N.updateTrafficDirector(0.30, { x = 0, y = 0, z = 0, vx = 25, vy = 0 }, { -600, -600, 600, 600 })
  T.check(#recycles == 0 and N.isCourierDwelling(61),
    'director: excludes dwelling courier from behind-player recycling while stopped')

  os.clock = clock0
  for k, val in pairs(sg2) do _G[k] = val end
  N.dropDeliveryPoints('tile_deliv')
  T.check(N.status().deliveryPointsLoaded == 0, 'dropDeliveryPoints clears tile drop points')
  N.reset()
end

-- 8. Cargo-Only Delivery Filtering, Dynamic paint_design Skin Injection, Rural H-Series Minibus & Village-Only Courier Stops
do
  -- 8a. Cargo-only filtering: windowed passenger vans/Scouts excluded from 'courier'; cargo/box configs included
  T.check(not N.isCargoCourierConfig('van', 'h15_passenger') and N.classifyVehicle('van', 'h15_passenger') == 'bus',
    'cargo-only: windowed H15 Passenger excluded from courier and classified as bus')
  T.check(not N.isCargoCourierConfig('van', 'h25_ext_passenger_4wd_xt') and N.classifyVehicle('van', 'h25_ext_passenger_4wd_xt') == 'bus',
    'cargo-only: windowed H25 Ext Passenger excluded from courier and classified as bus')
  T.check(not N.isCargoCourierConfig('van', 'vantastic') and N.classifyVehicle('van', 'vantastic') == 'bus',
    'cargo-only: windowed Vantastic excluded from courier and classified as bus')
  T.check(not N.isCargoCourierConfig('euvan', 'multiway_140i_s15_A') and N.classifyVehicle('euvan', 'multiway_140i_s15_A') == 'commuter',
    'cargo-only: windowed Gavril Scout Multiway excluded from courier')
  T.check(not N.isCargoCourierConfig('euvan', 'tracer_330dX_s25_AWD_A') and N.classifyVehicle('euvan', 'tracer_330dX_s25_AWD_A') == 'commuter',
    'cargo-only: windowed Gavril Scout Tracer excluded from courier')
  T.check(not N.isCargoCourierConfig('scout', 'scout_passenger') and N.classifyVehicle('scout', 'scout_passenger') == 'commuter',
    'cargo-only: windowed Scout passenger excluded from courier')

  T.check(N.isCargoCourierConfig('van', 'h15_vanster') and N.classifyVehicle('van', 'h15_vanster') == 'courier',
    'cargo-only: windowless H15 Vanster panel van included as courier')
  T.check(N.isCargoCourierConfig('van', 'deliverytruck') and N.classifyVehicle('van', 'deliverytruck') == 'courier',
    'cargo-only: H45 Delivery Truck box van included as courier')
  T.check(N.isCargoCourierConfig('pickup', 'd45_cargobox_A') and N.classifyVehicle('pickup', 'd45_cargobox_A') == 'courier',
    'cargo-only: D45 CargoBox included as courier')
  T.check(N.isCargoCourierConfig('euvan', 'cargo_250d_delivery_M') and N.classifyVehicle('euvan', 'cargo_250d_delivery_M') == 'courier',
    'cargo-only: Gavril Scout cargo panel van included as courier')
  T.check(N.isCargoCourierConfig('evvan', 'nile') and N.classifyVehicle('evvan', 'nile') == 'courier',
    'cargo-only: Bruckell ECV cargo van included as courier')
  T.check(N.isCargoCourierConfig('md_series', 'md_60_cargobox') and N.classifyVehicle('md_series', 'md_60_cargobox') == 'courier',
    'cargo-only: MD60 CargoBox included as courier')

  -- Persona guard: windowed passenger van forced with rosterArchetype='courier' must never get 'courier' persona
  local pPassVan = N.assignVehiclePersona(70, 'van', 'h25_passenger', false, 'courier')
  T.check(pPassVan.persona == 'bus', 'persona guard: windowed H-Series passenger demoted to bus, never courier')
  local pMultiway = N.assignVehiclePersona(71, 'euvan', 'multiway_250d_s15_M', false, 'courier')
  T.check(pMultiway.persona == 'commuter', 'persona guard: windowed Scout Multiway demoted to commuter, never courier')
  local pUnbrandedVan = N.assignVehiclePersona(72, 'van', 'h15_vanster', false, 'courier',
    { hasDeliveryLivery = false, paintDesign = nil })
  T.check(pUnbrandedVan.persona == 'commuter',
    'persona guard: plain unbranded van without delivery livery or paint_design drives as commuter')

  -- 8b. Dynamic paint_design part picker & core_vehicle_partmgmt application
  local vanParts = {
    van_skin_police = { slotType = 'paint_design', description = 'Police Livery' },
    van_skin_ambulance = { slotType = 'paint_design', description = 'Ambulance Livery' },
    van_skin_twotone = { slotType = 'paint_design', description = 'Two-Tone' },
    van_skin_beamcom = { slotType = 'paint_design', description = 'Beamcom Livery' },
    van_skin_bps = { slotType = 'paint_design', description = 'Beam Postal Service' },
    van_skin_hhl = { slotType = 'paint_design', description = 'HHL Livery' },
    van_skin_nile = { slotType = 'paint_design', description = 'Nile Delivery' },
    ['van_skin_Post-ItDelivery'] = { slotType = 'paint_design', description = 'Post-It Delivery' },
    van_skin_rrt = { slotType = 'paint_design', description = 'RRT Livery' },
  }
  local vanPick = N.pickDeliveryPaintDesign('van', vanParts, { seed = 1, region = 'europe' })
  T.check(vanPick ~= nil and vanPick ~= 'van_skin_police' and vanPick ~= 'van_skin_ambulance' and vanPick ~= 'van_skin_twotone',
    'pickDeliveryPaintDesign (van): selects delivery paint_design and rejects police/ambulance/twotone')

  local pickupParts = {
    pickup_skin_old = { slotType = 'paint_design', description = 'Old Paint' },
    pickup_skin_bps = { slotType = 'paint_design', description = 'Beam Postal Service' },
    pickup_skin_hhl = { slotType = 'paint_design', description = 'HHL Livery' },
    pickup_skin_rrts = { slotType = 'paint_design', description = 'RRT Livery' },
  }
  local pickupPick = N.pickDeliveryPaintDesign('pickup', pickupParts, { seed = 1, region = 'northAmerica' })
  T.check(pickupPick == 'pickup_skin_bps' or pickupPick == 'pickup_skin_hhl' or pickupPick == 'pickup_skin_rrts',
    'pickDeliveryPaintDesign (pickup): selects BPS/HHL/RRT delivery paint_design')

  local scoutParts = {
    euvan_main_skin_polizia = { slotType = 'paint_design', description = 'Polizia Livery' },
    euvan_main_skin_beamcom = { slotType = 'paint_design', description = 'Beamcom Livery' },
    euvan_main_skin_delivery = { slotType = 'paint_design', description = 'Delivery Livery' },
    euvan_main_skin_niledelivery = { slotType = 'paint_design', description = 'Nile Delivery' },
    ['euvan_skin_Post-ItDelivery'] = { slotType = 'paint_design', description = 'Post-It Delivery' },
    euvan_main_skin_hirochi = { slotType = 'paint_design', description = 'Hirochi Auto Parts' },
    euvan_main_skin_roadassistance = { slotType = 'paint_design', description = 'Road Assistance Livery' },
  }
  local scoutPick = N.pickDeliveryPaintDesign('scout', scoutParts, { seed = 1, region = 'europe' })
  T.check(scoutPick ~= nil and scoutPick ~= 'euvan_main_skin_polizia',
    'pickDeliveryPaintDesign (scout/euvan): selects delivery paint_design and rejects polizia')

  local evvanParts = {
    evvan_skin_nile = { slotType = 'paint_design', description = 'Nile Gold' },
    ['evvan_skin_Post-ItDelivery'] = { slotType = 'paint_design', description = 'Post-It Delivery' },
    evvan_skin_cad = { slotType = 'paint_design', description = 'Mail Canada / Canada Courriel' },
    evvan_skin_fallon = { slotType = 'paint_design', description = 'Fallon Home Services' },
    evvan_skin_concour = { slotType = 'paint_design', description = 'ConCour' },
  }
  local evvanPick = N.pickDeliveryPaintDesign('evvan', evvanParts, { seed = 1, region = 'northAmerica' })
  local ecvPick = N.pickDeliveryPaintDesign('ecv', evvanParts, { seed = 2, region = 'europe' })
  T.check(evvanPick ~= nil and ecvPick ~= nil,
    'pickDeliveryPaintDesign (evvan/ecv): selects Nile/Post-It/Mail Canada/Fallon/ConCour paint_design')
  T.check(N.pickDeliveryPaintDesign('pickup', {}) == nil,
    'pickDeliveryPaintDesign: returns nil when installedParts has no delivery paint_design')

  -- applyVehicleLivery: injects paint_design via core_vehicle_partmgmt, preserves paint == nil, never overrides active skin
  local sgPm = {
    core_vehicle_partmgmt = rawget(_G, 'core_vehicle_partmgmt'),
    core_vehicle_manager = rawget(_G, 'core_vehicle_manager'),
    getObjectByID = rawget(_G, 'getObjectByID'),
  }
  local pmCalls = {}
  local curConfigByVeh = {
    [801] = { parts = { paint_design = '' } },
    [802] = { parts = { paint_design = 'van_skin_nile' } },
    [803] = { parts = { paint_design = '' } },
  }
  core_vehicle_partmgmt = {
    getConfigOfVehicle = function(id) return curConfigByVeh[id] end,
    setConfigOfVehicle = function(veh, inData, respawn)
      pmCalls[#pmCalls + 1] = { kind = 'setConfigOfVehicle', veh = veh, inData = inData, respawn = respawn }
    end,
    setConfigPaints = function(paints, respawn, id)
      pmCalls[#pmCalls + 1] = { kind = 'setConfigPaints', paints = paints, respawn = respawn, id = id }
    end,
  }
  core_vehicle_manager = {
    getVehicleData = function(id)
      if id == 801 then return { config = curConfigByVeh[801], availableParts = vanParts } end
      if id == 802 then return { config = curConfigByVeh[802], availableParts = vanParts } end
      if id == 803 then return { config = curConfigByVeh[803], availableParts = {} } end
      return nil
    end,
  }
  getObjectByID = function(id) return { id = id, getJBeamFilename = function() return 'van' end } end

  -- 801: unskinned cargo van -> injects delivery paint_design via core_vehicle_partmgmt and clears paint
  local e801 = { model = 'van', config = 'h15_vanster', region = 'europe', paint = { 0.98, 0.78, 0.04, 1.0 } }
  local res801 = N.applyVehicleLivery(801, e801)
  T.check(res801.applied == 'paint_design' and type(res801.paintDesign) == 'string'
    and e801.paint == nil and e801.hasDeliveryLivery == true
    and #pmCalls == 1 and pmCalls[1].kind == 'setConfigOfVehicle'
    and pmCalls[1].inData.parts.paint_design == res801.paintDesign,
    'applyVehicleLivery: injects delivery paint_design via core_vehicle_partmgmt with paint == nil preservation')

  -- 802: vehicle already has active van_skin_nile -> preserved untouched, never overridden with solid paint
  local e802 = { model = 'van', config = 'nile', region = 'europe', paint = { 0.98, 0.78, 0.04, 1.0 } }
  local res802 = N.applyVehicleLivery(802, e802)
  T.check(res802.applied == 'existing_paint_design' and res802.paintDesign == 'van_skin_nile'
    and res802.preserved == true and e802.paint == nil and #pmCalls == 1,
    'applyVehicleLivery: preserves active paint_design and never overrides with solid paint')

  -- 803: model has zero delivery paint_design parts -> clean fallback to M.COURIER_PAINTS
  local e803 = { model = 'pickup', config = 'd45_cargobox_A', region = 'europe', paint = { 0.98, 0.78, 0.04, 1.0 } }
  local res803 = N.applyVehicleLivery(803, e803)
  T.check(res803.applied == 'fallback_paint' and #pmCalls == 2 and pmCalls[2].kind == 'setConfigPaints',
    'applyVehicleLivery: falls back to M.COURIER_PAINTS only when no delivery paint_design part exists')

  for k, val in pairs(sgPm) do _G[k] = val end

  -- buildTrafficRoster with installedParts injects paintDesign and preserves paint == nil
  local rDyn = N.buildTrafficRoster('DE', {
    { model = 'van', config = 'h15_vanster', name = 'H15 Vanster' },
    { model = 'vivace', config = '160_diesel', name = 'Vivace 160d' },
  }, false, { size = 6, urban = true, installedParts = { van = vanParts } })
  local dynCourier = nil
  for _, e in ipairs(rDyn) do if e.archetype == 'courier' then dynCourier = e; break end end
  T.check(dynCourier ~= nil and dynCourier.paintDesign ~= nil and dynCourier.hasDeliveryLivery == true
    and dynCourier.paint == nil and rDyn.counts.police == 0,
    'buildTrafficRoster: dynamic paint_design injection sets paintDesign, paint == nil, and Police == 0')

  -- 8c. Coexistence of rural H-Series minibus & urban heavy transit bus under 'bus' persona
  local busMixPool = {
    { model = 'citybus', config = 'city', name = 'City Transit Bus' },
    { model = 'wentward', config = 'metro_shuttle', name = 'Metro Shuttle' },
    { model = 'van', config = 'h25_passenger', name = 'H25 Passenger Minibus' },
    { model = 'van', config = 'h15_vanster', name = 'H15 Vanster Cargo' },
    { model = 'etk800', config = 'polizei', name = 'ETK 800 Polizei' },
  }
  for i = 1, 10 do
    busMixPool[#busMixPool + 1] = { model = 'vivace', config = 'comm_' .. tostring(i), name = 'Vivace ' .. tostring(i) }
  end
  local rUrbanBus = N.buildTrafficRoster('DE', busMixPool, false, { size = 8, urban = true })
  local rRuralMinibus = N.buildTrafficRoster('DE', busMixPool, false, { size = 8, urban = false })
  local urbanBusEntry, ruralBusEntry = nil, nil
  for _, e in ipairs(rUrbanBus) do if e.archetype == 'bus' then urbanBusEntry = e; break end end
  for _, e in ipairs(rRuralMinibus) do if e.archetype == 'bus' then ruralBusEntry = e; break end end
  T.check(urbanBusEntry ~= nil and (urbanBusEntry.model == 'citybus' or urbanBusEntry.model == 'wentward')
    and rUrbanBus.counts.bus == 1 and rUrbanBus.counts.police == 0,
    'bus coexistence (urban): selects heavy citybus/wentward with strict Police == 0')
  T.check(ruralBusEntry ~= nil and ruralBusEntry.model == 'van' and ruralBusEntry.config == 'h25_passenger'
    and ruralBusEntry.liveryTag == 'minibus' and rRuralMinibus.counts.bus == 1 and rRuralMinibus.counts.police == 0,
    'bus coexistence (rural size >= 6): selects H-Series passenger minibus with strict Police == 0')

  -- Urban fallback to H-Series minibus when no citybus/wentward exists
  local minibusOnlyPool = {
    { model = 'van', config = 'h25_passenger', name = 'H25 Passenger Minibus' },
    { model = 'vivace', config = '160_diesel', name = 'Vivace 160d' },
  }
  local rUrbanFallback = N.buildTrafficRoster('DE', minibusOnlyPool, false, { size = 6, urban = true })
  local fbBus = nil
  for _, e in ipairs(rUrbanFallback) do if e.archetype == 'bus' then fbBus = e; break end end
  T.check(fbBus ~= nil and fbBus.model == 'van' and fbBus.config == 'h25_passenger',
    'bus coexistence (urban fallback): falls back to H-Series minibus when citybus/wentward unavailable')

  -- H-Series minibus gets 'bus' persona and executes identical stepBusStop() lifecycle
  local pMini = N.assignVehiclePersona(88, 'van', 'h25_passenger', false)
  T.check(pMini.persona == 'bus' and pMini.laneBias == 'right' and pMini.overtakeAllowed == false,
    'minibus persona: H-Series passenger receives bus persona')
  N.reset()
  N.onBusStops('rural_tile', { { id = 'village_stop', x = 50, y = 3, z = 0, yaw = 0 } })
  local mCmds = {}
  local mObj = { queueLuaCommand = function(_, c) mCmds[#mCmds + 1] = c end }
  local ms1 = N.stepBusStop(88, 42, 0, 1, 0, 7.0, 200, mObj)
  local ms2 = N.stepBusStop(88, 46, 0, 1, 0, 0.0, 205.0, mObj)
  T.check(ms1 == 'stopped' and ms2 == 'released' and #mCmds == 2
    and mCmds[1]:find('electrics.set_warn_signal(1)', 1, true) ~= nil
    and mCmds[2]:find('electrics.set_warn_signal(0)', 1, true) ~= nil,
    'minibus bus-stop: executes identical stepBusStop pull-over, hazards, dwell, and release')
  N.reset()

  -- 8d. Village-only delivery point extraction & courier stop speed/limit gating
  local R = require('beamngEarth/roads')
  -- Isolated rural farmstead (only 2 buildings within 120 m) -> 0 delivery points
  local ruralPts = R.extractDeliveryPoints('rural_isolated', {
    buildings = {
      { x = 0, y = 0, z = 0 },
      { x = 40, y = 0, z = 0 },
    },
  }, nil)
  T.check(#ruralPts == 0, 'extractDeliveryPoints: rejects isolated rural buildings (< 3 buildings within 120 m)')

  -- Built-up village cluster (>= 3 buildings within 120 m) on residential street -> accepted;
  -- motorway/trunk/primary stretches -> excluded
  local villagePts = R.extractDeliveryPoints('village_cluster', {
    buildings = {
      { x = 0, y = 0, z = 0, highway = 'residential' },
      { x = 45, y = 0, z = 0, highway = 'residential' },
      { x = 90, y = 0, z = 0, highway = 'primary' },
      { x = 45, y = 45, z = 0, highway = 'motorway' },
    },
  }, nil)
  T.check(#villagePts == 2,
    'extractDeliveryPoints: accepts >= 3 building village cluster and excludes motorway/trunk/primary stretches')

  local trunkTilePts = R.extractDeliveryPoints('trunk_tile', {
    buildings = {
      { x = 0, y = 0, z = 0 },
      { x = 40, y = 0, z = 0 },
      { x = 80, y = 0, z = 0 },
    },
    roads = {
      { highway = 'trunk', pts = { { 0, 0 }, { 40, 0 }, { 80, 0 } } },
    },
  }, nil)
  T.check(#trunkTilePts == 0, 'extractDeliveryPoints: excludes delivery points along trunk/motorway/primary road geometry')

  -- stepCourierStop: requires vehicle speed < 12.5 m/s (45 km/h) AND local road speed limit <= 15.3 m/s (55 km/h)
  N.reset()
  N.onDeliveryPoints('village_tile', { { id = 'v_drop', x = 100, y = 4, z = 0, yaw = 0 } })
  local vCmds = {}
  local vObj = { queueLuaCommand = function(_, c) vCmds[#vCmds + 1] = c end }
  -- Vehicle speed >= 12.5 m/s (45 km/h): blocked
  T.check(N.stepCourierStop(90, 90, 0, 1, 0, 12.5, 300, vObj, 13.9) == 'none' and #vCmds == 0,
    'stepCourierStop: blocked at vehicle speed >= 12.5 m/s (45 km/h)')
  -- Rural highway speed limit 100 km/h (27.8 m/s > 15.3 m/s): blocked even at slow vehicle speed
  T.check(N.stepCourierStop(90, 90, 0, 1, 0, 8.0, 300, vObj, 27.8) == 'none' and #vCmds == 0,
    'stepCourierStop: blocked on rural highway (limit 100 km/h > 55 km/h)')
  -- 60 km/h arterial (16.7 m/s > 15.3 m/s): blocked
  T.check(N.stepCourierStop(90, 90, 0, 1, 0, 8.0, 300, vObj, 16.7) == 'none' and #vCmds == 0,
    'stepCourierStop: blocked when road speed limit > 15.3 m/s (55 km/h)')
  -- Village 50 km/h street (13.9 m/s <= 15.3 m/s) at 8.0 m/s (< 12.5 m/s): triggers stop!
  local stVill = N.stepCourierStop(90, 90, 0, 1, 0, 8.0, 300, vObj, 13.9)
  T.check(stVill == 'stopped' and N.isCourierDwelling(90) and #vCmds == 1,
    'stepCourierStop: triggers curbside stop in 50 km/h village street at < 12.5 m/s')
  N.reset()
end

-- 9. Autobahn Highway Horizon Spawns (340-480 m), Road-Tangent Snapping (Rural & Highway), Smooth Cruise Init & Junction Avoidance
do
  T.check(N.HORIZON_HWY_SPAWN_MIN_M == 340 and N.HORIZON_HWY_SPAWN_MAX_M == 480,
    'highway horizon spawn constants: 340-480 m')

  local hwyBox = { -600, -600, 600, 600 }
  local hx0, hy0, hdx0, hdy0, hlo, hhi = N.horizonSpawnWindow(0, 0, 1, 0, hwyBox, 0, 0, true)
  T.check(hx0 == 0 and hy0 == 0 and hdx0 == 1 and hdy0 == 0 and hlo == 340 and hhi == 480,
    'horizonSpawnWindow (highway): uses [340, 480] m forward window')

  -- Tangent snapping: aligns BOTH highway and rural road edges to forward tangent (never reversed)
  local sx1, sy1 = N.snapRoadTangent(0.94, 0.34, { highway = true, dx = 1, dy = 0, oneWay = true })
  T.check(math.abs(sx1 - 1) < 1e-6 and math.abs(sy1) < 1e-6,
    'snapRoadTangent (highway): angled player heading snaps strictly to forward highway tangent')
  local sx2, sy2 = N.snapRoadTangent(0.98, 0.20, { highway = true, dx = -1, dy = 0, oneWay = true })
  T.check(math.abs(sx2 - 1) < 1e-6 and math.abs(sy2) < 1e-6,
    'snapRoadTangent (highway): never reverses against player travel direction')
  local sx3, sy3 = N.snapRoadTangent(0.85, 0.52, { highway = false, dx = 1, dy = 0, oneWay = false })
  T.check(math.abs(sx3 - 1) < 1e-6 and math.abs(sy3) < 1e-6,
    'snapRoadTangent (rural): snaps rural horizon spawn heading strictly to road edge tangent')
  local sx4, sy4 = N.snapRoadTangent(0.90, -0.43, { highway = false, dx = -1, dy = 0, oneWay = false })
  T.check(math.abs(sx4 - 1) < 1e-6 and math.abs(sy4) < 1e-6,
    'snapRoadTangent (rural): flips reversed rural edge to match player travel direction')

  -- Smooth highway cruise initialization: NEVER fires thrusters.applyVelocity
  local rsCmds = {}
  local rsObj = { queueLuaCommand = function(_, c) rsCmds[#rsCmds + 1] = c end }
  local vTruck, cTruck, tx, ty = N.applyHighwayRollingStart(501, rsObj, 0.96, 0.28, { persona = 'truck' },
    { highway = true, dx = 1, dy = 0, oneWay = true })
  T.check(vTruck and vTruck >= 85 / 3.6 - 1e-6 and vTruck <= 90 / 3.6 + 1e-6 and vTruck >= 22.0,
    'applyHighwayRollingStart (truck): 85-90 km/h (>= 22 m/s)')
  T.check(math.abs(tx - 1) < 1e-6 and math.abs(ty) < 1e-6,
    'applyHighwayRollingStart (truck): heading snapped strictly to highway tangent')
  T.check(cTruck and not cTruck:find('thrusters.applyVelocity', 1, true)
    and cTruck:find('ai.driveInLane("on")', 1, true)
    and cTruck:find('ai.setSpeedMode("legal")', 1, true)
    and cTruck:find('ai.setSpeed(', 1, true),
    'applyHighwayRollingStart: initializes smooth AI cruise without thrusters.applyVelocity impulse')

  local vBus = N.applyHighwayRollingStart(502, rsObj, 1, 0, { persona = 'bus' }, { highway = true, dx = 1, dy = 0 })
  T.check(vBus and vBus >= 85 / 3.6 - 1e-6 and vBus <= 90 / 3.6 + 1e-6 and vBus >= 22.0,
    'applyHighwayRollingStart (bus): 85-90 km/h (>= 22 m/s)')

  local vComm = N.applyHighwayRollingStart(503, rsObj, 1, 0, { persona = 'commuter' }, { highway = true, dx = 1, dy = 0 })
  local vCour = N.applyHighwayRollingStart(504, rsObj, 1, 0, { persona = 'courier' }, { highway = true, dx = 1, dy = 0 })
  local vSpd = N.applyHighwayRollingStart(505, rsObj, 1, 0, { persona = 'speeder' }, { highway = true, dx = 1, dy = 0 })
  T.check(vComm and vComm >= 115 / 3.6 - 1e-6 and vComm <= 135 / 3.6 + 1e-6,
    'applyHighwayRollingStart (commuter): 115-135 km/h')
  T.check(vCour and vCour >= 115 / 3.6 - 1e-6 and vCour <= 135 / 3.6 + 1e-6,
    'applyHighwayRollingStart (courier): 115-135 km/h')
  T.check(vSpd and vSpd >= 115 / 3.6 - 1e-6 and vSpd <= 135 / 3.6 + 1e-6,
    'applyHighwayRollingStart (speeder): 115-135 km/h')
  T.check(N.applyHighwayRollingStart(506, rsObj, 1, 0, { persona = 'commuter' }, { highway = false, dx = 1, dy = 0 }) == nil,
    'applyHighwayRollingStart: returns nil on non-highway roads')

  -- End-to-end updateTrafficDirector on an Autobahn highway:
  -- 1) behind-player recycle uses [340, 480] m window, snaps heading to highway tangent (1,0), smooth AI cruise (no thrusters)
  -- 2) newly spawned / stalled highway car (< 12 m/s, no stop reason) gets smooth AI cruise init (no thrusters)
  -- 3) cruising (>= 12 m/s) or disabled highway cars are not boosted
  N.reset()
  N.enabled = true
  local sg = { gameplay_traffic = rawget(_G, 'gameplay_traffic'), getObjectByID = rawget(_G, 'getObjectByID'),
               be = rawget(_G, 'be'), core_camera = rawget(_G, 'core_camera'), map = rawget(_G, 'map'),
               jsonDecode = rawget(_G, 'jsonDecode'), readFile = rawget(_G, 'readFile') }
  local clock0 = os.clock
  os.clock = function() return 4000 end
  local function v(ax, ay, az)
    return { x = ax, y = ay, z = az or 0, length = function(s) return math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) end }
  end
  local hwyEdge = {
    inNode = 'h0', outNode = 'h1', oneWay = true, highway = true, unlimited = true,
    speedLimit = 36.11, lanes = '+++', lanesOut = 3, lanesIn = 0, inRadius = 5.4, outRadius = 5.4,
  }
  local hwyNodes = {
    h0 = { pos = v(-600, 0, 0), radius = 5.4, links = { h1 = hwyEdge } },
    h1 = { pos = v(600, 0, 0), radius = 5.4, links = { h0 = hwyEdge } },
  }
  map = {
    getMap = function() return { nodes = hwyNodes } end,
    findClosestRoad = function() return 'h0', 'h1' end,
  }
  local cmdsById, tports = {}, {}
  local function makeCar(id, px, py, vx, vy, dx, dy)
    cmdsById[id] = {}
    return {
      getActive = function() return true end,
      getPosition = function() return v(px, py, 0) end,
      getVelocity = function() return v(vx, vy, 0) end,
      getDirectionVector = function() return v(dx, dy, 0) end,
      queueLuaCommand = function(_, c) cmdsById[id][#cmdsById[id] + 1] = c end,
    }
  end
  local objs = {
    [401] = makeCar(401, -500, 0, 28, 0, 1, 0), -- > 420 m behind -> recycled ahead on highway
    [402] = makeCar(402, 120, 0, 2, 0, 1, 0),   -- newly spawned / stalled (< 12 m/s) on highway -> smooth cruise init
    [403] = makeCar(403, 200, 0, 32, 0, 1, 0),  -- already cruising (>= 12 m/s) -> not boosted
    [404] = makeCar(404, 240, 0, 0, 0, 1, 0),   -- disabled on highway -> not boosted
  }
  getObjectByID = function(id) return objs[id] end
  be = { getPlayerVehicleID = function() return 1 end }
  core_camera = { getPosition = function() return v(0, 0, 0) end }
  gameplay_traffic = {
    getState = function() return 'on' end,
    getTrafficData = function()
      return {
        [401] = { isAi = true, model = 'vivace', config = '160_diesel', respawnCount = 0 },
        [402] = { isAi = true, model = 'semi', config = 't75_hauler', respawnCount = 0 },
        [403] = { isAi = true, model = 'etk800', config = '854d_wagon', respawnCount = 0 },
        [404] = { isAi = true, model = 'vivace', config = '160_diesel', respawnCount = 0, state = 'disabled' },
      }
    end,
    forceTeleport = function(id, pos, dir, dmin, dmax)
      tports[#tports + 1] = { id = id, pos = pos, dir = dir, dmin = dmin, dmax = dmax }
    end,
  }
  -- Player moving slightly angled across lane (vx=36, vy=6) on eastbound Autobahn
  N.updateTrafficDirector(0.30, { x = 0, y = 0, z = 0, vx = 36, vy = 6 }, hwyBox)
  T.check(#tports == 1 and tports[1].id == 401 and tports[1].dmin == 340 and tports[1].dmax == 480,
    'director (highway): recycles behind-player vehicle into [340, 480] m forward window')
  T.check(math.abs(tports[1].dir.x - 1) < 1e-6 and math.abs(tports[1].dir.y) < 1e-6,
    'director (highway): snaps forceTeleport heading strictly to forward highway tangent (1, 0)')
  local function hasSmoothCruiseCmd(list)
    for _, c in ipairs(list or {}) do
      if c:find('ai.setSpeed(', 1, true) and c:find('ai.driveInLane("on")', 1, true)
          and not c:find('thrusters.applyVelocity', 1, true) then
        return true
      end
    end
    return false
  end
  local function hasThrusterCmd(list)
    for _, c in ipairs(list or {}) do
      if c:find('thrusters.applyVelocity', 1, true) then return true end
    end
    return false
  end
  T.check(hasSmoothCruiseCmd(cmdsById[401]) and not hasThrusterCmd(cmdsById[401]),
    'director (highway): initializes smooth AI cruise without thrusters.applyVelocity after forceTeleport')
  T.check(hasSmoothCruiseCmd(cmdsById[402]) and not hasThrusterCmd(cmdsById[402]),
    'director (highway): initializes smooth AI cruise on stalled/newly-spawned highway vehicle (< 12 m/s)')
  T.check(not hasSmoothCruiseCmd(cmdsById[403]),
    'director (highway): does not re-init vehicle already cruising >= 12 m/s')
  T.check(not hasSmoothCruiseCmd(cmdsById[404]),
    'director (highway): does not boost disabled vehicle with valid stop reason')

  -- Rural road horizon spawn: snaps heading to rural road edge tangent AND skips when nearJunction(ax, ay, 45)
  N.reset()
  N.enabled = true
  local ruralEdge = {
    inNode = 'r0', outNode = 'r1', oneWay = false, highway = false, unlimited = false,
    speedLimit = 22.2, lanes = '-+', lanesOut = 1, lanesIn = 1, inRadius = 3.5, outRadius = 3.5,
  }
  local ruralNodes = {
    r0 = { pos = v(-600, 0, 0), radius = 3.5, links = { r1 = ruralEdge } },
    r1 = { pos = v(600, 0, 0), radius = 3.5, links = { r0 = ruralEdge } },
  }
  map = {
    getMap = function() return { nodes = ruralNodes } end,
    findClosestRoad = function() return 'r0', 'r1' end,
  }
  local ruralTports = {}
  local ruralObj = makeCar(410, -500, 0, 15, 0, 1, 0)
  getObjectByID = function(id) return id == 410 and ruralObj or nil end
  gameplay_traffic = {
    getState = function() return 'on' end,
    getTrafficData = function()
      return { [410] = { isAi = true, model = 'vivace', config = '160_diesel', respawnCount = 0 } }
    end,
    forceTeleport = function(id, pos, dir, dmin, dmax)
      ruralTports[#ruralTports + 1] = { id = id, pos = pos, dir = dir, dmin = dmin, dmax = dmax }
    end,
  }
  -- Load a graph with a 3-way junction at (20, 0) (within 45 m of player origin (0, 0))
  readFile = function() return '{}' end
  jsonDecode = function()
    return {
      nodes = { j = { 20, 0, 0, 4 }, w = { -200, 0, 0, 4 }, e = { 400, 0, 0, 4 }, n = { 20, 200, 0, 4 } },
      edges = { { 'w', 'j', 0, 1, 1, 22.2, 1, 4 }, { 'j', 'e', 0, 1, 1, 22.2, 1, 4 }, { 'j', 'n', 0, 1, 1, 22.2, 1, 4 } },
    }
  end
  N.onMessage({ anchorId = 1, path = 'x', serial = 1 }, 1)
  N.updateTrafficDirector(0.30, { x = 0, y = 0, z = 0, vx = 20, vy = 5 }, hwyBox)
  T.check(#ruralTports == 0, 'director: skips horizon teleport when nearJunction(ax, ay, 45) is true')

  -- Move player & camera away from junction to (-100, 0) (120 m from junction): rural horizon spawn succeeds & snaps to (1, 0)
  ruralObj.getPosition = function() return v(-600, 0, 0) end
  core_camera = { getPosition = function() return v(-100, 0, 0) end }
  os.clock = function() return 4020 end
  N.updateTrafficDirector(0.30, { x = -100, y = 0, z = 0, vx = 20, vy = 5 }, { -800, -600, 600, 600 })
  T.check(#ruralTports == 1 and ruralTports[1].dmin == 160 and ruralTports[1].dmax == 340
    and math.abs(ruralTports[1].dir.x - 1) < 1e-6 and math.abs(ruralTports[1].dir.y) < 1e-6,
    'director (rural): snaps rural horizon forceTeleport heading strictly to road edge tangent (1, 0)')

  os.clock = clock0
  for k, val in pairs(sg) do _G[k] = val end
  N.reset()
end

-- 10. Deferred Post-Spawn partsTree Delivery Skins, Recycling Persistence & Anti-Loop Guards
do
  local sg = {}
  local keys = {
    'gameplay_traffic', 'getObjectByID', 'core_vehicle_partmgmt', 'core_vehicle_manager',
    'core_camera', 'map', 'be', 'simTimeAuthority', 'os', 'readFile', 'jsonDecode',
  }
  for _, k in ipairs(keys) do sg[k] = rawget(_G, k) end
  local function v(x, y, z) return { x = x, y = y, z = z or 0 } end
  readFile = function() return '{}' end
  jsonDecode = function() return { nodes = { n0 = { 0, 0, 0, 4 }, n1 = { 10, 0, 0, 4 } }, edges = { { 'n0', 'n1', 0, 1, 1, 13.8, 1, 4 } } } end
  local clock0 = os.clock
  local simNow = 5000
  os.clock = function() return simNow end
  simTimeAuthority = { getPause = function() return false end }
  be = { getPlayerVehicleID = function() return -1 end }
  core_camera = { getPosition = function() return v(0, 0, 0) end }

  local townEdge = {
    inNode = 't0', outNode = 't1', oneWay = false, highway = false, unlimited = false,
    speedLimit = 13.8, lanes = '-+', lanesOut = 1, lanesIn = 1, inRadius = 3.5, outRadius = 3.5,
  }
  local townNodes = {
    t0 = { pos = v(-200, 0, 0), radius = 3.5, links = { t1 = townEdge } },
    t1 = { pos = v(200, 0, 0), radius = 3.5, links = { t0 = townEdge } },
  }
  map = {
    getMap = function() return { nodes = townNodes } end,
    findClosestRoad = function() return 't0', 't1' end,
  }

  local function makePartsTree(bodyPart, paintChosen, paintSuitable, boxSlot, boxSuitable)
    local children = {
      van_body = { id = 'van_body', chosenPartName = bodyPart or 'van_body_cargo' },
      van_engine = { id = 'van_engine', chosenPartName = 'van_engine_v8' },
      paint_design = {
        id = 'paint_design',
        chosenPartName = paintChosen or '',
        suitablePartNames = paintSuitable or {},
      },
    }
    if boxSlot then
      children[boxSlot] = {
        id = boxSlot,
        chosenPartName = '',
        suitablePartNames = boxSuitable or {},
      }
    end
    return { id = 'main', chosenPartName = 'van', children = children }
  end

  local configs = {}
  local vehObjects = {}
  local trafficData = {}
  local respawnCalls = {}
  local dynFields = {}
  local posRestores = {}
  local aiModes = {}

  local function makeLiveCar(id, model, partConfigPath, x, y, vx, vy)
    local pos = v(x, y, 0)
    local vel = v(vx or 8, vy or 0, 0)
    local dir = v(1, 0, 0)
    local cmds = {}
    dynFields[id] = {}
    local obj = {
      partConfig = partConfigPath,
      _cmds = cmds,
      getActive = function() return true end,
      getJBeamFilename = function() return model end,
      getPosition = function() return pos end,
      getRotation = function() return { x = 0, y = 0, z = 0, w = 1 } end,
      getVelocity = function() return vel end,
      getDirectionVector = function() return dir end,
      setDynDataFieldbyName = function(_, k, _, val) dynFields[id][k] = val end,
      setPosRot = function(_, nx, ny, nz)
        pos = v(nx, ny, nz)
        posRestores[id] = (posRestores[id] or 0) + 1
      end,
      queueLuaCommand = function(_, c) cmds[#cmds + 1] = c end,
    }
    vehObjects[id] = obj
    return obj
  end

  core_vehicle_manager = {
    getVehicleData = function(id)
      local cfg = configs[id]
      if not cfg then return nil end
      return { config = cfg }
    end,
  }
  core_vehicle_partmgmt = {
    getConfigOfVehicle = function(id) return configs[id] end,
    setConfigOfVehicle = function(obj, inData, respawn)
      local vid
      for id, o in pairs(vehObjects) do if o == obj then vid = id break end end
      respawnCalls[#respawnCalls + 1] = { id = vid, inData = inData, respawn = respawn }
      if vid and inData and inData.partsTree then
        configs[vid].parts = nil
        configs[vid].partsTree = inData.partsTree
        -- Simulate BeamNG's onVehicleSpawned firing synchronously with traffic resetting useRandomPaint
        if trafficData[vid] then
          trafficData[vid].useRandomPaint = true
        end
        N.onVehicleSpawned(vid)
      end
    end,
  }
  getObjectByID = function(id) return vehObjects[id] end
  gameplay_traffic = {
    getState = function() return 'on' end,
    getTrafficData = function() return trafficData end,
  }

  -- 10a. Deferred post-spawn partsTree application: waits for respawnActive=false and partsTree ready,
  -- applies paint_design via partsTree (preserving sibling parts), prevents player auto-enter, clears useRandomPaint,
  -- and does NOT trigger spawn loops on onVehicleSpawned.
  N.reset()
  N.enabled = true
  N.trafficRegion = 'europe'
  makeLiveCar(901, 'van', 'vehicles/van/h15_vanster_cargo.pc', 0, 0, 8, 0)
  trafficData[901] = {
    isAi = true, model = 'van', respawnCount = 0, respawnActive = true, state = 'reset', useRandomPaint = true,
    setAiMode = function(_, m) aiModes[901] = m end,
  }
  -- Tick 1: vehicle still mid-spawn (respawnActive=true, no partsTree yet) -> deferred, 0 respawns!
  N.updateTrafficDirector(0.30, { x = 0, y = 0, z = 0, vx = 0, vy = 0 })
  T.check(#respawnCalls == 0,
    'deferred livery: waits while respawnActive=true / partsTree unready without calling partmgmt')
  T.check(N.getVehiclePersona(901) and N.getVehiclePersona(901).persona == 'commuter',
    'deferred livery: unskinned van does not act as courier before livery is applied')

  -- Traffic spawn finishes: partsTree is now populated with vanilla + mod skins (Beamcom, HHL, Nile, Post-It)
  trafficData[901].respawnActive = false
  trafficData[901].state = 'active'
  configs[901] = {
    partConfigFilename = 'vehicles/van/h15_vanster_cargo.pc',
    partsTree = makePartsTree('van_body_cargo', '', {
      'van_skin_police', 'van_skin_twotone', 'van_skin_beamcom', 'van_skin_hhl', 'van_skin_nile', 'van_skin_Post-ItDelivery',
    }),
  }
  -- Tick 2: defer window elapsed -> applies paint_design via partsTree once!
  simNow = 5001
  N.updateTrafficDirector(0.45, { x = 0, y = 0, z = 0, vx = 0, vy = 0 })
  T.check(#respawnCalls == 1 and respawnCalls[1].id == 901,
    'deferred livery: applies paint_design exactly once after traffic spawn init completes')
  T.check(respawnCalls[1].inData.partsTree ~= nil and respawnCalls[1].inData.parts == nil,
    'deferred livery: mutates modern partsTree (not obsolete flat .parts) so sibling slots stay intact')
  T.check(configs[901].partsTree.children.van_body.chosenPartName == 'van_body_cargo'
    and configs[901].partsTree.children.van_engine.chosenPartName == 'van_engine_v8',
    'deferred livery: preserves cargo body and engine slots inside partsTree')
  local appliedSkin901 = configs[901].partsTree.children.paint_design.chosenPartName
  T.check(appliedSkin901 == 'van_skin_hhl' or appliedSkin901 == 'van_skin_nile'
    or appliedSkin901 == 'van_skin_Post-ItDelivery' or appliedSkin901 == 'van_skin_beamcom',
    'deferred livery: selects valid delivery paint_design from partsTree.suitablePartNames')
  T.check(dynFields[901].autoEnterVehicle == 'false',
    'deferred livery: sets autoEnterVehicle="false" before respawn so player is never pulled into AI van')
  T.check(trafficData[901].useRandomPaint == false and aiModes[901] == 'traffic',
    'deferred livery: clears useRandomPaint and restores AI traffic mode in onVehicleSpawned')
  T.check(N.getVehiclePersona(901) and N.getVehiclePersona(901).persona == 'courier',
    'deferred livery: promotes skinned cargo van to courier persona once paint_design is applied')

  -- Tick 3: steady-state ticks never re-apply (anti-loop guard)
  simNow = 5002
  N.updateTrafficDirector(0.30, { x = 0, y = 0, z = 0, vx = 0, vy = 0 })
  T.check(#respawnCalls == 1, 'deferred livery: steady-state ticks cause zero extra respawns (no spawn loop)')

  -- 10b. Persistence across traffic pool recycling (forceTeleport / respawnCount increment / onVehicleSwitched):
  -- Skin still intact -> keeps useRandomPaint=false with ZERO respawns!
  trafficData[901].respawnCount = 1
  trafficData[901].useRandomPaint = true
  N.onVehicleSwitched(901, 100, 0)
  simNow = 5003
  N.updateTrafficDirector(0.30, { x = 0, y = 0, z = 0, vx = 0, vy = 0 })
  T.check(#respawnCalls == 1 and trafficData[901].useRandomPaint == false,
    'recycling persistence: intact paint_design after respawnCount/switch needs zero respawns and re-locks useRandomPaint=false')

  -- If an external reload wipes paint_design, director re-applies the persisted skin cleanly once!
  configs[901].partsTree.children.paint_design.chosenPartName = ''
  N.onVehicleSpawned(901)
  simNow = 5004
  N.updateTrafficDirector(0.45, { x = 0, y = 0, z = 0, vx = 0, vy = 0 })
  T.check(#respawnCalls == 2 and configs[901].partsTree.children.paint_design.chosenPartName == appliedSkin901,
    'recycling persistence: re-applies persisted paint_design if an external reload cleared it')

  -- 10c. md_series dual-slot skinning (paint_design + skin_md_series_cargobox)
  makeLiveCar(902, 'md_series', 'vehicles/md_series/md70_boxtruck.pc', 20, 0, 8, 0)
  trafficData[902] = { isAi = true, model = 'md_series', respawnCount = 0, respawnActive = false, state = 'active', useRandomPaint = true }
  configs[902] = {
    partConfigFilename = 'vehicles/md_series/md70_boxtruck.pc',
    partsTree = makePartsTree('md_series_cab_reg', '', { 'md_series_skin_hhl', 'md_series_skin_bps' },
      'skin_md_series_cargobox', { 'md_series_cargobox_skin_hhl', 'md_series_cargobox_skin_bps' }),
  }
  simNow = 5005
  N.updateTrafficDirector(0.30, { x = 0, y = 0, z = 0, vx = 0, vy = 0 })
  local mdCabSkin = configs[902].partsTree.children.paint_design.chosenPartName
  local mdBoxSkin = configs[902].partsTree.children.skin_md_series_cargobox.chosenPartName
  T.check((mdCabSkin == 'md_series_skin_hhl' and mdBoxSkin == 'md_series_cargobox_skin_hhl')
    or (mdCabSkin == 'md_series_skin_bps' and mdBoxSkin == 'md_series_cargobox_skin_bps'),
    'md_series dual-slot: applies matching brand livery to both paint_design and skin_md_series_cargobox')

  -- 10d. Windowed passenger van detected via obj.partConfig AND via partsTree body clue -> never courier, never skinned!
  local beforeRespawns = #respawnCalls
  makeLiveCar(903, 'van', 'vehicles/van/h15_vanster_passenger.pc', 40, 0, 8, 0)
  trafficData[903] = { isAi = true, model = 'van', respawnCount = 0, respawnActive = false, state = 'active' }
  configs[903] = {
    partConfigFilename = 'vehicles/van/h15_vanster_passenger.pc',
    partsTree = makePartsTree('van_body_passenger', '', { 'van_skin_beamcom', 'van_skin_hhl' }),
  }
  -- 10e. Unbranded vehicle with ZERO delivery paint_design parts in suitablePartNames -> downgraded to commuter, no courier stops!
  makeLiveCar(904, 'pickup', 'vehicles/pickup/d15_cargobox.pc', 60, 0, 8, 0)
  trafficData[904] = { isAi = true, model = 'pickup', respawnCount = 0, respawnActive = false, state = 'active' }
  configs[904] = {
    partConfigFilename = 'vehicles/pickup/d15_cargobox.pc',
    partsTree = makePartsTree('pickup_cargobox', '', { 'pickup_skin_old', 'pickup_skin_twotone' }),
  }
  N.onDeliveryPoints('t_unbranded', { { x = 65, y = 2, z = 0 } })
  simNow = 5006
  N.updateTrafficDirector(0.30, { x = 0, y = 0, z = 0, vx = 0, vy = 0 })
  T.check(#respawnCalls == beforeRespawns,
    'strict courier filter: neither windowed passenger van nor unbranded pickup triggers livery respawn')
  T.check(N.getVehiclePersona(903) and N.getVehiclePersona(903).persona ~= 'courier'
    and not N.isCourierDwelling(903),
    'strict courier filter: windowed passenger config (from obj.partConfig/partsTree) never receives courier stops')
  T.check(N.getVehiclePersona(904) and N.getVehiclePersona(904).persona == 'commuter'
    and not N.isCourierDwelling(904),
    'strict courier filter: unbranded cargo pickup without delivery livery drives as commuter and never takes courier stops')

  -- 10f. navgraph.transform rebases anchor-tile deliveryPoints alongside busStops
  N.onDeliveryPoints('a1:0_0', { { x = 100, y = 200, z = 5 } })
  local xf = { apply = function(_, x, y, z) return x + 10, y - 20, z + 1 end }
  -- Seed a minimal graph so transform() executes
  N.onMessage({ anchorId = 1, path = 'x', serial = 2 }, 1)
  N.transform(xf, 2)
  local dp = N.deliveryPoints()['a1:0_0']
  T.check(dp and dp[1] and dp[1].x == 110 and dp[1].y == 180 and dp[1].z == 6,
    'transform: rebases anchor-tile deliveryPoints into the new anchor frame')

  os.clock = clock0
  for k, val in pairs(sg) do _G[k] = val end
  N.reset()
end

T.done('test_navgraph')
