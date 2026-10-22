PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Map = PC.Map

-- POI areas of the player's zone on the minimap (docs/map-pois.md § Minimap,
-- decision 0054): the world map's records and colours, placed around the
-- player and clipped to the round minimap. Local display only.
local MinimapAreas = {
  patches = {},
  icons = {},
  iconKeys = {},
  used = 0,
  iconsUsed = 0,
  elapsed = 0,
  sinceLayout = 0,
  indoorDirty = true,
}

PC.MinimapAreas = MinimapAreas

-- Minimap diameter in yards per zoom level (1.12 client values used by
-- pfQuest and Questie, not measured on OctoWoW).
local OUTDOOR_YARDS = { 466.6667, 400, 333.3333, 266.6667, 200, 133.3333 }
local INDOOR_YARDS = { 300, 240, 180, 120, 80, 50 }
local UPDATE_INTERVAL = 0.05
local REFRESH_INTERVAL = 1
local MOVE_PIXELS = 0.5
-- Height of the bands a patch crossing the minimap edge is cut into.
local BAND = 2
local EDGE_INSET = 1
local MAX_PATCHES = 1500
-- Lighter than the world map so the terrain and blips stay readable.
local ALPHA = 0.6
local ICON_SIZE = 23

local function WorldMapShown()
  local frame = WorldMapFrame
  return frame and type(frame.IsVisible) == "function" and frame:IsVisible() and true or false
end

-- Map file and position (0..1) of the player on the zone map the client
-- holds; modules/presence.lua re-centres a closed map on the player's zone.
local function ReadPlayer()
  if type(GetMapInfo) ~= "function" or type(GetPlayerMapPosition) ~= "function" then
    return nil
  end
  local mapFile = GetMapInfo()
  if type(mapFile) ~= "string" or mapFile == "" then return nil end
  if type(GetCurrentMapZone) == "function" and GetCurrentMapZone() == 0 then return nil end
  local x, y = GetPlayerMapPosition("player")
  if type(x) ~= "number" or type(y) ~= "number" or (x == 0 and y == 0) then return nil end
  return mapFile, x, y
end

-- The client saves the outdoor and indoor zooms separately; when they differ,
-- the current zoom tells which one applies. Equal or unreadable: outdoor.
local function ReadIndoor(zoom)
  if type(GetCVar) ~= "function" then return false end
  local outsideOk, outside = pcall(GetCVar, "minimapZoom")
  local insideOk, inside = pcall(GetCVar, "minimapInsideZoom")
  outside = outsideOk and tonumber(outside) or nil
  inside = insideOk and tonumber(inside) or nil
  if not outside or not inside or outside == inside then return false end
  return zoom == inside
end

local function Hide(object)
  if object and type(object.Hide) == "function" then object:Hide() end
end

function MinimapAreas:Create()
  local minimap = Minimap
  if self.frame or not minimap or type(CreateFrame) ~= "function" then return self.frame end
  local frame = CreateFrame("Frame", "PandaConquestMinimapAreas", minimap)
  if not frame then return nil end
  if type(frame.SetAllPoints) == "function" then frame:SetAllPoints(minimap) end
  if type(frame.EnableMouse) == "function" then frame:EnableMouse(false) end
  frame:SetScript("OnUpdate", function()
    local ok, err = pcall(MinimapAreas.Tick, MinimapAreas, arg1)
    if not ok and PC.RecordError then PC.RecordError("minimap areas", err) end
  end)
  if type(frame.RegisterEvent) == "function" then
    frame:RegisterEvent("MINIMAP_UPDATE_ZOOM")
    frame:RegisterEvent("ZONE_CHANGED")
    frame:RegisterEvent("ZONE_CHANGED_INDOORS")
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:SetScript("OnEvent", function()
      MinimapAreas.indoorDirty = true
      MinimapAreas.sinceLayout = REFRESH_INTERVAL
    end)
  end
  self.frame, self.minimap = frame, minimap
  return frame
end

local function Patch(self, index)
  local texture = self.patches[index]
  if not texture then
    texture = self.frame:CreateTexture(nil, "ARTWORK")
    texture:SetTexture(Map.PROFILE_TEXTURE)
    self.patches[index] = texture
  end
  return texture
end

