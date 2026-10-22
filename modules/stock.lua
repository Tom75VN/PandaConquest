PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Stock = {
  states = {},
  here = nil,
  sent = 0,
  received = 0,
}

PC.Stock = Stock

-- Shared stocks of the resource POIs (docs/gathering.md, decision 0048).
-- Resource POIs are never captured: the authority is only the present client
-- that computes the stock and announces it, of either faction. Values from the
-- V1 balance sheet (decision 0047, tools/balance_sim.py BALANCE).
local GATHER_TICK = 10
local GATHER_AMOUNT = 5
local GATHER_PER_MINUTE = GATHER_AMOUNT * 60 / GATHER_TICK
local TYPES = {
  GOLD_MINE = { capacity = 320, regen = 9, resource = "gold", name = "Gold" },
  FARM = { capacity = 320, regen = 9, resource = "food", name = "Food" },
  FOREST = { capacity = 480, regen = 14, resource = "wood", name = "Wood" },
}
-- Same cadences and election delays as an outpost's timer (decision 0041).
local PRESENCE_INTERVAL = 10
local STATE_INTERVAL = 30
local MIN_BROADCAST_GAP = 1
local AUTHORITY_SILENCE = 90
local ENTRY_GRACE = 3.5
local ELIGIBILITY_INTERVAL = 1
local SAVE_INTERVAL = 1
local MAX_GATHERERS = 40
local PLAUSIBILITY_SLACK = 5
local REPLY_MATCHES = 2
local REPLY_ANY = 4

Stock.TYPES = TYPES
Stock.GATHER_TICK = GATHER_TICK
Stock.GATHER_AMOUNT = GATHER_AMOUNT

local FACTION_KEYS = { H = true, A = true }
local CODE_STATUSES = { I = "IN", N = "NC", O = "OUT" }

local function Now()
  local now = PC.Now and PC.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

-- Wall clock, only to age the stocks saved across a restart (never on the wire).
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

local function Int(text, maximum)
  if type(text) ~= "string" or not string.find(text, "^%d+$") or string.len(text) > 9 then
    return nil
  end
  local value = tonumber(text)
  if not value or value > maximum then return nil end
  return value
end

local function Me()
  return PC.Capture and PC.Capture:Me()
end

-- Areas and states ------------------------------------------------------------

function Stock:Resource(id)
  local map = PC.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.enabled and TYPES[area.type] then return area end
  return nil
end

function Stock:Info(id)
  local area = self:Resource(id)
  return area and TYPES[area.type] or nil
end

function Stock:GetState(id)
  local st = self.states[id]
  if st then return st end
  local info = self:Info(id)
  st = {
    id = id, stock = info and info.capacity or 0, n = 0, epoch = 0, seq = 0,
    at = Now(), lastStateAt = -1000, lastBroadcastAt = -1000, known = false,
  }
  self.states[id] = st
  return st
end

-- stock(t) = clamp(stock + (regen - 30 x n) x elapsed / 60): every client
-- extrapolates the last accepted state the same way.
function Stock.Level(st, info, now)
  local rate = info.regen - GATHER_PER_MINUTE * st.n
  -- Whole units only, rounded toward zero: re-anchoring every 30 s then never
  -- drains more than the gatherers took.
  local delta = rate * math.max(0, now - st.at) / 60
  if delta < 0 then delta = -Floor(-delta) else delta = Floor(delta) end
  local value = st.stock + delta
  if value < 0 then return 0 end
  if value > info.capacity then return info.capacity end
  return value
end

-- Moves the anchor to now, whole units only; the fraction of the unit under way
-- stays in st.at, so re-anchoring every 30 s neither adds nor loses resources.
local function Anchor(st, info, now)
  local rate = info.regen - GATHER_PER_MINUTE * st.n
  local delta = rate * math.max(0, now - st.at) / 60
  local whole
  if delta < 0 then whole = -Floor(-delta) else whole = Floor(delta) end
  local value = st.stock + whole
  if rate == 0 or value <= 0 or value >= info.capacity then
    if value < 0 then value = 0 end
    if value > info.capacity then value = info.capacity end
    st.stock, st.at = value, now
  else
    st.stock = value
    st.at = st.at + whole * 60 / rate
  end
end

-- Authority -------------------------------------------------------------------

