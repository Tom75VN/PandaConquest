PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Contours = PC.AreaContours
local Map = PC.Map
local Presence = {
  current = nil,
  listeners = {},
  samples = 0,
}

PC.Presence = Presence

-- Local presence only: which POI shape holds the player right now. Capture,
-- eligibility and P2P announcements (docs/capture.md) build on this later.
local SAMPLE_INTERVAL = 0.5
local Y_SCALE = 2 / 3

local function GetGlobal(name)
  if getglobal then return getglobal(name) end
  if _G then return _G[name] end
  return nil
end

local function Call(name, a, b)
  local fn = GetGlobal(name)
  if type(fn) ~= "function" then return false end
  return pcall(fn, a, b)
end

local function WorldMapShown()
  local frame = GetGlobal("WorldMapFrame")
  if not frame or type(frame.IsVisible) ~= "function" then return false end
  local ok, shown = pcall(frame.IsVisible, frame)
  return ok and shown and true or false
end

-- True when the selected map is a zone map holding the player.
local function OnZoneMap()
  local zoneOk, zoneIndex = Call("GetCurrentMapZone")
  if zoneOk and type(zoneIndex) == "number" and zoneIndex == 0 then return false end
  local posOk, x, y = Call("GetPlayerMapPosition", "player")
  return posOk and type(x) == "number" and type(y) == "number" and (x ~= 0 or y ~= 0)
end

-- After /reload, 1.12's SetMapToCurrentZone stops at the continent until the
-- player changes zone; select the zone by its name instead.
local function ZoomToZoneByName()
  local zoneOk, zoneName = Call("GetRealZoneText")
  local continentOk, continent = Call("GetCurrentMapContinent")
  local listZones = GetGlobal("GetMapZones")
  if not zoneOk or type(zoneName) ~= "string" or zoneName == ""
      or not continentOk or type(continent) ~= "number" or continent < 1
      or type(listZones) ~= "function" then
    return
  end
  local zones = { listZones(continent) }
  local index = 1
  while index <= table.getn(zones) do
    if zones[index] == zoneName then
      Call("SetMapZoom", continent, index)
      return
    end
    index = index + 1
  end
end

-- Reads the player's position on its own zone map, in percent (0..100) like
-- data/pois.lua. Returns nil with a reason when no zone position is available.
function Presence:ReadPosition()
  local mapShown = WorldMapShown()
  -- Re-centring the map while it is open would change the zone the user is
  -- browsing, so the open map is read as is. A closed map is re-centred only
  -- when it no longer shows the player's zone.
  if not mapShown and not OnZoneMap() then
    Call("SetMapToCurrentZone")
    if not OnZoneMap() then ZoomToZoneByName() end
  end

  local infoOk, mapFile = Call("GetMapInfo")
  if not infoOk or type(mapFile) ~= "string" or mapFile == "" then
    return nil, "no zone map"
  end
  local zoneOk, zoneIndex = Call("GetCurrentMapZone")
  if zoneOk and type(zoneIndex) == "number" and zoneIndex == 0 then
    return nil, "continent map shown"
  end

  local posOk, x, y = Call("GetPlayerMapPosition", "player")
  if not posOk or type(x) ~= "number" or type(y) ~= "number" then
    return nil, "GetPlayerMapPosition unavailable"
  end
  -- 0,0 means the player is not on the viewed map (instance, or another zone
  -- browsed on the open map).
  if x == 0 and y == 0 then
    return nil, mapShown and "player not on the viewed map" or "no position"
  end
  return { map = mapFile, x = x * 100, y = y * 100, mapShown = mapShown }
end

local function AreaCenter(area)
  if area.shape then return area.shape.x, area.shape.y end
  local points = area.controlVertices or area.vertices or area.locations
  local sumX, sumY, total = 0, 0, table.getn(points)
  local index = 1
  while index <= total do
    sumX = sumX + points[index].x
    sumY = sumY + points[index].y
    index = index + 1
  end
  return sumX / total, sumY / total
end

