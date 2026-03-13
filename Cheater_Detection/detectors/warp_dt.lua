local Constants = require("Cheater_Detection.core.constants")
local Database = require("Cheater_Detection.Database.Database")
local EventBus = require("Cheater_Detection.core.event_bus")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

local WarpDT = {}

local DETECTION_NAME = "warp_dt"
local HISTORY_SIZE = 33

-- Ensure history is tracking simulation time
local registeredConsumer = false
local function ensureConsumer()
    if registeredConsumer then return end
    HistoryManager.RegisterConsumer(DETECTION_NAME, {
        retentionTicks = HISTORY_SIZE,
        fields = { HistoryManager.Fields.SimulationTime }
    })
    registeredConsumer = true
end

-- Per-player pattern tracking
local playerStats = {} -- id -> { events = {tick1, tick2...} }

local function timeToTicks(time)
    return math.floor(0.5 + time / globals.TickInterval())
end

local Common = require("Cheater_Detection.Utils.Common")

function WarpDT.ProcessPlayer(playerState)
    assert(playerState, "WarpDT.ProcessPlayer: playerState missing")
    if not playerState.wrap then return end
    
    -- Check local stability to avoid false positives
    if not Common.CheckConnectionState() or Common.IsFrameGap() then return end

    ensureConsumer()

    local entity = playerState.wrap:GetRawEntity()
    if not entity or not entity:IsValid() or not entity:IsAlive() then return end

    -- Skip bots
    if Common.IsBot(entity) then return end

    local id = playerState.id
    if not playerStats[id] then
        playerStats[id] = { events = {} }
    end
    local data = playerStats[id]

    -- Already marked?
    if (playerState.flags & Constants.Flags.CHEATER) ~= 0 then return end

    -- HistoryManager uses PlayerState (legacy) storage
    local PlayerStateLegacy = require("Cheater_Detection.Utils.PlayerState")
    local legacyState = PlayerStateLegacy.Get(id)
    if not legacyState or not legacyState.History then return end

    local history = legacyState.History
    local historyCount = HistoryManager.GetCount(history)
    if historyCount < HISTORY_SIZE then return end

    -- Extract deltas from current history buffer (approx 0.5s of data)
    local simTicks = {}
    for i = 1, historyCount do
        local record = HistoryManager.GetAt(history, i)
        if record and record[HistoryManager.Fields.SimulationTime] then
            simTicks[#simTicks + 1] = timeToTicks(record[HistoryManager.Fields.SimulationTime])
        end
    end

    if #simTicks < HISTORY_SIZE then return end

    local deltaTicks = {}
    for i = 2, #simTicks do
        deltaTicks[#deltaTicks + 1] = simTicks[i] - simTicks[i - 1]
    end

    -- Check for a warp signature in THIS buffer
    local hasWarpSignature = false
    for _, d in ipairs(deltaTicks) do
        -- Skip huge deltas (respawn, teleport)
        -- Normal jitter is 2-4. Exploits are 8+.
        if d > 7 and d < 64 then
            hasWarpSignature = true
            break
        end
    end
    
    if not hasWarpSignature then
        -- Also check variance for "mathematical" warp
        local sum = 0
        for _, d in ipairs(deltaTicks) do sum = sum + d end
        local mean = sum / #deltaTicks
        local sumSq = 0
        for _, d in ipairs(deltaTicks) do
            local diff = d - mean
            sumSq = sumSq + diff * diff
        end
        local stdDev = math.sqrt(sumSq / (#deltaTicks - 1))
        -- Standard deviation of 2.0+ is very high for normal gameplay
        if stdDev > 2.0 then hasWarpSignature = true end
    end

    local curTick = globals.TickCount()
    if hasWarpSignature then
        -- Only record an event at most once every 33 ticks (0.5s)
        local lastEvent = data.events[#data.events]
        if not lastEvent or (curTick - lastEvent) > 33 then
            table.insert(data.events, curTick)
        end
    end

    -- Clean up events older than 330 ticks (approx 5 seconds)
    while #data.events > 0 and (curTick - data.events[1]) > 330 do
        table.remove(data.events, 1)
    end

    -- Trigger ONLY if they warp consistently (4+ clusters in 5 seconds)
    if #data.events >= 4 then
        local reason = "Warp/DT (Consistent rhythm)"
        
        -- Progressive suspicion
        playerState.score = math.min(99, playerState.score + 12)

        if playerState.score >= Constants.Threshold.SUSPICIOUS then
            playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
        end

        if playerState.score >= Constants.Threshold.HIGH_RISK then
            playerState.flags = playerState.flags | Constants.Flags.HIGH_RISK
        end

        Database.UpsertCheater(id, {
            name = playerState.wrap:GetName(),
            reason = reason,
            flags = playerState.flags,
            score = playerState.score
        })

        EventBus.Publish("OnPlayerStateChange", playerState, reason)
        
        -- Clear some events to prevent instant re-triggering on every tick
        table.remove(data.events, 1) 
    end
end

-- Cleanup on disconnect
EventBus.Subscribe("OnPlayerDisconnect", function(id)
    playerStats[id] = nil
end)

return WarpDT
