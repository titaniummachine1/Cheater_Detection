--[[
HTTP async single-flight test.

Purpose:
- dispatch exactly one async request at a time
- test one URL repeatedly with no parallelism
- report empty/error-read/timeout outcomes
]]

local CONFIG = {
    URL = "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json",
    REPEATS = 10,
    START_DELAY = 1.0,
    INTER_REQUEST_DELAY = 1.0,
    REQUEST_TIMEOUT = 12.0,
    CHECK_SYNC_BASELINE = true,
}

local State = {
    isAlive = true,
    isRunning = true,
    nextActionAt = 0,
    inFlight = false,
    currentRound = 0,
    startedAt = 0,

    sent = 0,
    completed = 0,
    ok = 0,
    empty = 0,
    errorRead = 0,
    timeout = 0,
    dispatchError = 0,

    baselineOk = 0,
    baselineError = 0,
}

local function Log(message)
    print(string.format("[HTTP-SINGLE] %s", tostring(message)))
end

local function IsErrorReadPayload(data)
    if type(data) ~= "string" then
        return false
    end
    return data:find("ERROR_READ:", 1, true) ~= nil
end

local function Finish(reason)
    Log(string.format(
        "finish reason=%s sent=%d completed=%d ok=%d empty=%d error_read=%d timeout=%d dispatch_error=%d baseline_ok=%d baseline_error=%d",
        tostring(reason),
        State.sent,
        State.completed,
        State.ok,
        State.empty,
        State.errorRead,
        State.timeout,
        State.dispatchError,
        State.baselineOk,
        State.baselineError
    ))
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
    State.completed = State.completed + 1

    if type(data) ~= "string" or data == "" then
        State.empty = State.empty + 1
        Log(string.format("result round=%d status=empty len=0", State.currentRound))
    elseif IsErrorReadPayload(data) then
        State.errorRead = State.errorRead + 1
        Log(string.format("result round=%d status=error_read len=%d body=%s", State.currentRound, #data, data))
    else
        State.ok = State.ok + 1
        Log(string.format("result round=%d status=ok len=%d", State.currentRound, #data))
    end

    if State.sent >= CONFIG.REPEATS and not State.inFlight then
        Finish("complete")
        return
    end

    State.nextActionAt = globals.RealTime() + CONFIG.INTER_REQUEST_DELAY
end

local function RunSyncBaseline()
    if not CONFIG.CHECK_SYNC_BASELINE then
        return
    end

    local ok, responseOrErr = pcall(http.Get, CONFIG.URL)
    if not ok or type(responseOrErr) ~= "string" or responseOrErr == "" then
        State.baselineError = State.baselineError + 1
        Log(string.format("baseline status=error detail=%s", tostring(responseOrErr)))
        return
    end

    State.baselineOk = State.baselineOk + 1
    Log(string.format("baseline status=ok len=%d", #responseOrErr))
end

local function DispatchNext(now)
    if State.inFlight then
        return
    end
    if State.sent >= CONFIG.REPEATS then
        if State.completed >= State.sent then
            Finish("complete")
        end
        return
    end

    State.currentRound = State.sent + 1
    RunSyncBaseline()

    State.inFlight = true
    State.startedAt = now
    State.sent = State.sent + 1

    Log(string.format("dispatch round=%d url=%s", State.currentRound, CONFIG.URL))
    local ok, err = pcall(http.GetAsync, CONFIG.URL, OnAsyncResponse)
    if not ok then
        State.inFlight = false
        State.dispatchError = State.dispatchError + 1
        State.completed = State.completed + 1
        Log(string.format("result round=%d status=dispatch_error detail=%s", State.currentRound, tostring(err)))

        if State.sent >= CONFIG.REPEATS and not State.inFlight then
            Finish("complete")
            return
        end

        State.nextActionAt = now + CONFIG.INTER_REQUEST_DELAY
    end
end

local function TickTimeout(now)
    if not State.inFlight then
        return
    end
    if (now - State.startedAt) < CONFIG.REQUEST_TIMEOUT then
        return
    end

    State.inFlight = false
    State.timeout = State.timeout + 1
    State.completed = State.completed + 1
    Log(string.format("result round=%d status=timeout after=%.2fs", State.currentRound, now - State.startedAt))

    if State.sent >= CONFIG.REPEATS and not State.inFlight then
        Finish("complete")
        return
    end

    State.nextActionAt = now + CONFIG.INTER_REQUEST_DELAY
end

local function OnDraw()
    if not State.isAlive or not State.isRunning then
        return
    end

    local now = globals.RealTime()
    TickTimeout(now)

    if now < State.nextActionAt then
        return
    end

    DispatchNext(now)
end

local function OnUnload()
    State.isAlive = false
    State.isRunning = false
    State.inFlight = false
    Log("unload")
end

callbacks.Unregister("Draw", "HTTPSingleFlightTest_Draw")
callbacks.Register("Draw", "HTTPSingleFlightTest_Draw", OnDraw)

callbacks.Unregister("Unload", "HTTPSingleFlightTest_Unload")
callbacks.Register("Unload", "HTTPSingleFlightTest_Unload", OnUnload)

State.nextActionAt = globals.RealTime() + CONFIG.START_DELAY
Log(string.format(
    "start repeats=%d timeout=%.2f delay=%.2f url=%s",
    CONFIG.REPEATS,
    CONFIG.REQUEST_TIMEOUT,
    CONFIG.INTER_REQUEST_DELAY,
    CONFIG.URL
))
