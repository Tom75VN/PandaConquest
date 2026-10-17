PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Garrison = {
  states = {},
  here = nil,
  sent = 0,
  received = 0,
}

PC.Garrison = Garrison

-- Collective garrisons of Outposts and Settlements, and the Settlement upgrade
-- funds (roadmap WP7, docs/garrison.md, decision 0049). A garrison is three
-- unit counters plus, for a Settlement, a gold and a wood fund, all bound to
-- the POI's ownership generation: a capture wipes them. One keeper per POI, a
-- present player of the owning faction, applies the donations in order and
-- announces the state G; a donor sends GD and waits for the keeper's answer.
-- Values from the V1 balance sheet (decision 0047, tools/balance_sim.py).
local OUTPOST_CAPACITY = 12
local SETTLEMENT_CAPACITY = { 28, 40, 50 }
-- Cumulative fund reaching levels 2 and 3 (1,200 + 300, then 2,400 + 600 more).
local LEVEL_GOLD = { 0, 1200, 3600 }
local LEVEL_WOOD = { 0, 300, 900 }
local UNIT_FIELDS = { FOOTMAN = "f", RIFLEMAN = "r", MORTAR = "m" }
local UNIT_ORDER = { "FOOTMAN", "RIFLEMAN", "MORTAR" }
local FUND_KINDS = { gold = true, wood = true }
local MAX_UNITS = 50
local MAX_NUMBER = 1000000
local MAX_OP = 1000000000
-- Post-combat lock bound (decision 0047), carried in G and AR (decision 0052).
local LOCK_MAX = 1200
-- Same election delays as an outpost's timer; the keeper waits for the
-- answers to its takeover before it accepts donations (READY_DELAY).
local ENTRY_GRACE = 3.5
local READY_DELAY = 4
local MIN_BROADCAST_GAP = 1
-- No periodic state: a change is announced at once, then repeated once.
local REPEAT_AFTER = 5
local RETRY_INTERVAL = 5
local MAX_SENDS = 4
local GIVE_UP_AFTER = RETRY_INTERVAL * MAX_SENDS + 5
local MAX_APPLIED = 64
local REPLY_MATCHES = 2
local REPLY_ANY = 4
local SAVE_INTERVAL = 5
local SCHEMA = 1
local MAX_LEVELS = 3
-- Four base-36 characters naming a donor in the keeper's answer.
local TAG_MODULUS = 1679609
local DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local RESULTS = {
  A = "accepted",
  F = "the garrison is full",
  X = "the upgrade fund is full",
  C = "an enemy capture is in progress",
  O = "the keeper does not see you inside, or this place is not held by your faction",
  G = "this place changed hands",
  B = "invalid donation",
  L = "reinforcements are blocked by an attack (final approach, battle or post-combat lock)",
}
local PLACE_NAMES = { OUTPOST = "Outpost", SETTLEMENT = "Settlement" }

Garrison.OUTPOST_CAPACITY = OUTPOST_CAPACITY
Garrison.SETTLEMENT_CAPACITY = SETTLEMENT_CAPACITY
Garrison.LEVEL_GOLD = LEVEL_GOLD
Garrison.LEVEL_WOOD = LEVEL_WOOD
Garrison.UNIT_ORDER = UNIT_ORDER
Garrison.RESULTS = RESULTS

local function GetGlobal(name)
  if getglobal then return getglobal(name) end
  if _G then return _G[name] end
  return nil
end

local function Now()
  local now = PC.Now and PC.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
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

local function Int(text, maximum)
  if type(text) ~= "string" or not string.find(text, "^%d+$") or string.len(text) > 10 then
    return nil
  end
  local value = tonumber(text)
  if not value or value > maximum then return nil end
  return value
end

local function Me()
  return PC.Capture and PC.Capture:Me()
end

local function Realm()
  local fn = GetGlobal("GetRealmName")
  local ok, realm = false, nil
  if type(fn) == "function" then ok, realm = pcall(fn) end
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

local function Base36(value, width)
  local text = ""
  while value > 0 do
    local digit = value - Floor(value / 36) * 36
    text = string.sub(DIGITS, digit + 1, digit + 1) .. text
    value = (value - digit) / 36
  end
  while string.len(text) < width do text = "0" .. text end
  return text
end

-- Names the donor inside the keeper's answer. Only the donor compares it with
-- its own name; nobody reads an identity from it (rule R1).
function Garrison.Tag(identity)
  local h = 0
  local position = 1
  while position <= string.len(identity) do
    h = h * 31 + string.byte(identity, position)
    h = h - Floor(h / TAG_MODULUS) * TAG_MODULUS
    position = position + 1
  end
  return Base36(h, 4)
end

-- Places and values ---------------------------------------------------------

function Garrison:Area(id)
  local map = PC.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.enabled and PLACE_NAMES[area.type] then return area end
  return nil
end

function Garrison.Level(gold, wood)
  local level = 1
  while level < 3 and gold >= LEVEL_GOLD[level + 1] and wood >= LEVEL_WOOD[level + 1] do
    level = level + 1
  end
  return level
end

function Garrison:Capacity(area, gold, wood)
  if area.type == "SETTLEMENT" then return SETTLEMENT_CAPACITY[Garrison.Level(gold, wood)] end
  return OUTPOST_CAPACITY
end

local function Size(f, r, m)
  local units = PC.Army.UNITS
  return f * units.FOOTMAN.size + r * units.RIFLEMAN.size + m * units.MORTAR.size
