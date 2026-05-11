--[[ detectors/silent_aim.lua
     Silent Aimbot Detector — 2-tick view-angle extrapolation.
     Uses shared tick-bucket history from HistoryManager.

     Algorithm:
       - Stage 3: Push angles to current bucket via HistoryManager.PushAngles()
       - On player_hurt: Record shot angle, build predictions from history
       - On ProcessPlayer: Consume accumulated score

     Uses shared bucket structure for angle storage instead of per-player tables.
]]

local Events = require("Cheater_Detection.Core.Events")
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Constants = require("Cheater_Detection.Core.constants")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local HitscanInfo = require("Cheater_Detection.Utils.HitscanInfo")

local SilentAim = {}

local MIN_SNAP_DEGREES = 2.0
local SMALL_SNAP_DECAY = 0.0625

local HARD_SNAP_CHEATER_DEGREES = 90.0
local INSTA_KILL_ALIGN_MAX_DEGREES = 5.0
local INSTA_KILL_HEAD_MAX_ERROR_DEGREES = 6.0
local INSTA_KILL_DIR_MIN = 0.5

local SNIPER_HEAD_MAX_ERROR_DEGREES = 6.0
local ALIGN_TIGHT_MAX_DEGREES = 2.0
local ALIGN_FLOOR = 0.05
local SNAP_STAGE1_MAX_DEGREES = 15.0
local SNAP_STAGE1_OUTPUT = 0.20
local SNAP_STAGE1_LOG_K = 3.0
local SNAP_STAGE2_MAX_DEGREES = 30.0
local SNAP_STAGE2_OUTPUT = 0.40
local SNAP_STAGE2_LOG_K = 2.0
local SNAP_SPIKE_EXP_K = 5.0
local DIR_MIN_DELTA_DEGREES = 7.0
local DISCONT_SNAP_MIN_DEGREES = 45.0
local DISCONT_AIMERR_MIN_DEGREES = 25.0

local SANITY_MAX_DEGREES = 16.0
local LILAC_WINDOW_TICKS = 33
local LILAC_SNAP_DELTA1_DEGREES = 10.0
local LILAC_SNAP_DELTA2_DEGREES = 5.0
local LILAC_SNAP_RATIO1 = 0.2
local LILAC_SNAP_RATIO2 = 0.1
local LILAC_RETURN_MIN_SNAP_DEGREES = 10.0
local LILAC_RETURN_ALIGN_MAX_DEGREES = 2.0
local LILAC_RETURN_DIR_MIN = 0.5

local LILAC_FLAG_SNAP = 1
local LILAC_FLAG_SNAP2 = 2
local LILAC_FLAG_RETURN = 4

local LILAC_GAIN_SNAP = 2.0
local LILAC_GAIN_SNAP2 = 1.2
local LILAC_GAIN_RETURN = 1.0

local playerData = {}
local NON_SNIPER_COOLDOWN_TICKS = 6
local lastNonSniperTickByUserID = {}

local debugFilterWindowStart = 0
local debugFilterWindowCount = 0
local DEBUG_FILTER_MAX_PER_SEC = 0

local debugRecordWindowStart = 0
local debugRecordWindowCount = 0
local DEBUG_RECORD_MAX_PER_SEC = 8

local function canPrintFiltered(now)
	if DEBUG_FILTER_MAX_PER_SEC <= 0 then
		return false
	end
	if now - debugFilterWindowStart >= 1.0 then
		debugFilterWindowStart = now
		debugFilterWindowCount = 0
	end
	if debugFilterWindowCount >= DEBUG_FILTER_MAX_PER_SEC then
		return false
	end
	debugFilterWindowCount = debugFilterWindowCount + 1
	return true
end

local function canPrintRecorded(now)
	if now - debugRecordWindowStart >= 1.0 then
		debugRecordWindowStart = now
		debugRecordWindowCount = 0
	end
	if debugRecordWindowCount >= DEBUG_RECORD_MAX_PER_SEC then
		return false
	end
	debugRecordWindowCount = debugRecordWindowCount + 1
	return true
end

local wrapAngle = Common.wrapAngle
local angularDist = Common.angularDist

