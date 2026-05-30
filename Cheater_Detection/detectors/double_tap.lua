--[[ detectors/double_tap.lua
     DOUBLE TAP — simtime burst [24,34) correlated with hitscan hurt (not generic warp).
     See header blocks below for replication notes (listen-server validated).

     WHY ~24–25 TICKS: choke ~24t, shoot one tick, release simtime in one packet → ~24t
     delta between network samples. FL without DT stays 1–2t; choke-only holds 40+t.

     NOT flagged: warp without DT band + hurt, FL alone, projectiles.

     Evidence: "double_tap" (legacy "warp_dt" still read in Evidence_system).
]]

local Evidence        = require("Cheater_Detection.Core.Evidence_system")
local Events          = require("Cheater_Detection.Core.Events")
local PlayerCache     = require("Cheater_Detection.Core.player_cache")
local Common          = require("Cheater_Detection.Utils.Common")
local Fetcher         = require("Cheater_Detection.Database.Fetcher")
local HistoryManager  = require("Cheater_Detection.Utils.HistoryManager")
local DetectionConfig = require("Cheater_Detection.Utils.DetectionConfig")

local DoubleTap = {}

local SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD = 3

local BURST_MIN_TICKS_66HZ         = 24.0
local FAKELAG_MAX_CHOKE_TICKS_66HZ   = 21.0
local BURST_MAX_TICKS_66HZ         = 34.0
local BURST_REPEAT_TOLERANCE       = 8
local RECENT_DT_BURST_SCAN         = 20
local WATCHING_DT_BURST_SCAN       = 40
local DT_CONFIRM_WINDOW_TICKS_66HZ = 48.0
local MAX_SIMTIME_DELTA_SEC        = 2.5
local FAKE_LAG_SUPPRESS_TICKS_66HZ   = 66.0

local DT_EVIDENCE_WEIGHT     = 30.0
local DT_EVIDENCE_MAX_MULT   = 5.0
local DT_EVIDENCE_COOLDOWN_S = 0.5
local REJECT_LOG_INTERVAL_S  = 0.35

local cachedTickInterval  = nil
local cachedBurstMinTicks = nil
local cachedBurstMaxTicks  = nil
local cachedConfirmTicks  = nil

local playerState         = {}
local dtSuppressUntil     = {}
local burstThisTick       = {}
local lastBurstCleanTick  = 0
local lastServerHitchTick = -math.huge
local _simTimes           = {}

local function getBurstThresholds()
	local tickInt = globals.TickInterval()
	if tickInt ~= cachedTickInterval then
		cachedTickInterval = tickInt
		cachedBurstMinTicks = math.floor(BURST_MIN_TICKS_66HZ / 66.0 / tickInt + 0.5)
		cachedBurstMaxTicks = math.floor(BURST_MAX_TICKS_66HZ / 66.0 / tickInt + 0.5)
		cachedConfirmTicks = math.floor(DT_CONFIRM_WINDOW_TICKS_66HZ / 66.0 / tickInt + 0.5)
		if cachedBurstMinTicks <= 0 or cachedBurstMaxTicks <= cachedBurstMinTicks then
			cachedBurstMinTicks = math.floor(BURST_MIN_TICKS_66HZ)
			cachedBurstMaxTicks = math.floor(BURST_MAX_TICKS_66HZ)
			cachedConfirmTicks = math.floor(DT_CONFIRM_WINDOW_TICKS_66HZ)
		end
	end
	return cachedBurstMinTicks, cachedBurstMaxTicks
end

local function getConfirmWindowTicks()
	getBurstThresholds()
	return cachedConfirmTicks
end

