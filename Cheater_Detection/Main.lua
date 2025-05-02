--[[
    Cheater Detection for Lmaobox Recode
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credits:
    LNX (github.com/lnx00) for base script
    Muqa for visuals and design assistance
    Alchemist for testing and party callout
]]

--[[ Import core utilities ]]
local G = require("Cheater_Detection.Utils.Globals") --[[ Imported by: Main.lua ]]
local Common = require("Cheater_Detection.Utils.Common") --[[ Imported by: Main.lua ]]
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers") --[[ Imported by: Main.lua ]]

require("Cheater_Detection.Utils.Config") --[[ Imported by: Main.lua ]]
--[[ Import database system ]]
require("Cheater_Detection.Database.Database") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Database.Fetcher") --[[ Imported by: Main.lua ]]

--[[ UI components ]]
require("Cheater_Detection.Misc.Visuals.Menu") --[[ Imported by: Main.lua ]]

--[[ Detection modules (uncomment when needed) ]]
--local Detections = require("Cheater_Detection.Detections")
--require("Cheater_Detection.Visuals")
--require("Cheater_Detection.Modules.EventHandler")

--[[ Variables ]]
local WPlayer, PR = Common.WPlayer, Common.PlayerResource

--[[ Update the player data every tick ]]
--
local function OnCreateMove(cmd)
	local DebugMode = G.Menu.Main.debug

	-- Use FastPlayers for optimized player fetching (required directly)
	G.pLocal = FastPlayers.GetLocal() -- Get cached local player (still store in G for now)
	local allPlayers = FastPlayers.GetAll(true) -- Get cached list of other players (exclude local)

	if not G.pLocal then -- Need local player to proceed
		return
	end

	-- Check connection state and store in G
	G.ConnectionState = Common.CheckConnectionState()

	-- Iterate over the cached list of players
	for _, entity in ipairs(allPlayers) do
		-- Get the steamid for the player
		local steamid = Common.GetSteamID64(entity)
		if not steamid then
			-- Log warning but continue loop instead of returning
			warn("Failed to get SteamID for player %s", entity:GetName() or "nil")
			goto continue_loop -- Use goto to skip to next iteration
		end

		-- Initialize player data if it doesn't exist
		if not G.PlayerData[steamid] then
			G.PlayerData[steamid] = G.DefaultPlayerData
		end

		-- TODO: Consider using FastPlayers.SetWrapper with WPlayer.FromEntity
		--       to avoid creating wrapper objects every tick.
		local wrappedPlayer = WPlayer.FromEntity(entity)
		local viewAngles = wrappedPlayer:GetEyeAngles()
		local entityFlags = entity:GetPropInt("m_fFlags")
		-- Correct bitwise flag check (assuming FL_ONGROUND is the correct global constant)
		local isOnGround = (entityFlags & FL_ONGROUND) ~= 0
		local headHitboxPosition = wrappedPlayer:GetHitboxPos(1)
		local bodyHitboxPosition = wrappedPlayer:GetHitboxPos(4)
		local viewPos = wrappedPlayer:GetEyePos()
		local simulationTime = wrappedPlayer:GetSimulationTime()

		-- Update history
		G.PlayerData[steamid].History = G.PlayerData[steamid].History or {}

		-- Gather player data
		G.PlayerData[steamid].Current =
			Common.createRecord(viewAngles, viewPos, headHitboxPosition, bodyHitboxPosition, simulationTime, isOnGround)

		table.insert(G.PlayerData[steamid].History, G.PlayerData[steamid].Current)

		-- Keep the history table size to a maximum of 66
		if #G.PlayerData[steamid].History > 66 then
			table.remove(G.PlayerData[steamid].History, 1)
		end

		-- Perform detection checks
		--Detections.CheckAngles(wrappedPlayer, entity)
		--Detections.CheckDuckSpeed(wrappedPlayer, entity)
		--Detections.CheckBunnyHop(wrappedPlayer, entity)

		if G.ConnectionState.stable then
			-- Optionally, print or log the reason for instability
			--FakeLag_check(wrappedPlayer, entity)
			--Warp_check(wrappedPlayer, entity)
			--warp_recharge_check(wrappedPlayer, entity)
			--triggerbot_check(wrappedPlayer, entity)
			--smooth_aimbot_check(wrappedPlayer, entity)
		end
		::continue_loop:: -- Label for goto statement
	end
end

--[[ Callbacks ]]
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)
