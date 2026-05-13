--[[
HTTP sync vs async comprehensive parity test.

Tests http.Get (sync) vs http.GetAsync on the same URLs across multiple size
buckets. Prints a plain-English verdict at the end so you can copy-paste one
block to Discord without any extra explanation.
]]

local CONFIG = {
    START_DELAY   = 1.0,
    TIMEOUT       = 12.0,
    ROUND_DELAY   = 2.0,
    REPEATS       = 3,
    SOURCES = {
        -- tiny (<1 KB)
        { name = "github-zen",      url = "https://api.github.com/zen",                                                                                               expectBytes = 50    },
        -- small (~1 KB)
        { name = "jsonplaceholder", url = "https://jsonplaceholder.typicode.com/todos/1",                                                                              expectBytes = 83    },
        -- medium (~10 KB)
        { name = "example.com",     url = "https://example.com/",                                                                                                     expectBytes = 528   },
        -- medium-large (~200 bytes)
        { name = "cloudflare",      url = "https://www.cloudflare.com/cdn-cgi/trace",                                                                                 expectBytes = 210   },
        -- small GitHub raw file (~1KB) - safe for http.GetAsync
        { name = "github-raw-small", url = "https://raw.githubusercontent.com/github/gitignore/main/Global/vim.gitignore",                                            expectBytes = 300    },
        -- NOTE: DO NOT test http.GetAsync with responses >= ~176KB.
        -- Confirmed: Lmaobox http.GetAsync CRASHES TF2 (engine-level fault, not Lua)
        -- when the response body is ~176KB or larger. The fetcher uses http.Get
        -- (blocking/sync) for all large DB downloads and is NOT affected by this bug.
    },
}

-- ── per-source stats (keyed by source name) ─────────────────────────────────
local stats = {}
for _, src in ipairs(CONFIG.SOURCES) do
    stats[src.name] = { syncOk=0, syncFail=0, asyncMatch=0, asyncEmpty=0, asyncDiffer=0, asyncTimeout=0 }
end

local State = {
    isAlive        = true,
    isRunning      = false,
    nextActionAt   = 0,
    sourceIndex    = 1,
    repeatIndex    = 1,
    inFlight       = false,
    asyncStartedAt = 0,
    currentSource  = nil,
    currentSyncLen = 0,
    currentSyncMs  = 0,
}

local function Log(msg) print("[HTTP-PARITY] " .. tostring(msg)) end
local function RT() return (globals and globals.RealTime and globals.RealTime()) or 0 end

local function Advance(now)
    State.inFlight = false
    State.sourceIndex = State.sourceIndex + 1
    if State.sourceIndex > #CONFIG.SOURCES then
        State.sourceIndex = 1
        State.repeatIndex = State.repeatIndex + 1
    end
    State.nextActionAt = now + CONFIG.ROUND_DELAY
end

-- ── final report ─────────────────────────────────────────────────────────────
local function PrintReport()
    Log("============================================================")
    Log(string.format("RESULTS  repeats=%d  sources=%d", CONFIG.REPEATS, #CONFIG.SOURCES))
    Log("------------------------------------------------------------")
    Log("SOURCE               SYNC SFAIL AMATCH AEMPTY ADIFFER ATIMEOUT  STATUS")
    Log("------------------------------------------------------------")

    local anyAsyncBroken   = false
    local sizeLimitSuspect = false
    local firstFailBytes   = nil

    for _, src in ipairs(CONFIG.SOURCES) do
        local s = stats[src.name]
        local asyncFailed = s.asyncEmpty + s.asyncDiffer + s.asyncTimeout
        local verdict = "OK"
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
        Log(string.format("%s  %d %d %d %d %d %d  %s",
            src.name, s.syncOk, s.syncFail,
            s.asyncMatch, s.asyncEmpty, s.asyncDiffer, s.asyncTimeout,
            verdict))
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

    local now    = RT()
    local source = State.currentSource
    local s      = stats[source.name]
    local syncLen = State.currentSyncLen

    State.inFlight = false

    local asyncMs = (now - (State.asyncStartedAt or now)) * 1000

    if type(data) ~= "string" or data == "" then
        s.asyncEmpty = s.asyncEmpty + 1
        Log(string.format("[r%d] ASYNC %s EMPTY (sync=%d bytes) time=%dms", State.repeatIndex, source.name, syncLen, math.floor(asyncMs)))
    elseif #data == syncLen then
        s.asyncMatch = s.asyncMatch + 1
        Log(string.format("[r%d] ASYNC %s MATCH len=%d time=%dms (sync=%dms)", State.repeatIndex, source.name, #data, math.floor(asyncMs), math.floor(State.currentSyncMs)))
    else
        s.asyncDiffer = s.asyncDiffer + 1
        Log(string.format("[r%d] ASYNC %s DIFFER async=%d sync=%d time=%dms", State.repeatIndex, source.name, #data, syncLen, math.floor(asyncMs)))
    end

    Advance(now)
    if State.repeatIndex > CONFIG.REPEATS then
        Finish()
    end
end

-- ── dispatch ──────────────────────────────────────────────────────────────────
local function DispatchCurrent(now)
    local source = CONFIG.SOURCES[State.sourceIndex]
    if not source then Finish() return end

    State.currentSource  = source
    local s = stats[source.name]

    Log(string.format("[r%d] ---- source=%s expect=~%d bytes", State.repeatIndex, source.name, source.expectBytes or 0))

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

    s.syncOk = s.syncOk + 1
    State.currentSyncLen = #syncResult
    State.currentSyncMs  = syncMs
    Log(string.format("[r%d] SYNC  %s OK len=%d time=%dms", State.repeatIndex, source.name, #syncResult, math.floor(syncMs)))

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
            local s = stats[source.name]
            s.asyncTimeout = s.asyncTimeout + 1
            State.inFlight = false
            Log(string.format("[r%d] ASYNC %-20s TIMEOUT  after=%.1fs", State.repeatIndex, source.name, CONFIG.TIMEOUT))
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
    State.isAlive    = false
    State.isRunning  = false
    State.inFlight   = false
    Log("unload")
end

callbacks.Unregister("Draw",   "HTTPParityTest_Draw")
callbacks.Unregister("Unload", "HTTPParityTest_Unload")
callbacks.Register("Draw",   "HTTPParityTest_Draw",   OnDraw)
callbacks.Register("Unload", "HTTPParityTest_Unload", OnUnload)

State.isRunning      = true
State.nextActionAt   = RT() + CONFIG.START_DELAY
Log(string.format("start  repeats=%d  timeout=%.1fs  sources=%d", CONFIG.REPEATS, CONFIG.TIMEOUT, #CONFIG.SOURCES))
