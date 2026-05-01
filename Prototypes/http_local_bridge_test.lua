--[[
Tiny local-bridge HTTP prototype.

Usage model:
1) Start bridge server on PC:
   python Prototypes/local_http_bridge_server.py
2) In Lua, call Bridge.Start(url)
3) Poll Bridge.Poll(id) in a callback

This lets Lua do short localhost blocking http.Get calls while the bridge performs
remote HTTP in background threads.
]]

local function LoadJsonModule()
    local okLocal, moduleLocal = pcall(require, "Json")
    if okLocal and type(moduleLocal) == "table" and type(moduleLocal.decode) == "function" then
        return moduleLocal
    end

    local okMain, moduleMain = pcall(require, "Cheater_Detection.Libs.Json")
    if okMain and type(moduleMain) == "table" and type(moduleMain.decode) == "function" then
        return moduleMain
    end

    error("http_local_bridge_test: JSON module missing (Prototypes.Json or Cheater_Detection.Libs.Json)")
end

local Json = LoadJsonModule()

local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 17354
local BRIDGE_BASE = "http://" .. BRIDGE_HOST .. ":" .. tostring(BRIDGE_PORT)

local POLL_INTERVAL = 0.10
local REQUEST_TIMEOUT_MS = 12000
local REQUEST_MAX_BYTES = 2 * 1024 * 1024
local START_RETRY_DELAY = 0.50
local ERROR_LOG_COOLDOWN = 1.50

local State = {
    pendingId = nil,
    nextPollAt = 0.0,
    nextStartAttemptAt = 0.0,
    lastErrorLogAt = -9999.0,
    startedAt = 0.0,
    completed = false,
}

local function Log(message)
    print(string.format("[LOCAL-BRIDGE] %s", tostring(message)))
end

local function UrlEncode(value)
    assert(type(value) == "string", "UrlEncode: value must be string")
    local encoded = string.gsub(value, "([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", string.byte(ch))
    end)
    return encoded
end

local function DecodeJson(body)
    if type(body) ~= "string" then
        return false, nil, "response body is not string"
    end

    if body == "" then
        return false, nil, "empty response from bridge"
    end

    local ok, decoded = pcall(Json.decode, body)
    if not ok or type(decoded) ~= "table" then
        local preview = string.sub(body, 1, 96)
        return false, nil, "invalid json from bridge: " .. tostring(preview)
    end

    return true, decoded, nil
end

local Bridge = {}

function Bridge.Health()
    local body = http.Get(BRIDGE_BASE .. "/health")
    local ok, decoded, err = DecodeJson(body)
    if not ok then
        return false, nil, err
    end
    return decoded.ok == true, decoded, nil
end

function Bridge.Start(url)
    assert(type(url) == "string" and url ~= "", "Bridge.Start: url missing")

    local endpoint = string.format(
        "%s/submit?url=%s&timeout_ms=%d&max_bytes=%d",
        BRIDGE_BASE,
        UrlEncode(url),
        REQUEST_TIMEOUT_MS,
        REQUEST_MAX_BYTES
    )

    local body = http.Get(endpoint)
    local ok, decoded, err = DecodeJson(body)
    if not ok then
        return false, nil, err
    end

    if decoded.ok ~= true or type(decoded.id) ~= "string" then
        return false, nil, decoded.error or "bridge submit failed"
    end

    return true, decoded.id, nil
end

function Bridge.Poll(id)
    assert(type(id) == "string" and id ~= "", "Bridge.Poll: id missing")

    local endpoint = string.format("%s/result?id=%s", BRIDGE_BASE, UrlEncode(id))
    local body = http.Get(endpoint)
    local ok, decoded, err = DecodeJson(body)
    if not ok then
        return false, true, nil, err
    end

    if decoded.ok ~= true then
        return false, true, nil, decoded.error or "bridge result failed"
    end

    if decoded.done ~= true then
        return true, false, nil, nil
    end

    if decoded.success == true then
        return true, true, decoded.data, nil
    end

    return false, true, nil, decoded.error or "remote request failed"
end

local function IsTransientBridgeError(err)
    if type(err) ~= "string" then
        return true
    end

    if string.find(err, "invalid json from bridge", 1, true) then
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

local function LogErrorRateLimited(message)
    local now = globals.RealTime()
    if now - State.lastErrorLogAt < ERROR_LOG_COOLDOWN then
        return
    end
    State.lastErrorLogAt = now
    Log(message)
end

local function StartDemoRequest()
    if State.pendingId then
        return
    end

    local now = globals.RealTime()
    if now < State.nextStartAttemptAt then
        return
    end

    local healthy, _, healthErr = Bridge.Health()
    if not healthy then
        State.nextStartAttemptAt = now + START_RETRY_DELAY
        LogErrorRateLimited("bridge not ready: " .. tostring(healthErr))
        return
    end

    local targetUrl = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids"
    local ok, requestId, err = Bridge.Start(targetUrl)
    if not ok then
        State.nextStartAttemptAt = now + START_RETRY_DELAY
        if IsTransientBridgeError(err) then
            LogErrorRateLimited("bridge transient submit error; retrying: " .. tostring(err))
        else
            LogErrorRateLimited("submit failed: " .. tostring(err))
        end
        return
    end

    State.pendingId = requestId
    State.startedAt = globals.RealTime()
    State.nextPollAt = State.startedAt + POLL_INTERVAL
    State.completed = false
    Log("submitted id=" .. requestId)
end

local function PollDemoRequest()
    if not State.pendingId or State.completed then
        return
    end

    local now = globals.RealTime()
    if now < State.nextPollAt then
        return
    end

    State.nextPollAt = now + POLL_INTERVAL

    local ok, done, data, err = Bridge.Poll(State.pendingId)
    if not done then
        return
    end

    State.completed = true

    if ok then
        local length = type(data) == "string" and #data or 0
        Log(string.format("success id=%s bytes=%d", State.pendingId, length))
    else
        Log(string.format("failed id=%s err=%s", State.pendingId, tostring(err)))
    end
end

local function OnDraw()
    if not State.pendingId then
        StartDemoRequest()
        return
    end

    PollDemoRequest()
end

callbacks.Unregister("Draw", "local_bridge_test_draw")
callbacks.Register("Draw", "local_bridge_test_draw", OnDraw)

return {
    Bridge = Bridge,
}
