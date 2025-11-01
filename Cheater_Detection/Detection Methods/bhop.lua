--[[ Cheater Detection - Bunny Hop Detection ]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local Bhop = {}

--[[ Configuration ]]
local DETECTION_NAME = "bhop"
local EVIDENCE_WEIGHT_BASE = 5
local EVIDENCE_MULTIPLIER = 1.5

-- Per-player state tracking
local playerBhopData = {}

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

local function initPlayerData(steamID)
	if not playerBhopData[steamID] then
		playerBhopData[steamID] = {
			lastOnGround = true,
			lastVelocityZ = 0,
			consecutiveGroundTicks = 0,
			lastJumpWasPerfect = false,
		}
	end
end

--[[ Public Functions ]]
function Bhop.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.Bhop then
		return false
	end

	-- Validate player
	if not validatePlayer(player) then
		return false
	end

	-- Get steamID for tracking
	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return false
	end

	-- Skip if already marked as cheater
	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	-- Initialize tracking data
	initPlayerData(steamID)
	local data = playerBhopData[steamID]

	-- Get raw entity for velocity access
	local entity = player:GetRawEntity()
	if not entity then
		return false
	end

	-- Check ground state and velocity
	local onGround = player:IsOnGround()
	local velocity = entity:EstimateAbsVelocity()

	if not velocity then
		return false
	end

	-- Tick-based perfect jump detection: airbone -> ground (1 tick) -> airbone
	if onGround and not data.lastOnGround then
		-- Just landed, reset counter
		data.consecutiveGroundTicks = 1
	elseif not onGround and data.lastOnGround then
		-- Just jumped, check if we were only on ground for 1 tick
		if data.consecutiveGroundTicks == 1 then
			-- Perfect jump detected - add weight
			Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT_BASE)

			if G.Menu.Advanced.debug then
				print(
					string.format(
						"[Bhop] %s - Perfect jump detected (1 tick on ground) +%.1f evidence",
						player:GetName(),
						EVIDENCE_WEIGHT_BASE
					)
				)
			end

			data.lastOnGround = false
			data.lastJumpWasPerfect = true
			return true
		else
			-- Imperfect jump (on ground for more than 1 tick) - apply decay
			if data.lastJumpWasPerfect then
				Evidence.ApplyDecayForMethod(steamID, DETECTION_NAME, 3.0) -- Decay 3.0 weight for imperfect jump
				data.lastJumpWasPerfect = false

				if G.Menu.Advanced.debug then
					print(
						string.format(
							"[Bhop] %s - Imperfect jump (on ground for %d ticks) -3.0 evidence",
							player:GetName(),
							data.consecutiveGroundTicks
						)
					)
				end
			end
		end
	elseif not onGround then
		-- Still in air, continue
		data.consecutiveGroundTicks = 0
	else
		-- Still on ground, increment counter
		data.consecutiveGroundTicks = (data.consecutiveGroundTicks or 0) + 1
	end

	-- Update state for next tick
	data.lastOnGround = onGround
	data.lastVelocityZ = velocity.z
	return false
end

return Bhop
