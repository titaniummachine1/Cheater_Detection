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

	-- Simplified bhop detection - detect perfect jump and add evidence
	-- Perfect bhop: player jumps without touching ground with TF2-specific velocity
	if not onGround and data.lastOnGround and data.lastVelocityZ < velocity.z then
		if velocity.z == 271 or velocity.z == 277 then
			-- Get current evidence for this detection method
			local currentEvidence = 0
			if G.PlayerData[steamID] and G.PlayerData[steamID].Evidence and G.PlayerData[steamID].Evidence.Reasons then
				local reason = G.PlayerData[steamID].Evidence.Reasons[DETECTION_NAME]
				if reason then
					currentEvidence = reason.Weight or 0
				end
			end

			-- Calculate weight: if 0 set to 5, otherwise multiply by 1.5
			local weight = currentEvidence == 0 and EVIDENCE_WEIGHT_BASE or (currentEvidence * EVIDENCE_MULTIPLIER - currentEvidence)
			
			Evidence.AddEvidence(steamID, DETECTION_NAME, weight)

			if G.Menu.Advanced.debug then
				print(string.format("[Bhop] %s - Perfect hop detected (vel.z: %.0f) +%.1f evidence", 
					player:GetName(), velocity.z, weight))
			end

			data.lastOnGround = false
			return true
		end
	end

	-- Update state for next tick
	data.lastOnGround = onGround
	data.lastVelocityZ = velocity.z
	return false
end

return Bhop
