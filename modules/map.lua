PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Contours = PC.AreaContours
local Map = {
  areas = {},
  order = {},
  groups = {},
  buildQueue = {},
  cache = {},
  cacheCount = 0,
  groupSerial = 0,
  revision = 0,
  dirty = true,
  enabled = true,
  visibleCount = 0,
  visiblePatches = 0,
  visibleIcons = 0,
  failures = 0,
}

PC.Map = Map

Map.COLORS = {
  HORDE = { 0.90, 0.12, 0.08 },
  ALLIANCE = { 0.10, 0.42, 1.00 },
  RESOURCE = { 1.00, 0.78, 0.05 },
  NEUTRAL = { 0.72, 0.72, 0.72 },
}

Map.POI_TYPES = {
  OUTPOST = true,
  SETTLEMENT = true,
  HUNTING_GROUNDS = true,
  FOREST = true,
  GOLD_MINE = true,
  FARM = true,
}

-- Resource POIs are harvested, never controlled: no faction owner (decision 0029).
Map.RESOURCE_TYPES = {
  FOREST = true,
  GOLD_MINE = true,
  FARM = true,
}

-- 512x512 RLE atlas built by tools/make_poi_icon_atlas.py: this client draws
-- large uncompressed TGA atlases as diagonal bands.
local POI_ICON_TEXTURE =
  "Interface\\AddOns\\pandaConquest\\media\\Textures\\Icons\\MapPOIIconAtlas"
local POI_ICON_CELL = 72 / 512

Map.POI_ICONS = {
  OUTPOST = POI_ICON_TEXTURE,
  SETTLEMENT = POI_ICON_TEXTURE,
  HUNTING_GROUNDS = POI_ICON_TEXTURE,
  GOLD_MINE = POI_ICON_TEXTURE,
  FOREST = POI_ICON_TEXTURE,
  FARM = POI_ICON_TEXTURE,
}

-- Rows follow the sheet order (one per type).
Map.POI_ICON_ROWS = {
  HUNTING_GROUNDS = 0,
  OUTPOST = 1,
  SETTLEMENT = 2,
  GOLD_MINE = 3,
  FOREST = 4,
  FARM = 5,
}

-- Columns are capture states for controlled POIs. Resource rows contain the
-- same coloured neutral icon in every column and always select column zero.
Map.POI_ICON_COLUMNS = {
  HORDE = 2,
  ALLIANCE = 4,
}

-- Half-captured columns, shown while a challenger holds 50 % or more.
Map.POI_ICON_HALF_COLUMNS = {
  HORDE = 1,
  ALLIANCE = 3,
}

function Map.GetIconTexCoord(poiType, colorKey, column)
  local row = Map.POI_ICON_ROWS[poiType]
  if not row then return { 0, 1, 0, 1 } end
  if Map.RESOURCE_TYPES[poiType] then
    column = 0
  else
    column = column or Map.POI_ICON_COLUMNS[colorKey or ""] or 0
  end
  return {
    column * POI_ICON_CELL, (column + 1) * POI_ICON_CELL,
    row * POI_ICON_CELL, (row + 1) * POI_ICON_CELL,
  }
end

local PROFILE_TEXTURE =
  "Interface\\AddOns\\pandaConquest\\media\\Textures\\Map\\Contours\\AreaContourProfileStrong"
local PROFILE_ALPHA = 1.00
-- Hovering stacks a second copy of the area patches at this opacity on top of
-- the normal ones, which raises the fill from about 50 % to about 62 %.
local HOVER_ALPHA = 0.50
local HOVER_INTERVAL = 0.05
local POI_ICON_SIZE = 28
-- Half-width of the icon hover square, as a share of the icon size (the art
-- leaves a transparent margin, so the full 0.5 would catch empty corners).
local ICON_HIT_RATIO = 0.4
local CACHE_LIMIT = 64
local REFRESH_INTERVAL = 0.25

local function GetGlobal(name)
  if getglobal then return getglobal(name) end
  if _G then return _G[name] end
  return nil
end

local function Clamp(value, minimum, maximum)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

local function CanonicalMapName(value)
  if type(value) ~= "string" then return nil end
  local normalized = string.lower(string.gsub(value, "[^%w]", ""))
  if normalized == "" then return nil end
  return normalized
end

Map.CanonicalMapName = CanonicalMapName

local function CopyLocations(locations)
  if type(locations) ~= "table" then
    return nil, "locations must be a table"
  end

  local output = {}
  local index = 1
  local total = table.getn(locations)
  while index <= total do
    local location = locations[index]
    local x = location and (location.x or location[1])
    local y = location and (location.y or location[2])
    if type(x) ~= "number" or type(y) ~= "number"
        or x < 0 or x > 100 or y < 0 or y > 100 then
      return nil, "each location needs numeric x/y coordinates from 0 to 100"
    end
    table.insert(output, { x = x, y = y })
    index = index + 1
  end

  if table.getn(output) == 0 then
    return nil, "at least one location is required"
  end
  return output
end

-- Creature IDs that must be killed to capture the area (HUNTING_GROUNDS).
-- Absent means no kill requirement; duplicates are dropped, order is kept.
local function CopyMobIds(ids)
  local output = {}
  if ids == nil then return output end
  if type(ids) ~= "table" then
    return nil, "requiredMobIds must be a list of creature IDs"
  end
  local seen = {}
  local index = 1
  local total = table.getn(ids)
  while index <= total do
    local id = ids[index]
    if type(id) ~= "number" or id < 1 or math.floor(id) ~= id then
      return nil, "requiredMobIds must contain positive integer creature IDs"
    end
    if not seen[id] then
      seen[id] = true
      table.insert(output, id)
    end
    index = index + 1
  end
  return output