end

local function Defense(st)
  local units = PC.Army.UNITS
  return st.f * units.FOOTMAN.def + st.r * units.RIFLEMAN.def + st.m * units.MORTAR.def
end

-- The garrison of a POI at its current ownership generation. A newer
-- generation (a capture) starts empty, at level 1, with an empty fund.
function Garrison:GetState(id)
  local owner, generation = PC.Capture:GetOwner(id)
  local st = self.states[id]
  if not st then
    st = {
      id = id, gen = generation, ver = 0, epoch = 0, top = 0, f = 0, r = 0, m = 0, gold = 0, wood = 0,
      applied = {}, appliedOrder = {}, lastBroadcastAt = -1000, readyAt = 0,
    }
    self.states[id] = st
  elseif st.gen < generation then
    st.gen, st.ver, st.epoch = generation, 0, 0
    st.f, st.r, st.m, st.gold, st.wood = 0, 0, 0, 0, 0
    st.relayable, st.ack, st.applied, st.appliedOrder, st.lockEnd = nil, nil, {}, {}, nil
    st.authority, st.authEpoch, st.takeoverAt, st.replyAt, st.sendDue = nil, nil, nil, nil, nil
    self.dirty = true
    Record("GARRISON_WIPED", { id = id, generation = generation })
  end
  st.owner = owner
  return st
end

local CONTENT = { "f", "r", "m", "gold", "wood" }

-- Total order of two states of one generation (rule R5): more donations
-- applied, then the later keeper epoch, then the larger content. Within a
-- generation a garrison only grows in V1, so the larger state is the newer.
local function Beats(a, b)
  if a.ver ~= b.ver then return a.ver > b.ver end
  if a.epoch ~= b.epoch then return a.epoch > b.epoch end
  local index = 1
  while index <= table.getn(CONTENT) do
    local key = CONTENT[index]
    if a[key] ~= b[key] then return a[key] > b[key] end
    index = index + 1
  end
  return false
end

local function Same(a, b)
  return not Beats(a, b) and not Beats(b, a)
end

-- A post-combat lock is taken only from a state of a higher version: repeats
-- and relays of the same state never extend it (decision 0052).
local function Adopt(st, f, now)
  if now and (f.lock or 0) > 0 and f.ver > st.ver then
    local finish = now + f.lock
    if not st.lockEnd or finish > st.lockEnd then st.lockEnd = finish end
  end
  st.ver, st.epoch = f.ver, f.epoch
  st.f, st.r, st.m, st.gold, st.wood = f.f, f.r, f.m, f.gold, f.wood
  if f.epoch > st.top then st.top = f.epoch end
end

-- The keeper signs what it publishes with its own epoch, raised above any
-- epoch seen: an older keeper's copy then never outranks the keeper's own.
local function Sign(st)
  if st.authEpoch < st.top then
    st.top = st.top + 1
    st.authEpoch = st.top
  end
  st.epoch = st.authEpoch
end

-- Presence and keeper -------------------------------------------------------

-- Faction of a live presence in the POI, the local player included.
local function PresentFaction(id, identity, now)
  local capture = PC.Capture
  if not identity or not capture:HasPresence(id, identity, now) then return nil end
  return capture.presence[id].entries[identity].faction
end

function Garrison:KeeperAlive(st, now)
  return st.authority ~= nil and PresentFaction(st.id, st.authority, now) == st.owner
end

-- An enemy capture attempt under way on this POI, from the moment it opens:
-- no donation for its whole duration, frozen or not (decision 0053).
function Garrison:Contested(id, owner, now)
  local view = PC.Capture:GetView(id, now)
  return view ~= nil and view.challenger ~= "-" and view.challenger ~= owner
end

-- Sending -------------------------------------------------------------------

function Garrison:Send(kind, body, key, priority)
  if not PC.Capture then return false end
  local ok = PC.Capture:Send(kind, body, key, priority)
  if ok then self.sent = self.sent + 1 end
  return ok
end

-- Seconds left of the post-combat lock, whole and bounded.
function Garrison:LockLeft(st, now)
  if not st.lockEnd or st.lockEnd <= now then return 0 end
  return math.min(LOCK_MAX, Floor(st.lockEnd - now))
end

-- G <poi>,<gen>,<ver>,<epoch>,<f>,<r>,<m>,<gold>,<wood>,<lock>,<op>,<tag>,<result>,<relay>
-- relay 0: the keeper's own state, answering donation op of the tagged donor;
-- relay 1: an answer to GQ, without any answer to a donation. lock: seconds
-- left of the post-combat lock (decision 0052).
function Garrison:SendState(st, relay)
  local op, tag, result = 0, "0000", "-"
  if not relay and st.ack then op, tag, result = st.ack.op, st.ack.tag, st.ack.result end
  return self:Send("G", st.id .. "," .. st.gen .. "," .. st.ver .. "," .. st.epoch .. "," .. st.f .. ","
    .. st.r .. "," .. st.m .. "," .. st.gold .. "," .. st.wood .. "," .. self:LockLeft(st, Now()) .. "," .. op
    .. "," .. tag .. "," .. result .. "," .. (relay and "1" or "0"), "G," .. st.id)
end

function Garrison:Broadcast(st, now)
  st.sendDue = nil
  st.lastBroadcastAt = now
  st.replyAt = nil
  self:SendState(st, false)
