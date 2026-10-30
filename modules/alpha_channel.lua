local PC = PandaConquest

-- Alpha player channel: every addon user joins pConquestTest so the team can
-- talk to testers, and the channel is shown in the first chat tab. Plain chat
-- only, unrelated to the PandaConquest P2P channel. Remove after the alpha.
PC.AlphaChannel = PC.AlphaChannel or {}
local Alpha = PC.AlphaChannel

local CHANNEL_NAME = "pConquestTest"
local INITIAL_DELAY_SECONDS = 8 -- after the P2P channel's first join (5 s)
local RETRY_SECONDS = 5
local MAX_ATTEMPTS = 6

local state = { attempts = 0, done = false, nextAt = nil }
local frame = CreateFrame("Frame", "PandaConquestAlphaChannelFrame", UIParent)

local function FindChannel()
  if type(GetChannelList) ~= "function" then return nil end
  local values = { pcall(GetChannelList) }
  if not values[1] then return nil end
  local expected = string.lower(CHANNEL_NAME)
  local i
  for i = 2, table.getn(values), 2 do
    local name = values[i + 1]
    if type(name) == "string" and string.lower(name) == expected then return name end
  end
  return nil
end

local function FrameListsChannel(chatFrame, name)
  if not chatFrame or type(chatFrame.channelList) ~= "table" then return false end
  local expected = string.lower(name)
  local _, value
  for _, value in pairs(chatFrame.channelList) do
    if type(value) == "string" and string.lower(value) == expected then return true end
  end
  return false
end

-- Once per session: a player who removes the channel from the tab keeps that
-- choice until the next login.
local function ShowInFirstTab(name)
  if not ChatFrame1 or type(ChatFrame_AddChannel) ~= "function" then return end
  if FrameListsChannel(ChatFrame1, name) then return end
  local ok, err = pcall(ChatFrame_AddChannel, ChatFrame1, name)
  if not ok and PC.RecordError then PC.RecordError("alpha channel display", err) end
end

local function Tick()
  if state.done then return end
  local now = PC.Now()
  if not state.nextAt then state.nextAt = now + INITIAL_DELAY_SECONDS end
  if now < state.nextAt then return end

  local joined = FindChannel()
  if joined then
    ShowInFirstTab(joined)
    state.done = true
    frame:SetScript("OnUpdate", nil)
    return
  end
  if state.attempts >= MAX_ATTEMPTS then
    state.done = true
    frame:SetScript("OnUpdate", nil)
    PC.Print("could not join the alpha channel; type /join " .. CHANNEL_NAME)
    return
  end
  state.attempts = state.attempts + 1
  state.nextAt = now + RETRY_SECONDS
  if type(JoinChannelByName) == "function" then
    -- Same call as FrameXML's /join: the frame id ties the channel to tab 1.
    local ok, err = pcall(JoinChannelByName, CHANNEL_NAME, nil, 1)
    if not ok and PC.RecordError then PC.RecordError("alpha channel join", err) end
  end
end

function Alpha:Status()
  return FindChannel(), state.attempts, state.done
end

frame:SetScript("OnUpdate", Tick)