end

local function ResolveColor(value)
  if type(value) == "string" then
    local preset = Map.COLORS[string.upper(value)]
    if preset then return { preset[1], preset[2], preset[3] } end
    return nil, "unknown color preset"
  end
  if type(value) ~= "table" then
    return nil, "color must be HORDE, ALLIANCE, RESOURCE, NEUTRAL, or an RGB table"
  end
  local red = value.r or value[1]
  local green = value.g or value[2]
  local blue = value.b or value[3]
  if type(red) ~= "number" or type(green) ~= "number" or type(blue) ~= "number" then
    return nil, "custom color needs numeric red, green, and blue values"
  end
  return {
    Clamp(red, 0, 1), Clamp(green, 0, 1), Clamp(blue, 0, 1),
  }
end

local function NormalizeDefinition(definition)
  if type(definition) ~= "table" then
    return nil, "area definition must be a table"
  end
  if type(definition.id) ~= "string" or definition.id == "" then
    return nil, "area id must be a non-empty string"
  end
  local mapName = definition.map or definition.mapFile or definition.zone
  local mapKey = CanonicalMapName(mapName)
  if not mapKey then
    return nil, "map must be a non-empty zone map name"
  end

  local poiType = definition.type
  if type(poiType) ~= "string" or not Map.POI_TYPES[poiType] then
    return nil, "type must be OUTPOST, SETTLEMENT, HUNTING_GROUNDS, FOREST, GOLD_MINE, or FARM"
  end

  local locations = definition.locations
  if not locations and definition.x and definition.y then
    locations = { { x = definition.x, y = definition.y } }
  end
  local copiedLocations, locationError = CopyLocations(locations)
  if not copiedLocations then return nil, locationError end

  local copiedVertices = nil
  if definition.vertices ~= nil then
    copiedVertices, locationError = CopyLocations(definition.vertices)
    if not copiedVertices then return nil, "vertices: " .. tostring(locationError) end
    if table.getn(copiedVertices) < 3 then
      return nil, "vertices must contain at least three ordered coordinates"
    end
  end

  local copiedControlVertices = nil
  if definition.controlVertices ~= nil then
    copiedControlVertices, locationError = CopyLocations(definition.controlVertices)
    if not copiedControlVertices then
      return nil, "controlVertices: " .. tostring(locationError)
    end
    local controlTotal = table.getn(copiedControlVertices)
    if controlTotal < 3 or controlTotal > 32 then
      return nil, "controlVertices must contain 3 to 32 ordered coordinates"
    end
  end

  local shape = nil
  if definition.shape == "circle" then
    local radius = definition.radius
    local centerX = definition.x or copiedLocations[1].x
    local centerY = definition.y or copiedLocations[1].y
    if type(radius) ~= "number" or radius < 0.5 or radius > 20 then
      return nil, "circle radius must be a number from 0.5 to 20"
    end
    if type(centerX) ~= "number" or type(centerY) ~= "number"
        or centerX < 0 or centerX > 100 or centerY < 0 or centerY > 100 then
      return nil, "circle center needs numeric x/y coordinates from 0 to 100"
    end
    shape = { type = "circle", x = centerX, y = centerY, radius = radius }
    copiedVertices = nil
    copiedControlVertices = nil
  elseif definition.shape ~= nil and definition.shape ~= "polygon" then
    return nil, "shape must be polygon or circle"
  end

  local colorValue = definition.color or definition.category
  local color, colorError = ResolveColor(colorValue)
  if not color then return nil, colorError end
  local colorKey = nil
  if type(colorValue) == "string" then
    colorKey = string.upper(colorValue)
  elseif type(definition.colorKey) == "string" then
    colorKey = definition.colorKey
  end

  local requiredMobIds, mobError = CopyMobIds(definition.requiredMobIds)
  if not requiredMobIds then return nil, mobError end

  return {
    id = definition.id,
    map = mapName,
    mapKey = mapKey,
    type = poiType,
    category = definition.category,
    label = definition.label,
    color = color,
    colorKey = colorKey,
    locations = copiedLocations,
    vertices = copiedVertices,
    controlVertices = copiedControlVertices,
    shape = shape,
    requiredMobIds = requiredMobIds,
    enabled = definition.enabled ~= false,
  }
end

local function HideObject(object)
  if not object or type(object.Hide) ~= "function" then return false end
  return pcall(object.Hide, object) and true or false
end

local function HideHoverPatches(entry)
  if not entry or not entry.hoverTextures then return end
  local index = 1
  while index <= table.getn(entry.hoverTextures) do
    HideObject(entry.hoverTextures[index])
    index = index + 1
  end
end

local function HideEntry(entry)
  HideHoverPatches(entry)
  if entry and entry.icon then HideObject(entry.icon) end
  if entry and entry.frame then HideObject(entry.frame) end
  if entry then
    entry.active = false
    entry.iconShown = false
  end
end

local function StoreArea(self, normalized)
  local isNew = self.areas[normalized.id] == nil
  self.areas[normalized.id] = normalized
  if isNew then table.insert(self.order, normalized.id) end

  local entry = self.groups[normalized.id]
  if entry then
    entry.layoutKey = nil
    entry.pending = nil
    HideEntry(entry)
  end
  self.revision = self.revision + 1
  self.dirty = true
  return true
end

function Map:RegisterArea(definition)
  local normalized, err = NormalizeDefinition(definition)
  if not normalized then return false, err end
  return StoreArea(self, normalized)
end

