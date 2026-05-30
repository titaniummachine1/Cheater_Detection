--[[ detectors/fake_lag.lua
     Sustained / rhythmic packet choke only — NOT double tap.

     Double tap (~24 tick release at 66 Hz) is warp_dt.lua only.

     Fake lag = repeated choke → release (8–21 ticks) → immediate re-choke, same
     release size, at least 3 cycles in a row (stalls only between releases).
     One isolated burst is not fake lag — that is DT or normal movement.
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
local MIN_FAKELAG_CYCLES          = 3   -- choke → release → re-choke, at least this many releases
local RELEASE_TOLERANCE_TICKS     = 1   -- same unchoke size each cycle (±1 tick)
local STALL_MAX_TICKS             = 1   -- simtime frozen while choking
local MAX_GAP_BETWEEN_RELEASES    = 2   -- no normal movement between FL cycles
local AVG_CHOKE_EVIDENCE_W        = 6.0
local FAKE_LAG_EVIDENCE_CAP       = Evidence.GetMethodScoreCap("fake_lag")
local MIN_FPS_FOR_DETECTION       = 40
local MAX_DELTA_SEC               = 2.5

local evidenceCooldowns           = {} -- [id] = last globals.RealTime() evidence was added
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

local function isFakeLagChokeDelta(tickDelta)
	if not tickDelta then
		return false
	end
	return tickDelta >= WarpDT.GetFakeLagMinChokeTicks()
		and tickDelta <= WarpDT.GetFakeLagMaxChokeTicks()
end

local function hasDtBurstInWindow(deltaTicks)
	for i = 1, #deltaTicks do
		if WarpDT.IsDtSizedBurst(deltaTicks[i]) then
			return true
		end
	end
	return false
end

-- deltaTicks[1] = newest. Walk oldest → newest for choke → release → re-choke chains.
local function countFakeLagCycles(deltaTicks)
	local cycles = 0
	local anchorRelease = nil
	local sawStallSinceLastRelease = false

	for i = #deltaTicks, 1, -1 do
		local d = deltaTicks[i]

		if WarpDT.IsDtSizedBurst(d) then
			return 0, nil
		end

		if isFakeLagChokeDelta(d) then
			if cycles > 0 and not sawStallSinceLastRelease then
				cycles = 0
				anchorRelease = nil
			end
			if anchorRelease == nil then
				anchorRelease = d
				cycles = 1
			elseif math.abs(d - anchorRelease) <= RELEASE_TOLERANCE_TICKS then
				cycles = cycles + 1
			else
				anchorRelease = d
				cycles = 1
			end
			sawStallSinceLastRelease = false
		elseif d <= STALL_MAX_TICKS then
			sawStallSinceLastRelease = true
		elseif d > MAX_GAP_BETWEEN_RELEASES then
			cycles = 0
			anchorRelease = nil
			sawStallSinceLastRelease = false
		end
	end

	return cycles, anchorRelease
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
	if WarpDT.ShouldSuppressFakeLag(id) or WarpDT.IsPlayerWatched(id) then
		return
	end

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

	for i = 1, #simTimes - 1 do
		local delta = simTimes[i] - simTimes[i + 1] -- simTimes[i] is newer
		if delta > 0 and delta <= MAX_DELTA_SEC then
			local t = timeToTicks(delta)
			if t then
				deltaTicks[#deltaTicks + 1] = t
			end
		end
	end

	if hasDtBurstInWindow(deltaTicks) then
		WarpDT.MarkDtRelease(id)
		return
	end

	local cycleCount, releaseTicks = countFakeLagCycles(deltaTicks)
	if cycleCount < MIN_FAKELAG_CYCLES or not releaseTicks then
		return
	end

	local now     = globals.RealTime()
	local isDebug = Common.IsLogCategoryEnabled("Choke")

	Evidence.HoldDecayForMethod(id, "fake_lag")
	tryAddChokeEvidence(
		id, now, isDebug,
		AVG_CHOKE_EVIDENCE_W,
		"choke cycles",
		string.format("%dx%d-tick releases (<%d max)", cycleCount, releaseTicks, WarpDT.GetDtBurstMinTicks())
	)
end

-- ── cleanup ────────────────────────────────────────────────────────────────
Events.Subscribe("OnPlayerDisconnect", function(id)
	evidenceCooldowns[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	evidenceCooldowns[id] = nil
end)

return FakeLag
