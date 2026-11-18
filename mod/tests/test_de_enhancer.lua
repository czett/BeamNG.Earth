-- luajit mod/tests/test_de_enhancer.lua
-- Verifies ref-counted runtime Materials, missing-texture fallback, nightlights day/night integration,
-- and roads.lua CONTENT_WHATS wiring for the Germany (DE) street enhancer.

local dir = (arg[0]:match('^(.*)[/\\]') or '.')
local T = dofile(dir .. '/testlib.lua')
dofile(dir .. '/stubs.lua')

local clock = 10.0
os.clockhp = function() return clock end

local nightlights = require('beamngEarth/nightlights')
local deEnhancer = require('beamngEarth/deEnhancer')
local roads = require('beamngEarth/roads')

-- Reset state cleanly before tests.
deEnhancer.clearAll()
nightlights.reset()

local existing = {
  ['/temp/beamngEarth/s1/de_st_aaa111.dds'] = true,
  ['/temp/beamngEarth/s1/de_sh_bbb222.dds'] = true,
  ['/temp/beamngEarth/s2/de_sh_bbb222.dds'] = true,
}
FS = {
  fileExists = function(_, p) return existing[p] == true end,
}

-- 1. No-op when deFaces is nil
T.check(deEnhancer.retain('0:0_0', nil) == 0, 'nil deFaces is a safe no-op')
T.check(deEnhancer.status().count == 0, 'zero materials created')

-- 2. Register street (non-emissive) + shop (emissive) materials for tile 1
local defs1 = {
  bne_de_st_aaa111 = { texture = '/temp/beamngEarth/s1/de_st_aaa111.dds', emissive = false },
  bne_de_sh_bbb222 = { texture = '/temp/beamngEarth/s1/de_sh_bbb222.dds', emissive = true, nits = 35, glowColor = '1 0.94 0.84' },
}
T.check(deEnhancer.retain('0:0_0', defs1) == 2, 'retained 2 new materials')
T.check(deEnhancer.status().count == 2, 'deEnhancer tracks 2 materials')

local mSt = scenetree.findObject('bne_de_st_aaa111')
local mSh = scenetree.findObject('bne_de_sh_bbb222')
T.check(mSt ~= nil and mSt.fields.colorMap == '/temp/beamngEarth/s1/de_st_aaa111.dds', 'street material has colorMap')
T.check(mSt.fields.emissiveMap == nil, 'street sign has no emissiveMap')
T.check(mSh ~= nil and mSh.fields.emissiveMap == '/temp/beamngEarth/s1/de_sh_bbb222.dds', 'shop fascia has emissiveMap')
T.check(nightlights.DYNAMIC.bne_de_sh_bbb222 ~= nil, 'shop fascia registered in nightlights.DYNAMIC')

-- 3. Night vs day lighting switch via nightlights.update()
local fakeNight = true
core_environment = {
  getLightState = function() return { isNight = fakeNight } end,
  getTimeOfDay = function() return { time = 0.48 } end, -- ~23:30
}
nightlights.update()
T.check(mSh.fields.emissiveFactor == '1 0.94 0.84', 'shop glow active at night')
T.check(mSh.fields.emissiveIntensityNits == '35', 'shop glow calibrated to 35 nits')

fakeNight = false
clock = clock + nightlights.CHECK_S + 0.2
nightlights.update()
T.check(mSh.fields.emissiveFactor == '0 0 0', 'shop glow turns off by day')
T.check(mSh.fields.emissiveIntensityNits == '-1', 'shop nits disabled (-1) by day')

-- 4. Reference counting & delayed cleanup sweep
T.check(deEnhancer.retain('0:1_0', { bne_de_sh_bbb222 = defs1.bne_de_sh_bbb222 }) == 0, 'shared material reuses existing instance')
T.check(deEnhancer.release('0:0_0') == 1, 'releasing first tile queues unique street mat for delete')
T.check(deEnhancer.sweep() == 1, 'sweep deletes unreferenced street material')
T.check(scenetree.findObject('bne_de_st_aaa111') == nil, 'unreferenced street material removed from scenetree')
T.check(scenetree.findObject('bne_de_sh_bbb222') ~= nil, 'shared shop material kept while tile 0:1_0 retains it')
T.check(nightlights.DYNAMIC.bne_de_sh_bbb222 ~= nil, 'shared shop stays in nightlights while retained')

T.check(deEnhancer.release('0:1_0') == 1, 'releasing last tile queues shared shop material')
T.check(deEnhancer.sweep() == 1, 'sweep deletes shop material at refs=0')
T.check(scenetree.findObject('bne_de_sh_bbb222') == nil, 'shop material removed from scenetree')
T.check(nightlights.DYNAMIC.bne_de_sh_bbb222 == nil, 'shop material unregistered from nightlights')

-- 5. Missing texture uses clean fallback and does not register emissive nightglow
deEnhancer.retain('0:2_0', {
  bne_de_missing = { texture = '/temp/beamngEarth/s1/missing.dds', emissive = true, nits = 35 },
})
local mMiss = scenetree.findObject('bne_de_missing')
T.check(mMiss ~= nil and mMiss.fields.colorMap == nil and mMiss.fields.diffuseColor == deEnhancer.FALLBACK_COLOR,
  'missing texture gets safe fallback color')