function Stock:Send(kind, body, key)
  if not PC.Capture then return false end
  local ok = PC.Capture:Send(kind, body, key)
  if ok then self.sent = self.sent + 1 end
  return ok
end

-- A direct state (age 0) only from the authority; a relayed answer has age >= 1.
function Stock:SendState(st, age)
  return self:Send("X", st.id .. "," .. st.epoch .. "," .. st.seq .. "," .. st.stock .. "," .. st.n
    .. "," .. Floor(age or 0), "X," .. st.id)
end

function Stock:AuthorityStep(id, now, force)
  local st, info = self.states[id], self:Info(id)
  if not st or not info then return end
  local nH, nA = PC.Capture:Count(id, now)
  local n = nH + nA
  if n ~= st.n then
    -- The drain changes from now on: anchor before the new rate applies.
    Anchor(st, info, now)
    st.n = n
    st.recounted = true
  end
  local level = Stock.Level(st, info, now)
  local empty = level <= 0
  local resting = n == 0 and level >= info.capacity
  local transition = (empty and not st.empty) or (resting and not st.resting)
  st.empty, st.resting = empty, resting
  st.lastStateAt = now
  local elapsed = now - st.lastBroadcastAt
  local due = not resting and elapsed >= STATE_INTERVAL
  if force or transition or (st.recounted and elapsed >= MIN_BROADCAST_GAP) or due then
    Anchor(st, info, now)
    st.seq = st.seq + 1
    st.lastBroadcastAt = now
    st.recounted = nil
    self:SendState(st, 0)
  end
end

function Stock:AuthorityLost(st, now)
  local me = Me()
  if st.authority and st.authority == me then return false end
  if st.authority then
    if not PC.Capture:HasPresence(st.id, st.authority, now) then return true end
    if not st.resting and now - st.lastStateAt > AUTHORITY_SILENCE then return true end
    return false
  end
  return true
end

function Stock:TakeOver(id, now)
  local st, info = self.states[id], self:Info(id)
  Anchor(st, info, now)
  st.epoch = st.epoch + 1
  st.seq = 0
  st.authority = Me()
  st.epochHolder = st.authority
  st.known, st.provisional, st.restored = true, nil, nil
  st.takeoverAt, st.explicitOut, st.replyAt = nil, nil, nil
  Record("STOCK_AUTHORITY", { id = id, epoch = st.epoch })
  self:AuthorityStep(id, now, true)
end

function Stock:Maintain(id, st, now)
  local me = Me()
  local info = self:Info(id)
  if not info then return end
  if st.authority and st.authority == me then
    self:AuthorityStep(id, now, false)
    return
  end
  if st.replyAt and now >= st.replyAt then
    st.replyAt = nil
    self:SendState(st, math.max(1, Floor(now - st.at)))
  end
  local present = self.here and self.here.id == id and self.here.status and me
  if not self:AuthorityLost(st, now) then
    st.takeoverAt = nil
    return
  end
  if present then
    if not st.takeoverAt then
      local _, _, candidates = PC.Capture:Count(id, now)
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
  elseif st.n > 0 and (st.authority or st.explicitOut or now - st.lastStateAt > AUTHORITY_SILENCE) then
    -- Nobody we know of computes this stock any more: it only regenerates. A
    -- relayed count without authority is kept until the usual silence.
    Anchor(st, info, now)
    st.n = 0
    st.authority = nil
  end
end

-- Reception -------------------------------------------------------------------

function Stock:Reject(reason, sender)
  return PC.Capture:Reject(reason, sender)
end

-- An OUT, or a presence elsewhere, releases the authority it held (decision 0028).
function Stock:OnDrop(id, sender)
  local st = self.states[id]
  if st and st.authority == sender then
    st.authority = nil
    st.explicitOut = true
    st.takeoverAt = nil
  end
end

function Stock:SeeReply(st, sender, matches)
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

function Stock:OnQuery(sender, id, now)
  local st = self.states[id]
  -- Provisional and restored stocks came from elsewhere: never relayed.
  if not st or not st.known or st.provisional then return true end
  if st.authority and st.authority == Me() then
    self:AuthorityStep(id, now, true)
  elseif not st.replyAt then
    st.replyAt, st.replyAny, st.replyMatch = now + 0.5 + math.random() * 2.5, nil, nil
  end
  return true
