PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Capture = {
  states = {},
  owners = {},
  presence = {},
  quotas = {},
  quotaCount = 0,
  alerts = {},
  captured = {},
  listeners = {},
  here = nil,
  sent = 0,
  sendFailures = 0,
  rejected = 0,
  received = 0,
  ignored = 0,
  duplicates = 0,
}

PC.Capture = Capture

-- OUTPOST capture (docs/capture.md, decision 0012). Progress is in thousandths
-- of the challenger's share. Modes: R rest, P push, C contested, D return.
local CAPTURE_DURATION = 180
local DECAY_DURATION = 360
local FULL_RATE = 1000 / CAPTURE_DURATION
local HALF_RATE = 1000 / DECAY_DURATION
local PRESENCE_INTERVAL = 10
local PRESENCE_TTL = 25
-- A defender of an idle POI it owns, with no rival in sight, slows down; each
-- P names its cadence so receivers keep it alive long enough (decision 0033).
local PRESENCE_REST_INTERVAL = 30
local PRESENCE_REST_TTL = 75
-- Alone at rest, nobody counts on it but distant observers (decision 0034).
local PRESENCE_LONE_INTERVAL = 60
local PRESENCE_LONE_TTL = 150
local STATE_INTERVAL = 5
local MIN_BROADCAST_GAP = 1
-- The authority also broadcasts each time the bar crosses a 5 % step (decision 0023).
local PROGRESS_STEP = 50
local AUTHORITY_SILENCE = 15
local ENTRY_GRACE = 3.5
local TICK_INTERVAL = 0.25
local ELIGIBILITY_INTERVAL = 1
local MAP_INTERVAL = 1
local ALERT_COOLDOWN = 60
local PLAUSIBILITY_SLACK = 30
local MAX_PRESENCE_PER_POI = 40
-- Incoming quota per sender and 10 s window (decision 0029). The total equals
-- what the send gate can emit (one message per 0.25 s, so 40) plus 20 % for
-- delivery jitter: an honest client is never refused. The per-kind limits
-- bound the kinds a liar could abuse: kills (risk B11) and requests, whose
-- answers every peer prepares (risk B8).
local QUOTA_WINDOW = 10
local QUOTA_TOTAL = 48
local QUOTA_BY_KIND = { S = 40, P = 20, Q = 6, HQ = 6, H = 10, K = 20 }
local MAX_QUOTA_SENDERS = 200
local SCHEMA = 1
local MAX_ARCHIVED_LEVELS = 3
local CAMPAIGN = "permanent"

Capture.CAPTURE_DURATION = CAPTURE_DURATION
Capture.DECAY_DURATION = DECAY_DURATION
Capture.PROGRESS_STEP = PROGRESS_STEP

local FACTION_KEYS = { H = "HORDE", A = "ALLIANCE" }
local FACTION_CODES = { HORDE = "H", ALLIANCE = "A" }
local FACTION_NAMES = { H = "Horde", A = "Alliance", N = "Neutral" }
local OWNERS = { N = true, H = true, A = true }
local SIDES = { ["-"] = true, H = true, A = true }
local MODES = { R = true, P = true, C = true, D = true }
-- One-letter wire codes for presence statuses and state events (decision 0027).
local STATUS_CODES = { IN = "I", NC = "N", OUT = "O" }
local CODE_STATUSES = { I = "IN", N = "NC", O = "OUT" }
local EVENT_CODES = { START = "S", CAPTURED = "C" }
local CODE_EVENTS = { ["-"] = "-", S = "START", C = "CAPTURED" }
-- Presence cadence: F every 10 s, R at rest every 30 s (decision 0033), L
-- alone at rest every 60 s (decision 0034). Lifetime = 2.5 intervals.
local CADENCE_TTLS = { F = PRESENCE_TTL, R = PRESENCE_REST_TTL, L = PRESENCE_LONE_TTL }
local CADENCE_INTERVALS = { F = PRESENCE_INTERVAL, R = PRESENCE_REST_INTERVAL, L = PRESENCE_LONE_INTERVAL }
local CADENCE_RANKS = { F = 1, R = 2, L = 3 }

Capture.FACTION_NAMES = FACTION_NAMES

-- 1.12 has no IsMounted, IsStealthed or UnitIsAFK. Without nampower or
-- VanillaHelpers, mount and stealth come from buff icons (an unknown icon is
-- not detected); AFK always comes from system messages.
local MOUNT_TEXTURES = { "ability_mount_", "inv_misc_foot_kodo", "qirajicrystal", "spell_nature_swiftness" }
local STEALTH_TEXTURES = { "ability_stealth", "ability_ambush", "invisibilty", "invisibility" }

local function GetGlobal(name)
  if getglobal then return getglobal(name) end
  if _G then return _G[name] end
  return nil
end

local function Call(name, a, b)
  local fn = GetGlobal(name)
  if type(fn) ~= "function" then return false end
  return pcall(fn, a, b)
end

local function Now()
  local now = PC.Now and PC.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

-- Wall clock, for timestamps that must survive a client restart.
local function Epoch()
  local epoch = PC.Epoch and PC.Epoch() or 0
  if type(epoch) ~= "number" then return 0 end
  return epoch
end

local function Floor(value)
  return math.floor(value + 0.0000001)
end

local function Record(kind, fields)
  if PC.Record then PC.Record(kind, fields) end
end

local function Print(text)
  if PC.Print then PC.Print(text) end
end

local function Split(text, separator)
  local parts = {}
  local start = 1
  while true do
    local position = string.find(text, separator, start, true)
    if not position then
      table.insert(parts, string.sub(text, start))
      return parts
    end
    table.insert(parts, string.sub(text, start, position - 1))
    start = position + 1
  end
end

local function Int(text, maximum)
  if type(text) ~= "string" or not string.find(text, "^%d+$") or string.len(text) > 9 then
    return nil
  end
  local value = tonumber(text)
  if not value or value > maximum then return nil end
  return value
end

local function Copy(st)
  return {
    id = st.id, owner = st.owner, generation = st.generation,
    challenger = st.challenger, progress = st.progress, mode = st.mode, dir = st.dir,
    nH = st.nH, nA = st.nA, epoch = st.epoch, seq = st.seq,
  }
end

