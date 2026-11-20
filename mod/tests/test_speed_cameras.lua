-- luajit mod/tests/test_speed_cameras.lua
-- Verifies DE speed cameras (tolerance thresholds, graduated fines, cooldown, red screen-edge flash,
-- transportModes career deduction & -12 score penalty, VIP/emergency exemptions), police patrols,
-- statusbar speed-limit display, and strict off-switch parity.

local dir = (arg[0]:match('^(.*)[/\\]') or '.')
local T = dofile(dir .. '/testlib.lua')
local S = dofile(dir .. '/stubs.lua')

local settings = require('beamngEarth/settings')
local speedCameras = require('beamngEarth/speedCameras')
local statusbar = require('beamngEarth/statusbar')
local navgraph = require('beamngEarth/navgraph')
local trees = require('beamngEarth/trees')

-- 1. Pure tolerance & graduated fine evaluation
T.check(speedCameras.evaluate(56, 50, true) == nil, 'urban: 56 km/h at 50 limit is within +6 tolerance')
T.check(speedCameras.evaluate(56.5, 50, true) == 35, 'urban: 56.5 km/h at 50 limit triggers $35 fine')
T.check(speedCameras.evaluate(108, 100, false) == nil, 'rural: 108 km/h at 100 limit is within +8 tolerance')
T.check(speedCameras.evaluate(109, 100, false) == 35, 'rural: 109 km/h at 100 limit triggers $35 fine')
T.check(speedCameras.evaluate(70, 50, true) == 75, '+20 km/h over -> $75 fine')
T.check(speedCameras.evaluate(85, 50, true) == 140, '+35 km/h over -> $140 fine')
T.check(speedCameras.evaluate(105, 50, true) == 200, '+55 km/h over -> $200 fine')
T.check(speedCameras.evaluate(120, 50, true) == 250, '+70 km/h over -> $250 max fine')
T.check(speedCameras.evaluate(240, 0, false) == nil, 'unlimited Autobahn (limit 0) never flashes')

-- 2. Verify 3D radar prop registration in trees.lua
T.check(trees.CATALOG.de_radar ~= nil and trees.GROUP_MAX_M.de_radar == 450 and trees.ONE_SPELLING.de_radar == true,
  'de_radar prop registered in trees.lua catalog')
T.check(trees.isBarrier('de_radar') == true, 'de_radar protected from thinning via isBarrier')

-- 3. Mock transportModes + ui_message + ImGui draw list
local balance = 1000
local jobScore = 100
local jobActive = true
local exemptRun = false
transportModes = {
  deductFine = function(amount) balance = balance - amount end,
  hasActiveJob = function() return jobActive end,
  applyScorePenalty = function(pts) jobScore = jobScore - pts end,
  isEmergencyRun = function() return exemptRun end,
}

