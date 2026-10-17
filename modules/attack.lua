PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Attack = {
  records = {},
  count = 0,
  out = {},
  sent = 0,
  received = 0,
}

PC.Attack = Attack

-- Virtual attacks and battles (roadmap WP9, docs/attacks.md, decision 0052).
-- An army leaves the reserve at departure and travels like a scout (relative
-- clock, first copy of an order (sender, op) wins, decision 0050). On arrival
-- the first able client (the garrison keeper, then the attacker, then anyone
-- who knows the order) applies the deterministic 0047 formula to its current
-- garrison and announces the full resulting state in AR. Receivers never apply
-- a delta from a message: the state goes through the garrison order (decision
-- 0049), and the battle is marked done once per order key. An order is bound
-- to the target's owner generation: a capture during the march cancels it.
-- Values from the V1 balance sheet (decision 0047, tools/balance_sim.py).
local ASSAULT_MIN = 8
local ASSAULT_MAX = 20
local COUNTER_PCT = 30
local BEATS = { FOOTMAN = "RIFLEMAN", RIFLEMAN = "MORTAR", MORTAR = "FOOTMAN" }
local UNIT_ORDER = { "FOOTMAN", "RIFLEMAN", "MORTAR" }
local FIELDS = { FOOTMAN = "f", RIFLEMAN = "r", MORTAR = "m" }
local LOCK_MAX = 1200
local FINAL_APPROACH = 120
local FACTIONS = { H = true, A = true }
local FACTION_NAMES = { H = "Horde", A = "Alliance" }
local ORIGIN_TYPES = { OUTPOST = true, SETTLEMENT = true, BARRACKS = true }
local MAX_RECORDS = 128
local MAX_PER_OWNER = 4
local MAX_OP = 1000000000
local MAX_GENERATION = 1000000
local MAX_NUMBER = 1000000
local MAX_UNITS = 50
local MAX_IDENTITY = 64
local OTHER_CONTINENT = 900
-- A pending battle lives 24 h after its arrival; a finished one 1 h, so a
-- newcomer's catch-up still learns it is done.
local PENDING_LIFE = 86400
local DONE_LIFE = 3600
-- The owner repeats its order once, and asks for the target's garrison
-- shortly before arrival so every resolver works on a fresh state.
local REPEAT_AFTER = 10
local QUERY_BEFORE = 30
-- Resolver slots after arrival: keeper, attacker, anyone else (plus a random
-- spread), never before catch-up had time to answer after loading.
local SLOT_OWNER = 3
local SLOT_OTHER = 5
local SLOT_SPREAD = 10
local LOAD_WAIT = 20
-- A battle result for an order that has not arrived yet on our clock.
local EARLY_TOLERANCE = 30
-- Catch-up, as scouting (rule R14, rule R13).
local QUERY_DELAY = 14
local QUERY_GAP = 60
local REPLY_MIN = 0.5
local REPLY_SPREAD = 2.5
local REPLY_MATCHES = 2
local REPLY_ANY = 4
local SEND_GAP = 1
local QUEUE_ROOM = 4
local PRUNE_INTERVAL = 1
local SAVE_INTERVAL = 5
local SCHEMA = 1
local MAX_LEVELS = 3

Attack.ASSAULT = { min = ASSAULT_MIN, max = ASSAULT_MAX }
Attack.COUNTER_PCT = COUNTER_PCT
Attack.LOCK_MAX = LOCK_MAX
Attack.FINAL_APPROACH = FINAL_APPROACH

local function Now()
  local now = PC.Now and PC.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

-- Wall clock, only to age the records saved across a restart (never on the wire).
local function Wall()
  local wall = PC.Epoch and PC.Epoch() or 0
  if type(wall) ~= "number" then return 0 end
  return wall
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

local function MyFaction()
  return PC.Capture and PC.Capture:MyFaction()
end

local function Realm()
  local fn = getglobal and getglobal("GetRealmName") or (_G and _G.GetRealmName)
  local ok, realm = false, nil
  if type(fn) == "function" then ok, realm = pcall(fn) end
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

local function Clock(seconds)
  if PC.Scout and PC.Scout.Clock then return PC.Scout.Clock(seconds) end
  return tostring(Floor(math.max(0, seconds))) .. "s"
end

local function Area(id)
  local map = PC.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.enabled then return area end
  return nil
end

function Attack:Target(id)
  return PC.Scout and PC.Scout:Target(id)
end

function Attack:Label(id)
  if PC.Scout and PC.Scout.Label then return PC.Scout:Label(id) end
  return tostring(id)
end

local function UnitName(key, fac)
  return PC.Army:Name(key, fac)
end

-- "4 Footman, 2 Rifleman" with the names of faction fac; only non-zero counts.
local function Composition(counts, fac)
  local parts = {}
  local index = 1
  while index <= table.getn(UNIT_ORDER) do
    local key = UNIT_ORDER[index]
    local n = counts[FIELDS[key]] or 0
    if n > 0 then table.insert(parts, n .. " " .. UnitName(key, fac)) end
    index = index + 1
  end
  if table.getn(parts) == 0 then return "nothing" end
  return table.concat(parts, ", ")
