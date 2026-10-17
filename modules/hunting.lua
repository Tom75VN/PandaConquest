PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Capture = PC.Capture
local Hunting = {
  states = {},
  seen = {},
  seenCount = 0,
  here = nil,
  dirty = false,
  deaths = 0,
  credited = 0,
  sent = 0,
  last = nil,
}

PC.Hunting = Hunting

-- HUNTING_GROUNDS capture (docs/capture.md, decision 0026). One shared bar like an
-- outpost, moved by kills instead of time: progress is in thousandths of the
-- challenger's share and every credited kill is worth one tenth of the bar.
local KILLS_REQUIRED = 10
local STEP = 1000 / KILLS_REQUIRED
-- Respawned creatures keep their GUID, so the duplicate window must stay shorter
-- than a respawn timer; it only has to absorb the same kill reported by a group.
local SEEN_TTL = 30
local MAX_SEEN = 256
local MAX_VERSION = 100000
local REPLY_DELAY = 0.5
local REPLY_SPREAD = 2.5
local MAP_INTERVAL = 1
local SAVE_INTERVAL = 1
local QUERY_WAIT = 4

Hunting.KILLS_REQUIRED = KILLS_REQUIRED

local FACTION_KEYS = { H = "HORDE", A = "ALLIANCE" }
local OWNERS = { N = true, H = true, A = true }
local SIDES = { ["-"] = true, H = true, A = true }
local FACTION_NAMES = { H = "Horde", A = "Alliance", N = "Neutral" }

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

local function Int(text, maximum)
  if type(text) ~= "string" or not string.find(text, "^%d+$") or string.len(text) > 9 then
    return nil
  end
  local value = tonumber(text)
  if not value or value > maximum then return nil end
  return value
end

-- Creature GUIDs are "0xF130" + 6 hex digits of entry + 6 of spawn counter
-- (VMaNGOS ObjectGuid). Returns the 16 hex digits and the entry, or nil.
local function ParseGuid(guid)
  if type(guid) ~= "string" then return nil end
  local digits = guid
  if string.sub(digits, 1, 2) == "0x" or string.sub(digits, 1, 2) == "0X" then
    digits = string.sub(digits, 3)
  end
  if string.len(digits) ~= 16 or not string.find(digits, "^%x+$") then return nil end
  digits = string.upper(digits)
  if string.sub(digits, 1, 4) ~= "F130" then return digits, nil end
  return digits, tonumber(string.sub(digits, 5, 10), 16)
end

Hunting.ParseGuid = ParseGuid

-- Catalogue -------------------------------------------------------------------

-- The area, only when it is a hunting ground that lists creatures to kill.
function Hunting:Area(id)
  local area = Capture and Capture:Capturable(id) or nil
  if area and area.type == "HUNTING_GROUNDS" and table.getn(area.requiredMobIds or {}) > 0 then
    return area
  end
  return nil
end

local function RequiresMob(area, entry)
  local ids = area.requiredMobIds
  local index = 1
  while index <= table.getn(ids) do
    if ids[index] == entry then return true end
    index = index + 1
  end
  return false
end

-- State -------------------------------------------------------------------------

function Hunting:GetState(id)
  local st = self.states[id]
  if st then return st end
  local owner, generation = Capture:GetOwner(id)
  st = {
    id = id, owner = owner, generation = generation, challenger = "-", progress = 0,
    ver = 0, known = false, replyAt = nil,
  }
  self.states[id] = st
  return st
end

local function Copy(st)
  return {
    id = st.id, owner = st.owner, generation = st.generation, challenger = st.challenger,
    progress = st.progress, ver = st.ver, known = st.known,
  }
end

function Hunting:GetView(id)
  local st = self.states[id]
  return st and Copy(st) or nil
end

-- Moves the shared bar by one kill of `side`. Returns the event ("START" when a
-- faction starts attacking, "CAPTURED" at 100 %) and whether anything changed. A
-- defender's kill on a bar at rest changes nothing and is not shared.
local function Apply(st, side)
  if st.owner == side and st.challenger == "-" then return nil, false end
  local event = nil
  if st.owner == side or (st.challenger ~= "-" and st.challenger ~= side) then
    -- The owner defends, or on a neutral POI the other faction first has to
    -- bring the challenger back to 0 before building its own share.
    st.progress = st.progress - STEP
    if st.progress <= 0 then st.challenger, st.progress = "-", 0 end
  elseif st.challenger == "-" then
    st.challenger, st.progress = side, STEP
    event = "START"
  else
    st.progress = st.progress + STEP
    if st.progress >= 1000 then
      st.owner = side
      st.generation = st.generation + 1
      st.challenger, st.progress = "-", 0
      st.ver = 0
      return "CAPTURED", true
    end
  end
  st.ver = st.ver + 1
  return event, true
