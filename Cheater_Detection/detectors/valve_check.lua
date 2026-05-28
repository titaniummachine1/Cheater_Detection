--[[ detectors/valve_check.lua
     Valve employee / ban verification (once per player per map session).

     Layers (in order):
       1a. Static SteamID64 lists
       1b. Legacy Steam2 list
       2.  Valve-quality item / employee badge (badge requires public profile + group XML)
       3.  Steam group / VAC / trade — via SteamHistory batch when enabled, else profile XML

     Work is driven by DirtySystem "checks" on join and a small retry queue after HTTP failures.
     Scheduler calls Tick() only when Valve check is enabled and there is pending work.
]]

local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local HttpQueue = require("Cheater_Detection.services.http_queue")
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
local MAX_CHECKS_PER_TICK = 3
local PROFILE_RETRY_DELAY = 10.0

local layer1Logged = {}
local pendingBadgeProfileVerification = {}
local profileRetryAfter = {}

local function isValveCheckEnabled()
	local menu = G.Menu
	return menu and menu.Main and menu.Main.ValveCheck == true
end

local function isValidHumanSteamID64(id)
	return id:match("^7656119%d+$") ~= nil and #id == 17
end

local function isSteamHistoryEnabled()
	return SteamHistory.IsEnabled()
end

local function isKnownValveID64(s64)
	if not s64 then
		return false
	end
	local key = (tostring(s64):match("^%s*(.-)%s*$")) or ""
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

local function isKnownValveIDSteam2(s2)
	if not s2 then
		return false
	end
	local legacyList = ValveData.ManualIDsSteam2
	return type(legacyList) == "table" and legacyList[s2] == true
end

local function isKnownStaticValvePlayer(playerState)
	return playerState and isKnownValveID64(playerState.id)
end

local function markExternalChecksComplete(playerState, checkFlags)
	checkFlags.valveGroupChecked = true
	checkFlags.vacBanChecked = true
	checkFlags.commBanChecked = true
	playerState.profileChecked = true
	playerState.externalChecked = true
	playerState.flags = playerState.flags | Constants.Flags.CHECKED
end

local function isValveVerificationComplete(state)
	if not state or not state.checkFlags then
		return true
	end
	local flags = state.checkFlags
	if not flags.valveID64Checked or not flags.valveSteam2Checked or not flags.valveItemBadgeChecked then
		return false
	end
	if not flags.valveGroupChecked or not flags.vacBanChecked or not flags.commBanChecked then
		return false
	end
	if isSteamHistoryEnabled() and not flags.steamHistoryChecked then
		return false
	end
	return state.profileChecked == true or state.externalChecked == true
end

local function applyValveFlag(playerState, reason)
	local oldFlags = playerState.flags
	playerState.flags = playerState.flags | Constants.Flags.VALVE

	local inStaticValveList = isKnownStaticValvePlayer(playerState)
	local reasonForDatabase = reason
	local staticTag = "valve_official"
	if not inStaticValveList then
		reasonForDatabase = reason .. " (Not in static Valve list)"
		staticTag = "ValveDynamic"
	end

	Database.UpsertCheater(playerState.id, {
		name = playerState.wrap:GetName(),
		reason = reasonForDatabase,
		flags = playerState.flags,
		score = playerState.score,
		Static = staticTag,
		source = "Valve Employee Check",
	})

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
		if not inStaticValveList then
			Logger.Info(
				"ValveCheck",
				string.format("Discovered non-static Valve employee saved to database: %s", tostring(playerState.id))
			)
		end
		Events.Publish("OnPlayerStateChange", playerState, reason)
	end
end

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
	if type(value) ~= "number" then
		return nil
	end
	return value
end

local function isVerifiedWearableItemEntity(ent)
	if not ent or not ent:IsValid() then
		return false
	end
	local className = ent:GetClass()
	if type(className) ~= "string" or not className:find("Wearable", 1, true) then
		return false
	end

	local defIndex = readItemInt(ent, "m_iItemDefinitionIndex")
	local itemIDHigh = readItemInt(ent, "m_iItemIDHigh")
	local itemIDLow = readItemInt(ent, "m_iItemIDLow")
	if defIndex == nil or itemIDHigh == nil or itemIDLow == nil or defIndex <= 0 then
		return false
	end
	if (itemIDHigh == 0 and itemIDLow == 0) or (itemIDHigh == -1 and itemIDLow == -1) then
		return false
	end
	return true
end

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

local function scheduleProfileRetry(id)
	profileRetryAfter[id] = globals.CurTime() + PROFILE_RETRY_DELAY
end

local function clearProfileRetry(id)
	profileRetryAfter[id] = nil
end

