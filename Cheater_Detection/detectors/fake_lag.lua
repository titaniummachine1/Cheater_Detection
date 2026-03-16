--[[ detectors/fake_lag.lua
     Detects excessive packet choking (Fake Lag) by monitoring simulation time deltas.
]]

local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local EventBus = require("Cheater_Detection.core.event_bus")

local FakeLag = {}

-- Constant threshold for fake lag (usually 14-15 on TF2)
local MAX_TICK_DELTA = 15 -- Standard fakelag is ~14-15

-- Per-player tracking
-- Per-player tracking
local playerStats = {} -- id -> { lastSimTime, events = {tick1, tick2...} }

local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
end

local Common = require("Cheater_Detection.Utils.Common")

function FakeLag.ProcessPlayer(playerState)
	assert(playerState, "FakeLag.ProcessPlayer: playerState missing")
	assert(playerState.wrap, "FakeLag.ProcessPlayer: playerState.wrap missing id=" .. tostring(playerState.id))
	assert(playerState.id, "FakeLag.ProcessPlayer: playerState.id missing")

	-- Check local stability to avoid false positives
	if not Common.CheckConnectionState() or Common.IsFrameGap() then
		return
	end

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
	if deltaTicks >= MAX_TICK_DELTA then
		table.insert(data.events, { tick = curTick, amount = deltaTicks })

		-- Clean up events older than 330 ticks (approx 5 seconds)
		while #data.events > 0 and (curTick - data.events[1].tick) > 330 do
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
				-- 22 tick cooldown between adding weight/marking for FakeLag per suspect
				local lastFlag = data.lastFlagTick or 0
				if (curTick - lastFlag) < 22 then
					return
				end

				data.lastFlagTick = curTick
				-- Lower score increment for FakeLag as requested
				playerState.score = math.min(99, playerState.score + 5)

				local reason = string.format("Fake Lag (Rhythmic choke: %d ticks)", deltaTicks)

				if playerState.score >= Constants.Threshold.HIGH_RISK then
					playerState.flags = playerState.flags | Constants.Flags.HIGH_RISK
					playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
				elseif playerState.score >= Constants.Threshold.SUSPICIOUS then
					playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
				end

				Database.UpsertCheater(id, {
					name = playerState.wrap:GetName(),
					reason = reason,
					flags = playerState.flags,
					score = playerState.score,
				})

				EventBus.Publish("OnPlayerStateChange", playerState, reason)

				-- Clear events to wait for next sequence
				data.events = {}
			end
		end
	end

	data.lastSimTime = currentSimTime
end

-- Cleanup
EventBus.Subscribe("OnPlayerDisconnect", function(id)
	playerStats[id] = nil
end)

return FakeLag
