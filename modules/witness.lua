PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Witness = {
  -- realm -> { [key] = true }, rebuilt from the saved entries (never saved itself).
  seen = {},
  recorded = 0,
  duplicates = 0,
  evicted = 0,
  refused = 0,
}

PC.Witness = Witness

-- Witness journal for the optional companion (decision 0031): what this client
-- itself accepted on the PandaConquest channel, never a relayed answer. Local
-- persistence only: nothing here is sent on the channel or read back into the
-- shared state (rule R16). The sender is the chat event author normalized by
-- Capture.Identity (rule R1), never a message field.
local SCHEMA = 1
-- Bounded (rule R9): oldest first out; the Worker accepts 500 per batch.
local MAX_ENTRIES = 500
local MAX_SENDER = 64
local MAX_POI = 16
local MAX_GENERATION = 1000000
local KINDS = { CAPTURED = true }

Witness.MAX_ENTRIES = MAX_ENTRIES

local function Realm()
  if type(GetRealmName) ~= "function" then return "unknown" end
  local ok, realm = pcall(GetRealmName)
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

local function Record(kind, fields)
  if PC.Record then PC.Record(kind, fields) end
end

local function Key(level, sender, kind, poi, generation)
  return level .. ":" .. sender .. ":" .. kind .. ":" .. poi .. ":" .. generation
end

-- The journal of this realm, or nil when SavedVariables are read-only or come
-- from a newer schema (left untouched).
function Witness:Bucket()
  local storage = PC.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  local journal = db.witness
  if type(journal) == "table" and type(journal.schema) == "number" and journal.schema > SCHEMA then
    return nil
  end
  if type(journal) ~= "table" or journal.schema ~= SCHEMA then
    journal = { schema = SCHEMA, realms = {} }
    db.witness = journal
  end
  if type(journal.realms) ~= "table" then journal.realms = {} end
  local realm = Realm()
  local bucket = journal.realms[realm]
  if type(bucket) ~= "table" then
    bucket = {}
    journal.realms[realm] = bucket
  end
  if type(bucket.entries) ~= "table" then bucket.entries = {} end
  bucket.next = tonumber(bucket.next) or 0
  local seen = self.seen[realm]
  if not seen or seen.bucket ~= bucket then
    seen = { bucket = bucket, keys = {} }
    self.seen[realm] = seen
    local entries = bucket.entries
    local i = 1
    while i <= table.getn(entries) do
      local e = entries[i]
      if type(e) == "table" and type(e.pc) == "number" and type(e.sender) == "string"
          and type(e.kind) == "string" and type(e.poi) == "string" and type(e.generation) == "number" then
        seen.keys[Key(e.pc, e.sender, e.kind, e.poi, e.generation)] = true
        if type(e.n) == "number" and e.n > bucket.next then bucket.next = e.n end
        i = i + 1
      else
        table.remove(entries, i)
      end
    end
    while table.getn(entries) > MAX_ENTRIES do table.remove(entries, 1) end
  end
  return bucket, seen.keys
end

-- One observation, idempotent by (level, sender, kind, POI, generation): the
-- same message delivered twice, or reported again later, is stored once.
-- Returns true when a new entry was added.
function Witness:Note(sender, kind, poi, generation)
  if type(sender) ~= "string" or sender == "" or string.len(sender) > MAX_SENDER
      or not string.find(sender, "@", 1, true) or not KINDS[kind]
      or type(poi) ~= "string" or poi == "" or string.len(poi) > MAX_POI
      or type(generation) ~= "number" or generation < 1 or generation > MAX_GENERATION
      or generation ~= math.floor(generation) then
    self.refused = self.refused + 1
    return false
  end
  local level = PC.channelLevel
  if type(level) ~= "number" then return false end
  local bucket, keys = self:Bucket()
  if not bucket then return false end
  local key = Key(level, sender, kind, poi, generation)
  if keys[key] then
    self.duplicates = self.duplicates + 1
    return false
  end
  bucket.next = bucket.next + 1
  table.insert(bucket.entries, {
    n = bucket.next, pc = level, version = PC.version,
    sender = sender, kind = kind, poi = poi, generation = generation,
  })
  keys[key] = true
  while table.getn(bucket.entries) > MAX_ENTRIES do
    local old = table.remove(bucket.entries, 1)
    keys[Key(old.pc, old.sender, old.kind, old.poi, old.generation)] = nil
    self.evicted = self.evicted + 1
  end
  self.recorded = self.recorded + 1
  Record("WITNESS", { sender = sender, kind = kind, id = poi, generation = generation })
  return true
end

function Witness:Count()
  local bucket = self:Bucket()
  if not bucket then return 0 end
  return table.getn(bucket.entries)
end
