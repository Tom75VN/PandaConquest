PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Window = { tabs = {}, order = {}, rows = {}, tabButtons = {}, offset = 0, elapsed = 0 }

PC.MainWindow = Window

-- Main gameplay window (roadmap WP11, docs/architecture.md). A tab only returns
-- rows; the window draws them in a fixed pool, once per second while shown.
-- A later work package adds its own tab with Window:AddTab. A local view: it
-- sends nothing itself; a confirmed donation goes through PC.Garrison.
local NAME = "PandaConquestMainWindow"
local WIDTH = 520
local ROWS = 20
local ROW_HEIGHT = 16
local LIST_TOP = -68
local LEFT_WITH_RIGHT = 230
local BUTTON_WIDTH = 38
local BUTTONS_PER_ROW = 2
local TAB_WIDTH = 104
local REFRESH_INTERVAL = 1
local COLORS = {
  H = "e64033", A = "408cff", N = "b3b3b3",
  GOOD = "4dff4d", BAD = "ff5959", DIM = "999999", GOLD = "ffd100",
}
local RESOURCE_NAMES = { gold = "Gold", wood = "Wood", food = "Food" }
local SOURCE_LABELS = {
  LOCAL = "seen by you",
  PEER = "reported by players, unverified",
  STATIC = "no capture known",
}
local TERRITORY_TYPES = { OUTPOST = true, HUNTING_GROUNDS = true, SETTLEMENT = true }

Window.ROWS = ROWS

local function GetGlobal(name)
  if getglobal then return getglobal(name) end
  if _G then return _G[name] end
  return nil
end

local function Now()
  return PC.Now and PC.Now() or 0
end

local function Paint(color, text)
  return "|cff" .. (COLORS[color] or COLORS.N) .. tostring(text) .. "|r"
end

local function FactionText(code)
  local names = PC.Capture and PC.Capture.FACTION_NAMES
  return Paint(code, names and names[code] or tostring(code))
end

local function Duration(seconds)
  seconds = math.ceil(seconds)
  if seconds < 60 then return seconds .. "s" end
  return string.format("%dm %02ds", math.floor(seconds / 60), math.mod(seconds, 60))
end

local function AreaTitle(area)
  local names = PC.Map and PC.Map.TYPE_NAMES
  local typeName = names and names[area.type] or tostring(area.type)
  return tostring(area.label or area.id) .. " " .. Paint("DIM", "(" .. typeName .. ", " .. tostring(area.map) .. ")")
end

local function Row(rows, left, right, buttons)
  table.insert(rows, { left = left, right = right, buttons = buttons })
end

local function Header(rows, text)
  Row(rows, Paint("GOLD", text))
end

-- Tabs ------------------------------------------------------------------------

-- rows(now) returns a list of { left, right, buttons }, each button
-- { label, fn, a, b } calling fn(Window, a, b) on click. enabled(now), when
-- given, greys the tab out while it returns false.
function Window:AddTab(key, title, rows, enabled)
  if type(key) ~= "string" or self.tabs[key] or type(rows) ~= "function" then return false end
  if enabled ~= nil and type(enabled) ~= "function" then return false end
  self.tabs[key] = { key = key, title = title, rows = rows, enabled = enabled }
  table.insert(self.order, key)
  if not self.selected then self.selected = key end
  if self.frame then self:BuildTabs() end
  return true
end

function Window.ResourceRows(now)
  local rows = {}
  local economy = PC.Economy
  local wallet = economy and economy:Wallet()
  Header(rows, "Your resources")
  if not wallet then
    Row(rows, "  " .. Paint("BAD", "Unavailable: no saved data or identity yet"))
  else
    local index = 1
    while index <= table.getn(economy.RESOURCES) do
      local resource = economy.RESOURCES[index]
      local cap = economy.CAPS[resource]
      local full = wallet[resource] >= cap and Paint("BAD", " full") or ""
      Row(rows, "  " .. RESOURCE_NAMES[resource], wallet[resource] .. " / " .. cap .. full)
      index = index + 1
    end
  end
  local stock = PC.Stock
  local hud = stock and stock:GetHud(now)
  Header(rows, "Gathering")
  if hud then
    Row(rows, "  " .. AreaTitle(hud.area), hud.resource.level .. " / " .. hud.resource.capacity)
    if hud.status == "IN" then
      Row(rows, "  " .. Paint("GOOD", "Gathering " .. stock.GATHER_AMOUNT .. " " .. hud.resource.resource
        .. " every " .. stock.GATHER_TICK .. "s"))
    else
      Row(rows, "  " .. Paint("BAD", "Not gathering: " .. tostring(hud.reason or "checking")))
    end
    Row(rows, "  " .. hud.resource.status)
  else
    Row(rows, "  " .. Paint("DIM", "Stand in a Gold Mine, Farm or Forest to gather, PvP flag on"))
  end
  local map = PC.Map
  if not stock or not map then return rows end
  Header(rows, "Resource stocks")
  local index = 1
  while index <= table.getn(map.order) do
    local id = map.order[index]
    local area = stock:Resource(id)
    local view = area and stock:View(id, now)
    if view then
      Row(rows, "  " .. AreaTitle(area), view.level .. " / " .. view.capacity
        .. (view.known and "" or Paint("DIM", " not observed")))
    end
    index = index + 1
  end
  return rows
