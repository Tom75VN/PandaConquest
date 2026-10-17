PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Capture = PC.Capture
local Catchup = {
  joinedAt = nil,
  lastSeriesAt = nil,
  digestAt = nil,
  sentAt = nil,
  retries = 0,
  round = nil,
  pending = {},
  answeredAt = {},
  skipped = {},
  out = {},
  nextSendAt = 0,
  digests = 0,
  answers = 0,
  ignored = 0,
}

PC.Catchup = Catchup

-- Owner catch-up after joining the channel (decision 0038). The joiner sends
-- one hash per map (OD); a peer whose hash differs sends that map's confirmed
-- owners (OL). Every OL entry is only a hint of its chat sender (Capture:NoteHint):
-- the registry moves only through the quorum. Values proposed, not measured.
local DIGEST_DELAY = 10
local SERIES_GAP = 60
local RETRY_DELAY = 30
local MAX_RETRIES = 2
local GROUPS_PER_DIGEST = 20
local MAX_DIGEST_PARTS = 3
local ENTRIES_PER_LINE = 10
local MAX_LINE_PARTS = 4
local SENIORITY = 300
local LOCAL_DELAY, LOCAL_SPREAD = 1, 2
local PEER_DELAY, PEER_SPREAD = 3, 3
-- Rule R14 with two answers: drop ours after two answers carrying our own
-- hash, or four answers of any hash, for that map.
local ANSWER_MATCHES = 2
local ANSWER_ANY = 4
-- Shorter than RETRY_DELAY, and a peer whose answer was dropped answers first
-- at the joiner's retry: retries bring the third sender quorum Q2 needs.
local ANSWER_GAP = 25
local SKIPPED_DELAY, SKIPPED_SPREAD = 0.5, 0.5
local LINES_PER_DIGEST = 12
local MAX_OUT = 24
local SEND_GAP = 1
local QUEUE_ROOM = 4
local HASH_MODULUS = 16777213
local EMPTY_HASH = "00000"
local DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

Catchup.SENIORITY = SENIORITY
Catchup.DIGEST_DELAY = DIGEST_DELAY

local function Now()
  return PC.Now and PC.Now() or 0
end

local function Floor(value)
  return math.floor(value)
end

local function Record(kind, fields)
  if PC.Record then PC.Record(kind, fields) end
end

-- A positive integer without leading zero, within bounds.
local function Int(text, minimum, maximum)
  if type(text) ~= "string" or not string.find(text, "^[1-9]%d*$") or string.len(text) > 7 then return nil end
  local value = tonumber(text)
  if not value or value < minimum or value > maximum then return nil end
  return value
end

local function Base36(value, width)
  local text = ""
  while value > 0 do
    local digit = value - Floor(value / 36) * 36
    text = string.sub(DIGITS, digit + 1, digit + 1) .. text
    value = Floor(value / 36)
  end
  while string.len(text) < width do text = "0" .. text end
  return text
end

local function IsCode(text)
  return type(text) == "string" and string.find(text, "^[0-9A-Z][0-9A-Z]$") ~= nil
end

local function IsHash(text)
  return type(text) == "string" and string.find(text, "^[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]$") ~= nil
end

local function IsPoi(text)
  return type(text) == "string" and string.find(text, "^[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]$") ~= nil
end

-- Capturable POIs grouped by map: the MM prefix of the id (decision 0038 makes
-- this exception to decision 0016). Codes and ids sorted.
function Catchup:Groups()
  local groups, codes = {}, {}
  local map = PC.Map
  if not map or type(map.order) ~= "table" then return groups, codes end
  local index = 1
  while index <= table.getn(map.order) do
    local id = map.order[index]
    if Capture:Capturable(id) then
      local code = string.sub(id, 1, 2)
      if not groups[code] then
        groups[code] = {}
        table.insert(codes, code)
      end
      table.insert(groups[code], id)
    end
    index = index + 1
  end
  table.sort(codes)
  local code
  for code in pairs(groups) do table.sort(groups[code]) end
  return groups, codes
