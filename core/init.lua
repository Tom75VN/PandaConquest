PandaConquest = PandaConquest or {}

local PC = PandaConquest

PC.name = "pandaConquest"
-- Same value as ## Version in the .toc (checked by tools/smoke.py). Every
-- channel line carries it so older builds learn that they are outdated.
-- Changed only by tools/release.py prepare, once per push (decision 0035).
PC.version = "0.0.1"
-- Compatibility level n of the channel line PC<n> (decision 0029): raised by any
-- change that can make two builds disagree on the same messages, at the next
-- tools/release.py prepare. Lines of another level are never applied.
PC.channelLevel = 4

local listeners = {}
local registrations = {}
local pendingLog = {}
local dispatcher = CreateFrame("Frame", "PandaConquestEventFrame", UIParent)

function PC.Now()
  if GetTime then return GetTime() end
  return 0
end

function PC.Epoch()
  if time then return time() end
  return 0
end

function PC.Print(message)
  local text = "|cfff5ae0apandaConquest:|r " .. tostring(message)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(text)
  end
end

function PC.Sanitize(value, limit)
  local source = tostring(value or "")
  local maximum = tonumber(limit) or 160
  local output = ""
  local truncated = false
  local i

  for i = 1, string.len(source) do
    local byte = string.byte(source, i)
    local piece
    if byte >= 32 and byte <= 126 then
      piece = string.char(byte)
    elseif byte == 9 then
      piece = "\\t"
    elseif byte == 10 then
      piece = "\\n"
    elseif byte == 13 then
      piece = "\\r"
    else
      piece = string.format("\\x%02X", byte)
    end

    if string.len(output) + string.len(piece) > maximum then
      truncated = true
      break
    end
    output = output .. piece
  end

  if truncated then output = output .. "..." end
  return output, truncated, string.len(source)
end

function PC.Record(kind, fields)
  if PC.Storage and PC.Storage.AddLog then
    PC.Storage:AddLog(kind, fields)
    return
  end

  table.insert(pendingLog, { kind = kind, fields = fields })
  while table.getn(pendingLog) > 50 do
    table.remove(pendingLog, 1)
  end
end

function PC.FlushPendingLog()
  if not PC.Storage or not PC.Storage.AddLog then return end
  local i
  for i = 1, table.getn(pendingLog) do
    local entry = pendingLog[i]
    PC.Storage:AddLog(entry.kind, entry.fields)
  end
  pendingLog = {}
end

function PC.RecordError(scope, errorText)
  local safe = PC.Sanitize(errorText, 240)
  if PC.Storage and PC.Storage.AddError then
    PC.Storage:AddError(scope, safe)
  else
    PC.Record("ERROR", { scope = scope, error = safe })
  end
end

-- Live, unpersisted counters of what the dispatcher receives (shown by /pc capture).
PC.eventCounts = {}
PC.unresolvedEvents = 0

-- 1.12 handlers receive no arguments: the event and arg1..arg9 are globals
-- (scripts.handler_arguments_legacy_globals).
PC.handlerShape = "legacy-globals"
dispatcher:SetScript("OnEvent", function()
  local eventName = event
  if type(eventName) ~= "string" then
    PC.unresolvedEvents = PC.unresolvedEvents + 1
    return
  end
  PC.eventCounts[eventName] = (PC.eventCounts[eventName] or 0) + 1

  local callbacks = listeners[eventName]
  if not callbacks then return end

  local a1, a2, a3, a4, a5, a6, a7, a8, a9 = arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9
  local n
  for n = 1, table.getn(callbacks) do
    local callback = callbacks[n]
    if callback then
      local ok, err = pcall(callback, eventName, a1, a2, a3, a4, a5, a6, a7, a8, a9)
      if not ok then
        PC.lastHandlerError = eventName .. ": " .. PC.Sanitize(err, 160)
        PC.RecordError(eventName .. " handler", err)
      end
    end
  end
end)

function PC.RegisterEvent(eventName, callback)
  if type(eventName) ~= "string" or type(callback) ~= "function" then
    return false, "invalid registration arguments"
  end

  if not listeners[eventName] then
    listeners[eventName] = {}
    local ok, err = pcall(dispatcher.RegisterEvent, dispatcher, eventName)
    registrations[eventName] = {
      attempted = true,
      accepted = ok and true or false,
      error = ok and nil or PC.Sanitize(err, 200),
    }
    if not ok then
      listeners[eventName] = nil
      PC.RecordError("RegisterEvent(" .. eventName .. ")", err)
      return false, err
    end
  end

  table.insert(listeners[eventName], callback)
  return true
end

function PC.GetEventRegistration(eventName)
  return registrations[eventName]
end