function Map:RegisterPOI(definition)
  return self:RegisterArea(definition)
end

Map.AddPOI = Map.RegisterPOI

function Map:RegisterAreas(definitions)
  if type(definitions) ~= "table" then return false, "definitions must be a table" end
  local normalized = {}
  local index = 1
  local total = table.getn(definitions)
  while index <= total do
    local definition, err = NormalizeDefinition(definitions[index])
    if not definition then return false, "entry " .. tostring(index) .. ": " .. tostring(err) end
    table.insert(normalized, definition)
    index = index + 1
  end
  -- Store the validated copies directly: normalizing them a second time would
  -- reject the circle shape table built by the first pass.
  index = 1
  while index <= total do
    StoreArea(self, normalized[index])
    index = index + 1
  end
  return true, total
end

-- Returns a copy of the creature IDs required to capture the area, or nil for an unknown area.
function Map:GetRequiredMobIds(id)
  local area = type(id) == "string" and self.areas[id] or nil
  if not area then return nil end
  local copy = {}
  local index = 1
  local total = table.getn(area.requiredMobIds or {})
  while index <= total do
    table.insert(copy, area.requiredMobIds[index])
    index = index + 1
  end
  return copy
end

-- Shows the captured owner (HORDE, ALLIANCE, or nil for the static colour) and a
-- half-captured icon for the challenger at 50 % or more. Returns true on change.
function Map:SetCaptureView(id, ownerKey, halfKey)
  local area = type(id) == "string" and self.areas[id] or nil
  if not area then return false end
  if area.baseColorKey == nil then
    area.baseColorKey = area.colorKey or false
    area.baseColor = area.color
  end
  local colorKey = area.baseColorKey or nil
  local color = area.baseColor
  local preset = ownerKey and Map.COLORS[ownerKey]
  if preset then
    colorKey = ownerKey
    color = { preset[1], preset[2], preset[3] }
  end
  local column = halfKey and Map.POI_ICON_HALF_COLUMNS[halfKey] or nil
  if area.colorKey == colorKey and area.iconColumn == column then return false end
  area.colorKey = colorKey
  area.color = color
  area.iconColumn = column
  self.dirty = true
  return true
end

function Map:RemoveArea(id)
  if type(id) ~= "string" or not self.areas[id] then return false end
  self.areas[id] = nil
  local entry = self.groups[id]
  if entry then
    entry.pending = nil
    HideEntry(entry)
  end
  local index = 1
  while index <= table.getn(self.order) do
    if self.order[index] == id then
      table.remove(self.order, index)
      break
    end
    index = index + 1
  end
  self.revision = self.revision + 1
  self.dirty = true
  return true
end

function Map:SetEnabled(enabled)
  self.enabled = enabled and true or false
  self.dirty = true
  if not self.enabled then self:HideAll() end
end

local function GetCanvas()
  local canvas = GetGlobal("WorldMapButton")
  if not canvas or type(canvas.GetWidth) ~= "function"
      or type(canvas.GetHeight) ~= "function" then
    return nil
  end
  return canvas
end

local function GetCanvasSize(canvas)
  if not canvas then return nil end
  local widthOk, width = pcall(canvas.GetWidth, canvas)
  local heightOk, height = pcall(canvas.GetHeight, canvas)
  if not widthOk or not heightOk or type(width) ~= "number" or type(height) ~= "number"
      or width <= 0 or height <= 0 then
    return nil
  end
  return width, height
end

local function GetCurrentMapFile()
  local getMapInfo = GetGlobal("GetMapInfo")
  if type(getMapInfo) ~= "function" then return nil end
  local ok, name = pcall(getMapInfo)
  if not ok or type(name) ~= "string" or name == "" then return nil end

  local getZone = GetGlobal("GetCurrentMapZone")
  if type(getZone) == "function" then
    local zoneOk, zoneIndex = pcall(getZone)
    if zoneOk and type(zoneIndex) == "number" and zoneIndex == 0 then return nil end
  end
  return name
end

local function CreateGroup()
  local canvas = GetCanvas()
  local create = GetGlobal("CreateFrame")
  if not canvas or type(create) ~= "function" then return nil end

  Map.groupSerial = Map.groupSerial + 1
  local ok, frame = pcall(create, "Frame",
    "PandaConquestMapAreaGroup" .. tostring(Map.groupSerial), canvas)
  if not ok or not frame then return nil end
  if type(frame.SetAllPoints) == "function" then pcall(frame.SetAllPoints, frame, canvas) end
  if type(frame.EnableMouse) == "function" then pcall(frame.EnableMouse, frame, false) end
  if type(canvas.GetFrameLevel) == "function" and type(frame.SetFrameLevel) == "function" then
    local levelOk, level = pcall(canvas.GetFrameLevel, canvas)
    if levelOk and type(level) == "number" then
      pcall(frame.SetFrameLevel, frame, level + 1)
    end
  end
  HideObject(frame)
  return frame
end

local function GetEntry(id)
  local entry = Map.groups[id]
  if entry then return entry end
  local frame = CreateGroup()
  if not frame then return nil end
  entry = { frame = frame, textures = {}, visible = 0, active = false }
  Map.groups[id] = entry
  return entry
end

