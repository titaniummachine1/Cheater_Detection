--[[ Core/DirtySystem.lua
     Dirty flag optimization system for player data updates.

     Instead of constantly iterating through all players for checks/updates,
     this system tracks which players have changed data and only processes
     those specific players.

     Dirty Flags:
       DIRTY_SCORE    - Player score changed (visuals need update)
       DIRTY_FLAGS    - Player flags changed (visuals + DB need update)
       DIRTY_CHECKS   - Check flags changed (valve_check needs processing)
       DIRTY_SESSION  - Session state changed (persistence needed)

     Usage:
       DirtySystem.MarkDirty(playerID, DirtySystem.FLAGS.SCORE)
       DirtySystem.ProcessDirty(DirtySystem.FLAGS.SCORE, callback)
]]

local Constants = require("Cheater_Detection.Core.constants")

local DirtySystem = {}

-- Import flags from centralized constants for consistency
DirtySystem.FLAGS = Constants.DirtyFlags

-- Queue of dirty player IDs by flag type (all flag types from Constants)
local dirtyQueues = {
    [DirtySystem.FLAGS.SCORE]        = {},
    [DirtySystem.FLAGS.FLAGS]        = {},
    [DirtySystem.FLAGS.CHECKS]       = {},
    [DirtySystem.FLAGS.SESSION]      = {},
    [DirtySystem.FLAGS.PRIORITY]     = {},
    [DirtySystem.FLAGS.CONNECTED]    = {},
    [DirtySystem.FLAGS.DISCONNECTED] = {},
}

-- Track which flags each player has dirty
local playerDirtyFlags = {}

-- Statistics for debugging
local stats = {
    marksTotal = 0,
    processesTotal = 0,
    lastResetTime = 0,
}

--- Mark a player as dirty with specific flags
---@param playerID string Player's SteamID64
---@param flags number Bitmask of DirtySystem.FLAGS
function DirtySystem.MarkDirty(playerID, flags)
    if not playerID or not flags or flags == 0 then
        return
    end

    local existing = playerDirtyFlags[playerID] or 0
    local newFlags = existing | flags

    -- Only add to queues for flags that weren't already dirty
    if newFlags ~= existing then
        local addedFlags = newFlags & ~existing

        -- Add player to relevant queues (iterate through all defined flags)
        local flagBit = 1
        while flagBit <= DirtySystem.FLAGS.ALL do
            if (addedFlags & flagBit) ~= 0 then
                dirtyQueues[flagBit][playerID] = true
            end
            flagBit = flagBit * 2
        end

        playerDirtyFlags[playerID] = newFlags
        stats.marksTotal = stats.marksTotal + 1
    end
end

--- Process dirty players for specific flag types
---@param flags number Bitmask of DirtySystem.FLAGS to process
---@param callback function Called for each dirty player: callback(playerID, flagMask)
function DirtySystem.ProcessDirty(flags, callback)
    if not flags or flags == 0 or not callback then
        return
    end

    local processedCount = 0

    -- Process each flag type
    local flagBit = 1
    while flagBit <= DirtySystem.FLAGS.ALL do
        if (flags & flagBit) ~= 0 then
            local queue = dirtyQueues[flagBit]

            -- Process all players in this queue
            for playerID, _ in pairs(queue) do
                callback(playerID, flagBit)
                processedCount = processedCount + 1

                -- Clear this flag from player's dirty flags
                local playerFlags = playerDirtyFlags[playerID] or 0
                playerFlags = playerFlags & ~flagBit
                playerDirtyFlags[playerID] = playerFlags

                -- If player has no more dirty flags, clean up completely
                if playerFlags == 0 then
                    playerDirtyFlags[playerID] = nil
                end
            end

            -- Clear the queue
            dirtyQueues[flagBit] = {}
        end
        flagBit = flagBit * 2
    end

    stats.processesTotal = stats.processesTotal + processedCount
    return processedCount
end

--- Check if a player has specific dirty flags
---@param playerID string Player's SteamID64
---@param flags number Bitmask of DirtySystem.FLAGS to check
---@return boolean True if player has any of the specified flags dirty
function DirtySystem.IsDirty(playerID, flags)
    local playerFlags = playerDirtyFlags[playerID]
    if not playerFlags or not flags then
        return false
    end
    return (playerFlags & flags) ~= 0
end

--- Get all dirty flags for a player
---@param playerID string Player's SteamID64
---@return number|nil Bitmask of dirty flags, or nil if not dirty
function DirtySystem.GetDirtyFlags(playerID)
    return playerDirtyFlags[playerID]
