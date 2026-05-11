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
local VERBOSE_DEBUG_LOGS = false

-- How often (seconds) to re-attempt the async profile check per player
local PROFILE_RECHECK_INTERVAL = 120 -- Re-verify every 2 minutes

-- Track last async profile-check TIME per player: id -> CurTime
-- (NOT a boolean; we re-check periodically even after success)
local lastProfileCheck = {}

-- Track if Layer 1 logging has occurred for a player: id -> boolean
local layer1Logged = {}
local deferredQueue = {}
local deferredSweepRequested = true
local pendingBadgeProfileVerification = {}

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
		local checkFlags = state.checkFlags
		if
			not checkFlags
			or not checkFlags.valveItemBadgeChecked
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

local function isKnownStaticValvePlayer(playerState)
	if not playerState or not playerState.id then
		return false
	end

	if isKnownValveID64(playerState.id) then
		return true
	end

	if playerState.wrap and playerState.wrap.GetRawEntity then
		local rawEntity = playerState.wrap:GetRawEntity()
		if rawEntity then
			local steam2 = Common.GetSteamID(rawEntity)
			if isKnownValveIDSteam2(steam2) then
				return true
			end
		end
	end

	return false
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Apply VALVE flag (idempotent – only logs/saves on first apply)
-- ──────────────────────────────────────────────────────────────────────────────
local function applyValveFlag(playerState, reason)
	local oldFlags = playerState.flags
	playerState.flags = playerState.flags | Constants.Flags.VALVE

	if playerState.flags ~= oldFlags then
		local inStaticValveList = isKnownStaticValvePlayer(playerState)
		local reasonForDatabase = reason
		local staticTag = nil
		if not inStaticValveList then
			reasonForDatabase = reason .. " (Not in static Valve list)"
			staticTag = "ValveDynamic"
		end

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
			reason = reasonForDatabase,
			flags = playerState.flags,
			score = playerState.score,
			Static = staticTag,
		})
		if not inStaticValveList then
			Logger.Info(
				"ValveCheck",
				string.format("Discovered non-static Valve employee saved to database: %s", tostring(playerState.id))
			)
		end
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

local function readItemInt(ent, propName)
	local ok, value = pcall(ent.GetPropInt, ent, propName)
	if not ok or type(value) ~= "number" then
		return nil
	end
	return value
end

local function isVerifiedWearableItemEntity(ent)
	if not ent then
		return false
	end

	local okValid, isValid = pcall(ent.IsValid, ent)
	if not okValid or not isValid then
		return false
	end

	local okClass, className = pcall(ent.GetClass, ent)
	if not okClass or type(className) ~= "string" then
		return false
	end
	if not className:find("Wearable", 1, true) then
		return false
	end

	local defIndex = readItemInt(ent, "m_iItemDefinitionIndex")
	local itemIDHigh = readItemInt(ent, "m_iItemIDHigh")
	local itemIDLow = readItemInt(ent, "m_iItemIDLow")
	if defIndex == nil or itemIDHigh == nil or itemIDLow == nil then
		return false
	end
	if defIndex <= 0 then
		return false
	end
	if (itemIDHigh == 0 and itemIDLow == 0) or (itemIDHigh == -1 and itemIDLow == -1) then
		return false
	end

	return true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Layer 2: Item + Badge check (pcall-safe)
-- ──────────────────────────────────────────────────────────────────────────────
local function checkPlayerItems(ply)
	for slot = 0, 18 do
		local okEnt, ent = pcall(ply.GetEntityForLoadoutSlot, ply, slot)
		if okEnt and isVerifiedWearableItemEntity(ent) then
			local quality = readItemInt(ent, "m_iEntityQuality")
			local defIdx = readItemInt(ent, "m_iItemDefinitionIndex")

			if quality == ValveData.QualityID then
				return true, "Valve-Quality Item (slot " .. slot .. ")"
			end
			if defIdx == ValveData.BadgeDefIndex then
				return true, "Valve Employee Badge (slot " .. slot .. ")"
			end
		end
	end
	return false, ""
end

