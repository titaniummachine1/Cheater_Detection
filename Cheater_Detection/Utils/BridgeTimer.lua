--[[
    BridgeTimer
    High-precision timing utility using the Python bridge as a timing server.
    Provides microsecond-level timing for profiling (even with ~200us HTTP overhead).
]]

local BridgeTimer = {}

local BRIDGE_BASE = "http://127.0.0.1:17354"
local lastPingMicros = 0
local bridgeOffset = 0
local lastSyncTime = 0
local SYNC_INTERVAL = 5.0 -- Sync clock every 5 seconds

-- Parse bridge time response (microseconds since epoch)
local function parseBridgeTime(body)
    if not body then return nil end
    -- Bridge returns {"time_us": 1234567890123456, "time_ms": 1234567890123.456}
    local timeUs = body:match('"time_us":%s*(%d+)')
    if timeUs then
        return tonumber(timeUs)
    end
    -- Fallback: try time_ms
    local timeMs = body:match('"time_ms":%s*([%d%.]+)')
    if timeMs then
        return math.floor(tonumber(timeMs) * 1000)
    end
    return nil
end

-- Get current time from bridge (blocking sync call)
function BridgeTimer.QueryTime()
    local url = BRIDGE_BASE .. "/time"
    local startLocal = globals.RealTime()

    -- http is provided by Lmaobox as a global
    local ok, body = pcall(http.Get, url)
    if not ok or type(body) ~= "string" then
        return nil
    end

    local endLocal = globals.RealTime()
    local roundTrip = (endLocal - startLocal) * 1e6 -- microseconds

    local bridgeUs = parseBridgeTime(body)
    if bridgeUs then
        -- Adjust for round-trip time (assume symmetric delay)
        local adjustedTime = bridgeUs + math.floor(roundTrip / 2)
        return adjustedTime, roundTrip
    end

    return nil
end

-- Synchronous time fetch (use sparingly - blocks)
-- Alias for QueryTime - both are sync blocking calls
BridgeTimer.GetTimeSync = BridgeTimer.QueryTime

-- Get high-precision time using bridge-synced clock
-- Falls back to RealTime() if bridge unavailable
function BridgeTimer.NowMicros()
    local now = globals.RealTime()

    -- Periodic sync with bridge (don't sync every call, only every SYNC_INTERVAL)
    if now - lastSyncTime > SYNC_INTERVAL then
        local bridgeUs, rtt = BridgeTimer.QueryTime()
        if bridgeUs then
            local localUs = math.floor(now * 1e6)
            bridgeOffset = bridgeUs - localUs
            lastPingMicros = rtt or 0
        end
        lastSyncTime = now
    end

    -- Return bridge-adjusted time or fallback
    local localUs = math.floor(now * 1e6)
    return localUs + bridgeOffset, lastPingMicros
end

-- Get time in milliseconds (with micro precision)
function BridgeTimer.NowMillis()
    local us, rtt = BridgeTimer.NowMicros()
    return us / 1000, rtt
end

-- Simple profiler section timing using bridge clock
local profileSections = {}

function BridgeTimer.Begin(name)
    profileSections[name] = BridgeTimer.NowMicros()
end

function BridgeTimer.End(name)
    local start = profileSections[name]
    if not start then return nil end

    local elapsed = BridgeTimer.NowMicros() - start
    profileSections[name] = nil
    return elapsed
end

-- Get bridge health/status
function BridgeTimer.GetStatus()
    return {
        offset = bridgeOffset,
        lastPingMicros = lastPingMicros,
        lastSync = lastSyncTime,
        synced = (globals.RealTime() - lastSyncTime) < SYNC_INTERVAL * 2
    }
end

return BridgeTimer