local function getFakeLagSuppressTicks()
	return math.floor(FAKE_LAG_SUPPRESS_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
end

function DoubleTap.GetDtBurstMinTicks()
	local burstMin, _ = getBurstThresholds()
	return burstMin
end

function DoubleTap.GetFakeLagMaxChokeTicks()
	return math.floor(FAKELAG_MAX_CHOKE_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
end

function DoubleTap.GetFakeLagMinChokeTicks()
	return math.max(3, math.floor(4.0 / 66.0 / globals.TickInterval() + 0.5))
end

function DoubleTap.IsDtSizedBurst(tickDelta)
	if not tickDelta or tickDelta <= 0 then
		return false
	end
	local burstMin, burstMax = getBurstThresholds()
	return tickDelta >= burstMin and tickDelta < burstMax
end

function DoubleTap.ShouldSuppressFakeLag(id)
	local untilTick = dtSuppressUntil[id]
	if not untilTick then
		return false
	end
	if globals.TickCount() > untilTick then
		dtSuppressUntil[id] = nil
		return false
	end
	return true
end

function DoubleTap.IsPlayerWatched(id)
	local data = playerState[id]
	if not data or data.lastDamageTick <= 0 then
		return false
	end
	local elapsed = globals.TickCount() - data.lastDamageTick
	return elapsed >= 0 and elapsed <= getConfirmWindowTicks()
end

function DoubleTap.MarkDtRelease(id)
	if not id then
		return
	end
	dtSuppressUntil[id] = globals.TickCount() + getFakeLagSuppressTicks()
end

function DoubleTap.GetDebugStats()
	return {
		enabled           = Common.IsDoubleTapDetectionEnabled(),
		fetchBlocking     = Fetcher.State.isRunning == true,
		connectionBlock   = Common.GetConnectionStabilityBlockReason(),
		localListenBypass = Common.IsDebugEnabled() and Common.IsLocalListenServer(),
		model             = "simtime burst <-> hitscan hurt (48t bidirectional)",
	}
end

local function timeToTicks(time)
	return math.floor(0.5 + time / globals.TickInterval())
end

local function getServerHitchWindow()
	return math.floor(1.0 / globals.TickInterval() + 0.5)
end

local function isInHitchWindow(curTick)
	return (curTick - lastServerHitchTick) < getServerHitchWindow()
end

local function recordBurstTick(tick, id)
	if not burstThisTick[tick] then
		burstThisTick[tick] = {}
	end
	burstThisTick[tick][#burstThisTick[tick] + 1] = id
end

local function isServerHitch(tick)
	local list = burstThisTick[tick]
	return list and #list >= SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD
end

local function cleanBurstTable(curTick)
	if (curTick - lastBurstCleanTick) < 4 then
		return
	end
	lastBurstCleanTick = curTick
	for tick in pairs(burstThisTick) do
		if (curTick - tick) > 3 then
			burstThisTick[tick] = nil
		end
	end
end

local function getState(id)
	if not playerState[id] then
		playerState[id] = {
			lastDamageTick        = 0,
			lastBurstTick         = 0,
			lastBurstAmount       = 0,
			lastBurstEvidenceTime = 0,
			lastBurstSignature    = nil,
			lastRejectTag         = nil,
			lastRejectLogTime     = 0,
		}
	end
	return playerState[id]
end

local function isEnabled()
	return Common.IsDoubleTapDetectionEnabled()
end

local function isDtLogEnabled()
	return Common.IsLogCategoryEnabled("DoubleTap")
		or Common.IsLogCategoryEnabled("Warp/DT")
end

local function formatDeltaPreview(deltaTicks, limit)
	local parts = {}
	local n = math.min(limit or 6, #deltaTicks)
	for i = 1, n do
		parts[#parts + 1] = tostring(deltaTicks[i])
	end
	if #deltaTicks > n then
		parts[#parts + 1] = "..."
	end
	return table.concat(parts, ",")
end

local function logDtReject(id, tag, detail, throttle)
	if not isDtLogEnabled() then
		return
	end
	if throttle then
		local data = getState(id)
		local now = globals.RealTime()
		if data.lastRejectTag == tag and (now - data.lastRejectLogTime) < REJECT_LOG_INTERVAL_S then
			return
		end
		data.lastRejectTag = tag
		data.lastRejectLogTime = now
	end
	print(string.format("[DoubleTap] %s reject [%s]: %s", id, tag, detail))
end

local function isWatchingForBurst(id)
	local data = getState(id)
	if data.lastDamageTick <= 0 then
		return false
	end
	local elapsed = globals.TickCount() - data.lastDamageTick
	return elapsed >= 0 and elapsed <= getConfirmWindowTicks()
end

local function _collectSimTimeSec(_, record)
	local simTime = record[HistoryManager.Fields.SimulationTime]
	if simTime then
		_simTimes[#_simTimes + 1] = simTime
	end
end

-- Same delta pipeline as fake_lag.lua (seconds between samples, then ticks).
local function buildDeltaTicksFromSimHistory()
	local deltaTicks = {}
	for i = 1, #_simTimes - 1 do
		local deltaSec = _simTimes[i] - _simTimes[i + 1]
		if deltaSec > 0 and deltaSec <= MAX_SIMTIME_DELTA_SEC then
			deltaTicks[#deltaTicks + 1] = timeToTicks(deltaSec)
		end
	end
	return deltaTicks
end

local function clearStaleBurstState(data, curTick)
	if data.lastBurstTick <= 0 then
		return
	end
	if (curTick - data.lastBurstTick) > getConfirmWindowTicks() then
		data.lastBurstTick = 0
		data.lastBurstAmount = 0
	end
end

local function addCappedDtEvidence(id, wantedWeight)
	local cap = Evidence.GetMethodScoreCap("double_tap")
	if cap <= 0 then
		cap = Evidence.GetMethodScoreCap("warp_dt")
	end
	local current = Evidence.GetMethodWeight(id, "double_tap")
	if current <= 0 then
		current = Evidence.GetMethodWeight(id, "warp_dt")
	end
	local remaining = cap - current
	if remaining <= 0 then
		logDtReject(id, "evidence_cap", string.format(
			"at cap (current=%.1f cap=%.1f wanted=%.1f)", current, cap, wantedWeight))
		return 0
	end
	local actual = math.min(wantedWeight, remaining)
	Evidence.AddEvidence(id, "double_tap", actual)
	return actual
end

local function tryCreditDtCorrelation(id, burstAmount, burstTick, damageTick, reason)
	local data = getState(id)
	local confirmWindow = getConfirmWindowTicks()
	local delayAfterDmg = burstTick - damageTick
	local delayAfterBurst = damageTick - burstTick
	local elapsed
	if delayAfterDmg >= 0 and delayAfterDmg <= confirmWindow then
		elapsed = delayAfterDmg
	elseif delayAfterBurst >= 0 and delayAfterBurst <= confirmWindow then
		elapsed = delayAfterBurst
	else
		logDtReject(id, "timing", string.format(
			"%s burst=%d dmgTick=%d burstTick=%d dmg→burst=%d burst→dmg=%d window=%d",
			reason, burstAmount, damageTick, burstTick, delayAfterBurst, delayAfterDmg, confirmWindow))
		return 0
	end

	local now = globals.RealTime()
	local cooldownLeft = DT_EVIDENCE_COOLDOWN_S - (now - data.lastBurstEvidenceTime)
	if cooldownLeft > 0 then
		logDtReject(id, "cooldown", string.format(
			"%s burst=%d delay=%d wait=%.2fs", reason, burstAmount, elapsed, cooldownLeft))
		return 0
	end

	local k = math.log(DT_EVIDENCE_MAX_MULT) / math.max(1, confirmWindow)
	local mult = DT_EVIDENCE_MAX_MULT * math.exp(-k * elapsed)
	local weight = DT_EVIDENCE_WEIGHT * mult

	data.lastBurstEvidenceTime = now
	local added = addCappedDtEvidence(id, weight)
	if added > 0 then
		if isDtLogEnabled() or Common.IsDebugEnabled() then
			print(string.format(
				"[DoubleTap] %s %s (burst=%d ticks, delay=%d) -> evidence +%.1f",
				id, reason, burstAmount, elapsed, added))
		end
	elseif weight > 0 then
		logDtReject(id, "evidence_add", string.format(
			"%s wanted=%.1f but AddEvidence returned 0", reason, weight))
	end
	return added
end

local function countSimilarBursts(deltaTicks, burstAmount)
	local similarCount = -1
	for i = 1, #deltaTicks do
		if math.abs(deltaTicks[i] - burstAmount) <= BURST_REPEAT_TOLERANCE then
			similarCount = similarCount + 1
		end
	end
	return similarCount
end

local function logBurstScanFailure(id, tag, detail)
	if isWatchingForBurst(id) then
		logDtReject(id, tag, detail, true)
	end
end

local function findRecentDtBurst(id)
	local history = HistoryManager.GetPlayerHistory(id)
	if not history or history._count < 2 then
		logBurstScanFailure(id, "no_history", string.format(
			"history missing or count=%s", history and tostring(history._count) or "nil"))
		return 0, 1, {}
	end

	for k = 1, #_simTimes do
		_simTimes[k] = nil
	end
	HistoryManager.ForEachRecordNewestFirst(history, nil, _collectSimTimeSec)
	if #_simTimes < 2 then
		logBurstScanFailure(id, "no_simtimes", string.format(
			"simtime samples=%d (need >=2)", #_simTimes))
		return 0, 1, {}
	end

	local deltaTicks = buildDeltaTicksFromSimHistory()
	if #deltaTicks < 1 then
		logBurstScanFailure(id, "no_deltas", string.format(
			"simtime samples=%d but no positive deltas", #_simTimes))
		return 0, 1, {}
	end

	local burstMin, burstMax = getBurstThresholds()
	local scanDepth = isWatchingForBurst(id) and WATCHING_DT_BURST_SCAN or RECENT_DT_BURST_SCAN
	local scanLimit = math.min(scanDepth, #deltaTicks)
	local sawDtBand = false
	local rhythmBlocked = nil
	local maxInScan = 0
	local skipRhythm = isWatchingForBurst(id)

	for index = 1, scanLimit do
		local burstAmount = deltaTicks[index]
		if burstAmount > maxInScan then
			maxInScan = burstAmount
		end
		if burstAmount >= burstMin and burstAmount < burstMax then
			sawDtBand = true
			local similar = countSimilarBursts(deltaTicks, burstAmount)
			if skipRhythm or similar < 2 then
				return burstAmount, index, deltaTicks
			end
			if not rhythmBlocked then
				rhythmBlocked = string.format(
					"idx=%d burst=%d similar=%d (>=2 in history)",
					index, burstAmount, similar + 1)
			end
		end
	end

	if rhythmBlocked then
		logBurstScanFailure(id, "rhythm", rhythmBlocked .. " | deltas=" .. formatDeltaPreview(deltaTicks, 8))
	else
		logBurstScanFailure(id, "no_dt_band", string.format(
			"scan=%d band=[%d,%d) sawDtBand=%s maxInScan=%d deltas=%s",
			scanLimit, burstMin, burstMax, tostring(sawDtBand), maxInScan, formatDeltaPreview(deltaTicks, 8)))
	end

	return 0, 1, deltaTicks
end

local function onBurstDetected(id, burstAmount, curTick, burstIndex)
	local data = getState(id)
	local signature = burstAmount * 100 + (burstIndex or 1)
	if data.lastBurstSignature == signature then
		return
	end
	data.lastBurstSignature = signature

	local burstTick = curTick
	DoubleTap.MarkDtRelease(id)

	if data.lastDamageTick > 0 then
		local damageTick = data.lastDamageTick
		local added = tryCreditDtCorrelation(id, burstAmount, burstTick, damageTick, "burst after dmg")
		data.lastDamageTick = 0
		data.lastBurstTick = 0
		data.lastBurstAmount = 0
		if added <= 0 and isDtLogEnabled() then
			logDtReject(id, "burst_after_dmg", string.format(
				"burst=%d dmgTick=%d burstTick=%d (see prior reject)",
				burstAmount, damageTick, burstTick))
		end
		return
	end

	data.lastBurstTick = burstTick
	data.lastBurstAmount = burstAmount
	if isDtLogEnabled() then
		logDtReject(id, "burst_no_pending_dmg", string.format(
			"burst=%d at tick=%d (waiting for hit)", burstAmount, burstTick), true)
	end
end

function DoubleTap.ProcessPlayer(playerState)
	if not isEnabled() then
		return
	end
	if Fetcher.State.isRunning then
		return
	end
	if Common.GetConnectionStabilityBlockReason()
		and not (Common.IsDebugEnabled() and Common.IsLocalListenServer()) then
		return
	end
	if not playerState or not playerState.pdata or not playerState.id then
		return
	end

	local id = playerState.id
	if id:sub(1, 4) == "BOT_" then
		return
	end

	local localID = PlayerCache.GetLocalID()
	if localID and id == localID and not Common.IsDebugEnabled() then
		return
	end

	if not playerState.pdata.isAlive then
		return
	end

	DetectionConfig.RecordHistory(playerState.wrap, "DoubleTap")

	local curTick = globals.TickCount()
	clearStaleBurstState(getState(id), curTick)

	local burstAmount, burstIndex = findRecentDtBurst(id)
	if burstAmount == 0 then
		return
	end

	cleanBurstTable(curTick)
	recordBurstTick(curTick, id)

	if isInHitchWindow(curTick) then
		return
	end

	if isServerHitch(curTick) then
		lastServerHitchTick = curTick
		if isDtLogEnabled() then
			print(string.format(
				"[DoubleTap] server hitch suppressed burst for %s (tick=%d)",
				id, curTick))
		end
		return
	end

	onBurstDetected(id, burstAmount, curTick, burstIndex)
end

function DoubleTap.Tick()
end

Events.Subscribe("OnHitscanHit", function(hit)
	if not isEnabled() then
		return
	end

	local attackerID = hit.attackerID
	local curTick    = hit.tickCount
	local data       = getState(attackerID)
	clearStaleBurstState(data, curTick)

	if data.lastBurstTick > 0 then
		local burstAmount = data.lastBurstAmount
		local burstTick = data.lastBurstTick
		local added = tryCreditDtCorrelation(
			attackerID,
			burstAmount,
			burstTick,
			curTick,
			"dmg after burst")
		data.lastBurstTick = 0
		data.lastBurstAmount = 0
		data.lastBurstSignature = nil
		if added <= 0 and isDtLogEnabled() then
			logDtReject(attackerID, "dmg_after_burst", string.format(
				"burst=%d burstTick=%d dmgTick=%d (see prior reject)",
				burstAmount, burstTick, curTick))
		end
	end

	data.lastDamageTick = curTick

	if isDtLogEnabled() then
		print(string.format(
			"[DoubleTap] %s dealt dmg=%d — watching for burst within %d ticks",
			attackerID, hit.damage, getConfirmWindowTicks()))
	end
end)

local function onPlayerGone(id)
	playerState[id] = nil
	dtSuppressUntil[id] = nil
end

Events.Subscribe("OnPlayerDisconnect", onPlayerGone)
Events.Subscribe("OnPlayerRemoved", onPlayerGone)

return DoubleTap
