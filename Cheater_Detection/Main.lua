--[[ Main.lua
     New Core Entry Point for Cheater Detection Service.
]]
client.Command("clear", true)

---@diagnostic disable: undefined-global, undefined-field
-- [[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Config = require("Cheater_Detection.Utils.Config")
local Events = require("Cheater_Detection.Core.Events")
Events.Reset()
local Constants = require("Cheater_Detection.Core.constants")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Scheduler = require("Cheater_Detection.Core.scheduler")
local DirtySystem = require("Cheater_Detection.Core.DirtySystem")
local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local Common = require("Cheater_Detection.Utils.Common")
require("Cheater_Detection.Utils.Commands")
require("Cheater_Detection.Misc.ChatPrefix")
require("Cheater_Detection.Misc.Vote_Reveal")
require("Cheater_Detection.Misc.Auto_Vote")
require("Cheater_Detection.Misc.Visuals.Menu")
-- Bundler must see a static require; dynamic tryRequireEmbed() in Database.lua is not traced.
require("Cheater_Detection.Database.Static_Embeded_Databases.unified_embedded")
local Database = require("Cheater_Detection.Database.Database")
require("Cheater_Detection.Database.SteamHistory")
local Fetcher = require("Cheater_Detection.Database.Fetcher")

-- Combat event hub (must load before detectors so OnHitscanHit/OnFireBullets are available)
require("Cheater_Detection.Core.CombatEvents")

-- Detectors
local ValveCheck            = require("Cheater_Detection.detectors.valve_check")
local SilentAim             = require("Cheater_Detection.detectors.silent_aim")
local AimLock               = require("Cheater_Detection.detectors.aim_lock")
local AntiAim               = require("Cheater_Detection.detectors.antiaim")
local DuckSpeed             = require("Cheater_Detection.detectors.duck_speed")
local Bhop                  = require("Cheater_Detection.detectors.bhop")
local WarpDT                = require("Cheater_Detection.detectors.warp_dt")
local FakeLag               = require("Cheater_Detection.detectors.fake_lag")
local CosmeticAbuse         = require("Cheater_Detection.detectors.cosmetic_abuse")

local HistoryManager        = require("Cheater_Detection.Utils.HistoryManager")
local DetectionConfig       = require("Cheater_Detection.Utils.DetectionConfig")
local JoinNotifications     = require("Cheater_Detection.Misc.JoinNotifications")
local _profilerOk, Profiler = pcall(require, "Profiler")
if not _profilerOk then
	Profiler = { Begin = function() end, End = function() end, SetVisible = function() end, SetContext = function() end, Draw = function() end }
end

-- Actions
local NotificationService = require("Cheater_Detection.services.notification_service")
local Visuals             = require("Cheater_Detection.actions.visuals")
local BridgePrompt        = require("Cheater_Detection.services.bridge_prompt")

local lastDetectorTick    = -1
local activePlayers       = {}

local sessionState        = {
	groupSearched = false,
	valveDisconnectTriggered = false,
	inServer = false,
	cleanedFriendIDs = {},
	lastProfilerEnabled = nil,
}

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
	local name = state.wrap:GetName() or fallbackName
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
	if sessionState.valveDisconnectTriggered or not playerState or not playerState.id then
		return
	end
	if not isValveAutoDisconnectEnabled() then
		return
	end
	if (playerState.flags & Constants.Flags.VALVE) == 0 then
		return
	end

	sessionState.valveDisconnectTriggered = true
	JoinNotifications.SendValveAlert({
		name = playerState.wrap:GetName() or playerState.id,
		tail = "is in the server - Leaving game",
		allowParty = false,
	})
	client.Command("disconnect", true)
end

local function persistActiveSessionPlayers()
	-- Use DirtySystem - only persist players with dirty SESSION flag
	local dirtyPlayers = DirtySystem.GetDirtyPlayers("session")

	for _, id in ipairs(dirtyPlayers) do
		local state = PlayerCache.GetByID(id)
		if state then
			persistSessionPlayerState(id, state, nil)
		end
		-- Clear the dirty flag after persisting
		DirtySystem.ClearDirty(id, "session")
	end
end

local function resetRuntimeSessionState()
	sessionState.groupSearched = false
	sessionState.valveDisconnectTriggered = false
	sessionState.cleanedFriendIDs = {}
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

local function isMenuProfilerEnabled()
	local adv = G.Menu and G.Menu.Advanced
	return adv and adv["profiler"] == true
end

-- [[ Initialization ]]
local function Init()
	JoinNotifications.Init()
	NotificationService.Init()
	BridgePrompt.Init()
	engine.PlaySound("hl1/fvox/activated.wav")

	-- Filter out engine warnings for out-of-range eye angles (Anti-Aim noise)
	client.Command('con_filter_enable 1; con_filter_text_out "Out-of-range value"', true)

	-- Populate global menu config before anything else
	Config.LoadCFG()

	-- Startup notification for missing SteamHistory API key
	local shCfg = G.Menu and G.Menu.Misc and G.Menu.Misc.SteamHistory
	if not shCfg or not shCfg.ApiKey or shCfg.ApiKey == "" then
		print("[CD] SteamHistory API key not set - configure in Misc tab or config.cfg")
		client.ChatPrintf("[CD] SteamHistory API key not set! Go to Misc tab to configure.")
	end

	DetectionConfig.RegisterWithHistoryManager()
	CosmeticAbuse.Init()

	-- Auto-sync: HTTP spread via scheduler + HttpQueue; parsing merges run in full per response/file.
	if G.Menu and G.Menu.Main and G.Menu.Main.AutoSync ~= false then
		Fetcher.Start()
	else
		print("[CD] Auto-Sync disabled via config.")
	end

	print("[CD] System initialized.")
end

-- [[ Callbacks ]]
local function OnCreateMove(cmd)
	-- Game logic only on CreateMove (never on Draw).
	Evidence.ApplyDecay()
	Scheduler.Tick()

	-- SetContext is expensive; Begin/End already no-op when profiler overlay is off.
	if isMenuProfilerEnabled() then
		Profiler.SetContext("tick")
	end
	Profiler.Begin("CreateMove_Total")
	local isGameUI = engine.IsGameUIVisible()
	if isGameUI then
		Profiler.End("CreateMove_Total")
		return
	end

	-- Definitive check if we are actually connected to a game server
	local serverIP = engine.GetServerIP()
	if not serverIP then
		if sessionState.inServer then
			persistActiveSessionPlayers()
			Database.SaveDatabase()
			resetRuntimeSessionState()
			sessionState.inServer = false
		else
			sessionState.groupSearched = false
			sessionState.valveDisconnectTriggered = false
		end
		Profiler.End("CreateMove_Total")
		return
	end
	sessionState.inServer = true

	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsValid() then
		Profiler.End("CreateMove_Total")
		return
	end

	if sessionState.valveDisconnectTriggered then
		Profiler.End("CreateMove_Total")
		return
	end

	Events.DispatchEngineEvent("CreateMove", cmd)

	local menu             = G.Menu
	local adv              = menu.Advanced

	local enableValveCheck = menu.Main.ValveCheck == true
	local enableSilent     = adv.SilentAimbot == true
	local enableAimLock    = enableSilent and adv.AimLock ~= false
	local enableAntiAim    = adv.AntiAim == true
	local enableDuckSpeed  = adv.DuckSpeed == true
	local enableBhop       = adv.Bhop == true
	local enableWarpDT     = adv["Warp"] == true
	local enableChoke      = adv.Choke == true
	local enableCosmetics  = adv.Cosmetics == true

	if not (enableValveCheck or enableSilent or enableAntiAim or enableDuckSpeed
			or enableBhop or enableWarpDT or enableChoke or enableCosmetics) then
		Profiler.End("CreateMove_Total")
		return
	end

	-- Rate-limited scan status logging (once every 5 seconds)
	local now = globals.RealTime()
	if Common.IsLogCategoryEnabled("All") then
		if not sessionState.lastScanLogTime or (now - sessionState.lastScanLogTime) >= 5.0 then
			sessionState.lastScanLogTime = now
			print(string.format(
				"[CD][SCAN] valve=%s silent=%s antiaim=%s duck=%s bhop=%s warp=%s choke=%s cosmetics=%s",
				tostring(enableValveCheck), tostring(enableSilent), tostring(enableAntiAim),
				tostring(enableDuckSpeed), tostring(enableBhop), tostring(enableWarpDT),
				tostring(enableChoke), tostring(enableCosmetics)
			))
		end
	end

	local historyEnabled = enableSilent or enableWarpDT or enableChoke

	if not sessionState.groupSearched then
		SteamLookup.RefreshValveGroup()
		sessionState.groupSearched = true
	end
	-- TickGroupFetch is paced in Scheduler.Tick, not the CreateMove hot path.

	-- Sync authoritative live-player list and tick entity cache once per tick
	Profiler.Begin("PlayerCache_Sync")
	-- DEBUG: skip SyncTick entirely to measure baseline FPS
	-- if false then
	PlayerCache.SyncTick()
	-- end
	Profiler.End("PlayerCache_Sync")

	-- Skip all detector work on frames where the game tick hasn't advanced
	-- (CreateMove fires per frame, game ticks at 66 Hz)
	local curTick = globals.TickCount()
	if curTick == lastDetectorTick then
		Profiler.End("CreateMove_Total")
		return
	end
	lastDetectorTick = curTick

	local isDebug = isDebugEnabled()
	local localID = tostring(Common.GetSteamID64(localPlayer) or "")
	local stateTable = PlayerCache.GetActiveTable()

	-- Pre-filter active players into a flat list (reuse module-level table)
	Profiler.Begin("PlayerScan_Loop")
	for k = 1, #activePlayers do activePlayers[k] = nil end
	for id, existingState in pairs(stateTable) do
		local pdata = existingState.pdata
		if not pdata then goto continue end

		if pdata.isDormant then
			if historyEnabled and not existingState.wasDormant then
				HistoryManager.ClearPlayer(id)
				existingState.wasDormant = true
			end
			goto continue
		end

		if not pdata.isAlive then goto continue end

		existingState.wasDormant = false

		if not isDebug then
			if id == localID then
				if not sessionState.cleanedFriendIDs[id] then
					sessionState.cleanedFriendIDs[id] = true
					Database.RemoveCheater(id)
					existingState.wrap:SetPriority(0)
				end
				goto continue
			end
			if existingState.isFriend then
				local friendID = existingState.id
				if friendID and not sessionState.cleanedFriendIDs[friendID] then
					sessionState.cleanedFriendIDs[friendID] = true
					Database.RemoveCheater(friendID)
				end
				goto continue
			end
		end

		activePlayers[#activePlayers + 1] = existingState
		::continue::
	end

	if enableSilent then
		Profiler.Begin("History_SilentAim")
		for _, pState in ipairs(activePlayers) do
			DetectionConfig.RecordHistory(pState.wrap, "SilentAim")
		end
		Profiler.End("History_SilentAim")
	end

	-- ValveCheck runs via scheduler + DirtySystem "checks" (once per player per map)
	-- Auto-disconnect enforcement still runs every tick for confirmed Valve employees
	if enableValveCheck then
		for _, pState in ipairs(activePlayers) do
			enforceValveAutoDisconnect(pState)
			if sessionState.valveDisconnectTriggered then
				Profiler.End("PlayerScan_Loop")
				Profiler.End("CreateMove_Total")
				return
			end
		end
	end

	if enableSilent then
		Profiler.Begin("SilentAim")
		for _, pState in ipairs(activePlayers) do
			-- Only process players with pending shots from damage events
			if SilentAim.HasPendingWork(pState) then
				SilentAim.ProcessPlayer(pState)
			end
			-- Only process aimlock for players with recent victims
			if enableAimLock and AimLock.HasWork(pState) then
				AimLock.ProcessPlayer(pState)
			end
		end
		Profiler.End("SilentAim")
	end

	if enableAntiAim then
		Profiler.Begin("AntiAim")
		for _, pState in ipairs(activePlayers) do
			-- Only check players that need anti-aim detection
			if AntiAim.HasWork(pState) then
				AntiAim.ProcessPlayer(pState, cmd)
			end
		end
		Profiler.End("AntiAim")
	end

	if enableDuckSpeed then
		Profiler.Begin("DuckSpeed")
		for _, pState in ipairs(activePlayers) do
			DuckSpeed.ProcessPlayer(pState)
		end
		Profiler.End("DuckSpeed")
	end

	if enableBhop then
		Profiler.Begin("Bhop")
		for _, pState in ipairs(activePlayers) do
			-- Only check players who are midair (potential bhop)
			if Bhop.HasWork(pState) then
				Bhop.ProcessPlayer(pState)
			end
		end
		Profiler.End("Bhop")
	end

	if enableWarpDT then
		Profiler.Begin("WarpDT")
		for _, pState in ipairs(activePlayers) do
			WarpDT.ProcessPlayer(pState)
		end
		Profiler.End("WarpDT")
	end

	if enableChoke then
		Profiler.Begin("FakeLag")
		for _, pState in ipairs(activePlayers) do
			FakeLag.ProcessPlayer(pState)
		end
		Profiler.End("FakeLag")
	end

	if enableCosmetics then
		Profiler.Begin("CosmeticAbuse")
		for _, pState in ipairs(activePlayers) do
			CosmeticAbuse.ProcessPlayer(pState)
		end
		Profiler.End("CosmeticAbuse")
	end

	Profiler.End("PlayerScan_Loop")
	Profiler.End("CreateMove_Total")
end

local function OnDraw()
	local profilerEnabled = isMenuProfilerEnabled()

	if sessionState.lastProfilerEnabled ~= profilerEnabled then
		sessionState.lastProfilerEnabled = profilerEnabled
		Profiler.SetVisible(profilerEnabled)
	end

	if profilerEnabled then
		Profiler.SetContext("frame")
		Profiler.Draw()
	end

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
			HistoryManager.ClearPlayer(id)
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
	-- Save config synchronously â€” fast io.open write, acceptable stutter on unload.
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
