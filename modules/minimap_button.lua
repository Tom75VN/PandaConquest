PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Button = {}

PC.MinimapButton = Button

-- Minimap button opening the main window (modules/main_window.lua). Dragged
-- around the minimap edge; its angle in degrees is saved in
-- PandaConquestDB.settings.minimapAngle. The 1.12 globals cos, sin and atan2
-- work in degrees.
local NAME = "PandaConquestMinimapButton"
local DEFAULT_ANGLE = 200
local RADIUS = 80
local FACTION_KEYS = { H = "HORDE", A = "ALLIANCE" }

Button.DEFAULT_ANGLE = DEFAULT_ANGLE

local function GetGlobal(name)
  if getglobal then return getglobal(name) end
  if _G then return _G[name] end
  return nil
end

local function Settings()
  local storage = PC.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" or type(db.settings) ~= "table" then return nil end
  return db.settings
end

function Button:Angle()
  local settings = Settings()
  local angle = settings and tonumber(settings.minimapAngle)
  if not angle or angle ~= angle or angle < 0 or angle >= 360 then return DEFAULT_ANGLE end
  return angle
end

function Button:Place(angle)
  local frame, minimap = self.frame, GetGlobal("Minimap")
  local cos, sin = GetGlobal("cos"), GetGlobal("sin")
  if not frame or not minimap then return end
  frame:ClearAllPoints()
  if type(cos) ~= "function" or type(sin) ~= "function" then
    frame:SetPoint("CENTER", minimap, "BOTTOMLEFT", 0, 0)
    return
  end
  frame:SetPoint("CENTER", minimap, "CENTER", RADIUS * cos(angle), RADIUS * sin(angle))
end

-- Angle of the cursor around the minimap centre, in [0, 360).
function Button:CursorAngle()
  local cursor, atan2, minimap = GetGlobal("GetCursorPosition"), GetGlobal("atan2"), GetGlobal("Minimap")
  if type(cursor) ~= "function" or type(atan2) ~= "function" or not minimap then return nil end
  local x, y = cursor()
  local scale = minimap:GetEffectiveScale()
  local cx, cy = minimap:GetCenter()
  if not x or not y or not cx or not cy or not scale or scale <= 0 then return nil end
  return math.mod(atan2(y / scale - cy, x / scale - cx) + 360, 360)
end

function Button:SetAngle(angle)
  if type(angle) ~= "number" or angle ~= angle then return end
  angle = math.mod(math.floor(angle + 0.5) + 360, 360)
  local settings = Settings()
  if settings then settings.minimapAngle = angle end
  self:Place(angle)
end

local function OnDragUpdate()
  Button:SetAngle(Button:CursorAngle())
end

function Button:ShowTooltip()
  local tooltip = GetGlobal("GameTooltip")
  if not tooltip or not self.frame then return end
  tooltip:SetOwner(self.frame, "ANCHOR_LEFT")
  tooltip:AddLine("|cffffffffPanda |cfff5ae0aConquest|r")
  tooltip:AddLine("Click: open or close the window", 1, 1, 1)
  tooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
  tooltip:Show()
end

function Button:Build()
  if self.frame then return self.frame end
  local create, minimap = GetGlobal("CreateFrame"), GetGlobal("Minimap")
  if type(create) ~= "function" or not minimap then return nil end
  local ok, frame = pcall(create, "Button", NAME, minimap)
  if not ok or not frame then return nil end
  self.frame = frame
  frame:SetWidth(31)
  frame:SetHeight(31)
  frame:SetFrameStrata("MEDIUM")
  frame:SetFrameLevel(minimap:GetFrameLevel() + 8)
  frame:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  -- The Outpost icon of the map atlas, in the player's faction colour.
  local map = PC.Map
  local icon = frame:CreateTexture(nil, "BACKGROUND")
  icon:SetWidth(20)
  icon:SetHeight(20)
  icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6)
  if map and map.POI_ICONS and type(map.GetIconTexCoord) == "function" then
    local faction = PC.Capture and PC.Capture:MyFaction()
    local coords = map.GetIconTexCoord("OUTPOST", FACTION_KEYS[faction or ""])
    icon:SetTexture(map.POI_ICONS.OUTPOST)
    icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
  end
  self.icon = icon
  local border = frame:CreateTexture(nil, "OVERLAY")
  border:SetWidth(52)
  border:SetHeight(52)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)

  frame:RegisterForClicks("LeftButtonUp")
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnClick", function() Button:OnClick() end)
  frame:SetScript("OnDragStart", function()
    this:LockHighlight()
    this:SetScript("OnUpdate", OnDragUpdate)
  end)
  frame:SetScript("OnDragStop", function()
    this:SetScript("OnUpdate", nil)
    this:UnlockHighlight()
  end)
  frame:SetScript("OnEnter", function() Button:ShowTooltip() end)
  frame:SetScript("OnLeave", function()
    local tooltip = GetGlobal("GameTooltip")
    if tooltip then tooltip:Hide() end
  end)
  self:Place(self:Angle())
  return frame
end

function Button:OnClick()
  if PC.MainWindow and PC.MainWindow.Toggle then PC.MainWindow:Toggle() end
end

-- After ADDON_LOADED: the saved angle and the faction are known.
if PC.RegisterEvent then
  PC.RegisterEvent("PLAYER_LOGIN", function() Button:Build() end)
end
