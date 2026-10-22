local PC = PandaConquest
local Storage = PC.Storage

PC.P2PTest = PC.P2PTest or {}
local P2P = PC.P2PTest

local PREFIX = "PC"
-- 1.12 caps prefix, separator and message at 255 bytes and accepts only
-- PARTY, RAID, GUILD and BATTLEGROUND (comms.addon_message_255_bytes).
local ADDON_MESSAGE_MAX_BYTES = 255
local MAX_MESSAGE_BYTES = ADDON_MESSAGE_MAX_BYTES - string.len(PREFIX) - 1
local MAX_DATA_BYTES = MAX_MESSAGE_BYTES
local MAX_BURST_COUNT = 50
local MAX_BURST_SECONDS = 10
local MAX_CAPTURED_ARGS = 9
local ALLOWED_TYPES = { HELLO = true, PING = true, PONG = true, DATA = true, BURST = true }
local TRANSPORTS = { PARTY = true, RAID = true, GUILD = true, BATTLEGROUND = true }
local EVENT_TRANSPORTS = {
  PARTY = true,
  RAID = true,
  GUILD = true,
  OFFICER = true,
  BATTLEGROUND = true,
  CHANNEL = true,
  WHISPER = true,
  SAY = true,
  YELL = true,
  EMOTE = true,
}
local SAFE_AUTO_REPLY = { PARTY = true, RAID = true, GUILD = true }
local DEFAULT_CUSTOM_CHANNEL = "PandaConquest"
-- Visible channel line (decisions 0027, 0029):
-- PC<level>:<addon version>:<id>:<session>:<seq base 36>:<body>. The addon
-- version always follows "PC<n>:", so a build reads it even on another level.
local CHANNEL_LEVEL = PC.channelLevel
local CHANNEL_WIRE_PREFIX = "PC" .. tostring(CHANNEL_LEVEL) .. ":" .. tostring(PC.version) .. ":"
-- One short id per event, as Overlord does. HI and D are diagnostics, V the
-- version announce (core/version.lua); the capture ids are routed to
-- PC.Capture:OnMessage (docs/p2p-protocol.md).
local CHANNEL_ID_BY_TYPE = { HELLO = "HI", DATA = "D" }
local CHANNEL_TYPE_BY_ID = { HI = "HELLO", D = "DATA", V = "VERSION" }
local CAPTURE_IDS = {
  P = true, S = true, Q = true, K = true, H = true, HQ = true, OD = true, OL = true, X = true,
  G = true, GD = true, GQ = true, SC = true, SQ = true, SL = true, AC = true, AQ = true, AL = true, AR = true,
}
local CUSTOM_CHANNEL_MAX_BYTES = 255
local CUSTOM_CHANNEL_TRANSPORT = "CHANNEL_CHAT"
-- Octo's own UI whispers addon data through the server: a GUILD addon message
-- whose prefix is TW_CHAT_MSG_WHISPER<Name> reaches only Name, which receives
-- arg1 = TW_CHAT_MSG_WHISPER and arg4 = sender (FrameXML/Turtle_InspectTalentsUI).
local TW_WHISPER_PREFIX = "TW_CHAT_MSG_WHISPER"
local TW_WHISPER_TRANSPORT = "TW_WHISPER"
local AUTO_JOIN_INITIAL_DELAY_SECONDS = 5
local AUTO_JOIN_RETRY_SECONDS = 3
local AUTO_JOIN_MAX_ATTEMPTS = 4
local AUTO_JOIN_MONITOR_SECONDS = 60
local PREPARED_CHAT_DELAY_SECONDS = 0.05
local SIZE_SWEEP_BASELINE_BYTES = { 32, 64, 96, 128, 160, 192, 224, 240, MAX_MESSAGE_BYTES, 32 }
local SIZE_SWEEP_BOUNDARY_BYTES = {
  MAX_MESSAGE_BYTES - 8, MAX_MESSAGE_BYTES - 4, MAX_MESSAGE_BYTES - 2, MAX_MESSAGE_BYTES - 1, MAX_MESSAGE_BYTES, 32,
}

local pendingPings = {}
local pendingPingOrder = {}
local seen = {}
local seenOrder = {}
local lastSequence = {}
local burstState
local sizeSweepState
local autoJoinState
local preparedChatState
local burstFrame = CreateFrame("Frame", "PandaConquestP2PBurstFrame", UIParent)
local sizeSweepFrame = CreateFrame("Frame", "PandaConquestP2PSizeSweepFrame", UIParent)
local channelJoinFrame = CreateFrame("Frame", "PandaConquestP2PChannelJoinFrame", UIParent)
local preparedChatFrame = CreateFrame("Frame", "PandaConquestP2PPreparedChatFrame", UIParent)

local function Upper(value)
  return string.upper(tostring(value or ""))
end

local function IsPrintableASCII(value)
  if type(value) ~= "string" then return false end
  local i
  for i = 1, string.len(value) do
    local byte = string.byte(value, i)
    if byte < 32 or byte > 126 then return false end
  end
  return true
end

local function TakeWord(text)
  local source = tostring(text or "")
  local _, _, word, rest = string.find(source, "^%s*(%S+)%s*(.*)$")
  return word, rest or ""
end

local function AddSeen(key)
  if seen[key] then return false end
  seen[key] = true
  table.insert(seenOrder, key)
  while table.getn(seenOrder) > 200 do
    local old = table.remove(seenOrder, 1)
    seen[old] = nil
  end
  return true
end

local function MakeFill(length)
  local output = ""
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local i
  for i = 1, length do
    local index = math.mod(i - 1, string.len(alphabet)) + 1
    output = output .. string.sub(alphabet, index, index)
  end
  return output
end

local function ValidateTransport(transport)
  local normalized = Upper(transport)
  if not TRANSPORTS[normalized] then
    return nil, "transport must be PARTY, RAID, GUILD, or BATTLEGROUND"
  end
  return normalized
end

local function IsExactSizeProbe(messageType, data, payloadBytes)
  if messageType ~= "DATA" or type(data) ~= "string" then return false end
  local _, _, requested = string.find(data, "^SIZE=(%d+);BODY=")
  if requested then return tonumber(requested) == payloadBytes end
  return false
end

