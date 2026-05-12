---@diagnostic disable: duplicate-set-field, undefined-field

--[[ Common.lua usage
     - Use Utils/MathUtils for all math/geometry primitives (angle wrap, angular distance, angle-to-pos, lerp, normalize, etc.)
     - Use Common for non-math shared utilities (SteamID handling, menu/debug helpers, player validation, network stability gates, etc.)
     - Avoid duplicating helpers in detectors/actions; import the utility module and alias hot functions to locals.
]]

--[[ Imports ]]
--
local Common = {
	Json = nil,
	PR = nil,
}

Common.Json = require("Cheater_Detection.Libs.Json")
local G = require("Cheater_Detection.Utils.Globals")
local Constants = require("Cheater_Detection.Core.constants")
local TickEntityCache = require("Cheater_Detection.Utils.TickEntityCache")

--[[ Inlined PlayerResource (from lnxLib/TF2/PlayerResource.lua) ]]
local PlayerResource = {}

function PlayerResource.GetScore()
	return entities.GetPlayerResources():GetPropDataTableInt("m_iScore")
end

function PlayerResource.GetDeaths()
	return entities.GetPlayerResources():GetPropDataTableInt("m_iDeaths")
end

function PlayerResource.GetConnected()
	return entities.GetPlayerResources():GetPropDataTableBool("m_bConnected")
end

function PlayerResource.GetTeam()
	return entities.GetPlayerResources():GetPropDataTableInt("m_iTeam")
end

function PlayerResource.GetAlive()
	return entities.GetPlayerResources():GetPropDataTableBool("m_bAlive")
end

function PlayerResource.GetHealth()
	return entities.GetPlayerResources():GetPropDataTableInt("m_iHealth")
end

function PlayerResource.GetPlayerClass()
	return entities.GetPlayerResources():GetPropDataTableInt("m_iPlayerClass")
end

function PlayerResource.GetTotalScore()
	return entities.GetPlayerResources():GetPropDataTableInt("m_iTotalScore")
end

function PlayerResource.GetMaxHealth()
	return entities.GetPlayerResources():GetPropDataTableInt("m_iMaxHealth")
end

function PlayerResource.GetDamage()
	return entities.GetPlayerResources():GetPropDataTableInt("m_iDamage")
end

Common.PR = PlayerResource

local cachedSteamID64Value = {}
local cachedSteamID64Tick = {}
local localSteamFallbackWarnTick = 0

local STEAM64_BASE = 76561197960265728

local partyCacheTick = -1
local partyMemberSet = {}

local function refreshPartyMemberSet()
	local currentTick = globals.TickCount()
	if partyCacheTick == currentTick then
		return
	end
	partyCacheTick = currentTick

	for k in pairs(partyMemberSet) do
		partyMemberSet[k] = nil
	end

	local partyMembers = party.GetMembers()
	if not partyMembers then
		return
	end
	for i = 1, #partyMembers do
		partyMemberSet[partyMembers[i]] = true
	end
end

local function convertSteamStringTo64(rawSteamID)
	if not rawSteamID then
		return nil
	end

	local idStr = tostring(rawSteamID)
	if idStr == "" then
		return nil
	end

	local steam64 = idStr:match("^(765%d+)$")
	if steam64 and #steam64 >= 17 then
		return steam64
	end

	local accountID = idStr:match("^%[U:1:(%d+)%]$")
	if accountID then
		local numericAccountID = tonumber(accountID)
		if numericAccountID then
			return tostring(STEAM64_BASE + numericAccountID)
		end
	end

	local steam2Universe, steam2Y, steam2Z = idStr:match("^STEAM_(%d+):(%d+):(%d+)$")
	if steam2Universe and steam2Y and steam2Z then
		local z = tonumber(steam2Z)
		local y = tonumber(steam2Y)
		if z and y then
			local accountFromSteam2 = z * 2 + y
			return tostring(STEAM64_BASE + accountFromSteam2)
		end
	end

	if steam and steam.ToSteamID64 then
		local converted = steam.ToSteamID64(idStr)
		local convertedString = tostring(converted):match("(765%d+)")
		if convertedString and #convertedString >= 17 then
			return convertedString
		end
	end

	return nil
end

--- Returns true when debug mode is active in the menu (eliminates repeated inline checks).
---@return boolean
function Common.IsDebugEnabled()
	return G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true or false
end

--[[ Inlined IsFriend (from lnxLib/TF2/TF2.lua) ]]
function Common.IsFriend(entity, includeParty)
	if includeParty == nil then
		includeParty = true
	end
	local idx = entity:GetIndex()
	if idx == client.GetLocalPlayerIndex() then
		return true
	end

	local playerInfo = client.GetPlayerInfo(idx)
	if not playerInfo then
		return false
	end
	if steam.IsFriend(playerInfo.SteamID) then
		return true
	end
	if playerlist.GetPriority(playerInfo.UserID) < 0 then
		return true
	end

	if includeParty then
		refreshPartyMemberSet()
		return partyMemberSet[playerInfo.SteamID] == true
	end

	return false