-- Moves a state forward by dt seconds in its current mode. Observers pass
-- allowCapture=false: only the authority completes a capture.
local function Advance(st, dt, allowCapture)
  local event = nil
  local guard = 0
  while dt > 0 and guard < 4 do
    guard = guard + 1
    if st.mode == "P" and FACTION_KEYS[st.dir] then
      local side = st.dir
      if st.challenger == "-" then
        if side == st.owner then return event end
        st.challenger = side
        st.progress = 0
      end
      if st.challenger == side then
        local need = (1000 - st.progress) / FULL_RATE
        if dt < need then
          st.progress = st.progress + FULL_RATE * dt
          return event
        end
        if not allowCapture then
          st.progress = 1000
          return event
        end
        dt = dt - need
        st.owner = side
        st.generation = st.generation + 1
        st.challenger = "-"
        st.progress = 0
        event = "CAPTURED"
      else
        -- The owner defends, or on a neutral POI the other faction must first
        -- bring the challenger back to 0 before building its own share.
        local need = st.progress / FULL_RATE
        if dt < need then
          st.progress = st.progress - FULL_RATE * dt
          return event
        end
        dt = dt - need
        st.challenger = "-"
        st.progress = 0
      end
    elseif st.mode == "D" then
      if st.challenger ~= "-" then
        local need = st.progress / HALF_RATE
        if dt < need then
          st.progress = st.progress - HALF_RATE * dt
          return event
        end
      end
      st.challenger = "-"
      st.progress = 0
      st.mode = "R"
      return event
    else
      return event
    end
  end
  return event
end

Capture.Advance = Advance

local function ModeFromCounts(nH, nA, st)
  if nH > nA then return "P", "H" end
  if nA > nH then return "P", "A" end
  if nH > 0 then return "C", "-" end
  if st.challenger == "-" then return "R", "-" end
  return "D", "-"
end

local function IsIdle(st)
  if st.challenger ~= "-" then return false end
  return not (st.mode == "P" and st.dir ~= st.owner)
end

-- Signed position on the bar within one owner: Horde share positive.
local function Position(st)
  if st.challenger == "H" then return st.progress end
  if st.challenger == "A" then return -st.progress end
  return 0
end

-- Identity ------------------------------------------------------------------

local function Realm()
  local ok, realm = Call("GetRealmName")
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

function Capture.Identity(name)
  if type(name) ~= "string" or name == "" then return nil end
  local dash = string.find(name, "-", 1, true)
  if dash and dash > 1 then
    return string.sub(name, 1, dash - 1) .. "@" .. string.sub(name, dash + 1)
  end
  return name .. "@" .. Realm()
end

function Capture:Me()
  if not self.me then
    local ok, name = Call("UnitName", "player")
    if ok and type(name) == "string" and name ~= "" then self.me = Capture.Identity(name) end
  end
  return self.me
end

function Capture:MyFaction()
  local ok, faction = Call("UnitFactionGroup", "player")
  if ok and faction == "Horde" then return "H" end
  if ok and faction == "Alliance" then return "A" end
  return nil
end

-- Catalogue and ownership -----------------------------------------------------

function Capture:Outpost(id)
  local map = PC.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.type == "OUTPOST" and area.enabled then return area end
  return nil
end

-- OUTPOST and HUNTING_GROUNDS share one owner registry; only outposts use the
-- timed bar below, hunting grounds use modules/hunting.lua (decision 0026).
function Capture:Capturable(id)
  local map = PC.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.enabled and (area.type == "OUTPOST" or area.type == "HUNTING_GROUNDS") then
    return area
  end
  return nil
end

local function StaticOwner(area)
  local key = area.baseColorKey
  if key == nil then key = area.colorKey end
  return FACTION_CODES[key or ""] or "N"
end

function Capture:GetOwner(id)
  local entry = self.owners[id]
  if entry then return entry.owner, entry.generation, entry.source end
  local area = self:Capturable(id)
  return area and StaticOwner(area) or "N", 0, "STATIC"
end

local function OwnerWins(owner, generation, currentOwner, currentGeneration)
  if generation ~= currentGeneration then return generation > currentGeneration end
  if owner == currentOwner then return false end
  -- Equal generations only diverge after a network partition: HORDE first.
  return owner == "H"
end

-- Captures are kept per channel compatibility level PC<n> (decision 0029):
-- owners agreed on by another level's network never enter this one, and
-- nothing is erased (rule R7). The realms of other levels wait in archive;
-- data saved before levels existed follows the same rules as level 2.
function Capture.SelectLevel(captures, level)
  if type(level) ~= "number" then return end
  local current = tonumber(captures.level)
  if not current then
    captures.level = level
    return
  end
  if current == level then return end
  if type(captures.archive) ~= "table" then captures.archive = {} end
  captures.archive[current] = captures.realms
  local restored = captures.archive[level]
  captures.archive[level] = nil
  captures.realms = type(restored) == "table" and restored or {}
  captures.level = level
  -- Bounded (rule R9): only the most recent other levels are kept.
  while true do
    local count, lowest = 0, nil
    local key
    for key in pairs(captures.archive) do
      count = count + 1
      if type(key) ~= "number" then
        lowest = key
        break
      end
      if not lowest or key < lowest then lowest = key end
    end
    if count <= MAX_ARCHIVED_LEVELS then break end
    captures.archive[lowest] = nil
  end
  Record("CAPTURE_LEVEL_SWITCH", { from = current, to = level })
end

-- The realm bucket: stable owners (pois) and in-progress bars (progress).
function Capture:Bucket()
  local storage = PC.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  local captures = db.captures
  if type(captures) == "table" and type(captures.schema) == "number" and captures.schema > SCHEMA then
    return nil
  end
  if type(captures) ~= "table" or captures.schema ~= SCHEMA then
    captures = { schema = SCHEMA, campaignId = CAMPAIGN, realms = {} }
    db.captures = captures
  end
  if type(captures.realms) ~= "table" then captures.realms = {} end
  Capture.SelectLevel(captures, PC.channelLevel)
  local realm = Realm()
  local bucket = captures.realms[realm]
  if type(bucket) ~= "table" then
    bucket = {}
    captures.realms[realm] = bucket
  end
  if type(bucket.pois) ~= "table" then bucket.pois = {} end
  if type(bucket.progress) ~= "table" then bucket.progress = {} end
  if type(bucket.hunting) ~= "table" then bucket.hunting = {} end
  return bucket
end

function Capture:Store()
  local bucket = self:Bucket()
  return bucket and bucket.pois or nil
end

function Capture:LoadOwners()
  local bucket = self:Bucket()
  if not bucket then return false end
  local pois = bucket.pois
  self.loaded = true
  local stale = {}
  local id, entry
  for id, entry in pairs(pois) do
    local owner = type(entry) == "table" and FACTION_CODES[entry.owner or ""]
    local generation = type(entry) == "table" and tonumber(entry.generation)
    if not self:Capturable(id) or not owner or not generation or generation < 1
        or Floor(generation) ~= generation then
      table.insert(stale, id)
    else
      local source = entry.source == "LOCAL" and "LOCAL" or "PEER"
      local currentOwner, currentGeneration = self:GetOwner(id)
      if OwnerWins(owner, generation, currentOwner, currentGeneration) then
        self.owners[id] = { owner = owner, generation = generation, source = source }
      end
      if generation > (self.captured[id] or 0) then self.captured[id] = generation end
    end
  end
  local index = 1
  while index <= table.getn(stale) do
    pois[stale[index]] = nil
    index = index + 1
  end
  self:RestoreProgress(bucket)
  if PC.Hunting then PC.Hunting:Restore(bucket) end
  return true