end

Hunting.Apply = Apply

-- (generation, version) order: higher wins, so a peer that saw more kills is adopted.
local function Newer(f, st)
  if f.generation ~= st.generation then return f.generation > st.generation end
  return f.ver > st.ver
end

local function Validate(f)
  if not f.generation or not f.progress or not f.ver then return false end
  if not OWNERS[f.owner] or not SIDES[f.challenger] then return false end
  if (f.owner == "N") ~= (f.generation == 0) or f.challenger == f.owner then return false end
  if (f.challenger == "-") ~= (f.progress == 0) then return false end
  -- Whole kills only; no modulo operator in Lua 5.0 and math.mod is absent from the test runtime.
  if f.progress >= 1000 or f.progress ~= Floor(f.progress / STEP) * STEP then return false end
  return true
end

function Hunting:Adopt(st, f, source)
  st.owner, st.generation = f.owner, f.generation
  st.challenger, st.progress, st.ver = f.challenger, f.progress, f.ver
  st.known, st.provisional = true, nil
  st.replyAt = nil
  self.dirty = true
  if FACTION_KEYS[f.owner] then Capture:MergeOwner(st.id, f.owner, f.generation, source) end
end

-- A promoted hint (decision 0038): the bar restarts at rest under the new owner,
-- provisional, so later kills of that generation apply on top of it.
function Hunting:OnPromoted(id, owner, generation)
  local st = self:GetState(id)
  if st.generation >= generation then return end
  st.owner, st.generation = owner, generation
  st.challenger, st.progress, st.ver = "-", 0, 0
  st.known, st.provisional = true, true
  st.replyAt = nil
  self.dirty = true
end

-- Remembers a kill GUID; false when the same kill was already counted.
function Hunting:Remember(guid, now)
  local at = self.seen[guid]
  if at and now - at < SEEN_TTL then return false end
  if not at then
    if self.seenCount >= MAX_SEEN then
      local key, value
      for key, value in pairs(self.seen) do
        if now - value >= SEEN_TTL then
          self.seen[key] = nil
          self.seenCount = self.seenCount - 1
        end
      end
      if self.seenCount >= MAX_SEEN then
        self.seen = {}
        self.seenCount = 0
      end
    end
    self.seenCount = self.seenCount + 1
  end
  self.seen[guid] = now
  return true
end

-- Applies one kill to the local state, then lets a peer that is ahead replace it.
-- The capturing kill: the killer's bar at rest, owned by its faction, one
-- generation above ours. Anything further is a capture we did not see.
local function Capturing(claimed, side, generation)
  return claimed.generation == generation + 1 and claimed.ver == 0 and claimed.owner == side
    and claimed.challenger == "-"
end

-- sender: the chat sender of a K, nil for a local kill.
function Hunting:Credit(id, side, guid, claimed, now, source, sender)
  local st = self:GetState(id)
  if claimed and claimed.generation > st.generation and not Capturing(claimed, side, st.generation) then
    -- A generation jump is only a hint (decision 0038): the bar does not move.
    self:Remember(guid, now)
    if sender and FACTION_KEYS[claimed.owner] then
      Capture:NoteHint(id, sender, claimed.owner, claimed.generation, now)
    end
    return nil, false
  end
  if not self:Remember(guid, now) then
    if claimed and Validate(claimed) and Newer(claimed, st) then self:Adopt(st, claimed, source) end
    return nil, false
  end
  local previousGeneration = st.generation
  local event, changed = nil, true
  if claimed and claimed.generation > st.generation then
    self:Adopt(st, claimed, source)
  else
    event, changed = Apply(st, side)
    if changed then self.dirty = true end
    st.known = true
    if claimed and Newer(claimed, st) then self:Adopt(st, claimed, source) end
  end
  if st.generation > previousGeneration then
    event = "CAPTURED"
    if FACTION_KEYS[st.owner] then Capture:MergeOwner(id, st.owner, st.generation, source) end
    Capture:ClearHints(id)
  end
  if event == "START" then
    Capture:HandleEvent(id, "START", side, now)
  elseif event == "CAPTURED" then
    Capture:HandleEvent(id, "CAPTURED", st.owner, now, st.generation)
  end
  return event, changed
end

-- Local kills ---------------------------------------------------------------------