-- OctoWoW rejects | in any chat-system message ("Invalid escape code in chat
-- message", comms.chat_message_rejects_pipe_escape): fields are separated by :.
local function Wire(messageType, session, sequence, data)
  return "V1:" .. messageType .. ":" .. session .. ":" .. tostring(sequence) .. ":" .. (data or "")
end

local function IsWire(value)
  local head = string.sub(value, 1, 3)
  return head == "V1:" or head == "V1|"
end

function P2P.Parse(message)
  if type(message) ~= "string" then return nil, "payload is not a string" end
  if string.len(message) > MAX_MESSAGE_BYTES then return nil, "payload exceeds diagnostic safety limit" end

  local _, _, messageType, session, sequenceText, data = string.find(message, "^V1[:|]([A-Z]+)[:|]([0-9A-F]+)[:|](%d+)[:|](.*)$")
  if not messageType then return nil, "envelope does not match V1" end
  if not ALLOWED_TYPES[messageType] then return nil, "unknown message type" end
  if string.len(session) < 4 or string.len(session) > 12 then return nil, "invalid session id" end
  if string.len(data) > MAX_DATA_BYTES and not IsExactSizeProbe(messageType, data, string.len(message)) then
    return nil, "data exceeds diagnostic safety limit"
  end
  if not IsPrintableASCII(data) then return nil, "data is not printable ASCII" end

  local sequence = tonumber(sequenceText)
  if not sequence or sequence < 0 or sequence > 2147483647 then return nil, "invalid sequence" end

  return {
    version = "V1",
    messageType = messageType,
    session = session,
    sequence = sequence,
    data = data,
  }
end

local BASE36 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

-- Channel sequences travel in base 36: 2147483647 still fits in 6 characters.
local function Base36(value)
  value = math.floor(tonumber(value) or 0)
  if value <= 0 then return "0" end
  local output = ""
  while value > 0 do
    local digit = value - math.floor(value / 36) * 36
    output = string.sub(BASE36, digit + 1, digit + 1) .. output
    value = math.floor(value / 36)
  end
  return output
end

local function ChannelWire(id, session, sequence, body)
  return CHANNEL_WIRE_PREFIX .. id .. ":" .. session .. ":" .. Base36(sequence) .. ":" .. (body or "")
end
P2P.ChannelWire = ChannelWire

local function ChannelMessageType(id)
  return CHANNEL_TYPE_BY_ID[id] or id
end

-- Returns parsed, error, meta; nil without error: not PandaConquest traffic.
-- meta = { level, version } whenever the sender's addon version is readable,
-- even on a line of another level that is not applied.
function P2P.ParseChannel(text)
  if type(text) ~= "string" then return nil end
  local _, _, levelText, rest = string.find(text, "^PC(%d+):(.*)$")
  if not levelText then return nil end
  local level = string.len(levelText) <= 3 and tonumber(levelText) or nil
  local _, _, build, tail = string.find(rest, "^([^:]*):(.*)$")
  local meta
  if level and build and PC.Version and PC.Version.Valid(build) then
    meta = { level = level, version = build }
  end
  if level ~= CHANNEL_LEVEL then return nil, "unsupported channel protocol PC" .. levelText, meta end
  if string.len(text) > CUSTOM_CHANNEL_MAX_BYTES then return nil, "channel message exceeds 255 bytes", meta end
  if not meta then return nil, "invalid addon version" end

  local _, _, id, session, sequenceText, body = string.find(tail, "^([A-Z][A-Z0-9]*):([0-9A-F]+):([0-9A-Z]+):(.*)$")
  if not id then return nil, "envelope does not match PC" .. tostring(CHANNEL_LEVEL), meta end
  if not CHANNEL_TYPE_BY_ID[id] and not CAPTURE_IDS[id] then return nil, "unknown channel event id", meta end
  if string.len(session) < 4 or string.len(session) > 12 then return nil, "invalid session id", meta end
  local sequence = string.len(sequenceText) <= 6 and tonumber(sequenceText, 36)
  if not sequence or sequence > 2147483647 then return nil, "invalid sequence", meta end
  if not IsPrintableASCII(body) then return nil, "data is not printable ASCII", meta end

  return {
    version = build,
    level = level,
    id = id,
    messageType = ChannelMessageType(id),
    session = session,
    sequence = sequence,
    data = body,
  }, nil, meta
end

local function CallStatus(accepted, skipped)
  if accepted then return "CALL_ACCEPTED" end
  if skipped then return "SKIPPED" end
  return "CALL_FAILED"
end

local function RecordSendResult(transport, messageType, sequence, payload, accepted, errorText, skipped)
  Storage:AddResult({
    kind = "SEND",
    status = CallStatus(accepted, skipped),
    transport = transport,
    messageType = messageType,
    sequence = sequence,
    bytes = string.len(payload),
    error = errorText and PC.Sanitize(errorText, 200) or nil,
  })
  PC.Record("SEND", {
    status = CallStatus(accepted, skipped),
    transport = transport,
    messageType = messageType,
    sequence = sequence,
    bytes = string.len(payload),
  })
end

-- Every client send goes through PC.SendQueue (decision 0023); the counters
-- and results are written when the call is really made or skipped.
local gateMissingReported

-- A file newly added to the TOC is only loaded by a client restart, not /reload.
-- priority: an event message, dropped last when the queue is full (risk B9).
local function Gate(fn, n, a1, a2, a3, a4, done, key, priority)
  if not PC.SendQueue then
    if not gateMissingReported then
      gateMissingReported = true
      PC.Print("send gate missing (core/send_queue.lua not loaded): restart the WoW client; /reload is not enough.")
    end
    return false, "send gate not loaded: restart the client"
  end
  return PC.SendQueue:Submit({ fn = fn, n = n, a1 = a1, a2 = a2, a3 = a3, a4 = a4, done = done, key = key,
    priority = priority })
end

local function SendRecorder(transport, messageType, sequence, payload, errorScope, extra)
  return function(ok, result, skipped)
    if ok then
      Storage:IncrementSend(transport, "acceptedCalls")
    elseif skipped then
      Storage:IncrementSend(transport, "skippedCalls")
    else
      Storage:IncrementSend(transport, "failedCalls")
      PC.RecordError(errorScope, result)
    end
    RecordSendResult(transport, messageType, sequence, payload, ok, result, skipped)
    if extra then extra(ok, result, skipped) end
  end
end

function P2P.SendEnvelope(messageType, transport, data, reservedSequence)
  local normalized, transportError = ValidateTransport(transport)
  if not normalized then return false, transportError end
  if not ALLOWED_TYPES[messageType] then return false, "invalid message type" end
  if not IsPrintableASCII(data or "") then return false, "data must contain printable ASCII only" end
  if string.find(data or "", "|", 1, true) then return false, "data cannot contain | (rejected by the client)" end

  local db = Storage:GetDB()
  if not db then return false, "SavedVariables are unavailable" end
  local sequence = reservedSequence or Storage:NextSequence()
  if not sequence then return false, "sequence is unavailable" end

  local payload = Wire(messageType, db.session.id, sequence, data)
  if string.len(payload) > MAX_MESSAGE_BYTES then return false, "complete message is too large" end
  if string.len(data or "") > MAX_DATA_BYTES and not IsExactSizeProbe(messageType, data, string.len(payload)) then
    return false, "data is too large"
  end

  Storage:IncrementSend(normalized, "attempted")
  if type(SendAddonMessage) ~= "function" then
    Storage:IncrementSend(normalized, "failedCalls")
    RecordSendResult(normalized, messageType, sequence, payload, false, "SendAddonMessage is unavailable")
    return false, "SendAddonMessage is unavailable"
  end

  local ok, err = Gate(SendAddonMessage, 3, PREFIX, payload, normalized, nil,
    SendRecorder(normalized, messageType, sequence, payload, "SendAddonMessage"))
  if not ok then return false, tostring(err) end
  return true, nil, sequence, payload
end

-- Experimental hidden whisper to one player; see TW_WHISPER_PREFIX.
local function SendTwWhisper(target, messageType, data, reservedSequence)
  if type(target) ~= "string" or target == "" or string.len(target) > 24 or string.find(target, "[%c<>|]") then
    return false, "target must be a player name"
  end
  if not ALLOWED_TYPES[messageType] then return false, "invalid message type" end
  if not IsPrintableASCII(data or "") then return false, "data must contain printable ASCII only" end
  if string.find(data or "", "|", 1, true) then return false, "data cannot contain | on the TW whisper transport" end
  if type(SendAddonMessage) ~= "function" then return false, "SendAddonMessage is unavailable" end

  local db = Storage:GetDB()
  if not db then return false, "SavedVariables are unavailable" end
  local sequence = reservedSequence or Storage:NextSequence()
  if not sequence then return false, "sequence is unavailable" end

  local prefix = TW_WHISPER_PREFIX .. "<" .. target .. ">"
  local payload = Wire(messageType, db.session.id, sequence, data)
  if string.len(prefix) + 1 + string.len(payload) > ADDON_MESSAGE_MAX_BYTES then
    return false, "message exceeds the 255-byte addon message limit"
  end

  Storage:IncrementSend(TW_WHISPER_TRANSPORT, "attempted")
  local ok, err = Gate(SendAddonMessage, 3, prefix, payload, "GUILD", nil,
    SendRecorder(TW_WHISPER_TRANSPORT, messageType, sequence, payload, "TW whisper"))
  if not ok then return false, tostring(err) end
  return true, nil, sequence, payload
end

local function PackArguments(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  local values = {}
  values[1], values[2], values[3], values[4], values[5] = a1, a2, a3, a4, a5
  values[6], values[7], values[8], values[9], values[10] = a6, a7, a8, a9, a10
  values[11], values[12], values[13] = a11, a12, a13
  values[14], values[15], values[16] = a14, a15, a16

  local count = 0
  local i
  for i = 1, MAX_CAPTURED_ARGS do
    if values[i] ~= nil then count = i end
  end

  local descriptors = {}
  for i = 1, count do
    local value = values[i]
    local valueType = type(value)
    local representation, truncated, originalLength = PC.Sanitize(value, 160)
    descriptors[i] = {
      index = i,
      valueType = valueType,
      value = representation,
      truncated = truncated or nil,
      stringBytes = valueType == "string" and originalLength or nil,
    }
  end
  return values, descriptors, count
end

local function FindTransport(values, count)
  local i
  for i = 1, count do
    if type(values[i]) == "string" then
      local candidate = Upper(values[i])
      if EVENT_TRANSPORTS[candidate] then return candidate, i end
    end
  end
  return nil
end

local function FindCandidateSender(values, count, prefixIndex, payloadIndex, transportIndex)
  local i
  for i = 1, count do
    if i ~= prefixIndex and i ~= payloadIndex and i ~= transportIndex and type(values[i]) == "string" and values[i] ~= "" then
      return PC.Sanitize(values[i], 100), i
    end
  end
  return nil
end

local function RecordMalformed(rawEntry, reason, oversized)
  if oversized then
    Storage:IncrementReceive("oversized")
  else
    Storage:IncrementReceive("malformed")
  end
  rawEntry.parseStatus = oversized and "OVERSIZED" or "MALFORMED"
  rawEntry.parseError = PC.Sanitize(reason, 160)
  Storage:AddMessage(rawEntry)
  PC.Record("RECEIVE_REJECTED", { reason = rawEntry.parseError, argCount = rawEntry.argCount })
end

local function ValidateMeasuredSize(parsed, rawPayload)
  local _, _, requested = string.find(parsed.data, "^SIZE=(%d+);BODY=")
  if not requested then return nil end
  local expected = tonumber(requested)
  local actual = string.len(rawPayload)
  return expected, actual, expected == actual
end

local function HandleParsed(parsed, rawPayload, transport, rawEntry)
  local db = Storage:GetDB()
  local key = parsed.session .. ":" .. tostring(parsed.sequence) .. ":" .. parsed.messageType
  local fresh = AddSeen(key)
  if not fresh then Storage:IncrementReceive("duplicates") end

  local previous = lastSequence[parsed.session]
  if previous and parsed.sequence < previous then Storage:IncrementReceive("outOfOrder") end
  if previous and parsed.sequence > previous + 1 then
    Storage:AddReceiveAmount("missingSequences", parsed.sequence - previous - 1)
  end
  if not previous or parsed.sequence > previous then lastSequence[parsed.session] = parsed.sequence end

  if db and parsed.session == db.session.id then Storage:IncrementReceive("echoes") end

  local expectedSize, actualSize, exactSize = ValidateMeasuredSize(parsed, rawPayload)
  rawEntry.parseStatus = "VALID"
  rawEntry.messageType = parsed.messageType
  rawEntry.session = parsed.session
  rawEntry.sequence = parsed.sequence
  rawEntry.transportCandidate = transport
  rawEntry.duplicate = not fresh
  rawEntry.expectedBytes = expectedSize
  rawEntry.actualBytes = actualSize or string.len(rawPayload)
  rawEntry.exactSize = exactSize
  Storage:AddMessage(rawEntry)
  Storage:IncrementReceive("validMessages", transport)

  if expectedSize then
    Storage:AddResult({
      kind = "SIZE_RECEIVE",
      status = exactSize and "EXACT" or "MISMATCH",
      messageType = parsed.messageType,
      transport = transport,
      session = parsed.session,
      sequence = parsed.sequence,
      requestedBytes = expectedSize,
      receivedBytes = actualSize,
    })
  end

  local whisperBack = transport == TW_WHISPER_TRANSPORT and rawEntry.senderCandidate
  if parsed.messageType == "PING" and (SAFE_AUTO_REPLY[transport] or whisperBack)
      and db and parsed.session ~= db.session.id then
    local ok, err
    if whisperBack then
      ok, err = SendTwWhisper(rawEntry.senderCandidate, "PONG", parsed.data)
    else
      ok, err = P2P.SendEnvelope("PONG", transport, parsed.data)
    end
    Storage:AddResult({
      kind = "AUTO_PONG",
      status = ok and "CALL_ACCEPTED" or "CALL_FAILED",
      transport = transport,
      requestSession = parsed.session,
      requestSequence = parsed.sequence,
      error = err,
    })
  elseif parsed.messageType == "PONG" then
    local pending = pendingPings[parsed.data]
    if pending then
      local rtt = math.floor(((PC.Now() - pending.sentAt) * 1000) + 0.5)
      pendingPings[parsed.data] = nil
      Storage:IncrementReceive("pongs")
      Storage:RecordRTT(rtt)
      Storage:AddResult({
        kind = "PING_RTT",
        status = "ROUND_TRIP_OBSERVED",
        transport = transport,
        token = parsed.data,
        rttMs = rtt,
        responderSession = parsed.session,
      })
      PC.Print("PONG received on " .. tostring(transport or "unknown") .. ": " .. rtt .. " ms")
    end
  end
end

local function OnAddonMessage(eventName, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  Storage:IncrementReceive("events")
  -- 1.12 passes the prefix as arg1: skip other addons' traffic, and Octo's own
  -- TW_ whispers, before building any capture.
  local twWhisper = a1 == TW_WHISPER_PREFIX and type(a2) == "string" and IsWire(a2)
  if a1 ~= PREFIX and not twWhisper then return end
  local values, descriptors, count = PackArguments(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  local rawEntry = {
    at = PC.Epoch(),
    elapsed = PC.Now(),
    event = eventName,
    handlerShape = PC.handlerShape,
    argCount = count,
    args = descriptors,
  }

  local prefixIndex
  local payloadIndex
  local payload
  local i
  for i = 1, count do
    if values[i] == PREFIX or values[i] == TW_WHISPER_PREFIX then prefixIndex = i end
    if type(values[i]) == "string" and IsWire(values[i]) then
      payloadIndex = i
      payload = values[i]
    end
  end

  local transport, transportIndex = FindTransport(values, count)
  local senderCandidate, senderIndex = FindCandidateSender(values, count, prefixIndex, payloadIndex, transportIndex)
  if twWhisper then
    transport = TW_WHISPER_TRANSPORT
    if type(a4) == "string" and a4 ~= "" then senderCandidate, senderIndex = PC.Sanitize(a4, 100), 4 end
  end
  rawEntry.prefixArgIndex = prefixIndex
  rawEntry.payloadArgIndex = payloadIndex
  rawEntry.transportArgIndex = transportIndex
  rawEntry.senderCandidate = senderCandidate
  rawEntry.senderCandidateArgIndex = senderIndex

  if not prefixIndex then
    rawEntry.parseStatus = "OTHER_PREFIX_OR_UNKNOWN_SIGNATURE"
    Storage:AddMessage(rawEntry)
    PC.Record("CHAT_MSG_ADDON", { argCount = count, prefixMatch = false })
    return
  end

  Storage:IncrementReceive("prefixMatches")
  if not payload then
    RecordMalformed(rawEntry, "PC prefix found but no V1 payload argument was identified", false)
    return
  end

  local parsed, parseError = P2P.Parse(payload)
  if not parsed then
    RecordMalformed(rawEntry, parseError, string.len(payload) > MAX_MESSAGE_BYTES)
    return
  end

  HandleParsed(parsed, payload, transport, rawEntry)
  PC.Record("CHAT_MSG_ADDON", {
    argCount = count,
    prefixMatch = true,
    messageType = parsed.messageType,
    transportCandidate = transport,
    senderCandidate = senderCandidate,
  })
end

local registered, registrationError = PC.RegisterEvent("CHAT_MSG_ADDON", OnAddonMessage)
P2P.registration = {
  attempted = true,
  accepted = registered and true or false,
  error = registrationError and PC.Sanitize(registrationError, 200) or nil,
}
Storage:AddResult({
  kind = "EVENT_REGISTRATION",
  event = "CHAT_MSG_ADDON",
  status = registered and "REGISTER_ACCEPTED" or "REGISTER_FAILED",
  error = P2P.registration.error,
})

local function SendHello(transport)
  return P2P.SendEnvelope("HELLO", transport, PC.version)
end

local function GetJoinedChannels()
  if type(GetChannelList) ~= "function" then return nil, "GetChannelList is unavailable" end
  local values = { pcall(GetChannelList) }
  if not values[1] then return nil, tostring(values[2]) end

  local channels = {}
  local i
  for i = 2, table.getn(values), 2 do
    local channelId = values[i]
    local channelName = values[i + 1]
    if type(channelId) == "number" and channelId > 0 and type(channelName) == "string" then
      table.insert(channels, { id = channelId, name = channelName })
    end
  end
  return channels
end

local function PrintJoinedChannels()
  local channels, err = GetJoinedChannels()
  if not channels then
    PC.Print("channel list unavailable: " .. tostring(err))
    return false
  end
  if table.getn(channels) == 0 then
    PC.Print("joined channels: none")
    return true
  end

  local parts = {}
  local i
  for i = 1, table.getn(channels) do
    table.insert(parts, tostring(channels[i].id) .. "=" .. PC.Sanitize(channels[i].name, 40))
  end
  PC.Print("joined channels: " .. table.concat(parts, ", "))
  return true
end

local function JoinDiagnosticChannel(requestedName, quiet, hidden)
  local name = requestedName
  if not name or name == "" then name = DEFAULT_CUSTOM_CHANNEL end
  if string.len(name) > 40 or not IsPrintableASCII(name) then
    if not quiet then PC.Print("channel join failed: name must be 1-40 printable ASCII characters") end
    return false, "name must be 1-40 printable ASCII characters"
  end
  if type(JoinChannelByName) ~= "function" then
    if not quiet then PC.Print("channel join failed: JoinChannelByName is unavailable") end
    return false, "JoinChannelByName is unavailable"
  end

  local ok
  local result
  if hidden then
    ok, result = pcall(JoinChannelByName, name, "", 0)
  else
    ok, result = pcall(JoinChannelByName, name)
  end
  local channelId = ok and tonumber(result) or nil
  if ok and (not channelId or channelId <= 0) and type(GetChannelName) == "function" then
    local lookupOk, lookupResult = pcall(GetChannelName, name)
    if lookupOk then channelId = tonumber(lookupResult) end
  end
  Storage:AddResult({
    kind = "CHANNEL_JOIN",
    status = ok and "CALL_ACCEPTED" or "CALL_FAILED",
    channelName = name,
    channelId = channelId,
    hidden = hidden and true or false,
    error = ok and nil or tostring(result),
  })
  if not ok then
    if not quiet then PC.Print("channel join failed: " .. tostring(result)) end
    return false, tostring(result)
  end

  if not quiet then
    PC.Print("channel join call accepted: " .. name .. " id=" .. tostring(channelId or "pending"))
    PrintJoinedChannels()
  end
  return true, nil, channelId, name
end

local function FindJoinedChannel(requestedName)
  local name = requestedName
  if not name or name == "" then name = DEFAULT_CUSTOM_CHANNEL end
  local channels, err = GetJoinedChannels()
  if not channels then return nil, err end

  local expected = string.lower(name)
  local i
  for i = 1, table.getn(channels) do
    if string.lower(channels[i].name) == expected then return channels[i] end
  end
  return nil, "channel is not joined or the join is still pending"
end

-- Only a chat tab named exactly like the channel shows its lines; every other
-- tab hides them. The default channel matches by its configured spelling, so
-- the server's casing of the joined name does not matter.
local function ChannelTabName(channelName)
  if type(channelName) ~= "string" then return nil end
  if string.lower(channelName) == string.lower(DEFAULT_CUSTOM_CHANNEL) then return DEFAULT_CUSTOM_CHANNEL end
  return channelName
end

local function TabShowsChannel(frameIndex, channelName)
  if type(GetChatWindowInfo) ~= "function" then return false end
  local ok, tabName = pcall(GetChatWindowInfo, frameIndex)
  return ok and type(tabName) == "string" and tabName == ChannelTabName(channelName)
end

local function FrameListsChannel(chatFrame, channelName)
  if not chatFrame or type(chatFrame.channelList) ~= "table" then return false end
  local expected = string.lower(channelName)
  local index, value
  for index, value in pairs(chatFrame.channelList) do
    if type(value) == "string" and string.lower(value) == expected then return true end
  end
  return false
end

-- 1.12 chat frames drop the lines of a channel missing from their channelList
-- (ChatFrame_OnEvent), while CHAT_MSG_CHANNEL still reaches every frame that
-- registered it. The list is rebuilt from the saved window settings on
-- UPDATE_CHAT_WINDOWS, so it is set here for every tab: added to the tabs named
-- like the channel, removed from all others.
local function ApplyChannelDisplay(channel)
  if not channel then return false, "channel is unavailable" end
  if type(ChatFrame_AddChannel) ~= "function" or type(ChatFrame_RemoveChannel) ~= "function" then
    return false, "chat window channel API is unavailable"
  end
  local removed, added, kept = 0, 0, 0
  local frameIndex = 1
  while frameIndex <= (NUM_CHAT_WINDOWS or 7) do
    local chatFrame = getglobal("ChatFrame" .. frameIndex)
    if chatFrame and type(chatFrame.channelList) == "table" then
      local listed = FrameListsChannel(chatFrame, channel.name)
      if TabShowsChannel(frameIndex, channel.name) then
        if listed then
          kept = kept + 1
        elseif pcall(ChatFrame_AddChannel, chatFrame, channel.name) then
          added = added + 1
        end
      elseif listed and pcall(ChatFrame_RemoveChannel, chatFrame, channel.name) then
        removed = removed + 1
      end
    end
    frameIndex = frameIndex + 1
  end
  Storage:AddResult({
    kind = "CHANNEL_CHAT_DISPLAY",
    status = "COMPLETED",
    channelId = channel.id,
    channelName = channel.name,
    removedFrames = removed,
    addedFrames = added,
    keptFrames = kept,
  })
  return true
end

-- Display guard: a chat frame drops the default channel's lines unless its tab
-- is named exactly like the channel, whatever its channelList holds (a client
-- rebuild or another addon may put the channel back). A matching tab gets the
-- channel listed so the line shows. Display only: reception has its own frame.
local function InstallChannelDisplayGuard()
  if type(ChatFrame_OnEvent) ~= "function" then return end
  local original = ChatFrame_OnEvent
  ChatFrame_OnEvent = function(event)
    if type(event) == "string" and string.sub(event, 1, 16) == "CHAT_MSG_CHANNEL"
      and event ~= "CHAT_MSG_CHANNEL_LIST" and type(arg9) == "string"
      and string.lower(arg9) == string.lower(DEFAULT_CUSTOM_CHANNEL)
      and this and type(this.GetID) == "function" then
      if not TabShowsChannel(this:GetID(), arg9) then return end
      if not FrameListsChannel(this, arg9) and type(ChatFrame_AddChannel) == "function" then
        pcall(ChatFrame_AddChannel, this, arg9)
      end
    end
    return original(event)
  end
end
InstallChannelDisplayGuard()

local function CompleteAutoJoinCycle(status, channel, errorText)
  local attempts = autoJoinState and autoJoinState.attempts or 0
  Storage:AddResult({
    kind = "CHANNEL_AUTO_JOIN_END",
    status = status,
    channelName = channel and channel.name or DEFAULT_CUSTOM_CHANNEL,
    channelId = channel and channel.id or nil,
    attempts = attempts,
    error = errorText,
  })
  if status == "JOINED" then
    if autoJoinState.lastStatus ~= "JOINED" then
      local applied, applyError = ApplyChannelDisplay(channel)
      if not applied then
        PC.Print("custom channel joined, chat display not applied: " .. tostring(applyError))
      end
      -- Tell the channel which build we run; older peers get warned, and newer
      -- ones answer so that we get warned (core/version.lua).
      if PC.Version then
        local announced, announceError = pcall(PC.Version.Announce, PC.Version)
        if not announced then PC.RecordError("version announce", announceError) end
      end
      -- Owner catch-up digest, 10 s later (modules/catchup.lua, decision 0038).
      if PC.Catchup then
        local joined, joinError = pcall(PC.Catchup.OnJoined, PC.Catchup)
        if not joined then PC.RecordError("catch-up join", joinError) end
      end
      -- Scouts under way and discoveries (modules/scout.lua, decision 0050).
      if PC.Scout then
        local asked, askError = pcall(PC.Scout.OnJoined, PC.Scout)
        if not asked then PC.RecordError("scout join", askError) end
      end
      -- Armies under way and pending battles (modules/attack.lua, decision 0052).
      if PC.Attack then
        local asked, askError = pcall(PC.Attack.OnJoined, PC.Attack)
        if not asked then PC.RecordError("attack join", askError) end
      end
    end
  elseif status == "FAILED" then
    PC.Print("automatic custom-channel join failed; retrying in " .. AUTO_JOIN_MONITOR_SECONDS .. " seconds.")
  end
  autoJoinState.attempts = 0
  autoJoinState.lastError = errorText
  autoJoinState.lastStatus = status
  autoJoinState.nextAt = PC.Now() + AUTO_JOIN_MONITOR_SECONDS
end

local function AutoJoinTick()
  if not autoJoinState then return end
  local now = PC.Now()
  if now < autoJoinState.nextAt then return end

  local channel = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if channel then
    CompleteAutoJoinCycle("JOINED", channel)
    return
  end
  if autoJoinState.lastStatus == "JOINED" then
    Storage:AddResult({
      kind = "CHANNEL_AUTO_JOIN_LOST",
      status = "RETRYING",
      channelName = DEFAULT_CUSTOM_CHANNEL,
    })
    autoJoinState.attempts = 0
    autoJoinState.lastStatus = "LOST"
  end
  if autoJoinState.attempts >= AUTO_JOIN_MAX_ATTEMPTS then
    CompleteAutoJoinCycle("FAILED", nil, autoJoinState.lastError)
    return
  end

  autoJoinState.attempts = autoJoinState.attempts + 1
  local hidden = autoJoinState.attempts < AUTO_JOIN_MAX_ATTEMPTS
  local ok, err = JoinDiagnosticChannel(DEFAULT_CUSTOM_CHANNEL, true, hidden)
  autoJoinState.lastError = err
  autoJoinState.lastStatus = "PENDING"
  autoJoinState.nextAt = now + AUTO_JOIN_RETRY_SECONDS
  Storage:AddResult({
    kind = "CHANNEL_AUTO_JOIN_ATTEMPT",
    status = ok and "CALL_ACCEPTED" or "CALL_FAILED",
    channelName = DEFAULT_CUSTOM_CHANNEL,
    attempt = autoJoinState.attempts,
    hidden = hidden,
    error = err,
  })
end

local function StartAutoJoin()
  if autoJoinState then return end
  autoJoinState = {
    attempts = 0,
    lastStatus = "SCHEDULED",
    nextAt = PC.Now() + AUTO_JOIN_INITIAL_DELAY_SECONDS,
  }
  Storage:AddResult({
    kind = "CHANNEL_AUTO_JOIN_START",
    status = "SCHEDULED",
    channelName = DEFAULT_CUSTOM_CHANNEL,
    delaySeconds = AUTO_JOIN_INITIAL_DELAY_SECONDS,
    maxAttempts = AUTO_JOIN_MAX_ATTEMPTS,
  })
  channelJoinFrame:SetScript("OnUpdate", AutoJoinTick)
end

local function OpenPreparedChatNow(text)
  if type(ChatFrame_OpenChat) == "function" then
    local ok, err = pcall(ChatFrame_OpenChat, text)
    if ok then return true end
    return false, tostring(err)
  end
  if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.OpenChat) == "function" then
    local ok, err = pcall(ChatFrameUtil.OpenChat, text)
    if ok then return true end
    return false, tostring(err)
  end
  return false, "the native chat composer is unavailable"
end

local function PreparedChatTick()
  if not preparedChatState then return end
  if PC.Now() < preparedChatState.openAt then return end

  local state = preparedChatState
  preparedChatState = nil
  preparedChatFrame:SetScript("OnUpdate", nil)
  local opened, openError = OpenPreparedChatNow(state.commandText)
  Storage:AddResult({
    kind = "CHANNEL_CHAT_PREPARE",
    status = opened and "AWAITING_USER_SEND" or "PREPARE_FAILED",
    transport = CUSTOM_CHANNEL_TRANSPORT,
    channelId = state.channelId,
    channelName = state.channelName,
    sequence = state.sequence,
    bytes = state.bytes,
    messageType = state.messageType,
    error = openError,
  })
  if opened then
    PC.Print(state.messageType .. " ready for " .. state.channelName .. "; press Enter once to send it.")
  else
    PC.Print("channel HELLO not prepared: " .. tostring(openError) .. "; manually send: " .. state.commandText)
  end
end

local function QueuePreparedChat(commandText, channel, sequence, bytes, messageType)
  if preparedChatState then return false, "another channel message is already being prepared" end
  preparedChatState = {
    commandText = commandText,
    channelId = channel.id,
    channelName = channel.name,
    sequence = sequence,
    bytes = bytes,
    messageType = messageType,
    openAt = PC.Now() + PREPARED_CHAT_DELAY_SECONDS,
  }
  preparedChatFrame:SetScript("OnUpdate", PreparedChatTick)
  return true
end

local function PrepareChannelMessage(messageType, data, requestedName)
  local channel, channelError = FindJoinedChannel(requestedName)
  if not channel then return false, channelError end

  local id = CHANNEL_ID_BY_TYPE[messageType]
  if not id then return false, "invalid message type" end
  if not IsPrintableASCII(data or "") then return false, "data must contain printable ASCII only" end

  local attached, attachError = ApplyChannelDisplay(channel)
  if not attached then return false, attachError end

  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end

  local visiblePayload = ChannelWire(id, db.session.id, sequence, data)
  if string.len(visiblePayload) > CUSTOM_CHANNEL_MAX_BYTES then
    return false, "prepared channel message exceeds 255 bytes"
  end

  local commandText = "/" .. tostring(channel.id) .. " " .. visiblePayload
  local queued, queueError = QueuePreparedChat(commandText, channel, sequence, string.len(visiblePayload), messageType)
  Storage:AddResult({
    kind = "CHANNEL_CHAT_PREPARE",
    status = queued and "QUEUED" or "PREPARE_FAILED",
    transport = CUSTOM_CHANNEL_TRANSPORT,
    channelId = channel.id,
    channelName = channel.name,
    sequence = sequence,
    bytes = string.len(visiblePayload),
    messageType = messageType,
    error = queueError,
  })
  if not queued then return false, queueError .. "; manually send: " .. commandText end

  PC.Print(messageType .. " queued for " .. channel.name .. "; the populated chat input will open next.")
  return true
end

local function PrepareChannelHello(requestedName)
  return PrepareChannelMessage("HELLO", PC.version, requestedName)
end

local function PrepareChannelData(data)
  if not data or data == "" then return false, "text is required" end
  return PrepareChannelMessage("DATA", data, DEFAULT_CUSTOM_CHANNEL)
end

local function SendChannelDataInternal(id, data, reservedSequence, maximumBytes, resultKind, key, priority)
  if not data or data == "" then return false, "text is required" end
  if not IsPrintableASCII(data) then return false, "data must contain printable ASCII only" end
  if string.find(data, "|", 1, true) then return false, "data cannot contain | on the visible channel transport" end

  local channel, channelError = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if not channel then return false, channelError end
  if type(SendChatMessage) ~= "function" then return false, "SendChatMessage is unavailable" end

  local db = Storage:GetDB()
  local sequence = reservedSequence or Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end

  local visiblePayload = ChannelWire(id, db.session.id, sequence, data)
  local messageType = ChannelMessageType(id)
  local allowedBytes = maximumBytes or CUSTOM_CHANNEL_MAX_BYTES
  if string.len(visiblePayload) > allowedBytes then
    return false, "complete visible channel message exceeds " .. tostring(allowedBytes) .. " bytes"
  end

  Storage:IncrementSend(CUSTOM_CHANNEL_TRANSPORT, "attempted")
  -- 1.12 targets a channel by its number: FrameXML resolves it with
  -- GetChannelName before SendChatMessage; a name is not delivered on OctoWoW.
  local channelId, channelName = channel.id, channel.name
  local ok, result = Gate(SendChatMessage, 4, visiblePayload, "CHANNEL", nil, channelId,
    SendRecorder(CUSTOM_CHANNEL_TRANSPORT, messageType, sequence, visiblePayload, "SendChatMessage CHANNEL",
      function(sent, errorText, skipped)
        Storage:AddResult({
          kind = resultKind or "CHANNEL_VISIBLE_SEND",
          status = CallStatus(sent, skipped),
          apiVariant = "DIRECT_DEFAULT_NUMBER",
          transport = CUSTOM_CHANNEL_TRANSPORT,
          channelId = channelId,
          channelName = channelName,
          sequence = sequence,
          bytes = string.len(visiblePayload),
          messageType = messageType,
          error = errorText,
        })
      end), key, priority)
  if not ok then return false, tostring(result) end
  return true, nil, sequence, visiblePayload
end

-- key: a queued message with the same key is superseded (PC.SendQueue).
function P2P.SendChannelData(data, reservedSequence, key)
  return SendChannelDataInternal("D", data, reservedSequence, CUSTOM_CHANNEL_MAX_BYTES, "CHANNEL_VISIBLE_SEND", key)
end

-- Capture traffic: id is one of CAPTURE_IDS, body its comma-separated fields.
-- priority marks an event (START/CAPTURED state, kill), which is never
-- replaceable (rule R12) and is dropped last when the send queue is full.
function P2P.SendChannelEvent(id, body, key, priority)
  if not CAPTURE_IDS[id] then return false, "unknown channel event id" end
  if key and priority then return false, "an event message cannot be replaceable" end
  return SendChannelDataInternal(id, body, nil, CUSTOM_CHANNEL_MAX_BYTES, "CHANNEL_VISIBLE_SEND", key,
    priority and true or nil)
end

-- Version announce (core/version.lua): flag A at channel join, R in reply.
function P2P.SendVersion(flag)
  if flag ~= "A" and flag ~= "R" then return false, "invalid version flag" end
  return SendChannelDataInternal("V", flag, nil, CUSTOM_CHANNEL_MAX_BYTES, "CHANNEL_VISIBLE_SEND")
end

local function FindChannelNameCandidate(values, count, payloadIndex)
  local channels = GetJoinedChannels()
  if not channels then return nil end

  local i
  local j
  for i = 1, count do
    if i ~= payloadIndex and type(values[i]) == "string" then
      local candidate = string.lower(values[i])
      for j = 1, table.getn(channels) do
        local joinedName = string.lower(channels[j].name)
        if candidate == joinedName or string.find(candidate, joinedName, 1, true) then
          return PC.Sanitize(values[i], 100), i
        end
      end
    end
  end
  return nil
end

local function OnChannelMessage(eventName, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  P2P.channelEvents = (P2P.channelEvents or 0) + 1
  local values, descriptors, count = PackArguments(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  local payloadIndex
  local visiblePayload
  local parsed
  local parseError
  local meta
  local i
  for i = 1, count do
    parsed, parseError, meta = P2P.ParseChannel(values[i])
    if parsed or parseError then
      payloadIndex = i
      visiblePayload = values[i]
      break
    end
  end

  Storage:IncrementReceive("events")
  local channelCandidate, channelIndex = FindChannelNameCandidate(values, count, payloadIndex)
  local senderCandidate, senderIndex = FindCandidateSender(values, count, nil, payloadIndex, channelIndex)
  local rawEntry = {
    at = PC.Epoch(),
    elapsed = PC.Now(),
    event = eventName,
    handlerShape = PC.handlerShape,
    argCount = count,
    args = descriptors,
    payloadArgIndex = payloadIndex,
    transportArgIndex = channelIndex,
    transportCandidate = CUSTOM_CHANNEL_TRANSPORT,
    channelCandidate = channelCandidate,
    senderCandidate = senderCandidate,
    senderCandidateArgIndex = senderIndex,
  }

  if not visiblePayload then
    rawEntry.parseStatus = "OTHER_PREFIX_OR_UNKNOWN_SIGNATURE"
    Storage:AddMessage(rawEntry)
    PC.Record("CHAT_MSG_CHANNEL", {
      argCount = count,
      prefixMatch = false,
      channelCandidate = channelCandidate,
      senderCandidate = senderCandidate,
    })
    return
  end

  Storage:IncrementReceive("prefixMatches")
  rawEntry.visibleBytes = string.len(visiblePayload)

  -- Any readable addon version counts, even on a line that is not applied:
  -- this is how a player learns that the addon is outdated (decision 0029).
  if meta and PC.Version then
    local noted, noteError = pcall(PC.Version.Note, PC.Version, meta.version, meta.level)
    if not noted then PC.RecordError("version note", noteError) end
  end

  if not parsed then
    RecordMalformed(rawEntry, parseError, string.len(visiblePayload) > CUSTOM_CHANNEL_MAX_BYTES)
    return
  end

  HandleParsed(parsed, visiblePayload, CUSTOM_CHANNEL_TRANSPORT, rawEntry)
  Storage:AddResult({
    kind = "CHANNEL_CHAT_RECEIVE",
    status = "VALID",
    transport = CUSTOM_CHANNEL_TRANSPORT,
    channelName = channelCandidate,
    sender = senderCandidate,
    messageType = parsed.messageType,
    session = parsed.session,
    sequence = parsed.sequence,
  })
  PC.Record("CHAT_MSG_CHANNEL", {
    argCount = count,
    prefixMatch = true,
    messageType = parsed.messageType,
    channelCandidate = channelCandidate,
    senderCandidate = senderCandidate,
  })
  local db = Storage:GetDB()
  local echo = db and db.session and parsed.session == db.session.id or false
  if parsed.id == "V" then
    if not echo and PC.Version then
      local handled, versionError = pcall(PC.Version.OnAnnounce, PC.Version, parsed.version, parsed.data)
      if not handled then PC.RecordError("version announce", versionError) end
    end
    return
  end
  if CAPTURE_IDS[parsed.id] then
    if PC.Capture and PC.Capture.OnMessage then
      P2P.capRouted = (P2P.capRouted or 0) + 1
      local ok, err = pcall(PC.Capture.OnMessage, PC.Capture, parsed.id, parsed.data, senderCandidate, echo)
      if not ok then
        P2P.capErrors = (P2P.capErrors or 0) + 1
        P2P.lastCapError = PC.Sanitize(err, 160)
        PC.RecordError("capture message", err)
      end
    end
    return
  end
  PC.Print("custom-channel " .. parsed.messageType .. " received from " .. tostring(senderCandidate or "unknown") .. " on " .. tostring(channelCandidate or "unknown"))
end

local channelRegistered, channelRegistrationError = PC.RegisterEvent("CHAT_MSG_CHANNEL", OnChannelMessage)
P2P.channelRegistration = {
  attempted = true,
  accepted = channelRegistered and true or false,
  error = channelRegistrationError and PC.Sanitize(channelRegistrationError, 200) or nil,
}
Storage:AddResult({
  kind = "EVENT_REGISTRATION",
  event = "CHAT_MSG_CHANNEL",
  status = channelRegistered and "REGISTER_ACCEPTED" or "REGISTER_FAILED",
  error = P2P.channelRegistration.error,
})

-- Independent probe: a bare frame counting CHAT_MSG_CHANNEL outside the shared
-- dispatcher, to tell a client that stops delivering from a dispatcher fault.
P2P.probeChannelEvents = 0
local probeOk, probe = pcall(CreateFrame, "Frame", "PandaConquestChannelProbe", UIParent)
if probeOk and probe then
  P2P.probeRegistered = pcall(probe.RegisterEvent, probe, "CHAT_MSG_CHANNEL") and true or false
  probe:SetScript("OnEvent", function()
    P2P.probeChannelEvents = P2P.probeChannelEvents + 1
  end)
end

local function SendAutomaticChannelProbe(channel, apiVariant, sender)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end

  local tag = "AUTO_" .. apiVariant
  local payload = Wire("DATA", db.session.id, sequence, tag)
  if string.len(payload) > MAX_MESSAGE_BYTES then return false, "probe payload exceeds the 1.12 addon message limit" end

  Storage:IncrementSend("CHANNEL", "attempted")
  local ok, result = Gate(sender, 1, payload, nil, nil, nil,
    SendRecorder("CHANNEL", "DATA", sequence, payload, "automatic CHANNEL probe " .. apiVariant,
      function(sent, errorText, skipped)
        Storage:AddResult({
          kind = "CHANNEL_AUTOMATIC_PROBE",
          status = CallStatus(sent, skipped),
          apiVariant = apiVariant,
          channelId = channel.id,
          channelName = channel.name,
          sequence = sequence,
          tag = tag,
          error = errorText,
        })
      end))
  return ok, ok and nil or tostring(result)
end

local function SendAutomaticChannelProbes()
  local channel, channelError = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if not channel then return false, channelError end

  local attempted = 0
  local accepted = 0
  local function Probe(apiVariant, sender)
    attempted = attempted + 1
    local ok = SendAutomaticChannelProbe(channel, apiVariant, sender)
    if ok then accepted = accepted + 1 end
  end

  if type(SendAddonMessage) == "function" then
    Probe("GLOBAL_THREE", function(payload)
      return SendAddonMessage(PREFIX, payload, "CHANNEL")
    end)
    Probe("GLOBAL_FOUR_ID", function(payload)
      return SendAddonMessage(PREFIX, payload, "CHANNEL", channel.id)
    end)
    Probe("GLOBAL_FOUR_NAME", function(payload)
      return SendAddonMessage(PREFIX, payload, "CHANNEL", channel.name)
    end)
  end

  if type(SendChatMessage) == "function" then
    Probe("CHAT_ADDON_DIRECT", function(payload)
      return SendChatMessage(PREFIX .. "\t" .. payload, "CHANNEL", "ADDON", channel.id)
    end)
  end

  Storage:AddResult({
    kind = "CHANNEL_AUTOMATIC_PROBE_SET",
    status = attempted > 0 and "COMPLETED" or "NO_API",
    channelId = channel.id,
    channelName = channel.name,
    attempted = attempted,
    submitted = accepted,
  })
  if attempted == 0 then return false, "no automatic channel API is available" end
  return true, nil, attempted, accepted
end

local function BuildVisibleAutomaticProbe(channel, apiVariant)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return nil, nil, nil, "storage is unavailable" end
  local tag = "AUTO_VISIBLE_" .. apiVariant
  local visiblePayload = ChannelWire("D", db.session.id, sequence, tag)
  if string.len(visiblePayload) > CUSTOM_CHANNEL_MAX_BYTES then
    return nil, nil, nil, "visible probe exceeds 255 bytes"
  end
  return visiblePayload, sequence, tag
end

local function RecordVisibleAutomaticProbe(channel, apiVariant, sequence, tag, visiblePayload, ok, errorText, skipped)
  Storage:AddResult({
    kind = "CHANNEL_VISIBLE_AUTOMATIC_PROBE",
    status = CallStatus(ok, skipped),
    apiVariant = apiVariant,
    transport = CUSTOM_CHANNEL_TRANSPORT,
    channelId = channel.id,
    channelName = channel.name,
    sequence = sequence,
    bytes = visiblePayload and string.len(visiblePayload) or nil,
    messageType = "DATA",
    tag = tag,
    error = errorText,
  })
end

local function SendVisibleAutomaticChannelProbes()
  local channel, channelError = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if not channel then return false, channelError end
  if type(SendChatMessage) ~= "function" then return false, "SendChatMessage is unavailable" end

  local attempted = 0
  local accepted = 0
  local function Probe(apiVariant, sender)
    local visiblePayload, sequence, tag, buildError = BuildVisibleAutomaticProbe(channel, apiVariant)
    if not visiblePayload then return false, buildError end
    attempted = attempted + 1
    local ok = Gate(sender, 1, visiblePayload, nil, nil, nil, function(sent, errorText, skipped)
      RecordVisibleAutomaticProbe(channel, apiVariant, sequence, tag, visiblePayload, sent, errorText, skipped)
    end)
    if ok then accepted = accepted + 1 end
    return ok
  end

  Probe("DIRECT_DEFAULT_NAME", function(payload)
    return SendChatMessage(payload, "CHANNEL", nil, channel.name)
  end)

  local defaultLanguage
  if type(GetDefaultLanguage) == "function" then
    local languageOk, language = pcall(GetDefaultLanguage)
    if languageOk and type(language) == "string" and language ~= "" then defaultLanguage = language end
  end
  if defaultLanguage then
    Probe("DIRECT_LANGUAGE_NAME", function(payload)
      return SendChatMessage(payload, "CHANNEL", defaultLanguage, channel.name)
    end)
  end

  Probe("DIRECT_DEFAULT_ID", function(payload)
    return SendChatMessage(payload, "CHANNEL", nil, tostring(channel.id))
  end)

  if type(RunScript) == "function" then
    Probe("RUNSCRIPT_NAME", function(payload)
      local code = string.format("SendChatMessage(%q, %q, nil, %q)", payload, "CHANNEL", channel.name)
      return RunScript(code)
    end)
  end

  Storage:AddResult({
    kind = "CHANNEL_VISIBLE_AUTOMATIC_PROBE_SET",
    status = "COMPLETED",
    channelId = channel.id,
    channelName = channel.name,
    attempted = attempted,
    submitted = accepted,
  })
  return true, nil, attempted, accepted
end

local function SendInvisibleTransportProbe(apiVariant, transport, target, sender)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end

  local tag = "AUTO_" .. apiVariant
  local payload = Wire("DATA", db.session.id, sequence, tag)
  if string.len(payload) > MAX_MESSAGE_BYTES then return false, "probe payload exceeds the 1.12 addon message limit" end

  Storage:IncrementSend(transport, "attempted")
  local ok, result = Gate(sender, 1, payload, nil, nil, nil,
    SendRecorder(transport, "DATA", sequence, payload, "invisible probe " .. apiVariant,
      function(sent, errorText, skipped)
        Storage:AddResult({
          kind = "INVISIBLE_AUTOMATIC_PROBE",
          status = CallStatus(sent, skipped),
          apiVariant = apiVariant,
          transport = transport,
          target = target,
          sequence = sequence,
          tag = tag,
          error = errorText,
        })
      end))
  return ok, ok and nil or tostring(result)
end

local function SendInvisibleTransportProbes(requestedTarget)
  if type(SendAddonMessage) ~= "function" then
    return false, "SendAddonMessage is unavailable"
  end

  local target = requestedTarget
  if target == "" then target = nil end
  if target and (string.len(target) > 48 or not IsPrintableASCII(target)) then
    return false, "target must be at most 48 printable ASCII characters"
  end

  local attempted = 0
  local accepted = 0
  local function Probe(apiVariant, transport, probeTarget, sender)
    attempted = attempted + 1
    local ok = SendInvisibleTransportProbe(apiVariant, transport, probeTarget, sender)
    if ok then accepted = accepted + 1 end
  end

  local untargeted = { "SAY", "YELL", "EMOTE", "GUILD", "OFFICER", "BATTLEGROUND" }
  local i
  for i = 1, table.getn(untargeted) do
    local chatType = untargeted[i]
    Probe("GLOBAL_" .. chatType, chatType, nil, function(payload)
      return SendAddonMessage(PREFIX, payload, chatType)
    end)
  end

  Probe("GLOBAL_WHISPER_THREE", "WHISPER", target, function(payload)
    return SendAddonMessage(PREFIX, payload, "WHISPER")
  end)
  if target then
    Probe("GLOBAL_WHISPER_FOUR_TARGET", "WHISPER", target, function(payload)
      return SendAddonMessage(PREFIX, payload, "WHISPER", target)
    end)
  end

  Storage:AddResult({
    kind = "INVISIBLE_AUTOMATIC_PROBE_SET",
    status = "COMPLETED",
    target = target,
    attempted = attempted,
    submitted = accepted,
  })
  return true, nil, attempted, accepted
end

StartAutoJoin()

local function SendPing(transport, whisperTarget)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end
  local token = db.session.id .. "-" .. tostring(sequence) .. "-" .. tostring(math.floor(PC.Now() * 1000))
  pendingPings[token] = {
    sentAt = PC.Now(), sequence = sequence,
    transport = whisperTarget and TW_WHISPER_TRANSPORT or Upper(transport),
  }
  table.insert(pendingPingOrder, token)
  while table.getn(pendingPingOrder) > 50 do
    local old = table.remove(pendingPingOrder, 1)
    pendingPings[old] = nil
  end
  local ok, err
  if whisperTarget then
    ok, err = SendTwWhisper(whisperTarget, "PING", token, sequence)
  else
    ok, err = P2P.SendEnvelope("PING", transport, token, sequence)
  end
  if not ok then pendingPings[token] = nil end
  return ok, err
end

local function SendExactSize(transport, requestedSize)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end
  local header = Wire("DATA", db.session.id, sequence, "")
  local marker = "SIZE=" .. tostring(requestedSize) .. ";BODY="
  local fillLength = requestedSize - string.len(header) - string.len(marker)
  if fillLength < 0 then return false, "requested size is too small for the envelope" end
  if requestedSize > MAX_MESSAGE_BYTES then return false, "requested size exceeds the safety limit" end
  return P2P.SendEnvelope("DATA", transport, marker .. MakeFill(fillLength), sequence)
end

local function StopSizeSweep(reason)
  if not sizeSweepState then return end
  local completed = sizeSweepState.index
  local total = table.getn(sizeSweepState.sizes)
  local profile = sizeSweepState.profile
  sizeSweepState = nil
  sizeSweepFrame:SetScript("OnUpdate", nil)
  Storage:AddResult({ kind = "SIZE_SWEEP_END", status = reason, profile = profile, completed = completed, requested = total })
  PC.Print("size sweep " .. profile .. " stopped: " .. tostring(reason) .. " (" .. completed .. "/" .. total .. ")")
end

local function SizeSweepTick()
  if not sizeSweepState then return end
  local now = PC.Now()
  if now < sizeSweepState.nextAt then return end

  local nextIndex = sizeSweepState.index + 1
  local requestedSize = sizeSweepState.sizes[nextIndex]
  local total = table.getn(sizeSweepState.sizes)
  PC.Print("SIZE TRY bytes=" .. requestedSize .. " profile=" .. sizeSweepState.profile .. " step=" .. nextIndex .. "/" .. total)
  local ok, err = SendExactSize(sizeSweepState.transport, requestedSize)
  sizeSweepState.index = nextIndex
  sizeSweepState.nextAt = now + sizeSweepState.intervalSeconds
  Storage:AddResult({
    kind = "SIZE_SWEEP_STEP",
    status = ok and "CALL_ACCEPTED" or "CALL_FAILED",
    transport = sizeSweepState.transport,
    index = nextIndex,
    requestedBytes = requestedSize,
    error = err,
  })
  if ok then
    PC.Print("SIZE ACCEPTED bytes=" .. requestedSize)
  else
    PC.Print("SIZE FAILED bytes=" .. requestedSize .. " error=" .. tostring(err))
  end

  if nextIndex >= table.getn(sizeSweepState.sizes) then
    StopSizeSweep("COMPLETED")
  end
end

sizeSweepFrame:SetScript("OnUpdate", nil)

local function StartSizeSweep(transport, requestedProfile)
  if sizeSweepState then return false, "a size sweep is already active" end
  if burstState then return false, "a burst is already active" end
  local normalized, transportError = ValidateTransport(transport)
  if not normalized then return false, transportError end

  local profile = string.lower(requestedProfile or "")
  local sizes
  local intervalSeconds = 1
  if profile == "" or profile == "baseline" then
    profile = "baseline"
    sizes = SIZE_SWEEP_BASELINE_BYTES
  elseif profile == "boundary" or profile == "extended" then
    profile = "boundary"
    sizes = SIZE_SWEEP_BOUNDARY_BYTES
  else
    return false, "profile must be baseline or boundary"
  end

  sizeSweepState = {
    transport = normalized,
    profile = profile,
    sizes = sizes,
    intervalSeconds = intervalSeconds,
    index = 0,
    startedAt = PC.Now(),
    nextAt = PC.Now(),
  }
  Storage:AddResult({
    kind = "SIZE_SWEEP_START",
    status = "STARTED",
    transport = normalized,
    profile = profile,
    messages = table.getn(sizes),
    intervalSeconds = intervalSeconds,
  })
  sizeSweepFrame:SetScript("OnUpdate", SizeSweepTick)
  return true, nil, profile, table.getn(sizes), intervalSeconds
end

local function BuildBurstData(index, count, dataBytes)
  local marker = "B=" .. tostring(index) .. "/" .. tostring(count) .. ";"
  if string.len(marker) > dataBytes then return nil end
  return marker .. MakeFill(dataBytes - string.len(marker))
end

local function StopBurst(reason)
  if not burstState then return end
  local completed = burstState.sent
  local total = burstState.count
  burstState = nil
  burstFrame:SetScript("OnUpdate", nil)
  Storage:AddResult({ kind = "BURST_END", status = reason, sent = completed, requested = total })
  PC.Print("burst stopped: " .. tostring(reason) .. " (" .. completed .. "/" .. total .. ")")
end

local function BurstTick()
  if not burstState then return end
  local now = PC.Now()
  if now < burstState.nextAt then return end
  if now - burstState.startedAt > MAX_BURST_SECONDS + 1 then
    StopBurst("TIME_LIMIT")
    return
  end

  local nextIndex = burstState.sent + 1
  local data = BuildBurstData(nextIndex, burstState.count, burstState.dataBytes)
  if not data then
    StopBurst("INVALID_SIZE")
    return
  end

  local ok, err = P2P.SendEnvelope("BURST", burstState.transport, data)
  if not ok then
    Storage:AddResult({ kind = "BURST_ERROR", status = "CALL_FAILED", error = err, index = nextIndex })
    StopBurst("SEND_FAILED")
    return
  end

  burstState.sent = nextIndex
  burstState.nextAt = now + (1 / burstState.rate)
  if burstState.sent >= burstState.count then StopBurst("COMPLETED") end
end

burstFrame:SetScript("OnUpdate", nil)

local function StartBurst(transport, count, dataBytes, rate)
  if burstState then return false, "a burst is already active" end
  if sizeSweepState then return false, "a size sweep is already active" end
  local normalized, transportError = ValidateTransport(transport)
  if not normalized then return false, transportError end
  if count < 1 or count > MAX_BURST_COUNT then return false, "count must be between 1 and 50" end
  if dataBytes < 12 or dataBytes > MAX_DATA_BYTES then return false, "data bytes must be between 12 and " .. MAX_DATA_BYTES end
  if rate ~= 1 and rate ~= 2 and rate ~= 4 then return false, "rate must be 1, 2, or 4 messages/second (send gate: 0.25 s apart, a 1.1 s pause after 6 close sends)" end
  if ((count - 1) / rate) > MAX_BURST_SECONDS then return false, "burst duration would exceed 10 seconds" end

  burstState = {
    transport = normalized,
    count = count,
    dataBytes = dataBytes,
    rate = rate,
    sent = 0,
    startedAt = PC.Now(),
    nextAt = PC.Now(),
  }
  Storage:AddResult({
    kind = "BURST_START",
    status = "STARTED",
    transport = normalized,
    count = count,
    dataBytes = dataBytes,
    rate = rate,
  })
  burstFrame:SetScript("OnUpdate", BurstTick)
  return true
end

local function PrintStatus()
  local db = Storage:GetDB()
  local receive = db and db.receiveStats or {}
  local send = db and db.sendStats or {}
  local registration = P2P.registration or {}
  local channelRegistration = P2P.channelRegistration or {}
  PC.Print("version=" .. PC.version .. " channel=PC" .. tostring(CHANNEL_LEVEL) .. " addon=V1 prefix=" .. PREFIX .. " session=" .. tostring(db and db.session.id or "none"))
  if PC.Version then PC.Print(PC.Version:Summary()) end
  PC.Print("CHAT_MSG_ADDON registration=" .. (registration.accepted and "accepted" or "failed") .. " handler=" .. PC.handlerShape)
  PC.Print("CHAT_MSG_CHANNEL registration=" .. (channelRegistration.accepted and "accepted" or "failed") .. " assisted transport=" .. CUSTOM_CHANNEL_TRANSPORT)
  local joinedChannel = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if joinedChannel then
    PC.Print("custom channel=" .. joinedChannel.name .. " id=" .. tostring(joinedChannel.id) .. " joined=yes chat=tab "
      .. DEFAULT_CUSTOM_CHANNEL .. " only")
  elseif autoJoinState then
    PC.Print("custom channel=" .. DEFAULT_CUSTOM_CHANNEL .. " joined=pending status=" .. tostring(autoJoinState.lastStatus) .. " attempts=" .. tostring(autoJoinState.attempts))
  else
    PC.Print("custom channel=" .. DEFAULT_CUSTOM_CHANNEL .. " joined=no")
  end
  PC.Print("send calls attempted=" .. tostring(send.attempted or 0) .. " accepted=" .. tostring(send.acceptedCalls or 0) .. " failed=" .. tostring(send.failedCalls or 0) .. " skipped=" .. tostring(send.skippedCalls or 0))
  PC.Print(PC.SendQueue:Summary())
  PC.Print("receive events=" .. tostring(receive.events or 0) .. " prefix=" .. tostring(receive.prefixMatches or 0) .. " valid=" .. tostring(receive.validMessages or 0) .. " malformed=" .. tostring(receive.malformed or 0))
  PC.Print("missing=" .. tostring(receive.missingSequences or 0) .. " duplicates=" .. tostring(receive.duplicates or 0) .. " out-of-order=" .. tostring(receive.outOfOrder or 0) .. " echoes=" .. tostring(receive.echoes or 0))
  if (receive.rttCount or 0) > 0 then
    local average = math.floor(((receive.rttTotalMs or 0) / receive.rttCount) + 0.5)
    PC.Print("RTT ms min/avg/max=" .. tostring(receive.rttMinMs) .. "/" .. tostring(average) .. "/" .. tostring(receive.rttMaxMs) .. " samples=" .. tostring(receive.rttCount))
  else
    PC.Print("PONG round trips observed=0")
  end
  if registration.error then PC.Print("registration error: " .. registration.error) end
  if channelRegistration.error then PC.Print("channel registration error: " .. channelRegistration.error) end
  if burstState then PC.Print("burst active: " .. burstState.sent .. "/" .. burstState.count .. " at " .. burstState.rate .. "/s") end
  if sizeSweepState then PC.Print("size sweep " .. sizeSweepState.profile .. " active: " .. sizeSweepState.index .. "/" .. table.getn(sizeSweepState.sizes)) end
end

local function PrintLog(requested)
  local db = Storage:GetDB()
  local messages = db and db.lastMessages or {}
  local count = tonumber(requested) or 10
  if count < 1 then count = 1 end
  if count > 20 then count = 20 end
  local first = table.getn(messages) - count + 1
  if first < 1 then first = 1 end
  if table.getn(messages) == 0 then
    PC.Print("no P2P receive events captured")
    return
  end

  local i
  for i = first, table.getn(messages) do
    local item = messages[i]
    local sizeSummary = ""
    if item.expectedBytes then
      sizeSummary = " size=" .. tostring(item.actualBytes) .. "/" .. tostring(item.expectedBytes) .. " exact=" .. tostring(item.exactSize)
    end
    PC.Print("#" .. i .. " " .. tostring(item.parseStatus) .. " args=" .. tostring(item.argCount) .. " type=" .. tostring(item.messageType or "-") .. " transport=" .. tostring(item.transportCandidate or "-") .. " sender?=" .. tostring(item.senderCandidate or "-") .. sizeSummary)
    local parts = {}
    local j
    for j = 1, table.getn(item.args or {}) do
      local argument = item.args[j]
      table.insert(parts, tostring(argument.index) .. ":" .. tostring(argument.valueType) .. "=" .. PC.Sanitize(argument.value, 60))
    end
    if table.getn(parts) > 0 then
      PC.Print("  " .. PC.Sanitize(table.concat(parts, "; "), 300))
    end
  end
end

local function PrintHelp()
  PC.Print("/pc or /pc ui (open or close the PandaConquest window); /pc help (this list)")
  PC.Print("/pc classic (open or close the classic text window)")
  PC.Print("/pc map (world-map POI area renderer status)")
  PC.Print("/pc map probe | probe off (area-texture test squares on the world map)")
  PC.Print("/pc where (player position and the POI it is inside)")
  PC.Print("/pc capture (outpost capture states and transport counters)")
  PC.Print("/pc hunt (hunting ground kills, last credited death and states)")
  PC.Print("/pc army (reserve, unit costs and whether you can recruit here)")
  PC.Print("/pc recruit <unit> [count] (in an Outpost or Settlement of your faction; footman, rifleman, mortar, scout)")
  PC.Print("/pc garrison (garrison, Settlement level and War Chest of the place you stand in)")
  PC.Print("/pc pledge <unit|gold|wood> [count] confirm (irreversible gift to the garrison or Settlement War Chest)")
  PC.Print("/pc scout [POI id] (scouting status and targets, or send your scout to an enemy Outpost or Settlement)")
  PC.Print("/pc attack [POI id footmen riflemen mortars] (armies and battles, or send an army to a discovered enemy place)")
  PC.Print("/pc p2p status")
  PC.Print("/pc p2p join [channel-name] | channels")
  PC.Print("/pc p2p channelauto (hidden CHANNEL SendAddonMessage experiments; no Enter)")
  PC.Print("/pc p2p channelvisibleauto (automatic visible API probes; no Enter)")
  PC.Print("/pc p2p channelsend <printable ASCII text> (automatic visible P2P)")
  PC.Print("/pc p2p invisible [target-player] (all non-group hidden probes)")
  PC.Print("/pc p2p channelhello [channel-name] (then press Enter)")
  PC.Print("/pc p2p channeldata <printable ASCII text> (then press Enter)")
  PC.Print("/pc p2p hello PARTY|RAID|GUILD|BATTLEGROUND")
  PC.Print("/pc p2p ping PARTY|RAID|GUILD")
  PC.Print("/pc p2p twhisper <player> [ping|hello] (experimental hidden whisper through the server)")
  PC.Print("/pc p2p send <transport> <printable ASCII text>")
  PC.Print("/pc p2p size <transport> <complete message bytes>")
  PC.Print("/pc p2p sizes <transport> [baseline|boundary]")
  PC.Print("  1.12 maximum=" .. MAX_MESSAGE_BYTES .. " message bytes (" .. ADDON_MESSAGE_MAX_BYTES .. " with prefix)")
  PC.Print("/pc p2p burst <transport> <count> <data bytes> [1|2|4 per second]")
  PC.Print("/pc p2p report | stop | log [1-20] | clear")
  PC.Print("channelsend uses the automatic visible custom-channel transport.")
end

local function ReportCommandResult(ok, err)
  if ok then
    PC.Print("SendAddonMessage call accepted or queued by the send gate; delivery is not yet proven.")
  else
    PC.Print("test not sent: " .. tostring(err))
  end
end

local function ChannelCommand(command, rest)
  if command == "join" then
    local channelName = TakeWord(rest)
    JoinDiagnosticChannel(channelName)
  elseif command == "channels" then
    PrintJoinedChannels()
  elseif command == "twhisper" then
    local target, tail = TakeWord(rest)
    local ok, err
    if string.lower(TakeWord(tail) or "") == "hello" then
      ok, err = SendTwWhisper(target, "HELLO", PC.version)
    else
      ok, err = SendPing(nil, target)
    end
    if ok then
      PC.Print("hidden TW whisper sent to " .. tostring(target) .. "; only a PONG or a capture on that client proves delivery.")
    else
      PC.Print("TW whisper not sent: " .. tostring(err))
    end
  elseif command == "channelauto" then
    local ok, err, attempted, accepted = SendAutomaticChannelProbes()
    if ok then
      PC.Print("automatic hidden CHANNEL probes completed: " .. tostring(attempted) .. " attempted, " .. tostring(accepted) .. " submitted to the send gate (0.25 s apart, 1.1 s pause after 6 close sends); no Enter was required.")
    else
      PC.Print("automatic hidden CHANNEL probes not completed: " .. tostring(err))
    end
  elseif command == "channelvisibleauto" then
    local ok, err, attempted, accepted = SendVisibleAutomaticChannelProbes()
    if ok then
      PC.Print("automatic visible CHANNEL probes completed: " .. tostring(attempted) .. " attempted, " .. tostring(accepted) .. " submitted to the send gate (0.25 s apart, 1.1 s pause after 6 close sends); no Enter is required.")
    else
      PC.Print("automatic visible CHANNEL probes not started: " .. tostring(err))
    end
  elseif command == "channelsend" then
    local ok, err, sequence = P2P.SendChannelData(rest)
    if ok then
      PC.Print("automatic visible CHANNEL DATA sent as sequence " .. tostring(sequence) .. "; no user confirmation was required.")
    else
      PC.Print("automatic visible CHANNEL DATA not sent: " .. tostring(err))
    end
  elseif command == "invisible" then
    local target = TakeWord(rest)
    local ok, err, attempted, accepted = SendInvisibleTransportProbes(target)
    if ok then
      PC.Print("non-group invisible probes completed: " .. tostring(attempted) .. " attempted, " .. tostring(accepted) .. " submitted to the send gate (0.25 s apart, 1.1 s pause after 6 close sends); no Enter was required.")
    else
      PC.Print("non-group invisible probes not completed: " .. tostring(err))
    end
  elseif command == "channelhello" then
    local channelName = TakeWord(rest)
    local ok, err = PrepareChannelHello(channelName)
    if not ok then PC.Print("channel HELLO not prepared: " .. tostring(err)) end
  elseif command == "channeldata" then
    local ok, err = PrepareChannelData(rest)
    if not ok then PC.Print("channel DATA not prepared: " .. tostring(err)) end
  else
    return false
  end
  return true
end

local function SlashCommand(message)
  local scope, rest = TakeWord(message)
  if scope == nil or string.lower(scope) == "ui" then
    if not PC.MainWindow or not PC.MainWindow.Toggle then
      PC.Print("the PandaConquest window is unavailable (restart the client after an update)")
      return
    end
    PC.MainWindow:Toggle()
    return
  end
  if string.lower(scope) == "classic" then
    if not PC.ClassicWindow or not PC.ClassicWindow.Toggle then
      PC.Print("the classic PandaConquest window is unavailable (restart the client after an update)")
      return
    end
    PC.ClassicWindow:Toggle()
    return
  end
  if string.lower(scope or "") == "map" then
    if not PC.Map or not PC.Map.GetStatus then
      PC.Print("map renderer is unavailable")
      return
    end
    local status = PC.Map:GetStatus()
    PC.Print("map enabled=" .. tostring(status.enabled)
      .. " zone=" .. tostring(status.map or "none")
      .. " registered=" .. tostring(status.registered)
      .. " visible=" .. tostring(status.visible)
      .. " patches=" .. tostring(status.patches)
      .. " icons=" .. tostring(status.icons)
      .. " building=" .. tostring(status.building)
      .. " failures=" .. tostring(status.failures))
    if PC.MinimapAreas then
      local mini = PC.MinimapAreas:GetStatus()
      PC.Print("minimap zone=" .. tostring(mini.zone or "none")
        .. " patches=" .. tostring(mini.patches) .. " icons=" .. tostring(mini.icons)
        .. " indoor=" .. tostring(mini.indoor))
    end
    local option = string.lower(rest or "")
    if option == "hover" then
      PC.Print("hover " .. tostring(PC.Map.hoverDebug or "no sample yet (open the map)"))
      PC.Print("last tooltip " .. tostring(PC.Map.tooltipDebug or "none yet (hover an area)"))
    elseif option == "hover probe" or option == "hover probe off" then
      PC.Map:SetHoverProbe(option == "hover probe")
      if option == "hover probe" then
        PC.Print("hover probe on: sweep the cursor over the areas, then /pc map hover report")
      else
        PC.Print("hover probe off")
      end
    elseif option == "hover report" then
      local lines = PC.Map:HoverProbeReport()
      local index = 1
      while index <= table.getn(lines) do
        PC.Print(lines[index])
        index = index + 1
      end
    elseif option == "probe" or option == "probe off" then
      local ok, shown, detail = pcall(PC.Map.ShowProbe, PC.Map, option == "probe")
      PC.Print("map probe " .. (ok and tostring(shown) or "error") .. " "
        .. tostring(ok and detail or shown))
      if ok and shown and option == "probe" then
        PC.Print("open the map: 5 pink squares near its top-left corner")
      end
    end
    return
  end
  if string.lower(scope or "") == "where" then
    if not PC.Presence or not PC.Presence.PrintStatus then
      PC.Print("POI presence detection is unavailable")
      return
    end
    PC.Presence:PrintStatus()
    return
  end
  if string.lower(scope or "") == "companion" then
    if not PC.Companion then
      PC.Print("companion guard is unavailable (restart the client after an update)")
      return
    end
    PC.Companion:PrintStatus()
    return
  end
  if string.lower(scope or "") == "fileprobe" then
    if not PC.FileProbe then
      PC.Print("file probe is unavailable (restart the client after an update)")
      return
    end
    PC.FileProbe:Command(rest)
    return
  end
  if string.lower(scope or "") == "res" or string.lower(scope or "") == "resources" then
    if not PC.Stock or not PC.Stock.PrintStatus then
      PC.Print("resources are unavailable")
      return
    end
    PC.Stock:PrintStatus()
    return
  end
  if string.lower(scope or "") == "army" or string.lower(scope or "") == "recruit" then
    if not PC.Army or not PC.Army.PrintStatus then
      PC.Print("army is unavailable")
      return
    end
    if string.lower(scope) == "recruit" then
      PC.Army:RecruitCommand(rest)
    else
      PC.Army:PrintStatus()
    end
    return
  end
  if string.lower(scope or "") == "garrison" or string.lower(scope or "") == "pledge" then
    if not PC.Garrison or not PC.Garrison.PrintStatus then
      PC.Print("garrisons are unavailable")
      return
    end
    if string.lower(scope) == "pledge" then
      PC.Garrison:PledgeCommand(rest)
    else
      PC.Garrison:PrintStatus()
    end
    return
  end
  if string.lower(scope or "") == "scout" then
    if not PC.Scout or not PC.Scout.Command then
      PC.Print("scouting is unavailable")
      return
    end
    PC.Scout:Command(rest)
    return
  end
  if string.lower(scope or "") == "attack" then
    if not PC.Attack or not PC.Attack.Command then
      PC.Print("attacks are unavailable")
      return
    end
    PC.Attack:Command(rest)
    return
  end
  if string.lower(scope or "") == "capture" then
    if not PC.Capture or not PC.Capture.PrintStatus then
      PC.Print("outpost capture is unavailable")
      return
    end
    PC.Capture:PrintStatus()
    return
  end
  if string.lower(scope or "") == "hunt" then
    if not PC.Hunting or not PC.Hunting.PrintStatus then
      PC.Print("hunting ground capture is unavailable")
      return
    end
    PC.Hunting:PrintStatus()
    return
  end
  if string.lower(scope or "") ~= "p2p" then
    PrintHelp()
    return
  end

  local command
  command, rest = TakeWord(rest)
  command = string.lower(command or "")
  if ChannelCommand(command, rest) then return end
  if command == "status" then
    PrintStatus()
  elseif command == "report" then
    PrintLog(20)
    PrintStatus()
  elseif command == "hello" then
    local transport = TakeWord(rest)
    ReportCommandResult(SendHello(transport))
  elseif command == "ping" then
    local transport = TakeWord(rest)
    local normalized = Upper(transport)
    if not SAFE_AUTO_REPLY[normalized] then
      PC.Print("automatic PONG is limited to PARTY, RAID, and GUILD until targeting semantics are known")
      return
    end
    ReportCommandResult(SendPing(normalized))
  elseif command == "send" then
    local transport, text = TakeWord(rest)
    if text == "" then
      PC.Print("test not sent: text is required")
      return
    end
    ReportCommandResult(P2P.SendEnvelope("DATA", transport, text))
  elseif command == "size" then
    local transport, sizeText = TakeWord(rest)
    local requestedSize = tonumber(sizeText)
    if not requestedSize or requestedSize ~= math.floor(requestedSize) then
      PC.Print("test not sent: size must be a whole number")
      return
    end
    PC.Print("SIZE TRY bytes=" .. requestedSize .. " profile=manual step=1/1")
    local ok, err = SendExactSize(transport, requestedSize)
    if ok then
      PC.Print("SIZE ACCEPTED bytes=" .. requestedSize)
    else
      PC.Print("SIZE FAILED bytes=" .. requestedSize .. " error=" .. tostring(err))
    end
  elseif command == "sizes" then
    local transport, tail = TakeWord(rest)
    local profile = TakeWord(tail)
    local ok, err, activeProfile, messageCount, intervalSeconds = StartSizeSweep(transport, profile)
    if ok then
      PC.Print("automatic " .. activeProfile .. " size sweep started: " .. messageCount .. " messages, one every " .. intervalSeconds .. " second(s)")
    else
      PC.Print("size sweep not started: " .. tostring(err))
    end
  elseif command == "burst" then
    local transport, tail = TakeWord(rest)
    local countText
    countText, tail = TakeWord(tail)
    local dataBytesText
    dataBytesText, tail = TakeWord(tail)
    local rateText = TakeWord(tail)
    local count = tonumber(countText)
    local dataBytes = tonumber(dataBytesText)
    local rate = tonumber(rateText) or 1
    if not count or count ~= math.floor(count) or not dataBytes or dataBytes ~= math.floor(dataBytes) then
      PC.Print("burst not started: count and data bytes must be whole numbers")
      return
    end
    local ok, err = StartBurst(transport, count, dataBytes, rate)
    if ok then
      PC.Print("bounded burst started; use /pc p2p stop to cancel")
    else
      PC.Print("burst not started: " .. tostring(err))
    end
  elseif command == "stop" then
    if burstState then
      StopBurst("USER_STOPPED")
    elseif sizeSweepState then
      StopSizeSweep("USER_STOPPED")
    else
      PC.Print("no burst or size sweep is active")
    end
  elseif command == "log" then
    local amount = TakeWord(rest)
    PrintLog(amount)
  elseif command == "clear" then
    if burstState then StopBurst("DIAGNOSTICS_CLEARED") end
    if sizeSweepState then StopSizeSweep("DIAGNOSTICS_CLEARED") end
    pendingPings = {}
    pendingPingOrder = {}
    seen = {}
    seenOrder = {}
    lastSequence = {}
    Storage:ClearDiagnostics()
    PC.Print("P2P diagnostics cleared; session and sequence were preserved.")
  else
    PrintHelp()
  end
end

if type(SlashCmdList) == "table" then
  SLASH_PANDACONQUEST1 = "/pc"
  SlashCmdList.PANDACONQUEST = SlashCommand
else
  PC.RecordError("slash registration", "SlashCmdList is unavailable; /pc was not registered")
end

PC.Record("P2P_READY", {
  prefix = PREFIX,
  protocol = "V1",
  registrationAccepted = registered and true or false,
  maxMessageBytes = MAX_MESSAGE_BYTES,
})