local function snapWeight(shotDev)
	if type(shotDev) ~= "number" then
		return 0.0
	end
	if shotDev <= MIN_SNAP_DEGREES then
		return 0.0
	end

	local stage1Max = SNAP_STAGE1_MAX_DEGREES
	if stage1Max <= MIN_SNAP_DEGREES then
		stage1Max = MIN_SNAP_DEGREES + 0.001
	end

	local stage2Max = SNAP_STAGE2_MAX_DEGREES
	if stage2Max <= stage1Max then
		stage2Max = stage1Max + 0.001
	end

	local stage1Out = math.max(0.0, math.min(1.0, SNAP_STAGE1_OUTPUT))
	local stage2Out = math.max(stage1Out, math.min(1.0, SNAP_STAGE2_OUTPUT))

	if shotDev <= stage1Max then
		local t = (shotDev - MIN_SNAP_DEGREES) / (stage1Max - MIN_SNAP_DEGREES)
		t = math.max(0.0, math.min(1.0, t))
		local k = math.max(0.0001, SNAP_STAGE1_LOG_K)
		local logScaled = math.log(1.0 + t * k) / math.log(1.0 + k)
		return stage1Out * logScaled
	end

	if shotDev <= stage2Max then
		local t = (shotDev - stage1Max) / (stage2Max - stage1Max)
		t = math.max(0.0, math.min(1.0, t))
		local k = math.max(0.0001, SNAP_STAGE2_LOG_K)
		local logScaled = math.log(1.0 + t * k) / math.log(1.0 + k)
		return stage1Out + (stage2Out - stage1Out) * logScaled
	end

	if shotDev >= HARD_SNAP_CHEATER_DEGREES then
		return 1.0
	end

	local denom = HARD_SNAP_CHEATER_DEGREES - stage2Max
	if denom <= 0.0 then
		return stage2Out
	end

	local t = (shotDev - stage2Max) / denom
	t = math.max(0.0, math.min(1.0, t))

	local k = math.max(0.0001, SNAP_SPIKE_EXP_K)
	local expScaled = (math.exp(k * t) - 1.0) / (math.exp(k) - 1.0)
	return stage2Out + (1.0 - stage2Out) * expScaled
end

local getAngleToPos = Common.angleToPos
local getAngleToXYZ = Common.angleToXYZ

local function bestAimDistToTarget(eyePos, headPos, bodyPos, pitch, yaw)
	if not eyePos then
		return nil
	end

	local best = nil
	if headPos then
		local hp, hy = getAngleToPos(eyePos, headPos)
		best = angularDist(pitch, yaw, hp, hy)
	end
	if bodyPos then
		local bp, by = getAngleToPos(eyePos, bodyPos)
		local bodyErr = angularDist(pitch, yaw, bp, by)
		if best == nil or bodyErr < best then
			best = bodyErr
		end
	end
	return best
end

local function lilacAimbotHeuristics(id, shotOffset, shotTick, shotAngles, eyePos, headPos, bodyPos)
	if not id or type(shotOffset) ~= "number" or type(shotTick) ~= "number" then
		return 0.0, 0.0, 0.0, 0
	end
	if not shotAngles or type(shotAngles.pitch) ~= "number" or type(shotAngles.yaw) ~= "number" then
		return 0.0, 0.0, 0.0, 0
	end
	if not eyePos or (not headPos and not bodyPos) then
		return 0.0, 0.0, 0.0, 0
	end

	local flags = 0
	local maxDelta = 0.0
	local totalDelta = 0.0

	local aimDist = bestAimDistToTarget(eyePos, headPos, bodyPos, shotAngles.pitch, shotAngles.yaw)
	if aimDist == nil then
		return 0.0, 0.0, 0.0, 0
	end

	local langPitch = shotAngles.pitch
	local langYaw = shotAngles.yaw
	local lastAimDist = aimDist

	for i = 1, LILAC_WINDOW_TICKS do
		local bucket = HistoryManager.GetBucketAt(shotOffset + i)
		if not bucket or bucket._tick ~= (shotTick - i) then
			break
		end

		local ang = HistoryManager.GetPlayerFieldAt(bucket, id, HistoryManager.Fields.Angles)
		if ang and type(ang.pitch) == "number" and type(ang.yaw) == "number" then
			local p = ang.pitch
			local y = wrapAngle(ang.yaw)

			local tdelta = angularDist(langPitch, langYaw, p, y)
			if tdelta > maxDelta then
				maxDelta = tdelta
			end
			totalDelta = totalDelta + tdelta

			local laimdist = bestAimDistToTarget(eyePos, headPos, bodyPos, p, y)
			if laimdist ~= nil and laimdist > 0.0001 then
				if (lastAimDist < (laimdist * LILAC_SNAP_RATIO1)) and (tdelta > LILAC_SNAP_DELTA1_DEGREES) then
					flags = flags | LILAC_FLAG_SNAP
				end
				if (lastAimDist < (laimdist * LILAC_SNAP_RATIO2)) and (tdelta > LILAC_SNAP_DELTA2_DEGREES) then
					flags = flags | LILAC_FLAG_SNAP2
				end
				lastAimDist = laimdist
			end

			langPitch = p
			langYaw = y
		end
	end

	local gain = 0.0
	if (flags & LILAC_FLAG_SNAP) ~= 0 then
		gain = gain + LILAC_GAIN_SNAP
	end
	if (flags & LILAC_FLAG_SNAP2) ~= 0 then
		gain = gain + LILAC_GAIN_SNAP2
	end

	return gain, maxDelta, totalDelta, flags
end

local TF_PROJECTILE_BULLET = 1
local TF_CLASS_SNIPER = 2
local TF_CLASS_SPY = 8

local AIMERR_MIN_WEIGHT = 0.1
local AIMERR_MIN_AT_DEGREES = 5.0

local function aimErrorWeight(errDegrees)
	if type(errDegrees) ~= "number" then
		return 0.0
	end
	if errDegrees <= 0 then
		return 1.0
	end
	if errDegrees >= AIMERR_MIN_AT_DEGREES then
		return AIMERR_MIN_WEIGHT
	end
	local t = math.log(1.0 + errDegrees) / math.log(1.0 + AIMERR_MIN_AT_DEGREES)
	return 1.0 - (1.0 - AIMERR_MIN_WEIGHT) * t
