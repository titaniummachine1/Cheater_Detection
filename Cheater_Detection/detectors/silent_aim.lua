--[[ detectors/silent_aim.lua
     Upgraded Silent Aimbot Detector.
     Tracks 4 ticks of history. When a player deals damage, it waits 1 tick 
     then interpolates the trajectory between the pre-shot and post-shot angles.
     Massive deviations in the middle ticks (1-tick flick & snap back) trigger exponential suspicion.
]]

local EventBus = require("Cheater_Detection.core.event_bus")
local PlayerCache = require("Cheater_Detection.core.player_cache")
local Constants = require("Cheater_Detection.core.constants")
local Common = require("Cheater_Detection.Utils.Common")
local Database = require("Cheater_Detection.Database.Database")

local SilentAim = {}

-- [[ Internal Storage ]]
local angleHistory = {}      -- string id -> array of {pitch, yaw, tick}
local verificationQueue = {} -- string id -> tickToVerify

local HISTORY_MAX = 4
local MIN_DEVIATION = 10.0   -- Degrees of error spike required to flag
local WEIGHT_EXPONENT = 1.3  -- (error^weight) calculation

local function lerpAngle(a, b, t)
	local diff = (b - a + 180) % 360 - 180
	return a + diff * t
end

local EventManager = require("Cheater_Detection.Utils.EventManager")

-- Listen to damage events to trigger verification on the attacker
local function onDamageEvent(event)
	local eventName = event:GetName()
	if eventName == "player_hurt" or eventName == "player_death" then
		local attackerUID = event:GetInt("attacker")
		if not attackerUID then return end

		local ply = entities.GetByUserID(attackerUID)
		if not ply then return end
		
		local localPlayer = entities.GetLocalPlayer()
		if not localPlayer or localPlayer:GetIndex() == ply:GetIndex() then return end
		
		local steamID64 = Common.GetSteamID64(ply)
		if not steamID64 then return end

		-- Queue verification for the exact next tick
		verificationQueue[steamID64] = globals.TickCount() + 1
	end
end

EventManager.Register("FireGameEvent", "CD_SilentAim_Event", onDamageEvent, "*")

function SilentAim.ProcessPlayer(playerState)
	local id = playerState.id
	local ply = playerState.wrap:GetRawEntity()
	if not ply or ply:IsDormant() then return end

	local angles = playerState.wrap:GetEyeAngles()
	if not angles then return end

	local cp, cy = angles.pitch, angles.yaw
	local curTick = globals.TickCount()

	if not angleHistory[id] then
		angleHistory[id] = {}
	end
	local hist = angleHistory[id]

	-- 1. Is it time to verify the trajectory for a shot?
	if verificationQueue[id] and curTick >= verificationQueue[id] then
		verificationQueue[id] = nil

		-- We need at least the oldest point, the snap point(s), and the current return point
		if #hist >= 3 then
			local oldest = hist[1]
			local newest = { pitch = cp, yaw = cy, tick = curTick }
			local tickSpan = newest.tick - oldest.tick
			
			if tickSpan > 0 then
				local maxDeviation = 0
				
				-- Check the intermediate ticks to find the flick severity
				for i = 2, #hist do
					local mid = hist[i]
					local fraction = (mid.tick - oldest.tick) / tickSpan
					
					-- Prevent domain errors
					if fraction > 0 and fraction < 1 then
						local expectedP = oldest.pitch + (newest.pitch - oldest.pitch) * fraction
						local expectedY = lerpAngle(oldest.yaw, newest.yaw, fraction)
						
						local errP = math.abs(mid.pitch - expectedP)
						local errY = math.abs((mid.yaw - expectedY + 180) % 360 - 180)
						local totalError = math.sqrt(errP^2 + errY^2)
						
						if totalError > maxDeviation then
							maxDeviation = totalError
						end
					end
				end
				
				-- 2. Evaluate Snap-Back logic
				if maxDeviation > MIN_DEVIATION then
					local scoreGain = maxDeviation ^ WEIGHT_EXPONENT
					playerState.score = playerState.score + scoreGain
					
					local oldFlags = playerState.flags
					local reason = string.format("SilentAim Spike (%.1f°)", maxDeviation)

					if playerState.score >= Constants.Threshold.SUSPICIOUS then
						playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
					end

					-- Hard clamp at 99 for suspicion stats (only AntiAim sets 100)
					playerState.score = math.min(99, playerState.score)

					if (playerState.flags & Constants.Flags.SUSPICIOUS) ~= 0 then
						Database.UpsertCheater(id, {
							name = playerState.wrap:GetName(),
							reason = reason,
							flags = playerState.flags,
							score = playerState.score,
						})

						if playerState.flags ~= oldFlags then
							EventBus.Publish("OnPlayerStateChange", playerState, reason)
						end
					end
				end
			end
		end
	end

	-- 3. Maintain Rolling History Buffer
	table.insert(hist, { pitch = cp, yaw = cy, tick = curTick })
	if #hist > HISTORY_MAX then
		table.remove(hist, 1)
	end
end

-- Cleanup on disconnect
EventBus.Subscribe("OnPlayerDisconnect", function(id)
	angleHistory[id] = nil
	verificationQueue[id] = nil
end)

return SilentAim
