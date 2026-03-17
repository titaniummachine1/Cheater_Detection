--[[ detectors/antiaim.lua
     Detects invalid view angles (Rage AA). 
     Triggering this marks the player as CHEATER immediately.
]]

local Constants = require("Cheater_Detection.Core.constants")
local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")

local AntiAim = {}

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

function AntiAim.ProcessPlayer(playerState, cmd)
	if not playerState or not playerState.wrap or not playerState.id then
		return
	end

	local isDebug = Common.IsDebugEnabled()
	traceLog(isDebug, playerState, "enter")

	local entity = playerState.wrap:GetRawEntity()
	if not entity then
		traceLog(isDebug, playerState, "raw entity missing")
		return
	end
	traceLog(isDebug, playerState, "raw entity ok")

	local localPlayer = entities.GetLocalPlayer()
	local isLocalPlayer = localPlayer ~= nil and entity == localPlayer
	local skipEntity = nil
	if not isDebug then
		skipEntity = localPlayer
	end

	if not Common.IsValidPlayer(entity, false, true, skipEntity) then
		traceLog(isDebug, playerState, "IsValidPlayer rejected")
		return
	end
	traceLog(isDebug, playerState, "IsValidPlayer ok")

	local simTime = playerState.wrap:GetSimulationTime()
	if not simTime or simTime <= 0 then
		traceLog(isDebug, playerState, "invalid simTime")
		return
	end
	traceLog(isDebug, playerState, string.format("simTime=%.6f", simTime))

	local isCheater = (playerState.flags & Constants.Flags.CHEATER) ~= 0
	if isCheater and not isDebug then
		traceLog(isDebug, playerState, "already cheater and debug off")
		return
	end
	traceLog(isDebug, playerState, "cheater gate ok")

	local pitch, yaw, angleSource, candidates =
		readDetectionAngles(playerState.wrap, entity, cmd, isDebug and isLocalPlayer)
	if pitch == nil then
		traceLog(isDebug, playerState, "pitch nil")
		return
	end
	traceLog(
		isDebug,
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
	traceLog(isDebug, playerState, string.format("isInvalid=%s", tostring(isInvalid)))

	if isInvalid then
		traceLog(isDebug, playerState, "invalid pitch hit")
		local reason = string.format("Invalid Pitch (%.2f)", pitch)
		DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER, reason)
	end
end

return AntiAim