-- Credit rule (decision 0026): the creature is listed by the hunting ground the
-- player stands in. Nothing else is checked: not the killer, not the creature position.
function Hunting:Qualify(guid, entry)
  local here = self.here
  if not here then return false, "not in a hunting ground" end
  local area = self:Area(here.id)
  if not area then return false, "hunting ground unavailable" end
  if not entry then return false, "not a creature" end
  if not RequiresMob(area, entry) then return false, "creature " .. entry .. " not required" end
  return true, "listed creature"
end

-- UNIT_DIED (nampower): arg1 is the GUID of the unit that died.
function Hunting:OnUnitDied(rawGuid)
  self.deaths = self.deaths + 1
  local guid, entry = ParseGuid(rawGuid)
  if not guid then return false end
  local ok, reason = self:Qualify(guid, entry)
  if self.here then self.last = { guid = guid, entry = entry, ok = ok, reason = reason } end
  if not ok then return false end
  -- A kill nobody could hear of must not move the local bar either.
  if not Capture:CanTalk() then
    self.last.ok, self.last.reason = false, Capture.LEVEL_REASON
    return false
  end
  local faction = Capture:MyFaction()
  if not faction then
    self.last.ok, self.last.reason = false, "faction unknown"
    return false
  end
  local id = self.here.id
  local now = Now()
  local event, changed = self:Credit(id, faction, guid, nil, now, "LOCAL")
  self.credited = self.credited + 1
  -- A defender's kill on a bar at rest changes nothing and is not shared.
  if changed then self:SendKill(self.states[id], faction, guid, event) end
  return true
end

function Hunting:SendKill(st, faction, guid, event)
  local sent = Capture:Send("K", st.id .. "," .. faction .. "," .. guid .. "," .. st.generation
    .. "," .. st.owner .. "," .. st.challenger .. "," .. Floor(st.progress) .. "," .. st.ver, nil, true)
  if sent then self.sent = self.sent + 1 end
  Record("HUNT_KILL", { id = st.id, side = faction, ver = st.ver, event = event })
end

function Hunting:SendState(st)
  return Capture:Send("H", st.id .. "," .. st.generation .. "," .. st.owner .. ","
    .. st.challenger .. "," .. Floor(st.progress) .. "," .. st.ver, "H," .. st.id)
end

-- Incoming messages ---------------------------------------------------------------

-- Fields shared by K and H once the state starts at `index`.
local function ParseClaim(parts, index)
  local f = {
    generation = Int(parts[index], 1000000),
    owner = parts[index + 1],
    challenger = parts[index + 2],
    progress = Int(parts[index + 3], 1000),
    ver = Int(parts[index + 4], MAX_VERSION),
  }
  if not Validate(f) then return nil end
  return f
end

-- parts: the fields after the event id, starting with the POI.
function Hunting:OnMessage(kind, parts, sender, now)
  local id = parts[1]
  if not self:Area(id) then return Capture:Reject("unknown hunting ground", sender) end
  local st = self:GetState(id)

  if kind == "HQ" then
    if table.getn(parts) ~= 1 then return Capture:Reject("bad HQ", sender) end
    -- A provisional bar came from a relay: never relayed again (decision 0038).
    if st.known and not st.provisional and not st.replyAt then
      Capture:ScheduleReply(st, now + REPLY_DELAY + math.random() * REPLY_SPREAD)
    end
    return true
  end

  if kind == "H" then
    if table.getn(parts) ~= 6 then return Capture:Reject("bad H", sender) end
    local f = ParseClaim(parts, 2)
    if not f then return Capture:Reject("bad H state", sender) end
    -- An H is always a relayed answer: a hint, never a confirmed owner nor an
    -- effect (decision 0038). Only the bar of the generation we hold moves.
    Capture:SeeReply(st, sender, f.owner == st.owner and f.generation == st.generation)
    if FACTION_KEYS[f.owner] then Capture:NoteHint(id, sender, f.owner, f.generation, now) end
    if f.generation == st.generation and f.owner == st.owner and (not st.known or Newer(f, st)) then
      local provisional = not st.known or st.provisional
      st.challenger, st.progress, st.ver = f.challenger, f.progress, f.ver
      st.known, st.provisional = true, provisional or nil
      self.dirty = true
    end
    return true
  end

  if table.getn(parts) ~= 8 then return Capture:Reject("bad K", sender) end
  local faction = parts[2]
  local guid = ParseGuid(parts[3])
  local f = ParseClaim(parts, 4)
  if not FACTION_KEYS[faction] or not guid or not f then return Capture:Reject("bad K", sender) end
  if f.generation < st.generation then return Capture:Reject("old generation", sender) end
  local generation = st.generation
  self:Credit(id, faction, guid, f, now, "PEER", sender)
  -- Only the capturing kill leaves the sender's bar at rest, owned by its
  -- faction, at version 0 (Apply); the H relay is never a witness, nor a
  -- generation jump kept as a hint (decision 0038).
  if f.ver == 0 and f.owner == faction and f.challenger == "-" and f.generation <= generation + 1
      and PC.Witness then
    PC.Witness:Note(sender, "CAPTURED", id, f.generation)
  end
  return true
