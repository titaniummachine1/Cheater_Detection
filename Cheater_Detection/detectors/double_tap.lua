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

local DoubleTap = {}

local SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD = 3

local BURST_MIN_TICKS_66HZ         = 24.0
local FAKELAG_MAX_CHOKE_TICKS_66HZ   = 21.0
local BURST_MAX_TICKS_66HZ         = 34.0
local BURST_REPEAT_TOLERANCE       = 8
local RECENT_DT_BURST_SCAN         = 20
local WATCHING_DT_BURST_SCAN       = 40
local DT_CONFIRM_WINDOW_TICKS_66HZ = 48.0
local FAKE_LAG_SUPPRESS_TICKS_66HZ   = 66.0

-- Flat ~30 per correlated burst (one "usage"). Cap 300 ≈ 10 usages before cheater threshold.
local DT_EVIDENCE_WEIGHT          = 30.0
local DT_LATE_DELAY_PENALTY_MAX   = 0.2 -- up to -20% weight at end of 48t confirm window
local DT_EVIDENCE_COOLDOWN_S      = 0.5
local REJECT_LOG_INTERVAL_S       = 0.35
local HURT_LOG_INTERVAL_S         = 1.0
local WATCH_BURST_SCAN_INTERVAL   = 4 -- ticks between scans while waiting for post-hit burst
local MAX_HURT_BURST_SCANS_TICK   = 10 -- routine cap per game tick (busy fights)
local MAX_HURT_BURST_SCANS_HOT    = 14 -- absolute cap; hot shooters may exceed routine budget

local DT_FOCUS_PRIORITY_WATCH     = 3 -- post-hit: waiting for simtime burst
local DT_FOCUS_PRIORITY_BURST     = 2 -- burst seen: waiting for hurt
local DT_FOCUS_PRIORITY_SUSPECT   = 1 -- already has double_tap evidence
local DT_FOCUS_PRIORITY_ROUTINE   = 0 -- under cap, background scan

local cachedTickInterval  = nil
local cachedBurstMinTicks = nil
local cachedBurstMaxTicks  = nil
local cachedConfirmTicks  = nil

local playerState         = {}
local dtSuppressUntil     = {}
local burstThisTick       = {}
local lastBurstCleanTick  = 0
local lastServerHitchTick = -math.huge

-- One burst-scan ProcessPlayer per game tick; hot suspects preempt the round-robin pool.
local focusTick           = -1
local focusedPlayerId     = nil
local hotRoundRobinIndex  = 0
local warmRoundRobinIndex = 0
local coldRoundRobinIndex = 0
local hurtBurstScanTick   = -1
local hurtBurstScansUsed  = 0

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
	return math.max(8, math.floor(8.0 / 66.0 / globals.TickInterval() + 0.5))
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

-- Legacy API for fake_lag; must stay false (true blocked all FL while shooting on main).
function DoubleTap.IsPlayerWatched(_id)
	return false
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
			lastHurtLogTime       = 0,
			lastHurtBurstScanTick = 0,
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

local function getDtEvidenceWeight(id)
	local weight = Evidence.GetMethodWeight(id, "double_tap")
	if weight <= 0 then
		weight = Evidence.GetMethodWeight(id, "warp_dt")
	end
	return weight
end

local function getDtEvidenceCap()
	local cap = Evidence.GetMethodScoreCap("double_tap")
	if cap <= 0 then
		cap = Evidence.GetMethodScoreCap("warp_dt")
	end
	return cap
end

local function getDtFocusPriority(id)
	if not id or id:sub(1, 4) == "BOT_" then
		return -1
	end
	if isWatchingForBurst(id) then
		return DT_FOCUS_PRIORITY_WATCH
	end
	local data = getState(id)
	if data.lastBurstTick > 0 then
		return DT_FOCUS_PRIORITY_BURST
	end
	local weight = getDtEvidenceWeight(id)
	local cap = getDtEvidenceCap()
	if weight >= cap then
		return -1
	end
	if weight > 0 then
		return DT_FOCUS_PRIORITY_SUSPECT
	end
	return DT_FOCUS_PRIORITY_ROUTINE
