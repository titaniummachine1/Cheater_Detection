--[[ detectors/antiaim.lua
     Detects invalid view angles (Rage AA). 
     Triggering this marks the player as CHEATER immediately.
]]

local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local Events = require("Cheater_Detection.Core.Events")
local Common = require("Cheater_Detection.Utils.Common")

local AntiAim = {}

-- ── Yaw Jitter Detection ──────────────────────────────────────────────────────
-- Classic jitter AA (Lmaobox / rage cheats): yaw snaps ±120-180° every tick,
-- alternating between two positions so the head hitbox is never stable.
-- Detection: find 3 consecutive ticks where the yaw delta alternates sign AND
-- both deltas exceed JITTER_SNAP_DEG, then count events. N events within the
-- window → hard CHEATER flag (same tier as invalid pitch).

local yawHistories = {} -- id -> array of {yaw, tick}, capped at 3
local jitterStates = {} -- id -> {count, windowStart}

local JITTER_SNAP_DEG = 120.0 -- Min yaw delta per tick to count as a snap
local JITTER_REQUIRED = 8 -- Consecutive jitter events before flagging
local JITTER_WINDOW_TICKS = 40 -- ~0.6 s at 66 tick; resets window if exceeded

local function isInvalidPitchValue(pitch)
	if type(pitch) ~= "number" then
		return false
	end
	return pitch > 89.0 or pitch < -89.0
end

local function toNumber(v)
	if type(v) == "number" then
		return v
	end
	if type(v) == "string" then
		return tonumber(v)
	end
	return nil
end

local function tryExtractPitchYaw(angleObj)
	if angleObj == nil then
		return nil, nil
	end

	local ok, p, y, x, yy = pcall(function()
		return angleObj.pitch, angleObj.yaw, angleObj.x, angleObj.y
	end)
	if not ok then
		return nil, nil
	end

	local pitch = toNumber(p) or toNumber(x)
	local yaw = toNumber(y) or toNumber(yy)
	return pitch, yaw
end

local function tracePhase(phase, playerState, detail)
	local id = playerState and playerState.id or "nil"
	if detail ~= nil then
		print(string.format("[AntiAim] %s id=%s %s", tostring(phase), tostring(id), tostring(detail)))
		return
	end
	print(string.format("[AntiAim] %s id=%s", tostring(phase), tostring(id)))
end

local function readDetectionAngles(wrap, entity, cmd, isLocalDebug)
	assert(wrap, "readDetectionAngles: wrap missing")
	assert(entity, "readDetectionAngles: entity missing")
	local candidates = {}

	local function addCandidate(source, pitch, yaw)
		local p = toNumber(pitch)
		local y = toNumber(yaw)
		if p == nil then
			return
		end
		candidates[#candidates + 1] = {
			source = source,
			pitch = p,
			yaw = y,
		}
	end

	if isLocalDebug and cmd then
		local ok, a, b = pcall(function()
			return cmd:GetViewAngles()
		end)
		if ok then
			if type(a) == "number" then
				addCandidate("cmd", a, b)
			else
				local pitch, yaw = tryExtractPitchYaw(a)
				addCandidate("cmd", pitch, yaw)
			end
		end

		local okViewangles, viewangles = pcall(function()
			return cmd.viewangles
		end)
		if okViewangles then
			local pitch, yaw = tryExtractPitchYaw(viewangles)
			addCandidate("cmd.viewangles", pitch, yaw)
		end
	end

	local pitch = entity:GetPropFloat("m_angEyeAngles[0]")
	local yaw = entity:GetPropFloat("m_angEyeAngles[1]")
	addCandidate("raw-prop", pitch, yaw)

	local netAngles = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
	if netAngles then
		addCandidate("tfnonlocaldata", netAngles.x, netAngles.y)
	end

	netAngles = entity:GetPropVector("m_angEyeAngles[0]")
	if netAngles then
		addCandidate("propvector", netAngles.x, netAngles.y)
	end

	local fallbackAngles = wrap:GetEyeAngles()
	if fallbackAngles then
		addCandidate("fallback", fallbackAngles.pitch or fallbackAngles.x, fallbackAngles.yaw or fallbackAngles.y)
	end

	for i = 1, #candidates do
		local candidate = candidates[i]
		if isInvalidPitchValue(candidate.pitch) then
			return candidate.pitch, candidate.yaw, candidate.source, candidates
		end
	end

	if #candidates == 0 then
		return nil, nil, "nil", candidates
	end

	local preferredSource = isLocalDebug and "cmd" or "raw-prop"
	for i = 1, #candidates do
		local candidate = candidates[i]
		if candidate.source == preferredSource then
			return candidate.pitch, candidate.yaw, candidate.source, candidates
		end
	end

	local first = candidates[1]
	return first.pitch, first.yaw, first.source, candidates
end

local function formatCandidates(candidates)
	if not candidates or #candidates == 0 then
		return "sources=nil"
	end

	local parts = {}
	for i = 1, #candidates do
		local candidate = candidates[i]
		parts[#parts + 1] = string.format(
			"%s=%.3f/%s",
			candidate.source,
			candidate.pitch,
			type(candidate.yaw) == "number" and string.format("%.3f", candidate.yaw) or "nil"
		)
	end

	return table.concat(parts, " | ")
end

local function wrapAngle(d)
	return (d + 180) % 360 - 180
