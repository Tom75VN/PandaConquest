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
  hints = {},
  -- Cloud owners of the import (decision 0060): one entry per POI, apart from
  -- the P2P hints, never persisted nor sent.
  cloud = {},
  -- Sender faction for the hint quorum. Only the chat language may fill it,
  -- once risk B12 is measured on OctoWoW; empty until then (decision 0038).
  senderFactions = {},
  promoted = 0,
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

-- OUTPOST and SETTLEMENT capture (docs/capture.md, decisions 0012, 0053).
-- Progress is in thousandths of the challenger's share. Modes: R rest, P push,
-- C contested or frozen, D return.
local CAPTURE_DURATION = 180
local DECAY_DURATION = 360
-- Each attempt carries its own full-bar duration, fixed when it starts and
-- announced in S (decision 0053): an Outpost from its garrison's defense,
-- 180 to 1,200 s (decision 0047); a Settlement always 600 s. An empty area
-- returns at half the attempt's speed.
local MAX_DURATION = 1200
local SETTLEMENT_DURATION = 600
-- A Settlement attempt needs two attackers to open and to advance.
local SIEGE_ATTACKERS = 2
-- Plausibility bound: the fastest attempt.
local MAX_RATE = 1000 / CAPTURE_DURATION
local PRESENCE_INTERVAL = 10
local PRESENCE_TTL = 25
-- A defender of an idle POI it owns, with no rival in sight, slows down; each
-- P names its cadence so receivers keep it alive long enough (decision 0033).
local PRESENCE_REST_INTERVAL = 30
local PRESENCE_REST_TTL = 75
-- Alone at rest, nobody counts on it but distant observers (decision 0034).
local PRESENCE_LONE_INTERVAL = 60
local PRESENCE_LONE_TTL = 150
-- A Settlement no faction can siege: no presence there moves a bar, W
-- every 60 s once it stayed so for QUIET_SETTLE, so every client learned the
-- owners that made it quiet before the first W (decision 0058).
local PRESENCE_QUIET_INTERVAL = 60
local PRESENCE_QUIET_TTL = 150
local QUIET_SETTLE = 30
-- A busy authority repeats its S every 30 s, and at once on a transition or a
-- recount; no 5 % steps (decision 0041). Three intervals of silence, as before.
local STATE_INTERVAL = 30
local MIN_BROADCAST_GAP = 1
local AUTHORITY_SILENCE = 90
local ENTRY_GRACE = 3.5
local TICK_INTERVAL = 0.25
local ELIGIBILITY_INTERVAL = 1
local MAP_INTERVAL = 1
local ALERT_COOLDOWN = 60
local PLAUSIBILITY_SLACK = 30
local MAX_PRESENCE_PER_POI = 40
-- Incoming quota per sender and 10 s window (decision 0029). The total equals
-- what a plain 0.25 s gate could emit (40) plus 20 % for delivery jitter, above
-- the current gate (6 sends then a 1.1 s pause, ~26, decision 0040): an honest
-- client is never refused. The per-kind limits
-- bound the kinds a liar could abuse: kills (risk B11) and requests, whose
-- answers every peer prepares (risk B8).
local QUOTA_WINDOW = 10
local QUOTA_TOTAL = 48
-- X: shared stock of a resource POI (modules/stock.lua, decision 0048).
-- G, GD, GQ: garrison state, pledge request and query (modules/garrison.lua,
-- decision 0049).
-- SC, SQ, SL: scouting order, catch-up request and relayed scout
-- (modules/scout.lua, decision 0050).
-- AC, AQ, AL, AR: attack order, catch-up request, relayed attack and battle
-- result (modules/attack.lua, decision 0052).
local QUOTA_BY_KIND = {
  S = 40, P = 20, Q = 6, HQ = 6, H = 10, K = 20, OD = 4, OL = 12, X = 20, G = 20, GD = 6, GQ = 6,
  SC = 6, SQ = 6, SL = 20, AC = 6, AQ = 6, AL = 20, AR = 10,
  -- T, TQ: membership ticket and its request (modules/ticket.lua, decision 0061).
  T = 6, TQ = 6,
}
-- Owner claims nobody here saw happen (decision 0038): relayed S and H, OL
-- catch-up lines, K beyond the next capture. They are hints, never confirmed
-- until enough distinct senders agree. Values proposed, not measured.
local HINT_SENDERS = 4
local HINT_TTL = 900
local HINT_JUMP = 10
-- Generation floor (decision 0060): values this close to the wire bound (1,000,000)
-- are ignored, so a forged generation can never make the next capture unrepresentable.
local FLOOR_MAX = 990000
local CLOUD_RANKS = { U = 0, C = 1, Q = 2, W = 3, D = 4 }
-- Rule R14 with two answers: a pending reply waits for two matching answers
-- from distinct senders, or four of any kind, before it is dropped.
local REPLY_MATCHES = 2
local REPLY_ANY = 4
local MAX_QUOTA_SENDERS = 200
local SCHEMA = 1
local MAX_ARCHIVED_LEVELS = 3
local CAMPAIGN = "permanent"

Capture.CAPTURE_DURATION = CAPTURE_DURATION
Capture.DECAY_DURATION = DECAY_DURATION
Capture.MAX_DURATION = MAX_DURATION
Capture.SETTLEMENT_DURATION = SETTLEMENT_DURATION
Capture.SIEGE_ATTACKERS = SIEGE_ATTACKERS

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
-- alone at rest every 60 s (decision 0034), W in a quiet neutral Settlement
-- every 60 s (decision 0058). Lifetime = 2.5 intervals.
local CADENCE_TTLS = { F = PRESENCE_TTL, R = PRESENCE_REST_TTL, L = PRESENCE_LONE_TTL, W = PRESENCE_QUIET_TTL }
local CADENCE_INTERVALS = {
  F = PRESENCE_INTERVAL, R = PRESENCE_REST_INTERVAL, L = PRESENCE_LONE_INTERVAL, W = PRESENCE_QUIET_INTERVAL,
}
local CADENCE_RANKS = { F = 1, R = 2, L = 3, W = 3 }

Capture.FACTION_NAMES = FACTION_NAMES

