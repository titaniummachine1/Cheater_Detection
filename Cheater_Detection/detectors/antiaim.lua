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

function AntiAim.ProcessPlayer(playerState)
	assert(playerState, "AntiAim.ProcessPlayer: playerState missing")
	assert(playerState.wrap, "AntiAim.ProcessPlayer: playerState.wrap missing id=" .. tostring(playerState.id))
	assert(playerState.id, "AntiAim.ProcessPlayer: playerState.id missing")

	local entity = playerState.wrap:GetRawEntity()
	if not entity then
		return
	end
	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	local isLocal = (entity and entity:GetIndex() == client.GetLocalPlayerIndex())

	-- Already marked as cheater? skip (except local debug testing)
	if (playerState.flags & Constants.Flags.CHEATER) ~= 0 and not (isDebug and isLocal) then
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
		return
	end

	local pitch = angles.pitch or angles.x
	if pitch == nil then
		return
	end

	if isDebug and isLocal then
		local currentTick = globals.TickCount()
		if (currentTick - lastDebugTick) >= 66 then
			print(string.format("[AntiAim] RUN local=true pitch=%.2f", pitch))
			lastDebugTick = currentTick
		end
	end

	local isInvalid = false

	-- Rage Pitch check:
	-- 89.0/-89.0 are often used by Lbox/other cheats but can be technically legal.
	-- However, exactly 90 or above/below is physically impossible in standard TF2.
	-- We'll use 89.0 as a suspicion factor, but > 89.1 or < -89.1 as "No Mercy"
	if math.abs(pitch) > 89.1 or pitch == 89.0 or pitch == -89.0 then
		isInvalid = true
	end

	if isInvalid then
		local oldFlags = playerState.flags
		playerState.flags = playerState.flags | Constants.Flags.CHEATER
		playerState.score = 100 -- Set score to 100 for hard detection

		local reason = string.format("Invalid Pitch (%.2f)", pitch)

		-- Persist immediately
		Database.UpsertCheater(playerState.id, {
			name = playerState.wrap:GetName(),
			reason = reason,
			flags = playerState.flags,
			score = playerState.score,
		})

		if oldFlags ~= playerState.flags or (isDebug and isLocal) then
			EventBus.Publish("OnPlayerStateChange", playerState, reason)
		end
	end
	if isDebug then
		print(
			string.format("[AntiAim] HIT id=%s pitch=%.2f local=%s", tostring(playerState.id), pitch, tostring(isLocal))
		)
	end
end

return AntiAim
