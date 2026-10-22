PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Companion = {
  active = false,
  state = "WAITING",
  line = nil,
  seenAt = nil,
  startedAt = nil,
  session = nil,
  beat = nil,
  importSeq = nil,
  cloud = nil,
  applied = nil,
  importStatus = nil,
  importReason = nil,
  polls = 0,
  readErrors = 0,
}

PC.Companion = Companion

-- Decision 0059: the companion, started with the game by a launcher mod, hands
-- the launch snapshot to the addon through nampower's <game>\CustomData folder.
-- The addon only reads: a status line every 5 s, and its own import file when
-- the status announces a new one. Without nampower, or without a status line
-- that changes within 60 s, the conquest is off (Capture:CanTalk). Nothing here
-- touches the channel or the shared capture state (R16).
--
-- Status line: PCB1 <session> <beat> <importSeq> <cloud>
--   session   1-32 letters/digits, random per companion start
--   beat      counter raised every 10 s (liveness)
--   importSeq 0 until the launch snapshot is written, then raised per rewrite
--   cloud     ok | offline | pending (informative: offline never locks)
-- Import file: pandaconquest_import_<crc>.txt, <crc> = 8 lowercase hex digits of
-- the CRC-32 of the import's char ("Name@Realm"); content "PCI1 <check>\n" then
-- the decision 0032 canonical form of the import without its check field.
local STATUS_FILE = "pandaconquest_status.txt"
local IMPORT_PREFIX = "pandaconquest_import_"
local POLL_INTERVAL = 5
local STALE_AFTER = 60
local MAX_STATUS = 128
local MAX_IMPORT = 262144
local MAX_COUNTER = 1000000000
local CLOUD = { ok = true, offline = true, pending = true }

local REASONS = {
  NO_NAMPOWER = "nampower missing, launch through the Octo launcher",
  WAITING = "waiting for PandaConquest Companion",
  MISSING = "PandaConquest Companion is not running",
}

local NOTICES = {
  NO_NAMPOWER = {
    "Launch the game with nampower",
    "Start the game from the Octo launcher, with nampower ticked.\n"
      .. "The conquest is paused until then.",
    "nampower required",
  },
  WAITING = {
    "Connecting to PandaConquest Companion",
    "It starts with the game: a few seconds.",
    "Connecting...",
  },
  MISSING = {
    "PandaConquest Companion is not running",
    "Turn it on once:\n"
      .. "- tick PandaConquestLauncher.dll in the Octo launcher's mods\n"
      .. "- or run PandaConquest.Companion.exe (PandaConquest-Companion folder)\n"
      .. "The conquest is paused until it connects.",
    "Companion required",
  },
}

Companion.REASONS = REASONS
Companion.STATUS_FILE = STATUS_FILE
Companion.STALE_AFTER = STALE_AFTER

local function Now()
  if PC.Now then return PC.Now() end
  return 0
end

local function Print(text)
  if PC.Print then PC.Print(text) end
end

local function Record(kind, fields)
  if PC.Record then PC.Record(kind, fields) end
end

-- nampower counts arguments and refuses a trailing nil: exactly one here.
local function Read(name)
  return pcall(function() return ReadCustomFile(name) end)
end

local function Hex8(n)
  local digits = "0123456789abcdef"
  local out = ""
  local i
  for i = 1, 8 do
    local d = n - math.floor(n / 16) * 16
    out = string.sub(digits, d + 1, d + 1) .. out
    n = math.floor(n / 16)
  end
  return out
end

function Companion:Available()
  return type(ReadCustomFile) == "function"
end

-- session, beat, importSeq, cloud of a valid status line, else nil.
function Companion.ParseStatus(text)
  if type(text) ~= "string" or string.len(text) > MAX_STATUS then return nil end
  local _, _, session, beat, seq, cloud = string.find(text, "^PCB1 (%w+) (%d+) (%d+) (%a+)\r?\n?$")
  if not session or string.len(session) > 32 or not CLOUD[cloud] then return nil end
  if string.len(beat) > 10 or string.len(seq) > 10 then return nil end
  beat, seq = tonumber(beat), tonumber(seq)
  if beat > MAX_COUNTER or seq > MAX_COUNTER then return nil end
  return session, beat, seq, cloud
end

-- The bridge file name of a character, or nil without the bit library.
function Companion.ImportFile(identity)
  local Import = PC.Import
  if type(identity) ~= "string" or not Import or not Import.Crc32 then return nil end
  if not bit or type(bit.bxor) ~= "function" then return nil end
  return IMPORT_PREFIX .. Hex8(Import.Crc32(identity)) .. ".txt"
end

-- An import file's text as a raw table for Import:Validate, or nil and a reason.
function Companion.Decode(text)
  if text == nil then return nil, "none" end
  if type(text) ~= "string" or string.len(text) > MAX_IMPORT then return nil, "too large" end
  local _, last, check = string.find(text, "^PCI1 (%d+)\r?\n")
  if not last or string.len(check) > 10 then return nil, "header" end
  local body = string.sub(text, last + 1)
  body = (string.gsub(body, "\r?\n$", ""))
  local raw, reason = PC.Import.ParseCanonical(body)
  if type(raw) ~= "table" then return nil, reason or "not a table" end
  if raw.check ~= nil then return nil, "check in body" end
  raw.check = tonumber(check)
  return raw
