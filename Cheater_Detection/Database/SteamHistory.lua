--[[ SteamHistory.lua
	Performs SteamHistory API lookups for players in the current match.
	Scans all players once when enabled, then scans newcomers as they join.
]]

local SteamHistory = {}

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")
local Database = require("Cheater_Detection.Database.Database")
local JoinNotifications = require("Cheater_Detection.Misc.JoinNotifications")
local Json = Common.Json

--[[ Constants ]]
local KEYWORDS = {
	"[stac]",
	"smac ",
	"cheat",
	"hack",
	"aimbot",
}

local API_TEMPLATE = "https://steamhistory.net/api/sourcebans?key=%s&shouldkey=0&steamids=%s"
local MAX_BATCH = 25
local MIN_INTERVAL = 1.5 -- seconds between batches to avoid spamming the API

--[[ Internal State ]]
local state = {
	enabled = false,
	initialQueued = false,
	pending = {},
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

	for _, player in ipairs(FastPlayers.GetAll(true)) do
		local id = normalizeSteamID64(player:GetSteamID64())
		if id == steamID then
			local info = player:GetInfo()
			if info and info.Name and info.Name ~= "" then
				return info.Name
			end
			local raw = player.GetRawEntity and player:GetRawEntity() or nil
			if raw and raw.IsValid and raw:IsValid() and raw.GetName then
				local rawName = raw:GetName()
				if type(rawName) == "string" and rawName ~= "" then
					return rawName
				end
			end
		end
	end

	local stateEntry = PlayerState and PlayerState.Get(steamID)
	if stateEntry and stateEntry.info and stateEntry.info.Name and stateEntry.info.Name ~= "" then
		return stateEntry.info.Name
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
	if state.scanned[steamID] or state.pending[steamID] then
		return false
	end

	-- Check local database first
	local existing = Database.GetCheater(steamID)
	if existing then
		-- Already known as cheater, skip scanning
		state.scanned[steamID] = true
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
	if clearScanned then
		state.scanned = {}
	end
	state.initialQueued = false
	state.lastBatchTime = 0
	state.scanning = false
	state.errorCount = 0
	state.nextRetryTime = 0
end

local function queueCurrentPlayers()
	local queued = 0
	local maxClients = (globals and globals.MaxClients and globals.MaxClients()) or 32
	for i = 1, maxClients do
		local info = client.GetPlayerInfo(i)
		if info and info.SteamID and not info.IsBot and not info.IsHLTV then
			-- Skip local player unless debug mode is enabled
			local isLocal = false
			local localPlayer = entities.GetLocalPlayer()
			if localPlayer and localPlayer:GetIndex() == i then
				isLocal = true
			end

			-- Check if player is on a valid team (Red=2, Blue=3)
			local entity = entities.GetByIndex(i)
			local teamNum = entity and entity:GetTeamNumber() or 0
			local isValidTeam = teamNum == 2 or teamNum == 3

			if (isValidTeam and not isLocal) or (G.Menu.Advanced and G.Menu.Advanced.debug) then
				local steamID64 = nil
				local steamIDStr = tostring(info.SteamID)
				if steamIDStr:match("^7656119%d+$") then
					steamID64 = normalizeSteamID64(steamIDStr)
				elseif steamIDStr:match("%[U:1:%d+%]") then
					steamID64 = normalizeSteamID64(Common.FromSteamid3To64(steamIDStr))
				end
				if steamID64 then
					local contextName = info.Name
					if queueSteamID(steamID64, { name = contextName }) then
						queued = queued + 1
					end
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

local function popBatch()
	local ids = {}
	local contexts = {}
	for steamID, ctx in pairs(state.pending) do
		ids[#ids + 1] = steamID
		contexts[steamID] = ctx
		state.pending[steamID] = nil
		if #ids >= MAX_BATCH then
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

local function resolveName(steamID, context, entry, stateEntry)
	local contextName = context and context.name
	if contextName and contextName ~= "" then
		return contextName
	end
	if stateEntry and stateEntry.info and stateEntry.info.Name and stateEntry.info.Name ~= "" then
		return stateEntry.info.Name
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
	local stateEntry = PlayerState and PlayerState.GetOrCreate(steamID)
	if stateEntry and context and context.name and context.name ~= "" then
		stateEntry.info = stateEntry.info or {}
		stateEntry.info.Name = context.name
	end

	local name = resolveName(steamID, context, entry, stateEntry)

	printInfo({ 255, 120, 120, 255 }, string.format("[SteamHistory] %s flagged (%s)", name, reason))

	local formattedReason = string.format("SteamHistory (%s)", reason)
	if stateEntry then
		stateEntry.info = stateEntry.info or {}
		stateEntry.info.LastFlagReason = formattedReason
		stateEntry.info.LastFlagSource = "SteamHistory"
		local evidence = stateEntry.Evidence or {}
		evidence.Reasons = evidence.Reasons or {}
		evidence.Reasons.SteamHistory = {
			Weight = (evidence.Reasons.SteamHistory and evidence.Reasons.SteamHistory.Weight) or 0,
			Category = "Exploit",
			LastAddedTick = globals.TickCount(),
		}
		stateEntry.Evidence = evidence
	end

	Database.UpsertCheater(steamID, {
		name = name,
		reason = formattedReason,
	})
	Database.SetPriority(steamID, 10, false)

	JoinNotifications.SendCheaterAlert({
		name = name,
		reason = formattedReason,
		tail = string.format("is in the server (Suspected of: %s)", formattedReason),
		allowParty = false,
	})
end

local function handleBatchResponse(ids, contexts, responseTable)
	local responseMap = {}
	if type(responseTable) == "table" then
		if responseTable.response and type(responseTable.response) == "table" then
			responseTable = responseTable.response
		end

		for _, entry in pairs(responseTable) do
			local steamID = normalizeSteamID64(entry.SteamID or entry.steamid or entry.id)
			if steamID then
				responseMap[steamID] = entry
			end
		end
	end

	local flagged = 0
	for _, steamID in ipairs(ids) do
		if type(steamID) ~= "string" then
			steamID = tostring(steamID)
		end
		state.scanned[steamID] = true
		local entry = responseMap[steamID]
		local context = contexts[steamID] or {}
		if entry and matchesKeyword(entry.BanReason or "") then
			flagged = flagged + 1
			flagPlayer(steamID, context, entry)
		else
			-- Player is clean or not found in SteamHistory
		end
	end

	local passed = #ids - flagged
	printInfo(
		flagged > 0 and { 255, 200, 120, 255 } or { 0, 200, 255, 255 },
		string.format("[SteamHistory] Batch: %d flagged, %d clean", flagged, passed)
	)

	-- Success! Reset error count and consecutive failures
	state.errorCount = 0
	state.nextRetryTime = 0
	state.consecutiveFailures = 0
	state.scanning = false
end

local function handleError(message, contexts)
	state.errorCount = state.errorCount + 1
	state.consecutiveFailures = state.consecutiveFailures + 1

	-- Exponential backoff: 10s, 20s, 40s, capped at 60s
	local delay = math.min(60, 10 * (2 ^ (state.errorCount - 1)))
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
			"[SteamHistory] Error: %s. Retrying in %ds... (%d/%d failures)",
			message,
			delay,
			state.consecutiveFailures,
			state.maxConsecutiveFailures
		)
	)

	-- Requeue items
	if contexts then
		for steamID, ctx in pairs(contexts) do
			state.pending[steamID] = ctx
		end
	end
	state.scanning = false
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

	state.scanning = true
	state.lastBatchTime = globals.RealTime()

	local url = string.format(API_TEMPLATE, cfg.ApiKey, table.concat(ids, ","))
	local success, body = pcall(http.Get, url)

	if not success or type(body) ~= "string" or body == "" then
		handleError("HTTP Request failed", contexts)
		return
	end

	-- Check for HTML/Error responses
	if
		body:match("<html>")
		or body:match("<title>")
		or body:match("502 Bad Gateway")
		or body:match("503 Service Unavailable")
		or body:match("error code:")
	then
		handleError("API returned HTML (likely down)", contexts)
		return
	end

	local ok, decoded = pcall(Json.decode, body)
	if not ok or type(decoded) ~= "table" then
		local preview = body:sub(1, 50):gsub("\n", " ")
		handleError(string.format("JSON Decode failed (%s...)", preview), contexts)
		return
	end

	-- Success! Reset error count
	state.errorCount = 0
	state.nextRetryTime = 0
	state.consecutiveFailures = 0

	handleBatchResponse(ids, contexts, decoded)
	state.scanning = false
