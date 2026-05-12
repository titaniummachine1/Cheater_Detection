--[[ Main.lua
     New Core Entry Point for Cheater Detection Service.
]]
client.Command("clear", true)
---@diagnostic disable: undefined-global, undefined-field
-- [[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Config = require("Cheater_Detection.Utils.Config")
local Events = require("Cheater_Detection.Core.Events")
local Constants = require("Cheater_Detection.Core.constants")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local Scheduler = require("Cheater_Detection.Core.scheduler")
local DirtySystem = require("Cheater_Detection.Core.DirtySystem")
local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local Common = require("Cheater_Detection.Utils.Common")
require("Cheater_Detection.Utils.Commands")
require("Cheater_Detection.Misc.ChatPrefix")
require("Cheater_Detection.Misc.Vote_Reveal")
require("Cheater_Detection.Misc.Auto_Vote")
require("Cheater_Detection.Misc.SniperDotAngle")
require("Cheater_Detection.Misc.Visuals.Menu")
local Database = require("Cheater_Detection.Database.Database")
require("Cheater_Detection.Database.SteamHistory")
require("Cheater_Detection.Database.MAC")
local Fetcher = require("Cheater_Detection.Database.Fetcher")

-- Detectors
local ValveCheck = require("Cheater_Detection.detectors.valve_check")
local SilentAim = require("Cheater_Detection.detectors.silent_aim")
local AimLock = require("Cheater_Detection.detectors.aim_lock")
local AntiAim = require("Cheater_Detection.detectors.antiaim")
local DuckSpeed = require("Cheater_Detection.detectors.duck_speed")
local Bhop = require("Cheater_Detection.detectors.bhop")
local WarpDT = require("Cheater_Detection.detectors.warp_dt")
local FakeLag = require("Cheater_Detection.detectors.fake_lag")
local CosmeticAbuse = require("Cheater_Detection.detectors.cosmetic_abuse")

local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local DetectionConfig = require("Cheater_Detection.Utils.DetectionConfig")
local JoinNotifications = require("Cheater_Detection.Misc.JoinNotifications")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")

-- Actions
local NotificationService = require("Cheater_Detection.services.notification_service")
local Visuals = require("Cheater_Detection.actions.visuals")
local BridgePrompt = require("Cheater_Detection.services.bridge_prompt")

local hasSearchedGroup = false
local valveDisconnectTriggered = false
local wasInServer = false
local cleanedFriendIDs = {}
local lastProfilerEnabled = nil

local function isValveAutoDisconnectEnabled()
	local menu = G.Menu
	local joinNotifications = menu and menu.Misc and menu.Misc.JoinNotifications
	return joinNotifications and joinNotifications.ValveAutoDisconnect == true
end

local function getPersistReason(flags, existingReason)
	if existingReason and existingReason ~= "" then
		return existingReason
	end
	if (flags & Constants.Flags.VALVE) ~= 0 then
		return "Valve Employee"
	end
	if (flags & Constants.Flags.CHEATER) ~= 0 then
		return "Runtime Detection"
	end
	if (flags & Constants.Flags.VAC_BANNED) ~= 0 then
		return "VAC Ban on Record"
	end
	if (flags & Constants.Flags.COMM_BANNED) ~= 0 then
		return "Community/Trade Ban"
	end
	if (flags & Constants.Flags.SUSPICIOUS) ~= 0 then
		return "Suspicious Behavior"
	end
	return "Player Flagged During Session"
end

local function persistSessionPlayerState(id, state, fallbackName)
	if not state or not id then
		return false
	end

	local flags = tonumber(state.flags or 0) or 0
	local hasPersistentFlags = (flags & Constants.PERSISTENT_MASK) ~= 0
	local score = tonumber(state.score or 0) or 0
	if not hasPersistentFlags and score < Constants.Threshold.SUSPICIOUS then
		return false
	end

	local existing = Database.GetCheater(id)
	local name = fallbackName
	if state.wrap and state.wrap.GetName then
		name = state.wrap:GetName()
	end
	if (not name or name == "") and existing and existing.Name then
		name = existing.Name
	end

	return Database.UpsertCheater(id, {
		name = name or id,
		reason = getPersistReason(flags, existing and existing.Reason),
		flags = flags,
		score = score,
	})
end

local function enforceValveAutoDisconnect(playerState)
	if valveDisconnectTriggered or not playerState or not playerState.id then
		return
	end
	if not isValveAutoDisconnectEnabled() then
		return
	end
	if (playerState.flags & Constants.Flags.VALVE) == 0 then
		return
	end

	valveDisconnectTriggered = true
	JoinNotifications.SendValveAlert({
		name = playerState.wrap and playerState.wrap:GetName() or playerState.id,
		tail = "is in the server - Leaving game",
		allowParty = false,
	})
	client.Command("disconnect", true)
end

local function persistActiveSessionPlayers()
	-- Use DirtySystem - only persist players with dirty SESSION flag
	local dirtyPlayers = DirtySystem.GetDirtyPlayers(DirtySystem.FLAGS.SESSION)
	
	for _, id in ipairs(dirtyPlayers) do
		local state = PlayerCache.GetByID(id)
		if state then
			persistSessionPlayerState(id, state, nil)
		end
		-- Clear the dirty flag after persisting
		DirtySystem.ClearDirty(id, DirtySystem.FLAGS.SESSION)
	end
end

local function resetRuntimeSessionState()
	hasSearchedGroup = false
	valveDisconnectTriggered = false
	cleanedFriendIDs = {}
	PlayerCache.ResetCheckedState()
	PlayerCache.Cleanup()
	-- Reset notification state for new session (new round/new game)
	if NotificationService and NotificationService.ResetSession then
		NotificationService.ResetSession()
	end
	if JoinNotifications and JoinNotifications.ResetSession then
		JoinNotifications.ResetSession()
	end
end

local function isDebugEnabled()
	return Common.IsDebugEnabled()
end

-- [[ Initialization ]]
local function Init()
	Events.Reset()
	JoinNotifications.Init()
	NotificationService.Init()
	BridgePrompt.Init()
	engine.PlaySound("hl1/fvox/activated.wav")

	-- Filter out engine warnings for out-of-range eye angles (Anti-Aim noise)
	client.Command('con_filter_enable 1; con_filter_text_out "Out-of-range value"', true)

	-- Populate global menu config before anything else
	Config.LoadCFG()

	DetectionConfig.RegisterWithHistoryManager()

	-- Automate Database Fetch (Local then Online) - Respects AutoSync setting
	if G.Menu and G.Menu.Main and G.Menu.Main.AutoSync ~= false then
		Fetcher.Start() -- Begin async local import followed by online sync
	else
		print("[CD] Auto-Sync disabled via config.")
	end

	print("[CD] System initialized.")
end

-- [[ Callbacks ]]
local function OnCreateMove(cmd)
	TickProfiler.BeginSection("CreateMove_Total")
	local isGameUI = engine.IsGameUIVisible()
	local isConVisible = engine.Con_IsVisible()
	if isGameUI or isConVisible then
		TickProfiler.EndSection("CreateMove_Total")
		return
	end

	-- Definitive check if we are actually connected to a game server
	local serverIP = engine.GetServerIP()
	if not serverIP then
		if wasInServer then
			persistActiveSessionPlayers()
			Database.SaveDatabase()
			resetRuntimeSessionState()
			wasInServer = false
		else
			hasSearchedGroup = false
			valveDisconnectTriggered = false
		end
		TickProfiler.EndSection("CreateMove_Total")
		return
	end
	wasInServer = true

	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsValid() then
		TickProfiler.EndSection("CreateMove_Total")
		return
	end

	if valveDisconnectTriggered then
		TickProfiler.EndSection("CreateMove_Total")
		return
	end

	Events.DispatchEngineEvent("CreateMove", cmd)

	local menu = G.Menu
	local mainMenu = menu and menu.Main or nil
	local adv = menu and menu.Advanced or nil

	local enableValveCheck = mainMenu and mainMenu.ValveCheck == true
	local enableSilent = adv and adv.SilentAimbot == true
	local enableAimLock = enableSilent and (adv.AimLock ~= false)
	local enableAntiAim = adv and adv.AntiAim == true
	local enableDuckSpeed = adv and adv.DuckSpeed == true
	local enableBhop = adv and adv.Bhop == true
	local enableWarpDT = adv and adv["Warp"] == true
	local enableChoke = adv and adv.Choke == true
	local enableCosmetics = adv and adv.Cosmetics == true

	local tagsEnabled = mainMenu == nil or mainMenu.Cheater_Tags ~= false
	local anyDetectorsEnabled = enableValveCheck
		or enableSilent
		or enableAntiAim
		or enableDuckSpeed
		or enableBhop
		or enableWarpDT
		or enableChoke
		or enableCosmetics
	if not anyDetectorsEnabled and not tagsEnabled then
		TickProfiler.EndSection("CreateMove_Total")
		return
	end

	local historyEnabled = enableSilent or enableWarpDT or enableChoke
	if historyEnabled then
		TickProfiler.BeginSection("History_NewTick")
		HistoryManager.NewTick()
		TickProfiler.EndSection("History_NewTick")
	end

	if not hasSearchedGroup then
		SteamLookup.RefreshValveGroup()
		hasSearchedGroup = true
	end
	-- TickGroupFetch is paced in Scheduler.Tick, not the CreateMove hot path.

	-- Sync authoritative live-player list and tick entity cache once per tick
	TickProfiler.BeginSection("PlayerCache_Sync")
	PlayerCache.SyncTick()
	TickProfiler.EndSection("PlayerCache_Sync")

	local isDebug = isDebugEnabled()
	local localID = tostring(Common.GetSteamID64(localPlayer))
	local stateTable = PlayerCache.GetActiveTable()

	TickProfiler.BeginSection("PlayerScan_Loop")
	for id, existingState in pairs(stateTable) do
		local wrap = existingState and existingState.wrap or nil
		local ply = wrap and wrap:GetRawEntity() or nil
		if not ply or not ply:IsValid() then
			goto continue
		end

		if ply:IsDormant() then
			if historyEnabled and not existingState.wasDormant then
				HistoryManager.ClearPlayer(id)
				existingState.wasDormant = true
			end
			goto continue
		end

		local pState = PlayerCache.Get(ply)
		if not pState then
			goto continue
		end

		pState.wasDormant = false

		-- In normal mode: exclude local player's friends and party members.
		-- In debug mode: process everyone including self and friends.
		if not isDebug then
			if id == localID then
				goto continue
			end
			if pState.isFriend then
				local friendID = pState.id
				if friendID and friendID:match("^7656119%d+$") and not cleanedFriendIDs[friendID] then
					cleanedFriendIDs[friendID] = true
					Database.RemoveCheater(friendID)
				end
				goto continue
			end
		end

		if isDebug then
			assert(pState.wrap, "OnCreateMove: pState.wrap missing for id=" .. tostring(pState.id))
			assert(pState.id, "OnCreateMove: pState.id missing")
		end

		if historyEnabled then
			TickProfiler.BeginSection("History_Push")
			HistoryManager.Push(pState.wrap)
			TickProfiler.EndSection("History_Push")
		end

		TickProfiler.BeginSection("Detectors")
		if enableValveCheck then
			ValveCheck.ProcessPlayer(pState, cmd)
		end
		if enableSilent then
			SilentAim.ProcessPlayer(pState, cmd)
			if enableAimLock then
				AimLock.ProcessPlayer(pState, cmd)
			end
		end
		if enableAntiAim then
			AntiAim.ProcessPlayer(pState, cmd)
		end
		if enableDuckSpeed then
			DuckSpeed.ProcessPlayer(pState, cmd)
		end
		if enableBhop then
			Bhop.ProcessPlayer(pState, cmd)
		end
		if enableWarpDT then
			WarpDT.ProcessPlayer(pState, cmd)
		end
		if enableChoke then
			FakeLag.ProcessPlayer(pState, cmd)
		end
		if enableCosmetics then
			CosmeticAbuse.ProcessPlayer(pState, cmd)
		end
		TickProfiler.EndSection("Detectors")

		if enableValveCheck then
			enforceValveAutoDisconnect(pState)
		end
		if valveDisconnectTriggered then
			TickProfiler.EndSection("PlayerScan_Loop")
			TickProfiler.EndSection("CreateMove_Total")
			return
		end

		::continue::
	end
	TickProfiler.EndSection("PlayerScan_Loop")
	TickProfiler.EndSection("CreateMove_Total")
end

local function OnDraw()
	local enabled = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	if lastProfilerEnabled ~= enabled then
		lastProfilerEnabled = enabled
		TickProfiler.SetEnabled(enabled)
	end
	Scheduler.Tick()
	Visuals.DrawTags()
	BridgePrompt.Draw()
end

local function OnFireGameEvent(event)
	if Events and Events.DispatchFireGameEvent then
		Events.DispatchFireGameEvent(event)
	end

	local name = event:GetName()
	if name == "player_disconnect" then
		local uid = event:GetInt("userid")
		local ent = entities.GetByUserID(uid)
		local id = nil
		if ent and ent:IsValid() then
			id = tostring(Common.GetSteamID64(ent))
		else
			id = Common.FromSteamid3To64(event:GetString("networkid"))
		end
		if id and id:match("^7656119%d+$") then
			local state = PlayerCache.GetByID(id)
			persistSessionPlayerState(id, state, event:GetString("name"))
			Events.Publish("OnPlayerDisconnect", id)
			PlayerCache.Remove(id)
		end
	elseif name == "player_team" then
		local uid = event:GetInt("userid")
		local team = event:GetInt("team")
		-- Only trigger entry logic if joining active teams (Red: 2, Blue: 3)
		if team == 2 or team == 3 then
			local ent = entities.GetByUserID(uid)
			if ent and ent:IsValid() then
				local id = tostring(Common.GetSteamID64(ent))
				if id and id:match("^7656119%d+$") then
					Events.Publish("OnPlayerJoinTeam", id, ent)
				end
			end
		end
	elseif name == "player_death" then
		-- Decay is handled globally by heartbeat now
	elseif name == "game_newmap" or name == "round_end" or name == "teamplay_round_start" then
		-- Reset session state on map change, round end, and round start
		-- This handles matchmaking-style games where rounds = sessions
		persistActiveSessionPlayers()
		resetRuntimeSessionState()
	end
end

local function OnUnload()
	print("[CD] Unloading system...")
	engine.PlaySound("hl1/fvox/deactivated.wav")
	-- Save config synchronously — fast io.open write, acceptable stutter on unload.
	if G.Menu then
		Config.CreateCFG(G.Menu)
	end
	-- Database has its own DatabaseAutoSaveOnUnload listener that handles the full DB save.
end

-- Register callbacks
callbacks.Unregister("CreateMove", "CD_CreateMove")
callbacks.Register("CreateMove", "CD_CreateMove", OnCreateMove)
callbacks.Unregister("FireGameEvent", "CD_Events")
callbacks.Register("FireGameEvent", "CD_Events", OnFireGameEvent)
callbacks.Unregister("Draw", "CD_Draw")
callbacks.Register("Draw", "CD_Draw", OnDraw)
callbacks.Unregister("Unload", "CD_Unload")
callbacks.Register("Unload", "CD_Unload", OnUnload)

Init()
