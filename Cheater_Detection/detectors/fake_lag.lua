--[[ detectors/fake_lag.lua
     Fake lag (choke holds, rhythmic choke). Double Tap is separate: ~24t simtime
     release + hitscan hurt correlation in detectors/double_tap.lua (not this file).

     Detects excessive packet choking (Fake Lag) via two complementary methods:

     1. Rhythmic pattern ??? recent simulation-time deltas match a fixed choke
        interval (scaled tolerance). Fires evidence.

     2. Sustained high choke ??? most recent deltas stay large (e.g. steady 22-tick FL).

     3. Choke/release burst ??? simtime freeze then large release spike.

     4. Average choke-tick method (Rijin-derived) ??? computes the mean
        simulation-time gap in ticks across the entire history window.
        avg_choke_ticks >= AVG_CHOKE_THRESHOLD signals fakelag even when the
        pattern is irregular (e.g. random/adaptive lag).
        Fires Evidence.AddEvidence so it decays and stacks with other signals.
]]

local Constants                   = require("Cheater_Detection.Core.constants")
local G                           = require("Cheater_Detection.Utils.Globals")
local Common                      = require("Cheater_Detection.Utils.Common")
local Evidence                    = require("Cheater_Detection.Core.Evidence_system")
local Events                      = require("Cheater_Detection.Core.Events")
local HistoryManager              = require("Cheater_Detection.Utils.HistoryManager")
local DetectionConfig             = require("Cheater_Detection.Utils.DetectionConfig")
local Fetcher                     = require("Cheater_Detection.Database.Fetcher")
local PlayerCache                 = require("Cheater_Detection.Core.player_cache")
local DoubleTap                   = require("Cheater_Detection.detectors.double_tap")

local FakeLag                     = {}

-- ?????? constants ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
-- Normal gameplay advances simtime ~1 tick per update; 1???2 tick gaps are not fakelag.
local MIN_FAKELAG_CHOKE_TICKS     = 4
local FAKELAG_EVIDENCE_COOLDOWN_S = 1.0  -- was 2.0 ??? twice as many evidence refreshes
local RECENT_CHOKE_SAMPLE_COUNT   = 16
local STRONG_CHOKE_MIN_HIGH_TICKS = 8    -- was 10 ??? count 8+ tick gaps as choke
local STRONG_CHOKE_HIGH_RATIO     = 0.28 -- was 0.55 ??? ~half the window must be large gaps
local RHYTHM_MIN_EVENTS           = 6    -- was 8 ??? faster rhythmic match
local RHYTHM_CHECK_COUNT          = 16   -- only judge recent deltas (not the whole ring buffer)
local RHYTHM_MATCH_RATIO          = 0.5  -- was 0.75
local RHYTHM_TOLERANCE_TICKS      = 2    -- floor tolerance for small choke values
local SUSTAINED_SAMPLE_COUNT      = 20   -- recent samples for steady high-choke fakelag
local SUSTAINED_MATCH_RATIO       = 0.45 -- was 0.65 ??? triggers on mixed 22+17 style choke
local SUSTAINED_MIN_AVG_TICKS     = 8    -- average choke in that window (22-tick FL ??? 22)

-- Rijin-derived: avg choke-tick threshold
-- avg simtime gap >= 2 ticks across the window = fakelag signal
local AVG_CHOKE_THRESHOLD         = 4.2
local AVG_CHOKE_MIN_SAMPLES       = 4                                      -- require more samples for average calculation
local FAKELAG_EVIDENCE_PER_USAGE  = 5.0                                    -- flat per hit; cap/decay in Evidence_system
local BURST_CHOKE_MIN_TICKS       = 8                                      -- ignore normal single-tick jitter
local BURST_CONFIRM_EVENTS        = 4                                      -- consecutive large deltas after a stall
local BURST_STALL_MAX_TICKS       = 0                                      -- simtime frozen (0), not normal 1???2 tick stepping
local BURST_STALL_LOOKBACK        = 6                                      -- recent samples that must include stalls
local BURST_STALL_MIN_COUNT       = 2                                      -- require choke-then-release, not steady drift
local CHOKE_HOLD_STALL_RATIO      = 0.4                                    -- frozen simtime fraction in window (330ms FL)
local CHOKE_HOLD_MIN_STALLS       = 6                                     -- min zero-tick gaps in 16-sample window
local DEBUG_SUMMARY_INTERVAL_S    = 1.0
local DEBUG_DELTA_WINDOW          = 16   -- newest simtime gaps to classify for Choke logs
local DEBUG_SAMPLE_TICK_INTERVAL  = 4   -- Choke log rollup: full window snapshot every N ticks
-- Newest simtime gaps to read; clamped to DetectionConfig simtime retention (see cd_simhistory).
local FAKE_LAG_EVIDENCE_CAP       = Evidence.GetMethodScoreCap("fake_lag") -- suspicious-only tuning cap
-- Below ~40 fps, frame gaps can exceed the 8-tick choke threshold (tickrate/fps). No listen/debug bypass.
local MIN_FPS_FOR_DETECTION       = 40

