--[[ detectors/silent_aim.lua
     Silent Aimbot Detector — 2-tick view-angle extrapolation.
     Uses shared tick-bucket history from HistoryManager.

     Algorithm:
       - Stage 3: Push angles to current bucket via HistoryManager.PushAngles()
       - On player_hurt: Record shot angle, build predictions from history
       - On ProcessPlayer: Consume accumulated score

     Uses shared bucket structure for angle storage instead of per-player tables.
]]

local Events                            = require("Cheater_Detection.Core.Events")
local Common                            = require("Cheater_Detection.Utils.Common")
local MathUtils                         = require("Cheater_Detection.Utils.MathUtils")
local G                                 = require("Cheater_Detection.Utils.Globals")
local Constants                         = require("Cheater_Detection.Core.constants")
local DetectorUtils                     = require("Cheater_Detection.Utils.DetectorUtils")
local Logger                            = require("Cheater_Detection.Utils.Logger")
local PlayerData                        = require("Cheater_Detection.Utils.PlayerData")
local HistoryManager                    = require("Cheater_Detection.Utils.HistoryManager")
local PlayerCache                       = require("Cheater_Detection.Core.player_cache")
local mathAbs                           = math.abs

local SilentAim                         = {}

local MIN_SNAP_DEGREES                  = 2.0
local SMALL_SNAP_DECAY                  = 0.0625

local HARD_SNAP_CHEATER_DEGREES         = 90.0
local INSTA_KILL_ALIGN_MAX_DEGREES      = 5.0
local INSTA_KILL_HEAD_MAX_ERROR_DEGREES = 6.0
local INSTA_KILL_DIR_MIN                = 0.5

local SNIPER_HEAD_MAX_ERROR_DEGREES     = 6.0
local ALIGN_TIGHT_MAX_DEGREES           = 2.0
local ALIGN_FLOOR                       = 0.05
local SNAP_STAGE1_MAX_DEGREES           = 15.0
local SNAP_STAGE1_OUTPUT                = 0.20
local SNAP_STAGE1_LOG_K                 = 3.0
local SNAP_STAGE2_MAX_DEGREES           = 30.0
local SNAP_STAGE2_OUTPUT                = 0.40
local SNAP_STAGE2_LOG_K                 = 2.0
local SNAP_SPIKE_EXP_K                  = 5.0
local DIR_MIN_DELTA_DEGREES             = 7.0
local DISCONT_SNAP_MIN_DEGREES          = 45.0
local DISCONT_AIMERR_MIN_DEGREES        = 25.0

local SANITY_MAX_DEGREES                = 16.0
local LILAC_WINDOW_TICKS                = 33
local LILAC_SNAP_DELTA1_DEGREES         = 10.0
local LILAC_SNAP_DELTA2_DEGREES         = 5.0
local LILAC_SNAP_RATIO1                 = 0.2
local LILAC_SNAP_RATIO2                 = 0.1
local LILAC_RETURN_MIN_SNAP_DEGREES     = 10.0
local LILAC_RETURN_ALIGN_MAX_DEGREES    = 2.0
local LILAC_RETURN_DIR_MIN              = 0.5

local LILAC_FLAG_SNAP                   = 1
local LILAC_FLAG_SNAP2                  = 2
local LILAC_FLAG_RETURN                 = 4

local LILAC_GAIN_SNAP                   = 2.0
local LILAC_GAIN_SNAP2                  = 1.2
local LILAC_GAIN_RETURN                 = 1.0

local playerData                        = {}
local NON_SNIPER_COOLDOWN_TICKS         = 6
local lastNonSniperTickByID             = {}

local _histPitches                      = {}
local _histYaws                         = {}
local _histTicks                        = {}

-- Fire-event cache: keyed by shooter entity index.
-- Populated by CTEFireBullets (exact shot tick), consumed by onDamageEvent.
-- { eyePos = Vector3, tick = n }
local fireShotCache                     = {}
local FIRE_CACHE_STALE_TICKS            = 8

