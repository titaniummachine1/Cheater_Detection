--[[ detectors/antiaim.lua
     Detects rage anti-aim via two complementary methods:

     1. Invalid Pitch  – networked eye pitch outside ±89.9° (classic AA tell).
        Accumulates a weighted hit score with decay; crossing SCORE_THRESHOLD
        (3+ ticks) hard-flags the player as CHEATER.

     2. Yaw-Delta History – analyses HistoryManager buckets for yaw AA patterns:
          • repeatTriggered : A→B→A angle alternation (RijiN angle_repeat) —
            primary desync AA signal, no choke gate.
          • avgTriggered    : elevated avg choke AND large avg delta — secondary
            signal for badly-implemented AA that also chokes packets.
          • maxTriggered    : single large snap bracketed by quiet frames
            (StAC aimsnapCheck).
          • flipTriggered   : alternating 120°+ flips, snap-bracketed.
        All fire Evidence.AddEvidence so they decay and stack.
]]

local Constants               = require("Cheater_Detection.Core.constants")
local Common                  = require("Cheater_Detection.Utils.Common")
local DetectorUtils           = require("Cheater_Detection.Utils.DetectorUtils")
local Evidence                = require("Cheater_Detection.Core.Evidence_system")
local Events                  = require("Cheater_Detection.Core.Events")
local G                       = require("Cheater_Detection.Utils.Globals")
local PlayerData              = require("Cheater_Detection.Utils.PlayerData")
local HistoryManager          = require("Cheater_Detection.Utils.HistoryManager")

local AntiAim                 = {}

-- Source engine netchannel flow direction constants
local FLOW_OUTGOING           = 0
local FLOW_INCOMING           = 1

-- ── constants ──────────────────────────────────────────────────────────────
-- Pitch threshold: legit players can hit ~89.5 when looking up (rocket jumps)
-- Cheats usually send exactly 90 or -90, so 89.9 catches them while avoiding false positives
local MAX_LEGAL_PITCH         = 89.90
local MAX_SANE_ABS_ANGLE      = 540
-- No cooldown for pitch - check every tick for continuous invalid pitch
local HIT_WEIGHT              = 0.34
local SCORE_DECAY_PER_TICK    = 0.05 -- Small per-tick decay (slower than accumulation)
local SCORE_THRESHOLD         = 1.0  -- 3 ticks of invalid pitch = flag

-- Yaw-history settings (using HistoryManager as single source of truth)
local YAW_HISTORY_SIZE        = 16    -- records to read from HistoryManager
local YAW_DELTA_THRESHOLD     = 20.0  -- degrees avg delta = yaw AA signal
local YAW_MAX_DELTA_THRESHOLD = 65.0  -- single-tick jump threshold (Rijin: large snap = AA desync)
local CHOKE_TICK_THRESHOLD    = 2.0   -- avg ticks gap required for avg-delta+choke trigger
local CHOKE_MAX_SANE_TICKS    = 8.0   -- above this = player was dormant/untracked; skip detection
local YAW_EVIDENCE_WEIGHT     = 15.0  -- evidence weight per positive detection
local YAW_EVIDENCE_COOLDOWN   = 1.0   -- seconds between evidence additions
local YAW_FLIP_THRESHOLD      = 120.0 -- legit-yaw AA: back-and-forth flip minimum degrees
local YAW_REPEAT_MIN_DEG      = 15.0  -- min snap for A→B→A repeat pattern (RijiN angle_repeat)
local YAW_REPEAT_EPSILON      = 3.0   -- max diff to consider two angles "the same" in repeat check

-- Minimum netchannel quality thresholds — below these we can't trust simtime gaps
local OUR_MAX_LOSS_SKIP       = 0.05 -- skip if our own packet loss > 5%
local OUR_MAX_CHOKE_SKIP      = 4    -- skip if we are choking > 4 outgoing packets

-- ── per-player state ───────────────────────────────────────────────────────
local antiAimStateById        = {} -- pitch-score state

