--[[ detectors/valve_check.lua
     Valve Employee Detector

     Detection Layers:
       1. SteamID64 static list (instant)
       2. Item badge / Valve-quality item (run via deferred checks)
       3. Async Steam Group + ban profile check
          - Retried every PROFILE_RECHECK_INTERVAL seconds if not yet confirmed
          - A failed/empty HTTP response does NOT permanently set externalChecked;
            the player will be re-queued on the next interval.

     Console debug output (requires G.Menu.Advanced.debug = true):
       Logs every check attempt, result, and skip reason.
]]

local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local ValveData = require("Cheater_Detection.data.valve_data")
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")
local Constants = require("Cheater_Detection.Core.constants")
local Events = require("Cheater_Detection.Core.Events")
local Common = require("Cheater_Detection.Utils.Common")
local Database = require("Cheater_Detection.Database.Database")
local Logger = require("Cheater_Detection.Utils.Logger")
local G = require("Cheater_Detection.Utils.Globals")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local SteamHistory = require("Cheater_Detection.Database.SteamHistory")

local ValveCheck = {}

-- How often (seconds) to re-attempt the async profile check per player
local PROFILE_RECHECK_INTERVAL = 120 -- Re-verify every 2 minutes

-- Track last async profile-check TIME per player: id -> CurTime
-- (NOT a boolean; we re-check periodically even after success)
local lastProfileCheck = {}

-- Track if Layer 1 logging has occurred for a player: id -> boolean
local layer1Logged = {}
local deferredQueue = {}
local deferredSweepRequested = true

local function queueDeferredCheck(id)
	if id then
		deferredQueue[tostring(id)] = true
	end
end

local function queueDeferredSweep()
	deferredSweepRequested = true
end

local function runDeferredSweep()
	if not deferredSweepRequested then
		return
	end
	deferredSweepRequested = false
	for id, state in pairs(PlayerCache.GetActiveTable()) do
		local checkFlags = PlayerCache.EnsureCheckFlags(state)
		if not checkFlags.valveItemBadgeChecked
			or not checkFlags.valveGroupChecked
			or not checkFlags.vacBanChecked
			or not checkFlags.commBanChecked
		then
			deferredQueue[id] = true
		end
	end
end

-- Layer 1: Check both static tables (valve_data AND ValveEmployees)
local function isKnownValveID64(s64)
	if not s64 then
		return false
	end
	local idStr = tostring(s64)
	local key = idStr:match("^%s*(.-)%s*$") or idStr
	if key == "" then
		return false
	end

	if ValveData.KnownSteamID64s[key] == true then
		return true
	end
	if ValveEmployees.IsEmployee and ValveEmployees.IsEmployee(key) then
		return true
	end
	if type(ValveEmployees.List) == "table" and ValveEmployees.List[key] then
		return true
	end
	return false
end

-- Layer 1b: Legacy Steam2 fallback
local function isKnownValveIDSteam2(s2)
	return s2 ~= nil and ValveData.ManualIDsSteam2[s2] == true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Apply VALVE flag (idempotent – only logs/saves on first apply)
-- ──────────────────────────────────────────────────────────────────────────────
local function applyValveFlag(playerState, reason)
	local oldFlags = playerState.flags
	playerState.flags = playerState.flags | Constants.Flags.VALVE

	if playerState.flags ~= oldFlags then
		printc(
			255,
			215,
			0,
			255,
			string.format(
				"[ValveCheck] VALVE EMPLOYEE detected! SteamID64=%s  Name=%s  Reason=%s",
				playerState.id,
				playerState.wrap:GetName(),
				reason
			)
		)
		Database.UpsertCheater(playerState.id, {
			name = playerState.wrap:GetName(),
			reason = reason,
			flags = playerState.flags,
			score = playerState.score,
		})
		Events.Publish("OnPlayerStateChange", playerState, reason)
	end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Apply VAC ban flag
-- ──────────────────────────────────────────────────────────────────────────────
local function applyVacFlag(playerState)
	local oldFlags = playerState.flags
	playerState.flags = playerState.flags | Constants.Flags.VAC_BANNED
	if playerState.flags ~= oldFlags then
		Logger.Info(
			"ValveCheck",
			string.format("VAC ban confirmed – SteamID64=%s  Name=%s", playerState.id, playerState.wrap:GetName())
		)
		Database.UpsertCheater(playerState.id, {
			name = playerState.wrap:GetName(),
			reason = "VAC Ban on Record",
			flags = playerState.flags,
			score = playerState.score,
		})
		Events.Publish("OnPlayerStateChange", playerState, "VAC Ban on Record")
	end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Apply Community/Trade ban flag
