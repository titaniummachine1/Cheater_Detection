--[[ core/scheduler.lua
     Handles rate-limited tasks and scheduled events.
     Ensures heavy logic (decay, db saving) doesn't spike frame time.
]]

local EventBus = require("Cheater_Detection.core.event_bus")
local Constants = require("Cheater_Detection.core.constants")

local Scheduler = {}

local lastHeartbeat = 0
local ticksPassed = 0

local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local HttpQueue = require("Cheater_Detection.services.http_queue")
local Fetcher = require("Cheater_Detection.Database.Fetcher")

function Scheduler.Tick()
	local currentTick = globals.TickCount()
	ticksPassed = ticksPassed + 1

	-- Heartbeat every 10 seconds (approx 660 ticks)
	if currentTick - lastHeartbeat >= (Constants.DECAY_INTERVAL_SECONDS * Constants.TICKS_PER_SECOND) then
		lastHeartbeat = currentTick
		EventBus.Publish("DecayHeartbeat", currentTick)
	end

	-- Every 1 second (approx 66 ticks)
	if (ticksPassed % Constants.TICKS_PER_SECOND) == 0 then
		EventBus.Publish("OneSecondTick", currentTick)
	end

	-- Every frame (Fetcher/HttpQueue handle their own internal states)
	if HttpQueue and HttpQueue.Tick then
		HttpQueue.Tick()
	end
	
	if Fetcher and Fetcher.Tick then
		Fetcher.Tick()
	end
end

return Scheduler