end

-- Bars saved at logout, /reload or disconnect (decision 0017). Nobody is assumed
-- present while away, so the bar returns at the decay rate for that time. The
-- state stays unknown: Q is still sent and any peer state replaces it.
function Capture:RestoreProgress(bucket)
  local saved = bucket.progress
  bucket.progress = {}
  local now, epoch = Now(), Epoch()
  local id, entry
  for id, entry in pairs(saved) do
    local st = self.states[id]
    if type(entry) == "table" and self:Outpost(id) and not (st and st.known) then
      local owner, generation = self:GetOwner(id)
      local progress = tonumber(entry.progress)
      local at = tonumber(entry.at)
      local savedEpoch = tonumber(entry.epoch)
      if entry.owner == owner and tonumber(entry.generation) == generation
          and (entry.challenger == "H" or entry.challenger == "A") and entry.challenger ~= owner
          and progress and progress > 0 and progress < 1000 and at and at <= epoch
          and savedEpoch and savedEpoch >= 0 and savedEpoch <= 1000000 then
        local left = progress - HALF_RATE * (epoch - at)
        if left > 0 then
          st = self:GetState(id)
          st.owner, st.generation = owner, generation
          st.challenger, st.progress = entry.challenger, left
          st.mode, st.dir, st.nH, st.nA = "D", "-", 0, 0
          st.epoch = math.max(st.epoch, Floor(savedEpoch))
          st.at, st.lastStateAt = now, now
          bucket.progress[id] = entry
          Record("CAPTURE_RESTORED", { id = id, progress = Floor(left) })
        end
      end
    end
  end
end

-- Rewrites the saved bars from the extrapolated states; idle POIs drop out.
function Capture:SaveProgress(now)
  if not self.loaded then return end
  local bucket = self:Bucket()
  if not bucket then return end
  local progress = {}
  local epoch = Epoch()
  local id, st
  for id, st in pairs(self.states) do
    local view = self:GetView(id, now)
    if view.challenger ~= "-" and view.progress > 0 and view.progress < 1000 then
      progress[id] = {
        owner = view.owner, generation = view.generation, challenger = view.challenger,
        progress = Floor(view.progress), epoch = st.epoch, at = epoch,
      }
    end
  end
  bucket.progress = progress
end

function Capture:MergeOwner(id, owner, generation, source)
  if not FACTION_KEYS[owner] or generation < 1 then return false end
  local currentOwner, currentGeneration = self:GetOwner(id)
  if not OwnerWins(owner, generation, currentOwner, currentGeneration) then return false end
  self.owners[id] = { owner = owner, generation = generation, source = source }
  local pois = self:Store()
  if pois then
    pois[id] = { owner = FACTION_KEYS[owner], generation = generation, source = source }
  end
  return true
end

-- States ----------------------------------------------------------------------

function Capture:GetState(id)
  local st = self.states[id]
  if st then return st end
  local owner, generation = self:GetOwner(id)
  st = {
    id = id, owner = owner, generation = generation, challenger = "-", progress = 0,
    mode = "R", dir = "-", nH = 0, nA = 0, epoch = 0, seq = 0,
    at = Now(), lastStateAt = -1000, lastBroadcastAt = -1000, known = false,
  }
  self.states[id] = st
  return st
end

-- The state extrapolated to now, without completing a capture.
function Capture:GetView(id, now)
  local st = self.states[id]
  if not st then return nil end
  local view = Copy(st)
  Advance(view, (now or Now()) - st.at, false)
  return view
end

-- Owner from the monotonic registry, plus the challenger's half-captured icon.
function Capture:GetDisplay(id, now)
  local owner = self:GetOwner(id)
  local view = self:GetView(id, now)
  local half = nil
  if view and view.owner == owner and view.challenger ~= "-" and view.progress >= 500 then
    half = view.challenger
  end
  return owner, half, view
end

-- Presence ------------------------------------------------------------------

function Capture:PresenceList(id)
  local list = self.presence[id]
  if not list then
    list = { entries = {}, count = 0 }
    self.presence[id] = list
  end
  return list
end

-- ttl is the sender's announced lifetime (CADENCE_TTLS), PRESENCE_TTL if absent.
function Capture:SetPresence(id, identity, faction, status, now, ttl)
  local list = self:PresenceList(id)
  local entry = list.entries[identity]
  if status == "OUT" then
    if entry then
      list.entries[identity] = nil
      list.count = list.count - 1
    end
    return
  end
  if not entry then
    if list.count >= MAX_PRESENCE_PER_POI then
      local oldestId, oldestAt = nil, nil
      local key, value
      for key, value in pairs(list.entries) do
        if key ~= self:Me() and (not oldestAt or value.at < oldestAt) then
          oldestId, oldestAt = key, value.at
        end
      end
      if not oldestId then return end
      list.entries[oldestId] = nil
      list.count = list.count - 1
    end
    entry = {}
    list.entries[identity] = entry
    list.count = list.count + 1
  end
  entry.faction = faction
  entry.status = status
  entry.at = now
  entry.expireAt = now + (ttl or PRESENCE_TTL)
  -- A rival in the POI ends the slow cadences: no entry outlives the normal
  -- lifetime from now, so a silent defender is not counted 50 s too long.
  -- A second player ends the lone one: nobody outlives the rest lifetime.
  -- Idempotent: repeating a presence never lengthens what this shortened.
  local owner = self:GetOwner(id)
  local cap = nil
  if self:HasRival(id, owner, now) then
    cap = PRESENCE_TTL
  elseif self:LiveCount(id, now) > 1 then
    cap = PRESENCE_REST_TTL
  end
  if cap then
    local limit = now + cap
    local key, value
    for key, value in pairs(list.entries) do
      if value.expireAt > limit then value.expireAt = limit end
    end
  end
end

local function Live(entry, identity, me, now)
  return identity == me or now <= entry.expireAt
end

function Capture:HasPresence(id, identity, now)
  local list = self.presence[id]
  local entry = list and list.entries[identity]
  return entry ~= nil and Live(entry, identity, self:Me(), now)
end

-- A live presence, IN or NC, of a faction other than the given one.
function Capture:HasRival(id, faction, now)
  local list = self.presence[id]
  if not list then return false end
  local me = self:Me()
  local identity, entry
  for identity, entry in pairs(list.entries) do
    if entry.faction ~= faction and Live(entry, identity, me, now) then return true end
  end
  return false
end

-- Live presences in a POI, the local player included.
function Capture:LiveCount(id, now)
  local list = self.presence[id]
  if not list then return 0 end
  local me = self:Me()
  local count = 0
  local identity, entry
  for identity, entry in pairs(list.entries) do
    if Live(entry, identity, me, now) then count = count + 1 end
  end
  return count
end

