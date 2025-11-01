--[[ Cheater Detection - Anti-Aim Detection ]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Logger = require("Cheater_Detection.Utils.Logger")

--[[ Module Declaration ]]
local AntiAim = {}

--[[ Configuration ]]
local DETECTION_NAME = "anti_aim"
local EVIDENCE_WEIGHT = 25 -- High weight - this is plain cheating
local MIN_DETECTIONS = 1 -- Instant evidence on first detection

-- Invalid pitch thresholds
local INVALID_PITCH_MIN = -90
local INVALID_PITCH_MAX = 90
local EXACT_PITCH_SUSPECT = 89.000 -- Common rage AA value

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

--[[ Public Functions ]]
function AntiAim.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.AntyAim then
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

	-- Get eye angles
	local angles = player:GetEyeAngles()
	if not angles then
		return false
	end

	local detected = false
	local detectionReason = nil
	-- Enhanced detection with cheat fingerprinting
	if angles.pitch > 89.4 or angles.pitch < -89.4 then
		-- Specific cheat pattern detection
		if angles.pitch % 3256 == 0 then
			detected = true
			detectionReason = "LBOX AA (Center)"
		elseif angles.pitch % 271 == 0 then
			detected = true
			detectionReason = "RIJIN AA"
		elseif angles.pitch % 90 == 0 then
			detected = true
			detectionReason = "AA (Up/Down)"
		else
			-- Generic invalid pitch
			detected = true
			detectionReason = "Anti-Aim"
		end
	end

	-- Add evidence immediately (exploits = instant flag)
	if detected then
		Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

		if G.Menu.Advanced.debug then
			print(
				string.format(
					"[AntiAim] %s - Detected %s (pitch: %.3f) +%.1f evidence",
					player:GetName(),
					detectionReason,
					angles.pitch,
					EVIDENCE_WEIGHT
				)
			)
		end

		Logger.Info(
			"AntiAim",
			string.format("%s detected using %s (pitch: %.3f)", player:GetName(), detectionReason, angles.pitch)
		)
		return true
	end

	return false
end

return AntiAim