end

-- Guard ---------------------------------------------------------------------------

function Companion:Ready()
  return self.state == "OK"
end

function Companion:Reason()
  return REASONS[self.state] or REASONS.WAITING
end

function Companion:IsReason(reason)
  local _, text
  for _, text in pairs(REASONS) do
    if text == reason then return true end
  end
  return false
end

-- title, text (paragraphs split by "\n"), short summary of the current lock.
function Companion:Notice()
  local notice = NOTICES[self.state] or NOTICES.WAITING
  return notice[1], notice[2], notice[3]
end

function Companion:SetState(state)
  local old = self.state
  if state == old then return end
  self.state = state
  Record("COMPANION", { state = state, from = old })
  if state == "NO_NAMPOWER" then
    Print("nampower is not loaded: start the game from the Octo launcher. Conquest paused.")
  elseif state == "MISSING" then
    Print("PandaConquest Companion is not running: tick PandaConquestLauncher.dll in the Octo launcher,"
      .. " or run the companion once. Conquest paused.")
  elseif state == "OK" and old == "MISSING" then
    Print("PandaConquest Companion connected: the conquest is back.")
  end
end

-- Polling ---------------------------------------------------------------------------

function Companion:LoadImport()
  if not self.importSeq or self.importSeq < 1 or not self.session then return end
  local key = self.session .. ":" .. self.importSeq
  if key == self.applied then return end
  local Import = PC.Import
  local me = PC.Progress and PC.Progress.Me and PC.Progress:Me()
  if not Import or not Import.Validate or not Import.Merge or not me then return end
  local name = Companion.ImportFile(me)
  if not name then
    self.applied = key
    self.importStatus, self.importReason = "REJECTED", "no bit library"
    return
  end
  local ok, text = Read(name)
  if not ok then
    -- Most likely read during the companion's rename: retried at the next poll.
    self.readErrors = self.readErrors + 1
    return
  end
  self.applied = key
  local data, reason = Companion.Decode(text)
  if data then data, reason = Import:Validate(data) end
  if data then
    Import:Merge(data)
    self.importStatus, self.importReason = "OK", nil
    return
  end
  self.importStatus = (reason == "none") and "NONE" or "REJECTED"
  self.importReason = reason
  Record("IMPORT", { status = self.importStatus, source = "bridge", reason = reason })
  if reason == "future schema" or reason == "level" then
    Print("Companion data needs another addon version; it is ignored until you update.")
  end
end

function Companion:Poll(now)
  now = now or Now()
  self.polls = self.polls + 1
  if not self.startedAt then self.startedAt = now end
  if not self:Available() then
    self:SetState("NO_NAMPOWER")
    return
  end
  local ok, text = Read(STATUS_FILE)
  if not ok then
    self.readErrors = self.readErrors + 1
  elseif text ~= nil then
    local session, beat, seq, cloud = Companion.ParseStatus(text)
    if session then
      local line = session .. " " .. beat .. " " .. seq .. " " .. cloud
      -- Only a change proves a live companion: a file left by an earlier
      -- session never does.
      if self.line ~= nil and line ~= self.line then self.seenAt = now end
      self.line = line
      self.session, self.beat, self.importSeq, self.cloud = session, beat, seq, cloud
    end
  end
  if self.seenAt and now - self.seenAt < STALE_AFTER then
    self:SetState("OK")
    self:LoadImport()
  elseif not self.seenAt and now - self.startedAt < STALE_AFTER then
    self:SetState("WAITING")
  else
    self:SetState("MISSING")
  end
end

function Companion:PrintStatus()
  local now = Now()
  Print("companion " .. self.state .. (self:Ready() and "" or (" (" .. self:Reason() .. ")"))
    .. " nampower=" .. tostring(self:Available())
    .. " session=" .. tostring(self.session or "none")
    .. " lastChange=" .. (self.seenAt and (string.format("%.0f", now - self.seenAt) .. "s ago") or "never")
    .. " cloud=" .. tostring(self.cloud or "?"))
  Print("companion import=" .. tostring(self.importStatus or "none")
    .. (self.importReason and (" (" .. self.importReason .. ")") or "")
    .. " importSeq=" .. tostring(self.importSeq or "?")
    .. " polls=" .. self.polls .. " readErrors=" .. self.readErrors)
end

-- Ticker: polls start once the player is in the world.
local elapsed = POLL_INTERVAL
local function OnUpdate()
  if not Companion.active then return end
  elapsed = elapsed + (arg1 or 0)
  if elapsed < POLL_INTERVAL then return end
  elapsed = 0
  Companion:Poll()
end

local function OnEnteringWorld()
  Companion.active = true
end

if type(CreateFrame) == "function" then
  local ok, frame = pcall(CreateFrame, "Frame", nil, UIParent)
  if ok and frame and frame.SetScript then frame:SetScript("OnUpdate", OnUpdate) end
end
if PC.RegisterEvent then
  PC.RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)
end
