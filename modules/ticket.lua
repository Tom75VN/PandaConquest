PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Ticket = {
  -- OBSERVE: tickets are checked and shown, a sender without a valid one is
  -- never ignored; only characters on the cloud's revocation list are
  -- (decision 0061 as accepted on 2026-10-22: no key may block a player).
  -- Ignoring unticketed senders is a later decision, after an in-game measure.
  MODE = "OBSERVE",
  own = { status = "NONE" },
  peers = {},
  peerCount = 0,
  queue = {},
  revoked = {},
  epoch = 0,
  counts = { verified = 0, invalid = 0, dropped = 0, revokedIgnored = 0, factionMismatch = 0, sent = 0, asked = 0 },
}

PC.Ticket = Ticket

-- Membership tickets (decision 0061): a Worker-signed Ed25519 ticket per
-- character, from the companion's import (schema 3), announced once per channel
-- join with T, asked with TQ. The signed text is rebuilt from the chat sender
-- (R1), never from a field. Tickets never enter shared state (R16 as amended):
-- they only say whether a sender is a member. Verification runs in slices of at
-- most BUDGET_MS per frame and every table here is bounded (R9).

local BUDGET_MS = 2
local MAX_PEERS = 512
local MAX_QUEUE = 16
local VALIDITY = 7
local REVOKED_DAYS = 7
local REPLY_GAP = 30
local ASK_GAP = 300
local ASK_EVERY = 2
local ASK_DELAY = 3
local MAX_ASKS = 32
local REQUEST_GAP = 600
local REQUEST_FILE = "pandaconquest_ticket_req.txt"
local MAX_FACTIONS = 64
local SIG_PATTERN = "^[%w%-_]+$"

local floor = math.floor

local function Now()
  return PC.Now and PC.Now() or (GetTime and GetTime()) or 0
end

local function Clock()
  if debugprofilestop then return debugprofilestop() end
  return Now() * 1000
end

local function Print(text)
  if PC.Print then PC.Print(text) end
end

local function Record(kind, fields)
  if PC.Record then PC.Record(kind, fields) end
end

local function DB()
  local storage = PC.Storage
  if not storage or not storage.GetDB or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  return db
end

local function Me()
  if PC.Capture and PC.Capture.Me then return PC.Capture:Me() end
  return nil
end

local function MyFaction()
  if not UnitFactionGroup then return nil end
  local group = UnitFactionGroup("player")
  if group == "Horde" then return "H" end
  if group == "Alliance" then return "A" end
  return nil
end

-- A wire field (digits only) or an imported number, as an integer in [0, maximum].
local function Int(value, maximum)
  local n
  if type(value) == "number" then
    n = value
  elseif type(value) == "string" and string.find(value, "^%d+$") and string.len(value) <= 7 then
    n = tonumber(value)
  end
  if not n or n < 0 or n > maximum or n ~= floor(n) then return nil end
  return floor(n)
end

local function D(n)
  return string.format("%d", n)
end

-- k, f, a, b, s as in the import and on the wire; nil when malformed.
function Ticket.Parse(k, f, a, b, s)
  if type(k) ~= "string" or not string.find(k, "^[0-9a-z]$") then return nil end
  if f ~= "H" and f ~= "A" then return nil end
  local from, to = Int(a, 1000000), Int(b, 1000000)
  if not from or not to or from > to or to - from > VALIDITY - 1 then return nil end
  if type(s) ~= "string" or string.len(s) ~= 86 or not string.find(s, SIG_PATTERN) then return nil end
  return { k = k, f = f, a = from, b = to, s = s }
end

function Ticket.Text(identity, t)
  return "PCT1|" .. identity .. "|" .. t.f .. "|" .. D(t.a) .. "|" .. D(t.b) .. "|" .. t.k
end

local keyCache = {}

local function KeyBytes(k)
  if keyCache[k] ~= nil then return keyCache[k] or nil end
  local keys = PC.TicketKeys and PC.TicketKeys.keys
  local hex = type(keys) == "table" and keys[k]
  local bytes = hex and PC.Ed25519 and PC.Ed25519.FromHex(hex)
  keyCache[k] = bytes or false
  return bytes
end

function Ticket:KeyCount()
  local keys = PC.TicketKeys and PC.TicketKeys.keys
  local n = 0
  if type(keys) == "table" then
    local k
    for k in pairs(keys) do n = n + 1 end
  end
  return n
