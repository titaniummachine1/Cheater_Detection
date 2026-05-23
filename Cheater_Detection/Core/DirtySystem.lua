--[[ Core/DirtySystem.lua
     Simplified dirty flag system for player data updates.

     For 32-100 player servers, we don't need complex bitmask queues.
     A simple hash table with per-player dirty reason sets is:
     - O(1) lookups
     - No bitwise operations
     - No queue synchronization
     - Cleaner code

     Usage:
       DirtySystem.MarkDirty(playerID, "score")
       DirtySystem.MarkDirty(playerID, "flags")
       DirtySystem.ProcessDirty("score", callback)
]]

local Constants = require("Cheater_Detection.Core.constants")

local DirtySystem = {}

-- Valid dirty reasons (string keys for clarity)
DirtySystem.REASONS = {
    SCORE        = "score",
    FLAGS        = "flags",
    CHECKS       = "checks",
    SESSION      = "session",
    PRIORITY     = "priority",
    CONNECTED    = "connected",
    DISCONNECTED = "disconnected",
}

-- Single table: [playerID] = {reason1=true, reason2=true, ...}
local dirtyPlayers = {}

-- Stats
local stats = {
    marksTotal = 0,
    processesTotal = 0,
}

--- Mark a player as dirty with specific reason
---@param playerID string Player's SteamID64
---@param reason string One of DirtySystem.REASONS
function DirtySystem.MarkDirty(playerID, reason)
    if not playerID or not reason then
        return
    end

    local playerEntry = dirtyPlayers[playerID]
    if not playerEntry then
        playerEntry = {}
        dirtyPlayers[playerID] = playerEntry
    end

    if not playerEntry[reason] then
        playerEntry[reason] = true
        stats.marksTotal = stats.marksTotal + 1
    end
end

--- Process dirty players for specific reason
---@param reason string One of DirtySystem.REASONS to process
---@param callback function Called for each dirty player: callback(playerID)
function DirtySystem.ProcessDirty(reason, callback)
    if not reason or not callback then
        return 0
    end

    local processedCount = 0

    for playerID, reasons in pairs(dirtyPlayers) do
        if reasons[reason] then
            callback(playerID)
            processedCount = processedCount + 1

            -- Clear this reason
            reasons[reason] = nil

            -- If no more reasons, remove player entry entirely
            if not next(reasons) then
                dirtyPlayers[playerID] = nil
            end
        end
    end

    stats.processesTotal = stats.processesTotal + processedCount
    return processedCount
end

--- Check if a player has specific dirty reason
---@param playerID string Player's SteamID64
---@param reason string One of DirtySystem.REASONS
---@return boolean True if player has this reason dirty
function DirtySystem.IsDirty(playerID, reason)
    local playerEntry = dirtyPlayers[playerID]
    if not playerEntry then
        return false
    end
    if reason then
        return playerEntry[reason] == true
    end
    return next(playerEntry) ~= nil
end

--- Get all dirty reasons for a player
---@param playerID string Player's SteamID64
---@return table|nil Table of reasons {score=true, flags=true} or nil
function DirtySystem.GetDirtyReasons(playerID)
    return dirtyPlayers[playerID]
end

--- Get all player IDs with specific dirty reason
---@param reason string One of DirtySystem.REASONS
---@return table Array of player IDs
function DirtySystem.GetDirtyPlayers(reason)
    local players = {}
    if not reason then
        return players
    end

    for playerID, reasons in pairs(dirtyPlayers) do
        if reasons[reason] then
            players[#players + 1] = playerID
        end
    end

    return players
end

--- Clear dirty reasons for a player
---@param playerID string Player's SteamID64
---@param reason string|nil Specific reason to clear (nil = clear all)
function DirtySystem.ClearDirty(playerID, reason)
    local playerEntry = dirtyPlayers[playerID]
    if not playerEntry then
        return
    end

    if not reason then
        -- Clear all
        dirtyPlayers[playerID] = nil
    else
        -- Clear specific reason
        playerEntry[reason] = nil
        if not next(playerEntry) then
            dirtyPlayers[playerID] = nil
        end
    end
end

--- Clear all dirty data
function DirtySystem.ClearAll()
    for k in pairs(dirtyPlayers) do
        dirtyPlayers[k] = nil
    end
    stats.marksTotal = 0
    stats.processesTotal = 0
end

--- Get statistics
---@return table Statistics
function DirtySystem.GetStats()
    local dirtyCount = 0
    for _ in pairs(dirtyPlayers) do
        dirtyCount = dirtyCount + 1
    end

    return {
        marksTotal = stats.marksTotal,
        processesTotal = stats.processesTotal,
        dirtyPlayerCount = dirtyCount,
    }
end

--- Reset statistics counters
function DirtySystem.ResetStats()
    stats.marksTotal = 0
    stats.processesTotal = 0
end

return DirtySystem
