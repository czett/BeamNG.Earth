-- luajit mod/tests/test_hudapps.lua  (our HUD as BeamNG UI apps: mounting, payload, throttled sends)
local T = dofile((arg[0]:match('^(.*)[/\\]') or '.') .. '/testlib.lua')
local H = require('beamngEarth/hudapps')
local sent = {}
guihooks = { trigger = function(name, p) sent[#sent + 1] = { name = name, p = p } end }
H._reset()
local calls = 0
local function get() calls = calls + 1; return { status = 'Elm St | 71 fps', credits = 'Imagery: x', banner = { text = '', level = 'ok', visible = false } } end
T.check(not H.update(1, get) and calls == 0, 'no app on screen: nothing computed or sent')
T.check(H.setMounted('status', true) and H.mounted('status') and H.any(), 'the status app mounted')
T.check(H.setMounted('transport', true) and H.mounted('transport'), 'the transport app mounted')
H.setMounted('transport', false)
T.check(H.setMounted('nonsense', true) == false, 'an unknown app is refused')
T.check(H.update(1, get) and #sent == 1 and sent[1].name == 'BeamNGEarthHud' and sent[1].p.status == 'Elm St | 71 fps', 'sent once mounted')
T.check(sent[1].p.banner == '' and sent[1].p.hidden == false, 'no banner while all is well')
T.check(not H.update(1.1, get), 'throttled within SEND_S')
T.check(not H.update(2, get) and #sent == 1, 'unchanged: not sent again')
T.check(H.update(8, get) and #sent == 2, 'unchanged but stale: sent again (an app opened since)')
H.setMounted('banner', true)
T.check(H.update(8.5, get) and #sent == 3, 'a new app: the current state at once')
local p = H.payload({ banner = { text = 'World server not running', level = 'error', visible = true }, transport = { state = 'active', mode = 'taxi', stopIndex = 1, stopCount = 2 } })
T.check(p.banner == 'World server not running' and p.bannerLevel == 'error' and p.status == '', 'the banner when there is one')
T.check(p.transport and p.transport.mode == 'taxi' and p.transport.stopIndex == 1, 'transport payload forwarded')
local busStep = 0
H.setMounted('transport', true)
local busGet = function()
  busStep = busStep + 1
  return {
    status = '', credits = '', banner = { text = '', level = 'info', visible = false },
    transport = { state = 'active', mode = 'bus', stopIndex = 1, stopCount = 4, paxCount = busStep == 1 and 8 or 14, paxCapacity = 40, scheduleText = 'On Time', nextStopName = 'Central' },
  }
end
T.check(H.update(10, busGet), 'bus hud update sent')
T.check(H.update(10.3, busGet), 'bus hud re-emits when paxCount changes')
local earnStep = 0
local sumGet = function()
  earnStep = earnStep + 1
  return {
    status = '', credits = '', banner = { text = '', level = 'info', visible = false },
    transport = {
      state = 'summary', mode = 'parcel', stopsCompleted = 4, stopCount = 4,
      score = 94, smoothnessPct = 96, collisions = 0, drivenM = 2800, elapsedS = 190,
      totalEarned = earnStep == 1 and 24.50 or 31.00,
      driverRank = earnStep == 1 and 'Rookie Driver' or 'Local Courier',
    },
  }
end
T.check(H.update(11, sumGet) and sent[#sent].p.transport.totalEarned == 24.50 and sent[#sent].p.transport.driverRank == 'Rookie Driver',
  'summary hud forwards totalEarned and driverRank')
T.check(H.update(11.3, sumGet) and sent[#sent].p.transport.totalEarned == 31.00 and sent[#sent].p.transport.driverRank == 'Local Courier',
  'summary hud re-emits when totalEarned/driverRank changes')
H.setMounted('transport', false)
H.setMounted('status', false); H.setMounted('banner', false)
T.check(not H.any() and not H.mounted('status'), 'all apps gone')
-- the minimap's label: the town, else the street, else the stock fallback; a level's own zone still first
T.check(H.minimapName({ street = 'Thames Street', place = 'Baltimore' }) == 'Baltimore', 'minimap label: the town')
T.check(H.minimapName({ street = 'Thames Street', place = '' }) == 'Thames Street', 'minimap label: the street until the town is known')
T.check(H.minimapName({ street = '', place = '' }) == nil and H.minimapName(nil) == nil, 'minimap label: nothing known, stock fallback')
T.check(H.coordsLabel(39.2834, -76.5934) == '39.28340° N, 76.59340° W', 'minimap label: the Earth coordinates')
T.check(H.coordsLabel(-33.8688, 151.2093) == '33.86880° S, 151.20930° E', 'south and east')
T.check(H.coordsLabel(nil, 1) == nil and H.coordsLabel(0 / 0, 1) == nil, 'no coordinates: none')
local levelZone = nil
gameplay_city = { getHighestPrioZone = function() return levelZone end }
local orig = gameplay_city.getHighestPrioZone
local name = 'Baltimore'
T.check(H.hookCityZone(function() return name end), 'city zones hooked')
T.check(gameplay_city.getHighestPrioZone({}).name == 'Baltimore', 'no zone: our town')
levelZone = { name = 'Firwood' }
T.check(gameplay_city.getHighestPrioZone({}).name == 'Firwood', "a level's own zone first")
levelZone, name = nil, nil
T.check(gameplay_city.getHighestPrioZone({}) == nil, 'nothing known: no zone (stock fallback)')
local wrapped = gameplay_city.getHighestPrioZone
T.check(H.hookCityZone(function() return name end) and gameplay_city.getHighestPrioZone == wrapped, 'hooked once')
H.unhookCityZone()
T.check(gameplay_city.getHighestPrioZone == orig, 'unhooked: the original back')
gameplay_city = nil
T.check(not H.hookCityZone(function() return 'x' end), 'no city extension: nothing hooked')
-- the minimap compass: true north for drawCompass only
do
  local nx, ny = H.mapNorth(2, 0, 0, -2, 1, 0)
  T.check(nx == 2 and ny == 0, 'mapNorth: the linear part of the transform')
  local function xf() return 2, 0, 0, -2, 10, 20 end
  ui_apps_minimap_utils = { getWorldToMapTransform = xf }
  local plainOrig = ui_apps_minimap_utils.getWorldToMapTransform
  T.check(H.hookMinimapNorth(function() return 1, 0 end), 'compass hooked')
  local get = ui_apps_minimap_utils.getWorldToMapTransform
  local function drawCompass() local _, a, _, b = get(); return a, b end
  local function drawRoads() return select(2, get()) end
  local a, b = drawCompass()
  T.check(a == 2 and b == 0, 'the compass gets true north through the transform')
  T.check(drawRoads() == 0, 'other callers get the plain transform')
  H.unhookMinimapNorth()
  T.check(ui_apps_minimap_utils.getWorldToMapTransform == plainOrig, 'unhooked: the original back')
  ui_apps_minimap_utils = nil
end
T.done('test_hudapps')
