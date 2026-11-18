-- Germany (DE) street-level immersion enhancer runtime materials & lifecycle.
-- Manages ref-counted dynamic Materials for per-tile street sign atlases and
-- emissive shopfront fascia atlases, integrating day/night switching via nightlights.lua.

local M = {}

M.FIELDS = {
  { 'diffuseColor', '1 1 1 1' },
  { 'specular', '0.35 0.35 0.35 1' },
  { 'specularPower', '18' },
  { 'pixelSpecular', '1' },
  { 'useAnisotropic', '1' },
}
M.FALLBACK_COLOR = '0.08 0.22 0.45 1'
M.DEFAULT_GLOW_COLOR = '1 0.94 0.84'
M.DEFAULT_GLOW_NITS = 35
M.DUSK_GLOW_COLOR = '1 0.82 0.56'
M.DUSK_SHOP_NITS = 22
M.DUSK_PYLON_NITS = 34
M.DUSK_WIN_NITS = 14
M.CHECK_S = 1.0

M.NO_SHADOW_WHATS = { destreets = true, deshops = true }
M.CULL_DIST = {
  low = { deshops = 85, destreets = 135, hedge = 0 },
  medium = { deshops = 95, destreets = 160, hedge = 160 },
  high = { deshops = 120, destreets = 185, hedge = 180 },
}

local mats = {}          -- matName -> { refs, texture, emissive, glowColor, nits }
local byTile = {}        -- tileKey -> { matName, ... }
local pendingDel = {}    -- matName -> true
local savedBldPbr = {}   -- matName -> { field -> origVal_or_false }
local savedDuskShop = nil
local duskMatState = {}  -- matName -> true when dusk emissive applied
local duskActive = false
local lastDuskCheck = -1e9
local settingsMod = nil
local nightlightsMod = nil
M.count = 0
M.pbrActive = false

M.BLD_PBR = {
  bne_bld_facade = {
    metallicFactor = '0',
    roughnessFactor = '0.92',
    normalMapStrength = '1.15',
  },
  bne_bld_shop = {
    metallicFactor = '0.75',
    roughnessFactor = '1',
    dynamicCubemap = 'true',
    clearCoatFactor = '0.45',
    clearCoatRoughnessFactor = '0.08',
  },
  bne_bld_office = {
    metallicFactor = '0.75',
    roughnessFactor = '1',
    dynamicCubemap = 'true',
    clearCoatFactor = '0.45',
    clearCoatRoughnessFactor = '0.08',
  },
  bne_bld_roof_flat = {
    normalMap = '/assets/materials/tileable/roofing/asphalt_roof/t_asphalt_roof_nm.normal.png',
    roughnessMap = '/assets/materials/tileable/roofing/asphalt_roof/t_asphalt_roof_r.data.png',
    ambientOcclusionMap = '/assets/materials/tileable/roofing/asphalt_roof/t_asphalt_roof_ao.data.png',
    roughnessFactor = '1',
  },
  bne_bld_panel = {
    normalMap = '/assets/materials/tileable/concrete/concrete_precast1/t_concrete_precast1_nm.normal.png',
    roughnessMap = '/assets/materials/tileable/concrete/concrete_precast1/t_concrete_precast1_r.data.png',
    ambientOcclusionMap = '/assets/materials/tileable/concrete/concrete_precast1/t_concrete_precast1_ao.data.png',
    roughnessFactor = '0.90',
  },
  bne_bld_metalwall = {
    normalMap = '/assets/materials/tileable/metal/m_metal_wall_corrugate/t_metal_wall_corrugated_nm.normal.png',
    roughnessMap = '/assets/materials/tileable/metal/m_metal_wall_corrugate/t_metal_wall_corrugated_r.data.png',
    ambientOcclusionMap = '/assets/materials/tileable/metal/m_metal_wall_corrugate/t_metal_wall_corrugated_ao.data.png',
    metallicMap = '/assets/materials/tileable/metal/m_metal_wall_corrugate/t_metal_wall_corrugated_m.data.png',
    roughnessFactor = '0.88',
    metallicFactor = '0.65',
  },
  bne_bld_lobby = {
    metallicFactor = '0.65',
    roughnessFactor = '1',
    dynamicCubemap = 'true',
    clearCoatFactor = '0.45',
    clearCoatRoughnessFactor = '0.08',
  },
}