-- ──────────────────────────────────────────────────────────────────────────────
local function applyCommBanFlag(playerState)
	local oldFlags = playerState.flags
	playerState.flags = playerState.flags | Constants.Flags.COMM_BANNED
	if playerState.flags ~= oldFlags then
		Logger.Info(
			"ValveCheck",
			string.format(
				"Community/Trade ban confirmed – SteamID64=%s  Name=%s",
				playerState.id,
				playerState.wrap:GetName()
			)
		)
		Database.UpsertCheater(playerState.id, {
			name = playerState.wrap:GetName(),
			reason = "Community/Trade Ban",
			flags = playerState.flags,
			score = playerState.score,
		})
		Events.Publish("OnPlayerStateChange", playerState, "Community/Trade Ban")
	end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Layer 2: Item + Badge check (pcall-safe)
-- ──────────────────────────────────────────────────────────────────────────────
local function checkPlayerItems(ply)
	for slot = 0, 18 do
		local okEnt, ent = pcall(ply.GetEntityForLoadoutSlot, ply, slot)
		if okEnt and ent then
			local okQ, quality = pcall(ent.GetPropInt, ent, "m_iEntityQuality")
			local okD, defIdx = pcall(ent.GetPropInt, ent, "m_iItemDefinitionIndex")

			if okQ and quality == ValveData.QualityID then
				return true, "Valve-Quality Item (slot " .. slot .. ")"
			end
			if okD and defIdx == ValveData.BadgeDefIndex then
				return true, "Valve Employee Badge (slot " .. slot .. ")"
			end
		end
	end
	return false, ""
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Main processor
-- ──────────────────────────────────────────────────────────────────────────────
function ValveCheck.ProcessPlayer(playerState)
	if not playerState or not playerState.id then
		return
	end

	local id = tostring(playerState.id)
	local now = globals.CurTime()
	local isDebug = Common.IsDebugEnabled()
	local checkFlags = PlayerCache.EnsureCheckFlags(playerState)
	local useSteamHistory = SteamHistory.IsEnabled and SteamHistory.IsEnabled()
	runDeferredSweep()

	-- Skip Bots (Non-SteamID64)
	if not id:match("^7656119%d+$") or #id ~= 17 then
		return
	end

	-- Skip if Scanner or ValveCheck is disabled
	if not G or not G.Menu or not G.Menu.Scanner or not G.Menu.Scanner.ValveCheck then
		return
	end

	-- Skip if already definitively flagged as Valve or Cheater
	if (playerState.flags & (Constants.Flags.VALVE | Constants.Flags.CHEATER)) ~= 0 then
		return
	end

	-- Skip local player unless debug mode is enabled
	if not isDebug then
		local localPlayer = PlayerCache.GetLocal()
		if localPlayer then
			local localSteamID = localPlayer:GetSteamID64()
			if localSteamID and tostring(localSteamID) == tostring(id) then
				return -- Skip local player check
			end
		end
	end

	-- ── Layer 1: SteamID64 instant check ──────────────────────────────────────
	-- Always log in debug so user can verify their ID matches what the engine sees,
	-- but only do it ONCE per player to avoid spamming the console every tick!
	if isDebug and not layer1Logged[id] then
		layer1Logged[id] = true
		Logger.Debug(
			"ValveCheck",
			string.format(
				"Processing ID=%s Name=%s  inKnownList=%s",
				tostring(id),
				playerState.wrap:GetName(),
				tostring(isKnownValveID64(id))
			)
		)
	end

	if not checkFlags.valveID64Checked and isKnownValveID64(id) then
		checkFlags.valveID64Checked = true
		checkFlags.valveGroupChecked = true
		checkFlags.vacBanChecked = true
		checkFlags.commBanChecked = true
		applyValveFlag(playerState, "Known Valve SteamID")
		return
	end
	checkFlags.valveID64Checked = true

	-- Keep heavy checks event-driven to avoid intrusive per-frame cost.
	if not deferredQueue[id]
		and (
			not checkFlags.valveItemBadgeChecked
			or not checkFlags.valveGroupChecked
			or not checkFlags.vacBanChecked
			or not checkFlags.commBanChecked
		)
	then
		deferredQueue[id] = true
	end
	if not deferredQueue[id] then
		return
	end

	-- ── Layer 1b: Legacy Steam2 fallback ──────────────────────────────────────
	local ply = playerState.wrap:GetRawEntity()
	if ply and not checkFlags.valveSteam2Checked then
		local s2 = Common.GetSteamID(ply)
		if isKnownValveIDSteam2(s2) then
			checkFlags.valveSteam2Checked = true
			checkFlags.valveGroupChecked = true
			checkFlags.vacBanChecked = true
			checkFlags.commBanChecked = true
			if isDebug then
				Logger.Debug("ValveCheck", id .. " matched legacy Steam2 list (" .. tostring(s2) .. ")")
			end
			applyValveFlag(playerState, "Known Valve SteamID (Legacy)")
			return
		end
		checkFlags.valveSteam2Checked = true
	end

	-- ── Layer 2: Item / Badge check (ONCE per session) ───────────────────────
	if not checkFlags.valveItemBadgeChecked then
		checkFlags.valveItemBadgeChecked = true
		playerState.itemChecked = true
		if ply then
			if isDebug then
				Logger.Debug("ValveCheck", id .. " – running item/badge check")
			end
			local found, reason = checkPlayerItems(ply)
			if found then
				if isDebug then
					Logger.Debug("ValveCheck", id .. " – item/badge HIT: " .. reason)
				end
				checkFlags.valveGroupChecked = true
				checkFlags.vacBanChecked = true
				checkFlags.commBanChecked = true
				applyValveFlag(playerState, reason)
				return
			else
				if isDebug then
					Logger.Debug("ValveCheck", id .. " – item/badge: no match")
				end
			end
		end
	end

	if useSteamHistory then
		if not checkFlags.valveGroupChecked then
			if SteamLookup.IsGroupMemberID64(id) then
				checkFlags.valveGroupChecked = true
				applyValveFlag(playerState, "Valve Steam Group Member")
			elseif SteamLookup.IsGroupFetchComplete and SteamLookup.IsGroupFetchComplete() then
				checkFlags.valveGroupChecked = true
			end
		end

		if checkFlags.steamHistoryChecked and checkFlags.valveGroupChecked then
			checkFlags.vacBanChecked = true
			checkFlags.commBanChecked = true
			playerState.flags = playerState.flags | Constants.Flags.CHECKED
			playerState.externalChecked = true
			deferredQueue[id] = nil
		end
		return
	end

	-- ── Layer 3: Async profile check (VAC / Comm ban / Valve Group) ──────────
	if not checkFlags.profileLookupQueued then
		local lastProfile = lastProfileCheck[id]
		if not lastProfile or (now - lastProfile > PROFILE_RECHECK_INTERVAL) then
			lastProfileCheck[id] = now
			checkFlags.profileLookupQueued = true
			if isDebug then
				Logger.Debug("ValveCheck", id .. " – queuing async profile check")
			end

			SteamLookup.CheckProfileAsync(id, function(results)
				if not results then
					checkFlags.profileLookupQueued = false
					deferredQueue[id] = true
					if isDebug then
						Logger.Debug("ValveCheck", id .. " – async profile check returned nil (HTTP failed)")
					end
					-- Reset timer so it retries sooner (10s) instead of waiting 2 min
					lastProfileCheck[id] = now - (PROFILE_RECHECK_INTERVAL - 10)
					return
				end

				if isDebug then
					Logger.Debug(
						"ValveCheck",
						string.format(
							"%s – profile check result: isValve=%s vacBanned=%s tradeBanned=%s",
							id,
							tostring(results.isValve),
							tostring(results.vacBanned),
							tostring(results.tradeBanned)
						)
					)
				end

				if results.isValve then
					applyValveFlag(playerState, "Valve Steam Group Member")
				end
				checkFlags.valveGroupChecked = true
				if results.vacBanned then
					applyVacFlag(playerState)
				end
				checkFlags.vacBanChecked = true
				if results.tradeBanned then
					applyCommBanFlag(playerState)
				end
				checkFlags.commBanChecked = true

				-- Mark checked so we NEVER run Layer 3 again for this player this session
				playerState.profileChecked = true
				playerState.externalChecked = true
				playerState.flags = playerState.flags | Constants.Flags.CHECKED
				deferredQueue[id] = nil
			end)
		end
	end
end

-- Reset per-player timers on disconnect so rejoining players are re-checked
Events.Subscribe("OnPlayerDisconnect", function(id)
	lastProfileCheck[id] = nil
	deferredQueue[id] = nil
end)

Events.Subscribe("OnPlayerJoinTeam", function(id, _ent)
	queueDeferredCheck(id)
end)

local function onRoundOrMap(_event)
	queueDeferredSweep()
end

local function onLocalSpawnOrDeath(event)
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer then
		return
	end
	local userID = event:GetInt("userid")
	local ent = entities.GetByUserID(userID)
	if ent and ent:GetIndex() == localPlayer:GetIndex() then
		queueDeferredSweep()
	end
end

Events.Register("FireGameEvent", "ValveCheck_NewMapSweep", onRoundOrMap, "game_newmap")
Events.Register("FireGameEvent", "ValveCheck_RoundStartSweep", onRoundOrMap, "teamplay_round_start")
Events.Register("FireGameEvent", "ValveCheck_LocalSpawnSweep", onLocalSpawnOrDeath, "player_spawn")
Events.Register("FireGameEvent", "ValveCheck_LocalDeathSweep", onLocalSpawnOrDeath, "player_death")

return ValveCheck