end

local function checkYawJitter(id, yaw, curTick)
	if not yawHistories[id] then
		yawHistories[id] = {}
	end

	local hist = yawHistories[id]

	-- Only record one entry per tick (CreateMove may fire multiple times)
	if #hist == 0 or hist[#hist].tick ~= curTick then
		hist[#hist + 1] = { yaw = yaw, tick = curTick }
		if #hist > 3 then
			table.remove(hist, 1)
		end
	end

	if #hist < 3 then
		return false
	end

	local delta1 = wrapAngle(hist[2].yaw - hist[1].yaw)
	local delta2 = wrapAngle(hist[3].yaw - hist[2].yaw)

	-- Jitter: two large swings in opposite directions back-to-back
	local isJitterTick = math.abs(delta1) >= JITTER_SNAP_DEG
		and math.abs(delta2) >= JITTER_SNAP_DEG
		and (delta1 * delta2 < 0)

	if not jitterStates[id] then
		jitterStates[id] = { count = 0, windowStart = curTick }
	end

	local js = jitterStates[id]

	if curTick - js.windowStart > JITTER_WINDOW_TICKS then
		js.count = 0
		js.windowStart = curTick
	end

	if isJitterTick then
		js.count = js.count + 1
		if js.count >= JITTER_REQUIRED then
			js.count = 0
			js.windowStart = curTick
			return true
		end
	end

	return false
end

function AntiAim.ProcessPlayer(playerState, cmd)
	assert(playerState, "AntiAim.ProcessPlayer: playerState missing")
	assert(playerState.wrap, "AntiAim.ProcessPlayer: playerState.wrap missing id=" .. tostring(playerState.id))
	assert(playerState.id, "AntiAim.ProcessPlayer: playerState.id missing")
	tracePhase(1, playerState, "enter")

	local entity = playerState.wrap:GetRawEntity()
	if not entity then
		tracePhase(2, playerState, "raw entity missing")
		return
	end
	tracePhase(2, playerState, "raw entity ok")

	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	local localPlayer = entities.GetLocalPlayer()
	local isLocalPlayer = localPlayer ~= nil and entity == localPlayer
	local skipEntity = nil
	if not isDebug then
		skipEntity = localPlayer
	end

	if not Common.IsValidPlayer(entity, false, true, skipEntity) then
		tracePhase(3, playerState, "IsValidPlayer rejected")
		return
	end
	tracePhase(3, playerState, "IsValidPlayer ok")

	local simTime = playerState.wrap:GetSimulationTime()
	if not simTime or simTime <= 0 then
		tracePhase(4, playerState, "invalid simTime")
		return
	end
	tracePhase(4, playerState, string.format("simTime=%.6f", simTime))

	local isCheater = (playerState.flags & Constants.Flags.CHEATER) ~= 0
	if isCheater and not isDebug then
		tracePhase(5, playerState, "already cheater and debug off")
		return
	end
	tracePhase(5, playerState, "cheater gate ok")

	local pitch, yaw, angleSource, candidates = readDetectionAngles(playerState.wrap, entity, cmd, isDebug and isLocalPlayer)
	if pitch == nil then
		tracePhase(6, playerState, "pitch nil")
		return
	end
	tracePhase(
		6,
		playerState,
		string.format(
			"pitch=%.3f yaw=%s source=%s all=%s",
			pitch,
			yaw ~= nil and string.format("%.3f", yaw) or "nil",
			tostring(angleSource),
			formatCandidates(candidates)
		)
	)

	local isInvalid = isInvalidPitchValue(pitch)
	tracePhase(7, playerState, string.format("isInvalid=%s", tostring(isInvalid)))

	if isInvalid then
		tracePhase(8, playerState, "invalid pitch hit")
		local oldFlags = playerState.flags
		playerState.flags = playerState.flags | Constants.Flags.CHEATER
		playerState.score = 100

		local reason = string.format("Invalid Pitch (%.2f)", pitch)

		Database.UpsertCheater(playerState.id, {
			name = playerState.wrap:GetName(),
			reason = reason,
			flags = playerState.flags,
			score = playerState.score,
		})

		if oldFlags ~= playerState.flags then
			Events.Publish("OnPlayerStateChange", playerState, reason)
		end
	end

	-- ── Yaw Jitter Check ─────────────────────────────────────────────────────
	if type(yaw) == "number" then
		local curTick = globals.TickCount()
		local hasJitter = checkYawJitter(playerState.id, yaw, curTick)
		tracePhase(9, playerState, string.format("yawJitter=%s", tostring(hasJitter)))
		if hasJitter then
			tracePhase(10, playerState, "yaw jitter hit")
			local oldFlags = playerState.flags
			playerState.flags = playerState.flags | Constants.Flags.CHEATER
			playerState.score = 100

			local jitterReason = "Yaw Jitter Anti-Aim"

			Database.UpsertCheater(playerState.id, {
				name = playerState.wrap:GetName(),
				reason = jitterReason,
				flags = playerState.flags,
				score = playerState.score,
			})

			if oldFlags ~= playerState.flags then
				Events.Publish("OnPlayerStateChange", playerState, jitterReason)
			end
		end
	else
		tracePhase(9, playerState, "yaw nil")
	end
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	yawHistories[id] = nil
	jitterStates[id] = nil
end)

return AntiAim
