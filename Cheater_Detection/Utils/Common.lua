---@diagnostic disable: duplicate-set-field, undefined-field

--[[ Imports ]]
--
local Common = {
	Lib = nil,
	Json = nil,
	Log = nil,
	Notify = nil,
	TF2 = nil,
	Math = nil,
	Conversion = nil,
	WPlayer = nil,
	PR = nil,
	Helpers = nil,
}

local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

-- Move requires here
Common.Json = require("Cheater_Detection.Libs.Json")
local G = require("Cheater_Detection.Utils.Globals")

if UnloadLib ~= nil then
	UnloadLib()
end

--------------------------------------------------------------------------------------
--Library loading--
--------------------------------------------------------------------------------------

--Function to download content from a URL
-- REMOVED: Security risk (Remote Code Execution)
-- The library must be installed locally.

-- Load and validate library
local function loadlib()
	local success, localLib = pcall(require, "lnxLib")
	if success and localLib then
		return localLib
	end

	-- Fallback: Check if it's in the Libs folder
	local success2, localLib2 = pcall(require, "Cheater_Detection.Libs.lnxLib")
	if success2 and localLib2 then
		return localLib2
	end

	error("Critical Error: lnxLib not found! Please install it or ensure it is in the Libs folder.")
end

local lnxLib = loadlib()

if not lnxLib then
	error("Failed to load lnxLib")
end

Common.Lib = lnxLib

-- Now initialize remaining Common fields using the loaded libraries
Common.Log = Common.Lib.Utils.Logger.new("Cheater Detection")
Common.Notify = Common.Lib.UI.Notify
Common.TF2 = Common.Lib.TF2
Common.Math = Common.Lib.Utils.Math
Common.Conversion = Common.Lib.Utils.Conversion
Common.WPlayer = Common.TF2.WPlayer
Common.PR = Common.Lib.TF2.PlayerResource
Common.Helpers = Common.Lib.TF2.Helpers

-- Now using WrappedPlayer module instead of monkey patching

local cachedSteamIDs = {}
local lastTick = -1

function Common.IsFriend(entity)
	return (not G.Menu.Main.debug and Common.TF2.IsFriend(entity:GetIndex(), true)) -- Entity is a freind and party member
end

function Common.GetSteamID64(Player)
	assert(Player, "Player is nil")

	local currentTick = globals.TickCount()
	local playerIndex = Player:GetIndex()

	-- Reset cache on new tick (simple conditional is better than "branchless")
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
			result = playerInfo.UserID
		else
			local converted = steam.ToSteamID64(steamID)
			result = assert(converted, "Failed to convert SteamID to SteamID64")
		end
	end

	cachedSteamIDs[playerIndex] = result
	return result
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

---@param entity Entity
---@param checkFriend boolean?
---@param checkDormant boolean?
---@param skipEntity Entity? Optional entity to skip (e.g., the local player)
function Common.IsValidPlayer(entity, checkFriend, checkDormant, skipEntity)
	-- Simple validation checks
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return false
	end

	-- Check dormancy (default is to reject dormant unless explicitly false)
	if checkDormant ~= false and entity:IsDormant() then
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
	if not G.Menu.Advanced.debug and checkFriend ~= false and Common.IsFriend(entity) then
		return false
	end

	return true -- Entity is a valid player
end

-- Create a common record structure
function Common.createRecord(angle, position, headHitbox, bodyHitbox, simTime, onGround)
	return {
		Angle = angle,
		ViewPos = position,
		Hitboxes = {
			Head = headHitbox,
			Body = bodyHitbox,
		},
		SimTime = simTime,
		onGround = onGround,
	}
end

-- Maximum number of historical snapshots to keep per player
Common.MAX_HISTORY = 66

-- Convenience: build a record directly from a player wrapper/entity
---@param player table|Entity WrappedPlayer or entity implementing required methods
---@return table|nil record
function Common.createRecordFromPlayer(player)
	if not player or type(player.GetEyeAngles) ~= "function" then
		return nil
	end

	return Common.createRecord(
		player:GetEyeAngles(),
		player:GetEyePos(),
		player:GetHitboxPos(1), -- Head
		player:GetHitboxPos(4), -- Body
		player:GetSimulationTime(),
		player:IsOnGround()
	)
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

-- Safe integer rounding function for drawing coordinates
Common.RoundCoord = function(value)
	if not value then
		return 0
	end

	if type(value) ~= "number" then
		return 0
	end

	-- Check for NaN and infinity
	if value ~= value or value == math.huge or value == -math.huge then
		return 0
	end

	return math.floor(value + 0.5)
end

local E_Flows = { FLOW_OUTGOING = 0, FLOW_INCOMING = 1, MAX_FLOWS = 2 }

function Common.CheckConnectionState()
	local netChannel = clientstate.GetNetChannel()
	if not netChannel then
		return { stable = false, reason = "No NetChannel" }
	end

	-- Check for timeout
	if netChannel:IsTimingOut() then
		return { stable = false, reason = "Timing out" }
	end

	-- If we're just playing a demo, consider connection perfectly stable and skip further checks
	if netChannel:IsPlayback() then
		return { stable = true, reason = "Demo" }
	end

	-- Check latency, choke, and loss (incoming) — only for real servers
	local latency = netChannel:GetAvgLatency(E_Flows.FLOW_INCOMING)
	local choke = netChannel:GetAvgChoke(E_Flows.FLOW_INCOMING)
	local loss = netChannel:GetAvgLoss(E_Flows.FLOW_INCOMING)
	-- Thresholds: adjust as needed
	if latency > 0.5 then
		return { stable = false, reason = string.format("High latency: %.2f", latency) }
	end
	if choke > 0.2 then
		return { stable = false, reason = string.format("High choke: %.2f", choke) }
	end
	if loss > 0.1 then
		return { stable = false, reason = string.format("High loss: %.2f", loss) }
	end

	return { stable = true }
end

--[[ Registrations and final actions ]]
--
local function OnUnload() -- Called when the script is unloaded
	if UnloadLib then
		pcall(UnloadLib) --unloading lualib safely
	end
	pcall(engine.PlaySound, "hl1/fvox/deactivated.wav") --deactivated safely
end

-- Unregister previous callbacks
callbacks.Unregister("Unload", "CD_Unload") -- unregister the "Unload" callback

-- Register callbacks
callbacks.Register("Unload", "CD_Unload", OnUnload) -- Register the "Unload" callback

-- Play sound when loaded
engine.PlaySound("hl1/fvox/activated.wav")

return Common
