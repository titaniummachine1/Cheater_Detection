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
local DECAY_AMOUNT = 2.0 -- Weight to remove on failed bhop

-- Per-player state tracking
local playerBhopData = {}

local function initPlayerData(steamID)
	if not playerBhopData[steamID] then
		playerBhopData[steamID] = {
			lastOnGround = true, -- Track last ground state
			lastVelocityZ = 0, -- Track last velocity for jump detection
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
	if not Common.IsValidPlayer(player, true, false) then
		return false
	end

	-- Get steamID for tracking
	local steamID = Common.GetSteamID64(player)
	if not Common.IsSteamID64(steamID) then
		return false
	end
	steamID = tostring(steamID)

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

	-- Get velocity for jump detection
	local velocity = entity:EstimateAbsVelocity()
	if not velocity then
		return false
	end

	-- Check ground state (matches old CheckBhop logic)
	local flags = player:GetPropInt("m_fFlags")
	local onGround = (flags & FL_ONGROUND) ~= 0

	if onGround then
		-- Player on ground - reset bhop counter and apply decay if they were airborne before
		if not data.lastOnGround then
			Evidence.ApplyDecayForMethod(steamID, DETECTION_NAME, DECAY_AMOUNT)

			if G.Menu.Advanced.debug then
				print(string.format("[Bhop] %s - Landed -%.1f evidence", player:GetName(), DECAY_AMOUNT))
			end
		end
		data.lastOnGround = true
	else
		-- Player in air - check if they jumped (velocity increased AND exact jump values)
		if data.lastOnGround and data.lastVelocityZ < velocity.z and (velocity.z == 271 or velocity.z == 277) then
			-- Jump detected - add weight immediately
			Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT_BASE)

			if G.Menu.Advanced.debug then
				print(
					string.format(
						"[Bhop] %s - Bhop detected (vel.z: %.0f) +%.1f evidence",
						player:GetName(),
						velocity.z,
						EVIDENCE_WEIGHT_BASE
					)
				)
			end

			return true
		end
		data.lastOnGround = false
	end

	-- Store current velocity for next tick comparison
	data.lastVelocityZ = velocity.z

	return false
end

return Bhop
