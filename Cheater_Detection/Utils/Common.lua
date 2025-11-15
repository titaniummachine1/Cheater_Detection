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
local function downloadFile(url)
	local success, body = pcall(http.Get, url)
	if not success or not body or body == "" then
		error("Failed to download file from " .. url .. ": " .. tostring(body))
	end
	return body
end

-- Load and validate library
local function loadlib(libName, libURL)
	local lnxLib = nil
	if libName == "lnxLib" then
		-- First try to load local LNXlib if it exists
		local success, localLib = pcall(require, "lnxLib")

		if success and localLib then
			-- Local version exists and loaded successfully
			lnxLib = localLib
			print("Loaded local lnxLib")
		else
			-- Local version doesn't exist, download from GitHub
			print("Local lnxLib not found, downloading from GitHub...")
			local libContent

			-- Try to download with error handling
			local downloadSuccess, errorMsg = pcall(function()
				libContent = downloadFile(libURL)
				return true
			end)

			if not downloadSuccess or not libContent then
				error("Failed to download lnxLib: " .. tostring(errorMsg))
			end

			-- Execute downloaded code with error handling
			local executeSuccess, result = pcall(load, libContent)
			if not executeSuccess or not result then
				error("Failed to load lnxLib content: " .. tostring(result))
			end

			-- Execute the loaded code
			local runSuccess, lib = pcall(result)
			if not runSuccess or not lib then
				error("Failed to execute lnxLib: " .. tostring(lib))
			end

			-- Assign globally
			lnxLib = lib
			print("Downloaded and loaded lnxLib from GitHub")
		end

		return lnxLib
	else
		error("Unsupported library: " .. libName)
	end
end

--why is this not working? added dpots tp prevent strign from makign this library link isntead of module in git comands so it doesnt break everything for git pull and stuff
local latestLNXlib = "https://" .. "github.com/lnx00/Lmaobox-Library/releases/latest/download/lnxLib.lua"
local lnxLib = loadlib("lnxLib", latestLNXlib)

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

	-- Branchless cache reset
	cachedSteamIDs, lastTick = (lastTick ~= currentTick and {} or cachedSteamIDs), currentTick

	-- Retrieve cached result or calculate it
	local result = cachedSteamIDs[playerIndex]
		or (function()
			local playerInfo = assert(client.GetPlayerInfo(playerIndex), "Failed to get player info")
			local steamID = assert(playerInfo.SteamID, "Failed to get SteamID")
			return (playerInfo.IsBot or playerInfo.IsHLTV or steamID == "[U:1:0]") and playerInfo.UserID
				or assert(steam.ToSteamID64(steamID), "Failed to convert SteamID to SteamID64")
		end)()

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

		-- Check if the target player was found
		if targetPlayer then
			steamId = assert(Common.GetSteamID64(targetPlayer), "Failed to get SteamID64 for player")
		else
			return false
		end
	elseif type(playerInfo) == "number" then
		-- If playerInfo is a number, convert it to a string and check its length
		local steamIdStr = tostring(playerInfo)
		if #steamIdStr == 17 then
			steamId = playerInfo
		else
			return false
		end
	elseif playerInfo.GetIndex then
		-- If playerInfo is a player entity, get its SteamID64
		steamId = assert(Common.GetSteamID64(playerInfo), "Failed to get SteamID64 for player entity")
	else
		-- If playerInfo is neither a valid index, a valid SteamID64, nor a player entity, return false
		return false
	end

	if not steamId then
		return false
	end

	-- Check if the player is marked as a cheater based on various criteria
	local strikes = G.PlayerData[steamId] and G.PlayerData[steamId].info.Strikes or 0
	local isMarkedCheater = G.PlayerData[steamId] and G.PlayerData[steamId].info.isCheater
	local inDatabase = G.DataBase[steamId] ~= nil
	local priorityCheater = playerlist.GetPriority(steamId) == 10

	return isMarkedCheater or inDatabase or priorityCheater
end

---@param entity Entity
---@param checkFriend boolean?
---@param checkDormant boolean?
---@param skipEntity Entity? Optional entity to skip (e.g., the local player)
function Common.IsValidPlayer(entity, checkFriend, checkDormant, skipEntity)
	-- Check if the entity is a valid player
	if
		not entity
		or not entity:IsValid()
		or not entity:IsAlive()
		or (checkDormant == true and entity:IsDormant() or checkDormant == nil and entity:IsDormant())
		or entity:GetTeamNumber() == TEAM_SPECTATOR
		or entity:GetTeamNumber() == TEAM_UNASSIGNED --can be simplified to entity:GetTeamNumber() > 1
		or (skipEntity and entity == skipEntity)
	then
		return false -- Entity is not a valid player
	end

	-- Skip friends unless debug mode is enabled
	if not G.Menu.Advanced.debug then
		if checkFriend == true and Common.IsFriend(entity) then
			return false -- Entity is a friend, skip
		elseif checkFriend == nil and Common.IsFriend(entity) then
			return false -- Entity is a friend, skip (default behavior)
		end
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
---@return table record
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

-- Push snapshot into player's history and keep size bounded
---@param player Entity|table Wrapped player / entity
function Common.pushHistory(player)
	local steamid = player:GetSteamID64()
	if not steamid or not player then
		return
	end
	G.PlayerData[steamid] = G.PlayerData[steamid] or {}
	local pdata = G.PlayerData[steamid]
	pdata.History = pdata.History or {}

	local record = Common.createRecordFromPlayer(player)
	if not record then
		return
	end -- skip invalid player

	pdata.Current = record
	table.insert(pdata.History, record)

	if #pdata.History > Common.MAX_HISTORY then
		table.remove(pdata.History, 1)
	end
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
	UnloadLib() --unloading lualib
	engine.PlaySound("hl1/fvox/deactivated.wav") --deactivated
end

-- Unregister previous callbacks
callbacks.Unregister("Unload", "CD_Unload") -- unregister the "Unload" callback

-- Register callbacks
callbacks.Register("Unload", "CD_Unload", OnUnload) -- Register the "Unload" callback

-- Play sound when loaded
engine.PlaySound("hl1/fvox/activated.wav")

return Common
