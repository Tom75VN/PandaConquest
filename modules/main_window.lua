PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Window = { tabs = {}, order = {}, tabButtons = {}, elapsed = 0 }

PC.MainWindow = Window

-- Main gameplay window (roadmap WP11, docs/architecture.md), textured with the
-- sprite atlas (modules/ui_skin.lua). Each tab is a page that builds its
-- widgets once and fills them once per second while shown, from the modules
-- that own the data. A local view: it sends nothing itself; a recruitment
-- goes through PC.Army, a confirmed pledge through PC.Garrison, a scout or a
-- confirmed attack through PC.Scout:Launch or PC.Attack:Launch. The classic
-- text window stays available as a backup (modules/main_window_classic.lua).
local NAME = "PandaConquestMainWindow"
local WIDTH = 640
local HEIGHT = 560
local CONTENT_LEFT = 16
local CONTENT_TOP = -98
local CONTENT_WIDTH = WIDTH - 2 * CONTENT_LEFT
local CONTENT_HEIGHT = 424
local GAP = 4
local REFRESH_INTERVAL = 1
-- The channel level of Capture:CanTalk (decision 0039).
local LOCK_LEVEL = 5
local FRAME_SCALE = 0.3
local ORNAMENT_SCALE = 0.42
local ALLIANCE_SCALE = 0.475
local HORDE_SCALE = 0.472
local TITLE_SCALE = 0.37
local COLORS = {
  H = "e64033", A = "408cff", N = "b3b3b3",
  GOOD = "4dff4d", BAD = "ff5959", DIM = "999999", GOLD = "ffd100", WHITE = "ffffff",
}
local RESOURCE_ORDER = { "gold", "wood", "food" }
local RESOURCE_NAMES = { gold = "Gold", wood = "Wood", food = "Food" }
local RESOURCE_FILLS = { gold = "gold", wood = "brown", food = "red" }
local TERRITORY_TYPES = { OUTPOST = true, HUNTING_GROUNDS = true, SETTLEMENT = true }
local SOURCE_DOTS = { LOCAL = "dot.green", PEER = "dot.yellow" }
local SOURCE_LABELS = {
  LOCAL = "Seen by you",
  PEER = "Reported by players",
  STATIC = "No capture known",
}
local UNIT_ICON_DIR = "Interface\\AddOns\\pandaConquest\\media\\Textures\\Icons\\War3Units\\"
local UNIT_ICONS = {
  FOOTMAN = { A = "BTNFootman", H = "BTNGrunt" },
  RIFLEMAN = { A = "BTNRifleman", H = "BTNHeadhunter" },
  MORTAR = { A = "BTNMortarTeam", H = "BTNDemolisher" },
  SCOUT = { A = "BTNKnight", H = "BTNRaider" },
}
-- Columns of MapPOIIconAtlas (Map.GetIcon) for an owner and a half challenger.
local POI_COLUMNS = { H = 2, A = 4 }
local POI_HALF_COLUMNS = { H = 1, A = 3 }

Window.CONTENT_HEIGHT = CONTENT_HEIGHT

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

local function FactionName(code)
  local names = PC.Capture and PC.Capture.FACTION_NAMES
  return names and names[code] or tostring(code)
end

local function FactionText(code)
  return Paint(code, FactionName(code))
end

local function Duration(seconds)
  seconds = math.ceil(seconds)
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return string.format("%dm %02ds", math.floor(seconds / 60), math.mod(seconds, 60)) end
  return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor(math.mod(seconds, 3600) / 60))
end

local function AreaName(area)
  return tostring(area.label or area.id)
end

local function AreaZone(area)
  return Paint("DIM", tostring(area.map or ""))
end

local function MyFaction()
  local faction = PC.Capture and PC.Capture:MyFaction()
  if faction == "H" or faction == "A" then return faction end
  return nil
end

local function OtherFaction(faction)
  if faction == "H" then return "A" end
  return "H"
end

-- Shows the same POI picture as the world map (MapPOIIconAtlas): type, owner
-- (H, A or N) and, while a challenger holds half the bar, the half state of
-- that challenger.
function Window.SetPoiIcon(texture, area, owner, challenger)
  local map = PC.Map
  if not texture or not area or not map or not map.GetIcon then return false end
  local column = POI_HALF_COLUMNS[challenger or ""] or POI_COLUMNS[owner or ""] or 0
  local level = map.SettlementLevel and map.SettlementLevel(area) or 1
  local path, left, right, top, bottom = map.GetIcon(area.type, nil, column, level)
  if not path then return false end
  texture:SetTexture(path)
  texture:SetTexCoord(left, right, top, bottom)
  return true
end

local function UnitIcon(texture, key, faction)
  local names = UNIT_ICONS[key]
  if not names then return end
  texture:SetTexture(UNIT_ICON_DIR .. (names[faction or "A"] or names.A))
  texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
end

local function Skin()
  return PC.Skin
end

-- Small widget helpers -----------------------------------------------------

local function Place(region, parent, x, y, point)
  region:ClearAllPoints()
  region:SetPoint(point or "TOPLEFT", parent, "TOPLEFT", x, y)
end

local function NewText(parent, template, x, y, width, justify)
  local text = Skin():Text(parent, template or "GameFontHighlightSmall", justify)
  Place(text, parent, x, y)
  if width then text:SetWidth(width) end
  if text.SetNonSpaceWrap then text:SetNonSpaceWrap(false) end
  text:SetHeight(14)
  return text
end

local function SetText(text, value)
  value = value or ""
  if text.value ~= value then
    text.value = value
    text:SetText(value)
  end
end

local function Show(region, shown)
  if shown then region:Show() else region:Hide() end
end

local function NewPanel(page, title, x, y, width, height)
  local panel = Skin():Panel(page.frame, title, width, height)
  Place(panel, page.frame, x, y)
  return panel
end

local function NewFrame(parent, width, height)
  local frame = GetGlobal("CreateFrame")("Frame", nil, parent)
  frame:SetWidth(width)
  frame:SetHeight(height)
  return frame
end

-- A list of `slots` pooled rows inside a panel, scrolled with the mouse wheel
-- over the panel. build(row, index) makes a row once; Fill(count, fill)
-- shows rows offset+1.. and calls fill(row, index).
local function NewList(panel, slots, rowHeight, top, build)
  local list = { panel = panel, rows = {}, slots = slots, offset = 0, count = 0 }
  local index = 1
  while index <= slots do
    local row = NewFrame(panel, panel.width - 12, rowHeight - 2)
    Place(row, panel, 6, top - (index - 1) * rowHeight)
    Skin():RowBackground(row, rowHeight - 2)
    build(row, index)
    list.rows[index] = row
    index = index + 1
  end
  panel:EnableMouseWheel(true)
  panel:SetScript("OnMouseWheel", function()
    if arg1 and arg1 > 0 then list.offset = list.offset - 1 else list.offset = list.offset + 1 end
    Window:Refresh()
  end)
  return list
end

local function FillList(list, count, fill)
  local most = count - list.slots
  if most < 0 then most = 0 end
  if list.offset > most then list.offset = most end
  if list.offset < 0 then list.offset = 0 end
  list.count = count
  local index = 1
  while index <= list.slots do
    local row = list.rows[index]
    local item = list.offset + index
    if item <= count then
      fill(row, item)
      row:Show()
    else
      row:Hide()
    end
    index = index + 1
  end
  if count > list.slots then
    SetText(list.panel.note, Paint("DIM", (list.offset + 1) .. "-" .. (list.offset + list.slots) .. " of " .. count .. ", scroll"))
  else
    SetText(list.panel.note, "")
  end
end

local function NewButton(parent, style, width, height, label, fn)
  local button = Skin():Button(parent, style, width, height, function(b)
    if b.action then b.action(Window, b.a, b.b) end
  end)
  button.action = fn
  Skin():SetButton(button, label, true)
  return button
end

local function SetAction(button, label, fn, a, b, enabled)
  button.action, button.a, button.b = fn, a, b
  Skin():SetButton(button, label, enabled ~= false and fn ~= nil)
end

-- Reused id lists: one per list, refilled on each refresh.
local function Collect(list, test)
  local count = 0
  local map = PC.Map
  local index = 1
  while map and index <= table.getn(map.order) do
    local id = map.order[index]
    if test(id) then
      count = count + 1
      list[count] = id
    end
    index = index + 1
  end
  local extra = count + 1
  while list[extra] do
    list[extra] = nil
    extra = extra + 1
  end
  return count
end

-- Tabs ------------------------------------------------------------------------

-- page = { Build = function(page) ... end, Update = function(page, now) ... end };
-- Build makes the widgets on page.frame once, Update fills them. enabled(now),
-- when given, greys the tab out while it returns false.
function Window:AddTab(key, title, page, enabled)
  if type(key) ~= "string" or self.tabs[key] or type(page) ~= "table" or type(page.Update) ~= "function" then
    return false
  end
  if enabled ~= nil and type(enabled) ~= "function" then return false end
  page.key = key
  self.tabs[key] = { key = key, title = title, page = page, enabled = enabled }
  table.insert(self.order, key)
  if not self.selected then self.selected = key end
  if self.frame then self:BuildTabs() end
  return true
end

-- Resources -------------------------------------------------------------------

local Resources = {}
Window.Resources = Resources

