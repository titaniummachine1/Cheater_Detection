--[[ Cheater Detection - Fake Lag Detection ]]
--
-- Detects packet choking (fakelag, doubletap) by monitoring simulation time delta

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local FakeLag = {}

--[[ Configuration ]]
local DETECTION_NAME = "fake_lag"
local EVIDENCE_WEIGHT = 22 -- High weight - exploit
local MAX_TICK_DELTA = 14 -- Increased to prevent false positives on laggy bots/players

-- Per-player state tracking
local playerSimTimeData = {}

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

local function initPlayerData(steamID)
	if not playerSimTimeData[steamID] then
		playerSimTimeData[steamID] = {
			lastSimTime = nil,
		}
	end
end

local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
end

--[[ Public Functions ]]
function FakeLag.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.Choke then
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

	-- Ignore bots (SteamID64 is always a 17-digit string)
	if type(steamID) ~= "string" or #steamID ~= 17 then
		return false
	end

	-- Skip if already marked as cheater
	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	-- Initialize tracking data
	initPlayerData(steamID)
	local data = playerSimTimeData[steamID]

	-- Get current simulation time
	local currentSimTime = player:GetSimulationTime()
	if not currentSimTime then
		return false
	end

	-- Need previous simtime for comparison
	if not data.lastSimTime then
		data.lastSimTime = currentSimTime
		return false
	end

	-- Calculate delta
	local delta = currentSimTime - data.lastSimTime

	-- Skip if rewinding (demo playback or local player lag compensation)
	if delta == 0 then
		return false
	end

	-- Convert to ticks
	local deltaTicks = timeToTicks(delta)

	-- Detect excessive tick delta (choking packets)
	if deltaTicks >= MAX_TICK_DELTA then
		Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

		if G.Menu.Advanced.debug then
			print(
				string.format(
					"[FakeLag] %s - Tick delta: %d (threshold: %d)",
					player:GetName(),
					deltaTicks,
					MAX_TICK_DELTA
				)
			)
		end

		data.lastSimTime = currentSimTime
		return true
	end

	-- Update last simtime
	data.lastSimTime = currentSimTime
	return false
end

return FakeLag
