--[[ detectors/antiaim.lua
     Detects rage anti-aim via two complementary methods:

     1. Invalid Pitch  – networked eye pitch outside ±89.3° (classic AA tell).
        Accumulates a weighted hit score with decay; crossing SCORE_THRESHOLD
        hard-flags the player as CHEATER.

     2. Yaw-Delta History (Rijin-derived) – per-player circular buffer of
        {pitch, yaw, simTime} records.  Each tick we compute:
          • avg_yaw_delta  : mean absolute yaw change between consecutive records
          • avg_choke_ticks: mean simulation-time gap in ticks between records
        Threshold: avg_choke_ticks >= 2 OR avg_yaw_delta >= 25° triggers yaw-AA
        evidence.  This fires Evidence.AddEvidence so it decays naturally and
        stacks with other signals rather than immediately hard-flagging.
]]

local Constants = require("Cheater_Detection.Core.constants")
local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Events = require("Cheater_Detection.Core.Events")
local G = require("Cheater_Detection.Utils.Globals")
local PlayerData = require("Cheater_Detection.Utils.PlayerData")

local AntiAim = {}

-- ── constants ──────────────────────────────────────────────────────────────
local MAX_LEGAL_PITCH        = 89.30
local MAX_SANE_ABS_ANGLE     = 540
local DETECTION_COOLDOWN_SEC = 1.0
local HIT_WEIGHT             = 1.0
local SCORE_DECAY_PER_SEC    = 0.67
local SCORE_THRESHOLD        = 10.0

-- Yaw-history buffer settings (mirrors Rijin: analyse last N records)
local YAW_HISTORY_SIZE       = 16   -- records kept per player
local YAW_DELTA_THRESHOLD    = 25.0 -- degrees avg delta = yaw AA signal
local CHOKE_TICK_THRESHOLD   = 2    -- ticks avg simtime gap = choke signal
local YAW_EVIDENCE_WEIGHT    = 8.0  -- evidence weight per positive detection
local YAW_EVIDENCE_COOLDOWN  = 3.0  -- seconds between evidence additions

-- ── per-player state ───────────────────────────────────────────────────────
local antiAimStateById = {}     -- pitch-score state
local lastInvalidPitchLogAt = {}
local yawHistoryById = {}       -- circular angle buffers

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

local function traceLog(isDebug, playerState, detail)
	if not isDebug then return end
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
		local decayed = (state.score or 0) - SCORE_DECAY_PER_SEC * elapsed
		state.score = mathMax(0, decayed)
		state.lastDecayTime = now
	end
end