local function LayoutKey(area)
  local parts = { area.id, area.mapKey, area.type }
  local index = 1
  local total = table.getn(area.locations)
  while index <= total do
    local location = area.locations[index]
    table.insert(parts, tostring(location.x) .. ":" .. tostring(location.y))
    index = index + 1
  end
  table.insert(parts, "vertices")
  index = 1
  total = table.getn(area.vertices or {})
  while index <= total do
    local vertex = area.vertices[index]
    table.insert(parts, tostring(vertex.x) .. ":" .. tostring(vertex.y))
    index = index + 1
  end
  table.insert(parts, "controlVertices")
  index = 1
  total = table.getn(area.controlVertices or {})
  while index <= total do
    local vertex = area.controlVertices[index]
    table.insert(parts, tostring(vertex.x) .. ":" .. tostring(vertex.y))
    index = index + 1
  end
  if area.shape then
    table.insert(parts, area.shape.type)
    table.insert(parts, tostring(area.shape.x) .. ":" .. tostring(area.shape.y))
    table.insert(parts, tostring(area.shape.radius))
  end
  return table.concat(parts, "|")
end

local function StoreCache(key, patches)
  if Map.cache[key] then return Map.cache[key] end
  if Map.cacheCount >= CACHE_LIMIT then
    Map.cache = {}
    Map.cacheCount = 0
  end
  Map.cache[key] = patches
  Map.cacheCount = Map.cacheCount + 1
  return patches
end

local function BuildRecords(patches)
  local records = {}
  local grid = Contours.GRID
  local index = 1
  local total = table.getn(patches or {})
  while index <= total do
    local patch = patches[index]
    local left = math.max(0, patch[1])
    local top = math.max(0, patch[2])
    local right = math.min(grid, patch[3])
    local bottom = math.min(grid, patch[4])
    if right > left and bottom > top then
      table.insert(records, {
        left / grid, top / grid, right / grid, bottom / grid,
        Contours.ProfileU(patch[5]), Contours.ProfileU(patch[6]), 0.25, 0.75,
      })
    end
    index = index + 1
  end
  return records
end

local function CreatePatch(entry)
  if not entry.frame or type(entry.frame.CreateTexture) ~= "function" then return nil end
  local ok, texture = pcall(entry.frame.CreateTexture, entry.frame, nil, "ARTWORK")
  if not ok then return nil end
  return texture
end

local function GetIconPosition(area)
  if area.shape then return area.shape.x / 100, area.shape.y / 100 end
  local points = area.controlVertices or area.vertices or area.locations
  local total = table.getn(points or {})
  if total == 0 then return nil end
  -- Middle of the bounding box, matching iconAnchor() in the HTML editor.
  local minX, maxX = points[1].x, points[1].x
  local minY, maxY = points[1].y, points[1].y
  local index = 2
  while index <= total do
    local point = points[index]
    if point.x < minX then minX = point.x end
    if point.x > maxX then maxX = point.x end
    if point.y < minY then minY = point.y end
    if point.y > maxY then maxY = point.y end
    index = index + 1
  end
  return (minX + maxX) / 200, (minY + maxY) / 200
end

local function PlaceIcon(entry, area, width, height)
  local path = Map.POI_ICONS[area.type]
  entry.iconShown = false
  if not path then
    if entry.icon then HideObject(entry.icon) end
    return true
  end
  if not entry.frame or type(entry.frame.CreateTexture) ~= "function" then return false end
  if not entry.icon then
    local ok, icon = pcall(entry.frame.CreateTexture, entry.frame, nil, "OVERLAY")
    if not ok or not icon then return false end
    entry.icon = icon
  end
  local x, y = GetIconPosition(area)
  if not x or not y then return false end
  if type(entry.icon.SetTexture) ~= "function" or type(entry.icon.ClearAllPoints) ~= "function"
      or type(entry.icon.SetTexCoord) ~= "function"
      or type(entry.icon.SetPoint) ~= "function" or type(entry.icon.SetWidth) ~= "function"
      or type(entry.icon.SetHeight) ~= "function" or type(entry.icon.Show) ~= "function" then
    return false
  end
  local ok = pcall(function()
    if entry.icon.pandaConquestPath ~= path then
      entry.icon:SetTexture(path)
      entry.icon.pandaConquestPath = path
    end
    local texCoord = Map.GetIconTexCoord(area.type, area.colorKey, area.iconColumn)
    entry.icon:SetTexCoord(texCoord[1], texCoord[2], texCoord[3], texCoord[4])
    entry.icon:ClearAllPoints()
    entry.icon:SetPoint("CENTER", entry.frame, "TOPLEFT", x * width, -y * height)
    entry.icon:SetWidth(POI_ICON_SIZE)
    entry.icon:SetHeight(POI_ICON_SIZE)
    entry.icon:Show()
  end)
  entry.iconShown = ok and true or false
  return entry.iconShown
end

local function PlacePatch(entry, texture, record, width, height, color, alpha)
  if not texture then return false end
  if type(texture.SetTexture) ~= "function" or type(texture.SetTexCoord) ~= "function"
      or type(texture.SetVertexColor) ~= "function"
      or type(texture.ClearAllPoints) ~= "function"
      or type(texture.SetPoint) ~= "function" or type(texture.SetWidth) ~= "function"
      or type(texture.SetHeight) ~= "function" or type(texture.Show) ~= "function" then
    return false
  end

  local ok = pcall(function()
    if texture.pandaConquestPath ~= PROFILE_TEXTURE then
      texture:SetTexture(PROFILE_TEXTURE)
      texture.pandaConquestPath = PROFILE_TEXTURE
    end
    texture:SetTexCoord(record[5], record[6], record[7], record[8])
    texture:SetVertexColor(color[1], color[2], color[3], alpha or PROFILE_ALPHA)
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", entry.frame, "TOPLEFT",
      record[1] * width, -record[2] * height)
    texture:SetWidth(math.max(0.1, (record[3] - record[1]) * width))
    texture:SetHeight(math.max(0.1, (record[4] - record[2]) * height))
    texture:Show()
  end)
  return ok and true or false
