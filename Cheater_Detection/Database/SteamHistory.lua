--[[ SteamHistory.lua
	Performs SteamHistory API lookups for players in the current match.
	Scans all players once when enabled, then scans newcomers as they join.
]]

local SteamHistory = {}

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local Database = require("Cheater_Detection.Database.Database")
local JoinNotifications = require("Cheater_Detection.Misc.JoinNotifications")
local Constants = require("Cheater_Detection.Core.constants")
local Json = Common.Json
local HttpQueue = require("Cheater_Detection.services.http_queue")

--[[ Constants ]]
local KEYWORDS = {
	"[stac]",
	"[smac]",
	"smac ",
	"cheat",
	"hack",
	"aimbot",
	"anticheat",
	"anti-cheat",
	"[ac]",
	"[sn]",
	"[st]",
	"wallhack",
	"triggerbot",
	"speedhack",
}

local API_TEMPLATE = "https://steamhistory.net/api/sourcebans?key=%s&shouldkey=0&steamids=%s"
local MAX_BATCH = 100
local MIN_BATCH = 1
local MIN_INTERVAL = 0.0 -- Dispatch next batch immediately when queue/HTTP permits
local ACTIVE_SWEEP_INTERVAL = 2.0
local DISABLED_LOG_INTERVAL = 10.0

--[[ Internal State ]]
local state = {
	enabled = false,
	initialQueued = false,
	pending = {},
	inFlight = {},
	scanned = {},
	lastBatchTime = 0,
	scanning = false,
	apiKey = nil,
	-- Error handling
	errorCount = 0,
	nextRetryTime = 0,
	consecutiveFailures = 0,
	maxConsecutiveFailures = 5, -- Disable after 5 failures at max cooldown
	temporarilyDisabled = false,
	currentBatchSize = MAX_BATCH,
	singlePlayerFallback = false,
	lastActiveSweepTime = 0,
	completionAnnounced = false,
	lastCompletionSignature = "",
	lastDisabledLogTime = 0,
	lastDisabledReason = "",
	currentServerIP = "",
}

--[[ Helper Functions ]]
local function getConfig()
	local menu = G.Menu
	return menu and menu.Misc and menu.Misc.SteamHistory or nil
end

local function normalizeSteamID64(rawID)
	if not rawID then
		return nil
	end

	local steamID = tostring(rawID)
	if type(steamID) ~= "string" or not steamID:match("^7656119%d+$") then
		return nil
	end

	return steamID
end

local function isValidSteamID64(steamID)
	return type(steamID) == "string" and steamID:match("^7656119%d+$") ~= nil and #steamID == 17
end

local IGNORED_ID = "76561197960265728" -- [U:1:0]

local function getScoreboardName(steamID)
	local maxClients = (globals and globals.MaxClients and globals.MaxClients()) or 32
	for i = 1, maxClients do
		local info = client.GetPlayerInfo(i)
		if info and info.SteamID then
			local infoSteamID = info.SteamID
			local converted = nil
			if infoSteamID:match("^7656119%d+$") then
				converted = normalizeSteamID64(infoSteamID)
			elseif infoSteamID:match("%[U:1:%d+%]") then
				converted = normalizeSteamID64(Common.FromSteamid3To64(infoSteamID))
			end
			if converted == steamID then
				return info.Name
			end
		end
	end
	return nil
end

local function getPlayerNameBySteamID(steamID)
	local scoreboardName = getScoreboardName(steamID)
	if scoreboardName and scoreboardName ~= "" then
		return scoreboardName
	end

	for _, player in ipairs(PlayerCache.GetAll(true)) do
		local id = normalizeSteamID64(player:GetSteamID64())
		if id == steamID then
			local name = player:GetName()
			if name and name ~= "" then
				return name
			end
		end
	end

	return nil
end

local function printInfo(color, text)
	printc(color[1], color[2], color[3], color[4], text)
end

local function queueSteamID(steamID, context)
	if not steamID then
		return false
	end
	steamID = normalizeSteamID64(steamID)
	if not steamID then
		return false
	end
	if steamID == IGNORED_ID then
		return false
	end
	if state.scanned[steamID] or state.pending[steamID] or state.inFlight[steamID] then
		return false
	end

	state.pending[steamID] = {
		name = context and context.name or nil,
		queuedAt = globals.RealTime(),
	}
	return true