-- An accepted live S proves its producer is still there as much as a P does:
-- it extends, never shortens, the producer's presence (decision 0034).
function Capture:RefreshPresence(id, identity, now)
  local list = self.presence[id]
  local entry = list and list.entries[identity]
  if not entry then return end
  entry.at = now
  if entry.expireAt < now + PRESENCE_TTL then entry.expireAt = now + PRESENCE_TTL end
end

-- Counted players per faction and sorted candidates; drops expired entries.
function Capture:Count(id, now)
  local list = self:PresenceList(id)
  local nH, nA = 0, 0
  local candidates = {}
  local expired = {}
  local me = self:Me()
  local identity, entry
  for identity, entry in pairs(list.entries) do
    if not Live(entry, identity, me, now) then
      table.insert(expired, identity)
    else
      table.insert(candidates, identity)
      if entry.status == "IN" then
        if entry.faction == "H" then nH = nH + 1 elseif entry.faction == "A" then nA = nA + 1 end
      end
    end
  end
  local index = 1
  while index <= table.getn(expired) do
    list.entries[expired[index]] = nil
    list.count = list.count - 1
    index = index + 1
  end
  table.sort(candidates)
  return nH, nA, candidates
end

-- Local eligibility -----------------------------------------------------------

local function HasBuff(patterns)
  local index = 1
  while index <= 32 do
    local ok, texture = Call("UnitBuff", "player", index)
    if not ok or type(texture) ~= "string" then return false end
    local lower = string.lower(texture)
    local p = 1
    while p <= table.getn(patterns) do
      if string.find(lower, patterns[p], 1, true) then return true end
      p = p + 1
    end
    index = index + 1
  end
  return false
end

local function Flag(name, fallback)
  local fn = GetGlobal(name)
  if type(fn) == "function" then
    local ok, value = pcall(fn, "player")
    if ok then return value and value ~= 0 and true or false end
  end
  if fallback then return fallback() end
  return false
end

-- Optional DLLs give exact answers: nampower's GetUnitField reads the mount
-- display and the aura spell IDs, whose aura type GetSpellRecField resolves;
-- VanillaHelpers' UnitDisplayInfo also returns the mount display.
-- SPELL_AURA_MOD_STEALTH and SPELL_AURA_MOD_INVISIBILITY in the 1.12 server enum.
local STEALTH_AURA_TYPES = { [16] = true, [18] = true }
local stealthSpells = {}

local function MountedByDll()
  local field = GetGlobal("GetUnitField")
  if type(field) == "function" then
    local ok, mount = pcall(field, "player", "mountDisplayId")
    if ok and type(mount) == "number" then return mount > 0, "nampower" end
  end
  local display = GetGlobal("UnitDisplayInfo")
  if type(display) == "function" then
    local ok, _, _, mount = pcall(display, "player")
    if ok and type(mount) == "number" then return mount > 0, "VanillaHelpers" end
  end
  return nil
end

local function IsStealthSpell(record, spellId)
  local known = stealthSpells[spellId]
  if known ~= nil then return known end
  local stealth = false
  local ok, auraTypes = pcall(record, spellId, "effectApplyAuraName")
  if ok and type(auraTypes) == "table" then
    local index = 1
    while index <= 3 do
      if STEALTH_AURA_TYPES[auraTypes[index]] then stealth = true end
      index = index + 1
    end
  end
  stealthSpells[spellId] = stealth
  return stealth
end

local function StealthedByDll()
  local field = GetGlobal("GetUnitField")
  local record = GetGlobal("GetSpellRecField")
  if type(field) ~= "function" or type(record) ~= "function" then return nil end
  local ok, auras = pcall(field, "player", "aura")
  if not ok or type(auras) ~= "table" then return nil end
  local index = 1
  while index <= 48 do
    local spellId = auras[index]
    if type(spellId) == "number" and spellId > 0 and IsStealthSpell(record, spellId) then return true end
    index = index + 1
  end
  return false
end

local function AlwaysTrue() return true end

function Capture:Eligibility()
  if Flag("UnitIsDeadOrGhost") then return "NC", "dead" end
  if Capture.afk then return "NC", "AFK" end
  if not Flag("UnitIsPVP", AlwaysTrue) then return "NC", "not PvP flagged" end
  local mounted, source = MountedByDll()
  if mounted == nil then mounted, source = HasBuff(MOUNT_TEXTURES), "buff icons" end
  Capture.mountSource = source
  if mounted then return "NC", "mounted" end
  local stealthed = StealthedByDll()
  Capture.stealthSource = stealthed == nil and "buff icons" or "nampower"
  if stealthed == nil then stealthed = HasBuff(STEALTH_TEXTURES) end
  if stealthed then return "NC", "stealthed or invisible" end
  return "IN", nil
end

local function AfkPrefix(name, fallback)
  local text = GetGlobal(name)
  if type(text) ~= "string" then return fallback end
  local cut = string.find(text, "%", 1, true)
  if cut then text = string.sub(text, 1, cut - 1) end
  return text
end

function Capture:OnSystemMessage(message)
  if type(message) ~= "string" then return end
  local marked = AfkPrefix("MARKED_AFK", "You are now AFK")
  local cleared = AfkPrefix("CLEARED_AFK", "You are no longer AFK")
  if cleared ~= "" and string.find(message, cleared, 1, true) == 1 then
    self.afk = false
  elseif marked ~= "" and string.find(message, marked, 1, true) == 1 then
    self.afk = true
  end
end

-- Transport -------------------------------------------------------------------

-- kind is the event id (P, S, Q, K, H, HQ), body its comma-separated fields;
-- key lets the send gate replace a queued message that this one supersedes;
-- priority marks an event message, dropped last by a full send queue.
function Capture:Send(kind, body, key, priority)
  local p2p = PC.P2PTest
  if not p2p or type(p2p.SendChannelEvent) ~= "function" then
    self.sendFailures = self.sendFailures + 1
    self.lastSendError = "P2P transport unavailable"
    return false
  end
  local ok, accepted, err = pcall(p2p.SendChannelEvent, kind, body, key, priority)
  if ok and accepted then
    self.sent = self.sent + 1
    return true
  end
  self.sendFailures = self.sendFailures + 1
  self.lastSendError = tostring(ok and err or accepted)
  return false
end

function Capture:SendPresence(id, status, cadence)
  local faction = self:MyFaction()
  if not faction then return false end
  return self:Send("P", id .. "," .. faction .. "," .. STATUS_CODES[status] .. "," .. (cadence or "F"))
end

-- R only for a defender of an idle POI its faction owns, with no rival
-- presence: nothing can start there until a rival's P arrives, which ends it.
-- L for the same defender when nobody else is live in the POI.
function Capture:PresenceCadence(id, faction, now)
  local st = self.states[id]
  if not st or not st.known or not IsIdle(st) then return "F" end
  if st.owner ~= faction or self:GetOwner(id) ~= faction then return "F" end
  if self:HasRival(id, faction, now) then return "F" end
  if self:LiveCount(id, now) <= 1 then return "L" end
  return "R"
end