end

local function ApplyEntry(entry, area, width, height)
  if not entry or not entry.frame or not entry.records then return 0 end
  local failures = 0
  local index = 1
  local total = table.getn(entry.records)
  while index <= total do
    if not entry.textures[index] then entry.textures[index] = CreatePatch(entry) end
    if not PlacePatch(entry, entry.textures[index], entry.records[index], width, height,
        area.color) then
      failures = failures + 1
      HideObject(entry.textures[index])
    end
    index = index + 1
  end
  while index <= table.getn(entry.textures) do
    HideObject(entry.textures[index])
    index = index + 1
  end
  entry.visible = total
  entry.active = true
  local canvas = GetCanvas()
  if canvas and type(entry.frame.SetAllPoints) == "function" then
    pcall(entry.frame.SetAllPoints, entry.frame, canvas)
  end
  if type(entry.frame.Show) == "function" then pcall(entry.frame.Show, entry.frame) end
  if not PlaceIcon(entry, area, width, height) then failures = failures + 1 end
  return failures
end

local function QueueBuild(entry, area, key)
  entry.layoutKey = key
  entry.records = nil
  entry.pending = {
    key = key,
    areaId = area.id,
    build = Contours.BeginBuild(
      area.locations, area.vertices, area.shape, area.controlVertices),
  }
  if not entry.queued then
    entry.queued = true
    table.insert(Map.buildQueue, entry)
  end
end

function Map:StepBuildQueue()
  if table.getn(self.buildQueue) == 0 then return false end
  local entry = table.remove(self.buildQueue, 1)
  entry.queued = nil
  local pending = entry.pending
  if not pending then return false end

  local done, patches = Contours.StepBuild(pending.build, Contours.BUILD_ROWS_PER_TICK)
  if not done then
    entry.queued = true
    table.insert(self.buildQueue, entry)
    return false
  end

  patches = StoreCache(pending.key, patches)
  if entry.pending == pending then
    entry.records = BuildRecords(patches)
    entry.pending = nil
    self.dirty = true
  end
  return true
end

function Map:HideAll()
  self:ClearHover()
  local index = 1
  while index <= table.getn(self.order) do
    local entry = self.groups[self.order[index]]
    if entry then HideEntry(entry) end
    index = index + 1
  end
  self.visibleCount = 0
  self.visiblePatches = 0
  self.visibleIcons = 0
end

-- Hides every group before the client hides the map, so its recursive hide
-- never walks our regions (crash 007A2452, docs/decisions/0021). The next
-- Refresh rebuilds the visible state.
function Map:SuspendForClose()
  self:HideAll()
  self.dirty = true
  self.lastSignature = nil
end

local function ReapplyVisibleGroups()
  local canvas = GetCanvas()
  local index = 1
  while index <= table.getn(Map.order) do
    local entry = Map.groups[Map.order[index]]
    if entry and entry.active and entry.frame then
      if canvas and type(entry.frame.SetAllPoints) == "function" then
        pcall(entry.frame.SetAllPoints, entry.frame, canvas)
      end
      if type(entry.frame.Show) == "function" then pcall(entry.frame.Show, entry.frame) end
    end
    index = index + 1
  end
end

function Map:Refresh(force)
  local canvas = GetCanvas()
  local mapName = GetCurrentMapFile()
  local mapKey = CanonicalMapName(mapName)
  local width, height = GetCanvasSize(canvas)
  if not self.enabled or not Contours or not canvas or not mapKey or not width then
    self:HideAll()
    self.lastSignature = nil
    return false
  end

  local signature = mapKey .. "|" .. tostring(width) .. "|" .. tostring(height)
    .. "|" .. tostring(self.revision)
  if not force and not self.dirty and self.lastSignature == signature then
    ReapplyVisibleGroups()
    return true
  end

  self.dirty = false
  self.lastSignature = signature
  self.currentMap = mapName
  self:ClearHover()
  self.visibleCount = 0
  self.visiblePatches = 0
  self.visibleIcons = 0
  self.failures = 0

  local index = 1
  while index <= table.getn(self.order) do
    local id = self.order[index]
    local area = self.areas[id]
    local entry = self.groups[id]
    if area and area.enabled and area.mapKey == mapKey then
      entry = entry or GetEntry(id)
      if entry then
        local key = LayoutKey(area)
        if entry.layoutKey ~= key then
          local cached = self.cache[key]
          if cached then
            entry.layoutKey = key
            entry.pending = nil
            entry.records = BuildRecords(cached)
          else
            QueueBuild(entry, area, key)
          end
        end

        if entry.records then
          self.failures = self.failures + ApplyEntry(entry, area, width, height)
          self.visibleCount = self.visibleCount + 1
          self.visiblePatches = self.visiblePatches + table.getn(entry.records)
          if entry.iconShown then self.visibleIcons = self.visibleIcons + 1 end
        else
          HideEntry(entry)
        end
      else
        self.failures = self.failures + 1
      end
    elseif entry then
      HideEntry(entry)
    end
    index = index + 1
  end
  return true
end

function Map:GetStatus()
  local building = 0
  local index = 1
  while index <= table.getn(self.buildQueue) do
    if self.buildQueue[index] and self.buildQueue[index].pending then
      building = building + 1
    end
    index = index + 1
  end
  return {
    enabled = self.enabled,
    registered = table.getn(self.order),
    map = self.currentMap,
    visible = self.visibleCount,
    patches = self.visiblePatches,
    icons = self.visibleIcons,
    building = building,
    failures = self.failures,
    cached = self.cacheCount,
  }
