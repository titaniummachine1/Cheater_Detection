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

local EventBus = require("Cheater_Detection.core.event_bus")
local Constants = require("Cheater_Detection.core.constants")
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local EventManager = require("Cheater_Detection.Utils.EventManager")

local SilentAim = {}

-- ── Tuning ────────────────────────────────────────────────────────────────────
local HISTORY_MAX = 4 -- Pre-shot ticks to retain
local MIN_SNAP_DEGREES = 8.0 -- Smaller snaps are ignored (noise floor)
local WEIGHT_EXPONENT = 1.8
-- score = shot_dev ^ (1 + alignment * WEIGHT_EXPONENT)
-- alignment=0 → shot_dev^1.0  (linear, weak — no confirmed snap-back)
-- alignment=1 → shot_dev^2.8  (exponential — perfect snap-back confirmed)

-- ── State ─────────────────────────────────────────────────────────────────────
-- Keyed by steamID64 string throughout.  No entity-index aliasing.

-- steamID64 -> entity  (populated by ProcessPlayer, iterated by FrameStageNotify)
local trackedEntities = {}

-- steamID64 -> array of { pitch, yaw, tick }  (max HISTORY_MAX entries)
local angleHistory = {}

-- steamID64 -> { shotTick, actualShotPitch, actualShotYaw,
--                predShotPitch, predShotYaw,
--                predNextPitch, predNextYaw }
local shotPending = {}

-- steamID64 -> { gain, angle }  (written by stage-3, consumed by ProcessPlayer)
local pendingScores = {}
local pendingAngles = {}

-- steamID64 -> accumulated score to subtract on the next ProcessPlayer call
-- populated when the attacker kills someone (kill decay)
local killDecays = {}

-- ── Angle Math ────────────────────────────────────────────────────────────────
local function wrapAngle(d)
	return (d + 180) % 360 - 180
end

local function angularDist(p1, y1, p2, y2)
	local dp = math.abs(wrapAngle(p2 - p1))
	local dy = math.abs(wrapAngle(y2 - y1))
	return math.sqrt(dp * dp + dy * dy)
end

-- Extrapolate 1 tick forward from the last 2 entries in hist.
local function extrapolate1(hist)
	local n = #hist
	assert(n >= 2, "extrapolate1: need >= 2 history entries")
	local prev = hist[n - 1]
	local curr = hist[n]
	local dtTicks = curr.tick - prev.tick
	if dtTicks <= 0 then
		dtTicks = 1
	end
	local vPitch = wrapAngle(curr.pitch - prev.pitch) / dtTicks
	local vYaw = wrapAngle(curr.yaw - prev.yaw) / dtTicks
	return curr.pitch + vPitch, curr.yaw + vYaw
end

-- ── Frame Stage Handler ───────────────────────────────────────────────────────
-- FRAME_NET_UPDATE_POSTDATAUPDATE_END = 3
-- Entity netprops have just been updated from the incoming server packet.
-- We read m_angEyeAngles here before the engine interpolates them.

local STAGE_POST_DATA_END = 3

