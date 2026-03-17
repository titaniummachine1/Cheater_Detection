--[[ detectors/fake_lag.lua
     Detects excessive packet choking (Fake Lag) by monitoring simulation time deltas.
]]

local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Events = require("Cheater_Detection.Core.Events")

local FakeLag = {}

-- Threshold for fake lag: ~0.227 s of simulation-time delta (≈15 ticks at 66 Hz).
-- Recalculated each check so it scales correctly with the server tick rate.
local function getMaxTickDelta()
	return math.floor(15.0 / 66.0 / globals.TickInterval() + 0.5)
end

-- Per-player tracking
local playerStats = {} -- id -> { lastSimTime, events = {tick1, tick2...} }

local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
end

function FakeLag.ProcessPlayer(playerState)
	if not playerState or not playerState.wrap or not playerState.id then
		return
	end

	-- Menu gate: cheapest check first
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.Choke) then
		return
	end

	-- Connection/FPS stability gate: remote sim times are unreliable when connection is bad
	if not Common.IsConnectionStableForDetection() then
		return
	end

	local entity = playerState.wrap:GetRawEntity()
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return
	end

	-- Skip bots. Skip local player unless debug mode is enabled for testing.
	if Common.IsBot(entity) or (entity == entities.GetLocalPlayer() and not Common.IsDebugEnabled()) then
		return
	end

	local id = playerState.id
	if not playerStats[id] then
		playerStats[id] = { lastSimTime = 0, events = {} }
	end
	local data = playerStats[id]

	local currentSimTime = playerState.wrap:GetSimulationTime()
	if not currentSimTime then
		return
	end

	if data.lastSimTime == 0 then
		data.lastSimTime = currentSimTime
		return
	end

	local delta = currentSimTime - data.lastSimTime

	-- Reject invalid deltas (respawn, lag comp, demo)
	if delta <= 0 or delta > 2 then
		data.lastSimTime = currentSimTime
		return
	end

	local deltaTicks = timeToTicks(delta)
	local curTick = globals.TickCount()

	-- Only record events that meet the threshold
	if deltaTicks >= getMaxTickDelta() then
		table.insert(data.events, { tick = curTick, amount = deltaTicks })

		-- Clean up events older than ~5 seconds
		while #data.events > 0 and (curTick - data.events[1].tick) > Constants.SecondsToTicks(5) do
			table.remove(data.events, 1)
		end

		-- Trigger suspicion ONLY if they choke in a rhythmic, repeating fashion
		-- (choking same amount of ticks for exact amount and repeating)
		if #data.events >= 3 then
			local consistent = true
			local firstAmount = data.events[1].amount
			for i = 2, #data.events do
				local diff = math.abs(data.events[i].amount - firstAmount)
				if diff > 1 then -- Stricter rhythm matching
					consistent = false
					break
				end
			end

			if consistent then
				-- ~0.333 s cooldown between adding weight/marking for FakeLag per suspect (≈22 ticks at 66 Hz)
				local lastFlag = data.lastFlagTick or 0
				if (curTick - lastFlag) < math.floor(22.0 / 66.0 / globals.TickInterval() + 0.5) then
					return
				end

				data.lastFlagTick = curTick
				local reason = string.format("Fake Lag (Rhythmic choke: %d ticks)", deltaTicks)
				DetectorUtils.ApplyPlayerFlag(playerState, 5, nil, reason)

				-- Clear events to wait for next sequence
				data.events = {}
			end
		end
	end

	data.lastSimTime = currentSimTime
end

-- Cleanup
Events.Subscribe("OnPlayerDisconnect", function(id)
	playerStats[id] = nil
end)

return FakeLag