end

local function pickRoundRobinId(pool, indexField)
	if #pool == 0 then
		return nil, indexField
	end
	local nextIndex = (indexField % #pool) + 1
	return pool[nextIndex], nextIndex
end

-- Among simultaneous hot shooters, prefer whoever hurt most recently; RR on ties.
local function pickHotPoolFocus(pool, rrIndex)
	local bestDamageTick = -1
	for i = 1, #pool do
		local damageTick = getState(pool[i]).lastDamageTick
		if damageTick > bestDamageTick then
			bestDamageTick = damageTick
		end
	end
	local tied = {}
	for i = 1, #pool do
		if getState(pool[i]).lastDamageTick == bestDamageTick then
			tied[#tied + 1] = pool[i]
		end
	end
	if #tied == 0 then
		return pickRoundRobinId(pool, rrIndex)
	end
	if #tied == 1 then
		return tied[1], rrIndex
	end
	return pickRoundRobinId(tied, rrIndex)
end

local function resetHurtBurstScanBudget(curTick)
	if hurtBurstScanTick ~= curTick then
		hurtBurstScanTick = curTick
		hurtBurstScansUsed = 0
	end
end

function DoubleTap.BeginDetectionTick(activePlayers, curTick)
	if not isEnabled() or focusTick == curTick then
		return
	end
	focusTick = curTick
	focusedPlayerId = nil
	resetHurtBurstScanBudget(curTick)

	if not activePlayers or #activePlayers == 0 then
		return
	end

	local hotPool, warmPool, coldPool = {}, {}, {}
	for i = 1, #activePlayers do
		local pState = activePlayers[i]
		local id = pState and pState.id
		if not id then
			goto continue
		end
		local priority = getDtFocusPriority(id)
		if priority == DT_FOCUS_PRIORITY_WATCH or priority == DT_FOCUS_PRIORITY_BURST then
			hotPool[#hotPool + 1] = id
		elseif priority == DT_FOCUS_PRIORITY_SUSPECT then
			warmPool[#warmPool + 1] = id
		elseif priority == DT_FOCUS_PRIORITY_ROUTINE then
			coldPool[#coldPool + 1] = id
		end
		::continue::
	end

	local chosenId
	if #hotPool > 0 then
		chosenId, hotRoundRobinIndex = pickHotPoolFocus(hotPool, hotRoundRobinIndex)
	elseif #warmPool > 0 then
		chosenId, warmRoundRobinIndex = pickRoundRobinId(warmPool, warmRoundRobinIndex)
	elseif #coldPool > 0 then
		chosenId, coldRoundRobinIndex = pickRoundRobinId(coldPool, coldRoundRobinIndex)
	end

	focusedPlayerId = chosenId
end

local function isFocusedPlayer(id)
	return focusedPlayerId ~= nil and id == focusedPlayerId
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

	-- No 5× mult on tight timing — that let 2 bursts ≈ suspicious (56+140). One usage ≈ 30.
	local delayFactor = 1.0 - DT_LATE_DELAY_PENALTY_MAX * (elapsed / math.max(1, confirmWindow))
	local weight = DT_EVIDENCE_WEIGHT * delayFactor

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

local function findRecentDtBurst(id, scanDepthOverride, quietOnMiss)
	local history = HistoryManager.GetPlayerHistory(id)
	if not history or history._count < 2 then
		if not quietOnMiss then
			logBurstScanFailure(id, "no_history", string.format(
				"history missing or count=%s", history and tostring(history._count) or "nil"))
		end
		return 0, 1, nil, 0
	end

	local burstMin, burstMax = getBurstThresholds()
	local scanDepth = scanDepthOverride
	if not scanDepth then
		scanDepth = isWatchingForBurst(id) and WATCHING_DT_BURST_SCAN or RECENT_DT_BURST_SCAN
	end
	local deltaTicks, deltaCount = HistoryManager.GetSimDeltaDeltas(history, scanDepth)
	if deltaCount < 1 then
		if not quietOnMiss then
			logBurstScanFailure(id, "no_deltas", string.format(
				"history count=%d but no simtime gaps", history._count))
		end
		return 0, 1, deltaTicks, 0
	end

	local scanLimit = math.min(scanDepth, deltaCount)
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
				return burstAmount, index, deltaTicks, deltaCount
			end
			if not rhythmBlocked then
				rhythmBlocked = string.format(
					"idx=%d burst=%d similar=%d (>=2 in history)",
					index, burstAmount, similar + 1)
			end
		end
	end

	if not quietOnMiss then
		if rhythmBlocked then
			logBurstScanFailure(id, "rhythm", rhythmBlocked .. " | deltas=" .. formatDeltaPreview(deltaTicks, 8))
		else
			logBurstScanFailure(id, "no_dt_band", string.format(
				"scan=%d band=[%d,%d) sawDtBand=%s maxInScan=%d deltas=%s",
				scanLimit, burstMin, burstMax, tostring(sawDtBand), maxInScan, formatDeltaPreview(deltaTicks, 8)))
		end
	end

	return 0, 1, deltaTicks, deltaCount
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

local function shouldScanBurstThisTick(id, curTick)
	if isFocusedPlayer(id) and getDtFocusPriority(id) >= DT_FOCUS_PRIORITY_BURST then
		return true
	end
	if not isWatchingForBurst(id) then
		return true
	end
	return (curTick % WATCH_BURST_SCAN_INTERVAL) == 0
end

local function tryDetectBurstForPlayer(id, curTick, forceScan)
	if not forceScan and not shouldScanBurstThisTick(id, curTick) then
		return
	end

	local scanDepth = forceScan and RECENT_DT_BURST_SCAN or nil
	local quietOnMiss = forceScan == true
	local burstAmount, burstIndex = findRecentDtBurst(id, scanDepth, quietOnMiss)
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

-- Hurt path: correlate every hit; burst scan at most once per attacker per tick (+ global cap).
local function tryHurtBurstScan(id, curTick)
	resetHurtBurstScanBudget(curTick)
	local data = getState(id)
	if data.lastHurtBurstScanTick == curTick then
		return
	end
	local scanCap = MAX_HURT_BURST_SCANS_TICK
	if getDtFocusPriority(id) >= DT_FOCUS_PRIORITY_WATCH then
		scanCap = MAX_HURT_BURST_SCANS_HOT
	end
	if hurtBurstScansUsed >= scanCap then
		return
	end
	data.lastHurtBurstScanTick = curTick
	hurtBurstScansUsed = hurtBurstScansUsed + 1
	tryDetectBurstForPlayer(id, curTick, true)
end

function DoubleTap.HasWork(playerState)
	if not isEnabled() then
		return false
	end
	if not playerState or not playerState.id then
		return false
	end
	local id = playerState.id
	if getDtFocusPriority(id) < 0 then
		return false
	end
	return isFocusedPlayer(id)
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

	local curTick = globals.TickCount()
	clearStaleBurstState(getState(id), curTick)
	tryDetectBurstForPlayer(id, curTick)
end

function DoubleTap.Tick()
	-- Focus is chosen in BeginDetectionTick (Main.lua) once per game tick.
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
	tryHurtBurstScan(attackerID, curTick)

	if isDtLogEnabled() then
		local now = globals.RealTime()
		if (now - data.lastHurtLogTime) >= HURT_LOG_INTERVAL_S then
			data.lastHurtLogTime = now
			print(string.format(
				"[DoubleTap] %s dealt dmg=%d — watching for burst within %d ticks",
				attackerID, hit.damage, getConfirmWindowTicks()))
		end
	end
end)

local function onPlayerGone(id)
	playerState[id] = nil
	dtSuppressUntil[id] = nil
	if focusedPlayerId == id then
		focusedPlayerId = nil
	end
end

Events.Subscribe("OnPlayerDisconnect", onPlayerGone)
Events.Subscribe("OnPlayerRemoved", onPlayerGone)

return DoubleTap