end

Attack.Composition = Composition

-- Combat (decision 0047) ----------------------------------------------------

local function Mult(attacker, defender)
  if BEATS[attacker] == defender then return 100 + COUNTER_PCT end
  if BEATS[defender] == attacker then return 100 - COUNTER_PCT end
  return 100
end

-- Defender losses of one attack, in whole units; army and garrison carry the
-- counts f, r, m. Integer arithmetic, the same as resolve() in
-- tools/balance_sim.py: each attacking type spreads ATK x count over the
-- defender types in proportion to their DEF power, times the counter
-- multiplier; a type loses floor(damage / DEF); pooled leftovers kill whole
-- units, largest leftover first, then table order.
function Attack.Resolve(army, garrison)
  local units = PC.Army.UNITS
  local kills = { f = 0, r = 0, m = 0 }
  local power, total = {}, 0
  local index = 1
  while index <= table.getn(UNIT_ORDER) do
    local d = UNIT_ORDER[index]
    power[d] = garrison[FIELDS[d]] * units[d].def
    total = total + power[d]
    index = index + 1
  end
  if total == 0 then return kills end
  local rem, pool = {}, 0
  index = 1
  while index <= table.getn(UNIT_ORDER) do
    local d = UNIT_ORDER[index]
    local acc = 0
    local inner = 1
    while inner <= table.getn(UNIT_ORDER) do
      local a = UNIT_ORDER[inner]
      acc = acc + army[FIELDS[a]] * units[a].atk * Mult(a, d) * power[d]
      inner = inner + 1
    end
    local damage = math.floor(acc / (100 * total))
    local n, def = garrison[FIELDS[d]], units[d].def
    local k = 0
    if n > 0 then k = math.min(n, math.floor(damage / def)) end
    kills[FIELDS[d]] = k
    rem[d] = damage - k * def
    pool = pool + rem[d]
    index = index + 1
  end
  while true do
    local best
    index = 1
    while index <= table.getn(UNIT_ORDER) do
      local d = UNIT_ORDER[index]
      if garrison[FIELDS[d]] > kills[FIELDS[d]] and units[d].def <= pool
        and (not best or rem[d] > rem[best]) then
        best = d
      end
      index = index + 1
    end
    if not best then break end
    kills[FIELDS[best]] = kills[FIELDS[best]] + 1
    pool = pool - units[best].def
    rem[best] = -1
  end
  return kills
end

-- Post-combat lock in seconds from the attack's raw ATK (decision 0047):
-- 1200 x min(P, ref) / ref, ref = the best ATK per Unit Size filling the
-- highest Assault Capacity. Applied only when a defender died.
function Attack.LockSeconds(army)
  local units = PC.Army.UNITS
  local best
  local power = 0
  local index = 1
  while index <= table.getn(UNIT_ORDER) do
    local key = UNIT_ORDER[index]
    local u = units[key]
    if not best or u.atk * best.size > best.atk * u.size then best = u end
    power = power + army[FIELDS[key]] * u.atk
    index = index + 1
  end
  local ref = math.floor(ASSAULT_MAX * best.atk / best.size)
  return math.floor(LOCK_MAX * math.min(power, ref) / ref)
end

local function ISqrt(n)
  local root = math.floor(math.sqrt(n))
  while root * root > n do root = root - 1 end
  while (root + 1) * (root + 1) <= n do root = root + 1 end
  return root
end

-- Assault Capacity of faction fac from its share of the catalog's
-- Settlements (decision 0047): 8 + isqrt(144 x owned / total), 8 to 20.
function Attack:AssaultCapacity(fac)
  local owned, total = 0, 0
  local map = PC.Map
  local id, area
  for id, area in pairs(map and map.areas or {}) do
    if type(area) == "table" and area.enabled and area.type == "SETTLEMENT" then
      total = total + 1
      if PC.Capture:GetOwner(id) == fac then owned = owned + 1 end
    end
  end
  if total == 0 then return ASSAULT_MIN end
  local span = ASSAULT_MAX - ASSAULT_MIN
  return ASSAULT_MIN + ISqrt(math.floor(span * span * owned / total))
end

local function Size(army)
  local units = PC.Army.UNITS
  return army.f * units.FOOTMAN.size + army.r * units.RIFLEMAN.size + army.m * units.MORTAR.size
end

-- Records -------------------------------------------------------------------

local function Arrival(r)
  return r.depart + r.dur
end

-- The local player's attack still active: marching, or arrived and waiting
-- for its battle, at the target's current generation.
function Attack:Mine(now)
  local me = Me()
  if not me then return nil end
  local key, r
  for key, r in pairs(self.records) do
    if r.owner == me and not r.done then
      local _, generation = PC.Capture:GetOwner(r.target)
      if r.gen >= generation then return r end
    end
  end
  return nil
end

