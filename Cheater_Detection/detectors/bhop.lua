--[[ detectors/bhop.lua
     Detects scripted bunnyhops by counting consecutive "perfect" jumps.
     A perfect jump is landing and leaving the ground within 1-2 ticks.
]]

local Constants = require("Cheater_Detection.core.constants")
local Database = require("Cheater_Detection.Database.Database")
local EventBus = require("Cheater_Detection.core.event_bus")

local Bhop = {}

-- Per-player state
local playerData = {}

function Bhop.ProcessPlayer(playerState)
    assert(playerState, "Bhop.ProcessPlayer: playerState missing")
    if not playerState.wrap then return end
    
    local entity = playerState.wrap:GetRawEntity()
    if not entity or not entity:IsValid() or not entity:IsAlive() then return end

    local id = playerState.id
    if not playerData[id] then
        playerData[id] = {
            wasOnGround = false,
            groundTicks = 0,
            consecutivePerfects = 0,
        }
    end
    local data = playerData[id]

    local flags = entity:GetPropInt("m_fFlags")
    local onGround = (flags & 1) ~= 0 -- FL_ONGROUND

    if onGround then
        data.groundTicks = data.groundTicks + 1
        data.wasOnGround = true
    else
        -- Transitioned from ground to air (The moment of the jump)
        if data.wasOnGround then
            -- Check if it was a "perfect" jump window
            -- Note: Constants.BHOP_MAX_GROUND_TICKS is usually 1
            if data.groundTicks > 0 and data.groundTicks <= Constants.BHOP_MAX_GROUND_TICKS then
                data.consecutivePerfects = data.consecutivePerfects + 1
                
                -- Threshold for adding suspicion
                if data.consecutivePerfects >= Constants.BHOP_MIN_CONSECUTIVE_SUCCESS then
                    local increment = 10
                    -- Scale increment for extreme consistency
                    if data.consecutivePerfects > 10 then increment = 25 end
                    
                    playerState.score = math.min(100, playerState.score + increment)
                    
                    local isBlatant = data.consecutivePerfects >= 12
                    if playerState.score >= 100 or isBlatant then
                        playerState.flags = playerState.flags | Constants.Flags.CHEATER
                        playerState.score = 100
                    elseif playerState.score >= Constants.Threshold.SUSPICIOUS then
                        playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
                    end

                    local reason = string.format("Bhop Script (%d perfect jumps)", data.consecutivePerfects)
                    
                    -- Persist
                    Database.UpsertCheater(id, {
                        name = playerState.wrap:GetName(),
                        reason = reason,
                        flags = playerState.flags,
                        score = playerState.score
                    })
                    
                    EventBus.Publish("OnPlayerStateChange", playerState, reason)
                end
            else
                -- Reset if they stayed on ground too long (not a bhop chain)
                data.consecutivePerfects = 0
            end
            
            data.wasOnGround = false
            data.groundTicks = 0
        end
    end
end

-- Cleanup
EventBus.Subscribe("OnPlayerDisconnect", function(id)
    playerData[id] = nil
end)

return Bhop