end

-- Within the window around the newest epoch this client knows (decision 0061 § 2).
function Ticket:InWindow(t)
  local e = self.epoch
  return t.a <= e + 1 and t.b >= e
end

function Ticket:Revoked(identity)
  local day = self.revoked[identity]
  return day ~= nil and day > self.epoch - REVOKED_DAYS
end

-- Verification queue -----------------------------------------------------------------

local worker
local frame
local Co
local requestAfterWorker
if type(coroutine) == "table" and type(coroutine.create) == "function"
    and type(coroutine.resume) == "function" and type(coroutine.status) == "function"
    and type(coroutine.yield) == "function" then
  Co = coroutine
end

local function Pause()
  if Ticket.sliceStart and Clock() - Ticket.sliceStart > BUDGET_MS then Co.yield() end
end

local function VerifyJob(job, pause)
  local ok, valid = pcall(PC.Ed25519.Verify, job.key, job.text, job.sig, pause)
  job.done(ok and valid == true, not ok and tostring(valid) or nil)
end

local function Work()
  while true do
    local job = table.remove(Ticket.queue, 1)
    if not job then return end
    VerifyJob(job, Pause)
  end
end

local function OnUpdate()
  if not Co then
    local job = table.remove(Ticket.queue, 1)
    if not job then
      if frame then frame:SetScript("OnUpdate", nil) end
      return
    end
    local ok, err = pcall(VerifyJob, job)
    if not ok and PC.RecordError then PC.RecordError("ticket verification", err) end
    if table.getn(Ticket.queue) == 0 and frame then frame:SetScript("OnUpdate", nil) end
    return
  end
  if not worker or Co.status(worker) == "dead" then
    if table.getn(Ticket.queue) == 0 then
      if frame then frame:SetScript("OnUpdate", nil) end
      worker = nil
      return
    end
    worker = Co.create(Work)
  end
  Ticket.sliceStart = Clock()
  local ok, err = Co.resume(worker)
  Ticket.sliceStart = nil
  if requestAfterWorker then
    requestAfterWorker = nil
    Ticket:RequestIfNeeded()
  end
  if not ok then
    worker = nil
    if PC.RecordError then PC.RecordError("ticket verification", err) end
  end
end

-- Queues one verification; false when the queue is full (the T counts as lost).
function Ticket:Enqueue(key, text, sig, done)
  if table.getn(self.queue) >= MAX_QUEUE then return false end
  table.insert(self.queue, { key = key, text = text, sig = sig, done = done })
  if frame then
    frame:SetScript("OnUpdate", OnUpdate)
  else
    self:Drain()
  end
  return true
end

-- Runs every queued verification now, in one go (tests, and /pc ticket drain).
function Ticket:Drain()
  while table.getn(self.queue) > 0 do
    local job = table.remove(self.queue, 1)
    local ok, valid = pcall(PC.Ed25519.Verify, job.key, job.text, job.sig)
    job.done(ok and valid == true)
  end
end

-- Status of a ticket before any signature work: nil when it must be verified.
function Ticket:Precheck(t)
  if not t then return "INVALID" end
  if not self:InWindow(t) then return "EXPIRED" end
  if not PC.Ed25519 or not bit or type(bit.bxor) ~= "function" then return "UNSUPPORTED" end
  if not KeyBytes(t.k) then return "NOKEY" end
  return nil
end

-- Own ticket -------------------------------------------------------------------------

