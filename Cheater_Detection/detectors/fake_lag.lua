--[[ detectors/fake_lag.lua
     Detects excessive packet choking (Fake Lag) via two complementary methods:

     1. Rhythmic pattern – recent simulation-time deltas match a fixed choke
        interval (scaled tolerance). Fires evidence.

     2. Sustained high choke – most recent deltas stay large (e.g. steady 22-tick FL).

     3. Choke/release burst – simtime freeze then large release spike.

     4. Average choke-tick method (Rijin-derived) – computes the mean
        simulation-time gap in ticks across the entire history window.
        avg_choke_ticks >= AVG_CHOKE_THRESHOLD signals fakelag even when the
        pattern is irregular (e.g. random/adaptive lag).
        Fires Evidence.AddEvidence so it decays and stacks with other signals.
]]

local G                           = require("Cheater_Detection.Utils.Globals")
local Common                      = require("Cheater_Detection.Utils.Common")
local Evidence                    = require("Cheater_Detection.Core.Evidence_system")
local Events                      = require("Cheater_Detection.Core.Events")
local HistoryManager              = require("Cheater_Detection.Utils.HistoryManager")
local DetectionConfig             = require("Cheater_Detection.Utils.DetectionConfig")
local Fetcher                     = require("Cheater_Detection.Database.Fetcher")

local FakeLag                     = {}

-- ── constants ──────────────────────────────────────────────────────────────
-- Normal gameplay advances simtime ~1 tick per update; 1–2 tick gaps are not fakelag.
local MIN_FAKELAG_CHOKE_TICKS     = 4
local FAKELAG_EVIDENCE_COOLDOWN_S = 1.0  -- was 2.0 — twice as many evidence refreshes
local RECENT_CHOKE_SAMPLE_COUNT   = 16
local STRONG_CHOKE_MIN_HIGH_TICKS = 8    -- was 10 — count 8+ tick gaps as choke
local STRONG_CHOKE_HIGH_RATIO     = 0.28 -- was 0.55 — ~half the window must be large gaps
local RHYTHM_MIN_EVENTS           = 6    -- was 8 — faster rhythmic match
local RHYTHM_CHECK_COUNT          = 16   -- only judge recent deltas (not the whole ring buffer)
local RHYTHM_MATCH_RATIO          = 0.5  -- was 0.75
local RHYTHM_TOLERANCE_TICKS      = 2    -- floor tolerance for small choke values
local SUSTAINED_SAMPLE_COUNT      = 20   -- recent samples for steady high-choke fakelag
local SUSTAINED_MATCH_RATIO       = 0.45 -- was 0.65 — triggers on mixed 22+17 style choke
local SUSTAINED_MIN_AVG_TICKS     = 8    -- average choke in that window (22-tick FL ≈ 22)

-- Rijin-derived: avg choke-tick threshold
-- avg simtime gap >= 2 ticks across the window = fakelag signal
local AVG_CHOKE_THRESHOLD         = 4.2
local AVG_CHOKE_MIN_SAMPLES       = 4                                      -- require more samples for average calculation
local AVG_CHOKE_EVIDENCE_W        = 6.0                                    -- was 3.0 — doubled weight per trigger
local BURST_CHOKE_MIN_TICKS       = 8                                      -- ignore normal single-tick jitter
local BURST_CONFIRM_EVENTS        = 4                                      -- consecutive large deltas after a stall
local BURST_STALL_MAX_TICKS       = 0                                      -- simtime frozen (0), not normal 1–2 tick stepping
local BURST_STALL_LOOKBACK        = 6                                      -- recent samples that must include stalls
local BURST_STALL_MIN_COUNT       = 2                                      -- require choke-then-release, not steady drift
local DEBUG_SUMMARY_INTERVAL_S    = 1.0
local FAKE_LAG_EVIDENCE_CAP       = Evidence.GetMethodScoreCap("fake_lag") -- suspicious-only tuning cap
local MIN_FPS_FOR_DETECTION       = 40                                     -- below ~40 fps, frame gaps can exceed the 8-tick choke threshold (ticks/frame = tickrate/fps)
local MAX_FAKELAG_TICKS           = 33
local MAX_DELTA_SEC               = 2.5