-- A state carrying an event is never superseded and is dropped last by a full
-- send queue, so START and CAPTURED survive.
function Capture:SendState(st, event, age)
  local key
  if not event then key = "S," .. st.id end
  return self:Send("S", st.id .. "," .. st.epoch .. "," .. st.seq .. "," .. st.owner
    .. "," .. st.generation .. "," .. st.challenger .. "," .. Floor(st.progress)
    .. "," .. st.mode .. "," .. st.dir .. "," .. st.nH .. "," .. st.nA
    .. "," .. (event and EVENT_CODES[event] or "-") .. "," .. Floor(age or 0), key, event ~= nil)
end

-- 5 % step of the challenger's share; "-" while nobody is capturing.
local function ProgressStep(st)
  if st.challenger == "-" then return "-" end
  return st.challenger .. Floor(st.progress / PROGRESS_STEP)
end

-- Events ----------------------------------------------------------------------

function Capture:OnEvent(callback)
  if type(callback) == "function" then table.insert(self.listeners, callback) end
end

function Capture:Emit(kind, id, side)
  local index = 1
  while index <= table.getn(self.listeners) do
    local ok, err = pcall(self.listeners[index], kind, id, side)
    if not ok and PC.RecordError then PC.RecordError("capture listener", err) end
    index = index + 1
  end
end

-- generation: the POI generation the event belongs to. A capture is identified
-- by (POI, generation), so it is announced once even when two authorities, a
-- repeated state or a hunting relay report it again.
function Capture:HandleEvent(id, event, side, now, generation)
  if event == "START" then
    local mine = self:MyFaction()
    if not mine or side == mine then return end
    local key = id .. ":" .. side
    local last = self.alerts[key]
    if last and now - last < ALERT_COOLDOWN then return end
    self.alerts[key] = now
    Record("CAPTURE_ALERT", { id = id, attacker = side })
    self:Emit("ALERT", id, side)
  elseif event == "CAPTURED" then
    if not generation or generation <= (self.captured[id] or 0) then
      self.duplicates = self.duplicates + 1
      Record("CAPTURE_DUPLICATE", { id = id, owner = side, generation = generation })
      return
    end
    self.captured[id] = generation
    Record("CAPTURE_DONE", { id = id, owner = side, generation = generation })
    self:Emit("CAPTURED", id, side)
  end
end

-- Authority -------------------------------------------------------------------

function Capture:AuthorityStep(id, now, force)
  local st = self.states[id]
  local nH, nA = self:Count(id, now)
  local event = Advance(st, now - st.at, true)
  st.at = now
  local mode, dir = ModeFromCounts(nH, nA, st)
  if not event and mode == "P" and dir ~= st.owner and not (st.mode == "P" and st.dir == dir) then
    event = "START"
  end
  local transition = event ~= nil or mode ~= st.mode or dir ~= st.dir
  local recounted = nH ~= st.nH or nA ~= st.nA
  local step = ProgressStep(st)
  local stepped = step ~= st.lastStep
  st.mode, st.dir, st.nH, st.nA = mode, dir, nH, nA
  st.lastStateAt = now
  if event == "CAPTURED" then
    self:MergeOwner(id, st.owner, st.generation, "LOCAL")
  end

  -- Busy POIs repeat every 5 s; once idle, one confirmation follows so a lost
  -- transition (for example CAPTURED) does not leave observers stale.
  local elapsed = now - st.lastBroadcastAt
  local due
  if IsIdle(st) then
    due = not st.settled and elapsed >= STATE_INTERVAL
  else
    st.settled = false
    due = elapsed >= STATE_INTERVAL
  end
  if force or transition or stepped or (recounted and elapsed >= MIN_BROADCAST_GAP) or due then
    if IsIdle(st) and not transition and not force and due then st.settled = true end
    st.seq = st.seq + 1
    st.lastBroadcastAt = now
    st.lastStep = step
    self:SendState(st, event, 0)
  end
  if event == "START" then
    self:HandleEvent(id, "START", dir, now)
  elseif event == "CAPTURED" then
    self:HandleEvent(id, "CAPTURED", st.owner, now, st.generation)
  end
end

function Capture:AuthorityLost(st, now)
  local me = self:Me()
  if st.authority and st.authority == me then return false end
  if st.authority then
    if not self:HasPresence(st.id, st.authority, now) then return true end
    if not IsIdle(st) and now - st.lastStateAt > AUTHORITY_SILENCE then return true end
    return false
  end
  if st.explicitOut then return true end
  -- A relayed push may still have a live authority we have not heard yet.
  if (st.mode == "P" or st.mode == "C") and now - st.lastStateAt <= AUTHORITY_SILENCE then
    return false
  end
  return true
end

function Capture:TakeOver(id, now)
  local st = self.states[id]
  Advance(st, now - st.at, false)
  st.at = now
  local owner, generation = self:GetOwner(id)
  if generation > st.generation then
    st.owner, st.generation = owner, generation
    if st.challenger == owner then
      st.challenger, st.progress = "-", 0
    end
  end
  st.epoch = st.epoch + 1
  st.seq = 0
  st.authority = self:Me()
  st.epochHolder = st.authority
  st.known = true
  st.takeoverAt = nil
  st.explicitOut = nil
  st.replyAt = nil
  Record("CAPTURE_AUTHORITY", { id = id, epoch = st.epoch })
  self:AuthorityStep(id, now, true)
end

-- Local presence --------------------------------------------------------------

function Capture:Enter(id, now)
  self.here = { id = id, enterAt = now, lastPresenceAt = -1000 }
  local st = self:GetState(id)
  self:UpdateEligibility(now, true)
  if not st.known then
    self.here.queried = true
    self:Send("Q", id)
  end
end

function Capture:Leave(id, now)
  local here = self.here
  self.here = nil
  local me = self:Me()
  if me then self:SetPresence(id, me, nil, "OUT", now) end
  local st = self.states[id]
  if st and me and st.authority == me then
    -- The last state goes out before OUT so peers still accept it.
    self:AuthorityStep(id, now, true)
    st.authority = nil
  end
  if st then st.takeoverAt = nil end
  if here and here.status then self:SendPresence(id, "OUT") end
end

function Capture:OnPresenceChange(area, previous)
  local now = Now()
  if previous and previous.type == "OUTPOST" and self.here and self.here.id == previous.id then
    self:Leave(previous.id, now)
  end
  if area and self:Outpost(area.id) then
    self:Enter(area.id, now)
  end
end

