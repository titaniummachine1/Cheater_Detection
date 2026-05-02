--[[ detectors/antiaim.lua
     Detects invalid view angles (Rage AA).
     Triggering this marks the player as CHEATER immediately.
]]

local Constants = require("Cheater_Detection.Core.constants")
local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local G = require("Cheater_Detection.Utils.Globals")

local AntiAim = {}

local lastInvalidPitchLogAt = {}
local MAX_LEGAL_PITCH = 89.30
local MAX_SANE_ABS_ANGLE = 540

local function isInvalidPitchValue(pitch)
	if type(pitch) ~= "number" then
		return false
	end
	return pitch > MAX_LEGAL_PITCH or pitch < -MAX_LEGAL_PITCH
end

local function isCorruptedAngleValue(value)
	if type(value) ~= "number" then
		return true
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return true
	end
	return math.abs(value) > MAX_SANE_ABS_ANGLE
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

-- Trace logging is only active in debug mode; use the shared IsDebugEnabled helper
-- so callers don't need to gate the call themselves.
local function traceLog(isDebug, playerState, detail)
	if not isDebug then
		return
	end
	local id = playerState and playerState.id or "nil"
	if detail ~= nil then
		print(string.format("[AntiAim] id=%s %s", tostring(id), tostring(detail)))
	else
		print(string.format("[AntiAim] id=%s", tostring(id)))
	end
end

local function readDetectionAngles(wrap, entity, cmd, isLocalDebug)
	if not wrap or not entity then
		return nil, nil, "nil", {}
	end
	local candidates = {}

	local function addCandidate(source, pitch, yaw)
		local p = toNumber(pitch)
		local y = toNumber(yaw)
		if p == nil then
			return
		end
		if isCorruptedAngleValue(p) then
			return
		end
		if y ~= nil and isCorruptedAngleValue(y) then
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

function AntiAim.ProcessPlayer(playerState, cmd)
	if not playerState or not playerState.wrap or not playerState.id then
		return
	end

	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.AntiAim) then
		return
	end

	local isDebug = Common.IsDebugEnabled()
	local entity = playerState.wrap:GetRawEntity()
	if not entity then
		return
	end

	local localPlayer = entities.GetLocalPlayer()
	local isLocalPlayer = localPlayer ~= nil and entity == localPlayer
	local skipEntity = nil
	if not isDebug then
		skipEntity = localPlayer
	end

	if not Common.IsValidPlayer(entity, true, true, skipEntity) then
		return
	end

	local simTime = playerState.wrap:GetSimulationTime()
	if not simTime or simTime <= 0 then
		return
	end

	local isCheater = (playerState.flags & Constants.Flags.CHEATER) ~= 0
	if isCheater then
		return
	end

	local pitch, yaw, angleSource, candidates =
		readDetectionAngles(playerState.wrap, entity, cmd, isDebug and isLocalPlayer)
	if pitch == nil then
		return
	end

	local isInvalid = isInvalidPitchValue(pitch)

	if isInvalid then
		if isCorruptedAngleValue(pitch) then
			return
		end
		-- Entity state can change between early validation and angle reads.
		-- Re-check here to avoid flagging stale dormant/dead snapshots.
		if (not entity:IsValid()) or entity:IsDormant() or (not entity:IsAlive()) then
			return
		end
		local now = globals.RealTime()
		local lastLog = lastInvalidPitchLogAt[playerState.id] or 0
		local cooldownExpired = (now - lastLog) >= 10.0
		if isDebug and cooldownExpired then
			lastInvalidPitchLogAt[playerState.id] = now
			traceLog(
				true,
				playerState,
				string.format(
					"invalid pitch hit pitch=%.3f yaw=%s source=%s",
					pitch,
					yaw ~= nil and string.format("%.3f", yaw) or "nil",
					tostring(angleSource)
				)
			)
		end
		local reason = string.format("Invalid Pitch (%.3f)", pitch)
		DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER, reason)
	end
end

return AntiAim