function Resources:Build()
  local cellWidth = math.floor((CONTENT_WIDTH - 12) / 3)
  local panel = NewPanel(self, "Your Resources", 0, 0, CONTENT_WIDTH, 66)
  self.cells = {}
  local index = 1
  while index <= 3 do
    local cell = NewFrame(panel, cellWidth, 40)
    Place(cell, panel, 6 + (index - 1) * cellWidth, -23)
    cell.icon = Skin():Icon(cell, nil, 30, 30)
    Place(cell.icon, cell, 4, -4)
    cell.name = NewText(cell, "GameFontHighlight", 40, -3)
    cell.value = NewText(cell, "GameFontHighlight", 40, -3, cellWidth - 50, "RIGHT")
    cell.bar = Skin():Bar(cell, cellWidth - 50, 12, "gold")
    Place(cell.bar, cell, 40, -22)
    if index > 1 then
      local divider = Skin():Icon(cell, "divider.v", 3, 36, "BORDER")
      Place(divider, cell, -3, -2)
    end
    self.cells[index] = cell
    index = index + 1
  end
  self.cellsPanel = panel

  panel = NewPanel(self, "Gathering", 0, -70, CONTENT_WIDTH, 70)
  self.gatherIcon = Skin():Icon(panel, nil, 40, 40)
  Place(self.gatherIcon, panel, 10, -24)
  self.gatherName = NewText(panel, "GameFontHighlight", 14, -26, 290)
  self.gatherStock = NewText(panel, "GameFontHighlight", 310, -26, 120)
  self.gatherState = NewText(panel, "GameFontHighlightSmall", 430, -27, 166, "RIGHT")
  self.gatherHint = NewText(panel, "GameFontHighlightSmall", 58, -46, CONTENT_WIDTH - 70)
  self.gatherPanel = panel

  panel = NewPanel(self, "Resource Stocks", 0, -144, CONTENT_WIDTH, CONTENT_HEIGHT - 144)
  self.stocks = NewList(panel, 9, 28, -24, function(row)
    row.icon = Skin():Icon(row, nil, 24, 24)
    Place(row.icon, row, 4, -1)
    row.name = NewText(row, "GameFontHighlight", 34, -6, 250)
    row.value = NewText(row, "GameFontHighlight", 280, -6, 80, "RIGHT")
    row.bar = Skin():Bar(row, 150, 12, "gold")
    Place(row.bar, row, 372, -7)
    row.state = NewText(row, "GameFontHighlightSmall", 528, -7, 60)
  end)
  self.stockIds = {}
end

function Resources:Update(now)
  local economy = PC.Economy
  local wallet = economy and economy:Wallet()
  local index = 1
  while index <= 3 do
    local cell = self.cells[index]
    local resource = economy and economy.RESOURCES[index]
    if wallet and resource then
      local cap = economy.CAPS[resource]
      Skin():Apply(cell.icon, "icon." .. resource)
      SetText(cell.name, RESOURCE_NAMES[resource])
      SetText(cell.value, wallet[resource] .. " / " .. cap .. (wallet[resource] >= cap and Paint("BAD", " full") or ""))
      Skin():SetBar(cell.bar, wallet[resource] / cap, RESOURCE_FILLS[resource])
      cell:Show()
    else
      cell:Hide()
    end
    index = index + 1
  end
  SetText(self.cellsPanel.note, wallet and "" or Paint("BAD", "Unavailable: no saved data or identity yet"))

  local stock = PC.Stock
  local hud = stock and stock:GetHud(now)
  Show(self.gatherIcon, hud ~= nil)
  Place(self.gatherName, self.gatherPanel, hud and 58 or 14, -26)
  Place(self.gatherHint, self.gatherPanel, hud and 58 or 14, -46)
  if hud then
    Window.SetPoiIcon(self.gatherIcon, hud.area)
    SetText(self.gatherName, AreaName(hud.area) .. " " .. AreaZone(hud.area))
    SetText(self.gatherStock, "Stock: " .. hud.resource.level .. " / " .. hud.resource.capacity)
    if hud.status == "IN" then
      SetText(self.gatherState, Paint("GOOD", "Gathering " .. stock.GATHER_AMOUNT .. " " .. hud.resource.resource
        .. " every " .. stock.GATHER_TICK .. "s"))
    else
      SetText(self.gatherState, Paint("BAD", "Not gathering: " .. tostring(hud.reason or "checking")))
    end
    SetText(self.gatherHint, Paint("DIM", hud.resource.status))
  else
    SetText(self.gatherName, Paint("DIM", "Not in a resource place"))
    SetText(self.gatherStock, "")
    SetText(self.gatherState, "")
    SetText(self.gatherHint, Paint("DIM", "Stand in a Gold Mine, Farm or Forest to gather, PvP flag on."))
  end

  local map = PC.Map
  local count = 0
  if stock and map then
    count = Collect(self.stockIds, function(id) return stock:Resource(id) ~= nil and stock:View(id, now) ~= nil end)
  end
  FillList(self.stocks, count, function(row, item)
    local id = self.stockIds[item]
    local area = stock:Resource(id)
    local view = stock:View(id, now)
    Window.SetPoiIcon(row.icon, area)
    SetText(row.name, AreaName(area) .. " " .. AreaZone(area))
    SetText(row.value, view.level .. " / " .. view.capacity)
    Skin():SetBar(row.bar, view.capacity > 0 and view.level / view.capacity or 0, RESOURCE_FILLS[view.resource] or "gold")
    if not view.known then
      SetText(row.state, Paint("DIM", "not observed"))
    elseif view.level >= view.capacity then
      SetText(row.state, Paint("GOOD", "Full"))
    else
      SetText(row.state, "")
    end
  end)
end

function Resources:Summary()
  local wallet = PC.Economy and PC.Economy:Wallet()
  if not wallet then return "" end
  return wallet.gold .. " gold   " .. wallet.wood .. " wood   " .. wallet.food .. " food"
end

-- Army ------------------------------------------------------------------------

local Army = {}
Window.Army = Army

function Army:Build()
  local panel = NewPanel(self, "Reserve", 0, 0, CONTENT_WIDTH, 70)
  local icon = Skin():Icon(panel, "icon.unitsize", 30, 24)
  Place(icon, panel, 10, -30)
  self.size = NewText(panel, "GameFontHighlight", 48, -25, 170)
  self.sizeBar = Skin():Bar(panel, 170, 12, "gold")
  Place(self.sizeBar, panel, 48, -44)
  self.placeIcon = Skin():Icon(panel, nil, 34, 34)
  Place(self.placeIcon, panel, 236, -26)
  self.place = NewText(panel, "GameFontHighlightSmall", 274, -26, 170)
  self.placeName = NewText(panel, "GameFontHighlightSmall", 274, -42, 170)
  self.wallet = {}
  local index = 1
  while index <= 3 do
    local x = 450 + (index - 1) * 50
    local coin = Skin():Icon(panel, nil, 20, 20)
    Place(coin, panel, x, -32)
    self.wallet[index] = { icon = coin, text = NewText(panel, "GameFontHighlightSmall", x + 20, -36, 30) }
    index = index + 1
  end
  self.reservePanel = panel

  panel = NewPanel(self, "Units", 0, -74, CONTENT_WIDTH, CONTENT_HEIGHT - 74)
  self.units = {}
  index = 1
  while index <= 4 do
    local row = NewFrame(panel, CONTENT_WIDTH - 12, 62)
    Place(row, panel, 6, -24 - (index - 1) * 66)
    Skin():RowBackground(row, 62)
    row.portrait = Skin():Icon(row, nil, 40, 40, "ARTWORK")
    Place(row.portrait, row, 10, -11)
    local frame = Skin():Icon(row, "portrait", 48, 48, "OVERLAY")
    Place(frame, row, 6, -7)
    row.name = NewText(row, "GameFontHighlight", 64, -12, 150)
    row.size = NewText(row, "GameFontHighlightSmall", 64, -32, 150)
    row.costs = {}
    local c = 1
    while c <= 3 do
      local x = 212 + (c - 1) * 58
      local coin = Skin():Icon(row, "icon." .. RESOURCE_ORDER[c], 18, 18)
      Place(coin, row, x, -22)
      row.costs[c] = NewText(row, "GameFontHighlightSmall", x + 20, -25, 36)
      c = c + 1
    end
    row.info = NewText(row, "GameFontHighlightSmall", 392, -14, 120)
    row.info2 = NewText(row, "GameFontHighlightSmall", 392, -32, 120)
    row.one = NewButton(row, "dark", 34, 26, "+1")
    Place(row.one, row, 518, -18)
    row.five = NewButton(row, "dark", 34, 26, "+5")
    Place(row.five, row, 556, -18)
    self.units[index] = row
    index = index + 1
  end
  self.note = NewText(panel, "GameFontHighlightSmall", 10, -292, CONTENT_WIDTH - 20)
end