end

-- parts: the X fields after the event id, starting with the POI.
function Stock:ParseState(parts)
  if table.getn(parts) ~= 6 then return nil, "bad X field count" end
  local info = self:Info(parts[1])
  if not info then return nil, "unknown resource POI" end
  local f = {
    id = parts[1],
    epoch = Int(parts[2], 1000000),
    seq = Int(parts[3], 100000000),
    stock = Int(parts[4], info.capacity),
    n = Int(parts[5], MAX_GATHERERS),
    age = Int(parts[6], 3600),
  }
  if not f.epoch or not f.seq or not f.stock or not f.n or not f.age then return nil, "bad X number" end
  return f
end

-- Plausibility between two states of the same producer only (rule R6).
function Stock:CheckPlausible(st, f, now)
  local info = self:Info(st.id)
  local elapsed = math.max(0, now - st.lastStateAt)
  if f.stock > st.stock + info.regen * elapsed / 60 + PLAUSIBILITY_SLACK then
    return false, "implausible stock rise"
  end
  if f.stock < st.stock - GATHER_PER_MINUTE * MAX_GATHERERS * elapsed / 60 - PLAUSIBILITY_SLACK then
    return false, "implausible stock drop"
  end
  return true
end

function Stock:OnStateMessage(sender, f, now)
  local id = f.id
  local st = self:GetState(id)
  local me = Me()
  if f.age == 0 then
    if not PC.Capture:HasPresence(id, sender, now) then return self:Reject("stock without presence", sender) end
    PC.Capture:RefreshPresence(id, sender, now)
    -- A provisional or restored stock never refuses a live one.
    if st.known and not st.provisional then
      if f.epoch < st.epoch then return self:Reject("old stock epoch", sender) end
      if f.epoch == st.epoch then
        local holder = st.authority or st.epochHolder
        if holder and holder ~= sender then
          if not (sender < holder) then return self:Reject("stock authority conflict lost", sender) end
        else
          if f.seq <= st.seq then return self:Reject("stock sequence already seen", sender) end
          local ok, reason = self:CheckPlausible(st, f, now)
          if not ok then return self:Reject(reason, sender) end
        end
      end
    end
  else
    -- A relayed answer: a starting point for display, never relayed again and
    -- never stronger than a direct state.
    self:SeeReply(st, sender, f.epoch == st.epoch and f.seq == st.seq)
    if st.known then return true end
    st.stock, st.n, st.epoch, st.seq = f.stock, f.n, f.epoch, f.seq
    st.at = now - f.age
    st.lastStateAt = st.at
    st.known, st.provisional, st.restored = true, true, nil
    st.authority, st.epochHolder = nil, nil
    return true
  end
  local wasMine = st.authority ~= nil and st.authority == me
  st.stock, st.n, st.epoch, st.seq = f.stock, f.n, f.epoch, f.seq
  st.at = now
  st.lastStateAt = now
  st.known, st.provisional, st.restored = true, nil, nil
  st.authority = sender
  st.epochHolder = sender
  st.takeoverAt, st.explicitOut, st.replyAt = nil, nil, nil
  st.recounted = nil
  if wasMine then Record("STOCK_STEP_DOWN", { id = id, winner = sender }) end
  return true
end

-- Routed by Capture:OnMessage after echo, identity and quota checks.
function Stock:OnMessage(kind, parts, sender, now)
  self.received = self.received + 1
  local id = parts[1]
  if kind == "X" then
    local f, err = self:ParseState(parts)
    if not f then return self:Reject(err, sender) end
    return self:OnStateMessage(sender, f, now)
  end
  if not self:Resource(id) then return self:Reject("unknown resource POI", sender) end
  if kind == "P" then
    -- Gatherers only use the 10 s cadence: a vanished one drains at most 25 s.
    local status = CODE_STATUSES[parts[3]]
    if table.getn(parts) ~= 4 or not FACTION_KEYS[parts[2]] or not status or parts[4] ~= "F" then
      return self:Reject("bad P", sender)
    end
    return PC.Capture:OnPresenceMessage(sender, id, parts[2], status, now, "F")
  elseif kind == "Q" then
    if table.getn(parts) ~= 1 then return self:Reject("bad Q", sender) end
    return self:OnQuery(sender, id, now)
  end
  return self:Reject("unknown kind", sender)
