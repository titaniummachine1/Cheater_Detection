--[[ detectors/warp_dt.lua
     Double Tap only (not generic warp — too noisy).

     DT = choke → unchoke → ~24 tick simtime jump (66 Hz). Fake lag stays below 22 ticks.

     Detection:
       1. ProcessPlayer — history scan for bursts >= 22 ticks (typical DT ~24).
       2. Tick / OnHitscanHit — optional burst+damage correlation (stronger signal).
       3. markDtRelease — suppress fake_lag scoring briefly after a burst.
]]

local Constants                             = require("Cheater_Detection.Core.constants")
local G                                     = require("Cheater_Detection.Utils.Globals")
local Evidence                              = require("Cheater_Detection.Core.Evidence_system")
local Events                                = require("Cheater_Detection.Core.Events")
local PlayerCache                           = require("Cheater_Detection.Core.player_cache")
local Common                                = require("Cheater_Detection.Utils.Common")
local Fetcher                               = require("Cheater_Detection.Database.Fetcher")
local HistoryManager                        = require("Cheater_Detection.Utils.HistoryManager")
local DetectionConfig                       = require("Cheater_Detection.Utils.DetectionConfig")

local WarpDT                                = {}

-- ── constants ──────────────────────────────────────────────────────────────

-- Hitch = multiple *humans* bursting same tick (bots on itemtest choke constantly).
local SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD = 3

-- Burst detection: simtime spike must be in this tick range (scaled to server tickrate)
-- At 66 Hz: FL choke < 22 ticks (~330 ms); DT release is almost always ~24 ticks.
local BURST_MIN_TICKS_66HZ                  = 22.0
local BURST_MAX_TICKS_66HZ                  = 64.0 -- above this is disconnect/lag, not DT
local WARP_COOLDOWN_TICKS_66HZ              = 24.0 -- min spacing between ProcessPlayer burst flags
local FAKE_LAG_SUPPRESS_TICKS_66HZ          = 66.0 -- ~1s: no fake_lag scoring after DT release

-- Correlation: damage must land within this many ticks of the burst to count.
-- Default DT is ~24 ticks at 66Hz = ~0.36s; 33 ticks (0.5s) gives a small network buffer.
local DT_CONFIRM_WINDOW_TICKS               = 33.0 -- ~0.5s at 66 tickrate

local DT_EVIDENCE_WEIGHT                    = 30.0 -- base evidence weight at max delay (t=0.5s)
local DT_EVIDENCE_MAX_MULT                  = 5.0  -- multiplier at t=0 (instant hit after burst)
local DT_EVIDENCE_COOLDOWN_S                = 1.0  -- min seconds between evidence adds per player

-- Hit history constants
local MAX_SHOT_HISTORY                      = 8 -- keep last N confirmed hits per player

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
	return WarpDT.GetDtBurstMinTicks() - 1
end

function WarpDT.GetFakeLagMinChokeTicks()
	return math.max(3, math.floor(4.0 / 66.0 / globals.TickInterval() + 0.5))
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
-- Must cover DT release (~24 ticks) after damage; match BURST_MAX window.
local ACTIVITY_WINDOW_TICKS = 66


-- Server-hitch suppression: track which ticks had simultaneous bursts
local burstThisTick       = {}
local lastBurstCleanTick  = 0
local lastServerHitchTick = -math.huge

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
			recentHits               = { _data = {}, _head = 1, _count = 0 },
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
	watchUntil[id] = curTick + ACTIVITY_WINDOW_TICKS
end

local function isEnabled()
	return Common.IsDoubleTapDetectionEnabled()
end

local function isDtLogEnabled()
	return Common.IsLogCategoryEnabled("DoubleTap")
end

function WarpDT.MarkDtRelease(id)
	if not id then
		return
	end
	markDtRelease(id, globals.TickCount())
end

function WarpDT.IsPlayerWatched(id)
	local untilTick = watchUntil[id]
	if not untilTick then
		return false
	end
	return globals.TickCount() <= untilTick
end

local function findHistoryBurst(id)
	local history = HistoryManager.GetPlayerHistory(id)
	if not history or history._count < 10 then
		return 0
	end

	for k = 1, #_simTimes do
		_simTimes[k] = nil
	end
	HistoryManager.ForEachRecordNewestFirst(history, nil, _collectSimTime)
	if #_simTimes < 10 then
		return 0
	end

	local burstMin, burstMax = getBurstThresholds()
	for i = 1, #_simTimes - 1 do
		local delta = _simTimes[i] - _simTimes[i + 1]
		if delta > 0 then
			local d = timeToTicks(delta)
			if d >= burstMin and d < burstMax then
				return d
			end
		end
	end
	return 0
end

