PandaConquest = PandaConquest or {}

local PC = PandaConquest

-- Mixed addon versions on the channel (decision 0029). Every PC<n> line carries
-- the sender's addon version right after "PC<n>:", whatever n is, so any build
-- learns that a newer one exists. A claimed version is unverified P2P data: it
-- only ever produces a warning, never a capture decision.
local Version = {
  -- A newer version seen once is recalled at login for this long.
  REMEMBER_SECONDS = 7 * 24 * 3600,
  -- A reply to an older announce waits 1 to 5 s and is cancelled when a peer at
  -- least as new answers first (rule R14); at most one per REPLY_GAP seconds.
  REPLY_DELAY = 1,
  REPLY_SPREAD = 4,
  REPLY_GAP = 60,
  newest = nil,
  newestLevel = nil,
  warnedFor = nil,
  replyAt = nil,
  lastAnnounceAt = nil,
  lastReplyAt = nil,
  announced = 0,
  replies = 0,
  suppressed = 0,
}

PC.Version = Version

local frame

local function Parts(text)
  if type(text) ~= "string" or string.len(text) > 11 then return nil end
  local _, _, a, b, c = string.find(text, "^(%d+)%.(%d+)%.(%d+)$")
  if not a or string.len(a) > 3 or string.len(b) > 3 or string.len(c) > 3 then return nil end
  return tonumber(a), tonumber(b), tonumber(c)
end

function Version.Valid(text)
  return Parts(text) ~= nil
end

-- > 0 when a is newer than b, 0 when equal, < 0 when older; nil if either is invalid.
function Version.Compare(a, b)
  local a1, a2, a3 = Parts(a)
  local b1, b2, b3 = Parts(b)
  if not a1 or not b1 then return nil end
  if a1 ~= b1 then return a1 - b1 end
  if a2 ~= b2 then return a2 - b2 end
  return a3 - b3
end

local function DB()
  local storage = PC.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  return db
end

-- True when the newest known build speaks a higher PC<n>: this client's lines
-- are then ignored by it, and its captures are not shared with those players.
function Version:Incompatible()
  return self.newestLevel ~= nil and self.newestLevel > (PC.channelLevel or 0)
end

function Version:Text()
  if not self.newest then return nil end
  if self:Incompatible() then
    return "pandaConquest " .. tostring(PC.version) .. " is outdated: players on " .. self.newest
      .. " no longer see your captures. Update the addon."
  end
  return "pandaConquest " .. tostring(PC.version) .. " is outdated: version " .. self.newest
    .. " is available. Please update."
end

-- Short line for the capture HUD.
function Version:Notice()
  if not self.newest then return nil end
  if self:Incompatible() then return "Addon outdated: captures not shared. Update to " .. self.newest end
  return "Addon outdated: update to " .. self.newest
end

function Version:Warn()
  if not self.newest or self.warnedFor == self.newest then return end
  self.warnedFor = self.newest
  if PC.Print then PC.Print("|cffff4040" .. self:Text() .. "|r") end
  if PC.Record then PC.Record("VERSION_OUTDATED", { newest = self.newest, level = self.newestLevel }) end
end

-- Called for every readable PC<n> line, valid or not, whatever its level.
function Version:Note(remote, level)
  local newer = Version.Compare(remote, PC.version)
  if not newer or newer <= 0 or type(level) ~= "number" then return false end
  if self.newest and Version.Compare(remote, self.newest) <= 0 then return false end
  self.newest, self.newestLevel = remote, level
  local db = DB()
  if db then db.newestVersion = { version = remote, level = level, seenAt = PC.Epoch and PC.Epoch() or 0 } end
  self:Warn()
  return true
end

-- At login: recall a newer version seen recently, forget it once installed or stale.
function Version:Restore()
  if self.restored then return end
  self.restored = true
  local db = DB()
  local saved = db and db.newestVersion
  if type(saved) ~= "table" then return end
  local age = (PC.Epoch and PC.Epoch() or 0) - (tonumber(saved.seenAt) or 0)
  local newer = Version.Compare(saved.version, PC.version)
  local level = tonumber(saved.level)
  if not newer or newer <= 0 or not level or age < 0 or age > self.REMEMBER_SECONDS then
    db.newestVersion = nil
    return
  end
  if not self.newest or Version.Compare(saved.version, self.newest) > 0 then
    self.newest, self.newestLevel = saved.version, level
  end
  self:Warn()
end

local function Send(flag)
  local p2p = PC.P2PTest
  if not p2p or type(p2p.SendVersion) ~= "function" then return false end
  local ok, accepted = pcall(p2p.SendVersion, flag)
  return ok and accepted
end

-- One V,A per channel join (login, /reload, rejoin), at most once per REPLY_GAP.
function Version:Announce(now)
  now = now or PC.Now()
  if self.lastAnnounceAt and now - self.lastAnnounceAt < self.REPLY_GAP then return false end
  if not Send("A") then return false end
  self.lastAnnounceAt = now
  self.announced = self.announced + 1
  return true
end

local function OnUpdate()
  Version:Tick(PC.Now())
end

function Version:Tick(now)
  if not self.replyAt or now < self.replyAt then return end
  self.replyAt = nil
  if frame then frame:SetScript("OnUpdate", nil) end
  if self.lastReplyAt and now - self.lastReplyAt < self.REPLY_GAP then return end
  if Send("R") then
    self.lastReplyAt = now
    self.replies = self.replies + 1
  end
end

-- V from another player; the caller has already ignored our own echo. flag A is
-- an announce at join, R a reply. A peer at least as new as us answering first
-- cancels our pending reply, so one older announce draws about one reply.
function Version:OnAnnounce(remote, flag, now)
  if flag ~= "A" and flag ~= "R" then return false end
  local order = Version.Compare(remote, PC.version)
  if not order then return false end
  now = now or PC.Now()
  if order >= 0 then
    if self.replyAt then
      self.replyAt = nil
      self.suppressed = self.suppressed + 1
      if frame then frame:SetScript("OnUpdate", nil) end
    end
    return true
  end
  if flag == "A" and not self.replyAt then
    if self.lastReplyAt and now - self.lastReplyAt < self.REPLY_GAP then return true end
    self.replyAt = now + self.REPLY_DELAY + math.random() * self.REPLY_SPREAD
    if frame then frame:SetScript("OnUpdate", OnUpdate) end
  end
  return true
end

function Version:Summary()
  return "version " .. tostring(PC.version) .. " level " .. tostring(PC.channelLevel)
    .. " newest=" .. tostring(self.newest or "-") .. " announced=" .. self.announced
    .. " replies=" .. self.replies .. " suppressed=" .. self.suppressed
end

if CreateFrame then
  frame = CreateFrame("Frame", "PandaConquestVersionFrame", UIParent)
  frame:SetScript("OnUpdate", nil)
end

if PC.RegisterEvent then
  PC.RegisterEvent("PLAYER_ENTERING_WORLD", function() Version:Restore() end)
end