local evidenceCooldowns           = {}                                     -- [id] = last globals.RealTime() evidence was added
local consecutiveChokeCount       = {}                                     -- count consecutive large deltas for impulse detection
local lastChokeDelta              = {}
local debugSummaries              = {}
local smoothedFrameTime           = 1 / 60
local _positiveDeltaBuf           = {}

-- Pre-HistoryManager, delta lists only had positive simtime steps (stalls omitted).
-- Scoring thresholds assume that shape; full buffer (with 0t holds) is for stall/burst paths only.
local function buildPositiveDeltaView(deltaTicks, deltaCount)
	local n = 0
	for i = 1, deltaCount do
		local d = deltaTicks[i]
		if d and d > 0 then
			n = n + 1
			_positiveDeltaBuf[n] = d
		end
	end
	for k = n + 1, #_positiveDeltaBuf do
		_positiveDeltaBuf[k] = nil
	end
	return _positiveDeltaBuf, n
end

-- ?????? helpers ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
local function getLocalSmoothedFps()
	local ft = globals.AbsoluteFrameTime()
	if ft and ft > 0 then
		smoothedFrameTime = smoothedFrameTime * 0.9 + ft * 0.1
	end
	return 1.0 / smoothedFrameTime
end

function FakeLag.IsLowFps()
	return getLocalSmoothedFps() < MIN_FPS_FOR_DETECTION
end

local function isChokeDetectionEnabled()
	local adv = G.Menu and G.Menu.Advanced
	return adv and adv.Choke == true
end

--- Why FakeLag did not run (nil = allowed). FPS gate is MIN_FPS only; no listen/debug bypass for net blocks.
function FakeLag.GetDetectionBlockReason()
	if not isChokeDetectionEnabled() then
		return "menu off"
	end

	local smoothedFps = getLocalSmoothedFps()
	if smoothedFps < MIN_FPS_FOR_DETECTION then
		return string.format("fps=%.0f < %d", smoothedFps, MIN_FPS_FOR_DETECTION)
	end

	local connReason = Common.GetConnectionStabilityBlockReason()
	if connReason and not connReason:match("^fps=") then
		return connReason
	end

	return nil
end

function FakeLag.IsDetectionAllowed()
	return FakeLag.GetDetectionBlockReason() == nil
end

function FakeLag.HasWork(playerState)
	if not playerState or not playerState.id then
		return false
	end
	if not FakeLag.IsDetectionAllowed() then
		return false
	end
	if (playerState.flags & Constants.Flags.CHEATER) ~= 0 then
		return Common.IsLogCategoryEnabled("Choke")
	end
	local id = playerState.id
	if Common.IsLogCategoryEnabled("Choke") then
		if Evidence.GetMethodWeight(id, "fake_lag") >= FAKE_LAG_EVIDENCE_CAP then
			return false
		end
		return true
	end
	if Evidence.GetMethodWeight(id, "fake_lag") >= FAKE_LAG_EVIDENCE_CAP then
		return false
	end
	return (globals.TickCount() % 4) == 0
end

local function getRhythmTolerance(anchorDelta)
	return math.max(RHYTHM_TOLERANCE_TICKS, math.floor(anchorDelta * 0.2 + 0.5))
