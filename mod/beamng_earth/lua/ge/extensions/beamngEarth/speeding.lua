-- Speeding traffic (the user, 2026-11-09: "add speeding as a feature where its common for real traffic to do so like
-- the usa"). The game's traffic drives at the speed limit exactly (ai speed mode "legal": the road's limit is the
-- cap). Here each standard traffic car gets its own habit, drawn once from its country's profile (PROFILES, by the
-- road rules' country: navgraph's graph.rules.country): how far over the limit it drives on fast roads and on town
-- streets; while it just drives (role standard, no action) its cap is its road's limit times that (ai speed mode
-- "limit", the limit the game's road tracking already follows for it). The police's own speeding check (traffic
-- vehicle.lua checkOffenses: 1.2x the limit, at least 60 km/h) stays out of reach (MAX_OVER), so speeders are not
-- chased; the speed limits the game shows and checks the player against are untouched.
local M = {}

M.ON = true
M.INTERVAL_S = 0.5      -- every car's cap checked this often ...
M.RESEND_S = 8.0        -- ... sent again this often even unchanged (a respawn or reset puts "legal" back)
M.MIN_CHANGE = 0.4      -- m/s: a cap closer than this to the last one sent is not sent
M.FAST_MS = 17.9        -- m/s (40 mph): a limit from this up is a fast road (the fast-road habit), under it a street
M.MAX_OVER = 0.18       -- over the limit at most (the police check is 1.2x)
M.MIN_OVER = -0.06      -- under it at most (the slow few)

-- [country or region] = { share of drivers who speed, mean over the limit on fast roads (share of it), its spread,
-- the share of that on town streets }. From traffic surveys: about 70 % of US drivers over the posted limit on
-- interstates, typically by 5-10 mph (65 -> 72); Canada similar; the UK and Western Europe a few km/h over with
-- cameras; Germany and the Netherlands strict (camera-dense); Japan's expressways commonly 10-20 km/h over 80-100;
-- Australia strict (low tolerance).
M.PROFILES = {
  US = { 0.75, 0.10, 0.05, 0.5 }, CA = { 0.70, 0.09, 0.05, 0.5 }, MX = { 0.65, 0.08, 0.06, 0.5 },
  GB = { 0.55, 0.05, 0.04, 0.6 }, IE = { 0.55, 0.05, 0.04, 0.6 },
  DE = { 0.40, 0.04, 0.04, 0.5 }, NL = { 0.40, 0.03, 0.03, 0.5 }, AT = { 0.45, 0.04, 0.04, 0.5 },
  CH = { 0.30, 0.03, 0.03, 0.5 }, FR = { 0.55, 0.06, 0.05, 0.6 }, IT = { 0.65, 0.08, 0.05, 0.6 },
  ES = { 0.55, 0.06, 0.05, 0.6 }, PT = { 0.60, 0.07, 0.05, 0.6 },
  JP = { 0.75, 0.12, 0.05, 0.4 }, KR = { 0.65, 0.08, 0.05, 0.5 },
  AU = { 0.35, 0.03, 0.03, 0.5 }, NZ = { 0.40, 0.04, 0.03, 0.5 },
  default = { 0.55, 0.06, 0.05, 0.5 },
}

function M.profile(cc)
  return M.PROFILES[type(cc) == 'string' and string.upper(cc) or ''] or M.PROFILES.default
end

-- A car's habit (over the limit on fast roads, on streets) from its profile and two uniform draws u1, u2 in [0, 1)
-- (u2 for the spread: a normal by Box-Muller with a third, u3). Pure.
function M.habit(p, u1, u2, u3)
  if u1 >= p[1] then                    -- (one who keeps to the limit, or a little under)
    local under = -0.03 * u2
    return under, under
  end
  local z = math.sqrt(-2 * math.log(math.max(u2, 1e-9))) * math.cos(2 * math.pi * u3)
  local over = math.max(M.MIN_OVER, math.min(M.MAX_OVER, p[2] + p[3] * z))
  return over, over * p[4]
end

-- The cap (m/s) for a limit (m/s) and a habit.
function M.cap(limit, fast, street)
  return limit * (1 + (limit >= M.FAST_MS and fast or street))
end

