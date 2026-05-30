--[[ detectors/bhop.lua
     Detects scripted bunnyhops by counting consecutive "perfect" jumps.
     Tracks ground contact ticks on landing, then scores on ground→air transition.
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
	if playerState.pdata and (playerState.pdata.isDormant or not playerState.pdata.isAlive) then
		return false
	end
	return true
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

	if onGround == nil then
		return
	end

	if id == PlayerCache.GetLocalID() and not Common.IsDebugEnabled() then
		return
	end

	local data = playerData[id]
	if not data then
		data = {
			wasOnGround = false,
			groundTicks = 0,
			consecutivePerfects = 0,
			lastJumpTime = nil,
		}
		playerData[id] = data
	end

	local now = globals.RealTime()
	if data.lastJumpTime and (now - data.lastJumpTime) > CHAIN_BREAK_SECONDS then
		data.consecutivePerfects = 0
	end

	if onGround then
		data.groundTicks = data.groundTicks + 1
		data.wasOnGround = true
	else
		if data.wasOnGround then
			data.lastJumpTime = now
			if data.groundTicks >= 0 and data.groundTicks <= MAX_GROUND_TICKS then
				data.consecutivePerfects = data.consecutivePerfects + 1

				if data.consecutivePerfects >= Constants.BHOP_MIN_CONSECUTIVE_SUCCESS then
					local lastEvidence = evidenceCooldowns[id] or 0
					if (now - lastEvidence) >= BHOP_EVIDENCE_COOLDOWN_S then
						Evidence.AddEvidence(id, "bhop", BHOP_EVIDENCE_WEIGHT)
						evidenceCooldowns[id] = now
						if Common.IsDebugEnabled() then
							print(string.format(
								"[Bhop] %s perfect jump #%d (ground_ticks=%d) evidence +%.1f",
								id, data.consecutivePerfects, data.groundTicks, BHOP_EVIDENCE_WEIGHT))
						end
					end
				end
			else
				data.consecutivePerfects = 0
			end

			data.wasOnGround = false
			data.groundTicks = 0
		end
	end
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	playerData[id] = nil
	evidenceCooldowns[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerData[id] = nil
	evidenceCooldowns[id] = nil
end)

return Bhop