-- 1.12 has no IsMounted, IsStealthed or UnitIsAFK. Without nampower or
-- VanillaHelpers, mount and stealth come from buff icons (an unknown icon is
-- not detected); AFK always comes from system messages.
local MOUNT_TEXTURES = { "ability_mount_", "inv_misc_foot_kodo", "qirajicrystal", "spell_nature_swiftness" }
local STEALTH_TEXTURES = { "ability_stealth", "ability_ambush", "invisibilty", "invisibility" }
-- The server refuses channel chat below this level: such a player could not
-- share anything, so it takes no part in any capture (decision 0039).
local MIN_CHANNEL_LEVEL = 5
Capture.LEVEL_REASON = "below level " .. MIN_CHANNEL_LEVEL .. ", channel chat locked"

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
    nH = st.nH, nA = st.nA, epoch = st.epoch, seq = st.seq, dur = st.dur, siege = st.siege,
  }
end

-- Full-bar speed of the attempt, in thousandths per second.
local function Rate(st)
  return 1000 / (st.dur or CAPTURE_DURATION)
end

local function HalfRate(st)
  return 500 / (st.dur or CAPTURE_DURATION)
end

-- Moves a state forward by dt seconds in its current mode. Observers pass
-- allowCapture=false: only the authority completes a capture. A Settlement
-- (siege) never opens an attempt here: only its authority does, once the
-- prerequisites hold (Capture:SiegeMode, decision 0053).
local function Advance(st, dt, allowCapture)
  local event = nil
  local guard = 0
  local rate, half = Rate(st), HalfRate(st)
  while dt > 0 and guard < 4 do
    guard = guard + 1
    if st.mode == "P" and FACTION_KEYS[st.dir] then
      local side = st.dir
      if st.challenger == "-" then
        if side == st.owner or st.siege then return event end
        st.challenger = side
        st.progress = 0
      end
      if st.challenger == side then
        local need = (1000 - st.progress) / rate
        if dt < need then
          st.progress = st.progress + rate * dt
          return event
        end
        if not allowCapture then
          st.progress = 1000
          return event
        end
        dt = dt - need
        st.owner = side
        st.generation = Capture:NextGeneration(st.id, st.generation)
        st.challenger = "-"
        st.progress = 0
        event = "CAPTURED"
      else
        -- The owner defends, or on a neutral POI the other faction must first
        -- bring the challenger back to 0 before building its own share.
        local need = st.progress / rate
        if dt < need then
          st.progress = st.progress - rate * dt
          return event
        end
        dt = dt - need
        st.challenger = "-"
        st.progress = 0
      end
    elseif st.mode == "D" then
      if st.challenger ~= "-" then
        local need = st.progress / half
        if dt < need then
          st.progress = st.progress - half * dt
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

-- A POI with the timed presence bar: an OUTPOST or, since decision 0053, a
-- SETTLEMENT (its attempts gated by Capture:SiegeMode).
local TIMED_TYPES = { OUTPOST = true, SETTLEMENT = true }

function Capture:Outpost(id)
  local map = PC.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and TIMED_TYPES[area.type] and area.enabled then return area end
  return nil
end

-- OUTPOST, SETTLEMENT and HUNTING_GROUNDS share one owner registry; hunting
-- grounds use modules/hunting.lua instead of the timed bar (decision 0026).
function Capture:Capturable(id)
  local map = PC.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.enabled and (TIMED_TYPES[area.type] or area.type == "HUNTING_GROUNDS") then
    return area
  end
  return nil
end

-- Objectives linked to a Settlement (decision 0053): every enabled OUTPOST
-- and HUNTING_GROUNDS of its map, sorted by id.
function Capture:LinkedObjectives(id)
  local links = {}
  local map = PC.Map
  local settlement = map and map.areas[id]
  if not settlement or settlement.type ~= "SETTLEMENT" then return links end
  local other, area
  for other, area in pairs(map.areas) do
    if type(area) == "table" and area.enabled and area.map == settlement.map
        and (area.type == "OUTPOST" or area.type == "HUNTING_GROUNDS") then
      table.insert(links, other)
    end
  end
  table.sort(links)
  return links
end

-- Full-bar duration of an Outpost attempt from its garrison's total defense
-- (decision 0047): 180 + floor(1020 x DEF x size_best / (12 x DEF_best)),
-- capped at 1,200, where DEF_best / size_best is the best DEF per Unit Size.
function Capture.DefenseDuration(defense)
  local units = PC.Army and PC.Army.UNITS
  if not units or defense <= 0 then return CAPTURE_DURATION end
  local bestDef, bestSize = 0, 1
  local key, unit
  for key, unit in pairs(units) do
    if (unit.def or 0) > 0 and unit.size and unit.def * bestSize > bestDef * unit.size then
      bestDef, bestSize = unit.def, unit.size
    end
  end
  if bestDef <= 0 then return CAPTURE_DURATION end
  local capacity = PC.Garrison and PC.Garrison.OUTPOST_CAPACITY or 12
  local extra = math.floor((MAX_DURATION - CAPTURE_DURATION) * defense * bestSize / (capacity * bestDef))
  return math.min(MAX_DURATION, CAPTURE_DURATION + extra)
end

-- Defense and unit count of the garrison as this client knows it, read
-- without creating or wiping a garrison record; an older generation is empty.
function Capture:GarrisonDefense(id)
  local garrison = PC.Garrison
  local units = PC.Army and PC.Army.UNITS
  if not garrison or not units then return 0, 0 end
  local g = garrison.states and garrison.states[id]
  local _, generation = self:GetOwner(id)
  if not g or g.gen ~= generation then return 0, 0 end
  local defense = g.f * units.FOOTMAN.def + g.r * units.RIFLEMAN.def + g.m * units.MORTAR.def
  return defense, g.f + g.r + g.m
end

-- Duration the next attempt on this POI would take, fixed when it opens.
function Capture:AttemptDuration(id)
  local area = self:Outpost(id)
  if area and area.type == "SETTLEMENT" then return SETTLEMENT_DURATION end
  local owner = self:GetOwner(id)
  if not FACTION_KEYS[owner] then return CAPTURE_DURATION end
  return Capture.DefenseDuration((self:GarrisonDefense(id)))
end

