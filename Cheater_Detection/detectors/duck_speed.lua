--[[ detectors/duck_speed.lua
     Detects players moving too fast while fully ducked.
     Must be grounded and fully crouched for 2 seconds to avoid false positives.
     Uses lazy PlayerData - NO direct entity API calls.
]]

local Constants                    = require("Cheater_Detection.Core.constants")
local Common                       = require("Cheater_Detection.Utils.Common")
local Evidence                     = require("Cheater_Detection.Core.Evidence_system")
local Events                       = require("Cheater_Detection.Core.Events")
local G                            = require("Cheater_Detection.Utils.Globals")
local PlayerData                   = require("Cheater_Detection.Utils.PlayerData")
local PlayerCache                  = require("Cheater_Detection.Core.player_cache")

local DuckSpeed                    = {}

local FULLY_CROUCHED_VIEW_OFFSET_Z = 45
local DUCK_SPEED_EVIDENCE_WEIGHT   = 85.0

local tickCounters                 = {}

local function isDuckSpeedEnabled()
	local adv = G.Menu and G.Menu.Advanced
	return adv and adv.DuckSpeed == true
end

function DuckSpeed.HasWork(playerState)
	if not isDuckSpeedEnabled() then
		return false
	end
	if not playerState or not playerState.id then
		return false
	end
	if (playerState.flags & Constants.Flags.CHEATER) ~= 0 then
		return false
	end
	local pdata = playerState.pdata
	if not pdata or pdata.isDormant or not pdata.isAlive then
		return false
	end
	return true
end

function DuckSpeed.ProcessPlayer(playerState)
	if not DuckSpeed.HasWork(playerState) then
		return
	end

	if not Common.IsPlayerConnected() then
		return
	end

	local pdata = playerState.pdata
	local id = playerState.id

	local onGround = pdata.onGround
	local flags = pdata.flags
	local velocity = pdata.velocity
	local viewOffset = pdata.viewOffset

	if onGround == nil or flags == nil or velocity == nil then
		return
	end

	if id == PlayerCache.GetLocalID() and not Common.IsDebugEnabled() then
		return
	end

	if not tickCounters[id] then
		tickCounters[id] = 0
	end

	local ducking = (flags & 2) ~= 0

	local viewOffsetZ = viewOffset and viewOffset.z or 0
	local isFullyCrouched = (math.floor(viewOffsetZ) == FULLY_CROUCHED_VIEW_OFFSET_Z)

	if onGround and ducking and isFullyCrouched then
		local ent = PlayerData.GetEntity(pdata)
		if not ent then
			return
		end

		local maxSpeed = ent:GetPropFloat("m_flMaxspeed")
		local currentSpeed = velocity:Length()

		if currentSpeed >= (maxSpeed * 0.66) then
			tickCounters[id] = tickCounters[id] + 1

			if tickCounters[id] >= Constants.SecondsToTicks(2) then
				Evidence.AddEvidence(id, "duck_speed", DUCK_SPEED_EVIDENCE_WEIGHT)
				tickCounters[id] = 0
				if Common.IsDebugEnabled() then
					print(string.format(
						"[DuckSpeed] %s duck speed exploit (evidence +%.1f)",
						id, DUCK_SPEED_EVIDENCE_WEIGHT))
				end
			end
		else
			tickCounters[id] = math.max(0, tickCounters[id] - 1)
		end
	else
		tickCounters[id] = 0
	end
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	tickCounters[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	tickCounters[id] = nil
end)

return DuckSpeed
