local PC = PandaConquest

PC.Storage = PC.Storage or {}
local Storage = PC.Storage

local SCHEMA_VERSION = 1
local MAX_LOG = 200
local MAX_MESSAGES = 100
local MAX_RESULTS = 100
local MAX_ERRORS = 50
local pendingLogs = {}
local pendingMessages = {}
local pendingResults = {}
local pendingErrors = {}

local function AppendBounded(list, value, maximum)
  table.insert(list, value)
  while table.getn(list) > maximum do
    table.remove(list, 1)
  end
end

local function NewSendStats()
  return {
    attempted = 0,
    acceptedCalls = 0,
    failedCalls = 0,
    byTransport = {},
  }
end

local function NewReceiveStats()
  return {
    events = 0,
    prefixMatches = 0,
    validMessages = 0,
    malformed = 0,
    oversized = 0,
    missingSequences = 0,
    duplicates = 0,
    outOfOrder = 0,
    echoes = 0,
    pongs = 0,
    rttCount = 0,
    rttTotalMs = 0,
    rttMinMs = nil,
    rttMaxMs = nil,
    byTransport = {},
  }
end

local function EnsureTable(parent, key)
  if type(parent[key]) ~= "table" then parent[key] = {} end
  return parent[key]
end

local function MakeSessionId()
  local value = math.floor((PC.Now() * 1000) + PC.Epoch())
  local playerName = UnitName and UnitName("player") or "unknown"
  local i
  for i = 1, string.len(playerName or "") do
    value = math.mod((value * 33) + string.byte(playerName, i), 65536)
  end
  return string.format("%04X", math.mod(value, 65536))
end

function Storage:Initialize()
  if self.initialized then return not self.readOnly end
  self.initialized = true

  if type(PandaConquestDB) ~= "table" then PandaConquestDB = {} end
  local db = PandaConquestDB
  local existingVersion = tonumber(db.schemaVersion) or 0

  if existingVersion > SCHEMA_VERSION then
    self.readOnly = true
    self.futureVersion = existingVersion
    self.db = db
    PC.Print("SavedVariables schema " .. existingVersion .. " is newer than this addon; diagnostics are read-only.")
    return false
  end

  db.schemaVersion = SCHEMA_VERSION
  -- The build that last wrote this file, read by the companion (decision 0031).
  db.addonVersion = PC.version
  db.channelLevel = PC.channelLevel
  db.sequence = tonumber(db.sequence) or 0
  db.session = {
    id = MakeSessionId(),
    startedAt = PC.Epoch(),
    addonVersion = PC.version,
    channelLevel = PC.channelLevel,
  }
  if type(db.sendStats) ~= "table" then db.sendStats = NewSendStats() end
  if type(db.receiveStats) ~= "table" then db.receiveStats = NewReceiveStats() end
  db.sendStats.attempted = tonumber(db.sendStats.attempted) or 0
  db.sendStats.acceptedCalls = tonumber(db.sendStats.acceptedCalls) or 0
  db.sendStats.failedCalls = tonumber(db.sendStats.failedCalls) or 0
  EnsureTable(db.sendStats, "byTransport")
  db.receiveStats.events = tonumber(db.receiveStats.events) or 0
  db.receiveStats.prefixMatches = tonumber(db.receiveStats.prefixMatches) or 0
  db.receiveStats.validMessages = tonumber(db.receiveStats.validMessages) or 0
  db.receiveStats.malformed = tonumber(db.receiveStats.malformed) or 0
  db.receiveStats.oversized = tonumber(db.receiveStats.oversized) or 0
  db.receiveStats.missingSequences = tonumber(db.receiveStats.missingSequences) or 0
  db.receiveStats.duplicates = tonumber(db.receiveStats.duplicates) or 0
  db.receiveStats.outOfOrder = tonumber(db.receiveStats.outOfOrder) or 0
  db.receiveStats.echoes = tonumber(db.receiveStats.echoes) or 0
  db.receiveStats.pongs = tonumber(db.receiveStats.pongs) or 0
  db.receiveStats.rttCount = tonumber(db.receiveStats.rttCount) or 0
  db.receiveStats.rttTotalMs = tonumber(db.receiveStats.rttTotalMs) or 0
  db.receiveStats.rttMinMs = tonumber(db.receiveStats.rttMinMs)
  db.receiveStats.rttMaxMs = tonumber(db.receiveStats.rttMaxMs)
  EnsureTable(db.receiveStats, "byTransport")
  EnsureTable(db, "log")
  EnsureTable(db, "lastMessages")
  EnsureTable(db, "lastResults")
  EnsureTable(db, "errors")
  EnsureTable(db, "settings")

  while table.getn(db.log) > MAX_LOG do table.remove(db.log, 1) end
  while table.getn(db.lastMessages) > MAX_MESSAGES do table.remove(db.lastMessages, 1) end
  while table.getn(db.lastResults) > MAX_RESULTS do table.remove(db.lastResults, 1) end
  while table.getn(db.errors) > MAX_ERRORS do table.remove(db.errors, 1) end

  self.db = db
  self:AddLog("SESSION_START", { session = db.session.id, version = PC.version })
  PC.FlushPendingLog()

  local queuedLogs = pendingLogs
  local queuedMessages = pendingMessages
  local queuedResults = pendingResults
  local queuedErrors = pendingErrors
  pendingLogs, pendingMessages, pendingResults, pendingErrors = {}, {}, {}, {}

  local i
  for i = 1, table.getn(queuedLogs) do
    self:AddLog(queuedLogs[i].kind, queuedLogs[i].fields)
  end
  for i = 1, table.getn(queuedMessages) do
    self:AddMessage(queuedMessages[i])
  end
  for i = 1, table.getn(queuedResults) do
    self:AddResult(queuedResults[i])
  end
  for i = 1, table.getn(queuedErrors) do
    self:AddError(queuedErrors[i].scope, queuedErrors[i].error)
  end
  return true