end

function Window.ArmyRows(now)
  local rows = {}
  local army = PC.Army
  local reserve = army and army:Reserve()
  local wallet = PC.Economy and PC.Economy:Wallet()
  Header(rows, "Reserve")
  if not reserve or not wallet then
    Row(rows, "  " .. Paint("BAD", "Unavailable: no saved data or identity yet"))
    return rows
  end
  local used = army:Used(reserve)
  Row(rows, "  Unit Size used", used .. " / " .. army.RESERVE_CAPACITY
    .. (used >= army.RESERVE_CAPACITY and Paint("BAD", " full") or ""))
  local area, where = army:Place()
  if area then
    Row(rows, "  " .. Paint("GOOD", "Recruitment open: ") .. AreaTitle(area))
  else
    Row(rows, "  " .. Paint("BAD", "Recruitment closed: ") .. where)
  end
  Row(rows, "  " .. Paint("DIM", "You have " .. wallet.gold .. " gold, " .. wallet.wood .. " wood, "
    .. wallet.food .. " food. Costs are paid at recruitment."))
  Header(rows, "Units")
  local index = 1
  while index <= table.getn(army.ORDER) do
    local key = army.ORDER[index]
    local unit = army.UNITS[key]
    local stats = unit.scout and "scout, never fights" or ("ATK " .. unit.atk .. " DEF " .. unit.def)
    Row(rows, "  " .. army:Name(key) .. " x" .. reserve[key],
      unit.gold .. " gold " .. unit.wood .. " wood " .. unit.food .. " food",
      { { label = "+1", fn = Window.Recruit, a = key, b = 1 }, { label = "+5", fn = Window.Recruit, a = key, b = 5 } })
    Row(rows, "    " .. Paint("DIM", "Unit Size " .. unit.size .. ", " .. stats .. ", up to "
      .. army:MostAffordable(key, reserve, wallet) .. " now"))
    index = index + 1
  end
  return rows
end

function Window.TerritoryRows(now)
  local rows = {}
  local map, capture = PC.Map, PC.Capture
  Header(rows, "Territory held")
  if not map or not capture then
    Row(rows, "  " .. Paint("BAD", "Unavailable: map or capture not loaded"))
    return rows
  end
  local counts = { H = 0, A = 0, N = 0 }
  local list = {}
  local index = 1
  while index <= table.getn(map.order) do
    local id = map.order[index]
    local area = map.areas[id]
    if area and area.enabled and TERRITORY_TYPES[area.type] then
      local owner, _, source = capture:GetOwner(id)
      local info = capture:TooltipInfo(id, now)
      local label = "not capturable yet"
      if capture:Capturable(id) then
        counts[owner] = (counts[owner] or 0) + 1
        label = SOURCE_LABELS[source] or tostring(source)
      end
      Row(list, "  " .. AreaTitle(area), FactionText(owner) .. " " .. Paint("DIM", label))
      if info and info.hint then
        Row(list, "    " .. Paint("DIM", "Unconfirmed: ") .. FactionText(info.hint.owner) .. Paint("DIM", ", "
          .. info.hint.count .. " player(s), " .. Duration(info.hint.age) .. " ago"))
      end
      if info and info.challenger then
        local text = "    Capture by " .. FactionText(info.challenger) .. " " .. info.percent .. "%"
        if info.status then
          text = text .. ", " .. info.status .. (info.remaining and (" (" .. Duration(info.remaining) .. ")") or "")
        end
        Row(list, text)
      end
    end
    index = index + 1
  end
  Row(rows, "  " .. FactionText("H") .. " " .. counts.H .. "    " .. FactionText("A") .. " " .. counts.A
    .. "    " .. FactionText("N") .. " " .. counts.N)
  Row(rows, "  " .. Paint("DIM", "What this client saw or was told; reports are not verified."))
  Header(rows, "Points of interest")
  index = 1
  while index <= table.getn(list) do
    table.insert(rows, list[index])
    index = index + 1
  end
  return rows