function Army:Update(now)
  local army = PC.Army
  local reserve = army and army:Reserve()
  local wallet = PC.Economy and PC.Economy:Wallet()
  local faction = MyFaction()
  if not reserve or not wallet then
    SetText(self.reservePanel.note, Paint("BAD", "Unavailable: no saved data or identity yet"))
    SetText(self.size, "")
    return
  end
  SetText(self.reservePanel.note, "")
  local used = army:Used(reserve)
  SetText(self.size, "Unit Size: " .. used .. " / " .. army.RESERVE_CAPACITY
    .. (used >= army.RESERVE_CAPACITY and Paint("BAD", " full") or ""))
  Skin():SetBar(self.sizeBar, used / army.RESERVE_CAPACITY, used >= army.RESERVE_CAPACITY and "red" or "gold")
  local area, where = army:Place()
  Show(self.placeIcon, area ~= nil)
  if area then
    Window.SetPoiIcon(self.placeIcon, area, faction)
    SetText(self.place, Paint("GOOD", "Recruitment open:"))
    SetText(self.placeName, Paint("GOOD", AreaName(area)))
  else
    SetText(self.place, Paint("BAD", "Recruitment closed:"))
    SetText(self.placeName, Paint("BAD", tostring(where)))
  end
  local index = 1
  while index <= 3 do
    local resource = RESOURCE_ORDER[index]
    Skin():Apply(self.wallet[index].icon, "icon." .. resource)
    SetText(self.wallet[index].text, tostring(wallet[resource]))
    index = index + 1
  end
  index = 1
  while index <= table.getn(self.units) do
    local row = self.units[index]
    local key = army.ORDER[index]
    local unit = key and army.UNITS[key]
    if unit then
      UnitIcon(row.portrait, key, faction)
      SetText(row.name, army:Name(key) .. Paint("GOLD", "  x" .. reserve[key]))
      SetText(row.size, Paint("DIM", "Size: " .. unit.size))
      SetText(row.costs[1], tostring(unit.gold))
      SetText(row.costs[2], tostring(unit.wood))
      SetText(row.costs[3], tostring(unit.food))
      if unit.scout then
        SetText(row.info, Paint("GOOD", "Scout, never fights"))
      else
        SetText(row.info, Paint("GOOD", "ATK " .. unit.atk .. "  DEF " .. unit.def))
      end
      SetText(row.info2, Paint("DIM", "Up to " .. army:MostAffordable(key, reserve, wallet) .. " now"))
      SetAction(row.one, "+1", Window.Recruit, key, 1)
      SetAction(row.five, "+5", Window.Recruit, key, 5)
      row:Show()
    else
      row:Hide()
    end
    index = index + 1
  end
  SetText(self.note, Paint("DIM", "Costs are paid once at recruitment. Knights scout enemy places; they never fight."))
end

function Army:Summary()
  local army = PC.Army
  local reserve = army and army:Reserve()
  if not reserve then return "" end
  local area = army:Place()
  return "Reserve " .. army:Used(reserve) .. " / " .. army.RESERVE_CAPACITY .. "   Recruitment "
    .. (area and Paint("GOOD", "open") or Paint("BAD", "closed"))
end

-- Territory -------------------------------------------------------------------

local Territory = {}
Window.Territory = Territory

function Territory:Build()
  local panel = NewPanel(self, "War Balance", 0, 0, CONTENT_WIDTH, 82)
  self.balance = Skin():Balance(panel, CONTENT_WIDTH - 40, 32)
  Place(self.balance, panel, 20, -24)
  self.held = NewText(panel, "GameFontHighlight", 10, -62, CONTENT_WIDTH - 20, "CENTER")
  self.balancePanel = panel

  panel = NewPanel(self, "Points of Interest", 0, -86, CONTENT_WIDTH, 176)
  local headers = { { "Location", 34 }, { "Owner", 236 }, { "Source / Status", 344 }, { "Details", 486 } }
  local index = 1
  while index <= table.getn(headers) do
    SetText(NewText(panel, "GameFontDisableSmall", headers[index][2] + 6, -24, 120), headers[index][1])
    index = index + 1
  end
  self.pois = NewList(panel, 6, 22, -38, function(row)
    row.icon = Skin():Icon(row, nil, 20, 20)
    Place(row.icon, row, 4, 0)
    row.name = NewText(row, "GameFontHighlightSmall", 34, -4, 196)
    row.badge = Skin():Icon(row, nil, 14, 16)
    Place(row.badge, row, 236, -2)
    row.owner = NewText(row, "GameFontHighlightSmall", 254, -4, 86)
    row.dot = Skin():Icon(row, nil, 14, 14)
    Place(row.dot, row, 344, -3)
    row.source = NewText(row, "GameFontHighlightSmall", 362, -4, 120)
    row.details = NewText(row, "GameFontHighlightSmall", 486, -4, 104)
  end)
  self.poiIds = {}

  panel = NewPanel(self, "Synchronization", 0, -266, CONTENT_WIDTH, 92)
  self.channelDot = Skin():Icon(panel, nil, 14, 14)
  Place(self.channelDot, panel, 10, -27)
  self.channel = NewText(panel, "GameFontHighlightSmall", 28, -28, 270)
  self.sendDot = Skin():Icon(panel, nil, 14, 14)
  Place(self.sendDot, panel, 10, -47)
  self.send = NewText(panel, "GameFontHighlightSmall", 28, -48, 270)
  self.queue = NewText(panel, "GameFontHighlightSmall", 28, -68, 270)
  local divider = Skin():Icon(panel, "divider.v", 3, 62, "BORDER")
  Place(divider, panel, 302, -24)
  local sync = Skin():Icon(panel, "icon.sync", 16, 18)
  Place(sync, panel, 312, -25)
  self.catchup = NewText(panel, "GameFontHighlightSmall", 334, -28, 260)
  self.versionIcon = Skin():Icon(panel, "icon.warning", 16, 15)
  Place(self.versionIcon, panel, 312, -46)
  self.version = NewText(panel, "GameFontHighlightSmall", 334, -48, 260)

  panel = NewPanel(self, "Legend: Source / Status", 0, -362, CONTENT_WIDTH, CONTENT_HEIGHT - 362)
  local chips = {
    { "dot.green", "Seen by you", "your own client saw it" },
    { "dot.yellow", "Reported", "told on the channel, unverified" },
    { "dot.grey", "Unconfirmed", "players claim another owner" },
    { "dot.empty", "Not observed", "nothing seen since login" },
  }
  local width = math.floor((CONTENT_WIDTH - 12) / 4)
  index = 1
  while index <= 4 do
    local x = 6 + (index - 1) * width
    local dot = Skin():Icon(panel, chips[index][1], 14, 14)
    Place(dot, panel, x + 4, -26)
    SetText(NewText(panel, "GameFontHighlightSmall", x + 22, -26, width - 24), chips[index][2])
    SetText(NewText(panel, "GameFontDisableSmall", x + 4, -42, width - 8), chips[index][3])
    index = index + 1
  end
end

local function Capturing(info)
  return info and info.challenger and info.challenger ~= "-" and (info.percent or 0) >= 50 and info.challenger or nil
end

function Territory:Update(now)
  local map, capture = PC.Map, PC.Capture
  if not map or not capture then
    SetText(self.held, Paint("BAD", "Unavailable: map or capture not loaded"))
    FillList(self.pois, 0, nil)
    return
  end
  local counts = self.counts or {}
  self.counts = counts
  counts.H, counts.A, counts.N = 0, 0, 0
  local count = Collect(self.poiIds, function(id)
    local area = map.areas[id]
    if not area or not area.enabled or not TERRITORY_TYPES[area.type] then return false end
    if capture:Capturable(id) then
      local owner = capture:GetOwner(id)
      counts[owner] = (counts[owner] or 0) + 1
    end
    return true
  end)
  Skin():SetBalance(self.balance, counts.A, counts.H)
  SetText(self.held, "Territory held:  " .. FactionText("A") .. " " .. counts.A .. "   /   " .. FactionText("H") .. " "
    .. counts.H .. "   /   " .. FactionText("N") .. " " .. counts.N)
  SetText(self.balancePanel.note, Paint("DIM", "What this client saw or was told; reports are not verified."))
  FillList(self.pois, count, function(row, item)
    local id = self.poiIds[item]
    local area = map.areas[id]
    local owner, _, source = capture:GetOwner(id)
    local info = capture:TooltipInfo(id, now)
    Window.SetPoiIcon(row.icon, area, owner, Capturing(info))
    SetText(row.name, AreaName(area) .. " " .. AreaZone(area))
    Skin():Apply(row.badge, owner == "A" and "badge.alliance" or owner == "H" and "badge.horde" or "badge.neutral")
    SetText(row.owner, FactionText(owner))
    if not capture:Capturable(id) then
      Skin():Apply(row.dot, "dot.empty")
      SetText(row.source, Paint("DIM", "Not capturable yet"))
    elseif info and info.cloud then
      local label, code = capture.CloudLine(info.cloud)
      Skin():Apply(row.dot, "dot.grey")
      SetText(row.source, code and (label .. ": " .. FactionText(code)) or label)
    elseif info and info.hint then
      Skin():Apply(row.dot, "dot.grey")
      SetText(row.source, "Unconfirmed: " .. FactionText(info.hint.owner))
    else
      Skin():Apply(row.dot, SOURCE_DOTS[source] or "dot.empty")
      SetText(row.source, source == "LOCAL" and SOURCE_LABELS.LOCAL or source == "PEER" and SOURCE_LABELS.PEER
        or Paint("DIM", SOURCE_LABELS.STATIC))
    end
    if info and info.challenger and info.challenger ~= "-" then
      SetText(row.details, FactionText(info.challenger) .. " " .. info.percent .. "%"
        .. (info.remaining and Paint("DIM", " " .. Duration(info.remaining)) or ""))
    elseif area.type == "SETTLEMENT" and map.LevelText then
      SetText(row.details, map.LevelText(area) or Paint("DIM", "Level 1"))
    elseif info and info.cloud then
      local _, _, detail = capture.CloudLine(info.cloud)
      SetText(row.details, Paint("DIM", detail))
    elseif info and info.hint then
      SetText(row.details, Paint("DIM", info.hint.count .. " player(s), " .. Duration(info.hint.age) .. " ago"))
    else
      SetText(row.details, Paint("DIM", "-"))
    end
  end)

  local catchup = PC.Catchup
  local joinedAt = catchup and catchup.joinedAt
  Skin():Apply(self.channelDot, joinedAt and "dot.green" or "dot.empty")
  SetText(self.channel, "Channel: " .. (joinedAt and Paint("GOOD", "joined " .. Duration(now - joinedAt) .. " ago")
    or Paint("BAD", "not joined yet: nothing is shared")))
  local talk = not capture.CanTalk or capture:CanTalk()
  Skin():Apply(self.sendDot, talk and "dot.green" or "dot.empty")
  SetText(self.send, "Can send data: " .. (talk and Paint("GOOD", "yes")
    or Paint("BAD", tostring(capture.LockReason and capture:LockReason() or capture.LEVEL_REASON))))
  local queue = PC.SendQueue
  if queue then
    local dropped = queue.dropped or 0
    SetText(self.queue, Paint("DIM", "Messages waiting to leave: " .. queue:Pending()
      .. (dropped > 0 and (", " .. dropped .. " dropped since login") or "")))
  else
    SetText(self.queue, "")
  end
  local pending = 0
  local code
  for code in pairs(catchup and catchup.pending or {}) do pending = pending + 1 end
  SetText(self.catchup, "Catch-up: " .. (pending > 0 and Paint("GOLD", "comparing " .. pending .. " group(s)")
    or Paint("DIM", "nothing to compare")))
  local version = PC.Version and PC.Version:Text()
  Show(self.versionIcon, version ~= nil)
  if version then
    SetText(self.version, Paint("BAD", version))
  else
    SetText(self.version, "Addon version: " .. tostring(PC.version) .. Paint("DIM", ", no newer version seen"))
  end