-- Owner used only by the linked-objective gate of a Settlement siege. During
-- testing and launch, a newer unconfirmed P2P or companion owner is accepted
-- without entering the confirmed registry (decision 0062).
function Capture:SiegeOwner(id, now)
  local owner = self:GetOwner(id)
  local hint = self:BestHint(id, now or Now())
  local cloud = self:CloudHint(id)
  if cloud and cloud.o and (not hint or cloud.g > hint.generation) then
    return cloud.o, false
  end
  if hint then return hint.owner, false end
  return owner, true
end

-- The Settlement prerequisites for faction side (decisions 0053 and 0062), in the order
-- SiegeBlocked checks them: every linked objective held or provisionally reported by side, an empty
-- garrison and, when the other faction holds it, a valid discovery by side.
-- Each item { ok, text, why }: why is the refusal when ok is false. The two
-- attackers are counted by SiegeMode. A local reading only (gameplay UI).
function Capture:SiegeChecklist(id, side, now)
  local list = {}
  local links = self:LinkedObjectives(id)
  local held, provisional, missing = 0, 0, nil
  local index = 1
  while index <= table.getn(links) do
    local objectiveOwner, confirmed = self:SiegeOwner(links[index], now)
    if objectiveOwner == side then
      held = held + 1
      if not confirmed then provisional = provisional + 1 end
    elseif not missing then
      missing = links[index]
    end
    index = index + 1
  end
  local why
  if missing then
    why = (PC.Map.areas[missing].label or missing) .. " is not held by the " .. FACTION_NAMES[side]
  end
  local accepted = provisional > 0 and (", " .. provisional .. " unconfirmed accepted") or ""
  table.insert(list, { ok = not missing, why = why,
    text = "Every Outpost and Hunting Grounds of the zone held (" .. held .. "/" .. table.getn(links)
      .. accepted .. ")" })
  local _, units = self:GarrisonDefense(id)
  table.insert(list, { ok = units == 0, text = "Garrison emptied",
    why = units > 0 and ("its garrison still has " .. units .. " defender(s)") or nil })
  if FACTION_KEYS[self:GetOwner(id)] then
    local found = PC.Scout and PC.Scout:Discovery(id, side, now)
    table.insert(list, { ok = found and true or false, text = "Scouted in the last hour",
      why = not found and ("not scouted by the " .. FACTION_NAMES[side]) or nil })
  end
  return list
end

-- Why faction side cannot open a Settlement attempt now, or nil: the first
-- failed item of SiegeChecklist. Checked only when an attempt opens.
function Capture:SiegeBlocked(id, side, now)
  local owner = self:GetOwner(id)
  if owner == side then return "already held by the " .. FACTION_NAMES[side] end
  local list = self:SiegeChecklist(id, side, now)
  local index = 1
  while index <= table.getn(list) do
    if not list[index].ok then return list[index].why end
    index = index + 1
  end
  return nil
end

-- A Settlement, neutral or held, with no attempt and that no faction can siege
-- (decision 0058): no presence there can open or move a bar, so W is allowed
-- and receivers keep its 150 s. SiegeBlocked refuses the owner's own faction,
-- so only a possible siege by another faction ends it. A state not known yet
-- counts as idle: distant receivers have none, and an attempt only opens once
-- a siege is possible. A known state whose owner differs from the registry is
-- not quiet: one of them is behind, the fast cadence stays until they agree.
function Capture:SettlementQuiet(id, now)
  local area = self:Outpost(id)
  if not area or area.type ~= "SETTLEMENT" then return false end
  local st = self.states[id]
  if st and st.known and (st.owner ~= self:GetOwner(id) or not IsIdle(st)) then return false end
  return self:SiegeBlocked(id, "H", now) ~= nil and self:SiegeBlocked(id, "A", now) ~= nil
end

-- Mode and direction of a Settlement's bar (decision 0053). With no attempt,
-- one opens only toward a majority of at least two attackers that meets the
-- prerequisites. During an attempt: two attackers ahead push, one alone with
-- no defender freezes it (no time limit), defenders ahead push back at full
-- speed, a non-zero tie freezes, an empty area returns.
function Capture:SiegeMode(id, st, nH, nA, now)
  local counts = { H = nH, A = nA }
  local required = st.owner == "N" and 1 or SIEGE_ATTACKERS
  if st.challenger == "-" then
    local side = nil
    if nH > nA then side = "H" elseif nA > nH then side = "A" end
    if side and side ~= st.owner and counts[side] >= required
        and not self:SiegeBlocked(id, side, now) then
      return "P", side
    end
    if nH > 0 and nH == nA then return "C", "-" end
    return "R", "-"
  end
  local attacker = st.challenger
  local defender = attacker == "H" and "A" or "H"
  local a, d = counts[attacker], counts[defender]
  if a > d then
    if a >= required then return "P", attacker end
    return "C", "-"
  end
  if d > a then return "P", defender end
  if a > 0 then return "C", "-" end
  return "D", "-"
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
  -- Presence is sampled before the first tick: after a /reload inside a POI its
  -- state was created with the static owner. Unknown states follow the registry.
  local st
  for id, st in pairs(self.states) do
    local owner, generation = self:GetOwner(id)
    if not st.known and generation > st.generation then
      st.owner, st.generation = owner, generation
      st.challenger, st.progress = "-", 0
      st.mode, st.dir = "R", "-"
    end
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
      -- Saves from before decision 0053 carry no duration: 180 s then.
      local dur = tonumber(entry.dur or CAPTURE_DURATION)
      if self:Outpost(id).type == "SETTLEMENT" then dur = SETTLEMENT_DURATION end
      if entry.owner == owner and tonumber(entry.generation) == generation
          and (entry.challenger == "H" or entry.challenger == "A") and entry.challenger ~= owner
          and progress and progress > 0 and progress < 1000 and at and at <= epoch
          and savedEpoch and savedEpoch >= 0 and savedEpoch <= 1000000
          and dur and dur >= CAPTURE_DURATION and dur <= MAX_DURATION then
        dur = Floor(dur)
        local left = progress - HalfRate({ dur = dur }) * (epoch - at)
        if left > 0 then
          st = self:GetState(id)
          st.owner, st.generation = owner, generation
          st.challenger, st.progress, st.dur = entry.challenger, left, dur
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
        progress = Floor(view.progress), epoch = st.epoch, at = epoch, dur = view.dur,
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