-- From the merged import (modules/import.lua): newest epoch, revocation list,
-- own ticket. The list of the latest Worker reading replaces the older one.
function Ticket:OnImport(data)
  if type(data) ~= "table" then return end
  local db = DB()
  local stored = db and tonumber(db.ticketEpoch) or 0
  local e = tonumber(data.ticketEpoch) or 0
  if stored > e then e = stored end
  if e > self.epoch then self.epoch = e end
  if db and self.epoch > stored then db.ticketEpoch = self.epoch end
  if type(data.revoked) == "table" then
    self.revoked = {}
    local who, day
    for who, day in pairs(data.revoked) do self.revoked[who] = day end
  end
  local me = Me()
  local raw = me and type(data.tickets) == "table" and data.tickets[me]
  local t = raw and Ticket.Parse(raw.k, raw.f, raw.a, raw.b, raw.s)
  if not t then
    if self.own.status ~= "VALID" then self.own = { status = raw and "INVALID" or "NONE" } end
    self:RequestIfNeeded()
    return
  end
  local stamp = Ticket.Text(me, t) .. t.s
  if self.own.stamp == stamp then return end
  self.own = { status = "PENDING", ticket = t, stamp = stamp }
  local pre = self:Precheck(t)
  if not pre and t.f ~= MyFaction() then pre = "FACTION" end
  if pre then
    self.own.status = pre
    self:RequestIfNeeded()
    return
  end
  local sig = PC.Ed25519.FromBase64Url(t.s)
  if not sig then
    self.own.status = "INVALID"
    return
  end
  self:Enqueue(KeyBytes(t.k), Ticket.Text(me, t), sig, function(valid)
    if Ticket.own.stamp ~= stamp then return end
    Ticket.own.status = valid and "VALID" or "INVALID"
    Record("TICKET_OWN", { status = Ticket.own.status, from = t.a, to = t.b })
    if valid and Ticket.joined then Ticket:Announce() end
    if not valid then
      if Ticket.sliceStart then requestAfterWorker = true else Ticket:RequestIfNeeded() end
    end
  end)
end

function Ticket:Expiring()
  local t = self.own.ticket
  return self.own.status ~= "VALID" or not t or t.b < self.epoch + 1
end

-- Asks the companion for a ticket through the nampower bridge (decision 0061
-- answer 2): one line, at most once per REQUEST_GAP.
function Ticket:RequestIfNeeded(now)
  now = now or Now()
  if not self:Expiring() then return false end
  if type(WriteCustomFile) ~= "function" then return false end
  if self.requestedAt and now - self.requestedAt < REQUEST_GAP then return false end
  local me, f = Me(), MyFaction()
  if not me or not f then return false end
  local ok = pcall(WriteCustomFile, REQUEST_FILE, "PCR1 " .. f .. " " .. me .. "\n")
  if not ok then return false end
  self.requestedAt = now
  self.requests = (self.requests or 0) + 1
  return true
end

-- Records this character's faction for the companion's launch snapshot.
function Ticket:SaveFaction()
  local db, me, f = DB(), Me(), MyFaction()
  if not db or not me or not f then return end
  if type(db.factions) ~= "table" then db.factions = {} end
  if db.factions[me] == f then return end
  if not db.factions[me] then
    local n, any = 0, nil
    local who
    for who in pairs(db.factions) do
      n = n + 1
      any = who
    end
    if n >= MAX_FACTIONS and any then db.factions[any] = nil end
  end
  db.factions[me] = f
end

-- Wire -------------------------------------------------------------------------------

function Ticket:Body()
  local t = self.own.ticket
  return t.k .. "," .. t.f .. "," .. D(t.a) .. "," .. D(t.b) .. "," .. t.s
end

-- One T per channel join (p2ptest.lua), and in answer to a TQ (REPLY_GAP).
function Ticket:Announce(now)
  now = now or Now()
  if self.own.status ~= "VALID" or not PC.Capture then return false end
  if self.lastSentAt and now - self.lastSentAt < REPLY_GAP then return false end
  if not PC.Capture:Send("T", self:Body(), nil, true) then return false end
  self.lastSentAt = now
  self.counts.sent = self.counts.sent + 1
  return true
end

function Ticket:OnJoined()
  self.joined = true
  self:SaveFaction()
  self:CheckServer()
  self:Announce()
end

local function EvictPeer()
  local oldest, at
  local who, entry
  for who, entry in pairs(Ticket.peers) do
    if not at or entry.at < at then oldest, at = who, entry.at end
  end
  if oldest then
    Ticket.peers[oldest] = nil
    Ticket.peerCount = Ticket.peerCount - 1
  end
end

local function SetPeer(sender, entry)
  if not Ticket.peers[sender] then
    if Ticket.peerCount >= MAX_PEERS then EvictPeer() end
    Ticket.peerCount = Ticket.peerCount + 1
  end
  Ticket.peers[sender] = entry
end