end

local function getHitboxCenter(ent, hitboxIndex)
	if not ent or not ent.GetHitboxes then
		return nil
	end
	local hitboxes = ent:GetHitboxes()
	if type(hitboxes) ~= "table" then
		return nil
	end
	local hb = hitboxes[hitboxIndex]
	if type(hb) ~= "table" then
		return nil
	end
	local mins = hb[1]
	local maxs = hb[2]
	if not mins or not maxs then
		return nil
	end
	if type(mins.x) ~= "number" or type(mins.y) ~= "number" or type(mins.z) ~= "number" then
		return nil
	end
	if type(maxs.x) ~= "number" or type(maxs.y) ~= "number" or type(maxs.z) ~= "number" then
		return nil
	end
	return Vector3((mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5, (mins.z + maxs.z) * 0.5)
end

local function tryFindAnyEnemy()
	local localPly = entities.GetLocalPlayer()
	if not localPly or not localPly:IsValid() then
		return nil
	end
	local myTeam = localPly:GetTeamNumber()
	local players = entities.FindByClass("CTFPlayer") or {}
	for i = 1, #players do
		local p = players[i]
		if p and p:IsValid() and p:IsPlayer() and p:IsAlive() and not p:IsDormant() then
			local team = p:GetTeamNumber()
			if team and team ~= myTeam and team ~= 1 then
				return p
			end
		end
	end
	return nil
end

local function simulateSilentAimLocal(playerState, pdata)
	if not Common.IsDebugEnabled() then
		return
	end
	if not (G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.SilentAimSimulate) then
		return
	end
	if not playerState or not playerState.wrap then
		return
	end
	local localEnt = entities.GetLocalPlayer()
	if not localEnt or not localEnt:IsValid() then
		return
	end
	local ent = playerState.wrap:GetRawEntity()
	if not ent or not ent:IsValid() then
		return
	end
	if ent:GetIndex() ~= localEnt:GetIndex() then
		return
	end

	G.Menu.Advanced.SilentAimSimulate = false

	local curTick = globals.TickCount()
	if HistoryManager.GetRingCount() < 8 then
		return
	end

	local victim = tryFindAnyEnemy()
	if not victim then
		return
	end

	local eyePos = playerState.wrap:GetEyePos()
	if not eyePos then
		return
	end

	local victimID = tostring(Common.GetSteamID64(victim))
	if not victimID then
		return
	end

	local vOrigin = victim:GetAbsOrigin()
	local vViewOffset = victim:GetPropVector("localdata", "m_vecViewOffset[0]")
	local victimEyePos = nil
	if vOrigin and vViewOffset then
		victimEyePos = vOrigin + vViewOffset
	end

	local victimHeadPos = getHitboxCenter(victim, 1) or victimEyePos
	local victimBodyPos = getHitboxCenter(victim, 4)
	if not victimBodyPos and vOrigin then
		victimBodyPos = vOrigin + Vector3(0, 0, 40)
	end
	if not victimHeadPos then
		return
	end

	local targetPitch, targetYaw = getAngleToPos(eyePos, victimHeadPos)
	local basePitch = targetPitch
	local baseYaw0 = wrapAngle(targetYaw - 83.0)

	local function setAnglesAt(offset, pitch, yaw)
		HistoryManager.DebugSetPlayerFieldAt(offset, playerState.id, HistoryManager.Fields.Angles,
			{ pitch = pitch, yaw = yaw })
	end

	setAnglesAt(6, basePitch, baseYaw0)
	setAnglesAt(5, basePitch, baseYaw0 + 1.0)
	setAnglesAt(4, basePitch, baseYaw0 + 2.0)
	setAnglesAt(3, targetPitch, targetYaw)
	setAnglesAt(2, basePitch, baseYaw0 + 4.0)
	setAnglesAt(1, basePitch, baseYaw0 + 5.0)
	setAnglesAt(0, basePitch, baseYaw0 + 6.0)

	local shotTick = HistoryManager.GetTickAt(3)
	if not shotTick then
		return
	end

	pdata.shotPending = {
		shotTick = shotTick,
		victimID = victimID,
		weaponID = 17,
		weaponClass = "CTFSniperRifle",
		projType = nil,
		weaponSpread = 0.0,
		weaponName = "sim_sniper",
		crit = false,
		minicrit = false,
		damage = 50,
		victimHealthAfter = 100,
		shooterEyePos = eyePos,
		victimEyePos = victimEyePos,
		victimHeadPos = victimHeadPos,
		victimBodyPos = victimBodyPos,
		victimOrigin = vOrigin,
	}
end

local function analyzePendingShot(playerState, ply, pdata, pending, curTick)
	if not playerState or not ply or not pdata or not pending then
		return
	end

	local id = playerState.id

	local attackerClass = ply:GetPropInt("m_iClass")
	local debugInterested = Common.IsDebugEnabled() and
		(attackerClass == TF_CLASS_SNIPER or attackerClass == TF_CLASS_SPY)

	if debugInterested then
		print(string.format("[SilentAim] Analyzing shot for %s (tick %d)", id, pending.shotTick))
	end

	local shotOffset = curTick - pending.shotTick
	local shotBucket = HistoryManager.GetBucketAt(shotOffset)
	if not shotBucket or shotBucket._tick ~= pending.shotTick then
		return
	end

	local shotAngles = HistoryManager.GetPlayerFieldAt(shotBucket, id, HistoryManager.Fields.Angles)
	if not shotAngles then
		return
	end
	if type(shotAngles.pitch) ~= "number" or type(shotAngles.yaw) ~= "number" then
		return
	end
	if math.abs(shotAngles.pitch) > 180 or math.abs(shotAngles.yaw) > 1000000 then
		return
	end
	shotAngles = { pitch = shotAngles.pitch, yaw = wrapAngle(shotAngles.yaw) }

	if debugInterested then
		print(string.format(
			"[SilentAim] shot context id=%s weaponid=%s projType=%s class=%s damage=%s",
			id,
			tostring(pending.weaponID),
			tostring(pending.projType),
			tostring(pending.weaponClass),
			tostring(pending.damage)
		))
	end

	local sanityFactor = 1.0
	local bestAimError = nil

	local headPos = pending.victimHeadPos or pending.victimEyePos
	local bodyPos = pending.victimBodyPos
	if not bodyPos and pending.victimOrigin then
		bodyPos = pending.victimOrigin + Vector3(0, 0, 40)
	end

	local eyePos = pending.shooterEyePos
		or HistoryManager.GetPlayerFieldAt(shotBucket, id, HistoryManager.Fields.EyePosition)
		or playerState.wrap:GetEyePos()

	local aimedAtTarget = false
	if eyePos then
		if headPos then
			local p, y = getAngleToPos(eyePos, headPos)
			local headErr = angularDist(shotAngles.pitch, shotAngles.yaw, p, y)
			bestAimError = headErr
			if headErr < SANITY_MAX_DEGREES then
				aimedAtTarget = true
			end
		end
		if not aimedAtTarget and bodyPos then
			local p, y = getAngleToPos(eyePos, bodyPos)
			local bodyErr = angularDist(shotAngles.pitch, shotAngles.yaw, p, y)
			if bestAimError == nil or bodyErr < bestAimError then
				bestAimError = bodyErr
			end
			if bodyErr < SANITY_MAX_DEGREES then
				aimedAtTarget = true
			end
		end
	else
		aimedAtTarget = true
	end

	if not aimedAtTarget and attackerClass ~= TF_CLASS_SNIPER and attackerClass ~= TF_CLASS_SPY then
		sanityFactor = 0.15
		if Common.IsDebugEnabled() then
			print(string.format("[SilentAim] %s sanity miss (outside %.0f° bubble)", id, SANITY_MAX_DEGREES))
		end
	end

	-- 1. Gather pre-shot history for prediction (up to 5 clean ticks)
	local historyAngles = {}
	local historyTicks = {}
	local offset = shotOffset + 1
	while #historyAngles < 5 and offset < HistoryManager.GetRingCount() do
		local bucket = HistoryManager.GetBucketAt(offset)
		if not bucket then
			break
		end
		local data = HistoryManager.GetPlayerFieldAt(bucket, id, HistoryManager.Fields.Angles)
		if data and type(data.pitch) == "number" and type(data.yaw) == "number" then
			if math.abs(data.pitch) <= 180 and math.abs(data.yaw) <= 1000000 then
				data = { pitch = data.pitch, yaw = wrapAngle(data.yaw) }
			else
				data = nil
			end
		else
			data = nil
		end
		-- Skip buckets with damageDealt to keep prediction clean.
		-- Also ensures we exclude the "current" tick since we are looking from shotOffset+1 onwards.
		if data and not (bucket[id] and bucket[id].damageDealt) then
			table.insert(historyAngles, data)
			table.insert(historyTicks, bucket._tick)
		end
		offset = offset + 1
	end

	if #historyAngles < 2 then
		if Common.IsDebugEnabled() then
			print(string.format("[SilentAim] %s extrapolation failed (only %d clean history ticks)", id, #historyAngles))
		end
		return
	end

	-- 2. Predict angular velocity (average over history)
	local totalVPitch, totalVYaw = 0, 0
	local samples = 0
	for i = 1, #historyAngles - 1 do
		local a1 = historyAngles[i]
		local a2 = historyAngles[i + 1]
		local dt = historyTicks[i] - historyTicks[i + 1]
		if dt > 0 then
			totalVPitch = totalVPitch + wrapAngle(a1.pitch - a2.pitch) / dt
			totalVYaw = totalVYaw + wrapAngle(a1.yaw - a2.yaw) / dt
			samples = samples + 1
		end
	end

	if samples == 0 then
		return
	end

	local avgVPitch = totalVPitch / samples
	local avgVYaw = totalVYaw / samples

	-- 3. Predict shot tick angles from the most recent clean history tick
	local mostRecentClean = historyAngles[1]
	local dtToShot = pending.shotTick - historyTicks[1]
	local predShotPitch = mostRecentClean.pitch + (avgVPitch * dtToShot)
	local predShotYaw = mostRecentClean.yaw + (avgVYaw * dtToShot)

	-- 4. Calculate deviation on shot tick
	local shotDev = angularDist(shotAngles.pitch, shotAngles.yaw, predShotPitch, predShotYaw)

	-- Minimum snap threshold to avoid noise
	if shotDev < MIN_SNAP_DEGREES then
		local now = globals.RealTime()
		if (now - (pdata.lastSmallSnapDecay or 0)) >= 1.0 and (playerState.score or 0) > 0 then
			DetectorUtils.ApplyPlayerFlag(playerState, -SMALL_SNAP_DECAY, nil, "SilentAim decay")
			pdata.lastSmallSnapDecay = now
		end
		if debugInterested then
			print(string.format("[SilentAim] %s snap too small: %.1f° (min %.1f°)", id, shotDev, MIN_SNAP_DEGREES))
		end
		return
	end

	-- 5. Alignment check: compare the player's viewangles 1-3 ticks AFTER the damage
	-- to what we predicted their viewangles would be (continued motion model).
	local bestAlignDev = nil
	local bestAlignTick = nil
	local bestDirFactor = 0.0
	local bestDirMeaningful = false
	local alignDev1 = nil
	local dirFactor1 = nil
	local dirMeaningful1 = nil

	local prevActualAngles = shotAngles
	local prevPredPitch = predShotPitch
	local prevPredYaw = predShotYaw

	for k = 1, 3 do
		local postTick = pending.shotTick + k
		local postShotBucket = HistoryManager.GetBucketAt(shotOffset - k)
		if postShotBucket and postShotBucket._tick == postTick then
			if not (postShotBucket[id] and postShotBucket[id].damageDealt) then
				local postShotAngles = HistoryManager.GetPlayerFieldAt(postShotBucket, id, HistoryManager.Fields.Angles)
				if postShotAngles and type(postShotAngles.pitch) == "number" and type(postShotAngles.yaw) == "number" then
					postShotAngles = { pitch = postShotAngles.pitch, yaw = wrapAngle(postShotAngles.yaw) }

					local dtToPost = postTick - historyTicks[1]
					local predPostPitch = mostRecentClean.pitch + (avgVPitch * dtToPost)
					local predPostYaw = mostRecentClean.yaw + (avgVYaw * dtToPost)

					local alignDev = angularDist(postShotAngles.pitch, postShotAngles.yaw, predPostPitch, predPostYaw)

					local actualDPitch = wrapAngle(postShotAngles.pitch - prevActualAngles.pitch)
					local actualDYaw = wrapAngle(postShotAngles.yaw - prevActualAngles.yaw)
					local predDPitch = wrapAngle(predPostPitch - prevPredPitch)
					local predDYaw = wrapAngle(predPostYaw - prevPredYaw)

					local actualLen = math.sqrt(actualDPitch * actualDPitch + actualDYaw * actualDYaw)
					local predLen = math.sqrt(predDPitch * predDPitch + predDYaw * predDYaw)
					local dirFactor = 0.0
					local dirMeaningful = (actualLen >= DIR_MIN_DELTA_DEGREES) and (predLen >= DIR_MIN_DELTA_DEGREES)
					if dirMeaningful then
						local dot = actualDPitch * predDPitch + actualDYaw * predDYaw
						dirFactor = math.max(0.0, math.min(1.0, dot / (actualLen * predLen)))
					else
						dirFactor = 0.5
					end

					if k == 1 then
						alignDev1 = alignDev
						dirFactor1 = dirFactor
						dirMeaningful1 = dirMeaningful
					end

					if (not bestAlignDev)
						or alignDev < bestAlignDev
						or (alignDev == bestAlignDev and (dirMeaningful and not bestDirMeaningful))
						or (alignDev == bestAlignDev and dirMeaningful == bestDirMeaningful and dirFactor > bestDirFactor)
					then
						bestAlignDev = alignDev
						bestAlignTick = postTick
						bestDirFactor = dirFactor
						bestDirMeaningful = dirMeaningful
					end

					prevActualAngles = postShotAngles
					prevPredPitch = predPostPitch
					prevPredYaw = predPostYaw
				end
			end
		end
	end

	if not bestAlignDev then
		bestAlignDev = shotDev
		bestAlignTick = pending.shotTick
		bestDirFactor = 0.5
		bestDirMeaningful = false
	end

	local alignDev = bestAlignDev
	local alignTick = bestAlignTick
	local dirFactor = bestDirFactor
	local dirMeaningful = bestDirMeaningful

	-- 6. Score calculation
	local snap01 = snapWeight(shotDev)

	local alignWeight = 0.0
	if alignDev <= ALIGN_TIGHT_MAX_DEGREES then
		local t = 1.0 - (alignDev / ALIGN_TIGHT_MAX_DEGREES)
		alignWeight = ALIGN_FLOOR + (1.0 - ALIGN_FLOOR) * (t * t)
	else
		local excess = alignDev - ALIGN_TIGHT_MAX_DEGREES
		local denom = 1.0 + math.log(1.0 + excess * 2.0)
		alignWeight = ALIGN_FLOOR / (denom * denom)
	end

	local scoreGain = 0.0
	local headError = nil
	local nonSniperBestAimError = bestAimError
	local aimFactor = 0.0
	if bestAimError ~= nil then
		aimFactor = aimErrorWeight(bestAimError)
	end
	local discontGain = 0.0
	if not aimedAtTarget and bestAimError ~= nil and bestAimError >= DISCONT_AIMERR_MIN_DEGREES and shotDev >= DISCONT_SNAP_MIN_DEGREES then
		local snapExcess = shotDev - DISCONT_SNAP_MIN_DEGREES
		local snapHard = 1.0 - math.exp(-snapExcess / 10.0)
		snapHard = math.max(0.0, math.min(1.0, snapHard))
		local aimExcess = bestAimError - DISCONT_AIMERR_MIN_DEGREES
		local aimHard = 1.0 - math.exp(-aimExcess / 10.0)
		aimHard = math.max(0.0, math.min(1.0, aimHard))
		discontGain = (shotDev ^ 1.0) * (snapHard ^ 2.0) * (aimHard ^ 2.0) * 0.35
		discontGain = math.min(discontGain, 6.0)
	end

	if shotDev >= HARD_SNAP_CHEATER_DEGREES and sanityFactor >= 1.0 then
		local headOk = (nonSniperBestAimError ~= nil and nonSniperBestAimError <= INSTA_KILL_HEAD_MAX_ERROR_DEGREES)
		if alignDev <= INSTA_KILL_ALIGN_MAX_DEGREES and dirMeaningful and dirFactor >= INSTA_KILL_DIR_MIN and headOk then
			local reason = string.format("Insta kill (%.1f° snap, %.1f° align, dir=%.2f)", shotDev, alignDev, dirFactor)
			DetectorUtils.ApplyPlayerFlag(playerState, 100, Constants.Flags.CHEATER, reason)
			return
		end
	end

	if shotDev >= HARD_SNAP_CHEATER_DEGREES and sanityFactor >= 1.0 and alignDev <= INSTA_KILL_ALIGN_MAX_DEGREES then
		local reason = string.format("Guaranteed aimbot (%.1f° snap, %.1f° align, dir=%.2f)", shotDev, alignDev,
			dirFactor)
		DetectorUtils.ApplyPlayerFlag(playerState, 100, Constants.Flags.CHEATER, reason)
		return
	end

	local alignGain = 0.0
	local noAlignGain = 0.0
	local lilacGain = 0.0
	local lilacMaxDelta = 0.0
	local lilacTotalDelta = 0.0
	local lilacFlags = 0

	local alignExcess = math.max(0.0, alignDev - ALIGN_TIGHT_MAX_DEGREES)
	local noAlignWeight = 1.0 / (1.0 + math.log(1.0 + alignExcess * 2.0))
	local dirSoft = 0.25 + 0.75 * dirFactor

	if attackerClass == TF_CLASS_SNIPER then
		local victimID = pending.victimID
		local sniperHeadPos = pending.victimHeadPos or pending.victimEyePos
		local sniperBodyPos = pending.victimBodyPos
		if not sniperBodyPos and pending.victimOrigin then
			sniperBodyPos = pending.victimOrigin + Vector3(0, 0, 40)
		end
		local eyePos = pending.shooterEyePos
			or HistoryManager.GetPlayerFieldAt(shotBucket, id, HistoryManager.Fields.EyePosition)
			or playerState.wrap:GetEyePos()

		if eyePos and sniperHeadPos then
			local hp, hy = getAngleToPos(eyePos, sniperHeadPos)
			headError = angularDist(shotAngles.pitch, shotAngles.yaw, hp, hy)
			bestAimError = headError
		end
		if bestAimError == nil and eyePos and sniperBodyPos then
			local bp, by = getAngleToPos(eyePos, sniperBodyPos)
			bestAimError = angularDist(shotAngles.pitch, shotAngles.yaw, bp, by)
		end

		if bestAimError ~= nil then
			aimFactor = aimErrorWeight(bestAimError)
		else
			-- No positional context: still allow detection but with weaker weight
			aimFactor = 0.25
		end

		local rawGain = 0.0
		if pending.crit == true then
			rawGain, lilacMaxDelta, lilacTotalDelta, lilacFlags = lilacAimbotHeuristics(id, shotOffset, pending.shotTick,
				shotAngles, eyePos, sniperHeadPos, sniperBodyPos)
		end
		if alignDev1 ~= nil and dirMeaningful1 and dirFactor1 ~= nil then
			if shotDev >= LILAC_RETURN_MIN_SNAP_DEGREES
				and alignDev1 <= LILAC_RETURN_ALIGN_MAX_DEGREES
				and dirFactor1 >= LILAC_RETURN_DIR_MIN
			then
				lilacFlags = lilacFlags | LILAC_FLAG_RETURN
				rawGain = rawGain + LILAC_GAIN_RETURN
			end
		end
		lilacGain = rawGain * (aimFactor ^ 2.0)
		lilacGain = math.min(lilacGain, 4.0)

		local dirWeight = dirFactor ^ 4.0

		alignGain = (shotDev ^ 1.2) * (snap01 ^ 2.0) * (alignWeight ^ 4.0) * dirWeight * (aimFactor ^ 2.0) * 18.0
		noAlignGain = (shotDev ^ 1.0) * (snap01 ^ 1.5) * (aimFactor ^ 2.0) * (dirSoft ^ 2.0) * (noAlignWeight ^ 2.0) *
			1.25
		noAlignGain = math.min(noAlignGain, 2.5)

		scoreGain = alignGain + noAlignGain + discontGain + lilacGain
		scoreGain = math.min(scoreGain, 25.0)
	else
		local dirWeight = dirFactor ^ 4.0
		alignGain = (shotDev ^ 1.4) * (snap01 ^ 2.0) * (alignWeight ^ 4.0) * dirWeight * (aimFactor ^ 2.0) * 6.0 *
			sanityFactor
		noAlignGain = (shotDev ^ 1.1) * (snap01 ^ 1.5) * (aimFactor ^ 2.0) * (dirSoft ^ 2.0) * (noAlignWeight ^ 2.0) *
			0.75 *
			sanityFactor
		noAlignGain = math.min(noAlignGain, 1.5)

		local rawGain = 0.0
		if (attackerClass == TF_CLASS_SPY) and (pending.crit == true) then
			rawGain, lilacMaxDelta, lilacTotalDelta, lilacFlags = lilacAimbotHeuristics(id, shotOffset, pending.shotTick,
				shotAngles, eyePos, headPos, bodyPos)
		end
		if alignDev1 ~= nil and dirMeaningful1 and dirFactor1 ~= nil then
			if shotDev >= LILAC_RETURN_MIN_SNAP_DEGREES
				and alignDev1 <= LILAC_RETURN_ALIGN_MAX_DEGREES
				and dirFactor1 >= LILAC_RETURN_DIR_MIN
			then
				lilacFlags = lilacFlags | LILAC_FLAG_RETURN
				rawGain = rawGain + LILAC_GAIN_RETURN
			end
		end
		lilacGain = rawGain * (aimFactor ^ 2.0) * sanityFactor
		lilacGain = math.min(lilacGain, 3.0)

		scoreGain = alignGain + noAlignGain + discontGain + lilacGain
		scoreGain = math.min(scoreGain, 15.0)
	end

	if Common.IsDebugEnabled() then
		local headErrText = "n/a"
		if bestAimError ~= nil then
			headErrText = string.format("%.1f°", bestAimError)
		end
		local align01 = alignWeight
		local gainAlignText = string.format("%.1f", alignGain)
		local gainNoAlignText = string.format("%.1f", noAlignGain)
		local gainLilacText = string.format("%.1f", lilacGain)
		print(string.format(
			"[SilentAim] %s | Snap: %.1f° | AlignDev: %.1f° (t=%s) | Dir: %.2f | Align01: %.3f | AimErr: %s | Gain: %.1f (A=%s N=%s D=%.1f L=%s)",
			id,
			shotDev,
			alignDev,
			tostring(alignTick),
			dirFactor,
			align01,
			headErrText,
			scoreGain,
			gainAlignText,
			gainNoAlignText,
			discontGain,
			gainLilacText
		))
		if lilacFlags ~= 0 then
			print(string.format("          | Lilac: flags=%d maxΔ=%.1f totalΔ=%.1f", lilacFlags, lilacMaxDelta,
				lilacTotalDelta))
		end
		print(string.format(
			"          | Pred: P%.1f Y%.1f | Actual: P%.1f Y%.1f",
			predShotPitch,
			wrapAngle(predShotYaw),
			shotAngles.pitch,
			wrapAngle(shotAngles.yaw)
		))
	end

	if scoreGain > 1.0 then
		local reason = string.format("SilentAim Anomaly (%.1f° snap, %.1f° align, dir=%.2f)", shotDev, alignDev,
			dirFactor)
		if discontGain > alignGain and discontGain > noAlignGain then
			local err = nonSniperBestAimError or 0
			reason = string.format("View Discontinuity (%.1f° snap, aimerr=%.1f°)", shotDev, err)
		end
		DetectorUtils.ApplyPlayerFlag(playerState, scoreGain, nil, reason)
	end
end

local function onDamageEvent(event)
	local eventName = event:GetName()
	if eventName ~= "player_hurt" then
		return
	end

	HistoryManager.NewTick()

	local attackerUID = event:GetInt("attacker")
	local victimUID = event:GetInt("userid")
	if not attackerUID or not victimUID or attackerUID == victimUID then
		if Common.IsDebugEnabled() then
			local now = globals.RealTime()
			if canPrintFiltered(now) then
				print(string.format("[SilentAim] player_hurt ignored (attacker=%s victim=%s)", tostring(attackerUID),
					tostring(victimUID)))
			end
		end
		return
	end

	local attackerPly = entities.GetByUserID(attackerUID)
	if not attackerPly or not attackerPly:IsValid() then
		return
	end

	-- 1. Check weaponid from event (authoritative for hitscan vs projectile)
	local curTick = globals.TickCount()
	local attackerClass = attackerPly:GetPropInt("m_iClass")
	local weaponID = event:GetInt("weaponid")
	local weaponName = event.GetString and event:GetString("weapon") or nil

	if attackerClass ~= TF_CLASS_SNIPER and attackerClass ~= TF_CLASS_SPY then
		local lastTick = lastNonSniperTickByUserID[attackerUID] or -999999
		if (curTick - lastTick) < NON_SNIPER_COOLDOWN_TICKS then
			return
		end
		lastNonSniperTickByUserID[attackerUID] = curTick
	end

	local isHitscan, weaponClass, weaponSpread, projType = HitscanInfo.Classify(attackerPly, weaponName, weaponID)
	if not isHitscan then
		return
	end

	local victimPly = entities.GetByUserID(victimUID)
	if not victimPly or not victimPly:IsValid() then
		return
	end

	if not Common.IsValidPlayer(attackerPly, nil, nil, nil) then
		return
	end
	if not Common.IsValidPlayer(victimPly, nil, nil, nil) then
		return
	end

	local attackerID = tostring(Common.GetSteamID64(attackerPly))
	local victimID = tostring(Common.GetSteamID64(victimPly))
	if not attackerID or not victimID then
		return
	end

	HistoryManager.MarkDamageDealt(attackerID)

	local pdata = playerData[attackerID]
	if not pdata then
		pdata = {
			shotPending = nil,
			lastSmallSnapDecay = 0,
		}
		playerData[attackerID] = pdata
	end
	if pdata.lastSmallSnapDecay == nil then
		pdata.lastSmallSnapDecay = 0
	end

	if pdata.shotPending and pdata.shotPending.shotTick < curTick then
		local state = PlayerCache.GetByID(attackerID)
		if state and state.wrap and attackerPly and attackerPly:IsValid() then
			analyzePendingShot(state, attackerPly, pdata, pdata.shotPending, curTick)
		end
		pdata.shotPending = nil
	end
	if not pdata.shotPending or pdata.shotPending.shotTick < curTick then
		local weapon = attackerPly:GetPropEntity("m_hActiveWeapon")
		local activeWeaponName = "unknown"
		if weapon and weapon:IsValid() then
			activeWeaponName = weapon:GetClass()
		end

		pdata.shotPending = {
			shotTick = curTick,
			victimID = victimID,
			weaponID = weaponID,
			weaponClass = weaponClass,
			projType = projType,
			weaponSpread = weaponSpread,
			weaponName = activeWeaponName,
			crit = (event:GetInt("crit") or 0) ~= 0,
			minicrit = (event:GetInt("minicrit") or 0) ~= 0,
			damage = event:GetInt("damageamount"),
			victimHealthAfter = event:GetInt("health"),
			shooterEyePos = nil,
			victimEyePos = nil,
			victimHeadPos = nil,
			victimBodyPos = nil,
			victimOrigin = nil,
		}

		local origin = attackerPly:GetAbsOrigin()
		local viewOffset = attackerPly:GetPropVector("localdata", "m_vecViewOffset[0]")
		if origin and viewOffset then
			pdata.shotPending.shooterEyePos = origin + viewOffset
		end

		local vOrigin = victimPly:GetAbsOrigin()
		local vViewOffset = victimPly:GetPropVector("localdata", "m_vecViewOffset[0]")
		if vOrigin then
			pdata.shotPending.victimOrigin = vOrigin
			if vViewOffset then
				pdata.shotPending.victimEyePos = vOrigin + vViewOffset
			end
		end

		local vHead = getHitboxCenter(victimPly, 1)
		if vHead then
			pdata.shotPending.victimHeadPos = vHead
		end
		local vBody = getHitboxCenter(victimPly, 4)
		if vBody then
			pdata.shotPending.victimBodyPos = vBody
		end

		if Common.IsDebugEnabled() and (attackerClass == TF_CLASS_SNIPER or attackerClass == TF_CLASS_SPY) then
			local now = globals.RealTime()
			if canPrintRecorded(now) then
				print(string.format(
					"[SilentAim] player_hurt recorded %s -> %s weaponid=%s projType=%s spread=%s class=%s name=%s",
					attackerID,
					victimID,
					tostring(weaponID),
					tostring(projType),
					tostring(weaponSpread),
					tostring(weaponClass),
					tostring(weaponName)
				))
			end
		end
	end
end

Events.Register("FireGameEvent", "CD_SilentAim_Event", onDamageEvent, "*")

function SilentAim.ProcessPlayer(playerState)
	if not playerState or not playerState.wrap or not playerState.id then
		return
	end

	if not (G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.SilentAimbot) then
		return
	end

	local id = playerState.id
	local ply = playerState.wrap:GetRawEntity()
	if not ply or not ply:IsValid() then
		return
	end

	if not playerData[id] then
		playerData[id] = {
			shotPending = nil,
			lastSmallSnapDecay = 0,
		}
	end
	local pdata = playerData[id]
	if pdata.lastSmallSnapDecay == nil then
		pdata.lastSmallSnapDecay = 0
	end

	local curTick = globals.TickCount()

	if not pdata.shotPending then
		simulateSilentAimLocal(playerState, pdata)
	end

	local pending = pdata.shotPending
	if pending then
		if curTick <= pending.shotTick then
			return
		end
		pdata.shotPending = nil
		analyzePendingShot(playerState, ply, pdata, pending, curTick)
	end
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	playerData[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerData[id] = nil
end)

return SilentAim
