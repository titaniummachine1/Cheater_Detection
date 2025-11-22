--[[
    Silent Aimbot Detection using Viewangle Extrapolation
    Detects silent aim by analyzing if player's aim trajectory "bridges over" aimbot snap
]]

local Quaternion = require("Cheater_Detection.Utils.Quaternion")

local SilentAimbot = {}

-- ============================================================================
-- Configuration
-- ============================================================================

local CONFIG = {
	MIN_FLICK_DELTA = 0.7, -- Minimum angle change to consider as flick (degrees)
	PERFECT_AIM_TOLERANCE = 0.2, -- How close to perfect aim to trigger check (degrees)
	TRAJECTORY_MAINTAINED = 1.0, -- Max FoV delta to consider trajectory maintained (degrees)
	TRAJECTORY_BROKEN = 5.0, -- Min FoV delta to consider trajectory broken (degrees)
	MAX_HISTORY_SIZE = 5, -- Only store 5 ticks, check on 6th (current)
	POS_HISTORY_SIZE = 2, -- Track 2 ticks of hitbox positions
	EXTRAPOLATE_TICKS = 2, -- How far ahead to extrapolate (ticks ahead from tick 5 to current)
}

-- ============================================================================
-- Data Storage
-- ============================================================================

-- Per-player angle history: 5 ticks max
local playerAngleHistory = {} -- [idx] = {{pitch, yaw, roll, tick, shotFired}, ...}

-- Per-player position history: 2 ticks max
local playerPosHistory = {} -- [idx] = {{headPos, bodyPos, tick}, ...}

-- Track last shot data
local lastShot = {
	shooter = nil,
	victim = nil,
	tick = 0,
}

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Calculate FoV between two angles
local function angleFoV(from, to)
	local dx = math.sin(math.rad(to.yaw)) * math.cos(math.rad(to.pitch))
		- math.sin(math.rad(from.yaw)) * math.cos(math.rad(from.pitch))
	local dy = math.cos(math.rad(to.yaw)) * math.cos(math.rad(to.pitch))
		- math.cos(math.rad(from.yaw)) * math.cos(math.rad(from.pitch))
	local dz = math.sin(math.rad(to.pitch)) - math.sin(math.rad(from.pitch))

	return math.deg(math.acos(math.max(-1, math.min(1, 1 - (dx * dx + dy * dy + dz * dz) / 2))))
end

-- Calculate angle to position
local function angleToPosition(fromPos, toPos)
	local delta = toPos - fromPos
	local hyp = math.sqrt(delta.x * delta.x + delta.y * delta.y)
	local yaw = math.deg(math.atan(delta.y, delta.x))
	local pitch = math.deg(math.atan(-delta.z, hyp))
	return { pitch = pitch, yaw = yaw, roll = 0 }
end

-- Add angle to history
local function addAngleHistory(idx, angles, tick, shotFired)
	if not playerAngleHistory[idx] then
		playerAngleHistory[idx] = {}
	end

	table.insert(playerAngleHistory[idx], {
		pitch = angles.pitch,
		yaw = angles.yaw,
		roll = angles.roll or 0,
		tick = tick,
		shotFired = shotFired or false,
	})

	-- Keep only last 5
	while #playerAngleHistory[idx] > CONFIG.MAX_HISTORY_SIZE do
		table.remove(playerAngleHistory[idx], 1)
	end
end

-- Add position to history
local function addPosHistory(idx, headPos, bodyPos, tick)
	if not playerPosHistory[idx] then
		playerPosHistory[idx] = {}
	end

	table.insert(playerPosHistory[idx], {
		headPos = headPos,
		bodyPos = bodyPos,
		tick = tick,
	})

	-- Keep only last 2
	while #playerPosHistory[idx] > CONFIG.POS_HISTORY_SIZE do
		table.remove(playerPosHistory[idx], 1)
	end
end

-- ============================================================================
-- Detection Logic
-- ============================================================================