local function hasFile(path)
  return type(path) == 'string' and FS ~= nil and FS:fileExists(path)
end

function M.isEnabled()
  if settingsMod == nil then
    local ok, s = pcall(require, 'beamngEarth/settings')
    settingsMod = (ok and type(s) == 'table') and s or false
  end
  return settingsMod ~= false and type(settingsMod.get) == 'function' and settingsMod.get('expDeStreetImmersion') == true
end

function M.detailLevel()
  if settingsMod == nil then
    local ok, s = pcall(require, 'beamngEarth/settings')
    settingsMod = (ok and type(s) == 'table') and s or false
  end
  local v = settingsMod ~= false and type(settingsMod.get) == 'function' and settingsMod.get('expDeDetailLevel') or nil
  if v == 'low' or v == 'medium' or v == 'high' then return v end
  return 'medium'
end

function M.setDetailLevel(level)
  local lvl = (level == 'low' or level == 'medium' or level == 'high') and level or 'medium'
  local ok, trees = pcall(require, 'beamngEarth/trees')
  if ok and type(trees) == 'table' and type(trees.setDeHedgeMaxM) == 'function' then
    trees.setDeHedgeMaxM(M.CULL_DIST[lvl].hedge)
  end
  return lvl
end

function M.cullDistance(what)
  local row = M.CULL_DIST[M.detailLevel()]
  return row and row[what] or nil
end

function M.applyStaticOpts(obj, what)
  if obj and M.NO_SHADOW_WHATS[what] and obj.setField then
    obj:setField('castShadows', 0, 'false')
  end
end

function M.isDusk(isNight)
  if not M.isEnabled() then return false end
  local env = rawget(_G, 'core_environment')
  if type(env) ~= 'table' or type(env.getTimeOfDay) ~= 'function' then return false end
  if isNight == nil and type(env.getLightState) == 'function' then
    local ok, st = pcall(env.getLightState)
    if ok and type(st) == 'table' then isNight = (st.isNight == true) end
  end
  if isNight == true then return false end
  local ok, tod = pcall(env.getTimeOfDay)
  if not ok or type(tod) ~= 'table' then return false end
  local t = tonumber(tod.time)
  if not t then return false end
  return (t >= 0.21 and t <= 0.28) or (t >= 0.72 and t <= 0.79)
end

local function applyBldPbr()
  if M.pbrActive then return end
  if not scenetree or type(scenetree.findObject) ~= 'function' then return end
  for matName, fields in pairs(M.BLD_PBR) do
    local m = scenetree.findObject(matName)
    if m then
      local orig = savedBldPbr[matName]
      if not orig then
        orig = {}
        savedBldPbr[matName] = orig
        for k in pairs(fields) do
          local v = m:getField(k, 0)
          orig[k] = (v ~= nil and v ~= '') and v or false
        end
      end
      for k, v in pairs(fields) do
        m:setField(k, 0, v)
      end
      pcall(m.flush, m)
      pcall(m.reload, m)
    end
  end
  M.pbrActive = true
end

local function restoreBldPbr()
  if not M.pbrActive and next(savedBldPbr) == nil then return end
  if not scenetree or type(scenetree.findObject) ~= 'function' then
    savedBldPbr = {}
    M.pbrActive = false
    return
  end
  for matName, orig in pairs(savedBldPbr) do
    local m = scenetree.findObject(matName)
    if m then
      for k, v in pairs(orig) do
        m:setField(k, 0, v == false and '' or v)
      end
      pcall(m.flush, m)
      pcall(m.reload, m)
    end
  end
  savedBldPbr = {}
  M.pbrActive = false
end