end

-- Presence ------------------------------------------------------------------------

-- Any hunting ground shows the HUD; only one that lists creatures asks peers for its state.
function Hunting:OnPresenceChange(area)
  local ground = area and Capture:Capturable(area.id)
  if ground and ground.type == "HUNTING_GROUNDS" then
    local st = self:GetState(area.id)
    self.here = { id = area.id, enterAt = Now() }
    if self:Area(area.id) and not st.known then Capture:Send("HQ", area.id) end
  else
    self.here = nil
  end
end

-- Persistence and map --------------------------------------------------------------

-- Saved bars follow the registry: a bar from an older generation is dropped.
function Hunting:Restore(bucket)
  local saved = bucket.hunting
  if type(saved) ~= "table" then return end
  local id, entry
  for id, entry in pairs(saved) do
    local st = self.states[id]
    if type(entry) == "table" and self:Area(id) and not (st and st.known) then
      local owner, generation = Capture:GetOwner(id)
      local f = {
        owner = entry.owner, generation = tonumber(entry.generation),
        challenger = entry.challenger, progress = tonumber(entry.progress),
        ver = tonumber(entry.ver),
      }
      if f.owner == owner and f.generation == generation and Validate(f)
          and Floor(f.ver) == f.ver and f.ver >= 0 and f.ver <= MAX_VERSION then
        st = self:GetState(id)
        st.owner, st.generation = f.owner, f.generation
        st.challenger, st.progress, st.ver = f.challenger, f.progress, f.ver
        Record("HUNT_RESTORED", { id = id, progress = f.progress })
      end
    end
  end
end

function Hunting:Save(force)
  if not self.dirty and not force then return end
  local bucket = Capture:Bucket()
  if not bucket then return end
  local saved = {}
  local id, st
  for id, st in pairs(self.states) do
    if st.ver > 0 or st.challenger ~= "-" then
      saved[id] = {
        owner = st.owner, generation = st.generation, challenger = st.challenger,
        progress = Floor(st.progress), ver = st.ver,
      }
    end
  end
  bucket.hunting = saved
  self.dirty = false
end

function Hunting:UpdateMap()
  local map = PC.Map
  if not map or type(map.SetCaptureView) ~= "function" then return end
  local index = 1
  while index <= table.getn(map.order) do
    local id = map.order[index]
    if self:Area(id) then
      local owner = Capture:GetOwner(id)
      local st = self.states[id]
      local half = nil
      if st and st.owner == owner and st.challenger ~= "-" and st.progress >= 500 then
        half = FACTION_KEYS[st.challenger]
      end
      local hint = Capture:BestHint(id, Now())
      if hint then
        map:SetCaptureView(id, FACTION_KEYS[hint.owner], nil, true)
      else
        map:SetCaptureView(id, FACTION_KEYS[owner], half)
      end
    end
    index = index + 1
  end
end

function Hunting:Tick(now)
  local id, st
  for id, st in pairs(self.states) do
    if st.replyAt and now >= st.replyAt then
      st.replyAt = nil
      self:SendState(st)
    end
  end
  if not self.lastMapAt or now - self.lastMapAt >= MAP_INTERVAL then
    self.lastMapAt = now
    self:UpdateMap()
  end
  if self.dirty and (not self.lastSaveAt or now - self.lastSaveAt >= SAVE_INTERVAL) then
    self.lastSaveAt = now
    self:Save(false)
  end
end

-- Display -----------------------------------------------------------------------------

-- Fills the map tooltip fields of Capture:TooltipInfo: a percentage, never a kill count.
function Hunting:TooltipInfo(id, info)
  local st = self.states[id]
  if st and st.challenger ~= "-" then
    info.challenger = st.challenger
    info.percent = Floor(st.progress / 10)
  end
  info.here = self.here ~= nil and self.here.id == id
end

