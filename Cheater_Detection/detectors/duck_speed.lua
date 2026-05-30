--[[ detectors/duck_speed.lua
     Detects players moving too fast while fully ducked.
     Must be grounded and fully crouched for ~3s before scoring (avoids brief crouch bursts).
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
local DUCK_SPEED_RATIO_MIN         = 0.66
local DUCK_CONFIRM_SECONDS         = 3.0
local DUCK_SPEED_EVIDENCE_WEIGHT   = 15.0
local DUCK_SPEED_EVIDENCE_COOLDOWN_S = 10.0
local DUCK_SPEED_EVIDENCE_CAP      = Evidence.GetMethodScoreCap("duck_speed")

local tickCounters                 = {}
local evidenceCooldowns            = {}

local function isDuckSpeedEnabled()
	local adv = G.Menu and G.Menu.Advanced
	return adv and adv.DuckSpeed == true
end

local function getConfirmTicks()
	return Constants.SecondsToTicks(DUCK_CONFIRM_SECONDS)
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
	if Evidence.GetMethodWeight(playerState.id, "duck_speed") >= DUCK_SPEED_EVIDENCE_CAP then
		return Common.IsLogCategoryEnabled("All")
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

	if Evidence.GetMethodWeight(id, "duck_speed") >= DUCK_SPEED_EVIDENCE_CAP then
		return
	end

	local now = globals.RealTime()
	if evidenceCooldowns[id] and (now - evidenceCooldowns[id]) < DUCK_SPEED_EVIDENCE_COOLDOWN_S then
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

		if currentSpeed >= (maxSpeed * DUCK_SPEED_RATIO_MIN) then
			tickCounters[id] = tickCounters[id] + 1

			if tickCounters[id] >= getConfirmTicks() then
				local beforeWeight = Evidence.GetMethodWeight(id, "duck_speed")
				Evidence.AddEvidence(id, "duck_speed", DUCK_SPEED_EVIDENCE_WEIGHT)
				tickCounters[id] = 0
				evidenceCooldowns[id] = now
				if Common.IsDebugEnabled() then
					print(string.format(
						"[DuckSpeed] %s duck speed (evidence +%.1f, total duck_speed=%.1f)",
						id,
						Evidence.GetMethodWeight(id, "duck_speed") - beforeWeight,
						Evidence.GetMethodWeight(id, "duck_speed")))
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
	evidenceCooldowns[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	tickCounters[id] = nil
	evidenceCooldowns[id] = nil
end)

return DuckSpeed