end

-- GD <poi>,<gen>,<op>,<f>,<r>,<m>,<gold>,<wood>: an event, never replaced (R12).
function Garrison:SendRequest(p)
  local fields = { f = 0, r = 0, m = 0, gold = 0, wood = 0 }
  fields[UNIT_FIELDS[p.kind] or p.kind] = p.count
  return self:Send("GD", p.id .. "," .. p.gen .. "," .. p.op .. "," .. fields.f .. "," .. fields.r .. ","
    .. fields.m .. "," .. fields.gold .. "," .. fields.wood, nil, true)
end

-- Keeper --------------------------------------------------------------------

function Garrison:TakeOver(st, now)
  st.top = st.top + 1
  st.authority, st.authEpoch = Me(), st.top
  -- The keeper signs what it publishes with its own epoch: the same content,
  -- ordered after the copies of earlier keepers (Beats compares ver first).
  st.epoch = st.authEpoch
  st.takeoverAt = nil
  st.relayable = true
  st.ack = nil
  -- Peers that know a later garrison answer this first state (OnStateMessage);
  -- donations wait until they had the time to.
  st.readyAt = now + READY_DELAY
  st.repeatAt = now + REPEAT_AFTER
  Record("GARRISON_KEEPER", { id = st.id, epoch = st.top, ver = st.ver })
  self:Broadcast(st, now)
end

local function Remember(st, key, result)
  if not st.applied[key] then
    table.insert(st.appliedOrder, key)
    if table.getn(st.appliedOrder) > MAX_APPLIED then
      st.applied[table.remove(st.appliedOrder, 1)] = nil
    end
  end
  st.applied[key] = result
end

-- The keeper's decision on one donation, before anything changes.
function Garrison:Judge(st, donor, f, now)
  local area = self:Area(st.id)
  if f.gen ~= st.gen then return "G" end
  if PresentFaction(st.id, donor, now) ~= st.owner then return "O" end
  if self:Contested(st.id, st.owner, now) then return "C" end
  if f.f + f.r + f.m + f.gold + f.wood <= 0 then return "B" end
  -- Units only: the upgrade fund ignores armies and battles (decision 0052).
  if f.f + f.r + f.m > 0 and PC.Attack and PC.Attack:Freeze(st.id, now) then return "L" end
  if area.type ~= "SETTLEMENT" and f.gold + f.wood > 0 then return "B" end
  local gold, wood = st.gold + f.gold, st.wood + f.wood
  if gold > LEVEL_GOLD[3] or wood > LEVEL_WOOD[3] then return "X" end
  if Size(st.f + f.f, st.r + f.r, st.m + f.m) > self:Capacity(area, gold, wood) then return "F" end
  return "A"
end

-- Applies a donation once per (donor, op) and answers it in the next state; a
-- repeated request gets the same answer again (rule R8).
function Garrison:Apply(st, donor, f, now)
  local key = donor .. ":" .. f.op
  local result = st.applied[key]
  if not result then
    result = self:Judge(st, donor, f, now)
    if result == "A" then
      local before = Garrison.Level(st.gold, st.wood)
      st.f, st.r, st.m = st.f + f.f, st.r + f.r, st.m + f.m
      st.gold, st.wood = st.gold + f.gold, st.wood + f.wood
      st.ver = st.ver + 1
      st.epoch = st.authEpoch
      st.repeatAt = now + REPEAT_AFTER
      self.dirty = true
      local after = Garrison.Level(st.gold, st.wood)
      if after > before then Record("GARRISON_LEVEL", { id = st.id, level = after }) end
    end
    Remember(st, key, result)
    Record("GARRISON_APPLIED", { id = st.id, donor = donor, op = f.op, result = result, ver = st.ver })
  end
  st.ack = { op = f.op, tag = Garrison.Tag(donor), result = result }
  st.sendDue = true
  if now - st.lastBroadcastAt >= MIN_BROADCAST_GAP then self:Broadcast(st, now) end
  return result
end

function Garrison:Maintain(id, st, now)
  local me = Me()
  if st.replyAt and now >= st.replyAt then
    st.replyAt = nil
    if st.relayable and st.ver > 0 then self:SendState(st, true) end
  end
  if st.authority and not self:KeeperAlive(st, now) then st.authority = nil end
  if me and st.authority == me then
    if st.repeatAt and now >= st.repeatAt then
      st.repeatAt = nil
      st.sendDue = true
    end
    if st.sendDue and now - st.lastBroadcastAt >= MIN_BROADCAST_GAP then self:Broadcast(st, now) end
    return
  end
  local here = self.here
  if st.authority or not here or here.id ~= id or not me or PresentFaction(id, me, now) ~= st.owner then
    st.takeoverAt = nil
    return
  end
  if not st.takeoverAt then
    -- Rank among the present players of the owning faction, as an outpost's timer.
    local _, _, candidates = PC.Capture:Count(id, now)
    local rank = 0
    local index = 1
    while index <= table.getn(candidates) and candidates[index] ~= me do
      if PresentFaction(id, candidates[index], now) == st.owner then rank = rank + 1 end
      index = index + 1
    end
    local earliest = now + 2 + 3 * rank
    if earliest < here.enterAt + ENTRY_GRACE then earliest = here.enterAt + ENTRY_GRACE end
    st.takeoverAt = earliest
  elseif now >= st.takeoverAt then
    self:TakeOver(st, now)
  end
