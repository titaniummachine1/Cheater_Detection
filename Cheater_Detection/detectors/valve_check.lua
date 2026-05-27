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
local DirtySystem = require("Cheater_Detection.Core.DirtySystem")

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
local pendingBadgeProfileVerification = {}

-- Track which players have been valve-checked this session (optimization)
-- Valve status is permanent - no need to re-check same session
local valveCheckedThisSession = {}

local function queueDeferredCheck(id)
	if id then
		-- Queue for async Steam profile check (can run multiple times per session)
		-- Item/badge checks are done immediately on join via dirty CONNECTED flag
		pendingBadgeProfileVerification[id] = true
	end
end

local function queueDeferredSweep() end

-- Forward declarations (defined after helper functions)
local runDeferredSweep

-- Subscribe to player check events
Events.Subscribe("OnPlayerNeedsCheck", function(playerState)
	if not playerState or not playerState.id then
		return
	end

	-- Mark player as needing deferred check via DirtySystem
	queueDeferredCheck(playerState.id)
end)

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

	return isKnownValveID64(playerState.id)
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
	local value = ent:GetPropInt(propName)
	if type(value) ~= "number" then return nil end
	return value
end

local function isVerifiedWearableItemEntity(ent)
	if not ent then
		return false
	end

	if not ent:IsValid() then return false end
	local className = ent:GetClass()
	if type(className) ~= "string" then return false end
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
-- Layer 2: Item + Badge check
-- ──────────────────────────────────────────────────────────────────────────────
local function checkPlayerItems(ply)
	for slot = 0, 18 do
		local ent = ply:GetEntityForLoadoutSlot(slot)
		if isVerifiedWearableItemEntity(ent) then
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

	-- OPTIMIZATION: Only check players on join (dirty CONNECTED flag)
	-- Valve status is permanent - cannot become Valve mid-session
	local isNewPlayer = DirtySystem.IsDirty(id, "connected")
	if not isNewPlayer and valveCheckedThisSession[id] then
		return -- Already checked this player this session, skip
	end

	local curTick = globals.TickCount()
	local now = globals.CurTime()
	local isDebug = Common.IsLogCategoryEnabled("ValveCheck")
	local checkFlags = playerState.checkFlags
	local useSteamHistory = SteamHistory.IsEnabled and SteamHistory.IsEnabled()

	-- Skip Bots (Non-SteamID64)
	if not id:match("^7656119%d%+$") or #id ~= 17 then
		return
	end

	-- Skip if already definitively flagged as Valve or Cheater
	if (playerState.flags & (Constants.Flags.VALVE | Constants.Flags.CHEATER)) ~= 0 then
		-- Mark as checked so we don't re-check
		valveCheckedThisSession[id] = true
		DirtySystem.ClearDirty(id, "connected")
		return
	end

	-- Skip local player unless global debug mode is enabled
	if not Common.IsDebugEnabled() then
		local localPlayer = entities.GetLocalPlayer()
		if localPlayer then
			local localSteamID = Common.GetSteamID64(localPlayer)
			if localSteamID and tostring(localSteamID) == tostring(id) then
				-- Mark local player as checked
				valveCheckedThisSession[id] = true
				DirtySystem.ClearDirty(id, "connected")
				return -- Skip local player check
			end
		end
	end

	-- Mark this player as checked this session
	valveCheckedThisSession[id] = true
	-- Clear the CONNECTED dirty flag - we've processed them
	DirtySystem.ClearDirty(id, "connected")

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
	if not checkFlags.valveSteam2Checked then
		local s2 = Common.GetSteamID(playerState.wrap:GetEntity())
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
			SteamHistory.QueuePlayerCheck(id, playerState.wrap:GetName() or id)
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

