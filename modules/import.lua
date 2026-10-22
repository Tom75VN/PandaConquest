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
-- Schema 2 adds the cloud owners of the character's realm (decision 0060);
-- schema 1 (no owners) is still accepted.
-- Schema 3 adds the membership ticket, the revocation list and the faction
-- history (decision 0061, roadmap WP15).
local SCHEMA = 3
local U32 = 4294967296
local I31 = 2147483648
local CRC_POLY = 3988292384 -- 0xEDB88320
local MAX_ID = 64
local MAX_CHAR = 64
local MAX_IMPORT_ID = 40
local MAX_CAMPAIGNS = 20
local MAX_PROGRESS = 500
local MAX_ROWS = 100
local MAX_OWNERS = 512
local MAX_GENERATION = 1000000
local OWNER_RANKS = { C = 1, Q = 2, W = 3, D = 4 }

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

-- Schema 2: the same fields plus owners = { [poi] = { g, o, t, c } }.
local SPEC2 = { kind = "record", fields = {} }
do
  local key, field
  for key, field in pairs(SPEC.fields) do SPEC2.fields[key] = field end
  SPEC2.fields.owners = {
    kind = "map", key = ID, max = MAX_OWNERS,
    value = {
      kind = "record",
      fields = {
        g = Int(MAX_GENERATION),
        o = Id(1, "^[HA%-]$"),
        t = Id(1, "^[CQWD]$"),
        c = { kind = "char", dash = true },
      },
    },
  }