local function restoreDuskGlow(isNight)
  if not duskActive and not savedDuskShop and next(duskMatState) == nil then return end
  if scenetree and type(scenetree.findObject) == 'function' then
    if savedDuskShop then
      local m = scenetree.findObject('bne_bld_shop')
      if m then
        for k, v in pairs(savedDuskShop) do
          m:setField(k, 0, v == false and '' or v)
        end
        pcall(m.flush, m)
        pcall(m.reload, m)
      end
    end
    if not isNight then
      for name in pairs(duskMatState) do
        local m = scenetree.findObject(name)
        if m then
          m:setField('emissiveFactor', 0, '0 0 0')
          m:setField('emissiveIntensityNits', 0, '-1')
          pcall(m.flush, m)
          pcall(m.reload, m)
        end
      end
    end
  end
  savedDuskShop = nil
  duskMatState = {}
  duskActive = false
end

function M.syncDuskGlow(isNight, force)
  local now = (os and type(os.clockhp) == 'function') and os.clockhp() or 0
  if not force and (now - lastDuskCheck) < M.CHECK_S then return duskActive end
  lastDuskCheck = now

  local active = M.isEnabled() and next(byTile) ~= nil and not isNight and M.isDusk(isNight)
  if not active then
    restoreDuskGlow(isNight)
    return false
  end
  if not scenetree or type(scenetree.findObject) ~= 'function' then return false end

  if not duskActive then
    local mShop = scenetree.findObject('bne_bld_shop')
    if mShop then
      savedDuskShop = {
        emissiveFactor = mShop:getField('emissiveFactor', 0) or false,
        emissiveIntensityNits = mShop:getField('emissiveIntensityNits', 0) or false,
      }
      if savedDuskShop.emissiveFactor == '' then savedDuskShop.emissiveFactor = false end
      if savedDuskShop.emissiveIntensityNits == '' then savedDuskShop.emissiveIntensityNits = false end
      mShop:setField('emissiveFactor', 0, M.DUSK_GLOW_COLOR)
      mShop:setField('emissiveIntensityNits', 0, tostring(M.DUSK_WIN_NITS))
      pcall(mShop.flush, mShop)
      pcall(mShop.reload, mShop)
    end
  end

  for name, entry in pairs(mats) do
    if entry.emissive and not duskMatState[name] then
      local m = scenetree.findObject(name)
      if m then
        local nits = name:sub(1, 10) == 'bne_de_fp_' and M.DUSK_PYLON_NITS or M.DUSK_SHOP_NITS
        m:setField('emissiveFactor', 0, M.DUSK_GLOW_COLOR)
        m:setField('emissiveIntensityNits', 0, tostring(nits))
        pcall(m.flush, m)
        pcall(m.reload, m)
        duskMatState[name] = true
      end
    end
  end

  duskActive = true
  return true
end

function M.syncBuildingMaterials()
  if M.isEnabled() and next(byTile) ~= nil then
    applyBldPbr()
  else
    restoreDuskGlow(false)
    if M.pbrActive or next(savedBldPbr) ~= nil then
      restoreBldPbr()
    end
  end
end

local function syncNightlights(name, def, active)
  if nightlightsMod == nil then
    local ok, nl = pcall(require, 'beamngEarth/nightlights')
    nightlightsMod = (ok and type(nl) == 'table') and nl or false
  end
  local nl = nightlightsMod
  if not nl then return end
  if active and def and def.emissive == true then
    if type(nl.addDynamic) == 'function' then
      nl.addDynamic(name, def.glowColor or M.DEFAULT_GLOW_COLOR, tonumber(def.nits) or M.DEFAULT_GLOW_NITS)
    end
  elseif type(nl.removeDynamic) == 'function' then
    nl.removeDynamic(name)
  end
end

