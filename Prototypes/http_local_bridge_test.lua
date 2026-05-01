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

assert(http and type(http.Get) == "function", "http_local_bridge_test: http.Get missing")
assert(callbacks and type(callbacks.Register) == "function", "http_local_bridge_test: callbacks missing")
assert(globals and type(globals.RealTime) == "function", "http_local_bridge_test: globals missing")

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

local CONFIG = {
    bridgeHost = "127.0.0.1",
    bridgePort = 17354,
    protocol = "local-http-bridge-v1",
    targetUrl = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
    pollInterval = 0.0,
    requestTimeoutMs = 12000,
    requestMaxBytes = 2 * 1024 * 1024,
    startRetryDelay = 0.50,
    statusLogInterval = 2.00,
    errorLogCooldown = 1.50,
}

local BRIDGE_BASE = "http://" .. CONFIG.bridgeHost .. ":" .. tostring(CONFIG.bridgePort)

local function Log(message)
    print(string.format("[LOCAL-BRIDGE] %s", tostring(message)))
end

local function UrlEncode(value)
    assert(type(value) == "string", "UrlEncode: value must be string")
    return string.gsub(value, "([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
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

local function HttpJson(path)
    local body = http.Get(BRIDGE_BASE .. path)
    return DecodeBody(body)
end

local Bridge = {
    state = {
        alive = false,
        protocol = nil,
        lastError = nil,
        lastProbeAt = 0.0,
    },
}

function Bridge.Probe()
    local response, err = HttpJson("/health")
    local payload = response or {}
    local alive = payload.ok == true and payload.alive == true and payload.protocol == CONFIG.protocol

    Bridge.state.alive = alive
    Bridge.state.protocol = payload.protocol
    Bridge.state.lastProbeAt = globals.RealTime()
    Bridge.state.lastError = alive and nil or (err or payload.error or "bridge offline")

    return alive, Bridge.state.lastError
end

function Bridge.IsAlive()
    return Bridge.state.alive == true
end

function Bridge.CanUse()
    return Bridge.IsAlive()
end

function Bridge.Start(url, timeoutMs, maxBytes)
    assert(type(url) == "string" and url ~= "", "Bridge.Start: url missing")

    local requestTimeoutMs = timeoutMs or CONFIG.requestTimeoutMs
    local requestMaxBytes = maxBytes or CONFIG.requestMaxBytes
    local path = string.format(
        "/submit?url=%s&timeout_ms=%d&max_bytes=%d",
        UrlEncode(url),
        requestTimeoutMs,
        requestMaxBytes
    )

    local response, err = HttpJson(path)
    local payload = response or {}
    local requestId = payload.id

    if payload.ok ~= true or type(requestId) ~= "string" then
        return nil, err or payload.error or "bridge submit failed"
    end

    return requestId, nil
end

function Bridge.Receive(id)
    assert(type(id) == "string" and id ~= "", "Bridge.Receive: id missing")

    local response, err = HttpJson("/result?id=" .. UrlEncode(id))
    if response == nil then
        return nil, false, err
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
    local frameTime = globals.FrameTime()
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
end

local function StartStressRequest(now)
    if Stress.pendingId ~= nil or now < Stress.nextStartAt then
        return
    end

    if not Bridge.CanUse() then
        local alive, probeErr = Bridge.Probe()
        if not alive then
            Stress.retry = Stress.retry + 1
            Stress.nextStartAt = now + CONFIG.startRetryDelay
            LogErrorRateLimited("bridge offline: " .. tostring(probeErr), now)
            return
        end
    end

    local requestId, err = Bridge.Start(CONFIG.targetUrl)
    if requestId == nil then
        Stress.retry = Stress.retry + 1
        Stress.nextStartAt = now + CONFIG.startRetryDelay
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
    local now = globals.RealTime()
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
