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

local Constants = require("Cheater_Detection.Core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Events = require("Cheater_Detection.Core.Events")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

local FakeLag = {}

-- ── constants ──────────────────────────────────────────────────────────────
local FAKELAG_COOLDOWN_TICKS_66HZ = 22.0
local RHYTHM_MIN_EVENTS           = 3

-- Rijin-derived: avg choke-tick threshold
-- avg simtime gap >= 2 ticks across the window = fakelag signal
local AVG_CHOKE_THRESHOLD   = 2.0
local AVG_CHOKE_MIN_SAMPLES = 5      -- need at least this many deltas
local AVG_CHOKE_EVIDENCE_W  = 6.0   -- evidence weight per trigger
local AVG_CHOKE_COOLDOWN_S  = 4.0   -- seconds between evidence additions

local playerCooldowns   = {}  -- tick-based cooldown for rhythmic check
local avgChokeCooldowns = {}  -- realtime-based cooldown for avg-choke check

local svMaxUnlag = 0.2

-- ── helpers ────────────────────────────────────────────────────────────────
local function refreshCvarCache()
	local val = client.GetConVar("sv_maxunlag")
	if type(val) == "number" and val > 0 then
		svMaxUnlag = val
	end
end

refreshCvarCache()

local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
end

local function onMapOrRoundRefresh(_event)
	refreshCvarCache()
end

local function onPlayerSpawnRefresh(event)
	local spawnedEntity = entities.GetByUserID(event:GetInt("userid"))
	local localPlayer = entities.GetLocalPlayer()
	if spawnedEntity and localPlayer and spawnedEntity:GetIndex() == localPlayer:GetIndex() then
		refreshCvarCache()
	end
end

Events.Register("FireGameEvent", "FakeLag_CvarRefresh_Map",   onMapOrRoundRefresh,   "game_newmap")
Events.Register("FireGameEvent", "FakeLag_CvarRefresh_Round", onMapOrRoundRefresh,   "teamplay_round_start")
Events.Register("FireGameEvent", "FakeLag_CvarRefresh_Spawn", onPlayerSpawnRefresh,  "player_spawn")

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

	local ringCount = HistoryManager.GetRingCount()
	if ringCount < 5 then return end

	-- Collect simulation times from history (newest first)
	local simTimes = {}
	for i = 0, ringCount - 1 do
		local bucket  = HistoryManager.GetBucketAt(i)
		local simTime = HistoryManager.GetPlayerFieldAt(bucket, id, HistoryManager.Fields.SimulationTime)
		if simTime then
			simTimes[#simTimes + 1] = simTime
		end
	end

	if #simTimes < 5 then return end

	-- Build delta-tick array (positive deltas only, cap at svMaxUnlag to ignore teleports)
	local maxDeltaSec = svMaxUnlag
	local deltaTicks  = {}
	local sumTicks    = 0

	for i = 1, #simTimes - 1 do
		local delta = simTimes[i] - simTimes[i + 1]  -- simTimes[i] is newer
		if delta > 0 and delta <= maxDeltaSec then
			local t = timeToTicks(delta)
			deltaTicks[#deltaTicks + 1] = t
			sumTicks = sumTicks + t
		end
	end

	local curTick       = globals.TickCount()
	local cooldownTicks = math.floor(FAKELAG_COOLDOWN_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
	local now           = globals.RealTime()
	local isDebug       = Common.IsDebugEnabled()

	-- ── 1. Rhythmic (original) ────────────────────────────────────────────
	if #deltaTicks >= RHYTHM_MIN_EVENTS then
		local firstDelta = deltaTicks[1]
		if firstDelta > 1 then
			local consistent = true
			for i = 2, #deltaTicks do
				local diff = math.abs(deltaTicks[i] - firstDelta)
				if diff > 1 then
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
	playerCooldowns[id]   = nil
	avgChokeCooldowns[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerCooldowns[id]   = nil
	avgChokeCooldowns[id] = nil
end)

return FakeLag