end

function Territory:Summary()
  local counts = self.counts
  if not counts then return "" end
  return FactionText("A") .. " " .. counts.A .. "   " .. FactionText("H") .. " " .. counts.H
end

-- Garrison --------------------------------------------------------------------

local Garrison = {}
Window.Garrison = Garrison

-- The Garrison tab only opens while the player stands in an Outpost or a
-- Settlement.
function Window.InGarrison()
  local area = PC.Presence and PC.Presence.current
  return area ~= nil and PC.Garrison ~= nil and PC.Garrison:Area(area.id) ~= nil
end

function Garrison:Build()
  local panel = NewPanel(self, "Garrison", 0, 0, CONTENT_WIDTH, 64)
  self.icon = Skin():Icon(panel, nil, 40, 40)
  Place(self.icon, panel, 8, -22)
  SetText(NewText(panel, "GameFontDisableSmall", 56, -24, 60), "Held by")
  self.badge = Skin():Icon(panel, nil, 14, 16)
  Place(self.badge, panel, 56, -40)
  self.owner = NewText(panel, "GameFontHighlight", 74, -41, 120)
  local columns = { { "Level", 236 }, { "Garrison", 336 }, { "Defense", 486 } }
  self.columns = {}
  local index = 1
  while index <= 3 do
    SetText(NewText(panel, "GameFontDisableSmall", columns[index][2], -24, 140), columns[index][1])
    self.columns[index] = NewText(panel, "GameFontHighlight", columns[index][2], -41, 140)
    index = index + 1
  end
  self.header = panel

  local notice = NewFrame(self.frame, CONTENT_WIDTH, 26)
  Place(notice, self.frame, 0, -66)
  self.noticeBack = Skin():Slice3(notice, "row", 26, "BACKGROUND")
  self.noticeText = NewText(notice, "GameFontHighlightSmall", 24, -7, 430)
  self.yes = NewButton(notice, "red", 56, 22, "Yes", Window.Pledge)
  Place(self.yes, notice, 470, -2)
  self.no = NewButton(notice, "dark", 56, 22, "No", Window.CancelPledge)
  Place(self.no, notice, 530, -2)
  self.notice = notice

  panel = NewPanel(self, "Current Situation", 0, -94, CONTENT_WIDTH, 118)
  self.strips = {}
  local kinds = { { "strip.red", "icon.swords" }, { "strip.blue", "icon.shield" }, { "strip.gold", "icon.hourglass" } }
  index = 1
  while index <= 3 do
    local strip = NewFrame(panel, CONTENT_WIDTH - 12, 22)
    Place(strip, panel, 6, -24 - (index - 1) * 23)
    Skin():Slice3(strip, kinds[index][1], 22, "BACKGROUND")
    strip.icon = Skin():Icon(strip, kinds[index][2], 18, 18)
    Place(strip.icon, strip, 14, -2)
    strip.text = NewText(strip, "GameFontHighlight", 40, -4, 330)
    strip.right = NewText(strip, "GameFontHighlight", 380, -4, 200, "RIGHT")
    self.strips[index] = strip
    index = index + 1
  end
  self.calm = NewText(panel, "GameFontHighlightSmall", 14, -28, CONTENT_WIDTH - 30)
  local lock = Skin():Icon(panel, "icon.lock", 15, 18)
  Place(lock, panel, 12, -95)
  self.reinforce = NewText(panel, "GameFontHighlight", 34, -97, 180)
  self.reinforceWhy = NewText(panel, "GameFontHighlightSmall", 200, -98, 390)

  panel = NewPanel(self, "Garrison Units", 0, -216, CONTENT_WIDTH, 104)
  self.unitsPanel = panel
  self.units = {}
  index = 1
  while index <= 3 do
    local row = NewFrame(panel, CONTENT_WIDTH - 12, 24)
    Place(row, panel, 6, -24 - (index - 1) * 26)
    Skin():RowBackground(row, 24)
    row.portrait = Skin():Icon(row, nil, 20, 20)
    Place(row.portrait, row, 6, -2)
    row.name = NewText(row, "GameFontHighlight", 34, -5, 170)
    row.count = NewText(row, "GameFontHighlight", 210, -5, 80)
    row.have = NewText(row, "GameFontHighlightSmall", 300, -6, 160)
    row.one = NewButton(row, "red", 50, 20, "+1")
    Place(row.one, row, 482, -2)
    row.five = NewButton(row, "red", 50, 20, "+5")
    Place(row.five, row, 536, -2)
    self.units[index] = row
    index = index + 1
  end

  panel = NewPanel(self, "War Chest", 0, -324, CONTENT_WIDTH, CONTENT_HEIGHT - 324)
  self.chestPanel = panel
  self.chest = {}
  local kindsChest = { { "gold", 100, 500 }, { "wood", 50, 100 } }
  local width = math.floor((CONTENT_WIDTH - 12) / 2)
  index = 1
  while index <= 2 do
    local cell = NewFrame(panel, width, 30)
    Place(cell, panel, 6 + (index - 1) * width, -22)
    cell.icon = Skin():Icon(cell, "icon." .. kindsChest[index][1], 24, 24)
    Place(cell.icon, cell, 4, -3)
    cell.value = NewText(cell, "GameFontHighlightSmall", 34, -2, 160)
    cell.bar = Skin():Bar(cell, 150, 10, kindsChest[index][1] == "gold" and "gold" or "brown")
    Place(cell.bar, cell, 34, -17)
    cell.small = NewButton(cell, "red", 52, 20, "+" .. kindsChest[index][2])
    Place(cell.small, cell, 190, -5)
    cell.large = NewButton(cell, "red", 52, 20, "+" .. kindsChest[index][3])
    Place(cell.large, cell, 244, -5)
    cell.kind, cell.smallCount, cell.largeCount = kindsChest[index][1], kindsChest[index][2], kindsChest[index][3]
    self.chest[index] = cell
    index = index + 1
  end
  self.nextLevel = NewText(panel, "GameFontHighlightSmall", 12, -56, CONTENT_WIDTH - 24)
  local pouch = Skin():Icon(panel, "icon.pouch", 20, 20)
  Place(pouch, panel, 10, -72)
  self.effort = NewText(panel, "GameFontHighlightSmall", 36, -74, CONTENT_WIDTH - 50)
end