function Capture:UpdateEligibility(now, force)
  local here = self.here
  if not here then return end
  local me = self:Me()
  local faction = self:MyFaction()
  if not me or not faction then
    here.status, here.reason = nil, "faction unknown"
    return
  end
  local status, reason = self:Eligibility()
  local changed = status ~= here.status
  here.status, here.reason = status, reason
  here.faction = faction
  self:SetPresence(here.id, me, faction, status, now)
  local cadence = self:PresenceCadence(here.id, faction, now)
  -- A faster cadence goes out at once: receivers then expect the next P
  -- sooner. A slower one waits for the P due under the previous cadence.
  local last = here.cadence or "F"
  local woken = CADENCE_RANKS[cadence] < CADENCE_RANKS[last]
  -- The authority of a busy POI repeats its S at least every 5 s, which keeps
  -- its presence alive (RefreshPresence): no periodic P then (decision 0034).
  local st = self.states[here.id]
  local streaming = st ~= nil and st.authority == me and not IsIdle(st)
  local due = not streaming and now - here.lastPresenceAt >= CADENCE_INTERVALS[last]
  if force or changed or woken or due then
    here.lastPresenceAt = now
    here.cadence = cadence
    self:SendPresence(here.id, status, cadence)
  end
end

-- Incoming messages -----------------------------------------------------------

function Capture:Reject(reason, sender)
  self.rejected = self.rejected + 1
  self.lastReject = reason
  Record("CAPTURE_REJECTED", { reason = reason, sender = sender })
  return false
end

Capture.QUOTA_WINDOW = QUOTA_WINDOW
Capture.QUOTA_TOTAL = QUOTA_TOTAL
Capture.QUOTA_BY_KIND = QUOTA_BY_KIND

-- A full table drops expired windows first, then the oldest one; it is never
-- emptied at once, so quotas keep working with many senders (risk B7).
function Capture:EvictQuota(now)
  local oldest, oldestStart
  local sender, quota
  for sender, quota in pairs(self.quotas) do
    if now - quota.start >= QUOTA_WINDOW then
      oldest = sender
      break
    end
    if not oldestStart or quota.start < oldestStart then
      oldest, oldestStart = sender, quota.start
    end
  end
  if not oldest then return false end
  self.quotas[oldest] = nil
  self.quotaCount = self.quotaCount - 1
  return true
end

function Capture:AllowSender(sender, kind, now)
  local quota = self.quotas[sender]
  if not quota then
    while self.quotaCount >= MAX_QUOTA_SENDERS do
      if not self:EvictQuota(now) then self.quotaCount = 0 end
    end
    quota = { start = now, count = 0, kinds = {} }
    self.quotas[sender] = quota
    self.quotaCount = self.quotaCount + 1
  end
  if now - quota.start >= QUOTA_WINDOW then
    quota.start, quota.count, quota.kinds = now, 0, {}
  end
  quota.count = quota.count + 1
  local kindCount = (quota.kinds[kind] or 0) + 1
  quota.kinds[kind] = kindCount
  return quota.count <= QUOTA_TOTAL and kindCount <= (QUOTA_BY_KIND[kind] or QUOTA_TOTAL)
end

-- Removes a remote player from a POI; if it held the timer, that is an explicit OUT.
function Capture:DropPresence(id, sender, now)
  self:SetPresence(id, sender, nil, "OUT", now)
  local st = self.states[id]
  if st and st.authority == sender then
    st.authority = nil
    st.explicitOut = true
    st.takeoverAt = nil
  end
end

function Capture:OnPresenceMessage(sender, id, faction, status, now, cadence)
  if status == "OUT" then
    self:DropPresence(id, sender, now)
    return true
  end
  -- A player stands in one POI at a time: even if its OUT was lost, it is never
  -- counted in two POIs, nor kept as the authority of the one it left.
  local other, list
  for other, list in pairs(self.presence) do
    if other ~= id and list.entries[sender] then self:DropPresence(other, sender, now) end
  end
  self:SetPresence(id, sender, faction, status, now, CADENCE_TTLS[cadence])
  return true
end

function Capture:OnQuery(sender, id, now)
  local st = self.states[id]
  if not st or not st.known then return true end
  if st.authority and st.authority == self:Me() then
    self:AuthorityStep(id, now, true)
  elseif not st.replyAt then
    st.replyAt = now + 0.5 + math.random() * 2.5
  end
  return true
end

function Capture:CheckPlausible(st, f, now)
  local elapsed = math.max(0, now - st.lastStateAt)
  local reach = FULL_RATE * elapsed + PLAUSIBILITY_SLACK
  if f.owner ~= st.owner then
    if f.generation ~= st.generation + 1 or st.challenger ~= f.owner
        or st.progress + reach < 1000 then
      return false, "implausible owner change"
    end
    return true
  end
  if f.generation ~= st.generation then return false, "generation changed without owner" end
  if math.abs(Position(f) - Position(st)) > reach then
    return false, "implausible progress jump"
  end
  return true
end

function Capture:OnStateMessage(sender, f, now)
  local id = f.id
  local st = self:GetState(id)
  local me = self:Me()
  local live = f.age == 0

  if live then
    if not self:HasPresence(id, sender, now) then return self:Reject("state without presence", sender) end
    -- Like a P, even if a rule below refuses the state: a refused authority
    -- must not also lose its presence (decision 0034).
    self:RefreshPresence(id, sender, now)
    if st.known then
      if f.epoch < st.epoch then return self:Reject("old epoch", sender) end
      if f.epoch == st.epoch then
        -- The producer of the epoch is kept after it leaves, so its late or
        -- repeated states stay ordered; unknown (relayed) epochs are ordered too.
        local holder = st.authority or st.epochHolder
        if holder and holder ~= sender then
          if not (sender < holder) then return self:Reject("authority conflict lost", sender) end
        else
          if f.seq <= st.seq then return self:Reject("sequence already seen", sender) end
          local ok, reason = self:CheckPlausible(st, f, now)
          if not ok then return self:Reject(reason, sender) end
        end
      end
    end
  elseif st.known and f.epoch <= st.epoch then
    -- A relayed answer only fills in a POI we know nothing newer about.
    st.replyAt = nil
    return true
  end

  local wasMine = st.authority ~= nil and st.authority == me
  st.owner, st.generation = f.owner, f.generation
  st.challenger, st.progress = f.challenger, f.progress
  st.mode, st.dir, st.nH, st.nA = f.mode, f.dir, f.nH, f.nA
  st.epoch, st.seq = f.epoch, f.seq
  st.at = now - f.age
  st.lastStateAt = now - f.age
  st.known = true
  st.authority = live and sender or nil
  st.epochHolder = st.authority
  st.takeoverAt = nil
  st.explicitOut = nil
  st.replyAt = nil
  if wasMine then Record("CAPTURE_STEP_DOWN", { id = id, winner = sender }) end

  local present = self.here and self.here.id == id
  self:MergeOwner(id, f.owner, f.generation, present and "LOCAL" or "PEER")
  if live and f.event == "START" then
    self:HandleEvent(id, "START", f.dir, now)
  elseif live and f.event == "CAPTURED" then
    self:HandleEvent(id, "CAPTURED", f.owner, now, f.generation)
    -- The authority's own announce, accepted above; never a relayed answer.
    if PC.Witness then PC.Witness:Note(sender, "CAPTURED", id, f.generation) end
  end
  return true
end

