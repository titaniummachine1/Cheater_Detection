--[[ detectors/fake_lag.lua
     Detects excessive packet choking (Fake Lag) via two complementary methods:

     1. Rhythmic pattern (original) – consecutive simulation-time deltas are
        consistent within ±1 tick.  Hard indicator of fixed-interval fakelag.
        Fires ApplyPlayerFlag score bump.

     2. Average choke-tick method (Rijin-derived) – computes the mean
        simulation-time gap in ticks across the entire history window.
        avg_choke_ticks >= AVG_CHOKE_THRESHOLD signals fakelag even when the
        pattern is irregular (e.g. random/adaptive lag).
        Fires Evidence.AddEvidence so it decays and stacks with other signals.
]]

local G                           = require("Cheater_Detection.Utils.Globals")
local Common                      = require("Cheater_Detection.Utils.Common")
local DetectorUtils               = require("Cheater_Detection.Utils.DetectorUtils")
local Evidence                    = require("Cheater_Detection.Core.Evidence_system")
local Events                      = require("Cheater_Detection.Core.Events")
local HistoryManager              = require("Cheater_Detection.Utils.HistoryManager")

local FakeLag                     = {}

-- ── constants ──────────────────────────────────────────────────────────────
local FAKELAG_COOLDOWN_TICKS_66HZ = 132.0 -- 2 second cooldown at 66Hz
local RHYTHM_MIN_EVENTS           = 8    -- require 8 consecutive large deltas for detection (stricter)
local RHYTHM_TOLERANCE_TICKS      = 2    -- ±2 ticks tolerance (was ±1)

-- Rijin-derived: avg choke-tick threshold
-- avg simtime gap >= 2 ticks across the window = fakelag signal
local AVG_CHOKE_THRESHOLD         = 4.2
local AVG_CHOKE_MIN_SAMPLES       = 4   -- require more samples for average calculation
local AVG_CHOKE_EVIDENCE_W        = 1.5 -- evidence weight per trigger (much lighter)
local AVG_CHOKE_COOLDOWN_S        = 5.0 -- 5 second cooldown between detections
local BURST_CHOKE_MIN_TICKS       = 4   -- ~60ms at 66 tick; repeated choke/release pattern
local BURST_CONFIRM_EVENTS        = 4   -- detect steady choke/burst quickly
local DEBUG_SUMMARY_INTERVAL_S    = 1.0
local FAKE_LAG_EVIDENCE_CAP       = Evidence.GetMethodScoreCap("fake_lag") -- suspicious-only tuning cap

local playerCooldowns             = {}  -- tick-based cooldown for rhythmic check
local avgChokeCooldowns           = {}  -- realtime-based cooldown for avg-choke check
local consecutiveChokeCount       = {}  -- count consecutive large deltas for impulse detection
local lastChokeDelta              = {}
local debugSummaries              = {}

-- ── helpers ────────────────────────────────────────────────────────────────
local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
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
	Evidence.AddEvidence(id, "fake_lag", actualWeight)
	return actualWeight
end