local evidenceCooldowns           = {} -- [id] = last globals.RealTime() evidence was added
local consecutiveChokeCount       = {} -- count consecutive large deltas for impulse detection
local lastChokeDelta              = {}
local debugSummaries              = {}
local smoothedFrameTime           = 1 / 60

local _simTimes                   = {}
local _deltaTicks                 = {}

-- ── helpers ────────────────────────────────────────────────────────────────
local function _collectSimTime(_, record)
	local simTime = record[HistoryManager.Fields.SimulationTime]
	if simTime then
		_simTimes[#_simTimes + 1] = simTime
	end
end

local function isLocalFpsSufficient()
	local ft = globals.AbsoluteFrameTime()
	if ft and ft > 0 then
		smoothedFrameTime = smoothedFrameTime * 0.9 + ft * 0.1
	end
	return (1.0 / smoothedFrameTime) >= MIN_FPS_FOR_DETECTION
end

function FakeLag.IsLowFps()
	return (1.0 / smoothedFrameTime) < MIN_FPS_FOR_DETECTION
end

local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
end

local function getRhythmTolerance(anchorDelta)
	return math.max(RHYTHM_TOLERANCE_TICKS, math.floor(anchorDelta * 0.2 + 0.5))
end

local function countHighChokeDeltas(deltaTicks, sampleCount)
	local limit = math.min(sampleCount, #deltaTicks)
	local highCount = 0
	local sumHigh = 0
	for i = 1, limit do
		local delta = deltaTicks[i]
		if delta >= MIN_FAKELAG_CHOKE_TICKS then
			highCount = highCount + 1
			sumHigh = sumHigh + delta
		end
	end
	return highCount, sumHigh, limit
end

-- Match debug summaries: dominant large gaps in the recent window.
local function getRecentChokeSignal(deltaTicks, sampleCount)
	local highCount, sumHigh, limit = countHighChokeDeltas(deltaTicks, sampleCount)
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

local function getFastChokeSignal(deltaTicks)
	local firstDelta = deltaTicks[1]
	if not firstDelta or firstDelta < STRONG_CHOKE_MIN_HIGH_TICKS then
		return nil, nil
	end

	local highCount, _, limit = countHighChokeDeltas(deltaTicks, 8)
	if limit < 3 or highCount < 3 then
		return nil, nil
	end

	return firstDelta, "high choke"
end

local function buildEvidenceWeight(anchorTicks)
	local strength = math.min(6.0, math.max(1.0, anchorTicks / 6.0))
	return AVG_CHOKE_EVIDENCE_W * strength
end

local function countRhythmMatches(deltaTicks, anchorDelta, sampleCount, tolerance)
	local limit = math.min(sampleCount, #deltaTicks)
	local matching = 0
	for i = 1, limit do
		local delta = deltaTicks[i]
		local diff = math.abs(delta - anchorDelta)
		if delta >= MIN_FAKELAG_CHOKE_TICKS and diff <= tolerance then
			matching = matching + 1
		end
	end
	return matching, limit
end

local function getSustainedChokeAverage(deltaTicks)
	local limit = math.min(SUSTAINED_SAMPLE_COUNT, #deltaTicks)
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

local function recordDebugSample(id, sampleCount, firstDelta, now)
	local summary = debugSummaries[id]
	if not summary then
		summary = {
			lastPrint = now,
			samples = 0,
			zero = 0,
			nonzero = 0,
			counts = {},
		}
		debugSummaries[id] = summary
	end

	summary.samples = summary.samples + 1
	if sampleCount <= 0 or firstDelta <= 0 then
		summary.zero = summary.zero + 1
	else
		summary.nonzero = summary.nonzero + 1
		summary.counts[firstDelta] = (summary.counts[firstDelta] or 0) + 1
	end

	if (now - summary.lastPrint) >= DEBUG_SUMMARY_INTERVAL_S then
		print(string.format("[FakeLag] %s delta summary: samples=%d zero=%d nonzero=%d top=%s",
			id, summary.samples, summary.zero, summary.nonzero, formatTopDeltas(summary.counts)))
		summary.lastPrint = now
		summary.samples = 0
		summary.zero = 0
		summary.nonzero = 0
		for k in pairs(summary.counts) do
			summary.counts[k] = nil
		end
	end
end

-- ── main entry ─────────────────────────────────────────────────────────────
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

local function isChokeDetectionEnabled()
	local adv = G.Menu and G.Menu.Advanced
	return adv and adv.Choke == true
end

local function isActiveChokePattern(deltaTicks, sumTicks)
	if getSustainedChokeAverage(deltaTicks) then
		return true
	end

	if #deltaTicks >= RHYTHM_MIN_EVENTS then
		local anchorDelta = deltaTicks[1]
		if anchorDelta and anchorDelta >= MIN_FAKELAG_CHOKE_TICKS then
			local tolerance = getRhythmTolerance(anchorDelta)
			local matching, checked = countRhythmMatches(
				deltaTicks,
				anchorDelta,
				RHYTHM_CHECK_COUNT,
				tolerance
			)
			if checked >= RHYTHM_MIN_EVENTS and (matching / checked) >= RHYTHM_MATCH_RATIO then
				return true
			end
		end
	end

	local recentChoke = getRecentChokeSignal(deltaTicks, RECENT_CHOKE_SAMPLE_COUNT)
	if recentChoke then
		return true
	end

	if #deltaTicks >= AVG_CHOKE_MIN_SAMPLES then
		local avgChoke = sumTicks / #deltaTicks
		if avgChoke >= AVG_CHOKE_THRESHOLD then
			return true
		end
	end

	return false
end

local function countRecentStalls(deltaTicks)
	local stalls = 0
	local lookback = math.min(BURST_STALL_LOOKBACK, #deltaTicks)
	for i = 2, lookback do
		if deltaTicks[i] <= BURST_STALL_MAX_TICKS then
			stalls = stalls + 1
		end
	end
	return stalls
end

local function tryAddChokeEvidence(id, now, isDebug, weight, logLabel, logDetail)
	local lastTime = evidenceCooldowns[id] or 0
	if (now - lastTime) < FAKELAG_EVIDENCE_COOLDOWN_S then
		return 0
	end
	local addedWeight = addCappedFakeLagEvidence(id, weight)
	if addedWeight > 0 then
		evidenceCooldowns[id] = now
		if isDebug then
			print(string.format("[FakeLag] %s %s: %s (evidence +%.1f)", id, logLabel, logDetail, addedWeight))
		end
	elseif isDebug and weight > 0 then
		print(string.format("[FakeLag] %s evidence blocked for %s (wanted +%.1f)", id, logLabel, weight))
	end
	return addedWeight
end

function FakeLag.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then return end
	if Fetcher.State.isRunning then return end
	if not isChokeDetectionEnabled() then return end

	local id = playerState.id
	if id:sub(1, 4) == "BOT_" then return end

	if not isLocalFpsSufficient() then return end
	if not Common.IsConnectionStableForDetection() then return end

	if not playerState.pdata.isAlive then return end

	DetectionConfig.RecordHistory(playerState.wrap, "FakeLag")

	local history = HistoryManager.GetPlayerHistory(id)
	if not history then return end

	if history._count < 5 then return end

	-- Collect simulation times (reuse module-level table)
	for k = 1, #_simTimes do _simTimes[k] = nil end
	HistoryManager.ForEachRecordNewestFirst(history, nil, _collectSimTime)

	if #_simTimes < 5 then return end

	-- Build delta-tick array (positive deltas only; reuse module-level table)
	for k = 1, #_deltaTicks do _deltaTicks[k] = nil end
	local deltaTicks = _deltaTicks
	local simTimes   = _simTimes
	local sumTicks   = 0

	for i = 1, #simTimes - 1 do
		local delta = simTimes[i] - simTimes[i + 1] -- simTimes[i] is newer
		if delta > 0 and delta <= MAX_DELTA_SEC then
			local t = timeToTicks(delta)
			-- Spike filter: reject isolated massive gaps (>33 ticks) as packet loss
			if t > MAX_FAKELAG_TICKS then
				-- Only allow if neighbors are also large (sustained choke, not a spike)
				local prevLarge = (i > 1) and (timeToTicks(simTimes[i - 1] - simTimes[i]) > MAX_FAKELAG_TICKS)
				local nextLarge = (i < #simTimes - 1) and
					(timeToTicks(simTimes[i + 1] - simTimes[i + 2]) > MAX_FAKELAG_TICKS)
				if not (prevLarge or nextLarge) then
					-- Single spike: treat as packet loss, clamp to reasonable choke
					t = MIN_FAKELAG_CHOKE_TICKS
				end
			end
			deltaTicks[#deltaTicks + 1] = t
			sumTicks = sumTicks + t
		end
	end

	local now     = globals.RealTime()
	local isDebug = Common.IsLogCategoryEnabled("Choke")

	if isDebug then
		recordDebugSample(id, #deltaTicks, deltaTicks[1] or 0, now)
	end

	-- Ongoing choke: pause exploit decay so score does not drain between evidence cooldowns.
	if isActiveChokePattern(deltaTicks, sumTicks) then
		Evidence.HoldDecayForMethod(id, "fake_lag")
	end

	-- ── 1. Choke-then-release bursts (not steady simtime drift) ───────────────
	if #deltaTicks >= 1 then
		local firstDelta = deltaTicks[1]
		if firstDelta >= BURST_CHOKE_MIN_TICKS and countRecentStalls(deltaTicks) >= BURST_STALL_MIN_COUNT then
			local previousDelta = lastChokeDelta[id]
			local tolerance = firstDelta >= 16 and 12 or 2
			local prevDiff = previousDelta and math.abs(firstDelta - previousDelta)
			if prevDiff and prevDiff > tolerance then
				consecutiveChokeCount[id] = 1
			else
				consecutiveChokeCount[id] = (consecutiveChokeCount[id] or 0) + 1
			end
			lastChokeDelta[id] = firstDelta

			if consecutiveChokeCount[id] >= BURST_CONFIRM_EVENTS then
				consecutiveChokeCount[id] = 0
				lastChokeDelta[id] = nil
				tryAddChokeEvidence(
					id, now, isDebug,
					buildEvidenceWeight(firstDelta),
					"choke/release burst",
					string.format("%d ticks", firstDelta)
				)
			end
		else
			consecutiveChokeCount[id] = 0
			lastChokeDelta[id] = nil
		end
	end

	-- ── 2. Evidence paths (one shared realtime cooldown) ───────────────────
	local chokeTicks, chokeLabel = getFastChokeSignal(deltaTicks)
	if not chokeTicks then
		chokeTicks, chokeLabel = getRecentChokeSignal(deltaTicks, RECENT_CHOKE_SAMPLE_COUNT)
	end
	if chokeTicks then
		tryAddChokeEvidence(
			id, now, isDebug,
			buildEvidenceWeight(chokeTicks),
			chokeLabel,
			string.format("%.1f ticks", chokeTicks)
		)
	else
		local sustainedAvg = getSustainedChokeAverage(deltaTicks)
		if sustainedAvg then
			tryAddChokeEvidence(
				id, now, isDebug,
				buildEvidenceWeight(sustainedAvg),
				"sustained choke",
				string.format("avg %.1f ticks", sustainedAvg)
			)
		elseif #deltaTicks >= RHYTHM_MIN_EVENTS then
			local anchorDelta = deltaTicks[1]
			if anchorDelta >= MIN_FAKELAG_CHOKE_TICKS then
				local tolerance = getRhythmTolerance(anchorDelta)
				local matching, checked = countRhythmMatches(
					deltaTicks,
					anchorDelta,
					RHYTHM_CHECK_COUNT,
					tolerance
				)
				if checked >= RHYTHM_MIN_EVENTS and (matching / checked) >= RHYTHM_MATCH_RATIO then
					tryAddChokeEvidence(
						id, now, isDebug,
						buildEvidenceWeight(anchorDelta),
						"rhythmic choke",
						string.format("%d ticks (%d/%d within \xc2\xb1%d)", anchorDelta, matching, checked, tolerance)
					)
				end
			end
		end
	end
end

-- ── cleanup ────────────────────────────────────────────────────────────────
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
