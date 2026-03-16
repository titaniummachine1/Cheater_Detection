--[[ detectors/antiaim.lua
     Detects invalid view angles (Rage AA). 
     Triggering this marks the player as CHEATER immediately.
]]

local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local EventBus = require("Cheater_Detection.core.event_bus")

local AntiAim = {}
local lastDebugTick = 0
local lastRemoteDebugTick = {} -- per-player throttle for remote RUN prints

function AntiAim.ProcessPlayer(playerState)
	assert(playerState, "AntiAim.ProcessPlayer: playerState missing")
	assert(playerState.wrap, "AntiAim.ProcessPlayer: playerState.wrap missing id=" .. tostring(playerState.id))
	assert(playerState.id, "AntiAim.ProcessPlayer: playerState.id missing")

	local entity = playerState.wrap:GetRawEntity()
	if not entity then
		return
	end
	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	local isLocal = (entity:GetIndex() == client.GetLocalPlayerIndex())

	-- Already marked as cheater? Skip in normal mode.
	-- In debug mode always run so we can verify detection works for known players.
	if (playerState.flags & Constants.Flags.CHEATER) ~= 0 and not isDebug then
		return
	end

	if entity == entities.GetLocalPlayer() and not isDebug then
		return
	end

	local angles = nil
	if isLocal and isDebug then
		-- In debug self-test, prioritize networked props over camera view angles.
		local netAng = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
		if netAng then
			angles = EulerAngles(netAng.x, netAng.y, netAng.z)
		else
			netAng = entity:GetPropVector("m_angEyeAngles[0]")
			if netAng then
				angles = EulerAngles(netAng.x, netAng.y, netAng.z)
			end
		end
	end

	if not angles then
		angles = playerState.wrap:GetEyeAngles()
	end

	if not angles then
		if isDebug then
			print(string.format("[AntiAim] SKIP id=%s angles=nil", tostring(playerState.id)))
		end
		return
	end

	local pitch = angles.pitch or angles.x
	if pitch == nil then
		if isDebug then
			print(
				string.format(
					"[AntiAim] SKIP id=%s pitch=nil angles.pitch=%s angles.x=%s",
					tostring(playerState.id),
					tostring(angles.pitch),
					tostring(angles.x)
				)
			)
		end
		return
	end

	-- Periodic RUN heartbeat (debug only)
	if isDebug then
		local currentTick = globals.TickCount()
		local lastTick = isLocal and lastDebugTick or (lastRemoteDebugTick[playerState.id] or 0)
		if (currentTick - lastTick) >= 66 then
			print(
				string.format(
					"[AntiAim] RUN local=%s id=%s pitch=%.2f",
					tostring(isLocal),
					tostring(playerState.id),
					pitch
				)
			)
			if isLocal then
				lastDebugTick = currentTick
			else
				lastRemoteDebugTick[playerState.id] = currentTick
			end
		end
	end

	local isInvalid = math.abs(pitch) > 89.1 or pitch == 89.0 or pitch == -89.0

	if isInvalid then
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

		if oldFlags ~= playerState.flags or (isDebug and isLocal) then
			EventBus.Publish("OnPlayerStateChange", playerState, reason)
		end

		if isDebug then
			print(
				string.format(
					"[AntiAim] HIT id=%s pitch=%.2f local=%s",
					tostring(playerState.id),
					pitch,
					tostring(isLocal)
				)
			)
		end
	end
end

EventBus.Subscribe("OnPlayerDisconnect", function(id)
	lastRemoteDebugTick[id] = nil
end)

return AntiAim