function Garrison:Update(now)
  local garrison = PC.Garrison
  local area = PC.Presence and PC.Presence.current
  local view = garrison and area and garrison:View(area.id, now)
  if not view then
    SetText(self.header.title, "Garrison")
    SetText(self.owner, Paint("DIM", "Stand in an Outpost or a Settlement to see its garrison"))
    return
  end
  local mine = MyFaction()
  SetText(self.header.title, AreaName(view.area) .. "  " .. AreaZone(view.area))
  Window.SetPoiIcon(self.icon, view.area, view.owner)
  Skin():Apply(self.badge, view.owner == "A" and "badge.alliance" or view.owner == "H" and "badge.horde" or "badge.neutral")
  SetText(self.owner, FactionText(view.owner))
  SetText(self.columns[1], view.settlement and (view.level .. " / 3") or Paint("DIM", "-"))
  SetText(self.columns[2], view.used .. " / " .. view.capacity .. Paint("DIM", " Unit Size")
    .. (view.used >= view.capacity and Paint("BAD", " full") or ""))
  SetText(self.columns[3], tostring(view.defense))

  -- Confirmation, pending pledge or nothing.
  local confirm = Window.confirm
  local pending = garrison:Pending()
  if confirm and confirm.id == view.id then
    Skin():SetSlice3(self.noticeBack, "strip.gold")
    SetText(self.noticeText, Paint("GOLD", "Give " .. confirm.count .. " " .. garrison:Name(confirm.kind, view.owner)
      .. "? It can never be taken back."))
    self.yes:Show()
    self.no:Show()
  elseif pending and pending.id == view.id then
    Skin():SetSlice3(self.noticeBack, "strip.gold")
    SetText(self.noticeText, Paint("DIM", "Waiting for the garrison keeper to accept " .. pending.count .. " "
      .. garrison:Name(pending.kind, pending.owner)))
    self.yes:Hide()
    self.no:Hide()
  else
    Skin():SetSlice3(self.noticeBack, "row")
    SetText(self.noticeText, Paint("DIM", "Garrison data: " .. view.source .. "."))
    self.yes:Hide()
    self.no:Hide()
  end

  -- Armies on their way and the post-combat lock (modules/attack.lua).
  local attack = PC.Attack
  local threat = attack and attack:TooltipInfo(view.id, now)
  local shown = 0
  local strip = self.strips[1]
  if threat and threat.enemy then
    shown = shown + 1
    SetText(strip.text, Paint("BAD", "Enemy army on its way"))
    SetText(strip.right, Paint("BAD", "Arrives in " .. Duration(threat.enemy)))
  end
  Show(strip, threat and threat.enemy)
  strip = self.strips[2]
  if threat and threat.allied then
    shown = shown + 1
    SetText(strip.text, Paint("A", "Allied army on its way"))
    SetText(strip.right, Paint("GOOD", "Arrives in " .. Duration(threat.allied.left)))
  end
  Show(strip, threat and threat.allied)
  strip = self.strips[3]
  if threat and threat.pending then
    shown = shown + 1
    SetText(strip.text, Paint("GOLD", "A battle here is waiting to be resolved"))
    SetText(strip.right, "")
  end
  Show(strip, threat and threat.pending)
  SetText(self.calm, shown == 0 and Paint("DIM", "No army on its way and no battle waiting here.") or "")
  local frozen = attack and attack:Freeze(view.id, now)
  SetText(self.reinforce, "Reinforcements: " .. (frozen and Paint("BAD", "blocked") or Paint("GOOD", "open")))
  SetText(self.reinforceWhy, frozen and Paint("BAD", frozen) or "")

  local closed = garrison:Closed(view.area, now)
  local reserve = PC.Army and PC.Army:Reserve()
  local wallet = PC.Economy and PC.Economy:Wallet()
  SetText(self.unitsPanel.note, view.used .. " / " .. view.capacity .. " Unit Size")
  local index = 1
  while index <= table.getn(self.units) do
    local row = self.units[index]
    local key = garrison.UNIT_ORDER[index]
    UnitIcon(row.portrait, key, view.owner == "H" and "H" or view.owner == "A" and "A" or mine)
    SetText(row.name, garrison:Name(key, view.owner))
    SetText(row.count, "x" .. view[key])
    SetText(row.have, reserve and Paint("DIM", "you have " .. reserve[key]) or "")
    local open = not closed and not frozen
    Show(row.one, open)
    Show(row.five, open)
    SetAction(row.one, "+1", open and Window.AskPledge or nil, key, 1)
    SetAction(row.five, "+5", open and Window.AskPledge or nil, key, 5)
    index = index + 1
  end

  SetText(self.chestPanel.title, view.settlement and "War Chest" or "War Effort")
  index = 1
  while index <= 2 do
    local cell = self.chest[index]
    if view.settlement then
      local value, goal = view[cell.kind], cell.kind == "gold" and view.nextGold or view.nextWood
      SetText(cell.value, RESOURCE_NAMES[cell.kind] .. "  " .. value .. (goal and (" / " .. goal) or "")
        .. (wallet and Paint("DIM", "   you have " .. wallet[cell.kind]) or ""))
      Skin():SetBar(cell.bar, goal and goal > 0 and value / goal or 1, cell.kind == "gold" and "gold" or "brown")
      Show(cell.small, not closed)
      Show(cell.large, not closed)
      SetAction(cell.small, "+" .. cell.smallCount, not closed and Window.AskPledge or nil, cell.kind, cell.smallCount)
      SetAction(cell.large, "+" .. cell.largeCount, not closed and Window.AskPledge or nil, cell.kind, cell.largeCount)
      cell:Show()
    else
      cell:Hide()
    end
    index = index + 1
  end
  if not view.settlement then
    SetText(self.nextLevel, Paint("DIM", "Only Settlements take gold and wood, to reach levels 2 and 3."))
  elseif view.nextGold then
    SetText(self.nextLevel, Paint("DIM", "Level " .. (view.level + 1) .. " once both are reached: garrison capacity "
      .. view.nextCapacity))
  else
    SetText(self.nextLevel, Paint("GOOD", "Maximum level reached"))
  end
  if closed then
    SetText(self.effort, Paint("BAD", "Closed: ") .. closed)
  else
    SetText(self.effort, Paint("GOOD", "Open: ") .. "what you give can never be taken back")
  end
end

function Garrison:Summary()
  local last = PC.Garrison and PC.Garrison.last
  if last then return Paint(last.ok and "GOOD" or "BAD", last.text) end
  return ""
end

-- War -------------------------------------------------------------------------

local War = {}
Window.War = War

-- The attack being built (target POI and unit counts f, r, m): local until
-- the player confirms Send, then PC.Attack:Launch takes it as /pc attack does.
Window.army = { f = 0, r = 0, m = 0 }

local function Arrives(r, now)
  local left = r.depart + r.dur - now
  if left > 0 then return "Arrives in " .. Duration(left) end
  return "Battle pending"
end

local function Progress(r, now)
  if not r.dur or r.dur <= 0 then return 1 end
  return (now - r.depart) / r.dur
end

function War:Build()
  local panel = NewPanel(self, "Your Orders", 0, 0, CONTENT_WIDTH, 72)
  self.orders = {}
  local index = 1
  while index <= 2 do
    local row = NewFrame(panel, CONTENT_WIDTH - 12, 22)
    Place(row, panel, 6, -23 - (index - 1) * 23)
    Skin():RowBackground(row, 22)
    row.icon = Skin():Icon(row, nil, 18, 18)
    Place(row.icon, row, 6, -2)
    row.text = NewText(row, "GameFontHighlightSmall", 32, -4, 270)
    row.bar = Skin():Bar(row, 150, 10, "green")
    Place(row.bar, row, 306, -6)
    row.right = NewText(row, "GameFontHighlightSmall", 462, -4, 126, "RIGHT")
    self.orders[index] = row
    index = index + 1
  end

  panel = NewPanel(self, "Attack Builder", 0, -76, CONTENT_WIDTH, 120)
  local swords = Skin():Icon(panel, "icon.swords", 22, 22)
  Place(swords, panel, 10, -24)
  self.capacity = NewText(panel, "GameFontHighlightSmall", 38, -24, 150)
  self.capacityBar = Skin():Bar(panel, 140, 10, "gold")
  Place(self.capacityBar, panel, 38, -38)
  self.from = NewText(panel, "GameFontHighlightSmall", 196, -24, 196)
  self.target = NewText(panel, "GameFontHighlightSmall", 196, -38, 196)
  self.targetIcon = Skin():Icon(panel, nil, 24, 24)
  Place(self.targetIcon, panel, 566, -22)
  self.cells = {}
  index = 1
  while index <= 3 do
    local cell = NewFrame(panel, 196, 26)
    Place(cell, panel, 6 + (index - 1) * 198, -54)
    Skin():RowBackground(cell, 26)
    cell.portrait = Skin():Icon(cell, nil, 20, 20)
    Place(cell.portrait, cell, 5, -3)
    cell.count = NewText(cell, "GameFontHighlightSmall", 30, -7, 100)
    cell.minus = NewButton(cell, "dark", 26, 20, "-")
    Place(cell.minus, cell, 132, -3)
    cell.plus = NewButton(cell, "dark", 26, 20, "+")
    Place(cell.plus, cell, 162, -3)
    self.cells[index] = cell
    index = index + 1
  end
  self.size = NewText(panel, "GameFontHighlightSmall", 12, -92, 150)
  self.clock = Skin():Icon(panel, "icon.clock", 14, 16)
  Place(self.clock, panel, 160, -90)
  self.travel = NewText(panel, "GameFontHighlightSmall", 178, -92, 130)
  self.warn = Skin():Icon(panel, "icon.warning", 14, 13)
  Place(self.warn, panel, 312, -91)
  self.reason = NewText(panel, "GameFontHighlightSmall", 330, -92, 180)
  self.send = NewButton(panel, "red", 74, 24, "Send", Window.AskLaunch)
  Place(self.send, panel, 520, -86)
  local confirm = NewFrame(panel, CONTENT_WIDTH - 12, 26)
  Place(confirm, panel, 6, -86)
  Skin():Slice3(confirm, "strip.gold", 26, "BACKGROUND")
  confirm:SetFrameLevel((panel:GetFrameLevel() or 0) + 3)
  self.confirmText = NewText(confirm, "GameFontHighlightSmall", 24, -7, 400)
  local yes = NewButton(confirm, "red", 56, 22, "Yes", Window.Launch)
  Place(yes, confirm, 456, -2)
  local no = NewButton(confirm, "dark", 56, 22, "No", Window.CancelLaunch)
  Place(no, confirm, 516, -2)
  self.confirm = confirm
  self.builder = panel

  local half = math.floor((CONTENT_WIDTH - GAP) / 2)
  panel = NewPanel(self, "Enemy Targets", 0, -200, half, 122)
  self.targets = NewList(panel, 4, 24, -23, function(row)
    row.icon = Skin():Icon(row, nil, 20, 20)
    Place(row.icon, row, 3, -1)
    row.name = NewText(row, "GameFontHighlightSmall", 26, -5, 120)
    row.state = NewText(row, "GameFontHighlightSmall", 146, -5, 92)
    row.button = NewButton(row, "dark", 44, 20, "Scout")
    Place(row.button, row, half - 58, -1)
  end)
  self.targetIds = {}
  panel = NewPanel(self, "Threats to Your Faction", half + GAP, -200, half, 122)
  self.threats = NewList(panel, 4, 24, -23, function(row)
    row.icon = Skin():Icon(row, nil, 18, 18)
    Place(row.icon, row, 4, -2)
    row.name = NewText(row, "GameFontHighlightSmall", 26, -5, 130)
    row.state = NewText(row, "GameFontHighlightSmall", 156, -5, 130, "RIGHT")
  end)
  self.threatList = {}
  self.threatPool = {}

  panel = NewPanel(self, "Settlement Sieges", 0, -326, CONTENT_WIDTH, CONTENT_HEIGHT - 326)
  self.sieges = NewList(panel, 1, 54, -23, function(row)
    row.icon = Skin():Icon(row, nil, 32, 32)
    Place(row.icon, row, 6, -9)
    row.name = NewText(row, "GameFontHighlight", 44, -10, 150)
    row.badge = Skin():Icon(row, nil, 12, 14)
    Place(row.badge, row, 44, -30)
    row.owner = NewText(row, "GameFontHighlightSmall", 60, -31, 120)
    row.checks = {}
    local c = 1
    while c <= 3 do
      local mark = Skin():Icon(row, nil, 12, 12)
      Place(mark, row, 200, -4 - (c - 1) * 16)
      row.checks[c] = { mark = mark, text = NewText(row, "GameFontHighlightSmall", 216, -4 - (c - 1) * 16, 370) }
      c = c + 1
    end
  end)
  self.siegeIds = {}
  self.siegeNote = NewText(panel, "GameFontDisableSmall", 10, -80, CONTENT_WIDTH - 20)
