--[[ Cheater Detection - Bunny Hop Detection ]]
--
-- Detects scripted bunnyhops by counting consecutive frame-perfect jumps.
-- A "perfect jump" = leaving ground within 2 ticks of landing.
-- Normal players rarely chain more than 2-3 perfect jumps.
-- Scripted bhop consistently chains 4+ perfect jumps every time.

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local Bhop = {}

--[[ Configuration ]]
local DETECTION_NAME = "bhop"
local EVIDENCE_WEIGHT = 15
local PERFECT_JUMP_WINDOW = 2
local MIN_CONSECUTIVE_HOPS = 4

local playerBhopData = {}

local function getPlayerData(steamID)
	local data = playerBhopData[steamID]
	if not data then
		data = {
			wasOnGround = false,
			groundTicks = 0,
			consecutivePerfectJumps = 0,
		}
		playerBhopData[steamID] = data
	end
	return data
end

--[[ Public Functions ]]
function Bhop.Check(player, steamID)
	if not G.Menu.Advanced.Bhop then
		return false
	end

	if not Common.IsValidPlayer(player, true, false) then
		return false
	end

	if not steamID then
		steamID = tostring(Common.GetSteamID64(player))
	end

	local data = getPlayerData(steamID)

	local flags = player:GetPropInt("m_fFlags")
	local onGround = (flags & FL_ONGROUND) ~= 0

	if onGround then
		data.groundTicks = data.groundTicks + 1
		data.wasOnGround = true
		return false
	end

	-- Transitioned from ground to air this tick
	if data.wasOnGround then
		if data.groundTicks <= PERFECT_JUMP_WINDOW and data.groundTicks > 0 then
			data.consecutivePerfectJumps = data.consecutivePerfectJumps + 1
		else
			data.consecutivePerfectJumps = 1
		end

		data.wasOnGround = false
		data.groundTicks = 0

		if data.consecutivePerfectJumps >= MIN_CONSECUTIVE_HOPS then
			Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

			if G.Menu.Advanced.debug then
				print(
					string.format(
						"[Bhop] %s - %d consecutive perfect jumps",
						player:GetName(),
						data.consecutivePerfectJumps
					)
				)
			end

			return true
		end
	end

	return false
end

return Bhop
