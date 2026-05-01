--[[
HTTP async stress prototype for Lmaobox.

Purpose:
- isolate http.GetAsync crash limits from the main cheat logic
- measure crash threshold, empty responses, and truncated responses
- preserve request identity so out-of-order callbacks are logged correctly
]]

assert(http, "http_test: http library missing")
assert(callbacks, "http_test: callbacks missing")
assert(globals, "http_test: globals missing")

local CONFIG = {
    MODE = "staircase",       -- sequential | burst | staircase | plateau
    URL_MODE = "fixed",       -- round_robin | fixed
    FIXED_URL_INDEX = 1,
    WAIT_FOR_SAFE_WINDOW = false,
    AUTO_START_DELAY = 2.0,
    ROUND_DELAY = 5.0,
    REQUEST_TIMEOUT = 12.0,
    FULL_RESPONSE_RATIO = 0.90,
    STOP_ON_FIRST_BAD = true,
    SEQUENTIAL_COUNT = 12,
    SEQUENTIAL_DELAY = 0.0,
    BURST_COUNT = 6,
    PLATEAU_BURST = 6,
    PLATEAU_ROUNDS = 12,
    STAIRCASE_STEPS = { 1, 2, 3 },
    MAX_CALLBACK_SLOTS = 32,
    SOURCES = {
        {
            name = "d3fc0n6",
            url = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
            expectedBytes = 24966,
        },
        {
            name = "TF2BD Official",
            url =
            "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json",
            expectedBytes = 176230,
        },
        {
            name = "MegaScaterbomb",
            url =
            "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/refs/heads/main/playerlist.megacheaterdb.json",
            expectedBytes = 1224603,
        },
        {
            name = "qfoxb",
            url = "https://raw.githubusercontent.com/qfoxb/tf2bd-lists/main/playerlist.qfoxb.json",
            expectedBytes = 64247,
        },
        {
            name = "joekiller",
            url = "https://raw.githubusercontent.com/joekiller/joekiller-list/main/playerlist.joekiller.json",
            expectedBytes = 94518,
        },
    },
}

local State = {
    isAlive = true,
    isRunning = false,
    startedAt = 0,
    nextActionAt = 0,
    mode = CONFIG.MODE,
    roundIndex = 1,
    roundDispatched = false,
    requestsSent = 0,
    requestsCompleted = 0,
    requestsOk = 0,
    requestsShort = 0,
    requestsEmpty = 0,
    requestsTimeout = 0,
    requestsDispatchError = 0,
    requestsDropped = 0,
    requestsFailed = 0,
    inFlight = 0,
    peakInFlight = 0,
    roundPeakInFlight = 0,
    lastDispatchLabel = "none",
    lastCompleteLabel = "none",
    pendingBySlot = {},
    roundStats = {
        ok = 0,
        short = 0,
        empty = 0,
        timeout = 0,
        dispatch_error = 0,
    },
}

local HandleAsyncResponse
local SlotCallbacks = {}

local function Log(message)
    print(string.format("[HTTP-TEST] %s", tostring(message)))
end

local function IsSafeWindow()
    local ok, localPlayer = pcall(entities.GetLocalPlayer)
    if not ok or not localPlayer then
        return true
    end

    local aliveOk, alive = pcall(localPlayer.IsAlive, localPlayer)
    if not aliveOk then
        return false
    end

    return not alive
end

local function GetMaxConfiguredBurst()
    local maxBurst = CONFIG.BURST_COUNT
    if CONFIG.PLATEAU_BURST > maxBurst then
        maxBurst = CONFIG.PLATEAU_BURST
    end
    for _, count in ipairs(CONFIG.STAIRCASE_STEPS) do
        if count > maxBurst then
            maxBurst = count
        end
    end
    return maxBurst
end

assert(CONFIG.MAX_CALLBACK_SLOTS >= GetMaxConfiguredBurst(), "http_test: MAX_CALLBACK_SLOTS too small")

local function ClearPending()
    for slot = 1, CONFIG.MAX_CALLBACK_SLOTS do
        State.pendingBySlot[slot] = nil
    end
end

