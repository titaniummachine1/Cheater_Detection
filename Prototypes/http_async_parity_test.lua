--[[
HTTP sync vs async comprehensive parity test with source health tracking.

Tests http.Get (sync) vs http.GetAsync on the same URLs across multiple size
buckets. Tracks source health, detects circuit breaker patterns, and tests
mirror URLs for resilience. Prints a plain-English verdict at the end.
]]

local CONFIG = {
    START_DELAY               = 1.0,
    TIMEOUT                   = 12.0,
    ROUND_DELAY               = 2.0,
    REPEATS                   = 3,
    CIRCUIT_BREAKER_THRESHOLD = 3,    -- consecutive failures to trigger circuit breaker
    TEST_MIRRORS              = true, -- test mirror URLs if available
    SOURCES                   = {
        -- tiny (<1 KB)
        { name = "github-zen",       url = "https://api.github.com/zen",                                                   expectBytes = 50 },
        -- small (~1 KB)
        { name = "jsonplaceholder",  url = "https://jsonplaceholder.typicode.com/todos/1",                                 expectBytes = 83 },
        -- medium (~10 KB)
        { name = "example.com",      url = "https://example.com/",                                                         expectBytes = 528 },
        -- medium-large (~200 bytes)
        { name = "cloudflare",       url = "https://www.cloudflare.com/cdn-cgi/trace",                                     expectBytes = 210 },
        -- small GitHub raw file (~1KB) - safe for http.GetAsync
        { name = "github-raw-small", url = "https://raw.githubusercontent.com/github/gitignore/main/Global/vim.gitignore", expectBytes = 300 },
        -- Source with mirrors for resilience testing
        {
            name = "mirrored-source",
            url = "https://raw.githubusercontent.com/github/gitignore/main/Global/vim.gitignore",
            mirrors = {
                "https://cdn.jsdelivr.net/gh/github/gitignore@main/Global/vim.gitignore",
            },
            expectBytes = 300
        },
        -- NOTE: DO NOT test http.GetAsync with responses >= ~176KB.
        -- Confirmed: Lmaobox http.GetAsync CRASHES TF2 (engine-level fault, not Lua)
        -- when the response body is ~176KB or larger. The fetcher uses http.Get
        -- (blocking/sync) for all large DB downloads and is NOT affected by this bug.
    },
}

-- ── per-source stats (keyed by source name) ─────────────────────────────────
local stats = {}
for _, src in ipairs(CONFIG.SOURCES) do
    stats[src.name] = {
        syncOk = 0,
        syncFail = 0,
        asyncMatch = 0,
        asyncEmpty = 0,
        asyncDiffer = 0,
        asyncTimeout = 0,
        -- Health tracking
        consecutiveFailures = 0,
        circuitBreakerTripped = false,
        circuitBreakerTripTime = 0,
        mirrorTested = false,
        mirrorSuccess = false,
        mirrorUrl = nil
    }
end

local State = {
    isAlive            = true,
    isRunning          = false,
    nextActionAt       = 0,
    sourceIndex        = 1,
    repeatIndex        = 1,
    inFlight           = false,
    asyncStartedAt     = 0,
    currentSource      = nil,
    currentSyncLen     = 0,
    currentSyncMs      = 0,
    testingMirror      = false,
    currentMirrorIndex = 0,
}

local function Log(msg) print("[HTTP-PARITY] " .. tostring(msg)) end
local function RT() return (globals and globals.RealTime and globals.RealTime()) or 0 end

local function Advance(now)
    State.inFlight = false
    State.testingMirror = false
    State.currentMirrorIndex = 0
    State.sourceIndex = State.sourceIndex + 1
    if State.sourceIndex > #CONFIG.SOURCES then
        State.sourceIndex = 1
        State.repeatIndex = State.repeatIndex + 1
    end
    State.nextActionAt = now + CONFIG.ROUND_DELAY
