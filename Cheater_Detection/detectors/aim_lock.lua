local Events = require("Cheater_Detection.Core.Events")
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local HitscanInfo = require("Cheater_Detection.Utils.HitscanInfo")

local AimLock = {}

local playerData = {}

local NON_SNIPER_COOLDOWN_TICKS = 6
local lastNonSniperTickByUserID = {}

local AIMLOCK_TARGET_TTL_TICKS = 66
local AIMLOCK_SAMPLE_TICKS = 6
local AIMLOCK_MIN_DIST_SQR = 300 * 300
local AIMLOCK_MAX_ERROR_DEGREES = 0.8
local AIMLOCK_TIGHT_ERROR_DEGREES = 0.15
local AIMLOCK_IDEAL_MOVE_MIN_DEGREES = 0.35
local AIMLOCK_VIEW_MOVE_MIN_DEGREES = 0.25
local AIMLOCK_TRACK_DIFF_MAX_DEGREES = 1.0
local AIMLOCK_STATIONARY_GAIN = 0.02
local AIMLOCK_STATIONARY_COOLDOWN_TICKS = 30
local AIMLOCK_EXP_K = 4.0
local AIMLOCK_MAX_GAIN = 6.0

local wrapAngle = Common.wrapAngle
local angularDist = Common.angularDist
local getAngleToPos = Common.angleToPos
local getAngleToXYZ = Common.angleToXYZ

local function aimlockGainFromConsecutive(consecutiveTicks, errDegrees)
	if type(consecutiveTicks) ~= "number" or type(errDegrees) ~= "number" then
		return 0.0
	end
	if consecutiveTicks <= 0 then
		return 0.0
	end
	if errDegrees < 0.0 then
		errDegrees = 0.0
	end
	if errDegrees >= AIMLOCK_MAX_ERROR_DEGREES then
		return 0.0
	end

	local denom = math.log(1.0 + AIMLOCK_MAX_ERROR_DEGREES)
	if denom <= 0.0 then
		return 0.0
	end
	local tErr = math.log(1.0 + errDegrees) / denom
	if tErr < 0.0 then
		tErr = 0.0
	end
	if tErr > 1.0 then
		tErr = 1.0
	end
	local errWeight = 1.0 - tErr
	errWeight = errWeight * errWeight

	local t = consecutiveTicks / (AIMLOCK_TARGET_TTL_TICKS * 0.5)
	if t < 0.0 then
		t = 0.0
	end
	if t > 1.0 then
		t = 1.0
	end

	local k = math.max(0.0001, AIMLOCK_EXP_K)
	local expScaled = (math.exp(k * t) - 1.0) / (math.exp(k) - 1.0)
	return AIMLOCK_MAX_GAIN * errWeight * expScaled
end

local function ensurePlayerData(id)
	local pdata = playerData[id]
	if pdata then
		return pdata
	end
	pdata = {
		lastVictimID = nil,
		lastVictimTick = 0,
		aimLockConsecTicks = 0,
		aimLockLastApplyTick = 0,
		aimLockPrevIdealPitch = nil,
		aimLockPrevIdealYaw = nil,
		aimLockPrevViewPitch = nil,
		aimLockPrevViewYaw = nil,
		aimLockLastStationaryTick = 0,
	}
	playerData[id] = pdata
	return pdata
end

local function onDamageEvent(event)
	local attackerUID = event:GetInt("attacker")
	local victimUID = event:GetInt("userid")
	if not attackerUID or not victimUID or attackerUID == victimUID then
		return
	end

	local attackerPly = entities.GetByUserID(attackerUID)
	if not attackerPly or not attackerPly:IsValid() then
		return
	end

	local curTick = globals.TickCount()
	local attackerClass = attackerPly:GetPropInt("m_iClass")
	if attackerClass ~= TF_CLASS_SNIPER and attackerClass ~= TF_CLASS_SPY then
		local lastTick = lastNonSniperTickByUserID[attackerUID] or -999999
		if (curTick - lastTick) < NON_SNIPER_COOLDOWN_TICKS then
			return
		end
		lastNonSniperTickByUserID[attackerUID] = curTick
	end

	local weaponID = event:GetInt("weaponid")
	local weaponName = event.GetString and event:GetString("weapon") or nil
	local isHitscan = HitscanInfo.Classify(attackerPly, weaponName, weaponID)
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

	local pdata = ensurePlayerData(attackerID)
	pdata.lastVictimID = victimID
	pdata.lastVictimTick = curTick
end

Events.Register("FireGameEvent", "CD_AimLock_Event", onDamageEvent, "player_hurt")

