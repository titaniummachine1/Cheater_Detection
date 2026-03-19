--[[ Main.lua
     New Core Entry Point for Cheater Detection Service.
]]
---@diagnostic disable: undefined-global, undefined-field
-- [[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Config = require("Cheater_Detection.Utils.Config")
local Events = require("Cheater_Detection.Core.Events")
local Constants = require("Cheater_Detection.Core.constants")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local Scheduler = require("Cheater_Detection.Core.scheduler")
local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local Common = require("Cheater_Detection.Utils.Common")
require("Cheater_Detection.Utils.Commands")
require("Cheater_Detection.Misc.ChatPrefix")
require("Cheater_Detection.Misc.Visuals.Menu")
local Database = require("Cheater_Detection.Database.Database")
require("Cheater_Detection.Database.SteamHistory")
local Fetcher = require("Cheater_Detection.Database.Fetcher")

-- Detectors
local ValveCheck = require("Cheater_Detection.detectors.valve_check")
local SilentAim = require("Cheater_Detection.detectors.silent_aim")
local AntiAim = require("Cheater_Detection.detectors.antiaim")
local DuckSpeed = require("Cheater_Detection.detectors.duck_speed")
local Bhop = require("Cheater_Detection.detectors.bhop")
local WarpDT = require("Cheater_Detection.detectors.warp_dt")
local FakeLag = require("Cheater_Detection.detectors.fake_lag")

local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local JoinNotifications = require("Cheater_Detection.Misc.JoinNotifications")

-- Actions
local NotificationService = require("Cheater_Detection.services.notification_service")
local Visuals = require("Cheater_Detection.actions.visuals")

local hasSearchedGroup = false
local detectorErrorSeen = {}
local valveDisconnectTriggered = false
local wasInServer = false

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
	for id, state in pairs(PlayerCache.GetActiveTable()) do
		persistSessionPlayerState(id, state, nil)
	end
end

local function resetRuntimeSessionState()
	hasSearchedGroup = false
	valveDisconnectTriggered = false
	PlayerCache.ResetCheckedState()
	PlayerCache.Cleanup()
end

local function isDebugEnabled()
	return Common.IsDebugEnabled()
end

local function runDetector(detectorName, detectorFn, playerState, ...)
	local ok, err = pcall(detectorFn, playerState, ...)
	if not ok then
		if not detectorErrorSeen[detectorName] then
			print(string.format("[CD][DetectorError] %s failed: %s", detectorName, tostring(err)))
			detectorErrorSeen[detectorName] = true
		end
		return false
	end

	if detectorErrorSeen[detectorName] then
		detectorErrorSeen[detectorName] = nil
	end
	return true
end

-- [[ Initialization ]]
local function Init()
	Events.Reset()
	NotificationService.Init()

	-- Populate global menu config before anything else
	Config.LoadCFG()

	-- Automate Database Fetch (Local then Online) - Respects AutoSync setting
	if G.Menu and G.Menu.Main and G.Menu.Main.AutoSync ~= false then
		Fetcher.Start() -- Begin async local import followed by online sync
	else
		print("[CD] Auto-Sync disabled via config.")
	end

	print("[CD] System initialized.")

	-- Register Decay Heartbeat
	Events.Subscribe("DecayHeartbeat", function()
		PlayerCache.Heartbeat()
	end)
end

-- [[ Callbacks ]]
local function OnCreateMove(cmd)
	if engine.IsGameUIVisible() or engine.Con_IsVisible() then
		hasSearchedGroup = false
		valveDisconnectTriggered = false
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
		return
	end
	wasInServer = true

	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsValid() then
		hasSearchedGroup = false
		valveDisconnectTriggered = false
		return
	end

	if not hasSearchedGroup then
		SteamLookup.RefreshValveGroup()
		hasSearchedGroup = true
	end
	SteamLookup.TickGroupFetch()

	-- Auto-fetching is disabled per user request.
	-- Use the menu to manually refresh sources if needed.

	-- Scan currently encountered players
	local players = entities.FindByClass("CTFPlayer")

	for i = 1, #players do
		local ply = players[i]
		local isLocalPlayer = (ply == localPlayer)
		if isLocalPlayer and not isDebugEnabled() then
			goto continue
		end

		local pState = PlayerCache.Get(ply)
		if pState then
			if isDebugEnabled() then
				assert(pState.wrap, "OnCreateMove: pState.wrap missing for id=" .. tostring(pState.id))
				assert(pState.id, "OnCreateMove: pState.id missing")
			end

			-- Update history snapshot first
			HistoryManager.Push(pState.wrap)

			-- Layer 1-3 Detections
			runDetector("ValveCheck", ValveCheck.ProcessPlayer, pState, cmd)
			runDetector("SilentAim", SilentAim.ProcessPlayer, pState, cmd)
			runDetector("AntiAim", AntiAim.ProcessPlayer, pState, cmd)
			runDetector("DuckSpeed", DuckSpeed.ProcessPlayer, pState, cmd)
			runDetector("Bhop", Bhop.ProcessPlayer, pState, cmd)
			runDetector("WarpDT", WarpDT.ProcessPlayer, pState, cmd)
			runDetector("FakeLag", FakeLag.ProcessPlayer, pState, cmd)
			enforceValveAutoDisconnect(pState)
		end

		::continue::
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
		local id = nil
		if ent then
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
			if ent then
				local id = tostring(Common.GetSteamID64(ent))
				if id and id:match("^7656119%d+$") then
					Events.Publish("OnPlayerJoinTeam", id, ent)
				end
			end
		end
	elseif name == "player_death" then
		-- Decay is handled globally by heartbeat now
	elseif name == "game_newmap" or name == "teamplay_round_start" then
		-- Reset all "checked" states on map change so we re-verify everyone
		persistActiveSessionPlayers()
		resetRuntimeSessionState()
	end
end

local function OnUnload()
	print("[CD] Unloading system...")
	-- Save config synchronously — fast io.open write, acceptable stutter on unload.
	if G.Menu then
		Config.CreateCFG(G.Menu)
	end
	-- Database has its own DatabaseAutoSaveOnUnload listener that handles the full DB save.
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
