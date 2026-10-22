PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Window = { tabs = {}, order = {}, rows = {}, tabButtons = {}, offset = 0, elapsed = 0 }

PC.ClassicWindow = Window

-- Classic text-row window, kept as a backup of the textured window
-- (modules/main_window.lua) and opened by /pc classic. A tab only returns
-- rows; the window draws them in a fixed pool, once per second while shown.
-- A later work package adds its own tab with Window:AddTab. A local view: it
-- sends nothing itself; a confirmed pledge goes through PC.Garrison, a
-- scout or a confirmed attack through PC.Scout:Launch or PC.Attack:Launch.
local NAME = "PandaConquestClassicWindow"
local WIDTH = 600
local ROWS = 20
local ROW_HEIGHT = 16
local LIST_TOP = -68
local LEFT_WITH_RIGHT = 270
local BUTTON_WIDTH = 44
local BUTTONS_PER_ROW = 2
local TAB_LEFT = 18
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
      if info and info.cloud then
        local cloudLabel, code, detail = capture.CloudLine(info.cloud)
        Row(list, "    " .. Paint("DIM", cloudLabel .. ": ") .. (code and FactionText(code) or "")
          .. Paint("DIM", (code and ", " or "") .. detail))
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
  Window.SyncRows(rows, now)
  return rows
end

-- Synchronization health and what the data labels mean: read from the
-- channel modules, nothing is sent.
function Window.SyncRows(rows, now)
  Header(rows, "Synchronization")
  local catchup = PC.Catchup
  local joinedAt = catchup and catchup.joinedAt
  Row(rows, "  Channel", joinedAt and Paint("GOOD", "joined " .. Duration(now - joinedAt) .. " ago")
    or Paint("BAD", "not joined yet: nothing is shared"))
  if PC.Capture and not PC.Capture:CanTalk() then
    Row(rows, "  " .. Paint("BAD", "You cannot send: " .. tostring(PC.Capture.LockReason and PC.Capture:LockReason()
      or PC.Capture.LEVEL_REASON)))
  end
  local pending = 0
  local code
  for code in pairs(catchup and catchup.pending or {}) do pending = pending + 1 end
  Row(rows, "  Catch-up", pending > 0 and Paint("GOLD", "comparing " .. pending .. " group(s) with other players")
    or "nothing to compare")
  local queue = PC.SendQueue
  if queue then
    local dropped = queue.dropped or 0
    Row(rows, "  Messages waiting to leave", queue:Pending() .. (dropped > 0
      and Paint("BAD", ", " .. dropped .. " dropped since login") or ""))
  end
  local version = PC.Version and PC.Version:Text()
  if version then
    Row(rows, "  " .. Paint("BAD", version))
  else
    Row(rows, "  Addon version", tostring(PC.version) .. Paint("DIM", ", no newer version seen"))
  end
  Header(rows, "What the labels mean")
  Row(rows, "  " .. Paint("DIM", "seen by you: your own client watched it happen"))
  Row(rows, "  " .. Paint("DIM", "reported by players, unverified: told on the channel, never checked"))
  Row(rows, "  " .. Paint("DIM", "Unconfirmed: some players claim another owner"))
  Row(rows, "  " .. Paint("DIM", "not observed: no stock seen since login, assumed full"))
end

-- The Garrison tab only opens while the player stands in an Outpost or a
-- Settlement.
function Window.InGarrison()
  local area = PC.Presence and PC.Presence.current
  return area ~= nil and PC.Garrison ~= nil and PC.Garrison:Area(area.id) ~= nil
end

local function PledgeButtons(kind, small, large)
  return { { label = "+" .. small, fn = Window.AskPledge, a = kind, b = small },
    { label = "+" .. large, fn = Window.AskPledge, a = kind, b = large } }
end