end

function Storage:GetDB()
  return self.db
end

function Storage:AddLog(kind, fields)
  local db = self:GetDB()
  if not self.initialized then
    AppendBounded(pendingLogs, { kind = kind, fields = fields }, MAX_LOG)
    return
  end
  if not db or self.readOnly then return end
  AppendBounded(db.log, {
    at = PC.Epoch(),
    elapsed = PC.Now(),
    kind = tostring(kind or "UNKNOWN"),
    fields = fields or {},
  }, MAX_LOG)
end

function Storage:AddMessage(message)
  local db = self:GetDB()
  if not self.initialized then
    AppendBounded(pendingMessages, message, MAX_MESSAGES)
    return
  end
  if not db or self.readOnly then return end
  AppendBounded(db.lastMessages, message, MAX_MESSAGES)
end

function Storage:AddResult(result)
  local db = self:GetDB()
  if not self.initialized then
    result.at = result.at or PC.Epoch()
    result.elapsed = result.elapsed or PC.Now()
    AppendBounded(pendingResults, result, MAX_RESULTS)
    return
  end
  if not db or self.readOnly then return end
  result.at = result.at or PC.Epoch()
  result.elapsed = result.elapsed or PC.Now()
  AppendBounded(db.lastResults, result, MAX_RESULTS)
end

function Storage:AddError(scope, errorText)
  local db = self:GetDB()
  if not self.initialized then
    AppendBounded(pendingErrors, { scope = scope, error = errorText }, MAX_ERRORS)
    return
  end
  if not db or self.readOnly then return end
  local entry = {
    at = PC.Epoch(),
    elapsed = PC.Now(),
    scope = PC.Sanitize(scope, 100),
    error = PC.Sanitize(errorText, 240),
  }
  AppendBounded(db.errors, entry, MAX_ERRORS)
  self:AddLog("ERROR", entry)
end

function Storage:NextSequence()
  local db = self:GetDB()
  if not db or self.readOnly then return nil end
  db.sequence = db.sequence + 1
  return db.sequence
end

function Storage:IncrementSend(transport, field)
  local db = self:GetDB()
  if not db or self.readOnly then return end
  local stats = db.sendStats
  stats[field] = (tonumber(stats[field]) or 0) + 1
  if field == "attempted" then
    stats.byTransport[transport] = (tonumber(stats.byTransport[transport]) or 0) + 1
  end
end

function Storage:IncrementReceive(field, transport)
  local db = self:GetDB()
  if not db or self.readOnly then return end
  local stats = db.receiveStats
  stats[field] = (tonumber(stats[field]) or 0) + 1
  if transport then
    stats.byTransport[transport] = (tonumber(stats.byTransport[transport]) or 0) + 1
  end
end

function Storage:AddReceiveAmount(field, amount)
  local db = self:GetDB()
  if not db or self.readOnly then return end
  db.receiveStats[field] = (tonumber(db.receiveStats[field]) or 0) + (tonumber(amount) or 0)
end

function Storage:RecordRTT(milliseconds)
  local db = self:GetDB()
  if not db or self.readOnly then return end
  local stats = db.receiveStats
  stats.rttCount = (tonumber(stats.rttCount) or 0) + 1
  stats.rttTotalMs = (tonumber(stats.rttTotalMs) or 0) + milliseconds
  if not stats.rttMinMs or milliseconds < stats.rttMinMs then stats.rttMinMs = milliseconds end
  if not stats.rttMaxMs or milliseconds > stats.rttMaxMs then stats.rttMaxMs = milliseconds end
end

function Storage:ClearDiagnostics()
  local db = self:GetDB()
  if not db or self.readOnly then return false end
  db.sendStats = NewSendStats()
  db.receiveStats = NewReceiveStats()
  db.log = {}
  db.lastMessages = {}
  db.lastResults = {}
  db.errors = {}
  self:AddLog("DIAGNOSTICS_CLEARED", { session = db.session.id })
  return true
end

local function OnAddonLoaded(eventName, addonName)
  if string.lower(tostring(addonName or "")) == string.lower(PC.name) then
    Storage:Initialize()
  end
end

local loadRegistered, loadRegistrationError = PC.RegisterEvent("ADDON_LOADED", OnAddonLoaded)
if not loadRegistered then
  PC.RecordError("RegisterEvent(ADDON_LOADED)", loadRegistrationError)
end
