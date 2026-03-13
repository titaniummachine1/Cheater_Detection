--[[ Main.lua
     New Core Entry Point for Cheater Detection Service.
]]

-- [[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Config = require("Cheater_Detection.Utils.Config")
local EventBus = require("Cheater_Detection.core.event_bus")
local PlayerCache = require("Cheater_Detection.core.player_cache")
local Scheduler = require("Cheater_Detection.core.scheduler")
local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local Common = require("Cheater_Detection.Utils.Common")
local Commands = require("Cheater_Detection.Utils.Commands")
local SteamHistory = require("Cheater_Detection.Database.SteamHistory")

-- Detectors
local ValveCheck = require("Cheater_Detection.detectors.valve_check")
local SilentAim = require("Cheater_Detection.detectors.silent_aim")
local AntiAim = require("Cheater_Detection.detectors.antiaim")
local DuckSpeed = require("Cheater_Detection.detectors.duck_speed")
local Bhop = require("Cheater_Detection.detectors.bhop")
local WarpDT = require("Cheater_Detection.detectors.warp_dt")
local FakeLag = require("Cheater_Detection.detectors.fake_lag")

local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

-- Actions
local NotificationService = require("Cheater_Detection.services.notification_service")
local Visuals = require("Cheater_Detection.actions.visuals")
local Menu = require("Cheater_Detection.Misc.Visuals.Menu")

local hasSearchedGroup = false

-- [[ Initialization ]]
local function Init()
	EventBus.Reset()
	NotificationService.Init()
	
	-- Populate global menu config before anything else
	if not G.Menu then
		require("Cheater_Detection.Utils.Config").LoadCFG()
	end
	
	-- Require the Menu at the end of initialization
	require("Cheater_Detection.Misc.Visuals.Menu")
	
	print("[CD] System initialized.")
end

-- [[ Callbacks ]]
local function OnCreateMove(cmd)
	-- Definitive check if we are actually connected to a game server
	if not engine.GetServerIP() then
		hasSearchedGroup = false
		return 
	end
	
	-- Only start fetching the Valve group members once per server session
	if not hasSearchedGroup then
		hasSearchedGroup = true
		SteamLookup.RefreshValveGroup()
	end

	-- Scan currently encountered players
	local players = entities.FindByClass("CTFPlayer")
	for i = 1, #players do
		local ply = players[i]
		local pState = PlayerCache.Get(ply)
		if pState then
			-- Update history snapshot first
			HistoryManager.Push(pState.wrap)

			-- Layer 1-3 Detections
			ValveCheck.ProcessPlayer(pState)
			SilentAim.ProcessPlayer(pState)
			AntiAim.ProcessPlayer(pState)
			DuckSpeed.ProcessPlayer(pState)
			Bhop.ProcessPlayer(pState)
			WarpDT.ProcessPlayer(pState)
			FakeLag.ProcessPlayer(pState)
		end
	end
end

local function OnDraw()
	Scheduler.Tick()
	Visuals.DrawTags()
end

local function OnFireGameEvent(event)
	local name = event:GetName()
	if name == "player_disconnect" then
		local uid = event:GetInt("userid")
		local ent = entities.GetByUserID(uid)
		if ent then
			local id = tostring(Common.GetSteamID64(ent))
			EventBus.Publish("OnPlayerDisconnect", id)
			PlayerCache.Remove(id)
		end
	end
end

-- Re-register
callbacks.Unregister("CreateMove", "CD_CreateMove")
callbacks.Unregister("FireGameEvent", "CD_Events")
callbacks.Unregister("Draw", "CD_Draw")

callbacks.Register("CreateMove", "CD_CreateMove", OnCreateMove)
callbacks.Register("FireGameEvent", "CD_Events", OnFireGameEvent)
callbacks.Register("Draw", "CD_Draw", OnDraw)

Init()
