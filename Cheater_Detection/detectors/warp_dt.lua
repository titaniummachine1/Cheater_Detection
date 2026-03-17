local Constants = require("Cheater_Detection.Core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Events = require("Cheater_Detection.Core.Events")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local Common = require("Cheater_Detection.Utils.Common")
local PlayerCache = require("Cheater_Detection.Core.player_cache")

local WarpDT = {}

local DETECTION_NAME = "warp_dt"
-- History window: ~0.5 s of simulation-time samples (≈33 ticks at 66 Hz).
-- Recalculated dynamically so it scales with the server tick rate.
local function getHistorySize()
	return math.floor(0.5 / globals.TickInterval() + 0.5)
end

-- If this many players burst on the same tick it is a server/network hitch, not cheating.
local SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD = 3

-- Ensure history is tracking simulation time
local registeredConsumer = false
local function ensureConsumer()
	if registeredConsumer then
		return
	end
	HistoryManager.RegisterConsumer(DETECTION_NAME, {
		retentionTicks = getHistorySize(),
		fields = { HistoryManager.Fields.SimulationTime },
	})
	registeredConsumer = true
end

-- Per-player pattern tracking
local playerStats = {} -- id -> { events = {tick1, tick2...} }

-- Global hitch window: once a hitch is confirmed, suppress ALL WarpDT for this many ticks.
-- This prevents players who arrive late to the burst tick from slipping past the threshold.
-- ~1 s window (≈66 ticks at 66 Hz), recalculated dynamically for the current tick rate.
local function getServerHitchWindow()
	return math.floor(1.0 / globals.TickInterval() + 0.5)
end
-- Initialised to a value that guarantees the hitch window is expired on the first check.
-- Using -math.huge ensures (curTick - lastServerHitchTick) is always >= any window size.
local lastServerHitchTick = -math.huge

local function isInHitchWindow(curTick)
	return (curTick - lastServerHitchTick) < getServerHitchWindow()
end

-- Simultaneous-burst suppression: track which players burst each tick.
-- Key = gameTick, Value = list of player ids that burst on that tick.
-- Entries are cleared when they are more than 2 ticks old.
local burstThisTick = {} -- [tick] -> { id1, id2, ... }
local lastBurstCleanTick = 0

local function recordBurst(tick, id)
	if not burstThisTick[tick] then
		burstThisTick[tick] = {}
	end
	burstThisTick[tick][#burstThisTick[tick] + 1] = id
end

local function isServerHitch(tick)
	local list = burstThisTick[tick]
	return list and #list >= SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD
end

local function cleanBurstTable(curTick)
	if (curTick - lastBurstCleanTick) < 4 then
		return
	end
	lastBurstCleanTick = curTick
	for tick in pairs(burstThisTick) do
		if (curTick - tick) > 3 then
			burstThisTick[tick] = nil
		end
	end
end

local function timeToTicks(time)
	return math.floor(0.5 + time / globals.TickInterval())
end

function WarpDT.ProcessPlayer(playerState)
	if not playerState or not playerState.wrap or not playerState.id then
		return
	end

	-- Menu gate: cheapest check first
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.Warp) then
		return
	end

	-- Connection/FPS stability gate: remote sim times are unreliable when connection is bad
	if not Common.IsConnectionStableForDetection() then
		return
	end

	ensureConsumer()

	local entity = playerState.wrap:GetRawEntity()
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return
	end

	-- Skip bots. Skip local player unless debug mode is enabled for testing.
	local isDebug = Common.IsDebugEnabled()
	if Common.IsBot(entity) or (entity == entities.GetLocalPlayer() and not isDebug) then
		return
	end

	local id = playerState.id
	if not playerStats[id] then
		playerStats[id] = { events = {} }
	end
	local data = playerStats[id]

	-- Already marked?
	if (playerState.flags & Constants.Flags.CHEATER) ~= 0 then
		return
	end

	-- History stored on the PlayerCache state entry
	local cacheEntry = PlayerCache.GetByID(id)
	if not cacheEntry or not cacheEntry.history then
		return
	end

	local history = cacheEntry.history
	local historyCount = HistoryManager.GetCount(history)
	if historyCount < getHistorySize() then
		return
	end

	-- Extract deltas from current history buffer (approx 0.5s of data)
	local simTicks = {}
	for i = 1, historyCount do
		local record = HistoryManager.GetAt(history, i)
		if record and record[HistoryManager.Fields.SimulationTime] then
			simTicks[#simTicks + 1] = timeToTicks(record[HistoryManager.Fields.SimulationTime])
		end
	end

	if #simTicks < getHistorySize() then
		return
	end

	-- Calculate deltas
	local deltaTicks = {}
	for i = 2, #simTicks do
		deltaTicks[#deltaTicks + 1] = simTicks[i] - simTicks[i - 1]
	end

	-- Look for a "Burst" event (large simulation time shift)
	-- Exploits like DT/Warp usually burst ~0.273 s–0.970 s (18–64 ticks at 66 Hz) to be effective.
	-- Standard fakelag is usually ~14–15 ticks. Thresholds scale with tick rate.
	local burstMin = math.floor(18.0 / 66.0 / globals.TickInterval() + 0.5)
	local burstMax = math.floor(64.0 / 66.0 / globals.TickInterval() + 0.5)
	local burstAmount = 0
	for _, d in ipairs(deltaTicks) do
		if d > burstMin and d < burstMax then
			burstAmount = d
			break
		end
	end

	local curTick = globals.TickCount()
	cleanBurstTable(curTick)

	if burstAmount > 0 then
		-- Register this player as bursting this tick BEFORE the cooldown check so the
		-- simultaneous-burst table is always populated for the hitch guard below.
		recordBurst(curTick, id)

		-- Bail immediately if we are already inside a confirmed hitch window.
		if isInHitchWindow(curTick) then
			return
		end

		if not data.lastWarpTick or (curTick - data.lastWarpTick) > math.floor(24.0 / 66.0 / globals.TickInterval() + 0.5) then
			-- If many players burst at the same tick it is a server/network hitch — skip.
			if isServerHitch(curTick) then
				-- Arm the global window so latecomers this burst are also suppressed.
				lastServerHitchTick = curTick
				-- Apply per-player cooldown so this burst doesn't re-fire every tick
				-- while the stale delta remains in the history buffer (~33 ticks).
				data.lastWarpTick = curTick
				if isDebug then
					print(string.format("[WarpDT] server hitch suppressed burst for %s (tick=%d)", id, curTick))
				end
				return
			end

			data.lastWarpTick = curTick
			table.insert(data.events, curTick)

			local reason = "Warp/DT (Packet Burst)"

			-- Scale increment based on events (Leeway: 5 per single, 15 for repeat)
			local increment = (#data.events >= 2) and 15 or 5
			DetectorUtils.ApplyPlayerFlag(playerState, increment, nil, reason)

			-- Clean up events older than ~10 seconds
			while #data.events > 0 and (curTick - data.events[1]) > Constants.SecondsToTicks(10) do
				table.remove(data.events, 1)
			end

			-- If we have many events, clear the oldest one to prevent compounding spam
			if #data.events >= 2 then
				table.remove(data.events, 1)
			end
		end
	end
end

-- Cleanup on disconnect
Events.Subscribe("OnPlayerDisconnect", function(id)
	playerStats[id] = nil
end)

return WarpDT
