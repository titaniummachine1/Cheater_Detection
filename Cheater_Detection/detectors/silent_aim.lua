--[[ detectors/silent_aim.lua
     Silent Aimbot Detector — 2-tick view-angle extrapolation.

     Algorithm:
       Per-player angle history is collected at FRAME_NET_UPDATE_POSTDATAUPDATE_END
       (stage 3) — this is raw server data before client-side interpolation is applied.

       When player_hurt fires for attacker A at game tick T:
         1. Record the actual angle at T (the snap-to-target angle).
         2. Take the last 2 pre-shot history entries (T-2, T-1) and extrapolate:
              predicted_T   = T-1 angle + 1-tick velocity
              predicted_T+1 = T-1 angle + 2-tick velocity
         3. One tick later (T+1), at stage 3, read the actual angle and check:
              shot_dev      = angular distance(actual_T,   predicted_T)
              return_dev    = angular distance(actual_T+1, predicted_T+1)
              alignment     = max(0, 1 - return_dev / shot_dev)
              score_gain    = shot_dev ^ (1 + alignment * WEIGHT_EXPONENT)

       Interpretation: if the player snapped far at T (large shot_dev) AND the
       angle at T+1 is back on the natural trajectory (large alignment), they
       triggered an aimbot. Score is accumulated exponentially — small snaps need
       strong alignment; large snaps score heavily even with partial alignment.

       Score is applied in ProcessPlayer (CreateMove) after stage 3 writes it.
]]

local Events = require("Cheater_Detection.Core.Events")
local Constants = require("Cheater_Detection.Core.constants")
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")

local SilentAim = {}

-- ── Tuning ────────────────────────────────────────────────────────────────────
local HISTORY_MAX = 4        -- Pre-shot ticks to retain
local MIN_SNAP_DEGREES = 8.0 -- Smaller snaps are ignored (noise floor)
local WEIGHT_EXPONENT = 1.8
-- score = shot_dev ^ (1 + alignment * WEIGHT_EXPONENT)
-- alignment=0 → shot_dev^1.0  (linear, weak — no confirmed snap-back)
-- alignment=1 → shot_dev^2.8  (exponential — perfect snap-back confirmed)

-- ── State ─────────────────────────────────────────────────────────────────────
-- Single per-player table keyed by steamID64 string.
-- Fields:
--   entity      - raw entity (populated by ProcessPlayer, read by FrameStageNotify)
--   angleHistory - array of { pitch, yaw, tick }  (max HISTORY_MAX entries)
--   shotPending  - { shotTick, actualShotPitch, actualShotYaw, predShotPitch, predShotYaw,
--                    predNextPitch, predNextYaw } or nil
--   pendingScore - accumulated score gain (written by stage-3, consumed by ProcessPlayer)
--   pendingAngle - largest snap angle for the pending score
--   killDecay    - accumulated score to subtract on the next ProcessPlayer call
local playerData = {}

-- ── Angle Math ────────────────────────────────────────────────────────────────
local function wrapAngle(d)
	return (d + 180) % 360 - 180
end

local function angularDist(p1, y1, p2, y2)
	local dp = math.abs(wrapAngle(p2 - p1))
	local dy = math.abs(wrapAngle(y2 - y1))
	return math.sqrt(dp * dp + dy * dy)
end

-- ── Frame Stage Handler ───────────────────────────────────────────────────────
-- FRAME_NET_UPDATE_POSTDATAUPDATE_END = 3
-- Entity netprops have just been updated from the incoming server packet.
-- We read m_angEyeAngles here before the engine interpolates them.

local STAGE_POST_DATA_END = 3

