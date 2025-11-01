--[[ Cheater Detection - Duck Speed Detection ]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local DuckSpeed = {}

--[[ Configuration ]]
local DETECTION_NAME = "Duck_Speed"
local EVIDENCE_WEIGHT = 20 -- Higher weight - movement exploit
local VIOLATION_TICKS_REQUIRED = 66 -- 1 second of violation
local DUCK_SPEED_MULTIPLIER = 0.66 -- TF2 duck speed penalty
local FULLY_CROUCHED_VIEW_OFFSET = 45 -- View offset Z when fully crouched

-- Per-player state tracking
local playerDuckData = {}

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

local function initPlayerData(steamID)
	if not playerDuckData[steamID] then
		playerDuckData[steamID] = {
			violationTicks = 0,
			lastDecayTick = 0,
		}
	end
end

--[[ Public Functions ]]
function DuckSpeed.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.DuckSpeed then
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
	local data = playerDuckData[steamID]

	-- Get raw entity for prop access
	local entity = player:GetRawEntity()
	if not entity then
		return false
	end

	-- Check flags
	local flags = player:GetPropInt("m_fFlags")
	local onGround = (flags & FL_ONGROUND) ~= 0
	local ducking = (flags & FL_DUCKING) ~= 0

	-- Only check when on ground and ducking
	if not (onGround and ducking) then
		data.violationTicks = 0
		
		-- Apply decay when not ducking or not on ground (normal behavior)
		if data.lastDecayTick ~= globals.TickCount() then
			Evidence.ApplyDecayForMethod(steamID, DETECTION_NAME, 1.5) -- Decay 1.5 weight per tick when normal
			data.lastDecayTick = globals.TickCount()
			
			if G.Menu.Advanced.debug then
				print(string.format("[DuckSpeed] %s - Normal movement (not ducking/on ground) -1.5 evidence", 
					player:GetName()))
			end
		end
		
		return false
	end

	-- Get max speed and current velocity
	local maxSpeed = entity:GetPropFloat("m_flMaxspeed")
	local velocity = entity:EstimateAbsVelocity()

	if not maxSpeed or not velocity then
		return false
	end

	local currentSpeed = velocity:Length()
	local maxDuckSpeed = maxSpeed * DUCK_SPEED_MULTIPLIER

	-- Check if exceeding duck speed limit
	if currentSpeed >= maxDuckSpeed then
		-- Verify fully crouched via view offset
		local viewOffset = player:GetViewOffset()
		if viewOffset and math.floor(viewOffset.z) == FULLY_CROUCHED_VIEW_OFFSET then
			data.violationTicks = data.violationTicks + 1

			-- Require sustained violation (1 second = 66 ticks)
			if data.violationTicks >= VIOLATION_TICKS_REQUIRED then
				Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

				if G.Menu.Advanced.debug then
					print(string.format(
						"[DuckSpeed] %s - Speed: %.1f / Max: %.1f (%.0f%% over limit)",
						player:GetName(),
						currentSpeed,
						maxDuckSpeed,
						(currentSpeed / maxDuckSpeed - 1) * 100
					))
				end

				-- Reset counter
				data.violationTicks = 0
				return true
			end
		end
	else
		-- Reset if not violating
		data.violationTicks = 0
		
		-- Apply decay when ducking but within speed limits (normal ducking)
		if data.lastDecayTick ~= globals.TickCount() then
			Evidence.ApplyDecayForMethod(steamID, DETECTION_NAME, 0.8) -- Slower decay when ducking normally
			data.lastDecayTick = globals.TickCount()
			
			if G.Menu.Advanced.debug then
				print(string.format("[DuckSpeed] %s - Normal ducking speed -0.8 evidence", 
					player:GetName()))
			end
		end
	end

	return false
end

return DuckSpeed