-- Shot accuracy tracking: keyed by steamID64 string.
-- Tracks hitscan shots fired and hits to compute a session hit rate.
-- Hit rate >= PRECISION_HIGH boosts scoreGain; rate below PRECISION_LOW suppresses it.
-- { fired = n, hit = n }
local shotAccuracy                      = {}
local MIN_SHOTS_FOR_ACCURACY            = 8    -- ignore until enough shots to be meaningful
local PRECISION_HIGH                    = 0.72 -- >= this hit rate boosts score by up to 1.5x
local PRECISION_LOW                     = 0.35 -- <= this hit rate suppresses score (legit misser)

local debugFilterWindowStart            = 0
local debugFilterWindowCount            = 0
local DEBUG_FILTER_MAX_PER_SEC          = 0

local debugRecordWindowStart            = 0
local debugRecordWindowCount            = 0
local DEBUG_RECORD_MAX_PER_SEC          = 8

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

local wrapAngle = MathUtils.wrapAngle
local angularDist = MathUtils.angularDist

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

local getAngleToPos = MathUtils.angleToPos
local getAngleToXYZ = MathUtils.angleToXYZ

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

local function lilacAimbotHeuristics(id, shotOffset, shotTick, shotPitch, shotYaw, eyePos, headPos, bodyPos)
	if not id or type(shotOffset) ~= "number" or type(shotTick) ~= "number" then
		return 0.0, 0.0, 0.0, 0
	end
	if type(shotPitch) ~= "number" or type(shotYaw) ~= "number" then
		return 0.0, 0.0, 0.0, 0
	end
	if not eyePos or (not headPos and not bodyPos) then
		return 0.0, 0.0, 0.0, 0
	end

	-- Get player history
	local history = HistoryManager.GetPlayerHistory(id)
	if not history then
		return 0.0, 0.0, 0.0, 0
	end
	local shotIndex = shotOffset + 1 -- convert to 1-indexed

	local flags = 0
	local maxDelta = 0.0
	local totalDelta = 0.0

	local aimDist = bestAimDistToTarget(eyePos, headPos, bodyPos, shotPitch, shotYaw)
	if aimDist == nil then
		return 0.0, 0.0, 0.0, 0
	end

	local langPitch = shotPitch
	local langYaw = shotYaw
	local lastAimDist = aimDist

	-- Look at older records (higher indices) for LILAC window
	for i = 1, LILAC_WINDOW_TICKS do
		local idx = shotIndex + i
		local record = history[idx]
		if not record or record._tick ~= (shotTick - i) then
			break
		end

		local ang = record[HistoryManager.Fields.Angles]
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