end
-- Schema 3: schema 2 plus ticketEpoch, tickets = { [char] = { k, f, a, b, s } }
-- (this character's ticket only, 0 or 1), revoked = { [char] = day } and
-- history = { { d, h, a }, ... } (decision 0061).
local MAX_DAY = 1000000
local SPEC3 = { kind = "record", fields = {} }
do
  local key, field
  for key, field in pairs(SPEC2.fields) do SPEC3.fields[key] = field end
  SPEC3.fields.ticketEpoch = Int(MAX_DAY)
  SPEC3.fields.tickets = {
    kind = "map", key = CHAR, max = 1,
    value = {
      kind = "record",
      fields = {
        k = Id(1, "^[0-9a-z]$"),
        f = Id(1, "^[HA]$"),
        a = Int(MAX_DAY),
        b = Int(MAX_DAY),
        s = Id(86, "^[%w%-_]+$"),
      },
    },
  }
  SPEC3.fields.revoked = { kind = "map", key = CHAR, max = 256, value = Int(MAX_DAY) }
  SPEC3.fields.history = {
    kind = "list", max = 7,
    value = { kind = "record", fields = { d = Int(MAX_DAY), h = Int(MAX_OWNERS), a = Int(MAX_OWNERS) } },
  }
end
local SPECS = { [1] = SPEC, [2] = SPEC2, [3] = SPEC3 }

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
    if not ValidChar(value) and not (spec.dash and value == "-") then return path end
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

-- Reads a canonical form back into a value (decision 0059): data only, never
-- executed. Bounded depth; non-integer numbers, boolean or table keys,
-- duplicate keys and trailing bytes are refused. Key order is not checked: the
-- checksum, recomputed by Validate, covers it.
local MAX_DEPTH = 8

local function Parse(text, pos, depth)
  local c = string.sub(text, pos, pos)
  if c == "i" then
    local _, last, digits = string.find(text, "^i(%-?%d+);", pos)
    if not last or string.len(digits) > 12 then return nil, nil, "bad integer" end
    return tonumber(digits), last + 1
  elseif c == "s" then
    local _, last, size = string.find(text, "^s(%d+):", pos)
    if not last or string.len(size) > 7 then return nil, nil, "bad string" end
    local n = tonumber(size)
    local value = string.sub(text, last + 1, last + n)
    if string.len(value) ~= n then return nil, nil, "short string" end
    return value, last + n + 1
  elseif c == "t" then
    return true, pos + 1
  elseif c == "f" then
    return false, pos + 1
  elseif c == "{" then
    if depth >= MAX_DEPTH then return nil, nil, "too deep" end
    local result = {}
    local length = string.len(text)
    pos = pos + 1
    while string.sub(text, pos, pos) ~= "}" do
      if pos > length then return nil, nil, "unterminated table" end
      local key, after, err = Parse(text, pos, depth + 1)
      if err then return nil, nil, err end
      if type(key) ~= "number" and type(key) ~= "string" then return nil, nil, "bad key" end
      if result[key] ~= nil then return nil, nil, "duplicate key" end
      local value
      value, pos, err = Parse(text, after, depth + 1)
      if err then return nil, nil, err end
      result[key] = value
    end
    return result, pos + 1
  end
  return nil, nil, "unexpected byte"
end

-- value, or nil and a reason.
function Import.ParseCanonical(text)
  if type(text) ~= "string" or text == "" then return nil, "empty" end
  local value, after, err = Parse(text, 1, 0)
  if err then return nil, err end
  if after <= string.len(text) then return nil, "trailing bytes" end
  return value
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
  local spec = SPECS[raw.schema]
  if not spec then return nil, "invalid import.schema" end
  local bad = Check(raw, spec, "import")
  if bad then return nil, "invalid " .. bad end
  if raw.owners then
    local poi, e
    for poi, e in pairs(raw.owners) do
      -- An owner and a capturer exactly when the entry is not disputed.
      local disputed = e.t == "Q" or e.t == "D"
      if e.g < 1 or disputed ~= (e.o == "-") or disputed ~= (e.c == "-") then
        return nil, "invalid import.owners." .. poi
      end
    end
  end
  if raw.tickets then
    local who, t
    for who, t in pairs(raw.tickets) do
      -- Only this character's ticket, a 7-day window, a full signature.
      if who ~= raw.char or t.a > t.b or t.b - t.a > 6 or string.len(t.s) ~= 86 then
        return nil, "invalid import.tickets"
      end
    end
  end
  if raw.pc ~= PC.channelLevel then return nil, "level" end
  local me = Me()
  if not me or raw.char ~= me then return nil, "other character" end
  if not bit or type(bit.bxor) ~= "function" then return nil, "no bit library" end
  if Import.Crc32(Import.Canonical(raw)) ~= raw.check then return nil, "checksum" end
  return Copy(raw)
end

-- Folds data into into (decision 0059). Campaigns keep the higher correctionEpoch
-- (at equal epoch an ended campaign stays ended), progress the higher
-- (correctionEpoch, value): the result does not depend on the arrival order.
-- The leaderboard and identifiers come from data, the later import.
local function MergeInto(into, data)
  local id, campaign
  for id, campaign in pairs(data.campaigns) do
    local old = into.campaigns[id]
    if not old or campaign.correctionEpoch > old.correctionEpoch then
      into.campaigns[id] = Copy(campaign)
    elseif campaign.correctionEpoch == old.correctionEpoch then
      old.active = old.active and campaign.active
    end
  end
  local entries
  for id, entries in pairs(data.progress) do
    local target = into.progress[id]
    if not target then
      target = {}
      into.progress[id] = target
    end
    local key, entry
    for key, entry in pairs(entries) do
      local old = target[key]
      if not old or entry.correctionEpoch > old.correctionEpoch
        or (entry.correctionEpoch == old.correctionEpoch and entry.value > old.value) then
        target[key] = Copy(entry)
      end
    end
  end
  -- Owners: the larger (generation, rank) per POI, as the Worker ledger (decision 0060).
  if data.owners then
    if not into.owners then into.owners = {} end
    local poi, entry
    for poi, entry in pairs(data.owners) do
      local old = into.owners[poi]
      if not old or entry.g > old.g or (entry.g == old.g and OWNER_RANKS[entry.t] > OWNER_RANKS[old.t]) then
        into.owners[poi] = Copy(entry)
      end
    end
  end
  -- Tickets (decision 0061): the newest epoch, the ticket that lasts longer; the
  -- revocation list and the history of the later Worker reading.
  if data.ticketEpoch and (not into.ticketEpoch or data.ticketEpoch > into.ticketEpoch) then
    into.ticketEpoch = data.ticketEpoch
  end
  if data.tickets then
    if not into.tickets then into.tickets = {} end
    local who, t
    for who, t in pairs(data.tickets) do
      local old = into.tickets[who]
      if not old or t.b > old.b or (t.b == old.b and t.a > old.a) then into.tickets[who] = Copy(t) end
    end
  end
  if data.revoked and (not into.revoked or data.generatedAt >= into.generatedAt) then
    into.revoked = Copy(data.revoked)
    into.history = Copy(data.history)
  end
  into.leaderboard = Copy(data.leaderboard)
  into.importId, into.generatedAt, into.catalogVersion = data.importId, data.generatedAt, data.catalogVersion
  return into
end

-- data = SavedVariables import merged with the bridge imports, either order.
local function Rebuild(self)
  if self.saved and self.bridged then
    self.data = MergeInto(Copy(self.saved), self.bridged)
  else
    self.data = self.saved or self.bridged
  end
  -- Cloud owners: shown and used as a generation floor only (decision 0060).
  if PC.Capture and PC.Capture.SetCloud then PC.Capture:SetCloud(self.data and self.data.owners) end
  -- Membership ticket and revocation list (modules/ticket.lua, decision 0061).
  if PC.Ticket and self.data then
    local ok, err = pcall(PC.Ticket.OnImport, PC.Ticket, self.data)
    if not ok and PC.RecordError then PC.RecordError("ticket import", err) end
  end
end

local function SaveState(self, importId)
  local db = PC.Storage and PC.Storage.GetDB and not PC.Storage.readOnly and PC.Storage:GetDB()
  if type(db) ~= "table" then return end
  if type(db.import) ~= "table" then db.import = {} end
  if importId then db.import.lastImportId = importId end
  db.import.status, db.import.reason = self.status, self.reason
end

-- A validated import received during play through the nampower bridge
-- (decision 0059, PC.Companion). Never touches the SavedVariables import.
function Import:Merge(data)
  if self.bridged then
    MergeInto(self.bridged, data)
  else
    self.bridged = data
  end
  Rebuild(self)
  self.status, self.reason = "OK", nil
  SaveState(self, data.importId)
  Record("IMPORT", { status = "OK", source = "bridge", id = data.importId })
end

function Import:Load()
  self.loaded = true
  local data, reason = self:Validate(PandaConquestImport)
  self.saved = data
  Rebuild(self)
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
