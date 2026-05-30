--[[ detectors/warp_dt.lua
     Double Tap only (not generic warp — too noisy).

     DT = choke → unchoke → ~24 tick simtime jump (66 Hz). Fake lag stays below 22 ticks.

     DT cycle (temp-entity fire tracking):
       1. Shot (CTEFireBullets) — arms detection.
       2. Warp — simtime burst 24–33 ticks.
       3. Shot again / damage in the next few ticks (warp window speed pump).

     Evidence only when all three line up; no shot = no flag.
]]

local Evidence                              = require("Cheater_Detection.Core.Evidence_system")
local Events                                = require("Cheater_Detection.Core.Events")
local PlayerCache                           = require("Cheater_Detection.Core.player_cache")
local Common                                = require("Cheater_Detection.Utils.Common")
local Fetcher                               = require("Cheater_Detection.Database.Fetcher")
local HistoryManager                        = require("Cheater_Detection.Utils.HistoryManager")
local DetectionConfig                       = require("Cheater_Detection.Utils.DetectionConfig")
local FireTickTracker                       = require("Cheater_Detection.Core.FireTickTracker")

local WarpDT                                = {}

-- ── constants ──────────────────────────────────────────────────────────────

-- Hitch = multiple *humans* bursting same tick (bots on itemtest choke constantly).
local SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD = 3

-- At 66 Hz: fake lag releases stay below 22 ticks; DT is bounded by
-- sv_maxusrcmdprocessticks (~24). 33 gives headroom; anything larger is a merged
-- double-release artifact or real packet loss, NOT a double tap.
local BURST_MIN_TICKS_66HZ                  = 24.0
local FAKELAG_MAX_CHOKE_TICKS_66HZ          = 21.0
local BURST_MAX_TICKS_66HZ                  = 34.0 -- DT window is 24–33 ticks (d < max)
local WARP_COOLDOWN_TICKS_66HZ              = 24.0 -- min spacing between ProcessPlayer burst flags
local FAKE_LAG_SUPPRESS_TICKS_66HZ          = 66.0 -- ~1s: no fake_lag scoring after DT release

-- Pre-burst must cover choke (≤21 ticks) plus margin; weapon_fire often only arrives on release.
local PRE_BURST_FIRE_TICKS_66HZ             = FAKELAG_MAX_CHOKE_TICKS_66HZ + 12.0
local POST_BURST_WINDOW_TICKS_66HZ          = 14.0 -- post-warp shots / damage register here

local DT_EVIDENCE_WEIGHT                    = 30.0
local DT_EVIDENCE_MAX_MULT                  = 5.0
local DT_EVIDENCE_COOLDOWN_S                = 0.35 -- short; separate DT cycles use tick cooldown

-- Cached tick calculations (recalculated when tick interval changes)
local cachedTickInterval                    = nil
local cachedBurstMinTicks                   = nil
local cachedBurstMaxTicks                   = nil

local function getBurstThresholds()
	local tickInt = globals.TickInterval()
	if tickInt ~= cachedTickInterval then
		cachedTickInterval = tickInt
		-- Scaled to actual server tickrate: ticks = time / tickInterval
		cachedBurstMinTicks = math.floor(BURST_MIN_TICKS_66HZ / 66.0 / tickInt + 0.5)
		cachedBurstMaxTicks = math.floor(BURST_MAX_TICKS_66HZ / 66.0 / tickInt + 0.5)
		if cachedBurstMinTicks <= 0 or cachedBurstMaxTicks <= cachedBurstMinTicks then
			print("[WarpDT ERROR] Invalid burst thresholds (min=" ..
				tostring(cachedBurstMinTicks) .. ", max=" .. tostring(cachedBurstMaxTicks) .. "), using defaults")
			cachedBurstMinTicks = math.floor(BURST_MIN_TICKS_66HZ)
			cachedBurstMaxTicks = math.floor(BURST_MAX_TICKS_66HZ)
		end
	end
	return cachedBurstMinTicks, cachedBurstMaxTicks
end

-- Shared tick-band limits for fake_lag.lua (keep DT vs FL boundary aligned).
function WarpDT.GetDtBurstMinTicks()
	local burstMin, _ = getBurstThresholds()
	return burstMin
end

