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
local BHOP_AIR_TICKS_THRESHOLD = 3  -- Number of consecutive air ticks to trigger detection (similar to old Menu.BhopTimes)
local DECAY_AMOUNT = 3.0  -- Weight to remove on failed bhop

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
			airTicks = 0,  -- Count consecutive ticks in air
			lastTriggeredBhop = false,  -- Track if we just triggered detection
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

	-- Check ground state (matches old CheckBhop logic)
	local flags = player:GetPropInt("m_fFlags")
	local onGround = (flags & FL_ONGROUND) ~= 0

	if onGround then
		-- Player on ground - reset air counter and apply decay if we had triggered bhop before
		if data.lastTriggeredBhop then
			Evidence.ApplyDecayForMethod(steamID, DETECTION_NAME, DECAY_AMOUNT)
			data.lastTriggeredBhop = false
			
			if G.Menu.Advanced.debug then
				print(string.format("[Bhop] %s - Landed (not bhopping) -%.1f evidence", 
					player:GetName(), DECAY_AMOUNT))
			end
		end
		data.airTicks = 0
	else
		-- Player in air - increment counter
		data.airTicks = data.airTicks + 1
		
		-- Check if reached threshold (consecutive air ticks = bhop)
		if data.airTicks >= BHOP_AIR_TICKS_THRESHOLD then
			-- Bhop detected - add weight
			Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT_BASE)
			data.lastTriggeredBhop = true
			data.airTicks = 0  -- Reset counter
			
			if G.Menu.Advanced.debug then
				print(string.format("[Bhop] %s - Bhop detected (air ticks: %d) +%.1f evidence", 
					player:GetName(), BHOP_AIR_TICKS_THRESHOLD, EVIDENCE_WEIGHT_BASE))
			end
			
			return true
		end
	end
	
	return false
end

return Bhop