T.check(nightlights.DYNAMIC.bne_de_missing == nil, 'missing texture skips emissive registration')

deEnhancer.clearAll()
T.check(scenetree.findObject('bne_de_missing') == nil and deEnhancer.status().count == 0, 'clearAll removes all tracked materials')

-- 6. Verify roads.CONTENT_WHATS exposes destreets and deshops
local seenWhats = {}
for _, w in ipairs(roads.CONTENT_WHATS) do seenWhats[w] = true end
T.check(seenWhats.destreets == true and seenWhats.deshops == true, 'roads.CONTENT_WHATS includes destreets and deshops')

-- 7. Verify de_hedge ONE_SPELLING and fr_hedge untouched parity
local trees = require('beamngEarth/trees')
T.check(trees.ONE_SPELLING.de_hedge == true, 'de_hedge uses ONE_SPELLING')
T.check(trees.ONE_SPELLING.fr_hedge == nil, 'fr_hedge does not force ONE_SPELLING')

-- 8. Runtime DE building PBR material enhancements (strictly when expDeStreetImmersion=true and DE tiles active)
local settings = require('beamngEarth/settings')
local function makeStockMat(name, fields)
  local m = createObject('Material')
  for k, v in pairs(fields or {}) do m:setField(k, 0, v) end
  m.canSave = false
  m:registerObject(name)
  return m
end

local mFacade = makeStockMat('bne_bld_facade', {})
local mShop = makeStockMat('bne_bld_shop', {})
local mMetal = makeStockMat('bne_bld_metalwall', { roughnessFactor = '0.85', metallicFactor = '0' })

-- 8a. Off-switch-no-change: expDeStreetImmersion=false leaves stock materials untouched even if retain() runs
settings.set('expDeStreetImmersion', false)
deEnhancer.retain('0:10_0', { bne_de_st_aaa111 = defs1.bne_de_st_aaa111 })
T.check(deEnhancer.status().pbrActive == false, 'PBR inactive when expDeStreetImmersion is false')
T.check(mFacade:getField('dynamicCubemap', 0) == nil, 'bne_bld_facade untouched when off')
T.check(mMetal:getField('roughnessFactor', 0) == '0.85', 'bne_bld_metalwall roughness untouched when off')
deEnhancer.clearAll()

-- 8b. Active DE mode: expDeStreetImmersion=true + active DE tile applies PBR tuning
settings.set('expDeStreetImmersion', true)
deEnhancer.retain('0:10_0', { bne_de_st_aaa111 = defs1.bne_de_st_aaa111 })
T.check(deEnhancer.status().pbrActive == true, 'PBR active when expDeStreetImmersion=true and DE tile active')
T.check(mFacade:getField('dynamicCubemap', 0) == nil, 'bne_bld_facade no longer sets dynamicCubemap')
T.check(mFacade:getField('clearCoatFactor', 0) == nil, 'bne_bld_facade no longer sets clearCoatFactor')
T.check(mFacade:getField('normalMapStrength', 0) == '1.15', 'bne_bld_facade gets normalMapStrength=1.15')
T.check(mFacade:getField('roughnessFactor', 0) == '0.92', 'bne_bld_facade gets roughnessFactor=0.92')
T.check(mShop:getField('metallicFactor', 0) == '0.75', 'bne_bld_shop gets metallicFactor=0.75')
T.check(mShop:getField('dynamicCubemap', 0) == 'true', 'bne_bld_shop gets dynamicCubemap=true')
T.check(mShop:getField('clearCoatFactor', 0) == '0.45', 'bne_bld_shop gets clearCoatFactor=0.45')
T.check(mMetal:getField('roughnessFactor', 0) == '0.88', 'bne_bld_metalwall gets roughnessFactor=0.88')
T.check(mMetal:getField('metallicFactor', 0) == '0.65', 'bne_bld_metalwall gets metallicFactor=0.65')

-- 8c. Releasing last DE tile restores original material fields
deEnhancer.release('0:10_0')
deEnhancer.sweep()
T.check(deEnhancer.status().pbrActive == false, 'PBR deactivated when last DE tile released')
T.check(mFacade:getField('normalMapStrength', 0) == '', 'bne_bld_facade normalMapStrength restored to empty')
T.check(mFacade:getField('roughnessFactor', 0) == '', 'bne_bld_facade roughnessFactor restored to empty')
T.check(mMetal:getField('roughnessFactor', 0) == '0.85', 'bne_bld_metalwall roughnessFactor restored to 0.85')
T.check(mMetal:getField('metallicFactor', 0) == '0', 'bne_bld_metalwall metallicFactor restored to 0')

-- 8d. Toggling expDeStreetImmersion off while tile is retained also restores original material fields
deEnhancer.retain('0:11_0', { bne_de_st_aaa111 = defs1.bne_de_st_aaa111 })
T.check(deEnhancer.status().pbrActive == true, 'PBR re-enabled for new DE tile')
settings.set('expDeStreetImmersion', false)
deEnhancer.syncBuildingMaterials()
T.check(deEnhancer.status().pbrActive == false, 'PBR deactivated when expDeStreetImmersion toggled off')
T.check(mMetal:getField('roughnessFactor', 0) == '0.85', 'bne_bld_metalwall restored on toggle off')
deEnhancer.clearAll()