end

local function CheckCircuitBreaker(sourceName, s)
    if not s then return false end
    s.consecutiveFailures = s.consecutiveFailures + 1
    if s.consecutiveFailures >= CONFIG.CIRCUIT_BREAKER_THRESHOLD then
        s.circuitBreakerTripped = true
        s.circuitBreakerTripTime = RT()
        Log(string.format("[CIRCUIT BREAKER] %s tripped after %d consecutive failures", sourceName, s
            .consecutiveFailures))
        return true
    end
    return false
end

local function TryMirrorFallback(source, s)
    if not CONFIG.TEST_MIRRORS then return false end
    if not source or not source.mirrors or #source.mirrors == 0 then return false end
    if s.mirrorTested then return false end

    State.testingMirror = true
    State.currentMirrorIndex = 1
    s.mirrorTested = true
    s.mirrorUrl = source.mirrors[1]
    Log(string.format("[MIRROR FALLBACK] Testing mirror for %s: %s", source.name, s.mirrorUrl))
    return true
end

-- ── final report ─────────────────────────────────────────────────────────────
local function PrintReport()
    Log("============================================================")
    Log(string.format("RESULTS  repeats=%d  sources=%d", CONFIG.REPEATS, #CONFIG.SOURCES))
    Log("------------------------------------------------------------")
    Log("SOURCE               SYNC SFAIL AMATCH AEMPTY ADIFFER ATIMEOUT  CBREAK  MIRROR  STATUS")
    Log("------------------------------------------------------------")

    local anyAsyncBroken         = false
    local sizeLimitSuspect       = false
    local firstFailBytes         = nil
    local circuitBreakersTripped = 0
    local mirrorsTested          = 0
    local mirrorsSucceeded       = 0

    for _, src in ipairs(CONFIG.SOURCES) do
        local s = stats[src.name]
        if not s then return end
        local asyncFailed = s.asyncEmpty + s.asyncDiffer + s.asyncTimeout
        local verdict = "OK"
        local cbStatus = s.circuitBreakerTripped and "YES" or "NO"
        local mirrorStatus = s.mirrorTested and (s.mirrorSuccess and "OK" or "FAIL") or "N/A"

        if s.circuitBreakerTripped then
            circuitBreakersTripped = circuitBreakersTripped + 1
        end
        if s.mirrorTested then
            mirrorsTested = mirrorsTested + 1
            if s.mirrorSuccess then
                mirrorsSucceeded = mirrorsSucceeded + 1
            end
        end

        if s.syncFail > 0 and s.asyncMatch == 0 then
            verdict = "SYNC-DEAD"
        elseif asyncFailed > 0 and s.syncOk > 0 then
            verdict = "ASYNC-BROKEN"
            anyAsyncBroken = true
            if not firstFailBytes or src.expectBytes > firstFailBytes then
                firstFailBytes = src.expectBytes
            end
        elseif asyncFailed > 0 then
            verdict = "BOTH-FAILED"
        end
        Log(string.format("%s  %d %d %d %d %d %d  %s  %s  %s",
            src.name, s.syncOk, s.syncFail,
            s.asyncMatch, s.asyncEmpty, s.asyncDiffer, s.asyncTimeout,
            cbStatus, mirrorStatus, verdict))
    end

    -- check if only large sources fail (size-limit pattern)
    if anyAsyncBroken and firstFailBytes then
        local allSmallOk = true
        for _, src in ipairs(CONFIG.SOURCES) do
            local s = stats[src.name]
            local asyncFailed = s.asyncEmpty + s.asyncDiffer + s.asyncTimeout
            if asyncFailed > 0 and src.expectBytes < firstFailBytes then
                allSmallOk = false
            end
        end
        sizeLimitSuspect = allSmallOk
    end

    Log("------------------------------------------------------------")
    Log("DIAGNOSIS:")
    if not anyAsyncBroken then
        Log("  [PASS] http.GetAsync matches http.Get on all sources.")
        Log("         Lmaobox async HTTP is working correctly.")
    else
        Log("  [FAIL] http.GetAsync returns empty/wrong body on some sources.")
        if sizeLimitSuspect then
            Log(string.format(
                "  [ROOT CAUSE] Looks like a response-size limit in http.GetAsync."))
            Log(string.format(
                "               Failures start at ~%d bytes. Small responses are fine.",
                firstFailBytes or 0))
            Log("  [IMPACT] Any fetcher using http.GetAsync for large DB files will")
            Log("           silently get empty responses. Use http.Get (blocking) instead.")
        else
            Log("  [ROOT CAUSE] Failures are not size-correlated - may be rate-limiting")
            Log("               or flaky network. Re-run to confirm.")
        end
    end
    if circuitBreakersTripped > 0 then
        Log(string.format("  [CIRCUIT BREAKERS] %d sources tripped (consecutive failures >= %d)",
            circuitBreakersTripped, CONFIG.CIRCUIT_BREAKER_THRESHOLD))
    end
    if mirrorsTested > 0 then
        Log(string.format("  [MIRROR TESTS] %d mirrors tested, %d succeeded (%.0f%% success rate)",
            mirrorsTested, mirrorsSucceeded, (mirrorsSucceeded / mirrorsTested) * 100))
    end
    Log("============================================================")
end

local function Finish()
    State.isRunning = false
    State.inFlight  = false
    PrintReport()
end

-- ── async callback ────────────────────────────────────────────────────────────
local function OnAsyncResponse(data)
    if not State.isAlive or not State.isRunning or not State.inFlight then return end

    local now = RT()
    local source = State.currentSource
    if not source then return end
    local s = stats[source.name]
    if not s then return end
    local syncLen = State.currentSyncLen

    State.inFlight = false

    local asyncMs = (now - (State.asyncStartedAt or now)) * 1000

    if State.testingMirror then
        -- Mirror response handling
        if type(data) == "string" and data ~= "" and #data == syncLen then
            s.mirrorSuccess = true
            s.asyncMatch = s.asyncMatch + 1
            Log(string.format("[r%d] MIRROR %s SUCCESS len=%d time=%dms", State.repeatIndex, source.name, #data,
                math.floor(asyncMs)))
            s.consecutiveFailures = 0 -- Reset on mirror success
        else
            Log(string.format("[r%d] MIRROR %s FAILED", State.repeatIndex, source.name))
            CheckCircuitBreaker(source.name, s)
        end
        Advance(now)
        if State.repeatIndex > CONFIG.REPEATS then
            Finish()
        end
        return
    end

    -- Primary URL response handling
    if type(data) ~= "string" or data == "" then
        s.asyncEmpty = s.asyncEmpty + 1
        Log(string.format("[r%d] ASYNC %s EMPTY (sync=%d bytes) time=%dms", State.repeatIndex, source.name, syncLen,
            math.floor(asyncMs)))
        if TryMirrorFallback(source, s) then
            State.inFlight = true
            State.asyncStartedAt = now
            http.GetAsync(s.mirrorUrl, OnAsyncResponse)
            return
        end
        CheckCircuitBreaker(source.name, s)
    elseif #data == syncLen then
        s.asyncMatch = s.asyncMatch + 1
        s.consecutiveFailures = 0 -- Reset on success
        Log(string.format("[r%d] ASYNC %s MATCH len=%d time=%dms (sync=%dms)", State.repeatIndex, source.name, #data,
            math.floor(asyncMs), math.floor(State.currentSyncMs)))
    else
        s.asyncDiffer = s.asyncDiffer + 1
        Log(string.format("[r%d] ASYNC %s DIFFER async=%d sync=%d time=%dms", State.repeatIndex, source.name, #data,
            syncLen, math.floor(asyncMs)))
        if TryMirrorFallback(source, s) then
            State.inFlight = true
            State.asyncStartedAt = now
            http.GetAsync(s.mirrorUrl, OnAsyncResponse)
            return
        end
        CheckCircuitBreaker(source.name, s)
    end

    Advance(now)
    if State.repeatIndex > CONFIG.REPEATS then
        Finish()
    end
end

-- ── dispatch ──────────────────────────────────────────────────────────────────
local function DispatchCurrent(now)
    local source = CONFIG.SOURCES[State.sourceIndex]
    if not source then
        Finish()
        return
    end

    State.currentSource = source
    local s = stats[source.name]
    if not s then
        Log(string.format("[ERROR] Missing stats for source: %s", source.name or "unknown"))
        Advance(now)
        if State.repeatIndex > CONFIG.REPEATS then Finish() end
        return
    end

    Log(string.format("[r%d] ---- source=%s expect=~%d bytes", State.repeatIndex, source.name or "unknown",
        source.expectBytes or 0))

    local syncT0 = RT()
    local syncResult = http.Get(source.url)
    local syncMs = (RT() - syncT0) * 1000

    if type(syncResult) ~= "string" or syncResult == "" then
        s.syncFail = s.syncFail + 1
        Log(string.format("[r%d] SYNC  %s FAILED (%dms)", State.repeatIndex, source.name, math.floor(syncMs)))
        Advance(now)
        if State.repeatIndex > CONFIG.REPEATS then Finish() end
        return
    end

    s.syncOk             = s.syncOk + 1
    State.currentSyncLen = #syncResult
    State.currentSyncMs  = syncMs
    Log(string.format("[r%d] SYNC  %s OK len=%d time=%dms", State.repeatIndex, source.name, #syncResult,
        math.floor(syncMs)))

    State.inFlight       = true
    State.asyncStartedAt = now
    http.GetAsync(source.url, OnAsyncResponse)
end

-- ── tick ──────────────────────────────────────────────────────────────────────
local function OnDraw()
    if not State.isAlive or not State.isRunning then return end
    local now = RT()

    if State.inFlight then
        if (now - State.asyncStartedAt) >= CONFIG.TIMEOUT then
            local source = State.currentSource
            if source then
                local s = stats[source.name]
                if s then
                    s.asyncTimeout = s.asyncTimeout + 1
                    if TryMirrorFallback(source, s) then
                        State.inFlight = true
                        State.asyncStartedAt = now
                        http.GetAsync(s.mirrorUrl, OnAsyncResponse)
                        return
                    end
                    CheckCircuitBreaker(source.name, s)
                end
                Log(string.format("[r%d] ASYNC %-20s TIMEOUT  after=%.1fs", State.repeatIndex, source.name,
                    CONFIG.TIMEOUT))
            end
            State.inFlight = false
            Advance(now)
            if State.repeatIndex > CONFIG.REPEATS then Finish() end
        end
        return
    end

    if now < State.nextActionAt then return end

    if State.repeatIndex > CONFIG.REPEATS then
        Finish()
        return
    end

    DispatchCurrent(now)
    -- do NOT call Advance here; Advance is called inside OnAsyncResponse or on timeout
end

local function OnUnload()
    State.isAlive   = false
    State.isRunning = false
    State.inFlight  = false
    Log("unload")
end

callbacks.Unregister("Draw", "HTTPParityTest_Draw")
callbacks.Unregister("Unload", "HTTPParityTest_Unload")
callbacks.Register("Draw", "HTTPParityTest_Draw", OnDraw)
callbacks.Register("Unload", "HTTPParityTest_Unload", OnUnload)

State.isRunning    = true
State.nextActionAt = RT() + CONFIG.START_DELAY
Log(string.format("start  repeats=%d  timeout=%.1fs  sources=%d", CONFIG.REPEATS, CONFIG.TIMEOUT, #CONFIG.SOURCES))