end

local function getFlGapMaxTicks()
	return DoubleTap.GetFakeLagMaxChokeTicks() + 2
end

local function isFlSizedGap(tickDelta)
	return tickDelta
		and tickDelta >= MIN_FAKELAG_CHOKE_TICKS
		and tickDelta <= getFlGapMaxTicks()
end

local function countStallsInWindow(deltaTicks, sampleCount, deltaCount)
	local limit = math.min(sampleCount, deltaCount or #deltaTicks)
	local stalls = 0
	for i = 1, limit do
		if (deltaTicks[i] or -1) <= BURST_STALL_MAX_TICKS then
			stalls = stalls + 1
		end
	end
	return stalls, limit
end

local function getMaxFlGap(deltaTicks, deltaCount)
	local maxGap = 0
	for i = 1, deltaCount or 0 do
		local d = deltaTicks[i]
		if isFlSizedGap(d) and d > maxGap then
			maxGap = d
		end
	end
	return maxGap
end

-- 330ms-style FL: simtime frozen most ticks (0), occasional ~22t release in the window.
local function getChokeHoldSignal(deltaTicks, sampleCount, deltaCount)
	local stalls, limit = countStallsInWindow(deltaTicks, sampleCount, deltaCount)
	if limit < CHOKE_HOLD_MIN_STALLS then
		return nil, nil
	end

	local minStalls = math.max(CHOKE_HOLD_MIN_STALLS, math.ceil(limit * CHOKE_HOLD_STALL_RATIO))
	if stalls < minStalls then
		return nil, nil
	end

	local maxGap = getMaxFlGap(deltaTicks, deltaCount)
	if maxGap < STRONG_CHOKE_MIN_HIGH_TICKS then
		return nil, nil
	end

	return maxGap, "choke hold"
end

local function countHighChokeDeltas(deltaTicks, sampleCount, deltaCount)
	local limit = math.min(sampleCount, deltaCount or #deltaTicks)
	local highCount = 0
	local sumHigh = 0
	for i = 1, limit do
		local delta = deltaTicks[i]
		if isFlSizedGap(delta) then
			highCount = highCount + 1
			sumHigh = sumHigh + delta
		end
	end
	return highCount, sumHigh, limit
end

-- Match debug summaries: dominant large gaps in the recent window.
local function getRecentChokeSignal(deltaTicks, sampleCount, deltaCount)
	local highCount, sumHigh, limit = countHighChokeDeltas(deltaTicks, sampleCount, deltaCount)
	if limit < AVG_CHOKE_MIN_SAMPLES or highCount == 0 then
		return nil, nil
	end

	local minHigh = math.max(3, math.ceil(limit * STRONG_CHOKE_HIGH_RATIO))
	local avgHigh = sumHigh / highCount

	if highCount >= minHigh and avgHigh >= STRONG_CHOKE_MIN_HIGH_TICKS then
		return avgHigh, "high choke"
	end

	if highCount >= 3 and avgHigh >= AVG_CHOKE_THRESHOLD then
		return avgHigh, "elevated choke"
	end

	return nil, nil
end

local function getFastChokeSignal(deltaTicks, deltaCount)
	local firstDelta = deltaTicks[1]
	if not isFlSizedGap(firstDelta) or firstDelta < STRONG_CHOKE_MIN_HIGH_TICKS then
		return nil, nil
	end

	local highCount, _, limit = countHighChokeDeltas(deltaTicks, 8, deltaCount)
	if limit < 3 or highCount < 3 then
		return nil, nil
	end

	return firstDelta, "high choke"
end

local function buildEvidenceWeight(_anchorTicks)
	return FAKELAG_EVIDENCE_PER_USAGE
end

local function countRhythmMatches(deltaTicks, anchorDelta, sampleCount, tolerance, deltaCount)
	local limit = math.min(sampleCount, deltaCount or #deltaTicks)
	local matching = 0
	for i = 1, limit do
		local delta = deltaTicks[i]
		if delta >= MIN_FAKELAG_CHOKE_TICKS and math.abs(delta - anchorDelta) <= tolerance then
			matching = matching + 1
		end
	end
	return matching, limit
end

local function getSustainedChokeAverage(deltaTicks, deltaCount)
	local limit = math.min(SUSTAINED_SAMPLE_COUNT, deltaCount or #deltaTicks)
	if limit < RHYTHM_MIN_EVENTS then
		return nil
	end

	local highCount = 0
	local sumHigh = 0
	for i = 1, limit do
		local delta = deltaTicks[i]
		if delta >= MIN_FAKELAG_CHOKE_TICKS then
			highCount = highCount + 1
			sumHigh = sumHigh + delta
		end
	end

	if highCount / limit < SUSTAINED_MATCH_RATIO then
		return nil
	end

	local avgHigh = sumHigh / highCount
	if avgHigh < SUSTAINED_MIN_AVG_TICKS then
		return nil
	end
	return avgHigh
end

local function getPositiveAvgChoke(posDeltas, posCount)
	if posCount < AVG_CHOKE_MIN_SAMPLES then
		return nil
	end

	local sumPos = 0
	for i = 1, posCount do
		sumPos = sumPos + posDeltas[i]
	end
	local avgChoke = sumPos / posCount
	if avgChoke < AVG_CHOKE_THRESHOLD then
		return nil
	end
	return avgChoke
end

local function getRhythmicChokeEvidence(posDeltas, posCount)
	if posCount < RHYTHM_MIN_EVENTS then
		return nil, nil, nil
	end

	local anchorDelta = posDeltas[1]
	if not anchorDelta or anchorDelta < MIN_FAKELAG_CHOKE_TICKS then
		return nil, nil, nil
	end

	local tolerance = getRhythmTolerance(anchorDelta)
	local matching, checked = countRhythmMatches(
		posDeltas,
		anchorDelta,
		RHYTHM_CHECK_COUNT,
		tolerance,
		posCount
	)
	if checked < RHYTHM_MIN_EVENTS or (matching / checked) < RHYTHM_MATCH_RATIO then
		return nil, nil, nil
	end

	return anchorDelta, "rhythmic choke", string.format(
		"%d ticks (%d/%d within +/-%d)", anchorDelta, matching, checked, tolerance)
end

-- Evidence fallback after sustained: avg path OR rhythm, never both.
-- With RHYTHM_MIN_EVENTS (6) > AVG_CHOKE_MIN_SAMPLES (4), rhythm is unreachable in practice;
-- still must not fall through to rhythm when avg fails but posCount >= 4 (regression from nested else).
local function tryAvgOrRhythmChokeEvidence(posDeltas, posCount, tryAddChokeEvidenceFn)
	if posCount >= AVG_CHOKE_MIN_SAMPLES then
		local avgChoke = getPositiveAvgChoke(posDeltas, posCount)
		if avgChoke then
			tryAddChokeEvidenceFn(
				buildEvidenceWeight(avgChoke),
				"avg choke",
				string.format("%.1f ticks (%d releases)", avgChoke, posCount)
			)
		end
		return
	end
	if posCount < RHYTHM_MIN_EVENTS then
		return
	end
	local rhythmTicks, rhythmLabel, rhythmDetail = getRhythmicChokeEvidence(posDeltas, posCount)
	if rhythmTicks then
		tryAddChokeEvidenceFn(
			buildEvidenceWeight(rhythmTicks),
			rhythmLabel,
			rhythmDetail
		)
	end
end

-- Choke debug: simtime gap kinds (newest-first deltas).
-- hold=0t frozen simtime; gap=FL-sized advance; dt_rel=DT band [24,34) like unchoke/DT release.
local function accumulateDeltaKinds(deltaTicks, sampleCount, acc)
	local limit = math.min(sampleCount or DEBUG_DELTA_WINDOW, #deltaTicks)
	for i = 1, limit do
		local d = deltaTicks[i]
		if not d then
			break
		end
		if d <= BURST_STALL_MAX_TICKS then
			acc.hold = (acc.hold or 0) + 1
		elseif d < MIN_FAKELAG_CHOKE_TICKS then
			acc.step = (acc.step or 0) + 1
		elseif DoubleTap.IsDtSizedBurst(d) then
			acc.dtCount = (acc.dtCount or 0) + 1
			if d > (acc.dtMax or 0) then
				acc.dtMax = d
			end
		elseif isFlSizedGap(d) then
			acc.gapCount = (acc.gapCount or 0) + 1
			if d > (acc.gapMax or 0) then
				acc.gapMax = d
			end
		elseif d >= MIN_FAKELAG_CHOKE_TICKS then
			acc.outlierCount = (acc.outlierCount or 0) + 1
			if d > (acc.outlierMax or 0) then
				acc.outlierMax = d
			end
		end
	end
end

local function formatDeltaKinds(acc)
	if not acc then
		return "win16 hold=0 step=0 fl_gap=0(max 0) dt_rel=0(max 0)"
	end
	local outlier = ""
	if (acc.outlierCount or 0) > 0 then
		outlier = string.format(" spike=%d(max %d)", acc.outlierCount, acc.outlierMax or 0)
	end
	return string.format(
		"win16 hold=%d step=%d fl_gap=%d(max %d) dt_rel=%d(max %d)%s",
		acc.hold or 0,
		acc.step or 0,
		acc.gapCount or 0,
		acc.gapMax or 0,
		acc.dtCount or 0,
		acc.dtMax or 0,
		outlier
	)
end

local function formatTopDeltas(counts)
	local bestA, bestACount = nil, 0
	local bestB, bestBCount = nil, 0
	for delta, count in pairs(counts) do
		if count > bestACount then
			bestB, bestBCount = bestA, bestACount
			bestA, bestACount = delta, count
		elseif count > bestBCount then
			bestB, bestBCount = delta, count
		end
	end

	if not bestA then
		return "none"
	end
	if not bestB then
		return string.format("%dx%d", bestA, bestACount)
	end
	return string.format("%dx%d, %dx%d", bestA, bestACount, bestB, bestBCount)
end

local function recordDebugSample(id, deltaTicks, deltaCount, now, snapshotWindow)
	local summary = debugSummaries[id]
	if not summary then
		summary = {
			lastPrint = now,
			samples = 0,
			idle = 0,
			active = 0,
			counts = {},
			windowKinds = {},
		}
		debugSummaries[id] = summary
	end

	local firstDelta = deltaTicks[1] or 0
	summary.samples = summary.samples + 1
	local isChokeActive = deltaCount > 0
		and (getChokeHoldSignal(deltaTicks, DEBUG_DELTA_WINDOW, deltaCount)
			or isFlSizedGap(firstDelta))
	if isChokeActive then
		summary.active = summary.active + 1
		if isFlSizedGap(firstDelta) then
			summary.counts[firstDelta] = (summary.counts[firstDelta] or 0) + 1
		end
	else
		summary.idle = summary.idle + 1
	end
	if snapshotWindow then
		summary.windowKinds = {}
		accumulateDeltaKinds(deltaTicks, DEBUG_DELTA_WINDOW, summary.windowKinds)
	end

	if (now - summary.lastPrint) >= DEBUG_SUMMARY_INTERVAL_S then
		print(string.format(
			"[FakeLag] %s delta summary: samples=%d active=%d idle=%d top=%s | %s",
			id, summary.samples, summary.active, summary.idle,
			formatTopDeltas(summary.counts), formatDeltaKinds(summary.windowKinds)))
		summary.lastPrint = now
		summary.samples = 0
		summary.idle = 0
		summary.active = 0
		summary.windowKinds = {}
		for k in pairs(summary.counts) do
			summary.counts[k] = nil
		end
	end
end

-- ?????? main entry ???????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
local function addCappedFakeLagEvidence(id, wantedWeight)
	local currentWeight = Evidence.GetMethodWeight(id, "fake_lag")
	local remaining = FAKE_LAG_EVIDENCE_CAP - currentWeight
	if remaining <= 0 then
		return 0
	end

	local actualWeight = math.min(wantedWeight, remaining)
	local beforeWeight = Evidence.GetMethodWeight(id, "fake_lag")
	Evidence.AddEvidence(id, "fake_lag", actualWeight)
	local afterWeight = Evidence.GetMethodWeight(id, "fake_lag")
	local added = afterWeight - beforeWeight
	if added > 0 then
		return added
	end
	return 0
end

local function isActiveChokePattern(deltaTicks, deltaCount)
	if getChokeHoldSignal(deltaTicks, RECENT_CHOKE_SAMPLE_COUNT, deltaCount) then
		return true
	end

	local posDeltas, posCount = buildPositiveDeltaView(deltaTicks, deltaCount)

	if getSustainedChokeAverage(posDeltas, posCount) then
		return true
	end

	if posCount >= RHYTHM_MIN_EVENTS then
		local anchorDelta = posDeltas[1]
		if anchorDelta and anchorDelta >= MIN_FAKELAG_CHOKE_TICKS then
			local tolerance = getRhythmTolerance(anchorDelta)
			local matching, checked = countRhythmMatches(
				posDeltas,
				anchorDelta,
				RHYTHM_CHECK_COUNT,
				tolerance,
				posCount
			)
			if checked >= RHYTHM_MIN_EVENTS and (matching / checked) >= RHYTHM_MATCH_RATIO then
				return true
			end
		end
	end

	local recentChoke = getRecentChokeSignal(posDeltas, RECENT_CHOKE_SAMPLE_COUNT, posCount)
	if recentChoke then
		return true
	end

	if posCount >= AVG_CHOKE_MIN_SAMPLES then
		local sumPos = 0
		for i = 1, posCount do
			sumPos = sumPos + posDeltas[i]
		end
		if (sumPos / posCount) >= AVG_CHOKE_THRESHOLD then
			return true
		end
	end

	return false
end

function FakeLag.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then return end
	if Fetcher.State.isRunning then return end
	if not isChokeDetectionEnabled() then return end

	local id = playerState.id
	if id:sub(1, 4) == "BOT_" then return end

	local localID = PlayerCache.GetLocalID()
	if localID and id == localID and not Common.IsDebugEnabled() then
		return
	end

	local blockReason = FakeLag.GetDetectionBlockReason()
	if blockReason then
		return
	end

	if not playerState.pdata.isAlive then return end

	-- Brief pause after DT-sized release only (do not block while DT is merely "watching").
	if DoubleTap.ShouldSuppressFakeLag(id) then
		return
	end

	local history = HistoryManager.GetPlayerHistory(id)
	if not history then return end

	if history._count < 5 then return end

	local now     = globals.RealTime()
	local isDebug = Common.IsLogCategoryEnabled("Choke")

	if not isDebug then
		if Evidence.GetMethodWeight(id, "fake_lag") >= FAKE_LAG_EVIDENCE_CAP then
			return
		end
		local lastEvidenceTime = evidenceCooldowns[id] or 0
		if (now - lastEvidenceTime) < FAKELAG_EVIDENCE_COOLDOWN_S
			and (globals.TickCount() % 2 ~= 0) then
			return
		end
	end

	local flScan = DetectionConfig.GetSimtimeScanLimits().flScan
	local deltaTicks, deltaCount, _sumTicks = HistoryManager.GetSimDeltaDeltas(history, flScan)
	if deltaCount < 1 then
		return
	end

	local posDeltas, posCount = buildPositiveDeltaView(deltaTicks, deltaCount)

	if isDebug then
		local snapshotWindow = (globals.TickCount() % DEBUG_SAMPLE_TICK_INTERVAL) == 0
		recordDebugSample(id, deltaTicks, deltaCount, now, snapshotWindow)
	end

	-- Ongoing choke: pause exploit decay so score does not drain between evidence cooldowns.
	if isActiveChokePattern(deltaTicks, deltaCount) then
		Evidence.HoldDecayForMethod(id, "fake_lag")
	end

	local fakeLagWeight = Evidence.GetMethodWeight(id, "fake_lag")
	if fakeLagWeight >= FAKE_LAG_EVIDENCE_CAP then
		return
	end

	local function countRecentStalls(lookbackEnd)
		local stalls = 0
		local lookback = math.min(BURST_STALL_LOOKBACK, lookbackEnd or deltaCount)
		for i = 1, lookback do
			if (deltaTicks[i] or -1) <= BURST_STALL_MAX_TICKS then
				stalls = stalls + 1
			end
		end
		return stalls
	end

	local function tryAddChokeEvidence(weight, logLabel, logDetail)
		if not weight or weight <= 0 then
			return 0
		end
		local lastTime = evidenceCooldowns[id] or 0
		if (now - lastTime) < FAKELAG_EVIDENCE_COOLDOWN_S then
			return 0
		end
		local addedWeight = addCappedFakeLagEvidence(id, weight)
		if addedWeight > 0 then
			evidenceCooldowns[id] = now
			if isDebug then
				local kindAcc = {}
				accumulateDeltaKinds(deltaTicks, DEBUG_DELTA_WINDOW, kindAcc)
				print(string.format(
					"[FakeLag] %s %s: %s (evidence +%.1f) | %s",
					id, logLabel, logDetail, addedWeight, formatDeltaKinds(kindAcc)))
			end
		end
		return addedWeight
	end

	-- ?????? 1. Choke-then-release bursts (not steady simtime drift) ?????????????????????????????????????????????
	if deltaCount >= 1 then
		local firstDelta = deltaTicks[1] or 0
		local releaseDelta = firstDelta
		if releaseDelta < BURST_CHOKE_MIN_TICKS then
			releaseDelta = getMaxFlGap(deltaTicks, math.min(BURST_STALL_LOOKBACK, deltaCount))
		end
		if releaseDelta >= BURST_CHOKE_MIN_TICKS and countRecentStalls(BURST_STALL_LOOKBACK) >= BURST_STALL_MIN_COUNT then
			local previousDelta = lastChokeDelta[id]
			local tolerance = releaseDelta >= 16 and 12 or 2
			if previousDelta and math.abs(releaseDelta - previousDelta) > tolerance then
				consecutiveChokeCount[id] = 1
			else
				consecutiveChokeCount[id] = (consecutiveChokeCount[id] or 0) + 1
			end
			lastChokeDelta[id] = releaseDelta

			if consecutiveChokeCount[id] >= BURST_CONFIRM_EVENTS then
				consecutiveChokeCount[id] = 0
				lastChokeDelta[id] = nil
				tryAddChokeEvidence(
					buildEvidenceWeight(releaseDelta),
					"choke/release burst",
					string.format("release %dt (stalls %d in lookback)", releaseDelta, countRecentStalls(BURST_STALL_LOOKBACK))
				)
			end
		else
			consecutiveChokeCount[id] = 0
			lastChokeDelta[id] = nil
		end
	end

	-- ?????? 2. Evidence paths (one shared realtime cooldown) ?????????????????????????????????????????????????????????
	local chokeTicks, chokeLabel = getChokeHoldSignal(deltaTicks, RECENT_CHOKE_SAMPLE_COUNT, deltaCount)
	if not chokeTicks then
		chokeTicks, chokeLabel = getFastChokeSignal(posDeltas, posCount)
	end
	if not chokeTicks then
		chokeTicks, chokeLabel = getRecentChokeSignal(posDeltas, RECENT_CHOKE_SAMPLE_COUNT, posCount)
	end
	if chokeTicks then
		tryAddChokeEvidence(
			buildEvidenceWeight(chokeTicks),
			chokeLabel,
			string.format("%.1f ticks", chokeTicks)
		)
	else
		local sustainedAvg = getSustainedChokeAverage(posDeltas, posCount)
		if sustainedAvg then
			tryAddChokeEvidence(
				buildEvidenceWeight(sustainedAvg),
				"sustained choke",
				string.format("avg %.1f ticks", sustainedAvg)
			)
		else
			tryAvgOrRhythmChokeEvidence(posDeltas, posCount, tryAddChokeEvidence)
		end
	end
end

-- ?????? cleanup ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
Events.Subscribe("OnPlayerDisconnect", function(id)
	evidenceCooldowns[id]     = nil
	consecutiveChokeCount[id] = nil
	lastChokeDelta[id]        = nil
	debugSummaries[id]        = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	evidenceCooldowns[id]     = nil
	consecutiveChokeCount[id] = nil
	lastChokeDelta[id]        = nil
	debugSummaries[id]        = nil
end)

return FakeLag
