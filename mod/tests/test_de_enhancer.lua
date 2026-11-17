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
T.check(mFacade:getField('dynamicCubemap', 0) == 'true', 'bne_bld_facade gets dynamicCubemap=true')
T.check(mFacade:getField('clearCoatFactor', 0) == '0.95', 'bne_bld_facade gets clearCoatFactor=0.95')
T.check(mShop:getField('metallicFactor', 0) == '0.75', 'bne_bld_shop gets metallicFactor=0.75')
T.check(mShop:getField('dynamicCubemap', 0) == 'true', 'bne_bld_shop gets dynamicCubemap=true')
T.check(mMetal:getField('roughnessFactor', 0) == '1', 'bne_bld_metalwall gets roughnessFactor=1')
T.check(mMetal:getField('metallicFactor', 0) == '0.75', 'bne_bld_metalwall gets metallicFactor=0.75')

-- 8c. Releasing last DE tile restores original material fields
deEnhancer.release('0:10_0')
deEnhancer.sweep()
T.check(deEnhancer.status().pbrActive == false, 'PBR deactivated when last DE tile released')
T.check(mFacade:getField('dynamicCubemap', 0) == '', 'bne_bld_facade dynamicCubemap restored to empty')
T.check(mFacade:getField('clearCoatFactor', 0) == '', 'bne_bld_facade clearCoatFactor restored to empty')
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

T.done('test_de_enhancer')
