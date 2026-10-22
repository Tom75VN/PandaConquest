PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Army = {}

PC.Army = Army

-- Military units, personal reserve and recruitment (roadmap WP6,
-- docs/game-design.md §§ 6-7). Private and local: never sent on the channel.
-- Values from the V1 balance sheet (decision 0047, tools/balance_sim.py
-- BALANCE): one entry per unit, the same for both factions, only the names
-- differ. Units leave the reserve as garrison pledges (modules/garrison.lua),
-- scouts (modules/scout.lua) or attacking armies (modules/attack.lua).
local SCHEMA = 1
local RESERVE_CAPACITY = 25
local MAX_CHARACTERS = 50
local UNITS = {
  FOOTMAN = { names = { A = "Footman", H = "Grunt" }, gold = 50, wood = 10, food = 40, size = 1, atk = 36, def = 66 },
  RIFLEMAN = { names = { A = "Rifleman", H = "Headhunter" }, gold = 75, wood = 25, food = 50, size = 1, atk = 60, def = 90 },
  MORTAR = { names = { A = "Mortar Team", H = "Demolisher" }, gold = 150, wood = 60, food = 90, size = 2, atk = 132, def = 162 },
  -- The scout never fights: no ATK, no DEF, no Assault Capacity.
  SCOUT = { names = { A = "Knight", H = "Wolf Rider" }, gold = 250, wood = 100, food = 150, size = 1, scout = true },
}
local ORDER = { "FOOTMAN", "RIFLEMAN", "MORTAR", "SCOUT" }
local ALIASES = {
  footman = "FOOTMAN", grunt = "FOOTMAN",
  rifleman = "RIFLEMAN", headhunter = "RIFLEMAN",
  mortar = "MORTAR", ["mortar team"] = "MORTAR", demolisher = "MORTAR",
  scout = "SCOUT", knight = "SCOUT", wolf = "SCOUT", ["wolf rider"] = "SCOUT",
}
local PLACE_NAMES = { OUTPOST = "Outpost", SETTLEMENT = "Settlement", BARRACKS = "Barracks" }
local FACTION_CODES = { HORDE = "H", ALLIANCE = "A" }

Army.UNITS = UNITS
Army.ORDER = ORDER
Army.RESERVE_CAPACITY = RESERVE_CAPACITY

local function GetGlobal(name)
  if getglobal then return getglobal(name) end
  if _G then return _G[name] end
  return nil
end

local function Realm()
  local fn = GetGlobal("GetRealmName")
  local ok, realm = false, nil
  if type(fn) == "function" then ok, realm = pcall(fn) end
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

local function Count(t)
  local n = 0
  local key
  for key in pairs(t) do n = n + 1 end
  return n
end

local function Print(text)
  if PC.Print then PC.Print(text) end
end

local function Faction()
  return PC.Capture and PC.Capture:MyFaction()
end

function Army:Key(text)
  if type(text) ~= "string" then return nil end
  local lower = string.lower(text)
  if ALIASES[lower] then return ALIASES[lower] end
  local upper = string.upper(text)
  if UNITS[upper] then return upper end
  return nil
end

function Army:Name(key, faction)
  local unit = UNITS[key]
  if not unit then return tostring(key) end
  return unit.names[faction or Faction() or "A"] or unit.names.A
end

