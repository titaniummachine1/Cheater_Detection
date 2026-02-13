--[[ Cheater Detection - Manual Priority Enforcement ]]
--
-- Awards evidence when a player is manually assigned priority 10 in Lmaobox.
-- Meant to integrate with the AutoFlagPriorityTen option to mark custom cheaters.

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local ManualPriority = {}

--[[ Configuration ]]
local DETECTION_NAME = "manual_priority"
local EVIDENCE_WEIGHT = 100 -- Immediate threshold push

-- Track last tick we awarded evidence per steamID to avoid double counting in same frame
local lastTriggerTick = {}

--[[ Helper Functions ]]
local function shouldRun()
	local advanced = G.Menu and G.Menu.Advanced
	return advanced and advanced.AutoFlagPriorityTen == true
end

local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() or player:IsDormant() then
		return false
	end
	return true
end

--[[ Public Functions ]]
function ManualPriority.Check(player, steamID)
	if not shouldRun() then
		return false
	end

	if not validatePlayer(player) then
		return false
	end

	if not steamID then
		steamID = tostring(Common.GetSteamID64(player))
	end

	local priority = playerlist.GetPriority(steamID)
	if priority ~= 10 then
		lastTriggerTick[steamID] = nil
		return false
	end

	local currentTick = globals.TickCount()
	if lastTriggerTick[steamID] == currentTick then
		return false
	end

	lastTriggerTick[steamID] = currentTick

	Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

	if G.Menu.Advanced.debug then
		print(string.format("[ManualPriority] %s flagged via priority 10", player:GetName() or steamID))
	end

	return true
end

return ManualPriority