-- T from sender: strict parse, then verification in the background. Duplicates
-- of a known ticket cost nothing (R8).
function Ticket:OnTicket(parts, sender, now)
  if table.getn(parts) ~= 5 then return false, "bad T" end
  local t = Ticket.Parse(parts[1], parts[2], parts[3], parts[4], parts[5])
  if not t then return false, "bad T" end
  local stamp = Ticket.Text(sender, t) .. t.s
  local known = self.peers[sender]
  if known and known.stamp == stamp then return true end
  if self.asks and self.asks[sender] then
    self.asks[sender] = nil
    self.askCount = self.askCount - 1
  end
  local entry = { status = "PENDING", stamp = stamp, f = t.f, b = t.b, at = now }
  local pre = self:Precheck(t)
  if pre then
    entry.status = pre
    SetPeer(sender, entry)
    return true
  end
  local sig = PC.Ed25519.FromBase64Url(t.s)
  if not sig then return false, "bad T" end
  SetPeer(sender, entry)
  if not self:Enqueue(KeyBytes(t.k), Ticket.Text(sender, t), sig, function(valid)
    if Ticket.peers[sender] ~= entry then return end
    entry.status = valid and "VALID" or "INVALID"
    if valid then
      Ticket.counts.verified = Ticket.counts.verified + 1
    else
      Ticket.counts.invalid = Ticket.counts.invalid + 1
      Record("TICKET_INVALID", { sender = sender })
    end
  end) then
    self.peers[sender] = nil
    self.peerCount = self.peerCount - 1
    self.counts.dropped = self.counts.dropped + 1
  end
  return true
end

-- TQ: only the named player answers, with its own T.
function Ticket:OnQuestion(parts, sender, now)
  if table.getn(parts) ~= 1 then return false, "bad TQ" end
  local target = parts[1]
  if type(target) ~= "string" or string.len(target) > 64 or not string.find(target, "^[^@,:|]+@[^@,:|]+$") then
    return false, "bad TQ"
  end
  if target == Me() then self:Announce(now) end
  return true
end

-- Messages T and TQ from Capture:OnMessage, after identity and quota.
function Ticket:OnMessage(kind, parts, sender, now)
  if kind == "T" then return self:OnTicket(parts, sender, now) end
  return self:OnQuestion(parts, sender, now)
end

-- Step 4b of the reception chain (p2ptest.lua § 3, rule R18 proposed in 0061):
-- false drops the message as if it had been lost. In OBSERVE mode only a
-- character on the revocation list is dropped; an unknown sender is asked for
-- its ticket, later, at most once per ASK_GAP.
function Ticket:Admit(sender, kind, now)
  if kind == "T" or kind == "TQ" then return true end
  if self:Revoked(sender) then
    self.counts.revokedIgnored = self.counts.revokedIgnored + 1
    return false
  end
  if not self.peers[sender] then self:Ask(sender, now) end
  return true
end

-- A presence from a member with a verified ticket of the other faction.
function Ticket:NoteFaction(sender, faction)
  local entry = self.peers[sender]
  if entry and entry.status == "VALID" and faction and entry.f ~= faction then
    self.counts.factionMismatch = self.counts.factionMismatch + 1
    Record("TICKET_FACTION", { sender = sender })
  end
end

function Ticket:Ask(sender, now)
  if self.own.status ~= "VALID" then return end
  self.asks = self.asks or {}
  self.askCount = self.askCount or 0
  local last = self.asks[sender]
  if last and now - last.at < ASK_GAP then return end
  if not last then
    if self.askCount >= MAX_ASKS then return end
    self.askCount = self.askCount + 1
  end
  self.asks[sender] = { at = now, due = now + math.random() * ASK_DELAY }
end

-- Sends the due TQ, one every ASK_EVERY seconds at most; a T meanwhile cancels it.
function Ticket:Tick(now)
  now = now or Now()
  if not self.asks or (self.lastAskAt and now - self.lastAskAt < ASK_EVERY) then return end
  local who, ask
  for who, ask in pairs(self.asks) do
    if ask.due and now >= ask.due then
      ask.due = nil
      if not self.peers[who] and PC.Capture and PC.Capture:Send("TQ", who, nil, true) then
        self.lastAskAt = now
        self.counts.asked = self.counts.asked + 1
      end
      break
    end
  end
  -- Forget old asks so that the table stays bounded.
  for who, ask in pairs(self.asks) do
    if not ask.due and now - ask.at >= ASK_GAP then
      self.asks[who] = nil
      self.askCount = self.askCount - 1
    end
  end
end