local function processOnePlayer(id, ply, curTick, isDebug)
	if not ply:IsValid() or ply:IsDormant() then
		trackedEntities[id] = nil
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

	-- Push to history (only once per game tick)
	if not angleHistory[id] then
		angleHistory[id] = {}
	end
	local hist = angleHistory[id]
	if #hist == 0 or hist[#hist].tick ~= curTick then
		hist[#hist + 1] = { pitch = pitch, yaw = yaw, tick = curTick }
		if #hist > HISTORY_MAX then
			table.remove(hist, 1)
		end
	end

	-- Verify any pending shot for this player
	local pending = shotPending[id]
	if not pending then
		return
	end
	if curTick < pending.shotTick + 1 then
		return
	end

	shotPending[id] = nil

	local shotDev =
		angularDist(pending.actualShotPitch, pending.actualShotYaw, pending.predShotPitch, pending.predShotYaw)

	if shotDev < MIN_SNAP_DEGREES then
		return
	end

	local returnDev = angularDist(pitch, yaw, pending.predNextPitch, pending.predNextYaw)

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

	-- Store for ProcessPlayer to consume (no table allocation — two scalar keys)
	pendingScores[id] = (pendingScores[id] or 0) + scoreGain
	pendingAngles[id] = math.max(pendingAngles[id] or 0, shotDev)
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
	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true

	for id, ply in pairs(trackedEntities) do
		processOnePlayer(id, ply, curTick, isDebug)
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
	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	if localPlayer and (localPlayer:GetIndex() == ply:GetIndex()) and not isDebug then
		return
	end

	local steamID64 = Common.GetSteamID64(ply)
	if not steamID64 then
		return
	end

	local id = tostring(steamID64)

	-- Kill decay: every kill reduces accumulated aimbot suspicion by 5.
	-- Applied before analysing the killing shot so legitimate aimers get credit.
	if eventName == "player_death" then
		killDecays[id] = (killDecays[id] or 0) + 5
	end

	local hist = angleHistory[id]

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
	local existing = shotPending[id]
	if not existing or existing.shotTick < shotTick then
		shotPending[id] = {
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

EventManager.Register("FireGameEvent", "CD_SilentAim_Event", onDamageEvent, "*")

-- ── ProcessPlayer (called from Main.lua / CreateMove) ─────────────────────────
function SilentAim.ProcessPlayer(playerState)
	assert(playerState, "SilentAim.ProcessPlayer: playerState missing")
	assert(playerState.wrap, "SilentAim.ProcessPlayer: wrap missing id=" .. tostring(playerState.id))
	assert(playerState.id, "SilentAim.ProcessPlayer: id missing")

	-- Menu gate: cheapest first
	if not (G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.SilentAimbot) then
		return
	end

	local id = playerState.id
	local ply = playerState.wrap:GetRawEntity()
	if not ply or not ply:IsValid() then
		return
	end

	-- Register entity so FrameStageNotify knows to track it
	trackedEntities[id] = ply

	-- Apply kill-based score decay accumulated between ProcessPlayer calls
	local decay = killDecays[id]
	if decay and decay > 0 then
		playerState.score = math.max(0, playerState.score - decay)
		killDecays[id] = nil
	end

	-- Consume any score that stage-3 prepared
	local gain = pendingScores[id]
	if not gain or gain <= 0 then
		return
	end

	local snapAngle = pendingAngles[id] or gain
	pendingScores[id] = nil
	pendingAngles[id] = nil

	local oldFlags = playerState.flags
	playerState.score = math.min(99, playerState.score + gain)

	local reason = string.format("SilentAim Spike (%.1f°)", snapAngle)

	local wasSuspicious = (oldFlags & Constants.Flags.SUSPICIOUS) ~= 0

	if playerState.score >= Constants.Threshold.SUSPICIOUS then
		playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
	end

	if playerState.score >= Constants.Threshold.HIGH_RISK then
		playerState.flags = playerState.flags | Constants.Flags.HIGH_RISK
	end

	if playerState.flags ~= oldFlags then
		Database.UpsertCheater(id, {
			name = playerState.wrap:GetName(),
			reason = reason,
			flags = playerState.flags,
			score = playerState.score,
		})
		EventBus.Publish("OnPlayerStateChange", playerState, reason)

		-- Dedicated event: first time this player crosses the SUSPICIOUS threshold
		-- via aimbot detection.  Lets the real-time analyser and other modules react
		-- without having to filter through generic OnPlayerStateChange.
		if not wasSuspicious and (playerState.flags & Constants.Flags.SUSPICIOUS) ~= 0 then
			EventBus.Publish("OnAimbotSuspect", playerState, reason)
		end
	end
end

-- ── Cleanup ───────────────────────────────────────────────────────────────────
EventBus.Subscribe("OnPlayerDisconnect", function(id)
	trackedEntities[id] = nil
	angleHistory[id] = nil
	shotPending[id] = nil
	pendingScores[id] = nil
	pendingAngles[id] = nil
	killDecays[id] = nil
end)

return SilentAim
