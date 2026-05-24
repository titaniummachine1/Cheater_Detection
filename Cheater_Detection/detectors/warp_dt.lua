--[[ detectors/warp_dt.lua
     Detects Double Tap / Warp exploit usage.

     Double Tap works by choking packets (storing ticks), then releasing them
     all at once to deal damage across multiple ticks simultaneously — typically
     used by Scout to deal 2× damage or move through danger zones faster.

     Detection strategy:
       1. ProcessPlayer tracks each player's simtime delta history and records a
          "pending burst" when a large isolated spike appears (not a repeated
          fake-lag pattern).
       2. The player_hurt game event checks if the attacker has a pending burst
          within DT_CONFIRM_WINDOW_S seconds. Only if burst + damage are
          correlated does evidence get added.

     This eliminates fake-lag false positives: fake laggers choke continuously
     but don't necessarily deal damage on every release; DT abusers release
     specifically to land hits.
]]

local Constants                             = require("Cheater_Detection.Core.constants")
local G                                     = require("Cheater_Detection.Utils.Globals")
local Evidence                              = require("Cheater_Detection.Core.Evidence_system")
local Events                                = require("Cheater_Detection.Core.Events")
local HistoryManager                        = require("Cheater_Detection.Utils.HistoryManager")
local Common                                = require("Cheater_Detection.Utils.Common")

local WarpDT                                = {}

-- ── constants ──────────────────────────────────────────────────────────────

local SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD = 3 -- suppress if N players burst same tick (server hitch)

-- Burst detection: simtime spike must be in this tick range (scaled to server tickrate)
local BURST_MIN_TICKS_66HZ                  = 10.0 -- minimum choke for DT (~150ms), excludes normal jitter
local BURST_MAX_TICKS_66HZ                  = 66.0 -- ~1.0s: above this is a disconnect artifact, not DT

-- A burst is only a spike if fewer than 2 other deltas in the window match it
-- (fake lag produces repeating matching deltas; DT is a single isolated spike)
local BURST_REPEAT_TOLERANCE                = 8 -- ticks: ±this = "similar" delta

-- Correlation: damage must land within this many ticks of the burst to count.
-- Default DT is ~24 ticks at 66Hz = ~0.36s; 33 ticks (0.5s) gives a small network buffer.
local DT_CONFIRM_WINDOW_TICKS               = 33.0 -- ~0.5s at 66 tickrate

local DT_EVIDENCE_WEIGHT                    = 30.0 -- base evidence weight at max delay (t=0.5s)
local DT_EVIDENCE_MAX_MULT                  = 5.0  -- multiplier at t=0 (instant hit after burst)
local DT_EVIDENCE_COOLDOWN_S                = 1.0  -- min seconds between evidence adds per player

-- Hit history constants
local MAX_SHOT_HISTORY                      = 8 -- keep last N confirmed hits per player

-- ── state ──────────────────────────────────────────────────────────────────

-- [id] = { lastDamageTick, lastBurstTick, lastBurstEvidenceTime, lastHitCountEvidenceTime, recentHits }
local playerState                           = {}


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

local function isServerHitch(tick)
	local list = burstThisTick[tick]
	return list and #list >= SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD
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
		playerState[id] = { lastDamageTick = 0, lastBurstTick = 0, lastBurstEvidenceTime = 0, lastHitCountEvidenceTime = 0, recentHits = {} }
	end
	return playerState[id]
end

local function isEnabled()
	local adv = G.Menu and G.Menu.Advanced or nil
	return adv and adv["Warp"] == true
end


