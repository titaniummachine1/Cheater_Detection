--[[ services/http_queue.lua
     HTTP policy:
       • Bridge up  → remote URLs via localhost bridge only (never blocking remote http.Get while alive).
       • One localhost http.Get per game tick: either result_batch (status) OR submit (one new job).
       • result_batch → ask which in-flight job ids are done (batched coordination).
       • submit       → queue pops one URL at a time (no submit_batch; simple serial remote work).
       • Poll results → at most one finished job callback per tick (spread merge work).
       • Bridge down + alive → wait; dead/menu may use blocking fallback.
]]

local Common = require("Cheater_Detection.Utils.Common")
local Json = Common.Json

local HttpQueue = {}

local queue = {}
local isAlive = true
local lastSerialDispatchTime = 0

local BRIDGE_BASE = "http://127.0.0.1:17354"
local bridgeState = {
    isAlive = false,
    isConfirmed = false,
    loadProbeDone = false,
    abandoned = false, -- any failed bridge I/O or failed load probe; no bridge contact until reload
}
local activeBridgeJobs = {} -- { [jobId] = item }

local REQUEST_DELAY = 1.2
local GITHUB_REQUEST_DELAY = 1.2
local REQUEST_TIMEOUT = 30.0 -- Lua + bridge: fail job if no terminal result within 30s
local BRIDGE_REMOTE_TIMEOUT_MS = 30000
local REQUEST_RETRY_INTERVAL = 0.25
local SLOW_BLOCKING_HTTP_WARN_SECONDS = 0.015
local LOCAL_DEATH_SAFE_WINDOW_DELAY = 3.0
local BRIDGE_POLL_INTERVAL = 0.5
local lastBridgePoll = 0
local BRIDGE_POLL_INTERVAL_ACTIVE = 0.35 -- while any in-flight bridge job exists
local BRIDGE_MAX_CALLBACKS_PER_TICK = 1 -- finish at most one job per tick after batch status poll
local BRIDGE_STATS_INTERVAL = 5.0
local BRIDGE_SLOW_LOCAL_GET_MS = 8.0

local function shouldLogBridge()
    return Common.IsLogCategoryEnabled("Database")
end

local bridgeStats = {
    polls = 0,
    pollsSkipped = 0,
    submits = 0,
    callbacksDone = 0,
    localGetMs = 0.0,
    pollGetMs = 0.0,
    lastSummaryAt = 0,
}
local jobWaitStart = {} -- [jobId] = globals.RealTime() when submit accepted

local function Now()
    return globals.RealTime()
end

local function GetLocalPlayerEntity()
    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer then return nil end
    if localPlayer.IsValid and not localPlayer:IsValid() then return nil end
    return localPlayer
end

local function IsEntityAlive(entity)
    if not entity then
        return false
    end
    local isAliveFn = entity.IsAlive
    if type(isAliveFn) ~= "function" then
        return false
    end
    -- Lmaobox/TF2 often returns 1 instead of true
    local alive = isAliveFn(entity)
    return alive == true or alive == 1
end

local function IsLocalPlayerAliveNow()
    return IsEntityAlive(GetLocalPlayerEntity())
end

-- True when remote work must not use blocking http.Get on the game thread.
local function ShouldDeferGameplayHTTP()
    return IsLocalPlayerAliveNow()
end

local function SafeEngineBoolean(methodName)
    if type(engine) ~= "table" then return false end
    local method = engine[methodName]
    if type(method) ~= "function" then return false end
    local value = method()
    return value == true
end

local function GetServerIP()
    if type(engine) ~= "table" then return nil end
    if type(engine.GetServerIP) ~= "function" then return nil end
    return engine.GetServerIP()
end

local function IsGitHubLikeURL(url)
    if type(url) ~= "string" then
        return false
    end
    if url:find("raw%.githubusercontent%.com") then
        return true
    end
    if url:find("cdn%.jsdelivr%.net/gh/") then
        return true
    end
    return false
