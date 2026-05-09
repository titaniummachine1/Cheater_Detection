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
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local PlayerCache = require("Cheater_Detection.Core.player_cache")

local SilentAim = {}

local MIN_SNAP_DEGREES = 8.0

local SNIPER_BIG_SNAP_DEGREES = 90.0
local SNIPER_HEAD_MAX_ERROR_DEGREES = 6.0
local SNIPER_RETURN_MAX_DEGREES = 3.0

local SANITY_MAX_DEGREES = 16.0
local playerData = {}

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

local function wrapAngle(d)
	return (d + 180) % 360 - 180
end

local function angularDist(p1, y1, p2, y2)
	local dp = math.abs(wrapAngle(p1 - p2))
	local dy = math.abs(wrapAngle(y1 - y2))
	return math.sqrt(dp * dp + dy * dy)
end

local function getAngleToPos(sourcePos, targetPos)
	local delta = {
		x = targetPos.x - sourcePos.x,
		y = targetPos.y - sourcePos.y,
		z = targetPos.z - sourcePos.z,
	}
	local dist = math.sqrt(delta.x * delta.x + delta.y * delta.y)
	local pitch = -math.deg(math.atan(delta.z, dist))
	local yaw = math.deg(math.atan(delta.y, delta.x))
	return pitch, yaw
end