-- Persona-driven speed cap (m/s) honoring truck/bus highway limits, courier pace, commuter limits, and Autobahn speeders.
-- Pure given limit (m/s), persona table (from navgraph.assignVehiclePersona), and optional roadProfile ({ highway, unlimited, rough }).
function M.personaCap(limit, persona, roadProfile)
  if type(persona) ~= 'table' or not limit then return nil end
  local kind = persona.persona
  local isHighway = (roadProfile and roadProfile.highway == true) or limit >= M.FAST_MS
  local isUnlimited = roadProfile and roadProfile.unlimited == true or false
  local isRough = roadProfile and roadProfile.rough == true or false
  local cap
  if kind == 'truck' or kind == 'bus' then
    local cruise = tonumber(persona.highwayCruiseMs) or (86 / 3.6)
    if isHighway or isUnlimited then
      cap = isUnlimited and cruise or math.min(limit, cruise)
    else
      cap = math.max(4.5, limit + (tonumber(persona.urbanDeltaKph) or -2) / 3.6)
    end
  elseif kind == 'courier' then
    local cruise = tonumber(persona.highwayCruiseMs) or (102 / 3.6)
    if isHighway or isUnlimited then
      cap = isUnlimited and cruise or math.min(limit * 1.08, cruise)
    else
      cap = math.max(4.5, limit + (tonumber(persona.urbanDeltaKph) or 2) / 3.6)
    end
  elseif kind == 'speeder' then
    if isUnlimited then
      cap = tonumber(persona.highwayCruiseMs) or (185 / 3.6)
    elseif isHighway then
      cap = limit + (tonumber(persona.highwayDeltaKph) or 20) / 3.6
    else
      cap = math.min(limit * 1.18, math.max(4.5, limit + (tonumber(persona.urbanDeltaKph) or 6) / 3.6))
    end
  else
    -- commuter (or unknown persona)
    if isUnlimited then
      cap = tonumber(persona.highwayCruiseMs) or (130 / 3.6)
    else
      cap = math.max(4.5, limit + (tonumber(persona.urbanDeltaKph) or 0) / 3.6)
    end
  end
  if isRough then
    cap = math.min(cap, limit)
  end
  return cap
end

-- A road OpenStreetMap tags smoothness=bad or worse (navgraph's edge flag "rough", server navgraph.ROUGH_SMOOTHNESS:
-- passability, not a speed limit) is not sped on: a habit over the limit keeps to the limit there (PR #1122).
local function roadProfileOf(obj)
  local ng = package.loaded['beamngEarth/navgraph']
  if not (ng and ng.speedProfileAt and obj and obj.getPosition) then return nil end
  local p = obj:getPosition()
  local ok, r = pcall(ng.speedProfileAt, p.x, p.y, p.z)
  return ok and type(r) == 'table' and r or nil
end
local function rough(obj)
  local r = roadProfileOf(obj)
  return r ~= nil and r.rough == true or false
end
M._rough = rough        -- (tests)

local cars = {}         -- id -> { fast, street, sent, at, country }
local timer, clock = 0, 0

local function release(id, c)
  local obj = getObjectByID(id)
  if obj and c.sent then obj:queueLuaCommand('ai.setSpeedMode("legal")') end
  cars[id] = nil
end

-- Each frame (core, after navgraph.update): graph (navgraph's current graph: its rules' country).
function M.update(dt, graph)
  clock = clock + (dt or 0)
  timer = timer - (dt or 0)
  if timer > 0 then return end
  timer = M.INTERVAL_S
  local gt = rawget(_G, 'gameplay_traffic')
  if not (gt and gt.getTrafficData) then return end
  local data = gt.getTrafficData() or {}
  if not M.ON then
    for id, c in pairs(cars) do release(id, c) end
    return
  end
  local cc = graph and graph.rules and graph.rules.country or nil
  local player = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or -1
  for id, c in pairs(cars) do
    if not data[id] then cars[id] = nil end        -- (gone)
  end
  local ng = package.loaded['beamngEarth/navgraph']
  for id, v in pairs(data) do
    local role = v.role
    local busDwelling = ng and ng.isBusDwelling and ng.isBusDwelling(id) == true or false
    local free = v.isAi and id ~= player and not busDwelling and role and role.name == 'standard' and role.state == 'none'
      and role.actionName == 'none' and v.state == 'active'
    local c = cars[id]
    if busDwelling then
      -- Do not overwrite the bus stop smooth-stop command while dwelling; resume cap updates once released.
      if c then c.sent = nil end
    elseif not free then
      if c then release(id, c) end
    else
      if not c or c.country ~= cc then
        local fast, street = M.habit(M.profile(cc), math.random(), math.random(), math.random())
        c = { fast = fast, street = street, country = cc, sent = nil, at = -1e9 }
        cars[id] = c
      end
      local limit = v.tracking and tonumber(v.tracking.speedLimit)
      if limit and limit > 4.2 then
        local obj = getObjectByID(id)
        local rp = roadProfileOf(obj)
        local persona = ng and ng.getVehiclePersona and ng.getVehiclePersona(id) or nil
        local cap
        if persona then
          cap = M.personaCap(limit, persona, rp)
        else
          cap = M.cap(limit, c.fast, c.street)
          if cap > limit and rp and rp.rough == true then cap = limit end     -- (a rough road: no speeding there)
        end
        if cap and (not c.sent or math.abs(cap - c.sent) >= M.MIN_CHANGE or clock - c.at >= M.RESEND_S) then
          if obj then
            obj:queueLuaCommand(string.format('ai.setSpeedMode("limit") ai.setSpeed(%.2f)', cap))
            c.sent, c.at = cap, clock
          end
        end
      end
    end
  end
end

function M.reset()
  for id, c in pairs(cars) do release(id, c) end
  cars = {}
end

function M._cars() return cars end        -- (tests)

return M
