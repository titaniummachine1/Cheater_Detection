--[[ detectors/fake_lag.lua
     Sustained / rhythmic packet choke only — NOT double tap.

     Double tap (choke → release → ~18+ tick simtime jump) is handled by warp_dt.lua.
     This module uses the same simtime history but README-era fake-lag rules only:

     1. Rhythmic – consecutive deltas within ±1 tick of the first.
     2. Average choke – mean gap >= AVG_CHOKE_THRESHOLD across the window.

     DT-sized bursts are stripped and trigger a short scoring suppress via WarpDT.
]]

local G                           = require("Cheater_Detection.Utils.Globals")
local Common                      = require("Cheater_Detection.Utils.Common")
local Evidence                    = require("Cheater_Detection.Core.Evidence_system")
local Events                      = require("Cheater_Detection.Core.Events")
local HistoryManager              = require("Cheater_Detection.Utils.HistoryManager")
local DetectionConfig             = require("Cheater_Detection.Utils.DetectionConfig")
local Fetcher                     = require("Cheater_Detection.Database.Fetcher")
local PlayerCache                 = require("Cheater_Detection.Core.player_cache")
local WarpDT                      = require("Cheater_Detection.detectors.warp_dt")

local FakeLag                     = {}

-- ── constants ──────────────────────────────────────────────────────────────
local FAKELAG_EVIDENCE_COOLDOWN_S = 1.0
local RHYTHM_MIN_EVENTS           = 3   -- README-era rhythmic minimum
local RHYTHM_TOLERANCE_TICKS      = 1   -- README: ±1 tick

-- Rijin-derived avg choke (README threshold)
local AVG_CHOKE_THRESHOLD         = 2.0
local AVG_CHOKE_MIN_SAMPLES       = 5
local AVG_CHOKE_EVIDENCE_W        = 6.0
-- DT release: stall then large simtime jump (must match warp_dt burst floor)
local DT_BURST_MIN_TICKS          = 18
local DT_RELEASE_MIN_TICKS        = DT_BURST_MIN_TICKS
local DT_RELEASE_STALL_MAX        = 1
local DT_RELEASE_STALL_LOOKAHEAD  = 8
local DT_RELEASE_STALL_MIN        = 2
local DEBUG_SUMMARY_INTERVAL_S    = 1.0
local FAKE_LAG_EVIDENCE_CAP       = Evidence.GetMethodScoreCap("fake_lag") -- suspicious-only tuning cap
local MIN_FPS_FOR_DETECTION       = 40                                     -- below ~40 fps, frame gaps can exceed the 8-tick choke threshold (ticks/frame = tickrate/fps)
local MAX_FAKELAG_TICKS           = 33
local MAX_DELTA_SEC               = 2.5

local evidenceCooldowns           = {} -- [id] = last globals.RealTime() evidence was added
local debugSummaries              = {}
local smoothedFrameTime           = 1 / 60

local _simTimes                   = {}
local _deltaTicks                 = {}
local _filteredDeltaTicks         = {}

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

-- deltaTicks[1] = newest. DT = frozen simtime (stall) then one large forward step (release).
local function isDoubleTapReleaseStep(deltaTicks, index)
	local step = deltaTicks[index]
	if not step or step < DT_RELEASE_MIN_TICKS then
		return false
	end
	local stalls = 0
	local lookEnd = math.min(index + DT_RELEASE_STALL_LOOKAHEAD, #deltaTicks)
	for j = index + 1, lookEnd do
		local prev = deltaTicks[j]
		if prev and prev <= DT_RELEASE_STALL_MAX then
			stalls = stalls + 1
		end
	end
	return stalls >= DT_RELEASE_STALL_MIN
end

local function buildFakeLagDeltaWindow(rawDeltas, filtered)
	for k = 1, #filtered do
		filtered[k] = nil
	end
	local sumTicks = 0
	for i = 1, #rawDeltas do
		if not isDoubleTapReleaseStep(rawDeltas, i) then
			filtered[#filtered + 1] = rawDeltas[i]
			sumTicks = sumTicks + rawDeltas[i]
		end
	end
	return sumTicks
end

local function hasDtBurstInWindow(deltaTicks)
	for i = 1, #deltaTicks do
		if deltaTicks[i] >= DT_BURST_MIN_TICKS then
			return true
		end
		if isDoubleTapReleaseStep(deltaTicks, i) then
			return true
		end
	end
	return false
end

local function isRhythmicChoke(deltaTicks)
	if #deltaTicks < RHYTHM_MIN_EVENTS then
		return false
	end
	local firstDelta = deltaTicks[1]
	if not firstDelta or firstDelta <= 1 then
		return false
	end
	for i = 2, #deltaTicks do
		if math.abs(deltaTicks[i] - firstDelta) > RHYTHM_TOLERANCE_TICKS then
			return false
		end
	end
	return true
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
	if isRhythmicChoke(deltaTicks) then
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

	-- DEBUG MODE: scan local player for self-test. Off = skip yourself.
	local localID = PlayerCache.GetLocalID()
	if localID and id == localID and not Common.IsDebugEnabled() then
		return
	end

	if not isLocalFpsSufficient() then return end
	if not Common.IsConnectionStableForDetection() then return end

	if not playerState.pdata.isAlive then return end
	if WarpDT.ShouldSuppressFakeLag(id) then return end

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
				local prevLarge = (i > 1) and (timeToTicks(simTimes[i - 1] - simTimes[i]) > MAX_FAKELAG_TICKS)
				local nextLarge = (i < #simTimes - 1) and
					(timeToTicks(simTimes[i + 1] - simTimes[i + 2]) > MAX_FAKELAG_TICKS)
				if not (prevLarge or nextLarge) then
					t = nil
				end
			end
			if t then
				deltaTicks[#deltaTicks + 1] = t
			end
		end
	end

	if hasDtBurstInWindow(deltaTicks) then
		WarpDT.MarkDtRelease(id)
		return
	end

	local filteredDeltas = _filteredDeltaTicks
	local filteredSum = buildFakeLagDeltaWindow(deltaTicks, filteredDeltas)
	if #filteredDeltas < AVG_CHOKE_MIN_SAMPLES then
		return
	end

	local now     = globals.RealTime()
	local isDebug = Common.IsLogCategoryEnabled("Choke")

	if isDebug then
		recordDebugSample(id, #filteredDeltas, filteredDeltas[1] or 0, now)
	end

	if isActiveChokePattern(filteredDeltas, filteredSum) then
		Evidence.HoldDecayForMethod(id, "fake_lag")
	end

	if isRhythmicChoke(filteredDeltas) then
		tryAddChokeEvidence(
			id, now, isDebug,
			AVG_CHOKE_EVIDENCE_W,
			"rhythmic choke",
			string.format("%d ticks", filteredDeltas[1])
		)
	elseif #filteredDeltas >= AVG_CHOKE_MIN_SAMPLES then
		local avgChoke = filteredSum / #filteredDeltas
		if avgChoke >= AVG_CHOKE_THRESHOLD then
			tryAddChokeEvidence(
				id, now, isDebug,
				AVG_CHOKE_EVIDENCE_W,
				"avg choke",
				string.format("%.2f ticks (>= %.1f)", avgChoke, AVG_CHOKE_THRESHOLD)
			)
		end
	end
end

-- ── cleanup ────────────────────────────────────────────────────────────────
Events.Subscribe("OnPlayerDisconnect", function(id)
	evidenceCooldowns[id] = nil
	debugSummaries[id]    = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	evidenceCooldowns[id] = nil
	debugSummaries[id]    = nil
end)

return FakeLag
