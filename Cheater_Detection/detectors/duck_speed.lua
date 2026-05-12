--[[ detectors/duck_speed.lua
     Detects players moving too fast while fully ducked.
     Must be grounded and fully crouched for 2 seconds to avoid false positives.
     Uses lazy PlayerData - NO direct entity API calls.
]]

local Constants = require("Cheater_Detection.Core.constants")
local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Events = require("Cheater_Detection.Core.Events")
local PlayerData = require("Cheater_Detection.Utils.PlayerData")

local DuckSpeed = {}

-- View offset Z when fully crouched in TF2 (engine constant)
local FULLY_CROUCHED_VIEW_OFFSET_Z = 45

-- State storage for tick accumulation
local tickCounters = {}

function DuckSpeed.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then
		return
	end

	-- Basic check: must be connected to server (but not 100% stability required)
	if not Common.IsPlayerConnected() then
		return
	end

	local pdata = playerState.pdata
	local id = playerState.id
	
	-- Use lazy cached properties from PlayerData
	local onGround = pdata.onGround
	local flags = pdata.flags
	local velocity = pdata.velocity
	local viewOffset = pdata.viewOffset
	
	-- If data is stale (old tick), skip this tick
	if onGround == nil or flags == nil or velocity == nil then
		return
	end

	-- Skip local player unless debug mode is enabled for testing.
	if id == tostring(Common.GetSteamID64(entities.GetLocalPlayer())) and not Common.IsDebugEnabled() then
		return
	end

	if not tickCounters[id] then
		tickCounters[id] = 0
	end

	local ducking = (flags & 2) ~= 0 -- FL_DUCKING
	
	-- Get View Offset Z (Fully crouched check)
	local viewOffsetZ = viewOffset and viewOffset.z or 0
	local isFullyCrouched = (math.floor(viewOffsetZ) == FULLY_CROUCHED_VIEW_OFFSET_Z)

	if onGround and ducking and isFullyCrouched then
		-- Calculate Max Speed
		-- Note: m_flMaxspeed needs entity access - skip if can't get safe entity
		local ent = PlayerData.GetEntity(pdata)
		if not ent then
			return
		end
		
		local maxSpeed = ent:GetPropFloat("m_flMaxspeed")
		local currentSpeed = velocity:Length()

		-- Exploit check: Velocity > 66% of max standing speed while ducked
		if currentSpeed >= (maxSpeed * 0.66) then
			tickCounters[id] = tickCounters[id] + 1

			-- 2 Second Threshold
			if tickCounters[id] >= Constants.SecondsToTicks(2) then
				DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER, "Duck Speed Exploit")
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

Events.Subscribe("OnPlayerRemoved", function(id)
	tickCounters[id] = nil
end)

return DuckSpeed