local function analyzePendingShot(playerState, ply, pdata, pending, curTick)
	if not playerState or not ply or not pdata or not pending then
		return
	end

	local id = playerState.id

	-- Get player history for this analysis
	local history = HistoryManager.GetPlayerHistory(id)
	if not history then
		return
	end

	-- Compute session hit rate for this player (precision multiplier).
	-- precisionMult > 1.0 = high accuracy suspect; < 1.0 = low accuracy, suppress.
	local acc = shotAccuracy[id]
	local precisionMult = 1.0
	if acc and acc.fired >= MIN_SHOTS_FOR_ACCURACY and acc.fired > 0 then
		local hitRate = acc.hit / acc.fired
		if hitRate >= PRECISION_HIGH then
			precisionMult = 1.0 + (hitRate - PRECISION_HIGH) / (1.0 - PRECISION_HIGH) * 0.5
		elseif hitRate <= PRECISION_LOW then
			precisionMult = 0.5 + (hitRate / PRECISION_LOW) * 0.5
		end
	end

	local attackerClass = ply:GetPropInt("m_iClass")
	local debugInterested = Common.IsLogCategoryEnabled("SilentAim") and
		(attackerClass == TF_CLASS_SNIPER or attackerClass == TF_CLASS_SPY)

	if debugInterested then
		print(string.format("[SilentAim] Analyzing shot for %s (tick %d)", id, pending.shotTick))
	end

	local shotOffset = curTick - pending.shotTick
	local shotIndex = shotOffset + 1 -- convert to 1-indexed array
	local shotRecord = history[shotIndex]
	if not shotRecord or shotRecord._tick ~= pending.shotTick then
		return
	end

	local shotAngles = shotRecord[HistoryManager.Fields.Angles]
	if not shotAngles then
		return
	end
	if type(shotAngles.pitch) ~= "number" or type(shotAngles.yaw) ~= "number" then
		return
	end
	if mathAbs(shotAngles.pitch) > 180 or mathAbs(shotAngles.yaw) > 1000000 then
		return
	end
	local shotPitch = shotAngles.pitch
	local shotYaw   = wrapAngle(shotAngles.yaw)

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
		or shotRecord[HistoryManager.Fields.EyePosition]
		or playerState.wrap:GetEyePos()

	local aimedAtTarget = false
	if eyePos then
		if headPos then
			local p, y = getAngleToPos(eyePos, headPos)
			local headErr = angularDist(shotPitch, shotYaw, p, y)
			bestAimError = headErr
			if headErr < SANITY_MAX_DEGREES then
				aimedAtTarget = true
			end
		end
		if not aimedAtTarget and bodyPos then
			local p, y = getAngleToPos(eyePos, bodyPos)
			local bodyErr = angularDist(shotPitch, shotYaw, p, y)
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
		if Common.IsLogCategoryEnabled("SilentAim") then
			print(string.format("[SilentAim] %s sanity miss (outside %.0f° bubble)", id, SANITY_MAX_DEGREES))
		end
	end

	-- 1. Gather pre-shot history for prediction (up to 5 clean ticks)
	local startIdx = shotIndex + 1
	local histN = 0
	for i = 1, #_histPitches do _histPitches[i] = nil end
	for i = 1, #_histYaws do _histYaws[i] = nil end
	for i = 1, #_histTicks do _histTicks[i] = nil end

	for idx = startIdx, startIdx + 10 do
		if histN >= 5 then break end
		local record = history[idx]
		if not record then break end

		local data = record[HistoryManager.Fields.Angles]
		if data and type(data.pitch) == "number" and type(data.yaw) == "number" then
			if mathAbs(data.pitch) <= 180 and mathAbs(data.yaw) <= 1000000 then
				if not record.damageDealt then
					histN               = histN + 1
					_histPitches[histN] = data.pitch
					_histYaws[histN]    = wrapAngle(data.yaw)
					_histTicks[histN]   = record._tick
				end
			end
		end
	end

	if histN < 2 then
		if Common.IsLogCategoryEnabled("SilentAim") then
			print(string.format("[SilentAim] %s extrapolation failed (only %d clean history ticks)", id, histN))
		end
		return
	end

	-- 2. Predict angular velocity (average over history)
	local totalVPitch, totalVYaw = 0, 0
	local samples = 0
	for i = 1, histN - 1 do
		local dt = _histTicks[i] - _histTicks[i + 1]
		if dt > 0 then
			totalVPitch = totalVPitch + wrapAngle(_histPitches[i] - _histPitches[i + 1]) / dt
			totalVYaw = totalVYaw + wrapAngle(_histYaws[i] - _histYaws[i + 1]) / dt
			samples = samples + 1
		end
	end

	if samples == 0 then
		return
	end

	local avgVPitch = totalVPitch / samples
	local avgVYaw = totalVYaw / samples

	-- 3. Predict shot tick angles from the most recent clean history tick
	local dtToShot = pending.shotTick - _histTicks[1]
	local predShotPitch = _histPitches[1] + (avgVPitch * dtToShot)
	local predShotYaw = _histYaws[1] + (avgVYaw * dtToShot)

	-- 4. Calculate deviation on shot tick
	local shotDev = angularDist(shotPitch, shotYaw, predShotPitch, predShotYaw)

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
	local bestAlignDev      = nil
	local bestAlignTick     = nil
	local bestDirFactor     = 0.0
	local bestDirMeaningful = false
	local alignDev1         = nil
	local dirFactor1        = nil
	local dirMeaningful1    = nil

	local prevActualPitch   = shotPitch
	local prevActualYaw     = shotYaw
	local prevPredPitch     = predShotPitch
	local prevPredYaw       = predShotYaw

	for k = 1, 3 do
		local postTick = pending.shotTick + k
		-- In new system: newer ticks have lower indices
		-- shotIndex = shot record, shotIndex - 1 = 1 tick newer (if exists)
		local postIdx = shotIndex - k
		if postIdx < 1 then break end -- Can't go newer than current

		local postRecord = history[postIdx]
		if postRecord and postRecord._tick == postTick then
			if not postRecord.damageDealt then
				local postShotAngles = postRecord[HistoryManager.Fields.Angles]
				if postShotAngles and type(postShotAngles.pitch) == "number" and type(postShotAngles.yaw) == "number" then
					local postPitch     = postShotAngles.pitch
					local postYaw       = wrapAngle(postShotAngles.yaw)

					local dtToPost      = postTick - _histTicks[1]
					local predPostPitch = _histPitches[1] + (avgVPitch * dtToPost)
					local predPostYaw   = _histYaws[1] + (avgVYaw * dtToPost)

					local alignDev      = angularDist(postPitch, postYaw, predPostPitch, predPostYaw)

					local actualDPitch  = wrapAngle(postPitch - prevActualPitch)
					local actualDYaw    = wrapAngle(postYaw - prevActualYaw)
					local predDPitch    = wrapAngle(predPostPitch - prevPredPitch)
					local predDYaw      = wrapAngle(predPostYaw - prevPredYaw)

					local actualLen     = math.sqrt(actualDPitch * actualDPitch + actualDYaw * actualDYaw)
					local predLen       = math.sqrt(predDPitch * predDPitch + predDYaw * predDYaw)
					local dirFactor     = 0.0
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

					prevActualPitch = postPitch
					prevActualYaw   = postYaw
					prevPredPitch   = predPostPitch
					prevPredYaw     = predPostYaw
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
			or shotRecord[HistoryManager.Fields.EyePosition]
			or playerState.wrap:GetEyePos()

		if eyePos and sniperHeadPos then
			local hp, hy = getAngleToPos(eyePos, sniperHeadPos)
			headError = angularDist(shotPitch, shotYaw, hp, hy)
			bestAimError = headError
		end
		if bestAimError == nil and eyePos and sniperBodyPos then
			local bp, by = getAngleToPos(eyePos, sniperBodyPos)
			bestAimError = angularDist(shotPitch, shotYaw, bp, by)
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
				shotPitch, shotYaw, eyePos, sniperHeadPos, sniperBodyPos)
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
				shotPitch, shotYaw, eyePos, headPos, bodyPos)
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

	if Common.IsLogCategoryEnabled("SilentAim") then
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
			shotPitch,
			wrapAngle(shotYaw)
		))
	end

	local CLEAN_SHOT_DECAY = -0.5
	local CLEAN_SHOT_MAX_DEV = MIN_SNAP_DEGREES * 3
	scoreGain = scoreGain * precisionMult

	if scoreGain > 1.0 then
		local reason = string.format("SilentAim Anomaly (%.1fdeg snap, %.1fdeg align, dir=%.2f)", shotDev, alignDev,
			dirFactor)
		if discontGain > alignGain and discontGain > noAlignGain then
			local err = nonSniperBestAimError or 0
			reason = string.format("View Discontinuity (%.1fdeg snap, aimerr=%.1fdeg)", shotDev, err)
		end
		if Common.IsLogCategoryEnabled("SilentAim") and acc and acc.fired >= MIN_SHOTS_FOR_ACCURACY then
			print(string.format("[SilentAim] precisionMult=%.2f (hit=%d fired=%d rate=%.0f%%)",
				precisionMult, acc.hit, acc.fired, (acc.hit / acc.fired) * 100))
		end
		print(string.format("[SilentAim] +%.1f score on %s | %s", scoreGain, id, reason))
		DetectorUtils.ApplyPlayerFlag(playerState, scoreGain, nil, reason)
	elseif aimedAtTarget and shotDev < CLEAN_SHOT_MAX_DEV and (playerState.score or 0) > 0 then
		if Common.IsLogCategoryEnabled("SilentAim") then
			print(string.format("[SilentAim] clean shot decay -%.2f on %s (snap=%.1fdeg)", -CLEAN_SHOT_DECAY, id, shotDev))
		end
		DetectorUtils.ApplyPlayerFlag(playerState, CLEAN_SHOT_DECAY, nil, "Clean shot decay")
	else
		if Common.IsLogCategoryEnabled("SilentAim") then
			print(string.format("[SilentAim] gated out %s | snap=%.1fdeg gain=%.2f aimed=%s", id, shotDev, scoreGain,
				tostring(aimedAtTarget)))
		end
	end