end

-- The Settlement tab only opens while the player stands in a Settlement.
function Window.InSettlement()
  local area = PC.Presence and PC.Presence.current
  return area ~= nil and area.type == "SETTLEMENT"
end

local function DonateButtons(kind, small, large)
  return { { label = "+" .. small, fn = Window.AskDonate, a = kind, b = small },
    { label = "+" .. large, fn = Window.AskDonate, a = kind, b = large } }
end

-- Garrison, level and upgrade fund of the place the player stands in
-- (modules/garrison.lua). A donation asks for confirmation first: it is
-- irreversible.
function Window.GarrisonRows(now)
  local rows = {}
  local garrison = PC.Garrison
  local area = PC.Presence and PC.Presence.current
  local view = garrison and area and garrison:View(area.id, now)
  if not view then
    Header(rows, "Settlement")
    Row(rows, "  " .. Paint("DIM", "Stand in a Settlement to see its garrison, level and upgrade fund"))
    return rows
  end
  Header(rows, AreaTitle(view.area))
  local confirm = Window.confirm
  if confirm and confirm.id == view.id then
    Row(rows, "  " .. Paint("GOLD", "Give " .. confirm.count .. " " .. garrison:Name(confirm.kind, view.owner)
      .. "? It can never be taken back."), nil,
      { { label = "Yes", fn = Window.Donate }, { label = "No", fn = Window.CancelDonate } })
  end
  local pending = garrison:Pending()
  if pending and pending.id == view.id then
    Row(rows, "  " .. Paint("DIM", "Waiting for the garrison keeper to accept " .. pending.count .. " "
      .. garrison:Name(pending.kind, pending.owner)))
  end
  Row(rows, "  Held by", FactionText(view.owner))
  if view.settlement then Row(rows, "  Level", view.level .. " / 3") end
  Row(rows, "  Garrison", view.used .. " / " .. view.capacity .. " Unit Size"
    .. (view.used >= view.capacity and Paint("BAD", " full") or ""))
  Row(rows, "  Defense", tostring(view.defense))
  local closed = garrison:Closed(view.area, now)
  local reserve = PC.Army and PC.Army:Reserve()
  local wallet = PC.Economy and PC.Economy:Wallet()
  Header(rows, "Garrison units")
  local index = 1
  while index <= table.getn(garrison.UNIT_ORDER) do
    local key = garrison.UNIT_ORDER[index]
    Row(rows, "  " .. garrison:Name(key, view.owner),
      "x" .. view[key] .. (reserve and Paint("DIM", "  you have " .. reserve[key]) or ""),
      not closed and DonateButtons(key, 1, 5) or nil)
    index = index + 1
  end
  if view.settlement then
    Header(rows, "Upgrade fund")
    Row(rows, "  Gold", view.gold .. (view.nextGold and (" / " .. view.nextGold) or "")
      .. (wallet and Paint("DIM", "  you have " .. wallet.gold) or ""), not closed and DonateButtons("gold", 100, 500) or nil)
    Row(rows, "  Wood", view.wood .. (view.nextWood and (" / " .. view.nextWood) or "")
      .. (wallet and Paint("DIM", "  you have " .. wallet.wood) or ""), not closed and DonateButtons("wood", 50, 100) or nil)
    if view.nextGold then
      Row(rows, "  " .. Paint("DIM", "Level " .. (view.level + 1) .. " once both are reached: garrison capacity "
        .. view.nextCapacity))
    else
      Row(rows, "  " .. Paint("GOOD", "Maximum level reached"))
    end
  end
  Header(rows, "Donations")
  if closed then
    Row(rows, "  " .. Paint("BAD", "Closed: ") .. closed)
  else
    Row(rows, "  " .. Paint("GOOD", "Open: ") .. "what you give can never be taken back")
  end
  local last = garrison.last
  if last then Row(rows, "  " .. Paint(last.ok and "GOOD" or "BAD", last.text)) end
  Row(rows, "  " .. Paint("DIM", "Garrison data: " .. view.source .. "."))
  return rows
end

function Window:AskDonate(kind, count)
  local area = PC.Presence and PC.Presence.current
  self.confirm = area and { id = area.id, kind = kind, count = count } or nil
  self:SetStatus(nil)
  self:Refresh()
end

function Window:CancelDonate()
  self.confirm = nil
  self:SetStatus("Donation cancelled", "DIM")
  self:Refresh()
end