local function recordConfirmedHit(attackerID, tick)
	local data = getState(attackerID)
	local hits = data.recentHits
	hits[#hits + 1] = tick
	while #hits > MAX_SHOT_HISTORY do
		table.remove(hits, 1)
	end
end

local function getLastConfirmedHitDelta(attackerID, tick)
	local data = getState(attackerID)
	local hits = data.recentHits
	if #hits == 0 then return nil end
	return tick - hits[#hits]
end

-- ── burst detection (called per-player each tick) ──────────────────────────

function WarpDT.ProcessPlayer(pState)
	if not pState or not pState.pdata or not pState.id then return end
	if not isEnabled() then return end
	if not Common.IsConnectionStableForDetection() then return end

	local pdata = pState.pdata
	if not pdata.isAlive then return end

	local id = pState.id
	if id:sub(1, 4) == "BOT_" then return end

	local isDebug = Common.IsLogCategoryEnabled("Warp/DT")
	if id == tostring(Common.GetSteamID64(entities.GetLocalPlayer())) and not Common.IsDebugEnabled() then return end
	if (pState.flags & Constants.Flags.CHEATER) ~= 0 then return end

	local history = HistoryManager.GetPlayerHistory(id)
	if not history then return end

	local simTicks = {}
	HistoryManager.ForEachRecordNewestFirst(history, nil, function(_, record)
		local simTime = record[HistoryManager.Fields.SimulationTime]
		if simTime then
			simTicks[#simTicks + 1] = timeToTicks(simTime)
		end
	end)
	if #simTicks < 10 then return end

	local deltaTicks = {}
	for i = 1, #simTicks - 1 do
		deltaTicks[#deltaTicks + 1] = simTicks[i] - simTicks[i + 1]
	end

	local burstMin    = math.floor(BURST_MIN_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
	local burstMax    = math.floor(BURST_MAX_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
	-- Only check the MOST RECENT delta for burst (newest-first history)
	local burstAmount = 0
	if #deltaTicks >= 1 then
		local d = deltaTicks[1] -- most recent delta only
		if d >= burstMin and d < burstMax then
			burstAmount = d
		end
	end
	if burstAmount == 0 then return end

	local curTick = globals.TickCount()
	cleanBurstTable(curTick)
	recordBurstTick(curTick, id)

	if isInHitchWindow(curTick) then return end

	if isServerHitch(curTick) then
		lastServerHitchTick = curTick
		if isDebug then
			print(string.format("[DoubleTap] server hitch suppressed burst for %s (tick=%d)", id, curTick))
		end
		return
	end

	-- Record burst tick for reverse correlation (damage after burst)
	local data = getState(id)
	data.lastBurstTick = curTick

	-- Burst after damage = Double Tap confirmed.
	-- Check if a prior damage event is still within the correlation window.
	if data.lastDamageTick > 0 and (curTick - data.lastDamageTick) <= DT_CONFIRM_WINDOW_TICKS then
		-- Damage → burst within window: DT usage.
		-- Exponential weight: closer the burst to the damage, more suspicious.
		-- k = ln(MAX_MULT) / WINDOW so at t=0 → MAX_MULT, at t=WINDOW → 1.0
		local elapsedTicks = curTick - data.lastDamageTick
		local k = math.log(DT_EVIDENCE_MAX_MULT) / DT_CONFIRM_WINDOW_TICKS
		local mult = DT_EVIDENCE_MAX_MULT * math.exp(-k * elapsedTicks)
		local weight = DT_EVIDENCE_WEIGHT * mult

		data.lastDamageTick = 0 -- consume so one burst only confirms once

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

	-- Note: bursts without prior damage are silently ignored (lag/fake lag, not DT)
end

-- ── damage recording (via CombatEvents hub) ──────────────────────────────
-- Subscribes to the pre-resolved OnHitscanHit event published by
-- Core/CombatEvents.lua — entity lookup and weapon classification are
-- already done once for all detectors.

Events.Subscribe("OnHitscanHit", function(hit)
	if not isEnabled() then return end

	local attackerID = hit.attackerID
	local curTick    = hit.tickCount
	local data       = getState(attackerID)

	recordConfirmedHit(attackerID, curTick)

	if data.lastBurstTick > 0 and (curTick - data.lastBurstTick) <= DT_CONFIRM_WINDOW_TICKS then
		local hitsInWindow = 0
		local hits = data.recentHits
		for i = #hits, 1, -1 do
			if hits[i] >= data.lastBurstTick then
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
				if Common.IsLogCategoryEnabled("Warp/DT") then
					print(string.format(
						"[DoubleTap] %s DT: %d hits in %d ticks after %d-tick burst, dmg=%d → evidence +%.1f",
						attackerID, hitsInWindow, elapsedTicks,
						data.lastBurstTick > 0 and (curTick - data.lastBurstTick) or 0, hit.damage, weight))
				end
			end
		end
	end

	data.lastDamageTick = curTick

	if Common.IsLogCategoryEnabled("Warp/DT") then
		print(string.format("[DoubleTap] %s dealt dmg=%d — watching for burst within %d ticks",
			attackerID, hit.damage, DT_CONFIRM_WINDOW_TICKS))
	end
end)


-- ── cleanup ────────────────────────────────────────────────────────────────

Events.Subscribe("OnPlayerDisconnect", function(id)
	playerState[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerState[id] = nil
end)

return WarpDT