local function makeMaterial(name, def)
  local tex = type(def) == 'table' and def.texture or nil
  local exists = hasFile(tex)
  if not exists then
    log('W', 'beamngEarth', 'deEnhancer texture missing: ' .. tostring(tex))
  end
  local m = scenetree.findObject(name)
  if m then
    if exists then
      m:setField('colorMap', 0, tex)
      m:setField('diffuseColor', 0, M.FIELDS[1][2])
      if def.emissive == true then
        m:setField('emissiveMap', 0, tex)
      end
      pcall(m.flush, m)
      pcall(m.reload, m)
    end
    syncNightlights(name, def, exists)
    return
  end

  m = createObject('Material')
  m:setField('mapTo', 0, name)
  for _, f in ipairs(M.FIELDS) do m:setField(f[1], 0, f[2]) end
  if exists then
    m:setField('colorMap', 0, tex)
    if def.emissive == true then
      m:setField('emissiveMap', 0, tex)
      m:setField('emissiveFactor', 0, '0 0 0')
      m:setField('emissiveIntensityNits', 0, '-1')
    end
  else
    m:setField('diffuseColor', 0, M.FALLBACK_COLOR)
  end
  m.canSave = false
  m:registerObject(name)
  M.count = M.count + 1
  syncNightlights(name, def, exists)
end

-- Retain materials referenced by tileKey's deFaces table ({ matName -> { texture, emissive, nits, glowColor } }).
-- Returns count of newly registered or updated materials.
function M.retain(tileKey, deFaces)
  if type(tileKey) ~= 'string' then return 0 end
  if byTile[tileKey] then M.release(tileKey) end
  if type(deFaces) ~= 'table' then return 0 end

  local list = {}
  local changed = 0
  for name, def in pairs(deFaces) do
    if type(name) == 'string' and type(def) == 'table' and type(def.texture) == 'string' then
      list[#list + 1] = name
      pendingDel[name] = nil
      local entry = mats[name]
      if not entry then
        mats[name] = {
          refs = 1,
          texture = def.texture,
          emissive = def.emissive == true,
          glowColor = def.glowColor or M.DEFAULT_GLOW_COLOR,
          nits = tonumber(def.nits) or M.DEFAULT_GLOW_NITS,
        }
        makeMaterial(name, def)
        changed = changed + 1
      else
        entry.refs = entry.refs + 1
        if entry.texture ~= def.texture or entry.emissive ~= (def.emissive == true) then
          entry.texture = def.texture
          entry.emissive = def.emissive == true
          entry.glowColor = def.glowColor or M.DEFAULT_GLOW_COLOR
          entry.nits = tonumber(def.nits) or M.DEFAULT_GLOW_NITS
          makeMaterial(name, def)
          changed = changed + 1
        end
      end
    end
  end
  if #list > 0 then byTile[tileKey] = list end
  M.syncBuildingMaterials()
  return changed
end

-- Decrement material refcounts when a tile is dropped. Materials with 0 refs wait for sweep() after TSStatic deletion.
function M.release(tileKey)
  local list = byTile[tileKey]
  if not list then return 0 end
  byTile[tileKey] = nil
  local queued = 0
  for _, name in ipairs(list) do
    local entry = mats[name]
    if entry then
      entry.refs = entry.refs - 1
      if entry.refs <= 0 then
        entry.refs = 0
        pendingDel[name] = true
        queued = queued + 1
      end
    end
  end
  M.syncBuildingMaterials()
  return queued
end

-- Delete materials whose tiles & TSStatic objects are gone.
function M.sweep()
  if next(pendingDel) == nil then return 0 end
  local deleted = 0
  local done = {}
  for name in pairs(pendingDel) do done[#done + 1] = name end
  for _, name in ipairs(done) do
    pendingDel[name] = nil
    local entry = mats[name]
    if entry and entry.refs <= 0 then
      mats[name] = nil
      syncNightlights(name, nil, false)
      local m = scenetree.findObject(name)
      if m then m:delete() end
      M.count = math.max(0, M.count - 1)
      deleted = deleted + 1
    end
  end
  return deleted
end

-- Clear all tracked runtime materials (level unload / extension reset).
function M.clearAll()
  restoreDuskGlow(false)
  for name in pairs(mats) do
    syncNightlights(name, nil, false)
    local m = scenetree.findObject(name)
    if m then m:delete() end
  end
  mats, byTile, pendingDel, M.count = {}, {}, {}, 0
  lastDuskCheck = -1e9
  restoreBldPbr()
end

function M.status()
  local active = 0
  for _ in pairs(mats) do active = active + 1 end
  return { count = M.count, active = active, pbrActive = M.pbrActive, duskActive = duskActive }
end

return M