-- OctoWoW only (roadmap WP15): a warning, nothing is turned off.
function Ticket:CheckServer()
  if self.serverChecked or not GetCVar then return end
  self.serverChecked = true
  local ok, list = pcall(GetCVar, "realmList")
  if ok and type(list) == "string" and list ~= "" and not string.find(string.lower(list), "octowow", 1, true) then
    self.foreignServer = list
    Print("PandaConquest is made for OctoWoW: the cloud ignores data from other servers.")
  end
end

-- Status and measure ----------------------------------------------------------------

function Ticket:Summary()
  local counts = { VALID = 0, INVALID = 0, PENDING = 0, EXPIRED = 0, NOKEY = 0, UNSUPPORTED = 0 }
  local who, entry
  for who, entry in pairs(self.peers) do counts[entry.status] = (counts[entry.status] or 0) + 1 end
  local n = 0
  for who in pairs(self.revoked) do n = n + 1 end
  local own = self.own.status
  if self.own.ticket then own = own .. " days " .. D(self.own.ticket.a) .. "-" .. D(self.own.ticket.b) end
  return "tickets mode=" .. self.MODE .. " keys=" .. self:KeyCount() .. " epoch=" .. self.epoch
    .. " own=" .. own .. " peers verified=" .. counts.VALID .. " invalid=" .. counts.INVALID
    .. " pending=" .. counts.PENDING .. " expired=" .. counts.EXPIRED .. " nokey=" .. counts.NOKEY
    .. " revoked=" .. n .. " ignored=" .. self.counts.revokedIgnored
    .. " factionMismatch=" .. self.counts.factionMismatch .. " sent=" .. self.counts.sent
    .. " asked=" .. self.counts.asked .. " requests=" .. tostring(self.requests or 0)
end

-- The prerequisite of decision 0061: one verification of the public test vector
-- (contract/vectors/tickets.json, key 't'), timed without slicing.
local BENCH_KEY = "8d943067fe2e127acd7608a8b6558bcaac448ef2915155d87b44c36403d0a429"
local BENCH_TEXT = "PCT1|Totom@N'Zoth|A|294|300|t"
local BENCH_SIG = "rlMc4NdmCMi3TbHpRSCnwOJUTFMgSuAJZO1RDnVY_SJQeb_odRFPk3NqUARblf9xd2klb_EOVid7B5fgjTv1BQ"

function Ticket:Bench(runs)
  local E = PC.Ed25519
  if not E or not bit or type(bit.bxor) ~= "function" then return nil, "no Ed25519 or no bit library" end
  runs = runs or 3
  local key, sig = E.FromHex(BENCH_KEY), E.FromBase64Url(BENCH_SIG)
  local start = Clock()
  local ok = true
  local i
  for i = 1, runs do ok = ok and E.Verify(key, BENCH_TEXT, sig) end
  local ms = (Clock() - start) / runs
  local tampered = E.Verify(key, BENCH_TEXT .. "x", sig)
  self.bench = { ms = ms, ok = ok and not tampered }
  Record("TICKET_BENCH", { ms = floor(ms + 0.5), ok = self.bench.ok })
  return self.bench
end

function Ticket:Command(rest)
  local option = string.lower(rest or "")
  if option == "bench" then
    local result, err = self:Bench(3)
    if not result then
      Print("ticket bench: " .. err)
    else
      Print(string.format("ticket bench: %s, %.1f ms per Ed25519 verification (thresholds: <= 20 aimed, <= 100 accepted, > 200 rejects 0061)",
        result.ok and "correct" or "WRONG RESULT", result.ms))
    end
    return
  end
  if option == "request" then
    self.requestedAt = nil
    Print(self:RequestIfNeeded() and "ticket requested from the companion" or "no request needed or possible")
    return
  end
  Print(self:Summary())
end

if CreateFrame then
  frame = CreateFrame("Frame", "PandaConquestTicketFrame", UIParent)
  frame:SetScript("OnUpdate", nil)
  local ticker = CreateFrame("Frame", "PandaConquestTicketTicker", UIParent)
  local elapsed = 0
  ticker:SetScript("OnUpdate", function()
    elapsed = elapsed + (arg1 or 0)
    if elapsed < 1 then return end
    elapsed = 0
    Ticket:Tick(Now())
  end)
end

if PC.RegisterEvent then
  PC.RegisterEvent("PLAYER_ENTERING_WORLD", function() Ticket:SaveFaction() end)
end