end

local function OrderRow(row, kind, order, now, faction)
  if order then
    UnitIcon(row.icon, kind == "scout" and "SCOUT" or "FOOTMAN", faction)
    row.icon:Show()
    if kind == "scout" then
      SetText(row.text, PC.Army:Name("SCOUT", faction) .. Paint("DIM", "  to  ") .. PC.Scout:Label(order.target))
    else
      SetText(row.text, "Army" .. Paint("DIM", "  to  ") .. PC.Attack:Label(order.target) .. Paint("DIM", "  ("
        .. PC.Attack.Composition(order, faction) .. ")"))
    end
    Skin():SetBar(row.bar, Progress(order, now), kind == "scout" and "green" or (faction == "H" and "red" or "blue"))
    row.bar:Show()
    SetText(row.right, Paint("GOOD", Arrives(order, now)))
  else
    row.icon:Hide()
    row.bar:Hide()
    SetText(row.text, Paint("DIM", kind == "scout" and "No scout travelling" or "No army marching"))
    SetText(row.right, "")
  end
end

local function TargetState(id, faction, now)
  local scout, attack = PC.Scout, PC.Attack
  local _, finish = scout:Discovery(id, faction, now)
  local info = attack:TooltipInfo(id, now)
  if info and info.pending then return Paint("GOLD", "Battle pending"), finish end
  if finish and Window.target == id then return Paint("GOLD", "Your target"), finish end
  if finish then return Paint("A", "Found (" .. Duration(finish - now) .. ")"), finish end
  local travelling = scout:Travelling(id, faction, now)
  if travelling then return Paint("GOOD", "Scout: " .. Duration(math.max(0, travelling.depart + travelling.dur - now))), nil end
  if info and info.locked then return Paint("DIM", "Locked " .. Duration(info.locked)), nil end
  return Paint("BAD", "Not scouted"), nil
end

function War:Update(now)
  local faction = MyFaction()
  local reserve = PC.Army and PC.Army:Reserve()
  if not PC.Scout or not PC.Attack or not PC.Map or not reserve or not faction then
    OrderRow(self.orders[1], "scout", nil, now, "A")
    SetText(self.orders[2].text, Paint("BAD", "Unavailable: no saved data, identity or faction yet"))
    return
  end
  local attack, scout, map, capture = PC.Attack, PC.Scout, PC.Map, PC.Capture
  OrderRow(self.orders[1], "scout", scout:Mine(now), now, faction)
  OrderRow(self.orders[2], "army", attack:Mine(now), now, faction)

  -- Attack builder.
  local army = Window.army
  local capacity = attack:AssaultCapacity(faction)
  local size = attack.Size(army)
  SetText(self.capacity, "Assault Capacity: " .. Paint(size > capacity and "BAD" or "WHITE", size .. " / " .. capacity))
  Skin():SetBar(self.capacityBar, capacity > 0 and size / capacity or 0, size > capacity and "red" or "gold")
  local origin, why = PC.Army:Place()
  SetText(self.from, Paint("DIM", "Leave from: ") .. (origin and AreaName(origin) or Paint("BAD", why)))
  local target = Window.target and attack:Target(Window.target)
  SetText(self.target, Paint("DIM", "Target: ") .. (target and AreaName(target) or Paint("DIM", "pick a found target below")))
  Show(self.targetIcon, target ~= nil)
  if target then Window.SetPoiIcon(self.targetIcon, target, OtherFaction(faction)) end
  local index = 1
  while index <= table.getn(self.cells) do
    local cell = self.cells[index]
    local key = attack.UNIT_ORDER[index]
    local count = army[attack.FIELDS[key]]
    UnitIcon(cell.portrait, key, faction)
    SetText(cell.count, PC.Army:Name(key, faction) .. " " .. Paint("GOLD", count) .. Paint("DIM", "/" .. reserve[key]))
    SetAction(cell.minus, "-", Window.ChangeArmy, key, -1, count > 0)
    SetAction(cell.plus, "+", Window.ChangeArmy, key, 1, count < reserve[key])
    index = index + 1
  end
  SetText(self.size, "Army size: " .. Paint(size > capacity and "BAD" or "GOOD", size .. " / " .. capacity)
    .. (size > capacity and Paint("BAD", " too large") or ""))
  local duration = origin and target and scout:Travel(origin, target)
  SetText(self.travel, duration and ("Travel: " .. Duration(duration)) or Paint("DIM", "Travel: -"))
  if Window.launch then
    SetText(self.confirmText, Paint("GOLD", "Send " .. attack.Composition(army, faction) .. "? The units never come back."))
    self.confirm:Show()
  else
    self.confirm:Hide()
  end
  local ready, reason = false, "pick a target first"
  if target then ready, reason = attack:Check(target.id, army, now) end
  if ready then
    SetText(self.reason, Paint("BAD", "The units never come back"))
  else
    SetText(self.reason, Paint("BAD", "Cannot send: " .. tostring(reason)))
  end
  Skin():SetButton(self.send, "Send", ready and true or false)

  -- Enemy targets: places the other faction holds.
  local enemy = OtherFaction(faction)
  local count = Collect(self.targetIds, function(id)
    return scout:Target(id) ~= nil and capture:GetOwner(id) == enemy
  end)
  FillList(self.targets, count, function(row, item)
    local id = self.targetIds[item]
    local area = scout:Target(id)
    Window.SetPoiIcon(row.icon, area, enemy)
    SetText(row.name, AreaName(area))
    local state, found = TargetState(id, faction, now)
    SetText(row.state, state)
    if found and Window.target ~= id then
      SetAction(row.button, "Pick", Window.Pick, id)
      row.button:Show()
    elseif not found and not scout:Travelling(id, faction, now) then
      SetAction(row.button, "Scout", Window.SendScout, id)
      row.button:Show()
    else
      row.button:Hide()
    end
  end)
  SetText(self.targets.panel.note, count == 0 and Paint("DIM", "none known") or self.targets.panel.note.value)

  -- Threats: enemy armies, battles and enemy scouts heading to our places.
  local threats, pool = self.threatList, self.threatPool
  local n = 0
  index = 1
  while index <= table.getn(map.order) do
    local id = map.order[index]
    local area = scout:Target(id)
    if area and capture:GetOwner(id) == faction then
      local info = attack:TooltipInfo(id, now)
      local spy = scout:Travelling(id, enemy, now)
      local kinds = 0
      if info and info.enemy then kinds = 1 elseif info and info.pending then kinds = 2 end
      if kinds > 0 then
        n = n + 1
        pool[n] = pool[n] or {}
        pool[n].id, pool[n].kind, pool[n].left = id, kinds, info.enemy
        threats[n] = pool[n]
      end
      if spy then
        n = n + 1
        pool[n] = pool[n] or {}
        pool[n].id, pool[n].kind, pool[n].left = id, 3, spy.depart + spy.dur - now
        threats[n] = pool[n]
      end
    end
    index = index + 1
  end
  local extra = n + 1
  while threats[extra] do
    threats[extra] = nil
    extra = extra + 1
  end
  FillList(self.threats, n, function(row, item)
    local threat = threats[item]
    SetText(row.name, AreaName(map.areas[threat.id]))
    if threat.kind == 1 then
      Skin():Apply(row.icon, "icon.swords")
      SetText(row.state, Paint("BAD", "Army in " .. Duration(threat.left)))
    elseif threat.kind == 2 then
      Skin():Apply(row.icon, "icon.hourglass")
      SetText(row.state, Paint("GOLD", "Battle pending"))
    else
      Skin():Apply(row.icon, "icon.scout")
      SetText(row.state, Paint("BAD", "Scout in " .. Duration(math.max(0, threat.left))))
    end
  end)
  if n == 0 then SetText(self.threats.panel.note, Paint("DIM", "none known")) end

  -- Settlement sieges: every Settlement the faction does not hold.
  count = Collect(self.siegeIds, function(id)
    local area = map.areas[id]
    return area and area.enabled and area.type == "SETTLEMENT" and capture:GetOwner(id) ~= faction
  end)
  FillList(self.sieges, count, function(row, item)
    local id = self.siegeIds[item]
    local area = map.areas[id]
    local owner = capture:GetOwner(id)
    Window.SetPoiIcon(row.icon, area, owner)
    SetText(row.name, AreaName(area))
    Skin():Apply(row.badge, owner == "A" and "badge.alliance" or owner == "H" and "badge.horde" or "badge.neutral")
    SetText(row.owner, FactionText(owner))
    local list = capture:SiegeChecklist(id, faction, now)
    local c = 1
    while c <= 3 do
      local check = list[c]
      if check then
        Skin():Apply(row.checks[c].mark, check.ok and "icon.check" or "icon.cross")
        row.checks[c].mark:Show()
        SetText(row.checks[c].text, check.ok and check.text or Paint("BAD", check.text))
      else
        row.checks[c].mark:Hide()
        SetText(row.checks[c].text, "")
      end
      c = c + 1
    end
  end)
  if count == 0 then
    SetText(self.siegeNote, Paint("DIM", "Your faction holds every Settlement."))
  else
    SetText(self.siegeNote, "Then " .. capture.SIEGE_ATTACKERS .. " players of your faction standing inside start the siege.")
  end