-- Donates with the reserve's current donation number, so one confirmation
-- donates once (modules/garrison.lua, Garrison:Donate).
function Window:Donate()
  local confirm = self.confirm
  self.confirm = nil
  local garrison = PC.Garrison
  local area = PC.Presence and PC.Presence.current
  local reserve = PC.Army and PC.Army:Reserve()
  local ok, result = false, "no saved data or identity yet"
  if not confirm or not area or area.id ~= confirm.id then
    result = "you are no longer in the same place"
  elseif garrison and reserve then
    ok, result = garrison:Donate(confirm.kind, confirm.count, reserve.gop)
  end
  if ok and result == "sent" then
    self:SetStatus("Donation sent: waiting for the garrison keeper", "GOOD")
  elseif ok then
    self:SetStatus("Donated " .. confirm.count .. " " .. garrison:Name(confirm.kind, garrison:View(confirm.id).owner), "GOOD")
  else
    self:SetStatus("Donation refused: " .. tostring(result), "BAD")
  end
  self:Refresh()
  return ok
end

-- Recruits through PC.Army with the reserve's current operation number, so one
-- click recruits once (modules/army.lua, Army:Recruit).
function Window:Recruit(key, count)
  local army = PC.Army
  local reserve = army and army:Reserve()
  local ok, reason = false, "no saved data or identity yet"
  if reserve then ok, reason = army:Recruit(key, count, reserve.op) end
  if ok then
    self:SetStatus("Recruited " .. count .. " " .. army:Name(key) .. ", reserve " .. army:Used(reserve)
      .. " / " .. army.RESERVE_CAPACITY, "GOOD")
  else
    self:SetStatus("Recruitment refused: " .. tostring(reason), "BAD")
  end
  self:Refresh()
  return ok
end

-- Frame -----------------------------------------------------------------------

local function NewText(frame, template)
  local text = frame:CreateFontString(nil, "OVERLAY", template)
  text:SetJustifyH("LEFT")
  return text
end

function Window:BuildTabs()
  local frame = self.frame
  local create = GetGlobal("CreateFrame")
  local index = table.getn(self.tabButtons) + 1
  while index <= table.getn(self.order) do
    local button = create("Button", NAME .. "Tab" .. index, frame, "UIPanelButtonTemplate")
    button:SetWidth(TAB_WIDTH - 4)
    button:SetHeight(22)
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", 18 + (index - 1) * TAB_WIDTH, -36)
    button:SetText(self.tabs[self.order[index]].title)
    button.tabKey = self.order[index]
    button:SetScript("OnClick", function() Window:Select(this.tabKey) end)
    table.insert(self.tabButtons, button)
    index = index + 1
  end
end

function Window:BuildRow(index)
  local frame = self.frame
  local create = GetGlobal("CreateFrame")
  local y = LIST_TOP - (index - 1) * ROW_HEIGHT
  local slot = { left = NewText(frame, "GameFontHighlightSmall"), right = NewText(frame, "GameFontHighlightSmall"),
    buttons = {}, y = y }
  slot.left:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, y)
  slot.right:SetJustifyH("RIGHT")
  local column = 1
  while column <= BUTTONS_PER_ROW do
    local button = create("Button", NAME .. "Row" .. index .. "Button" .. column, frame, "UIPanelButtonTemplate")
    button:SetWidth(BUTTON_WIDTH)
    button:SetHeight(16)
    button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20 - (BUTTONS_PER_ROW - column) * (BUTTON_WIDTH + 2), y + 2)
    button:SetScript("OnClick", function() Window:Click(this) end)
    button:Hide()
    slot.buttons[column] = button
    column = column + 1
  end
  self.rows[index] = slot
end

function Window:Build()
  if self.frame then return self.frame end
  local create = GetGlobal("CreateFrame")
  if type(create) ~= "function" then return nil end
  local ok, frame = pcall(create, "Frame", NAME, UIParent)
  if not ok or not frame then return nil end
  self.frame = frame
  frame:SetWidth(WIDTH)
  frame:SetHeight(-LIST_TOP + ROWS * ROW_HEIGHT + 40)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() this:StartMoving() end)
  frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function() Window:Scroll(arg1) end)
  frame:SetScript("OnShow", function() Window:Refresh() end)
  frame:SetScript("OnUpdate", function() Window:OnUpdate(arg1) end)

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", frame, "TOP", 0, -16)
  title:SetText("|cffffffffPanda |cfff5ae0aConquest|r")
  local close = create("Button", NAME .. "Close", frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)

  local index = 1
  while index <= ROWS do
    self:BuildRow(index)
    index = index + 1
  end
  self.status = NewText(frame, "GameFontHighlightSmall")
  self.status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 18)
  self.status:SetWidth(WIDTH - 140)
  self.page = NewText(frame, "GameFontDisableSmall")
  self.page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 18)
  self.page:SetJustifyH("RIGHT")
  self:BuildTabs()

  -- Escape closes the frames listed in UISpecialFrames (FrameXML UIParent.lua).
  local special = GetGlobal("UISpecialFrames")
  if type(special) == "table" then table.insert(special, NAME) end
  frame:Hide()
  return frame