end

function Common.GetSteamID(Player)
	if not Player then
		return "[U:1:0]"
	end
	local playerIndex = Player:GetIndex()
	local playerInfo = client.GetPlayerInfo(playerIndex)
	return playerInfo and playerInfo.SteamID or "[U:1:0]"
end

function Common.GetSteamID64(Player)
	if not Player then
		return nil
	end

	local currentTick = globals.TickCount()
	local playerIndex = Player and Player:GetIndex()
	if not playerIndex or playerIndex < 1 or playerIndex > 100 then
		return nil
	end

	if cachedSteamID64Tick[playerIndex] == currentTick then
		return cachedSteamID64Value[playerIndex]
	end

	local result = nil
	local playerInfo = client.GetPlayerInfo(playerIndex)
	if playerInfo then
		local steamID = playerInfo.SteamID
		if playerInfo.IsBot or playerInfo.IsHLTV or steamID == "[U:1:0]" then
			result = "BOT_" .. tostring(playerInfo.UserID or playerIndex)
		elseif steamID then
			result = convertSteamStringTo64(steamID)
		end
	end

	if not result and playerIndex == client.GetLocalPlayerIndex() then
		result = "LOCAL_" .. tostring(playerIndex)
		if (currentTick - localSteamFallbackWarnTick) >= 300 then
			localSteamFallbackWarnTick = currentTick
			print(string.format("[Common][WARN] Local SteamID64 unavailable, using fallback id=%s", result))
		end
	end

	cachedSteamID64Tick[playerIndex] = currentTick
	cachedSteamID64Value[playerIndex] = result
	return result
end

-- Check if player is a runtime bot (engine-reported)
function Common.IsBot(Player)
	if not Player then
		return false
	end
	local info = client.GetPlayerInfo(Player:GetIndex())
	return info and (info.IsBot or info.IsHLTV) or false
end

-- Check if player is a bot from bot lists (has BOT flag in database)
function Common.IsDatabaseBot(steamId)
	if not steamId or type(steamId) ~= "string" then
		return false
	end
	-- Runtime bots (BOT_ prefix from GetSteamID64)
	if steamId:sub(1, 4) == "BOT_" then
		return true
	end
	-- Database bots (from embedded bot lists)
	local entry = G.DataBase and G.DataBase[steamId] or nil
	if type(entry) == "table" then
		local flags = tonumber(entry.Flags or 0) or 0
		return (flags & Constants.Flags.BOT) ~= 0
	end
	return false
end

function Common.IsCheater(playerInfo)
	local steamId = nil

	if type(playerInfo) == "number" and playerInfo < 101 then
		-- playerInfo is a player index; resolve to SteamID64 via entity
		local ent = TickEntityCache.GetPlayerByIndex(playerInfo)
		if ent then
			steamId = Common.GetSteamID64(ent)
			if type(steamId) ~= "string" then
				steamId = nil
			end
		end
	elseif type(playerInfo) == "string" then
		-- playerInfo is a SteamID64 string
		steamId = playerInfo
	elseif type(playerInfo) == "table" then
		-- playerInfo is a playerInfo table
		if playerInfo.SteamID then
			steamId = steam.ToSteamID64(playerInfo.SteamID)
		end
	end

	if not steamId then
		return false
	end

	-- Check if the player is marked as a cheater based on flags.
	-- Karma/retaliation-only rows must not count as cheater status.
	-- Bots with BOT flag are also considered "cheaters" for votekick purposes
	-- (this allows "kick cheaters" setting to also kick bots)
	local inDatabase = false
	local entry = G.DataBase and G.DataBase[steamId] or nil
	if type(entry) == "table" then
		local flags = tonumber(entry.Flags or 0) or 0
		local cheaterMask = Constants.Flags.CHEATER | Constants.Flags.SUSPICIOUS | Constants.Flags.VAC_BANNED |
			Constants.Flags.COMM_BANNED | Constants.Flags.BOT
		inDatabase = (flags & cheaterMask) ~= 0
	end
	local PRIORITY_CHEATER = 10
	local priorityCheater = playerlist.GetPriority(steamId) == PRIORITY_CHEATER

	return inDatabase or priorityCheater
end

---@param entity any
---@param checkFriend boolean?
---@param checkDormant boolean?
---@param skipEntity any? Optional entity to skip (e.g., the local player)
function Common.IsValidPlayer(entity, checkFriend, checkDormant, skipEntity)
	if not entity then
		return false
	end

	-- Simple validation checks
	if not entity:IsValid() then
		return false
	end
	if not entity:IsAlive() then
		return false
	end

	-- Check dormancy (default is to reject dormant unless explicitly false)
	local isDormant = entity:IsDormant()
	if checkDormant ~= false and isDormant then
		return false
	end

	-- Reject spectators/unassigned
	local team = entity:GetTeamNumber()
	if team == TEAM_SPECTATOR or team == TEAM_UNASSIGNED then
		return false
	end

	-- Skip specific entity if requested
	if skipEntity and entity == skipEntity then
		return false
	end

	-- Skip friends (default behavior unless debug enabled or explicitly disabled)
	local isFriend = Common.IsFriend(entity)
	if not Common.IsDebugEnabled() and checkFriend ~= false and isFriend then
		return false
	end

	return true -- Entity is a valid player