-- parts: the S fields after the event id, starting with the POI.
function Capture:ParseState(parts)
  if table.getn(parts) ~= 13 then return nil, "bad S field count" end
  local f = {
    id = parts[1],
    epoch = Int(parts[2], 1000000),
    seq = Int(parts[3], 100000000),
    owner = parts[4],
    generation = Int(parts[5], 1000000),
    challenger = parts[6],
    progress = Int(parts[7], 1000),
    mode = parts[8],
    dir = parts[9],
    nH = Int(parts[10], MAX_PRESENCE_PER_POI),
    nA = Int(parts[11], MAX_PRESENCE_PER_POI),
    event = CODE_EVENTS[parts[12]],
    age = Int(parts[13], 3600),
  }
  if not f.epoch or not f.seq or not f.generation or not f.progress or not f.nH or not f.nA
      or not f.age then
    return nil, "bad S number"
  end
  if not OWNERS[f.owner] or not SIDES[f.challenger] or not MODES[f.mode] or not SIDES[f.dir]
      or not f.event then
    return nil, "bad S value"
  end
  if (f.owner == "N") ~= (f.generation == 0) or f.challenger == f.owner
      or (f.challenger == "-" and f.progress ~= 0) or ((f.mode == "P") ~= (f.dir ~= "-")) then
    return nil, "inconsistent S"
  end
  if f.event == "-" then f.event = nil end
  return f
end

function Capture:Ignore(reason, senderName)
  self.ignored = self.ignored + 1
  self.lastIgnore = reason .. " from " .. tostring(senderName)
  return false
end

-- Entry point for capture events received on the visible channel: kind is the
-- event id, data its comma-separated fields, POI first (decision 0027).
function Capture:OnMessage(kind, data, senderName, isEcho)
  self.received = self.received + 1
  if isEcho then return self:Ignore("session echo", senderName) end
  if type(kind) ~= "string" or type(data) ~= "string" then return self:Ignore("non-string data", senderName) end
  local sender = Capture.Identity(senderName)
  if not sender then return self:Ignore("no sender", senderName) end
  if sender == self:Me() then return self:Ignore("own identity", senderName) end
  local now = Now()
  if not self:AllowSender(sender, kind, now) then return self:Reject("quota " .. kind, sender) end

  local parts = Split(data, ",")
  local id = parts[1]
  if kind == "K" or kind == "H" or kind == "HQ" then
    if not PC.Hunting then return self:Reject("hunting unavailable", sender) end
    return PC.Hunting:OnMessage(kind, parts, sender, now)
  end
  if not self:Outpost(id) then return self:Reject("unknown outpost", sender) end

  if kind == "P" then
    local status = CODE_STATUSES[parts[3]]
    if table.getn(parts) ~= 4 or not FACTION_KEYS[parts[2]] or not status or not CADENCE_TTLS[parts[4]] then
      return self:Reject("bad P", sender)
    end
    return self:OnPresenceMessage(sender, id, parts[2], status, now, parts[4])
  elseif kind == "Q" then
    if table.getn(parts) ~= 1 then return self:Reject("bad Q", sender) end
    return self:OnQuery(sender, id, now)
  elseif kind == "S" then
    local f, err = self:ParseState(parts)
    if not f then return self:Reject(err, sender) end
    return self:OnStateMessage(sender, f, now)
  end
  return self:Reject("unknown kind", sender)
end

-- Driver ----------------------------------------------------------------------

function Capture:Maintain(id, st, now)
  local me = self:Me()
  if st.authority and st.authority == me then
    self:AuthorityStep(id, now, false)
    return
  end
  if st.replyAt and now >= st.replyAt then
    st.replyAt = nil
    self:SendState(st, nil, math.max(1, Floor(now - st.at)))
  end
  local present = self.here and self.here.id == id and self.here.status and me
  if not self:AuthorityLost(st, now) then
    st.takeoverAt = nil
    return
  end
  if present then
    if not st.takeoverAt then
      local _, _, candidates = self:Count(id, now)
      local rank = 0
      local index = 1
      while index <= table.getn(candidates) do
        if candidates[index] == me then rank = index - 1 end
        index = index + 1
      end
      local delay = 2 + 3 * rank
      if st.explicitOut and rank == 0 then delay = 0 end
      local earliest = now + delay
      if self.here.queried and earliest < self.here.enterAt + ENTRY_GRACE then
        earliest = self.here.enterAt + ENTRY_GRACE
      end
      st.takeoverAt = earliest
    elseif now >= st.takeoverAt then
      self:TakeOver(id, now)
    end
  elseif st.mode == "P" or st.mode == "C" then
    -- The authority vanished and nobody we know of holds the POI: return.
    Advance(st, now - st.at, false)
    st.at = now
    st.mode = st.challenger == "-" and "R" or "D"
    st.dir, st.nH, st.nA = "-", 0, 0
    st.authority = nil
  end
end

function Capture:UpdateMap(now)
  local map = PC.Map
  if not map or type(map.SetCaptureView) ~= "function" then return end
  local index = 1
  while index <= table.getn(map.order) do
    local id = map.order[index]
    if self:Outpost(id) then
      local owner, half = self:GetDisplay(id, now)
      map:SetCaptureView(id, FACTION_KEYS[owner], half and FACTION_KEYS[half] or nil)
    end
    index = index + 1
  end
end

function Capture:Tick()
  local now = Now()
  if now <= 0 then return end
  if self.lastTickAt and now - self.lastTickAt < TICK_INTERVAL then return end
  self.lastTickAt = now
  if not self.loaded then self:LoadOwners() end

  if self.here and (not self.lastEligibilityAt or now - self.lastEligibilityAt >= ELIGIBILITY_INTERVAL) then
    self.lastEligibilityAt = now
    self:UpdateEligibility(now, false)
  end
  local id, st
  for id, st in pairs(self.states) do
    self:Maintain(id, st, now)
  end
  if not self.lastMapAt or now - self.lastMapAt >= MAP_INTERVAL then
    self.lastMapAt = now
    self:UpdateMap(now)
    -- Every second, so a disconnect without PLAYER_LOGOUT loses at most that.
    self:SaveProgress(now)
  end
  if PC.Hunting then PC.Hunting:Tick(now) end
end

-- Display helpers ---------------------------------------------------------------

function Capture:Remaining(view)
  if not view then return nil end
  if view.mode == "P" then
    local side = view.dir
    if view.challenger == "-" then
      if side == view.owner then return nil end
      return 1000 / FULL_RATE
    end
    if view.challenger == side then return (1000 - view.progress) / FULL_RATE end
    local back = view.progress / FULL_RATE
    if view.owner == "N" then back = back + 1000 / FULL_RATE end
    return back
  elseif view.mode == "D" then
    return view.progress / HALF_RATE
  end
  return nil
end