-- Why units cannot be donated to garrison id right now (decision 0052), or
-- nil: the post-combat lock, an enemy army in its last two minutes of march,
-- or a battle waiting to be resolved. The upgrade fund ignores this.
function Attack:Freeze(id, now)
  now = now or Now()
  local garrison = PC.Garrison
  local st = garrison and garrison.states[id]
  if st and st.lockEnd and st.lockEnd > now then
    return "reinforcements are locked after a battle (" .. Clock(st.lockEnd - now) .. " left)"
  end
  local owner, generation = PC.Capture:GetOwner(id)
  local soonest
  local key, r
  for key, r in pairs(self.records) do
    if r.target == id and not r.done and r.gen == generation and r.fac ~= owner then
      local left = Arrival(r) - now
      if left <= FINAL_APPROACH and (not soonest or left < soonest) then soonest = left end
    end
  end
  if not soonest then return nil end
  if soonest <= 0 then return "a battle here is waiting to be resolved" end
  return "an enemy army arrives in " .. Clock(soonest)
end

-- Arrived battles of target not yet resolved, at generation, in total order:
-- arrival, then key (the same order everywhere).
function Attack:Due(target, generation, now)
  local list = {}
  local key, r
  for key, r in pairs(self.records) do
    if r.target == target and not r.done and r.gen == generation and Arrival(r) <= now then
      table.insert(list, r)
    end
  end
  table.sort(list, function(a, b)
    if Arrival(a) ~= Arrival(b) then return Arrival(a) < Arrival(b) end
    return a.key < b.key
  end)
  return list
end

function Attack:Remove(key)
  if self.records[key] then
    self.records[key] = nil
    self.count = self.count - 1
    self.dirty = true
  end
end

-- Drops what can no longer matter: an order whose target changed hands (the
-- attack is cancelled, its units lost), a finished battle 1 h after arrival,
-- a pending one after 24 h.
function Attack:Prune(now)
  local me = Me()
  local key, r
  for key, r in pairs(self.records) do
    local _, generation = PC.Capture:GetOwner(r.target)
    if r.gen < generation then
      if r.owner == me and not r.done then
        Print("Your attack on " .. self:Label(r.target)
          .. " is cancelled: the place changed hands during the march; the units are lost")
      end
      Record("ATTACK_CANCELLED", { owner = r.owner, op = r.op, target = r.target, gen = r.gen })
      self:Remove(key)
    elseif r.done and now >= Arrival(r) + DONE_LIFE then
      self:Remove(key)
    elseif not r.done and now >= Arrival(r) + PENDING_LIFE then
      if r.owner == me then
        Print("Your attack on " .. self:Label(r.target) .. " was never resolved and is dropped; the units are lost")
      end
      Record("ATTACK_EXPIRED", { owner = r.owner, op = r.op, target = r.target })
      self:Remove(key)
    end
  end
end

-- Room for one more record (rule R9): a cancelled or finished record first,
-- else the oldest departure that is not the local player's own.
function Attack:MakeRoom(now)
  if self.count < MAX_RECORDS then return true end
  self:Prune(now)
  if self.count < MAX_RECORDS then return true end
  local me = Me()
  local victim
  local key, r
  for key, r in pairs(self.records) do
    if r.owner ~= me then
      if not victim or (r.done and not victim.done)
        or (r.done == victim.done and r.depart < victim.depart) then
        victim = r
      end
    end
  end
  if not victim then return false end
  self:Remove(victim.key)
  return true
end

-- Tells the defenders an enemy army is on its way (once per order).
function Attack:Warn(r, now)
  if r.warned then return end
  r.warned = true
  local owner = PC.Capture:GetOwner(r.target)
  local faction = MyFaction()
  if not faction or owner ~= faction or r.fac == faction or Arrival(r) <= now then return end
  Print("Enemy army marching on " .. self:Label(r.target) .. ", arrives in " .. Clock(Arrival(r) - now))
end

-- Learns one attack order. The first copy known fixes its local departure;
-- later copies change nothing (rule R8), except that a record learned from a
-- relay or restored after a restart takes a relayed "done" (a client that saw
-- the order itself while online also sees its battle). Returns the record,
-- and whether it was new.
function Attack:Learn(owner, f, direct, now)
  local key = owner .. "#" .. f.op
  local r = self.records[key]
  if r then
    if direct then r.direct = true end
    if f.done and not r.done and not r.direct then
      r.done = true
      self.dirty = true
    end
    return r, false
  end
  local depart = now - f.el
  local arrival = depart + f.dur
  if f.done and now >= arrival + DONE_LIFE then return nil, false end
  if not f.done and now >= arrival + PENDING_LIFE then return nil, false end
  local _, generation = PC.Capture:GetOwner(f.target)
  if f.gen < generation then return nil, false end
  local mine = 0
  local other, rec
  for other, rec in pairs(self.records) do
    if rec.owner == owner then mine = mine + 1 end
  end
  if mine >= MAX_PER_OWNER and owner ~= Me() then return nil, false end
  if not self:MakeRoom(now) then return nil, false end
  r = {
    key = key, owner = owner, op = f.op, target = f.target, origin = f.origin, gen = f.gen,
    dur = f.dur, fac = f.fac, f = f.f, r = f.r, m = f.m, depart = depart, direct = direct,
    done = f.done or nil, spread = math.random() * SLOT_SPREAD,
  }
  self.records[key] = r
  self.count = self.count + 1
  self.dirty = true
  Record("ATTACK_SEEN", { owner = owner, op = f.op, target = f.target, fac = f.fac, el = f.el, direct = direct })
  self:Warn(r, now)
  return r, true