end

-- Consumes the pre-resolved hitscan hit event from Core/CombatEvents.lua.
-- Entity lookup, SteamID resolution and weapon classification are already done.
Events.Subscribe("OnHitscanHit", function(hit)
	local menu = G.Menu
	local adv = menu and menu.Advanced or nil
	if not adv or adv.SilentAimbot ~= true then return end

	HistoryManager.NewTick()

	local attackerEnt   = hit.attackerEnt
	local victimEnt     = hit.victimEnt
	local curTick       = hit.tickCount
	local attackerID    = hit.attackerID
	local victimID      = hit.victimID
	local attackerUID   = hit.attackerUID

	local attackerClass = attackerEnt:GetPropInt("m_iClass")
	if attackerClass ~= TF_CLASS_SNIPER and attackerClass ~= TF_CLASS_SPY then
		local lastTick = lastNonSniperTickByID[attackerID] or -999999
		if (curTick - lastTick) < NON_SNIPER_COOLDOWN_TICKS then return end
		lastNonSniperTickByID[attackerID] = curTick
	end

	if not Common.IsValidPlayer(attackerEnt, nil, nil, nil) then return end
	if not Common.IsValidPlayer(victimEnt, nil, nil, nil) then return end

	HistoryManager.MarkDamageDealt(attackerID)

	local acc = shotAccuracy[attackerID]
	if acc then
		acc.hit = acc.hit + 1
	else
		shotAccuracy[attackerID] = { fired = 0, hit = 1 }
	end

	local pdata = playerData[attackerID]
	if not pdata then
		pdata = { shotPending = nil, lastSmallSnapDecay = 0 }
		playerData[attackerID] = pdata
	end
	if pdata.lastSmallSnapDecay == nil then
		pdata.lastSmallSnapDecay = 0
	end

	if pdata.shotPending and pdata.shotPending.shotTick < curTick then
		local state = PlayerCache.GetByID(attackerID)
		if state and attackerEnt:IsValid() then
			analyzePendingShot(state, attackerEnt, pdata, pdata.shotPending, curTick)
		end
		pdata.shotPending = nil
	end
	if not pdata.shotPending or pdata.shotPending.shotTick < curTick then
		local weapon = attackerEnt:GetPropEntity("m_hActiveWeapon")
		local activeWeaponName = "unknown"
		if weapon and weapon:IsValid() then
			activeWeaponName = weapon:GetClass()
		end

		pdata.shotPending = {
			shotTick          = curTick,
			victimID          = victimID,
			weaponID          = hit.weaponID,
			weaponClass       = hit.weaponClass,
			projType          = hit.projType,
			weaponSpread      = hit.weaponSpread,
			weaponName        = activeWeaponName,
			crit              = hit.crit,
			minicrit          = hit.minicrit,
			damage            = hit.damage,
			victimHealthAfter = hit.victimHealthAfter,
			shooterEyePos     = nil,
			victimEyePos      = nil,
			victimHeadPos     = nil,
			victimBodyPos     = nil,
			victimOrigin      = nil,
		}

		local attackerIdx = attackerEnt:GetIndex()
		local fireEntry   = fireShotCache[attackerIdx]
		if fireEntry and (curTick - fireEntry.tick) <= FIRE_CACHE_STALE_TICKS then
			pdata.shotPending.shooterEyePos = fireEntry.eyePos
			fireShotCache[attackerIdx] = nil
		else
			local origin     = attackerEnt:GetAbsOrigin()
			local viewOffset = attackerEnt:GetPropVector("localdata", "m_vecViewOffset[0]")
			if origin and viewOffset then
				pdata.shotPending.shooterEyePos = origin + viewOffset
			end
		end

		local vOrigin     = victimEnt:GetAbsOrigin()
		local vViewOffset = victimEnt:GetPropVector("localdata", "m_vecViewOffset[0]")
		if vOrigin then
			pdata.shotPending.victimOrigin = vOrigin
			if vViewOffset then
				pdata.shotPending.victimEyePos = vOrigin + vViewOffset
			end
		end

		local vHead = getHitboxCenter(victimEnt, 1)
		if vHead then pdata.shotPending.victimHeadPos = vHead end
		local vBody = getHitboxCenter(victimEnt, 4)
		if vBody then pdata.shotPending.victimBodyPos = vBody end

		if Common.IsLogCategoryEnabled("SilentAim") then
			local now = globals.RealTime()
			if canPrintRecorded(now) then
				print(string.format(
					"[SilentAim] shot recorded %s -> %s weapon=%s class=%s",
					attackerID, victimID,
					tostring(hit.weaponName), tostring(hit.weaponClass)
				))
			end
		end
	end
end)