-- One rectangle in minimap pixels from its centre (y downwards).
local function Draw(self, left, top, right, bottom, u1, u2, color)
  if self.used >= MAX_PATCHES then return end
  self.used = self.used + 1
  local texture = Patch(self, self.used)
  texture:SetTexCoord(u1, u2, 0.25, 0.75)
  if texture.pandaConquestColor ~= color then
    texture:SetVertexColor(color[1], color[2], color[3], ALPHA)
    texture.pandaConquestColor = color
  end
  texture:ClearAllPoints()
  texture:SetPoint("TOPLEFT", self.frame, "CENTER", left, -top)
  texture:SetWidth(right - left)
  texture:SetHeight(bottom - top)
  texture:Show()
end

-- A record fully inside the circle is drawn as is; one crossing the edge is
-- cut into bands, each clipped to the circle's chord at its middle, the
-- profile coordinate following the clipped ends.
local function PlaceRecord(self, record, view, color)
  local left = (record[1] - view.x) * view.width
  local right = (record[3] - view.x) * view.width
  local top = (record[2] - view.y) * view.height
  local bottom = (record[4] - view.y) * view.height
  local radius = view.radius
  if right <= -radius or left >= radius or bottom <= -radius or top >= radius then return end
  local farX = math.max(math.abs(left), math.abs(right))
  local farY = math.max(math.abs(top), math.abs(bottom))
  if farX * farX + farY * farY <= radius * radius then
    Draw(self, left, top, right, bottom, record[5], record[6], color)
    return
  end
  local u1, span = record[5], right - left
  local slope = (record[6] - u1) / span
  local y = math.max(top, -radius)
  local last = math.min(bottom, radius)
  while y < last do
    local y2 = math.min(y + BAND, last)
    local middle = (y + y2) / 2
    local half = math.sqrt(math.max(0, radius * radius - middle * middle))
    local l = math.max(left, -half)
    local r = math.min(right, half)
    if r > l then
      Draw(self, l, y, r, y2, u1 + slope * (l - left), u1 + slope * (r - left), color)
    end
    y = y2
  end
end

local function PlaceIcon(self, area, view)
  local x, y = Map.IconPosition(area)
  if not x then return end
  local dx, dy = (x - view.x) * view.width, (y - view.y) * view.height
  local reach = view.radius - ICON_SIZE / 2
  if reach <= 0 or dx * dx + dy * dy > reach * reach then return end
  self.iconsUsed = self.iconsUsed + 1
  local index = self.iconsUsed
  local icon = self.icons[index]
  if not icon then
    icon = self.frame:CreateTexture(nil, "OVERLAY")
    icon:SetWidth(ICON_SIZE)
    icon:SetHeight(ICON_SIZE)
    self.icons[index] = icon
  end
  local keys = self.iconKeys[index]
  if not keys then
    keys = {}
    self.iconKeys[index] = keys
  end
  local level = Map.SettlementLevel(area)
  if keys.type ~= area.type or keys.color ~= area.colorKey or keys.column ~= area.iconColumn
      or keys.level ~= level then
    local path, left, right, top, bottom, w, h = Map.GetIcon(area.type, area.colorKey, area.iconColumn, level)
    if not path then
      icon:Hide()
      return
    end
    icon:SetTexture(path)
    icon:SetTexCoord(left, right, top, bottom)
    local width, height = Map.FitIcon(ICON_SIZE, w, h)
    icon:SetWidth(width)
    icon:SetHeight(height)
    keys.type, keys.color, keys.column, keys.level = area.type, area.colorKey, area.iconColumn, level
  end
  icon:ClearAllPoints()
  icon:SetPoint("CENTER", self.frame, "CENTER", dx, -dy)
  icon:Show()
end

-- Bounding box of a records table, kept on it (records never change once built).
local function Bounds(records)
  local bounds = records.pandaConquestBounds
  if bounds then return bounds end
  bounds = { 1, 1, 0, 0 }
  local index = 1
  while index <= table.getn(records) do
    local record = records[index]
    if record[1] < bounds[1] then bounds[1] = record[1] end
    if record[2] < bounds[2] then bounds[2] = record[2] end
    if record[3] > bounds[3] then bounds[3] = record[3] end
    if record[4] > bounds[4] then bounds[4] = record[4] end
    index = index + 1
  end
  records.pandaConquestBounds = bounds
  return bounds