end

-- Sending -------------------------------------------------------------------

function Attack:Send(kind, body, key, priority)
  if not PC.Capture then return false end
  local ok = PC.Capture:Send(kind, body, key, priority)
  if ok then self.sent = self.sent + 1 end
  return ok
end

local function Body(r, now)
  return r.target .. "," .. r.origin .. "," .. r.op .. "," .. r.gen .. "," .. r.dur .. ","
    .. Floor(math.max(0, now - r.depart)) .. "," .. r.fac .. "," .. r.f .. "," .. r.r .. "," .. r.m
end

-- AC <target>,<origin>,<op>,<gen>,<dur>,<elapsed>,<fac>,<f>,<r>,<m>: the
-- owner's order, an event, never replaced (rule R12).
function Attack:SendOrder(r, now)
  return self:Send("AC", Body(r, now), nil, true)
end

-- AR <target>,<gen>,<ver>,<epoch>,<f>,<r>,<m>,<gold>,<wood>,<lock>,<kf>,<kr>,<km>,<op>,<owner>:
-- the garrison after a battle, an event (rule R12).
function Attack:SendResult(r, st, now)
  local lock = PC.Garrison:LockLeft(st, now)
  local k = r.kills
  return self:Send("AR", st.id .. "," .. st.gen .. "," .. st.ver .. "," .. st.epoch .. "," .. st.f .. ","
    .. st.r .. "," .. st.m .. "," .. st.gold .. "," .. st.wood .. "," .. lock .. "," .. k.f .. "," .. k.r .. ","
    .. k.m .. "," .. r.op .. "," .. r.owner, nil, true)
end

-- Checks an attack toward targetId with army { f, r, m } from where the
-- player stands. Returns origin, target, duration, generation or nil, reason.
function Attack:Check(targetId, army, now)
  now = now or Now()
  local reserve = PC.Army and PC.Army:Reserve()
  if not reserve then return nil, "no saved data or identity yet" end
  local fac = MyFaction()
  local total = 0
  local index = 1
  while index <= table.getn(UNIT_ORDER) do
    local key = UNIT_ORDER[index]
    local n = army[FIELDS[key]]
    if type(n) ~= "number" or n < 0 or math.floor(n) ~= n then return nil, "unit counts must be whole numbers" end
    if n > reserve[key] then return nil, "you have only " .. reserve[key] .. " " .. UnitName(key, fac) end
    total = total + n
    index = index + 1
  end
  if total < 1 then return nil, "choose at least one combat unit" end
  if not PC.Capture:CanTalk() then return nil, PC.Capture.LEVEL_REASON or "you cannot speak on the channel yet" end
  local mine = self:Mine(now)
  if mine then
    if Arrival(mine) > now then return nil, "your army is still marching (" .. Clock(Arrival(mine) - now) .. " left)" end
    return nil, "your last attack is waiting for its battle"
  end
  local origin, why = PC.Army:Place()
  if not origin then return nil, why end
  local target = self:Target(targetId)
  if not target then return nil, "only an Outpost or a Settlement can be attacked" end
  local owner, generation = PC.Capture:GetOwner(target.id)
  if not FACTIONS[owner or ""] or owner == fac then
    return nil, "only a place held by the enemy faction can be attacked"
  end
  if not PC.Scout:Discovery(target.id, fac, now) then
    return nil, "scout it first: an attack needs an active discovery of the target"
  end
  local capacity = self:AssaultCapacity(fac)
  local size = Size(army)
  if size > capacity then
    return nil, "army too large: " .. size .. " Unit Size, your Assault Capacity is " .. capacity
  end
  local duration = PC.Scout:Travel(origin, target)
  if not duration then return nil, "no travel data for this map" end
  return origin, target, duration, generation
end

-- Sends the player's army: its units leave the reserve at once and for good.
-- op is the reserve's attack number, so a repeated request does nothing (as
-- recruitment). Returns true, record or false, reason.
function Attack:Launch(targetId, army, op)
  local now = Now()
  local origin, target, duration, generation = self:Check(targetId, army, now)
  if not origin then return false, target end
  local reserve = PC.Army:Reserve()
  if op ~= reserve.aop then return false, "request already done or out of date" end
  local me = Me()
  local f = {
    target = target.id, origin = origin.id, op = reserve.aop + 1, gen = generation, dur = duration,
    el = 0, fac = MyFaction(), f = army.f, r = army.r, m = army.m,
  }
  if self.records[me .. "#" .. f.op] then return false, "request already done or out of date" end
  local r = self:Learn(me, f, true, now)
  if not r then return false, "too many attacks known" end
  reserve.FOOTMAN = reserve.FOOTMAN - army.f
  reserve.RIFLEMAN = reserve.RIFLEMAN - army.r
  reserve.MORTAR = reserve.MORTAR - army.m
  reserve.aop = f.op
  r.repeatAt = now + REPEAT_AFTER
  r.queryAt = Arrival(r) - QUERY_BEFORE
  self:SendOrder(r, now)
  Record("ATTACK_SENT", { target = f.target, origin = f.origin, op = f.op, gen = f.gen, dur = f.dur,
    f = f.f, r = f.r, m = f.m })
  return true, r
