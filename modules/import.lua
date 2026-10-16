PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Import = {
  data = nil,
  status = "NONE",
  reason = nil,
  loaded = false,
}

PC.Import = Import

-- Companion import (decision 0032): PandaConquestImport is the only per-character
-- SavedVariable, written by the companion with the client closed. It is checked
-- whole before any use and never modified. Cloud data stays out of the shared
-- capture state and is never sent on the channel (C11, rule R16).
local SCHEMA = 1
local U32 = 4294967296
local I31 = 2147483648
local CRC_POLY = 3988292384 -- 0xEDB88320
local MAX_ID = 64
local MAX_CHAR = 64
local MAX_IMPORT_ID = 40
local MAX_CAMPAIGNS = 20
local MAX_PROGRESS = 500
local MAX_ROWS = 100

Import.SCHEMA = SCHEMA

local function Record(kind, fields)
  if PC.Record then PC.Record(kind, fields) end
end

local function Mod(x, m)
  return x - math.floor(x / m) * m
end

-- Schema ------------------------------------------------------------------------

local function Int(maximum) return { kind = "int", max = maximum } end
local function Id(maximum, pattern) return { kind = "string", max = maximum, pattern = pattern } end

local ID = Id(MAX_ID, "^[%w_%.%-]+$")
local CHAR = { kind = "char" }
local EPOCH = Int(1000000)
local VALUE = Int(1000000000)
local ROW = { kind = "record", fields = { char = CHAR, value = VALUE } }
local SPEC = {
  kind = "record",
  fields = {
    schema = Int(SCHEMA),
    importId = Id(MAX_IMPORT_ID, "^[%w%-]+$"),
    generatedAt = Int(U32 - 1),
    catalogVersion = Int(U32 - 1),
    pc = Int(1000),
    char = CHAR,
    campaigns = {
      kind = "map", key = ID, max = MAX_CAMPAIGNS,
      value = { kind = "record", fields = { active = { kind = "bool" }, correctionEpoch = EPOCH } },
    },
    progress = {
      kind = "map", key = ID, max = MAX_CAMPAIGNS,
      value = {
        kind = "map", key = ID, max = MAX_PROGRESS,
        value = { kind = "record", fields = { correctionEpoch = EPOCH, value = VALUE } },
      },
    },
    leaderboard = {
      kind = "map", key = ID, max = MAX_CAMPAIGNS,
      value = {
        kind = "record",
        fields = {
          claimed = { kind = "list", max = MAX_ROWS, value = ROW },
          witnessed = { kind = "list", max = MAX_ROWS, value = ROW },
        },
      },
    },
    check = Int(U32 - 1),
  },
}

local function ValidChar(text)
  if type(text) ~= "string" or string.len(text) > MAX_CHAR or string.find(text, "%c") then return false end
  local at = string.find(text, "@", 1, true)
  return at ~= nil and at > 1 and at < string.len(text) and not string.find(text, "@", at + 1, true)
end

-- Returns nil when value matches spec, else the path of the first mismatch.
local function Check(value, spec, path)
  local kind = spec.kind
  if kind == "int" then
    if type(value) ~= "number" or value < 0 or value > spec.max or value ~= math.floor(value) then return path end
  elseif kind == "string" then
    if type(value) ~= "string" or string.len(value) > spec.max or not string.find(value, spec.pattern) then
      return path
    end
  elseif kind == "char" then
    if not ValidChar(value) then return path end
  elseif kind == "bool" then
    if type(value) ~= "boolean" then return path end
  elseif kind == "record" then
    if type(value) ~= "table" then return path end
    local key, field
    for key in pairs(value) do
      if type(key) ~= "string" or not spec.fields[key] then return path .. ".?" end
    end
    for key, field in pairs(spec.fields) do
      local bad = Check(value[key], field, path .. "." .. key)
      if bad then return bad end
    end
  elseif kind == "map" or kind == "list" then
    if type(value) ~= "table" then return path end
    local count = 0
    local key, item
    for key, item in pairs(value) do
      count = count + 1
      if count > spec.max then return path .. "#" end
      if kind == "list" then
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return path .. ".?" end
      elseif Check(key, spec.key, path .. ".?") then
        return path .. ".?"
      end
      local bad = Check(item, spec.value, path .. "." .. tostring(key))
      if bad then return bad end
    end
    if kind == "list" and table.getn(value) ~= count then return path .. "#" end
  else
    return path
  end
  return nil
end

-- Canonical form and CRC-32 (decision 0032) --------------------------------------

local function ByteLess(a, b)
  local la, lb = string.len(a), string.len(b)
  local n = la
  if lb < n then n = lb end
  local i
  for i = 1, n do
    local x, y = string.byte(a, i), string.byte(b, i)
    if x ~= y then return x < y end
  end
  return la < lb
end

