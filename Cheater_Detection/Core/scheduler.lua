--[[ Core/scheduler.lua
     Handles rate-limited tasks and scheduled events.
     Ensures heavy logic (decay, db saving) doesn't spike frame time.
]]

local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local HttpQueue = require("Cheater_Detection.services.http_queue")
local Fetcher = require("Cheater_Detection.Database.Fetcher")
local CosmeticAbuse = require("Cheater_Detection.detectors.cosmetic_abuse")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")

local Scheduler = {}

local _profilerOk, Profiler = pcall(require, "Profiler")
if not _profilerOk then
	Profiler = { Begin = function() end, End = function() end }
end

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
        or Common.IsDoubleTapDetectionEnabled()
        or (adv and adv.Choke == true)
end

local function syncPlayerCacheForMode()
	-- Main.lua PlayerCache_Sync runs SyncTick once per game tick when detectors are on.
	if detectorsNeedLiveCache() then
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

	Profiler.Begin("Sched_PlayerCache")
	syncPlayerCacheForMode()
	Profiler.End("Sched_PlayerCache")

	Profiler.Begin("Sched_ValidateStates")
	PlayerCache.ValidateStates()
	Profiler.End("Sched_ValidateStates")

	if HttpQueue and HttpQueue.Tick then
		Profiler.Begin("Sched_HttpQueue")
		HttpQueue.Tick()
		Profiler.End("Sched_HttpQueue")
	end

	if SteamLookup and SteamLookup.ShouldTickGroupFetch and SteamLookup.ShouldTickGroupFetch() then
		Profiler.Begin("Sched_SteamGroup")
		SteamLookup.TickGroupFetch()
		Profiler.End("Sched_SteamGroup")
	end

	if CosmeticAbuse.HasPendingWork() then
		Profiler.Begin("Sched_Cosmetics")
		CosmeticAbuse.ProcessPending()
		Profiler.End("Sched_Cosmetics")
	end

	if Fetcher and Fetcher.Tick then
		Profiler.Begin("Sched_Fetcher")
		local ok, err = pcall(Fetcher.Tick)
		if not ok then
			local mode = tostring(Fetcher.State and Fetcher.State.mode)
			printc(255, 80, 80, 255, "[FETCHER CRASH] mode=" .. mode .. " err=" .. tostring(err))
			if Fetcher.State then
				Fetcher.State.isRunning = false
				Fetcher.State.mode = "IDLE"
			end
		end
		Profiler.End("Sched_Fetcher")
	end
end

return Scheduler
