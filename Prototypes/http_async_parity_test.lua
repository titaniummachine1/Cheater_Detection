--[[
HTTP async parity test.

Goal:
- compare http.GetAsync against http.Get on the same URL set
- report exact parity by length and lightweight content signature
- keep dispatch single-flight to avoid concurrency noise
]]

local CONFIG = {
    START_DELAY = 1.0,
    REQUEST_TIMEOUT = 12.0,
    ROUND_DELAY = 1.5,
    REPEATS = 2,
    SOURCES = {
        { name = "example.com",       url = "https://example.com/" },
        { name = "httpbin-get",       url = "https://httpbin.org/get" },
        { name = "jsonplaceholder",   url = "https://jsonplaceholder.typicode.com/todos/1" },
        { name = "api-github-zen",    url = "https://api.github.com/zen" },
        { name = "raw-github-sample", url = "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json" },
    },
}

local State = {
    isAlive = true,
    isRunning = false,
    nextActionAt = 0,
    sourceIndex = 1,
    repeatIndex = 1,
    inFlight = false,
    waitingForAsync = false,
    asyncStartedAt = 0,
    currentSource = nil,
    currentSyncBody = nil,
    total = 0,
    matches = 0,
    mismatches = 0,
    emptyAsync = 0,
    timeoutAsync = 0,
    syncErrors = 0,
    asyncDispatchErrors = 0,
}

local function Log(message)
    print(string.format("[HTTP-PARITY] %s", tostring(message)))
end

local function Signature(text)
    if type(text) ~= "string" then
        return "nil"
    end

    local len = #text
    local sum = 0
    local limit = len
    if limit > 256 then
        limit = 256
    end

    for i = 1, limit do
        sum = (sum + string.byte(text, i) * i) % 2147483647
    end

    local head = text:sub(1, 24):gsub("%c", " ")
    return string.format("len=%d sig=%d head='%s'", len, sum, head)
end

local function Finish()
    Log(string.format(
        "finish total=%d matches=%d mismatches=%d empty_async=%d timeout_async=%d sync_errors=%d async_dispatch_errors=%d",
        State.total,
        State.matches,
        State.mismatches,
        State.emptyAsync,
        State.timeoutAsync,
        State.syncErrors,
        State.asyncDispatchErrors
    ))
    State.isRunning = false
    State.inFlight = false
    State.waitingForAsync = false
    State.currentSource = nil
    State.currentSyncBody = nil
end

local function Advance(now)
    State.sourceIndex = State.sourceIndex + 1
    if State.sourceIndex > #CONFIG.SOURCES then
        State.sourceIndex = 1
        State.repeatIndex = State.repeatIndex + 1
    end

    if State.repeatIndex > CONFIG.REPEATS then
        Finish()
        return
    end

    State.nextActionAt = now + CONFIG.ROUND_DELAY
end

local function OnAsyncResponse(data)
    if not State.isAlive or not State.isRunning or not State.inFlight then
        return
    end

    local now = globals.RealTime()
    local source = State.currentSource
    local syncBody = State.currentSyncBody

    State.inFlight = false
    State.waitingForAsync = false
    State.total = State.total + 1

    if type(data) ~= "string" or data == "" then
        State.emptyAsync = State.emptyAsync + 1
        State.mismatches = State.mismatches + 1
        Log(string.format("mismatch source=%s reason=empty_async sync={%s}", source.name, Signature(syncBody)))
        Advance(now)
        return
    end

    if data == syncBody then
        State.matches = State.matches + 1
        Log(string.format("match source=%s sync={%s} async={%s}", source.name, Signature(syncBody), Signature(data)))
    else
        State.mismatches = State.mismatches + 1
        Log(string.format("mismatch source=%s sync={%s} async={%s}", source.name, Signature(syncBody), Signature(data)))
    end

    Advance(now)
end

local function DispatchCurrent(now)
    local source = CONFIG.SOURCES[State.sourceIndex]
    assert(source, "http_async_parity_test: source missing")

    State.currentSource = source
    Log(string.format("start repeat=%d source_index=%d source=%s url=%s", State.repeatIndex, State.sourceIndex,
        source.name, source.url))

    local syncOk, syncResult = pcall(http.Get, source.url)
    if not syncOk or type(syncResult) ~= "string" or syncResult == "" then
        State.syncErrors = State.syncErrors + 1
        State.total = State.total + 1
        State.mismatches = State.mismatches + 1
        Log(string.format("mismatch source=%s reason=sync_failed detail=%s", source.name, tostring(syncResult)))
        Advance(now)
        return
    end

    State.currentSyncBody = syncResult
    State.inFlight = true
    State.waitingForAsync = true
    State.asyncStartedAt = now

    local asyncOk, asyncErr = pcall(http.GetAsync, source.url, OnAsyncResponse)
    if not asyncOk then
        State.inFlight = false
        State.waitingForAsync = false
        State.asyncDispatchErrors = State.asyncDispatchErrors + 1
        State.total = State.total + 1
        State.mismatches = State.mismatches + 1
        Log(string.format("mismatch source=%s reason=async_dispatch_failed detail=%s", source.name, tostring(asyncErr)))
        Advance(now)
        return
    end

    Log(string.format("dispatched source=%s baseline={%s}", source.name, Signature(syncResult)))
end

local function TickTimeout(now)
    if not State.waitingForAsync then
        return
    end

    if (now - State.asyncStartedAt) < CONFIG.REQUEST_TIMEOUT then
        return
    end

    local source = State.currentSource
    State.waitingForAsync = false
    State.inFlight = false
    State.timeoutAsync = State.timeoutAsync + 1
    State.total = State.total + 1
    State.mismatches = State.mismatches + 1
    Log(string.format("mismatch source=%s reason=async_timeout baseline={%s}", source and source.name or "unknown",
        Signature(State.currentSyncBody)))
    Advance(now)
end

local function OnDraw()
    if not State.isAlive or not State.isRunning then
        return
    end

    local now = globals.RealTime()
    TickTimeout(now)

    if State.inFlight then
        return
    end

    if now < State.nextActionAt then
        return
    end

    DispatchCurrent(now)
end

local function OnUnload()
    State.isAlive = false
    State.isRunning = false
    State.inFlight = false
    State.waitingForAsync = false
    Log("unload")
end

callbacks.Register("Draw", "HTTPParityTest_Draw", OnDraw)

callbacks.Register("Unload", "HTTPParityTest_Unload", OnUnload)

State.isRunning = true
State.nextActionAt = globals.RealTime() + CONFIG.START_DELAY
Log(string.format("start repeats=%d timeout=%.2f sources=%d", CONFIG.REPEATS, CONFIG.REQUEST_TIMEOUT, #CONFIG.SOURCES))
