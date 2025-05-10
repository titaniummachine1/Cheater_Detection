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
	local pLocal = FastPlayers.GetLocal() -- Get cached local player (still store in G for now)
	local allPlayers = FastPlayers.GetAll(true) -- Get cached list of other players (exclude local)

	if not pLocal then -- Need local player to proceed
		return
	end

	-- Check connection state and store in G
	local ConnectionState = Common.CheckConnectionState()

	-- Iterate over the cached list of players
	for _, Player in ipairs(allPlayers) do
		-- Get the steamid for the player
		local steamid = Player:GetSteamID64()

		if steamid then
			Common.pushHistory(steamid, Player)

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
		end
	end
end

--[[ Callbacks ]]
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)
