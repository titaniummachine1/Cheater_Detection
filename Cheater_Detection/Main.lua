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
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Config = require("Cheater_Detection.Utils.Config") -- Load config early
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Database = require("Cheater_Detection.Database.Database")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")
local EventManager = require("Cheater_Detection.Utils.EventManager")

--[[ UI components ]]
require("Cheater_Detection.Misc.Visuals.Menu") --[[ Imported by: Main.lua ]]

--[[ Misc features ]]
require("Cheater_Detection.Misc.ChatPrefix") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Misc.JoinNotifications") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Utils.Commands") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Database.SteamHistory") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Misc.Vote_Revel") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Misc.Auto_Vote") --[[ Imported by: Main.lua ]]

--[[ Detection modules ]]
local AntiAim = require("Cheater_Detection.Detection Methods.anti_aim")
local Bhop = require("Cheater_Detection.Detection Methods.bhop")
local DuckSpeed = require("Cheater_Detection.Detection Methods.Duck_Speed")
local FakeLag = require("Cheater_Detection.Detection Methods.fake_lag")
local WarpDT = require("Cheater_Detection.Detection Methods.warp_dt")
local ManualPriority = require("Cheater_Detection.Detection Methods.manual_priority")
local SilentAimbot = require("Cheater_Detection.Detection Methods.silent_aimbot")

--[[ Variables ]]

--[[ Update the player data every tick ]]
local function OnCreateMove(cmd)
	local DebugMode = false
	if G.Menu.Advanced then
		DebugMode = G.Menu.Advanced.debug
	end

	TickProfiler.SetEnabled(DebugMode)
	TickProfiler.BeginSection("CreateMove")

	-- Use FastPlayers for optimized player fetching
	TickProfiler.BeginSection("FetchPlayers")
	local pLocal = FastPlayers.GetLocal()
	G.pLocal = pLocal 
	
	local fastFilter = true
	if DebugMode then fastFilter = false end
	local allPlayers = FastPlayers.GetAll(fastFilter)
	TickProfiler.EndSection("FetchPlayers")

	if not pLocal then
		TickProfiler.EndSection("CreateMove")
		return
	end

	TickProfiler.BeginSection("CheckConnection")
	local isStable = Common.CheckConnectionState()
	local isFrameGap = Common.IsFrameGap()
	TickProfiler.EndSection("CheckConnection")

	if not isStable or isFrameGap then
		TickProfiler.EndSection("CreateMove")
		return
	end

	-- Apply evidence decay (once per second)
	TickProfiler.BeginSection("EvidenceDecay")
	Evidence.ApplyDecay()
	TickProfiler.EndSection("EvidenceDecay")

	-- Iterate over the cached list of players
	for _, Player in ipairs(allPlayers) do
		local steamID = Player:GetSteamID64()
		if not steamID then goto continue end

		-- Skip if already confirmed cheater
		TickProfiler.BeginSection("CheckCheaterStatus")
		local isMarked = Evidence.IsMarkedCheater(steamID)
		TickProfiler.EndSection("CheckCheaterStatus")

		if isMarked then
			goto continue
		end

		-- Push history ONLY for non-dormant players
		TickProfiler.BeginSection("HistoryPush")
		if not Player:IsDormant() then
			Common.pushHistory(Player)
		end
		TickProfiler.EndSection("HistoryPush")

		-- Perform detection checks
		TickProfiler.BeginSection("Detections")

		local steamStr = tostring(steamID)

		TickProfiler.BeginSection("Detection_AntiAim")
		AntiAim.Check(Player, steamStr)
		TickProfiler.EndSection("Detection_AntiAim")

		TickProfiler.BeginSection("Detection_DuckSpeed")
		DuckSpeed.Check(Player, steamStr)
		TickProfiler.EndSection("Detection_DuckSpeed")

		TickProfiler.BeginSection("Detection_Bhop")
		Bhop.Check(Player, steamStr)
		TickProfiler.EndSection("Detection_Bhop")

		TickProfiler.BeginSection("Detection_FakeLag")
		FakeLag.Check(Player, steamStr)
		TickProfiler.EndSection("Detection_FakeLag")

		TickProfiler.BeginSection("Detection_WarpDT")
		WarpDT.Check(Player, steamStr)
		TickProfiler.EndSection("Detection_WarpDT")

		TickProfiler.BeginSection("Detection_ManualPriority")
		ManualPriority.Check(Player, steamStr)
		TickProfiler.EndSection("Detection_ManualPriority")

		TickProfiler.BeginSection("Detection_SilentAimbot")
		SilentAimbot.Check(Player, steamStr)
		TickProfiler.EndSection("Detection_SilentAimbot")

		TickProfiler.EndSection("Detections")

		::continue::
	end

	TickProfiler.EndSection("CreateMove")
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

--[[ Event Handlers ]]

-- Handler: Player disconnect cleanup
local function onPlayerDisconnect(event)
	local networkID = event:GetString("networkid")
	local steamID = Common.FromSteamid3To64(networkID)
	if steamID then
		Evidence.OnPlayerLeave(steamID)
	end
end

-- Handler: Auto-save on local player death
local function onPlayerDeath(event)
	local localPlayer = entities.GetLocalPlayer()
	local victimUserID = event:GetInt("userid")
	local victim = entities.GetByUserID(victimUserID)

	if localPlayer and victim and localPlayer == victim then
		Database.SaveDatabase()
	end
end

-- Handler: Auto-save on round end
local function onRoundEnd(event)
	Database.SaveDatabase()
end

-- Handler: Auto-save on game over
local function onGameOver(event)
	Database.SaveDatabase()
end

-- Handler: Silent aimbot shot detection
local function onPlayerHurt(event)
	local shooterUserID = event:GetInt("attacker")
	local victimUserID = event:GetInt("userid")
	local shooter = entities.GetByUserID(shooterUserID)
	local victim = entities.GetByUserID(victimUserID)

	if shooter and victim then
		SilentAimbot.OnPlayerHurt(shooter, victim)
	end
end

--[[ Event Registration - Centralized via EventManager ]]

-- Main detection loop
EventManager.Register("CreateMove", "Main_Detection", OnCreateMove)

-- Map change events (save and reload database)
EventManager.Register("FireGameEvent", "Main_MapChange_NewMap", OnMapChange, "game_newmap")
EventManager.Register("FireGameEvent", "Main_MapChange_RoundStart", OnMapChange, "teamplay_round_start")
EventManager.Register("FireGameEvent", "Main_MapChange_CSRoundStart", OnMapChange, "cs_round_start")

-- Player lifecycle
EventManager.Register("FireGameEvent", "Main_PlayerDisconnect", onPlayerDisconnect, "player_disconnect")

-- Auto-save triggers (non-intrusive moments)
EventManager.Register("FireGameEvent", "Main_PlayerDeath", onPlayerDeath, "player_death")
EventManager.Register("FireGameEvent", "Main_RoundWin", onRoundEnd, "teamplay_round_win")
EventManager.Register("FireGameEvent", "Main_RoundStalemate", onRoundEnd, "teamplay_round_stalemate")
EventManager.Register("FireGameEvent", "Main_GameOver", onGameOver, "teamplay_game_over")
EventManager.Register("FireGameEvent", "Main_TFGameOver", onGameOver, "tf_game_over")
EventManager.Register("FireGameEvent", "Main_PlayerHurt", onPlayerHurt, "player_hurt")
EventManager.Register("FireGameEvent", "Main_ArenaRoundStart", onRoundEnd, "arena_round_start")
