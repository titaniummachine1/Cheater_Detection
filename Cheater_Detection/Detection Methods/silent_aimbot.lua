--[[ Cheater Detection - Silent Aimbot Detection (Viewangle Extrapolation) ]]
--
-- Theory: Silent aimbot controls aim for exactly 1 tick (the shot tick).
-- Before and after the shot, the player's real viewangle is in control.
-- We extrapolate the pre-shot trajectory and verify:
--   1. Shot tick deviates from predicted trajectory (aimbot snapped to target)
--   2. Post-shot tick returns to predicted trajectory (aimbot released control)
-- This combination is impossible for a human to replicate because a real
-- flick stays near the target after firing; it never snaps back to the
-- exact predicted pre-shot trajectory within 1 tick.

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Quaternion = require("Cheater_Detection.Utils.Quaternion")
local Logger = require("Cheater_Detection.Utils.Logger")

--[[ Module Declaration ]]
local SilentAimbot = {}

--[[ Configuration ]]
local DETECTION_NAME = "silent_aimbot"
local EVIDENCE_WEIGHT = 25

local MAX_HISTORY_SIZE = 12
local MAX_PENDING_AGE = 3
local MIN_SHOT_DEVIATION = 0.5
local MAX_RETURN_DEVIATION = 1.5
local MIN_PRE_SHOT_SAMPLES = 3

--[[ Per-Player State ]]
local playerAngleHistory = {}
local pendingAnalysis = {}

--[[ Helper Functions ]]

local function angleFoV(a, b)
	local dx = math.sin(math.rad(b.yaw)) * math.cos(math.rad(b.pitch))
		- math.sin(math.rad(a.yaw)) * math.cos(math.rad(a.pitch))
	local dy = math.cos(math.rad(b.yaw)) * math.cos(math.rad(b.pitch))
		- math.cos(math.rad(a.yaw)) * math.cos(math.rad(a.pitch))
	local dz = math.sin(math.rad(b.pitch)) - math.sin(math.rad(a.pitch))

	local dot = 1 - (dx * dx + dy * dy + dz * dz) / 2
	return math.deg(math.acos(math.max(-1, math.min(1, dot))))
end

local function pushAngle(idx, pitch, yaw, roll, tick)
	local history = playerAngleHistory[idx]
	if not history then
		history = {}
		playerAngleHistory[idx] = history
	end

	history[#history + 1] = { pitch = pitch, yaw = yaw, roll = roll, tick = tick }

	while #history > MAX_HISTORY_SIZE do
		table.remove(history, 1)
	end
end

local function collectPreShotHistory(history, shotTick)
	local result = {}
	for i = 1, #history do
		if history[i].tick < shotTick then
			result[#result + 1] = history[i]
		end
	end
	return result
end

local function findAngleAtTick(history, targetTick)
	for i = #history, 1, -1 do
		if history[i].tick == targetTick then
			return history[i]
		end
	end
	return nil
end

local function analyzeShot(shooterIdx, postShotAngle)
	local pending = pendingAnalysis[shooterIdx]
	assert(pending, "analyzeShot: no pending analysis")

	local history = playerAngleHistory[shooterIdx]
	if not history or #history < MIN_PRE_SHOT_SAMPLES + 1 then
		return false, 0, nil
	end

	local shotTick = pending.shotTick
	local shotAngle = findAngleAtTick(history, shotTick)
	if not shotAngle then
		return false, 0, nil
	end

	local preShotHistory = collectPreShotHistory(history, shotTick)
	if #preShotHistory < MIN_PRE_SHOT_SAMPLES then
		return false, 0, nil
	end

	local predictedShotAngle = Quaternion.extrapolateAngle(preShotHistory, 1)
	if not predictedShotAngle then
		return false, 0, nil
	end

	local predictedReturnAngle = Quaternion.extrapolateAngle(preShotHistory, 2)
	if not predictedReturnAngle then
		return false, 0, nil
	end

	local shotDeviation = angleFoV(shotAngle, predictedShotAngle)
	local returnDeviation = angleFoV(postShotAngle, predictedReturnAngle)

	if shotDeviation < MIN_SHOT_DEVIATION then
		return false, 0, nil
	end

	if returnDeviation > MAX_RETURN_DEVIATION then
		return false, 0, nil
	end

	local confidence = math.min(1.0, shotDeviation / 10.0)
		* math.min(1.0, (MAX_RETURN_DEVIATION - returnDeviation) / MAX_RETURN_DEVIATION)

	local reason =
		string.format("Shot deviated %.1f° from predicted, returned within %.1f°", shotDeviation, returnDeviation)

	return true, confidence, reason
end

--[[ Public Functions ]]

function SilentAimbot.Check(player, steamID)
	if not G.Menu.Advanced or not G.Menu.Advanced.SilentAimbot then
		return false
	end

	if not Common.IsValidPlayer(player, true, false) then
		return false
	end

	if not steamID then
		steamID = tostring(Common.GetSteamID64(player))
	end

	local playerIdx = player:GetIndex()
	local currentTick = globals.TickCount()
	local eyeAngles = player:GetEyeAngles()
	assert(eyeAngles, "SilentAimbot.Check: GetEyeAngles returned nil")

	local currentAngle = { pitch = eyeAngles.pitch, yaw = eyeAngles.yaw, roll = eyeAngles.roll or 0 }

	local pending = pendingAnalysis[playerIdx]
	local isAimbot = false
	local confidence = 0
	local reason = nil

	if pending then
		local age = currentTick - pending.shotTick
		if age >= 1 and age <= MAX_PENDING_AGE then
			isAimbot, confidence, reason = analyzeShot(playerIdx, currentAngle)
		end
		pendingAnalysis[playerIdx] = nil
	end

	pushAngle(playerIdx, currentAngle.pitch, currentAngle.yaw, currentAngle.roll, currentTick)

	if isAimbot and confidence > 0 then
		Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT * confidence)

		Logger.Info(
			"SilentAim",
			string.format("%s - %s (confidence: %.0f%%)", player:GetName() or steamID, reason, confidence * 100)
		)

		return true
	end

	return false
end

function SilentAimbot.OnPlayerHurt(shooterEntity, victimEntity)
	if not shooterEntity or not victimEntity then
		return
	end

	local shooterIdx = shooterEntity:GetIndex()
	local victimIdx = victimEntity:GetIndex()

	if shooterIdx == victimIdx then
		return
	end

	local weapon = shooterEntity:GetPropEntity("m_hActiveWeapon")
	if not weapon or not weapon.GetWeaponProjectileType then
		return
	end
	if weapon:GetWeaponProjectileType() ~= 1 then
		return
	end

	local history = playerAngleHistory[shooterIdx]
	if not history or #history == 0 then
		return
	end

	local currentTick = globals.TickCount()
	local latest = history[#history]
	if currentTick - latest.tick > MAX_PENDING_AGE then
		return
	end

	pendingAnalysis[shooterIdx] = {
		shotTick = latest.tick,
		victimIdx = victimIdx,
	}
end

return SilentAimbot