end

local function GetRequiredDelay(item)
    local requiredDelay = REQUEST_DELAY
    if item and item.noDelay then
        requiredDelay = 0
    end
    if item and IsGitHubLikeURL(item.url) and requiredDelay < GITHUB_REQUEST_DELAY then
        requiredDelay = GITHUB_REQUEST_DELAY
    end
    return requiredDelay
end

local function shortUrl(url)
    if type(url) ~= "string" then
        return "?"
    end
    if #url > 88 then
        return url:sub(1, 85) .. "..."
    end
    return url
end

local function contextLabel(context)
    if type(context) == "table" and type(context.name) == "string" then
        return context.name
    end
    return "?"
end

local function countActiveBridgeJobs()
    local count = 0
    for _ in pairs(activeBridgeJobs) do
        count = count + 1
    end
    return count
end

local function maybePrintBridgeSummary(now)
    if now - bridgeStats.lastSummaryAt < BRIDGE_STATS_INTERVAL then
        return
    end
    bridgeStats.lastSummaryAt = now
    if bridgeStats.submits == 0
        and bridgeStats.callbacksDone == 0
        and countActiveBridgeJobs() == 0
        and #queue == 0
        and bridgeStats.localGetMs == 0 then
        bridgeStats.polls = 0
        bridgeStats.pollsSkipped = 0
        return
    end
    if shouldLogBridge() then
        print(string.format(
            "[HTTP BRIDGE] window %.0fs | lua_polls=%d skipped=%d submits=%d done=%d active=%d queued=%d local_get_ms=%.1f poll_get_ms=%.1f",
            BRIDGE_STATS_INTERVAL,
            bridgeStats.polls,
            bridgeStats.pollsSkipped,
            bridgeStats.submits,
            bridgeStats.callbacksDone,
            countActiveBridgeJobs(),
            #queue,
            bridgeStats.localGetMs,
            bridgeStats.pollGetMs
        ))
    end
    bridgeStats.polls = 0
    bridgeStats.pollsSkipped = 0
    bridgeStats.submits = 0
    bridgeStats.callbacksDone = 0
    bridgeStats.localGetMs = 0.0
    bridgeStats.pollGetMs = 0.0
end

local function logBridgeJobDone(item, jobId, responseBody, errorMessage)
    local waitMs = 0
    local startedAt = jobWaitStart[jobId]
    if startedAt then
        waitMs = (Now() - startedAt) * 1000.0
        jobWaitStart[jobId] = nil
    end
    local bytes = 0
    if type(responseBody) == "string" then
        bytes = #responseBody
    end
    local status = errorMessage and ("ERR:" .. tostring(errorMessage)) or "OK"
    if shouldLogBridge() then
        print(string.format(
            "[HTTP BRIDGE] DONE %s | wait=%.0fms bytes=%d src=%s | %s",
            shortUrl(item.url),
            waitMs,
            bytes,
            contextLabel(item.context),
            status
        ))
    end
end

local function InvokeCallback(item, responseBody, errorMessage)
    assert(item, "InvokeCallback: item is missing")
    assert(type(item.callback) == "function", "InvokeCallback: item.callback is missing or not a function")
    local cbStatus, cbErr = pcall(item.callback, responseBody, errorMessage, item.context)
    if not cbStatus then
        print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
    end
end

-- Terminal: success, remote failure (done+not success), unknown id, or batch ok=false.
local function finishBridgeJob(item, jobId, responseBody, errorMessage)
    bridgeStats.callbacksDone = bridgeStats.callbacksDone + 1
    logBridgeJobDone(item, jobId, responseBody, errorMessage)
    InvokeCallback(item, responseBody, errorMessage)
    activeBridgeJobs[jobId] = nil
    jobWaitStart[jobId] = nil
end

