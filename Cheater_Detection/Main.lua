--[[
    Cheater Detection for Lmaobox Recode
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credits:
    LNX (github.com/lnx00) for base script
    Muqa for visuals and design assistance
    Alchemist for testing and party callout
]]

-- Check and disable anonymous mode if enabled (disrupts player detection)
if gui.GetValue("ANONYMOUSE MODE") == 1 then
	gui.SetValue("ANONYMOUSE MODE", 0)
	-- Send warning to local chat
	client.ChatPrintf(
		"\x04[CD]\x01 Anonymous mode disabled - it makes all players appear as bots and breaks detection!"
	)
end

--[[ Import core utilities ]]
local G = require("Cheater_Detection.Utils.Globals") --[[ Imported by: Main.lua ]]
local Common = require("Cheater_Detection.Utils.Common") --[[ Imported by: Main.lua ]]
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers") --[[ Imported by: Main.lua ]]

require("Cheater_Detection.Utils.Config") --[[ Imported by: Main.lua ]]
--[[ Import database system ]]
local Database = require("Cheater_Detection.Database.Database") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Database.Fetcher") --[[ Imported by: Main.lua ]]

--[[ Import evidence system ]]
local Evidence = require("Cheater_Detection.Core.Evidence_system") --[[ Imported by: Main.lua ]]

--[[ UI components ]]
require("Cheater_Detection.Misc.Visuals.Menu") --[[ Imported by: Main.lua ]]

--[[ Misc features ]]
require("Cheater_Detection.Misc.ChatPrefix") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Misc.JoinNotifications") --[[ Imported by: Main.lua ]]

--[[ Detection modules ]]
local AntiAim = require("Cheater_Detection.Detection Methods.anti_aim")
local Bhop = require("Cheater_Detection.Detection Methods.bhop")
local DuckSpeed = require("Cheater_Detection.Detection Methods.Duck_Speed")
local FakeLag = require("Cheater_Detection.Detection Methods.fake_lag")
local WarpDT = require("Cheater_Detection.Detection Methods.warp_dt")

--[[ Variables ]]
local WPlayer, PR = Common.WPlayer, Common.PlayerResource

--[[ Update the player data every tick ]]
--
local function OnCreateMove(cmd)
	local DebugMode = G.Menu.Main.debug

	-- Use FastPlayers for optimized player fetching (required directly)
	local pLocal = FastPlayers.GetLocal() -- Get cached local player (still store in G for now)
	G.pLocal = pLocal -- Store for Evidence system to identify local player
	local allPlayers = FastPlayers.GetAll(not G.Menu.Advanced.debug) -- Exclude local unless debug mode

	if not pLocal then -- Need local player to proceed
		return
	end

	-- Check connection state and store in G
	local ConnectionState = Common.CheckConnectionState()

	--if not stable connection then dont do any checks
	if not ConnectionState.stable then
		return
	end

	-- Apply evidence decay (once per second)
	Evidence.ApplyDecay()

	-- Iterate over the cached list of players
	for _, Player in ipairs(allPlayers) do
		local steamID = Player:GetSteamID64()

		-- Skip if already confirmed cheater (optimization - database or marked)
		if Evidence.IsMarkedCheater(steamID) then
			goto continue
		end

		-- Push history for detection analysis
		Common.pushHistory(Player)

		-- Perform detection checks
		AntiAim.Check(Player)
		DuckSpeed.Check(Player)
		Bhop.Check(Player)
		FakeLag.Check(Player)
		WarpDT.Check(Player)

		-- TODO: Implement remaining detection methods
		--warp_recharge_check(Player)
		--triggerbot_check(Player)
		--smooth_aimbot_check(Player)
		--plain_aimbot_check(Player)
		--strafe_bot_check(Player)
		--bot_walk_check(Player)

		::continue::
	end
end

--[[ Map Change Handler ]]
local function OnMapChange()
	-- Force save database on map change
	Database.ForceSave()

	-- Reload database on new map
	Database.LoadDatabase(false, true)

	if G.Menu.Advanced.debug then
		print("[CD] Map changed - Database saved and reloaded")
	end
end

--[[ Callbacks ]]
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)
callbacks.Register("FireGameEvent", "CD_MapChange", function(event)
	if
		event:GetName() == "game_newmap"
		or event:GetName() == "teamplay_round_start"
		or event:GetName() == "cs_round_start"
	then
		OnMapChange()
	end
end)

-- Clean up player data when they leave (centralized through evidence system)
callbacks.Register("FireGameEvent", "CD_PlayerDisconnect", function(event)
	if event:GetName() == "player_disconnect" then
		local steamID = tostring(event:GetInt("userid"))
		Evidence.OnPlayerLeave(steamID)
	end
end)
