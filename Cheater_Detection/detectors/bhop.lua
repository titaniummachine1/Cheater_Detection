--[[ detectors/bhop.lua
     Detects scripted bunnyhops by counting consecutive "perfect" jumps.
     Uses lazy PlayerData - NO direct entity API calls.
]]

local Constants = require("Cheater_Detection.Core.constants")
local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Events = require("Cheater_Detection.Core.Events")
local PlayerData = require("Cheater_Detection.Utils.PlayerData")

local Bhop = {}

-- Per-player state
local playerData = {}

-- Constant override: some scripts use 2 ticks to bypass simple anticheats
local MAX_GROUND_TICKS = 2
local CHAIN_BREAK_SECONDS = 1.5

function Bhop.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then
		return
	end

	-- Basic check: must be connected to server (but not 100% stability required)
	if not Common.IsPlayerConnected() then
		return
	end

	local id = playerState.id
	local pdata = playerState.pdata
	local data = playerData[id]

	-- Use lazy cached properties from PlayerData (fetched once per tick)
	local isDormant = pdata.isDormant
	local isAlive = pdata.isAlive
	local onGround = pdata.onGround
	local flags = pdata.flags

	-- If PlayerData is stale (old tick), properties return nil
	-- This is safe - we just skip this tick and wait for fresh data
	if isDormant == nil or isAlive == nil or onGround == nil then
		return
	end

	if isDormant then
		if data then
			data.wasOnGround = false
			data.groundTicks = 0
			data.consecutivePerfects = 0
			data.lastJumpTime = nil
		end
		return
	end

	if not isAlive then
		if data then
			data.wasOnGround = false
			data.groundTicks = 0
			data.consecutivePerfects = 0
			data.lastJumpTime = nil
		end
		return
	end

	-- Skip local player unless debug mode is enabled for testing.
	-- Note: We check steamID instead of entity reference (safe)
	if id == tostring(Common.GetSteamID64(entities.GetLocalPlayer())) and not Common.IsDebugEnabled() then
		return
	end

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
		-- Transitioned from ground to air (The moment of the jump)
		if data.wasOnGround then
			data.lastJumpTime = now
			-- Check if it was a "perfect" jump window (0-2 ticks)
			if data.groundTicks >= 0 and data.groundTicks <= MAX_GROUND_TICKS then
				data.consecutivePerfects = data.consecutivePerfects + 1

				-- Threshold for adding suspicion
				if data.consecutivePerfects >= Constants.BHOP_MIN_CONSECUTIVE_SUCCESS then
					local increment = 2
					-- Scale increment for extreme consistency
					if data.consecutivePerfects > 8 then
						increment = 5
					end

					local reason = string.format("Bhop Script (%d perfect jumps)", data.consecutivePerfects)
					DetectorUtils.ApplyPlayerFlag(playerState, increment, nil, reason)

					if Common.IsDebugEnabled() then
						print(string.format("[Bhop] %s perfect jump #%d (ground_ticks=%d) gain=%d", id,
							data.consecutivePerfects, data.groundTicks, increment))
					end
				end
			else
				-- Reset if they stayed on ground too long (not a bhop chain)
				data.consecutivePerfects = 0
			end

			data.wasOnGround = false
			data.groundTicks = 0
		end
	end
end

-- Cleanup
Events.Subscribe("OnPlayerDisconnect", function(id)
	playerData[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerData[id] = nil
end)

return Bhop
