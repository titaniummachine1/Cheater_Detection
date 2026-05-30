--[[ detectors/bhop.lua
     Detects scripted bunnyhops by counting consecutive "perfect" jumps.
     Tracks ground contact ticks on landing, then scores on ground→air transition.
]]

local Constants     = require("Cheater_Detection.Core.constants")
local Common        = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Events        = require("Cheater_Detection.Core.Events")
local PlayerCache   = require("Cheater_Detection.Core.player_cache")

local Bhop          = {}

local playerData    = {}
local MAX_GROUND_TICKS = 2
local CHAIN_BREAK_SECONDS = 1.5

function Bhop.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then
		return
	end

	if not Common.IsPlayerConnected() then
		return
	end

	local id = playerState.id
	local pdata = playerState.pdata

	local isDormant = pdata.isDormant
	local isAlive = pdata.isAlive
	local onGround = pdata.onGround

	if isDormant == nil or isAlive == nil or onGround == nil then
		return
	end

	-- DEBUG MODE: scan local player for self-test. Off = skip yourself.
	if id == PlayerCache.GetLocalID() and not Common.IsDebugEnabled() then
		return
	end

	if isDormant then
		playerData[id] = nil
		return
	end

	if not isAlive then
		playerData[id] = nil
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
					local increment = 2
					if data.consecutivePerfects > 8 then
						increment = 5
					end

					local reason = string.format("Bhop Script (%d perfect jumps)", data.consecutivePerfects)
					DetectorUtils.ApplyPlayerFlag(playerState, increment, nil, reason)

					if Common.IsDebugEnabled() then
						print(string.format("[Bhop] %s perfect jump #%d (ground_ticks=%d) gain=%d",
							id, data.consecutivePerfects, data.groundTicks, increment))
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
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerData[id] = nil
end)

return Bhop