-- Check if player is using silent aimbot
-- Returns: isAimbot (bool), confidence (0-1), reason (string)
local function checkSilentAimbot(shooterIdx, victimIdx, currentAngles)
	local history = playerAngleHistory[shooterIdx]

	-- Need full history (5 ticks) + current tick
	if not history or #history < 5 then
		return false, 0, "Insufficient history"
	end

	-- Check if last tick (tick 5) was a shot
	if not history[5].shotFired then
		return false, 0, "No shot fired last tick"
	end

	-- Get victim position from history
	local victimPosData = playerPosHistory[victimIdx]
	if not victimPosData or #victimPosData < 1 then
		return false, 0, "No victim position data"
	end

	local victimHeadPos = victimPosData[#victimPosData].headPos
	local victimBodyPos = victimPosData[#victimPosData].bodyPos

	-- STEP 1: Flick Detection (tick 4 → tick 5)
	local tick4Angle = history[4]
	local tick5Angle = history[5] -- Shot tick
	local flickDelta = angleFoV(tick4Angle, tick5Angle)

	if flickDelta < CONFIG.MIN_FLICK_DELTA then
		return false, 0, "Flick too small: " .. string.format("%.2f", flickDelta)
	end

	-- STEP 2: Perfect Aim Check (did tick 5 aim at victim's head?)
	local shooterPos = victimPosData[#victimPosData].bodyPos -- Use shooter's recorded position (approximate)
	local perfectHeadAngle = angleToPosition(shooterPos, victimHeadPos)
	local aimFoV = angleFoV(tick5Angle, perfectHeadAngle)

	if aimFoV > CONFIG.PERFECT_AIM_TOLERANCE then
		-- Also check body as fallback
		local perfectBodyAngle = angleToPosition(shooterPos, victimBodyPos)
		local bodyFoV = angleFoV(tick5Angle, perfectBodyAngle)

		if bodyFoV > CONFIG.PERFECT_AIM_TOLERANCE then
			return false,
				0,
				"Aim not on target: head=" .. string.format("%.2f", aimFoV) .. "° body=" .. string.format(
					"%.2f",
					bodyFoV
				) .. "°"
		end
	end

	-- STEP 3: Extrapolate using ticks 1-4
	local extrapolatedAngle =
		Quaternion.extrapolateAngle({ history[1], history[2], history[3], history[4] }, CONFIG.EXTRAPOLATE_TICKS)

	if not extrapolatedAngle then
		return false, 0, "Extrapolation failed"
	end

	-- STEP 4: Compare extrapolation to current angle (tick 6)
	local trajectoryDelta = angleFoV(extrapolatedAngle, currentAngles)

	-- STEP 5: Determine if trajectory was maintained
	local trajectoryMaintained = trajectoryDelta < CONFIG.TRAJECTORY_MAINTAINED
	local trajectoryBroken = trajectoryDelta > CONFIG.TRAJECTORY_BROKEN

	if trajectoryBroken then
		return false, 0, "Trajectory broken: " .. string.format("%.2f", trajectoryDelta) .. "° (normal flick)"
	end

	if not trajectoryMaintained then
		return false, 0, "Trajectory uncertain: " .. string.format("%.2f", trajectoryDelta) .. "°"
	end

	-- STEP 6: Calculate confidence score (exponential weighting)
	-- Small flicks that return to trajectory = very suspicious
	-- flickDelta range: 0.7° to 20°
	local normalizedFlick = (flickDelta - CONFIG.MIN_FLICK_DELTA) / 5.0
	local flickWeight = math.exp(normalizedFlick)

	-- Trajectory weight: how well did they return to predicted path?
	local trajectoryWeight = 1.0 - (trajectoryDelta / CONFIG.TRAJECTORY_MAINTAINED)

	-- Combined confidence
	local confidence = math.min(1.0, (flickWeight * trajectoryWeight) / 10.0)

	local reason = string.format(
		"Flick: %.2f° | Aim: %.2f° | Trajectory: %.2f° | Confidence: %.1f%%",
		flickDelta,
		aimFoV,
		trajectoryDelta,
		confidence * 100
	)

	-- Flag as aimbot if confidence > 0.5
	return confidence > 0.5, confidence, reason
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Called on player_hurt event
function SilentAimbot.onPlayerHurt(shooterEntity, victimEntity)
	if not shooterEntity or not victimEntity then
		return
	end

	local shooterIdx = shooterEntity:GetIndex()
	local victimIdx = victimEntity:GetIndex()

	lastShot.shooter = shooterIdx
	lastShot.victim = victimIdx
	lastShot.tick = globals.TickCount()

	-- Flag the current last tick in history as a shot
	if playerAngleHistory[shooterIdx] and #playerAngleHistory[shooterIdx] > 0 then
		playerAngleHistory[shooterIdx][#playerAngleHistory[shooterIdx]].shotFired = true
	end
end

-- Called every tick to update history and check for aimbot
-- Returns: isAimbot (bool), confidence (0-1), reason (string)
function SilentAimbot.onTick(entity, eyeAngles, eyePos, headPos, bodyPos)
	local idx = entity:GetIndex()
	local currentTick = globals.TickCount()

	-- Update position history
	addPosHistory(idx, headPos, bodyPos, currentTick)

	-- Check for aimbot BEFORE adding to history
	-- This happens on tick 6, using tick 5 as shot tick
	local isAimbot, confidence, reason = false, 0, ""

	if lastShot.shooter == idx and lastShot.tick == (currentTick - 1) then
		-- Last tick was a shot, check now
		isAimbot, confidence, reason = checkSilentAimbot(idx, lastShot.victim, eyeAngles)
	end

	-- Add current angle to history (will be tick 5 next time)
	addAngleHistory(idx, eyeAngles, currentTick, false)

	return isAimbot, confidence, reason
end

-- Clear history for a player
function SilentAimbot.clearPlayer(idx)
	playerAngleHistory[idx] = nil
	playerPosHistory[idx] = nil
end

return SilentAimbot