-- Owner hints (decision 0038) ----------------------------------------------------
-- Per POI, at most HINT_SENDERS claims { sender, generation, owner, at }, at in
-- local time only. Never persisted, never sent, never used to refuse a state.

local function Beats(id, owner, generation)
  local currentOwner, currentGeneration = Capture:GetOwner(id)
  return OwnerWins(owner, generation, currentOwner, currentGeneration)
end

function Capture:ClearHints(id)
  self.hints[id] = nil
end

-- Drops the claims the confirmed registry caught up with, and the expired ones.
function Capture:PruneHints(id, now)
  local list = self.hints[id]
  if not list then return end
  local kept = {}
  local index = 1
  while index <= table.getn(list) do
    local claim = list[index]
    if Beats(id, claim.owner, claim.generation) and (not now or now - claim.at < HINT_TTL) then
      table.insert(kept, claim)
    end
    index = index + 1
  end
  self.hints[id] = table.getn(kept) > 0 and kept or nil
end

-- One claim of `sender`, read from the chat event (rule R1). A sender replaces
-- its own claim; a full table drops the oldest one.
function Capture:NoteHint(id, sender, owner, generation, now)
  if not self:Capturable(id) or not FACTION_KEYS[owner] or type(generation) ~= "number"
      or generation < 1 or not sender or sender == self:Me() then
    return false
  end
  local list = self.hints[id] or {}
  local index = 1
  while index <= table.getn(list) do
    if list[index].sender == sender then
      table.remove(list, index)
    else
      index = index + 1
    end
  end
  if not Beats(id, owner, generation) then
    self.hints[id] = table.getn(list) > 0 and list or nil
    return false
  end
  table.insert(list, { sender = sender, owner = owner, generation = generation, at = now })
  while table.getn(list) > HINT_SENDERS do
    -- The list keeps arrival order: at equal time, the first arrived leaves.
    local oldest = 1
    index = 2
    while index <= table.getn(list) do
      if list[index].at < list[oldest].at then oldest = index end
      index = index + 1
    end
    table.remove(list, oldest)
  end
  self.hints[id] = list
  self:PromoteHint(id, owner, generation, now)
  return true
end

-- Q1: two distinct senders of two known factions; Q2: three distinct senders.
-- A jump of more than HINT_JUMP generations needs one sender more.
function Capture:Quorum(id, owner, generation)
  local list = self.hints[id]
  if not list then return false end
  local count, factions = 0, {}
  local index = 1
  while index <= table.getn(list) do
    local claim = list[index]
    if claim.owner == owner and claim.generation == generation then
      count = count + 1
      local faction = self.senderFactions[claim.sender]
      if faction then factions[faction] = true end
    end
    index = index + 1
  end
  local _, currentGeneration = self:GetOwner(id)
  local extra = generation - currentGeneration > HINT_JUMP and 1 or 0
  if factions.H and factions.A and count >= 2 + extra then return true end
  if count >= 3 + extra then return true end
  -- A witnessed cloud owner is one vote: one live sender other than its
  -- capturer confirms it (decision 0060).
  local cloud = self.cloud[id]
  if cloud and cloud.t == "W" and cloud.o == owner and cloud.g == generation then
    local others = 0
    index = 1
    while index <= table.getn(list) do
      local claim = list[index]
      if claim.owner == owner and claim.generation == generation and claim.sender ~= cloud.c then
        others = others + 1
      end
      index = index + 1
    end
    return others >= 1 + extra
  end
  return false
end

-- A promoted hint enters the registry as PEER, without any effect (rule R4).
function Capture:PromoteHint(id, owner, generation, now)
  if not self:Quorum(id, owner, generation) then return false end
  if not self:MergeOwner(id, owner, generation, "PEER") then return false end
  self.promoted = self.promoted + 1
  Record("CAPTURE_HINT_PROMOTED", { id = id, owner = owner, generation = generation })
  if PC.Hunting and PC.Hunting:Area(id) then PC.Hunting:OnPromoted(id, owner, generation) end
  self:PruneHints(id, nil)
  return true
end

-- The most supported claim that beats the registry: owner, count, age.
function Capture:BestHint(id, now)
  local list = self.hints[id]
  if not list then return nil end
  local bestOwner, bestGeneration, bestCount, bestAt
  local index = 1
  while index <= table.getn(list) do
    local claim = list[index]
    if Beats(id, claim.owner, claim.generation) and now - claim.at < HINT_TTL then
      local count, newest = 0, claim.at
      local other = 1
      while other <= table.getn(list) do
        local peer = list[other]
        if peer.owner == claim.owner and peer.generation == claim.generation then
          count = count + 1
          if peer.at > newest then newest = peer.at end
        end
        other = other + 1
      end
      if not bestCount or count > bestCount or (count == bestCount
          and OwnerWins(claim.owner, claim.generation, bestOwner, bestGeneration)) then
        bestOwner, bestGeneration, bestCount, bestAt = claim.owner, claim.generation, count, newest
      end
    end
    index = index + 1
  end
  if not bestOwner then return nil end
  return { owner = bestOwner, generation = bestGeneration, count = bestCount, age = Floor(now - bestAt) }
end

-- Cloud owners (decision 0060) --------------------------------------------------
-- From the validated import only: { g, o (H/A, nil when disputed), t (C claimed,
-- Q disputed claims, W witnessed, D disputed witnessed), c (capturer or nil) }.
-- Shown, raising the generation floor, and one vote for a witnessed owner;
-- never an owner for gameplay, never sent (rule R16 as amended).

function Capture:SetCloud(owners, now)
  self.cloud = {}
  if type(owners) ~= "table" then return end
  local id, e
  for id, e in pairs(owners) do
    if self:Capturable(id) and type(e) == "table" and CLOUD_RANKS[e.t] and type(e.g) == "number" and e.g >= 1 then
      local owner = FACTION_KEYS[e.o] and e.o or nil
      self.cloud[id] = { g = e.g, o = owner, t = e.t, c = owner and e.c or nil }
    end
  end
  for id, e in pairs(self.cloud) do
    if e.t == "W" and e.o then self:PromoteHint(id, e.o, e.g, now or Now()) end
  end
end

-- The cloud entry worth showing: newer than the confirmed registry.
function Capture:CloudHint(id)
  local entry = self.cloud[id]
  if not entry then return nil end
  local _, generation = self:GetOwner(id)
  if entry.t == "U" and generation > 0 then return nil end
  if entry.g <= generation then return nil end
  return entry