-- The character's reserve { FOOTMAN, RIFLEMAN, MORTAR, SCOUT, op }, its
-- values bounded; nil without storage or identity, or for a newer schema.
function Army:Reserve()
  local storage = PC.Storage
  local me = PC.Capture and PC.Capture:Me()
  if not me or not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  local army = db.army
  -- A newer schema belongs to a newer build: leave it untouched.
  if type(army) == "table" and type(army.schema) == "number" and army.schema > SCHEMA then
    return nil
  end
  if type(army) ~= "table" or army.schema ~= SCHEMA then
    army = { schema = SCHEMA, realms = {} }
    db.army = army
  end
  if type(army.realms) ~= "table" then army.realms = {} end
  local realm = Realm()
  local bucket = army.realms[realm]
  if type(bucket) ~= "table" then
    bucket = {}
    army.realms[realm] = bucket
  end
  if type(bucket.chars) ~= "table" then bucket.chars = {} end
  local reserve = bucket.chars[me]
  if type(reserve) ~= "table" then
    if Count(bucket.chars) >= MAX_CHARACTERS then return nil end
    reserve = {}
    bucket.chars[me] = reserve
  end
  local index = 1
  while index <= table.getn(ORDER) do
    local key = ORDER[index]
    local value = math.floor(tonumber(reserve[key]) or 0)
    local most = math.floor(RESERVE_CAPACITY / UNITS[key].size)
    if value < 0 then value = 0 end
    if value > most then value = most end
    reserve[key] = value
    index = index + 1
  end
  local op = math.floor(tonumber(reserve.op) or 0)
  if op < 0 or op > 1000000000 then op = 0 end
  reserve.op = op
  -- Garrison pledges (modules/garrison.lua): their own operation number and
  -- at most one pledge waiting for the keeper's answer.
  local gop = math.floor(tonumber(reserve.gop) or 0)
  if gop < 0 or gop > 1000000000 then gop = 0 end
  reserve.gop = gop
  -- Scouting orders (modules/scout.lua): their own operation number, sent
  -- with the order so that its copies are recognized.
  local sop = math.floor(tonumber(reserve.sop) or 0)
  if sop < 0 or sop >= 1000000000 then sop = 0 end
  reserve.sop = sop
  -- Attack orders (modules/attack.lua): the same, for armies.
  local aop = math.floor(tonumber(reserve.aop) or 0)
  if aop < 0 or aop >= 1000000000 then aop = 0 end
  reserve.aop = aop
  local p = reserve.pending
  if p ~= nil and (type(p) ~= "table" or not UNITS[p.kind or ""] and p.kind ~= "gold" and p.kind ~= "wood"
    or type(p.count) ~= "number" or p.count < 1 or p.count > 3600) then
    reserve.pending = nil
  end
  return reserve
end

-- Sum of Unit Size in the reserve.
function Army:Used(reserve)
  local used = 0
  local index = 1
  while index <= table.getn(ORDER) do
    local key = ORDER[index]
    used = used + reserve[key] * UNITS[key].size
    index = index + 1
  end
  return used
end

-- The recruitment place holding the player: an Outpost or Settlement owned by
-- the player's faction, or the faction's Barracks. Returns area or nil, reason.
function Army:Place()
  local faction = Faction()
  if not faction then return nil, "faction unknown" end
  local dead = GetGlobal("UnitIsDeadOrGhost")
  if type(dead) == "function" then
    local ok, flag = pcall(dead, "player")
    if ok and flag then return nil, "you are dead" end
  end
  local area = PC.Presence and PC.Presence.current
  if not area or not PLACE_NAMES[area.type] then
    return nil, "go inside an Outpost or Settlement of your faction, or your Barracks"
  end
  local owner
  if area.type == "BARRACKS" then
    -- Not in the catalog yet (roadmap WP1): its faction is its fixed color.
    owner = FACTION_CODES[area.baseColorKey or area.colorKey or ""] or "N"
  else
    -- Outposts and Settlements follow the owner registry (decision 0053).
    owner = PC.Capture and PC.Capture:GetOwner(area.id) or "N"
  end
  if owner ~= faction then
    return nil, "this " .. PLACE_NAMES[area.type] .. " is not held by your faction"
  end
  return area, nil
end

-- Largest count of a unit the resources and the free capacity allow.
function Army:MostAffordable(key, reserve, wallet)
  local unit = UNITS[key]
  local most = math.floor((RESERVE_CAPACITY - self:Used(reserve)) / unit.size)
  local index = 1
  while index <= table.getn(PC.Economy.RESOURCES) do
    local resource = PC.Economy.RESOURCES[index]
    local can = math.floor(wallet[resource] / unit[resource])
    if can < most then most = can end
    index = index + 1
  end
  if most < 0 then most = 0 end
  return most
end

