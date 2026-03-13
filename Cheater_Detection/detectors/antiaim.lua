--[[ detectors/antiaim.lua
     Detects invalid view angles (Rage AA). 
     Triggering this marks the player as CHEATER immediately.
]]

local Constants = require("Cheater_Detection.core.constants")
local Database = require("Cheater_Detection.Database.Database")
local EventBus = require("Cheater_Detection.core.event_bus")

local AntiAim = {}

function AntiAim.ProcessPlayer(playerState)
	if not playerState or not playerState.wrap then return end
	
	-- Already marked as cheater? skip
	if (playerState.flags & Constants.Flags.CHEATER) ~= 0 then return end

	local angles = playerState.wrap:GetEyeAngles()
	if not angles then return end

	local pitch = angles.pitch
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
			score = playerState.score
		})

		if oldFlags ~= playerState.flags then
			EventBus.Publish("OnPlayerStateChange", playerState, reason)
		end
	end
end

return AntiAim
