PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Button = {}

PC.MinimapButton = Button

-- Minimap button opening the main window (modules/main_window.lua). Dragged
-- around the minimap edge (circle or square, following PandaUI's setting);
-- its angle in degrees is saved in
-- PandaConquestDB.settings.minimapAngle. The 1.12 globals cos, sin and atan2
-- work in degrees.
local NAME = "PandaConquestMinimapButton"
local DEFAULT_ANGLE = 200
local RADIUS = 80
local FRAME_SIZE = 33
local ICON_SIZE = 24
local HIGHLIGHT = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"

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

-- PandaUI owns the optional circle/square minimap setting; the standard
-- GetMinimapShape() hook of other minimap addons is the fallback. Anything
-- unknown stays round.
function Button:IsSquare()
  local pandaUI = GetGlobal("PandaUI")
  if type(pandaUI) == "table" and type(pandaUI.MinimapIsSquare) == "function" then
    local ok, square = pcall(pandaUI.MinimapIsSquare)
    if ok then return square == true end
  end
  local shape = GetGlobal("GetMinimapShape")
  if type(shape) == "function" then
    local ok, name = pcall(shape)
    return ok and name == "SQUARE"
  end
  return false
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
  local c, s = cos(angle), sin(angle)
  local reach = RADIUS
  self.square = self:IsSquare()
  if self.square then
    -- Ride the square edge: scale the direction until its larger axis reaches it.
    local longest = math.max(math.abs(c), math.abs(s))
    if longest > 0 then reach = RADIUS / longest end
  end
  frame:SetPoint("CENTER", minimap, "CENTER", reach * c, reach * s)
end

-- The circle/square setting can change while playing: re-place on a change.
local function OnShapeWatch()
  Button.shapeElapsed = (Button.shapeElapsed or 0) + (arg1 or 0)
  if Button.shapeElapsed < 1 then return end
  Button.shapeElapsed = 0
  if Button.frame and Button:IsSquare() ~= Button.square then Button:Place(Button:Angle()) end
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
  frame:SetWidth(FRAME_SIZE)
  frame:SetHeight(FRAME_SIZE)
  frame:SetFrameStrata("MEDIUM")
  frame:SetFrameLevel(minimap:GetFrameLevel() + 8)

  -- The crossed-swords emblem; pushed while held, native blue highlight on hover.
  local skin = PC.Skin
  local icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetWidth(ICON_SIZE)
  icon:SetHeight(ICON_SIZE)
  icon:SetPoint("CENTER", frame, "CENTER", 0, 0)
  if skin then
    skin:Apply(icon, "minimap.normal")
  end
  frame:SetHighlightTexture(HIGHLIGHT)
  self.icon = icon

  frame:RegisterForClicks("LeftButtonUp")
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnMouseDown", function() if PC.Skin then PC.Skin:Apply(Button.icon, "minimap.pushed") end end)
  frame:SetScript("OnMouseUp", function() if PC.Skin then PC.Skin:Apply(Button.icon, "minimap.normal") end end)
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
  local watcher = create("Frame", NAME .. "ShapeWatch", frame)
  if watcher then
    watcher:SetScript("OnUpdate", OnShapeWatch)
    self.watcher = watcher
  end
  return frame
end

function Button:OnClick()
  if PC.MainWindow and PC.MainWindow.Toggle then PC.MainWindow:Toggle() end
end

-- After ADDON_LOADED: the saved angle and the faction are known.
if PC.RegisterEvent then
  PC.RegisterEvent("PLAYER_LOGIN", function() Button:Build() end)
end
