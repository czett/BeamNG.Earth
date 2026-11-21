-- The AI road graph (server/navgraph.py, --traffic on) handed to the game's own navgraph with
-- map.reset(customNodes) (docs/research/2026-10-10-navgraph-traffic-signals.md §2.4-2.8, the plan in §8): BeamNG's
-- traffic and AI then drive our streamed roads. The server sends a graph around the player every ~400 m; this
-- module clips it to the terrain block (the only collidable ground, minus EDGE_M) and applies it whenever a new
-- graph arrives or the block moved, at most every MIN_GAP_S.
--
-- The custom map path's pitfalls (research §2.7), each handled here: vehicles are told to fetch the new graph
-- (mapmgr.requestMap); the node table object stays the same one across resets (gameplay_traffic caches it); every
-- edge carries its speed limit and lanes; the road rules come from a file of ours (the level's info.json has none);
-- a reset by someone else (map.reset() with no graph rebuilds an empty one from our level) is undone next frame.
local M = {}
local localplayers = require('beamngEarth/localplayers')
local overtake = require('beamngEarth/overtake')
local controlled = {}

M.EDGE_M = 60           -- graph nodes this far inside the block's ground box only
M.MIN_GAP_S = 1.0
-- m past the block's ground box (less EDGE_M) the graph's nodes are kept for the AI's route planning (GitHub #657 /
-- #279: the map ended a few hundred metres ahead, the AI planned back the other way and turned round in the road);
-- the cuts (headingToCut) and the guard stay at the box: a car is respawned before it leaves the ground. 0: off.
M.HALO_M = 0
-- ... but the fast roads' nodes (edges at FAST_HALO_MS or more: motorways, fast trunk roads) are kept FAST_HALO_M past it:
-- a highway's graph ended ~450 m ahead, so a traffic car placed there (the stock traffic's respawns go 100-500 m in
-- front of the camera) braked for the dead end and turned round across the lanes: the cars standing sideways on I-94 /
-- I-90 in Montana (Tann2019, 2026-11-05; PR #728's route halo, there for blocks over 1200 m only). A motorway's nodes are
-- ~80 m apart: a few dozen nodes, not the tripled city graph of HALO_M.
-- Off for now (0): PR #773's merge A/B (autodrive east of Billings with traffic, two warm runs each, 2026-11-06) had
-- 87.9 / 84.5 fps with it at 650 m against 92.8 / 88.2 with it off and 91.7 / 88.5 before the merge, and 89 frames
-- over 50 ms in PhysicsAndVLUA in one run (the traffic AI's planning on the longer graph); launch, oncoming spawns and
-- overtaking cost nothing measurable. 650 to try it.
M.FAST_HALO_M = 0
M.FAST_HALO_MS = 24.5     -- (55 mph)
-- An apply (or its signals' second step) waits for a light frame (governor roomFor: at most APPLY_ROOM_MS of streaming
-- and other work spent in it, not a terrain commit's), APPLY_WAIT_FRAMES at most
M.APPLY_ROOM_MS = 4.0
M.APPLY_WAIT_FRAMES = 30
-- The block moved this far from where the graph was last clipped: clipped again to the new block (the server's graph
-- reaches WINDOW_M = 1100 m, the block ~450 m; without it the graph ran out ahead of a car driving on before the next
-- graph came, every 400 m: the GPS arrows ended and the autodrive stopped, the user's Cannonball run 2026-10-14)
M.RECLIP_M = 150
M.UI_MAP = false        -- send our graph to the UI (the big map) on every apply
M.RULES_FILE = '/temp/beamngEarth/roadRules.json'
M.rules = { rightHandDrive = false, turnOnRed = true }    -- US; `rightHandDrive = true` means driving on the left
M.enabled = true
-- Traffic (gameplay_traffic, the player's traffic amount): started once the first graph is in the map; unoccupied AI
-- within GUARD_M of the block's edge (or past it, where there is no ground) is respawned on the graph
-- (gameplay_traffic.forceTeleport), checked every GUARD_S; after a teleport the AI is respawned when the new graph is in.
M.GUARD_M = 40
M.GUARD_S = 0.5
-- A car standing still this long (longer than a signal cycle), this far from the player, is respawned too: stock
-- traffic respawns only cars far away and out of sight, so one wedged on a corner the map's road cuts through a
-- building, or queued behind the player's parked car in a one-lane street, stood for good (Frederick, Fells Point
-- 2026-10-14)
M.STUCK_S = 45
M.STUCK_MS = 0.5
M.STUCK_FAR_M = 40
M.RESPAWN_M = { 60, 300 }   -- a respawned car goes this far (min, max) behind the camera
-- A car heading for a graph node whose road the clip cut off (within 45 degrees, CUT_M or CUT_S of driving away) is
-- respawned too: to the AI the cut is a dead end, and a car spawned facing one made a three-point turn on the spot
-- (GitHub #72, "spawns the wrong way and tries to turn around immediately"; Bathurst 2026-10-21: 20 m from a cut)
-- A car that has just appeared (FRESH_S) turns round for a cut much farther ahead (Bathurst: 89 m): CUT_FRESH_M
-- (250 m sent cars respawned near a cut straight back again: traffic popping in and out, PR #493, OmdevShastri).
-- A car respawned for a cut or for standing still is not respawned for those again within COOLDOWN_S (one that
-- leaves the block's guard still is at once).
M.CUT_M = 60
M.CUT_S = 4
M.CUT_FRESH_M = 95
-- ... and at least as far as the car needs to stop for it (its speed squared over 2 CUT_DECEL, CUT_STOP_M more): the
-- AI plans to the end of the graph and brakes for the dead end long before 4 s from it; at 70 mph it braked from
-- ~200 m and turned round across the lanes ahead of the player, every half minute on a motorway (GitHub #855 / #966)
M.CUT_DECEL = 2.5
M.CUT_STOP_M = 30
M.FRESH_S = 5
M.COOLDOWN_S = 8.0
-- A car that reached the cut no longer heads for it: it stopped at the dead end at an angle, or it is turning round
-- across the road (the AI's three-point turn: crawling through the swing, reversing, or standing across its road's
-- axis), so headingToCut's 45-degree test let it go and it waited for the generic stuck timer — STUCK_S (45 s), and
-- only STUCK_FAR_M or more from the player: time enough to block the lane and U-turn in front of the player
-- (GitHub #855, "happens everywhere PERMANENTLY", with #72 / #279 the history; driving slowly near Oceanside CA
-- 2026-11-10: cars stopping and U-turning constantly). Within CUT_NEAR_M of a cut, a car reversing, moving more
-- than CUT_TURN_COS off its road's axis or along a one-way road against it, or nearly stationary (under CUT_NEAR_MS)
-- while facing the dead end or standing across its road, is respawned at once — no STUCK_S wait; COOLDOWN_S and the
-- fresh-car window (FRESH_S, a freshly placed car stands still before its launch) still apply, and nothing is taken
-- while the game is paused. A car merely slow or stopped near a cut is not the cut's: a red light or a stop sign on
-- a through road of a junction the clip cut holds cars just there, aligned with their road and facing past the dead
-- end — those are left alone (cutStopped). Still uncaught: a car that completed its turn before a scan saw it and
-- stands or drives back along a two-way road reads as ordinary oncoming traffic and is left alone.
M.CUT_NEAR_M = 30
M.CUT_NEAR_MS = 2.5
M.CUT_TURN_COS = 0.5    -- (cos 60 degrees)
-- The guard is frame-timed: a long frame (streaming hitches, 0.3-5 s in session logs) runs between two scans, and a
-- car covers the whole gap unwatched — CUT_STOP_M's margin assumes a scan every GUARD_S, and the first frame after
-- the gap runs the scan at once but measured only the car's position now. That scan widens each car's cut reach
-- (cutReach), and JUMP_M's respawn-detection threshold, by the missed time at the car's speed, so the stretch it
-- drove meanwhile is still inside the window; capped at GUARD_LAG_MAX_S (a level load or a pause is not a hitch).
M.GUARD_LAG_MAX_S = 6
M.JUMP_M = 30           -- a car this much farther than at the last check was respawned (stock or ours)
-- At speed a car respawned behind the camera is never seen again: on a motorway every car ahead reached the block's
-- edge within ~30 s and reappeared behind the player, who drove alone (GitHub #353, Albany to New York). Faster than
-- AHEAD_MS, a respawned car goes ahead along the player's way instead, AHEAD_M (min, max) on, short of the block's
-- edge guard (a car popping in 100+ m ahead at motorway speed is hardly seen; in town it still goes behind).
M.AHEAD_MS = 20         -- (45 mph)
M.AHEAD_M = { 100, 200 }
-- ... and every other one on the other carriageway, ONCOMING_M ahead, facing the player: on a divided highway the cars
-- put ahead all went the player's way and the other carriageway stayed empty (Tann2019, I-94 2026-11-05: "is there a
-- way so that traffic goes both ways on the interstate"). The other carriageway is looked for ONCOMING_SIDE_M to the
-- side the oncoming traffic drives on (left in right-hand traffic): a one-way road there running against the player.
M.ONCOMING = true
M.ONCOMING_M = { 230, 170, 290 }
M.ONCOMING_SIDE_M = { 14, 20, 26, 34, 44, 56 }
M.ONCOMING_ON_M = 6     -- the point that far from the road at most
-- A respawned traffic car is launched at LAUNCH_SHARE of its road's limit, its wheels spinning with it (PR #728 by
-- ProxyFirewall202: spawnVelocityCommand and the vehicle's beamngEarth_spawnMotion): it came at 0 mph, so on a highway the
-- cars round the player crawled up from a standstill after every respawn (every 5-30 s at 65 mph) and the autodrive
-- behind them did 40 (Tann2019, Huntley to Billings 2026-11-05). Not near a junction (LAUNCH_JUNCTION_M), not facing
-- off its road (LAUNCH_ALIGN) or against a one-way road; looked at every LAUNCH_SCAN_S, once the stock traffic has placed
-- it (LAUNCH_DELAY_S after it is active), given up after LAUNCH_TIMEOUT_S.
M.LAUNCH = true
M.LAUNCH_SHARE = 0.9
M.LAUNCH_MIN_MS = 8
M.LAUNCH_ALIGN = 0.94     -- (cos 20 degrees)
M.LAUNCH_JUNCTION_M = 20
M.LAUNCH_SCAN_S = 0.15
M.LAUNCH_DELAY_S = 0.4      -- (0.12 in PR #728: a launch 0.12 s after a respawn once read 63,000 mph, the car teleported again under it)
M.LAUNCH_TIMEOUT_S = 6
-- (gameplay_walk: 0.40's traffic.lua calls gameplay_walk.addVehicleToBlacklist when it activates its cars, and this
-- level had none loaded: the cars spawned and never drove, 2026-10-19)
M.EXTENSIONS = { 'core_multiSpawn', 'gameplay_traffic', 'gameplay_walk' }

local graph = nil       -- the server's last graph {anchor, nodes, edges}
local applied = nil     -- {anchor, serial, box} of the graph in the game's map now
local dirty = false
local lastApply = -math.huge
local persistent = nil  -- the node table handed out once (research §2.7.2)
local ours = false
local foreign = false
local urgent = false      -- a rebase moved the graph: applied again without waiting for MIN_GAP_S (M.transform)
M.HEADS_ONLY = true      -- setupSignals sees only our signal heads, not every TSStatic (applySignals)
local stats = { applies = 0, lastMs = 0, nodes = 0, edges = 0 }
-- (the stopwatch's wall clock for the parts of an apply; in the game os.clock reads the same, measured 2026-11-09 on
-- Linux and Windows)
local stopwatch = require('beamngEarth/stopwatch')
local wall = stopwatch.clock()       -- ms since load, monotonic (one clock: stopwatch.clock() makes a new one)
local pendingSignals = nil -- the clipped nodes whose signals go in next frame
local started = false
local respawnAll = false
local lastGuard = -math.huge
local cuts = {}         -- { x, y } of the applied graph's nodes that lost a road to the clip

-- Pure: point inside box {x0, y0, x1, y1} shrunk by m (no box: anywhere).
function M.inside(b, x, y, m)
  return not b or (x >= b[1] + m and x <= b[3] - m and y >= b[2] + m and y <= b[4] - m)
end

-- Pure: the lanes string of an edge (one char per lane, '+' along in -> out, '-' against; research §2.2), the
-- lanes against the direction first for right-hand traffic.
function M.lanes(out, back, leftHand)
  local plus, minus = string.rep('+', out), string.rep('-', back)
  return leftHand and (plus .. minus) or (minus .. plus)
end

-- A link steeper than this (rise over run) is left out of the graph: no car drives it, and the AI given a path over
-- one circled under it for ever (GitHub #131: Baltimore's East Eager Street, a bridge whose first node stood 6.4 m
-- over its junction with Greenmount Avenue 8 m away; the steepest real streets are ~0.37, San Francisco's).
M.MAX_GRADE = 0.45

-- Pure: is the link between graph nodes p and q ({x, y, z}) too steep to drive (MAX_GRADE)?
function M.tooSteep(p, q)
  local run = math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2)
  return math.abs(p[3] - q[3]) > M.MAX_GRADE * math.max(run, 1.0)
end

-- Contract isolated sub-metre seams on a continuous road with matching directed lane metadata. The stock marker
-- planner merges points this close, but the vehicle AI given both nodes can make a sharp lane adjustment and stop.
-- Keep junctions, clip boundaries, controls and changes in lanes/width/rules; the downstream node stays stable.
function M.compactShortEdges(nodes, protected)
  local function other(id, except)
    local found
    for nextId in pairs(nodes[id].links) do
      if nextId ~= except then if found then return nil end; found = nextId end
    end
    return found
  end
  local function lengthSq(a, b)
    return (a.x - b.x)^2 + (a.y - b.y)^2 + (a.z - b.z)^2
  end
  local function aligned(a, b, c, d)
    local dot = (b.x - a.x) * (d.x - c.x) + (b.y - a.y) * (d.y - c.y) + (b.z - a.z) * (d.z - c.z)
    return dot > 0.98 * math.sqrt(lengthSq(a, b) * lengthSq(c, d))
  end
  local function sameLanes(a, b)
    return a.oneWay == b.oneWay and a.lanes == b.lanes and a.drivability == b.drivability
      and a.rough == b.rough and a.rumble == b.rumble
      and a.highway == b.highway and a.unlimited == b.unlimited
  end
  local ids, removed = {}, 0
  for id in pairs(nodes) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, a in ipairs(ids) do
    local A = nodes[a]
    if A and not protected[a] then
      for b, e in pairs(A.links) do
        local B = nodes[b]
        if e.inNode == a and not protected[b] and lengthSq(A.pos, B.pos) <= 1 then
          local p, q = other(a, b), other(b, a)
          if p and q and p ~= q then
            local P, Q = nodes[p], nodes[q]
            local before, after = A.links[p], B.links[q]
            if before.inNode == p and after.inNode == b and sameLanes(before, e) and sameLanes(e, after)
              and before.outRadius == e.inRadius and e.inRadius == e.outRadius and e.outRadius == after.inRadius
              and e.speedLimit == after.speedLimit and e.posted == after.posted
              and lengthSq(P.pos, A.pos) > 1 and lengthSq(B.pos, Q.pos) > 1
              -- At <=5 cm, coordinate rounding can give the seam a zero or arbitrary direction.
              and ((aligned(P.pos, A.pos, A.pos, B.pos) and aligned(A.pos, B.pos, B.pos, Q.pos))
                or (lengthSq(A.pos, B.pos) <= 0.0025 and aligned(P.pos, A.pos, B.pos, Q.pos))) then
              P.links[a], B.links[a] = nil, nil
              P.links[b], B.links[p] = before, before
              before.outNode, before.outPos = b, B.pos
              nodes[a], removed = nil, removed + 1
              break
            end
          end
        end
      end
    end
  end
  return removed
end

-- Pure-ish (needs vec3): the stock map's node table of graph g clipped to box b: {name = {pos, radius,
-- links = {other = edge}}}, every edge shared by both ends (double-sided) with in/out nodes, positions and radii.
-- Returns nodes, node count, edge count and the cuts: { x, y } of each kept node with a road to a node left out.
function M.toNodes(g, b, edgeM, leftHand, yieldEvery, halo, fastHalo)
  local nodes, nn, ne = {}, 0, 0
  local keep = {}
  local fast = nil        -- (fastHalo: the nodes of the fast roads, FAST_HALO_MS)
  if fastHalo and fastHalo > 0 then
    fast = {}
    for _, e in ipairs(g.edges) do
      if (tonumber(e[6]) or 0) >= M.FAST_HALO_MS then fast[e[1]], fast[e[2]] = true, true end
    end
  end
  local phys = {}         -- (halo: the nodes kept past the box's edge for the AI's route planning; the cuts stay at it)
  local steps = 0
  local function step()       -- (in a coroutine: a pause every yieldEvery items, buildNodes)
    if yieldEvery then
      steps = steps + 1
      if steps % yieldEvery == 0 then coroutine.yield() end
    end
  end
  for name, n in pairs(g.nodes) do
    if M.inside(b, n[1], n[2], edgeM) then keep[name], phys[name] = n, true
    elseif halo and halo > 0 and M.inside(b, n[1], n[2], edgeM - halo) then keep[name] = n
    elseif fast and fast[name] and M.inside(b, n[1], n[2], edgeM - fastHalo) then keep[name] = n end
    step()
  end
  local function node(name)
    local t = nodes[name]
    if not t then
      local n = keep[name]
      t = { pos = vec3(n[1], n[2], n[3]), radius = n[4], links = {} }
      nodes[name] = t
      nn = nn + 1
    end
    return t
  end
  local cut, cutList = {}, {}
  for _, e in ipairs(g.edges) do
    step()
    local a, bb = e[1], e[2]
    for _, pair in ipairs({ { a, bb }, { bb, a } }) do
      local k = pair[1]
      if phys[k] and not phys[pair[2]] and g.nodes[pair[2]] and not cut[k] then
        cut[k] = true
        cutList[#cutList + 1] = { keep[k][1], keep[k][2] }
      end
    end
    if keep[a] and keep[bb] and a ~= bb and not M.tooSteep(keep[a], keep[bb]) then
      local A, B = node(a), node(bb)
      if not A.links[bb] then
        local edge = { drivability = e[7], oneWay = e[3] == 1, lanes = M.lanes(e[4], e[5], leftHand),
          lanesOut = e[4], lanesIn = e[5],
          speedLimit = e[6], inNode = a, outNode = bb, inPos = A.pos, outPos = B.pos,
          inRadius = e[8], outRadius = e[9] or e[8],      -- (e[9]: a road narrowing to a tunnel's portal)
          posted = e[10], rough = e[11] == true, rumble = e[12] == true,
          highway = (e[13] == 1 or e[13] == 2), unlimited = (e[13] == 2) } -- (e[13]: 1=highway, 2=unlimited DE Autobahn)
        A.links[bb] = edge
        B.links[a] = edge
        ne = ne + 1
      end
    end
  end
  -- A clipped-away arm must not turn a junction into an apparent degree-two seam.
  for _, sg in ipairs(g.signals or {}) do
    if sg.j then cut[sg.j] = true end
    for _, app in ipairs(sg.app or {}) do if app[1] then cut[app[1]] = true end end
  end
  local removed = M.compactShortEdges(nodes, cut)
  return nodes, nn - removed, ne - removed, cutList
end

M.FOLLOW_MS = 8         -- m/s the player moves at least for a car ahead going its way to keep going (followsPlayer)
M.FOLLOW_DOT = 0.7

-- Pure-ish (vectors with x, y): a traffic car at p moving along dir, ahead of a player at pp moving at pu, going the
-- player's way: the cut it heads for is the block's edge, which moves on with the player, so it is not respawned
-- for it (on a highway at 30 m/s a car ~200 m ahead was within the cut's reach and vanished in front of the player,
-- GitHub #353); it still is when it leaves the box (guard's GUARD_M).
-- How far ahead a car at sp m/s sees a dead end it will brake for (CUT_DECEL, CUT_STOP_M). Pure.
function M.stopReach(sp)
  return (sp or 0) ^ 2 / (2 * M.CUT_DECEL) + M.CUT_STOP_M
end

-- (car_sp: a car faster than the player by FOLLOW_FASTER_MS outruns the graph growing with the player: not following)
M.FOLLOW_FASTER_MS = 2.0
function M.followsPlayer(p, dir, pp, pu, car_sp)
  local ps = math.sqrt(pu.x * pu.x + pu.y * pu.y)
  local dl = math.sqrt(dir.x * dir.x + dir.y * dir.y)
  if ps < M.FOLLOW_MS or dl < 1e-6 then return false end
  if car_sp and car_sp > ps + M.FOLLOW_FASTER_MS then return false end
  local ux, uy = pu.x / ps, pu.y / ps
  if (dir.x * ux + dir.y * uy) / dl < M.FOLLOW_DOT then return false end
  return (p.x - pp.x) * ux + (p.y - pp.y) * uy > 0
end

-- Pure: how far a car at sp m/s sees a cut it heads for (CUT_M / CUT_S, CUT_FRESH_M when fresh, at least its
-- stopping distance), widened by the time the guard missed (lag s, a long frame) at the car's speed.
function M.cutReach(sp, fresh, lag)
  return math.max(fresh and M.CUT_FRESH_M or math.max(M.CUT_M, sp * M.CUT_S), M.stopReach(sp)) + (lag or 0) * sp
end

-- Pure: is a car at (px, py) within m of one of the cuts, whichever way it points?
function M.nearCut(px, py, list, m)
  for _, c in ipairs(list) do
    if (c[1] - px) ^ 2 + (c[2] - py) ^ 2 <= m * m then return true end
  end
  return false
end

-- Pure: has a car near a cut stopped at the dead end or begun its turn (CUT_NEAR_MS, CUT_TURN_COS)? sp its speed
-- (m/s), fwd its velocity along its facing (negative: reversing), roadDot the cosine of its direction of travel
-- (at a stand: its facing) with its road's in -> out direction (nil: no road found), oneWay that road's, facingCut
-- whether its facing points at a cut (headingToCut's cone). Merely slow or stopped is not enough: a red light or a
-- stop sign on a through road of a junction the clip cut holds a car just there, aligned with its road and facing
-- past the dead end — left alone.
function M.cutStopped(sp, fwd, roadDot, oneWay, facingCut)
  local turned = roadDot ~= nil
    and (math.abs(roadDot) < M.CUT_TURN_COS or (oneWay and roadDot < -M.CUT_TURN_COS)) or false
  if sp < M.CUT_NEAR_MS then
    return facingCut or turned                          -- stopped at the dead end, or stood across its road
  end
  return fwd < 0 or turned                              -- backing, across the road, or against a one-way road
end

-- Pure: is a car at (px, py) moving along unit (dx, dy) heading for one of the cuts within reach m (45 degrees)?
function M.headingToCut(px, py, dx, dy, list, reach)
  for _, c in ipairs(list) do
    local vx, vy = c[1] - px, c[2] - py
    local d = math.sqrt(vx * vx + vy * vy)
    if d <= reach and (d < 1 or (vx * dx + vy * dy) >= 0.7071 * d) then return true end
  end
  return false
end

function M.onMessage(msg, currentAnchor)
  if not M.enabled or msg.anchorId ~= currentAnchor then return false end
  local ok, g = pcall(jsonDecode, readFile(msg.path) or '')
  if not ok or type(g) ~= 'table' or type(g.nodes) ~= 'table' or type(g.edges) ~= 'table' then return false end
  graph = { anchor = msg.anchorId, serial = msg.serial, nodes = g.nodes, edges = g.edges,
            signals = type(g.signals) == 'table' and g.signals or {}, rules = type(g.rules) == 'table' and g.rules or nil,
            lines = type(g.lines) == 'table' and g.lines or nil,      -- (tunnel stretches: the minimap's, minimaproads)
            trafficProfile = type(g.trafficProfile) == 'table' and g.trafficProfile or nil,  -- (M.ADAPTIVE)
            mph = g.mph }       -- (the country's speed signs: api.speedLimit)
  dirty = true
  return true
end

-- Traffic signals and stop signs (core_trafficSignals, research §5): the server's controlled junctions whose
-- node and approach nodes are in the clipped graph. A signalled junction is one sequence of two phases (its
-- approaches split by axis, US lightsBasic timings from the approach speed), a stop junction shares one signStop
-- controller; an instance's pos is the stop point on its approach's right half, dir the travel direction.
M.SIGNAL_TYPE = 'lightsBasic'
-- the switchable head (the stock boom, instanced_trafficlight material): one TSStatic per approach where the
-- road tile's static boom stands (trees.lua's signal group is hidden while these exist)
M.SIGNAL_SHAPE = '/art/shapes/objects/s_trafficlight_boom_sn.dae'
local heads = {}        -- instance name -> {id, x, y}: the heads in the scene (kept across applies)
local seenHeads = {}

local function clearHeads(keep)
  for name, h in pairs(heads) do
    if not (keep and keep[name]) then
      local o = scenetree.findObjectById(h.id)
      if o then o:delete() end
      heads[name] = nil
    end
  end
end

-- A head for instance inst at a's prop transform: the one already standing there is kept (it is linked by
-- the instance's name, which stays the same: setupSignals finds it again), so a new graph costs only the new ones.
local function makeHead(inst, a)
  if not a[8] or not inst.createSignalObject then return end
  local shape = M.SIGNAL_SHAPE
  if a[12] == 1 then
    local left = require('beamngEarth/signalshape').ensureLeft()
    if not left then return end
    shape = left .. '.dae'
  end
  seenHeads[inst.name] = true
  local h = heads[inst.name]
  if h and h.shape == shape and math.abs(h.x - a[8]) < 0.05 and math.abs(h.y - a[9]) < 0.05
    and scenetree.findObjectById(h.id) then return end
  if h then
    local old = scenetree.findObjectById(h.id)
    if old then old:delete() end
  end
  local o = inst:createSignalObject(shape, vec3(a[8], a[9], a[10]), quat(0, 0, 0, 1))
  if not o then return end
  local m = MatrixF(true)
  m:setFromEuler(vec3(0, 0, -math.rad(a[11] or 0)))     -- as trees.lua turns the static boom (negated: clockwise)
  m:setPosition(vec3(a[8], a[9], a[10]))
  o:setTransform(m)
  heads[inst.name] = { id = o:getID(), x = a[8], y = a[9], shape = shape }
end

local function signalData(nodes)
  local ts = core_trafficSignals
  local inst, ctrls, seqs = {}, {}, {}
  local stop = nil
  local ns = 0
  for _, j in ipairs(graph.signals or {}) do
    local jn = nodes[j.j]
    if jn and type(j.app) == 'table' then
      local apps = {}
      for _, a in ipairs(j.app) do if nodes[a[1]] then apps[#apps + 1] = a end end
      if #apps > 0 then
        ns = ns + 1
        local cs = {}
        if j.kind == 'signal' then
          local speed = 13
          for _, l in pairs(jn.links) do speed = math.max(speed, l.speedLimit or 0) end
          for ph = 0, 1 do
            local c = ts.newController({ name = 'bne_' .. j.j .. '_' .. ph })
            c:applyDefinition(M.SIGNAL_TYPE)
            if c.autoSetTimings then c:autoSetTimings(speed, 2 * jn.radius + 6) end
            ctrls[#ctrls + 1] = c
            cs[ph] = c
          end
          local seq = ts.newSequence({ name = 'bne_' .. j.j, phases = { { controllerIds = { cs[0].id } },
            { controllerIds = { cs[1].id } } } })
          seqs[#seqs + 1] = seq
          for i, a in ipairs(apps) do
            local s = ts.newSignal({ name = 'bne_' .. j.j .. '_' .. i, pos = vec3(a[2], a[3], a[4]),
              dir = vec3(a[5], a[6], 0), controllerId = cs[a[7] == 1 and 1 or 0].id, sequenceId = seq.id })
            inst[#inst + 1] = s
            local okH, errH = pcall(makeHead, s, a)
            if not okH then log('W', 'beamngEarth', 'navgraph: signal head: ' .. tostring(errH)) end
          end
        else
          if not stop then
            stop = ts.newController({ name = 'bne_stop' })
            stop:applyDefinition('signStop')
            ctrls[#ctrls + 1] = stop
          end
          for i, a in ipairs(apps) do
            inst[#inst + 1] = ts.newSignal({ name = 'bne_' .. j.j .. '_' .. i, pos = vec3(a[2], a[3], a[4]),
              dir = vec3(a[5], a[6], 0), controllerId = stop.id })
          end
        end
      end
    end
  end
  return { instances = inst, controllers = ctrls, sequences = seqs }, ns
end

local function signalsSystem()
  if not core_trafficSignals and extensions and extensions.load then pcall(extensions.load, 'core_trafficSignals') end
  return core_trafficSignals
end

local function setRules()
  -- the country's rules (server navgraph.road_rules): driving side, turn on red, red+yellow before green
  local r = graph.rules
  if r then
    M.rules = { rightHandDrive = r.rightHandDrive and true or false, turnOnRed = r.turnOnRed and true or false }
    M.SIGNAL_TYPE = r.redYellow and 'lightsBasicEU' or 'lightsBasic'
  end
end

-- pre: toNodes' results built ahead (buildNodes), else made here
local function apply(b, pre, moved)
  setRules()
  local tN = wall()
  local nodes, nn, ne, cl
  if pre then nodes, nn, ne, cl = pre[1], pre[2], pre[3], pre[4]
  else nodes, nn, ne, cl = M.toNodes(graph, b, M.EDGE_M, M.rules.rightHandDrive, nil, M.HALO_M, M.FAST_HALO_M) end
  stats.nodesMs = wall() - tN         -- (the parts of an apply's frame: the hitch hunt, 2026-10-23)
  local ts = signalsSystem()
  -- before the reset: its onNavgraphReloaded would place the old instances on the new graph (research §2.8)
  if ts then pcall(ts.resetSignals) end
  writeFile(M.RULES_FILE, jsonEncode({ roadRules = M.rules }))
  local orig = path.getPathLevelInfo
  path.getPathLevelInfo = function() return M.RULES_FILE end
  -- the reset sends the whole map to the UI (NavigationMapChanged, research §2.3): only the big map uses it,
  -- and it is a good part of the reset's frame; dropped during ours (M.UI_MAP = true keeps it)
  local trig = guihooks and guihooks.trigger
  if trig and not M.UI_MAP then
    guihooks.trigger = function(name, ...) if name ~= 'NavigationMapChanged' then return trig(name, ...) end end
  end
  local okG, gps = pcall(require, 'beamngEarth/gps')
  local mOld = map.getMap and map.getMap()
  local tG = wall()
  local keep = okG and gps.beforeGraph and gps.beforeGraph(mOld and mOld.nodes) or nil
  stats.gpsMs = wall() - tG
  local t0 = wall()
  ours = true
  local ok, err = pcall(map.reset, nodes)
  ours = false
  if trig then guihooks.trigger = trig end
  path.getPathLevelInfo = orig
  if not ok then
    log('E', 'beamngEarth', 'navgraph: map.reset: ' .. tostring(err))
    return false
  end
  stats.resetMs = wall() - t0
  local m = map.getMap()
  if persistent and persistent ~= m.nodes then
    table.clear(persistent)
    for k, v in pairs(m.nodes) do persistent[k] = v end
    m.nodes = persistent
  else
    persistent = m.nodes
  end
  local tA = wall()
  if keep then pcall(gps.afterGraph, keep, m.nodes, moved) end    -- before the vehicles' new map
  stats.gpsMs = stats.gpsMs + (wall() - tA)
  be:queueAllObjectLua('mapmgr.requestMap()')
  -- the minimap (the navigation app, in 0.40's freeroam layout and ours) indexes the map's roads once and keeps them:
  -- it showed the first graph's streets, or none, as the player drove on (the user, 2026-10-22)
  local mr = rawget(_G, 'ui_apps_minimap_roads')
  if mr and mr.reset then pcall(mr.reset) end
  pendingSignals = ts and nodes or nil     -- next frame: a second, smaller hitch instead of one big one
  cuts = cl
  stats.applies, stats.lastMs, stats.nodes, stats.edges = stats.applies + 1, wall() - t0, nn, ne
  stats.applyMs = wall() - tN
  stats.cuts = #cl
  return true
end

-- The vehicle Lua that hands a vehicle the signals (a serialized table). A traffic car keeps the junction it
-- is approaching across map changes (ai.lua's trafficStates.intersection; stock maps never change) and
-- reads signalsData[node][nextNode][idx] without a check: a new graph without that junction (a teleport,
-- or the junction left the window) disabled every car near one (in game 2026-10-14, "attempt to index a
-- nil value" at ai.lua trafficActions). So the new table keeps the old entries it lacks: their nodes are
-- not on the new graph's paths (ai.lua's other reads check first), only a remembered junction resolves.
function M.setSignalsLua(data)
  return 'do local old, new = mapmgr.signalsData, ' .. data .. '\n'
    .. 'if old and new then for a, t in pairs(old) do local n = new[a] if not n then new[a] = t else '
    .. 'for b, u in pairs(t) do if n[b] == nil then n[b] = u end end end end end\n'
    .. 'mapmgr.setSignals(new) end'
end

-- The signals of the graph applied last frame (core_trafficSignals resolves them on the new map).
local function applySignals(nodes)
  local ts = core_trafficSignals
  if not ts then return end
  local t1 = wall()
  local okS, err2 = pcall(function()
    seenHeads = {}
    local data, ns = signalData(nodes)
    clearHeads(seenHeads)                   -- the heads of junctions no longer in the graph
    local t2 = wall()
    stats.sigDataMs = t2 - t1
    -- setupSignals finds the signal heads by walking every TSStatic in the level (setupSignalObjects:
    -- getObjectsByClass('TSStatic') and a dynamic-field read on each); ours holds thousands (buildings, roads, far
    -- tiles), so each apply paid for all of them. The heads are ours (heads): only they are handed over meanwhile.
    local gobc = rawget(_G, 'getObjectsByClass')
    if gobc and M.HEADS_ONLY then
      getObjectsByClass = function(cls)
        if cls ~= 'TSStatic' then return gobc(cls) end
        local out = {}
        for _, h in pairs(heads) do
          local o = scenetree.findObjectById(h.id)
          if o then out[#out + 1] = o end
        end
        return out
      end
    end
    local okSet, errSet = pcall(ts.setupSignals, data, false, true)
    if gobc then getObjectsByClass = gobc end
    if not okSet then error(errSet) end
    local t3 = wall()
    stats.sigSetupMs = t3 - t2
    -- a vehicle holding signals reads the state-change mailbox every frame and dies on one never written
    -- ("lpack: unexpected end of buffer", in game 2026-10-14): write an empty update before handing them out
    be:sendToMailbox('trafficSignalUpdates', lpack.encodeBin({}))
    be:queueAllObjectLua(M.setSignalsLua(serialize(ts.getMapNodeSignals())))
    local t4 = wall()
    stats.sigSendMs = t4 - t3
    stats.junctions = ns
    -- the road tiles' static booms stand where the switchable heads are now
    local trees = require('beamngEarth/trees')
    local grid = {}
    for _, h in pairs(heads) do grid[math.floor(h.x / 4) .. ',' .. math.floor(h.y / 4)] = true end
    trees.suppress = function(g, x, y)
      if g ~= 'signal' and g ~= 'signal_left' then return false end
      local cx, cy = math.floor(x / 4), math.floor(y / 4)
      for dx = -1, 1 do for dy = -1, 1 do if grid[(cx + dx) .. ',' .. (cy + dy)] then return true end end end
      return false
    end
    local t5 = wall()
    trees.refresh('signal')            -- (only the tiles with signal items: suppress hides nothing else)
    trees.refresh('signal_left')
    stats.sigTreesMs = wall() - t5
  end)
  stats.signalsMs = wall() - t1
  stats.signalsMaxMs = math.max(stats.signalsMaxMs or 0, stats.signalsMs)
  if not okS then log('W', 'beamngEarth', 'navgraph: signals: ' .. tostring(err2)) end
end

local function trafficSystem()
  if not (gameplay_traffic and core_multiSpawn and gameplay_walk) and extensions and extensions.load then
    pcall(extensions.load, unpack(M.EXTENSIONS))
  end
  return gameplay_traffic
end

local function playerId() return be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or -1 end

-- Pure: where a respawned car goes, (x, y, dirX, dirY, min m, max m) for gameplay_traffic.forceTeleport, or nil for
-- behind the camera: ahead of a player at (px, py) moving (vx, vy) m/s faster than AHEAD_MS, AHEAD_M along the way but
-- no farther than the block b's edge guard (GUARD_M + a margin) in that direction; nil too when that leaves no room.
function M.aheadSpot(px, py, vx, vy, b)
  local sp = math.sqrt(vx * vx + vy * vy)
  if sp < M.AHEAD_MS then return nil end
  local dx, dy = vx / sp, vy / sp
  local reach = math.huge
  if b then
    if dx > 1e-6 then reach = math.min(reach, (b[3] - px) / dx) elseif dx < -1e-6 then reach = math.min(reach, (b[1] - px) / dx) end
    if dy > 1e-6 then reach = math.min(reach, (b[4] - py) / dy) elseif dy < -1e-6 then reach = math.min(reach, (b[2] - py) / dy) end
  end
  local hi = math.min(M.AHEAD_M[2], reach - M.GUARD_M - 20)
  if hi < M.AHEAD_M[1] then return nil end
  return px, py, dx, dy, M.AHEAD_M[1], hi
end

-- Pure but for closest: a spot on the other carriageway ahead of a player at (px, py) heading (dx, dy) (unit), inside
-- box b by GUARD_M + 20, for a car driving towards the player: x, y, dirX, dirY, or nil. closest(x, y) -> {dist, dx, dy,
-- oneWay} of the nearest road (its edge's direction in -> out) or nil. leftHand: traffic on the left (the oncoming side
-- is then to the right).
function M.oncomingSpot(px, py, dx, dy, b, leftHand, closest)
  local sx, sy = -dy, dx                 -- (left of the heading)
  if leftHand then sx, sy = dy, -dx end
  for _, ahead in ipairs(M.ONCOMING_M) do
    for _, side in ipairs(M.ONCOMING_SIDE_M) do
      local x, y = px + dx * ahead + sx * side, py + dy * ahead + sy * side
      if M.inside(b, x, y, M.GUARD_M + 20) then
        local r = closest(x, y)
        if r and r.oneWay and r.dist <= M.ONCOMING_ON_M and (r.dx * dx + r.dy * dy) < -0.8 then
          return x, y, r.dx, r.dy
        end
      end
    end
  end
  return nil
end

local function closestRoad(x, y, z)
  local m = map.getMap()
  local n1, n2 = map.findClosestRoad(vec3(x, y, z or 0))
  local a, c = n1 and m.nodes[n1], n2 and m.nodes[n2]
  local e = a and c and (a.links[n2] or c.links[n1])
  if not e then return nil end
  local i, o = m.nodes[e.inNode or n1], m.nodes[e.outNode or n2]
  if not i or not o then return nil end
  local ex, ey = o.pos.x - i.pos.x, o.pos.y - i.pos.y
  local l = math.sqrt(ex * ex + ey * ey)
  if l < 0.1 then return nil end
  -- (findClosestRoad's distance is 3D, the probe at the player's height: measured in the plane here)
  local t = math.max(0, math.min(1, ((x - i.pos.x) * ex + (y - i.pos.y) * ey) / (l * l)))
  local qx, qy = i.pos.x + t * ex, i.pos.y + t * ey
  return { dist = math.sqrt((x - qx) ^ 2 + (y - qy) ^ 2), dx = ex / l, dy = ey / l, oneWay = e.oneWay,
    speedLimit = e.speedLimit, posted = e.posted, rough = e.rough == true,
    highway = e.highway == true, unlimited = e.unlimited == true,
    lanes = e.lanes, lanesOut = e.lanesOut, lanesIn = e.lanesIn,
    lateral = (ex * (y - qy) - ey * (x - qx)) / l, halfWidth = (e.inRadius or 3.5) +
      ((e.outRadius or e.inRadius or 3.5) - (e.inRadius or 3.5)) * t, rumble = e.rumble == true,
    edgeKey = tostring(e.inNode or n1) .. ':' .. tostring(e.outNode or n2) }
end

-- Local road speed metadata for traffic drivers. The graph is the current streamed graph; a generous distance gate
-- avoids applying an adjacent road's speed profile when the vehicle is off-road or the graph is still rebuilding.
function M.speedProfileAt(x, y, z)
  local r = closestRoad(x, y, z)
  if not r or r.dist > 35 then return nil end
  return { target = r.speedLimit, posted = r.posted, rough = r.rough, distance = r.dist,
    highway = r.highway == true, unlimited = r.unlimited == true,
    lanes = r.lanes, lanesOut = r.lanesOut, lanesIn = r.lanesIn }
end

-- Lane-departure strip metadata for the rumble audio. The server only marks selected country/road classes; only the
-- centerline of an undivided carriageway and its outer edges are candidates (never same-direction lane separators).
function M.rumbleLineAt(x, y, z)
  local r = closestRoad(x, y, z)
  if not r or not r.rumble or r.dist > 20 or r.halfWidth < 2 then return nil end
  return { lateral = r.lateral, halfWidth = r.halfWidth, oneWay = r.oneWay, edgeKey = r.edgeKey }
end
local oncomingTurn = false

-- Pure: is a car that has stood still since `since` (nil: moving) at distance d from the player stuck at `now`?
function M.stuck(since, now, d)
  return since ~= nil and now - since >= M.STUCK_S and d >= M.STUCK_FAR_M
end

-- Traffic cars the block left behind (or all, after a teleport), and stuck ones, are respawned on the graph.
local stillSince = {}   -- car id -> os.clock() it stopped moving
local seenAt = {}       -- car id -> { x, y, os.clock() it appeared there }
local lastTeleport = {} -- car id -> os.clock() it was last teleported
local syncTrafficPool
-- (lag: the time beyond GUARD_S since the last scan, a long frame's; it widens the cut reach and the jump threshold)
local function guard(b, all, lag)
  lag = lag or 0
  local gt = gameplay_traffic
  if not gt or gt.getState() ~= 'on' then return end
  syncTrafficPool(gt)
  local me = playerId()
  local pv = me >= 0 and getObjectByID(me) or nil
  local pp = pv and pv:getPosition() or nil
  local now = os.clock()
  -- paused: nothing moves, nobody is stuck (the clocks start again after it)
  local paused = simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause()
  if paused then table.clear(stillSince) end
  for id, traffic in pairs(gt.getTrafficData() or {}) do
    local o = getObjectByID(id)
    -- The full traffic table also contains player vehicles and may still contain an AI car just entered by a player.
    if localplayers.controlled(id, o, controlled) or (type(traffic) == 'table' and traffic.isAi == false) then
      stillSince[id], seenAt[id], lastTeleport[id] = nil, nil, nil
    else
      if o and o:getActive() then
        local p = o:getPosition()
        local u = o:getVelocity()
        local sp = math.sqrt(u.x * u.x + u.y * u.y)
        local dir = sp > 1 and { x = u.x / sp, y = u.y / sp } or o:getDirectionVector()
        local dl = math.sqrt(dir.x * dir.x + dir.y * dir.y)
        local s0 = seenAt[id]
        -- (a long frame carried the car on at its speed: that is driving, not a respawn's jump)
        local jump = M.JUMP_M + (s0 and s0[4] or 0) * lag
        if not s0 or (p.x - s0[1]) ^ 2 + (p.y - s0[2]) ^ 2 > jump ^ 2 then s0 = { p.x, p.y, now } end
        seenAt[id] = { p.x, p.y, s0[3], sp }
        local fresh = now - s0[3] < M.FRESH_S
        local reach = M.cutReach(sp, fresh, lag)
        local toCut = dl > 1e-6 and M.headingToCut(p.x, p.y, dir.x / dl, dir.y / dl, cuts, reach)
        if toCut and pp and M.followsPlayer(p, dir, pp, pv:getVelocity(), sp) then
          toCut = false     -- (the block goes on with the player: the guard's box check stays; GitHub #353)
        end
        -- at the cut already (GitHub #855): stopped at the dead end or turning round, which no longer heads for it
        local atCut = false
        if not toCut and not fresh and not paused and M.nearCut(p.x, p.y, cuts, M.CUT_NEAR_M) then
          local f = o:getDirectionVector()
          local fl = math.sqrt(f.x * f.x + f.y * f.y)
          local fwd = u.x * f.x + u.y * f.y
          local hx, hy        -- its direction of travel at speed, its facing at a stand
          if sp >= M.CUT_NEAR_MS then hx, hy = u.x / sp, u.y / sp
          elseif fl > 1e-6 then hx, hy = f.x / fl, f.y / fl end
          local r = hx and closestRoad(p.x, p.y, p.z) or nil
          local roadDot = r and (r.dx * hx + r.dy * hy) or nil
          local facingCut = fl > 1e-6 and M.headingToCut(p.x, p.y, f.x / fl, f.y / fl, cuts, M.CUT_NEAR_M) or false
          atCut = M.cutStopped(sp, fwd, roadDot, r and r.oneWay or nil, facingCut)
        end
        if not paused and o:getVelocity():length() < M.STUCK_MS then
          stillSince[id] = stillSince[id] or now
        else
          stillSince[id] = nil
        end
        local d = pp and (p - pp):length() or math.huge
        local underCooldown = (now - (lastTeleport[id] or -math.huge)) < M.COOLDOWN_S
        local urgent = not M.inside(b, p.x, p.y, M.GUARD_M)
        if all or urgent or (not underCooldown and (toCut or atCut or M.stuck(stillSince[id], now, d))) then
          if toCut then stats.cutRespawns = (stats.cutRespawns or 0) + 1
          elseif atCut then stats.cutStopRespawns = (stats.cutStopRespawns or 0) + 1 end
          stillSince[id] = nil
          lastTeleport[id] = now
          -- behind the camera: the stock default is 100-500 m in front of it, where the player sees the car
          -- pop in and its tyres smoke as it lands (the photo comparisons, 2026-10-14)
          local cp, cf = core_camera and core_camera.getPosition(), core_camera and core_camera.getForward()
          local pu = pv and pv:getVelocity()
          local ax, ay, adx, ady, amin, amax = nil
          if pp and pu and not all then ax, ay, adx, ady, amin, amax = M.aheadSpot(pp.x, pp.y, pu.x, pu.y, b) end
          local ox, oy, odx, ody
          if ax and M.ONCOMING then
            oncomingTurn = not oncomingTurn
            if oncomingTurn then
              local ok, x, y, ddx, ddy = pcall(M.oncomingSpot, pp.x, pp.y, adx, ady, b, M.rules.rightHandDrive,
                function(x, y) return closestRoad(x, y, pp.z) end)
              if ok and x then ox, oy, odx, ody = x, y, ddx, ddy end
            end
          end
          if ox then
            stats.oncomingRespawns = (stats.oncomingRespawns or 0) + 1
            pcall(gt.forceTeleport, id, vec3(ox, oy, pp.z), vec3(odx, ody, 0), 0, 40)
          elseif ax then
            stats.aheadRespawns = (stats.aheadRespawns or 0) + 1
            pcall(gt.forceTeleport, id, vec3(ax, ay, pp.z), vec3(adx, ady, 0), amin, amax)
          elseif cp and cf then
            pcall(gt.forceTeleport, id, cp, -cf, M.RESPAWN_M[1], M.RESPAWN_M[2])
          else
            pcall(gt.forceTeleport, id)
          end
        end
      else
        stillSince[id] = nil
      end
    end
  end
end

-- Stock forceTeleportAll defaults to every AI id, including an AI car a local player may have just entered. Hand it
-- an explicit filtered list instead; its full traffic data also contains non-AI player cars.
local eligibleTraffic = {}
local function scatterTraffic(gt, b)
  local list = gt.getTrafficList and gt.getTrafficList()
  if not gt.forceTeleportAll or type(list) ~= 'table' then return guard(b, true) end
  localplayers.snapshot(controlled)
  for i = #eligibleTraffic, 1, -1 do eligibleTraffic[i] = nil end
  for _, id in ipairs(list) do
    local o = getObjectByID(id)
    if o and not localplayers.controlled(id, o, controlled) then
      eligibleTraffic[#eligibleTraffic + 1] = id
    end
  end
  pcall(gt.forceTeleportAll, eligibleTraffic)
end

-- Stock can keep a traffic car in its AI pool after somebody enters it. In particular, setActiveAmount(0) would
-- deactivate that car, and reactivating it can invoke stock forceTeleport before our filtered scatter. Protect only
-- the occupied AI cars, and return each to its original pool and respawn policy when its last local occupant leaves.
local protectedTraffic, aiTraffic = {}, {}
local function trafficPool()
  local pools = rawget(_G, 'core_vehicleActivePooling')
  local pool = pools and pools.getPool and pools.getPool('autoTraffic')
  if pool and type(pool.allVehs) == 'table' and pool.removeVeh and pool.insertVeh then return pool end
end

local function releaseTraffic(id, saved, pool, data, force)
  local t = saved.traffic
  if data[id] == t then
    if t.enableRespawn == false then t.enableRespawn = saved.enableRespawn end
    if t.ignoreForceTeleport == true then t.ignoreForceTeleport = saved.ignoreForceTeleport end
  end
  if saved.pool == pool and pool and aiTraffic[id] and getObjectByID(id) and pool.allVehs[id] == nil then
    pool:insertVeh(id, force)
  end
  protectedTraffic[id] = nil
end

-- A false return means the pool cannot safely be put on hold; the post-graph guard still recycles the AI.
syncTrafficPool = function(gt)
  local data = gt.getTrafficData and gt.getTrafficData() or {}
  local list = gt.getTrafficList and gt.getTrafficList()
  for id in pairs(aiTraffic) do aiTraffic[id] = nil end
  if type(list) == 'table' then
    for _, id in ipairs(list) do aiTraffic[id] = true end
  else
    for id, t in pairs(data) do if type(t) == 'table' and t.isAi then aiTraffic[id] = true end end
  end
  localplayers.snapshot(controlled)
  local pool = trafficPool()
  for id, saved in pairs(protectedTraffic) do
    local o = getObjectByID(id)
    if not aiTraffic[id] or not o or data[id] ~= saved.traffic or not localplayers.controlled(id, o, controlled) then
      releaseTraffic(id, saved, pool, data, false)
    end
  end
  local safe = type(list) == 'table'
  for id in pairs(aiTraffic) do
    local o, t = getObjectByID(id), data[id]
    if o and localplayers.controlled(id, o, controlled) then
      if type(t) ~= 'table' then
        safe = false
      else
        local saved = protectedTraffic[id]
        if not saved then
          saved = { traffic = t, enableRespawn = t.enableRespawn, ignoreForceTeleport = t.ignoreForceTeleport }
          protectedTraffic[id] = saved
          t.enableRespawn, t.ignoreForceTeleport, t._teleport = false, true, nil
          if t.state ~= nil then t.state = 'locked' end
          if t.alpha ~= nil then t.alpha = 1 end
          if o.setMeshAlpha then o:setMeshAlpha(1, '') end
        end
        if pool and pool.allVehs[id] ~= nil then
          if pool:removeVeh(id) then saved.pool = pool else safe = false end
        elseif not pool then
          safe = false
        end
        -- A player can join while the pool is held. Clear its deferred stock teleport before making that car active.
        if o.getActive and o.setActive and not o:getActive() then
          t._teleport = nil
          o:setActive(1)
        end
      end
    end
  end
  return safe
end

-- core forwards the game's switch hook so a newly occupied traffic car is protected before the next guard tick.
function M.onVehicleSwitched(_, _, player)
  localplayers.observe(player)
  local gt = gameplay_traffic
  if gt and gt.getState() == 'on' then syncTrafficPool(gt) end
end

-- The player's traffic choice (the user, 2026-10-14: "if a player has them on then yes, if not then no"): the
-- level-start configurator's (Disabled / Parked only / Normal / Police; freeroam's spawningOptionsHelper), taken at
-- mission start by M.takeChoice. Off by default; the radial menu's traffic entries work at any time as on stock maps.
M.choice = { traffic = false, parked = false, police = false, trafficAmount = -1, parkedAmount = -1 }

-- Pure on its argument: the choice in freeroam's spawning options `o`, which are then set to disabled: freeroam would
-- spawn at camera-ready, before our first road graph is in the map; we start them once it is.
local heldOpts = nil    -- { options table, its traffic values } until freeroam's spawn time has passed

-- The player's options back as they chose them (the level-start configurator shows them as the current choice next
-- time): once our cars started, and when the level ends.
function M.restoreChoice()
  if not heldOpts then return end
  local o, v = heldOpts[1], heldOpts[2]
  o.trafficMode, o.trafficParked, o.trafficPolice = v[1], v[2], v[3]
  heldOpts = nil
end

function M.takeChoice(o)
  -- level start runs twice (seen 2026-10-14): the second would read the options we just disabled
  if heldOpts and heldOpts[1] == o then return M.choice end
  heldOpts = nil
  if type(o) ~= 'table' then
    M.choice = { traffic = false, parked = false, police = false, trafficAmount = -1, parkedAmount = -1 }
    return M.choice
  end
  M.choice = { traffic = o.trafficMode == 'enabled', parked = o.trafficParked == 'enabled',
               police = o.trafficPolice == 'enabled', trafficAmount = tonumber(o.trafficAmount) or -1,
               -- (0.40 renamed trafficParkedAmount to trafficParkingAmount)
               parkedAmount = tonumber(o.trafficParkingAmount or o.trafficParkedAmount) or -1 }
  -- (as stock freeroam: with traffic and parked cars both chosen, Options > Gameplay's parked vehicles setting off
  -- means none; GitHub #320 / #145: parked cars came with the setting off)
  local st = rawget(_G, 'settings')
  if M.choice.traffic and M.choice.parked and st and st.getValue and st.getValue('trafficParkedVehicles') == false then
    M.choice.parked = false
  end
  if log then
    log('I', 'beamngEarth', string.format('traffic choice: traffic %s, parked %s, police %s (freeroam %s / %s)',
      tostring(M.choice.traffic), tostring(M.choice.parked), tostring(M.choice.police), tostring(o.trafficMode),
      tostring(o.trafficParked)))
  end
  heldOpts = { o, { o.trafficMode, o.trafficParked, o.trafficPolice } }
  o.trafficMode, o.trafficParked, o.trafficPolice = 'disabled', 'disabled', 'disabled'
  return M.choice
end

-- The traffic cars of the region the player is in (the user, 2026-11-09: "the normal maps have this already"): a stock
-- level names its region in info.json (northAmerica, europe, asiaPacific) and the game's traffic picks the vehicles
-- of that region with Options > Gameplay > Traffic's smart selections on (gameplay/traffic/trafficUtils
-- getBaseGroupParams). Ours spans the Earth: the region of the road rules' country (server navgraph.road_rules),
-- the same filters as the game's own group (its simple vehicles too); nil (the game's own group) elsewhere, without
-- smart selections, or when the group cannot be made.
M.REGIONS = {
  northAmerica = { 'US', 'CA', 'MX', 'PR' },
  europe = { 'AT', 'BE', 'BG', 'HR', 'CY', 'CZ', 'DK', 'EE', 'FI', 'FR', 'DE', 'GR', 'HU', 'IE', 'IT', 'LV', 'LT', 'LU',
    'MT', 'NL', 'PL', 'PT', 'RO', 'SK', 'SI', 'ES', 'SE', 'GB', 'NO', 'CH', 'IS', 'LI', 'MC', 'SM', 'AD', 'AL', 'BA',
    'ME', 'MK', 'RS', 'XK', 'MD', 'UA', 'BY', 'FO', 'GI', 'IM', 'JE', 'GG' },
  asiaPacific = { 'JP', 'KR', 'TW', 'HK', 'MO', 'SG', 'MY', 'TH', 'ID', 'PH', 'AU', 'NZ' },
}
M.COUNTRY_NAMES = { US = 'United States', DE = 'Germany', IT = 'Italy', FR = 'France', JP = 'Japan' }   -- (countryRef)
M.GROUP_SIZE = 40       -- vehicles drawn for the traffic's pool
local regionOfCountry = {}
for region, list in pairs(M.REGIONS) do for _, cc in ipairs(list) do regionOfCountry[cc] = region end end

function M.regionOf(cc)
  return type(cc) == 'string' and regionOfCountry[string.upper(cc)] or nil
end

M.EU_POLICE_CONFIGS = {
  { model = 'etk800', config = 'polizei' },
  { model = 'vivace', config = 'police' },
  { model = 'etkc', config = 'police' },
  { model = 'sunburst', config = 'police' },
}

local function deStreetImmersionOn()
  local ok, de = pcall(require, 'beamngEarth/deEnhancer')
  return ok and type(de) == 'table' and type(de.isEnabled) == 'function' and de.isEnabled() == true
end

function M.appendEuPolicePatrols(group, cc, available)
  if type(group) ~= 'table' or M.regionOf(cc) ~= 'europe' then return group end
  local hasPolice = false
  for _, v in ipairs(group) do
    if type(v) == 'table' then
      local cfg = tostring(v.config or v.name or ''):lower()
      if cfg:find('police', 1, true) or cfg:find('polizei', 1, true) then
        hasPolice = true
        break
      end
    end
  end
  if hasPolice then return group end
  for _, p in ipairs(M.EU_POLICE_CONFIGS) do
    if available == nil or available[p.model .. ':' .. p.config] then
      group[#group + 1] = { model = p.model, config = p.config }
      break
    end
  end
  return group
end

function M.regionalGroupParams(cc, getSetting, includePolice)
  local region = M.regionOf(cc)
  if not region or not getSetting or not getSetting('trafficSmartSelections') then return nil end
  local params = { filters = { Type = { car = 1, truck = 0.6 }, Region = { [region] = 1, default = 1 } },
    country = M.COUNTRY_NAMES[string.upper(cc)] or 'default', maxYear = 0, minPop = 50, allConfigs = true,
    allMods = getSetting('trafficAllowMods') and true or false, modelPopPower = 1, configPopPower = 1 }
  if getSetting('trafficSimpleVehicles') then
    -- (the simple traffic models' configs carry their region too: US, EU and Japanese-market bodies; the game's
    -- own simple group, createTrafficGroup's: prop traffic only, every config)
    params.filters.Type = { proptraffic = 1 }
    params.minPop = 0
  else
    local euPolice = (region == 'europe') and (includePolice == true or (includePolice == nil and deStreetImmersionOn()))
    params.filters['Config Type'] = { Police = euPolice and 0.12 or 0, other = 1 }
    if params.allMods then params.filters.Type.automation = 1; params.minPop = 0 end
  end
  return params, region
end

-- Smart Regional Traffic Overhaul: deterministic archetype & livery roster, driving personas,
-- OSM bus stop dwell state machine, and zero-GC horizon spawn/despawn director.
M.DIRECTOR_TICK_S = 0.25
M.HORIZON_SPAWN_MIN_M = 160
M.HORIZON_SPAWN_MAX_M = 340
M.HORIZON_SAFE_MIN_M = 95
M.HORIZON_BEHIND_DESPAWN_M = 420
M.HORIZON_SPAWN_SPACING_M = 140
M.HORIZON_SPACING_TTL_S = 10.0

M.BUS_STOP_RANGE_M = 18.0
M.BUS_STOP_MAX_SPEED_MS = 14.0
M.BUS_STOP_COOLDOWN_S = 45.0
M.BUS_STOP_DWELL_MIN_S = 3.5
M.BUS_STOP_DWELL_MAX_S = 4.5
M.BUS_STOP_LATERAL_MAX_M = 12.0
M.BUS_STOP_CURB_OFFSET_M = 0.85

M.COURIER_STOP_RANGE_M = 16.0
M.COURIER_STOP_MAX_SPEED_MS = 12.5
M.COURIER_STOP_MAX_LIMIT_MS = 15.3
M.COURIER_STOP_COOLDOWN_S = 45.0
M.COURIER_STOP_DWELL_MIN_S = 4.0
M.COURIER_STOP_DWELL_MAX_S = 6.0
M.COURIER_STOP_LATERAL_MAX_M = 16.0
M.COURIER_STOP_CURB_OFFSET_M = 0.85

M.BUS_MODELS = { citybus = true, wentward = true, dt40l = true }
M.MINIBUS_MODELS = { van = true, h_series = true, gavril_h = true }
M.MOD_COURIER_MODELS = { scout = true, euvan = true, evvan = true, ecv = true }
M.COURIER_MODELS = {
  scout = true, euvan = true, evvan = true, ecv = true,
  van = true, boxtruck = true, h_series = true, gavril_h = true,
}
M.CARGO_COURIER_MODELS = {
  scout = true, euvan = true, evvan = true, ecv = true,
  van = true, boxtruck = true, h_series = true, gavril_h = true,
  pickup = true, d_series = true, md_series = true,
}
M.HEAVY_SEMI_MODELS = { semi = true, us_semi = true, t_series = true }
M.TRUCK_MODELS = { semi = true, us_semi = true, t_series = true, md_series = true }
M.PICKUP_MODELS = { pickup = true, d_series = true }
M.SPEEDER_MODELS = { etk800 = true, etkc = true, vivace = true, sbr = true, scintilla = true, bastion = true,
                     sunburst = true, bolide = true }

-- Curated vanilla & mod delivery paint_design part names per model (scanned from vanilla & installed mods).
M.DELIVERY_PAINT_DESIGNS = {
  van = {
    'van_skin_beamcom', 'van_skin_delivery', 'van_skin_bps', 'van_skin_bpsb',
    'van_skin_hhl', 'van_skin_hhlb', 'van_skin_rrt', 'van_skin_rrtb',
    'van_skin_nile', 'van_skin_nilefresh', 'van_skin_Post-ItDelivery',
    'van_skin_Post-ItDeliveryBoxVan', 'van_skin_Post-ItDeliveryVanEV',
    'van_cargobox_skin_truckitup',
  },
  pickup = {
    'pickup_skin_bps', 'pickup_skin_hhl', 'pickup_skin_rrts', 'pickup_skin_rlspickupupull',
  },
  euvan = {
    'euvan_main_skin_beamcom', 'euvan_main_skin_delivery', 'euvan_main_skin_niledelivery',
    'euvan_skin_Post-ItDelivery', 'euvan_main_skin_hirochi', 'euvan_main_skin_roadassistance',
  },
  scout = {
    'euvan_main_skin_beamcom', 'euvan_main_skin_delivery', 'euvan_main_skin_niledelivery',
    'euvan_skin_Post-ItDelivery', 'euvan_main_skin_hirochi', 'euvan_main_skin_roadassistance',
  },
  evvan = {
    'evvan_skin_nile', 'evvan_skin_Post-ItDelivery', 'evvan_skin_ams', 'evvan_skin_cad',
    'evvan_skin_concour', 'evvan_skin_fallon', 'evvan_skin_presto', 'evvan_skin_sus',
  },
  ecv = {
    'evvan_skin_nile', 'evvan_skin_Post-ItDelivery', 'evvan_skin_ams', 'evvan_skin_cad',
    'evvan_skin_concour', 'evvan_skin_fallon', 'evvan_skin_presto', 'evvan_skin_sus',
  },
  md_series = {
    'md_series_skin_bps', 'md_series_skin_hhl', 'md_series_skin_rrt',
    'md_series_skin_nilemd', 'md_series_skin_shuffleboard', 'md_series_skin_spearleaf',
  },
}
M.VANILLA_DELIVERY_PAINT_DESIGNS = {
  van = { 'van_skin_beamcom', 'van_skin_delivery' },
}

M.COURIER_PAINTS = {
  europe = {
    { tag = 'dhl_amber', paintName = 'DHL Amber', paint = { 0.98, 0.78, 0.04, 1.0 } },
    { tag = 'commercial_white', paintName = 'Commercial White', paint = { 0.93, 0.94, 0.95, 1.0 } },
    { tag = 'courier_slate', paintName = 'Courier Slate', paint = { 0.32, 0.36, 0.42, 1.0 } },
    { tag = 'ups_brown', paintName = 'Courier Brown', paint = { 0.22, 0.13, 0.07, 1.0 } },
  },
  northAmerica = {
    { tag = 'commercial_white', paintName = 'Commercial White', paint = { 0.93, 0.94, 0.95, 1.0 } },
    { tag = 'ups_brown', paintName = 'Courier Brown', paint = { 0.22, 0.13, 0.07, 1.0 } },
    { tag = 'courier_slate', paintName = 'Courier Slate', paint = { 0.32, 0.36, 0.42, 1.0 } },
    { tag = 'dhl_amber', paintName = 'DHL Amber', paint = { 0.98, 0.78, 0.04, 1.0 } },
  },
  asiaPacific = {
    { tag = 'commercial_white', paintName = 'Commercial White', paint = { 0.93, 0.94, 0.95, 1.0 } },
    { tag = 'courier_slate', paintName = 'Courier Slate', paint = { 0.32, 0.36, 0.42, 1.0 } },
    { tag = 'dhl_amber', paintName = 'DHL Amber', paint = { 0.98, 0.78, 0.04, 1.0 } },
  },
}

local director = {
  accum = 0,
  clock = 0,
  rosterArchetype = {},
  rosterEntry = {},
  liveryApplied = {},
  personas = {},
  busStops = {},
  busStopCount = 0,
  busDwell = {},
  busStopCooldowns = {},
  deliveryPoints = {},
  deliveryPointCount = 0,
  courierDwell = {},
  deliveryCooldowns = {},
  recentSpawns = {
    { x = 0, y = 0, at = -1e9 }, { x = 0, y = 0, at = -1e9 },
    { x = 0, y = 0, at = -1e9 }, { x = 0, y = 0, at = -1e9 },
    { x = 0, y = 0, at = -1e9 }, { x = 0, y = 0, at = -1e9 },
    { x = 0, y = 0, at = -1e9 }, { x = 0, y = 0, at = -1e9 },
  },
  recentSpawnIdx = 0,
}

local function hasAnyKeyword(str, list)
  for i = 1, #list do
    if str:find(list[i], 1, true) then return true end
  end
  return false
end

local function normalizeTokens(str)
  return ' ' .. tostring(str or ''):lower():gsub('[^%w]+', ' ') .. ' '
end

local function hasAnyToken(tokStr, list)
  for i = 1, #list do
    if tokStr:find(' ' .. list[i] .. ' ', 1, true) then return true end
  end
  return false
end

local EXCLUDED_KEYWORDS = {
  'hero', 'jato', 'ramplow', 'destructor', 'derby', 'drag', 'drift', 'monster',
  'stunt', 'crawler', 'capsule', 'demolition', 'ambulance', 'fire', 'swat', 'rally',
}
local POLICE_KEYWORDS = { 'police', 'polizei', 'interceptor', 'sheriff', 'patrol', 'carabinieri', 'gendarmerie' }
local BUS_LIVERY_KEYWORDS = { 'city', 'transit', 'metro', 'shuttle', 'municipal', 'express', 'local', 'coach' }

-- Tier 1: Installed delivery company skin packs (short acronyms token-matched to avoid false positives)
local TIER1_COMPANY_TOKENS = { 'hhl', 'bps', 'rrt', 'fdc', 'dhl', 'ups', 'dpd' }
local TIER1_COMPANY_SUBSTR = { 'nile', 'postit', 'post-it', 'post_it', 'hermes', 'fedex' }
local REGION_TIER1_TOKENS = {
  europe = { 'hhl', 'dhl', 'dpd' },
  northAmerica = { 'hhl', 'bps', 'rrt', 'fdc', 'ups' },
  asiaPacific = { 'dhl' },
}
local REGION_TIER1_SUBSTR = {
  europe = { 'postit', 'post-it', 'post_it', 'nile', 'hermes' },
  northAmerica = { 'nile', 'fedex' },
  asiaPacific = { 'nile', 'fedex', 'postit', 'post-it', 'post_it' },
}
local REGION_MOD_COURIER_BONUS = {
  europe = { scout = 45, euvan = 45, evvan = 40, ecv = 40 },
  northAmerica = { evvan = 45, ecv = 45, scout = 25, euvan = 25 },
  asiaPacific = { evvan = 35, ecv = 35, scout = 30, euvan = 30 },
}

-- Tier 2: Built-in vanilla delivery/commercial livery configs (preserved untouched with paint = nil)
local TIER2_LIVERY_KEYWORDS = {
  'delivery', 'courier', 'parcel', 'postal', 'commercial', 'fleet', 'service',
  'livery', 'cargobox', 'beamcom', 'truckitup', 'fallon', 'concour', 'hirochi',
  'roadassistance', 'courriel', 'mail canada',
}
-- Tier 3 / plain cargo keywords (qualifies van/md_series as courier; receives regional COURIER_PAINTS if unskinned)
local COURIER_PLAIN_KEYWORDS = {
  'cargo', 'box', 'upfit', 'panel', 'freight', 'worker', 'post', 'mail', 'van',
}
-- Windowed passenger/minibus keywords (excluded from cargo-only courier; H-Series passenger/minibus routes to 'bus')
local MINIBUS_KEYWORDS = { 'passenger', 'minibus', 'shuttle', 'vantastic' }
local PASSENGER_VAN_KEYWORDS = {
  'passenger', 'minibus', 'shuttle', 'vantastic', 'windowed', 'camper',
  'multiway', 'tracer', 'combi', 'family', 'tourer',
}
local NON_DELIVERY_SKIN_KEYWORDS = {
  'police', 'polizei', 'polizia', 'bcpd', 'gendarmerie', 'ambulance', 'fire', 'swat',
  'camo', 'military', 'army', 'old', 'twotone', 'stripes', 'flames', 'splatter',
  'vandal', 'curiosity', 'dirttest', 'dynamictextures', 'parkranger', 'hero',
  'zebra', 'safari', 'sport', 'race', 'safetycar', 'interior', 'glass',
}
local DELIVERY_SKIN_TOKENS = {
  'hhl', 'hhlb', 'bps', 'bpsb', 'rrt', 'rrtb', 'rrts', 'fdc', 'dhl', 'ups', 'dpd',
  'ams', 'cad', 'sus', 'presto', 'concour', 'fallon', 'hirochi', 'beamcom',
}
local DELIVERY_SKIN_SUBSTR = {
  'delivery', 'postal', 'parcel', 'courier', 'nile', 'postit', 'post-it', 'post_it',
  'beamcom', 'truckitup', 'mail', 'courriel', 'fallon', 'concour', 'hirochi',
  'roadassistance', 'road assistance', 'shuffleboard', 'spearleaf', 'upull', 'fedex', 'hermes',
}
local BOX_SKIN_SUBSTR = { 'bpsb', 'hhlb', 'rrtb', 'boxvan', 'truckitup' }

local function canonCourierModel(model)
  local m = tostring(model or ''):lower()
  if m == 'h_series' or m == 'gavril_h' then return 'van' end
  if m == 'd_series' then return 'pickup' end
  return m
end

local function isDeliveryPaintDesignPart(partName, displayName)
  local pn = tostring(partName or ''):lower()
  if pn == '' or pn == 'none' then return false end
  local dn = tostring(displayName or ''):lower()
  local combined = pn .. ' ' .. dn
  if hasAnyKeyword(combined, NON_DELIVERY_SKIN_KEYWORDS) then return false end
  local tok = normalizeTokens(combined)
  if hasAnyToken(tok, DELIVERY_SKIN_TOKENS) or hasAnyKeyword(combined, DELIVERY_SKIN_SUBSTR) then
    return true
  end
  for _, list in pairs(M.DELIVERY_PAINT_DESIGNS) do
    for i = 1, #list do
      if list[i]:lower() == pn then return true end
    end
  end
  return false
end

-- Pure: true when (model, config, entry) is an H-Series passenger/minibus/shuttle config.
function M.isMinibusConfig(model, config, entry)
  local m = tostring(model or ''):lower()
  if not M.MINIBUS_MODELS[m] then return false end
  local c = tostring(config or ''):lower()
  local nm = type(entry) == 'table' and tostring(entry.name or ''):lower() or ''
  local body = type(entry) == 'table' and tostring(entry.body or ''):lower() or ''
  local combined = m .. ' ' .. c .. ' ' .. nm .. ' ' .. body
  if type(entry) == 'table' and entry.isPolice == true then return false end
  if hasAnyKeyword(combined, POLICE_KEYWORDS) or hasAnyKeyword(combined, EXCLUDED_KEYWORDS) then return false end
  return hasAnyKeyword(combined, MINIBUS_KEYWORDS)
end

-- Pure: true when (model, config, entry) is a windowed passenger van/minibus/Scout/bus config (excluded from courier).
function M.isPassengerVanConfig(model, config, entry)
  local m = tostring(model or ''):lower()
  local c = tostring(config or ''):lower()
  local nm = type(entry) == 'table' and tostring(entry.name or ''):lower() or ''
  local body = type(entry) == 'table' and tostring(entry.body or ''):lower() or ''
  local combined = m .. ' ' .. c .. ' ' .. nm .. ' ' .. body
  if hasAnyKeyword(combined, PASSENGER_VAN_KEYWORDS) then return true end
  if m == 'md_series' and (combined:find('schoolbus', 1, true) or combined:find('prisonbus', 1, true)
      or combined:find('derbybus', 1, true) or combined:find('crewcab', 1, true)
      or combined:find('pickup_crew', 1, true)) then
    return true
  end
  if (m == 'van' or m == 'h_series' or m == 'gavril_h' or m == 'scout' or m == 'euvan')
      and (body:find('passenger', 1, true) or body:find('tailgateglass', 1, true)) then
    return true
  end
  return false
end

-- Pure: true ONLY for windowless cargo/panel/box configs of van, pickup, scout/euvan, evvan/ecv, md_series, boxtruck.
function M.isCargoCourierConfig(model, config, entry)
  local m = tostring(model or ''):lower()
  if not M.CARGO_COURIER_MODELS[m] then return false end
  local c = tostring(config or ''):lower()
  local nm = type(entry) == 'table' and tostring(entry.name or ''):lower() or ''
  local body = type(entry) == 'table' and tostring(entry.body or ''):lower() or ''
  local combined = m .. ' ' .. c .. ' ' .. nm .. ' ' .. body
  if type(entry) == 'table' and entry.isPolice == true then return false end
  if hasAnyKeyword(combined, POLICE_KEYWORDS) or hasAnyKeyword(combined, EXCLUDED_KEYWORDS) then return false end
  if M.isPassengerVanConfig(m, c, entry) then return false end
  local tok = normalizeTokens(combined)
  if M.PICKUP_MODELS[m] then
    return (type(entry) == 'table' and (entry.hasDeliveryLivery == true or entry.paintDesign ~= nil))
      or hasAnyToken(tok, TIER1_COMPANY_TOKENS) or hasAnyKeyword(combined, TIER1_COMPANY_SUBSTR)
      or hasAnyKeyword(combined, TIER2_LIVERY_KEYWORDS)
      or combined:find('cargobox', 1, true) ~= nil or combined:find('flatbed', 1, true) ~= nil
  end
  if m == 'md_series' then
    return (type(entry) == 'table' and (entry.hasDeliveryLivery == true or entry.paintDesign ~= nil))
      or hasAnyToken(tok, TIER1_COMPANY_TOKENS) or hasAnyKeyword(combined, TIER1_COMPANY_SUBSTR)
      or hasAnyKeyword(combined, TIER2_LIVERY_KEYWORDS)
      or hasAnyKeyword(combined, COURIER_PLAIN_KEYWORDS)
  end
  return true
end

-- Pure: deterministically pick a delivery paint_design part for `model` from `installedParts` (array or map).
-- Returns nil if installedParts is provided and contains no delivery paint_design parts for that model.
function M.pickDeliveryPaintDesign(model, installedParts, seedOrOpts)
  local m = canonCourierModel(model)
  local seed, region, isBox = 1, 'europe', false
  if type(seedOrOpts) == 'number' then
    seed = seedOrOpts
  elseif type(seedOrOpts) == 'table' then
    seed = tonumber(seedOrOpts.seed) or 1
    region = M.REGIONS[seedOrOpts.region] and seedOrOpts.region or 'europe'
    isBox = seedOrOpts.isBox == true
  end

  local candidates = {}
  local seen = {}
  local function pushPart(pname, dname)
    if type(pname) ~= 'string' or pname == '' or seen[pname] then return end
    if isDeliveryPaintDesignPart(pname, dname) then
      seen[pname] = true
      local pl = pname:lower()
      local tok = normalizeTokens(pl .. ' ' .. tostring(dname or ''):lower())
      local score = 10
      local rt = REGION_TIER1_TOKENS[region]
      local rs = REGION_TIER1_SUBSTR[region]
      if (rt and hasAnyToken(tok, rt)) or (rs and hasAnyKeyword(pl, rs)) then
        score = score + 40
      end
      if hasAnyToken(tok, TIER1_COMPANY_TOKENS) or hasAnyKeyword(pl, TIER1_COMPANY_SUBSTR) then
        score = score + 30
      end
      local isBoxSkin = hasAnyKeyword(pl, BOX_SKIN_SUBSTR)
      if isBox then
        if isBoxSkin then score = score + 25 end
      else
        if isBoxSkin then score = score - 25 end
      end
      candidates[#candidates + 1] = { name = pname, score = score }
    end
  end

  if type(installedParts) == 'table' then
    if #installedParts > 0 then
      for i = 1, #installedParts do
        local v = installedParts[i]
        if type(v) == 'string' then
          pushPart(v, nil)
        elseif type(v) == 'table' and type(v.name) == 'string' then
          if not v.slotType or v.slotType == 'paint_design' then
            pushPart(v.name, v.description or (type(v.information) == 'table' and v.information.name) or nil)
          end
        end
      end
    else
      for k, v in pairs(installedParts) do
        if type(k) == 'string' and v ~= false then
          if type(v) == 'table' then
            if not v.slotType or v.slotType == 'paint_design' then
              local dn = v.description or v.name or (type(v.information) == 'table' and v.information.name) or nil
              if type(dn) == 'table' then dn = tostring(dn.brand1 or dn.txt or '') end
              pushPart(k, dn)
            end
          else
            pushPart(k, type(v) == 'string' and v or nil)
          end
        end
      end
    end
  else
    -- No installedParts passed: use vanilla-guaranteed delivery paint_design parts only.
    local vanilla = M.VANILLA_DELIVERY_PAINT_DESIGNS[m]
    if vanilla then
      for i = 1, #vanilla do pushPart(vanilla[i], nil) end
    end
  end

  if #candidates == 0 then return nil end
  table.sort(candidates, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
  end)
  local idx = (math.abs(math.floor(seed)) % #candidates) + 1
  return candidates[idx].name
end

-- Apply a delivery paint_design part (or preserve an active paint_design) on a spawned courier vehicle via
-- core_vehicle_partmgmt, falling back to M.COURIER_PAINTS only if no delivery paint_design exists on that model.
function M.applyVehicleLivery(vehId, entry)
  if type(entry) ~= 'table' then return { applied = 'none' } end
  local pm = rawget(_G, 'core_vehicle_partmgmt')
  local vm = rawget(_G, 'core_vehicle_manager')
  local obj = getObjectByID and getObjectByID(vehId) or nil
  local model = entry.model or (obj and obj.getJBeamFilename and obj:getJBeamFilename()) or ''
  local cfgStr = tostring(entry.config or ''):lower()
  local isBox = cfgStr:find('box', 1, true) ~= nil or cfgStr:find('deliverytruck', 1, true) ~= nil
    or cfgStr:find('upfit', 1, true) ~= nil

  -- 1. Check for an already-active paint_design on the vehicle; never override an active paint_design with solid paint.
  local existingPd = nil
  if pm and type(pm.getConfigOfVehicle) == 'function' then
    local ok, curCfg = pcall(pm.getConfigOfVehicle, vehId)
    if ok and type(curCfg) == 'table' and type(curCfg.parts) == 'table' then
      local pd = curCfg.parts.paint_design
      if type(pd) == 'string' and pd ~= '' and pd ~= 'none' then existingPd = pd end
    end
  end
  local vdata = nil
  if vm and type(vm.getVehicleData) == 'function' then
    local ok, vd = pcall(vm.getVehicleData, vehId)
    if ok and type(vd) == 'table' then
      vdata = vd
      if not existingPd and type(vd.config) == 'table' and type(vd.config.parts) == 'table' then
        local pd = vd.config.parts.paint_design
        if type(pd) == 'string' and pd ~= '' and pd ~= 'none' then existingPd = pd end
      end
    end
  end
  if existingPd and (entry.hasDeliveryLivery == true or isDeliveryPaintDesignPart(existingPd)) then
    entry.paintDesign = existingPd
    entry.hasDeliveryLivery = true
    entry.paint = nil
    entry.paintName = nil
    return { applied = 'existing_paint_design', paintDesign = existingPd, preserved = true }
  end
  if entry.hasDeliveryLivery == true and not entry.paintDesign then
    entry.paint = nil
    entry.paintName = nil
    return { applied = 'preserved_livery', preserved = true }
  end

  -- 2. Resolve a delivery paint_design part from entry.paintDesign, entry.installedParts, or vehicle's available parts.
  local chosenPd = entry.paintDesign
  if not chosenPd then
    local avail = entry.installedParts
    if not avail and vdata then
      if type(vdata.availableParts) == 'table' then
        avail = vdata.availableParts
      elseif vdata.ioCtx and rawget(_G, 'jbeamIO') and type(jbeamIO.getAvailableParts) == 'function' then
        local okP, parts = pcall(jbeamIO.getAvailableParts, vdata.ioCtx)
        if okP and type(parts) == 'table' then avail = parts end
      end
    end
    chosenPd = M.pickDeliveryPaintDesign(model, avail, { seed = vehId, region = entry.region, isBox = isBox })
  end

  if chosenPd and chosenPd ~= '' then
    local appliedOk = false
    if pm then
      if obj and type(pm.setConfigOfVehicle) == 'function' then
        appliedOk = pcall(pm.setConfigOfVehicle, obj, { parts = { paint_design = chosenPd } }, true)
      elseif type(pm.setConfig) == 'function' then
        appliedOk = pcall(pm.setConfig, { parts = { paint_design = chosenPd } }, true, vehId)
      elseif type(pm.setPartsConfig) == 'function' then
        appliedOk = pcall(pm.setPartsConfig, { paint_design = chosenPd }, true)
      end
    end
    entry.paintDesign = chosenPd
    entry.hasDeliveryLivery = true
    entry.paint = nil
    entry.paintName = nil
    return { applied = 'paint_design', paintDesign = chosenPd, ok = appliedOk }
  end

  -- 3. Fallback to regional M.COURIER_PAINTS only when no delivery paint_design part exists on this model.
  if not existingPd and type(entry.paint) == 'table' then
    local paintOk = false
    if pm then
      if type(pm.setConfigPaints) == 'function' then
        paintOk = pcall(pm.setConfigPaints, { { baseColor = entry.paint } }, false, vehId)
      elseif obj and type(pm.setConfigOfVehicle) == 'function' then
        paintOk = pcall(pm.setConfigOfVehicle, obj, { paints = { { baseColor = entry.paint } } }, false)
      elseif type(pm.setConfig) == 'function' then
        paintOk = pcall(pm.setConfig, { paints = { { baseColor = entry.paint } } }, false, vehId)
      end
    end
    return { applied = 'fallback_paint', paint = entry.paint, ok = paintOk }
  end

  return { applied = 'none' }
end

local SPEEDER_KEYWORDS = {
  'ttsport', 'sport', 'gt4', 'gt3', 'gt2', 'gt', 'rs', 'redtail', 'battlehawk',
  'arsenal', 'sv', 'track', '340', '410', 'v10', 'v8', 'em', '_s', ' s ',
}
local REGION_SPEEDER_PREF = {
  europe = { etk800 = 30, etkc = 28, vivace = 25, scintilla = 22, sbr = 15, sunburst = 10, bastion = 5 },
  northAmerica = { bastion = 30, sbr = 25, scintilla = 22, etk800 = 18, etkc = 16, sunburst = 14, vivace = 8 },
  asiaPacific = { sunburst = 30, sbr = 28, vivace = 20, etk800 = 15, etkc = 14, scintilla = 12, bastion = 6 },
}

local function hasTier1CompanySkin(rawLower, tokStr)
  return hasAnyToken(tokStr, TIER1_COMPANY_TOKENS) or hasAnyKeyword(rawLower, TIER1_COMPANY_SUBSTR)
end

local function hasTier2VanillaLivery(rawLower)
  return hasAnyKeyword(rawLower, TIER2_LIVERY_KEYWORDS)
end

local function tier1LiveryTag(rawLower, tokStr)
  if hasAnyToken(tokStr, { 'hhl' }) then return 'mod_hhl' end
  if hasAnyToken(tokStr, { 'bps' }) then return 'mod_bps' end
  if hasAnyToken(tokStr, { 'rrt' }) then return 'mod_rrt' end
  if rawLower:find('nile', 1, true) then return 'mod_nile' end
  if rawLower:find('postit', 1, true) or rawLower:find('post-it', 1, true) or rawLower:find('post_it', 1, true) then
    return 'mod_postit'
  end
  if hasAnyToken(tokStr, { 'fdc' }) then return 'mod_fdc' end
  if hasAnyToken(tokStr, { 'dhl' }) then return 'dhl_amber' end
  if hasAnyToken(tokStr, { 'ups' }) then return 'ups_brown' end
  if hasAnyToken(tokStr, { 'dpd' }) or rawLower:find('hermes', 1, true) then return 'courier_slate' end
  if rawLower:find('fedex', 1, true) then return 'mod_fedex' end
  return 'mod_delivery'
end

-- Pure: classify a vehicle (model, config, optional entry metadata) into an archetype or 'excluded'.
function M.classifyVehicle(model, config, entry)
  local m = tostring(model or ''):lower()
  local c = tostring(config or ''):lower()
  local nm = type(entry) == 'table' and tostring(entry.name or ''):lower() or ''
  local combined = m .. ' ' .. c .. ' ' .. nm
  local tok = normalizeTokens(combined)
  if type(entry) == 'table' and entry.isPolice == true then return 'police' end
  if hasAnyKeyword(combined, POLICE_KEYWORDS) then return 'police' end
  if hasAnyKeyword(combined, EXCLUDED_KEYWORDS) then return 'excluded' end
  if M.BUS_MODELS[m] or combined:find('citybus', 1, true) or combined:find('wentward', 1, true)
      or M.isMinibusConfig(m, c, entry) then
    return 'bus'
  end
  -- Windowed passenger vans/Scouts/buses must never be assigned 'courier'
  if M.isPassengerVanConfig(m, c, entry) then
    if m == 'md_series' then return 'truck' end
    return 'commuter'
  end
  if M.COURIER_MODELS[m] then
    return 'courier'
  end
  if m == 'md_series' then
    if hasTier1CompanySkin(combined, tok) or hasTier2VanillaLivery(combined) or hasAnyKeyword(combined, COURIER_PLAIN_KEYWORDS) then
      return 'courier'
    end
    return 'truck'
  end
  if M.HEAVY_SEMI_MODELS[m] then
    if hasTier1CompanySkin(combined, tok) or hasTier2VanillaLivery(combined) then
      return 'courier'
    end
    return 'truck'
  end
  if M.TRUCK_MODELS[m] then
    return 'truck'
  end
  if M.PICKUP_MODELS[m] then
    if hasTier1CompanySkin(combined, tok) or hasTier2VanillaLivery(combined) then
      return 'courier'
    end
    return 'commuter'
  end
  if M.SPEEDER_MODELS[m] and (m == 'scintilla' or m == 'bolide' or hasAnyKeyword(combined, SPEEDER_KEYWORDS)) then
    return 'speeder'
  end
  return 'commuter'
end

local function cloneEntry(src, archetype, liveryTag, paint, paintName, hasDeliveryLivery, deliveryTier, paintDesign)
  local out = {
    model = src.model,
    config = src.config,
    archetype = archetype,
  }
  if src.name then out.name = src.name end
  if src.region then out.region = src.region end
  if src.body then out.body = src.body end
  if src.installedParts then out.installedParts = src.installedParts end
  if liveryTag then out.liveryTag = liveryTag end
  local pd = paintDesign or src.paintDesign
  if pd then out.paintDesign = pd end
  if hasDeliveryLivery ~= nil then out.hasDeliveryLivery = hasDeliveryLivery end
  if deliveryTier ~= nil then out.deliveryTier = deliveryTier end
  if hasDeliveryLivery == true or pd ~= nil then
    out.paint = nil
    out.paintName = nil
  else
    if paint then out.paint = paint elseif src.paint then out.paint = src.paint end
    if paintName then out.paintName = paintName elseif src.paintName then out.paintName = src.paintName end
  end
  return out
end

-- Pure deterministic regional traffic roster builder.
-- Enforces Police == 0 whenever deEnabled is false/nil (unless opts.includePolice == true).
function M.buildTrafficRoster(region, allConfigs, deEnabled, opts)
  opts = type(opts) == 'table' and opts or {}
  local reg = region
  if type(reg) == 'string' and not M.REGIONS[reg] then
    reg = M.regionOf(reg) or reg
  end
  reg = M.REGIONS[reg] and reg or 'europe'
  local allowPolice = (deEnabled == true and reg == 'europe') or (opts.includePolice == true)
  local urban = opts.urban ~= false
  local targetSize = math.max(1, math.floor(tonumber(opts.size) or M.GROUP_SIZE))

  local buckets = { bus = {}, courier = {}, truck = {}, speeder = {}, commuter = {}, police = {} }
  local seen = {}
  for _, item in ipairs(type(allConfigs) == 'table' and allConfigs or {}) do
    if type(item) == 'table' and type(item.model) == 'string' and item.model ~= '' then
      local cfg = tostring(item.config or '')
      local key = item.model:lower() .. ':' .. cfg:lower()
      if not seen[key] then
        seen[key] = true
        local arch = M.classifyVehicle(item.model, cfg, item)
        if arch ~= 'excluded' and (arch ~= 'police' or allowPolice) then
          local score = 0
          local cl = (cfg .. ' ' .. tostring(item.name or '')):lower()
          local ml = item.model:lower()
          local clTok = normalizeTokens(ml .. ' ' .. cl)
          if item.region == reg then score = score + 25 end
          if arch == 'bus' then
            local isHeavyBus = M.BUS_MODELS[ml] == true or cl:find('citybus', 1, true) or cl:find('wentward', 1, true)
            local isMinibus = M.isMinibusConfig(ml, cfg, item)
            if urban then
              if isHeavyBus then score = score + 200 elseif isMinibus then score = score + 80 end
            else
              if isMinibus then score = score + 200 elseif isHeavyBus then score = score + 80 end
            end
            if hasAnyKeyword(cl, BUS_LIVERY_KEYWORDS) then score = score + 100 end
          elseif arch == 'courier' then
            local isModModel = M.MOD_COURIER_MODELS[ml] == true
            local isTier1Skin = hasTier1CompanySkin(cl, clTok)
            local isTier2Livery = hasTier2VanillaLivery(cl)
            -- Tier 1: Installed delivery mod vehicles (scout/euvan, evvan/ecv) & delivery company skin packs
            if isTier1Skin then
              score = score + 300
              local rt = REGION_TIER1_TOKENS[reg]
              local rs = REGION_TIER1_SUBSTR[reg]
              if (rt and hasAnyToken(clTok, rt)) or (rs and hasAnyKeyword(cl, rs)) then
                score = score + 40
              end
            end
            if isModModel then
              local bonus = REGION_MOD_COURIER_BONUS[reg]
              score = score + 220 + (bonus and bonus[ml] or 30)
            end
            -- Tier 2: Vanilla in-game delivery/commercial liveries (zero-mod fallback)
            if not isTier1Skin and isTier2Livery then
              score = score + 150
            end
            -- Tier 3: Plain/unskinned cargo & van configs
            if not isTier1Skin and not isTier2Livery and hasAnyKeyword(cl, COURIER_PLAIN_KEYWORDS) then
              score = score + 30
            end
            if ml == 'van' or ml == 'boxtruck' then
              score = score + 20
            elseif ml == 'md_series' then
              score = score + 15
            elseif M.HEAVY_SEMI_MODELS[ml] then
              score = score + 10
            elseif M.PICKUP_MODELS[ml] then
              score = score + 8
            end
          elseif arch == 'truck' then
            if ml == 'semi' or ml == 'us_semi' or ml == 't_series' then score = score + 30 end
            if cl:find('hauler', 1, true) or cl:find('cargo', 1, true) or cl:find('sleeper', 1, true)
              or cl:find('daycab', 1, true) or cl:find('flatbed', 1, true) then
              score = score + 40
            end
          elseif arch == 'speeder' then
            local pref = REGION_SPEEDER_PREF[reg]
            score = score + (pref and pref[ml] or 10)
            if hasAnyKeyword(cl, SPEEDER_KEYWORDS) then score = score + 40 end
          elseif arch == 'police' then
            if reg == 'europe' and (cl:find('polizei', 1, true) or ml == 'etk800' or ml == 'vivace') then
              score = score + 50
            end
          end
          buckets[arch][#buckets[arch] + 1] = { item = item, score = score, key = key }
        end
      end
    end
  end

  local function cmp(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.key < b.key
  end
  for _, list in pairs(buckets) do table.sort(list, cmp) end

  local roster = {}
  local counts = { bus = 0, courier = 0, truck = 0, speeder = 0, commuter = 0, police = 0 }
  local function take(arch, limit, decorateFn)
    local src = buckets[arch]
    local n = math.min(#src, limit)
    for i = 1, n do
      if #roster >= targetSize then break end
      local e = src[i].item
      local tag, paint, paintName, hasDeliveryLivery, deliveryTier, paintDesign = nil, nil, nil, nil, nil, nil
      if decorateFn then
        tag, paint, paintName, hasDeliveryLivery, deliveryTier, paintDesign = decorateFn(e, i)
      end
      roster[#roster + 1] = cloneEntry(e, arch, tag, paint, paintName, hasDeliveryLivery, deliveryTier, paintDesign)
      counts[arch] = counts[arch] + 1
    end
  end

  -- Natural traffic proportions: everyday commuter cars make up ~75-85% of the pool.
  -- Bus: 1 heavy transit bus in urban pools (or minibus fallback); 1 H-Series minibus in rural pools (size >= 6,
  -- falling back to citybus/wentward if unavailable).
  -- Courier: 1 per standard 6-10 vehicle pool; at most 2 only if pool size >= 14.
  local busQuota = (urban or targetSize >= 6) and 1 or 0
  local courierQuota = targetSize >= 14 and 2 or 1
  local truckQuota = urban and (targetSize >= 24 and 2 or (targetSize >= 12 and 1 or 0))
    or (targetSize >= 14 and 2 or (targetSize >= 8 and 1 or 0))
  local speederQuota = targetSize >= 24 and 2 or (targetSize >= 12 and 1 or 0)
  local policeQuota = allowPolice and (targetSize >= 24 and 2 or 1) or 0

  local courierPal = M.COURIER_PAINTS[reg] or M.COURIER_PAINTS.europe
  local plainCourierPaintIdx = 0
  local installedByModel = type(opts.installedParts) == 'table' and opts.installedParts or nil
  take('bus', busQuota, function(e)
    local ml = tostring(e.model or ''):lower()
    local cl = (tostring(e.config or '') .. ' ' .. tostring(e.name or '')):lower()
    if M.isMinibusConfig(ml, e.config, e) then return 'minibus', nil, nil end
    if hasAnyKeyword(cl, BUS_LIVERY_KEYWORDS) then return 'transit_bus', nil, nil end
    return 'city_bus', nil, nil
  end)
  take('courier', courierQuota, function(e, idx)
    local ml = tostring(e.model or ''):lower()
    local cl = (tostring(e.config or '') .. ' ' .. tostring(e.name or '')):lower()
    local clTok = normalizeTokens(ml .. ' ' .. cl)
    local isModModel = M.MOD_COURIER_MODELS[ml] == true
    -- Tier 1: custom delivery company skin -> preserve livery (paint = nil)
    if hasTier1CompanySkin(cl, clTok) then
      return tier1LiveryTag(cl, clTok), nil, nil, true, 1, e.paintDesign
    end
    -- Tier 2: vanilla in-game delivery/commercial livery -> preserve livery (paint = nil)
    if e.hasDeliveryLivery == true or hasTier2VanillaLivery(cl) then
      return 'vanilla_delivery', nil, nil, true, isModModel and 1 or 2, e.paintDesign
    end
    -- Dynamic paint_design part injection when installedParts are known for this model
    local modelParts = e.installedParts or (installedByModel and (installedByModel[ml] or installedByModel[canonCourierModel(ml)]))
    if e.paintDesign or type(modelParts) == 'table' then
      local isBox = cl:find('box', 1, true) ~= nil or cl:find('upfit', 1, true) ~= nil
      local pd = e.paintDesign or M.pickDeliveryPaintDesign(ml, modelParts, { seed = idx, region = reg, isBox = isBox })
      if pd then
        local pdl = pd:lower()
        local pdTok = normalizeTokens(pdl)
        local tag = hasTier1CompanySkin(pdl, pdTok) and tier1LiveryTag(pdl, pdTok) or 'paint_design_delivery'
        return tag, nil, nil, true, isModModel and 1 or 2, pd
      end
    end
    -- Tier 3: plain unpainted/solid-color cargo/van -> apply regional M.COURIER_PAINTS
    plainCourierPaintIdx = plainCourierPaintIdx + 1
    local swatch = courierPal[((plainCourierPaintIdx - 1) % #courierPal) + 1]
    return swatch.tag, swatch.paint, swatch.paintName, false, isModModel and 1 or 3, nil
  end)
  take('truck', truckQuota)
  take('speeder', speederQuota)
  if allowPolice then take('police', policeQuota) end

  -- Fill remaining slots with everyday commuters
  local rem = targetSize - #roster
  if rem > 0 then take('commuter', rem) end

  -- Interleave commuters first with evenly spaced specialty vehicles so any spawned prefix
  -- (e.g. 6-10 active traffic vehicles) preserves the natural commuter-majority mix.
  local specials, commuters = {}, {}
  for i = 1, #roster do
    local e = roster[i]
    if e.archetype == 'commuter' then
      commuters[#commuters + 1] = e
    else
      specials[#specials + 1] = e
    end
  end
  if #commuters > 0 and #specials > 0 then
    local ordered = {}
    local ci, si = 1, 1
    local stride = math.max(2, math.floor(#commuters / (#specials + 1)))
    while ci <= #commuters or si <= #specials do
      for _ = 1, stride do
        if ci <= #commuters then
          ordered[#ordered + 1] = commuters[ci]
          ci = ci + 1
        end
      end
      if si <= #specials then
        ordered[#ordered + 1] = specials[si]
        si = si + 1
      end
    end
    roster = ordered
  end

  roster.counts = counts
  roster.region = reg
  return roster
end

-- Pure deterministic AI driving persona assignment.
function M.assignVehiclePersona(vehId, model, config, isAutobahn, rosterArchetype, entry)
  local ml = tostring(model or ''):lower()
  local arch = rosterArchetype
  if arch ~= 'bus' and arch ~= 'truck' and arch ~= 'courier' and arch ~= 'speeder' and arch ~= 'commuter' then
    local cls = M.classifyVehicle(model, config, entry)
    arch = (cls == 'bus' or cls == 'truck' or cls == 'courier' or cls == 'speeder') and cls or 'commuter'
  end
  -- Cargo-only constraint: only windowless cargo/panel/box configs of van, pickup, scout/euvan, evvan/ecv, md_series,
  -- boxtruck can be assigned 'courier'. Windowed passenger vans/minibuses and heavy semis never get 'courier'.
  if arch == 'courier' and not M.isCargoCourierConfig(model, config, entry) then
    if M.HEAVY_SEMI_MODELS[ml] or ml == 'md_series' then
      arch = 'truck'
    elseif M.isMinibusConfig(model, config, entry) then
      arch = 'bus'
    else
      arch = 'commuter'
    end
  end
  -- Plain unbranded vehicles (neither a delivery livery config nor a delivery paint_design part) drive as 'commuter'.
  if arch == 'courier' and type(entry) == 'table' and entry.hasDeliveryLivery == false and not entry.paintDesign then
    arch = 'commuter'
  end
  local idNum = math.abs(math.floor(tonumber(vehId) or 0))
  local u1 = ((idNum * 2654435761 + 17) % 1000) / 1000
  local u2 = ((idNum * 1597334677 + 53) % 1000) / 1000
  local autobahn = isAutobahn == true

  local risk, aggr, hwyKph, hwyDelta, urbDelta, laneBias, overtakeOk
  if arch == 'truck' then
    risk = 0.22 + u1 * 0.08
    aggr = 0.25 + u1 * 0.10
    hwyKph = 82 + u2 * 8
    hwyDelta = 0
    urbDelta = -4 + u2 * 4
    laneBias = 'right'
    overtakeOk = false
  elseif arch == 'bus' then
    risk = 0.24 + u1 * 0.08
    aggr = 0.25 + u1 * 0.10
    hwyKph = 84 + u2 * 8
    hwyDelta = 0
    urbDelta = -5 + u2 * 3
    laneBias = 'right'
    overtakeOk = false
  elseif arch == 'courier' then
    risk = 0.40 + u1 * 0.05
    aggr = 0.42 + u1 * 0.08
    hwyKph = 95 + u2 * 15
    hwyDelta = 4 + u2 * 4
    urbDelta = 0 + u2 * 4
    laneBias = 'right_or_middle'
    overtakeOk = true
  elseif arch == 'speeder' then
    risk = 0.72 + u1 * 0.16
    aggr = 0.75 + u1 * 0.15
    hwyKph = autobahn and (165 + u2 * 40) or nil
    hwyDelta = 15 + u2 * 13
    urbDelta = 4 + u2 * 6
    laneBias = 'overtake_left'
    overtakeOk = true
  else
    arch = 'commuter'
    risk = 0.38 + u1 * 0.14
    aggr = 0.38 + u1 * 0.14
    hwyKph = autobahn and (126 + u2 * 10) or nil
    hwyDelta = -4 + u2 * 8
    urbDelta = -4 + u2 * 8
    laneBias = 'right'
    overtakeOk = true
  end

  return {
    vehId = vehId,
    persona = arch,
    risk = math.floor(risk * 1000 + 0.5) / 1000,
    aggression = math.floor(aggr * 1000 + 0.5) / 1000,
    highwayCruiseKph = hwyKph and (math.floor(hwyKph * 10 + 0.5) / 10) or nil,
    highwayCruiseMs = hwyKph and (hwyKph / 3.6) or nil,
    highwayDeltaKph = math.floor(hwyDelta * 10 + 0.5) / 10,
    urbanDeltaKph = math.floor(urbDelta * 10 + 0.5) / 10,
    laneBias = laneBias,
    overtakeAllowed = overtakeOk,
    driveInLane = 'on',
    avoidCars = 'on',
    isAutobahn = autobahn,
  }
end

-- Whether ambient darkness (dusk/night/dawn) or rain/precipitation requires low-beam headlights on AI traffic.
function M.needsHeadlights()
  local env = rawget(_G, 'core_environment')
  if type(env) == 'table' then
    if type(env.getLightState) == 'function' then
      local ok, st = pcall(env.getLightState)
      if ok and type(st) == 'table' and st.isNight == true then return true end
    end
    if type(env.getTimeOfDay) == 'function' then
      local ok, tod = pcall(env.getTimeOfDay)
      if ok and type(tod) == 'table' then
        local t = tonumber(tod.time)
        if t and t >= 0.21 and t <= 0.79 then return true end
      end
    end
    if type(env.getPrecipitation) == 'function' then
      local ok, pr = pcall(env.getPrecipitation)
      if ok and (tonumber(pr) or 0) > 0.05 then return true end
    end
  end
  local w = rawget(_G, 'beamngEarth_weather')
  if type(w) == 'table' then
    if w.isRaining == true or (tonumber(w.rain) or 0) > 0.05 or (tonumber(w.precipitation) or 0) > 0.05 then
      return true
    end
    if type(w.isPrecipitating) == 'function' then
      local ok, pr = pcall(w.isPrecipitating)
      if ok and pr == true then return true end
    end
  end
  local stree = rawget(_G, 'scenetree')
  if type(stree) == 'table' and stree.theRain then
    local drops = tonumber(stree.theRain.numDrops) or 0
    if drops > 0 then return true end
  end
  return false
end

-- Vehicle Lua command applying a persona's baseline AI parameters (called once per spawn/respawn).
function M.personaAiCommand(p, lightsOn)
  if type(p) ~= 'table' then return nil end
  local waitTime = (p.persona == 'speeder') and 0.6 or ((p.persona == 'truck' or p.persona == 'bus') and 1.8 or 1.2)
  local turnCoef = (p.persona == 'truck' or p.persona == 'bus') and 0.85 or ((p.persona == 'speeder') and 1.15 or 1.0)
  local cmd = string.format(
    'ai.setAggression(%.2f) ai.driveInLane("%s") ai.setAvoidCars("%s") ai.setParameters({ trafficWaitTime = %.2f, turnForceCoef = %.2f })',
    tonumber(p.aggression) or 0.45,
    tostring(p.driveInLane or 'on'),
    tostring(p.avoidCars or 'on'),
    waitTime,
    turnCoef
  )
  if lightsOn then
    cmd = cmd .. ' electrics.setLightsState(1)'
  end
  return cmd
end

function M.getVehiclePersona(vehId)
  return director.personas[vehId]
end

-- OSM Bus Stop ingestion & dwell state machine (roads.lua -> navgraph.onBusStops).
local function recountBusStops()
  local n = 0
  for _, list in pairs(director.busStops) do n = n + #list end
  director.busStopCount = n
end

function M.onBusStops(key, stops)
  if key == nil then return 0 end
  if type(stops) ~= 'table' or #stops == 0 then
    director.busStops[key] = nil
    recountBusStops()
    return 0
  end
  local clean = {}
  for i, s in ipairs(stops) do
    if type(s) == 'table' then
      local x, y = tonumber(s.x or s[1]), tonumber(s.y or s[2])
      if x and y then
        clean[#clean + 1] = {
          id = s.id or (tostring(key) .. ':' .. tostring(i)),
          x = x, y = y, z = tonumber(s.z or s[3]) or 0,
          yaw = tonumber(s.yaw or s[4]) or 0,
        }
      end
    end
  end
  director.busStops[key] = #clean > 0 and clean or nil
  recountBusStops()
  return #clean
end

function M.dropBusStops(key)
  if key ~= nil and director.busStops[key] then
    director.busStops[key] = nil
    recountBusStops()
  end
end

function M.busStops()
  return director.busStops
end

function M.isBusDwelling(vehId)
  return director.busDwell[vehId] ~= nil
end

-- Step the city bus dwell state machine for one bus vehicle (zero table allocations on idle ticks).
function M.stepBusStop(vehId, px, py, dx, dy, speed, now, obj)
  local dwell = director.busDwell[vehId]
  if dwell then
    if now >= dwell.releaseAt then
      director.busDwell[vehId] = nil
      director.busStopCooldowns[dwell.stopId] = now + M.BUS_STOP_COOLDOWN_S
      stats.busStopsServed = (stats.busStopsServed or 0) + 1
      if obj and obj.queueLuaCommand then
        local resetOff = -(tonumber(dwell.curbOffset) or 0)
        obj:queueLuaCommand(string.format(
          'electrics.set_warn_signal(0) ai.driveInLane("on") ai.laneChange(nil, 12.0, %.2f) ai.setSpeedMode("legal") ai.setMode("traffic")',
          resetOff))
      end
      return 'released', dwell.stopId
    end
    return 'dwelling', dwell.stopId
  end
  if not speed or speed >= M.BUS_STOP_MAX_SPEED_MS then return 'none' end
  if director.busStopCount <= 0 then return 'none' end

  local range2 = M.BUS_STOP_RANGE_M * M.BUS_STOP_RANGE_M
  local latMax = M.BUS_STOP_LATERAL_MAX_M
  local bestStop, bestD2 = nil, range2 + 1
  for _, list in pairs(director.busStops) do
    for i = 1, #list do
      local s = list[i]
      local cd = director.busStopCooldowns[s.id]
      if not cd or now >= cd then
        local vx, vy = s.x - px, s.y - py
        local d2 = vx * vx + vy * vy
        if d2 <= range2 and d2 < bestD2 then
          local along = vx * dx + vy * dy
          if along >= -2.0 and along <= M.BUS_STOP_RANGE_M then
            local lat = math.abs(vx * dy - vy * dx)
            if lat <= latMax then
              bestStop, bestD2 = s, d2
            end
          end
        end
      end
    end
  end
  if not bestStop then return 'none' end

  local frac = (((math.abs(math.floor(tonumber(vehId) or 0)) * 131 + math.floor(now * 10)) % 101) / 100)
  local dwellS = M.BUS_STOP_DWELL_MIN_S + frac * (M.BUS_STOP_DWELL_MAX_S - M.BUS_STOP_DWELL_MIN_S)
  local curbSign = (M.rules and M.rules.rightHandDrive) and -1 or 1
  local curbOff = curbSign * M.BUS_STOP_CURB_OFFSET_M
  director.busDwell[vehId] = {
    stopId = bestStop.id,
    startedAt = now,
    releaseAt = now + dwellS,
    dwellS = dwellS,
    curbOffset = curbOff,
  }
  director.busStopCooldowns[bestStop.id] = now + dwellS + M.BUS_STOP_COOLDOWN_S
  if obj and obj.queueLuaCommand then
    obj:queueLuaCommand(string.format(
      'electrics.set_warn_signal(1) ai.driveInLane("off") ai.laneChange(nil, 10.0, %.2f) ai.setSpeedMode("set") ai.setSpeed(0)',
      curbOff))
  end
  return 'stopped', bestStop
end

-- Roadside building/delivery drop point ingestion & AI courier curbside dwell state machine (roads.lua -> navgraph.onDeliveryPoints).
local function recountDeliveryPoints()
  local n = 0
  for _, list in pairs(director.deliveryPoints) do n = n + #list end
  director.deliveryPointCount = n
end

function M.onDeliveryPoints(key, pts)
  if key == nil then return 0 end
  if type(pts) ~= 'table' or #pts == 0 then
    director.deliveryPoints[key] = nil
    recountDeliveryPoints()
    return 0
  end
  local clean = {}
  for i, s in ipairs(pts) do
    if type(s) == 'table' then
      local x, y = tonumber(s.x or s[1]), tonumber(s.y or s[2])
      if x and y then
        clean[#clean + 1] = {
          id = s.id or (tostring(key) .. ':d' .. tostring(i)),
          x = x, y = y, z = tonumber(s.z or s[3]) or 0,
          yaw = tonumber(s.yaw or s[4]) or 0,
        }
      end
    end
  end
  director.deliveryPoints[key] = #clean > 0 and clean or nil
  recountDeliveryPoints()
  return #clean
end

function M.dropDeliveryPoints(key)
  if key ~= nil and director.deliveryPoints[key] then
    director.deliveryPoints[key] = nil
    recountDeliveryPoints()
  end
end

function M.deliveryPoints()
  return director.deliveryPoints
end

function M.isCourierDwelling(vehId)
  return director.courierDwell[vehId] ~= nil
end

-- Step the AI courier curbside delivery stop state machine for one courier vehicle (zero table allocations on idle ticks).
-- Restricted to built-up villages/towns: requires vehicle speed < 12.5 m/s (45 km/h) and local road speed limit
-- <= 15.3 m/s (55 km/h), never pulling over on rural highways.
function M.stepCourierStop(vehId, px, py, dx, dy, speed, now, obj, roadLimitMs)
  local dwell = director.courierDwell[vehId]
  if dwell then
    if now >= dwell.releaseAt then
      director.courierDwell[vehId] = nil
      director.deliveryCooldowns[dwell.pointId] = now + M.COURIER_STOP_COOLDOWN_S
      stats.courierStopsServed = (stats.courierStopsServed or 0) + 1
      if obj and obj.queueLuaCommand then
        local resetOff = -(tonumber(dwell.curbOffset) or 0)
        obj:queueLuaCommand(string.format(
          'electrics.set_warn_signal(0) ai.driveInLane("on") ai.laneChange(nil, 12.0, %.2f) ai.setSpeedMode("legal") ai.setMode("traffic")',
          resetOff))
      end
      return 'released', dwell.pointId
    end
    return 'dwelling', dwell.pointId
  end
  if not speed or speed >= M.COURIER_STOP_MAX_SPEED_MS then return 'none' end
  local limitMs = tonumber(roadLimitMs)
  if limitMs == nil and map and map.getMap then
    local road = closestRoad(px, py, 0)
    if road then
      if road.highway == true or road.unlimited == true then return 'none' end
      limitMs = tonumber(road.speedLimit)
    end
  end
  if limitMs ~= nil and (limitMs <= 0 or limitMs > M.COURIER_STOP_MAX_LIMIT_MS) then return 'none' end
  if director.deliveryPointCount <= 0 then return 'none' end

  local range2 = M.COURIER_STOP_RANGE_M * M.COURIER_STOP_RANGE_M
  local latMax = M.COURIER_STOP_LATERAL_MAX_M
  local bestPt, bestD2 = nil, range2 + 1
  for _, list in pairs(director.deliveryPoints) do
    for i = 1, #list do
      local s = list[i]
      local cd = director.deliveryCooldowns[s.id]
      if not cd or now >= cd then
        local vx, vy = s.x - px, s.y - py
        local d2 = vx * vx + vy * vy
        if d2 <= range2 and d2 < bestD2 then
          local along = vx * dx + vy * dy
          if along >= -2.0 and along <= M.COURIER_STOP_RANGE_M then
            local lat = math.abs(vx * dy - vy * dx)
            if lat <= latMax then
              bestPt, bestD2 = s, d2
            end
          end
        end
      end
    end
  end
  if not bestPt then return 'none' end

  local frac = (((math.abs(math.floor(tonumber(vehId) or 0)) * 131 + math.floor(now * 10)) % 101) / 100)
  local dwellS = M.COURIER_STOP_DWELL_MIN_S + frac * (M.COURIER_STOP_DWELL_MAX_S - M.COURIER_STOP_DWELL_MIN_S)
  local curbSign = (M.rules and M.rules.rightHandDrive) and -1 or 1
  local curbOff = curbSign * M.COURIER_STOP_CURB_OFFSET_M
  director.courierDwell[vehId] = {
    pointId = bestPt.id,
    startedAt = now,
    releaseAt = now + dwellS,
    dwellS = dwellS,
    curbOffset = curbOff,
  }
  director.deliveryCooldowns[bestPt.id] = now + dwellS + M.COURIER_STOP_COOLDOWN_S
  if obj and obj.queueLuaCommand then
    obj:queueLuaCommand(string.format(
      'electrics.set_warn_signal(1) ai.driveInLane("off") ai.laneChange(nil, 10.0, %.2f) ai.setSpeedMode("set") ai.setSpeed(0)',
      curbOff))
  end
  return 'stopped', bestPt
end

-- Pure zero-alloc: true when candidate horizon spawn point (sx, sy) is >= minSpacingM from all recent horizon spawns.
function M.horizonSpawnClear(sx, sy, recentSpawns, now, minSpacingM)
  local minD = minSpacingM or M.HORIZON_SPAWN_SPACING_M
  local minD2 = minD * minD
  local ttl = M.HORIZON_SPACING_TTL_S
  for i = 1, #recentSpawns do
    local s = recentSpawns[i]
    if s and (now - s.at) <= ttl then
      local dx, dy = sx - s.x, sy - s.y
      if dx * dx + dy * dy < minD2 then return false end
    end
  end
  return true
end

-- Pure zero-alloc: true when AI vehicle at (vx, vy) lags > behindM behind player (px, py) heading unit (hx, hy).
function M.shouldRecycleBehind(vx, vy, px, py, hx, hy, behindM)
  local along = (vx - px) * hx + (vy - py) * hy
  return along < -(behindM or M.HORIZON_BEHIND_DESPAWN_M)
end

-- Pure zero-alloc: forward-biased horizon respawn interval [lo, hi] along unit (hx, hy) from (px, py),
-- clamped to box b's guard margin and never popping in within < HORIZON_SAFE_MIN_M of player or camera.
function M.horizonSpawnWindow(px, py, hx, hy, b, camX, camY)
  local hl = math.sqrt(hx * hx + hy * hy)
  if hl < 1e-6 then return nil end
  hx, hy = hx / hl, hy / hl
  local reach = math.huge
  if b then
    if hx > 1e-6 then reach = math.min(reach, (b[3] - px) / hx)
    elseif hx < -1e-6 then reach = math.min(reach, (b[1] - px) / hx) end
    if hy > 1e-6 then reach = math.min(reach, (b[4] - py) / hy)
    elseif hy < -1e-6 then reach = math.min(reach, (b[2] - py) / hy) end
  end
  local hi = math.min(M.HORIZON_SPAWN_MAX_M, reach - M.GUARD_M - 20)
  local safeMin = M.HORIZON_SAFE_MIN_M
  if camX and camY then
    local camAlong = (camX - px) * hx + (camY - py) * hy
    local camPerp = math.abs((camX - px) * hy - (camY - py) * hx)
    if camPerp < M.HORIZON_SAFE_MIN_M then
      local clearance = math.sqrt(M.HORIZON_SAFE_MIN_M * M.HORIZON_SAFE_MIN_M - camPerp * camPerp)
      local needed = camAlong + clearance
      if needed > safeMin then safeMin = needed end
    end
  end
  local lo = math.max(M.HORIZON_SPAWN_MIN_M, safeMin)
  if hi < lo then
    lo = safeMin
    if hi < lo then return nil end
  end
  return px, py, hx, hy, lo, hi
end

-- Throttled (~4 Hz) zero-GC traffic director: persona sync, bus stop dwell, and behind-player horizon recycling.
function M.updateTrafficDirector(dtReal, player, box)
  local dt = tonumber(dtReal) or 0
  if dt < 0 then dt = 0 end
  director.clock = director.clock + dt
  director.accum = director.accum + dt
  if director.accum < M.DIRECTOR_TICK_S then return false end
  director.accum = 0

  if not M.enabled then return false end
  if simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() then return false end
  local gt = gameplay_traffic
  if not gt or not gt.getState or gt.getState() ~= 'on' then return false end
  local data = gt.getTrafficData and gt.getTrafficData()
  if type(data) ~= 'table' then return false end

  local now = os.clock()
  local me = playerId()
  local px, py, pz, hx, hy = nil, nil, 0, 0, 0
  if type(player) == 'table' and tonumber(player.x) and tonumber(player.y) then
    px, py, pz = player.x, player.y, tonumber(player.z) or 0
    local pvx, pvy = tonumber(player.vx) or 0, tonumber(player.vy) or 0
    local psp = math.sqrt(pvx * pvx + pvy * pvy)
    if psp >= 2.0 then
      hx, hy = pvx / psp, pvy / psp
    end
  end
  local pv = (px == nil or (hx == 0 and hy == 0)) and me >= 0 and getObjectByID and getObjectByID(me) or nil
  if pv then
    if px == nil then
      local pp = pv:getPosition()
      px, py, pz = pp.x, pp.y, pp.z
    end
    if hx == 0 and hy == 0 then
      local pu = pv:getVelocity()
      local psp = math.sqrt(pu.x * pu.x + pu.y * pu.y)
      if psp >= 2.0 then
        hx, hy = pu.x / psp, pu.y / psp
      else
        local pf = pv:getDirectionVector()
        local pfl = math.sqrt(pf.x * pf.x + pf.y * pf.y)
        if pfl > 1e-6 then hx, hy = pf.x / pfl, pf.y / pfl end
      end
    end
  end
  local hasHeading = (px ~= nil) and (hx * hx + hy * hy > 0.25)
  local camX, camY = nil, nil
  if core_camera and core_camera.getPosition then
    local cp = core_camera.getPosition()
    if cp then camX, camY = cp.x, cp.y end
  end
  local activeBox = box or (applied and applied.box) or nil
  local lightsOn = M.needsHeadlights()

  -- Clean stale personas / dwells / livery flags for despawned vehicles
  for id in pairs(director.personas) do
    if data[id] == nil then director.personas[id] = nil end
  end
  for id in pairs(director.liveryApplied) do
    if data[id] == nil then director.liveryApplied[id] = nil end
  end
  for id in pairs(director.busDwell) do
    if data[id] == nil then director.busDwell[id] = nil end
  end
  for id in pairs(director.courierDwell) do
    if data[id] == nil then director.courierDwell[id] = nil end
  end

  localplayers.snapshot(controlled)
  for id, t in pairs(data) do
    if type(t) == 'table' and t.isAi ~= false then
      local o = getObjectByID and getObjectByID(id) or nil
      if o and o:getActive() and not localplayers.controlled(id, o, controlled) then
        local p = o:getPosition()
        local u = o:getVelocity()
        local f = o:getDirectionVector()
        local sp = math.sqrt(u.x * u.x + u.y * u.y)
        local dx, dy = 0, 0
        if sp > 0.5 then
          dx, dy = u.x / sp, u.y / sp
        else
          local fl = math.sqrt(f.x * f.x + f.y * f.y)
          if fl > 1e-6 then dx, dy = f.x / fl, f.y / fl end
        end

        -- 1. Assign or refresh persona (and inject dynamic delivery paint_design on couriers) on first sight / respawn
        local rc = tonumber(t.respawnCount) or 0
        local curP = director.personas[id]
        local road = nil
        if not curP or curP._respawnCount ~= rc then
          local model = t.model or (o.getJBeamFilename and o:getJBeamFilename()) or ''
          local config = t.config or t.partConfig or ''
          local rkey = tostring(model):lower() .. ':' .. tostring(config):lower()
          road = map and map.getMap and closestRoad(p.x, p.y, p.z) or nil
          local isAutobahn = road ~= nil and road.unlimited == true
          local rArch = director.rosterArchetype[rkey]
          local rEntry = director.rosterEntry[rkey]
          local liveryEntry = nil
          if rArch == 'courier' or (rArch == nil and M.classifyVehicle(model, config, rEntry) == 'courier') then
            if M.isCargoCourierConfig(model, config, rEntry) then
              liveryEntry = {
                model = model,
                config = config,
                region = M.trafficRegion or 'europe',
                hasDeliveryLivery = rEntry and rEntry.hasDeliveryLivery or nil,
                paintDesign = rEntry and rEntry.paintDesign or nil,
                paint = rEntry and rEntry.paint or nil,
                paintName = rEntry and rEntry.paintName or nil,
              }
              if director.liveryApplied[id] ~= rc then
                director.liveryApplied[id] = rc
                M.applyVehicleLivery(id, liveryEntry)
              end
            end
          end
          local assigned = M.assignVehiclePersona(id, model, config, isAutobahn, rArch, liveryEntry or rEntry)
          assigned._respawnCount = rc
          director.personas[id] = assigned
          curP = assigned
          if t.risk ~= nil then t.risk = assigned.risk end
          local cmd = M.personaAiCommand(assigned, lightsOn)
          if cmd and o.queueLuaCommand then o:queueLuaCommand(cmd) end
        end

        -- 2. City bus / H-Series minibus OSM bus stop & AI courier village-only curbside delivery dwell state machines
        if curP.persona == 'bus' and (dx ~= 0 or dy ~= 0) then
          M.stepBusStop(id, p.x, p.y, dx, dy, sp, now, o)
        elseif curP.persona == 'courier' and (dx ~= 0 or dy ~= 0) then
          if road == nil and map and map.getMap then road = closestRoad(p.x, p.y, p.z) end
          local roadLimitMs = nil
          if road then
            roadLimitMs = (road.highway == true or road.unlimited == true) and math.huge or road.speedLimit
          end
          M.stepCourierStop(id, p.x, p.y, dx, dy, sp, now, o, roadLimitMs)
        end

        -- 3. Behind-player horizon recycling into forward cone [160, 340] m (never < 95 m, >= 140 m spacing)
        if hasHeading and not director.busDwell[id] and not director.courierDwell[id]
            and (now - (lastTeleport[id] or -math.huge)) >= M.COOLDOWN_S
            and M.shouldRecycleBehind(p.x, p.y, px, py, hx, hy) then
          local ax, ay, ahx, ahy, alo, ahi = M.horizonSpawnWindow(px, py, hx, hy, activeBox, camX, camY)
          if ax and gt.forceTeleport then
            local mid = (alo + ahi) * 0.5
            local sx, sy = ax + ahx * mid, ay + ahy * mid
            if M.horizonSpawnClear(sx, sy, director.recentSpawns, now) then
              lastTeleport[id] = now
              stillSince[id] = nil
              local slot = (director.recentSpawnIdx % #director.recentSpawns) + 1
              director.recentSpawnIdx = slot
              local rec = director.recentSpawns[slot]
              rec.x, rec.y, rec.at = sx, sy, now
              stats.horizonRespawns = (stats.horizonRespawns or 0) + 1
              pcall(gt.forceTeleport, id, vec3(ax, ay, pz), vec3(ahx, ahy, 0), alo, ahi)
              if lightsOn and o.queueLuaCommand then
                o:queueLuaCommand('electrics.setLightsState(1)')
              end
            end
          end
        end
      end
    end
  end
  return true
end

local function regionalGroup()
  local st = rawget(_G, 'settings')
  local cc = graph and graph.rules and graph.rules.country
  local euPolice = deStreetImmersionOn()
  local params, region = M.regionalGroupParams(cc, st and st.getValue and function(k) return st.getValue(k) end, euPolice)
  M.trafficRegionKey = region or 'none'
  M.trafficRegion = nil
  if not params then return nil end
  if not core_multiSpawn and extensions and extensions.load then pcall(extensions.load, 'core_multiSpawn') end
  if not (core_multiSpawn and core_multiSpawn.createGroup) then return nil end
  local ok, g = pcall(core_multiSpawn.createGroup, M.GROUP_SIZE, params)
  if not ok or type(g) ~= 'table' or not g[1] then return nil end
  local simpleTraffic = st and st.getValue and st.getValue('trafficSimpleVehicles') and true or false
  local candidates = {}
  for i = 1, #g do
    local src = g[i]
    if type(src) == 'table' then
      candidates[#candidates + 1] = {
        model = src.model,
        config = src.config,
        name = src.name,
        region = src.region or region,
        paint = src.paint,
        paintName = src.paintName,
      }
    end
  end
  local configListCount = 0
  local cv = rawget(_G, 'core_vehicles')
  if cv and cv.getConfigList then
    local okC, list = pcall(cv.getConfigList)
    if okC and type(list) == 'table' then
      for _, v in pairs(list) do
        if type(v) == 'table' and type(v.model_key) == 'string' and type(v.key) == 'string' then
          candidates[#candidates + 1] = { model = v.model_key, config = v.key, name = v.Name or v.Configuration }
          configListCount = configListCount + 1
        end
      end
    end
  end
  if not simpleTraffic or configListCount > 0 then
    local prof = graph and graph.trafficProfile
    local isUrban = not (type(prof) == 'table' and (prof.band == 'rural' or prof.band == 'highway'))
    local roster = M.buildTrafficRoster(region, candidates, euPolice, {
      urban = isUrban, size = M.GROUP_SIZE, includePolice = M.choice.police,
    })
    if type(roster) == 'table' and roster[1] then
      g = roster
      director.rosterArchetype = {}
      director.rosterEntry = {}
      for i = 1, #roster do
        local e = roster[i]
        if e.model and e.archetype then
          local rk = tostring(e.model):lower() .. ':' .. tostring(e.config or ''):lower()
          director.rosterArchetype[rk] = e.archetype
          director.rosterEntry[rk] = e
        end
      end
    end
  end
  if euPolice and region == 'europe' then M.appendEuPolicePatrols(g, cc) end
  M.trafficRegion = region
  log('I', 'beamngEarth', string.format('traffic: %s vehicles (%s)', region, tostring(cc)))
  return g
end
M._regionalGroup = regionalGroup

local function setupTraffic(gt, c)
  local okG, group = pcall(regionalGroup)
  local ok, err = pcall(gt.setupTraffic, c.trafficAmount ~= 0 and c.trafficAmount or -1,
    { police = c.police, vehGroup = okG and group or nil })
  if not ok then log('W', 'beamngEarth', 'navgraph: setupTraffic: ' .. tostring(err)) end
end

local function startTraffic()
  started = true
  M.restoreChoice()       -- freeroam's own spawn time has passed
  local c = M.choice
  local gt = c.traffic and trafficSystem() or nil
  if gt and gt.getState() ~= 'on' then setupTraffic(gt, c) end
end

-- The traffic set up again with the new place's vehicles when a graph of another region comes (a teleport from
-- the US to Germany kept the American cars): once per region change, the stock group outside the regions.
M.REGION_CHECK_S = 2.0
local regionCheckAt = 0
local function checkRegion(t)
  if t < regionCheckAt or not started or not M.trafficRegionKey then return end
  regionCheckAt = t + M.REGION_CHECK_S
  local want = M.regionOf(graph and graph.rules and graph.rules.country) or 'none'
  if want == M.trafficRegionKey then return end
  local c = M.choice
  local gt = c and c.traffic and trafficSystem() or nil
  if not gt or gt.getState() ~= 'on' then return end
  log('I', 'beamngEarth', string.format('traffic: region %s -> %s, set up again', M.trafficRegionKey, want))
  setupTraffic(gt, c)
  M.trafficRegionKey = want         -- (once a change, whatever the setup did)
end

-- The player teleported: the traffic cars go inactive (no physics: their old positions have no ground) and come
-- back on the new place's graph once it is in.
local heldActive = nil

-- Adaptive traffic amount (PR #728 / #773, ProxyFirewall202; docs/ADAPTIVE_TRAFFIC.md): with the setting on (M.ADAPTIVE,
-- settings adaptiveTraffic; off by default), the stock traffic's active amount follows the graph's trafficProfile.target
-- (server traffic.py: the nearest populated place and the road length round the graph's centre, a divided road
-- doubling it), never over the player's own amount (the ceiling before we touched it, or the cars spawned), moved one
-- car at a time at most every ADAPTIVE_STEP_S; after a teleport the new place's amount at once. Not while the pool is
-- held for a teleport or an occupied traffic car is protected. A ceiling changed by someone else (the radial menu, the
-- game's UI) becomes the player's amount. Off again: the player's amount back. Looked at every ADAPTIVE_CHECK_S.
M.ADAPTIVE = false
M.ADAPTIVE_STEP_S = 5
M.ADAPTIVE_CHECK_S = 1
-- base: the player's amount (the stock ceiling we found, or set by someone else since); seen: the ceiling as we last
-- left it; touched: we changed it; paused: the player's traffic toggled off (ceiling 0), left alone until it is back
local function newAdaptive()
  return { base = nil, seen = nil, touched = false, paused = false, target = nil, lastStep = -math.huge,
           lastCheck = -math.huge }
end
local adaptive = newAdaptive()

-- Pure: the amount (whole cars) for a profile target t and the player's amount cap.
function M.adaptiveTarget(t, cap)
  t, cap = tonumber(t), tonumber(cap)
  if not t or t ~= t or not cap or cap ~= cap then return nil end
  return math.max(0, math.min(math.floor(cap), math.floor(t + 0.5)))
end

-- Pure: the next ceiling from current toward target, one car at a time.
function M.adaptiveStep(current, target)
  if current < target then return current + 1 elseif current > target then return current - 1 end
  return current
end

-- The player's amount as a number of cars: base, at most the cars the traffic spawned (a ceiling of math.huge: those).
local function adaptiveCap(gt)
  local base = adaptive.base
  local n = gt.getNumOfTraffic and tonumber(gt.getNumOfTraffic()) or nil
  if not base or base == math.huge then base = n or base end
  if n and base then base = math.min(base, n) end
  return base
end

-- The amount the graph's profile asks for now (nil: adaptive off, no profile or no player's amount yet).
local function adaptiveAmount(gt)
  if not (M.ADAPTIVE and graph and graph.trafficProfile and gt and adaptive.base) then return nil end
  return M.adaptiveTarget(graph.trafficProfile.target, adaptiveCap(gt))
end

local function updateAdaptive(now)
  if now - adaptive.lastCheck < M.ADAPTIVE_CHECK_S then return end
  adaptive.lastCheck = now
  local gt = gameplay_traffic
  if not (started and M.choice.traffic and gt and gt.getState and gt.getState() == 'on' and gt.setActiveAmount) then
    return
  end
  if heldActive ~= nil or respawnAll or next(protectedTraffic) ~= nil then return end
  local vars = gt.getTrafficVars and gt.getTrafficVars() or {}
  local cur = tonumber(vars.activeAmount)
  if cur == nil then return end
  if not M.ADAPTIVE then
    if adaptive.touched and cur == adaptive.seen and adaptive.base ~= nil and not adaptive.paused then
      pcall(gt.setActiveAmount, adaptive.base)               -- (off again: the player's amount back)
      log('I', 'beamngEarth', 'Adaptive traffic off: active amount back to ' .. tostring(adaptive.base))
    end
    if adaptive.base ~= nil then adaptive = newAdaptive() end
    return
  end
  if adaptive.seen == nil or cur ~= adaptive.seen then
    -- (first look, or changed by someone else: the player's amount now; 0: their traffic toggled off)
    if cur == 0 then adaptive.paused = true else adaptive.base, adaptive.paused = cur, false end
    adaptive.seen = cur
  end
  if adaptive.paused then return end
  local target = adaptiveAmount(gt)
  adaptive.target = target
  if not target or now - adaptive.lastStep < M.ADAPTIVE_STEP_S then return end
  local current = cur
  if current == math.huge then current = adaptiveCap(gt) end
  if not current or current == target then return end
  local nextAmount = M.adaptiveStep(current, target)
  local ok, err = pcall(gt.setActiveAmount, nextAmount)
  if ok then
    adaptive.seen, adaptive.touched, adaptive.lastStep = nextAmount, true, now
    log('D', 'beamngEarth', string.format('Adaptive traffic: active amount %s -> %d (target %d)', tostring(current),
      nextAmount, target))
  else
    log('W', 'beamngEarth', 'Adaptive traffic: setActiveAmount: ' .. tostring(err))
  end
end

function M._adaptiveTick(now) return updateAdaptive(now) end     -- (tests)
function M.setAdaptive(on) M.ADAPTIVE = on and true or false end

function M.trafficStatus()
  return { enabled = M.ADAPTIVE, target = adaptive.target, applied = adaptive.touched and adaptive.seen or nil,
           base = adaptive.base, paused = adaptive.paused, profile = graph and graph.trafficProfile or nil }
end

-- A rebase (core finishRebase, xf: the old frame -> the new one): the server's graph moved into the new anchor and
-- applied again at once, as the roads and trees are moved. It was dropped instead (its anchor no longer the current
-- one) and the game's map stayed in the old frame until the server's graph for the new anchor came, seconds later:
-- the AI planned toward roads hundreds of metres off and swerved, into a street tree on North Front Street, Baltimore
-- (Steam Deck, 3 of 3 rebase drives, 2026-10-29). The server's own graph replaces this one when it comes.
function M.transform(xf, anchorId)
  if not graph or not xf then return false end
  local nodes = {}
  for name, n in pairs(graph.nodes) do
    local m = {}
    for i, v in ipairs(n) do m[i] = v end
    m[1], m[2], m[3] = xf:apply(n[1], n[2], n[3])
    nodes[name] = m
  end
  local lines
  if graph.lines then
    lines = {}
    for i, l in ipairs(graph.lines) do
      local x1, y1 = xf:apply(l[1], l[2], 0)
      local x2, y2 = xf:apply(l[3], l[4], 0)
      lines[i] = { x1, y1, x2, y2, l[5] }
    end
  end
  graph = { anchor = anchorId, serial = graph.serial, nodes = nodes, edges = graph.edges, signals = graph.signals,
            rules = graph.rules, lines = lines, trafficProfile = graph.trafficProfile, mph = graph.mph, moved = true }
  -- Transform anchor-tile bus stops into the new frame (geotile stops are refreshed by roads.replace)
  for key, list in pairs(director.busStops) do
    if type(key) ~= 'string' or key:sub(1, 2) ~= 'g:' then
      for i = 1, #list do
        local s = list[i]
        s.x, s.y, s.z = xf:apply(s.x, s.y, s.z)
      end
    end
  end
  dirty, urgent = true, true
  if applied then applied.box = nil end
  return true
end

function M.currentGraph() return graph end      -- (tests)
function M._startTraffic() return startTraffic() end    -- (tests: the level start's traffic, by hand)
function M._cuts() return cuts end      -- (probes: the clip's cut nodes)

function M.onTeleport()
  respawnAll = true
  local gt = gameplay_traffic
  if gt and gt.getState() == 'on' and not heldActive and syncTrafficPool(gt) then
    local vars = gt.getTrafficVars and gt.getTrafficVars() or {}
    heldActive = vars.activeAmount or math.huge
    pcall(gt.setActiveAmount, 0)
  end
end

-- Every frame: a new graph, a moved block or a foreign reset applies the graph again; the traffic guard.
-- Pure: how far the centre of ground box b {x0, y0, x1, y1} is from that of box a (0 when either is missing).
function M.boxMoved(a, b)
  if not a or not b or not a[4] or not b[4] then return 0 end
  local dx = (b[1] + b[3]) / 2 - (a[1] + a[3]) / 2
  local dy = (b[2] + b[4]) / 2 - (a[2] + a[4]) / 2
  return math.sqrt(dx * dx + dy * dy)
end

local waited = 0

-- The node tables an apply hands map.reset, built over several frames (toNodes in a coroutine, PREP_MS a frame; ~20 ms in
-- one frame on a Steam Deck), for this graph and block box; nil until done.
M.PREP_MS = 2.0
M.PREP_YIELD = 256
local prep = nil        -- { graph, box, co, result }

local function buildNodes(b)
  if not prep or prep.graph ~= graph or not (prep.box == b or (prep.box and b and prep.box[1] == b[1] and prep.box[2] == b[2]
      and prep.box[3] == b[3] and prep.box[4] == b[4])) then
    setRules()
    local g, box, rh = graph, b and { b[1], b[2], b[3], b[4] } or nil, M.rules.rightHandDrive
    prep = { graph = g, box = box, co = coroutine.create(function()
      return { M.toNodes(g, box, M.EDGE_M, rh, M.PREP_YIELD, M.HALO_M, M.FAST_HALO_M) }
    end) }
  end
  if prep.result then return prep.result end
  local sw = stopwatch.new()
  repeat
    local ok, res = coroutine.resume(prep.co)
    if not ok then
      log('W', 'beamngEarth', 'navgraph: nodes: ' .. tostring(res))
      prep = nil
      return nil
    end
    if coroutine.status(prep.co) == 'dead' then prep.result = res end
  until prep.result or sw() >= M.PREP_MS
  return prep.result
end

-- May the apply run in this frame (gov: the frame governor; nil: always)?
local function room(gov)
  if not (gov and gov.roomFor) or waited >= M.APPLY_WAIT_FRAMES or gov:roomFor(M.APPLY_ROOM_MS) then
    waited = 0
    return true
  end
  waited = waited + 1
  return false
end

-- Pure (PR #728, ProxyFirewall202): the vehicle Lua that pushes a car standing (or slower than target - 1 m/s) on to
-- target m/s along its heading (thrusters.applyVelocity) and spins its wheels to match (beamngEarth_spawnMotion), or nil.
function M.spawnVelocityCommand(target)
  target = tonumber(target)
  if not target or target ~= target or target <= 1 or target == math.huge or target > 80 then return nil end
  local threshold = math.max(0, target - 1)
  return string.format('local _d=obj:getDirectionVector(); local _v=obj:getVelocity(); local _f=_v:dot(_d); '
    .. 'if _f>=-1 and _f<%.3f and thrusters and type(thrusters.applyVelocity)=="function" then '
    .. 'local _ok=pcall(thrusters.applyVelocity,_d*%.3f); if _ok then pcall(function() '
    .. 'if not beamngEarth_spawnMotion then extensions.load("beamngEarth_spawnMotion") end; '
    .. 'if beamngEarth_spawnMotion then beamngEarth_spawnMotion.applyRollingSpeed(%.3f) end end) end end',
    threshold, target, target)
end

-- Pure: the speed (m/s) a respawned car is launched at on an edge with this limit (m/s), its heading's cosine with the
-- edge's direction (in -> out; negative: against it), the edge one-way, a junction within LAUNCH_JUNCTION_M; or nil.
function M.launchSpeed(limit, cosine, oneWay, nearJunction)
  limit, cosine = tonumber(limit), tonumber(cosine)
  if not limit or not cosine or nearJunction then return nil end
  if (oneWay and cosine or math.abs(cosine)) < M.LAUNCH_ALIGN then return nil end
  local v = limit * M.LAUNCH_SHARE
  if v < M.LAUNCH_MIN_MS then return nil end
  return math.min(v, 80)
end

local launchCount, launchWait, lastLaunchScan = {}, {}, -math.huge
local junctionNodes, junctionOf = nil, nil   -- (the graph's nodes where 3+ roads meet: positions, per graph table)

local function nearJunction(x, y, radius)
  if not graph then return false end
  if junctionOf ~= graph then
    local deg = {}
    for _, e in ipairs(graph.edges) do deg[e[1]], deg[e[2]] = (deg[e[1]] or 0) + 1, (deg[e[2]] or 0) + 1 end
    junctionNodes, junctionOf = {}, graph
    for name, n in pairs(graph.nodes) do
      if (deg[name] or 0) > 2 then junctionNodes[#junctionNodes + 1] = n end
    end
  end
  local r2 = (radius or M.LAUNCH_JUNCTION_M) ^ 2
  for _, n in ipairs(junctionNodes) do
    if (x - n[1]) ^ 2 + (y - n[2]) ^ 2 < r2 then return true end
  end
  return false
end

local function launch(id)
  local o = getObjectByID(id)
  if not o or not o:getActive() or localplayers.controlled(id, o, controlled) then return end
  local m = map and map.getMap and map.getMap()
  local p = o:getPosition()
  local n1, n2 = map.findClosestRoad(p)
  local a, c = m and n1 and m.nodes[n1], m and n2 and m.nodes[n2]
  local e = a and c and (a.links[n2] or c.links[n1])
  if not e then return end
  local inN, outN = m.nodes[e.inNode or n1], m.nodes[e.outNode or n2]
  if not inN or not outN then return end
  local d = outN.pos - inN.pos
  d.z = 0
  local f = o:getDirectionVector()
  f.z = 0
  if d:length() < 0.1 or f:length() < 0.1 then return end
  local v = M.launchSpeed(e.speedLimit, d:normalized():dot(f:normalized()), e.oneWay, nearJunction(p.x, p.y))
  local cmd = v and M.spawnVelocityCommand(v)
  if cmd then
    o:queueLuaCommand(cmd)
    stats.launches = (stats.launches or 0) + 1
  end
end

-- Every LAUNCH_SCAN_S: the traffic cars whose respawn count went up are launched once placed (M.LAUNCH above).
local function launchRespawned(now)
  local gt = gameplay_traffic
  if not M.LAUNCH or not gt or not gt.getState or gt.getState() ~= 'on' or now - lastLaunchScan < M.LAUNCH_SCAN_S then
    return
  end
  lastLaunchScan = now
  if simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() then return end
  localplayers.snapshot(controlled)
  local data = gt.getTrafficData() or {}
  for id, t in pairs(data) do
    if type(t) == 'table' and t.isAi ~= false then
      local rc = tonumber(t.respawnCount)
      if rc and launchCount[id] and rc > launchCount[id] then
        launchWait[id] = { readyAt = nil, expires = now + M.LAUNCH_TIMEOUT_S }
      end
      launchCount[id] = rc
      local w = launchWait[id]
      if w then
        if t.state == 'fadeIn' or (t.state == 'active' and t.respawnActive ~= true) then
          w.readyAt = w.readyAt or (now + M.LAUNCH_DELAY_S)
          if now >= w.readyAt then
            launchWait[id] = nil
            local ok, err = pcall(launch, id)
            if not ok then log('W', 'beamngEarth', 'navgraph launch: ' .. tostring(err)) end
          end
        elseif now >= w.expires then
          launchWait[id] = nil
        end
      end
    end
  end
  for id in pairs(launchCount) do
    if data[id] == nil then launchCount[id], launchWait[id] = nil, nil end
  end
end

-- Overtaking on multi-lane highways (overtake.lua): the traffic cars and the player's car while it autodrives.
local function overtakeScan(now)
  local gt = gameplay_traffic
  if not overtake.due(now) or not gt or not gt.getState or gt.getState() ~= 'on' then return end
  local ids = {}
  for id, t in pairs(gt.getTrafficData() or {}) do
    if type(t) == 'table' and t.isAi ~= false then ids[id] = true end
  end
  local gps = package.loaded['beamngEarth/gps']
  local st = gps and gps.status and gps.status()
  local me = playerId()
  local auto = st and st.autodrive and me >= 0 and me or nil
  if auto then ids[auto] = nil end
  localplayers.snapshot(controlled)
  overtake.update(now, ids, auto, nearJunction, M.rules.rightHandDrive,
    function(id) return localplayers.controlled(id, getObjectByID(id), controlled) end,
    M.getVehiclePersona)
end

function M.update(aid, b, gov)
  if not M.enabled or not graph then return end
  local t0 = os.clock()
  do
    local ok, err = pcall(checkRegion, t0)
    if not ok then log('W', 'beamngEarth', 'navgraph region: ' .. tostring(err)) end
  end
  if applied then
    local ok, err = pcall(launchRespawned, t0)
    if not ok then log('W', 'beamngEarth', 'navgraph launch scan: ' .. tostring(err)) end
    ok, err = pcall(overtakeScan, t0)
    if not ok then log('W', 'beamngEarth', 'navgraph overtake scan: ' .. tostring(err)) end
    if t0 - adaptive.lastCheck >= M.ADAPTIVE_CHECK_S then       -- (once a second, on or off: off puts the amount back)
      ok, err = pcall(updateAdaptive, t0)
      if not ok then log('W', 'beamngEarth', 'navgraph adaptive traffic: ' .. tostring(err)) end
    end
  end
  if applied and t0 - lastGuard >= M.GUARD_S then
    -- (the gate is elapsed time, so the first frame after a long one scans at once; the lag widens its window)
    local lag = lastGuard > -math.huge
      and math.min(math.max(t0 - lastGuard - M.GUARD_S, 0), M.GUARD_LAG_MAX_S) or 0
    lastGuard = t0
    local ok, err = pcall(guard, b, false, lag)
    if not ok then log('W', 'beamngEarth', 'navgraph guard: ' .. tostring(err)) end
    local g = (os.clock() - t0) * 1000
    stats.guardMs = g
    stats.guardMaxMs = math.max(stats.guardMaxMs or 0, g)
  end
  if graph.anchor ~= aid then
    graph = nil
    return
  end
  if pendingSignals then
    if not room(gov) then return end
    local nodes = pendingSignals
    pendingSignals = nil
    local sw = stopwatch.new()
    applySignals(nodes)
    if gov and gov.noteFrame then gov:noteFrame(sw()) end
    return
  end
  -- a small block move alone does not re-apply (each apply is a ~40 ms frame); one of RECLIP_M does
  if not (dirty or foreign) and applied and M.boxMoved(applied.box, b) >= M.RECLIP_M then dirty = true end
  if not (dirty or foreign) then return end
  local t = os.clock()
  if t - lastApply < M.MIN_GAP_S and not foreign and not urgent then return end
  -- (a moved graph, M.transform: built in one go and applied in this frame, whatever the frame budget: until the cars
  -- have it their AI drives on points of the old frame)
  local pre
  if urgent then
    setRules()
    pre = { M.toNodes(graph, b and { b[1], b[2], b[3], b[4] } or nil, M.EDGE_M, M.rules.rightHandDrive, nil, M.HALO_M,
                      M.FAST_HALO_M) }
  else
    pre = buildNodes(b)
    if not pre or not room(gov) then return end
  end
  prep = nil
  lastApply = t
  dirty, foreign = false, false
  local moved = urgent
  urgent = false
  local sw = stopwatch.new()
  local okA = apply(b, pre, moved)
  if gov and gov.noteFrame then gov:noteFrame(sw()) end
  if okA then
    applied = { anchor = aid, serial = graph.serial, box = b and { b[1], b[2], b[3], b[4] } or {} }
    if not started then startTraffic() end
    if respawnAll then
      respawnAll = false
      local gt = gameplay_traffic
      if gt and heldActive then
        syncTrafficPool(gt)
        -- (adaptive: the new place's amount at once, not stepped up from the old place's)
        if M.ADAPTIVE and not adaptive.paused then
          if adaptive.base == nil then adaptive.base = heldActive end    -- (the pool's 0 while held is not the player's)
          local okA2, want = pcall(adaptiveAmount, gt)
          if okA2 and want then heldActive, adaptive.seen, adaptive.touched = want, want, true end
        end
        pcall(gt.setActiveAmount, heldActive)
        heldActive = nil
        scatterTraffic(gt, b)
      else
        pcall(guard, b, true)
      end
    end
  end
end

-- onNavgraphReloaded (core forwards the hook): someone else rebuilt the map; ours again next frame.
function M.onReloaded()
  if not ours and graph then foreign = true end
end

-- How many times a graph went into the game's map (gps.lua: the map's node table stays the same table across them).
function M.applies() return stats.applies end

-- The server's last graph, unclipped ({anchor, serial, nodes, edges}; nil before one): the cars' navigation screens
-- draw its roads (dashboard.lua). Read-only. (The accessor as in iambobab's PR #472.)
function M.graph() return graph end

function M.status()
  return { graph = graph and graph.serial or nil, applies = stats.applies, lastMs = stats.lastMs,
           nodes = stats.nodes, edges = stats.edges, junctions = stats.junctions, started = started,
           cuts = stats.cuts, cutRespawns = stats.cutRespawns, cutStopRespawns = stats.cutStopRespawns,
           aheadRespawns = stats.aheadRespawns, horizonRespawns = stats.horizonRespawns,
           busStopsLoaded = director.busStopCount, busStopsServed = stats.busStopsServed,
           deliveryPointsLoaded = director.deliveryPointCount, courierStopsServed = stats.courierStopsServed,
           launches = stats.launches, oncomingRespawns = stats.oncomingRespawns, overtake = overtake.status(),
           resetMs = stats.resetMs, signalsMs = stats.signalsMs, nodesMs = stats.nodesMs, gpsMs = stats.gpsMs,
           applyMs = stats.applyMs, guardMs = stats.guardMs, guardMaxMs = stats.guardMaxMs,
           traffic = gameplay_traffic and gameplay_traffic.getState() or nil, trafficAdaptive = M.trafficStatus() }
end

function M.reset()
  local gt = gameplay_traffic
  if gt and gt.getState and gt.getState() == 'on' and (heldActive or next(protectedTraffic)) then
    syncTrafficPool(gt)
    if heldActive then pcall(gt.setActiveAmount, heldActive) end
    local pool, data = trafficPool(), gt.getTrafficData and gt.getTrafficData() or {}
    -- Keep any still-occupied cars active while returning them to the stock pool on level exit.
    for id, saved in pairs(protectedTraffic) do releaseTraffic(id, saved, pool, data, true) end
  else
    for id, saved in pairs(protectedTraffic) do
      local t = saved.traffic
      if t.enableRespawn == false then t.enableRespawn = saved.enableRespawn end
      if t.ignoreForceTeleport == true then t.ignoreForceTeleport = saved.ignoreForceTeleport end
      protectedTraffic[id] = nil
    end
  end
  heads = {}            -- (the level took them with it)
  graph, applied, dirty, lastApply, persistent, ours, foreign = nil, nil, false, -math.huge, nil, false, false
  started, respawnAll, lastGuard, heldActive = false, false, -math.huge, nil
  adaptive = newAdaptive()
  launchCount, launchWait, lastLaunchScan, junctionNodes, junctionOf = {}, {}, -math.huge, nil, nil
  overtake.reset()
  pendingSignals = nil
  stillSince = {}
  seenAt = {}
  lastTeleport = {}
  cuts = {}
  director.accum, director.clock = 0, 0
  director.rosterArchetype = {}
  director.rosterEntry = {}
  director.liveryApplied = {}
  director.personas = {}
  director.busStops = {}
  director.busStopCount = 0
  director.busDwell = {}
  director.busStopCooldowns = {}
  director.deliveryPoints = {}
  director.deliveryPointCount = 0
  director.courierDwell = {}
  director.deliveryCooldowns = {}
  director.recentSpawnIdx = 0
  for i = 1, #director.recentSpawns do director.recentSpawns[i].at = -1e9 end
  M.restoreChoice()
  stats = { applies = 0, lastMs = 0, nodes = 0, edges = 0 }
  prep, waited = nil, 0
end

return M
