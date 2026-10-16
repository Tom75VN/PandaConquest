PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Capture = PC.Capture
local HUD = {}

PC.CaptureHUD = HUD

-- Top-of-screen capture bar shown while the player stands in an OUTPOST, plus
-- the alert sent to the defending faction (docs/capture.md, Affichage).
local UPDATE_INTERVAL = 0.1
local WIDTH = 280
local BAR_WIDTH = 240
local BAR_HEIGHT = 12
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local COLORS = {
  H = { 0.90, 0.12, 0.08 },
  A = { 0.10, 0.42, 1.00 },
  N = { 0.45, 0.45, 0.45 },
}

local function GetGlobal(name)
  if getglobal then return getglobal(name) end
  if _G then return _G[name] end
  return nil
end

local function FactionName(code)
  return Capture and Capture.FACTION_NAMES[code] or tostring(code)
end

local function AreaName(area)
  return tostring(area.label or area.id)
end

local function Clock(seconds)
  seconds = math.floor(seconds + 0.5)
  local minutes = math.floor(seconds / 60)
  local rest = seconds - minutes * 60
  if rest < 10 then return minutes .. ":0" .. rest end
  return minutes .. ":" .. rest
end

local function NewText(frame, template, point, y)
  local text = frame:CreateFontString(nil, "OVERLAY", template)
  text:SetPoint(point, frame, point, 0, y)
  text:SetWidth(WIDTH - 12)
  return text
end

local function NewFill(bar, color)
  local texture = bar:CreateTexture(nil, "ARTWORK")
  texture:SetTexture(BAR_TEXTURE)
  texture:SetVertexColor(color[1], color[2], color[3], 1)
  texture:SetHeight(BAR_HEIGHT)
  return texture
end

function HUD:Build()
  if self.frame then return self.frame end
  local create = GetGlobal("CreateFrame")
  if type(create) ~= "function" then return nil end
  local ok, frame = pcall(create, "Frame", "PandaConquestCaptureHUD", UIParent)
  if not ok or not frame then return nil end
  frame:SetWidth(WIDTH)
  frame:SetHeight(70)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -70)

  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetTexture(0, 0, 0, 0.55)
  background:SetAllPoints(frame)

  self.title = NewText(frame, "GameFontNormal", "TOP", -6)
  self.mode = NewText(frame, "GameFontHighlightSmall", "TOP", -40)
  self.info = NewText(frame, "GameFontHighlightSmall", "TOP", -53)

  local bar = create("Frame", nil, frame)
  bar:SetWidth(BAR_WIDTH)
  bar:SetHeight(BAR_HEIGHT)
  bar:SetPoint("TOP", frame, "TOP", 0, -23)
  self.bar = bar
  self.neutral = NewFill(bar, COLORS.N)
  self.neutral:SetAllPoints(bar)
  self.horde = NewFill(bar, COLORS.H)
  self.horde:SetPoint("LEFT", bar, "LEFT", 0, 0)
  self.alliance = NewFill(bar, COLORS.A)
  self.alliance:SetPoint("RIGHT", bar, "RIGHT", 0, 0)

  self.warning = NewText(frame, "GameFontHighlightSmall", "BOTTOM", -14)
  self.warning:SetTextColor(1, 0.35, 0.35)

  frame:Hide()
  self.frame = frame
  return frame
end

local function SetFill(texture, fraction)
  if fraction <= 0.001 then
    texture:Hide()
    return
  end
  texture:SetWidth(math.max(1, BAR_WIDTH * math.min(1, fraction)))
  texture:Show()
end

-- Horde share fills from the left, Alliance from the right, grey in between.
function HUD.Shares(view)
  local p = view.progress / 1000
  if view.owner == "H" then
    local alliance = view.challenger == "A" and p or 0
    return 1 - alliance, alliance
  elseif view.owner == "A" then
    local horde = view.challenger == "H" and p or 0
    return horde, 1 - horde
  end
  return view.challenger == "H" and p or 0, view.challenger == "A" and p or 0
end

-- An outdated addon (core/version.lua) is announced on entering each POI, as
-- Overlord does on entering a front, and stays on the warning line.
function HUD:VersionNotice(data)
  local version = PC.Version
  if not data then
    self.enteredId = nil
    return nil
  end
  if not version or not version.newest then return nil end
  if self.enteredId ~= data.id then
    self.enteredId = data.id
    self:Alert(version:Text())
  end
  return version:Notice()