function Capture:ModeText(view)
  local owner = FACTION_NAMES[view.owner]
  if view.mode == "P" then
    if view.dir == view.owner then
      if view.challenger == "-" then return "Controlled by " .. owner end
      return "Defending - " .. owner
    end
    return "Capturing - " .. FACTION_NAMES[view.dir]
  elseif view.mode == "C" then
    return "Contested (" .. view.nH .. " vs " .. view.nA .. ")"
  elseif view.mode == "D" then
    if view.owner == "N" then return "Returning to neutral" end
    return "Returning to " .. owner
  end
  if view.owner == "N" then return "Neutral" end
  return "Controlled by " .. owner
end

-- Capture details for the map tooltip, nil when the area cannot be captured:
-- owner, challenger and percent, status and seconds left, players inside, here.
function Capture:TooltipInfo(id, now)
  if not self:Capturable(id) then return nil end
  local info = { owner = self:GetOwner(id) }
  if PC.Hunting and PC.Hunting:Area(id) then
    PC.Hunting:TooltipInfo(id, info)
    return info
  end
  if not self:Outpost(id) then return info end
  local _, _, view = self:GetDisplay(id, now or Now())
  if view then
    if view.challenger ~= "-" then
      info.challenger = view.challenger
      info.percent = Floor(view.progress / 10)
    end
    -- An owner alone on its own outpost is plain control, already shown as owner.
    local idle = view.mode == "R" or (view.mode == "P" and view.dir == view.owner
      and view.challenger == "-")
    if not idle then
      info.status = self:ModeText(view)
      info.remaining = self:Remaining(view)
    end
    info.nH, info.nA = view.nH, view.nA
  end
  info.here = self.here ~= nil and self.here.id == id
  return info
end

-- Data for the HUD while the player stands in an outpost.
function Capture:GetHud(now)
  local here = self.here
  if not here then return nil end
  now = now or Now()
  local area = self:Outpost(here.id)
  if not area then return nil end
  local st = self:GetState(here.id)
  local view = self:GetView(here.id, now)
  local me = self:Me()
  return {
    id = here.id,
    area = area,
    view = view,
    known = st.known,
    authority = st.authority ~= nil and st.authority == me,
    status = here.status,
    reason = here.reason,
    remaining = self:Remaining(view),
  }
end

function Capture:PrintStatus()
  local now = Now()
  local here = self.here
  if here then
    Print("capture: in " .. here.id .. " as " .. tostring(here.status)
      .. (here.reason and (" (" .. here.reason .. ")") or ""))
  else
    Print("capture: not in an outpost")
  end
  Print("capture: mount detection=" .. tostring(self.mountSource or "not checked yet")
    .. " stealth detection=" .. tostring(self.stealthSource or "not checked yet"))
  local shown = 0
  local id, st
  for id, st in pairs(self.states) do
    local view = self:GetView(id, now)
    Print(string.format("capture: %s owner=%s gen=%d challenger=%s %d%% mode=%s epoch=%d authority=%s",
      id, view.owner, view.generation, view.challenger, Floor(view.progress / 10), view.mode,
      st.epoch, tostring(st.authority)))
    shown = shown + 1
  end
  local oid, entry
  for oid, entry in pairs(self.owners) do
    if not self.states[oid] then
      Print("capture: " .. oid .. " owner=" .. entry.owner .. " gen=" .. entry.generation
        .. " (" .. entry.source .. ")")
      shown = shown + 1
    end
  end
  if shown == 0 then Print("capture: no outpost state known yet") end
  Print("capture: sent=" .. self.sent .. " sendFailures=" .. self.sendFailures
    .. (self.lastSendError and (" lastError=" .. self.lastSendError) or "")
    .. " rejected=" .. self.rejected .. (self.lastReject and (" lastReject=" .. self.lastReject) or "")
    .. " duplicateCaptures=" .. self.duplicates)
  if PC.SendQueue then Print("capture: " .. PC.SendQueue:Summary()) end
  -- Live receive counters: SavedVariables diagnostics can lag or be stale.
  local p2p = PC.P2PTest or {}
  Print("capture: channelEvents=" .. (p2p.channelEvents or 0) .. " routed=" .. (p2p.capRouted or 0)
    .. " routeErrors=" .. (p2p.capErrors or 0)
    .. (p2p.lastCapError and (" lastRouteError=" .. p2p.lastCapError) or ""))
  Print("capture: received=" .. self.received .. " ignored=" .. self.ignored
    .. (self.lastIgnore and (" lastIgnore=" .. self.lastIgnore) or ""))
  if PC.lastHandlerError then Print("capture: lastHandlerError=" .. PC.lastHandlerError) end
  local counts = PC.eventCounts or {}
  local total, name, value = 0
  for name, value in pairs(counts) do total = total + value end
  Print("capture: dispatcher CHAT_MSG_CHANNEL=" .. (counts.CHAT_MSG_CHANNEL or 0)
    .. " CHAT_MSG_SYSTEM=" .. (counts.CHAT_MSG_SYSTEM or 0) .. " total=" .. total
    .. " unresolved=" .. (PC.unresolvedEvents or 0) .. " shape=" .. tostring(PC.handlerShape)
    .. " probe=" .. (p2p.probeChannelEvents or 0) .. "/" .. tostring(p2p.probeRegistered))
  local storage = PC.Storage
  local db = storage and type(storage.GetDB) == "function" and storage:GetDB() or nil
  local pois = self:Store()
  local stored = 0
  local key
  if pois then
    for key in pairs(pois) do stored = stored + 1 end
  end
  Print("capture: storage initialized=" .. tostring(storage and storage.initialized)
    .. " readOnly=" .. tostring(storage and storage.readOnly)
    .. " savedTable=" .. tostring(db ~= nil and db == GetGlobal("PandaConquestDB"))
    .. " loaded=" .. tostring(self.loaded) .. " realm=" .. Realm() .. " stored=" .. stored)
end

-- Wiring ------------------------------------------------------------------------

if PC.Presence and PC.Presence.OnChange then
  PC.Presence:OnChange(function(area, previous)
    Capture:OnPresenceChange(area, previous)
  end)
end

if PC.RegisterEvent then
  PC.RegisterEvent("CHAT_MSG_SYSTEM", function(eventName, message)
    Capture:OnSystemMessage(message)
  end)
  -- Fires on logout, quit and /reload, before SavedVariables are written.
  PC.RegisterEvent("PLAYER_LOGOUT", function()
    Capture:SaveProgress(Now())
  end)
end

local create = GetGlobal("CreateFrame")
if type(create) == "function" then
  local parent = GetGlobal("WorldFrame") or UIParent
  local frameOk, driver = pcall(create, "Frame", "PandaConquestCaptureDriver", parent)
  if frameOk and driver and type(driver.SetScript) == "function" then
    driver:SetScript("OnUpdate", function()
      local ok, err = pcall(Capture.Tick, Capture)
      if not ok and PC.RecordError then PC.RecordError("capture driver", err) end
    end)
    Capture.driver = driver
  elseif PC.RecordError then
    PC.RecordError("capture driver", "unable to create OnUpdate driver")
  end
end
