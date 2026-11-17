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

local mats = {}          -- matName -> { refs, texture, emissive, glowColor, nits }
local byTile = {}        -- tileKey -> { matName, ... }
local pendingDel = {}    -- matName -> true
local savedBldPbr = {}   -- matName -> { field -> origVal_or_false }
M.count = 0
M.pbrActive = false

M.BLD_PBR = {
  bne_bld_facade = {
    clearCoatMap = '/assets/materials/trim/plaster/t_highrise_plaster/t_highrise_plaster_m.data.png',
    clearCoatFactor = '0.95',
    clearCoatRoughnessFactor = '0.045',
    metallicFactor = '0.2',
    roughnessFactor = '1',
    normalMapStrength = '1',
    dynamicCubemap = 'true',
  },
  bne_bld_shop = {
    metallicFactor = '0.75',
    roughnessFactor = '1',
    dynamicCubemap = 'true',
  },
  bne_bld_office = {
    metallicFactor = '0.75',
    roughnessFactor = '1',
    dynamicCubemap = 'true',
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
    roughnessFactor = '1',
  },
  bne_bld_metalwall = {
    normalMap = '/assets/materials/tileable/metal/m_metal_wall_corrugate/t_metal_wall_corrugated_nm.normal.png',
    roughnessMap = '/assets/materials/tileable/metal/m_metal_wall_corrugate/t_metal_wall_corrugated_r.data.png',
    ambientOcclusionMap = '/assets/materials/tileable/metal/m_metal_wall_corrugate/t_metal_wall_corrugated_ao.data.png',
    metallicMap = '/assets/materials/tileable/metal/m_metal_wall_corrugate/t_metal_wall_corrugated_m.data.png',
    roughnessFactor = '1',
    metallicFactor = '0.75',
  },
  bne_bld_lobby = {
    metallicFactor = '0.65',
    roughnessFactor = '1',
    dynamicCubemap = 'true',
  },
}

local function hasFile(path)
  return type(path) == 'string' and FS ~= nil and FS:fileExists(path)
end

function M.isEnabled()
  local ok, s = pcall(require, 'beamngEarth/settings')
  return ok and type(s) == 'table' and type(s.get) == 'function' and s.get('expDeStreetImmersion') == true
end

local function applyBldPbr()
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
      pcall(function() m:flush() end)
      pcall(function() m:reload() end)
    end
  end
  M.pbrActive = true
end

local function restoreBldPbr()
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
      pcall(function() m:flush() end)
      pcall(function() m:reload() end)
    end
  end
  savedBldPbr = {}
  M.pbrActive = false
end

function M.syncBuildingMaterials()
  if M.isEnabled() and next(byTile) ~= nil then
    applyBldPbr()
  elseif M.pbrActive or next(savedBldPbr) ~= nil then
    restoreBldPbr()
  end
end

local function syncNightlights(name, def, active)
  local ok, nl = pcall(require, 'beamngEarth/nightlights')
  if not ok or type(nl) ~= 'table' then return end
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
      pcall(function() m:flush() end)
      pcall(function() m:reload() end)
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
  for name in pairs(mats) do
    syncNightlights(name, nil, false)
    local m = scenetree.findObject(name)
    if m then m:delete() end
  end
  mats, byTile, pendingDel, M.count = {}, {}, {}, 0
  restoreBldPbr()
end

function M.status()
  local active = 0
  for _ in pairs(mats) do active = active + 1 end
  return { count = M.count, active = active, pbrActive = M.pbrActive }
end

return M