end

local function resetState(clearScanned)
	state.pending = {}
	state.inFlight = {}
	if clearScanned then
		state.scanned = {}
	end
	state.initialQueued = false
	state.lastBatchTime = 0
	state.scanning = false
	state.errorCount = 0
	state.nextRetryTime = 0
	state.lastActiveSweepTime = 0
	state.completionAnnounced = false
	state.lastCompletionSignature = ""
	state.lastDisabledLogTime = 0
	state.lastDisabledReason = ""
	state.currentServerIP = ""
end

local function syncServerBoundaryState()
	local serverIP = engine.GetServerIP()
	if not serverIP or serverIP == "" then
		serverIP = ""
	end

	if serverIP ~= state.currentServerIP then
		local oldServerIP = state.currentServerIP
		-- Only hard-reset when leaving a server or switching between two active servers.
		-- Entering a server from main menu should not reset again because disconnect path
		-- already cleared per-match state.
		if oldServerIP ~= "" and serverIP == "" then
			resetState(true)
			state.scanning = false
		elseif oldServerIP ~= "" and serverIP ~= "" and oldServerIP ~= serverIP then
			printInfo({ 180, 210, 255, 255 }, "[SteamHistory] Server changed - resetting per-match scan state")
			resetState(true)
			state.scanning = false
		end
		state.currentServerIP = serverIP
	end

	return serverIP ~= ""
end

local function getInactiveReason()
	local cfg = getConfig()
	local scannerEnabled = G and G.Menu and G.Menu.Scanner and G.Menu.Scanner.SteamHistory == true
	if not scannerEnabled then
		return "toggle_off"
	end
	if not cfg or type(cfg.ApiKey) ~= "string" or cfg.ApiKey == "" then
		return "missing_api_key"
	end
	if state.temporarilyDisabled then
		return "temporarily_disabled"
	end
	return "inactive"
end

local function logInactiveReason(force)
	local now = globals.RealTime()
	local reason = getInactiveReason()
	if force or (now - state.lastDisabledLogTime) >= DISABLED_LOG_INTERVAL then
		if force or reason ~= state.lastDisabledReason then
			printInfo({ 200, 200, 200, 255 }, "[SteamHistory] Inactive: " .. reason)
			if reason == "missing_api_key" then
				printInfo({ 255, 120, 120, 255 }, "[SteamHistory] Set key via console: steamhistory <your_key>")
			end
		end
		state.lastDisabledLogTime = now
		state.lastDisabledReason = reason
	end
end

local function countEntries(map)
	local total = 0
	for _ in pairs(map) do
		total = total + 1
	end
	return total
end

local function bodySample(body)
	if type(body) ~= "string" then
		return "<non-string body>"
	end
	local sample = body:gsub("[%c%s]+", " ")
	if #sample > 220 then
		sample = sample:sub(1, 220) .. "..."
	end
	return sample
end

local function countActiveProgress()
	local totalTargets = 0
	local checkedTargets = 0
	local includeLocal = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	local localSteamID = nil
	local localWrap = PlayerCache.GetLocal()
	if localWrap and localWrap.GetSteamID64 then
		localSteamID = normalizeSteamID64(localWrap:GetSteamID64())
	end

	for steamID, playerState in pairs(PlayerCache.GetActiveTable()) do
		local id = normalizeSteamID64(steamID)
		if id and (includeLocal or id ~= localSteamID) then
			totalTargets = totalTargets + 1
			local checkFlags = PlayerCache.EnsureCheckFlags(playerState)
			if checkFlags.steamHistoryChecked then
				checkedTargets = checkedTargets + 1
			end
		end
	end

	return totalTargets, checkedTargets
end

