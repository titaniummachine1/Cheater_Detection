--[[ SteamHistory.lua
	Performs SteamHistory API lookups for players in the current match.
	Scans all players once when enabled, then scans newcomers as they join.
]]

local SteamHistory = {}

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local Database = require("Cheater_Detection.Database.Database")
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
	for _, player in ipairs(FastPlayers.GetAll(false)) do
		local id = normalizeSteamID64(player:GetSteamID64())
		if id == steamID then
			local raw = player.GetRawEntity and player:GetRawEntity() or nil
			if raw and raw:IsValid() and raw.GetName then
				local rawName = raw:GetName()
				if type(rawName) == "string" and rawName ~= "" then
					return rawName
				end
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
	if state.scanned[steamID] or state.pending[steamID] then
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
end

local function queueCurrentPlayers()
	local queued = 0
	local maxClients = (globals and globals.MaxClients and globals.MaxClients()) or 32
	for i = 1, maxClients do
		local info = client.GetPlayerInfo(i)
		if info and info.SteamID then
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

local function flagPlayer(steamID, context, entry)
	local reason = entry.BanReason or "Unknown reason"
	local name = context and context.name
		or entry.PersonaName
		or getPlayerNameBySteamID(steamID)
		or string.format("Player %s", steamID)
	printInfo({ 255, 120, 120, 255 }, string.format("[SteamHistory] %s flagged (%s)", name, reason))

	-- Update database and player priority for visibility
	Database.UpsertCheater(steamID, {
		name = name,
		reason = string.format("(%s)", reason),
	})
	Database.SetPriority(steamID, 10, false)
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
		end
	end

	local passed = #ids - flagged
	printInfo(
		flagged > 0 and { 255, 200, 120, 255 } or { 0, 200, 255, 255 },
		string.format("[SteamHistory] Batch: %d flagged, %d clean", flagged, passed)
	)
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
		printInfo({ 255, 100, 100, 255 }, string.format("[SteamHistory] Request failed: %s", tostring(body)))
		-- Requeue the batch for another attempt later
		if contexts then
			for steamID, ctx in pairs(contexts) do
				state.pending[steamID] = ctx
			end
		end
		state.scanning = false
		return
	end

	local ok, decoded = pcall(Json.decode, body)
	if not ok or type(decoded) ~= "table" then
		printInfo({ 255, 100, 100, 255 }, "[SteamHistory] Failed to decode SteamHistory response")
		if contexts then
			for steamID, ctx in pairs(contexts) do
				state.pending[steamID] = ctx
			end
		end
		state.scanning = false
		return
	end

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

	queueSteamID(steamID, { name = event:GetString("name") })
end

local function onGameEvent(event)
	local name = event:GetName()
	if name == "player_connect" then
		onPlayerConnect(event)
	elseif name == "game_newmap" or name == "teamplay_round_start" then
		resetState(true)
	end
end

local function onCreateMove()
	if not refreshEnabled() then
		return
	end

	if not state.initialQueued then
		queueCurrentPlayers()
		state.initialQueued = true
	end

	if state.scanning then
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
end

--[[ Callback Registration ]]
callbacks.Unregister("FireGameEvent", "CD_SteamHistory_Events")
callbacks.Register("FireGameEvent", "CD_SteamHistory_Events", onGameEvent)

callbacks.Unregister("CreateMove", "CD_SteamHistory_OnCreateMove")
callbacks.Register("CreateMove", "CD_SteamHistory_OnCreateMove", onCreateMove)

return SteamHistory