end

-- /pc attack [<POI id> <footmen> [riflemen] [mortars]]
function Attack:Command(text)
  local words = {}
  local position = 1
  while true do
    local first, last, word = string.find(text or "", "(%S+)", position)
    if not first then break end
    table.insert(words, word)
    position = last + 1
  end
  if table.getn(words) == 0 then
    self:PrintStatus()
    return false
  end
  local id = string.upper(words[1])
  local army = {
    f = tonumber(words[2] or "0"), r = tonumber(words[3] or "0"), m = tonumber(words[4] or "0"),
  }
  if table.getn(words) < 2 or table.getn(words) > 4 or not army.f or not army.r or not army.m then
    Print("usage: /pc attack <POI id> <footmen> [riflemen] [mortars]")
    return false
  end
  local reserve = PC.Army and PC.Army:Reserve()
  local ok, result = self:Launch(id, army, reserve and reserve.aop)
  if not ok then
    Print("attack refused: " .. tostring(result))
    return false
  end
  Print("Army of " .. Composition(result, result.fac) .. " sent to " .. self:Label(id) .. ", arrives in "
    .. Clock(result.dur) .. "; the units are gone for good")
  return true
end

-- Battles ---------------------------------------------------------------------

-- Marks a battle done once per order key and tells the players concerned:
-- the attacker's faction and the defenders. The enemy never sees the
-- attacking composition.
function Attack:Done(r, kills, lock, now)
  if r.done then return false end
  r.done = true
  r.kills = kills
  r.lock = lock
  self.dirty = true
  local faction = MyFaction()
  local owner = PC.Capture:GetOwner(r.target)
  if faction and (r.fac == faction or owner == faction) then
    local text = "Battle at " .. self:Label(r.target) .. ": " .. (FACTION_NAMES[r.fac] or "enemy") .. " attack"
    if kills and kills.f + kills.r + kills.m > 0 then
      text = text .. " killed " .. Composition(kills, owner) .. "; reinforcements locked " .. Clock(lock or 0)
    elseif kills then
      text = text .. " killed nobody"
    else
      text = text .. " resolved by another player"
    end
    Print(text)
  end
  Record("ATTACK_RESOLVED", { owner = r.owner, op = r.op, target = r.target, lock = lock,
    kf = kills and kills.f, kr = kills and kills.r, km = kills and kills.m })
  return true
end

-- Resolves one battle on the current garrison and announces the new state.
function Attack:ResolveOne(r, st, now)
  local kills = Attack.Resolve(r, st)
  local lock = 0
  if kills.f + kills.r + kills.m > 0 then lock = Attack.LockSeconds(r) end
  PC.Garrison:ApplyBattle(st, kills, lock, now)
  self:Done(r, kills, lock, now)
  self:SendResult(r, st, now)
end

-- Resolves the due battles of upto's target in total order, up to upto: each
-- one on the previous result, so the same losses are never applied twice.
function Attack:ResolveTarget(upto, now)
  local st = PC.Garrison:GetState(upto.target)
  if st.gen ~= upto.gen or not FACTIONS[st.owner or ""] then return end
  local list = self:Due(upto.target, st.gen, now)
  local index = 1
  while index <= table.getn(list) do
    local r = list[index]
    if r.fac ~= st.owner then self:ResolveOne(r, st, now) end
    if r == upto then break end
    index = index + 1
  end
end

-- When this client resolves r (local clock): the keeper at arrival, the
-- attacker 3 s later, anyone else 5 to 15 s later; never before catch-up had
-- time to answer after loading.
function Attack:Slot(r, now)
  local arrival = Arrival(r)
  local me = Me()
  local slot
  local st = PC.Garrison.states[r.target]
  if st and me and st.authority == me and PC.Garrison:KeeperAlive(st, now) then
    slot = arrival
  elseif r.owner == me then
    slot = arrival + SLOT_OWNER
  else
    slot = arrival + SLOT_OTHER + (r.spread or 0)
  end
  local ready = (self.loadedAt or now) + LOAD_WAIT
  if slot < ready then slot = ready end
  return slot
end

function Attack:Resolver(now)
  if not PC.Garrison or not PC.Capture:CanTalk() then return end
  local due = {}
  local key, r
  for key, r in pairs(self.records) do
    if not r.done and Arrival(r) <= now and now >= self:Slot(r, now) then table.insert(due, r) end
  end
  table.sort(due, function(a, b)
    if Arrival(a) ~= Arrival(b) then return Arrival(a) < Arrival(b) end
    return a.key < b.key
  end)
  local index = 1
  while index <= table.getn(due) do
    local r = due[index]
    if not r.done then
      local _, generation = PC.Capture:GetOwner(r.target)
      if r.gen == generation then self:ResolveTarget(r, now) end
    end
    index = index + 1
  end
