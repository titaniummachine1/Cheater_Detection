--[[ Cheater Detection - Warp / Doubletap Detection ]]
--
-- Detects time manipulation exploits using statistical analysis of simulation time
-- Uses standard deviation of tick deltas to identify sequence burst patterns

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local WarpDT = {}

--[[ Configuration ]]
local DETECTION_NAME = "warp_dt"
local EVIDENCE_WEIGHT = 30 -- Very high - blatant exploit
local HISTORY_SIZE = 33 -- Ticks to analyze
local MIN_DELTA_SAMPLES = 30 -- Minimum samples for statistical analysis
local WARP_STDDEV_SIGNATURE = -132 -- Specific standard deviation value indicating warp
local TICK_TOLERANCE = 13 -- Tolerance for tick interval checks

-- Per-player state tracking
local playerWarpData = {}

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

local function initPlayerData(steamID)
	if not playerWarpData[steamID] then
		playerWarpData[steamID] = {
			simTimes = {},
			stdDevList = {},
			lastTickCount = nil,
		}
	end
end

local function timeToTicks(time)
	return Common.Conversion.Time_to_Ticks(time)
end

--[[ Public Functions ]]
function WarpDT.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.Warp then
		return false
	end

	-- Validate player
	if not validatePlayer(player) then
		return false
	end

	-- Get steamID for tracking
	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return false
	end

	-- Skip if already marked as cheater
	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	-- Initialize tracking data
	initPlayerData(steamID)
	local data = playerWarpData[steamID]

	-- Get simulation time in ticks
	local simTime = player:GetSimulationTime()
	if not simTime then
		return false
	end

	local simTimeTicks = timeToTicks(simTime)
	table.insert(data.simTimes, simTimeTicks)

	-- Keep history bounded
	if #data.simTimes > HISTORY_SIZE then
		table.remove(data.simTimes, 1)
	end

	-- Need enough data for analysis
	if #data.simTimes < HISTORY_SIZE then
		return false
	end

	-- Calculate tick deltas
	local deltaTicks = {}
	for i = 2, #data.simTimes do
		local delta = data.simTimes[i] - data.simTimes[i - 1]
		table.insert(deltaTicks, delta)
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

	-- Clamp to detect warp signature
	stdDev = math.max(-132, stdDev)

	-- Check tick interval consistency (avoid false positives from script lag)
	local currentTick = globals.TickCount()
	if not data.lastTickCount then
		data.lastTickCount = currentTick
	else
		local tickInterval = globals.TickInterval()
		local expectedInterval = (currentTick - data.lastTickCount) / tickInterval

		-- If ticks are inconsistent, may be our own lag - skip
		if math.abs(currentTick - data.lastTickCount) < expectedInterval + TICK_TOLERANCE then
			data.lastTickCount = currentTick
			return false
		end

		data.lastTickCount = currentTick
	end

	-- Detect warp signature
	if stdDev == WARP_STDDEV_SIGNATURE then
		Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

		if G.Menu.Advanced.debug then
			print(string.format("[WarpDT] %s - Sequence burst detected (stdDev: %.0f)", player:GetName(), stdDev))
		end

		return true
	end

	-- Track standard deviation history
	table.insert(data.stdDevList, stdDev)
	if #data.stdDevList > HISTORY_SIZE then
		table.remove(data.stdDevList, 1)
	end

	return false
end

return WarpDT
