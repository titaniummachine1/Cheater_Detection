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

-- Check for silent aimbot using angle extrapolation
local function checkSilentAimbot(shooterIdx, victimIdx, currentAngles)
	local history = playerAngleHistory[shooterIdx]
	if not history or #history < 3 then
		return false, 0, nil -- Not enough history
	end

	local victimPosHistory = playerPosHistory[victimIdx]
	if not victimPosHistory or #victimPosHistory == 0 then
		return false, 0, nil -- No victim position data
	end

	-- Get victim position (head preferred)
	local victimPos = victimPosHistory[#victimPosHistory].headPos or victimPosHistory[#victimPosHistory].bodyPos
	if not victimPos then
		return false, 0, nil
	end

	-- Find the tick when shot was fired
	local shotIdx = nil
	for i = #history, 1, -1 do
		if history[i].shotFired then
			shotIdx = i
			break
		end
	end

	if not shotIdx or shotIdx < 2 then
		return false, 0, nil -- No shot found or not enough pre-shot history
	end

	-- Use quaternion extrapolation to predict where they SHOULD be looking
	local predicted = Quaternion.extrapolateAngle(history, CONFIG.EXTRAPOLATE_TICKS)
	if not predicted then
		return false, 0, nil
	end

	-- Calculate angle to victim
	local shooterPos = playerPosHistory[shooterIdx]
		and playerPosHistory[shooterIdx][#playerPosHistory[shooterIdx]]
		and playerPosHistory[shooterIdx][#playerPosHistory[shooterIdx]].headPos
	if not shooterPos then
		return false, 0, nil
	end

	local angleToVictim = angleToPosition(shooterPos, victimPos)

	-- Check how close their view was to victim when they shot
	local shotAngles = history[shotIdx]
	local fovToVictim = angleFoV(shotAngles, angleToVictim)

	-- Check deviation from predicted trajectory
	local fovFromPredicted = angleFoV(shotAngles, predicted)

	-- Detection logic:
	-- 1. IMPOSSIBLE: Shot at target behind them (90°+ from predicted trajectory)
	if fovFromPredicted >= CONFIG.IMPOSSIBLE_FLICK then
		return true, 1.0, "Impossible flick (shot behind)"
	end

	-- 2. SILENT AIM: Perfect aim but trajectory was broken
	if fovToVictim < CONFIG.PERFECT_AIM_TOLERANCE and fovFromPredicted > CONFIG.TRAJECTORY_BROKEN then
		local confidence = math.min(1.0, fovFromPredicted / CONFIG.IMPOSSIBLE_FLICK)
		return true,
			confidence,
			string.format("Silent aim (%.1f° snap, %.1f° from predicted)", fovToVictim, fovFromPredicted)
	end

	-- 3. FLICK CHECK: Big flick to target that instantly returns
	local postShotIdx = shotIdx + 1
	if postShotIdx <= #history then
		local postShotAngles = history[postShotIdx]
		local postFov = angleFoV(shotAngles, postShotAngles)

		-- Shot was accurate AND instantly returned to trajectory
		if fovToVictim < CONFIG.PERFECT_AIM_TOLERANCE and postFov > CONFIG.MIN_FLICK_DELTA then
			local confidence = math.min(1.0, postFov / CONFIG.TRAJECTORY_BROKEN)
			return true,
				confidence * 0.7,
				string.format("Snap-back (%.1f° accuracy, %.1f° return)", fovToVictim, postFov)
		end
	end

	return false, 0, nil
end

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
