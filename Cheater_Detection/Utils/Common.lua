---@diagnostic disable: duplicate-set-field, undefined-field

--[[ Imports ]]
--
local Common = {
	Json = nil,
	PR = nil,
}

local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

Common.Json = require("Cheater_Detection.Libs.Json")
local G = require("Cheater_Detection.Utils.Globals")

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

local cachedSteamIDs = {}
local lastTick = -1

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
		local partyMembers = party.GetMembers()
		if partyMembers then
			for _, member in ipairs(partyMembers) do
				if member == playerInfo.SteamID then
					return true
				end
			end
		end
	end

	return false
end

function Common.GetSteamID(Player)
	assert(Player, "Player is nil")
	local playerIndex = Player:GetIndex()
	local playerInfo = client.GetPlayerInfo(playerIndex)
	return playerInfo and playerInfo.SteamID or "[U:1:0]"
end

function Common.GetSteamID64(Player)
	assert(Player, "Player is nil")

	local currentTick = globals.TickCount()
	local playerIndex = Player:GetIndex()

	-- Reset cache on new tick
	if lastTick ~= currentTick then
		cachedSteamIDs = {}
		lastTick = currentTick
	end

	-- Retrieve cached result or calculate it
	local result = cachedSteamIDs[playerIndex]
	if not result then
		local playerInfo = assert(client.GetPlayerInfo(playerIndex), "Failed to get player info")
		local steamID = assert(playerInfo.SteamID, "Failed to get SteamID")

		if playerInfo.IsBot or playerInfo.IsHLTV or steamID == "[U:1:0]" then
			result = "BOT_" .. tostring(playerInfo.UserID)
		else
			local converted = steam.ToSteamID64(steamID)
			result = tostring(assert(converted, "Failed to convert SteamID to SteamID64"))
		end
	end

	cachedSteamIDs[playerIndex] = result
	return result
end

function Common.IsBot(Player)
	if not Player then return false end
	local info = client.GetPlayerInfo(Player:GetIndex())
	return info and (info.IsBot or info.IsHLTV) or false
end

function Common.IsCheater(playerInfo)
	local steamId = nil

	if type(playerInfo) == "number" and playerInfo < 101 then
		-- Assuming playerInfo is the index
		local targetIndex = playerInfo
		local targetPlayer = nil

		-- Find the player with the same index
		for _, player in ipairs(G.players) do
			if player:GetIndex() == targetIndex then
				targetPlayer = player
				break
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

	-- Check if the player is marked as a cheater based on various criteria
	-- Use Evidence system instead of deprecated G.PlayerData.info fields
	local Evidence = require("Cheater_Detection.Core.Evidence_system")
	local isMarkedCheater = Evidence.IsMarkedCheater(steamId)
	local inDatabase = G.DataBase[steamId] ~= nil
	local priorityCheater = playerlist.GetPriority(steamId) == 10

	return isMarkedCheater or inDatabase or priorityCheater
end

---@param entity any
---@param checkFriend boolean?
---@param checkDormant boolean?
---@param skipEntity any? Optional entity to skip (e.g., the local player)
function Common.IsValidPlayer(entity, checkFriend, checkDormant, skipEntity)
	assert(entity, "Common.IsValidPlayer: entity missing")
	
	-- Simple validation checks
	if not entity:IsValid() then return false end
	if not entity:IsAlive() then return false end

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
	if not G.Menu.Advanced.debug and checkFriend ~= false and isFriend then
		return false
	end

	return true -- Entity is a valid player
end

-- Legacy shim; new code should use HistoryManager.Push directly
function Common.pushHistory(player)
	HistoryManager.Push(player)
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

	-- Handle SteamID2 format (STEAM_X:Y:Z)
	if raw:match("^STEAM_%d+:%d+:%d+$") then
		local ok, converted = pcall(steam.ToSteamID64, raw)
		return ok and tostring(converted) or nil
	end

	-- Ensure SteamID3 wrapped in brackets
	if not raw:match("^%[U:1:%d+%]$") then
		raw = string.format("[U:1:%s]", raw)
	end

	local ok, converted = pcall(steam.ToSteamID64, raw)
	return ok and tostring(converted) or nil
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

