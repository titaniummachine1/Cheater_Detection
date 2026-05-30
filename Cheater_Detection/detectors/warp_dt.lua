--[[ detectors/warp_dt.lua
     Detects Double Tap / Warp exploit usage.

     Double Tap works by choking packets (storing ticks), then releasing them
     all at once to deal damage across multiple ticks simultaneously — typically
     used by Scout to deal 2× damage or move through danger zones faster.

     Detection strategy:
       1. Tick() tracks simtime delta for combat-active players only (fire/damage).
       2. OnHitscanHit checks if the attacker has a pending burst
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
local PlayerCache                           = require("Cheater_Detection.Core.player_cache")
local Common                                = require("Cheater_Detection.Utils.Common")
local Fetcher                               = require("Cheater_Detection.Database.Fetcher")

local WarpDT                                = {}

-- ── constants ──────────────────────────────────────────────────────────────

local SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD = 3 -- suppress if N players burst same tick (server hitch)

-- Burst detection: simtime spike must be in this tick range (scaled to server tickrate)
local BURST_MIN_TICKS_66HZ                  = 10.0 -- minimum choke for DT (~150ms), excludes normal jitter
local BURST_MAX_TICKS_66HZ                  = 66.0 -- ~1.0s: above this is a disconnect artifact, not DT

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

-- ── state ──────────────────────────────────────────────────────────────────

local playerState = {}
local watchUntil  = {}

local ACTIVITY_WINDOW_TICKS = 40


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
		playerState[id] = {
			lastDamageTick           = 0,
			lastBurstTick            = 0,
			lastBurstEvidenceTime    = 0,
			lastHitCountEvidenceTime = 0,
			recentHits               = { _data = {}, _head = 1, _count = 0 },
			prevSimTick              = nil,
			lastSimTick              = nil,
		}
	end
	return playerState[id]
end

local function watchPlayer(id, curTick)
	watchUntil[id] = curTick + ACTIVITY_WINDOW_TICKS
end

local function isEnabled()
	local adv = G.Menu and G.Menu.Advanced or nil
	return adv and adv["Warp"] == true
end


local function recordConfirmedHit(attackerID, tick)
	local ring = getState(attackerID).recentHits
	ring._data[ring._head] = tick
	ring._head = (ring._head % MAX_SHOT_HISTORY) + 1
	if ring._count < MAX_SHOT_HISTORY then
		ring._count = ring._count + 1
	end
end

local function tryBurst(pState, curTick)
	local id = pState.id
	local data = getState(id)
	local simTick = timeToTicks(pState.wrap:GetSimulationTime())

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

	local isDebug = Common.IsLogCategoryEnabled("Warp/DT")
	if isServerHitch(curTick) then
		lastServerHitchTick = curTick
		if isDebug then
			print(string.format("[DoubleTap] server hitch suppressed burst for %s (tick=%d)", id, curTick))
		end
		return
	end

	data.lastBurstTick = curTick
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

function WarpDT.Tick()
	if Fetcher.State.isRunning or not isEnabled() then return end
	if not Common.IsConnectionStableForDetection() then return end

	local curTick = globals.TickCount()
	local localID = tostring(Common.GetSteamID64(entities.GetLocalPlayer()))
	cleanBurstTable(curTick)

	for id, untilTick in pairs(watchUntil) do
		if curTick > untilTick then
			watchUntil[id] = nil
		elseif id == localID and not Common.IsDebugEnabled() then
			-- skip local player
		elseif id:sub(1, 4) == "BOT_" then
			watchUntil[id] = nil
		else
			local pState = PlayerCache.GetByID(id)
			if not pState or not pState.pdata.isAlive or (pState.flags & Constants.Flags.CHEATER) ~= 0 then
				watchUntil[id] = nil
			else
				tryBurst(pState, curTick)
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

local function onPlayerGone(id)
	playerState[id] = nil
	watchUntil[id] = nil
end

Events.Subscribe("OnPlayerDisconnect", onPlayerGone)
Events.Subscribe("OnPlayerRemoved", onPlayerGone)

return WarpDT