-- Garrison, level and War Chest of the place the player stands in
-- (modules/garrison.lua). A pledge asks for confirmation first: it is
-- irreversible.
function Window.GarrisonRows(now)
  local rows = {}
  local garrison = PC.Garrison
  local area = PC.Presence and PC.Presence.current
  local view = garrison and area and garrison:View(area.id, now)
  if not view then
    Header(rows, "Garrison")
    Row(rows, "  " .. Paint("DIM", "Stand in an Outpost or a Settlement to see its garrison"))
    return rows
  end
  Header(rows, AreaTitle(view.area))
  local confirm = Window.confirm
  if confirm and confirm.id == view.id then
    Row(rows, "  " .. Paint("GOLD", "Give " .. confirm.count .. " " .. garrison:Name(confirm.kind, view.owner)
      .. "? It can never be taken back."), nil,
      { { label = "Yes", fn = Window.Pledge }, { label = "No", fn = Window.CancelPledge } })
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
  -- Armies on their way and the post-combat lock (modules/attack.lua).
  local attack = PC.Attack
  local threat = attack and attack:TooltipInfo(view.id, now)
  if threat and threat.enemy then
    Row(rows, "  " .. Paint("BAD", "Enemy army on its way"), "arrives in " .. Duration(threat.enemy))
  end
  if threat and threat.allied then
    Row(rows, "  Allied army on its way", "arrives in " .. Duration(threat.allied.left))
  end
  if threat and threat.pending then Row(rows, "  " .. Paint("BAD", "A battle here is waiting to be resolved")) end
  local frozen = attack and attack:Freeze(view.id, now)
  Row(rows, "  Reinforcements", frozen and Paint("BAD", "blocked") or Paint("GOOD", "open"))
  if frozen then Row(rows, "    " .. Paint("BAD", frozen)) end
  local closed = garrison:Closed(view.area, now)
  local reserve = PC.Army and PC.Army:Reserve()
  local wallet = PC.Economy and PC.Economy:Wallet()
  Header(rows, "Garrison units")
  local index = 1
  while index <= table.getn(garrison.UNIT_ORDER) do
    local key = garrison.UNIT_ORDER[index]
    Row(rows, "  " .. garrison:Name(key, view.owner),
      "x" .. view[key] .. (reserve and Paint("DIM", "  you have " .. reserve[key]) or ""),
      not closed and not frozen and PledgeButtons(key, 1, 5) or nil)
    index = index + 1
  end
  if view.settlement then
    Header(rows, "War Chest")
    Row(rows, "  Gold", view.gold .. (view.nextGold and (" / " .. view.nextGold) or "")
      .. (wallet and Paint("DIM", "  you have " .. wallet.gold) or ""), not closed and PledgeButtons("gold", 100, 500) or nil)
    Row(rows, "  Wood", view.wood .. (view.nextWood and (" / " .. view.nextWood) or "")
      .. (wallet and Paint("DIM", "  you have " .. wallet.wood) or ""), not closed and PledgeButtons("wood", 50, 100) or nil)
    if view.nextGold then
      Row(rows, "  " .. Paint("DIM", "Level " .. (view.level + 1) .. " once both are reached: garrison capacity "
        .. view.nextCapacity))
    else
      Row(rows, "  " .. Paint("GOOD", "Maximum level reached"))
    end
  end
  Header(rows, "War Effort")
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

-- War -------------------------------------------------------------------------

-- The attack being built (target POI and unit counts f, r, m): local until
-- the player confirms Send, then PC.Attack:Launch takes it as /pc attack does.
Window.army = { f = 0, r = 0, m = 0 }

local function Arrives(r, now)
  local left = r.depart + r.dur - now
  if left > 0 then return "arrives in " .. Duration(left) end
  return "battle pending"
end

local function OtherFaction(faction)
  if faction == "H" then return "A" end
  return "H"
end

local function OrderRows(rows, now, faction)
  Header(rows, "Your orders")
  local scout = PC.Scout:Mine(now)
  if scout then
    Row(rows, "  " .. PC.Army:Name("SCOUT", faction) .. " to " .. PC.Scout:Label(scout.target), Arrives(scout, now))
  else
    Row(rows, "  " .. Paint("DIM", "No scout travelling"))
  end
  local mine = PC.Attack:Mine(now)
  if mine then
    Row(rows, "  Army to " .. PC.Attack:Label(mine.target), Arrives(mine, now))
    Row(rows, "    " .. Paint("DIM", PC.Attack.Composition(mine, faction) .. ", gone from your reserve"))
  else
    Row(rows, "  " .. Paint("DIM", "No army marching"))
  end
end

