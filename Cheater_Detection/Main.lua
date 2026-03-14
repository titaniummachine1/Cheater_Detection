---@diagnostic disable: undefined-global, undefined-field
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
	
    -- Automate Database Fetch (Local then Online)
    local Fetcher = require("Cheater_Detection.Database.Fetcher")
    Fetcher.ImportLocal()  -- Merge local files first
    Fetcher.Start()        -- Begin online sync
    
	print("[CD] System initialized.")
end

-- [[ Callbacks ]]
local function OnCreateMove(cmd)
	-- Definitive check if we are actually connected to a game server
	if not engine.GetServerIP() then
		hasSearchedGroup = false
		return 
	end
	
	-- Auto-fetching is disabled per user request.
    -- Use the menu to manually refresh sources if needed.

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
    elseif name == "player_team" then
        local uid = event:GetInt("userid")
        local team = event:GetInt("team")
        -- Only trigger entry logic if joining active teams (Red: 2, Blue: 3)
        if team == 2 or team == 3 then
            local ent = entities.GetByUserID(uid)
            if ent then
                local id = tostring(Common.GetSteamID64(ent))
                if id and id:match("^7656119%d+$") then
                    EventBus.Publish("OnPlayerJoinTeam", id, ent)
                end
            end
        end
    elseif name == "player_death" then
        local attacker_uid = event:GetInt("attacker")
        if attacker_uid ~= 0 then
            local attacker_ent = entities.GetByUserID(attacker_uid)
            if attacker_ent then
                local id = tostring(Common.GetSteamID64(attacker_ent))
                if id and id:match("^7656119%d+$") then
                    PlayerCache.DecayPlayer(id)
                end
            end
        end
    elseif name == "game_newmap" or name == "teamplay_round_start" then
        -- Reset all "checked" states on map change so we re-verify everyone
        PlayerCache.ResetCheckedState()
        PlayerCache.Cleanup()
	end
end

local function OnUnload()
    print("[CD] Unloading system...")
    -- Database and Config have their own internal Unload listeners, but we can trigger a final save here too if needed
    if Database and Database.SaveDatabase then
        Database.SaveDatabase()
    end
end

-- Re-register
callbacks.Unregister("CreateMove", "CD_CreateMove")
callbacks.Unregister("FireGameEvent", "CD_Events")
callbacks.Unregister("Draw", "CD_Draw")
callbacks.Unregister("Unload", "CD_Unload")

callbacks.Register("CreateMove", "CD_CreateMove", OnCreateMove)
callbacks.Register("FireGameEvent", "CD_Events", OnFireGameEvent)
callbacks.Register("Draw", "CD_Draw", OnDraw)
callbacks.Register("Unload", "CD_Unload", OnUnload)

Init()