end

Map.TYPE_NAMES = {
  OUTPOST = "Outpost",
  SETTLEMENT = "Settlement",
  HUNTING_GROUNDS = "Hunting Grounds",
  FOREST = "Forest",
  GOLD_MINE = "Gold Mine",
  FARM = "Farm",
}

Map.TYPE_HINTS = {
  OUTPOST = "Stay inside the zone to capture it.",
  SETTLEMENT = "Capturable once every associated objective is controlled.",
  HUNTING_GROUNDS = "Kill the required creatures to capture it.",
  FOREST = "Harvest wood.",
  GOLD_MINE = "Harvest gold.",
  FARM = "Produce agricultural resources.",
}

local OWNER_CODES = { HORDE = "H", ALLIANCE = "A" }
local FACTION_LABELS = {
  H = { "Horde", 0.90, 0.25, 0.20 },
  A = { "Alliance", 0.25, 0.55, 1.00 },
  N = { "Neutral", 0.70, 0.70, 0.70 },
}

local function CursorOnCanvas(canvas, width, height)
  local getCursor = GetGlobal("GetCursorPosition")
  if type(getCursor) ~= "function" or type(canvas.GetEffectiveScale) ~= "function"
      or type(canvas.GetLeft) ~= "function" or type(canvas.GetTop) ~= "function" then
    return nil
  end
  local ok, cursorX, cursorY, scale, left, top = pcall(function()
    local x, y = getCursor()
    return x, y, canvas:GetEffectiveScale(), canvas:GetLeft(), canvas:GetTop()
  end)
  if not ok or type(cursorX) ~= "number" or type(cursorY) ~= "number"
      or type(scale) ~= "number" or scale <= 0
      or type(left) ~= "number" or type(top) ~= "number" then
    return nil
  end
  local x = ((cursorX / scale) - left) / width * 100
  local y = (top - (cursorY / scale)) / height * 100
  if x < 0 or x > 100 or y < 0 or y > 100 then return nil end
  return x, y
end

local function ShowHoverPatches(entry, area, width, height)
  if not entry.records then return end
  entry.hoverTextures = entry.hoverTextures or {}
  local total = table.getn(entry.records)
  local index = 1
  while index <= total do
    if not entry.hoverTextures[index] then entry.hoverTextures[index] = CreatePatch(entry) end
    if not PlacePatch(entry, entry.hoverTextures[index], entry.records[index],
        width, height, area.color, HOVER_ALPHA) then
      HideObject(entry.hoverTextures[index])
    end
    index = index + 1
  end
  while index <= table.getn(entry.hoverTextures) do
    HideObject(entry.hoverTextures[index])
    index = index + 1
  end
end

local function FormatDuration(seconds)
  seconds = math.ceil(seconds)
  if seconds < 60 then return seconds .. "s" end
  return string.format("%dm %02ds", math.floor(seconds / 60), math.mod(seconds, 60))
end

local function AddFactionLine(tooltip, left, code, suffix)
  local label = FACTION_LABELS[code] or FACTION_LABELS.N
  tooltip:AddDoubleLine(left, label[1] .. (suffix or ""), 0.8, 0.8, 0.8,
    label[2], label[3], label[4])
end

-- The open world map is a full-screen panel: SetFullScreenFrame hides UIParent and
-- GameTooltip with it, so use the map's own WorldMapTooltip (parent WorldMapFrame).
local function MapTooltip()
  local tooltip = GetGlobal("WorldMapTooltip")
  if tooltip and type(tooltip.SetOwner) == "function" then return tooltip, "WorldMapTooltip" end
  tooltip = GetGlobal("GameTooltip")
  if tooltip and type(tooltip.SetOwner) == "function" then return tooltip, "GameTooltip" end
  return nil, "none"
end

