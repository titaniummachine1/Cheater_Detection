--[[ Database/MAC.lua
	Polls the MAC client-backend at localhost:1984 for player conviction data.
	No API key is required for local read endpoints.
	Run the MAC client-backend: github.com/MegaAntiCheat/client-backend
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

local DEFAULT_BASE_URL = "http://127.0.0.1:1984"
local MAC_USER_ENDPOINT = "/mac/user/v1"
local EVENT_POLL_COOLDOWN = 1.5
local HEARTBEAT_INTERVAL = 30.0
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
    pollAttempt = 0,
    loggedLocalhostHint = false,
    pollRequested = true,
    pollReason = "startup",
    currentServerIP = "",
}

local normalizeSteamID64

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

local function collectLookupUsers()
    local users = {}
    local seen = {}

    if type(PlayerCache.GetAll) == "function" then
        local wrappedPlayers = PlayerCache.GetAll(true)
        if type(wrappedPlayers) == "table" then
            for i = 1, #wrappedPlayers do
                local wrapped = wrappedPlayers[i]
                if wrapped and wrapped.GetRawEntity then
                    local raw = wrapped:GetRawEntity()
                    local steamID = normalizeSteamID64(Common.GetSteamID64(raw))
                    if steamID and not seen[steamID] then
                        seen[steamID] = true
                        users[#users + 1] = steamID
                    end
                end
            end
        end
    end

    if #users == 0 and type(PlayerCache.GetActiveTable) == "function" then
        local activeTable = PlayerCache.GetActiveTable()
        if type(activeTable) == "table" then
            for steamID, _ in pairs(activeTable) do
                local normalized = normalizeSteamID64(steamID)
                if normalized and not seen[normalized] then
                    seen[normalized] = true
                    users[#users + 1] = normalized
                end
            end
        end
    end

    return users
end

local function buildLookupRequestBody()
    local users = collectLookupUsers()
    if #users == 0 then
        return nil, nil, "no players to query"
    end

    if type(Json) ~= "table" or type(Json.encode) ~= "function" then
        return nil, nil, "json encoder missing"
    end

    local ok, encoded = pcall(Json.encode, { users = users })
    if not ok or type(encoded) ~= "string" or encoded == "" then
        return nil, nil, "failed to encode user lookup request"
    end

    return encoded, #users, nil
end

normalizeSteamID64 = function(rawID)
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

    if not state.loggedLocalhostHint then
        local lowerBase = tostring(state.baseURL):lower()
        local lowerMessage = tostring(message):lower()
        local isLocalhost = lowerBase:find("127.0.0.1", 1, true) ~= nil or lowerBase:find("localhost", 1, true) ~= nil
        local refused = lowerMessage:find("10061", 1, true) ~= nil or
            lowerMessage:find("actively refused", 1, true) ~= nil
        if isLocalhost and refused then
            state.loggedLocalhostHint = true
            printInfo({ 255, 180, 100, 255 }, "[MAC] Local backend unreachable at " .. tostring(state.baseURL))
            printInfo({ 255, 180, 100, 255 },
                "[MAC] Download/run MAC client-backend: github.com/MegaAntiCheat/client-backend")
            printInfo({ 255, 180, 100, 255 }, "[MAC] Or change endpoint with: mac_url <base_url>")
        end
    end

    printInfo(
        { 255, 120, 120, 255 },
        string.format(
            "[MAC] poll #%d failed: %s (retry in %.1fs)",
            state.pollAttempt,
            tostring(message),
            ERROR_RETRY_SECONDS
        )
    )
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
            return false, "missing players array in mac/user/v1 response"
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

    logActivity(
        string.format(
            "poll #%d complete: players=%d cheater=%d suspicious=%d",
            state.pollAttempt,
            processed,
            flaggedCheater,
            flaggedSus
        ),
        true
    )

    state.scanning = false
    state.lastSuccessAt = globals.RealTime()
    state.lastError = ""
    state.nextRetryAt = 0
    state.startupProbePending = false
    state.startupProbeAttempts = 0
    return true, nil
end

local function enqueueLookup(url, body)
    if type(url) ~= "string" or url == "" then
        handleError("no valid MAC endpoint URL")
        return
    end
    if type(body) ~= "string" or body == "" then
        handleError("invalid MAC request body")
        return
    end

    local enqueued = HttpQueue.Enqueue(url, function(responseBody, errorMessage)
        if errorMessage ~= nil then
            local displayURL = tostring(url):gsub("%?.*$", "")
            handleError("request failed: " .. displayURL .. " " .. tostring(errorMessage))
            return
        end

        local ok, parseError = handleResponse(responseBody)
        if ok then
            return
        end
        handleError(parseError or "invalid response from backend")
    end, nil, {
        noDelay = true,
        highPriority = true,
        method = "POST",
        body = body,
        contentType = "application/json",
        bridgeTimeoutMs = 6000,
        bridgeMaxBytes = 1024 * 1024,
    })

    if not enqueued then
        state.scanning = false
        state.nextRetryAt = globals.RealTime() + 1.0
    end
end

local function requestSnapshot()
    local requestBody, userCount, bodyError = buildLookupRequestBody()
    if requestBody == nil then
        state.pollRequested = false
        state.pollReason = "periodic"
        if bodyError ~= "no players to query" then
            handleError(bodyError or "failed to build lookup request")
        else
            state.scanning = false
            state.lastSuccessAt = globals.RealTime()
            state.lastError = ""
            state.nextRetryAt = 0
        end
        return
    end

    state.scanning = true
    state.pollAttempt = state.pollAttempt + 1
    state.lastPollAt = globals.RealTime()
    logActivity(
        string.format(
            "poll #%d start: %s users=%d (key=%s, reason=%s)",
            state.pollAttempt,
            tostring(state.baseURL .. MAC_USER_ENDPOINT),
            tonumber(userCount) or 0,
            tostring(state.apiKey ~= nil),
            tostring(state.pollReason or "unknown")
        ),
        true
    )
    state.pollRequested = false
    state.pollReason = "periodic"
    enqueueLookup(state.baseURL .. MAC_USER_ENDPOINT, requestBody)
end

local function requestSnapshotSoon(reason)
    state.pollRequested = true
    if type(reason) == "string" and reason ~= "" then
        state.pollReason = reason
    end
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
        state.loggedLocalhostHint = false
        requestSnapshotSoon("base_url_changed")
    end

    if newApiKey ~= state.apiKey then
        state.apiKey = newApiKey
        state.lastPollAt = 0
        state.nextRetryAt = 0
        state.lastError = ""
        state.startupProbePending = true
        state.startupProbeAttempts = 0
        state.loggedLocalhostHint = false
        requestSnapshotSoon("api_key_changed")
    end

    if scannerEnabled ~= state.enabled then
        state.enabled = scannerEnabled
        if state.enabled then
            state.startupProbePending = true
            state.startupProbeAttempts = 0
            printInfo({ 120, 220, 255, 255 }, "[MAC] scanning enabled")
            requestSnapshotSoon("enabled")
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
        requestSnapshotSoon("new_map")
    elseif eventName == "player_connect" or eventName == "player_connect_client" then
        requestSnapshotSoon("player_join")
    elseif eventName == "teamplay_round_start" or eventName == "post_inventory_application" then
        requestSnapshotSoon("round_or_inventory")
    end
end

local function onCreateMove()
    local serverIP = engine.GetServerIP()
    if not serverIP then
        state.currentServerIP = ""
        return
    end

    if serverIP ~= state.currentServerIP then
        state.currentServerIP = serverIP
        requestSnapshotSoon("server_changed")
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

    if (now - state.lastPollAt) >= HEARTBEAT_INTERVAL then
        requestSnapshotSoon("heartbeat")
    end

    if not state.pollRequested then
        return
    end

    if (now - state.lastPollAt) < EVENT_POLL_COOLDOWN then
        return
    end

    requestSnapshot()
end

function MAC.IsEnabled()
    return state.enabled == true
end

function MAC.GetStatusText()
    if not state.enabled then
        return "MAC: Disabled (requires client-backend at localhost:1984)"
    end
    if state.lastError ~= "" then
        return "MAC: " .. state.lastError
    end
    if state.lastSuccessAt > 0 then
        return "MAC: Connected (client-backend localhost:1984)"
    end
    return "MAC: Waiting for client-backend (localhost:1984)"
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
    requestSnapshotSoon("manual_rescan")
end

callbacks.Unregister("FireGameEvent", "CD_MAC_Events")
callbacks.Register("FireGameEvent", "CD_MAC_Events", onGameEvent)

callbacks.Unregister("CreateMove", "CD_MAC_OnCreateMove")
callbacks.Register("CreateMove", "CD_MAC_OnCreateMove", onCreateMove)

return MAC
