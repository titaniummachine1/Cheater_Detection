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
local FAKELAG_COOLDOWN_TICKS_66HZ = 66.0 -- 1 second cooldown at 66Hz
local RHYTHM_MIN_EVENTS           = 8    -- require 8 consecutive large deltas for detection (stricter)
local RHYTHM_TOLERANCE_TICKS      = 2    -- ±2 ticks tolerance (was ±1)

-- Rijin-derived: avg choke-tick threshold
-- avg simtime gap >= 2 ticks across the window = fakelag signal
local AVG_CHOKE_THRESHOLD         = 3.8
local AVG_CHOKE_MIN_SAMPLES       = 3    -- require more samples for average calculation
local AVG_CHOKE_EVIDENCE_W        = 10.0 -- evidence weight per trigger (higher for extreme fake lag)
local AVG_CHOKE_COOLDOWN_S        = 4.0  -- 4 second cooldown between detections

local playerCooldowns             = {}   -- tick-based cooldown for rhythmic check
local avgChokeCooldowns           = {}   -- realtime-based cooldown for avg-choke check
local consecutiveChokeCount       = {}   -- count consecutive large deltas for impulse detection

-- ── helpers ────────────────────────────────────────────────────────────────
local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
end

-- ── main entry ─────────────────────────────────────────────────────────────
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
		print(string.format("[FakeLag] %s deltaTicks: %d entries, firstDelta=%d", id, #deltaTicks, deltaTicks[1] or 0))
	end

	-- ── 1. Single large delta detection (for 330ms choke patterns) ─────────────
	-- Require 3 consecutive large deltas before adding evidence (impulse-based)
	if #deltaTicks >= 1 then
		local firstDelta = deltaTicks[1]
		if firstDelta >= 38 then -- 38 ticks = ~575ms at 66Hz - higher threshold for leniency
			-- Count consecutive large deltas
			consecutiveChokeCount[id] = (consecutiveChokeCount[id] or 0) + 1

			-- Only add evidence after 8 consecutive detections
			if consecutiveChokeCount[id] >= 8 then
				local lastFlag = playerCooldowns[id] or 0
				if (curTick - lastFlag) >= cooldownTicks then
					playerCooldowns[id] = curTick
					-- Use evidence system instead of ApplyPlayerFlag for decay
					Evidence.AddEvidence(id, "fake_lag", AVG_CHOKE_EVIDENCE_W)
					if isDebug then
						print(string.format("[FakeLag] %s large choke: %d ticks (8 consecutive, evidence +%.1f)", id,
							firstDelta, AVG_CHOKE_EVIDENCE_W))
					end
				end
			end
		else
			-- Reset counter if delta is below threshold
			consecutiveChokeCount[id] = 0
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
				Evidence.AddEvidence(id, "fake_lag", AVG_CHOKE_EVIDENCE_W)
				if isDebug then
					print(string.format("[FakeLag] %s avg choke %.2f ticks (>= %.1f) → evidence +%.1f",
						id, avgChoke, AVG_CHOKE_THRESHOLD, AVG_CHOKE_EVIDENCE_W))
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
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerCooldowns[id]       = nil
	avgChokeCooldowns[id]     = nil
	consecutiveChokeCount[id] = nil
end)

return FakeLag