end

function HUD:Update()
  local data = Capture and (Capture:GetHud() or (PC.Hunting and PC.Hunting:GetHud()))
  local notice = self:VersionNotice(data)
  local frame = self.frame or (data and self:Build())
  if not frame then return end
  if not data then
    frame:Hide()
    return
  end
  local view = data.view
  local owner = view and view.owner or Capture:GetOwner(data.id)
  self.title:SetText(AreaName(data.area) .. " - " .. FactionName(owner))

  if data.hunting then
    -- Kills move the bar; there is no presence count or countdown.
    local horde, alliance = HUD.Shares(view)
    SetFill(self.horde, horde)
    SetFill(self.alliance, alliance)
    self.mode:SetText(PC.Hunting:ModeText(view))
    self.info:SetText(data.known and "Kill the required creatures"
      or "Waiting for the hunting ground state...")
    if data.warning or notice then
      self.warning:SetText(data.warning or notice)
      self.warning:Show()
    else
      self.warning:Hide()
    end
    frame:Show()
    return
  end

  if view then
    local horde, alliance = HUD.Shares(view)
    SetFill(self.horde, horde)
    SetFill(self.alliance, alliance)
    local percent = ""
    if view.challenger ~= "-" then
      percent = " - " .. FactionName(view.challenger) .. " " .. math.floor(view.progress / 10) .. "%"
    end
    self.mode:SetText(Capture:ModeText(view) .. percent)
    local info = "H " .. view.nH .. "  A " .. view.nA
    if data.remaining then info = info .. "  -  " .. Clock(data.remaining) end
    self.info:SetText(info)
  else
    SetFill(self.horde, owner == "H" and 1 or 0)
    SetFill(self.alliance, owner == "A" and 1 or 0)
    self.mode:SetText("Waiting for the outpost state...")
    self.info:SetText("")
  end

  if data.status == "NC" or not data.status then
    self.warning:SetText("You are not counted: " .. tostring(data.reason or "unknown"))
    self.warning:Show()
  elseif notice then
    self.warning:SetText(notice)
    self.warning:Show()
  else
    self.warning:Hide()
  end
  frame:Show()
end

function HUD:Alert(text)
  if PC.Print then PC.Print(text) end
  local shown = false
  local raidFrame = GetGlobal("RaidWarningFrame")
  if raidFrame and type(raidFrame.AddMessage) == "function" then
    shown = pcall(raidFrame.AddMessage, raidFrame, text, 1.0, 0.28, 0.0)
  end
  if not shown then
    local errors = GetGlobal("UIErrorsFrame")
    if errors and type(errors.AddMessage) == "function" then
      pcall(errors.AddMessage, errors, text, 1.0, 0.28, 0.0)
    end
  end
  local sound = GetGlobal("PlaySound")
  if type(sound) == "function" then pcall(sound, "RaidWarning") end
end

function HUD:OnCaptureEvent(kind, id, side)
  local area = Capture:Capturable(id)
  if not area then return end
  local where = AreaName(area) .. " (" .. tostring(area.map) .. ")"
  if kind == "ALERT" then
    self:Alert("The " .. FactionName(side) .. " is attacking " .. where .. "!")
  elseif kind == "CAPTURED" and PC.Print then
    PC.Print("The " .. FactionName(side) .. " captured " .. where .. ".")
  end
end

if Capture then
  Capture:OnEvent(function(kind, id, side) HUD:OnCaptureEvent(kind, id, side) end)
end

local create = GetGlobal("CreateFrame")
if type(create) == "function" then
  local ok, driver = pcall(create, "Frame", "PandaConquestCaptureHUDDriver", UIParent)
  if ok and driver and type(driver.SetScript) == "function" then
    driver:SetScript("OnUpdate", function()
      local now = PC.Now and PC.Now() or 0
      if type(now) ~= "number" or (HUD.lastAt and now - HUD.lastAt < UPDATE_INTERVAL) then return end
      HUD.lastAt = now
      local updated, err = pcall(HUD.Update, HUD)
      if not updated and PC.RecordError then PC.RecordError("capture HUD", err) end
    end)
    HUD.driver = driver
  end
end