end

-- The confirmed registry only, never a hint: { id, generation, owner, source }.
function Catchup:Entries(ids)
  local entries = {}
  local index = 1
  while index <= table.getn(ids or {}) do
    local entry = Capture.owners[ids[index]]
    if entry and entry.generation and entry.generation >= 1 and (entry.owner == "H" or entry.owner == "A") then
      table.insert(entries, { id = ids[index], generation = entry.generation, owner = entry.owner,
        source = entry.source })
    end
    index = index + 1
  end
  return entries
end

-- h = (h * 31 + byte) mod 16777213 over "id:generation:owner;", base 36 on 5
-- characters; 00000 for an empty map, 00001 when a non-empty one hashes to 0.
function Catchup:Hash(ids)
  local entries = self:Entries(ids)
  if table.getn(entries) == 0 then return EMPTY_HASH, entries end
  local h = 0
  local index = 1
  while index <= table.getn(entries) do
    local entry = entries[index]
    local text = entry.id .. ":" .. entry.generation .. ":" .. entry.owner .. ";"
    local position = 1
    while position <= string.len(text) do
      h = h * 31 + string.byte(text, position)
      h = h - Floor(h / HASH_MODULUS) * HASH_MODULUS
      position = position + 1
    end
    index = index + 1
  end
  if h == 0 then h = 1 end
  return Base36(h, 5), entries
end

-- Channel join (modules/p2ptest.lua): one digest series 10 s later, at most one
-- series per minute. Seniority, needed to answer, restarts at each join.
function Catchup:OnJoined(now)
  now = now or Now()
  self.joinedAt = now
  if self.lastSeriesAt and now - self.lastSeriesAt < SERIES_GAP then return false end
  self.lastSeriesAt = now
  self.digestAt = now + DIGEST_DELAY
  self.retries = 0
  return true
end

function Catchup:SendDigest(now)
  local groups, codes = self:Groups()
  local count = table.getn(codes)
  if count > GROUPS_PER_DIGEST * MAX_DIGEST_PARTS then count = GROUPS_PER_DIGEST * MAX_DIGEST_PARTS end
  if count == 0 then return 0 end
  local parts = Floor((count + GROUPS_PER_DIGEST - 1) / GROUPS_PER_DIGEST)
  local round = { mine = {}, answers = {} }
  local sent = 0
  local part = 1
  while part <= parts do
    local first = (part - 1) * GROUPS_PER_DIGEST + 1
    local last = math.min(count, part * GROUPS_PER_DIGEST)
    local fields = { part, parts, last - first + 1 }
    local index = first
    while index <= last do
      local code = codes[index]
      local hash = self:Hash(groups[code])
      round.mine[code] = hash
      table.insert(fields, code)
      table.insert(fields, hash)
      index = index + 1
    end
    if Capture:Send("OD", table.concat(fields, ",")) then sent = sent + 1 end
    part = part + 1
  end
  self.round = round
  self.sentAt = now
  self.digests = self.digests + 1
  Record("CATCHUP_DIGEST", { groups = count, parts = parts, retry = self.retries })
  return sent
end

-- Retry only while an answer seen still carries another hash than ours.
function Catchup:StillDiffers()
  if not self.round then return false end
  local groups = self:Groups()
  local code, hashes
  for code, hashes in pairs(self.round.answers) do
    local mine = self:Hash(groups[code])
    local hash
    for hash in pairs(hashes) do
      if hash ~= mine then return true end
    end
  end
  return false
end

-- Incoming ---------------------------------------------------------------------

function Catchup:OnMessage(kind, parts, sender, now)
  if kind == "OD" then return self:OnDigestLine(parts, sender, now) end
  return self:OnAnswerLine(parts, sender, now)
end

