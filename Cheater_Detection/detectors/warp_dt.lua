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

    -- Skip bots and local player
    if Common.IsBot(entity) or entity == entities.GetLocalPlayer() then return end

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

    -- Calculate deltas
    local deltaTicks = {}
    for i = 2, #simTicks do
        deltaTicks[#deltaTicks + 1] = simTicks[i] - simTicks[i - 1]
    end

    -- Look for a "Burst" event (large simulation time shift)
    local burstAmount = 0
    for _, d in ipairs(deltaTicks) do
        -- Exploits like DT/Warp usually burst 18-24+ ticks to be effective.
        -- Standard fakelag is usually 14-15.
        if d > 18 and d < 64 then 
            burstAmount = d
            break
        end
    end

    local curTick = globals.TickCount()
    
    -- STATE MACHINE: Burst -> Recharge
    if burstAmount > 0 then
        -- Record the burst event and its size
        data.lastBurstTick = curTick
        data.lastBurstAmount = burstAmount
        data.isRecharging = true
    end

    -- If we are in the "Recharging" phase, look for lack of simulation time progress
    if data.isRecharging then
        local timeSinceBurst = curTick - (data.lastBurstTick or 0)
        
        -- Warp usually recharges for the same amount of ticks it used
        -- We give it a window of time to show "0" progress
        local lastDelta = deltaTicks[#deltaTicks] or 1
        if lastDelta == 0 then
            data.rechargeTicks = (data.rechargeTicks or 0) + 1
        end

        -- If they have recharged enough OR too much time passed
        if timeSinceBurst > 66 then -- 1 second timeout
            data.isRecharging = false
            data.rechargeTicks = 0
        elseif data.rechargeTicks and data.rechargeTicks >= 4 then
            -- We detected a Burst AND a period of 0-simulation-progress (recharge)
            -- This is a high-confidence Warp/DT signature.
            
            -- Record this specific signature event
            local lastEvent = data.events[#data.events]
            if not lastEvent or (curTick - lastEvent) > 20 then
                table.insert(data.events, curTick)
            end
            
            -- Reset state so we don't spam 1 signature per tick
            data.isRecharging = false
            data.rechargeTicks = 0
        end
    end

    -- Clean up events older than 660 ticks (approx 10 seconds for Warp)
    while #data.events > 0 and (curTick - data.events[1]) > 660 do
        table.remove(data.events, 1)
    end

    -- Warp is more "one-time" but we still want some consistency or high score
    -- 2 sequences is enough for definitive suspicion, 1 is enough for minor scoring
    if #data.events >= 1 then
        local reason = "Warp/DT (Burst + Recharge)"
        
        -- Scale increment based on events
        local increment = (#data.events >= 2) and 40 or 20
        playerState.score = math.min(99, playerState.score + increment)

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
        
        -- If we hit high risk, clear one event so we don't spam
        if #data.events >= 2 then
            table.remove(data.events, 1)
        end
    end
end

-- Cleanup on disconnect
EventBus.Subscribe("OnPlayerDisconnect", function(id)
    playerStats[id] = nil
end)

return WarpDT