-- Valve check sweep: runs periodically via Scheduler.Tick to check players marked with CHECKS flag.
-- Uses DirtySystem - only checks players explicitly marked as needing verification.
-- Includes Layer 1 (SteamID static lists) and Layer 2 (badge/items) checks.
runDeferredSweep = function()
	local isDebug = (G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true)
	local now = globals.CurTime()

	-- Get only players marked with dirty CHECKS flag (via DirtySystem)
	local dirtyPlayers = DirtySystem.GetDirtyPlayers("checks")

	-- Limit checks per frame to avoid lag spikes
	local maxChecksPerFrame = 3
	local checksThisFrame = 0

	for _, id in ipairs(dirtyPlayers) do
		if checksThisFrame >= maxChecksPerFrame then
			break -- Process rest next frame
		end

		local state = PlayerCache.GetByID(id)
		if not state then
			-- Player no longer active, clear their dirty flag
			DirtySystem.ClearDirty(id, "checks")
			goto continue
		end

		-- Skip if already confirmed as Valve or Cheater (flag won't change mid-session)
		if (state.flags & (Constants.Flags.VALVE | Constants.Flags.CHEATER)) ~= 0 then
			DirtySystem.ClearDirty(id, "checks")
			goto continue
		end

		-- Skip local player unless debug mode
		if not Common.IsDebugEnabled() then
			local localID = PlayerCache.GetLocalID()
			if localID and id == localID then
				DirtySystem.ClearDirty(id, "checks")
				goto continue
			end
		end

		local checkFlags = state.checkFlags

		-- ── Layer 1a: SteamID64 instant check ─────────────────────────────────────
		if not checkFlags.valveID64Checked then
			checkFlags.valveID64Checked = true
			if isKnownValveID64(id) then
				checkFlags.valveGroupChecked = true
				checkFlags.vacBanChecked = true
				checkFlags.commBanChecked = true
				applyValveFlag(state, "Known Valve SteamID")
				DirtySystem.ClearDirty(id, "checks")
				goto continue
			end
		end

		-- ── Layer 2: Item / Badge check (deferred, limited per frame) ─────────────
		if not checkFlags.valveItemBadgeChecked then
			checksThisFrame = checksThisFrame + 1
			checkFlags.valveItemBadgeChecked = true
			state.itemChecked = true

			local ent = state.wrap:GetEntity()
			if ent and ent:IsValid() then
				local found, reason = checkPlayerItems(ent)
				if found then
					-- Async profile verification for badge-based detection
					if not pendingBadgeProfileVerification[id] then
						pendingBadgeProfileVerification[id] = true
						queueDeferredCheck(id) -- Re-queue for profile verification
					end
				end
			end
		end

		-- ── Layer 3: Async profile check (VAC / Comm ban / Valve Group) ──────────
		-- Only run once per session after layers 1-2 are done
		if not checkFlags.profileLookupQueued and not state.profileChecked then
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
						if isDebug then
							Logger.Debug("ValveCheck", id .. " – async profile check returned nil (HTTP failed)")
						end
						-- Reset timer so it retries sooner (10s) instead of waiting 2 min
						lastProfileCheck[id] = now - (PROFILE_RECHECK_INTERVAL - 10)
						return
					end

					if results.isValve then
						applyValveFlag(state, "Valve Steam Group Member")
					end
					checkFlags.valveGroupChecked = true
					if results.vacBanned then
						applyVacFlag(state)
					end
					checkFlags.vacBanChecked = true
					if results.tradeBanned then
						applyCommBanFlag(state)
					end
					checkFlags.commBanChecked = true

					-- Mark checked so we NEVER run Layer 3 again for this player this session
					state.profileChecked = true
					state.externalChecked = true
					state.flags = state.flags | Constants.Flags.CHECKED
				end)
			end
		end

		-- If all checks done, clear dirty flag
		if checkFlags.valveItemBadgeChecked and checkFlags.valveGroupChecked then
			DirtySystem.ClearDirty(id, "checks")
		end

		::continue::
	end
end

-- Reset per-player state on disconnect so rejoining players are re-checked
Events.Subscribe("OnPlayerDisconnect", function(id)
	lastProfileCheck[id] = nil
	deferredQueue[id] = nil
	pendingBadgeProfileVerification[id] = nil
	valveCheckedThisSession[id] = nil
	layer1Logged[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	lastProfileCheck[id] = nil
	deferredQueue[id] = nil
	pendingBadgeProfileVerification[id] = nil
	valveCheckedThisSession[id] = nil
	layer1Logged[id] = nil
end)

-- Clear ALL session state on new map or round start (new session)
local function onNewSession()
	for k in pairs(lastProfileCheck) do lastProfileCheck[k] = nil end
	for k in pairs(deferredQueue) do deferredQueue[k] = nil end
	for k in pairs(pendingBadgeProfileVerification) do pendingBadgeProfileVerification[k] = nil end
	for k in pairs(valveCheckedThisSession) do valveCheckedThisSession[k] = nil end
	for k in pairs(layer1Logged) do layer1Logged[k] = nil end
	queueDeferredSweep()
end

Events.Register("FireGameEvent", "ValveCheck_NewMapClear", onNewSession, "game_newmap")
Events.Register("FireGameEvent", "ValveCheck_RoundStartClear", onNewSession, "teamplay_round_start")

Events.Subscribe("OnPlayerJoinTeam", function(id, _ent)
	queueDeferredCheck(id)
end)

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

-- Note: NewMap/RoundStart now handled by onNewSession above (clears session + queues sweep)
Events.Register("FireGameEvent", "ValveCheck_LocalSpawnSweep", onLocalSpawnOrDeath, "player_spawn")
Events.Register("FireGameEvent", "ValveCheck_LocalDeathSweep", onLocalSpawnOrDeath, "player_death")

-- Public tick: call once per frame from Scheduler, not once per player
function ValveCheck.Tick()
	runDeferredSweep()
end

return ValveCheck
