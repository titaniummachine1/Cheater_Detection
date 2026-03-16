local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local EventBus = require("Cheater_Detection.core.event_bus")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

local WarpDT = {}

local DETECTION_NAME = "warp_dt"
local HISTORY_SIZE = 33

-- Ensure history is tracking simulation time
local registeredConsumer = false
local function ensureConsumer()
	if registeredConsumer then
		return
	end
	HistoryManager.RegisterConsumer(DETECTION_NAME, {
		retentionTicks = HISTORY_SIZE,
		fields = { HistoryManager.Fields.SimulationTime },
	})
	registeredConsumer = true
end

-- Per-player pattern tracking
local playerStats = {} -- id -> { events = {tick1, tick2...} }

local function timeToTicks(time)
	return math.floor(0.5 + time / globals.TickInterval())
end

local Common = require("Cheater_Detection.Utils.Common")

function WarpDT.ProcessPlayer(playerState)
	assert(playerState, "WarpDT.ProcessPlayer: playerState missing")
	assert(playerState.wrap, "WarpDT.ProcessPlayer: playerState.wrap missing id=" .. tostring(playerState.id))
	assert(playerState.id, "WarpDT.ProcessPlayer: playerState.id missing")

	-- Check local stability to avoid false positives
	if not Common.CheckConnectionState() or Common.IsFrameGap() then
		return
	end

	ensureConsumer()

	local entity = playerState.wrap:GetRawEntity()
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return
	end

	-- Skip bots. Skip local player unless debug mode is enabled for testing.
	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
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

	-- HistoryManager uses PlayerState (legacy) storage
	local PlayerStateLegacy = require("Cheater_Detection.Utils.PlayerState")
	local legacyState = PlayerStateLegacy.Get(id)
	if not legacyState or not legacyState.History then
		return
	end

	local history = legacyState.History
	local historyCount = HistoryManager.GetCount(history)
	if historyCount < HISTORY_SIZE then
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

	if #simTicks < HISTORY_SIZE then
		return
	end

	-- Calculate deltas
	local deltaTicks = {}
	for i = 2, #simTicks do
		deltaTicks[#deltaTicks + 1] = simTicks[i] - simTicks[i - 1]
	end

	-- Look for a "Burst" event (large simulation time shift)
	local burstAmount = 0
	for _, d in ipairs(deltaTicks) do
		-- Exploits like DT/Warp usually burst 18-24+ ticks to be effective.
		-- Standard fakelag is usually 14-15.
		if d > 18 and d < 64 then
			burstAmount = d
			break
		end
	end

	local curTick = globals.TickCount()

	-- STATE MACHINE: Simple Burst Detect
	if burstAmount > 0 then
		-- Warp is more "one-time" but we still want some consistency or high score
		-- We detect a Burst and then wait for a cooldown (24 ticks) before allowing another detection for this player
		if not data.lastWarpTick or (curTick - data.lastWarpTick) > 24 then
			data.lastWarpTick = curTick
			table.insert(data.events, curTick)

			local reason = "Warp/DT (Packet Burst)"

			-- Scale increment based on events (Leeway: 5 per single, 15 for repeat)
			local increment = (#data.events >= 2) and 15 or 5
			playerState.score = math.min(99, playerState.score + increment)

			if playerState.score >= Constants.Threshold.SUSPICIOUS then
				playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
			end

			if playerState.score >= Constants.Threshold.HIGH_RISK then
				playerState.flags = playerState.flags | Constants.Flags.HIGH_RISK
			end

			Database.UpsertCheater(id, {
				name = playerState.wrap:GetName(),
				reason = reason,
				flags = playerState.flags,
				score = playerState.score,
			})

			EventBus.Publish("OnPlayerStateChange", playerState, reason)

			-- Clean up events older than 660 ticks (approx 10 seconds)
			while #data.events > 0 and (curTick - data.events[1]) > 660 do
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
EventBus.Subscribe("OnPlayerDisconnect", function(id)
	playerStats[id] = nil
end)

return WarpDT