function FakeLag.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then return end
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.Choke) then return end
	if not Common.IsConnectionStableForDetection() then return end

	local pdata   = playerState.pdata
	local isAlive = pdata.isAlive
	if isAlive == nil or not isAlive then return end

	local id = playerState.id
	if id:sub(1, 4) == "BOT_" then return end
	if id == tostring(Common.GetSteamID64(entities.GetLocalPlayer())) and not Common.IsDebugEnabled() then return end

	local history = HistoryManager.GetPlayerHistory(id)
	if not history then return end

	-- Need at least 5 records
	local count = 0
	for _ in ipairs(history) do count = count + 1 end
	if count < 5 then return end

	-- Collect simulation times from history (newest first, history[1] = current)
	local simTimes = {}
	for _, record in ipairs(history) do
		local simTime = record[HistoryManager.Fields.SimulationTime]
		if simTime then
			simTimes[#simTimes + 1] = simTime
		end
	end

	if #simTimes < 5 then return end

	-- Build delta-tick array (positive deltas only, cap at 1.0s to ignore disconnect artifacts)
	local maxDeltaSec = 1.0
	local deltaTicks  = {}
	local sumTicks    = 0

	for i = 1, #simTimes - 1 do
		local delta = simTimes[i] - simTimes[i + 1] -- simTimes[i] is newer
		if delta > 0 and delta <= maxDeltaSec then
			local t = timeToTicks(delta)
			deltaTicks[#deltaTicks + 1] = t
			sumTicks = sumTicks + t
		end
	end

	local curTick       = globals.TickCount()
	local cooldownTicks = math.floor(FAKELAG_COOLDOWN_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
	local now           = globals.RealTime()
	local isDebug       = Common.IsLogCategoryEnabled("Choke")

	if isDebug then
		recordDebugSample(id, #deltaTicks, deltaTicks[1] or 0, now)
	end

	-- ── 1. Single large delta detection (for 330ms choke patterns) ─────────────
	-- Require 3 consecutive large deltas before adding evidence (impulse-based)
	if #deltaTicks >= 1 then
		local firstDelta = deltaTicks[1]
		if firstDelta >= BURST_CHOKE_MIN_TICKS then
			local previousDelta = lastChokeDelta[id]
			local tolerance = firstDelta >= 16 and 12 or 2
			if previousDelta and math.abs(firstDelta - previousDelta) > tolerance then
				consecutiveChokeCount[id] = 1
			else
				consecutiveChokeCount[id] = (consecutiveChokeCount[id] or 0) + 1
			end
			lastChokeDelta[id] = firstDelta

			if consecutiveChokeCount[id] >= BURST_CONFIRM_EVENTS then
				local lastFlag = playerCooldowns[id] or 0
				if (curTick - lastFlag) >= cooldownTicks then
					playerCooldowns[id] = curTick
					local strength = math.min(6.0, math.max(1.0, firstDelta / 4.0))
					local evidenceWeight = AVG_CHOKE_EVIDENCE_W * strength
					local addedWeight = addCappedFakeLagEvidence(id, evidenceWeight)
					if isDebug and addedWeight > 0 then
						print(string.format("[FakeLag] %s repeated choke/burst: %d ticks (%d events, evidence +%.1f)", id,
							firstDelta, consecutiveChokeCount[id], addedWeight))
					end
				end
			end
		else
			-- Reset counter if delta is below threshold
			consecutiveChokeCount[id] = 0
			lastChokeDelta[id] = nil
		end
	end

	-- ── 2. Rhythmic (original) ────────────────────────────────────────────
	if #deltaTicks >= RHYTHM_MIN_EVENTS then
		local firstDelta = deltaTicks[1]
		if firstDelta > 1 then
			local consistent = true
			for i = 2, #deltaTicks do
				local diff = math.abs(deltaTicks[i] - firstDelta)
				if diff > RHYTHM_TOLERANCE_TICKS then
					consistent = false
					break
				end
			end

			if consistent then
				local lastFlag = playerCooldowns[id] or 0
				if (curTick - lastFlag) >= cooldownTicks then
					playerCooldowns[id] = curTick
					local reason = string.format("Fake Lag (Rhythmic choke: %d ticks)", firstDelta)
					DetectorUtils.ApplyPlayerFlag(playerState, 5, nil, reason)
					if isDebug then
						print(string.format("[FakeLag] %s rhythmic choke: %d ticks", id, firstDelta))
					end
				end
			end
		end
	end

	-- ── 2. Average choke-tick (Rijin-derived) ────────────────────────────
	if #deltaTicks >= AVG_CHOKE_MIN_SAMPLES then
		local avgChoke = sumTicks / #deltaTicks

		if avgChoke >= AVG_CHOKE_THRESHOLD then
			local lastEvidence = avgChokeCooldowns[id] or 0
			if (now - lastEvidence) >= AVG_CHOKE_COOLDOWN_S then
				avgChokeCooldowns[id] = now
				local addedWeight = addCappedFakeLagEvidence(id, AVG_CHOKE_EVIDENCE_W)
				if isDebug and addedWeight > 0 then
					print(string.format("[FakeLag] %s avg choke %.2f ticks (>= %.1f) → evidence +%.1f",
						id, avgChoke, AVG_CHOKE_THRESHOLD, addedWeight))
				end
			end
		end
	end
end

-- ── cleanup ────────────────────────────────────────────────────────────────
Events.Subscribe("OnPlayerDisconnect", function(id)
	playerCooldowns[id]       = nil
	avgChokeCooldowns[id]     = nil
	consecutiveChokeCount[id] = nil
	lastChokeDelta[id]        = nil
	debugSummaries[id]        = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerCooldowns[id]       = nil
	avgChokeCooldowns[id]     = nil
	consecutiveChokeCount[id] = nil
	lastChokeDelta[id]        = nil
	debugSummaries[id]        = nil
end)

return FakeLag