local function BuilderRows(rows, now, faction, reserve)
  local attack, army = PC.Attack, Window.army
  local capacity = attack:AssaultCapacity(faction)
  Header(rows, "Attack builder")
  Row(rows, "  Assault Capacity", capacity .. " Unit Size")
  Row(rows, "    " .. Paint("DIM", "From " .. attack.ASSAULT.min .. " to " .. attack.ASSAULT.max
    .. ", it grows with the Settlements your faction holds"))
  local origin, why = PC.Army:Place()
  Row(rows, "  Leave from: " .. (origin and AreaTitle(origin) or Paint("BAD", why)))
  local target = Window.target and attack:Target(Window.target)
  Row(rows, "  Target: " .. (target and AreaTitle(target) or Paint("DIM", "pick a discovered target below")))
  local index = 1
  while index <= table.getn(attack.UNIT_ORDER) do
    local key = attack.UNIT_ORDER[index]
    Row(rows, "  " .. PC.Army:Name(key, faction) .. " x" .. army[attack.FIELDS[key]],
      Paint("DIM", "you have " .. reserve[key]),
      { { label = "-1", fn = Window.ChangeArmy, a = key, b = -1 },
        { label = "+1", fn = Window.ChangeArmy, a = key, b = 1 } })
    index = index + 1
  end
  local size = attack.Size(army)
  Row(rows, "  Army size", size .. " / " .. capacity .. " Unit Size" .. (size > capacity and Paint("BAD", " too large") or ""))
  local duration = origin and target and PC.Scout:Travel(origin, target)
  if duration then Row(rows, "  Travel time", Duration(duration)) end
  if Window.launch then
    Row(rows, "  " .. Paint("GOLD", "Send " .. attack.Composition(army, faction) .. "? The units never come back."), nil,
      { { label = "Yes", fn = Window.Launch }, { label = "No", fn = Window.CancelLaunch } })
    return
  end
  if not target then
    Row(rows, "  " .. Paint("BAD", "Cannot send: ") .. "pick a target first")
    return
  end
  local ok, reason = attack:Check(target.id, army, now)
  if ok then
    Row(rows, "  " .. Paint("GOOD", "Ready to send"), nil, { { label = "Send", fn = Window.AskLaunch } })
  else
    Row(rows, "  " .. Paint("BAD", "Cannot send: ") .. tostring(reason))
  end
end

local function TargetRows(rows, now, faction)
  local map, capture, scout, attack = PC.Map, PC.Capture, PC.Scout, PC.Attack
  Header(rows, "Enemy targets")
  local count = 0
  local index = 1
  while index <= table.getn(map.order) do
    local id = map.order[index]
    local area = scout:Target(id)
    local owner = area and capture:GetOwner(id)
    if owner == OtherFaction(faction) then
      count = count + 1
      local _, finish = scout:Discovery(id, faction, now)
      local travelling = scout:Travelling(id, faction, now)
      if finish and Window.target == id then
        Row(rows, "  " .. AreaTitle(area), Paint("GOLD", "your target") .. Paint("GOOD", ", " .. Duration(finish - now) .. " left"))
      elseif finish then
        Row(rows, "  " .. AreaTitle(area), Paint("GOOD", "discovered, " .. Duration(finish - now) .. " left"),
          { { label = "Pick", fn = Window.Pick, a = id } })
      elseif travelling then
        Row(rows, "  " .. AreaTitle(area), Paint("DIM", "scout " .. Arrives(travelling, now)))
      else
        Row(rows, "  " .. AreaTitle(area), Paint("DIM", "not scouted"), { { label = "Scout", fn = Window.SendScout, a = id } })
      end
      local info = attack:TooltipInfo(id, now)
      if info and info.allied then Row(rows, "    Allied army arrives in " .. Duration(info.allied.left)) end
      if info and info.pending then Row(rows, "    " .. Paint("GOLD", "A battle is waiting to be resolved")) end
      if info and info.locked then Row(rows, "    " .. Paint("DIM", "Reinforcements locked " .. Duration(info.locked))) end
    end
    index = index + 1
  end
  if count == 0 then Row(rows, "  " .. Paint("DIM", "No Outpost or Settlement known to be held by the enemy")) end
end

local function ThreatRows(rows, now, faction)
  local map, capture, scout, attack = PC.Map, PC.Capture, PC.Scout, PC.Attack
  Header(rows, "Threats to your faction")
  local count = 0
  local index = 1
  while index <= table.getn(map.order) do
    local id = map.order[index]
    local area = scout:Target(id)
    if area and capture:GetOwner(id) == faction then
      local info = attack:TooltipInfo(id, now)
      if info and info.enemy then
        Row(rows, "  " .. AreaTitle(area), Paint("BAD", "enemy army in " .. Duration(info.enemy)))
        count = count + 1
      elseif info and info.pending then
        Row(rows, "  " .. AreaTitle(area), Paint("GOLD", "battle pending"))
        count = count + 1
      end
      local spy = scout:Travelling(id, OtherFaction(faction), now)
      if spy then
        Row(rows, "  " .. AreaTitle(area), Paint("BAD", "enemy scout " .. Arrives(spy, now)))
        count = count + 1
      end
    end
    index = index + 1
  end
  if count == 0 then Row(rows, "  " .. Paint("DIM", "No enemy army or scout known on its way")) end
