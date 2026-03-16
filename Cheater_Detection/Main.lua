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
require("Cheater_Detection.Utils.Commands")
local Database = require("Cheater_Detection.Database.Database")
require("Cheater_Detection.Database.SteamHistory")

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
local detectorErrorSeen = {}
local lastDrawHeartbeatTick = 0
local lastCMTraceTick = 0 -- throttle for OnCreateMove diagnostics
local lastPStateNilLogTick = 0

local function isDebugEnabled()
	return G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
end

local function runDetector(detectorName, detectorFn, playerState)
	assert(detectorName, "runDetector: detectorName missing")
	assert(detectorFn, "runDetector: detectorFn missing")
	assert(playerState, "runDetector: playerState missing")

	local ok, err = pcall(detectorFn, playerState)
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
	EventBus.Reset()
	NotificationService.Init()

	-- Populate global menu config before anything else
	Config.LoadCFG()

	-- Require the Menu at the end of initialization
	require("Cheater_Detection.Misc.Visuals.Menu")

	-- Automate Database Fetch (Local then Online) - Respects AutoSync setting
	local Fetcher = require("Cheater_Detection.Database.Fetcher")
	if G.Menu and G.Menu.Main and G.Menu.Main.AutoSync ~= false then
		Fetcher.Start() -- Begin async local import followed by online sync
	else
		print("[CD] Auto-Sync disabled via config.")
	end

	print("[CD] System initialized.")

	-- Register Decay Heartbeat
	EventBus.Subscribe("DecayHeartbeat", function()
		PlayerCache.Hearthbeat()
	end)
end

-- [[ Callbacks ]]
local function OnCreateMove(cmd)
	-- Definitive check if we are actually connected to a game server
	local serverIP = engine.GetServerIP()
	local cmTick = globals.TickCount()
	if not serverIP then
		if (cmTick - lastCMTraceTick) >= 300 then
			lastCMTraceTick = cmTick
			print("[CD-CM] no serverIP, skipping")
		end
		hasSearchedGroup = false
		return
	end

	-- Auto-fetching is disabled per user request.
	-- Use the menu to manually refresh sources if needed.

	-- Scan currently encountered players
	local players = entities.FindByClass("CTFPlayer")
	if isDebugEnabled() and (cmTick - lastCMTraceTick) >= 132 then
		lastCMTraceTick = cmTick
		print(string.format("[CD-CM] tick=%d serverIP=%s players=%d", cmTick, tostring(serverIP), #players))
	end

	for i = 1, #players do
		local ply = players[i]
		if ply == entities.GetLocalPlayer() then
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
			runDetector("ValveCheck", ValveCheck.ProcessPlayer, pState)
			runDetector("SilentAim", SilentAim.ProcessPlayer, pState)
			runDetector("AntiAim", AntiAim.ProcessPlayer, pState)
			runDetector("DuckSpeed", DuckSpeed.ProcessPlayer, pState)
			runDetector("Bhop", Bhop.ProcessPlayer, pState)
			runDetector("WarpDT", WarpDT.ProcessPlayer, pState)
			runDetector("FakeLag", FakeLag.ProcessPlayer, pState)
		else
			if isDebugEnabled() and ply and ply:IsValid() then
				if (cmTick - lastPStateNilLogTick) >= 132 then
					lastPStateNilLogTick = cmTick
					local steamID = Common.GetSteamID64(ply)
					print(
						string.format(
							"[CD-CM] pState=nil idx=%d steamID=%s",
							ply:GetIndex(),
							tostring(steamID)
						)
					)
				end
			end
		end

		::continue::
	end
end

local function OnDraw()
	if G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true then
		local currentTick = globals.TickCount()
		if (currentTick - lastDrawHeartbeatTick) >= 132 then
			print("[CD] OnDraw heartbeat")
			lastDrawHeartbeatTick = currentTick
		end
	end
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
		-- Decay is handled globally by heartbeat now
	elseif name == "game_newmap" or name == "teamplay_round_start" then
		-- Reset all "checked" states on map change so we re-verify everyone
		PlayerCache.ResetCheckedState()
		PlayerCache.Cleanup()
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