function WarpDT.GetFakeLagMaxChokeTicks()
	return math.floor(FAKELAG_MAX_CHOKE_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
end

function WarpDT.GetFakeLagMinChokeTicks()
	return math.max(8, math.floor(8.0 / 66.0 / globals.TickInterval() + 0.5))
end

function WarpDT.IsDtSizedBurst(tickDelta)
	if not tickDelta or tickDelta <= 0 then
		return false
	end
	local burstMin, burstMax = getBurstThresholds()
	return tickDelta >= burstMin and tickDelta < burstMax
end

-- ── state ──────────────────────────────────────────────────────────────────

local playerState       = {}
local watchUntil        = {}
local dtSuppressUntil   = {} -- [id] = tick until fake_lag should ignore this player
local _simTimes         = {}
local _deltaTicks       = {}

-- Sample simtime while a shooter was recently active (fire arms the window).
local ACTIVITY_WINDOW_TICKS_66HZ            = 20.0


-- Server-hitch suppression: track which ticks had simultaneous bursts
local burstThisTick       = {}
local lastBurstCleanTick  = 0
local lastServerHitchTick = -math.huge

local lastDtDebugLogTime  = 0
local dtDebugFireCount    = 0
local dtDebugBurstCount   = 0
local dtDebugNoPreFire    = 0

-- ── helpers ────────────────────────────────────────────────────────────────

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
	if not burstThisTick[tick] then burstThisTick[tick] = {} end
	burstThisTick[tick][#burstThisTick[tick] + 1] = id
end

local function isHumanSteamID(id)
	return type(id) == "string" and id:match("^7656119%d+$") ~= nil
end

local function countHumanBurstsOnTick(tick)
	local list = burstThisTick[tick]
	if not list then return 0 end
	local n = 0
	for i = 1, #list do
		if isHumanSteamID(list[i]) then
			n = n + 1
		end
	end
	return n
end

local function isServerHitch(tick)
	return countHumanBurstsOnTick(tick) >= SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD
end

local function cleanBurstTable(curTick)
	if (curTick - lastBurstCleanTick) < 4 then return end
	lastBurstCleanTick = curTick
	for tick in pairs(burstThisTick) do
		if (curTick - tick) > 3 then burstThisTick[tick] = nil end
	end
end

local function getState(id)
	if not playerState[id] then
		playerState[id] = {
			lastDamageTick           = 0,
			lastBurstTick            = 0,
			lastBurstEvidenceTime    = 0,
			lastHitCountEvidenceTime = 0,
			lastProcessBurstTick     = 0,
			lastCreditedBurstTick    = 0,
			lastFiredTick            = 0,
			lastDamageTick           = 0,
			lastBurstAmount          = 0,
			awaitingPostConfirm      = false,
			preFireTick              = 0,
			firesOnBurstTick         = 0,
			postBurstHits            = 0,
			prevSimTick              = nil,
			lastSimTick              = nil,
			lastSampleTick           = 0,
		}
	end
	return playerState[id]
end

local function getFakeLagSuppressTicks()
	return math.floor(FAKE_LAG_SUPPRESS_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
end

local function getPreBurstFireTicks()
	return math.floor(PRE_BURST_FIRE_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
end

local function getPostBurstWindowTicks()
	return math.floor(POST_BURST_WINDOW_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
end

local function getActivityWindowTicks()
	return math.floor(ACTIVITY_WINDOW_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
end

function WarpDT.ShouldSuppressFakeLag(id)
	local untilTick = dtSuppressUntil[id]
	if not untilTick then
		return false
	end
	local curTick = globals.TickCount()
	if curTick > untilTick then
		dtSuppressUntil[id] = nil
		return false
	end
	return true
end

local function markDtRelease(id, curTick)
	dtSuppressUntil[id] = curTick + getFakeLagSuppressTicks()
end

local function _collectSimTime(_, record)
	local simTime = record[HistoryManager.Fields.SimulationTime]
	if simTime then
		_simTimes[#_simTimes + 1] = simTime
	end
end

local function watchPlayer(id, curTick)
	watchUntil[id] = curTick + getActivityWindowTicks()
end

local function isEnabled()
	return Common.IsDoubleTapDetectionEnabled()
end

local function isDtLogEnabled()
	return Common.IsLogCategoryEnabled("DoubleTap")
end

local function shouldLogDtDebug()
	return Common.IsDebugEnabled() or isDtLogEnabled()
end

local function logDtDebug(msg)
	if not shouldLogDtDebug() then return end
	local now = globals.RealTime()
	if (now - lastDtDebugLogTime) < 0.35 then return end
	lastDtDebugLogTime = now
	print(msg)
end

function WarpDT.MarkDtRelease(id)
	if not id then
		return
	end
	markDtRelease(id, globals.TickCount())
end

local function isPlayerWatched(id)
	local untilTick = watchUntil[id]
	if not untilTick then
		return false
	end
	return globals.TickCount() <= untilTick
end

function WarpDT.IsPlayerWatched(id)
	return isPlayerWatched(id)
end

local function buildNewestDeltas(id)
	for k = 1, #_simTimes do
		_simTimes[k] = nil
	end
	for k = 1, #_deltaTicks do
		_deltaTicks[k] = nil
	end

	local history = HistoryManager.GetPlayerHistory(id)
	if not history or history._count < 2 then
		return _deltaTicks, 0
	end

	HistoryManager.ForEachRecordNewestFirst(history, nil, _collectSimTime)
	if #_simTimes < 2 then
		return _deltaTicks, 0
	end

	local deltas = _deltaTicks
	for i = 1, #_simTimes - 1 do
		local delta = _simTimes[i] - _simTimes[i + 1]
		if delta > 0 then
			deltas[#deltas + 1] = timeToTicks(delta)
		end
	end
	return deltas, deltas[1] or 0
end

-- Newest step only — avoids re-flagging an old burst sitting in the ring buffer.
local function findNewestHistoryBurst(id)
	local history = HistoryManager.GetPlayerHistory(id)
	if not history or history._count < 2 then
		return 0
	end

	for k = 1, #_simTimes do
		_simTimes[k] = nil
	end
	HistoryManager.ForEachRecordNewestFirst(history, nil, _collectSimTime)
	if #_simTimes < 2 then
		return 0
	end

	local delta = _simTimes[1] - _simTimes[2]
	if delta <= 0 then
		return 0
	end

	local d = timeToTicks(delta)
	local burstMin, burstMax = getBurstThresholds()
	if d >= burstMin and d < burstMax then
		return d
	end
	return 0
end

local function addCappedDtEvidence(id, wantedWeight)
	local cap = Evidence.GetMethodScoreCap("warp_dt")
	local current = Evidence.GetMethodWeight(id, "warp_dt")
	local remaining = cap - current
	if remaining <= 0 then
		return 0
	end
	local actual = math.min(wantedWeight, remaining)
	Evidence.AddEvidence(id, "warp_dt", actual)
	return actual
end

local function canCreditDtEvidence(id, curTick)
	local data = getState(id)
	local cooldownTicks = math.floor(WARP_COOLDOWN_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
	if data.lastCreditedBurstTick > 0 and (curTick - data.lastCreditedBurstTick) <= cooldownTicks then
		return false
	end
	local now = globals.RealTime()
	if (now - data.lastBurstEvidenceTime) < DT_EVIDENCE_COOLDOWN_S then
		return false
	end
	return true
end

local function getPreBurstFireTick(id, burstTick)
	local window = getPreBurstFireTicks()
	local snap = FireTickTracker.GetRecentFire(id, window)
	if snap and snap.tick <= burstTick and (burstTick - snap.tick) <= window then
		return snap.tick
	end
	local data = getState(id)
	if data.lastFiredTick > 0
		and data.lastFiredTick <= burstTick
		and (burstTick - data.lastFiredTick) <= window then
		return data.lastFiredTick
	end
	return nil
end

-- Server hitscan damage while holding fire (minigun); works when weapon_fire is choked away.
local function getPreBurstCombatTick(id, burstTick)
	local fireTick = getPreBurstFireTick(id, burstTick)
	if fireTick then
		return fireTick, "shot"
	end
	local data = getState(id)
	local window = getPreBurstFireTicks()
	if data.lastDamageTick > 0
		and data.lastDamageTick <= burstTick
		and (burstTick - data.lastDamageTick) <= window then
		return data.lastDamageTick, "hitscan"
	end
	return nil, nil
end

-- Post-warp shot: later tick, or same tick as warp if fire tick is after pre-fire
-- or a second CTEFireBullets on the warp tick (shot → warp → shot in one tick).
local function isPostWarpFire(data, tick)
	if not data.awaitingPostConfirm or data.lastBurstTick <= 0 then
		return false
	end
	if tick > data.lastBurstTick then
		return true
	end
	if tick < data.lastBurstTick then
		return false
	end
	if data.preFireTick > 0 and tick > data.preFireTick then
		return true
	end
	return (data.firesOnBurstTick or 0) >= 2
end

local function tryCreditDtEvidence(id, burstAmount, curTick, reason)
	if not canCreditDtEvidence(id, curTick) then
		return 0
	end

	local data = getState(id)
	local elapsed = math.max(0, curTick - data.lastBurstTick)
	local postWindow = getPostBurstWindowTicks()
	local k = math.log(DT_EVIDENCE_MAX_MULT) / math.max(1, postWindow)
	local timeMult = DT_EVIDENCE_MAX_MULT * math.exp(-k * elapsed)
	local weight = math.min(40, burstAmount * 1.2) * timeMult

	local extraHits = data.postBurstHits or 0
	if extraHits > 1 then
		weight = weight * (1 + 0.2 * (extraHits - 1))
	end

	data.lastCreditedBurstTick = curTick
	data.lastBurstEvidenceTime = globals.RealTime()
	data.awaitingPostConfirm = false

	local added = addCappedDtEvidence(id, weight)
	if added > 0 then
		local msg = string.format(
			"[DoubleTap] %s packet burst: %d ticks (%s, +%d post hits) → evidence +%.1f",
			id, burstAmount, reason, extraHits, added)
		if isDtLogEnabled() or Common.IsDebugEnabled() then
			print(msg)
		end
	end
	return added
end

local function confirmPostWarpActivity(id, curTick, reason)
	local data = getState(id)
	if not data.awaitingPostConfirm or data.lastBurstTick <= 0 then
		return 0
	end
	local elapsed = curTick - data.lastBurstTick
	if elapsed < 0 or elapsed > getPostBurstWindowTicks() then
		return 0
	end
	return tryCreditDtEvidence(id, data.lastBurstAmount, curTick, reason)
end

local function handleWarpBurst(id, burstAmount, curTick)
	local data = getState(id)

	if data.awaitingPostConfirm and data.lastBurstTick == curTick then
		return
	end

	data.lastBurstTick = curTick
	data.lastBurstAmount = burstAmount
	data.lastProcessBurstTick = curTick
	markDtRelease(id, curTick)

	local preCombatTick, preCombatKind = getPreBurstCombatTick(id, curTick)
	if not preCombatTick then
		data.awaitingPostConfirm = false
		dtDebugNoPreFire = dtDebugNoPreFire + 1
		if shouldLogDtDebug() then
			logDtDebug(string.format(
				"[DoubleTap] %s DT-sized burst (%d ticks) ignored — no pre-warp combat (shot or hitscan within %d ticks)",
				id, burstAmount, getPreBurstFireTicks()))
		end
		return
	end

	dtDebugBurstCount = dtDebugBurstCount + 1

	data.awaitingPostConfirm = true
	data.preFireTick = preCombatTick
	data.postBurstHits = 0
	data.firesOnBurstTick = 0
	if data.lastFiredTick == curTick then
		data.firesOnBurstTick = 1
	end

	if Common.IsDebugEnabled() or isDtLogEnabled() then
		print(string.format(
			"[DoubleTap] %s warp %d ticks armed (pre-%s tick %d, awaiting post shot/hit)",
			id, burstAmount, preCombatKind or "?", preCombatTick))
	end
end

-- Fire temp-ent can arrive after CreateMove; re-check history once shot is known.
local function reconcileBurstAfterFire(id, fireTick)
	local burstAmount = findNewestHistoryBurst(id)
	if burstAmount == 0 then
		return
	end
	handleWarpBurst(id, burstAmount, globals.TickCount())
end

local function sampleSimBurst(pState, curTick)
	local id = pState.id
	local data = getState(id)
	if data.lastSampleTick == curTick then
		return
	end
	data.lastSampleTick = curTick

	local simTime = pState.wrap:GetSimulationTime()
	if type(simTime) ~= "number" then return end
	local simTick = timeToTicks(simTime)

	local burstAmount = 0
	if data.prevSimTick then
		local d = simTick - data.prevSimTick
		local burstMin, burstMax = getBurstThresholds()
		if d >= burstMin and d < burstMax then
			burstAmount = d
		end
	end
	data.prevSimTick = data.lastSimTick
	data.lastSimTick = simTick
	if burstAmount == 0 then return end

	recordBurstTick(curTick, id)
	if isInHitchWindow(curTick) then return end

	local isDebug = isDtLogEnabled()
	if isServerHitch(curTick) then
		lastServerHitchTick = curTick
		if isDebug then
			print(string.format(
				"[DoubleTap] server hitch suppressed burst for %s (tick=%d, humans=%d)",
				id, curTick, countHumanBurstsOnTick(curTick)))
		end
		return
	end

	handleWarpBurst(id, burstAmount, curTick)
end

function WarpDT.GetDebugStats()
	return {
		enabled            = isEnabled(),
		fetchBlocking      = Fetcher.State.isRunning == true,
		connectionBlock    = Common.GetConnectionStabilityBlockReason(),
		localListenBypass  = Common.IsDebugEnabled() and Common.IsLocalListenServer(),
		fireEventsSeen     = dtDebugFireCount,
		dtBurstsArmed      = dtDebugBurstCount,
		burstsNoPreFire    = dtDebugNoPreFire,
	}
end

function WarpDT.ProcessPlayer(playerState)
	if not isEnabled() then
		return
	end
	if Fetcher.State.isRunning then
		logDtDebug("[DoubleTap] paused — database fetch in progress")
		return
	end
	local connBlock = Common.GetConnectionStabilityBlockReason()
	if connBlock and not (Common.IsDebugEnabled() and Common.IsLocalListenServer()) then
		logDtDebug("[DoubleTap] paused — connection unstable: " .. connBlock)
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

	DetectionConfig.RecordHistory(playerState.wrap, "FakeLag")

	local curTick = globals.TickCount()
	cleanBurstTable(curTick)

	-- Live simtime step every tick (history-only missed same-tick DT).
	sampleSimBurst(playerState, curTick)
end

function WarpDT.Tick()
	if not isEnabled() then return end
	if Fetcher.State.isRunning then return end
	if Common.GetConnectionStabilityBlockReason()
		and not (Common.IsDebugEnabled() and Common.IsLocalListenServer()) then
		return
	end

	local curTick = globals.TickCount()
	cleanBurstTable(curTick)

	for id, untilTick in pairs(watchUntil) do
		if curTick > untilTick then
			watchUntil[id] = nil
		else
			local pState = PlayerCache.GetByID(id)
			if not pState or not pState.pdata.isAlive then
				watchUntil[id] = nil
			else
				sampleSimBurst(pState, curTick)
			end
		end
	end
end

-- ── damage recording (via CombatEvents hub) ──────────────────────────────
-- Subscribes to the pre-resolved OnHitscanHit event published by
-- Core/CombatEvents.lua — entity lookup and weapon classification are
-- already done once for all detectors.

Events.Subscribe("OnPlayerFired", function(fire)
	if not isEnabled() then
		return
	end

	local id = fire.shooterID
	dtDebugFireCount = dtDebugFireCount + 1
	if shouldLogDtDebug() and (dtDebugFireCount <= 3 or dtDebugFireCount % 25 == 0) then
		print(string.format("[DoubleTap] fire tracked: %s tick=%d src=%s (total=%d)",
			id, fire.tick or -1, tostring(fire.source or "?"), dtDebugFireCount))
	end
	local tick = fire.tick
	local data = getState(id)

	data.lastFiredTick = tick
	watchPlayer(id, tick)

	local pState = PlayerCache.GetByID(id)
	if pState and pState.pdata and pState.pdata.isAlive then
		DetectionConfig.RecordHistory(pState.wrap, "FakeLag")
		reconcileBurstAfterFire(id, tick)
	end

	if data.awaitingPostConfirm and data.lastBurstTick > 0 and tick == data.lastBurstTick then
		data.firesOnBurstTick = (data.firesOnBurstTick or 0) + 1
	end

	if isPostWarpFire(data, tick) then
		confirmPostWarpActivity(id, tick, "post-warp shot")
	end
end)

Events.Subscribe("OnHitscanHit", function(hit)
	if not isEnabled() then
		return
	end

	local attackerID = hit.attackerID
	local curTick    = hit.tickCount
	local data       = getState(attackerID)

	data.lastDamageTick = curTick

	watchPlayer(attackerID, curTick)

	local attackerState = PlayerCache.GetByID(attackerID)
	if attackerState and attackerState.pdata.isAlive then
		DetectionConfig.RecordHistory(attackerState.wrap, "FakeLag")
		sampleSimBurst(attackerState, curTick)
	end

	if data.awaitingPostConfirm and data.lastBurstTick > 0 then
		local elapsed = curTick - data.lastBurstTick
		if elapsed >= 0 and elapsed <= getPostBurstWindowTicks() then
			data.postBurstHits = (data.postBurstHits or 0) + 1
			confirmPostWarpActivity(attackerID, curTick, "post-warp damage")
		end
	end
end)


-- ── cleanup ────────────────────────────────────────────────────────────────

local function onPlayerGone(id)
	playerState[id] = nil
	watchUntil[id] = nil
	dtSuppressUntil[id] = nil
end

Events.Subscribe("OnPlayerDisconnect", onPlayerGone)
Events.Subscribe("OnPlayerRemoved", onPlayerGone)

return WarpDT