end

-- Reception -----------------------------------------------------------------

function Garrison:Reject(reason, sender)
  return PC.Capture:Reject(reason, sender)
end

-- An OUT, or a presence elsewhere, releases the keeper role it held.
function Garrison:OnDrop(id, sender)
  local st = self.states[id]
  if st and st.authority == sender then
    st.authority = nil
    st.takeoverAt = nil
  end
end

function Garrison:SeeReply(st, sender, matches)
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

function Garrison:ScheduleReply(st, now)
  if st.replyAt then return end
  st.replyAt, st.replyAny, st.replyMatch = now + 0.5 + math.random() * 2.5, nil, nil
end

-- GQ <poi>: the keeper answers at once (an empty garrison too, so the asker
-- learns who keeps it); others only relay a non-empty state they saw from a
-- keeper, late and cancellable (rule R14).
function Garrison:OnQuery(sender, id, now)
  local st = self:GetState(id)
  if st.authority and st.authority == Me() then
    st.sendDue = true
    if now - st.lastBroadcastAt >= MIN_BROADCAST_GAP then self:Broadcast(st, now) end
  elseif st.relayable and st.ver > 0 then
    self:ScheduleReply(st, now)
  end
  return true
end

-- parts: the G fields after the event id, starting with the POI.
function Garrison:ParseState(parts, area)
  if table.getn(parts) ~= 14 then return nil, "bad G field count" end
  local f = {
    id = parts[1],
    gen = Int(parts[2], MAX_NUMBER),
    ver = Int(parts[3], MAX_NUMBER),
    epoch = Int(parts[4], MAX_NUMBER),
    f = Int(parts[5], MAX_UNITS),
    r = Int(parts[6], MAX_UNITS),
    m = Int(parts[7], MAX_UNITS),
    gold = Int(parts[8], LEVEL_GOLD[3]),
    wood = Int(parts[9], LEVEL_WOOD[3]),
    lock = Int(parts[10], LOCK_MAX),
    op = Int(parts[11], MAX_OP),
    tag = parts[12],
    result = parts[13],
  }
  if not f.gen or not f.ver or not f.epoch or not f.f or not f.r or not f.m or not f.gold or not f.wood
    or not f.lock or not f.op then
    return nil, "bad G number"
  end
  if not string.find(f.tag, "^[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]$") or not (f.result == "-" or RESULTS[f.result])
    or (parts[14] ~= "0" and parts[14] ~= "1") then
    return nil, "bad G code"
  end
  if area.type ~= "SETTLEMENT" and f.gold + f.wood > 0 then return nil, "fund outside a Settlement" end
  if Size(f.f, f.r, f.m) > self:Capacity(area, f.gold, f.wood) then return nil, "garrison above capacity" end
  f.relay = parts[14] == "1"
  return f
end

function Garrison:ParseRequest(parts, area)
  if table.getn(parts) ~= 8 then return nil, "bad GD field count" end
  local f = {
    id = parts[1],
    gen = Int(parts[2], MAX_NUMBER),
    op = Int(parts[3], MAX_OP),
    f = Int(parts[4], MAX_UNITS),
    r = Int(parts[5], MAX_UNITS),
    m = Int(parts[6], MAX_UNITS),
    gold = Int(parts[7], LEVEL_GOLD[3]),
    wood = Int(parts[8], LEVEL_WOOD[3]),
  }
  if not f.gen or not f.op or not f.f or not f.r or not f.m or not f.gold or not f.wood then
    return nil, "bad GD number"
  end
  if f.op < 1 or f.f + f.r + f.m + f.gold + f.wood <= 0 then return nil, "empty GD" end
  if area.type ~= "SETTLEMENT" and f.gold + f.wood > 0 then return nil, "fund outside a Settlement" end
  return f
end

