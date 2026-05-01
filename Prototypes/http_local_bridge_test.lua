--[[
Local bridge client plus continuous stress test.

Bridge API:
- Bridge.Probe() -> alive, err
- Bridge.CanUse() -> boolean
- Bridge.Start(url) -> requestId, err
- Bridge.Receive(id) -> data, finished, err

Pending receive returns nil, false, nil.
Successful receive returns data, true, nil.
Failed receive returns nil, true, err.
]]
--do not assert glboaly defined stuff please in environment
local localJsonOk, localJson = pcall(require, "Json")
local mainJsonOk, mainJson = pcall(require, "Cheater_Detection.Libs.Json")

local Json = nil
if localJsonOk and type(localJson) == "table" and type(localJson.decode) == "function" then
    Json = localJson
elseif mainJsonOk and type(mainJson) == "table" and type(mainJson.decode) == "function" then
    Json = mainJson
else
    error("http_local_bridge_test: JSON module missing (Json or Cheater_Detection.Libs.Json)")
end

local optionalHttpRequireOk, optionalHttpRequireResult = pcall(require, "http")
local optionalCommonRequireOk, optionalCommonRequireResult = pcall(require, "Cheater_Detection.Utils.Common")

local CONFIG = {
    bridgeHost = "127.0.0.1",
    bridgePort = 17354,
    protocol = "local-http-bridge-v1",
    assumeBridgeAliveOnLoad = true,
    targetUrl = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
    bridgeStallLimit = 0.20,
    pollInterval = 0.0,
    requestTimeoutMs = 12000,
    requestMaxBytes = 2 * 1024 * 1024,
    startRetryDelay = 0.50,
    offlineRetryDelay = 15.00,
    offlineRetryMaxDelay = 60.00,
    statusLogInterval = 2.00,
    errorLogCooldown = 1.50,
}

local BRIDGE_BASE = "http://" .. CONFIG.bridgeHost .. ":" .. tostring(CONFIG.bridgePort)
local didLogHttpAvailability = false

local function Log(message)
    print(string.format("[LOCAL-BRIDGE] %s", tostring(message)))
end