function AimLock.ProcessPlayer(playerState)
	if not playerState or not playerState.wrap or not playerState.id then
		return
	end

	if not (G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.SilentAimbot) then
		return
	end
	local adv = G and G.Menu and G.Menu.Advanced or nil
	if adv and adv.AimLock == false then
		return
	end

	local id = playerState.id
	local ply = playerState.wrap:GetRawEntity()
	if not ply or not ply:IsValid() then
		return
	end

	local pdata = ensurePlayerData(id)
	local curTick = globals.TickCount()

	local targetID = pdata.lastVictimID
	local targetTick = pdata.lastVictimTick or 0
	if not targetID or (curTick - targetTick) > AIMLOCK_TARGET_TTL_TICKS then
		pdata.aimLockConsecTicks = 0
		return
	end

	local attackerData = playerState.current
	local attackerAngles = attackerData and attackerData[HistoryManager.Fields.Angles] or nil
	local attackerEyePos = attackerData and attackerData[HistoryManager.Fields.EyePosition] or nil
	if not attackerAngles or not attackerEyePos then
		return
	end

	local victimState = PlayerCache.GetByID(targetID)
	local victimData = victimState and victimState.current or nil
	local victimEyePos = victimData and victimData[HistoryManager.Fields.EyePosition] or nil
	local victimEnt = victimState and victimState.wrap and victimState.wrap:GetRawEntity() or nil
	if not victimEyePos or not victimEnt or not victimEnt:IsValid() then
		return
	end

	local myTeam = ply:GetTeamNumber()
	local vTeam = victimEnt:GetTeamNumber()
	if not myTeam or not vTeam or myTeam == 0 or vTeam == 0 or myTeam == vTeam then
		return
	end

	local dx = victimEyePos.x - attackerEyePos.x
	local dy = victimEyePos.y - attackerEyePos.y
	local dz = victimEyePos.z - attackerEyePos.z
	local distSqr = dx * dx + dy * dy + dz * dz
	if distSqr < AIMLOCK_MIN_DIST_SQR then
		return
	end

	local p0 = attackerAngles.pitch
	local y0 = wrapAngle(attackerAngles.yaw)
	local hp, hy = getAngleToPos(attackerEyePos, victimEyePos)
	local headErr = angularDist(p0, y0, hp, hy)
	local bp, by = getAngleToXYZ(attackerEyePos, victimEyePos.x, victimEyePos.y, victimEyePos.z - 40.0)
	local bodyErr = angularDist(p0, y0, bp, by)
	local idealPitch = hp
	local idealYaw = hy
	local err = headErr
	if bodyErr < err then
		err = bodyErr
		idealPitch = bp
		idealYaw = by
	end

	local prevIdealPitch = pdata.aimLockPrevIdealPitch
	local prevIdealYaw = pdata.aimLockPrevIdealYaw
	local prevViewPitch = pdata.aimLockPrevViewPitch
	local prevViewYaw = pdata.aimLockPrevViewYaw

	pdata.aimLockPrevIdealPitch = idealPitch
	pdata.aimLockPrevIdealYaw = idealYaw
	pdata.aimLockPrevViewPitch = p0
	pdata.aimLockPrevViewYaw = y0

	local idealDelta = 0.0
	if type(prevIdealPitch) == "number" and type(prevIdealYaw) == "number" then
		idealDelta = angularDist(prevIdealPitch, prevIdealYaw, idealPitch, idealYaw)
	end

	local viewDelta = 0.0
	if type(prevViewPitch) == "number" and type(prevViewYaw) == "number" then
		viewDelta = angularDist(prevViewPitch, prevViewYaw, p0, y0)
	end

	local movedIdeal = idealDelta >= AIMLOCK_IDEAL_MOVE_MIN_DEGREES
	local movedView = viewDelta >= AIMLOCK_VIEW_MOVE_MIN_DEGREES
	local follows = false
	if movedIdeal and movedView then
		local diff = math.abs(viewDelta - idealDelta)
		if diff <= AIMLOCK_TRACK_DIFF_MAX_DEGREES then
			follows = true
		end
	end

	if not movedIdeal then
		pdata.aimLockConsecTicks = 0
	elseif err <= AIMLOCK_MAX_ERROR_DEGREES then
		if follows then
			pdata.aimLockConsecTicks = (pdata.aimLockConsecTicks or 0) + 1
		else
			local c = pdata.aimLockConsecTicks or 0
			if c > 0 then
				pdata.aimLockConsecTicks = math.max(0, c - 2)
			else
				pdata.aimLockConsecTicks = 0
			end
		end
	else
		pdata.aimLockConsecTicks = 0
	end

	if (curTick - (pdata.aimLockLastApplyTick or 0)) < AIMLOCK_SAMPLE_TICKS then
		return
	end

	pdata.aimLockLastApplyTick = curTick
	local consec = pdata.aimLockConsecTicks or 0
	local gain = 0.0
	if follows then
		gain = aimlockGainFromConsecutive(consec, err)
	else
		local lastStationary = pdata.aimLockLastStationaryTick or 0
		if (not movedIdeal) and err <= AIMLOCK_TIGHT_ERROR_DEGREES
			and (curTick - lastStationary) >= AIMLOCK_STATIONARY_COOLDOWN_TICKS then
			pdata.aimLockLastStationaryTick = curTick
			gain = AIMLOCK_STATIONARY_GAIN
		end
	end

	if gain >= 0.5 and consec >= 12 then
		local reason = string.format("AimLock (%.1f° err, %d ticks)", err, consec)
		DetectorUtils.ApplyPlayerFlag(playerState, gain, nil, reason)
	end
end

local function onPlayerDisconnect(id)
	playerData[id] = nil
end

local function onPlayerRemoved(id)
	playerData[id] = nil
end

Events.Subscribe("OnPlayerDisconnect", onPlayerDisconnect)
Events.Subscribe("OnPlayerRemoved", onPlayerRemoved)

return AimLock