end

-- Reception -----------------------------------------------------------------

function Attack:Reject(reason, sender)
  return PC.Capture:Reject(reason, sender)
end

-- Fields shared by AC and AL, strictly checked (rule R2).
function Attack:Parse(parts, maxElapsed)
  local f = {
    target = parts[1], origin = parts[2],
    op = Int(parts[3], MAX_OP), gen = Int(parts[4], MAX_GENERATION), dur = Int(parts[5], OTHER_CONTINENT),
    fac = parts[7], f = Int(parts[8], ASSAULT_MAX), r = Int(parts[9], ASSAULT_MAX), m = Int(parts[10], ASSAULT_MAX),
  }
  if not f.op or not f.gen or not f.dur or f.op < 1 then return nil, "bad attack number" end
  if not f.f or not f.r or not f.m then return nil, "bad attack composition" end
  local size = Size(f)
  if f.f + f.r + f.m < 1 or size > ASSAULT_MAX then return nil, "bad attack composition" end
  f.el = Int(parts[6], f.dur + (maxElapsed or 0))
  if not f.el then return nil, "bad attack elapsed time" end
  if not FACTIONS[f.fac or ""] then return nil, "bad attack faction" end
  local target, origin = self:Target(f.target), Area(f.origin)
  if not target then return nil, "unknown attack target" end
  if not origin or not ORIGIN_TYPES[origin.type] or origin.id == target.id then
    return nil, "bad attack origin"
  end
  if PC.Scout:Travel(origin, target) ~= f.dur then return nil, "bad attack duration" end
  return f
end

local function ValidOwner(text)
  return type(text) == "string" and string.len(text) <= MAX_IDENTITY
    and string.find(text, "^[^,@]+@[^,@]+$") ~= nil
end

-- R14: our pending answer is cancelled after two other answers matching
-- what we know, or any four answers.
function Attack:SeeReply(sender, matches)
  if not self.replyAt and table.getn(self.out) == 0 then return end
  self.replyAny = self.replyAny or {}
  self.replyMatch = self.replyMatch or {}
  self.replyAny[sender] = true
  if matches then self.replyMatch[sender] = true end
  local any, match = 0, 0
  local name
  for name in pairs(self.replyAny) do any = any + 1 end
  for name in pairs(self.replyMatch) do match = match + 1 end
  if match >= REPLY_MATCHES or any >= REPLY_ANY then
    self.replyAt, self.replyAny, self.replyMatch = nil, nil, nil
    self.out = {}
  end
end

-- AR: the garrison state goes through the garrison order whatever happens
-- (convergence, rule R6); the battle is marked done only for a known order of
-- that generation that has arrived, and only when the result matches what
-- this client computes from the same garrison version (or when this client
-- is behind and cannot check).
function Attack:OnResult(parts, sender, now)
  if table.getn(parts) ~= 15 then return self:Reject("bad AR field count", sender) end
  local garrison = PC.Garrison
  local area = self:Target(parts[1])
  if not area or not garrison then return self:Reject("unknown battle target", sender) end
  local f, err = garrison:ParseState({ parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7],
    parts[8], parts[9], parts[10], "0", "0000", "-", "1" }, area)
  if not f then return self:Reject(err, sender) end
  local kills = { f = Int(parts[11], MAX_UNITS), r = Int(parts[12], MAX_UNITS), m = Int(parts[13], MAX_UNITS) }
  local op = Int(parts[14], MAX_OP)
  if not kills.f or not kills.r or not kills.m or not op or op < 1 then return self:Reject("bad AR number", sender) end
  if not ValidOwner(parts[15]) then return self:Reject("bad AR owner", sender) end
  local r = self.records[parts[15] .. "#" .. op]
  if not r then
    -- An order we never learned: a plain relayed garrison state.
    return garrison:OfferBattle(sender, f, now, false)
  end
  if r.target ~= f.id or r.gen ~= f.gen then return self:Reject("battle result for another target", sender) end
  if Arrival(r) > now + EARLY_TOLERANCE then return self:Reject("early battle result", sender) end
  local st = garrison:GetState(f.id)
  if not r.done and (f.ver == st.ver or f.ver == st.ver + 1) and st.gen == f.gen then
    local expect = Attack.Resolve(r, st)
    local any = expect.f + expect.r + expect.m > 0
    local ver = st.ver
    if any then ver = ver + 1 end
    if f.ver ~= ver or f.f ~= st.f - expect.f or f.r ~= st.r - expect.r or f.m ~= st.m - expect.m
      or kills.f ~= expect.f or kills.r ~= expect.r or kills.m ~= expect.m then
      -- Built on another garrison version (a concurrent battle) or forged:
      -- not ours to adopt; our own slot resolves it on what we hold.
      return self:Reject("battle result mismatch", sender)
    end
  end
  local accepted = garrison:OfferBattle(sender, f, now, true)
  if accepted and not r.done then
    local lock = 0
    if kills.f + kills.r + kills.m > 0 then lock = Attack.LockSeconds(r) end
    self:Done(r, kills, lock, now)
  end
  return accepted
end