-- Consumes the pre-resolved fire-bullet event from Core/CombatEvents.lua.
-- Populates fireShotCache with the exact shooter eye pos captured at fire time,
-- and increments the per-player shots-fired accuracy counter.
Events.Subscribe("OnFireBullets", function(fire)
	local existing = fireShotCache[fire.shooterIdx]
	if existing then
		existing.eyePos = fire.eyePos
		existing.tick   = fire.tickCount
	elseif fire.eyePos then
		fireShotCache[fire.shooterIdx] = { eyePos = fire.eyePos, tick = fire.tickCount }
	end

	local acc = shotAccuracy[fire.shooterID]
	if acc then
		acc.fired = acc.fired + 1
	else
		shotAccuracy[fire.shooterID] = { fired = 1, hit = 0 }
	end
end)

function SilentAim.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then
		return
	end

	-- Basic check: must be connected to server (but not 100% stability required)
	if not Common.IsPlayerConnected() then
		return
	end

	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.SilentAimbot) then
		return
	end

	local id = playerState.id
	if not playerState.wrap:IsValid() then return end

	if not playerData[id] then
		playerData[id] = {
			shotPending = nil,
			lastSmallSnapDecay = 0,
		}
	end
	local pdata = playerData[id]
	local curTick = globals.TickCount()


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
	playerData[id]            = nil
	shotAccuracy[id]          = nil
	lastNonSniperTickByID[id] = nil
	local curTick             = globals.TickCount()
	for idx, entry in pairs(fireShotCache) do
		if (curTick - entry.tick) > FIRE_CACHE_STALE_TICKS then
			fireShotCache[idx] = nil
		end
	end
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerData[id]            = nil
	shotAccuracy[id]          = nil
	lastNonSniperTickByID[id] = nil
end)

return SilentAim
