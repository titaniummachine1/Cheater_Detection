--[[ Core/scheduler.lua
     Handles rate-limited tasks and scheduled events.
     Ensures heavy logic (decay, db saving) doesn't spike frame time.
]]

local Events = require("Cheater_Detection.Core.Events")
local Constants = require("Cheater_Detection.Core.constants")

local Scheduler = {}

local lastHeartbeat = 0
local ticksPassed = 0

local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local HttpQueue = require("Cheater_Detection.services.http_queue")
local Fetcher = require("Cheater_Detection.Database.Fetcher")

function Scheduler.Tick()
    local currentTick = globals.TickCount()
    ticksPassed = ticksPassed + 1

    if currentTick - lastHeartbeat >= Constants.SecondsToTicks(Constants.DECAY_INTERVAL_SECONDS) then
        lastHeartbeat = currentTick
        Events.Publish("DecayHeartbeat", currentTick)
    end

    if (ticksPassed % Constants.SecondsToTicks(1)) == 0 then
        Events.Publish("OneSecondTick", currentTick)
    end

    if HttpQueue and HttpQueue.Tick then
        HttpQueue.Tick()
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