-- ── networked-angle reading ────────────────────────────────────────────────
local function readNetAngles(entity, cmd, isLocalDebug)
	if not entity then return nil, nil, "nil" end
	local candidates = {}

	local function add(src, pitch, yaw)
		local p, y = toNum(pitch), toNum(yaw)
		if p == nil or isCorrupted(p) then return end
		if y ~= nil and isCorrupted(y) then return end
		candidates[#candidates + 1] = { source = src, pitch = p, yaw = y }
	end

	if isLocalDebug and cmd then
		local ok, a, b = pcall(function() return cmd:GetViewAngles() end)
		if ok then
			if type(a) == "number" then add("cmd", a, b)
			else add("cmd", tryExtractPitchYaw(a)) end
		end
		local ok2, va = pcall(function() return cmd.viewangles end)
		if ok2 then add("cmd.viewangles", tryExtractPitchYaw(va)) end
	end

	add("raw-prop",    entity:GetPropFloat("m_angEyeAngles[0]"),
	                   entity:GetPropFloat("m_angEyeAngles[1]"))

	local nv = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
	if nv then add("tfnonlocaldata", nv.x, nv.y) end

	nv = entity:GetPropVector("m_angEyeAngles[0]")
	if nv then add("propvector", nv.x, nv.y) end

	for i = 1, #candidates do
		local c = candidates[i]
		if isInvalidPitch(c.pitch) then
			return c.pitch, c.yaw, c.source
		end
	end

	if #candidates == 0 then return nil, nil, "nil" end

	local pref = isLocalDebug and "cmd" or "raw-prop"
	for i = 1, #candidates do
		if candidates[i].source == pref then
			return candidates[i].pitch, candidates[i].yaw, candidates[i].source
		end
	end

	return candidates[1].pitch, candidates[1].yaw, candidates[1].source
end

-- ── yaw-history helpers (Rijin-derived) ───────────────────────────────────
local function normalizeAngle(a)
	local wrapped = a % 360
	if wrapped > 180 then wrapped = wrapped - 360 end
	return wrapped
end

local function getYawHistory(id)
	local h = yawHistoryById[id]
	if not h then
		h = { records = {}, head = 0, count = 0, lastEvidenceTime = 0 }
		yawHistoryById[id] = h
	end
	return h
end

local function pushYawRecord(h, pitch, yaw, simTime)
	local cap = YAW_HISTORY_SIZE
	h.head = (h.head % cap) + 1
	h.records[h.head] = { pitch = pitch, yaw = yaw, simTime = simTime }
	if h.count < cap then h.count = h.count + 1 end
end

-- Returns avg_yaw_delta, avg_choke_ticks (or nil if insufficient data)
local function analyseYawHistory(h)
	if h.count < 3 then return nil, nil end

	local tickInterval = globals.TickInterval()
	local collected = 0
	local sumYawDelta = 0.0
	local sumChokeTicks = 0

	local cap = YAW_HISTORY_SIZE
	-- Walk pairs: newest = head, going backwards
	for i = 0, h.count - 2 do
		local idxA = (h.head - i - 1) % cap + 1
		local idxB = (h.head - i - 2) % cap + 1
		local rA = h.records[idxA]
		local rB = h.records[idxB]
		if rA and rB and rA.simTime and rB.simTime then
			local yawDiff = normalizeAngle(rA.yaw) - normalizeAngle(rB.yaw)
			local yawDelta = math.abs(yawDiff)
			local rawTimeDiff = rA.simTime - rB.simTime
			local timeDiff = math.abs(rawTimeDiff)
			local chokeTicks = math.floor(timeDiff / tickInterval + 0.5)
			sumYawDelta   = sumYawDelta + yawDelta
			sumChokeTicks = sumChokeTicks + chokeTicks
			collected = collected + 1
		end
	end

	if collected == 0 then return nil, nil end

	local avgYawDelta = sumYawDelta / collected
	local avgChokeTicks = sumChokeTicks / collected

	-- Normalise yaw delta by choke ticks (per Rijin: divide out bunched updates)
	if avgChokeTicks > 1 then
		avgYawDelta = avgYawDelta / avgChokeTicks
	end

	return avgYawDelta, avgChokeTicks
end

-- ── main entry ─────────────────────────────────────────────────────────────
function AntiAim.ProcessPlayer(playerState, cmd)
	if not playerState or not playerState.pdata or not playerState.id then return end
	if not Common.IsPlayerConnected() then return end
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.AntiAim) then return end

	local isDebug = Common.IsDebugEnabled()
	local pdata   = playerState.pdata
	local simTime = pdata.simTime
	local isAlive = pdata.isAlive
	local isDorm  = pdata.isDormant

	if simTime == nil or isAlive == nil or isDorm == nil then return end
	if not isAlive or isDorm then return end
	if not simTime or simTime <= 0 then return end

	local localPlayer = entities.GetLocalPlayer()
	local isLocalPlayer = playerState.id == tostring(Common.GetSteamID64(localPlayer))
	if not isDebug then
		if playerState.isFriend or isLocalPlayer then return end
	end

	local isCheater = (playerState.flags & Constants.Flags.CHEATER) ~= 0
	if isCheater then return end

	-- Guard against re-processing the same simulation snapshot
	local pitchState = getPitchState(playerState.id)
	if pitchState.lastSimTime ~= nil and simTime <= pitchState.lastSimTime then return end
	pitchState.lastSimTime = simTime

	-- Get entity safely
	local ent = PlayerData.GetEntity(pdata)
	if not ent then return end

	local pitch, yaw, angleSource = readNetAngles(ent, cmd, isDebug and isLocalPlayer)
	local now = globals.RealTime()
	applyPitchDecay(pitchState, now)

	-- ── 1. Invalid pitch detection ────────────────────────────────────────
	if pitch ~= nil and isInvalidPitch(pitch) and not isCorrupted(pitch) then
		ent = PlayerData.GetEntity(pdata)
		if ent and ent:IsValid() and not ent:IsDormant() and ent:IsAlive() then
			if (now - (pitchState.lastHitTime or 0)) >= DETECTION_COOLDOWN_SEC then
				pitchState.score = pitchState.score + HIT_WEIGHT
				pitchState.lastHitTime = now
			end

			if isDebug then
				local lastLog = lastInvalidPitchLogAt[playerState.id] or 0
				local logElapsed = now - lastLog
				if logElapsed >= 10.0 then
					lastInvalidPitchLogAt[playerState.id] = now
					local yawStr = "nil"
					if yaw ~= nil then
						yawStr = string.format("%.3f", yaw)
					end
					traceLog(true, playerState, string.format(
						"invalid pitch pitch=%.3f yaw=%s src=%s score=%.2f/%.2f",
						pitch, yawStr, tostring(angleSource), pitchState.score, SCORE_THRESHOLD))
				end
			end

			if pitchState.score >= SCORE_THRESHOLD then
				local reason = string.format("Invalid Pitch sustained (%.3f)", pitch)
				DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER, reason)
				antiAimStateById[playerState.id] = nil
				yawHistoryById[playerState.id]   = nil
				return
			end
		end
	end

	-- ── 2. Yaw-delta history detection (Rijin-derived) ────────────────────
	if pitch ~= nil and yaw ~= nil and not isCorrupted(pitch) and not isCorrupted(yaw) then
		local h = getYawHistory(playerState.id)
		pushYawRecord(h, pitch, yaw, simTime)

		local avgYawDelta, avgChokeTicks = analyseYawHistory(h)
		if avgYawDelta ~= nil then
			local triggered = avgChokeTicks >= CHOKE_TICK_THRESHOLD or avgYawDelta >= YAW_DELTA_THRESHOLD

			if triggered then
				if (now - h.lastEvidenceTime) >= YAW_EVIDENCE_COOLDOWN then
					h.lastEvidenceTime = now
					Evidence.AddEvidence(playerState.id, "anti_aim", YAW_EVIDENCE_WEIGHT)

					if isDebug then
						traceLog(true, playerState, string.format(
							"yaw AA detected avgDelta=%.1f° avgChoke=%.1f ticks",
							avgYawDelta, avgChokeTicks
						))
					end
				end
			end
		end
	end
end

-- ── cleanup ────────────────────────────────────────────────────────────────
Events.Subscribe("OnPlayerDisconnect", function(id)
	antiAimStateById[id]     = nil
	yawHistoryById[id]       = nil
	lastInvalidPitchLogAt[id] = nil
end)
Events.Subscribe("OnPlayerRemoved", function(id)
	antiAimStateById[id]     = nil
	yawHistoryById[id]       = nil
	lastInvalidPitchLogAt[id] = nil
end)

return AntiAim