local function KeyLess(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  if ta == "number" then return a < b end
  return ByteLess(a, b)
end

local function Canon(value, out, top)
  local kind = type(value)
  if kind == "number" then
    table.insert(out, "i" .. string.format("%.0f", value) .. ";")
  elseif kind == "string" then
    table.insert(out, "s" .. string.len(value) .. ":" .. value)
  elseif kind == "boolean" then
    table.insert(out, value and "t" or "f")
  else
    local keys = {}
    local key
    for key in pairs(value) do
      if not (top and key == "check") then table.insert(keys, key) end
    end
    table.sort(keys, KeyLess)
    table.insert(out, "{")
    local i
    for i = 1, table.getn(keys) do
      Canon(keys[i], out)
      Canon(value[keys[i]], out)
    end
    table.insert(out, "}")
  end
end

function Import.Canonical(value)
  local out = {}
  Canon(value, out, true)
  return table.concat(out)
end

-- bit.bxor is only given 32-bit signed operands and its result is read back as
-- unsigned, whatever sign convention the client uses; shifts and masks are done
-- with arithmetic.
local function Signed(x)
  if x >= I31 then return x - U32 end
  return x
end

local function Unsigned(x)
  if x < 0 then return x + U32 end
  return x
end

local function Xor(a, b)
  return Unsigned(bit.bxor(Signed(a), Signed(b)))
end

local crcTable

function Import.Crc32(text)
  if not crcTable then
    crcTable = {}
    local i, j
    for i = 0, 255 do
      local c = i
      for j = 1, 8 do
        if Mod(c, 2) == 1 then
          c = Xor(math.floor(c / 2), CRC_POLY)
        else
          c = math.floor(c / 2)
        end
      end
      crcTable[i] = c
    end
  end
  local crc = U32 - 1
  local i
  for i = 1, string.len(text) do
    local index = Xor(Mod(crc, 256), string.byte(text, i))
    crc = Xor(math.floor(crc / 256), crcTable[index])
  end
  return Xor(crc, U32 - 1)
end

-- Loading ---------------------------------------------------------------------------

local function Copy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  local key, item
  for key, item in pairs(value) do copy[key] = Copy(item) end
  return copy
end

local function Me()
  if PC.Progress and PC.Progress.Me then return PC.Progress:Me() end
  return nil
end

-- All or nothing (C6): returns a private copy of the import, or nil and a reason.
function Import:Validate(raw)
  if raw == nil then return nil, "none" end
  if type(raw) ~= "table" then return nil, "not a table" end
  if type(raw.schema) == "number" and raw.schema > SCHEMA then return nil, "future schema" end
  local bad = Check(raw, SPEC, "import")
  if bad then return nil, "invalid " .. bad end
  if raw.schema ~= SCHEMA then return nil, "invalid import.schema" end
  if raw.pc ~= PC.channelLevel then return nil, "level" end
  local me = Me()
  if not me or raw.char ~= me then return nil, "other character" end
  if not bit or type(bit.bxor) ~= "function" then return nil, "no bit library" end
  if Import.Crc32(Import.Canonical(raw)) ~= raw.check then return nil, "checksum" end
  return Copy(raw)
end

function Import:Load()
  self.loaded = true
  local data, reason = self:Validate(PandaConquestImport)
  self.data = data
  local db = PC.Storage and PC.Storage.GetDB and not PC.Storage.readOnly and PC.Storage:GetDB()
  local state = type(db) == "table" and db.import
  if type(db) == "table" and type(state) ~= "table" then
    state = {}
    db.import = state
  end
  if data then
    self.status, self.reason = "OK", nil
    if state then state.lastImportId = data.importId end
  elseif reason == "none" then
    self.status, self.reason = "NONE", nil
  else
    self.status, self.reason = "REJECTED", reason
    if (reason == "future schema" or reason == "level") and PC.Print then
      PC.Print("Companion data needs another addon version; it is ignored until you update.")
    end
  end
  if state then state.status, state.reason = self.status, self.reason end
  Record("IMPORT", { status = self.status, reason = reason, id = data and data.importId })
  return data ~= nil
end

-- The imported (correctionEpoch, value) of the player, or nil.
function Import:Progress(campaignId, achievementId)
  local campaign = self.data and self.data.progress[campaignId]
  local entry = campaign and campaign[achievementId]
  if not entry then return nil end
  return entry.value, entry.correctionEpoch
end

function Import:Epoch(campaignId)
  local campaign = self.data and self.data.campaigns[campaignId]
  return campaign and campaign.correctionEpoch or 0
end

local function OnLogin()
  if not Import.loaded then Import:Load() end
end

if PC.RegisterEvent then
  PC.RegisterEvent("PLAYER_LOGIN", OnLogin)
  -- Fallback when PLAYER_LOGIN is not seen again after /reload.
  PC.RegisterEvent("PLAYER_ENTERING_WORLD", OnLogin)
end