end

-- The largest generation known for id: registry, current state, cloud entry,
-- and P2P hints at most HINT_JUMP above the registry. A capture is numbered one
-- above it, so it wins over every capture its author did not see.
function Capture:Floor(id, current)
  local _, registry = self:GetOwner(id)
  local best = registry
  if type(current) == "number" and current > best then best = current end
  local entry = self.cloud[id]
  if entry and entry.t ~= "U" and entry.g > best and entry.g <= FLOOR_MAX then best = entry.g end
  local list = self.hints[id]
  if list then
    local index = 1
    while index <= table.getn(list) do
      local g = list[index].generation
      if g > best and g <= registry + HINT_JUMP and g <= FLOOR_MAX then best = g end
      index = index + 1
    end
  end
  return best
end

-- Display of a cloud entry: label, owner code (nil when disputed), detail.
function Capture.CloudLine(entry)
  if entry.t == "U" and entry.o then return "Unconfirmed owner", entry.o, nil end
  if entry.t == "W" then return "Unconfirmed owner", entry.o, "seen by 3+ players" end
  if entry.t == "C" then
    local name = string.gsub(entry.c or "?", "@.*$", "")
    return "Unconfirmed owner", entry.o, "claimed by " .. name
  end
  return "Unconfirmed owner", nil, "Reports disagree"
end

function Capture:NextGeneration(id, current)
  if not id then return current + 1 end
  return self:Floor(id, current) + 1
end

-- Rule R14 with two answers: `matches` says whether the answer seen carries the
-- same (generation, owner) as the reply we hold.
function Capture:SeeReply(st, sender, matches)
  if not st.replyAt then return end
  st.replyAny = st.replyAny or {}
  st.replyMatch = st.replyMatch or {}
  st.replyAny[sender] = true
  if matches then st.replyMatch[sender] = true end
  local any, match = 0, 0
  local name
  for name in pairs(st.replyAny) do any = any + 1 end
  for name in pairs(st.replyMatch) do match = match + 1 end
  if match >= REPLY_MATCHES or any >= REPLY_ANY then
    st.replyAt, st.replyAny, st.replyMatch = nil, nil, nil
  end
end

function Capture:ScheduleReply(st, at)
  st.replyAt, st.replyAny, st.replyMatch = at, nil, nil
end

-- States ----------------------------------------------------------------------

