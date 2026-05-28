--[[ Core/scheduler.lua
     Handles rate-limited tasks and scheduled events.
     Ensures heavy logic (decay, db saving) doesn't spike frame time.
]]

local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local HttpQueue = require("Cheater_Detection.services.http_queue")
local Fetcher = require("Cheater_Detection.Database.Fetcher")
local ValveCheck = require("Cheater_Detection.detectors.valve_check")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local G = require("Cheater_Detection.Utils.Globals")

local Scheduler = {}

local lastTick = -1
local lastIdleCacheSync = 0
local IDLE_CACHE_SYNC_INTERVAL = 0.5

local function detectorsNeedLiveCache()
    local menu = G.Menu
    local main = menu and menu.Main or nil
    local adv = menu and menu.Advanced or nil
    return (main and main.ValveCheck == true)
        or (adv and adv.SilentAimbot == true)
        or (adv and adv.AntiAim == true)
        or (adv and adv.DuckSpeed == true)
        or (adv and adv.Bhop == true)
        or (adv and adv["Warp"] == true)
        or (adv and adv.Choke == true)
        or (adv and adv.Cosmetics == true)
end

local function syncPlayerCacheForMode()
    if detectorsNeedLiveCache() then
        PlayerCache.SyncTick()
        return
    end

    local now = globals.RealTime()
    if (now - lastIdleCacheSync) >= IDLE_CACHE_SYNC_INTERVAL then
        lastIdleCacheSync = now
        PlayerCache.SyncTick()
    end
end

function Scheduler.Tick()
    local currentTick = globals.TickCount()
    if currentTick == lastTick then
        return
    end
    lastTick = currentTick

    syncPlayerCacheForMode()

    -- Periodic player state validation (cleanup orphaned players)
    PlayerCache.ValidateStates()

    if HttpQueue and HttpQueue.Tick then
        HttpQueue.Tick()
    end

    if SteamLookup and SteamLookup.TickGroupFetch then
        SteamLookup.TickGroupFetch()
    end

    if ValveCheck.IsEnabled() then
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