local function ShowAreaTooltip(canvas, area)
  local tooltip = MapTooltip()
  if not tooltip then return nil end
  local typeName = Map.TYPE_NAMES[area.type] or area.type
  local info = PC.Capture and PC.Capture.TooltipInfo and PC.Capture:TooltipInfo(area.id)
  local ok = pcall(function()
    tooltip:SetOwner(canvas, "ANCHOR_CURSOR")
    tooltip:ClearLines()
    tooltip:AddLine(area.label or typeName, 1, 0.82, 0)
    if area.label then tooltip:AddLine(typeName, 1, 1, 1) end
    -- Capturable areas follow the owner registry; others keep their drawn color.
    if not Map.RESOURCE_TYPES[area.type] then
      AddFactionLine(tooltip, "Owner", info and info.owner or OWNER_CODES[area.colorKey or ""] or "N")
    end
    if info and info.challenger then
      AddFactionLine(tooltip, "Capture", info.challenger, " " .. info.percent .. "%")
    end
    if info and info.status then
      local status = info.status
      if info.remaining then status = status .. " (" .. FormatDuration(info.remaining) .. ")" end
      tooltip:AddLine(status, 1, 1, 1)
    end
    if info and (info.nH or 0) + (info.nA or 0) > 0 then
      tooltip:AddDoubleLine("Players inside", "|cffe64033" .. info.nH .. " Horde|r  |cff408cff"
        .. info.nA .. " Alliance|r", 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if info and info.here then tooltip:AddLine("You are here", 0.3, 1, 0.3) end
    local hint = Map.TYPE_HINTS[area.type]
    if hint then tooltip:AddLine(hint, 0.8, 0.8, 0.8, 1) end
    local mobs = table.getn(area.requiredMobIds or {})
    if mobs > 0 then
      tooltip:AddLine("Required creatures: " .. mobs, 1, 1, 1)
    end
    tooltip:Show()
  end)
  return ok and tooltip or nil
end

function Map:ClearHover()
  local id = self.hoverId
  self.hoverId = nil
  self.cursorX = nil
  self.cursorY = nil
  local entry = id and self.groups[id]
  if entry then HideHoverPatches(entry) end
  local tooltip = self.tooltipShown
  if tooltip then
    self.tooltipShown = nil
    if type(tooltip.Hide) == "function" then pcall(tooltip.Hide, tooltip) end
  end
end

function Map:FindAreaAt(x, y, width, height)
  local mapKey = CanonicalMapName(self.currentMap)
  local index
  -- Icons draw above every area and may overhang their own zone (the bounding-box
  -- middle can fall outside a concave one), so the cursor on an icon picks it first.
  if width and height then
    local reachX = POI_ICON_SIZE * ICON_HIT_RATIO / width * 100
    local reachY = POI_ICON_SIZE * ICON_HIT_RATIO / height * 100
    index = table.getn(self.order)
    while index >= 1 do
      local id = self.order[index]
      local area = self.areas[id]
      local entry = self.groups[id]
      if area and entry and entry.active and entry.iconShown and area.mapKey == mapKey then
        local iconX, iconY = GetIconPosition(area)
        if iconX and math.abs(x - iconX * 100) <= reachX
            and math.abs(y - iconY * 100) <= reachY then
          return id
        end
      end
      index = index - 1
    end
  end
  index = table.getn(self.order)
  -- Later areas draw above earlier ones, so test them first.
  while index >= 1 do
    local id = self.order[index]
    local area = self.areas[id]
    local entry = self.groups[id]
    if area and entry and entry.active and entry.records and area.mapKey == mapKey
        and Contours.AreaContainsPoint(area, x, y) then
      return id
    end
    index = index - 1
  end
  return nil
end

-- True when the mouse is over the map itself: the canvas, or a frame that holds it
-- (WorldMapDetailFrame, WorldMapFrame). Buttons drawn on the canvas and unrelated
-- frames above the map block the hover.
local function MapHasFocus(canvas, focus)
  if focus == canvas then return true end
  if not focus then return false end
  local node = canvas
  local depth = 0
  while node and depth < 10 do
    if type(node.GetParent) ~= "function" then return false end
    local ok, parent = pcall(node.GetParent, node)
    if not ok then return false end
    if parent == focus then return true end
    node = parent
    depth = depth + 1
  end
  return false
end

local function FrameLabel(frame)
  if not frame then return "none" end
  if type(frame.GetName) == "function" then
    local ok, name = pcall(frame.GetName, frame)
    if ok and name then return tostring(name) end
  end
  return "unnamed"
end

-- Taken when a tooltip opens, for /pc map hover (chat cannot be typed with the map open).
local function TooltipProbe(tooltip)
  local _, name = MapTooltip()
  if not tooltip then return "tooltip=" .. name .. " not shown" end
  local function Ask(frame, method)
    if not frame or type(frame[method]) ~= "function" then return "n/a" end
    local ok, value = pcall(frame[method], frame)
    return ok and tostring(value) or "error"
  end
  local parent = nil
  if type(tooltip.GetParent) == "function" then
    local ok, frame = pcall(tooltip.GetParent, tooltip)
    if ok then parent = frame end
  end
  return "tooltip=" .. name .. " parent=" .. FrameLabel(parent)
    .. " visible=" .. Ask(tooltip, "IsVisible") .. " lines=" .. Ask(tooltip, "NumLines")
    .. " strata=" .. Ask(tooltip, "GetFrameStrata")
    .. " UIParent.visible=" .. Ask(GetGlobal("UIParent"), "IsVisible")
end

function Map:UpdateHover()
  local canvas = GetCanvas()
  local width, height = GetCanvasSize(canvas)
  local canvasShown = true
  if canvas and type(canvas.IsVisible) == "function" then
    local shownOk, shown = pcall(canvas.IsVisible, canvas)
    canvasShown = not shownOk or shown and true or false
  end
  if not width or not canvasShown then
    if self.hoverId then self:ClearHover() end
    return
  end

  local getFocus = GetGlobal("GetMouseFocus")
  local focus = nil
  local focusOk = false
  if type(getFocus) == "function" then focusOk, focus = pcall(getFocus) end
  local x, y = CursorOnCanvas(canvas, width, height)
  -- This client can report no focused frame over the open map, so only a frame that
  -- is reported and unrelated to the map (a button, a window) blocks the hover.
  local overMap = not focus or MapHasFocus(canvas, focus)
  self.hoverDebug = "focus=" .. FrameLabel(focus) .. " getFocus=" .. type(getFocus)
    .. " focusOk=" .. tostring(focusOk) .. " overMap=" .. tostring(overMap)
    .. " cursor=" .. (x and string.format("%.1f,%.1f", x, y) or "off-canvas")
    .. " visible=" .. tostring(self.visibleCount) .. " map=" .. tostring(self.currentMap)
    .. " hover=" .. tostring(self.hoverId)

  if not self.enabled or not Contours or not overMap or not x
      or self.visibleCount == 0 or not self.currentMap then
    if self.hoverId then self:ClearHover() end
    return
  end
  if self.cursorX == x and self.cursorY == y then return end

  local id = self:FindAreaAt(x, y, width, height)
  if id == self.hoverId then
    self.cursorX, self.cursorY = x, y
    return
  end

  self:ClearHover()
  self.cursorX, self.cursorY = x, y
  if not id then return end

  local area = self.areas[id]
  local entry = self.groups[id]
  self.hoverId = id
  ShowHoverPatches(entry, area, width, height)
  self.tooltipShown = ShowAreaTooltip(canvas, area)
  self.tooltipDebug = id .. " " .. TooltipProbe(self.tooltipShown)
end

function Map:Tick()
  self:StepBuildQueue()
  local now = PC.Now and PC.Now() or 0
  if type(now) == "number" and now > 0
      and (not self.lastHoverAt or now - self.lastHoverAt >= HOVER_INTERVAL) then
    self.lastHoverAt = now
    local hoverOk, hoverError = pcall(self.UpdateHover, self)
    if not hoverOk and PC.RecordError then PC.RecordError("map hover", hoverError) end
  end
  if type(now) == "number" and now > 0 then
    if not self.lastRefreshAt or now - self.lastRefreshAt >= REFRESH_INTERVAL then
      self.lastRefreshAt = now
      self:Refresh()
    end
  else
    self.fallbackTicks = (self.fallbackTicks or 0) + 1
    if self.fallbackTicks >= 15 then
      self.fallbackTicks = 0
      self:Refresh()
    end
  end
end

-- Diagnostic squares for the area-patch texture, built like a real area group.
-- Each square isolates one suspect, left to right:
-- 1 white WHITE8X8 (control), 2 profile fill, 3 the same fill with mirrored u
-- (every real patch has u1 > u2), 4 the fill stacked from 48 strips 0.83 units
-- tall (the real patch height), 5 the whole profile strip (border gradient).
local PROBE_SIZE = 40
local PROBE_STRIPS = 48

function Map:ShowProbe(enabled)
  if self.probe then
    HideObject(self.probe)
    self.probe = nil
  end
  if not enabled then return true, "probe removed" end

  local canvas = GetCanvas()
  local create = GetGlobal("CreateFrame")
  if not canvas or type(create) ~= "function" then return false, "no WorldMapButton" end
  local ok, frame = pcall(create, "Frame", nil, canvas)
  if not ok or not frame then return false, "CreateFrame failed" end
  frame:SetAllPoints(canvas)
  frame:EnableMouse(false)
  frame:SetFrameLevel(canvas:GetFrameLevel() + 1)
  self.probe = frame

  local results = {}
  local function Square(index, path, u1, u2, v1, v2, top, height)
    local texture = frame:CreateTexture(nil, "ARTWORK")
    local loaded = texture:SetTexture(path)
    texture:SetTexCoord(u1, u2, v1, v2)
    texture:SetVertexColor(1, 0.2, 0.8, 1)
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT",
      40 + (index - 1) * (PROBE_SIZE + 12), -(40 + top))
    texture:SetWidth(PROBE_SIZE)
    texture:SetHeight(height)
    texture:Show()
    return loaded
  end

  results[1] = Square(1, "Interface\\Buttons\\WHITE8X8", 0, 1, 0, 1, 0, PROBE_SIZE)
  results[2] = Square(2, PROFILE_TEXTURE, 0.95, 0.99, 0.25, 0.75, 0, PROBE_SIZE)
  results[3] = Square(3, PROFILE_TEXTURE, 0.99, 0.95, 0.25, 0.75, 0, PROBE_SIZE)
  local strip = PROBE_SIZE / PROBE_STRIPS
  local index = 1
  while index <= PROBE_STRIPS do
    results[4] = Square(4, PROFILE_TEXTURE, 0.95, 0.99, 0.25, 0.75,
      (index - 1) * strip, strip)
    index = index + 1
  end
  results[5] = Square(5, PROFILE_TEXTURE, 0, 1, 0, 1, 0, PROBE_SIZE)
  frame:Show()
  return true, "SetTexture white=" .. tostring(results[1])
    .. " profile=" .. tostring(results[2])