function Capture:GetState(id)
  local st = self.states[id]
  if st then return st end
  local owner, generation = self:GetOwner(id)
  local area = self:Outpost(id)
  local siege = area ~= nil and area.type == "SETTLEMENT" or nil
  st = {
    id = id, owner = owner, generation = generation, challenger = "-", progress = 0,
    mode = "R", dir = "-", nH = 0, nA = 0, epoch = 0, seq = 0,
    dur = siege and SETTLEMENT_DURATION or CAPTURE_DURATION, siege = siege,
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
  -- A quiet Settlement caps nothing: no presence there can move a bar. Once a
  -- siege is possible it caps as below, here every second on a present client,
  -- on the next P elsewhere (decision 0058).
  local owner = self:GetOwner(id)
  local cap = nil
  if self:SettlementQuiet(id, now) then
    cap = nil
  elseif self:HasRival(id, owner, now) then
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

-- False below level 5 (an unknown level, no API or 0 while loading, does not
-- block) and, when the companion guard is loaded, without nampower or a running
-- companion (decision 0059). Second result: why. Local only: it gates what this
-- client sends, never how a message is accepted.
function Capture:CanTalk()
  local ok, level = Call("UnitLevel", "player")
  if ok and type(level) == "number" and level > 0 and level < MIN_CHANNEL_LEVEL then
    return false, self.LEVEL_REASON, "level"
  end
  local companion = PC.Companion
  if companion and companion.Ready and not companion:Ready() then
    return false, companion:Reason(), "companion"
  end
  return true
end

-- Why the player cannot take part right now, or nil.
function Capture:LockReason()
  local _, reason = self:CanTalk()
  return reason
end

-- "level", "companion" or nil.
function Capture:LockKind()
  local _, _, kind = self:CanTalk()
  return kind
end

-- True for a reason set by CanTalk (the HUD shows it as a hard block).
function Capture:IsLockReason(reason)
  if reason == nil then return false end
  if reason == self.LEVEL_REASON then return true end
  local companion = PC.Companion
  return companion ~= nil and companion.IsReason ~= nil and companion:IsReason(reason)
end

function Capture:Eligibility()
  if Flag("UnitIsDeadOrGhost") then return "NC", "dead" end
  if Capture.afk then return "NC", "AFK" end
  if not Flag("UnitIsPVP", AlwaysTrue) then
    -- The flag is gone: the next toggle can only turn PvP back on.
    Capture.pvpOff = nil
    return "NC", "not PvP flagged"
  end
  -- /pvp off keeps the flag about five minutes, UnitIsPVP included.
  if Capture.pvpOff then return "NC", "PvP toggled off" end
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

-- Server answers to /pvp; the client strings win over these fallbacks.
local PVP_MESSAGES = {
  ERR_PVP_TOGGLE_OFF = "PvP combat toggled off",
  ERR_PVP_TOGGLE_ON = "PvP combat toggled on",
  PVP_TOGGLE_OFF_VERBOSE = "You will be unflagged for PvP combat",
  PVP_TOGGLE_ON_VERBOSE = "You are now flagged for PvP combat",
}

function Capture:OnSystemMessage(message)
  if type(message) ~= "string" then return end
  local marked = AfkPrefix("MARKED_AFK", "You are now AFK")
  local cleared = AfkPrefix("CLEARED_AFK", "You are no longer AFK")
  if cleared ~= "" and string.find(message, cleared, 1, true) == 1 then
    self.afk = false
  elseif marked ~= "" and string.find(message, marked, 1, true) == 1 then
    self.afk = true
  end
  local name, text
  for name, text in pairs(PVP_MESSAGES) do
    local wanted = GetGlobal(name)
    if type(wanted) ~= "string" then wanted = text end
    if string.find(message, wanted, 1, true) == 1 then
      self:SetPvpOff(string.find(name, "_OFF", 1, true) ~= nil)
      return
    end
  end
end

-- 1.12 has no GetPVPDesired: the wanted state comes from the toggle itself.
-- The server message, when it comes, overrides this guess.
function Capture:OnPvpToggle()
  if self.pvpOff then
    self:SetPvpOff(false)
  else
    self:SetPvpOff(Flag("UnitIsPVP") and true or false)
  end
end

-- The HUD and the presence follow on the next tick, not a second later.
function Capture:SetPvpOff(off)
  self.pvpOff = off or nil
  self.lastEligibilityAt = nil
  if PC.Stock then PC.Stock.lastEligibilityAt = nil end
end

-- /pvp calls the global at run time, so a wrapper sees every toggle.
function Capture:HookPvpToggle()
  local original = GetGlobal("TogglePVP")
  if self.pvpHooked or type(original) ~= "function" then return end
  self.pvpHooked = true
  TogglePVP = function(a, b, c)
    pcall(Capture.OnPvpToggle, Capture)
    return original(a, b, c)
  end
end

-- Transport -------------------------------------------------------------------

-- kind is the event id (P, S, Q, K, H, HQ), body its comma-separated fields;
-- key lets the send gate replace a queued message that this one supersedes;
-- priority marks an event message, dropped last by a full send queue.
function Capture:Send(kind, body, key, priority)
  local talk, lockReason = self:CanTalk()
  if not talk then
    self.sendFailures = self.sendFailures + 1
    self.lastSendError = lockReason
    return false
  end
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
-- L for the same defender when nobody else is live in the POI. W for anyone in
-- a quiet Settlement (UpdateEligibility waits QUIET_SETTLE first).
function Capture:PresenceCadence(id, faction, now)
  local st = self.states[id]
  if not st or not st.known or not IsIdle(st) then return "F" end
  if self:SettlementQuiet(id, now) then return "W" end
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
    .. "," .. st.mode .. "," .. st.dir .. "," .. st.nH .. "," .. st.nA .. "," .. Floor(st.dur or CAPTURE_DURATION)
    .. "," .. (event and EVENT_CODES[event] or "-") .. "," .. Floor(age or 0), key, event ~= nil)
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
  if event == "CAPTURED" then
    self:MergeOwner(id, st.owner, st.generation, "LOCAL")
  end
  local mode, dir
  if st.siege then
    mode, dir = self:SiegeMode(id, st, nH, nA, now)
  else
    mode, dir = ModeFromCounts(nH, nA, st)
  end
  if not event and mode == "P" and dir ~= st.owner and not (st.mode == "P" and st.dir == dir) then
    event = "START"
  end
  local transition = event ~= nil or mode ~= st.mode or dir ~= st.dir
  -- While no attempt runs, the next one's duration follows the garrison; it
  -- is fixed once the attempt opens and travels in S (decision 0053).
  if st.challenger == "-" then
    local dur = self:AttemptDuration(id)
    if dur ~= st.dur then
      st.dur = dur
      if mode == "P" and dir ~= st.owner then transition = true end
    end
  end
  -- Only the authority opens a Settlement attempt, prerequisites checked.
  if st.siege and mode == "P" and st.challenger == "-" and dir ~= st.owner then
    st.challenger, st.progress = dir, 0
    Record("SIEGE_OPENED", { id = id, attacker = dir })
  end
  local recounted = nH ~= st.nH or nA ~= st.nA
  st.mode, st.dir, st.nH, st.nA = mode, dir, nH, nA
  st.lastStateAt = now

  -- Busy POIs repeat every 30 s; once idle, one confirmation follows so a lost
  -- transition (for example CAPTURED) does not leave observers stale.
  local elapsed = now - st.lastBroadcastAt
  local due
  if IsIdle(st) then
    due = not st.settled and elapsed >= STATE_INTERVAL
  else
    st.settled = false
    due = elapsed >= STATE_INTERVAL
  end
  if force or transition or (recounted and elapsed >= MIN_BROADCAST_GAP) or due then
    if IsIdle(st) and not transition and not force and due then st.settled = true end
    st.seq = st.seq + 1
    st.lastBroadcastAt = now
    self:SendState(st, event, 0)
  end
  if event == "START" then
    self:HandleEvent(id, "START", dir, now)
  elseif event == "CAPTURED" then
    self:HandleEvent(id, "CAPTURED", st.owner, now, st.generation)
    -- Our own capture: a claim for the cloud owner ledger (decision 0060).
    if PC.Witness then PC.Witness:Note(self:Me(), "CAPTURED", id, st.generation, st.owner) end
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
  if previous and self:Outpost(previous.id) and self.here and self.here.id == previous.id then
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
  -- No status: no presence, never a candidate for authority (Maintain).
  local talk, lockReason = self:CanTalk()
  if not talk then
    here.status, here.reason = nil, lockReason
    return
  end
  local status, reason = self:Eligibility()
  local changed = status ~= here.status
  here.status, here.reason = status, reason
  here.faction = faction
  self:SetPresence(here.id, me, faction, status, now)
  local cadence = self:PresenceCadence(here.id, faction, now)
  -- W only after QUIET_SETTLE of quiet in a row: a receiver still behind on
  -- the owner change that made it quiet would cap it to 25 s (decision 0058).
  if cadence == "W" then
    if not here.quietSince then here.quietSince = now end
    if now - here.quietSince < QUIET_SETTLE then cadence = "F" end
  else
    here.quietSince = nil
  end
  -- A faster cadence goes out at once: receivers then expect the next P
  -- sooner. A slower one waits for the P due under the previous cadence.
  local last = here.cadence or "F"
  local woken = CADENCE_RANKS[cadence] < CADENCE_RANKS[last]
  -- A busy authority keeps its periodic P: its S every 30 s would outlast the
  -- 25 s presence a rival caps it to (decision 0041, reverts part of 0034).
  local due = now - here.lastPresenceAt >= CADENCE_INTERVALS[last]
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
  -- The same presence table counts gatherers: release a stock authority too.
  if PC.Stock then PC.Stock:OnDrop(id, sender) end
  if PC.Garrison then PC.Garrison:OnDrop(id, sender) end
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
  -- A provisional state came from a relay: never relayed again (decision 0038).
  if not st or not st.known or st.provisional then return true end
  if st.authority and st.authority == self:Me() then
    self:AuthorityStep(id, now, true)
  elseif not st.replyAt then
    self:ScheduleReply(st, now + 0.5 + math.random() * 2.5)
  end
  return true