end

function War:Summary()
  local faction = MyFaction()
  if not faction or not PC.Attack then return "" end
  return "Assault Capacity " .. PC.Attack:AssaultCapacity(faction)
end

-- Guide -----------------------------------------------------------------------

local Guide = {}
Window.Guide = Guide

-- The game loop for new players, one card per mechanic; the numbers come from
-- the modules that own them.
local function GuideSteps()
  local stock, army, scout, capture = PC.Stock, PC.Army, PC.Scout, PC.Capture
  return {
    { "Gather", "guide.gather", "In a Gold Mine, Forest or Farm, PvP flag on: +" .. stock.GATHER_AMOUNT
      .. " every " .. stock.GATHER_TICK .. "s. Stocks are shared and refill slowly." },
    { "Recruit", "guide.recruit", "Inside a place your faction holds, spend resources on units. Reserve: "
      .. army.RESERVE_CAPACITY .. " Unit Size." },
    { "Capture", "guide.capture", "Stay in an enemy or neutral Outpost, PvP flag on, until the bar is full. Hunting Grounds: kill their creatures." },
    { "Garrison", "guide.garrison", "Give units to a place of your faction: they defend it. A gift never comes back." },
    { "Scout", "guide.scout", "Send a Knight to an enemy place: your faction sees it for "
      .. math.floor(scout.DISCOVERY / 60) .. " minutes." },
    { "Attack", "guide.attack", "Pick a found target, choose units within your Assault Capacity and send them. They never come back." },
    { "Conquer", "guide.conquer", "Hold its zone, empty its garrison, scout it, then " .. capture.SIEGE_ATTACKERS
      .. " players stand inside for " .. math.floor(capture.SETTLEMENT_DURATION / 60) .. " minutes." },
    { "Shared, not verified", "icon.warning", "Players share everything on the PandaConquest channel; no server checks it. See the Territory tab." },
  }
end
Window.GuideSteps = GuideSteps

function Guide:Build()
  self.cards = {}
  local width = math.floor((CONTENT_WIDTH - 3 * GAP) / 4)
  local height = math.floor((CONTENT_HEIGHT - GAP) / 2)
  local index = 1
  while index <= 8 do
    local column = math.mod(index - 1, 4)
    local row = math.floor((index - 1) / 4)
    local card = NewFrame(self.frame, width, height)
    Place(card, self.frame, column * (width + GAP), -row * (height + GAP))
    Skin():Slice9(card, "panel", 0.25, "BACKGROUND")
    if index < 8 then
      local ring = Skin():Icon(card, "icon.ring", 22, 22)
      Place(ring, card, 8, -8)
      local number = NewText(card, "GameFontNormalSmall", 8, -12, 22, "CENTER")
      SetText(number, tostring(index))
    end
    card.title = NewText(card, "GameFontNormal", index < 8 and 34 or 10, -12, width - 40)
    card.picture = Skin():Icon(card, nil, 96, 72)
    card.picture:SetPoint("TOP", card, "TOP", 0, -36)
    card.text = NewText(card, "GameFontHighlightSmall", 10, -114, width - 20)
    card.text:SetHeight(height - 120)
    card.text:SetJustifyV("TOP")
    self.cards[index] = card
    index = index + 1
  end
end

function Guide:Update(now)
  if not PC.Stock or not PC.Army or not PC.Scout or not PC.Capture then return end
  if self.filled then return end
  local steps = GuideSteps()
  local index = 1
  while index <= table.getn(self.cards) do
    local card, step = self.cards[index], steps[index]
    SetText(card.title, step[1])
    Skin():Apply(card.picture, step[2])
    local piece = Skin():Piece(step[2])
    if piece then
      local scale = math.min(96 / piece.w, 72 / piece.h)
      card.picture:SetWidth(piece.w * scale)
      card.picture:SetHeight(piece.h * scale)
    end
    SetText(card.text, step[3])
    index = index + 1
  end
  self.filled = true
end

function Guide:Summary()
  return Paint("DIM", "Shared on the PandaConquest channel, not verified")
end

-- Actions ---------------------------------------------------------------------

function Window:ChangeArmy(key, delta)
  local reserve = PC.Army and PC.Army:Reserve()
  local field = PC.Attack and PC.Attack.FIELDS[key]
  if not reserve or not field then return end
  local n = self.army[field] + delta
  if n > reserve[key] then n = reserve[key] end
  if n < 0 then n = 0 end
  self.army[field] = n
  self.launch = nil
  self:SetStatus(nil)
  self:Refresh()
end

function Window:Pick(id)
  self.target = id
  self.launch = nil
  self:SetStatus("Target: " .. PC.Attack:Label(id), "GOOD")
  self:Refresh()
end

function Window:AskLaunch()
  local ok, reason = PC.Attack:Check(self.target or "", self.army, Now())
  if ok then
    self.launch = true
    self:SetStatus(nil)
  else
    self:SetStatus("Attack refused: " .. tostring(reason), "BAD")
  end
  self:Refresh()
end

function Window:CancelLaunch()
  self.launch = nil
  self:SetStatus("Attack cancelled", "DIM")
  self:Refresh()
end

-- Sends the army with the reserve's current attack number, so one
-- confirmation sends once (Attack:Launch, as /pc attack).
function Window:Launch()
  local confirmed = self.launch
  self.launch = nil
  local reserve = PC.Army and PC.Army:Reserve()
  local ok, result = false, "no saved data or identity yet"
  if not confirmed then
    result = "confirm the attack first"
  elseif reserve then
    ok, result = PC.Attack:Launch(self.target or "", { f = self.army.f, r = self.army.r, m = self.army.m }, reserve.aop)
  end
  if ok then
    self:SetStatus("Army sent to " .. PC.Attack:Label(result.target) .. ", arrives in " .. Duration(result.dur), "GOOD")
    self.army = { f = 0, r = 0, m = 0 }
    self.target = nil
  else
    self:SetStatus("Attack refused: " .. tostring(result), "BAD")
  end
  self:Refresh()
  return ok
end

-- Sends one scout with the reserve's current scouting number, so one click
-- sends once (Scout:Launch, as /pc scout).
function Window:SendScout(id)
  local reserve = PC.Army and PC.Army:Reserve()
  local ok, result = false, "no saved data or identity yet"
  if reserve then ok, result = PC.Scout:Launch(id, reserve.sop) end
  if ok then
    self:SetStatus(PC.Army:Name("SCOUT") .. " sent to " .. PC.Scout:Label(id) .. ", arrives in "
      .. Duration(result.dur), "GOOD")
  else
    self:SetStatus("Scout refused: " .. tostring(result), "BAD")
  end
  self:Refresh()
  return ok
end

function Window:AskPledge(kind, count)
  local area = PC.Presence and PC.Presence.current
  self.confirm = area and { id = area.id, kind = kind, count = count } or nil
  self:SetStatus(nil)
  self:Refresh()
end

function Window:CancelPledge()
  self.confirm = nil
  self:SetStatus("Pledge cancelled", "DIM")
  self:Refresh()
end

-- Pledges with the reserve's current pledge number, so one confirmation
-- pledges once (modules/garrison.lua, Garrison:Pledge).
function Window:Pledge()
  local confirm = self.confirm
  self.confirm = nil
  local garrison = PC.Garrison
  local area = PC.Presence and PC.Presence.current
  local reserve = PC.Army and PC.Army:Reserve()
  local ok, result = false, "no saved data or identity yet"
  if not confirm or not area or area.id ~= confirm.id then
    result = "you are no longer in the same place"
  elseif garrison and reserve then
    ok, result = garrison:Pledge(confirm.kind, confirm.count, reserve.gop)
  end
  if ok and result == "sent" then
    self:SetStatus("Pledge sent: waiting for the garrison keeper", "GOOD")
  elseif ok then
    self:SetStatus("Pledged " .. confirm.count .. " " .. garrison:Name(confirm.kind, garrison:View(confirm.id).owner), "GOOD")
  else
    self:SetStatus("Pledge refused: " .. tostring(result), "BAD")
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

function Window:BuildTabs()
  local frame = self.frame
  local index = table.getn(self.tabButtons) + 1
  while index <= table.getn(self.order) do
    local key = self.order[index]
    local button = Skin():Button(frame, "tab", 100, 26, function(b) Window:Select(b.tabKey) end, NAME .. "Tab" .. index)
    button.tabKey = key
    Skin():SetButton(button, self.tabs[key].title, true)
    table.insert(self.tabButtons, button)
    index = index + 1
  end
  -- Every tab shares the content width evenly.
  local count = table.getn(self.tabButtons)
  local width = math.floor((CONTENT_WIDTH + 4) / count)
  index = 1
  while index <= count do
    local button = self.tabButtons[index]
    button:SetWidth(width - 4)
    Place(button, frame, CONTENT_LEFT + (index - 1) * width, CONTENT_TOP + 26)
    index = index + 1
  end