-- 9. Performance guard: idle sweep() is a 0-op no-op and active PBR does not re-flush on additional tiles
T.check(deEnhancer.sweep() == 0, 'idle sweep returns 0')
settings.set('expDeStreetImmersion', true)
local flushCount = 0
local origFlush = mFacade.flush
mFacade.flush = function(self)
  flushCount = flushCount + 1
  if origFlush then return origFlush(self) end
end
deEnhancer.retain('0:20_0', { bne_de_st_aaa111 = defs1.bne_de_st_aaa111 })
T.check(flushCount == 1, 'first DE tile flushes bne_bld_facade once')
deEnhancer.retain('0:21_0', { bne_de_st_aaa111 = defs1.bne_de_st_aaa111 })
T.check(flushCount == 1, 'second DE tile does not redundantly re-flush bne_bld_facade')
mFacade.flush = origFlush
deEnhancer.clearAll()

-- 10. Static shadow opt-out, detail level culling, and dusk warmth
do
  local ts = createObject('TSStatic')
  deEnhancer.applyStaticOpts(ts, 'bld')
  T.check(ts:getField('castShadows', 0) == nil, 'bld keeps default castShadows')
  deEnhancer.applyStaticOpts(ts, 'destreets')
  T.check(ts:getField('castShadows', 0) == 'false', 'destreets disables castShadows')
  local ts2 = createObject('TSStatic')
  deEnhancer.applyStaticOpts(ts2, 'deshops')
  T.check(ts2:getField('castShadows', 0) == 'false', 'deshops disables castShadows')

  settings.set('expDeDetailLevel', 'low')
  deEnhancer.setDetailLevel('low')
  T.check(deEnhancer.detailLevel() == 'low' and deEnhancer.cullDistance('deshops') == 85 and trees.GROUP_MAX_M.de_hedge == 0,
    'low detail sets 85m deshops cull and 0m de_hedge')
  settings.set('expDeDetailLevel', 'medium')
  deEnhancer.setDetailLevel('medium')
  T.check(deEnhancer.detailLevel() == 'medium' and deEnhancer.cullDistance('destreets') == 160 and trees.GROUP_MAX_M.de_hedge == 160,
    'medium detail sets 160m destreets/de_hedge cull')

  -- Dusk warmth in [0.21..0.28] when expDeStreetImmersion=true and DE tiles active
  local fakeTod = 0.24
  fakeNight = false
  core_environment = {
    getLightState = function() return { isNight = fakeNight } end,
    getTimeOfDay = function() return { time = fakeTod } end,
  }
  settings.set('expDeStreetImmersion', false)
  T.check(deEnhancer.isDusk(false) == false, 'isDusk is false when expDeStreetImmersion=false')
  settings.set('expDeStreetImmersion', true)
  T.check(deEnhancer.isDusk(false) == true, 'isDusk is true at tod.time=0.24 when enabled')
  deEnhancer.retain('0:30_0', {
    bne_de_sh_bbb222 = defs1.bne_de_sh_bbb222,
    bne_de_fp_ccc333 = { texture = '/temp/beamngEarth/s1/de_st_aaa111.dds', emissive = true, nits = 48, glowColor = '1 0.88 0.66' },
  })
  clock = clock + 2.0
  T.check(deEnhancer.syncDuskGlow(false) == true and deEnhancer.status().duskActive == true, 'syncDuskGlow activates at dusk')
  local mDuskSh = scenetree.findObject('bne_de_sh_bbb222')
  local mDuskFp = scenetree.findObject('bne_de_fp_ccc333')
  T.check(mDuskSh.fields.emissiveFactor == deEnhancer.DUSK_GLOW_COLOR and mDuskSh.fields.emissiveIntensityNits == tostring(deEnhancer.DUSK_SHOP_NITS),
    'shop fascia gets warm dusk nits')
  T.check(mDuskFp.fields.emissiveIntensityNits == tostring(deEnhancer.DUSK_PYLON_NITS),
    'fuel pylon gets warm dusk pylon nits')
  T.check(mShop:getField('emissiveIntensityNits', 0) == tostring(deEnhancer.DUSK_WIN_NITS),
    'bne_bld_shop gets warm dusk window nits')

  -- Leaving dusk (or turning off) restores shop window & turns off dusk glow
  fakeTod = 0.48
  T.check(deEnhancer.isDusk(false) == false, 'tod.time=0.48 is outside dusk window')
  clock = clock + 2.0
  T.check(deEnhancer.syncDuskGlow(false) == false and deEnhancer.status().duskActive == false, 'syncDuskGlow deactivates outside dusk')
  T.check(mShop:getField('emissiveIntensityNits', 0) == '', 'bne_bld_shop emissive restored outside dusk')
  deEnhancer.clearAll()
  settings.set('expDeStreetImmersion', false)
end

T.done('test_de_enhancer')