end

function Capture:CheckPlausible(st, f, now)
  local elapsed = math.max(0, now - st.lastStateAt)
  local reach = MAX_RATE * elapsed + PLAUSIBILITY_SLACK
  if f.owner ~= st.owner then
    -- Any generation above ours: the authority numbers a capture above every
    -- generation it knows, which may be more than ours (decision 0060).
    if f.generation <= st.generation or st.challenger ~= f.owner
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
    -- A provisional state never refuses a live one (decision 0038).
    if st.known and not st.provisional then
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
  else
    -- A relayed answer is a hint (decision 0038): it never enters the registry,
    -- never replaces a known state nor its authority, and never has an effect.
    self:SeeReply(st, sender, f.owner == st.owner and f.generation == st.generation)
    if FACTION_KEYS[f.owner] then self:NoteHint(id, sender, f.owner, f.generation, now) end
    local owner, generation = self:GetOwner(id)
    if st.known or f.owner ~= owner or f.generation ~= generation then return true end
    -- Unknown POI, same confirmed owner: a provisional bar for display only.
    st.owner, st.generation = owner, generation
    st.challenger, st.progress = f.challenger, f.progress
    st.mode, st.dir, st.nH, st.nA, st.dur = f.mode, f.dir, f.nH, f.nA, f.dur
    st.epoch, st.seq = f.epoch, f.seq
    st.at = now - f.age
    st.lastStateAt = now - f.age
    st.known, st.provisional = true, true
    st.authority, st.epochHolder = nil, nil
    return true
  end

  local wasMine = st.authority ~= nil and st.authority == me
  st.owner, st.generation = f.owner, f.generation
  st.challenger, st.progress = f.challenger, f.progress
  st.mode, st.dir, st.nH, st.nA, st.dur = f.mode, f.dir, f.nH, f.nA, f.dur
  st.epoch, st.seq = f.epoch, f.seq
  st.at = now - f.age
  st.lastStateAt = now - f.age
  st.known, st.provisional = true, nil
  st.authority = sender
  st.epochHolder = st.authority
  st.takeoverAt = nil
  st.explicitOut = nil
  st.replyAt = nil
  if wasMine then Record("CAPTURE_STEP_DOWN", { id = id, winner = sender }) end

  local present = self.here and self.here.id == id
  self:MergeOwner(id, f.owner, f.generation, present and "LOCAL" or "PEER")
  -- A live state of a present authority replaces every hint (decision 0038).
  self:ClearHints(id)
  if f.event == "START" then
    self:HandleEvent(id, "START", f.dir, now)
  elseif f.event == "CAPTURED" then
    self:HandleEvent(id, "CAPTURED", f.owner, now, f.generation)
    -- The authority's own announce, accepted above; never a relayed answer.
    if PC.Witness then PC.Witness:Note(sender, "CAPTURED", id, f.generation, f.owner) end
  end
  return true
end

-- parts: the S fields after the event id, starting with the POI.
function Capture:ParseState(parts)
  if table.getn(parts) ~= 14 then return nil, "bad S field count" end
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
    dur = Int(parts[12], MAX_DURATION),
    event = CODE_EVENTS[parts[13]],
    age = Int(parts[14], 3600),
  }
  if not f.epoch or not f.seq or not f.generation or not f.progress or not f.nH or not f.nA
      or not f.dur or not f.age then
    return nil, "bad S number"
  end
  -- Attempt duration (decision 0053): 180 to 1,200 s, exactly 600 s for a
  -- Settlement.
  local area = self:Outpost(f.id)
  if f.dur < CAPTURE_DURATION or (area and area.type == "SETTLEMENT" and f.dur ~= SETTLEMENT_DURATION) then
    return nil, "bad S duration"
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
  -- Membership tickets (decision 0061): T and TQ before any routing. Step 4b
  -- drops a revoked character's messages as if they were lost; in the OBSERVE
  -- mode nothing else is ever dropped for a missing ticket.
  if kind == "T" or kind == "TQ" then
    if not PC.Ticket then return self:Reject("tickets unavailable", sender) end
    local handled, err = PC.Ticket:OnMessage(kind, parts, sender, now)
    if not handled then return self:Reject(err or ("bad " .. kind), sender) end
    return true
  end
  if PC.Ticket and not PC.Ticket:Admit(sender, kind, now) then return self:Ignore("revoked character", senderName) end
  local id = parts[1]
  if kind == "K" or kind == "H" or kind == "HQ" then
    if not PC.Hunting then return self:Reject("hunting unavailable", sender) end
    return PC.Hunting:OnMessage(kind, parts, sender, now)
  end
  if kind == "OD" or kind == "OL" then
    if not PC.Catchup then return self:Reject("catch-up unavailable", sender) end
    return PC.Catchup:OnMessage(kind, parts, sender, now)
  end
  if kind == "G" or kind == "GD" or kind == "GQ" then
    if not PC.Garrison then return self:Reject("garrison unavailable", sender) end
    return PC.Garrison:OnMessage(kind, parts, sender, now)
  end
  if kind == "SC" or kind == "SQ" or kind == "SL" then
    if not PC.Scout then return self:Reject("scouting unavailable", sender) end
    return PC.Scout:OnMessage(kind, parts, sender, now)
  end
  if kind == "AC" or kind == "AQ" or kind == "AL" or kind == "AR" then
    if not PC.Attack then return self:Reject("attacks unavailable", sender) end
    return PC.Attack:OnMessage(kind, parts, sender, now)
  end
  -- Resource POIs: P, Q and X go to the shared stocks (decision 0048).
  if kind == "X" or (PC.Stock and PC.Stock:Resource(id)) then
    if not PC.Stock then return self:Reject("stock unavailable", sender) end
    return PC.Stock:OnMessage(kind, parts, sender, now)
  end
  if not self:Outpost(id) then return self:Reject("unknown outpost", sender) end

  if kind == "P" then
    local status = CODE_STATUSES[parts[3]]
    if table.getn(parts) ~= 4 or not FACTION_KEYS[parts[2]] or not status or not CADENCE_TTLS[parts[4]] then
      return self:Reject("bad P", sender)
    end
    -- W exists only in a Settlement (static type, the same for every client).
    if parts[4] == "W" and self:Outpost(id).type ~= "SETTLEMENT" then
      return self:Reject("bad P", sender)
    end
    -- Counted only (OBSERVE mode): a verified member stating the other faction.
    if PC.Ticket then PC.Ticket:NoteFaction(sender, parts[2]) end
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
      local hint = self:BestHint(id, now)
      local cloud = self:CloudHint(id)
      if cloud and hint and hint.generation >= cloud.g then cloud = nil end
      if cloud and cloud.o then
        map:SetCaptureView(id, FACTION_KEYS[cloud.o], nil, true)
      elseif hint then
        map:SetCaptureView(id, FACTION_KEYS[hint.owner], nil, true)
      else
        map:SetCaptureView(id, FACTION_KEYS[owner], half and FACTION_KEYS[half] or nil)
      end
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
    local hinted
    for hinted in pairs(self.hints) do self:PruneHints(hinted, now) end
    self:UpdateMap(now)
    -- Every second, so a disconnect without PLAYER_LOGOUT loses at most that.
    self:SaveProgress(now)
  end
  if PC.Hunting then PC.Hunting:Tick(now) end
  if PC.Catchup then PC.Catchup:Tick(now) end
  if PC.Stock then PC.Stock:Tick(now) end
  if PC.Garrison then PC.Garrison:Tick(now) end
  if PC.Scout then PC.Scout:Tick(now) end
  if PC.Attack then PC.Attack:Tick(now) end
