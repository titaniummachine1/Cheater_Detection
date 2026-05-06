--[[ Core/scheduler.lua
     Handles rate-limited tasks and scheduled events.
     Ensures heavy logic (decay, db saving) doesn't spike frame time.
]]

local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local HttpQueue = require("Cheater_Detection.services.http_queue")
local Fetcher = require("Cheater_Detection.Database.Fetcher")
local ValveCheck = require("Cheater_Detection.detectors.valve_check")
local PlayerCache = require("Cheater_Detection.Core.player_cache")

local Scheduler = {}

function Scheduler.Tick()
    local currentTick = globals.TickCount()

    -- Periodic player state validation (cleanup orphaned players)
    PlayerCache.ValidateStates()

    if HttpQueue and HttpQueue.Tick then
        HttpQueue.Tick()
    end

    if SteamLookup and SteamLookup.TickGroupFetch then
        SteamLookup.TickGroupFetch()
    end

    if ValveCheck and ValveCheck.Tick then
        ValveCheck.Tick()
    end

    if Fetcher and Fetcher.Tick then
        local ok, err = pcall(Fetcher.Tick)
        if not ok then
            local mode = tostring(Fetcher.State and Fetcher.State.mode)
            printc(255, 80, 80, 255, "[FETCHER CRASH] mode=" .. mode .. " err=" .. tostring(err))
            -- Abort to prevent per-frame crash spam
            if Fetcher.State then
                Fetcher.State.isRunning = false
                Fetcher.State.mode = "IDLE"
            end
        end
    end
end

return Scheduler