-- ── helpers ────────────────────────────────────────────────────────────────
local function isInvalidPitch(pitch)
	if type(pitch) ~= "number" then return false end
	return pitch > MAX_LEGAL_PITCH or pitch < -MAX_LEGAL_PITCH
end

local MATH_HUGE = math.huge

local function isCorrupted(value)
	if type(value) ~= "number" then return true end
	if value ~= value or value == MATH_HUGE or value == -MATH_HUGE then return true end
	local absVal = math.abs(value)
	return absVal > MAX_SANE_ABS_ANGLE
end

local function toNum(v)
	if type(v) == "number" then return v end
	if type(v) == "string" then return tonumber(v) end
	return nil
end

local function tryExtractPitchYaw(ao)
	if ao == nil then return nil, nil end
	local ok, p, y, x, yy = pcall(function() return ao.pitch, ao.yaw, ao.x, ao.y end)
	if not ok then return nil, nil end
	return toNum(p) or toNum(x), toNum(y) or toNum(yy)
end

local function traceLog(playerState, detail)
	if not Common.IsLogCategoryEnabled("AntiAim") then return end
	local id = playerState and playerState.id or "nil"
	local msg = string.format("[AntiAim] id=%s %s", tostring(id), tostring(detail or ""))
	print(msg)
end

-- ── pitch-score state ──────────────────────────────────────────────────────
local function getPitchState(playerID)
	local s = antiAimStateById[playerID]
	if not s then
		s = { score = 0, lastHitTime = 0, lastDecayTime = globals.RealTime(), lastSimTime = nil }
		antiAimStateById[playerID] = s
	end
	return s
end

local mathMax = math.max

local function applyPitchDecay(state, now)
	if not state then return end
	local elapsed = now - (state.lastDecayTime or now)
	if elapsed > 0 then
		-- Per-tick decay (approx 66 ticks/sec at 66 tickrate)
		local ticks = math.floor(elapsed / globals.TickInterval())
		local decayed = (state.score or 0) - (SCORE_DECAY_PER_TICK * ticks)
		state.score = mathMax(0, decayed)
		state.lastDecayTime = now
	end
end

-- ── networked-angle reading ────────────────────────────────────────────────
local function readNetAngles(entity, cmd, isLocalDebug)
	if not entity then return nil, nil, "nil" end

	-- 1. cmd angles (local debug only)
	if isLocalDebug and cmd then
		local p, y = tryExtractPitchYaw(cmd:GetViewAngles())
		if p ~= nil and not isCorrupted(p) then return p, y, "cmd" end
	end

	-- 2. tfnonlocaldata table holds the full unclamped networked eye angles for
	--    remote players. GetPropFloat("m_angEyeAngles[0]") is engine-clamped to
	--    ±90 and must not be used here. Single-arg GetPropVector returns nil.
	local av = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
	if av and (av.x ~= 0 or av.y ~= 0) then
		local p = toNum(av.x)
		local y = toNum(av.y)
		if p ~= nil and not isCorrupted(p) then
			return p, y, "propvec"
		end
	end

	-- 3. GetVAngles fallback
	local va = entity:GetVAngles()
	if va and (va.x ~= 0 or va.y ~= 0) then
		local p = toNum(va.x)
		local y = toNum(va.y)
		if p ~= nil and not isCorrupted(p) then
			return p, y, "vangles"
		end
	end

	return nil, nil, "nil"
end

-- ── yaw-history helpers (using HistoryManager) ─────────────────────────────
-- Returns the shortest signed delta between two yaw angles [-180, 180]
local function yawDelta(a, b)
	local d = (a - b) % 360
	if d > 180 then d = d - 360 end
	return d
end

-- Per-player cooldown for evidence (not stored in HistoryManager)
local yawEvidenceCooldownById = {}

-- Quiet-frame threshold for noise-bracket guard (degrees)
local NOISE_BRACKET_MAX_DEG = 2.0