local notices = {}
ui_message = function(msg, _, ch)
  notices[#notices + 1] = { msg = msg, ch = ch }
end

local rectCalls = 0
local fakeIm = {
  GetMainViewport = function() return { Pos = { x = 0, y = 0 }, Size = { x = 1920, y = 1080 } } end,
  GetBackgroundDrawList1 = function() return {} end,
  ImVec2 = function(x, y) return { x = x, y = y } end,
  ImVec4 = function(r, g, b, a) return { r, g, b, a } end,
  GetColorU322 = function(c) return c end,
  ImDrawList_AddRectFilled = function() rectCalls = rectCalls + 1 end,
}

local gateRow = { 'de_cam_1', 0, 0, 100, 0, 4.0, 50, 0, -5.5, 102.1, 1, 0 }
local function drive(x, vx, dt, opts)
  return speedCameras.update({
    vehicleId = 1, x = x, y = 0, z = 101, vx = vx, vy = 0, vz = 0, speed = math.abs(vx),
  }, dt or 0.1, dt or 0.1, opts)
end

-- 4. Off-switch parity: expDeStreetImmersion = false must never flash, fine, or draw overlay
speedCameras.clear()
settings.set('expDeStreetImmersion', false)
speedCameras.onRows('g:t1', { gateRow })
drive(-2, 80 / 3.6)
drive(2, 80 / 3.6)
T.check(balance == 1000 and jobScore == 100 and #notices == 0, 'off-switch parity: no fine or alert when disabled')
T.check(speedCameras.drawFlash(fakeIm) == false and rectCalls == 0, 'off-switch parity: no red flash drawn when disabled')

-- 5. Enabled: crossing above tolerance flashes red overlay, deducts fine, applies -12 pts, respects cooldown
settings.set('expDeStreetImmersion', true)
speedCameras.resetMotion()
drive(-2, 80 / 3.6)
local hit = drive(2, 80 / 3.6)
T.check(hit == true, '80 km/h in 50 zone triggers speed camera')
T.check(balance == 860, 'graduated fine $140 (+30 km/h) deducted from transportModes balance (got ' .. balance .. ')')
T.check(jobScore == 88, 'active transport job penalized -12 pts (got ' .. jobScore .. ')')
T.check(#notices == 1 and notices[1].ch == 'beamngEarthSpeedCamera', 'speed camera alert sent')
T.check(speedCameras.flashAlpha() > 0.9, 'red camera flash overlay active immediately after trigger')
T.check(speedCameras.drawFlash(fakeIm) == true and rectCalls == 5, 'drawFlash renders 1 wash + 4 screen-edge red borders')

-- Immediate second pass within 15 s cooldown must NOT double-fine
speedCameras.resetMotion()
drive(-2, 80 / 3.6)
drive(2, 80 / 3.6)
T.check(balance == 860 and #notices == 1, 'per-camera cooldown prevents double-fining on same pass')

-- Advance past flash duration -> flash fades to 0 and stops drawing
drive(20, 10, 0.6)
rectCalls = 0
T.check(speedCameras.flashAlpha() == 0 and speedCameras.drawFlash(fakeIm) == false and rectCalls == 0,
  'red flash expires cleanly and draws nothing when idle')

-- 6. VIP / emergency exemption
exemptRun = true
speedCameras.clear()
speedCameras.onRows('g:t1', { gateRow })
drive(-2, 95 / 3.6)
drive(2, 95 / 3.6)
T.check(balance == 860 and jobScore == 88, 'VIP/emergency transport run is exempt from camera fines')
exemptRun = false

-- 7. Police patrols: EU traffic pool inclusion when enabled vs Police = 0 when disabled
do
  local get = function(k) return k == 'trafficSmartSelections' end
  settings.set('expDeStreetImmersion', false)
  local pOff = navgraph.regionalGroupParams('DE', get)
  T.check(pOff.filters['Config Type'].Police == 0, 'off-switch parity: Police = 0 when DE immersion disabled')
  settings.set('expDeStreetImmersion', true)
  local pOn = navgraph.regionalGroupParams('DE', get)
  T.check(pOn.filters['Config Type'].Police > 0, 'EU/DE traffic pool includes police patrols when enabled')
  local grp = { { model = 'etk800', config = 'base' } }
  navgraph.appendEuPolicePatrols(grp, 'DE')
  T.check(#grp == 2 and grp[2].config == 'polizei', 'appendEuPolicePatrols injects DE polizei config')
end

-- 8. Police patrol enforcement: speeding (> limit + 20 km/h) and direct collision trigger lightbar + citation
do
  local sentCmds = {}
  local patrolObj = {
    queueLuaCommand = function(_, cmd) sentCmds[#sentCmds + 1] = cmd end,
  }
  local trafficData = {
    [99] = {
      state = 'active',
      role = { name = 'police' },
      model = 'etk800',
      config = 'polizei',
      pos = { x = 10, y = 4, z = 101 },
      obj = patrolObj,
    },
  }
  speedCameras.clear()
  local prevBal = balance
  drive(0, 80 / 3.6, 0.1, { limitKph = 50, trafficData = trafficData })
  T.check(#sentCmds >= 1 and sentCmds[1]:find('set_lightbar_signal(2)', 1, true) ~= nil,
    'speeding > limit+20 beside police patrol activates lightbar/siren')
  T.check(balance < prevBal, 'police patrol speeding citation deducts fine')

  -- Direct collision beside patrol
  sentCmds = {}
  speedCameras.clear()
  prevBal = balance
  trafficData[99].pos = { x = 3, y = 1, z = 101 }
  trafficData[99].collidedWithPlayer = true
  drive(0, 30 / 3.6, 0.1, { limitKph = 50, trafficData = trafficData })
  T.check(#sentCmds >= 1 and sentCmds[1]:find('set_lightbar_signal(2)', 1, true) ~= nil,
    'direct collision beside patrol activates lightbar/siren')
  T.check(balance == prevBal - 150, 'police patrol collision deducts $150 citation')
end

-- 9. Statusbar speed-limit formatting & display
T.check(statusbar.formatSpeedLimit(50) == '50 km/h', 'statusbar formats numeric km/h limit')
T.check(statusbar.formatSpeedLimit(0) == 'Autobahn ∞', 'statusbar formats unlimited Autobahn limit')
T.check(statusbar.formatSpeedLimit({ ms = 30 / 3.6, unit = 'kmh' }) == '30 km/h', 'statusbar formats api.speedLimit() table')
T.check(statusbar.compose({ street = 'Hellweg', place = 'Dortmund', country = 'Germany' }, nil, nil, '50 km/h')
  == 'Hellweg  |  Dortmund, Germany  |  50 km/h', 'statusbar composes street, place, and polished speed limit')

-- Cleanup globals
transportModes = nil
settings.set('expDeStreetImmersion', false)
speedCameras.clear()
T.done('test_speed_cameras')