end

local function refreshEnabled()
	local cfg = getConfig()
	local apiKey = cfg and cfg.ApiKey or nil
	apiKey = apiKey ~= "" and apiKey or nil

	if apiKey ~= state.apiKey then
		state.apiKey = apiKey
		resetState(true)
	end

	local enabled = cfg and cfg.Enable and apiKey ~= nil
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
	local playerEntity = entities.GetByUserID(userid)
	if not playerEntity then
		return
	end

	local playerIndex = playerEntity:GetIndex()
	local info = client.GetPlayerInfo(playerIndex)

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
		queueSteamID(steamID, { name = info.Name })
	end
end

local function onGameEvent(event)
	local name = event:GetName()
	if name == "player_team" then
		onPlayerTeam(event)
	elseif name == "game_newmap" or name == "teamplay_round_start" then
		resetState(true)
	end
end

local function onCreateMove()
	if not refreshEnabled() then
		return
	end

	if state.temporarilyDisabled then
		return
	end

	if not state.initialQueued then
		queueCurrentPlayers()
		state.initialQueued = true
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
end

--[[ Public API ]]
function SteamHistory.OnApiKeyUpdated()
	resetState(true)
	refreshEnabled()
end

function SteamHistory.QueueRescan()
	resetState(true)
	state.temporarilyDisabled = false
	printInfo({ 0, 200, 255, 255 }, "[SteamHistory] Re-enabled and queue reset")
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
		printInfo({ 255, 100, 100, 255 }, "[SteamHistory] Set it via console: steamhistory <your_key>")
	end
end
checkApiKey()

return SteamHistory