-- Routed by Capture:OnMessage after echo, identity and quota checks.
function Attack:OnMessage(kind, parts, sender, now)
  self.received = self.received + 1
  if kind == "AC" then
    if table.getn(parts) ~= 10 then return self:Reject("bad AC field count", sender) end
    local f, err = self:Parse(parts, 0)
    if not f then return self:Reject(err, sender) end
    -- Identity: the chat sender, never a field (rule R1).
    self:Learn(sender, f, true, now)
    return true
  elseif kind == "AL" then
    if table.getn(parts) ~= 12 then return self:Reject("bad AL field count", sender) end
    local f, err = self:Parse(parts, PENDING_LIFE)
    if not f then return self:Reject(err, sender) end
    if parts[11] ~= "0" and parts[11] ~= "1" then return self:Reject("bad AL done flag", sender) end
    if not ValidOwner(parts[12]) then return self:Reject("bad AL owner", sender) end
    f.done = parts[11] == "1"
    -- A relay about a third party (or us): data, never the relayer's identity.
    local r, new = self:Learn(parts[12], f, false, now)
    self:SeeReply(sender, r ~= nil and not new and (r.done or false) == f.done)
    return true
  elseif kind == "AQ" then
    if table.getn(parts) ~= 1 or parts[1] ~= "*" then return self:Reject("bad AQ", sender) end
    if self.count > 0 and not self.replyAt then
      self.replyAt = now + REPLY_MIN + math.random() * REPLY_SPREAD
      self.replyAny, self.replyMatch = nil, nil
    end
    return true
  elseif kind == "AR" then
    return self:OnResult(parts, sender, now)
  end
  return self:Reject("unknown kind", sender)
end

-- Channel join (modules/p2ptest.lua): one catch-up request a little later.
function Attack:OnJoined(now)
  now = now or Now()
  if self.askedAt and now - self.askedAt < QUERY_GAP then return false end
  self.askedAt = now
  self.queryAt = now + QUERY_DELAY
  return true
end

local function QueueRoom()
  local queue = PC.SendQueue
  if not queue or type(queue.Pending) ~= "function" then return true end
  return queue:Pending() < QUEUE_ROOM
end

local function RelayBody(r, now)
  return Body(r, now) .. "," .. (r.done and "1" or "0") .. "," .. r.owner
end

-- AL <...AC fields>,<done>,<owner>: one known attack, elapsed since its
-- departure; replaceable, dropped first (rule R13).
function Attack:Answer(now)
  self.replyAt = nil
  self.out = {}
  self:Prune(now)
  local key
  for key in pairs(self.records) do table.insert(self.out, key) end
  table.sort(self.out)
end

-- Driver --------------------------------------------------------------------

function Attack:Tick(now)
  if not self.loaded then self:Load(now) end
  if self.queryAt and now >= self.queryAt then
    self.queryAt = nil
    self:Send("AQ", "*")
  end
  if self.replyAt and now >= self.replyAt then self:Answer(now) end
  if table.getn(self.out) > 0 and now >= (self.nextSendAt or 0) and QueueRoom() then
    local key = table.remove(self.out, 1)
    local r = self.records[key]
    -- Rebuilt at send time so the elapsed time stays current (risk B10).
    if r and self:Send("AL", RelayBody(r, now), "AL," .. key) then
      self.answers = (self.answers or 0) + 1
    end
    self.nextSendAt = now + SEND_GAP
  end
  local mine = self:Mine(now)
  if mine and mine.repeatAt and now >= mine.repeatAt then
    mine.repeatAt = nil
    self:SendOrder(mine, now)
  end
  if mine and mine.queryAt and now >= mine.queryAt then
    mine.queryAt = nil
    if PC.Garrison then PC.Garrison:Send("GQ", mine.target) end
  end
  if not self.lastPruneAt or now - self.lastPruneAt >= PRUNE_INTERVAL then
    self.lastPruneAt = now
    self:Prune(now)
  end
  self:Resolver(now)
  if self.dirty and (not self.lastSaveAt or now - self.lastSaveAt >= SAVE_INTERVAL) then
    self.lastSaveAt = now
    self:Save()
  end
end

-- Persistence ---------------------------------------------------------------

-- PandaConquestDB.attack = { schema, realms = { [realm] = { levels = {
-- [channel level] = { at = wall clock, records = { [key] = { owner, op,
-- target, origin, gen, dur, fac, f, r, m, el, done, kf, kr, km, lock } } } } } } }.
function Attack:Store()
  local storage = PC.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  local data = db.attack
  if type(data) == "table" and type(data.schema) == "number" and data.schema > SCHEMA then return nil end
  if type(data) ~= "table" or data.schema ~= SCHEMA then
    data = { schema = SCHEMA, realms = {} }
    db.attack = data
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
  local entry = bucket.levels[level]
  if type(entry.records) ~= "table" then entry.records = {} end
  return entry
end