local function tryAddProcessBurstEvidence(playerState, burstAmount, curTick)
	local id = playerState.id
	local data = getState(id)

	markDtRelease(id, curTick)
	data.lastBurstTick = curTick

	local cooldownTicks = math.floor(WARP_COOLDOWN_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
	if data.lastProcessBurstTick > 0 and (curTick - data.lastProcessBurstTick) <= cooldownTicks then
		return
	end
	data.lastProcessBurstTick = curTick

	local now = globals.RealTime()
	if (now - data.lastBurstEvidenceTime) < DT_EVIDENCE_COOLDOWN_S then
		return
	end
	data.lastBurstEvidenceTime = now

	local weight = math.min(40, burstAmount * 1.2)
	Evidence.AddEvidence(id, "warp_dt", weight)
	if isDtLogEnabled() then
		print(string.format("[DoubleTap] %s packet burst: %d ticks → evidence +%.1f",
			id, burstAmount, weight))
	end
end

local function recordConfirmedHit(attackerID, tick)
	local ring = getState(attackerID).recentHits
	ring._data[ring._head] = tick
	ring._head = (ring._head % MAX_SHOT_HISTORY) + 1
	if ring._count < MAX_SHOT_HISTORY then
		ring._count = ring._count + 1
	end
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

	data.lastBurstTick = curTick
	markDtRelease(id, curTick)
	if data.lastDamageTick > 0 and (curTick - data.lastDamageTick) <= DT_CONFIRM_WINDOW_TICKS then
		local elapsedTicks = curTick - data.lastDamageTick
		local k = math.log(DT_EVIDENCE_MAX_MULT) / DT_CONFIRM_WINDOW_TICKS
		local weight = DT_EVIDENCE_WEIGHT * DT_EVIDENCE_MAX_MULT * math.exp(-k * elapsedTicks)
		data.lastDamageTick = 0

		local now = globals.RealTime()
		if (now - data.lastBurstEvidenceTime) >= DT_EVIDENCE_COOLDOWN_S then
			data.lastBurstEvidenceTime = now
			Evidence.AddEvidence(id, "warp_dt", weight)
			if isDebug then
				print(string.format("[DoubleTap] %s burst after dmg (delay=%d ticks, %d ticks) → evidence +%.1f",
					id, elapsedTicks, burstAmount, weight))
			end
		end
	end
end

function WarpDT.ProcessPlayer(playerState)
	if Fetcher.State.isRunning or not isEnabled() then
		return
	end
	if not Common.IsConnectionStableForDetection() then
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

	local burstAmount = findHistoryBurst(id)
	if burstAmount == 0 then
		return
	end

	local curTick = globals.TickCount()
	cleanBurstTable(curTick)
	recordBurstTick(curTick, id)

	if isInHitchWindow(curTick) then
		return
	end

	if isServerHitch(curTick) then
		lastServerHitchTick = curTick
		if isDtLogEnabled() then
			print(string.format(
				"[DoubleTap] server hitch suppressed burst for %s (tick=%d, humans=%d)",
				id, curTick, countHumanBurstsOnTick(curTick)))
		end
		return
	end

	tryAddProcessBurstEvidence(playerState, burstAmount, curTick)
end

function WarpDT.Tick()
	if Fetcher.State.isRunning or not isEnabled() then return end
	if not Common.IsConnectionStableForDetection() then return end

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
	if isEnabled() then watchPlayer(fire.shooterID, fire.tick) end
end)

Events.Subscribe("OnHitscanHit", function(hit)
	if not isEnabled() then return end

	local attackerID = hit.attackerID
	local curTick    = hit.tickCount
	local data       = getState(attackerID)

	watchPlayer(attackerID, curTick)

	local attackerState = PlayerCache.GetByID(attackerID)
	if attackerState and attackerState.pdata.isAlive then
		-- Sample on hurt tick too (CreateMove may run before player_hurt this frame).
		sampleSimBurst(attackerState, curTick)
	end

	recordConfirmedHit(attackerID, curTick)

	if data.lastBurstTick > 0 and (curTick - data.lastBurstTick) <= DT_CONFIRM_WINDOW_TICKS then
		local hitsInWindow = 0
		local ring = data.recentHits
		for i = 0, ring._count - 1 do
			local idx = ((ring._head - 2 - i) % MAX_SHOT_HISTORY) + 1
			local hitTick = ring._data[idx]
			if hitTick and hitTick >= data.lastBurstTick then
				hitsInWindow = hitsInWindow + 1
			else
				break
			end
		end

		if hitsInWindow >= 2 then
			local now = globals.RealTime()
			if (now - data.lastHitCountEvidenceTime) >= DT_EVIDENCE_COOLDOWN_S then
				data.lastHitCountEvidenceTime = now
				local certaintyMult           = 2 ^ (hitsInWindow - 2)
				local elapsedTicks            = curTick - data.lastBurstTick
				local k                       = math.log(DT_EVIDENCE_MAX_MULT) / DT_CONFIRM_WINDOW_TICKS
				local timeMult                = DT_EVIDENCE_MAX_MULT * math.exp(-k * elapsedTicks)
				local weight                  = DT_EVIDENCE_WEIGHT * timeMult * certaintyMult

				Evidence.AddEvidence(attackerID, "warp_dt", weight)
				if isDtLogEnabled() then
					print(string.format(
						"[DoubleTap] %s DT: %d hits in %d ticks after %d-tick burst, dmg=%d → evidence +%.1f",
						attackerID, hitsInWindow, elapsedTicks,
						data.lastBurstTick > 0 and (curTick - data.lastBurstTick) or 0, hit.damage, weight))
				end
			end
		end
	end

	data.lastDamageTick = curTick

	if isDtLogEnabled() then
		print(string.format(
			"[DoubleTap] %s dealt dmg=%d — watching for burst (lastBurstTick=%d, window=%d ticks)",
			attackerID, hit.damage, data.lastBurstTick, DT_CONFIRM_WINDOW_TICKS))
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