end

function Window:BuildPage(tab)
  local page = tab.page
  if page.frame then return true end
  local frame = GetGlobal("CreateFrame")("Frame", nil, self.frame)
  frame:SetWidth(CONTENT_WIDTH)
  frame:SetHeight(CONTENT_HEIGHT)
  Place(frame, self.frame, CONTENT_LEFT, CONTENT_TOP)
  page.frame = frame
  page.error = Skin():Text(frame, "GameFontHighlight", "LEFT")
  Place(page.error, frame, 8, -8)
  page.error:SetWidth(CONTENT_WIDTH - 16)
  if page.Build then
    local ok, err = pcall(page.Build, page)
    if not ok then
      if PC.RecordError then PC.RecordError("main window " .. tab.key, err) end
      page.broken = tostring(err)
    end
  end
  frame:Hide()
  return true
end

local function Ornament(frame, name, scale, point, x, y, level)
  local piece = Skin():Piece(name)
  if not piece then return nil end
  local image = Skin():Image(frame, name, piece.w * scale, piece.h * scale, "ARTWORK")
  image:SetPoint(point, frame, point, x, y)
  image:SetFrameLevel((frame:GetFrameLevel() or 0) + (level or 4))
  return image
end

-- True below level 5: the server refuses channel chat, the player takes no
-- part in the conquest and the maps show nothing (decision 0039).
function Window.Locked()
  return PC.Capture and PC.Capture.CanTalk and not PC.Capture:CanTalk() and true or false
end

-- title, text, summary of the companion guard when it, not the level, locks the
-- conquest (decision 0059); nil otherwise.
local function CompanionNotice()
  local capture = PC.Capture
  if capture and capture.LockKind and capture:LockKind() == "companion" and PC.Companion then
    return PC.Companion:Notice()
  end
  return nil
end

function Window.LockTitle()
  local title = CompanionNotice()
  return title or ("Reach level " .. LOCK_LEVEL .. " to join the conquest")
end

function Window.LockSummary()
  local title, _, summary = CompanionNotice()
  if title then return summary end
  return "Level " .. LOCK_LEVEL .. " required"
end

function Window.LockText()
  local companionTitle, companionText = CompanionNotice()
  if companionTitle then return companionText end
  local ok, level = pcall(GetGlobal("UnitLevel") or function() return nil end, "player")
  local yours = ok and type(level) == "number" and level > 0 and (" You are level " .. level .. ".") or ""
  return "Below level " .. LOCK_LEVEL .. " the server blocks channel chat, so PandaConquest cannot"
    .. " share anything for you and what it would show could be wrong." .. yours .. "\n\n"
    .. "Until then you cannot capture, gather, send scouts or attack, and the world map and"
    .. " minimap show no conquest places.\n\n"
    .. "At level " .. LOCK_LEVEL .. " you join automatically, no /reload needed. Meanwhile the"
    .. " Guide tab explains how the conquest works."
end

function Window:ShowLock()
  if not self.lock then
    local frame = GetGlobal("CreateFrame")("Frame", nil, self.frame)
    frame:SetWidth(CONTENT_WIDTH)
    frame:SetHeight(CONTENT_HEIGHT)
    Place(frame, self.frame, CONTENT_LEFT, CONTENT_TOP)
    Skin():Slice9(frame, "panel", 0.25, "BACKGROUND")
    frame.title = NewText(frame, "GameFontNormalLarge", 24, -120, CONTENT_WIDTH - 48, "CENTER")
    frame.title:SetHeight(24)
    frame.text = NewText(frame, "GameFontHighlight", 48, -160, CONTENT_WIDTH - 96, "CENTER")
    frame.text:SetHeight(200)
    frame.text:SetJustifyV("TOP")
    self.lock = frame
  end
  SetText(self.lock.title, Paint("GOLD", Window.LockTitle()))
  SetText(self.lock.text, Window.LockText())
  if not self.lock:IsShown() then self.lock:Show() end
end

function Window:Build()
  if self.frame then return self.frame end
  local create = GetGlobal("CreateFrame")
  if type(create) ~= "function" or not PC.Skin or not PC.UIAtlas then return nil end
  local ok, frame = pcall(create, "Frame", NAME, UIParent)
  if not ok or not frame then return nil end
  self.frame = frame
  frame:SetWidth(WIDTH)
  frame:SetHeight(HEIGHT)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() this:StartMoving() end)
  frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  frame:SetScript("OnShow", function() Window:Refresh() end)
  frame:SetScript("OnUpdate", function() Window:OnUpdate(arg1) end)

  -- One shared frame: dark stone, the Alliance lion and drape on the left
  -- corner, the Horde cloth, crest and chain on the right corner, their rails on
  -- the top border, the PandaConquest medallion and title between.
  Skin():Border(frame, { top = "frame.top", bottom = "frame.bottom", left = "frame.left", right = "frame.right",
    centre = "frame.centre", sideCap = 14, overlap = 10 }, FRAME_SCALE)
  -- The status strip runs between the bottom corner blocks of the frame: only
  -- its middle is drawn, its own caps would repeat those corners.
  local bottom = Skin():Piece("frame.bottom")
  local inset = bottom and bottom.insets and math.floor(bottom.insets[1] * FRAME_SCALE) or 10
  local status = create("Frame", nil, frame)
  status:SetHeight(24)
  status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, 12)
  status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, 12)
  local strip = Skin():Slice3(status, "frame.status", 24, "ARTWORK")
  strip.L:Hide()
  strip.R:Hide()
  strip.M:ClearAllPoints()
  strip.M:SetAllPoints(status)
  self.statusBar = status
  self.ornaments = {
    alliance = Ornament(frame, "frame.alliance", ALLIANCE_SCALE, "TOPLEFT", -8, 28),
    horde = Ornament(frame, "frame.horde", HORDE_SCALE, "TOPRIGHT", 8, 36),
    medallion = Ornament(frame, "frame.medallion", ORNAMENT_SCALE, "TOP", 0, 38, 6),
    title = Ornament(frame, "frame.title", TITLE_SCALE, "TOP", 0, -25, 7),
  }
  local close = Skin():CloseButton(frame, 26, function() Window.frame:Hide() end)
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 7, 36)
  close:SetFrameLevel((frame:GetFrameLevel() or 0) + 9)
  self.close = close

  self.status = Skin():Text(status, "GameFontHighlightSmall", "LEFT")
  self.status:SetPoint("LEFT", status, "LEFT", 44 - inset, 0)
  self.status:SetWidth(320)
  self.summary = Skin():Text(status, "GameFontHighlightSmall", "RIGHT")
  self.summary:SetPoint("RIGHT", status, "RIGHT", inset - 44, 0)
  self.summary:SetWidth(220)
  self:BuildTabs()

  -- Escape closes the frames listed in UISpecialFrames (FrameXML UIParent.lua).
  local special = GetGlobal("UISpecialFrames")
  if type(special) == "table" then table.insert(special, NAME) end
  frame:Hide()
  return frame
end

function Window:Refresh()
  if not self.frame then return end
  local now = Now()
  local tab = self.tabs[self.selected]
  if tab and not self:TabEnabled(tab, now) then
    -- The place that opened this tab was left: back to the first tab.
    self.selected, self.confirm = self.order[1], nil
    tab = self.tabs[self.selected]
  end
  if not tab then return end
  -- Below level 5 every tab but the Guide shows the level notice instead.
  local locked = Window.Locked() and tab.key ~= "guide"
  local index = 1
  while index <= table.getn(self.order) do
    local other = self.tabs[self.order[index]]
    if (locked or other ~= tab) and other.page.frame and other.page.frame:IsShown() then other.page.frame:Hide() end
    index = index + 1
  end
  if locked then
    self:ShowLock()
    SetText(self.summary, Paint("BAD", Window.LockSummary()))
    self:RefreshTabs(now)
    return
  end
  if self.lock and self.lock:IsShown() then self.lock:Hide() end
  self:BuildPage(tab)
  local page = tab.page
  if not page.frame:IsShown() then page.frame:Show() end
  local ok, err = true, page.broken
  if not err then ok, err = pcall(page.Update, page, now) end
  if not ok or page.broken then
    if not ok and PC.RecordError then PC.RecordError("main window " .. tab.key, err) end
    SetText(page.error, Paint("BAD", "This tab failed: " .. tostring(err)))
  else
    SetText(page.error, "")
  end
  local summary = ""
  if ok and page.Summary then
    local fine, text = pcall(page.Summary, page)
    if fine and type(text) == "string" then summary = text end
  end
  SetText(self.summary, summary)
  self:RefreshTabs(now)
end

function Window:RefreshTabs(now)
  local index = 1
  while index <= table.getn(self.tabButtons) do
    local button = self.tabButtons[index]
    button.tabEnabled = self:TabEnabled(self.tabs[button.tabKey], now)
    Skin():SetButton(button, self.tabs[button.tabKey].title, button.tabEnabled, button.tabKey == self.selected)
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

function Window:SetStatus(text, color)
  if self.status then SetText(self.status, text and Paint(color, text) or "") end
end

function Window:Select(key)
  if not self.tabs[key] or not self:TabEnabled(self.tabs[key], Now()) then return false end
  self.selected = key
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

Window:AddTab("res", "Resources", Resources)
Window:AddTab("army", "Army", Army)
Window:AddTab("map", "Territory", Territory)
Window:AddTab("garrison", "Garrison", Garrison, Window.InGarrison)
Window:AddTab("war", "War", War)
Window:AddTab("guide", "Guide", Guide)