end

-- Local player ----------------------------------------------------------------

function Stock:Full(id)
  local info = self:Info(id)
  return info ~= nil and PC.Economy ~= nil and PC.Economy:Full(info.resource)
end

-- Same eligibility as capture, plus room in the inventory for this resource.
function Stock:UpdateHere(now, force)
  local here = self.here
  local capture = PC.Capture
  if not here or not capture then return end
  local me = capture:Me()
  local faction = capture:MyFaction()
  if not me or not faction then
    here.status, here.reason, here.nextGatherAt = nil, "faction unknown", nil
    return
  end
  local talk, lockReason = capture:CanTalk()
  if not talk then
    here.status, here.reason, here.nextGatherAt = nil, lockReason, nil
    return
  end
  local status, reason = capture:Eligibility()
  if status == "IN" and self:Full(here.id) then status, reason = "NC", "inventory full" end
  local changed = status ~= here.status
  here.status, here.reason = status, reason
  capture:SetPresence(here.id, me, faction, status, now)
  if force or changed or now - here.lastPresenceAt >= PRESENCE_INTERVAL then
    here.lastPresenceAt = now
    capture:SendPresence(here.id, status, "F")
  end
  if status == "IN" then
    if not here.nextGatherAt then here.nextGatherAt = now + GATHER_TICK end
  else
    here.nextGatherAt = nil
  end
end

-- The local 10 s tick credits this character only, from its own extrapolation;
-- no message handler ever credits anything (rule R4).
function Stock:Gather(now)
  local here = self.here
  if not here or here.status ~= "IN" or not here.nextGatherAt or now < here.nextGatherAt then return end
  here.nextGatherAt = here.nextGatherAt + GATHER_TICK
  local info = self:Info(here.id)
  if not info or not PC.Economy then return end
  local level = Stock.Level(self:GetState(here.id), info, now)
  local amount = math.min(GATHER_AMOUNT, level)
  if amount <= 0 then return end
  local added = PC.Economy:Add(info.resource, amount)
  here.gathered = (here.gathered or 0) + added
end

function Stock:Enter(id, now)
  self.here = { id = id, enterAt = now, lastPresenceAt = -1000 }
  local st = self:GetState(id)
  self:UpdateHere(now, true)
  if not st.known then
    self.here.queried = true
    self:Send("Q", id)
  end
end

function Stock:Leave(id, now)
  local here = self.here
  self.here = nil
  local me = Me()
  if me then PC.Capture:SetPresence(id, me, nil, "OUT", now) end
  local st = self.states[id]
  if st and me and st.authority == me then
    -- The last state, without this player, goes out before OUT.
    self:AuthorityStep(id, now, true)
    st.authority = nil
  end
  if st then st.takeoverAt = nil end
  if here and here.status then PC.Capture:SendPresence(id, "OUT", "F") end
end

function Stock:OnPresenceChange(area, previous)
  local now = Now()
  if previous and self.here and self.here.id == previous.id then self:Leave(previous.id, now) end
  if area and self:Resource(area.id) then self:Enter(area.id, now) end
end

-- Persistence -----------------------------------------------------------------

-- Stocks below capacity survive /reload and logout, so a reload never refills
-- a mine; they are restored with n = 0 and never relayed nor broadcast as such.
function Stock:Save(now)
  local bucket = PC.Economy and PC.Economy:RealmBucket()
  if not bucket then return end
  local stocks = {}
  local id, st
  for id, st in pairs(self.states) do
    local info = self:Info(id)
    if info and (st.known or st.restored) then
      local level = Stock.Level(st, info, now)
      if level < info.capacity or st.n > 0 then
        stocks[id] = { stock = level, t = Epoch(), epoch = st.epoch }
      end
    end
  end
  bucket.stocks = stocks
end

function Stock:Load()
  self.loaded = true
  local bucket = PC.Economy and PC.Economy:RealmBucket()
  if not bucket then return end
  local now, wall = Now(), Epoch()
  local id, entry
  for id, entry in pairs(bucket.stocks) do
    local info = self:Info(id)
    local stock, t = type(entry) == "table" and tonumber(entry.stock), type(entry) == "table" and tonumber(entry.t)
    if info and stock and t and stock >= 0 then
      local level = math.min(info.capacity, Floor(stock) + Floor(info.regen * math.max(0, wall - t) / 60))
      local st = self:GetState(id)
      if level < info.capacity and not st.known then
        st.stock, st.at, st.n = level, now, 0
        st.epoch = math.max(st.epoch, math.floor(tonumber(entry.epoch) or 0))
        st.restored = true
      end
    end
  end
