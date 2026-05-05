--[[ Database/MAC.lua
	Performs MegaAntiCheat backend lookups for players in the current match.
	No API key is required by this module; it queries a local/remote MAC backend URL.
]]

local MAC = {}

local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local Database = require("Cheater_Detection.Database.Database")
local JoinNotifications = require("Cheater_Detection.Misc.JoinNotifications")
local Constants = require("Cheater_Detection.Core.constants")
local HttpQueue = require("Cheater_Detection.services.http_queue")

local Json = Common.Json

local DEFAULT_BASE_URL = "http://127.0.0.1:3000"
local MAC_GAME_ENDPOINT = "/mac/game/v1"
local POLL_INTERVAL = 4.0
local ERROR_RETRY_SECONDS = 8.0
local ERROR_LOG_INTERVAL = 12.0
local STARTUP_PROBE_RETRY_SECONDS = 1.0
local ACTIVITY_LOG_INTERVAL = 15.0

local state = {
    enabled = false,
    scanning = false,
    lastPollAt = 0,
    nextRetryAt = 0,
    lastErrorAt = 0,
    lastError = "",
    lastSuccessAt = 0,
    baseURL = DEFAULT_BASE_URL,
    apiKey = nil,
    startupProbePending = true,
    startupProbeAttempts = 0,
    lastActivityLogAt = 0,
}

local function printInfo(color, text)
    printc(color[1], color[2], color[3], color[4], text)
end

local function logActivity(message, force)
    local now = globals.RealTime()
    if force == true or (now - state.lastActivityLogAt) >= ACTIVITY_LOG_INTERVAL then
        state.lastActivityLogAt = now
        printInfo({ 120, 220, 255, 255 }, "[MAC] " .. message)
    end
end

local function getConfig()
    local menu = G.Menu
    return menu and menu.Misc and menu.Misc.MAC or nil
end

local function trimTrailingSlash(url)
    if type(url) ~= "string" then
        return nil
    end
    local trimmed = url:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
        return nil
    end
    trimmed = trimmed:gsub("/+$", "")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

local function getBaseURL()
    local cfg = getConfig()
    local configured = cfg and cfg.BaseURL or nil
    return trimTrailingSlash(configured) or DEFAULT_BASE_URL
end

local function getApiKey()
    local cfg = getConfig()
    local rawKey = cfg and cfg.ApiKey or nil
    if type(rawKey) ~= "string" then
        return nil
    end
    local trimmed = rawKey:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
        return nil
    end
    return trimmed
end