-- Checks a recruitment without changing anything. Returns reserve, wallet or
-- nil, reason.
function Army:Check(key, count)
  local unit = UNITS[key]
  if not unit then return nil, "unknown unit" end
  if type(count) ~= "number" or count < 1 or count > RESERVE_CAPACITY or math.floor(count) ~= count then
    return nil, "count must be 1 to " .. RESERVE_CAPACITY
  end
  local reserve = self:Reserve()
  local wallet = PC.Economy and PC.Economy:Wallet()
  if not reserve or not wallet then return nil, "no saved data or identity yet" end
  local _, where = self:Place()
  if where then return nil, where end
  local used = self:Used(reserve)
  local size = unit.size * count
  if used + size > RESERVE_CAPACITY then
    return nil, "reserve full: needs " .. size .. " Unit Size, " .. used .. "/" .. RESERVE_CAPACITY .. " used"
  end
  local index = 1
  while index <= table.getn(PC.Economy.RESOURCES) do
    local resource = PC.Economy.RESOURCES[index]
    local cost = unit[resource] * count
    if wallet[resource] < cost then
      return nil, "not enough " .. resource .. ": needs " .. cost .. ", you have " .. wallet[resource]
    end
    index = index + 1
  end
  return reserve, wallet
end

-- Pays every cost and adds the units in one step, or changes nothing. op is
-- the reserve's operation number read by the caller: a repeated or stale
-- request (op already used) is refused, so one action recruits once.
function Army:Recruit(key, count, op)
  local reserve, wallet = self:Check(key, count)
  if not reserve then return false, wallet end
  if op ~= reserve.op then return false, "request already done or out of date" end
  local unit = UNITS[key]
  local index = 1
  while index <= table.getn(PC.Economy.RESOURCES) do
    local resource = PC.Economy.RESOURCES[index]
    wallet[resource] = wallet[resource] - unit[resource] * count
    index = index + 1
  end
  reserve[key] = reserve[key] + count
  reserve.op = reserve.op + 1
  if PC.Record then
    PC.Record("RECRUIT", { unit = key, count = count, op = reserve.op, used = self:Used(reserve) })
  end
  return true, nil
end

-- /pc recruit <unit> [count]
function Army:RecruitCommand(text)
  local _, _, name, number = string.find(string.lower(text or ""), "^%s*(.-)%s*(%d*)%s*$")
  local key = self:Key(name)
  if not key then
    Print("usage: /pc recruit footman|rifleman|mortar|scout [count] (faction names work too)")
    return
  end
  local count = 1
  if number ~= "" then count = string.len(number) <= 3 and tonumber(number) or 0 end
  local reserve = self:Reserve()
  local ok, reason = self:Recruit(key, count, reserve and reserve.op)
  if not ok then
    Print("recruitment refused: " .. tostring(reason))
    return
  end
  local unit = UNITS[key]
  Print("recruited " .. count .. " " .. self:Name(key) .. " for " .. unit.gold * count .. " gold, "
    .. unit.wood * count .. " wood, " .. unit.food * count .. " food - reserve "
    .. self:Used(reserve) .. "/" .. RESERVE_CAPACITY)
end

-- /pc army
function Army:PrintStatus()
  local reserve = self:Reserve()
  local wallet = PC.Economy and PC.Economy:Wallet()
  if not reserve or not wallet then
    Print("army unavailable (no saved data or identity yet)")
    return
  end
  local used = self:Used(reserve)
  local parts = {}
  local index = 1
  while index <= table.getn(ORDER) do
    local key = ORDER[index]
    table.insert(parts, self:Name(key) .. " " .. reserve[key])
    index = index + 1
  end
  Print("reserve " .. used .. "/" .. RESERVE_CAPACITY .. " Unit Size" .. (used >= RESERVE_CAPACITY and " (full)" or "")
    .. ": " .. table.concat(parts, ", "))
  Print("resources gold " .. wallet.gold .. "  wood " .. wallet.wood .. "  food " .. wallet.food)
  local area, where = self:Place()
  if area then
    Print("recruitment open here: " .. PLACE_NAMES[area.type] .. " " .. tostring(area.label or area.id))
  else
    Print("recruitment closed: " .. where)
  end
  index = 1
  while index <= table.getn(ORDER) do
    local key = ORDER[index]
    local unit = UNITS[key]
    local stats = unit.scout and "scout, no combat" or ("ATK " .. unit.atk .. " DEF " .. unit.def)
    Print("  " .. self:Name(key) .. ": " .. unit.gold .. " gold, " .. unit.wood .. " wood, " .. unit.food
      .. " food, size " .. unit.size .. ", " .. stats .. " - up to " .. self:MostAffordable(key, reserve, wallet))
    index = index + 1
  end
end
