--[[ detectors/antiaim.lua
     Detects invalid view angles (Rage AA). 
     Triggering this marks the player as CHEATER immediately.
]]

local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local Events = require("Cheater_Detection.Core.Events")

local AntiAim = {}

-- ── Yaw Jitter Detection ──────────────────────────────────────────────────────
-- Classic jitter AA (Lmaobox / rage cheats): yaw snaps ±120-180° every tick,
-- alternating between two positions so the head hitbox is never stable.
-- Detection: find 3 consecutive ticks where the yaw delta alternates sign AND
-- both deltas exceed JITTER_SNAP_DEG, then count events. N events within the
-- window → hard CHEATER flag (same tier as invalid pitch).

local yawHistories = {} -- id -> array of {yaw, tick}, capped at 3
local jitterStates = {} -- id -> {count, windowStart}

local JITTER_SNAP_DEG = 120.0 -- Min yaw delta per tick to count as a snap
local JITTER_REQUIRED = 8 -- Consecutive jitter events before flagging
local JITTER_WINDOW_TICKS = 40 -- ~0.6 s at 66 tick; resets window if exceeded

local function wrapAngle(d)
	return (d + 180) % 360 - 180
end

local function checkYawJitter(id, yaw, curTick)
	if not yawHistories[id] then
		yawHistories[id] = {}
	end

	local hist = yawHistories[id]

	-- Only record one entry per tick (CreateMove may fire multiple times)
	if #hist == 0 or hist[#hist].tick ~= curTick then
		hist[#hist + 1] = { yaw = yaw, tick = curTick }
		if #hist > 3 then
			table.remove(hist, 1)
		end
	end

	if #hist < 3 then
		return false
	end

	local delta1 = wrapAngle(hist[2].yaw - hist[1].yaw)
	local delta2 = wrapAngle(hist[3].yaw - hist[2].yaw)

	-- Jitter: two large swings in opposite directions back-to-back
	local isJitterTick = math.abs(delta1) >= JITTER_SNAP_DEG
		and math.abs(delta2) >= JITTER_SNAP_DEG
		and (delta1 * delta2 < 0)

	if not jitterStates[id] then
		jitterStates[id] = { count = 0, windowStart = curTick }
	end

	local js = jitterStates[id]

	if curTick - js.windowStart > JITTER_WINDOW_TICKS then
		js.count = 0
		js.windowStart = curTick
	end

	if isJitterTick then
		js.count = js.count + 1
		if js.count >= JITTER_REQUIRED then
			js.count = 0
			js.windowStart = curTick
			return true
		end
	end

	return false
end

function AntiAim.ProcessPlayer(playerState)
	assert(playerState, "AntiAim.ProcessPlayer: playerState missing")
	assert(playerState.wrap, "AntiAim.ProcessPlayer: playerState.wrap missing id=" .. tostring(playerState.id))
	assert(playerState.id, "AntiAim.ProcessPlayer: playerState.id missing")

	local entity = playerState.wrap:GetRawEntity()
	if not entity then
		return
	end

	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true

	local isCheater = (playerState.flags & Constants.Flags.CHEATER) ~= 0
	if isCheater and not isDebug then
		return
	end

	if entity == entities.GetLocalPlayer() and not isDebug then
		return
	end

	local angles = playerState.wrap:GetEyeAngles()
	if not angles then
		return
	end

	local pitch = angles.pitch or angles.x
	if pitch == nil then
		return
	end

	local isInvalid = math.abs(pitch) > 89.1 or pitch == 89.0 or pitch == -89.0

	if isInvalid then
		local oldFlags = playerState.flags
		playerState.flags = playerState.flags | Constants.Flags.CHEATER
		playerState.score = 100

		local reason = string.format("Invalid Pitch (%.2f)", pitch)

		Database.UpsertCheater(playerState.id, {
			name = playerState.wrap:GetName(),
			reason = reason,
			flags = playerState.flags,
			score = playerState.score,
		})

		if oldFlags ~= playerState.flags then
			Events.Publish("OnPlayerStateChange", playerState, reason)
		end
	end

	-- ── Yaw Jitter Check ─────────────────────────────────────────────────────
	local yaw = angles.yaw or angles.y
	if yaw ~= nil then
		local curTick = globals.TickCount()
		local hasJitter = checkYawJitter(playerState.id, yaw, curTick)
		if hasJitter then
			local oldFlags = playerState.flags
			playerState.flags = playerState.flags | Constants.Flags.CHEATER
			playerState.score = 100

			local jitterReason = "Yaw Jitter Anti-Aim"

			Database.UpsertCheater(playerState.id, {
				name = playerState.wrap:GetName(),
				reason = jitterReason,
				flags = playerState.flags,
				score = playerState.score,
			})

			if oldFlags ~= playerState.flags then
				Events.Publish("OnPlayerStateChange", playerState, jitterReason)
			end
		end
	end
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	yawHistories[id] = nil
	jitterStates[id] = nil
end)

return AntiAim