function Garrison:OnStateMessage(sender, f, now)
  local st = self:GetState(f.id)
  -- Bound to the owner registry, never a source for it (rule R7).
  if st.owner ~= "H" and st.owner ~= "A" then return self:Reject("garrison of an unheld place", sender) end
  if f.gen < st.gen then return self:Reject("old garrison generation", sender) end
  if f.gen > st.gen then return self:Reject("unobserved garrison generation", sender) end
  if f.relay then
    -- Display only: how old what a scout's faction sees is (modules/scout.lua).
    st.seenAt = now
    self:SeeReply(st, sender, Same(f, st))
    -- The larger state wins for everyone, keeper included (rules R5, R6); a
    -- state learned from a relay is never relayed again (rule R14).
    if Beats(f, st) then
      Adopt(st, f, now)
      self.dirty = true
      if st.authority and st.authority == Me() then
        Sign(st)
        st.sendDue = true
      else
        st.relayable = nil
      end
    end
    return true
  end
  -- A direct state: only a present player of the owning faction keeps a garrison.
  if PresentFaction(f.id, sender, now) ~= st.owner then
    return self:Reject("garrison state from outside the owners", sender)
  end
  st.seenAt = now
  -- Only accepted states raise the epochs a takeover must exceed.
  if f.epoch > st.top then st.top = f.epoch end
  local me = Me()
  local later = Beats(st, f)
  if Beats(f, st) then
    Adopt(st, f, now)
    self.dirty = true
  end
  if not later then
    -- This keeper knows at least what we know: no answer needed from us.
    st.relayable = true
    st.replyAt = nil
  end
  -- Keeper: the later epoch, then the smallest name (as an outpost's timer).
  local holder = st.authority
  if not holder or holder == sender or not self:KeeperAlive(st, now) or f.epoch > (st.authEpoch or 0)
    or (f.epoch == st.authEpoch and sender < holder) then
    if holder and holder == me and sender ~= me then
      Record("GARRISON_STEP_DOWN", { id = f.id, winner = sender })
    end
    st.authority, st.authEpoch = sender, f.epoch
    st.takeoverAt = nil
  elseif holder == me then
    -- We stay keeper: our next state, signed with our epoch, tells the rival.
    Sign(st)
    st.sendDue = true
  end
  if later and st.relayable and st.authority ~= me then
    -- We saw a later garrison than this keeper: tell it, late and cancellable.
    self:ScheduleReply(st, now)
  end
  if st.authority == sender then self:SeeAnswer(st, sender, f) end
  return true
end

-- A battle resolved by this client (modules/attack.lua, decision 0052): the
-- losses applied once, a new version when a defender died, the post-combat
-- lock never shortened. The keeper announces it as its own state too.
function Garrison:ApplyBattle(st, kills, lock, now)
  if kills.f + kills.r + kills.m <= 0 then return false end
  st.f, st.r, st.m = st.f - kills.f, st.r - kills.r, st.m - kills.m
  st.ver = st.ver + 1
  if lock > 0 and (not st.lockEnd or now + lock > st.lockEnd) then st.lockEnd = now + lock end
  if st.authority and st.authority == Me() then
    st.epoch = st.authEpoch
    st.sendDue = true
    st.repeatAt = now + REPEAT_AFTER
  end
  st.relayable = true
  st.seenAt = now
  self.dirty = true
  Record("GARRISON_BATTLE", { id = st.id, ver = st.ver, kf = kills.f, kr = kills.r, km = kills.m, lock = lock })
  return true
end

-- A garrison state announced with a battle result (AR). It is offered to the
-- garrison order like any state (rules R5, R6); trusted (a known, arrived,
-- checked battle) makes it relayable, otherwise it counts as a relay.
function Garrison:OfferBattle(sender, f, now, trusted)
  local st = self:GetState(f.id)
  if st.owner ~= "H" and st.owner ~= "A" then return self:Reject("garrison of an unheld place", sender) end
  if f.gen < st.gen then return self:Reject("old garrison generation", sender) end
  if f.gen > st.gen then return self:Reject("unobserved garrison generation", sender) end
  st.seenAt = now
  if Beats(f, st) then
    Adopt(st, f, now)
    self.dirty = true
    if st.authority and st.authority == Me() then
      Sign(st)
      st.sendDue = true
    elseif trusted then
      st.relayable = true
    else
      st.relayable = nil
    end
  end
  return true
end

function Garrison:OnRequest(sender, f, now)
  local st = self:GetState(f.id)
  local me = Me()
  -- Only the keeper answers; before it is ready the donor simply asks again.
  if not me or st.authority ~= me or now < st.readyAt then return true end
  self:Apply(st, sender, f, now)
  return true
end

-- Routed by Capture:OnMessage after echo, identity and quota checks.
function Garrison:OnMessage(kind, parts, sender, now)
  self.received = self.received + 1
  local area = self:Area(parts[1])
  if not area then return self:Reject("unknown garrison POI", sender) end
  if kind == "G" then
    local f, err = self:ParseState(parts, area)
    if not f then return self:Reject(err, sender) end
    return self:OnStateMessage(sender, f, now)
  elseif kind == "GD" then
    local f, err = self:ParseRequest(parts, area)
    if not f then return self:Reject(err, sender) end
    return self:OnRequest(sender, f, now)
  elseif kind == "GQ" then
    if table.getn(parts) ~= 1 then return self:Reject("bad GQ", sender) end
    return self:OnQuery(sender, parts[1], now)
  end
  return self:Reject("unknown kind", sender)
end

-- Local donor ---------------------------------------------------------------

local function UnitKey(text)
  if type(text) ~= "string" then return nil end
  local lower = string.lower(text)
  if FUND_KINDS[lower] then return lower end
  return PC.Army and PC.Army:Key(text)
end

function Garrison:Name(kind, owner)
  if FUND_KINDS[kind] then return kind end
  local faction = (owner == "H" or owner == "A") and owner or nil
  return PC.Army:Name(kind, faction)
end

-- Why the local player cannot donate here right now, or nil. Amounts are
-- checked by Check.
function Garrison:Closed(area, now)
  if not area then return "go inside an Outpost or Settlement of your faction" end
  local capture = PC.Capture
  local faction = capture:MyFaction()
  if not faction or not Me() then return "faction unknown" end
  local dead = GetGlobal("UnitIsDeadOrGhost")
  if type(dead) == "function" then
    local ok, flag = pcall(dead, "player")
    if ok and flag then return "you are dead" end
  end
  local st = self:GetState(area.id)
  if st.owner ~= faction then
    if area.type == "SETTLEMENT" and st.owner == "N" then
      return "nobody holds this Settlement yet: capture it first"
    end
    return "this " .. PLACE_NAMES[area.type] .. " is not held by your faction"
  end
  local here = capture.here
  if not here or here.id ~= area.id or not here.status then
    return "you are not counted inside: " .. tostring(here and here.reason or "presence unknown")
  end
  if self:Contested(area.id, st.owner, now) then return "an enemy capture is in progress" end
  if self:Pending() then return "your previous donation is still waiting for an answer" end
  local me = Me()
  if not self:KeeperAlive(st, now) then return "no garrison keeper yet: wait a few seconds" end
  if st.authority == me and now < st.readyAt then return "the garrison keeper just changed: wait a few seconds" end
  return nil
end

-- Checks a donation without changing anything. kind is a unit key, "gold" or
-- "wood". Returns st, reserve, wallet or nil, reason.
function Garrison:Check(kind, count, now)
  now = now or Now()
  if not UNIT_FIELDS[kind] and not FUND_KINDS[kind] then
    if kind == "SCOUT" then return nil, "scouts cannot join a garrison" end
    return nil, "unknown unit or resource"
  end
  local most = FUND_KINDS[kind] and LEVEL_GOLD[3] or MAX_UNITS
  if type(count) ~= "number" or count < 1 or count > most or math.floor(count) ~= count then
    return nil, "count must be 1 to " .. most
  end
  local reserve = PC.Army and PC.Army:Reserve()
  local wallet = PC.Economy and PC.Economy:Wallet()
  if not reserve or not wallet then return nil, "no saved data or identity yet" end
  local area = self:Area(PC.Presence and PC.Presence.current and PC.Presence.current.id)
  local closed = self:Closed(area, now)
  if closed then return nil, closed end
  local st = self:GetState(area.id)
  if FUND_KINDS[kind] then
    if area.type ~= "SETTLEMENT" then return nil, "only Settlements have an upgrade fund" end
    if wallet[kind] < count then return nil, "not enough " .. kind .. ": you have " .. wallet[kind] end
    local cap = kind == "gold" and LEVEL_GOLD[3] or LEVEL_WOOD[3]
    if st[kind] + count > cap then
      return nil, "the " .. kind .. " fund needs only " .. (cap - st[kind]) .. " more"
    end
    return st, reserve, wallet
  end
  if reserve[kind] < count then
    return nil, "you have only " .. reserve[kind] .. " " .. self:Name(kind, st.owner)
  end
  local frozen = PC.Attack and PC.Attack:Freeze(area.id, now)
  if frozen then return nil, frozen end
  local add = { f = 0, r = 0, m = 0 }
  add[UNIT_FIELDS[kind]] = count
  local used = Size(st.f, st.r, st.m)
  local size = Size(add.f, add.r, add.m)
  local capacity = self:Capacity(area, st.gold, st.wood)
  if used + size > capacity then
    return nil, "garrison full: needs " .. size .. " Unit Size, " .. used .. "/" .. capacity .. " used"
  end
  return st, reserve, wallet
end

function Garrison:Pending()
  local reserve = PC.Army and PC.Army:Reserve()
  local p = reserve and reserve.pending
  if type(p) == "table" then return p, reserve end
  return nil, reserve
end

local function Take(reserve, wallet, kind, count)
  if FUND_KINDS[kind] then wallet[kind] = wallet[kind] - count else reserve[kind] = reserve[kind] - count end
end

function Garrison:Finish(p, ok, text)
  self.last = { ok = ok, text = text, at = Now() }
  Record(ok and "GARRISON_DONATED" or "GARRISON_REFUNDED",
    { id = p.id, kind = p.kind, count = p.count, op = p.op, reason = text })
  Print(text)
end

-- Gives the units or resources back when the keeper refused or never answered.
-- Never a shared effect: only this character's own reserve or wallet.
function Garrison:Refund(p, reserve, reason)
  reserve.pending = nil
  local name = self:Name(p.kind, p.owner)
  if FUND_KINDS[p.kind] then
    if PC.Economy then PC.Economy:Add(p.kind, p.count) end
  else
    reserve[p.kind] = reserve[p.kind] + p.count
  end
  self:Finish(p, false, "Donation of " .. p.count .. " " .. name .. " returned: " .. reason)
end

-- Donates count units (or gold/wood) to the garrison or fund of the POI the
-- player stands in. op is the reserve's donation number read by the caller: a
-- repeated or stale request is refused, so one confirmed action donates once.
-- The units leave at once; the keeper's refusal or silence gives them back.
function Garrison:Donate(kind, count, op)
  local now = Now()
  local st, reserve, wallet = self:Check(kind, count, now)
  if not st then return false, reserve end
  if op ~= reserve.gop then return false, "request already done or out of date" end
  reserve.gop = reserve.gop + 1
  Take(reserve, wallet, kind, count)
  local p = {
    id = st.id, gen = st.gen, op = reserve.gop, kind = kind, count = count, owner = st.owner,
    to = st.authority, sends = 1, nextAt = now + RETRY_INTERVAL, giveUpAt = now + GIVE_UP_AFTER,
  }
  local me = Me()
  if st.authority == me then
    local fields = { gen = p.gen, op = p.op, f = 0, r = 0, m = 0, gold = 0, wood = 0 }
    fields[UNIT_FIELDS[kind] or kind] = count
    local result = self:Apply(st, me, fields, now)
    if result ~= "A" then
      self:Refund(p, reserve, RESULTS[result])
      return false, RESULTS[result]
    end
    self:Finish(p, true, "Donated " .. count .. " " .. self:Name(kind, st.owner) .. " to " .. st.id)
    return true, "donated"
  end
  reserve.pending = p
  self.pendingThisSession = true
  self:SendRequest(p)
  return true, "sent"
end

-- The keeper's answer to our pending donation, in a direct state.
function Garrison:SeeAnswer(st, sender, f)
  local p, reserve = self:Pending()
  if not p or p.id ~= f.id or p.to ~= sender or f.op ~= p.op or f.result == "-" then return end
  local me = Me()
  if not me or f.tag ~= Garrison.Tag(me) then return end
  if f.result == "A" then
    reserve.pending = nil
    self:Finish(p, true, "Donated " .. p.count .. " " .. self:Name(p.kind, p.owner) .. " to " .. p.id)
  else
    self:Refund(p, reserve, RESULTS[f.result])
  end
end

-- Retries a pending donation to the same keeper only: asking a new keeper
-- could apply it twice (risk B30). Gives up and refunds otherwise.
function Garrison:TickPending(now)
  local p, reserve = self:Pending()
  if not p then return end
  if not self.pendingThisSession or type(p.id) ~= "string" or not self:Area(p.id) then
    return self:Refund(p, reserve, "the client restarted before the keeper answered")
  end
  local st = self:GetState(p.id)
  local current = PC.Presence and PC.Presence.current
  if st.gen ~= p.gen then return self:Refund(p, reserve, "this place changed hands") end
  if st.authority ~= p.to then return self:Refund(p, reserve, "the garrison keeper left before answering") end
  if not current or current.id ~= p.id then return self:Refund(p, reserve, "you left before the keeper answered") end
  if now >= p.giveUpAt then return self:Refund(p, reserve, "no answer from the garrison keeper") end
  if now >= p.nextAt and p.sends < MAX_SENDS then
    p.sends = p.sends + 1
    p.nextAt = now + RETRY_INTERVAL
    self:SendRequest(p)
  end
end

-- /pc donate <unit|gold|wood> <count> confirm
function Garrison:DonateCommand(text)
  local words = {}
  local position = 1
  while true do
    local first, last, word = string.find(text or "", "(%S+)", position)
    if not first then break end
    table.insert(words, word)
    position = last + 1
  end
  local confirm = string.lower(words[table.getn(words)] or "") == "confirm"
  if confirm then table.remove(words) end
  local count = tonumber(words[table.getn(words)] or "")
  if count then table.remove(words) else count = 1 end
  local kind = UnitKey(table.concat(words, " "))
  if not kind then
    Print("usage: /pc donate <footman|rifleman|mortar|gold|wood> [count] confirm")
    return false
  end
  local st, reason = self:Check(kind, count)
  if not st then
    Print("donation refused: " .. tostring(reason))
    return false
  end
  local name = self:Name(kind, st.owner)
  if not confirm then
    Print("Irreversible: " .. count .. " " .. name .. " can never be taken back. Type /pc donate "
      .. string.lower(kind) .. " " .. count .. " confirm")
    return false
  end
  local ok, result = self:Donate(kind, count, reason.gop)
  if not ok then Print("donation refused: " .. tostring(result)) end
  if ok and result == "sent" then Print("Donation of " .. count .. " " .. name .. " sent to the garrison keeper") end
  return ok
end

-- Presence ------------------------------------------------------------------

function Garrison:Enter(id, now)
  self.here = { id = id, enterAt = now }
  local st = self:GetState(id)
  -- Always ask: what we remember may be older than the realm's garrison.
  if st.owner == "H" or st.owner == "A" then self:Send("GQ", id) end
end

function Garrison:Leave(id, now)
  self.here = nil
  local st = self.states[id]
  if st and st.authority and st.authority == Me() then st.authority = nil end
  if st then st.takeoverAt = nil end
end

function Garrison:OnPresenceChange(area, previous)
  local now = Now()
  if previous and self.here and self.here.id == previous.id then self:Leave(previous.id, now) end
  if area and self:Area(area.id) then self:Enter(area.id, now) end
end

-- Persistence ---------------------------------------------------------------

-- PandaConquestDB.garrison = { schema, realms = { [realm] = { levels = {
-- [channel level] = { [poi] = { gen, ver, epoch, f, r, m, gold, wood, lock, at } } } } } }:
-- garrisons seen from a keeper or a checked battle, per channel level (rule
-- R11), with the post-combat lock left at the wall-clock time at. Nil
-- without storage or for a newer schema.
function Garrison:Store()
  local storage = PC.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  local data = db.garrison
  if type(data) == "table" and type(data.schema) == "number" and data.schema > SCHEMA then return nil end
  if type(data) ~= "table" or data.schema ~= SCHEMA then
    data = { schema = SCHEMA, realms = {} }
    db.garrison = data
  end
  if type(data.realms) ~= "table" then data.realms = {} end
  local realm = Realm()
  local bucket = data.realms[realm]
  if type(bucket) ~= "table" then
    bucket = {}
    data.realms[realm] = bucket
  end
  if type(bucket.levels) ~= "table" then bucket.levels = {} end
  local level = tonumber(PC.channelLevel) or 0
  if type(bucket.levels[level]) ~= "table" then
    bucket.levels[level] = {}
    -- Older levels stay archived, the oldest beyond MAX_LEVELS dropped.
    while true do
      local count, lowest = 0, nil
      local key
      for key in pairs(bucket.levels) do
        count = count + 1
        if not lowest or key < lowest then lowest = key end
      end
      if count <= MAX_LEVELS then break end
      bucket.levels[lowest] = nil
    end
  end
  return bucket.levels[level]
end

function Garrison:Save()
  local pois = self:Store()
  if not pois then return end
  local id
  for id in pairs(pois) do pois[id] = nil end
  local st
  local now, wall = Now(), PC.Epoch and PC.Epoch() or 0
  for id, st in pairs(self.states) do
    local _, generation = PC.Capture:GetOwner(id)
    if st.relayable and st.ver > 0 and st.gen == generation then
      pois[id] = { gen = st.gen, ver = st.ver, epoch = st.epoch, f = st.f, r = st.r, m = st.m,
        gold = st.gold, wood = st.wood, lock = self:LockLeft(st, now), at = wall }
    end
  end
  self.dirty = nil
end

function Garrison:Load()
  self.loaded = true
  local pois = self:Store()
  if not pois then return end
  local now, wall = Now(), PC.Epoch and PC.Epoch() or 0
  local id, entry
  for id, entry in pairs(pois) do
    local area = self:Area(id)
    if area and type(entry) == "table" then
      -- The lock goes on running while offline.
      local lock = math.floor(tonumber(entry.lock) or 0)
      local away = math.max(0, wall - (tonumber(entry.at) or wall))
      lock = math.max(0, math.min(LOCK_MAX, lock - Floor(away)))
      local parts = { id, tostring(entry.gen), tostring(entry.ver), tostring(entry.epoch), tostring(entry.f),
        tostring(entry.r), tostring(entry.m), tostring(entry.gold), tostring(entry.wood), tostring(lock), "0",
        "0000", "-", "0" }
      local f = self:ParseState(parts, area)
      local st = f and self:GetState(id)
      -- A garrison of an older generation was wiped by a capture meanwhile.
      if st and f.gen == st.gen and Beats(f, st) then
        Adopt(st, f, now)
        st.relayable = true
      end
    end
  end
end

-- Driver --------------------------------------------------------------------

function Garrison:Tick(now)
  if not self.loaded then self:Load() end
  local id, st
  for id, st in pairs(self.states) do
    self:GetState(id)
    self:Maintain(id, st, now)
  end
  self:TickPending(now)
  if self.dirty and (not self.lastSaveAt or now - self.lastSaveAt >= SAVE_INTERVAL) then
    self.lastSaveAt = now
    self:Save()
  end
end

-- Display -------------------------------------------------------------------

function Garrison:View(id, now)
  local area = self:Area(id)
  if not area then return nil end
  now = now or Now()
  local st = self:GetState(id)
  local level = Garrison.Level(st.gold, st.wood)
  local view = {
    id = id, area = area, owner = st.owner, generation = st.gen, version = st.ver,
    FOOTMAN = st.f, RIFLEMAN = st.r, MORTAR = st.m, gold = st.gold, wood = st.wood,
    level = level, capacity = self:Capacity(area, st.gold, st.wood), used = Size(st.f, st.r, st.m),
    defense = Defense(st), settlement = area.type == "SETTLEMENT",
    keeper = self:KeeperAlive(st, now) and st.authority or nil, lock = self:LockLeft(st, now),
  }
  if level < 3 then
    view.nextGold, view.nextWood = LEVEL_GOLD[level + 1], LEVEL_WOOD[level + 1]
    view.nextCapacity = SETTLEMENT_CAPACITY[level + 1]
  end
  if view.keeper and view.keeper == Me() then
    view.source = "you keep this garrison"
  elseif st.relayable then
    view.source = "seen from its keeper"
  elseif st.ver > 0 then
    view.source = "reported by a player, unverified"
  else
    view.source = "no donation seen"
  end
  return view
end

function Garrison:PrintStatus()
  local current = PC.Presence and PC.Presence.current
  local view = current and self:View(current.id)
  if not view then
    Print("not in an Outpost or Settlement")
    return
  end
  local text = view.id .. " garrison " .. view.used .. "/" .. view.capacity .. " Unit Size:"
  local index = 1
  while index <= table.getn(UNIT_ORDER) do
    local key = UNIT_ORDER[index]
    text = text .. " " .. view[key] .. " " .. self:Name(key, view.owner)
    index = index + 1
  end
  Print(text .. " - defense " .. view.defense .. " - " .. view.source)
  if view.settlement then
    Print("level " .. view.level .. "/3, fund gold " .. view.gold .. " wood " .. view.wood
      .. (view.nextGold and (" (level " .. (view.level + 1) .. " at " .. view.nextGold .. " gold and "
        .. view.nextWood .. " wood)") or ""))
  end
  local now = Now()
  local closed = self:Closed(self:Area(view.id), now)
  Print(closed and ("donations closed: " .. closed) or "donations open: /pc donate <unit|gold|wood> [count] confirm")
  local frozen = not closed and PC.Attack and PC.Attack:Freeze(view.id, now)
  if frozen then Print("units cannot be given right now: " .. frozen) end
  local p = self:Pending()
  if p then Print("waiting for the keeper to answer your donation of " .. p.count .. " " .. self:Name(p.kind, p.owner)) end
end

if PC.Presence and PC.Presence.OnChange then
  PC.Presence:OnChange(function(area, previous)
    Garrison:OnPresenceChange(area, previous)
  end)
end

if PC.RegisterEvent then
  -- Fires on logout, quit and /reload, before SavedVariables are written.
  PC.RegisterEvent("PLAYER_LOGOUT", function()
    if Garrison.dirty then Garrison:Save() end
  end)
end
