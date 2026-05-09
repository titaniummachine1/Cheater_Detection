--[[ services/http_queue.lua
     Safe-window HTTP queue.
     Uses blocking http.Get only during non-intrusive windows
     (main menu, console open, not in server, or local player dead long enough).
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
    lastHealthCheck = 0,
    isConfirmed = false,
}
local activeBridgeJobs = {} -- { [jobId] = item }

local REQUEST_DELAY = 1.2
local GITHUB_REQUEST_DELAY = 1.2
local REQUEST_TIMEOUT = 120.0
local REQUEST_RETRY_INTERVAL = 0.25
local SLOW_BLOCKING_HTTP_WARN_SECONDS = 0.015
local LOCAL_DEATH_SAFE_WINDOW_DELAY = 1.0
local BRIDGE_POLL_INTERVAL = 0.5 -- 500ms when alive, faster when dead/menu
local lastBridgePoll = 0
local lastBridgeDispatch = 0
local BRIDGE_DISPATCH_INTERVAL = 0.5
local MAX_SUBMISSIONS_PER_TICK = 1

local function Now()
    return globals.RealTime()
end

local function GetLocalPlayerEntity()
    local ok, localPlayer = pcall(entities.GetLocalPlayer)
    if not ok or not localPlayer then
        return nil
    end

    local isValidFn = localPlayer.IsValid
    if type(isValidFn) == "function" then
        local validOk, isValid = pcall(isValidFn, localPlayer)
        if not validOk or isValid ~= true then
            return nil
        end
    end

    return localPlayer
end

local function IsLocalPlayerAliveNow()
    local localPlayer = GetLocalPlayerEntity()
    if not localPlayer then
        return false
    end

    local isAliveFn = localPlayer.IsAlive
    if type(isAliveFn) ~= "function" then
        return false
    end

    local aliveOk, alive = pcall(isAliveFn, localPlayer)
    if not aliveOk then
        return false
    end

    return alive == true
end

local function SafeEngineBoolean(methodName)
    local engineTable = engine
    if type(engineTable) ~= "table" then
        return false
    end

    local method = engineTable[methodName]
    if type(method) ~= "function" then
        return false
    end

    local ok, value = pcall(method)
    if not ok then
        return false
    end

    return value == true
end

local function GetServerIP()
    local engineTable = engine
    if type(engineTable) ~= "table" then
        return nil
    end

    local getServerIP = engineTable.GetServerIP
    if type(getServerIP) ~= "function" then
        return nil
    end

    local ok, serverIP = pcall(getServerIP)
    if not ok then
        return nil
    end

    return serverIP
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

local function InvokeCallback(item, responseBody, errorMessage)
    assert(item, "InvokeCallback: item is missing")
    assert(type(item.callback) == "function", "InvokeCallback: item.callback is missing or not a function")
    local cbStatus, cbErr = pcall(item.callback, responseBody, errorMessage, item.context)
    if not cbStatus then
        print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
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

local function CheckBridgeHealth(now)
    local interval = bridgeState.isAlive and 60.0 or 15.0
    -- On startup, check immediately (lastHealthCheck is 0)
    if bridgeState.lastHealthCheck ~= 0 and now - bridgeState.lastHealthCheck < interval then
        return
    end

    -- If in-game and alive, only check if it's the very first time or we've waited a long time
    if bridgeState.lastHealthCheck ~= 0 and IsLocalPlayerAliveNow() and not SafeEngineBoolean("IsGameUIVisible") then
        if now - bridgeState.lastHealthCheck < 300.0 then -- 5 minutes
            return
        end
    end

    bridgeState.lastHealthCheck = now

    local body, err = HttpGet(BRIDGE_BASE .. "/health")
    if body and body:find('"ok":true') then
        if not bridgeState.isAlive then
            print("[HTTP QUEUE] Local bridge detected and connected.")
        end
        bridgeState.isAlive = true
        bridgeState.isConfirmed = true
    else
        if bridgeState.isAlive then
            print("[HTTP QUEUE] Local bridge connection lost.")
        end
        bridgeState.isAlive = false
    end
end

local function PollBridgeResults(now)
    local interval = BRIDGE_POLL_INTERVAL
    if not IsLocalPlayerAliveNow() or SafeEngineBoolean("IsGameUIVisible") then
        interval = 0.1 -- Faster polling when dead or in menu
    end

    if now - lastBridgePoll < interval then
        return
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
        return
    end

    -- Use batch result endpoint for efficiency
    local url = BRIDGE_BASE .. "/result_batch?" .. table.concat(ids, "&")
    local body, err = HttpGet(url)
    if not body then
        return
    end

    local ok, data = pcall(Json.decode, body)
    if not ok or not data or not data.ok or not data.items then
        return
    end

    for _, res in ipairs(data.items) do
        local jobId = res.id
        local item = jobMap[jobId]
        if item then
            if res.done then
                if res.success then
                    InvokeCallback(item, res.data, nil)
                else
                    InvokeCallback(item, nil, res.error or "Remote request failed")
                end
                activeBridgeJobs[jobId] = nil
            elseif res.error == "unknown id" then
                InvokeCallback(item, nil, "Bridge lost job context")
                activeBridgeJobs[jobId] = nil
            end
        end
    end
end

local function TryDispatchToBridge(now)
    if not bridgeState.isAlive then
        return false
    end

    local interval = BRIDGE_DISPATCH_INTERVAL
    if not IsLocalPlayerAliveNow() or SafeEngineBoolean("IsGameUIVisible") then
        interval = 0.0 -- No dispatch throttle when dead or in menu
    end

    if now - lastBridgeDispatch < interval then
        return false
    end

    local submissions = 0
    while #queue > 0 and submissions < MAX_SUBMISSIONS_PER_TICK do
        local item = queue[1]
        if not item then
            table.remove(queue, 1)
        elseif type(item.callback) ~= "function" then
            table.remove(queue, 1)
        else
            -- Check if we should wait (GitHub rate limiting etc)
            local requiredDelay = GetRequiredDelay(item)
            if (now - lastSerialDispatchTime) < requiredDelay then
                return false
            end

            item = table.remove(queue, 1)
            submissions = submissions + 1
            lastSerialDispatchTime = now
            lastBridgeDispatch = now

            local submitUrl
            if item.method and item.method ~= "GET" then
                submitUrl = string.format(
                    "%s/submit_json?url=%s&method=%s&content_type=%s&body=%s",
                    BRIDGE_BASE,
                    UrlEncode(item.url),
                    UrlEncode(item.method),
                    UrlEncode(item.contentType or "application/json"),
                    UrlEncode(item.body or "")
                )
            else
                submitUrl = string.format("%s/submit?url=%s", BRIDGE_BASE, UrlEncode(item.url))
            end

            local body, err = HttpGet(submitUrl)
            if body then
                local ok, data = pcall(Json.decode, body)
                if ok and data and data.ok and data.id then
                    activeBridgeJobs[data.id] = item
                else
                    InvokeCallback(item, nil, "Bridge submission failed: " .. tostring(body))
                end
            else
                InvokeCallback(item, nil, "Bridge submission error: " .. tostring(err))
            end
        end
    end

    return true
end

local function ResetBlockingWindowState()
    blockingWindowState.wasAlive = nil
    blockingWindowState.deadSince = 0
end

local function CanRunBlockingHTTPNow(now)
    local currentTime = type(now) == "number" and now or Now()

    if SafeEngineBoolean("IsGameUIVisible") then
        ResetBlockingWindowState()
        return true
    end

    if SafeEngineBoolean("Con_IsVisible") then
        ResetBlockingWindowState()
        return true
    end

    local serverIP = GetServerIP()
    if serverIP == nil or serverIP == "" then
        ResetBlockingWindowState()
        return true
    end

    local localPlayer = GetLocalPlayerEntity()
    if not localPlayer then
        ResetBlockingWindowState()
        return true
    end

    local isAliveFn = localPlayer.IsAlive
    if type(isAliveFn) ~= "function" then
        ResetBlockingWindowState()
        return false
    end

    local aliveOk, alive = pcall(isAliveFn, localPlayer)
    if not aliveOk then
        ResetBlockingWindowState()
        return false
    end

    if alive == true then
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

    return (currentTime - blockingWindowState.deadSince) >= LOCAL_DEATH_SAFE_WINDOW_DELAY
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

    if not CanRunBlockingHTTPNow(now) then
        return
    end

    activeAttemptCount = activeAttemptCount + 1
    activeAttemptInFlight = true

    local item = activeItem
    if IsLocalPlayerAliveNow() then
        print(string.format(
            "[HTTP QUEUE WARN] blocking http.Get attempted while local player alive; url=%s",
            tostring(item and item.url)
        ))
    end

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
    return bridgeState.isAlive
end

function HttpQueue.IsBridgeConfirmed()
    return bridgeState.isConfirmed
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

    if not bridgeState.isAlive and (method ~= "GET" or body ~= nil or contentType ~= nil) then
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

    -- 1. Manage Bridge
    CheckBridgeHealth(now)
    if bridgeState.isAlive then
        PollBridgeResults(now)
        TryDispatchToBridge(now)
    end

    -- 2. Manage Blocking Fallback (only if bridge is not handling everything)
    if not bridgeState.isAlive then
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

return HttpQueue
