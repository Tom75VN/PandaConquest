PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Economy = {}

PC.Economy = Economy

-- Gold, wood and food of this account's characters (docs/gathering.md,
-- decision 0048). Private and local: never sent on the channel. Caps from the
-- V1 balance sheet (decision 0047, tools/balance_sim.py BALANCE.inventoryCap).
local SCHEMA = 1
local CAPS = { gold = 2000, wood = 1000, food = 1500 }
local RESOURCES = { "gold", "wood", "food" }
local MAX_CHARACTERS = 50

Economy.CAPS = CAPS
Economy.RESOURCES = RESOURCES

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

-- Per-realm bucket shared with modules/stock.lua: { chars = {}, stocks = {} }.
function Economy:RealmBucket()
  local storage = PC.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  local economy = db.economy
  -- A newer schema belongs to a newer build: leave it untouched.
  if type(economy) == "table" and type(economy.schema) == "number" and economy.schema > SCHEMA then
    return nil
  end
  if type(economy) ~= "table" or economy.schema ~= SCHEMA then
    economy = { schema = SCHEMA, realms = {} }
    db.economy = economy
  end
  if type(economy.realms) ~= "table" then economy.realms = {} end
  local realm = Realm()
  local bucket = economy.realms[realm]
  if type(bucket) ~= "table" then
    bucket = {}
    economy.realms[realm] = bucket
  end
  if type(bucket.chars) ~= "table" then bucket.chars = {} end
  if type(bucket.stocks) ~= "table" then bucket.stocks = {} end
  return bucket
end

-- The character's wallet, its values bounded; nil without storage or identity.
function Economy:Wallet()
  local me = PC.Capture and PC.Capture:Me()
  local bucket = self:RealmBucket()
  if not me or not bucket then return nil end
  local wallet = bucket.chars[me]
  if type(wallet) ~= "table" then
    if Count(bucket.chars) >= MAX_CHARACTERS then return nil end
    wallet = {}
    bucket.chars[me] = wallet
  end
  local index = 1
  while index <= table.getn(RESOURCES) do
    local resource = RESOURCES[index]
    local value = tonumber(wallet[resource]) or 0
    value = math.floor(value)
    if value < 0 then value = 0 end
    if value > CAPS[resource] then value = CAPS[resource] end
    wallet[resource] = value
    index = index + 1
  end
  return wallet
end

function Economy:Get(resource)
  local wallet = self:Wallet()
  return wallet and wallet[resource] or 0
end

function Economy:Full(resource)
  local cap = CAPS[resource]
  return cap ~= nil and self:Get(resource) >= cap
end

-- Adds up to the cap; returns what was actually added.
function Economy:Add(resource, amount)
  local cap = CAPS[resource]
  local wallet = cap and self:Wallet()
  if not wallet or type(amount) ~= "number" or amount <= 0 then return 0 end
  local added = math.min(math.floor(amount), cap - wallet[resource])
  if added <= 0 then return 0 end
  wallet[resource] = wallet[resource] + added
  return added
end