-- Returns avg_yaw_delta, avg_choke_ticks, max_yaw_delta, flip_count, cooldownTime,
--         snapBracketed (bool), repeatCount (int — A→B→A desync pattern per RijiN)
--
-- Real desync AA: simTime advances ~1 tick normally, yaw alternates A→B→A every tick.
-- repeatCount detects this with no choke gate. avgTriggered is the secondary path for
-- badly-implemented AA that also chokes packets.
local function analyseYawHistoryFromManager(id)
	if not HistoryManager.IsInitialized() then return nil, nil, nil, nil, nil, false, 0 end

	local tickInterval  = globals.TickInterval()
	local collected     = 0
	local sumYawDelta   = 0.0
	local sumChokeTicks = 0
	local maxYawDelta   = 0.0
	local flipCount     = 0
	local repeatCount   = 0
	local lastDeltaSign = 0

	local frameDeltas   = {}
	local frameYaws     = {} -- raw yaw per record, index 1 = newest
	local recordCount   = 0
	local lastRecord    = nil

	local history       = HistoryManager.GetPlayerHistory(id)
	if not history then return nil, nil, nil, nil, nil, false, 0 end

	HistoryManager.ForEachRecordNewestFirst(history, YAW_HISTORY_SIZE, function(_, playerData)
		local ang     = playerData[HistoryManager.Fields.Angles]
		local simTime = playerData[HistoryManager.Fields.SimulationTime]

		if ang and simTime then
			local yaw = ang.yaw or ang[2]
			if yaw then
				recordCount = recordCount + 1
				frameYaws[recordCount] = yaw

				if lastRecord then
					local d          = yawDelta(yaw, lastRecord.yaw)
					local absDelta   = math.abs(d)
					local timeDiff   = math.abs(simTime - lastRecord.simTime)
					local chokeTicks = math.floor(timeDiff / tickInterval + 0.5)

					if absDelta > maxYawDelta then maxYawDelta = absDelta end
					sumYawDelta   = sumYawDelta + absDelta
					sumChokeTicks = sumChokeTicks + chokeTicks

					if absDelta >= YAW_FLIP_THRESHOLD then
						local sign = d > 0 and 1 or -1
						if lastDeltaSign ~= 0 and sign ~= lastDeltaSign then
							flipCount = flipCount + 1
						end
						lastDeltaSign = sign
					end

					collected = collected + 1
					frameDeltas[collected] = absDelta
				end
				lastRecord = { yaw = yaw, simTime = simTime }
			end
		end
	end)

	if collected == 0 then return nil, nil, nil, nil, nil, false, 0 end

	local avgYawDelta   = sumYawDelta / collected
	local avgChokeTicks = sumChokeTicks / collected
	local cooldownTime  = yawEvidenceCooldownById[id] or 0

	-- A→B→A repeat check (RijiN angle_repeat):
	-- frameYaws[1]=newest. Pattern: yaw[k] ≈ yaw[k+2] but |yaw[k+1]-yaw[k]| >= threshold.
	-- No choke requirement — real desync AA fires every single tick.
	if recordCount >= 3 then
		for k = 1, recordCount - 2 do
			local cur         = frameYaws[k]
			local mid         = frameYaws[k + 1]
			local prev        = frameYaws[k + 2]
			local curPrevDiff = math.abs(yawDelta(cur, prev))
			local midCurDiff  = math.abs(yawDelta(mid, cur))
			if curPrevDiff <= YAW_REPEAT_EPSILON and midCurDiff >= YAW_REPEAT_MIN_DEG then
				repeatCount = repeatCount + 1
			end
		end
	end

	-- Noise-bracket: snap is software-forced when both neighbours are quiet (< 0.5deg).
	local snapBracketed = false
	if maxYawDelta >= YAW_MAX_DELTA_THRESHOLD and collected >= 3 then
		local snapIdx = 1
		for k = 2, collected do
			if frameDeltas[k] > frameDeltas[snapIdx] then snapIdx = k end
		end
		local prevDelta = snapIdx > 1 and frameDeltas[snapIdx - 1] or nil
		local nextDelta = snapIdx < collected and frameDeltas[snapIdx + 1] or nil
		snapBracketed = (prevDelta == nil or prevDelta < NOISE_BRACKET_MAX_DEG)
			and (nextDelta == nil or nextDelta < NOISE_BRACKET_MAX_DEG)
	end

	return avgYawDelta, avgChokeTicks, maxYawDelta, flipCount, cooldownTime, snapBracketed, repeatCount