local function maybeAnnounceScanComplete()
	local pendingCount = countEntries(state.pending)
	local totalTargets, checkedTargets = countActiveProgress()
	local isComplete = totalTargets > 0 and checkedTargets >= totalTargets and pendingCount == 0 and not state.scanning
	if isComplete then
		local signature = string.format("%d/%d", checkedTargets, totalTargets)
		if state.lastCompletionSignature == signature then
			state.completionAnnounced = true
			return
		end
		printInfo(
			{ 120, 255, 120, 255 },
			string.format("[SteamHistory] Scan complete: checked %d/%d active players", checkedTargets, totalTargets)
		)
		state.completionAnnounced = true
		state.lastCompletionSignature = signature
		return
	end
	state.completionAnnounced = false
end

local function queueCurrentPlayers()
	local queued = 0
	local includeLocal = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	local localPlayer = entities.GetLocalPlayer()
	local localIndex = localPlayer and localPlayer:IsValid() and localPlayer:GetIndex() or -1

	-- Use connected player info only; avoids touching potentially stale entities.
	local maxClients = (globals and globals.MaxClients and globals.MaxClients()) or 32
	for i = 1, maxClients do
		if includeLocal or i ~= localIndex then
			local info = client.GetPlayerInfo(i)
			if info and info.SteamID and not info.IsBot and not info.IsHLTV then
				local steamID64 = nil
				local steamIDStr = tostring(info.SteamID)
				if steamIDStr:match("^7656119%d+$") then
					steamID64 = normalizeSteamID64(steamIDStr)
				elseif steamIDStr:match("%[U:1:%d+%]") then
					steamID64 = normalizeSteamID64(Common.FromSteamid3To64(steamIDStr))
				end
				if steamID64 and queueSteamID(steamID64, { name = info.Name }) then
					queued = queued + 1
				end
			end
		end
	end

	if queued > 0 then
		printInfo(
			{ 0, 200, 255, 255 },
			string.format("[SteamHistory] Queued %d player%s for scanning", queued, queued == 1 and "" or "s")
		)
	end
end

local function getPlayerInfoByUserID(userID)
	if type(userID) ~= "number" or userID <= 0 then
		return nil, nil
	end

	local maxClients = (globals and globals.MaxClients and globals.MaxClients()) or 32
	for i = 1, maxClients do
		local info = client.GetPlayerInfo(i)
		if info and info.UserID == userID then
			return info, i
		end
	end

	return nil, nil
end

local function onPlayerConnect(event)
	if event:GetName() ~= "player_connect" then
		return
	end

	if not state.enabled then
		return
	end

	local networkid = event:GetString("networkid")
	local steamID = normalizeSteamID64(Common.FromSteamid3To64(networkid))
	if not steamID then
		return
	end

	local name = event:GetString("name")
	if queueSteamID(steamID, { name = name }) then
		printInfo(
			{ 0, 200, 255, 255 },
			string.format("[SteamHistory] New player connected: %s - queued for scan", name ~= "" and name or steamID)
		)
	end
end