end

local staticData = PC.POIData or {}
local ok, err = Map:RegisterAreas(staticData)
if not ok and PC.RecordError then PC.RecordError("map static POIs", err) end

local create = GetGlobal("CreateFrame")
if type(create) == "function" then
  -- UIParent is hidden while the fullscreen map is open, which stops its children's
  -- OnUpdate; WorldFrame keeps ticking so the open map refreshes and finishes builds.
  local driverParent = GetGlobal("WorldFrame") or UIParent
  local frameOk, driver = pcall(create, "Frame", "PandaConquestMapDriver", driverParent)
  if frameOk and driver and type(driver.SetScript) == "function" then
    driver:SetScript("OnUpdate", function()
      local tickOk, tickError = pcall(Map.Tick, Map)
      if not tickOk and PC.RecordError then PC.RecordError("map driver", tickError) end
    end)
    Map.driver = driver
  elseif PC.RecordError then
    PC.RecordError("map driver", "unable to create OnUpdate driver")
  end
end

local function SuspendSafely()
  local suspendOk, suspendError = pcall(Map.SuspendForClose, Map)
  if not suspendOk and PC.RecordError then PC.RecordError("map close", suspendError) end
end

local mapFrame = GetGlobal("WorldMapFrame")
if mapFrame and type(mapFrame.GetScript) == "function"
    and type(mapFrame.SetScript) == "function" then
  local previousOnHide = mapFrame:GetScript("OnHide")
  mapFrame:SetScript("OnHide", function()
    SuspendSafely()
    if previousOnHide then previousOnHide() end
  end)
end

local toggleWorldMap = GetGlobal("ToggleWorldMap")
if type(toggleWorldMap) == "function" and mapFrame and type(mapFrame.IsVisible) == "function" then
  ToggleWorldMap = function()
    if mapFrame:IsVisible() then SuspendSafely() end
    return toggleWorldMap()
  end
end
