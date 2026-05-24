--[[
HTTP source resilience test with rate limit simulation.

Purpose:
- Test source health tracking under simulated rate limiting
- Validate circuit breaker behavior
- Test mirror fallback effectiveness
- Measure recovery time after rate limits
- Ensure no bias toward broken providers
]]

local CONFIG = {
    START_DELAY = 1.0,
    REQUEST_TIMEOUT = 12.0,
    INTER_REQUEST_DELAY = 0.5,
    SIMULATED_RATE_LIMIT_DELAY = 2.0, -- delay to simulate rate limit recovery
    CIRCUIT_BREAKER_THRESHOLD = 3,
    HEALTH_DECAY_INTERVAL = 60,       -- seconds
    SOURCES = {
        {
            name = "primary-source",
            url = "https://raw.githubusercontent.com/github/gitignore/main/Global/vim.gitignore",
            mirrors = {
                "https://cdn.jsdelivr.net/gh/github/gitignore@main/Global/vim.gitignore",
            },
            expectBytes = 300
        },
        {
            name = "secondary-source",
            url = "https://example.com/",
            mirrors = {},
            expectBytes = 528
        },
    },
}

local State = {
    isAlive = true,
    isRunning = true,
    nextActionAt = 0,
    inFlight = false,
    currentRound = 0,
    startedAt = 0,
    currentSourceIndex = 1,
    testingMirror = false,

    -- Stats
    totalRequests = 0,
    successfulRequests = 0,
    failedRequests = 0,
    timeoutRequests = 0,
    mirrorFailures = 0,
    mirrorSuccesses = 0,
    circuitBreakerTrips = 0,
    circuitBreakerRecoveries = 0,

    -- Per-source health
    sourceHealth = {},
}

local function Log(message)
    print(string.format("[HTTP-RESILIENCE] %s", tostring(message)))
end

local function RT()
    return (globals and globals.RealTime and globals.RealTime()) or 0
end

local function initSourceHealth(sourceName)
    if not State.sourceHealth[sourceName] then
        State.sourceHealth[sourceName] = {
            successCount = 0,
            failureCount = 0,
            consecutiveFailures = 0,
            circuitBreakerTripped = false,
            circuitBreakerTripTime = 0,
            lastSuccessTime = 0,
            healthScore = 1.0,
        }
    end
    return State.sourceHealth[sourceName]
end

local function checkCircuitBreaker(sourceName, health)
    if health.consecutiveFailures >= CONFIG.CIRCUIT_BREAKER_THRESHOLD and not health.circuitBreakerTripped then
        health.circuitBreakerTripped = true
        health.circuitBreakerTripTime = RT()
        State.circuitBreakerTrips = State.circuitBreakerTrips + 1
        Log(string.format("[CIRCUIT BREAKER] %s tripped after %d consecutive failures",
            sourceName, health.consecutiveFailures))
        return true
    end
    return false
end

local function resetCircuitBreaker(sourceName, health)
    if health.circuitBreakerTripped then
        local now = RT()
        local cooldownElapsed = (now - health.circuitBreakerTripTime) >= CONFIG.SIMULATED_RATE_LIMIT_DELAY
        if cooldownElapsed then
            health.circuitBreakerTripped = false
            health.consecutiveFailures = 0
            State.circuitBreakerRecoveries = State.circuitBreakerRecoveries + 1
            Log(string.format("[CIRCUIT BREAKER] %s recovered after %.1fs cooldown",
                sourceName, now - health.circuitBreakerTripTime))
            return true
        end
    end
    return false
end

local function updateSourceHealth(sourceName, success)
    local health = initSourceHealth(sourceName)
    local now = RT()

    if success then
        health.successCount = health.successCount + 1
        health.consecutiveFailures = 0
        health.lastSuccessTime = now
        health.healthScore = math.min(1.0, health.healthScore + 0.1)
        resetCircuitBreaker(sourceName, health)
    else
        health.failureCount = health.failureCount + 1
        health.consecutiveFailures = health.consecutiveFailures + 1
        health.healthScore = math.max(0.0, health.healthScore - 0.2)
        checkCircuitBreaker(sourceName, health)
    end
end

local function Finish(reason)
    Log(string.format(
        "finish reason=%s total=%d success=%d failed=%d timeout=%d mirror_fail=%d mirror_ok=%d cb_trips=%d cb_recovers=%d",
        tostring(reason),
        State.totalRequests,
        State.successfulRequests,
        State.failedRequests,
        State.timeoutRequests,
        State.mirrorFailures,
        State.mirrorSuccesses,
        State.circuitBreakerTrips,
        State.circuitBreakerRecoveries
    ))

    -- Print per-source health report
    Log("============================================================")
    Log("SOURCE HEALTH REPORT:")
    Log("------------------------------------------------------------")
    for sourceName, health in pairs(State.sourceHealth) do
        Log(string.format("%s: health=%.2f success=%d fail=%d cb=%s",
            sourceName,
            health.healthScore,
            health.successCount,
            health.failureCount,
            health.circuitBreakerTripped and "TRIPPED" or "OK"
        ))
    end
    Log("============================================================")

    State.isRunning = false
    State.inFlight = false
end