end

-- Driver ----------------------------------------------------------------------

function Stock:Tick(now)
  if not self.loaded then self:Load() end
  if self.here and (not self.lastEligibilityAt or now - self.lastEligibilityAt >= ELIGIBILITY_INTERVAL) then
    self.lastEligibilityAt = now
    self:UpdateHere(now, false)
  end
  local id, st
  for id, st in pairs(self.states) do self:Maintain(id, st, now) end
  self:Gather(now)
  if not self.lastSaveAt or now - self.lastSaveAt >= SAVE_INTERVAL then
    self.lastSaveAt = now
    self:Save(now)
  end
end

-- Display ---------------------------------------------------------------------

local function Duration(seconds)
  local minutes = math.floor(seconds / 60 + 0.5)
  if minutes < 1 then return "less than 1 min" end
  return minutes .. " min"
end

function Stock:View(id, now)
  local info = self:Info(id)
  if not info then return nil end
  now = now or Now()
  local st = self.states[id]
  local level = st and Stock.Level(st, info, now) or info.capacity
  local n = st and st.n or 0
  local known = st ~= nil and (st.known or st.restored)
  local status, fullIn
  if not known then
    status = "Not observed yet: full unless gathered"
  elseif n > 0 then
    status = level <= 0 and ("Empty, " .. n .. " gatherer(s)") or ("Being gathered by " .. n .. " player(s)")
  elseif level >= info.capacity then
    status = "Full"
  else
    fullIn = (info.capacity - level) * 60 / info.regen
    status = "Regenerating, full in " .. Duration(fullIn)
  end
  return {
    id = id, resource = info.resource, name = info.name, level = level, capacity = info.capacity,
    n = n, known = known, status = status, fullIn = fullIn,
    here = self.here ~= nil and self.here.id == id,
  }
end

function Stock:TooltipInfo(id, now)
  return self:View(id, now)
end

-- Data for the HUD while the player stands in a resource POI.
function Stock:GetHud(now)
  local here = self.here
  if not here then return nil end
  local area = self:Resource(here.id)
  local view = area and self:View(here.id, now)
  if not view then return nil end
  local cap = PC.Economy and PC.Economy.CAPS[view.resource] or 0
  return {
    id = here.id, area = area, resource = view, status = here.status, reason = here.reason,
    owned = PC.Economy and PC.Economy:Get(view.resource) or 0, cap = cap,
  }
end

function Stock:PrintStatus()
  if PC.Economy then
    local wallet = PC.Economy:Wallet()
    if wallet then
      Print("resources gold " .. wallet.gold .. "/" .. PC.Economy.CAPS.gold
        .. "  wood " .. wallet.wood .. "/" .. PC.Economy.CAPS.wood
        .. "  food " .. wallet.food .. "/" .. PC.Economy.CAPS.food)
    else
      Print("resources unavailable (no saved data or identity yet)")
    end
  end
  local hud = self:GetHud()
  if hud then
    local st = self.states[hud.id]
    Print(hud.id .. " " .. hud.resource.name .. " stock " .. hud.resource.level .. "/" .. hud.resource.capacity
      .. " - " .. hud.resource.status .. " - you: " .. tostring(hud.status or "not counted")
      .. (hud.reason and (" (" .. hud.reason .. ")") or "")
      .. " - authority " .. tostring(st and st.authority or "none") .. " epoch " .. tostring(st and st.epoch or 0))
  else
    Print("not in a gold mine, forest or farm")
  end
end

if PC.Presence and PC.Presence.OnChange then
  PC.Presence:OnChange(function(area, previous)
    Stock:OnPresenceChange(area, previous)
  end)
end

if PC.RegisterEvent then
  -- Fires on logout, quit and /reload, before SavedVariables are written.
  PC.RegisterEvent("PLAYER_LOGOUT", function()
    Stock:Save(Now())
  end)
end