function Attack:Save()
  local entry = self:Store()
  self.dirty = nil
  if not entry then return end
  local now = Now()
  entry.at = Wall()
  entry.records = {}
  local key, r
  for key, r in pairs(self.records) do
    local saved = {
      owner = r.owner, op = r.op, target = r.target, origin = r.origin, gen = r.gen, dur = r.dur, fac = r.fac,
      f = r.f, r = r.r, m = r.m, el = Floor(math.max(0, now - r.depart)), done = r.done and true or nil,
      lock = r.lock,
    }
    if r.kills then saved.kf, saved.kr, saved.km = r.kills.f, r.kills.r, r.kills.m end
    entry.records[key] = saved
  end
end

-- Restores the saved attacks, aged by the wall time spent offline; the same
-- checks as a received record.
function Attack:Load(now)
  self.loaded = true
  now = now or Now()
  self.loadedAt = now
  local entry = self:Store()
  if not entry then return end
  local away = math.max(0, Wall() - (tonumber(entry.at) or Wall()))
  local key, saved
  for key, saved in pairs(entry.records) do
    if type(saved) == "table" and ValidOwner(saved.owner) then
      local el = (tonumber(saved.el) or 0) + away
      local parts = { tostring(saved.target), tostring(saved.origin), tostring(saved.op), tostring(saved.gen),
        tostring(saved.dur), tostring(Floor(math.min(el, (tonumber(saved.dur) or 0) + PENDING_LIFE))),
        tostring(saved.fac), tostring(saved.f), tostring(saved.r), tostring(saved.m) }
      local f = self:Parse(parts, PENDING_LIFE)
      if f then
        f.done = saved.done == true
        local r = self:Learn(saved.owner, f, false, now)
        if r and r.done then
          r.warned = true
          if tonumber(saved.kf) and tonumber(saved.kr) and tonumber(saved.km) then
            r.kills = { f = tonumber(saved.kf), r = tonumber(saved.kr), m = tonumber(saved.km) }
          end
          r.lock = tonumber(saved.lock)
        end
      end
    end
  end
  self.dirty = nil
end

-- Display -------------------------------------------------------------------

-- Armies still marching, for the map routes (modules/map.lua): records with
-- depart, dur, origin, target and fac, as scouts.
function Attack:Marching(now)
  local list = {}
  local key, r
  for key, r in pairs(self.records) do
    if not r.done and Arrival(r) > now then table.insert(list, r) end
  end
  return list
end

-- Tooltip lines of an Outpost or Settlement: armies on their way (the exact
-- composition for one's own faction only), a battle waiting, the lock.
function Attack:TooltipInfo(id, now)
  if not self:Target(id) or not PC.Capture then return nil end
  now = now or Now()
  local faction = MyFaction()
  local _, generation = PC.Capture:GetOwner(id)
  local info = {}
  local key, r
  for key, r in pairs(self.records) do
    if r.target == id and not r.done and r.gen == generation then
      if Arrival(r) <= now then
        info.pending = true
      elseif r.fac == faction then
        if not info.allied or Arrival(r) < info.allied.arrival then
          info.allied = { arrival = Arrival(r), left = Arrival(r) - now, army = Composition(r, r.fac) }
        end
      elseif not info.enemy or Arrival(r) - now < info.enemy then
        info.enemy = Arrival(r) - now
      end
    end
  end
  local st = PC.Garrison and PC.Garrison.states[id]
  if st and st.lockEnd and st.lockEnd > now then info.locked = st.lockEnd - now end
  if not info.pending and not info.allied and not info.enemy and not info.locked then return nil end
  return info
end

function Attack:PrintStatus()
  local now = Now()
  local fac = MyFaction()
  local reserve = PC.Army and PC.Army:Reserve()
  if not reserve then
    Print("no saved data or identity yet")
    return
  end
  Print("Assault Capacity " .. self:AssaultCapacity(fac) .. " Unit Size; reserve: "
    .. Composition({ f = reserve.FOOTMAN, r = reserve.RIFLEMAN, m = reserve.MORTAR }, fac))
  local mine = self:Mine(now)
  if mine then
    if Arrival(mine) > now then
      Print("your army (" .. Composition(mine, fac) .. ") arrives at " .. self:Label(mine.target) .. " in "
        .. Clock(Arrival(mine) - now))
    else
      Print("your attack on " .. self:Label(mine.target) .. " is waiting for its battle")
    end
  else
    Print("send an army: /pc attack <POI id> <footmen> [riflemen] [mortars], from an allied place, to a"
      .. " discovered enemy Outpost or Settlement")
  end
  local key, r
  for key, r in pairs(self.records) do
    if r.owner ~= Me() and not r.done then
      local owner = PC.Capture:GetOwner(r.target)
      local where = self:Label(r.target)
      local state = Arrival(r) > now and ("arrives in " .. Clock(Arrival(r) - now)) or "battle pending"
      if r.fac == fac then
        Print("allied army (" .. Composition(r, fac) .. ") toward " .. where .. ": " .. state)
      elseif owner == fac then
        Print("enemy army toward " .. where .. ": " .. state)
      end
    end
  end
end

if PC.RegisterEvent then
  -- Fires on logout, quit and /reload, before SavedVariables are written.
  PC.RegisterEvent("PLAYER_LOGOUT", function()
    if Attack.dirty then Attack:Save() end
  end)
end
