--[[ Cheater Detection - Detection Method Template ]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local Detection = {}

--[[ Local Variables ]]
local detectionName = "Template" -- Change this to match specific detection
local evidenceWeight = 15 -- Default evidence weight
local MIN_DETECTIONS = 3 -- Minimum required detections before adding evidence

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

--[[ Public Functions ]]
function Detection.Check(player, entity)
	-- Skip if detection is disabled in menu
	if not G.Menu.Advanced[detectionName] then
		return false
	end

	-- Validate player
	if not validatePlayer(entity) then
		return false
	end

	-- Get steamID for tracking
	local steamID = Common.GetSteamID64(entity)
	if not steamID then
		return false
	end

	-- Initialize detection counter if needed
	if not G.PlayerData[steamID] then
		G.PlayerData[steamID] = G.DefaultPlayerData
	end

	if not G.PlayerData[steamID].detections then
		G.PlayerData[steamID].detections = {}
	end

	if not G.PlayerData[steamID].detections[detectionName] then
		G.PlayerData[steamID].detections[detectionName] = 0
	end

	-- Implement detection logic here
	local detected = false

	-- Example detection logic (replace with actual logic):
	-- if extraordinary_condition_detected then
	--     detected = true
	-- end

	-- If detected, increment counter and check threshold
	if detected then
		G.PlayerData[steamID].detections[detectionName] = G.PlayerData[steamID].detections[detectionName] + 1

		if G.PlayerData[steamID].detections[detectionName] >= MIN_DETECTIONS then
			-- Add evidence when threshold reached
			Evidence.AddEvidence(steamID, detectionName, evidenceWeight)
			-- Reset counter after adding evidence
			G.PlayerData[steamID].detections[detectionName] = 0
		end

		return true
	end

	return false
end

return Detection