end

local function SiegeRows(rows, now, faction)
  local map, capture = PC.Map, PC.Capture
  Header(rows, "Settlement sieges")
  local count = 0
  local index = 1
  while index <= table.getn(map.order) do
    local id = map.order[index]
    local area = map.areas[id]
    local owner = capture:GetOwner(id)
    if area and area.enabled and area.type == "SETTLEMENT" and owner ~= faction then
      count = count + 1
      Row(rows, "  " .. AreaTitle(area), FactionText(owner))
      local list = capture:SiegeChecklist(id, faction, now)
      local item = 1
      while item <= table.getn(list) do
        local check = list[item]
        Row(rows, "    " .. (check.ok and Paint("GOOD", "[x] ") or Paint("BAD", "[  ] ")) .. check.text)
        item = item + 1
      end
      Row(rows, "    " .. Paint("DIM", "Then " .. capture.SIEGE_ATTACKERS
        .. " players of your faction standing inside start the siege"))
    end
    index = index + 1
  end
  if count == 0 then Row(rows, "  " .. Paint("DIM", "Your faction holds every Settlement")) end
end

-- Orders, attack builder, scouting, threats and Settlement prerequisites
-- (modules/scout.lua, modules/attack.lua, Capture:SiegeChecklist).
function Window.WarRows(now)
  local rows = {}
  local faction = PC.Capture and PC.Capture:MyFaction()
  local reserve = PC.Army and PC.Army:Reserve()
  if not PC.Scout or not PC.Attack or not PC.Map or not reserve or (faction ~= "H" and faction ~= "A") then
    Header(rows, "War")
    Row(rows, "  " .. Paint("BAD", "Unavailable: no saved data, identity or faction yet"))
    return rows
  end
  OrderRows(rows, now, faction)
  BuilderRows(rows, now, faction, reserve)
  TargetRows(rows, now, faction)
  ThreatRows(rows, now, faction)
  SiegeRows(rows, now, faction)
  return rows
end

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

-- Below level 5 ---------------------------------------------------------------

-- Shown on every tab but the Guide while Capture:CanTalk is false.
function Window.LockRows()
  local rows = {}
  -- Without nampower or a running companion (decision 0059).
  local capture = PC.Capture
  if capture and capture.LockKind and capture:LockKind() == "companion" and PC.Companion then
    local title, text = PC.Companion:Notice()
    Header(rows, title)
    local paragraph, word
    for paragraph in string.gfind(text, "[^\n]+") do
      local line = ""
      for word in string.gfind(paragraph, "%S+") do
        if line ~= "" and string.len(line) + 1 + string.len(word) > 68 then
          Row(rows, " " .. line)
          line = word
        elseif line == "" then
          line = word
        else
          line = line .. " " .. word
        end
      end
      if line ~= "" then Row(rows, " " .. line) end
    end
    Row(rows, " " .. Paint("DIM", "The Guide tab explains how the conquest works."))
    return rows
  end
  local ok, level = pcall(GetGlobal("UnitLevel") or function() return nil end, "player")
  Header(rows, "Reach level 5 to join the conquest")
  if ok and type(level) == "number" and level > 0 then Row(rows, " You are level " .. level .. ".") end
  Row(rows, " Below level 5 the server blocks channel chat: PandaConquest cannot")
  Row(rows, " share anything for you, and what it would show could be wrong.")
  Row(rows, " You cannot capture, gather, send scouts or attack, and the world map")
  Row(rows, " and minimap show no conquest places.")
  Row(rows, " At level 5 you join automatically, no /reload needed.")
  Row(rows, " " .. Paint("DIM", "The Guide tab explains how the conquest works."))
  return rows
end

-- Guide -----------------------------------------------------------------------

