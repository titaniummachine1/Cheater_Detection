--[[ detectors/duck_speed.lua
     Detects players moving too fast while fully ducked.
     Must be grounded and fully crouched for 2 seconds to avoid false positives.
]]

local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local Events = require("Cheater_Detection.Core.Events")

local DuckSpeed = {}

-- State storage for tick accumulation
local tickCounters = {}

function DuckSpeed.ProcessPlayer(playerState)
	assert(playerState, "DuckSpeed.ProcessPlayer: playerState missing")
	assert(playerState.wrap, "DuckSpeed.ProcessPlayer: playerState.wrap missing id=" .. tostring(playerState.id))
	assert(playerState.id, "DuckSpeed.ProcessPlayer: playerState.id missing")

	local entity = playerState.wrap:GetRawEntity()
	if not entity then
		return
	end

	-- Skip local player unless debug mode is enabled for testing.
	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	if entity == entities.GetLocalPlayer() and not isDebug then
		return
	end

	local id = playerState.id
	if not tickCounters[id] then
		tickCounters[id] = 0
	end

	-- Get Flags
	local flags = entity:GetPropInt("m_fFlags")
	local onGround = (flags & 1) ~= 0 -- FL_ONGROUND
	local ducking = (flags & 2) ~= 0 -- FL_DUCKING

	-- Get View Offset (Fully crouched check)
	local viewOffsetZ = entity:GetPropVector("localdata", "m_vecViewOffset[0]").z
	local isFullyCrouched = (math.floor(viewOffsetZ) == 45)

	if onGround and ducking and isFullyCrouched then
		-- Calculate Max Speed
		local maxSpeed = entity:GetPropFloat("m_flMaxspeed")
		local currentSpeed = entity:EstimateAbsVelocity():Length()

		-- Exploit check: Velocity > 66% of max standing speed while ducked
		if currentSpeed >= (maxSpeed * 0.66) then
			tickCounters[id] = tickCounters[id] + 1

			-- 2 Second Threshold (132 ticks at 66 FPS)
			if tickCounters[id] >= 132 then
				local oldFlags = playerState.flags
				playerState.flags = playerState.flags | Constants.Flags.CHEATER
				playerState.score = 100

				local reason = "Duck Speed Exploit"

				Database.UpsertCheater(id, {
					name = playerState.wrap:GetName(),
					reason = reason,
					flags = playerState.flags,
					score = playerState.score,
				})

				if oldFlags ~= playerState.flags then
						Events.Publish("OnPlayerStateChange", playerState, reason)
				end

				tickCounters[id] = 0 -- Reset after detection
			end
		else
			tickCounters[id] = math.max(0, tickCounters[id] - 1)
		end
	else
		-- Reset counter if state breaks (not on ground or not ducking)
		tickCounters[id] = 0
	end
end

-- Cleanup when player disconnects
Events.Subscribe("OnPlayerDisconnect", function(id)
	tickCounters[id] = nil
end)

return DuckSpeed
