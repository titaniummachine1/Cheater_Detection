--[[ detectors/bhop.lua
     Detects scripted bunnyhops by counting consecutive "perfect" jumps.
     Tracks ground contact ticks on landing, then scores on ground→air transition.
     Only runs while airborne or in the brief post-landing ground window (no idle ground work).
]]

local Constants     = require("Cheater_Detection.Core.constants")
local Common        = require("Cheater_Detection.Utils.Common")
local Evidence      = require("Cheater_Detection.Core.Evidence_system")
local Events        = require("Cheater_Detection.Core.Events")
local G             = require("Cheater_Detection.Utils.Globals")
local PlayerCache   = require("Cheater_Detection.Core.player_cache")

local Bhop          = {}

local playerData    = {}
local evidenceCooldowns = {}
local MAX_GROUND_TICKS = 2
local CHAIN_BREAK_SECONDS = 1.5
local BHOP_EVIDENCE_WEIGHT = 5.0
local BHOP_EVIDENCE_COOLDOWN_S = 1.0

local function isBhopEnabled()
	local adv = G.Menu and G.Menu.Advanced
	return adv and adv.Bhop == true
end

local function clearBhopState(id)
	playerData[id] = nil
end

--- Airborne this tick, or still counting landing ticks after air (inAir / groundTicks only set during chains).
function Bhop.HasWork(playerState)
	if not isBhopEnabled() then
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
	if pdata.onGround == nil then
		return false
	end
	if not pdata.onGround then
		return true
	end
	local data = playerData[playerState.id]
	return data ~= nil and (data.inAir == true or data.groundTicks ~= nil)
end

function Bhop.ProcessPlayer(playerState)
	if not Bhop.HasWork(playerState) then
		return
	end

	if not Common.IsPlayerConnected() then
		return
	end

	local id = playerState.id
	local pdata = playerState.pdata
	local onGround = pdata.onGround

	if id == PlayerCache.GetLocalID() and not Common.IsDebugEnabled() then
		return
	end

	if onGround then
		local data = playerData[id]
		if not data then
			return
		end

		if data.inAir then
			data.inAir = nil
			data.groundTicks = 1
			return
		end

		if not data.groundTicks then
			return
		end

		data.groundTicks = data.groundTicks + 1
		if data.groundTicks > MAX_GROUND_TICKS then
			clearBhopState(id)
		end
		return
	end

	-- Airborne
	local data = playerData[id]
	if data and data.inAir then
		return
	end

	local groundTicks = (data and data.groundTicks) or 0
	if not data then
		data = {
			consecutivePerfects = 0,
			lastJumpTime = nil,
		}
		playerData[id] = data
	end

	local now = globals.RealTime()
	if data.lastJumpTime and (now - data.lastJumpTime) > CHAIN_BREAK_SECONDS then
		data.consecutivePerfects = 0
	end

	data.lastJumpTime = now
	if groundTicks >= 0 and groundTicks <= MAX_GROUND_TICKS then
		data.consecutivePerfects = data.consecutivePerfects + 1

		if data.consecutivePerfects >= Constants.BHOP_MIN_CONSECUTIVE_SUCCESS then
			local lastEvidence = evidenceCooldowns[id] or 0
			if (now - lastEvidence) >= BHOP_EVIDENCE_COOLDOWN_S then
				Evidence.AddEvidence(id, "bhop", BHOP_EVIDENCE_WEIGHT)
				evidenceCooldowns[id] = now
				if Common.IsDebugEnabled() then
					print(string.format(
						"[Bhop] %s perfect jump #%d (ground_ticks=%d) evidence +%.1f",
						id, data.consecutivePerfects, groundTicks, BHOP_EVIDENCE_WEIGHT))
				end
			end
		end
	else
		data.consecutivePerfects = 0
	end

	data.groundTicks = nil
	data.inAir = true
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	clearBhopState(id)
	evidenceCooldowns[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	clearBhopState(id)
	evidenceCooldowns[id] = nil
end)

return Bhop
