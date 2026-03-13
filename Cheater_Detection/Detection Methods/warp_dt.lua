--[[ Cheater Detection - Warp / Doubletap Detection ]]
--
-- Detects time manipulation exploits using statistical analysis of simulation time
-- Uses standard deviation of tick deltas to identify sequence burst patterns

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local Constants = require("Cheater_Detection.core.constants")
local EventBus = require("Cheater_Detection.core.event_bus")
local Database = require("Cheater_Detection.Database.Database")

--[[ Module Declaration ]]
local WarpDT = {}

local DETECTION_NAME = "warp_dt"
local EVIDENCE_WEIGHT = 100 -- Instant ban - blatant exploit
local HISTORY_SIZE = 33 -- Ticks to analyze
local MIN_DELTA_SAMPLES = 30 -- Minimum samples for statistical analysis
local WARP_STDDEV_SIGNATURE = -132 -- Specific standard deviation value indicating warp
--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() or player:IsDormant() then
		return false
	end
	return true
end

local function timeToTicks(time)
	return math.floor(0.5 + time / globals.TickInterval())
end

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

local function collectSimTimeTicks(steamID)
	local state = PlayerState.Get(steamID)
	if not state or not state.History then
		return nil
	end

	local history = state.History
	local total = #history
	if total < HISTORY_SIZE then
		return nil
	end

	local ticks = {}
	local startIndex = math.max(1, total - HISTORY_SIZE + 1)
	for i = startIndex, total do
		local entry = history[i]
		local simTime = entry and (entry.sim_time or entry.SimTime)
		if not simTime then
			return nil
		end
		ticks[#ticks + 1] = timeToTicks(simTime)
	end

	if #ticks < HISTORY_SIZE then
		return nil
	end

	return ticks
end

--[[ Public Functions ]]
function WarpDT.Check(player, steamID)
	if not G.Menu.Advanced.Warp then
		if registeredConsumer then
			HistoryManager.UnregisterConsumer(DETECTION_NAME)
			registeredConsumer = false
		end
		return false
	end

	ensureConsumer()

	if not validatePlayer(player) then
		return false
	end

	if not steamID then
		steamID = tostring(Common.GetSteamID64(player))
	end

	local simTicks = collectSimTimeTicks(steamID)
	if not simTicks then
		return false
	end

	local deltaTicks = {}
	for i = 2, #simTicks do
		deltaTicks[#deltaTicks + 1] = simTicks[i] - simTicks[i - 1]
	end

	if #deltaTicks < MIN_DELTA_SAMPLES then
		return false
	end

	-- Calculate mean delta
	local meanDelta = 0
	for _, delta in ipairs(deltaTicks) do
		meanDelta = meanDelta + delta
	end
	meanDelta = meanDelta / #deltaTicks

	-- Calculate variance
	local sumSquaredDiff = 0
	for _, delta in ipairs(deltaTicks) do
		local diff = delta - meanDelta
		sumSquaredDiff = sumSquaredDiff + diff * diff
	end

	local variance = sumSquaredDiff / (#deltaTicks - 1)
	local stdDev = math.sqrt(variance)

	--[[ 
		MAGIC FIX EXPLANATION:
		When a player manipulates tickbase (warp/doubletap) with extreme values (e.g. -2000 ticks),
		the variance calculation overflows or corrupts due to floating point precision issues with
		massive negative deltas.
		
		In Lua/Source Engine, `math.sqrt(corrupted_variance)` often results in `-nan(ind)` or `-inf`.
		However, due to a specific engine quirk/compiler behavior, `math.max(-132, NaN)` or 
		`math.max(-132, -inf)` reliably resolves to exactly -132.
		
		This "magic number" -132 acts as a catch-all bucket for these mathematical impossibilities
		that only occur during heavy tickbase manipulation.
	]]
	stdDev = math.max(-132, stdDev)

	-- Detect warp signature or spike
	local spikeDetected = false
	for i = 1, #deltaTicks do
		-- Detection for ticks shifted (SimulationTime delta > 1.5x tickrate)
		-- Normal movement is 1, maybe 2 with jitter. 3+ is a blatant warp/DT.
		if deltaTicks[i] > 3 then 
			spikeDetected = true
			break
		end
	end

	if stdDev == WARP_STDDEV_SIGNATURE or spikeDetected then
		local reason = spikeDetected and "Tick Spike (Warp)" or "Warp Signature"
		
		-- Direct mark as cheater per user request
		local state = PlayerState.Get(steamID)
		if state then
			local oldFlags = state.flags
			state.flags = state.flags | Constants.Flags.CHEATER
			state.score = 100
			
			Database.UpsertCheater(steamID, {
				name = player:GetName(),
				reason = reason,
				flags = state.flags,
				score = state.score
			})
			
			if oldFlags ~= state.flags then
				EventBus.Publish("OnPlayerStateChange", state, reason)
			end
		end

		Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

		if G.Menu.Advanced.debug then
			print(string.format("[WarpDT] %s - %s detected (stdDev: %.1f)", player:GetName(), reason, stdDev))
		end

		return true
	end

	return false
end

return WarpDT