local function UrlEncode(value)
    if type(value) ~= "string" then
        return nil
    end
    return string.gsub(value, "([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
end

local function Now()
    local globalsTable = globals
    if globalsTable ~= nil and type(globalsTable.RealTime) == "function" then
        local ok, value = pcall(globalsTable.RealTime)
        if ok and type(value) == "number" then
            return value
        end
    end
    return os.clock()
end

local function ClampOfflineRetryDelay(delay)
    if type(delay) ~= "number" then
        return CONFIG.offlineRetryDelay
    end
    if delay < CONFIG.offlineRetryDelay then
        return CONFIG.offlineRetryDelay
    end
    if delay > CONFIG.offlineRetryMaxDelay then
        return CONFIG.offlineRetryMaxDelay
    end
    return delay
end

local function CanRunBlockingBridgeNow()
    local entitiesTable = entities
    if entitiesTable == nil or type(entitiesTable.GetLocalPlayer) ~= "function" then
        return true
    end

    local ok, localPlayer = pcall(entitiesTable.GetLocalPlayer)
    if not ok or localPlayer == nil then
        return true
    end

    local aliveOk, alive = pcall(function()
        return localPlayer:IsAlive()
    end)
    if not aliveOk then
        return false
    end

    return not alive
end

local function DecodeBody(body)
    if type(body) ~= "string" then
        return nil, "response body is not string"
    end
    if body == "" then
        return nil, "empty response from bridge"
    end

    local ok, decoded = pcall(Json.decode, body)
    if not ok or type(decoded) ~= "table" then
        return nil, "invalid json from bridge: " .. tostring(string.sub(body, 1, 96))
    end

    return decoded, nil
end

local function TryGetFunctionField(target, fieldName)
    if target == nil or type(fieldName) ~= "string" then
        return nil
    end

    local ok, value = pcall(function()
        return target[fieldName]
    end)
    if not ok or type(value) ~= "function" then
        return nil
    end

    return value
end

local function ResolveHttpGet()
    local httpTable = http
    local globalGet = TryGetFunctionField(httpTable, "Get")
    if globalGet ~= nil then
        return globalGet, "global http.Get"
    end
    local globalGetLower = TryGetFunctionField(httpTable, "get")
    if globalGetLower ~= nil then
        return globalGetLower, "global http.get"
    end

    local requiredHttp = nil
    if optionalHttpRequireOk and (type(optionalHttpRequireResult) == "table" or type(optionalHttpRequireResult) == "userdata") then
        requiredHttp = optionalHttpRequireResult
    end

    local requiredGet = TryGetFunctionField(requiredHttp, "Get")
    if requiredGet ~= nil then
        http = requiredHttp
        return requiredGet, "require('http').Get"
    end
    local requiredGetLower = TryGetFunctionField(requiredHttp, "get")
    if requiredGetLower ~= nil then
        http = requiredHttp
        return requiredGetLower, "require('http').get"
    end

    if optionalCommonRequireOk and type(optionalCommonRequireResult) == "table" then
        local commonHttp = optionalCommonRequireResult.http
        local commonGet = TryGetFunctionField(commonHttp, "Get")
        if commonGet ~= nil then
            http = commonHttp
            return commonGet, "Common.http.Get"
        end
        local commonGetLower = TryGetFunctionField(commonHttp, "get")
        if commonGetLower ~= nil then
            http = commonHttp
            return commonGetLower, "Common.http.get"
        end
    end

    return nil, "none"
end

local function HttpJson(path)
    local httpGet, source = ResolveHttpGet()
    if not didLogHttpAvailability then
        didLogHttpAvailability = true
        if httpGet ~= nil then
            Log("http availability: " .. tostring(source))
        else
            Log("http availability: missing (global/require/Common all unavailable)")
        end
    end
    if httpGet == nil then
        return nil, "http.Get unavailable"
    end

    local startedAt = Now()
    local ok, body = pcall(httpGet, BRIDGE_BASE .. path)
    local elapsed = Now() - startedAt
    if elapsed > CONFIG.bridgeStallLimit then
        return nil, string.format("bridge call stalled for %.3fs", elapsed)
    end
    if not ok then
        return nil, tostring(body)
    end

    return DecodeBody(body)
end

local Bridge = {
    state = {
        alive = CONFIG.assumeBridgeAliveOnLoad == true,
        protocol = CONFIG.assumeBridgeAliveOnLoad == true and CONFIG.protocol or nil,
        lastError = nil,
        lastProbeAt = 0.0,
        nextProbeAt = 0.0,
        retryDelay = CONFIG.offlineRetryDelay,
        blockedUntilSafeWindow = false,
    },
}

function Bridge.MarkOffline(err, now, delay, blockUntilSafeWindow)
    local offlineAt = type(now) == "number" and now or Now()
    local retryDelay = ClampOfflineRetryDelay(delay or Bridge.state.retryDelay)

    Bridge.state.alive = false
    Bridge.state.protocol = nil
    Bridge.state.lastError = err or "bridge offline"
    Bridge.state.lastProbeAt = offlineAt
    Bridge.state.nextProbeAt = offlineAt + retryDelay

    if delay == nil then
        Bridge.state.retryDelay = ClampOfflineRetryDelay(retryDelay * 2.0)
    else
        Bridge.state.retryDelay = ClampOfflineRetryDelay(delay)
    end

    if blockUntilSafeWindow then
        Bridge.state.blockedUntilSafeWindow = true
    end
end

function Bridge.Probe(now, force)
    local probeNow = type(now) == "number" and now or Now()
    local safeWindow = CanRunBlockingBridgeNow()

    if Bridge.state.blockedUntilSafeWindow and safeWindow then
        Bridge.state.blockedUntilSafeWindow = false
    end
    if not safeWindow and Bridge.state.alive ~= true then
        return false, Bridge.state.lastError or "bridge offline"
    end
    if Bridge.state.blockedUntilSafeWindow and not safeWindow then
        return false, Bridge.state.lastError or "bridge offline"
    end
    if force ~= true and probeNow < Bridge.state.nextProbeAt then
        return false, Bridge.state.lastError or "bridge offline"
    end

    local response, err = HttpJson("/health")
    local payload = response or {}
    local alive = payload.ok == true and payload.alive == true and payload.protocol == CONFIG.protocol

    if alive then
        Bridge.state.alive = true
        Bridge.state.protocol = payload.protocol
        Bridge.state.lastProbeAt = probeNow
        Bridge.state.lastError = nil
        Bridge.state.nextProbeAt = probeNow
        Bridge.state.retryDelay = CONFIG.offlineRetryDelay
        Bridge.state.blockedUntilSafeWindow = false
        return true, nil
    end

    if err == "http.Get unavailable" then
        Bridge.MarkOffline(err, probeNow, CONFIG.offlineRetryMaxDelay, true)
    else
        local shouldBlockUntilSafeWindow = type(err) == "string" and string.find(err, "stalled", 1, true) ~= nil
        Bridge.MarkOffline(err or payload.error or "bridge offline", probeNow, nil, shouldBlockUntilSafeWindow)
    end

    return false, Bridge.state.lastError
end

function Bridge.IsAlive()
    return Bridge.state.alive == true
end

function Bridge.CanUse()
    return Bridge.IsAlive()
end

function Bridge.Start(url, timeoutMs, maxBytes)
    if type(url) ~= "string" or url == "" then
        return nil, "url missing"
    end

    local requestTimeoutMs = timeoutMs or CONFIG.requestTimeoutMs
    local requestMaxBytes = maxBytes or CONFIG.requestMaxBytes
    local encodedUrl = UrlEncode(url)
    if encodedUrl == nil then
        return nil, "url encode failed"
    end
    local path = string.format(
        "/submit?url=%s&timeout_ms=%d&max_bytes=%d",
        encodedUrl,
        requestTimeoutMs,
        requestMaxBytes
    )

    local response, err = HttpJson(path)
    if response == nil then
        local shouldBlockUntilSafeWindow = type(err) == "string" and string.find(err, "stalled", 1, true) ~= nil
        Bridge.MarkOffline(err, nil, nil, shouldBlockUntilSafeWindow)
        return nil, Bridge.state.lastError
    end

    local payload = response or {}
    local requestId = payload.id

    if payload.ok ~= true or type(requestId) ~= "string" then
        return nil, err or payload.error or "bridge submit failed"
    end

    return requestId, nil
end

function Bridge.Receive(id)
    if type(id) ~= "string" or id == "" then
        return nil, true, "id missing"
    end

    local encodedId = UrlEncode(id)
    if encodedId == nil then
        return nil, true, "id encode failed"
    end

    local response, err = HttpJson("/result?id=" .. encodedId)
    if response == nil then
        local shouldBlockUntilSafeWindow = type(err) == "string" and string.find(err, "stalled", 1, true) ~= nil
        Bridge.MarkOffline(err, nil, nil, shouldBlockUntilSafeWindow)
        return nil, true, Bridge.state.lastError
    end

    local payload = response or {}
    if payload.ok ~= true then
        return nil, true, payload.error or "bridge result failed"
    end

    if payload.done ~= true then
        return nil, false, nil
    end

    if payload.success == true then
        if type(payload.data) == "string" then
            return payload.data, true, nil
        end
        return nil, true, "bridge success missing data"
    end

    return nil, true, payload.error or "remote request failed"
end

local function IsTransientError(err)
    if type(err) ~= "string" then
        return false
    end
    if string.find(err, "bridge", 1, true) then
        return true
    end
    if string.find(err, "response body is not string", 1, true) then
        return true
    end
    if string.find(err, "empty response from bridge", 1, true) then
        return true
    end
    return false
end

local Stress = {
    pendingId = nil,
    requestStartedAt = 0.0,
    nextStartAt = 0.0,
    nextPollAt = 0.0,
    lastErrorLogAt = -9999.0,
    runStartedAt = 0.0,
    lastStatusAt = 0.0,
    submitted = 0,
    resolved = 0,
    success = 0,
    failed = 0,
    retry = 0,
    bytes = 0,
    latencySum = 0.0,
    latencyMax = 0.0,
    frameCount = 0,
    frameSum = 0.0,
    frameMax = 0.0,
}

local function LogErrorRateLimited(message, now)
    if now - Stress.lastErrorLogAt < CONFIG.errorLogCooldown then
        return
    end
    Stress.lastErrorLogAt = now
    Log(message)
end

local function UpdateFrameStats()
    local frameTime = 0.0
    local globalsTable = globals
    if globalsTable ~= nil and type(globalsTable.FrameTime) == "function" then
        local ok, value = pcall(globalsTable.FrameTime)
        if ok and type(value) == "number" then
            frameTime = value
        end
    end
    if type(frameTime) ~= "number" or frameTime < 0 then
        return
    end

    Stress.frameCount = Stress.frameCount + 1
    Stress.frameSum = Stress.frameSum + frameTime
    if frameTime > Stress.frameMax then
        Stress.frameMax = frameTime
    end
end

local function EnsureRunStarted(now)
    if Stress.runStartedAt > 0 then
        return
    end

    Stress.runStartedAt = now
    Stress.lastStatusAt = now
    Log("stress test started")
    if CONFIG.assumeBridgeAliveOnLoad == true then
        Log("startup mode: optimistic bridge alive")
    end
end

local function StartStressRequest(now)
    if Stress.pendingId ~= nil or now < Stress.nextStartAt then
        return
    end

    if not Bridge.CanUse() then
        local alive, probeErr = Bridge.Probe(now)
        if not alive then
            Stress.retry = Stress.retry + 1
            if type(Bridge.state.nextProbeAt) == "number" and Bridge.state.nextProbeAt > now then
                Stress.nextStartAt = Bridge.state.nextProbeAt
            elseif not CanRunBlockingBridgeNow() then
                Stress.nextStartAt = now + CONFIG.startRetryDelay
            else
                Stress.nextStartAt = now + CONFIG.offlineRetryDelay
            end
            LogErrorRateLimited("bridge offline: " .. tostring(probeErr), now)
            return
        end
    end

    local requestId, err = Bridge.Start(CONFIG.targetUrl)
    if requestId == nil then
        Stress.retry = Stress.retry + 1
        if Bridge.CanUse() then
            Stress.nextStartAt = now + CONFIG.startRetryDelay
        elseif type(Bridge.state.nextProbeAt) == "number" and Bridge.state.nextProbeAt > now then
            Stress.nextStartAt = Bridge.state.nextProbeAt
        else
            Stress.nextStartAt = now + CONFIG.offlineRetryDelay
        end
        LogErrorRateLimited("submit retry: " .. tostring(err), now)
        return
    end

    Stress.pendingId = requestId
    Stress.requestStartedAt = now
    Stress.nextPollAt = now + CONFIG.pollInterval
    Stress.submitted = Stress.submitted + 1
end

local function PollStressRequest(now)
    if Stress.pendingId == nil or now < Stress.nextPollAt then
        return
    end

    Stress.nextPollAt = now + CONFIG.pollInterval

    local data, finished, err = Bridge.Receive(Stress.pendingId)
    if not finished then
        if err ~= nil then
            Stress.retry = Stress.retry + 1
            LogErrorRateLimited("poll retry: " .. tostring(err), now)
        end
        return
    end

    Stress.resolved = Stress.resolved + 1
    local latency = now - Stress.requestStartedAt
    if latency > 0 then
        Stress.latencySum = Stress.latencySum + latency
        if latency > Stress.latencyMax then
            Stress.latencyMax = latency
        end
    end

    if type(data) == "string" then
        Stress.success = Stress.success + 1
        Stress.bytes = Stress.bytes + #data
    else
        Stress.failed = Stress.failed + 1
        if IsTransientError(err) then
            Stress.retry = Stress.retry + 1
        end
        LogErrorRateLimited("request failed: " .. tostring(err), now)
    end

    Stress.pendingId = nil
    Stress.requestStartedAt = 0.0
end

local function LogStatus(now)
    if now - Stress.lastStatusAt < CONFIG.statusLogInterval then
        return
    end

    local elapsed = now - Stress.runStartedAt
    local avgLatencyMs = Stress.resolved > 0 and (Stress.latencySum / Stress.resolved) * 1000.0 or 0.0
    local avgFrameMs = Stress.frameCount > 0 and (Stress.frameSum / Stress.frameCount) * 1000.0 or 0.0
    local rps = elapsed > 0 and (Stress.resolved / elapsed) or 0.0

    Log(string.format(
        "status sec=%.1f alive=%s submitted=%d resolved=%d ok=%d fail=%d retry=%d rps=%.2f avg_latency_ms=%.2f max_latency_ms=%.2f avg_frame_ms=%.3f max_frame_ms=%.3f bytes=%d pending=%s",
        elapsed,
        tostring(Bridge.CanUse()),
        Stress.submitted,
        Stress.resolved,
        Stress.success,
        Stress.failed,
        Stress.retry,
        rps,
        avgLatencyMs,
        Stress.latencyMax * 1000.0,
        avgFrameMs,
        Stress.frameMax * 1000.0,
        Stress.bytes,
        tostring(Stress.pendingId ~= nil)
    ))

    Stress.lastStatusAt = now
end

local function OnDraw()
    local now = Now()
    EnsureRunStarted(now)
    UpdateFrameStats()
    PollStressRequest(now)
    StartStressRequest(now)
    LogStatus(now)
end

callbacks.Unregister("Draw", "local_bridge_test_draw")
callbacks.Register("Draw", "local_bridge_test_draw", OnDraw)

return {
    Bridge = Bridge,
    Stress = Stress,
}