local function urlEncode(value)
    if type(value) ~= "string" then
        return nil
    end
    return string.gsub(value, "([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
end

local function buildSnapshotURL()
    local url = state.baseURL .. MAC_GAME_ENDPOINT
    local apiKey = state.apiKey
    if not apiKey then
        return url
    end

    local encoded = urlEncode(apiKey)
    if not encoded then
        return url
    end

    return url .. "?key=" .. encoded
end

local function buildSnapshotURLVariants()
    local base = state.baseURL .. MAC_GAME_ENDPOINT
    local apiKey = state.apiKey
    if not apiKey then
        return { base }
    end

    local encoded = urlEncode(apiKey)
    if not encoded then
        return { base }
    end

    -- Spec-first: plain GET /mac/game/v1. Keep keyed variants for custom deployments.
    return {
        base,
        base .. "?key=" .. encoded,
        base .. "?api_key=" .. encoded,
    }
end

local function normalizeSteamID64(rawID)
    if not rawID then
        return nil
    end
    local steamID = tostring(rawID)
    if not steamID:match("^7656119%d+$") or #steamID ~= 17 then
        return nil
    end
    return steamID
end

local function normalizeVerdict(rawVerdict)
    if type(rawVerdict) ~= "string" then
        return "none"
    end
    local lowered = rawVerdict:lower()
    if lowered == "convict" or lowered == "cheater" then
        return "cheater"
    end
    if lowered == "sus" or lowered == "suspicious" then
        return "sus"
    end
    if lowered == "trusted" then
        return "trusted"
    end
    return "none"
end

local function isConvicted(playerEntry)
    if type(playerEntry) ~= "table" then
        return false
    end
    if playerEntry.convicted == true then
        return true
    end
    if type(playerEntry.tags) == "table" then
        for i = 1, #playerEntry.tags do
            local tag = tostring(playerEntry.tags[i]):lower()
            if tag:find("convicted", 1, true) then
                return true
            end
        end
    end
    return false
end

local function resolvePlayerName(steamID, playerEntry)
    if type(playerEntry) == "table" and type(playerEntry.name) == "string" and playerEntry.name ~= "" then
        return playerEntry.name
    end

    local fromCache = PlayerCache.GetByID(steamID)
    if fromCache and fromCache.wrap and fromCache.wrap.GetName then
        local cacheName = fromCache.wrap:GetName()
        if cacheName and cacheName ~= "" then
            return cacheName
        end
    end

    return "Player " .. steamID
end

local function applyVerdict(steamID, playerEntry)
    local verdict = normalizeVerdict(playerEntry.localVerdict)
    local convicted = isConvicted(playerEntry)
    local hardCheater = convicted or verdict == "cheater"
    local suspicious = verdict == "sus"

    if not hardCheater and not suspicious then
        local cached = PlayerCache.GetByID(steamID)
        if cached then
            local checkFlags = PlayerCache.EnsureCheckFlags(cached)
            checkFlags.macChecked = true
        end
        return "none"
    end

    local name = resolvePlayerName(steamID, playerEntry)
    local playerState = PlayerCache.GetByID(steamID)
    local currentFlags = playerState and (tonumber(playerState.flags) or 0) or 0
    local nextFlags = currentFlags
    local reason = "MAC Verdict: suspicious"

    if hardCheater then
        nextFlags = nextFlags | Constants.Flags.CHEATER
        reason = convicted and "MAC Convicted" or "MAC Verdict: cheater"
    else
        nextFlags = nextFlags | Constants.Flags.SUSPICIOUS
    end

    if playerState then
        playerState.flags = nextFlags
        local checkFlags = PlayerCache.EnsureCheckFlags(playerState)
        checkFlags.macChecked = true
    end

    local changed = Database.UpsertCheater(steamID, {
        name = name,
        reason = reason,
        flags = nextFlags,
        score = playerState and (playerState.score or 0) or 0,
        Static = "MAC",
    })

    if changed and hardCheater then
        if G.Menu and G.Menu.Main and G.Menu.Main.AutoPriority then
            Database.SetPriority(steamID, 10)
        end
        JoinNotifications.SendCheaterAlert({
            name = name,
            reason = reason,
            tail = "is in the server (MAC: " .. reason .. ")",
            allowParty = false,
        })
        printInfo({ 255, 120, 120, 255 }, string.format("[MAC] %s flagged as CHEATER (%s)", name, reason))
    elseif changed and suspicious then
        printInfo({ 255, 200, 120, 255 }, string.format("[MAC] %s flagged as SUSPICIOUS (%s)", name, reason))
    end

    if hardCheater then
        return "cheater"
    end
    return "sus"
end

local function handleError(message)
    if state.startupProbePending then
        state.startupProbeAttempts = state.startupProbeAttempts + 1
        if state.startupProbeAttempts < 2 then
            state.scanning = false
            state.nextRetryAt = globals.RealTime() + STARTUP_PROBE_RETRY_SECONDS
            state.lastError = ""
            return
        end
        state.startupProbePending = false
    end

    state.scanning = false
    state.lastError = message
    state.nextRetryAt = globals.RealTime() + ERROR_RETRY_SECONDS
    if globals.RealTime() - state.lastErrorAt >= ERROR_LOG_INTERVAL then
        state.lastErrorAt = globals.RealTime()
        printInfo({ 255, 120, 120, 255 }, "[MAC] " .. message)
    end
end

local function previewBody(body)
    if type(body) ~= "string" then
        return ""
    end
    local snippet = body:sub(1, 180)
    snippet = snippet:gsub("\r", " "):gsub("\n", " ")
    return snippet
end

local function extractPlayers(decoded)
    if type(decoded) ~= "table" then
        return nil, nil
    end

    if type(decoded.players) == "table" then
        return decoded.players, nil
    end

    if type(decoded.data) == "table" and type(decoded.data.players) == "table" then
        return decoded.data.players, nil
    end

    if decoded[1] ~= nil then
        return decoded, nil
    end

    if type(decoded.error) == "string" and decoded.error ~= "" then
        return nil, decoded.error
    end

    if type(decoded.message) == "string" and decoded.message ~= "" then
        return nil, decoded.message
    end

    return nil, nil
end

local function handleResponse(body)
    if type(body) ~= "string" then
        return false, "invalid response from backend"
    end

    if body == "" then
        state.scanning = false
        state.lastSuccessAt = globals.RealTime()
        state.lastError = ""
        state.nextRetryAt = 0
        return true, nil
    end

    if type(Json) ~= "table" or type(Json.decode) ~= "function" then
        return false, "json decoder missing"
    end

    local ok, decoded = pcall(Json.decode, body)
    if not ok or type(decoded) ~= "table" then
        return false, "invalid json from backend: " .. previewBody(body)
    end

    local players, payloadError = extractPlayers(decoded)
    if type(players) ~= "table" then
        if type(payloadError) == "string" and payloadError ~= "" then
            return false, "backend error: " .. payloadError
        else
            return false, "missing players array in mac/game/v1 response"
        end
    end

    ---@cast players table

    local count = #players
	local processed = 0
	local flaggedCheater = 0
	local flaggedSus = 0
    if count > 0 then
        for _, playerEntry in ipairs(players) do
            if type(playerEntry) == "table" and playerEntry.isSelf ~= true then
                local steamID = normalizeSteamID64(playerEntry.steamID64)
                if steamID then
					processed = processed + 1
					local verdictResult = applyVerdict(steamID, playerEntry)
					if verdictResult == "cheater" then
						flaggedCheater = flaggedCheater + 1
					elseif verdictResult == "sus" then
						flaggedSus = flaggedSus + 1
					end
                end
            end
        end
    else
        for _, playerEntry in pairs(players) do
            if type(playerEntry) == "table" and playerEntry.isSelf ~= true then
                local steamID = normalizeSteamID64(playerEntry.steamID64)
                if steamID then
					processed = processed + 1
					local verdictResult = applyVerdict(steamID, playerEntry)
					if verdictResult == "cheater" then
						flaggedCheater = flaggedCheater + 1
					elseif verdictResult == "sus" then
						flaggedSus = flaggedSus + 1
					end
                end
            end
        end
    end

	logActivity(string.format("poll complete: players=%d cheater=%d suspicious=%d", processed, flaggedCheater, flaggedSus), false)

    state.scanning = false
    state.lastSuccessAt = globals.RealTime()
    state.lastError = ""
    state.nextRetryAt = 0
    state.startupProbePending = false
    state.startupProbeAttempts = 0
    return true, nil
end

local function enqueueSnapshotAttempt(urls, attemptIndex)
    local url = urls[attemptIndex]
    if type(url) ~= "string" or url == "" then
        handleError("no valid MAC endpoint URL")
        return
    end

    local enqueued = HttpQueue.Enqueue(url, function(body, errorMessage)
        if errorMessage ~= nil then
            if attemptIndex < #urls then
                enqueueSnapshotAttempt(urls, attemptIndex + 1)
                return
            end
			local displayURL = tostring(url):gsub("%?.*$", "")
			handleError("request failed: " .. displayURL .. " " .. tostring(errorMessage))
            return
        end

        local ok, parseError = handleResponse(body)
        if ok then
            return
        end

        if attemptIndex < #urls then
            enqueueSnapshotAttempt(urls, attemptIndex + 1)
            return
        end

        handleError(parseError or "invalid response from backend")
    end, nil, { noDelay = true, highPriority = true, bridgeTimeoutMs = 6000, bridgeMaxBytes = 1024 * 1024 })

    if not enqueued then
        state.scanning = false
        state.nextRetryAt = globals.RealTime() + 1.0
    end
end

local function requestSnapshot()
    state.scanning = true
    state.lastPollAt = globals.RealTime()
	logActivity("polling backend...", false)
    local urls = buildSnapshotURLVariants()
    enqueueSnapshotAttempt(urls, 1)
end

local function refreshEnabled()
    local scannerEnabled = G and G.Menu and G.Menu.Scanner and G.Menu.Scanner.MAC == true
    local newBaseURL = getBaseURL()
    local newApiKey = getApiKey()
    if newBaseURL ~= state.baseURL then
        state.baseURL = newBaseURL
        state.lastPollAt = 0
        state.nextRetryAt = 0
        state.lastError = ""
        state.startupProbePending = true
        state.startupProbeAttempts = 0
    end

    if newApiKey ~= state.apiKey then
        state.apiKey = newApiKey
        state.lastPollAt = 0
        state.nextRetryAt = 0
        state.lastError = ""
        state.startupProbePending = true
        state.startupProbeAttempts = 0
    end

    if scannerEnabled ~= state.enabled then
        state.enabled = scannerEnabled
        if state.enabled then
            state.startupProbePending = true
            state.startupProbeAttempts = 0
            printInfo({ 120, 220, 255, 255 }, "[MAC] scanning enabled")
        else
            state.startupProbePending = true
            state.startupProbeAttempts = 0
            printInfo({ 200, 200, 200, 255 }, "[MAC] scanning disabled")
        end
    end

    return state.enabled
end

local function onGameEvent(event)
    local eventName = event:GetName()
    if eventName == "game_newmap" then
        state.lastPollAt = 0
        state.nextRetryAt = 0
        state.lastError = ""
        state.startupProbePending = true
        state.startupProbeAttempts = 0
    elseif eventName == "player_connect" or eventName == "player_connect_client" then
        state.lastPollAt = 0
    end
end

local function onCreateMove()
    if not engine.GetServerIP() then
        return
    end

    if not refreshEnabled() then
        return
    end

    if state.scanning then
        return
    end

    local now = globals.RealTime()
    if now < state.nextRetryAt then
        return
    end

    if (now - state.lastPollAt) < POLL_INTERVAL then
        return
    end

    requestSnapshot()
end

function MAC.IsEnabled()
    return state.enabled == true
end

function MAC.GetStatusText()
    if not state.enabled then
        return "MAC: Disabled"
    end
    if state.lastError ~= "" then
        return "MAC: " .. state.lastError
    end
    if state.lastSuccessAt > 0 then
        return "MAC: Connected"
    end
    return "MAC: Waiting"
end

function MAC.GetBaseURL()
    return state.baseURL
end

function MAC.GetApiKey()
    return state.apiKey
end

function MAC.SetBaseURL(url)
    local normalized = trimTrailingSlash(url)
    if not normalized then
        return false, "invalid URL"
    end

    G.Menu = G.Menu or {}
    G.Menu.Misc = G.Menu.Misc or {}
    G.Menu.Misc.MAC = G.Menu.Misc.MAC or {}
    G.Menu.Misc.MAC.BaseURL = normalized

    state.baseURL = normalized
    state.lastPollAt = 0
    state.nextRetryAt = 0
    state.lastError = ""
    return true, nil
end

function MAC.SetApiKey(apiKey)
    local normalized = nil
    if type(apiKey) == "string" then
        normalized = apiKey:match("^%s*(.-)%s*$")
    end
    if not normalized or normalized == "" then
        return false, "invalid API key"
    end

    G.Menu = G.Menu or {}
    G.Menu.Misc = G.Menu.Misc or {}
    G.Menu.Misc.MAC = G.Menu.Misc.MAC or {}
    G.Menu.Misc.MAC.ApiKey = normalized

    state.apiKey = normalized
    state.lastPollAt = 0
    state.nextRetryAt = 0
    state.lastError = ""
    return true, nil
end

function MAC.ClearApiKey()
    G.Menu = G.Menu or {}
    G.Menu.Misc = G.Menu.Misc or {}
    G.Menu.Misc.MAC = G.Menu.Misc.MAC or {}
    G.Menu.Misc.MAC.ApiKey = ""

    state.apiKey = nil
    state.lastPollAt = 0
    state.nextRetryAt = 0
    state.lastError = ""
    return true
end

function MAC.QueueRescan()
    state.lastPollAt = 0
    state.nextRetryAt = 0
    state.lastError = ""
end

callbacks.Unregister("FireGameEvent", "CD_MAC_Events")
callbacks.Register("FireGameEvent", "CD_MAC_Events", onGameEvent)

callbacks.Unregister("CreateMove", "CD_MAC_OnCreateMove")
callbacks.Register("CreateMove", "CD_MAC_OnCreateMove", onCreateMove)

return MAC