-- OD <part>,<parts>,<n>,<MM>,<hash>,... : exactly 3 + 2n fields, codes increasing.
function Catchup:OnDigestLine(parts, sender, now)
  local part = Int(parts[1], 1, MAX_DIGEST_PARTS)
  local total = Int(parts[2], 1, MAX_DIGEST_PARTS)
  local n = Int(parts[3], 1, GROUPS_PER_DIGEST)
  if not part or not total or not n or part > total or table.getn(parts) ~= 3 + 2 * n then
    return Capture:Reject("bad OD", sender)
  end
  local list = {}
  local previous = ""
  local index = 1
  while index <= n do
    local code, hash = parts[2 + 2 * index], parts[3 + 2 * index]
    if not IsCode(code) or not IsHash(hash) or not (code > previous) then return Capture:Reject("bad OD", sender) end
    table.insert(list, { code = code, hash = hash })
    previous = code
    index = index + 1
  end
  self:OnDigest(sender, list, now)
  return true
end

-- Only a peer in the channel for SENIORITY seconds answers, for each map whose
-- hash differs and whose registry is not empty; LOCAL entries answer sooner.
function Catchup:OnDigest(sender, list, now)
  if not self.joinedAt or now - self.joinedAt < SENIORITY then return end
  local groups = self:Groups()
  local budget = LINES_PER_DIGEST
  local index = 1
  while index <= table.getn(list) do
    local code, theirs = list[index].code, list[index].hash
    local ids = groups[code]
    local answered = self.answeredAt[code]
    if ids and not self.pending[code] and not (answered and now - answered < ANSWER_GAP) then
      local mine, entries = self:Hash(ids)
      local count = table.getn(entries)
      if mine ~= theirs and count > 0 then
        local lines = math.min(MAX_LINE_PARTS, Floor((count + ENTRIES_PER_LINE - 1) / ENTRIES_PER_LINE))
        if lines > budget then return end
        budget = budget - lines
        local hasLocal = false
        local entry = 1
        while entry <= count do
          if entries[entry].source == "LOCAL" then hasLocal = true end
          entry = entry + 1
        end
        local delay = hasLocal and LOCAL_DELAY + math.random() * LOCAL_SPREAD
          or PEER_DELAY + math.random() * PEER_SPREAD
        if self.skipped[code] then delay = SKIPPED_DELAY + math.random() * SKIPPED_SPREAD end
        self.pending[code] = { at = now + delay, hash = mine, any = {}, match = {}, anyCount = 0, matchCount = 0 }
      end
    end
    index = index + 1
  end
end

-- OL <MM>,<hash>,<part>,<parts>,<n>,<poi>,<generation>,<owner>,... : exactly
-- 5 + 3n fields. Validated whole before any effect (rule R2).
function Catchup:OnAnswerLine(parts, sender, now)
  local code, hash = parts[1], parts[2]
  local part = Int(parts[3], 1, MAX_LINE_PARTS)
  local total = Int(parts[4], 1, MAX_LINE_PARTS)
  local n = Int(parts[5], 1, ENTRIES_PER_LINE)
  if not IsCode(code) or not IsHash(hash) or not part or not total or not n or part > total
      or table.getn(parts) ~= 5 + 3 * n then
    return Capture:Reject("bad OL", sender)
  end
  local entries = {}
  local index = 1
  while index <= n do
    local base = 3 + 3 * index
    local poi, generation, owner = parts[base], Int(parts[base + 1], 1, 1000000), parts[base + 2]
    if not IsPoi(poi) or not generation or (owner ~= "H" and owner ~= "A") then
      return Capture:Reject("bad OL", sender)
    end
    table.insert(entries, { id = poi, generation = generation, owner = owner })
    index = index + 1
  end

  self:SeeAnswer(code, hash, sender, now)
  if self.round and self.round.mine[code] then
    local hashes = self.round.answers[code] or {}
    local known = 0
    local seen
    for seen in pairs(hashes) do known = known + 1 end
    if hashes[hash] or known < ANSWER_ANY then hashes[hash] = true end
    self.round.answers[code] = hashes
  end
  index = 1
  while index <= table.getn(entries) do
    local entry = entries[index]
    -- Another build of the same level may hold another catalog: skip, count.
    if string.sub(entry.id, 1, 2) == code and Capture:Capturable(entry.id) then
      Capture:NoteHint(entry.id, sender, entry.owner, entry.generation, now)
    else
      self.ignored = self.ignored + 1
    end
    index = index + 1
  end
  return true