end

function Common.FromSteamid3To64(steamid3)
	if not steamid3 then
		return nil
	end

	local raw = tostring(steamid3)
	if raw == "" then
		return nil
	end

	-- Already SteamID64
	if raw:match("^7656119%d+$") then
		return raw
	end

	if raw:match("^STEAM_%d+:%d+:%d+$") or raw:match("^%[U:1:%d+%]$") then
		return convertSteamStringTo64(raw)
	end

	local wrappedSteam3 = string.format("[U:1:%s]", raw)
	return convertSteamStringTo64(wrappedSteam3)
end

function Common.IsSteamID64(steamID)
	if not steamID then
		return false
	end
	steamID = tostring(steamID)
	return steamID:match("^7656119%d+$") and #steamID == 17
end

-- Helper function to determine if the content is JSON
function Common.isJson(content)
	local firstChar = content:sub(1, 1)
	return firstChar == "{" or firstChar == "["
end

local WORLD2SCREEN = client.WorldToScreen

function Common.worldToScreenXY(pos)
	local screenPos = WORLD2SCREEN(pos)
	if screenPos then
		return screenPos[1], screenPos[2]
	end
	return nil, nil
end

function Common.TraceHit(result)
	return result.fraction ~= 1
end

local lastFrameTick = 0
-- Frame-gap threshold: ~0.091 s (≈6 ticks at 66 Hz), recomputed dynamically for the tick rate.
local function getFrameGapThreshold()
	return math.floor(6.0 / 66.0 / globals.TickInterval() + 0.5)
end
local lastFrameTime = 0

function Common.IsFrameGap()
	local currentTick = globals.TickCount()
	local gap = currentTick - lastFrameTick
	lastFrameTick = currentTick

	-- Performance/FPS validation: If FPS is lower than tickrate, simtime is unreliable
	local currentTime = globals.RealTime()
	local frameTime = currentTime - lastFrameTime
	lastFrameTime = currentTime

	local fps = 1 / frameTime
	local tickInterval = globals.TickInterval()
	local tickRate = 1 / tickInterval
	if fps < tickRate then
		return true
	end

	return gap > getFrameGapThreshold()
end

local E_Flows = { FLOW_OUTGOING = 0, FLOW_INCOMING = 1, MAX_FLOWS = 2 }

function Common.CheckConnectionState()
	local netChannel = clientstate.GetNetChannel()
	if not netChannel then
		return false, "No NetChannel"
	end

	if netChannel:IsTimingOut() then
		return false, "Timing out"
	end

	if netChannel:IsPlayback() then
		return true, "Demo"
	end

	local latency = netChannel:GetAvgLatency(E_Flows.FLOW_INCOMING)
	local choke = netChannel:GetAvgChoke(E_Flows.FLOW_INCOMING)
	local loss = netChannel:GetAvgLoss(E_Flows.FLOW_INCOMING)

	if latency > 0.5 then
		return false
	end
	if choke > 0.2 then
		return false
	end
	if loss > 0.1 then
		return false
	end

	return true
end

-- Returns true when the local connection is stable enough to trust
-- simulation-time-based detectors (WarpDT, FakeLag).
--
-- Rules (per spec):
--   • FPS below server tick rate → engine can't process every packet → unreliable
--   • Incoming avg latency > 2 tick intervals → our view of remote sim times is too stale
--   • Any incoming packet loss > 1%
--   • Any outgoing choke > 0 → our end is queuing packets → timing is off
function Common.IsConnectionStableForDetection()
	local tickInterval = globals.TickInterval()
	local tickRate = 1.0 / tickInterval

	-- FPS gate: must be able to process at tick frequency
	local fps = 1.0 / globals.FrameTime()
	if fps < tickRate then
		return false
	end

	local netChannel = clientstate.GetNetChannel()
	if not netChannel then
		return false
	end

	-- Latency threshold: ~180 ms (≈12 ticks at 66 Hz).
	-- Latency is measured in seconds; compare directly against the equivalent time value.
	local latency = netChannel:GetAvgLatency(E_Flows.FLOW_INCOMING)
	local maxLatency = tickInterval * 12.0
	if latency > maxLatency then
		return false
	end

	-- Any packet loss means we are missing data; deltas are unreliable
	local loss = netChannel:GetAvgLoss(E_Flows.FLOW_INCOMING)
	if loss > 0.01 then
		return false
	end

	-- Any outgoing choke means our updates are stacking up
	local choke = netChannel:GetAvgChoke(E_Flows.FLOW_OUTGOING)
	if choke > 0 then
		return false
	end

	return true
end

return Common