end

-- Returns true when our own connection is too unstable to attribute gaps to the target
local function ourConnectionUnstable()
	local netchan = clientstate.GetNetChannel()
	if not netchan then return false end
	local loss  = netchan:GetAvgLoss(FLOW_INCOMING)
	local choke = netchan:GetAvgChoke(FLOW_OUTGOING)
	return (loss and loss > OUR_MAX_LOSS_SKIP) or (choke and choke > OUR_MAX_CHOKE_SKIP)
end

-- ── main entry ─────────────────────────────────────────────────────────────
function AntiAim.ProcessPlayer(playerState, cmd)
	if not playerState or not playerState.pdata or not playerState.id then return end
	if not Common.IsPlayerConnected() then return end
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.AntiAim) then return end

	local isDebug = Common.IsLogCategoryEnabled("AntiAim")
	local pdata   = playerState.pdata
	local simTime = pdata.simTime
	local isAlive = pdata.isAlive
	local isDorm  = pdata.isDormant

	if simTime == nil or isAlive == nil or isDorm == nil then return end
	if not isAlive or isDorm then return end
	if not simTime or simTime <= 0 then return end

	local localPlayer = entities.GetLocalPlayer()
	local isLocalPlayer = playerState.id == tostring(Common.GetSteamID64(localPlayer))
	-- Skip friends and local player unless global debug mode is enabled
	if not Common.IsDebugEnabled() then
		if playerState.isFriend or isLocalPlayer then return end
	end

	local isCheater = (playerState.flags & Constants.Flags.CHEATER) ~= 0
	if isCheater then return end

	local pitchState = getPitchState(playerState.id)

	-- Get entity safely
	local ent = PlayerData.GetEntity(pdata)
	if not ent then return end

	local pitch, yaw, angleSource = readNetAngles(ent, cmd, isDebug and isLocalPlayer)
	if pitch == nil and yaw == nil then return end -- spectator / observer slot, no angles available
	local now = globals.RealTime()
	applyPitchDecay(pitchState, now)
	if isDebug then
		local pitchStr = "nil"
		local yawStr = "nil"
		if pitch ~= nil then
			pitchStr = string.format("%.3f", pitch)
		end
		if yaw ~= nil then
			yawStr = string.format("%.3f", yaw)
		end
		print(string.format("[AntiAim][TICK] id=%s pitch=%s yaw=%s src=%s sim=%.3f",
			tostring(playerState.id), pitchStr, yawStr, tostring(angleSource), simTime))
	end

	-- ── 1. Invalid pitch detection ────────────────────────────────────────
	-- Checked every tick regardless of simTime so choking AA players still
	-- accumulate score. No cooldown - every invalid pitch tick adds weight.
	if pitch ~= nil and isInvalidPitch(pitch) and not isCorrupted(pitch) then
		pitchState.score = pitchState.score + HIT_WEIGHT
		pitchState.lastHitTime = now

		if isDebug then
			local yawStr = "nil"
			if yaw ~= nil then yawStr = string.format("%.3f", yaw) end
			print(string.format("[AntiAim][HIT] invalid pitch=%.3f yaw=%s src=%s score=%.2f/%.2f",
				pitch, yawStr, tostring(angleSource), pitchState.score, SCORE_THRESHOLD))
		end

		if pitchState.score >= SCORE_THRESHOLD then
			local reason = string.format("Invalid Pitch sustained (%.3f)", pitch)
			DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER, reason)
			antiAimStateById[playerState.id] = nil
			yawEvidenceCooldownById[playerState.id] = nil
			return
		end
	end

	-- ── 2. Yaw-delta history detection (using HistoryManager) ────────────
	-- Skip entirely when our own connection is jittery — simtime gaps would
	-- be indistinguishable from the target choking.
	if ourConnectionUnstable() then return end

	-- HistoryManager stores angles per-tick - we analyse last 16 records
	local avgYawDelta, avgChokeTicks, maxYawDelta, flipCount, lastCooldown, snapBracketed, repeatCount =
		analyseYawHistoryFromManager(playerState.id)
	if avgYawDelta ~= nil then
		-- Guard: if avg choke gap is too large the player was dormant/untracked — skip.
		if avgChokeTicks > CHOKE_MAX_SANE_TICKS then
			return
		end

		-- repeatTriggered: A→B→A angle pattern (RijiN angle_repeat) — primary desync AA signal.
		-- Real yaw AA chokes 0 extra ticks; yaw just alternates every tick. No choke gate needed.
		local repeatTriggered = repeatCount >= 2

		-- avgTriggered: secondary signal for badly-implemented AA that also chokes packets.
		-- Requires BOTH elevated choke AND large avg delta to fire.
		local avgTriggered = avgChokeTicks >= CHOKE_TICK_THRESHOLD
			and avgYawDelta >= YAW_DELTA_THRESHOLD

		-- maxTriggered: single large snap surrounded by quiet frames (StAC aimsnapCheck logic).
		-- Requires snapBracketed — both neighbours < 0.5deg — to reject mouse flicks.
		local maxTriggered = maxYawDelta >= YAW_MAX_DELTA_THRESHOLD
			and avgChokeTicks >= 1 and snapBracketed

		-- flipTriggered: alternating large flips (>= 120deg) while choking AND snap-bracketed.
		local flipTriggered = flipCount >= 3 and avgChokeTicks >= 1 and snapBracketed

		local triggered = repeatTriggered or avgTriggered or maxTriggered or flipTriggered

		if triggered then
			local now = globals.RealTime()
			if (now - lastCooldown) >= YAW_EVIDENCE_COOLDOWN then
				yawEvidenceCooldownById[playerState.id] = now

				-- Scale weight by signal strength.
				local weight = YAW_EVIDENCE_WEIGHT
				if repeatTriggered then
					weight = weight * 1.5 -- strongest signal: confirmed A→B→A pattern
				elseif maxTriggered and maxYawDelta >= 120.0 then
					weight = weight * 1.3
				elseif flipTriggered then
					weight = weight * 1.2
				end
				Evidence.AddEvidence(playerState.id, "anti_aim", weight)

				-- Hard flag for sustained yaw AA (similar to pitch)
				if repeatTriggered or (maxTriggered and maxYawDelta >= 120.0 and repeatCount >= 1) or flipTriggered then
					local reason = string.format("Yaw AA detected (%s)",
						repeatTriggered and "repeat" or (flipTriggered and "flip" or "snap"))
					DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER, reason)
					yawEvidenceCooldownById[playerState.id] = nil -- Reset cooldown after flag
				end

				local trigReason = ""
				if repeatTriggered then
					trigReason = string.format("repeat=%d ", repeatCount)
				elseif maxTriggered then
					trigReason = string.format("max=%.1fdeg ", maxYawDelta)
				elseif flipTriggered then
					trigReason = string.format("flips=%d ", flipCount)
				end
				print(string.format("[AntiAim] yaw AA on %s | %savg=%.1fdeg choke=%.1f repeats=%d w=%.1f",
					playerState.id, trigReason, avgYawDelta, avgChokeTicks, repeatCount, weight))
			end
		end

		if isDebug then
			traceLog(playerState, string.format(
				"yaw history avg=%.1fdeg max=%.1fdeg choke=%.1f flips=%d repeats=%d bracketed=%s triggered=%s",
				avgYawDelta, maxYawDelta or 0, avgChokeTicks, flipCount or 0, repeatCount,
				tostring(snapBracketed), tostring(triggered)
			))
		end
	end
end

-- ── cleanup ────────────────────────────────────────────────────────────────
Events.Subscribe("OnPlayerDisconnect", function(id)
	antiAimStateById[id]        = nil
	yawEvidenceCooldownById[id] = nil
end)
Events.Subscribe("OnPlayerRemoved", function(id)
	antiAimStateById[id]        = nil
	yawEvidenceCooldownById[id] = nil
end)

return AntiAim
