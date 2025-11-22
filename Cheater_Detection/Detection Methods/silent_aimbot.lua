--[[ Cheater Detection - Silent Aimbot Detection (Viewangle Extrapolation) ]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Quaternion = require("Cheater_Detection.Utils.Quaternion")

--[[ Module Declaration ]]
local SilentAimbot = {}

--[[ Configuration ]]
local DETECTION_NAME = "silent_aimbot"
local EVIDENCE_WEIGHT_BASE = 15 -- Moderate-high weight for confirmed detections
local EVIDENCE_WEIGHT_IMPOSSIBLE = 50 -- Max weight for 90°+ impossible shots

local CONFIG = {
	MIN_FLICK_DELTA = 0.7, -- Minimum flick to trigger check
	PERFECT_AIM_TOLERANCE = 0.2, -- How close to perfect aim
	TRAJECTORY_MAINTAINED = 1.0, -- Max delta for maintained trajectory
	TRAJECTORY_BROKEN = 5.0, -- Min delta for broken trajectory
	IMPOSSIBLE_FLICK = 90.0, -- Instant catch for shooting behind
	MAX_HISTORY_SIZE = 5, -- Track 5 ticks per player
	POS_HISTORY_SIZE = 2, -- Track 2 ticks of positions
	EXTRAPOLATE_TICKS = 2, -- Predict 2 ticks ahead
}

--[[ Per-Player State ]]
local playerAngleHistory = {} -- [idx] = {{pitch, yaw, roll, tick, shotFired}, ...}
local playerPosHistory = {} -- [idx] = {{headPos, bodyPos, tick}, ...}
local lastShot = { shooter = nil, victim = nil, tick = 0 }

--[[ Helper Functions ]]

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

	while #playerPosHistory[idx] > CONFIG.POS_HISTORY_SIZE do
		table.remove(playerPosHistory[idx], 1)
	end
end

-- Main detection logic
local function checkSilentAimbot(shooterIdx, victimIdx, currentAngles)
	local history = playerAngleHistory[shooterIdx]

	if not history or #history < 5 then
		return false, 0, "Insufficient history"
	end

	if not history[5].shotFired then
		return false, 0, "No shot fired last tick"
	end

	local victimPosData = playerPosHistory[victimIdx]
	if not victimPosData or #victimPosData < 1 then
		return false, 0, "No victim position data"
	end

	local victimHeadPos = victimPosData[#victimPosData].headPos
	local tick4Angle = history[4]
	local tick5Angle = history[5]
	local flickDelta = angleFoV(tick4Angle, tick5Angle)

	-- INSTANT CATCH: Shooting behind (>=90° flick)
	if flickDelta >= CONFIG.IMPOSSIBLE_FLICK then
		return true, 1.0, string.format("Impossible shot (%.0f° flick)", flickDelta)
	end

	if flickDelta < CONFIG.MIN_FLICK_DELTA then
		return false, 0, nil
	end

	-- Check perfect aim (simplified - just check head FoV)
	local shooterPos = victimPosData[#victimPosData].bodyPos
	local perfectHeadAngle = angleToPosition(shooterPos, victimHeadPos)
	local aimFoV = angleFoV(tick5Angle, perfectHeadAngle)

	if aimFoV > CONFIG.PERFECT_AIM_TOLERANCE then
		return false, 0, nil
	end

	-- Extrapolate trajectory
	local extrapolatedAngle =
		Quaternion.extrapolateAngle({ history[1], history[2], history[3], history[4] }, CONFIG.EXTRAPOLATE_TICKS)

	if not extrapolatedAngle then
		return false, 0, nil
	end

	local trajectoryDelta = angleFoV(extrapolatedAngle, currentAngles)

	if trajectoryDelta > CONFIG.TRAJECTORY_BROKEN then
		return false, 0, nil -- Normal flick
	end

	if trajectoryDelta >= CONFIG.TRAJECTORY_MAINTAINED then
		return false, 0, nil -- Uncertain
	end

	-- Calculate confidence
	local normalizedFlick = (flickDelta - CONFIG.MIN_FLICK_DELTA) / 5.0
	local flickWeight = math.exp(normalizedFlick)
	local trajectoryWeight = 1.0 - (trajectoryDelta / CONFIG.TRAJECTORY_MAINTAINED)
	local confidence = math.min(1.0, (flickWeight * trajectoryWeight) / 10.0)

	if confidence > 0.5 then
		local reason =
			string.format("Flick: %.1f° | Aim: %.2f° | Trajectory: %.2f°", flickDelta, aimFoV, trajectoryDelta)
		return true, confidence, reason
	end

	return false, 0, nil
end

--[[ Public API ]]

-- Main check function (called every tick from Main.lua)
function SilentAimbot.Check(player)
	-- Skip if detection disabled
	if not G.Menu.Advanced or not G.Menu.Advanced.SilentAimbot then
		return false
	end

	-- Validate player
	if not Common.IsValidPlayer(player, true, false) then
		return false
	end

	local steamID = Common.GetSteamID64(player)
	if not Common.IsSteamID64(steamID) then
		return false
	end
	steamID = tostring(steamID)

	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	local playerIdx = player:GetIndex()
	local currentTick = globals.TickCount()
	local eyeAngles = player:GetEyeAngles()
	local headPos = player:GetHitboxPos(1)
	local bodyPos = player:GetAbsOrigin()

	-- Update position history
	addPosHistory(playerIdx, headPos, bodyPos, currentTick)

	-- Check if last tick was a shot
	local isAimbot, confidence, reason = false, 0, nil
	if lastShot.shooter == playerIdx and lastShot.tick == (currentTick - 1) then
		if G.Menu.Advanced.debug then
			print(
				string.format("[SilentAim] Checking player %s (idx %d) who shot last tick", player:GetName(), playerIdx)
			)
		end
		isAimbot, confidence, reason = checkSilentAimbot(playerIdx, lastShot.victim, eyeAngles)
	end

	-- Add current angle to history
	addAngleHistory(playerIdx, eyeAngles, currentTick, false)

	-- Add evidence if detected
	if isAimbot then
		local weight = (confidence >= 1.0) and EVIDENCE_WEIGHT_IMPOSSIBLE or EVIDENCE_WEIGHT_BASE
		Evidence.AddEvidence(steamID, DETECTION_NAME, weight * confidence)

		if G.Menu.Advanced.debug then
			print(string.format("[SilentAim] %s - %s (confidence: %.0f%%)", player:GetName(), reason, confidence * 100))
		end

		return true
	end

	return false
end

-- Event handler for player_hurt (called from Main.lua event handler)
function SilentAimbot.OnPlayerHurt(shooterEntity, victimEntity)
	if not shooterEntity or not victimEntity then
		return
	end

	local shooterIdx = shooterEntity:GetIndex()
	local victimIdx = victimEntity:GetIndex()

	lastShot.shooter = shooterIdx
	lastShot.victim = victimIdx
	lastShot.tick = globals.TickCount()

	if G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug then
		print(
			string.format(
				"[SilentAim] OnPlayerHurt: shooter idx=%d, victim idx=%d, tick=%d",
				shooterIdx,
				victimIdx,
				lastShot.tick
			)
		)
	end

	-- Flag the last tick in history as a shot
	if playerAngleHistory[shooterIdx] and #playerAngleHistory[shooterIdx] > 0 then
		playerAngleHistory[shooterIdx][#playerAngleHistory[shooterIdx]].shotFired = true
		if G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug then
			print(
				string.format(
					"[SilentAim] Flagged tick %d as shot for idx %d (history size: %d)",
					playerAngleHistory[shooterIdx][#playerAngleHistory[shooterIdx]].tick,
					shooterIdx,
					#playerAngleHistory[shooterIdx]
				)
			)
		end
	end
end

return SilentAimbot