end

local function Overlaps(bounds, view)
  local radius = view.radius
  return (bounds[3] - view.x) * view.width > -radius
    and (bounds[1] - view.x) * view.width < radius
    and (bounds[4] - view.y) * view.height > -radius
    and (bounds[2] - view.y) * view.height < radius
end

function MinimapAreas:HideRest(fromPatch, fromIcon)
  local index = fromPatch
  while self.patches[index] do
    Hide(self.patches[index])
    index = index + 1
  end
  index = fromIcon
  while self.icons[index] do
    Hide(self.icons[index])
    index = index + 1
  end
end

function MinimapAreas:Clear()
  if self.used > 0 or self.iconsUsed > 0 then self:HideRest(1, 1) end
  self.used, self.iconsUsed, self.mapKey, self.lastX = 0, 0, nil, nil
end

function MinimapAreas:Layout(view)
  self.used, self.iconsUsed = 0, 0
  self.pending = false
  local mapKey, order = view.mapKey, Map.order
  local index = 1
  while index <= table.getn(order) do
    local area = Map.areas[order[index]]
    if area and area.enabled and area.mapKey == mapKey then
      local records = Map:GetAreaRecords(area)
      if records and Overlaps(Bounds(records), view) then
        local color = area.color or Map.COLORS.NEUTRAL
        local total = table.getn(records)
        local recordIndex = 1
        while recordIndex <= total do
          PlaceRecord(self, records[recordIndex], view, color)
          recordIndex = recordIndex + 1
        end
      elseif not records then
        self.pending = true
      end
      if Map.POI_ICON_ROWS[area.type] then PlaceIcon(self, area, view) end
    end
    index = index + 1
  end
  self:HideRest(self.used + 1, self.iconsUsed + 1)
end

-- Scratch table reused on every tick: no allocation while the player moves.
local view = {}

function MinimapAreas:Tick(elapsed)
  self.elapsed = self.elapsed + (elapsed or 0)
  if self.elapsed < UPDATE_INTERVAL then return end
  self.sinceLayout = self.sinceLayout + self.elapsed
  self.elapsed = 0
  local minimap = self.minimap
  if not Map.enabled or Map:Locked() or not minimap then
    self:Clear()
    return
  end

  local mapFile, x, y = ReadPlayer()
  if not mapFile then
    -- A windowed world map browsing another zone keeps the last drawing.
    if not WorldMapShown() then self:Clear() end
    return
  end
  if mapFile ~= self.mapFile then
    self.mapFile = mapFile
    self.fileKey = Map.CanonicalMapName(mapFile)
  end
  local zone = self.fileKey and Map.ROUTE_ZONES[self.fileKey]
  local zoom = type(minimap.GetZoom) == "function" and minimap:GetZoom() or 0
  if self.indoorDirty or zoom ~= self.zoom then
    self.indoor = ReadIndoor(zoom)
    self.indoorDirty = false
  end
  local yards = (self.indoor and INDOOR_YARDS or OUTDOOR_YARDS)[zoom + 1]
  local size = minimap:GetWidth()
  if not zone or not yards or type(size) ~= "number" or size <= 0 then
    self:Clear()
    return
  end

  local scale = size / yards
  local width, height = (zone[1] - zone[2]) * scale, (zone[3] - zone[4]) * scale
  local moved = self.lastX and math.max(math.abs(x - self.lastX) * width,
    math.abs(y - self.lastY) * height) or MOVE_PIXELS
  if self.mapKey == self.fileKey and zoom == self.zoom and size == self.size
      and moved < MOVE_PIXELS and not self.pending and self.revision == Map.revision
      and self.sinceLayout < REFRESH_INTERVAL then
    return
  end

  self.mapKey, self.zoom, self.size, self.revision = self.fileKey, zoom, size, Map.revision
  self.lastX, self.lastY, self.sinceLayout = x, y, 0
  view.mapKey, view.x, view.y = self.fileKey, x, y
  view.width, view.height, view.radius = width, height, size / 2 - EDGE_INSET
  self:Layout(view)
end

function MinimapAreas:GetStatus()
  return { patches = self.used, icons = self.iconsUsed, zone = self.mapKey, indoor = self.indoor }
end

MinimapAreas:Create()
