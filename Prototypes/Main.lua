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
    local ok, value = pcall(function()
        return globals.RealTime()
    end)
    if ok and type(value) == "number" then
        return value
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
    local ok, localPlayer = pcall(function()
        return entities.GetLocalPlayer()
    end)
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

local function HttpText(path)
    local startedAt = Now()
    local ok, bodyOrErr = pcall(function()
        return http.Get(BRIDGE_BASE .. path)
    end)
    local elapsed = Now() - startedAt

    if not didLogHttpAvailability then
        didLogHttpAvailability = true
        if ok then
            Log("http availability: direct http.Get")
        else
            Log("http availability: direct http.Get failed: " .. tostring(bodyOrErr))
        end
    end
    if elapsed > CONFIG.bridgeStallLimit then
        return nil, string.format("bridge call stalled for %.3fs", elapsed)
    end
    if not ok then
        return nil, tostring(bodyOrErr)
    end
    local body = bodyOrErr
    if type(body) ~= "string" then
        return nil, "response body is not string"
    end
    if body == "" then
        return nil, "empty response from bridge"
    end

    return body, nil
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
        activeRequestId = nil,
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

    local body, err = HttpText("/health_txt")
    local protocol = type(body) == "string" and body:match("^ok|([^\n]+)") or nil
    local alive = protocol == CONFIG.protocol

    if alive then
        Bridge.state.alive = true
        Bridge.state.protocol = protocol
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
        local lineError = type(body) == "string" and body:match("^err|(.-)\n?$") or nil
        Bridge.MarkOffline(err or lineError or "bridge offline", probeNow, nil, shouldBlockUntilSafeWindow)
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
    if Bridge.state.activeRequestId ~= nil then
        return nil, "request already in progress"
    end

    local requestTimeoutMs = timeoutMs or CONFIG.requestTimeoutMs
    local requestMaxBytes = maxBytes or CONFIG.requestMaxBytes
    local encodedUrl = UrlEncode(url)
    if encodedUrl == nil then
        return nil, "url encode failed"
    end

    local path = string.format(
        "/submit_txt?url=%s&timeout_ms=%d&max_bytes=%d",
        encodedUrl,
        requestTimeoutMs,
        requestMaxBytes
    )

    local body, err = HttpText(path)
    if body == nil then
        local shouldBlockUntilSafeWindow = type(err) == "string" and string.find(err, "stalled", 1, true) ~= nil
        Bridge.MarkOffline(err, nil, nil, shouldBlockUntilSafeWindow)
        return nil, Bridge.state.lastError
    end

    local requestId = body:match("^ok|([^\n]+)")
    if type(requestId) ~= "string" or requestId == "" then
        return nil, body:match("^err|(.-)\n?$") or "bridge submit failed"
    end

    Bridge.state.activeRequestId = requestId
    return requestId, nil
end

local function ParseResultBody(body)
    if body == "pending\n" or body == "pending" then
        return nil, false, nil
    end

    local lineEnd = string.find(body, "\n", 1, true)
    local header = lineEnd and string.sub(body, 1, lineEnd - 1) or body
    local payload = lineEnd and string.sub(body, lineEnd + 1) or ""

    local errorMessage = header:match("^err|(.*)$")
    if errorMessage ~= nil then
        return nil, true, errorMessage
    end

    local lengthText = header:match("^ok|(%d+)$")
    local expectedLength = tonumber(lengthText)
    if expectedLength == nil then
        return nil, true, "bridge result malformed"
    end
    if #payload < expectedLength then
        return nil, true, "bridge success truncated data"
    end

    return string.sub(payload, 1, expectedLength), true, nil
end

function Bridge.Receive(id)
    if type(id) ~= "string" or id == "" then
        return nil, true, "id missing"
    end
    if Bridge.state.activeRequestId ~= id then
        return nil, true, "unknown or stale request id"
    end

    local encodedId = UrlEncode(id)
    if encodedId == nil then
        Bridge.state.activeRequestId = nil
        return nil, true, "id encode failed"
    end

    local body, err = HttpText("/result_txt?id=" .. encodedId)
    if body == nil then
        local shouldBlockUntilSafeWindow = type(err) == "string" and string.find(err, "stalled", 1, true) ~= nil
        Bridge.MarkOffline(err, nil, nil, shouldBlockUntilSafeWindow)
        Bridge.state.activeRequestId = nil
        return nil, true, Bridge.state.lastError
    end

    local data, finished, receiveErr = ParseResultBody(body)
    if finished then
        Bridge.state.activeRequestId = nil
    end
    return data, finished, receiveErr
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
    local ok, value = pcall(function()
        return globals.FrameTime()
    end)
    if ok and type(value) == "number" then
        frameTime = value
    end
    if frameTime < 0 then
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

callbacks.Unregister("Draw", "local_bridge_simple_draw")
callbacks.Register("Draw", "local_bridge_simple_draw", OnDraw)

return {
    Bridge = Bridge,
    Stress = Stress,
}