local function expireStaleBridgeJobs(now)
    local expired = {}
    for jobId, item in pairs(activeBridgeJobs) do
        local startedAt = jobWaitStart[jobId]
        if startedAt and (now - startedAt) >= REQUEST_TIMEOUT then
            expired[#expired + 1] = { jobId = jobId, item = item }
        end
    end
    for i = 1, #expired do
        local entry = expired[i]
        finishBridgeJob(
            entry.item,
            entry.jobId,
            nil,
            "Bridge job timed out after " .. tostring(REQUEST_TIMEOUT) .. "s"
        )
    end
end

local function UrlEncode(str)
    if not str then
        return ""
    end
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end

local function DirectHttpGet(url)
    return http.Get(url)
end

local function HttpGet(url)
    local ok, bodyOrErr = pcall(DirectHttpGet, url)
    if not ok then
        return nil, tostring(bodyOrErr)
    end
    return bodyOrErr, nil
end

local activeItem = nil
local activeDeadline = 0
local activeNextRetry = 0
local activeLastError = ""
local activeAttemptCount = 0
local activeAttemptInFlight = false

local blockingWindowState = {
    wasAlive = nil,
    deadSince = 0,
}

local function IsBridgeUsable()
    return bridgeState.loadProbeDone
        and bridgeState.isAlive
        and not bridgeState.abandoned
end

local function AbandonBridge(reason)
    if bridgeState.abandoned then
        return
    end
    bridgeState.abandoned = true
    bridgeState.isAlive = false
    bridgeState.isConfirmed = false

    for jobId, item in pairs(activeBridgeJobs) do
        InvokeCallback(item, nil, reason or "Bridge unavailable")
        activeBridgeJobs[jobId] = nil
    end

    print("[HTTP QUEUE] Bridge disabled until Lua reload: " .. tostring(reason))
end

local function ParseBridgeHealthBody(body)
    if type(body) ~= "string" or body == "" then
        return false
    end
    local ok, data = pcall(Json.decode, body)
    if ok and type(data) == "table" then
        return data.ok == true
    end
    return false
end

-- All bridge traffic except the one-shot /health at module load.
local function BridgeHttpGet(url)
    if not IsBridgeUsable() then
        return nil, "bridge disabled"
    end
    local startedAt = Now()
    local body, err = HttpGet(url)
    local elapsedMs = (Now() - startedAt) * 1000.0
    bridgeStats.localGetMs = bridgeStats.localGetMs + elapsedMs
    if type(url) == "string" and url:find("/result_batch", 1, true) then
        bridgeStats.pollGetMs = bridgeStats.pollGetMs + elapsedMs
    end
    if elapsedMs >= BRIDGE_SLOW_LOCAL_GET_MS then
        print(string.format("[HTTP BRIDGE] slow localhost GET %.1fms %s", elapsedMs, shortUrl(url)))
    end
    if not body then
        AbandonBridge("bridge request failed: " .. tostring(err))
        return nil, err
    end
    return body, nil
end

local function hasActiveBridgeJobs()
    for _ in pairs(activeBridgeJobs) do
        return true
    end
    return false
end

local function bridgeHasWork()
    return hasActiveBridgeJobs() or #queue > 0
end

local function shouldPollBridgeNow(now)
    if not hasActiveBridgeJobs() then
        return false
    end
    local interval = BRIDGE_POLL_INTERVAL_ACTIVE
    return (now - lastBridgePoll) >= interval
end

-- One result_batch per call: which submitted jobs are done? (no remote payload in this request)
local function PollBridgeResults(now)
    if not IsBridgeUsable() then
        return false
    end
    if not hasActiveBridgeJobs() then
        return false
    end
    if not shouldPollBridgeNow(now) then
        bridgeStats.pollsSkipped = bridgeStats.pollsSkipped + 1
        return false
    end
    lastBridgePoll = now

    local ids = {}
    local jobMap = {}
    local count = 0
    for jobId, item in pairs(activeBridgeJobs) do
        count = count + 1
        table.insert(ids, "id=" .. UrlEncode(jobId))
        jobMap[jobId] = item
        if count >= 20 then
            break
        end
    end

    if #ids == 0 then
        return false
    end
    bridgeStats.polls = bridgeStats.polls + 1

    local url = BRIDGE_BASE .. "/result_batch?" .. table.concat(ids, "&")
    local body, err = BridgeHttpGet(url)
    if not body then
        return true
    end

    local ok, data = pcall(Json.decode, body)
    if not ok or not data or not data.ok or not data.items then
        return true
    end

    local callbacksThisTick = 0
    for _, res in ipairs(data.items) do
        if callbacksThisTick >= BRIDGE_MAX_CALLBACKS_PER_TICK then
            break
        end
        local jobId = res.id
        local item = jobMap[jobId]
        if item then
            if res.done then
                if res.success then
                    finishBridgeJob(item, jobId, res.data, nil)
                else
                    finishBridgeJob(item, jobId, nil, res.error or "Remote request failed")
                end
                callbacksThisTick = callbacksThisTick + 1
            elseif res.ok == false or res.error == "unknown id" then
                finishBridgeJob(item, jobId, nil, res.error or "Bridge lost job context")
                callbacksThisTick = callbacksThisTick + 1
            end
        end
    end
    return true
end

-- One submit per call: queue the next single remote GET (or POST via submit_json).
local function TryDispatchToBridge(now)
    if not IsBridgeUsable() then
        return false
    end
    if #queue == 0 then
        return false
    end

    local item = queue[1]
    if not item then
        table.remove(queue, 1)
        return false
    end
    if type(item.callback) ~= "function" then
        table.remove(queue, 1)
        return false
    end

    local requiredDelay = GetRequiredDelay(item)
    if (now - lastSerialDispatchTime) < requiredDelay then
        return false
    end

    item = table.remove(queue, 1)
    lastSerialDispatchTime = now

    local timeoutQuery = "&timeout_ms=" .. tostring(BRIDGE_REMOTE_TIMEOUT_MS)
    local submitUrl
    if item.method and item.method ~= "GET" then
        submitUrl = string.format(
            "%s/submit_json?url=%s&method=%s&content_type=%s&body=%s%s",
            BRIDGE_BASE,
            UrlEncode(item.url),
            UrlEncode(item.method),
            UrlEncode(item.contentType or "application/json"),
            UrlEncode(item.body or ""),
            timeoutQuery
        )
    else
        submitUrl = string.format(
            "%s/submit?url=%s%s",
            BRIDGE_BASE,
            UrlEncode(item.url),
            timeoutQuery
        )
    end

    local body, err = BridgeHttpGet(submitUrl)
    if not body then
        InvokeCallback(item, nil, "Bridge submission error: " .. tostring(err))
        return true
    end

    local decodeOk, data = pcall(Json.decode, body)
    if decodeOk and data and data.ok and data.id then
        bridgeStats.submits = bridgeStats.submits + 1
        jobWaitStart[data.id] = now
        activeBridgeJobs[data.id] = item
        if shouldLogBridge() then
            print(string.format(
                "[HTTP BRIDGE] SUBMIT id=%s src=%s | %s",
                tostring(data.id):sub(1, 8),
                contextLabel(item.context),
                shortUrl(item.url)
            ))
        end
    else
        AbandonBridge("bridge submit rejected")
        InvokeCallback(item, nil, "Bridge submission failed: " .. tostring(body))
    end
    return true
end

-- Exactly one localhost HTTP request: poll in-flight status first, else submit one queued URL.
local function runBridgeTick(now)
    expireStaleBridgeJobs(now)

    if shouldPollBridgeNow(now) then
        PollBridgeResults(now)
        maybePrintBridgeSummary(now)
        return
    end

    if #queue > 0 then
        TryDispatchToBridge(now)
    end
    maybePrintBridgeSummary(now)
end

local function ResetBlockingWindowState()
    blockingWindowState.wasAlive = nil
    blockingWindowState.deadSince = 0
end

-- Blocking fallback for remote URLs only (never while alive and walking).
local function CanRunBlockingHTTPNow(now)
    local currentTime = type(now) == "number" and now or Now()

    local serverIP = GetServerIP()
    if serverIP == nil or serverIP == "" then
        -- Main menu / not on server: allow blocking fetch (no gameplay to stutter).
        return true
    end

    local localPlayer = GetLocalPlayerEntity()
    if not localPlayer then
        return false
    end

    if IsEntityAlive(localPlayer) then
        -- Alive on server: remote blocking http.Get is never allowed.
        blockingWindowState.wasAlive = true
        blockingWindowState.deadSince = 0
        return false
    end

    if blockingWindowState.wasAlive ~= false then
        blockingWindowState.wasAlive = false
        blockingWindowState.deadSince = currentTime
        return false
    end

    if blockingWindowState.deadSince <= 0 then
        blockingWindowState.deadSince = currentTime
        return false
    end

    if SafeEngineBoolean("Con_IsVisible") then
        ResetBlockingWindowState()
        return true
    end

    return (currentTime - blockingWindowState.deadSince) >= LOCAL_DEATH_SAFE_WINDOW_DELAY
end

-- One blocking /health at Lua require time only (never on join / Tick).
local function ProbeBridgeAtModuleLoad()
    if bridgeState.loadProbeDone then
        return
    end
    bridgeState.loadProbeDone = true

    local body, err = HttpGet(BRIDGE_BASE .. "/health")
    if ParseBridgeHealthBody(body) then
        bridgeState.isAlive = true
        bridgeState.isConfirmed = true
        bridgeState.abandoned = false
        print("[HTTP QUEUE] Local bridge detected and connected.")
    else
        bridgeState.abandoned = true
        bridgeState.isAlive = false
        bridgeState.isConfirmed = false
        print("[HTTP QUEUE] Local bridge not available at load; safe-window HTTP only (reload Lua to retry).")
    end
end

local function ResetActiveRequestState()
    activeItem = nil
    activeAttemptInFlight = false
    activeNextRetry = 0
    activeLastError = ""
    activeAttemptCount = 0
    activeDeadline = 0
end

local function FinishActiveRequest(responseBody, errorMessage)
    local item = activeItem
    if item then
        InvokeCallback(item, responseBody, errorMessage)
    end
    ResetActiveRequestState()
end

local function DispatchBlockingAttempt(now)
    if activeAttemptInFlight or not activeItem then
        return
    end

    if ShouldDeferGameplayHTTP() then
        return
    end

    if not CanRunBlockingHTTPNow(now) then
        return
    end

    activeAttemptCount = activeAttemptCount + 1
    activeAttemptInFlight = true

    local item = activeItem

    local startedAt = Now()
    local dataOrErr, err = HttpGet(item.url)
    local elapsed = Now() - startedAt
    activeAttemptInFlight = false

    if elapsed > SLOW_BLOCKING_HTTP_WARN_SECONDS then
        print(string.format(
            "[HTTP QUEUE WARN] slow blocking http.Get %.1fms url=%s",
            elapsed * 1000,
            tostring(item and item.url)
        ))
    end

    if err ~= nil then
        activeLastError = "Get call failed: " .. tostring(err)
        activeNextRetry = Now() + REQUEST_RETRY_INTERVAL
        return
    end

    if type(dataOrErr) == "string" and #dataOrErr > 0 then
        FinishActiveRequest(dataOrErr, nil)
        return
    end

    activeLastError = "Get returned empty/invalid response"
    activeNextRetry = Now() + REQUEST_RETRY_INTERVAL
end

local function TryStartBlockingRequest(now)
    if activeItem ~= nil then
        return false
    end

    if ShouldDeferGameplayHTTP() then
        return false
    end

    if not CanRunBlockingHTTPNow(now) then
        return false
    end

    while #queue > 0 do
        local item = queue[1]
        if not item then
            table.remove(queue, 1)
        elseif type(item.callback) ~= "function" then
            table.remove(queue, 1)
        else
            local requiredDelay = GetRequiredDelay(item)
            if (now - lastSerialDispatchTime) < requiredDelay then
                return false
            end

            item = table.remove(queue, 1)
            activeItem = item
            activeDeadline = now + REQUEST_TIMEOUT
            activeNextRetry = now
            activeLastError = ""
            activeAttemptCount = 0
            activeAttemptInFlight = false
            lastSerialDispatchTime = now
            DispatchBlockingAttempt(now)
            return true
        end
    end

    return false
end

function HttpQueue.IsBusy()
    local hasBridgeJobs = false
    for _ in pairs(activeBridgeJobs) do
        hasBridgeJobs = true
        break
    end
    return activeItem ~= nil or activeAttemptInFlight or #queue > 0 or hasBridgeJobs
end

function HttpQueue.IsBridgeAlive()
    return IsBridgeUsable()
end

function HttpQueue.IsBridgeConfirmed()
    return bridgeState.isConfirmed and not bridgeState.abandoned
end

function HttpQueue.CanRunBlockingHTTPNow()
    return CanRunBlockingHTTPNow(Now())
end

function HttpQueue.ShouldDeferGameplayHTTP()
    return ShouldDeferGameplayHTTP()
end

function HttpQueue.Enqueue(url, callback, context, options)
    assert(type(url) == "string" and url ~= "", "HttpQueue.Enqueue: url must be a non-empty string")
    assert(type(callback) == "function", "HttpQueue.Enqueue: callback must be a function")

    local noDelay = false
    local highPriority = false
    local method = "GET"
    local body = nil
    local contentType = nil

    if type(options) == "table" then
        noDelay = options.noDelay == true
        highPriority = options.highPriority == true
        method = options.method or "GET"
        body = options.body
        contentType = options.contentType
    end

    if not IsBridgeUsable() and (method ~= "GET" or body ~= nil or contentType ~= nil) then
        print(
            "[HTTP QUEUE ERROR] only GET without body/contentType is supported in safe-window mode (bridge is offline)")
        return false
    end

    local item = {
        url = url,
        callback = callback,
        context = context,
        noDelay = noDelay,
        method = method,
        body = body,
        contentType = contentType,
    }

    if highPriority then
        table.insert(queue, 1, item)
    else
        table.insert(queue, item)
    end

    return true
end

function HttpQueue.Tick()
    if not isAlive then
        return
    end

    local now = Now()

    -- 1. Bridge: one localhost GET per tick when there is work (batch status OR one submit).
    if IsBridgeUsable() and bridgeHasWork() then
        runBridgeTick(now)
    end

    -- 2. Blocking in-game http.Get only when the bridge is unavailable.
    if not IsBridgeUsable() then
        if activeItem and now >= activeDeadline and activeAttemptCount > 0 then
            local err = "HTTP request timed out after " .. tostring(REQUEST_TIMEOUT) .. "s"
            if activeLastError ~= "" then
                err = err .. " (last error: " .. activeLastError .. ")"
            end
            print("[HTTP QUEUE ERROR] " .. err .. " url=" .. tostring(activeItem.url))
            FinishActiveRequest(nil, err)
            return
        end

        if activeItem and (not activeAttemptInFlight) and now >= activeNextRetry then
            DispatchBlockingAttempt(now)
            return
        end

        TryStartBlockingRequest(now)
    end
end

local function OnHttpQueueUnload()
    isAlive = false
    queue = {}
    ResetActiveRequestState()
    ResetBlockingWindowState()
end

callbacks.Unregister("Unload", "HttpQueue_Unload")
callbacks.Register("Unload", "HttpQueue_Unload", OnHttpQueueUnload)

ProbeBridgeAtModuleLoad()

return HttpQueue