local function ResetRoundStats()
    State.roundStats.ok = 0
    State.roundStats.short = 0
    State.roundStats.empty = 0
    State.roundStats.timeout = 0
    State.roundStats.dispatch_error = 0
    State.roundPeakInFlight = 0
end

local function ResetState()
    State.isRunning = false
    State.startedAt = 0
    State.nextActionAt = 0
    State.mode = CONFIG.MODE
    State.roundIndex = 1
    State.roundDispatched = false
    State.requestsSent = 0
    State.requestsCompleted = 0
    State.requestsOk = 0
    State.requestsShort = 0
    State.requestsEmpty = 0
    State.requestsTimeout = 0
    State.requestsDispatchError = 0
    State.requestsDropped = 0
    State.requestsFailed = 0
    State.inFlight = 0
    State.peakInFlight = 0
    State.lastDispatchLabel = "none"
    State.lastCompleteLabel = "none"
    ClearPending()
    ResetRoundStats()
end

local function GetSourceForRequest(requestIndex)
    local sources = CONFIG.SOURCES
    assert(type(sources) == "table" and #sources > 0, "http_test: CONFIG.SOURCES missing")

    if CONFIG.URL_MODE == "fixed" then
        local fixedSource = sources[CONFIG.FIXED_URL_INDEX]
        assert(fixedSource, "http_test: FIXED_URL_INDEX invalid")
        return fixedSource
    end

    local offset = ((requestIndex - 1) % #sources) + 1
    return sources[offset]
end

local function FindFreeSlot()
    for slot = 1, CONFIG.MAX_CALLBACK_SLOTS do
        if not State.pendingBySlot[slot] then
            return slot
        end
    end
    return nil
end

local function GetCurrentRoundBurst()
    if State.mode == "burst" then
        return CONFIG.BURST_COUNT
    end
    if State.mode == "plateau" then
        return CONFIG.PLATEAU_BURST
    end
    if State.mode == "staircase" then
        return CONFIG.STAIRCASE_STEPS[State.roundIndex] or 0
    end
    return 1
end

local function FormatRatio(actualBytes, expectedBytes)
    if expectedBytes <= 0 then
        return tostring(actualBytes)
    end
    local ratio = (actualBytes / expectedBytes) * 100.0
    return string.format("%d/%d %.1f%%%%", actualBytes, expectedBytes, ratio)
end

local function LogRoundSummary(reason)
    Log(string.format(
        "round %d summary burst=%d ok=%d short=%d empty=%d timeout=%d dispatch=%d round_peak=%d reason=%s",
        State.roundIndex,
        GetCurrentRoundBurst(),
        State.roundStats.ok,
        State.roundStats.short,
        State.roundStats.empty,
        State.roundStats.timeout,
        State.roundStats.dispatch_error,
        State.roundPeakInFlight,
        tostring(reason)
    ))
    ResetRoundStats()
end

local function FinishExperiment(reason)
    Log(string.format(
        "finish reason=%s sent=%d callbacks=%d ok=%d short=%d empty=%d timeout=%d dispatch=%d dropped=%d fail=%d peak=%d last_dispatch=%s last_complete=%s",
        tostring(reason),
        State.requestsSent,
        State.requestsCompleted,
        State.requestsOk,
        State.requestsShort,
        State.requestsEmpty,
        State.requestsTimeout,
        State.requestsDispatchError,
        State.requestsDropped,
        State.requestsFailed,
        State.peakInFlight,
        State.lastDispatchLabel,
        State.lastCompleteLabel
    ))
    ResetState()
end

local function AbortExperimentOnFailure(request, status)
    if status == "ok" then
        return false
    end
    if not CONFIG.STOP_ON_FIRST_BAD then
        return false
    end

    if State.inFlight > 0 then
        State.requestsDropped = State.requestsDropped + State.inFlight
        Log(string.format(
            "abort after first bad response: remaining_inflight=%d callbacks will be discarded",
            State.inFlight
        ))
    else
        Log("abort after first bad response: no remaining inflight callbacks")
    end

    LogRoundSummary("first bad response")
    FinishExperiment(string.format(
        "first bad response status=%s label=%s source=%s round=%d",
        status,
        request.label,
        request.source.name,
        State.roundIndex
    ))
    return true
end

local function AdvanceRound(now, reason)
    LogRoundSummary(reason)

    if State.mode == "burst" then
        FinishExperiment(reason)
        return
    end

    if State.mode == "staircase" then
        State.roundIndex = State.roundIndex + 1
        State.roundDispatched = false
        State.nextActionAt = now + CONFIG.ROUND_DELAY
        if State.roundIndex > #CONFIG.STAIRCASE_STEPS then
            FinishExperiment("staircase complete")
        end
        return
    end

    if State.mode == "plateau" then
        State.roundIndex = State.roundIndex + 1
        State.roundDispatched = false
        State.nextActionAt = now + CONFIG.ROUND_DELAY
        if State.roundIndex > CONFIG.PLATEAU_ROUNDS then
            FinishExperiment("plateau complete")
        end
    end
end

local function RecordCompletion(request, status, value, now)
    State.inFlight = State.inFlight - 1
    if State.inFlight < 0 then
        State.inFlight = 0
    end

    State.lastCompleteLabel = request.label .. ":" .. status
    State.roundStats[status] = (State.roundStats[status] or 0) + 1
    Log(string.format(
        "%s label=%s slot=%d source=%s value=%s inflight=%d",
        status,
        request.label,
        request.slot,
        request.source.name,
        tostring(value),
        State.inFlight
    ))

    if AbortExperimentOnFailure(request, status) then
        return
    end

    if State.mode == "sequential" then
        if State.requestsSent >= CONFIG.SEQUENTIAL_COUNT and State.inFlight == 0 then
            LogRoundSummary("sequential complete")
            FinishExperiment("sequential complete")
        end
        return
    end

    if State.roundDispatched and State.inFlight == 0 then
        AdvanceRound(now, State.mode .. " complete")
    end
end

HandleAsyncResponse = function(slot, data)
    if not State.isAlive then
        return
    end

    if not State.isRunning then
        Log("callback ignored after experiment finished slot=" .. tostring(slot))
        return
    end

    local request = State.pendingBySlot[slot]
    if not request then
        Log("late callback ignored slot=" .. tostring(slot))
        return
    end

    State.pendingBySlot[slot] = nil
    local now = globals.RealTime()
    local source = request.source
    local expectedBytes = source.expectedBytes or 0

    if type(data) ~= "string" or #data == 0 then
        State.requestsCompleted = State.requestsCompleted + 1
        State.requestsEmpty = State.requestsEmpty + 1
        State.requestsFailed = State.requestsFailed + 1
        RecordCompletion(request, "empty", 0, now)
        return
    end

    State.requestsCompleted = State.requestsCompleted + 1
    if expectedBytes > 0 and #data < math.floor(expectedBytes * CONFIG.FULL_RESPONSE_RATIO) then
        State.requestsShort = State.requestsShort + 1
        State.requestsFailed = State.requestsFailed + 1
        RecordCompletion(request, "short", FormatRatio(#data, expectedBytes), now)
        return
    end

    State.requestsOk = State.requestsOk + 1
    RecordCompletion(request, "ok", FormatRatio(#data, expectedBytes), now)
end

for slot = 1, CONFIG.MAX_CALLBACK_SLOTS do
    local slotIndex = slot
    SlotCallbacks[slotIndex] = function(data)
        HandleAsyncResponse(slotIndex, data)
    end
end

local function DispatchAsyncRequest(requestIndex)
    local slot = FindFreeSlot()
    assert(slot, "http_test: no free callback slot available")

    local source = GetSourceForRequest(requestIndex)
    local label = string.format("%s-r%d-q%d", State.mode, State.roundIndex, State.requestsSent + 1)
    local request = {
        label = label,
        slot = slot,
        source = source,
        startedAt = globals.RealTime(),
    }
    State.pendingBySlot[slot] = request
    State.requestsSent = State.requestsSent + 1
    State.inFlight = State.inFlight + 1
    if State.inFlight > State.peakInFlight then
        State.peakInFlight = State.inFlight
    end
    if State.inFlight > State.roundPeakInFlight then
        State.roundPeakInFlight = State.inFlight
    end
    State.lastDispatchLabel = label
    Log(string.format(
        "dispatch label=%s slot=%d inflight=%d source=%s url=%s",
        label,
        slot,
        State.inFlight,
        source.name,
        source.url
    ))

    local ok, err = pcall(http.GetAsync, source.url, SlotCallbacks[slot])
    if not ok then
        State.pendingBySlot[slot] = nil
        State.requestsDispatchError = State.requestsDispatchError + 1
        State.requestsFailed = State.requestsFailed + 1
        RecordCompletion(request, "dispatch_error", tostring(err), globals.RealTime())
    end
end

local function PollTimeouts()
    local now = globals.RealTime()
    for slot = 1, CONFIG.MAX_CALLBACK_SLOTS do
        local request = State.pendingBySlot[slot]
        if request then
            local age = now - request.startedAt
            if age >= CONFIG.REQUEST_TIMEOUT then
                State.pendingBySlot[slot] = nil
                State.requestsTimeout = State.requestsTimeout + 1
                State.requestsFailed = State.requestsFailed + 1
                RecordCompletion(request, "timeout", string.format("%.2fs", age), now)
            end
        end
    end
end

local function StartExperiment()
    ResetState()
    State.isRunning = true
    State.startedAt = globals.RealTime()
    State.nextActionAt = State.startedAt + CONFIG.AUTO_START_DELAY
    Log("============================================================")
    Log(string.format(
        "start mode=%s url_mode=%s fixed_url=%d safe_window=%s start_delay=%.2f timeout=%.2f full_ratio=%.2f stop_on_first_bad=%s",
        CONFIG.MODE,
        CONFIG.URL_MODE,
        CONFIG.FIXED_URL_INDEX,
        tostring(CONFIG.WAIT_FOR_SAFE_WINDOW),
        CONFIG.AUTO_START_DELAY,
        CONFIG.REQUEST_TIMEOUT,
        CONFIG.FULL_RESPONSE_RATIO,
        tostring(CONFIG.STOP_ON_FIRST_BAD)
    ))
    if CONFIG.MODE == "sequential" then
        Log(string.format("sequential count=%d delay=%.2f", CONFIG.SEQUENTIAL_COUNT, CONFIG.SEQUENTIAL_DELAY))
    elseif CONFIG.MODE == "burst" then
        Log(string.format("burst count=%d", CONFIG.BURST_COUNT))
    elseif CONFIG.MODE == "plateau" then
        Log(string.format("plateau burst=%d rounds=%d", CONFIG.PLATEAU_BURST, CONFIG.PLATEAU_ROUNDS))
    else
        Log("staircase steps=" .. table.concat(CONFIG.STAIRCASE_STEPS, ","))
    end
    Log("============================================================")
end

local function TickSequential(now)
    if State.requestsSent >= CONFIG.SEQUENTIAL_COUNT then
        if State.inFlight == 0 then
            LogRoundSummary("sequential complete")
            FinishExperiment("sequential complete")
        end
        return
    end

    if State.inFlight > 0 or now < State.nextActionAt then
        return
    end

    DispatchAsyncRequest(State.requestsSent + 1)
    State.nextActionAt = now + CONFIG.SEQUENTIAL_DELAY
end

local function TickBurstLike(now)
    if State.roundDispatched or now < State.nextActionAt then
        return
    end

    local burst = GetCurrentRoundBurst()
    Log(string.format("starting round=%d burst=%d", State.roundIndex, burst))
    for requestIndex = 1, burst do
        DispatchAsyncRequest(requestIndex)
    end
    State.roundDispatched = true
end

local function OnDraw()
    if not State.isAlive then
        return
    end

    PollTimeouts()
    if not State.isRunning then
        return
    end

    if CONFIG.WAIT_FOR_SAFE_WINDOW and not IsSafeWindow() then
        return
    end

    local now = globals.RealTime()
    if State.mode == "sequential" then
        TickSequential(now)
    else
        TickBurstLike(now)
    end
end

local function OnUnload()
    State.isAlive = false
    ResetState()
    Log("unload")
end

callbacks.Unregister("Draw", "HTTPStressTest_Draw")
callbacks.Register("Draw", "HTTPStressTest_Draw", OnDraw)

callbacks.Unregister("Unload", "HTTPStressTest_Unload")
callbacks.Register("Unload", "HTTPStressTest_Unload", OnUnload)

StartExperiment()