end

--- Get all player IDs with specific dirty flags
---@param flags number Bitmask of DirtySystem.FLAGS to check
---@return table Array of player IDs that have any of the specified flags dirty
function DirtySystem.GetDirtyPlayers(flags)
    local players = {}
    if not flags or flags == 0 then
        return players
    end

    for playerID, playerFlags in pairs(playerDirtyFlags) do
        if (playerFlags & flags) ~= 0 then
            players[#players + 1] = playerID
        end
    end

    return players
end

--- Clear dirty flags for a player
---@param playerID string Player's SteamID64
---@param flags number|nil Bitmask of flags to clear (nil = clear all)
function DirtySystem.ClearDirty(playerID, flags)
    local playerFlags = playerDirtyFlags[playerID]
    if not playerFlags then
        return
    end

    if not flags then
        -- Clear all flags
        playerDirtyFlags[playerID] = nil
        -- Remove from all queues
        for _, queue in pairs(dirtyQueues) do
            queue[playerID] = nil
        end
    else
        -- Clear specific flags
        local newFlags = playerFlags & ~flags
        if newFlags == 0 then
            playerDirtyFlags[playerID] = nil
        else
            playerDirtyFlags[playerID] = newFlags
        end

        -- Remove from specific queues
        local flagBit = 1
        while flagBit <= DirtySystem.FLAGS.ALL do
            if (flags & flagBit) ~= 0 then
                dirtyQueues[flagBit][playerID] = nil
            end
            flagBit = flagBit * 2
        end
    end
end

--- Get statistics about dirty system usage
---@return table Statistics including marks, processes, and queue sizes
function DirtySystem.GetStats()
    local queueSizes = {}
    for flag, queue in pairs(dirtyQueues) do
        local count = 0
        for _ in pairs(queue) do count = count + 1 end
        queueSizes[flag] = count
    end

    local dirtyPlayerCount = 0
    for _ in pairs(playerDirtyFlags) do dirtyPlayerCount = dirtyPlayerCount + 1 end

    return {
        marksTotal = stats.marksTotal,
        processesTotal = stats.processesTotal,
        dirtyPlayerCount = dirtyPlayerCount,
        queueSizes = queueSizes,
        lastResetTime = stats.lastResetTime,
    }
end

--- Reset statistics counters
function DirtySystem.ResetStats()
    stats.marksTotal = 0
    stats.processesTotal = 0
    stats.lastResetTime = globals.RealTime()
end

--- Clear all dirty data (useful for testing or session reset)
function DirtySystem.ClearAll()
    playerDirtyFlags = {}
    dirtyQueues = {
        [DirtySystem.FLAGS.SCORE]        = {},
        [DirtySystem.FLAGS.FLAGS]        = {},
        [DirtySystem.FLAGS.CHECKS]       = {},
        [DirtySystem.FLAGS.SESSION]      = {},
        [DirtySystem.FLAGS.PRIORITY]     = {},
        [DirtySystem.FLAGS.CONNECTED]    = {},
        [DirtySystem.FLAGS.DISCONNECTED] = {},
    }
    DirtySystem.ResetStats()
end

--- Debug function to print current dirty state
function DirtySystem.DebugPrint()
    local stats = DirtySystem.GetStats()
    print("[DirtySystem] Debug Info:")
    print(string.format("  Total marks: %d, Total processes: %d",
        stats.marksTotal, stats.processesTotal))
    print(string.format("  Dirty players: %d", stats.dirtyPlayerCount))

    for flag, size in pairs(stats.queueSizes) do
        local flagName = "UNKNOWN"
        if flag == DirtySystem.FLAGS.SCORE then
            flagName = "SCORE"
        elseif flag == DirtySystem.FLAGS.FLAGS then
            flagName = "FLAGS"
        elseif flag == DirtySystem.FLAGS.CHECKS then
            flagName = "CHECKS"
        elseif flag == DirtySystem.FLAGS.SESSION then
            flagName = "SESSION"
        elseif flag == DirtySystem.FLAGS.PRIORITY then
            flagName = "PRIORITY"
        elseif flag == DirtySystem.FLAGS.CONNECTED then
            flagName = "CONNECTED"
        elseif flag == DirtySystem.FLAGS.DISCONNECTED then
            flagName = "DISCONNECTED"
        end
        print(string.format("  Queue %s: %d players", flagName, size))
    end
end

return DirtySystem
