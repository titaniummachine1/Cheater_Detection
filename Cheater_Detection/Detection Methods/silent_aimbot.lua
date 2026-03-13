--[[ Cheater Detection - Silent Aimbot Detection (Viewangle Extrapolation) ]]
-- Refactored for Zero-Allocation Per-Frame Path

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Quaternion = require("Cheater_Detection.Utils.Quaternion")
local Logger = require("Cheater_Detection.Utils.Logger")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")

--[[ Module Declaration ]]
local SilentAimbot = {}

--[[ Constants ]]
local DETECTION_NAME = "silent_aimbot"
local EVIDENCE_WEIGHT = 25

local MAX_PENDING_AGE = 3
local MIN_SHOT_DEVIATION = 0.5
local MAX_RETURN_DEVIATION = 1.5
local MIN_PRE_SHOT_SAMPLES = 3

--[[ Register with HistoryManager ]]
HistoryManager.RegisterConsumer(DETECTION_NAME, {
	retentionTicks = 12,
	fields = { HistoryManager.Fields.Angles }
})

--[[ Per-Player Data for analysis context ]]
local pendingAnalysis = {}

--[[ Functions ]]

local function angleFoV(pitch1, yaw1, pitch2, yaw2)
	local r1p, r1y = math.rad(pitch1), math.rad(yaw1)
	local r2p, r2y = math.rad(pitch2), math.rad(yaw2)
	
	local x1 = math.cos(r1p) * math.cos(r1y)
	local y1 = math.cos(r1p) * math.sin(r1y)
	local z1 = math.sin(r1p)

	local x2 = math.cos(r2p) * math.cos(r2y)
	local y2 = math.cos(r2p) * math.sin(r2y)
	local z2 = math.sin(r2p)

	local dot = x1 * x2 + y1 * y2 + z1 * z2
	return math.deg(math.acos(math.max(-1, math.min(1, dot))))
end

local function getPending(idx)
	local p = pendingAnalysis[idx]
	if not p then
		p = { shotTick = 0, victimIdx = 0 }
		pendingAnalysis[idx] = p
	end
	return p
end

local function analyzeShot(steamID, idx, curPitch, curYaw)
	local pending = pendingAnalysis[idx]
	if not pending or pending.shotTick == 0 then return false, 0, nil end

	local state = PlayerState.Get(steamID)
	local history = state and state.History
	if not history then return false, 0, nil end
	
	local count = HistoryManager.GetCount(history)
	if count < MIN_PRE_SHOT_SAMPLES + 1 then return false, 0, nil end

	-- Find shot record
	local shotRecord = nil
	local shotIdx = 0
	for i = count, 1, -1 do
		local rec = HistoryManager.GetAt(history, i)
		if rec and rec.tick == pending.shotTick then
			shotRecord = rec
			shotIdx = i
			break
		end
	end

	if not shotRecord or shotIdx < MIN_PRE_SHOT_SAMPLES then
		return false, 0, nil
	end

	-- Predict shot angle from pre-shot history
	-- history, count, ticksAhead
	local pPitch, pYaw, pRoll = Quaternion.extrapolate(history, shotIdx - 1, 1)
	if not pPitch then return false, 0, nil end

	-- Predict return angle (current tick)
	local rPitch, rYaw, rRoll = Quaternion.extrapolate(history, shotIdx - 1, count - (shotIdx - 1))
	if not rPitch then return false, 0, nil end

	local shotDeviation = angleFoV(shotRecord.angles.pitch, shotRecord.angles.yaw, pPitch, pYaw)
	local returnDeviation = angleFoV(curPitch, curYaw, rPitch, rYaw)

	if shotDeviation < MIN_SHOT_DEVIATION then return false, 0, nil end
	if returnDeviation > MAX_RETURN_DEVIATION then return false, 0, nil end

	local confidence = math.min(1.0, shotDeviation / 10.0)
		* math.min(1.0, (MAX_RETURN_DEVIATION - returnDeviation) / MAX_RETURN_DEVIATION)

	local reason = string.format("Shot deviation: %.1f, Return deviation: %.1f", shotDeviation, returnDeviation)
	return true, confidence, reason
end

--[[ Public Functions ]]

function SilentAimbot.Check(player, steamID)
	assert(player, "SilentAimbot.Check: player missing")
	
	if not G.Menu.Advanced or not G.Menu.Advanced.SilentAimbot then
		return false
	end

	if not Common.IsValidPlayer(player, true, false) then
		return false
	end

	local playerIdx = player:GetIndex()
	local currentTick = globals.TickCount()
	local eyeAngles = player:GetEyeAngles()
	assert(eyeAngles, "SilentAimbot.Check: GetEyeAngles failed")

	local pending = pendingAnalysis[playerIdx]
	local isAimbot = false
	local confidence = 0
	local reason = nil

	if pending and pending.shotTick ~= 0 then
		local age = currentTick - pending.shotTick
		if age >= 1 and age <= MAX_PENDING_AGE then
			isAimbot, confidence, reason = analyzeShot(steamID, playerIdx, eyeAngles.pitch, eyeAngles.yaw)
		end
		pending.shotTick = 0 -- Reset
	end

	if isAimbot and confidence > 0 then
		Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT * confidence)
		Logger.Info("SilentAim", string.format("%s - %s (%.0f%%)", player:GetName(), reason, confidence * 100))
		return true
	end

	return false
end

function SilentAimbot.OnPlayerHurt(shooterEntity, victimEntity)
	if not shooterEntity or not victimEntity then return end

	local shooterIdx = shooterEntity:GetIndex()
	if shooterIdx == victimEntity:GetIndex() then return end

	local weapon = shooterEntity:GetPropEntity("m_hActiveWeapon")
	if not weapon or not weapon.GetWeaponProjectileType then return end
	if weapon:GetWeaponProjectileType() ~= 1 then return end -- Check for bullets

	local steamID = tostring(Common.GetSteamID64(shooterEntity))
	local state = PlayerState.Get(steamID)
	local history = state and state.History
	if not history then return end
	
	local count = HistoryManager.GetCount(history)
	if count == 0 then return end
	
	local latest = HistoryManager.GetAt(history, count)
	if not latest then return end
	
	local currentTick = globals.TickCount()
	if currentTick - latest.tick > MAX_PENDING_AGE then return end

	local pending = getPending(shooterIdx)
	pending.shotTick = latest.tick
	pending.victimIdx = victimEntity:GetIndex()
end

return SilentAimbot
