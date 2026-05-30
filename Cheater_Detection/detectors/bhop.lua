--[[ detectors/bhop.lua
     Detects scripted bunnyhops by counting consecutive "perfect" jumps.
     Only tracks AIRBORNE state - ground state is implicit (gaps in tracking).
]]

local Constants           = require("Cheater_Detection.Core.constants")
local Common              = require("Cheater_Detection.Utils.Common")
local DetectorUtils       = require("Cheater_Detection.Utils.DetectorUtils")
local Events              = require("Cheater_Detection.Core.Events")
local PlayerCache         = require("Cheater_Detection.Core.player_cache")

local Bhop                = {}

-- Per-player state: only stored when airborne
-- [id] = { lastAirTick, lastGroundTicks, consecutivePerfects, lastJumpTime }
local playerData          = {}

-- Bhop pattern: 0-2 ticks on ground between jumps
local MAX_GROUND_TICKS    = 2
local CHAIN_BREAK_SECONDS = 1.5


-- Fast check: returns true if player is midair with potential bhop pattern.
-- Gap of 0-2 ticks since last airborne = brief ground contact = potential bhop.
function Bhop.HasWork(playerState)
	if not playerState or not playerState.pdata or not playerState.id then
		return false
	end
	local pdata = playerState.pdata
	-- Only check if player is in air
	if pdata.onGround then return false end
	if pdata.isDormant or not pdata.isAlive then return false end
	local id = playerState.id
	if id:sub(1, 4) == "BOT_" then return false end
	if id == PlayerCache.GetLocalID() and not Common.IsDebugEnabled() then
		return false
	end

	-- Check gap since last airborne - if >2 ticks, they were on ground too long
	local data = playerData[id]
	local curTick = globals.TickCount()
	local lastAirTick = data and data.lastAirTick or 0
	local gapTicks = curTick - lastAirTick
	-- Gap of 1-2 ticks = brief ground contact (potential bhop)
	-- Gap of 0 = same jump (not a new jump yet)
	-- Gap > 2 = too long on ground, not bhopping
	if gapTicks > MAX_GROUND_TICKS + 1 then
		return false
	end

	return true
end

function Bhop.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then
		return
	end

	if not Common.IsPlayerConnected() then
		return
	end

	local id = playerState.id
	local pdata = playerState.pdata

	-- Skip grounded players entirely - we don't store ground state
	if pdata.onGround then
		return
	end

	if pdata.isDormant or not pdata.isAlive then
		playerData[id] = nil
		return
	end

	if id == PlayerCache.GetLocalID() and not Common.IsDebugEnabled() then
		return
	end

	local curTick = globals.TickCount()
	local now = globals.RealTime()

	-- Get or create state
	local data = playerData[id]
	if not data then
		data = {
			lastAirTick = 0,
			consecutivePerfects = 0,
			lastJumpTime = nil,
		}
		playerData[id] = data
	end

	-- Calculate gap since last airborne (how long were they on ground)
	local gapTicks = curTick - data.lastAirTick

	-- Update last airborne tick
	data.lastAirTick = curTick

	-- Chain break timeout
	if data.lastJumpTime and (now - data.lastJumpTime) > CHAIN_BREAK_SECONDS then
		data.consecutivePerfects = 0
	end

	-- Gap of 1-2 ticks = brief ground contact = bhop pattern
	-- Gap of 0 or 1 = first check this jump, or tick-perfect transition
	if gapTicks >= 1 and gapTicks <= MAX_GROUND_TICKS + 1 then
		data.consecutivePerfects = data.consecutivePerfects + 1
		data.lastJumpTime = now

		-- Threshold for adding suspicion
		if data.consecutivePerfects >= Constants.BHOP_MIN_CONSECUTIVE_SUCCESS then
			local increment = 2
			if data.consecutivePerfects > 8 then
				increment = 5
			end

			local reason = string.format("Bhop Script (%d perfect jumps)", data.consecutivePerfects)
			DetectorUtils.ApplyPlayerFlag(playerState, increment, nil, reason)

			if Common.IsDebugEnabled() then
				print(string.format("[Bhop] %s perfect jump #%d (gap=%d ticks) gain=%d", id,
					data.consecutivePerfects, gapTicks, increment))
			end
		end
	elseif gapTicks > MAX_GROUND_TICKS + 1 then
		-- Too long on ground - reset chain
		data.consecutivePerfects = 0
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