local function processOnePlayer(id, ply, curTick, isDebug)
	if not ply:IsValid() or ply:IsDormant() then
		playerData[id] = nil
		return
	end

	-- Read raw server angle.  Local player uses engine.GetViewAngles() to avoid
	-- the DataTable "Out-of-range" warning that reading m_angEyeAngles triggers.
	local pitch, yaw
	local localPlayer = entities.GetLocalPlayer()
	local isLocal = localPlayer and (ply:GetIndex() == localPlayer:GetIndex())
	if isLocal then
		local va = engine.GetViewAngles()
		if not va then
			return
		end
		pitch = va.pitch
		yaw = va.yaw
	else
		pitch = ply:GetPropFloat("m_angEyeAngles[0]")
		yaw = ply:GetPropFloat("m_angEyeAngles[1]")
		if not pitch or not yaw then
			return
		end
	end

	local pdata = playerData[id]
	if not pdata then
		return
	end

	-- Push to history (only once per game tick)
	local hist = pdata.angleHistory
	if #hist == 0 or hist[#hist].tick ~= curTick then
		hist[#hist + 1] = { pitch = pitch, yaw = yaw, tick = curTick }
		if #hist > HISTORY_MAX then
			table.remove(hist, 1)
		end
	end

	-- Verify any pending shot for this player
	local pending = pdata.shotPending
	if not pending then
		return
	end
	if curTick < pending.shotTick + 1 then
		return
	end

	pdata.shotPending = nil

	local shotDev =
		angularDist(pending.actualShotPitch, pending.actualShotYaw, pending.predShotPitch, pending.predShotYaw)

	if not (shotDev == shotDev) or shotDev == math.huge or shotDev < MIN_SNAP_DEGREES then
		return
	end

	local returnDev = angularDist(pitch, yaw, pending.predNextPitch, pending.predNextYaw)
	if not (returnDev == returnDev) or returnDev == math.huge then
		return
	end

	-- alignment: 1 = T+1 angle returned perfectly to predicted path (strong confirm)
	--            0 = T+1 angle is as far away as the shot itself (noise / natural move)
	local alignmentFactor = math.max(0.0, 1.0 - returnDev / math.max(shotDev, 1.0))
	local scoreGain = shotDev ^ (1.0 + alignmentFactor * WEIGHT_EXPONENT)

	if isDebug then
		print(
			string.format(
				"[SilentAim] %s  snap=%.1f°  return=%.1f°  align=%.2f  gain=%.1f",
				id,
				shotDev,
				returnDev,
				alignmentFactor,
				scoreGain
			)
		)
	end

	-- Accumulate for ProcessPlayer to consume
	pdata.pendingScore = (pdata.pendingScore or 0) + scoreGain
	pdata.pendingAngle = math.max(pdata.pendingAngle or 0, shotDev)
end

local function onFrameStage(stage)
	if stage ~= STAGE_POST_DATA_END then
		return
	end

	-- Menu gate — cheapest check first
	if not (G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.SilentAimbot) then
		return
	end

	local curTick = globals.TickCount()
	local isDebug = Common.IsDebugEnabled()

	for id, pdata in pairs(playerData) do
		if pdata.entity then
			processOnePlayer(id, pdata.entity, curTick, isDebug)
		end
	end
end

callbacks.Unregister("FrameStageNotify", "CD_SilentAim_FSN")
callbacks.Register("FrameStageNotify", "CD_SilentAim_FSN", onFrameStage)

-- ── Damage Event ──────────────────────────────────────────────────────────────
local function onDamageEvent(event)
	local eventName = event:GetName()
	if eventName ~= "player_hurt" and eventName ~= "player_death" then
		return
	end

	local attackerUID = event:GetInt("attacker")
	if not attackerUID then
		return
	end

	local ply = entities.GetByUserID(attackerUID)
	if not ply then
		return
	end

	local localPlayer = entities.GetLocalPlayer()
	if localPlayer and (localPlayer:GetIndex() == ply:GetIndex()) and not Common.IsDebugEnabled() then
		return
	end

	local steamID64 = Common.GetSteamID64(ply)
	if not steamID64 then
		return
	end

	local id = tostring(steamID64)
	local pdata = playerData[id]
	if not pdata then
		return
	end

	-- Kill decay: every kill reduces accumulated aimbot suspicion by 5.
	-- Applied before analysing the killing shot so legitimate aimers get credit.
	if eventName == "player_death" then
		pdata.killDecay = (pdata.killDecay or 0) + 5
	end

	local hist = pdata.angleHistory

	-- Need at minimum 3 entries: T-2, T-1, T (T is the shot tick)
	if not hist or #hist < 3 then
		return
	end

	-- The last entry is the shot-tick angle.
	-- Pre-shot history = all but the last entry.
	local shotTick = hist[#hist].tick
	local actualShotPitch = hist[#hist].pitch
	local actualShotYaw = hist[#hist].yaw

	-- Build pre-shot history (exclude shot tick)
	-- We need at least 2 entries for extrapolate1.
	local preN = #hist - 1
	if preN < 2 then
		return
	end

	-- Use the last 2 pre-shot entries for velocity
	local prePrev = hist[preN - 1]
	local preCurr = hist[preN]

	-- Extrapolate predicted angle at shot tick T
	local dtTicks = preCurr.tick - prePrev.tick
	if dtTicks <= 0 then
		dtTicks = 1
	end
	local vPitch = wrapAngle(preCurr.pitch - prePrev.pitch) / dtTicks
	local vYaw = wrapAngle(preCurr.yaw - prePrev.yaw) / dtTicks

	local predShotPitch = preCurr.pitch + vPitch
	local predShotYaw = preCurr.yaw + vYaw

	-- Extrapolate predicted angle at T+1 (one more step)
	local predNextPitch = predShotPitch + vPitch
	local predNextYaw = predShotYaw + vYaw

	-- Only register if no pending shot already queued for a later tick
	local existing = pdata.shotPending
	if not existing or existing.shotTick < shotTick then
		pdata.shotPending = {
			shotTick = shotTick,
			actualShotPitch = actualShotPitch,
			actualShotYaw = actualShotYaw,
			predShotPitch = predShotPitch,
			predShotYaw = predShotYaw,
			predNextPitch = predNextPitch,
			predNextYaw = predNextYaw,
		}
	end
end

Events.Register("FireGameEvent", "CD_SilentAim_Event", onDamageEvent, "*")

-- ── ProcessPlayer (called from Main.lua / CreateMove) ─────────────────────────
function SilentAim.ProcessPlayer(playerState)
	if not playerState or not playerState.wrap or not playerState.id then
		return
	end

	-- Menu gate: cheapest first
	if not (G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.SilentAimbot) then
		return
	end

	local id = playerState.id
	local ply = playerState.wrap:GetRawEntity()
	if not ply or not ply:IsValid() then
		return
	end

	-- Ensure per-player data table exists and register entity for FrameStageNotify
	if not playerData[id] then
		playerData[id] = {
			entity       = ply,
			angleHistory = {},
			shotPending  = nil,
			pendingScore = 0,
			pendingAngle = 0,
			killDecay    = 0,
		}
	else
		playerData[id].entity = ply
	end
	local pdata = playerData[id]

	-- Apply kill-based score decay accumulated between ProcessPlayer calls
	local decay = pdata.killDecay
	if decay and decay > 0 then
		playerState.score = math.max(0, playerState.score - decay)
		pdata.killDecay = 0
	end

	-- Consume any score that stage-3 prepared
	local gain = pdata.pendingScore
	if not gain or gain <= 0 then
		return
	end

	local snapAngle = pdata.pendingAngle or gain
	pdata.pendingScore = 0
	pdata.pendingAngle = 0

	local reason = string.format("SilentAim Spike (%.1f°)", snapAngle)
	local wasSuspicious = (playerState.flags & Constants.Flags.SUSPICIOUS) ~= 0

	local flagsChanged = DetectorUtils.ApplyPlayerFlag(playerState, gain, nil, reason)

	-- Dedicated event: first time this player crosses the SUSPICIOUS threshold
	-- via aimbot detection.  Lets the real-time analyser and other modules react
	-- without having to filter through generic OnPlayerStateChange.
	if flagsChanged and not wasSuspicious and (playerState.flags & Constants.Flags.SUSPICIOUS) ~= 0 then
		Events.Publish("OnAimbotSuspect", playerState, reason)
	end
end

-- ── Cleanup ───────────────────────────────────────────────────────────────────
Events.Subscribe("OnPlayerDisconnect", function(id)
	playerData[id] = nil
end)

return SilentAim
