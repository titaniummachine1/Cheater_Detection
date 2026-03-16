--[[ detectors/antiaim.lua
     Detects invalid view angles (Rage AA). 
     Triggering this marks the player as CHEATER immediately.
]]

local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local EventBus = require("Cheater_Detection.core.event_bus")

local AntiAim = {}

function AntiAim.ProcessPlayer(playerState)
	assert(playerState, "AntiAim.ProcessPlayer: playerState missing")
	assert(playerState.wrap, "AntiAim.ProcessPlayer: playerState.wrap missing id=" .. tostring(playerState.id))
	assert(playerState.id, "AntiAim.ProcessPlayer: playerState.id missing")

	local entity = playerState.wrap:GetRawEntity()
	if not entity then
		return
	end

	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true

	local isCheater = (playerState.flags & Constants.Flags.CHEATER) ~= 0
	if isCheater and not isDebug then
		return
	end

	if entity == entities.GetLocalPlayer() and not isDebug then
		return
	end

	local angles = playerState.wrap:GetEyeAngles()
	if not angles then
		return
	end

	local pitch = angles.pitch or angles.x
	if pitch == nil then
		return
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

		if oldFlags ~= playerState.flags then
			EventBus.Publish("OnPlayerStateChange", playerState, reason)
		end
	end
end
return AntiAim
