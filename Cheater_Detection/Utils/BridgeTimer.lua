--[[
    BridgeTimer
    High-precision timing for profiling. Uses globals.RealTime() only.
    (Bridge /time sync removed — bridge gets a single /health check at Lua load.)
]]

local BridgeTimer = {}

local lastPingMicros = 0

-- Get high-precision time (microseconds from RealTime)
function BridgeTimer.NowMicros()
    local now = globals.RealTime()
    local localUs = math.floor(now * 1e6)
    return localUs, lastPingMicros
end

-- Get time in milliseconds (with micro precision)
function BridgeTimer.NowMillis()
    local us, rtt = BridgeTimer.NowMicros()
    return us / 1000, rtt
end

-- Simple profiler section timing
local profileSections = {}

function BridgeTimer.Begin(name)
    profileSections[name] = BridgeTimer.NowMicros()
end

function BridgeTimer.End(name)
    local start = profileSections[name]
    if not start then
        return nil
    end

    local elapsed = BridgeTimer.NowMicros() - start
    profileSections[name] = nil
    return elapsed
end

function BridgeTimer.GetStatus()
    return {
        offset = 0,
        lastPingMicros = lastPingMicros,
        lastSync = 0,
        synced = false,
    }
end

return BridgeTimer