-- Cache frequently used engine functions for performance
local vectorDivide = vector.Divide
local vectorLength = vector.Length
local vectorDistance = vector.Distance

-- Clamp a value between min and max
function Common.clamp(value, minVal, maxVal)
	return math.max(minVal, math.min(maxVal, value))
end

-- 2D cross product for orientation testing
function Common.cross2D(a, b, c)
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end

-- Rotate local vector by angles (transform to world space)
function Common.vecRot(localVec, angles)
	return (angles:Forward() * localVec.x) + (angles:Right() * localVec.y) + (angles:Up() * localVec.z)
end

-- Linear interpolation between angles (handles wraparound)
function Common.lerpAngle(a, b, t)
	local diff = (b - a + 180) % 360 - 180
	return a + diff * t
end

-- Linear interpolation between vectors
function Common.lerpVector(startVector, endVector, interpolationFactor)
	return startVector + (endVector - startVector) * interpolationFactor
end

-- Convert velocity vector to angles
function Common.velocityToAngles(vel)
	local speed = vel:Length()
	if speed < 0.001 then
		return EulerAngles(0, 0, 0)
	end

	-- Fixed pitch calculation for proper velocity-to-angle conversion
	local pitch = -math.deg(math.asin(vel.z / speed))
	local yaw = math.deg(math.atan(vel.y, vel.x))

	return EulerAngles(pitch, yaw, 0)
end

-- Alternative velocity to angles (more robust for edge cases)
function Common.velocityToAnglesRobust(vel)
	local speed = vel:Length()
	if speed < 0.001 then
		return EulerAngles(0, 0, 0)
	end

	local pitch = math.deg(math.atan(vel.z, math.sqrt(vel.x * vel.x + vel.y * vel.y)))
	local yaw = math.deg(math.atan(vel.y, vel.x))

	return EulerAngles(pitch, yaw, 0)
end

-- Check if plane normal faces downward (for ground detection)
function Common.surfaceFacesDown(plane, threshold)
	return plane.z < -threshold
end

-- Vector normalization with safety check
function Common.normalize(vec)
	return vectorDivide(vec, vectorLength(vec))
end

-- Dot product wrapper
function Common.dot(a, b)
	return a:Dot(b)
end

-- Cross product wrapper
function Common.cross(a, b)
	return a:Cross(b)
end

-- Get 2D length of vector
function Common.length2D(vec)
	return vec:Length2D()
end

-- Calculate 2D distance between vectors
function Common.distance2D(a, b)
	return (a - b):Length2D()
end

-- Calculate 3D distance between vectors
function Common.distance3D(a, b)
	return vectorDistance(a, b)
end

-- Get angles from vector direction
function Common.anglesFromVector(vec)
	return vec:Angles()
end

-- Check if trace result hit something
function Common.TraceHit(result)
	return result.fraction ~= 1
end

local lastFrameTick = 0
local FRAME_GAP_THRESHOLD = 6

function Common.IsFrameGap()
	local currentTick = globals.TickCount()
	local gap = currentTick - lastFrameTick
	lastFrameTick = currentTick
	return gap > FRAME_GAP_THRESHOLD
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

--[[ Registrations and final actions ]]
--
local function OnUnload()
	pcall(engine.PlaySound, "hl1/fvox/deactivated.wav")
end

-- Unregister previous callbacks
callbacks.Unregister("Unload", "CD_Unload") -- unregister the "Unload" callback

-- Register callbacks
callbacks.Register("Unload", "CD_Unload", OnUnload) -- Register the "Unload" callback

-- Play sound when loaded
engine.PlaySound("hl1/fvox/activated.wav")

return Common