end

function Catchup:SeeAnswer(code, hash, sender, now)
  local pending = self.pending[code]
  if not pending then return end
  if not pending.any[sender] then
    pending.any[sender] = true
    pending.anyCount = pending.anyCount + 1
  end
  if hash == pending.hash and not pending.match[sender] then
    pending.match[sender] = true
    pending.matchCount = pending.matchCount + 1
  end
  if pending.matchCount >= ANSWER_MATCHES or pending.anyCount >= ANSWER_ANY then
    -- Dropped, not answered: free to answer, and first, at the next digest.
    self.pending[code] = nil
    self.skipped[code] = true
  end
end

-- Outgoing ---------------------------------------------------------------------

-- The confirmed owners of one map, ten per line, four lines at most.
function Catchup:Lines(code)
  local groups = self:Groups()
  local hash, entries = self:Hash(groups[code])
  local count = math.min(table.getn(entries), ENTRIES_PER_LINE * MAX_LINE_PARTS)
  if count == 0 then return {} end
  local parts = Floor((count + ENTRIES_PER_LINE - 1) / ENTRIES_PER_LINE)
  local lines = {}
  local part = 1
  while part <= parts do
    local first = (part - 1) * ENTRIES_PER_LINE + 1
    local last = math.min(count, part * ENTRIES_PER_LINE)
    local fields = { code, hash, part, parts, last - first + 1 }
    local index = first
    while index <= last do
      local entry = entries[index]
      table.insert(fields, entry.id)
      table.insert(fields, entry.generation)
      table.insert(fields, entry.owner)
      index = index + 1
    end
    table.insert(lines, { body = table.concat(fields, ","), key = "OL:" .. code .. ":" .. part })
    part = part + 1
  end
  return lines
end

local function QueueRoom()
  local queue = PC.SendQueue
  if not queue or type(queue.Pending) ~= "function" then return true end
  return queue:Pending() < QUEUE_ROOM
end

function Catchup:Tick(now)
  if self.digestAt and now >= self.digestAt then
    self.digestAt = nil
    self:SendDigest(now)
  elseif self.sentAt and now - self.sentAt >= RETRY_DELAY then
    if self.retries < MAX_RETRIES and self:StillDiffers() then
      self.retries = self.retries + 1
      self:SendDigest(now)
    else
      self.sentAt = nil
    end
  end

  local code, pending
  for code, pending in pairs(self.pending) do
    if now >= pending.at then
      self.pending[code] = nil
      self.skipped[code] = nil
      self.answeredAt[code] = now
      local lines = self:Lines(code)
      local index = 1
      while index <= table.getn(lines) and table.getn(self.out) < MAX_OUT do
        table.insert(self.out, lines[index])
        index = index + 1
      end
    end
  end

  -- One OL per second, only while the send queue has room: catch-up never
  -- delays a capture state (rule R13); its key makes it dropped first.
  if table.getn(self.out) > 0 and now >= self.nextSendAt and QueueRoom() then
    local line = table.remove(self.out, 1)
    if Capture:Send("OL", line.body, line.key) then self.answers = self.answers + 1 end
    self.nextSendAt = now + SEND_GAP
  end
end

function Catchup:Summary()
  local pending = 0
  local code
  for code in pairs(self.pending) do pending = pending + 1 end
  return "catch-up digests=" .. self.digests .. " answers=" .. self.answers .. " pending=" .. pending
    .. " queued=" .. table.getn(self.out) .. " ignored=" .. self.ignored .. " promoted=" .. Capture.promoted
end