-- The game loop for new players, one section per mechanic; the numbers come
-- from the modules that own them.
function Window.GuideRows(now)
  local rows = {}
  local stock, army, scout, capture = PC.Stock, PC.Army, PC.Scout, PC.Capture
  Header(rows, "1. Gather")
  Row(rows, "  In a Gold Mine, Forest or Farm, PvP flag on, you gain " .. stock.GATHER_AMOUNT
    .. " of its resource every " .. stock.GATHER_TICK .. "s.")
  Row(rows, "  " .. Paint("DIM", "Each place has one stock shared by everyone; it empties and slowly refills."))
  Header(rows, "2. Recruit")
  Row(rows, "  Inside an Outpost or Settlement your faction holds, spend resources on units (Army tab).")
  Row(rows, "  " .. Paint("DIM", "Your reserve holds " .. army.RESERVE_CAPACITY
    .. " Unit Size; every cost, food included, is paid once at recruitment."))
  Header(rows, "3. Capture")
  Row(rows, "  Stay inside an enemy or neutral Outpost with your PvP flag on until the bar is full.")
  Row(rows, "  " .. Paint("DIM", "A strong garrison slows the capture. Hunting Grounds fill as you kill their creatures."))
  Header(rows, "4. Garrison")
  Row(rows, "  Give units to an Outpost or Settlement of your faction (Garrison tab): they defend it.")
  Row(rows, "  " .. Paint("DIM", "A gift never comes back. Settlements also take gold and wood to reach levels 2 and 3."))
  Header(rows, "5. Scout")
  Row(rows, "  From an allied place, send a scout to an enemy Outpost or Settlement (War tab).")
  Row(rows, "  " .. Paint("DIM", "On arrival your whole faction sees it for " .. math.floor(scout.DISCOVERY / 60)
    .. " minutes: attacks need it."))
  Header(rows, "6. Attack")
  Row(rows, "  Pick a discovered target, choose units within your Assault Capacity and send them.")
  Row(rows, "  " .. Paint("DIM", "They travel, fight once on arrival and never come back."))
  Row(rows, "  " .. Paint("DIM", "Killing defenders locks the reinforcements of that place for a while."))
  Header(rows, "7. Conquer a Settlement")
  Row(rows, "  Hold every Outpost and Hunting Grounds of its zone, empty its garrison and scout it.")
  Row(rows, "  " .. Paint("DIM", "Then " .. capture.SIEGE_ATTACKERS .. " players stand inside for "
    .. math.floor(capture.SETTLEMENT_DURATION / 60) .. " minutes. The War tab shows what is missing."))
  Header(rows, "Shared, not verified")
  Row(rows, "  Players online share everything on the PandaConquest channel; no server checks it.")
  Row(rows, "  " .. Paint("DIM", "The Territory tab shows where each piece of data comes from and the channel health."))
  return rows
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
    button:SetHeight(22)
    button:SetText(self.tabs[self.order[index]].title)
    button.tabKey = self.order[index]
    button:SetScript("OnClick", function() Window:Select(this.tabKey) end)
    table.insert(self.tabButtons, button)
    index = index + 1
  end
  -- Every tab shares the width of the window evenly.
  local width = math.floor((WIDTH - 2 * TAB_LEFT) / table.getn(self.tabButtons))
  index = 1
  while index <= table.getn(self.tabButtons) do
    local button = self.tabButtons[index]
    button:SetWidth(width - 4)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", TAB_LEFT + (index - 1) * width, -36)
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
  title:SetText("|cffffffffPanda |cfff5ae0aConquest|r |cff999999(classic)|r")
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
  local build = tab.rows
  -- Below level 5 every tab but the Guide shows the level notice (decision 0039).
  if tab.key ~= "guide" and PC.Capture and PC.Capture.CanTalk and not PC.Capture:CanTalk() then
    build = Window.LockRows
  end
  local ok, rows = pcall(build, now)
  if not ok or type(rows) ~= "table" then
    if PC.RecordError then PC.RecordError("classic window " .. tab.key, rows) end
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

-- /pc classic
function Window:Toggle()
  local frame = self:Build()
  if not frame then
    PC.Print("the classic PandaConquest window is unavailable")
    return false
  end
  if frame:IsShown() then frame:Hide() else frame:Show() end
  return true
end

Window:AddTab("res", "Resources", Window.ResourceRows)
Window:AddTab("army", "Army", Window.ArmyRows)
Window:AddTab("map", "Territory", Window.TerritoryRows)
Window:AddTab("garrison", "Garrison", Window.GarrisonRows, Window.InGarrison)
Window:AddTab("war", "War", Window.WarRows)
Window:AddTab("guide", "Guide", Window.GuideRows)