local lastCheckTick = {}
local CHECK_INTERVAL_TICKS = 33 -- ~0.5s at 66Hz

-- ──────────────────────────────────────────────────────────────────────────────
-- Main processor
-- ──────────────────────────────────────────────────────────────────────────────
function ValveCheck.ProcessPlayer(playerState)
	if not playerState or not playerState.id then
		return
	end

	local id = tostring(playerState.id)
	local curTick = globals.TickCount()

	-- Throttle checks to once every ~0.5s per player
	if lastCheckTick[id] and (curTick - lastCheckTick[id]) < CHECK_INTERVAL_TICKS then
		return
	end
	lastCheckTick[id] = curTick

	local now = globals.CurTime()
	local isDebug = Common.IsDebugEnabled()
	local checkFlags = playerState.checkFlags
	local useSteamHistory = SteamHistory.IsEnabled and SteamHistory.IsEnabled()

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
		local localPlayer = entities.GetLocalPlayer()
		if localPlayer then
			local localSteamID = Common.GetSteamID64(localPlayer)
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
				"Start ID=%s Name=%s inKnownList=%s",
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
	if
		not deferredQueue[id]
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
			if isDebug and VERBOSE_DEBUG_LOGS then
				Logger.Debug("ValveCheck", id .. " – running item/badge check")
			end
			local found, reason = checkPlayerItems(ply)
			if found then
				if isDebug then
					Logger.Debug("ValveCheck", id .. " – item/badge HIT: " .. reason)
				end

				-- Private profiles cannot be used to verify badge-based Valve detection.
				if not pendingBadgeProfileVerification[id] then
					pendingBadgeProfileVerification[id] = true
					SteamLookup.CheckProfileAsync(id, function(results)
						pendingBadgeProfileVerification[id] = nil
						if not results then
							if isDebug then
								Logger.Debug("ValveCheck", id .. " – badge not verified: profile lookup failed")
							end
							deferredQueue[id] = true
							return
						end

						if results.isPrivate then
							if isDebug then
								Logger.Debug("ValveCheck", id .. " – badge not verified: profile is private")
							end
							deferredQueue[id] = true
							return
						end

						if not results.isPublic then
							if isDebug then
								Logger.Debug("ValveCheck", id .. " – badge not verified: profile visibility unknown")
							end
							deferredQueue[id] = true
							return
						end

						if not results.isValve then
							if isDebug then
								Logger.Debug("ValveCheck", id .. " – badge not verified: no Valve group confirmation")
							end
							deferredQueue[id] = true
							return
						end

						checkFlags.valveGroupChecked = true
						checkFlags.vacBanChecked = true
						checkFlags.commBanChecked = true
						applyValveFlag(playerState, reason .. " (public profile verified)")
						deferredQueue[id] = nil
					end)
				end
				return
			end
		end
	end

	if useSteamHistory then
		if not checkFlags.steamHistoryChecked and SteamHistory.QueuePlayerCheck then
			SteamHistory.QueuePlayerCheck(id, playerState.wrap and playerState.wrap:GetName() or id)
		end

		if not checkFlags.valveGroupChecked then
			if SteamLookup.IsGroupMemberID64(id) then
				checkFlags.valveGroupChecked = true
				applyValveFlag(playerState, "Valve Steam Group Member")
			elseif SteamLookup.IsGroupFetchComplete and SteamLookup.IsGroupFetchComplete() then
				checkFlags.valveGroupChecked = true
			end
		end

		if
			checkFlags.steamHistoryChecked
			and checkFlags.valveGroupChecked
			and checkFlags.vacBanChecked
			and checkFlags.commBanChecked
		then
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
			if isDebug and VERBOSE_DEBUG_LOGS then
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

				if isDebug and VERBOSE_DEBUG_LOGS then
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
	pendingBadgeProfileVerification[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	lastProfileCheck[id] = nil
	deferredQueue[id] = nil
	pendingBadgeProfileVerification[id] = nil
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

-- Public tick: call once per frame from Scheduler, not once per player
function ValveCheck.Tick()
	runDeferredSweep()
end

return ValveCheck