local function onProfileLookupResponse(id, playerState, checkFlags, isDebug, results)
	checkFlags.profileLookupQueued = false

	if not results then
		if isDebug then
			Logger.Debug("ValveCheck", id .. " – async profile check returned nil (HTTP failed)")
		end
		scheduleProfileRetry(id)
		DirtySystem.MarkDirty(id, "checks")
		return
	end

	if isDebug and VERBOSE_DEBUG_LOGS then
		Logger.Debug(
			"ValveCheck",
			string.format(
				"%s – profile: isValve=%s vacBanned=%s tradeBanned=%s",
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
	markExternalChecksComplete(playerState, checkFlags)
	clearProfileRetry(id)
end

local function queueProfileLookup(id, playerState, checkFlags, isDebug)
	if checkFlags.profileLookupQueued or playerState.profileChecked then
		return false
	end

	checkFlags.profileLookupQueued = true
	local enqueued = SteamLookup.CheckProfileAsync(id, function(results)
		onProfileLookupResponse(id, playerState, checkFlags, isDebug, results)
	end)

	if not enqueued then
		checkFlags.profileLookupQueued = false
		scheduleProfileRetry(id)
		DirtySystem.MarkDirty(id, "checks")
		return false
	end
	return true
end

local function onBadgeProfileResponse(id, playerState, badgeReason, checkFlags, isDebug, results)
	pendingBadgeProfileVerification[id] = nil
	checkFlags.profileLookupQueued = false

	if not results then
		if isDebug then
			Logger.Debug("ValveCheck", id .. " – badge not verified: profile lookup failed")
		end
		scheduleProfileRetry(id)
		DirtySystem.MarkDirty(id, "checks")
		return
	end
	if results.isPrivate or not results.isPublic or not results.isValve then
		if isDebug then
			if results.isPrivate then
				Logger.Debug("ValveCheck", id .. " – badge not verified: profile is private")
			elseif not results.isPublic then
				Logger.Debug("ValveCheck", id .. " – badge not verified: profile visibility unknown")
			else
				Logger.Debug("ValveCheck", id .. " – badge not verified: no Valve group confirmation")
			end
		end
		if isSteamHistoryEnabled() then
			DirtySystem.MarkDirty(id, "checks")
		elseif not playerState.profileChecked then
			queueProfileLookup(id, playerState, checkFlags, isDebug)
		end
		return
	end

	markExternalChecksComplete(playerState, checkFlags)
	applyValveFlag(playerState, badgeReason .. " (public profile verified)")
	clearProfileRetry(id)
end

local function queueBadgeProfileVerification(id, playerState, badgeReason, checkFlags, isDebug)
	if pendingBadgeProfileVerification[id] or checkFlags.profileLookupQueued then
		return false
	end

	pendingBadgeProfileVerification[id] = true
	checkFlags.profileLookupQueued = true

	local enqueued = SteamLookup.CheckProfileAsync(id, function(results)
		onBadgeProfileResponse(id, playerState, badgeReason, checkFlags, isDebug, results)
	end)

	if not enqueued then
		pendingBadgeProfileVerification[id] = nil
		checkFlags.profileLookupQueued = false
		scheduleProfileRetry(id)
		DirtySystem.MarkDirty(id, "checks")
		return false
	end
	return true
end

local function runSteamHistoryPath(id, playerState, checkFlags)
	if not checkFlags.steamHistoryChecked then
		SteamHistory.QueuePlayerCheck(id, playerState.wrap:GetName() or id)
	end

	if not checkFlags.valveGroupChecked then
		if SteamLookup.IsGroupMemberID64(id) then
			checkFlags.valveGroupChecked = true
			applyValveFlag(playerState, "Valve Steam Group Member")
		elseif SteamLookup.IsGroupFetchComplete() then
			checkFlags.valveGroupChecked = true
		end
	end

	return isValveVerificationComplete(playerState)
end

--[[
  processValvePlayer
  @return "done" | "waiting" | "skip"
]]
local function processValvePlayer(state, id, isDebug)
	if id:sub(1, 4) == "BOT_" or not isValidHumanSteamID64(id) then
		return "skip"
	end

	if (state.flags & Constants.Flags.VALVE) ~= 0 then
		return "skip"
	end

	if not Common.IsDebugEnabled() then
		local localID = PlayerCache.GetLocalID()
		if localID and id == localID then
			return "skip"
		end
	end

	local checkFlags = state.checkFlags
	local useSteamHistory = isSteamHistoryEnabled()

	if isDebug and not layer1Logged[id] then
		layer1Logged[id] = true
		Logger.Debug(
			"ValveCheck",
			string.format(
				"Start ID=%s Name=%s inKnownList=%s",
				id,
				state.wrap:GetName(),
				tostring(isKnownValveID64(id))
			)
		)
	end

	if not checkFlags.valveID64Checked then
		checkFlags.valveID64Checked = true
		if isKnownValveID64(id) then
			markExternalChecksComplete(state, checkFlags)
			applyValveFlag(state, "Known Valve SteamID")
			return "done"
		end
	end

	if not checkFlags.valveSteam2Checked then
		checkFlags.valveSteam2Checked = true
		local ent = state.wrap:GetEntity()
		local s2 = ent and ent:IsValid() and Common.GetSteamID(ent) or nil
		if isKnownValveIDSteam2(s2) then
			markExternalChecksComplete(state, checkFlags)
			if isDebug then
				Logger.Debug("ValveCheck", id .. " matched legacy Steam2 list (" .. tostring(s2) .. ")")
			end
			applyValveFlag(state, "Known Valve SteamID (Legacy)")
			return "done"
		end
	end

	if not checkFlags.valveItemBadgeChecked then
		checkFlags.valveItemBadgeChecked = true
		state.itemChecked = true

		local ent = state.wrap:GetEntity()
		if ent and ent:IsValid() then
			if isDebug and VERBOSE_DEBUG_LOGS then
				Logger.Debug("ValveCheck", id .. " – running item/badge check")
			end
			local found, reason = checkPlayerItems(ent)
			if found then
				if isDebug then
					Logger.Debug("ValveCheck", id .. " – item/badge HIT: " .. reason)
				end
				if queueBadgeProfileVerification(id, state, reason, checkFlags, isDebug) then
					return "waiting"
				end
			end
		end
	end

	if useSteamHistory then
		if runSteamHistoryPath(id, state, checkFlags) then
			return "done"
		end
		return "waiting"
	end

	if not state.profileChecked and not checkFlags.profileLookupQueued then
		if queueProfileLookup(id, state, checkFlags, isDebug) then
			return "waiting"
		end
	end

	if isValveVerificationComplete(state) then
		return "done"
	end
	return "waiting"
end

local function collectIdsToProcess()
	local seen = {}
	local ids = {}
	local count = 0

	local function addId(id)
		if not id or seen[id] then
			return
		end
		seen[id] = true
		count = count + 1
		ids[count] = id
	end

	for _, id in ipairs(DirtySystem.GetDirtyPlayers("checks")) do
		addId(id)
	end

	local now = globals.CurTime()
	for id, retryAt in pairs(profileRetryAfter) do
		if now >= retryAt then
			addId(id)
		end
	end

	return ids
end

local function runDeferredSweep()
	if HttpQueue.ShouldDeferGameplayHTTP() then
		return
	end

	local ids = collectIdsToProcess()
	if #ids == 0 then
		return
	end

	local isDebug = Common.IsLogCategoryEnabled("ValveCheck")
	local processed = 0

	for i = 1, #ids do
		if processed >= MAX_CHECKS_PER_TICK then
			break
		end

		local id = ids[i]
		local state = PlayerCache.GetByID(id)
		if not state then
			DirtySystem.ClearDirty(id, "checks")
			clearProfileRetry(id)
		else
			local outcome = processValvePlayer(state, id, isDebug)
			if outcome == "skip" or outcome == "done" then
				DirtySystem.ClearDirty(id, "checks")
				if outcome == "done" then
					clearProfileRetry(id)
				end
			elseif outcome == "waiting" then
				DirtySystem.ClearDirty(id, "checks")
			end
			processed = processed + 1
		end
	end
end

local function hasPendingWork()
	if not isValveCheckEnabled() then
		return false
	end
	if #DirtySystem.GetDirtyPlayers("checks") > 0 then
		return true
	end
	local now = globals.CurTime()
	for _, retryAt in pairs(profileRetryAfter) do
		if now >= retryAt then
			return true
		end
	end
	return false
end

local function clearSessionState()
	for k in pairs(layer1Logged) do
		layer1Logged[k] = nil
	end
	for k in pairs(pendingBadgeProfileVerification) do
		pendingBadgeProfileVerification[k] = nil
	end
	for k in pairs(profileRetryAfter) do
		profileRetryAfter[k] = nil
	end
end

local function onPlayerLeave(id)
	layer1Logged[id] = nil
	pendingBadgeProfileVerification[id] = nil
	clearProfileRetry(id)
end

local function onNewMap()
	clearSessionState()
	PlayerCache.ResetCheckedState()
end

local function onLocalSpawnOrDeath(event)
	if not isValveCheckEnabled() then
		return
	end
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer then
		return
	end
	local userID = event:GetInt("userid")
	local ent = entities.GetByUserID(userID)
	if not ent or ent:GetIndex() ~= localPlayer:GetIndex() then
		return
	end

	local now = globals.CurTime()
	for id, state in pairs(PlayerCache.GetActiveTable()) do
		if state and not isValveVerificationComplete(state) and (state.flags & Constants.Flags.VALVE) == 0 then
			profileRetryAfter[id] = now
		end
	end
end

local function onPlayerJoinTeam(id)
	if not id or not isValveCheckEnabled() then
		return
	end
	DirtySystem.MarkDirty(tostring(id), "checks")
end

Events.Subscribe("OnPlayerDisconnect", onPlayerLeave)
Events.Subscribe("OnPlayerRemoved", onPlayerLeave)
Events.Register("FireGameEvent", "ValveCheck_NewMapClear", onNewMap, "game_newmap")
Events.Register("FireGameEvent", "ValveCheck_LocalSpawnSweep", onLocalSpawnOrDeath, "player_spawn")
Events.Register("FireGameEvent", "ValveCheck_LocalDeathSweep", onLocalSpawnOrDeath, "player_death")
Events.Subscribe("OnPlayerJoinTeam", onPlayerJoinTeam)

function ValveCheck.IsEnabled()
	return isValveCheckEnabled()
end

function ValveCheck.Tick()
	if not hasPendingWork() then
		return
	end
	runDeferredSweep()
end

return ValveCheck