end

-- Display helpers ---------------------------------------------------------------

function Capture:Remaining(view)
  if not view then return nil end
  if view.mode == "P" then
    local side = view.dir
    local rate = Rate(view)
    if view.challenger == "-" then
      if side == view.owner then return nil end
      return 1000 / rate
    end
    if view.challenger == side then return (1000 - view.progress) / rate end
    local back = view.progress / rate
    if view.owner == "N" and not view.siege then back = back + 1000 / rate end
    return back
  elseif view.mode == "D" then
    return view.progress / HalfRate(view)
  end
  return nil
end

-- A Settlement attempt held by one attacker with no defender (decision 0053).
local function Frozen(view)
  if not view.siege or view.mode ~= "C" or view.challenger == "-" then return false end
  local attackers = view.challenger == "H" and view.nH or view.nA
  local defenders = view.challenger == "H" and view.nA or view.nH
  return attackers == 1 and defenders == 0
end

local function Clock(seconds)
  seconds = Floor(seconds)
  local minutes = math.floor(seconds / 60)
  return string.format("%d:%02d", minutes, seconds - minutes * 60)
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
    if Frozen(view) then return "Frozen - " .. FACTION_NAMES[view.challenger] .. " needs a second attacker" end
    return "Contested (" .. view.nH .. " vs " .. view.nA .. ")"
  elseif view.mode == "D" then
    if view.owner == "N" then return "Returning to neutral" end
    return "Returning to " .. owner
  end
  if view.owner == "N" then return "Neutral" end
  return "Controlled by " .. owner
end

-- Why an attempt takes its time, or why a Settlement attempt cannot open for
-- faction side (roadmap WP10): one line for the HUD and the map tooltip.
function Capture:Detail(id, view, side, now)
  local area = self:Outpost(id)
  if not area or not view then return nil end
  if area.type == "SETTLEMENT" then
    local required = view.owner == "N" and 1 or SIEGE_ATTACKERS
    if view.challenger ~= "-" then
      local attackers = required == 1 and "1 attacker" or required .. " attackers"
      return "Siege: " .. Clock(view.dur or SETTLEMENT_DURATION) .. " for a full bar, " .. attackers .. " needed to advance"
    end
    if not FACTION_KEYS[side or ""] or side == view.owner then return nil end
    local blocked = self:SiegeBlocked(id, side, now or Now())
    if blocked then return "Siege locked: " .. blocked end
    if required == 1 then return "Siege open: 1 " .. FACTION_NAMES[side] .. " attacker inside starts it" end
    local inside = (side == "H" and view.nH or view.nA) or 0
    if inside > SIEGE_ATTACKERS then inside = SIEGE_ATTACKERS end
    return FACTION_NAMES[side] .. " siege: " .. inside .. "/" .. SIEGE_ATTACKERS .. " attackers inside"
  end
  if view.challenger ~= "-" then
    return "Capture time " .. Clock(view.dur or CAPTURE_DURATION) .. ", set by the garrison when the attempt began"
  end
  if not FACTION_KEYS[view.owner] then return "Capture time " .. Clock(CAPTURE_DURATION) .. " (no garrison)" end
  local defense, units = self:GarrisonDefense(id)
  local dur = self:AttemptDuration(id)
  if units == 0 then return "Capture time " .. Clock(dur) .. " (empty garrison)" end
  return "Capture time " .. Clock(dur) .. " (garrison defense " .. defense .. ")"
end

-- Capture details for the map tooltip, nil when the area cannot be captured:
-- owner, challenger and percent, status and seconds left, players inside, here.
function Capture:TooltipInfo(id, now)
  if not self:Capturable(id) then return nil end
  local info = { owner = self:GetOwner(id) }
  info.hint = self:BestHint(id, now or Now())
  info.cloud = self:CloudHint(id)
  if info.cloud and info.hint and info.hint.generation >= info.cloud.g then info.cloud = nil end
  if info.cloud and info.cloud.o and info.hint then info.hint = nil end
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
  info.detail = self:Detail(id, view or { owner = info.owner, challenger = "-", progress = 0 },
    self:MyFaction(), now)
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
    detail = self:Detail(here.id, view, self:MyFaction(), now),
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
  if PC.Catchup then Print("capture: " .. PC.Catchup:Summary()) end
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
  -- Where the server puts the /pvp answer is not measured yet.
  PC.RegisterEvent("UI_INFO_MESSAGE", function(eventName, message)
    Capture:OnSystemMessage(message)
  end)
  -- Fires on logout, quit and /reload, before SavedVariables are written.
  PC.RegisterEvent("PLAYER_LOGOUT", function()
    Capture:SaveProgress(Now())
  end)
end

Capture:HookPvpToggle()

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