local TF_PROJECTILE_BULLET = 1
local TF_CLASS_SNIPER = 2
local TF_CLASS_SPY = 8

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
	local weaponID = event:GetInt("weaponid")
	local isHitscan = false
	local projType = nil
	local weaponClass = nil
	local weaponSpread = nil
	local weaponName = event.GetString and event:GetString("weapon") or nil

	-- Use weapon APIs if we can get the active weapon
	local activeWeapon = attackerPly:GetPropEntity("m_hActiveWeapon")
	if activeWeapon and activeWeapon:IsValid() then
		weaponClass = activeWeapon.GetClass and activeWeapon:GetClass() or nil
		if activeWeapon.GetWeaponSpread then
			weaponSpread = activeWeapon:GetWeaponSpread()
		end

		local token = tostring(weaponClass or weaponName or ""):lower()
		local classNonHitscan = token:find("rocketlauncher")
			or token:find("grenadelauncher")
			or token:find("pipebomb")
			or token:find("compoundbow")
			or token:find("flamethrower")
			or token:find("particlecannon")
			or token:find("flare")
			or token:find("crossbow")
			or token:find("syringe")
			or token:find("cannon")
			or token:find("sticky")
			or token:find("knife")
			or token:find("bat")
			or token:find("bottle")
			or token:find("shovel")
			or token:find("wrench")
			or token:find("fists")
			or token:find("bonesaw")
			or token:find("sword")
			or token:find("club")
			or token:find("whip")
			or token:find("robotarm")
			or token:find("breakablesign")
			or token:find("breakable")
			or token:find("sign")
			or token:find("rocket")
			or token:find("grenade")
			or token:find("pipe")
			or token:find("arrow")
			or token:find("bow")
			or token:find("flame")

		if classNonHitscan then
			isHitscan = false
		elseif weaponSpread ~= nil then
			isHitscan = true
		else
			local getProjType = activeWeapon.GetWeaponProjectileType
			if type(getProjType) == "function" then
				projType = activeWeapon:GetWeaponProjectileType()
				if projType ~= nil and projType ~= 0 and projType ~= TF_PROJECTILE_BULLET then
					isHitscan = false
				else
					isHitscan = true
				end
			else
				local nameToken = tostring(weaponName or weaponClass or ""):lower()
				local isProjectileName = nameToken:find("tf_projectile")
					or nameToken:find("rocket")
					or nameToken:find("pipe")
					or nameToken:find("grenade")
					or nameToken:find("arrow")
					or nameToken:find("bow")
					or nameToken:find("crossbow")
					or nameToken:find("flare")
					or nameToken:find("flame")
					or nameToken:find("robotarm")
					or nameToken:find("breakable")
					or nameToken:find("sign")
					or nameToken:find("knife")
					or nameToken:find("bat")
					or nameToken:find("wrench")
				local isHitscanName = nameToken:find("sniper")
					or nameToken:find("scatter")
					or nameToken:find("shotgun")
					or nameToken:find("pistol")
					or nameToken:find("revolver")
					or nameToken:find("smg")
					or nameToken:find("minigun")
				if isProjectileName then
					isHitscan = false
				elseif isHitscanName then
					isHitscan = true
				else
					isHitscan = true
				end
			end
		end
	end

	-- Extra check: filter out common non-direct damage sources using weaponID
	-- 54: SENTRY_BULLET, 55: SENTRY_ROCKET, 68: DISPENSER_GUN etc.
	if weaponID == 54 or weaponID == 55 or weaponID == 68 then
		isHitscan = false
	end

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
		}
		playerData[attackerID] = pdata
	end

	local curTick = globals.TickCount()
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
			shooterEyePos = nil,
			victimEyePos = nil,
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

		if Common.IsDebugEnabled() then
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
		}
	end
	local pdata = playerData[id]

	local pending = pdata.shotPending
	if not pending then
		return
	end

	local curTick = globals.TickCount()
	-- Wait until the shot bucket is at least 1 tick in the past
	if curTick <= pending.shotTick then
		return
	end

	pdata.shotPending = nil

	if Common.IsDebugEnabled() then
		print(string.format("[SilentAim] Analyzing shot for %s (tick %d)", id, pending.shotTick))
	end

	-- Find the shot bucket (offset 1 if we are processing at shotTick + 1)
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

	if Common.IsDebugEnabled() then
		print(string.format(
			"[SilentAim] shot context id=%s weaponid=%s projType=%s class=%s damage=%s",
			id,
			tostring(pending.weaponID),
			tostring(pending.projType),
			tostring(pending.weaponClass),
			tostring(pending.damage)
		))
	end

	-- SANITY CHECK: Was the player aiming remotely close to the victim? (degrees)
	-- Skip this check for Sniper (2) and Spy (8)
	local attackerClass = ply:GetPropInt("m_iClass")
	local isSniperOrSpy = (attackerClass == TF_CLASS_SNIPER or attackerClass == TF_CLASS_SPY)

	local sanityFactor = 1.0
	if not isSniperOrSpy then
		local victimID = pending.victimID
		local victimWrap = PlayerCache.GetBySteamID(victimID)
		local headPos = victimWrap and victimWrap:GetHitboxPos(1) or nil
		local bodyPos = victimWrap and victimWrap:GetHitboxPos(4) or nil
		local eyePos = pending.shooterEyePos or
			HistoryManager.GetPlayerFieldAt(shotBucket, id, HistoryManager.Fields.EyePosition) or
			playerState.wrap:GetEyePos()

		local aimedAtTarget = false
		if eyePos then
			if headPos then
				local p, y = getAngleToPos(eyePos, headPos)
				if angularDist(shotAngles.pitch, shotAngles.yaw, p, y) < SANITY_MAX_DEGREES then
					aimedAtTarget = true
				end
			end
			if not aimedAtTarget and bodyPos then
				local p, y = getAngleToPos(eyePos, bodyPos)
				if angularDist(shotAngles.pitch, shotAngles.yaw, p, y) < SANITY_MAX_DEGREES then
					aimedAtTarget = true
				end
			end
		else
			aimedAtTarget = true
		end

		if not aimedAtTarget then
			sanityFactor = 0.15
			if Common.IsDebugEnabled() then
				print(string.format("[SilentAim] %s sanity miss (outside %.0f° bubble)", id, SANITY_MAX_DEGREES))
			end
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
		if Common.IsDebugEnabled() then
			print(string.format("[SilentAim] %s snap too small: %.1f° (min %.1f°)", id, shotDev, MIN_SNAP_DEGREES))
		end
		return
	end

	-- 5. Check "return to pattern" over the next few ticks (silent aim can snap back within 1-3 ticks)
	local bestReturnDev = nil
	local bestReturnTick = nil
	for k = 1, 3 do
		local postShotBucket = HistoryManager.GetBucketAt(shotOffset - k)
		if postShotBucket and postShotBucket._tick == (pending.shotTick + k) then
			local postShotAngles = HistoryManager.GetPlayerFieldAt(postShotBucket, id, HistoryManager.Fields.Angles)
			if postShotAngles and type(postShotAngles.pitch) == "number" and type(postShotAngles.yaw) == "number" then
				postShotAngles = { pitch = postShotAngles.pitch, yaw = wrapAngle(postShotAngles.yaw) }

				local dtToPost = (pending.shotTick + k) - historyTicks[1]
				local predPostPitch = mostRecentClean.pitch + (avgVPitch * dtToPost)
				local predPostYaw = mostRecentClean.yaw + (avgVYaw * dtToPost)
				local returnDev = angularDist(postShotAngles.pitch, postShotAngles.yaw, predPostPitch, predPostYaw)

				if not bestReturnDev or returnDev < bestReturnDev then
					bestReturnDev = returnDev
					bestReturnTick = pending.shotTick + k
				end
			end
		end
	end

	if not bestReturnDev then
		return
	end

	-- 6. Score calculation
	-- High alignment (low returnDev relative to shotDev) indicates silent aim snapping back.
	local alignmentFactor = math.max(0.0, 1.0 - bestReturnDev / math.max(shotDev, 1.0))

	local scoreGain = 0.0
	local headError = nil
	local bestAimError = nil

	if attackerClass == TF_CLASS_SNIPER then
		local victimID = pending.victimID
		local victimWrap = PlayerCache.GetBySteamID(victimID)
		local headPos = pending.victimEyePos or (victimWrap and victimWrap:GetHitboxPos(1) or nil)
		local bodyPos = nil
		if pending.victimOrigin then
			bodyPos = pending.victimOrigin + Vector3(0, 0, 40)
		else
			bodyPos = victimWrap and victimWrap:GetHitboxPos(4) or nil
		end
		local eyePos = pending.shooterEyePos
			or HistoryManager.GetPlayerFieldAt(shotBucket, id, HistoryManager.Fields.EyePosition)
			or playerState.wrap:GetEyePos()

		if eyePos and headPos then
			local hp, hy = getAngleToPos(eyePos, headPos)
			headError = angularDist(shotAngles.pitch, shotAngles.yaw, hp, hy)
			bestAimError = headError
		end
		if bestAimError == nil and eyePos and bodyPos then
			local bp, by = getAngleToPos(eyePos, bodyPos)
			bestAimError = angularDist(shotAngles.pitch, shotAngles.yaw, bp, by)
		end

		local bigSnapFactor = 0.0
		if shotDev >= SNIPER_BIG_SNAP_DEGREES then
			bigSnapFactor = math.min(1.0, (shotDev - SNIPER_BIG_SNAP_DEGREES) / 90.0 + 1.0)
		end

		local aimFactor = 0.0
		if bestAimError ~= nil then
			aimFactor = math.max(0.0, 1.0 - (bestAimError / SNIPER_HEAD_MAX_ERROR_DEGREES))
		else
			-- No positional context: still allow detection but with weaker weight
			aimFactor = 0.25
		end

		local returnFactor = math.max(0.0, 1.0 - (bestReturnDev / SNIPER_RETURN_MAX_DEGREES))

		-- Baseline for huge flicks that land precisely, even if snap-back isn't immediate.
		local baseline = 0.0
		if shotDev >= SNIPER_BIG_SNAP_DEGREES and aimFactor > 0.5 then
			baseline = (shotDev - SNIPER_BIG_SNAP_DEGREES) * (aimFactor ^ 2.0)
		end

		-- Sniper: prioritize huge flicks that land precisely and snap back to predicted motion.
		scoreGain = (shotDev ^ 1.25) * (aimFactor ^ 2.0) * (returnFactor ^ 2.0) * (1.0 + bigSnapFactor) + baseline
	else
		-- Default: prior model
		scoreGain = (shotDev ^ 1.5) * (alignmentFactor ^ 2) * 10.0 * sanityFactor
	end

	if Common.IsDebugEnabled() then
		local headErrText = "n/a"
		if bestAimError ~= nil then
			headErrText = string.format("%.1f°", bestAimError)
		end
		print(string.format(
			"[SilentAim] %s | Snap: %.1f° | Return: %.1f° (t=%s) | Align: %.2f | AimErr: %s | Gain: %.1f",
			id, shotDev, bestReturnDev, tostring(bestReturnTick), alignmentFactor, headErrText, scoreGain
		))
		print(string.format(
			"          | Pred: P%.1f Y%.1f | Actual: P%.1f Y%.1f",
			predShotPitch,
			wrapAngle(predShotYaw),
			shotAngles.pitch,
			wrapAngle(shotAngles.yaw)
		))
	end

	if scoreGain > 1.0 then
		local reason = string.format("SilentAim Anomaly (%.1f° snap, %.2f align)", shotDev, alignmentFactor)
		DetectorUtils.ApplyPlayerFlag(playerState, scoreGain, nil, reason)
	end
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	playerData[id] = nil
end)

return SilentAim