function Hunting:ModeText(view)
  local owner = FACTION_NAMES[view.owner]
  if view.challenger ~= "-" then
    return FACTION_NAMES[view.challenger] .. " " .. Floor(view.progress / 10) .. "%"
  end
  if view.owner == "N" then return "Neutral" end
  return "Controlled by " .. owner
end

-- UNIT_DIED comes from nampower. Any of its functions, or an event already seen, proves it.
local DLL_FUNCTIONS = { "GetNampowerVersion", "GetUnitGUID", "GetUnitField" }

-- Wider list for /pc hunt: nampower, VanillaHelpers and SuperWoW extensions.
local PROBE_FUNCTIONS = {
  "GetNampowerVersion", "GetUnitGUID", "GetUnitField", "GetSpellRecField", "GetCastInfo",
  "SetUnitBlip", "ReadFile", "WriteFile", "UnitXP", "SetAutoloot", "QueueSpellByName",
  "CombatLogFlush", "SpellInfo", "TrackUnit",
}

function Hunting:DllFunctions()
  local found = {}
  local index = 1
  while index <= table.getn(DLL_FUNCTIONS) do
    if type(GetGlobal(DLL_FUNCTIONS[index])) == "function" then table.insert(found, DLL_FUNCTIONS[index]) end
    index = index + 1
  end
  return found
end

function Hunting:CanDetectDeaths()
  return self.deaths > 0 or table.getn(self:DllFunctions()) > 0
end

-- Data for the HUD while the player stands in a hunting ground.
function Hunting:GetHud()
  local here = self.here
  if not here then return nil end
  local area = Capture:Capturable(here.id)
  if not area then return nil end
  local st = self:GetState(here.id)
  local view = Copy(st)
  view.mode = "H"
  local warning = nil
  if not Capture:CanTalk() then
    warning = "You cannot capture: " .. Capture.LEVEL_REASON
  elseif not self:Area(here.id) then
    warning = "No creature listed here: cannot be captured yet"
  elseif not self:CanDetectDeaths() then
    warning = "Enable NamPower in the Octo launcher"
  end
  return {
    hunting = true,
    id = here.id,
    area = area,
    view = view,
    -- Alone in the area nobody answers the state query: after a short wait the local state stands.
    known = st.known or not self:Area(here.id) or Now() - here.enterAt >= QUERY_WAIT,
    warning = warning,
  }
end

function Hunting:PrintStatus()
  local here = self.here
  PC.Print("hunt: " .. (here and ("in " .. here.id) or "not in a hunting ground")
    .. " nampower functions=" .. (table.getn(self:DllFunctions()) > 0
      and table.concat(self:DllFunctions(), "/") or "none")
    .. " UNIT_DIED registration=" .. tostring(PC.GetEventRegistration
      and PC.GetEventRegistration("UNIT_DIED") and PC.GetEventRegistration("UNIT_DIED").accepted)
    .. " deaths=" .. self.deaths .. " credited=" .. self.credited .. " sent=" .. self.sent)
  -- Extension probe: shows which DLL functions this client really exposes.
  local probe = ""
  local index = 1
  while index <= table.getn(PROBE_FUNCTIONS) do
    local name = PROBE_FUNCTIONS[index]
    probe = probe .. name .. "=" .. (type(GetGlobal(name)) == "function" and "yes" or "no") .. " "
    index = index + 1
  end
  PC.Print("hunt: probe " .. probe)
  local last = self.last
  if last then
    PC.Print("hunt: last death " .. tostring(last.guid) .. " entry=" .. tostring(last.entry)
      .. " credited=" .. tostring(last.ok) .. " (" .. tostring(last.reason) .. ")")
  end
  local shown = 0
  local id, st
  for id, st in pairs(self.states) do
    PC.Print(string.format("hunt: %s owner=%s gen=%d challenger=%s %d/%d ver=%d known=%s",
      id, st.owner, st.generation, st.challenger, Floor(st.progress / STEP), KILLS_REQUIRED,
      st.ver, tostring(st.known)))
    shown = shown + 1
  end
  if shown == 0 then PC.Print("hunt: no hunting ground state yet") end
end

-- Wiring ------------------------------------------------------------------------------

if PC.Presence and PC.Presence.OnChange then
  PC.Presence:OnChange(function(area)
    Hunting:OnPresenceChange(area)
  end)
end

if PC.RegisterEvent then
  PC.RegisterEvent("UNIT_DIED", function(eventName, guid)
    Hunting:OnUnitDied(guid)
  end)
  PC.RegisterEvent("PLAYER_LOGOUT", function()
    Hunting:Save(true)
  end)
end
