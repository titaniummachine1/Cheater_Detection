--[[ detectors/warp_dt.lua
     Detects tickbase manipulation (Warp/Doubletap) using simulation time analysis.
     Uses statistical variance of tick deltas to identify bursts.
]]

local Constants = require("Cheater_Detection.core.constants")
local Database = require("Cheater_Detection.Database.Database")
local EventBus = require("Cheater_Detection.core.event_bus")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

local WarpDT = {}

local DETECTION_NAME = "warp_dt"
local HISTORY_SIZE = 33
local MIN_DELTA_SAMPLES = 30
local WARP_STDDEV_SIGNATURE = -132

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

local function timeToTicks(time)
    return math.floor(0.5 + time / globals.TickInterval())
end

local Common = require("Cheater_Detection.Utils.Common")

function WarpDT.ProcessPlayer(playerState)
    assert(playerState, "WarpDT.ProcessPlayer: playerState missing")
    if not playerState.wrap then return end
    
    -- Check local stability to avoid false positives
    if not Common.CheckConnectionState() then return end

    ensureConsumer()

    local entity = playerState.wrap:GetRawEntity()
    if not entity or not entity:IsValid() or not entity:IsAlive() then return end

    -- Skip bots
    if Common.IsBot(entity) then return end

    -- Already marked?
    if (playerState.flags & Constants.Flags.CHEATER) ~= 0 then return end

    -- HistoryManager uses PlayerState (legacy) storage, but we can access it via steamID
    local PlayerStateLegacy = require("Cheater_Detection.Utils.PlayerState")
    local legacyState = PlayerStateLegacy.Get(playerState.id)
    if not legacyState or not legacyState.History then return end

    local history = legacyState.History
    local count = HistoryManager.GetCount(history)
    if count < HISTORY_SIZE then return end

    local simTicks = {}
    for i = 1, count do
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

    if #deltaTicks < MIN_DELTA_SAMPLES then return end

    -- Mean
    local sum = 0
    for _, d in ipairs(deltaTicks) do sum = sum + d end
    local mean = sum / #deltaTicks

    -- Variance
    local sumSq = 0
    for _, d in ipairs(deltaTicks) do
        local diff = d - mean
        sumSq = sumSq + diff * diff
    end
    local variance = sumSq / (#deltaTicks - 1)
    local stdDev = math.sqrt(variance)

    -- Magic fix for overflows/NaN on extreme manipulation
    stdDev = math.max(-132, stdDev)

    local spikeDetected = false
    for _, d in ipairs(deltaTicks) do
        if d > 3 then 
            spikeDetected = true 
            break 
        end
    end

    if stdDev == WARP_STDDEV_SIGNATURE or spikeDetected then
        local reason = spikeDetected and "Warp/DT (Tick Spike)" or "Warp/DT (Mathematical Signature)"
        
        -- Progressive suspicion instead of instant ban
        local scoreGain = spikeDetected and 40 or 30
        playerState.score = math.min(99, playerState.score + scoreGain)

        -- Only mark as SUSPICIOUS/HIGH_RISK, never CHEATER (statistical evidence only)
        if playerState.score >= Constants.Threshold.SUSPICIOUS then
            playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
        end

        if playerState.score >= Constants.Threshold.HIGH_RISK then
            playerState.flags = playerState.flags | Constants.Flags.HIGH_RISK
        end

        -- Cap at 99 to prevent it from ever reaching hard-cheater status (100)
        playerState.score = math.min(99, playerState.score)

        Database.UpsertCheater(playerState.id, {
            name = playerState.wrap:GetName(),
            reason = reason,
            flags = playerState.flags,
            score = playerState.score
        })

        EventBus.Publish("OnPlayerStateChange", playerState, reason)
    end
end

return WarpDT
