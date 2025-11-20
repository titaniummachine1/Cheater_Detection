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

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")
require("Cheater_Detection.Utils.HistoryConfig")

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
require("Cheater_Detection.Utils.Commands") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Database.SteamHistory") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Misc.Vote_Revel") --[[ Imported by: Main.lua ]]

--[[ Detection modules ]]
local AntiAim = require("Cheater_Detection.Detection Methods.anti_aim")
local Bhop = require("Cheater_Detection.Detection Methods.bhop")
local DuckSpeed = require("Cheater_Detection.Detection Methods.Duck_Speed")
local FakeLag = require("Cheater_Detection.Detection Methods.fake_lag")
local WarpDT = require("Cheater_Detection.Detection Methods.warp_dt")
local ManualPriority = require("Cheater_Detection.Detection Methods.manual_priority")

--[[ Variables ]]
local WPlayer, PR = Common.WPlayer, Common.PlayerResource

--[[ Update the player data every tick ]]
--
local function OnCreateMove(cmd)
	local DebugMode = G.Menu.Advanced and G.Menu.Advanced.debug
	TickProfiler.SetEnabled(DebugMode)
	TickProfiler.BeginSection("CreateMove")

	local function profilerEnd()
		TickProfiler.EndSection("CreateMove")
	end

	-- Use FastPlayers for optimized player fetching (required directly)
	TickProfiler.BeginSection("FetchPlayers")
	local pLocal = FastPlayers.GetLocal() -- Get cached local player (still store in G for now)
	G.pLocal = pLocal -- Store for Evidence system to identify local player
	local allPlayers = FastPlayers.GetAll(not G.Menu.Advanced.debug) -- Exclude local unless debug mode
	TickProfiler.EndSection("FetchPlayers")

	if not pLocal then -- Need local player to proceed
		profilerEnd()
		return
	end

	-- Check connection state and store in G
	TickProfiler.BeginSection("CheckConnection")
	local ConnectionState = Common.CheckConnectionState()
	TickProfiler.EndSection("CheckConnection")

	--if not stable connection then dont do any checks
	if not ConnectionState.stable then
		profilerEnd()
		return
	end

	-- Apply evidence decay (once per second)
	TickProfiler.BeginSection("EvidenceDecay")
	Evidence.ApplyDecay()
	TickProfiler.EndSection("EvidenceDecay")

	-- Cleanup disconnected players to prevent memory leak (once per second)
	TickProfiler.BeginSection("PlayerCleanup")
	local currentTick = globals.TickCount()
	local ticksPerSecond = 66 -- TF2 tick rate

	-- Only run cleanup once per second to avoid overhead
	if not G.LastCleanupTick or (currentTick - G.LastCleanupTick) >= ticksPerSecond then
		G.LastCleanupTick = currentTick

		-- Build set of currently active players
		local activeSet = {}
		for _, Player in ipairs(allPlayers) do
			local sid = Player:GetSteamID64()
			if sid then
				activeSet[tostring(sid)] = true
			end
		end

		-- Trim PlayerState to only active players
		PlayerState.TrimToActive(activeSet)
	end
	TickProfiler.EndSection("PlayerCleanup")

	-- Iterate over the cached list of players
	for _, Player in ipairs(allPlayers) do
		local steamID = Player:GetSteamID64()

		-- Skip if already confirmed cheater (optimization - database or marked)
		TickProfiler.BeginSection("CheckCheaterStatus")
		local isMarked = Evidence.IsMarkedCheater(steamID)
		TickProfiler.EndSection("CheckCheaterStatus")

		if isMarked then
			goto continue
		end

		-- Push history for detection analysis
		TickProfiler.BeginSection("HistoryPush")
		Common.pushHistory(Player)
		TickProfiler.EndSection("HistoryPush")

		-- Perform detection checks
		TickProfiler.BeginSection("Detections")

		TickProfiler.BeginSection("Detection_AntiAim")
		AntiAim.Check(Player)
		TickProfiler.EndSection("Detection_AntiAim")

		TickProfiler.BeginSection("Detection_DuckSpeed")
		DuckSpeed.Check(Player)
		TickProfiler.EndSection("Detection_DuckSpeed")

		TickProfiler.BeginSection("Detection_Bhop")
		Bhop.Check(Player)
		TickProfiler.EndSection("Detection_Bhop")

		TickProfiler.BeginSection("Detection_FakeLag")
		FakeLag.Check(Player)
		TickProfiler.EndSection("Detection_FakeLag")

		TickProfiler.BeginSection("Detection_WarpDT")
		WarpDT.Check(Player)
		TickProfiler.EndSection("Detection_WarpDT")

		TickProfiler.BeginSection("Detection_ManualPriority")
		ManualPriority.Check(Player)
		TickProfiler.EndSection("Detection_ManualPriority")

		TickProfiler.EndSection("Detections")

		-- TODO: Implement remaining detection methods
		--warp_recharge_check(Player)
		--triggerbot_check(Player)
		--smooth_aimbot_check(Player)
		--plain_aimbot_check(Player)
		--strafe_bot_check(Player)
		--bot_walk_check(Player)

		::continue::
	end

	-- Incremental garbage collection to prevent lag spikes
	TickProfiler.BeginSection("GarbageCollection")
	local memBefore = collectgarbage("count")

	-- Run incremental GC step to prevent automatic full collection spikes
	-- Smoother GC: Run small steps always, increase aggression only if very high
	local stepSize = 20 -- Default small step (20KB) - steady state

	-- Gradual ramp up to avoid "stop the world" spikes
	if memBefore > 120000 then -- >120MB: High urgency
		stepSize = 200 -- 200KB steps (was 1000)
	elseif memBefore > 80000 then -- >80MB: Moderate urgency
		stepSize = 100 -- 100KB steps (was 200)
	elseif memBefore > 40000 then -- >40MB: Low urgency
		stepSize = 50 -- 50KB steps (was 50)
	end

	collectgarbage("step", stepSize)

	local memAfter = collectgarbage("count")
	TickProfiler.EndSection("GarbageCollection")

	profilerEnd()
end

--[[ Map Change Handler ]]
local function OnMapChange()
	-- Force save database on map change
	-- Save database on map change if dirty
	Database.SaveDatabase()

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
		local networkID = event:GetString("networkid")
		local steamID = Common.FromSteamid3To64(networkID)
		if steamID then
			Evidence.OnPlayerLeave(steamID)
		end
	elseif event:GetName() == "player_death" then
		-- Opportunistic save when local player dies (dead time)
		local localPlayer = entities.GetLocalPlayer()
		local victimUserID = event:GetInt("userid")
		local victim = entities.GetByUserID(victimUserID)

		if localPlayer and victim and localPlayer == victim then
			Database.SaveDatabase()
		end
	end
end)