end

function Window:Render(rows)
  local total = table.getn(rows)
  local most = total - ROWS
  if most < 0 then most = 0 end
  if self.offset > most then self.offset = most end
  if self.offset < 0 then self.offset = 0 end
  local index = 1
  while index <= ROWS do
    local slot = self.rows[index]
    local row = rows[self.offset + index] or {}
    local buttons = row.buttons and table.getn(row.buttons) or 0
    local right = row.right or ""
    slot.left:SetText(row.left or "")
    slot.left:SetWidth(right ~= "" and LEFT_WITH_RIGHT or WIDTH - 40)
    slot.right:SetText(right)
    slot.right:ClearAllPoints()
    slot.right:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -20 - buttons * (BUTTON_WIDTH + 2), slot.y)
    slot.right:SetWidth(WIDTH - 44 - LEFT_WITH_RIGHT - buttons * (BUTTON_WIDTH + 2))
    local column = 1
    while column <= BUTTONS_PER_ROW do
      local button = slot.buttons[column]
      -- Buttons are right-aligned: the last action takes the last column.
      local action = row.buttons and row.buttons[column - (BUTTONS_PER_ROW - buttons)]
      button.action = action
      if action then
        button:SetText(action.label)
        button:Show()
      else
        button:Hide()
      end
      column = column + 1
    end
    index = index + 1
  end
  if total > ROWS then
    local last = self.offset + ROWS
    self.page:SetText((self.offset + 1) .. "-" .. last .. " of " .. total .. ", scroll for more")
  else
    self.page:SetText("")
  end
end

function Window:Refresh()
  if not self.frame then return end
  local now = Now()
  local tab = self.tabs[self.selected]
  if tab and not self:TabEnabled(tab, now) then
    -- The place that opened this tab was left: back to the first tab.
    self.selected, self.offset, self.confirm = self.order[1], 0, nil
    tab = self.tabs[self.selected]
  end
  if not tab then return end
  local ok, rows = pcall(tab.rows, now)
  if not ok or type(rows) ~= "table" then
    if PC.RecordError then PC.RecordError("main window " .. tab.key, rows) end
    rows = { { left = Paint("BAD", "This tab failed: " .. tostring(rows)) } }
  end
  self:Render(rows)
  local index = 1
  while index <= table.getn(self.tabButtons) do
    local button = self.tabButtons[index]
    if button.tabKey == self.selected then button:LockHighlight() else button:UnlockHighlight() end
    button.tabEnabled = self:TabEnabled(self.tabs[button.tabKey], now)
    if button.tabEnabled then button:Enable() else button:Disable() end
    index = index + 1
  end
end

function Window:TabEnabled(tab, now)
  if not tab.enabled then return true end
  local ok, enabled = pcall(tab.enabled, now)
  return ok and enabled and true or false
end

function Window:OnUpdate(elapsed)
  self.elapsed = self.elapsed + (elapsed or 0)
  if self.elapsed < REFRESH_INTERVAL then return end
  self.elapsed = 0
  self:Refresh()
end

function Window:Scroll(delta)
  if type(delta) ~= "number" then return end
  if delta > 0 then self.offset = self.offset - 1 else self.offset = self.offset + 1 end
  self:Refresh()
end

function Window:Click(button)
  local action = button and button.action
  if action and type(action.fn) == "function" then action.fn(self, action.a, action.b) end
end

function Window:SetStatus(text, color)
  if self.status then self.status:SetText(text and Paint(color, text) or "") end
end

function Window:Select(key)
  if not self.tabs[key] or not self:TabEnabled(self.tabs[key], Now()) then return false end
  self.selected = key
  self.offset = 0
  self:SetStatus(nil)
  self:Refresh()
  return true
end

-- /pc and /pc ui
function Window:Toggle()
  local frame = self:Build()
  if not frame then
    PC.Print("the PandaConquest window is unavailable")
    return false
  end
  if frame:IsShown() then frame:Hide() else frame:Show() end
  return true
end

Window:AddTab("res", "Resources", Window.ResourceRows)
Window:AddTab("army", "Army", Window.ArmyRows)
Window:AddTab("map", "Territory", Window.TerritoryRows)
Window:AddTab("settlement", "Settlement", Window.GarrisonRows, Window.InSettlement)
