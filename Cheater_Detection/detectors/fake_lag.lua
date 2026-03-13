--[[ detectors/fake_lag.lua
     Detects excessive packet choking (Fake Lag) by monitoring simulation time deltas.
]]

local Constants = require("Cheater_Detection.core.constants")
local Database = require("Cheater_Detection.Database.Database")
local EventBus = require("Cheater_Detection.core.event_bus")

local FakeLag = {}

-- Constant threshold for fake lag (usually 14-15 on TF2)
local MAX_TICK_DELTA = 14

-- Per-player tracking
-- Per-player tracking
local playerStats = {} -- id -> { lastSimTime, events = {tick1, tick2...} }

local function timeToTicks(time)
    return math.floor(time / globals.TickInterval() + 0.5)
end

local Common = require("Cheater_Detection.Utils.Common")

function FakeLag.ProcessPlayer(playerState)
    assert(playerState, "FakeLag.ProcessPlayer: playerState missing")
    if not playerState.wrap then return end

    -- Check local stability to avoid false positives
    if not Common.CheckConnectionState() then return end

    local entity = playerState.wrap:GetRawEntity()
    if not entity or not entity:IsValid() or not entity:IsAlive() then return end

    -- Skip bots
    if Common.IsBot(entity) then return end

    local id = playerState.id
    if not playerStats[id] then
        playerStats[id] = { lastSimTime = 0, events = {} }
    end
    local data = playerStats[id]

    local currentSimTime = playerState.wrap:GetSimulationTime()
    if not currentSimTime then return end

    if data.lastSimTime == 0 then
        data.lastSimTime = currentSimTime
        return
    end

    local delta = currentSimTime - data.lastSimTime
    
    -- Reject invalid deltas (respawn, lag comp, demo)
    if delta <= 0 or delta > 2 then
        data.lastSimTime = currentSimTime
        return
    end

    local deltaTicks = timeToTicks(delta)
    local curTick = globals.TickCount()

    -- Only record events that meet the threshold
    if deltaTicks >= MAX_TICK_DELTA then
        table.insert(data.events, curTick)
        
        -- Clean up events older than 132 ticks (approx 2 seconds)
        while #data.events > 0 and (curTick - data.events[1]) > 132 do
            table.remove(data.events, 1)
        end

        -- Trigger suspicion ONLY if they choke in a repeating fashion (2+ times in 2 seconds)
        if #data.events >= 2 then
            playerState.score = math.min(99, playerState.score + 15)
            
            local reason = string.format("Fake Lag (Choke pattern detected)")
            
            if playerState.score >= Constants.Threshold.HIGH_RISK then
                playerState.flags = playerState.flags | Constants.Flags.HIGH_RISK
                playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
            elseif playerState.score >= Constants.Threshold.SUSPICIOUS then
                playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
            end

            Database.UpsertCheater(id, {
                name = playerState.wrap:GetName(),
                reason = reason,
                flags = playerState.flags,
                score = playerState.score
            })

            EventBus.Publish("OnPlayerStateChange", playerState, reason)
        end
    end

    data.lastSimTime = currentSimTime
end

-- Cleanup
EventBus.Subscribe("OnPlayerDisconnect", function(id)
    playerStats[id] = nil
end)

return FakeLag