local function popBatch()
	local ids = {}
	local contexts = {}
	local batchSize = state.currentBatchSize
	for steamID, ctx in pairs(state.pending) do
		if isValidSteamID64(steamID) then
			ids[#ids + 1] = steamID
			contexts[steamID] = ctx
			state.inFlight[steamID] = true
		else
			printInfo({ 255, 120, 120, 255 },
				string.format("[SteamHistory] Dropping invalid SteamID in queue: %s", tostring(steamID)))
		end
		state.pending[steamID] = nil
		if #ids >= batchSize then
			break
		end
	end
	return ids, contexts
end

local function matchesKeyword(reason)
	if not reason or reason == "" then
		return false
	end
	local lower = reason:lower()
	for _, keyword in ipairs(KEYWORDS) do
		if lower:find(keyword, 1, true) then
			return true
		end
	end
	return false
end

local function resolveName(steamID, context, entry)
	local contextName = context and context.name
	if contextName and contextName ~= "" then
		return contextName
	end
	if entry and entry.PersonaName and entry.PersonaName ~= "" then
		return entry.PersonaName
	end
	local scoreboardName = getPlayerNameBySteamID(steamID)
	if scoreboardName and scoreboardName ~= "" then
		return scoreboardName
	end
	return string.format("Player %s", steamID)
end

local function flagPlayer(steamID, context, entry)
	local reason = entry.BanReason or "Unknown reason"
	local name = resolveName(steamID, context, entry)

	-- Hard evidence decision:
	-- If the ban reason explicitly mentions cheats/hacks, we mark as CHEATER immediately.
	local lowerReason = reason:lower()
	local isHardEvidence = lowerReason:find("aimbot")
		or lowerReason:find("cheat")
		or lowerReason:find("hack")
		or lowerReason:find("smac")
		or lowerReason:find("%[stac%]")
		or lowerReason:find("anticheat")
		or lowerReason:find("anti%-cheat")
		or lowerReason:find("%[ac%]")
		or lowerReason:find("%[sn%]")
		or lowerReason:find("%[st%]")
		or lowerReason:find("wallhack")
		or lowerReason:find("triggerbot")
		or lowerReason:find("speedhack")

	local formattedReason = string.format("SteamHistory (%s)", reason)
	local flags = 0
	if isHardEvidence then
		flags = Constants.Flags.CHEATER
		printInfo(
			{ 255, 50, 50, 255 },
			string.format("[SteamHistory] %s flagged as CHEATER (Reason: %s)", name, reason)
		)
	else
		flags = Constants.Flags.SUSPICIOUS
		printInfo(
			{ 255, 120, 120, 255 },
			string.format("[SteamHistory] %s flagged as SUSPICIOUS (Reason: %s)", name, reason)
		)
	end

	Database.UpsertCheater(steamID, {
		name = name,
		reason = formattedReason,
		source = "SteamHistory",
		flags = flags,
	})

	-- Set priority 10 if AutoPriority enabled
	local autoPriorityEnabled = false
	if G.Menu and G.Menu.Advanced and G.Menu.Advanced.AutoPriority ~= nil then
		autoPriorityEnabled = G.Menu.Advanced.AutoPriority == true
	elseif G.Menu and G.Menu.Main and G.Menu.Main.AutoPriority ~= nil then
		autoPriorityEnabled = G.Menu.Main.AutoPriority == true
	end

	if autoPriorityEnabled then
		Database.SetPriority(steamID, 10)
	end

	JoinNotifications.SendCheaterAlert({
		name = name,
		reason = formattedReason,
		tail = string.format("is in the server (Suspected of: %s)", formattedReason),
		allowParty = false,
	})
end

local function toBool(value)
	if value == true then
		return true
	end
	if type(value) == "number" then
		return value ~= 0
	end
	if type(value) == "string" then
		local lowered = value:lower()
		return lowered == "1" or lowered == "true"
	end
	return false
end

local function setSteamHistoryChecks(steamID, entry)
	local playerState = PlayerCache.GetByID(steamID)
	if not playerState then
		return nil
	end

	local oldFlags = playerState.flags
	local checkFlags = PlayerCache.EnsureCheckFlags(playerState)
	checkFlags.steamHistoryChecked = true

	local hasEntry = entry ~= nil
	local responseHasVac = entry
		and (
			entry.VACBanned ~= nil
			or entry.vacBanned ~= nil
			or entry.vacbanned ~= nil
			or entry.NumberOfVACBans ~= nil
			or entry.numberOfVACBans ~= nil
		)
	local responseHasComm = entry
		and (
			entry.CommunityBanned ~= nil
			or entry.communityBanned ~= nil
			or entry.EconomyBan ~= nil
			or entry.economyBan ~= nil
			or entry.tradeBanned ~= nil
		)

	local isVacBanned = false
	local isCommBanned = false
	if entry then
		isVacBanned = toBool(entry.VACBanned)
			or toBool(entry.vacBanned)
			or toBool(entry.vacbanned)
			or tonumber(entry.NumberOfVACBans or entry.numberOfVACBans or 0) > 0
		isCommBanned = toBool(entry.CommunityBanned)
			or toBool(entry.communityBanned)
			or toBool(entry.tradeBanned)
			or (type(entry.EconomyBan) == "string" and entry.EconomyBan ~= "" and entry.EconomyBan:lower() ~= "none")
			or (type(entry.economyBan) == "string" and entry.economyBan ~= "" and entry.economyBan:lower() ~= "none")
	end

	if responseHasVac then
		checkFlags.vacBanChecked = true
		if isVacBanned then
			playerState.flags = playerState.flags | Constants.Flags.VAC_BANNED
		end
	end
	if responseHasComm then
		checkFlags.commBanChecked = true
		if isCommBanned then
			playerState.flags = playerState.flags | Constants.Flags.COMM_BANNED
		end
	end

	-- In a successful batch, a missing player entry means "not found/clean" for this source.
	-- Mark both checks as completed so detectors do not fall back to per-player profile HTTP.
	if not hasEntry then
		checkFlags.vacBanChecked = true
		checkFlags.commBanChecked = true
	end
	if checkFlags.vacBanChecked and checkFlags.commBanChecked then
		playerState.externalChecked = true
		playerState.flags = playerState.flags | Constants.Flags.CHECKED
	end

	if
		playerState.flags ~= oldFlags
		and (playerState.flags & (Constants.Flags.VAC_BANNED | Constants.Flags.COMM_BANNED)) ~= 0
	then
		Database.UpsertCheater(steamID, {
			name = playerState.wrap and playerState.wrap:GetName() or resolveName(steamID, nil, entry),
			reason = isVacBanned and "SteamHistory VAC Ban" or "SteamHistory Community/Trade Ban",
			source = "SteamHistory",
			flags = playerState.flags,
			score = playerState.score or 0,
		})
	end

	return {
		hasEntry = hasEntry,
		isVacBanned = isVacBanned,
		isCommBanned = isCommBanned,
	}
end

local function logPlayerScanResult(steamID, context, entry, checkResult)
	local name = resolveName(steamID, context, entry)
	if checkResult and checkResult.isVacBanned then
		printInfo(
			{ 255, 180, 120, 255 },
			string.format("[SteamHistory] %s scan complete: VAC ban on record", name)
		)
		return
	end
	if checkResult and checkResult.isCommBanned then
		printInfo(
			{ 255, 180, 120, 255 },
			string.format("[SteamHistory] %s scan complete: Community/Trade ban on record", name)
		)
		return
	end
	printInfo({ 150, 220, 255, 255 }, string.format("[SteamHistory] %s scan complete: clean", name))
end

local function handleError(message, contexts, details)
	state.errorCount = state.errorCount + 1
	state.consecutiveFailures = state.consecutiveFailures + 1
	if state.currentBatchSize ~= MIN_BATCH or not state.singlePlayerFallback then
		state.currentBatchSize = MIN_BATCH
		state.singlePlayerFallback = true
		printInfo(
			{ 255, 200, 100, 255 },
			"[SteamHistory] Request failed - switching to single-player retries"
		)
	end

	-- Adaptive backoff based on error type
	local delay
	if message:match("Rate limited") or message:match("429") then
		-- Rate limit: longer backoff, start at 30s
		delay = math.min(300, 30 * (2 ^ (state.errorCount - 1))) -- Max 5 minutes
	elseif message:match("Server error") or message:match("502") or message:match("503") or message:match("504") then
		-- Server errors: moderate backoff, start at 15s
		delay = math.min(120, 15 * (2 ^ (state.errorCount - 1))) -- Max 2 minutes
	else
		-- Other errors: normal backoff, start at 10s
		delay = math.min(60, 10 * (2 ^ (state.errorCount - 1))) -- Max 1 minute
	end
	state.nextRetryTime = globals.RealTime() + delay

	-- If we've hit max cooldown (60s) and failed too many times, disable temporarily
	if delay >= 60 and state.consecutiveFailures >= state.maxConsecutiveFailures then
		state.temporarilyDisabled = true
		printInfo(
			{ 255, 80, 80, 255 },
			string.format(
				"[SteamHistory] API appears to be down (%d consecutive failures). Disabling SteamHistory scanning.",
				state.consecutiveFailures
			)
		)
		printInfo(
			{ 255, 120, 120, 255 },
			"[SteamHistory] Re-enable manually via menu or use console command: steamhistory_rescan"
		)
		-- Clear pending queue to avoid wasting memory
		state.pending = {}
		state.scanning = false
		return
	end

	printInfo(
		{ 255, 100, 100, 255 },
		string.format(
			"[SteamHistory] Error: %s. Retrying in %ds... (%d/%d failures) [pending=%d inFlight=%d mode=%s]%s",
			message,
			delay,
			state.consecutiveFailures,
			state.maxConsecutiveFailures,
			countEntries(state.pending),
			countEntries(state.inFlight),
			state.singlePlayerFallback and "single" or "batch",
			details and (" details=" .. tostring(details)) or ""
		)
	)

	-- Requeue items
	if contexts then
		for steamID, ctx in pairs(contexts) do
			state.inFlight[steamID] = nil
			state.pending[steamID] = ctx
		end
	end
	state.scanning = false
end

local function handleBatchResponse(ids, contexts, responseTable)
	local responseMap = {}
	if type(responseTable) ~= "table" then
		handleError("Invalid response format (not a table)", contexts)
		return
	end

	-- Check for API error messages in response
	if responseTable.error or responseTable.message or responseTable.status == "error" then
		local errorMsg = responseTable.error or responseTable.message or "Unknown API error"
		handleError(string.format("API error: %s", errorMsg), contexts)
		return
	end

	-- Extract response array if wrapped
	if responseTable.response and type(responseTable.response) == "table" then
		responseTable = responseTable.response
	end

	-- Build response map from entries (empty array = all players clean, which is valid)
	for _, entry in pairs(responseTable) do
		if type(entry) == "table" then
			local steamID = normalizeSteamID64(entry.SteamID or entry.steamid or entry.id)
			if steamID then
				responseMap[steamID] = entry
			end
		end
	end

	-- Empty response is valid - means no bans found for queried players

	local flagged = 0
	for _, steamID in ipairs(ids) do
		if type(steamID) ~= "string" then
			steamID = tostring(steamID)
		end
		state.inFlight[steamID] = nil
		state.scanned[steamID] = true
		local entry = responseMap[steamID]
		local context = contexts[steamID] or {}
		local checkResult = setSteamHistoryChecks(steamID, entry)
		if entry and matchesKeyword(entry.BanReason or "") then
			flagged = flagged + 1
			flagPlayer(steamID, context, entry)
		else
			logPlayerScanResult(steamID, context, entry, checkResult)
		end
	end

	local passed = #ids - flagged
	printInfo(
		flagged > 0 and { 255, 200, 120, 255 } or { 0, 200, 255, 255 },
		string.format("[SteamHistory] Batch done: %d flagged, %d clean", flagged, passed)
	)

	-- Success! Reset error count and consecutive failures
	state.errorCount = 0
	state.nextRetryTime = 0
	state.consecutiveFailures = 0
	state.scanning = false
	maybeAnnounceScanComplete()

	if state.singlePlayerFallback and state.currentBatchSize == MIN_BATCH then
		-- Keep single-player fallback until the queue is drained.
		-- Restoring MAX_BATCH after one success can trigger immediate 429 loops.
		if countEntries(state.pending) == 0 then
			state.currentBatchSize = MAX_BATCH
			state.singlePlayerFallback = false
			printInfo({ 150, 255, 150, 255 }, "[SteamHistory] Single-player retry succeeded - batch size restored to 100")
		end
	end
end

local function requestBatch()
	local cfg = getConfig()
	if not cfg or not cfg.ApiKey or cfg.ApiKey == "" then
		return
	end

	local ids, contexts = popBatch()
	if #ids == 0 then
		return
	end

	-- Final guard: never send malformed IDs to API.
	local validIDs = {}
	local validContexts = {}
	for i = 1, #ids do
		local steamID = ids[i]
		if isValidSteamID64(steamID) then
			validIDs[#validIDs + 1] = steamID
			validContexts[steamID] = contexts[steamID]
		else
			state.inFlight[steamID] = nil
			printInfo({ 255, 120, 120, 255 },
				string.format("[SteamHistory] Skipping invalid SteamID before request: %s", tostring(steamID)))
		end
	end
	if #validIDs == 0 then
		return
	end
	ids = validIDs
	contexts = validContexts

	state.scanning = true
	state.lastBatchTime = globals.RealTime()
	printInfo(
		{ 120, 220, 255, 255 },
		string.format("[SteamHistory] Batch start: %d players", #ids)
	)

	local joinedIds = table.concat(ids, ",")
	if joinedIds == "" then
		state.scanning = false
		return
	end

	local url = string.format(API_TEMPLATE, cfg.ApiKey, joinedIds)

	-- Use HttpQueue to avoid blocking during network I/O.
	-- The inner pcall guarantees state.scanning is always reset even on an unhandled Lua error.
	local enqueued = HttpQueue.Enqueue(url, function(body)
		local ok, err = pcall(function()
			if type(body) ~= "string" or body == "" then
				handleError("HTTP Request failed (empty/invalid response)", contexts, "body_type=" .. type(body))
				return
			end

			local lowerBody = body:lower()

			-- Detect HTML/text gateway errors explicitly (avoid false positives from random "429" in JSON text).
			if body:match("^%s*<") or lowerBody:find("<html", 1, true) then
				if lowerBody:find("too many requests", 1, true) or lowerBody:find("rate limit", 1, true) then
					handleError("Rate limited (html response)", contexts, bodySample(body))
					return
				end
				if lowerBody:find("502", 1, true) or lowerBody:find("503", 1, true) or lowerBody:find("504", 1, true) then
					handleError("Server error (html gateway response)", contexts, bodySample(body))
					return
				end
				handleError("API returned unexpected HTML response", contexts, bodySample(body))
				return
			end

			-- Rule II.3: Mandatory Validation
			assert(Json and Json.decode, "SteamHistory: JSON decoder missing")
			local decodeOk, decoded = pcall(Json.decode, body)
			if not decodeOk or type(decoded) ~= "table" then
				handleError("JSON Decode failed", contexts, bodySample(body))
				return
			end

			local statusCode = tonumber(decoded.status or decoded.code or decoded.status_code or decoded.http_status)
			if statusCode == 429 then
				handleError("Rate limited (api status 429)", contexts, bodySample(body))
				return
			end
			if statusCode == 502 or statusCode == 503 or statusCode == 504 then
				handleError(string.format("Server error (api status %d)", statusCode), contexts, bodySample(body))
				return
			end

			if decoded.error or decoded.message or decoded.status == "error" then
				local errorMsg = tostring(decoded.error or decoded.message or "Unknown API error")
				handleError("API error: " .. errorMsg, contexts, bodySample(body))
				return
			end

			handleBatchResponse(ids, contexts, decoded)
		end)

		if not ok then
			-- Unhandled error inside callback: unlock scanning so future batches aren't blocked
			state.scanning = false
			printc(255, 80, 80, 255, "[SteamHistory] Unexpected batch callback error: " .. tostring(err))
		end
	end, nil, { noDelay = true, highPriority = true })

	if not enqueued then
		state.scanning = false
		for i = 1, #ids do
			local steamID = ids[i]
			state.inFlight[steamID] = nil
			if steamID and not state.pending[steamID] then
				state.pending[steamID] = contexts[steamID] or { queuedAt = globals.RealTime() }
			end
		end
	end
end

local function refreshEnabled()
	local cfg = getConfig()
	local rawKey = cfg and cfg.ApiKey
	local apiKey = (type(rawKey) == "string" and rawKey ~= "") and rawKey or nil

	if apiKey ~= state.apiKey then
		state.apiKey = apiKey
		resetState(true)
	end

	local enabled = G and G.Menu and G.Menu.Scanner and G.Menu.Scanner.SteamHistory and apiKey ~= nil
	if enabled ~= state.enabled then
		state.enabled = enabled
		if enabled then
			printInfo({ 0, 200, 255, 255 }, "[SteamHistory] SteamHistory scanning enabled")
		else
			printInfo({ 200, 200, 200, 255 }, "[SteamHistory] SteamHistory scanning disabled")
			resetState(false)
		end
	end

	return state.enabled
end

--[[ Event Handlers ]]
local function onPlayerTeam(event)
	if event:GetName() ~= "player_team" then
		return
	end

	if not state.enabled then
		return
	end

	local team = event:GetInt("team")
	-- Only scan if joining Red (2) or Blue (3)
	if team ~= 2 and team ~= 3 then
		return
	end

	local userid = event:GetInt("userid")
	local info, playerIndex = getPlayerInfoByUserID(userid)

	-- Check if bot via player info (bot field doesn't exist in event)
	if not info or info.IsBot or info.IsHLTV then
		return
	end

	-- Skip local player
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer and localPlayer:GetIndex() == playerIndex then
		if not (G.Menu.Advanced and G.Menu.Advanced.debug) then
			return
		end
	end

	local steamIDStr = tostring(info.SteamID)
	local steamID = nil
	if steamIDStr:match("^7656119%d+$") then
		steamID = normalizeSteamID64(steamIDStr)
	elseif steamIDStr:match("%[U:1:%d+%]") then
		steamID = normalizeSteamID64(Common.FromSteamid3To64(steamIDStr))
	end

	if steamID then
		if queueSteamID(steamID, { name = info.Name }) then
			printInfo(
				{ 0, 200, 255, 255 },
				string.format("[SteamHistory] New player joined: %s - queued for scan", info.Name or steamID)
			)
		end
	end
end

local function onGameEvent(event)
	local name = event:GetName()
	if name == "player_connect" then
		onPlayerConnect(event)
	elseif name == "player_team" then
		onPlayerTeam(event)
	elseif name == "game_newmap" then
		resetState(true)
	elseif name == "teamplay_round_start" then
		-- Round transitions are not session boundaries; avoid full requeue storms.
		return
	end
end

local function onCreateMove()
	local inServer = syncServerBoundaryState()
	if not inServer then
		return
	end

	if not refreshEnabled() then
		logInactiveReason(false)
		return
	end

	if state.temporarilyDisabled then
		logInactiveReason(false)
		return
	end

	if not state.initialQueued then
		queueCurrentPlayers()
		state.initialQueued = true
	end

	if globals.RealTime() - state.lastActiveSweepTime >= ACTIVE_SWEEP_INTERVAL then
		queueCurrentPlayers()
		state.lastActiveSweepTime = globals.RealTime()
	end

	if state.scanning then
		return
	end

	-- Check if we are in cooldown
	if globals.RealTime() < state.nextRetryTime then
		return
	end

	if next(state.pending) and globals.RealTime() - state.lastBatchTime >= MIN_INTERVAL then
		requestBatch()
	end
	maybeAnnounceScanComplete()
end

--[[ Public API ]]
function SteamHistory.HasKey()
	local cfg = getConfig()
	return cfg and cfg.ApiKey and cfg.ApiKey ~= ""
end

function SteamHistory.IsEnabled()
	local scannerEnabled = G and G.Menu and G.Menu.Scanner and G.Menu.Scanner.SteamHistory
	return scannerEnabled == true and SteamHistory.HasKey() and not state.temporarilyDisabled
end

function SteamHistory.IsTemporarilyDisabled()
	return state.temporarilyDisabled
end

function SteamHistory.OnApiKeyUpdated()
	resetState(true)
	refreshEnabled()
end

function SteamHistory.QueueRescan()
	resetState(true)
	state.temporarilyDisabled = false
	state.currentBatchSize = MAX_BATCH
	state.singlePlayerFallback = false
	queueCurrentPlayers()
	printInfo(
		{ 0, 200, 255, 255 },
		string.format("[SteamHistory] Re-enabled, queue reset, batch size restored to %d", MAX_BATCH)
	)
end

function SteamHistory.QueuePlayerCheck(steamID, name)
	if not refreshEnabled() then
		return false
	end
	if state.temporarilyDisabled then
		return false
	end
	return queueSteamID(steamID, { name = name })
end

--[[ Callback Registration ]]
callbacks.Unregister("FireGameEvent", "CD_SteamHistory_Events")
callbacks.Register("FireGameEvent", "CD_SteamHistory_Events", onGameEvent)

callbacks.Unregister("CreateMove", "CD_SteamHistory_OnCreateMove")
callbacks.Register("CreateMove", "CD_SteamHistory_OnCreateMove", onCreateMove)

-- Check for API key on load
local function checkApiKey()
	local cfg = getConfig()
	if not cfg or not cfg.ApiKey or cfg.ApiKey == "" then
		printInfo({ 255, 100, 100, 255 }, "[SteamHistory] API Key missing! Get one at https://steamhistory.net")
		printInfo({ 255, 120, 120, 255 }, "[SteamHistory] Set it via console: steamhistory <your_key>")
	end
end
checkApiKey()

return SteamHistory