-- Every enabled POI of the zone that contains the point, topmost first (the
-- map draws later areas above earlier ones), and the nearest centre.
function Presence:FindAreas(mapFile, x, y)
  local found = {}
  local nearest, nearestDistance = nil, nil
  if not Map or not Contours or not Map.CanonicalMapName then return found end
  local mapKey = Map.CanonicalMapName(mapFile)
  local index = table.getn(Map.order)
  while index >= 1 do
    local area = Map.areas[Map.order[index]]
    if area and area.enabled and area.mapKey == mapKey then
      if Contours.AreaContainsPoint(area, x, y) then
        table.insert(found, area)
      end
      local cx, cy = AreaCenter(area)
      local dx, dy = x - cx, (y - cy) * Y_SCALE
      local distance = math.sqrt(dx * dx + dy * dy)
      if not nearestDistance or distance < nearestDistance then
        nearest, nearestDistance = area, distance
      end
    end
    index = index - 1
  end
  return found, nearest, nearestDistance
end

local function AreaName(area)
  return tostring(area.label or area.id)
end

function Presence:OnChange(callback)
  if type(callback) == "function" then table.insert(self.listeners, callback) end
end

function Presence:SetCurrent(area)
  local previous = self.current
  if previous == area then return end
  self.current = area
  -- No on-screen notice: the capture HUD shows when the player is in an outpost.
  if previous then
    if PC.Record then PC.Record("POI_EXIT", { id = previous.id, type = previous.type }) end
  end
  if area then
    if PC.Record then PC.Record("POI_ENTER", { id = area.id, type = area.type }) end
  end
  local index = 1
  while index <= table.getn(self.listeners) do
    local ok, err = pcall(self.listeners[index], area, previous)
    if not ok then PC.RecordError("presence listener", err) end
    index = index + 1
  end
end

function Presence:Sample()
  self.samples = self.samples + 1
  local position, reason = self:ReadPosition()
  self.position = position
  self.reason = reason
  if not position then
    -- An open map showing another zone says nothing about the player: keep
    -- the last state instead of reporting a false exit.
    if reason ~= "player not on the viewed map" and reason ~= "continent map shown" then
      self:SetCurrent(nil)
    end
    return
  end
  local found = self:FindAreas(position.map, position.x, position.y)
  self:SetCurrent(found[1])
end

function Presence:Tick()
  local now = PC.Now and PC.Now() or 0
  if type(now) ~= "number" or now <= 0 then return end
  if self.lastSampleAt and now - self.lastSampleAt < SAMPLE_INTERVAL then return end
  self.lastSampleAt = now
  self:Sample()
end

function Presence:PrintStatus()
  self:Sample()
  local position = self.position
  if not position then
    PC.Print("where: no position (" .. tostring(self.reason) .. ")")
    return
  end
  PC.Print(string.format("where: map=%s x=%.2f y=%.2f%s", position.map,
    position.x, position.y, position.mapShown and " (map open)" or ""))
  local found, nearest, distance = self:FindAreas(position.map, position.x, position.y)
  if table.getn(found) == 0 then
    PC.Print("where: not inside any POI")
  end
  local index = 1
  while index <= table.getn(found) do
    PC.Print("where: inside " .. AreaName(found[index]) .. " (" .. found[index].type .. ")")
    index = index + 1
  end
  if nearest then
    local size = nearest.shape and string.format(", radius %.2f", nearest.shape.radius) or ""
    PC.Print(string.format("where: nearest %s at %.2f%s", AreaName(nearest), distance, size))
  else
    PC.Print("where: no POI registered for this map")
  end
end

local create = GetGlobal("CreateFrame")
if type(create) == "function" then
  -- WorldFrame keeps ticking while the fullscreen map hides UIParent.
  local parent = GetGlobal("WorldFrame") or UIParent
  local frameOk, driver = pcall(create, "Frame", "PandaConquestPresenceDriver", parent)
  if frameOk and driver and type(driver.SetScript) == "function" then
    driver:SetScript("OnUpdate", function()
      local ok, err = pcall(Presence.Tick, Presence)
      if not ok and PC.RecordError then PC.RecordError("presence driver", err) end
    end)
    Presence.driver = driver
  elseif PC.RecordError then
    PC.RecordError("presence driver", "unable to create OnUpdate driver")
  end
end