local function OnAsyncResponse(data)
    if not State.isAlive or not State.isRunning then
        return
    end

    if not State.inFlight then
        Log("late callback ignored")
        return
    end

    State.inFlight = false
    State.totalRequests = State.totalRequests + 1

    local source = CONFIG.SOURCES[State.currentSourceIndex]
    if not source then
        Finish("invalid source")
        return
    end

    local success = false
    if State.testingMirror then
        if type(data) == "string" and data ~= "" then
            State.mirrorSuccesses = State.mirrorSuccesses + 1
            success = true
            Log(string.format("result round=%d source=%s mirror=SUCCESS len=%d", State.currentRound, source.name, #data))
        else
            State.mirrorFailures = State.mirrorFailures + 1
            Log(string.format("result round=%d source=%s mirror=FAILED", State.currentRound, source.name))
        end
        State.testingMirror = false
    else
        if type(data) == "string" and data ~= "" then
            State.successfulRequests = State.successfulRequests + 1
            success = true
            Log(string.format("result round=%d source=%s status=OK len=%d", State.currentRound, source.name, #data))
        else
            State.failedRequests = State.failedRequests + 1
            Log(string.format("result round=%d source=%s status=FAILED", State.currentRound, source.name))
        end
    end

    updateSourceHealth(source.name, success)

    -- Check if we should test mirror on failure
    if not success and not State.testingMirror and source.mirrors and #source.mirrors > 0 then
        State.testingMirror = true
        State.inFlight = true
        State.startedAt = RT()
        Log(string.format("mirror_fallback round=%d source=%s url=%s", State.currentRound, source.name, source.mirrors
            [1]))
        local ok, err = pcall(http.GetAsync, source.mirrors[1], OnAsyncResponse)
        if not ok then
            State.testingMirror = false
            State.inFlight = false
            Log(string.format("mirror_dispatch_error round=%d detail=%s", State.currentRound, tostring(err)))
        end
        return
    end

    State.nextActionAt = RT() + CONFIG.INTER_REQUEST_DELAY
end

local function DispatchNext()
    if State.inFlight then
        return
    end

    local now = RT()
    if now < State.nextActionAt then
        return
    end

    -- Rotate through sources to avoid bias
    State.currentSourceIndex = State.currentSourceIndex + 1
    if State.currentSourceIndex > #CONFIG.SOURCES then
        State.currentSourceIndex = 1
    end

    local source = CONFIG.SOURCES[State.currentSourceIndex]
    if not source then
        Finish("no sources")
        return
    end

    local health = initSourceHealth(source.name)

    -- Skip if circuit breaker is tripped and cooldown hasn't elapsed
    if health.circuitBreakerTripped then
        local cooldownElapsed = (now - health.circuitBreakerTripTime) >= CONFIG.SIMULATED_RATE_LIMIT_DELAY
        if not cooldownElapsed then
            Log(string.format("skip round=%d source=%s cb_cooldown_remaining=%.1fs",
                State.currentRound, source.name,
                CONFIG.SIMULATED_RATE_LIMIT_DELAY - (now - health.circuitBreakerTripTime)))
            State.nextActionAt = now + 0.1
            return
        end
    end

    State.currentRound = State.currentRound + 1
    State.inFlight = true
    State.startedAt = now

    Log(string.format("dispatch round=%d source=%s url=%s", State.currentRound, source.name, source.url))
    local ok, err = pcall(http.GetAsync, source.url, OnAsyncResponse)
    if not ok then
        State.inFlight = false
        State.failedRequests = State.failedRequests + 1
        updateSourceHealth(source.name, false)
        Log(string.format("dispatch_error round=%d detail=%s", State.currentRound, tostring(err)))
        State.nextActionAt = now + CONFIG.INTER_REQUEST_DELAY
    end
end

local function TickTimeout()
    if not State.inFlight then
        return
    end
    if (RT() - State.startedAt) < CONFIG.REQUEST_TIMEOUT then
        return
    end

    State.inFlight = false
    State.timeoutRequests = State.timeoutRequests + 1

    local source = CONFIG.SOURCES[State.currentSourceIndex]
    if source then
        Log(string.format("timeout round=%d source=%s after=%.2fs", State.currentRound, source.name,
            RT() - State.startedAt))
        updateSourceHealth(source.name, false)

        -- Try mirror on timeout
        if not State.testingMirror and source.mirrors and #source.mirrors > 0 then
            State.testingMirror = true
            State.inFlight = true
            State.startedAt = RT()
            Log(string.format("mirror_fallback_after_timeout round=%d source=%s", State.currentRound, source.name))
            local ok, err = pcall(http.GetAsync, source.mirrors[1], OnAsyncResponse)
            if not ok then
                State.testingMirror = false
                State.inFlight = false
            end
            return
        end
    end

    State.nextActionAt = RT() + CONFIG.INTER_REQUEST_DELAY
end

local function OnDraw()
    if not State.isAlive or not State.isRunning then
        return
    end

    TickTimeout()
    DispatchNext()

    -- Auto-finish after 50 rounds for testing
    if State.currentRound >= 50 then
        Finish("round_limit")
    end
end

local function OnUnload()
    State.isAlive = false
    State.isRunning = false
    State.inFlight = false
    Log("unload")
end

callbacks.Unregister("Draw", "HTTPResilienceTest_Draw")
callbacks.Register("Draw", "HTTPResilienceTest_Draw", OnDraw)

callbacks.Unregister("Unload", "HTTPResilienceTest_Unload")
callbacks.Register("Unload", "HTTPResilienceTest_Unload", OnUnload)

State.nextActionAt = RT() + CONFIG.START_DELAY
Log(string.format("start timeout=%.2f delay=%.2f cb_threshold=%d sources=%d",
    CONFIG.REQUEST_TIMEOUT,
    CONFIG.INTER_REQUEST_DELAY,
    CONFIG.CIRCUIT_BREAKER_THRESHOLD,
    #CONFIG.SOURCES
))
