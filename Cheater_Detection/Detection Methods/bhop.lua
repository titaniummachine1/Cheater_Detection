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
local GROUND_TICKS_FOR_DECAY = 5 -- Must be grounded for this many ticks before decay applies

-- Per-player state tracking
local playerBhopData = {}

local function initPlayerData(steamID)
	if not playerBhopData[steamID] then
		playerBhopData[steamID] = {
			lastOnGround = true, -- Track last ground state
			lastVelocityZ = 0, -- Track last velocity for jump detection
			groundedTicks = 0, -- Track how long player has been grounded
			decayApplied = false, -- Track if we already applied decay for this ground period
			hasJumped = false, -- Track if player has ever jumped (prevents initial false positives)
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
		-- Player on ground - increment grounded tick counter
		data.groundedTicks = data.groundedTicks + 1

		-- Only apply decay if they've been grounded long enough AND have jumped before
		if data.hasJumped and data.groundedTicks >= GROUND_TICKS_FOR_DECAY and not data.decayApplied then
			-- They stayed grounded for 2+ ticks - bhop sequence ended
			Evidence.ApplyDecayForMethod(steamID, DETECTION_NAME, DECAY_AMOUNT)

			if G.Menu.Advanced.debug then
				print(
					string.format(
						"[Bhop] %s - Landed (stopped bhopping) -%.1f evidence",
						player:GetName(),
						DECAY_AMOUNT
					)
				)
			end

			data.decayApplied = true -- Mark decay as applied for this ground period
		end

		data.lastOnGround = true
	else
		-- Player in air - check if they jumped (velocity increased AND exact jump values)
		if data.lastOnGround and data.lastVelocityZ < velocity.z and (velocity.z == 271 or velocity.z == 277) then
			-- Jump detected - add weight immediately
			data.hasJumped = true -- Mark that this player has jumped
			-- Use manual decay (only decays when landed, not automatic time-based)
			Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT_BASE, { manualDecay = true })

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

		-- Reset ground tracking when leaving ground
		data.lastOnGround = false
		data.groundedTicks = 0
		data.decayApplied = false
	end

	-- Store current velocity for next tick comparison
	data.lastVelocityZ = velocity.z

	return false
end

return Bhop
