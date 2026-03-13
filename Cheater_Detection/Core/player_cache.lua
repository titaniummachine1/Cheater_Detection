--[[ core/player_cache.lua
     Optimized player state management and lookup.
     Integrates WrappedPlayer and Evidence into a single object.
]]

local Constants = require("Cheater_Detection.core.constants")
local WrappedPlayer = require("Cheater_Detection.Utils.WrappedPlayer")
local Common = require("Cheater_Detection.Utils.Common")

local G = require("Cheater_Detection.Utils.Globals")

local PlayerCache = {}

---@type table<string, table>
local activeSet = {} -- Only players currently in the server

---@class InternalState
---@field wrap table The WrappedPlayer object
---@field flags integer Bitmask of Constants.Flags
---@field score number Current suspicion score
---@field externalChecked boolean Whether Steam/Valve check was done this session
---@field lastUpdate integer Last tick updated

---Get or create active state for a player
---@param ply Entity
---@return InternalState|nil
function PlayerCache.Get(ply)
	if not ply or not ply:IsValid() then
		return nil
	end

	local steamID = Common.GetSteamID64(ply)
	if not steamID then
		return nil
	end

	local id = tostring(steamID)
	if not activeSet[id] then
		-- Check Database for existing data
		local dbEntry = G.DataBase[id]
		local initialFlags = dbEntry and dbEntry.Flags or Constants.Flags.NONE
		local initialScore = dbEntry and dbEntry.Score or 0

		activeSet[id] = {
			wrap = WrappedPlayer.FromEntity(ply),
			flags = initialFlags,
			score = initialScore,
			externalChecked = false,
			lastUpdate = globals.TickCount(),
			id = id,
		}
	end

	return activeSet[id]
end

---Get all currently active players
---@return table[]
function PlayerCache.GetAll()
	local results = {}
	for _, state in pairs(activeSet) do
		table.insert(results, state)
	end
	return results
end

---Remove player from active cache (e.g. disconnect)
---@param id string
function PlayerCache.Remove(id)
	activeSet[id] = nil
end

--- Clear non-persistent data while keeping suspicion for players in-server
function PlayerCache.Hearthbeat()
	local currentTick = globals.TickCount()
	for id, state in pairs(activeSet) do
		-- 1. Check if player is still in server
		local ply = state.wrap:GetRawEntity()
		if not ply or not ply:IsValid() then
			activeSet[id] = nil
		else
			-- 2. Performance: Decay suspicion if no events happened
			if state.score > 0 then
				-- Logic for different decay per flag
				if (state.flags & Constants.Flags.HIGH_RISK) ~= 0 then
					state.score = math.max(0, state.score - 2)
				elseif (state.flags & Constants.Flags.SUSPICIOUS) ~= 0 then
					state.score = math.max(0, state.score - 5)
				end

				-- 3. Update flags based on new score
				if state.score < Constants.Threshold.SUSPICIOUS then
					state.flags = state.flags & ~Constants.Flags.SUSPICIOUS
					state.flags = state.flags & ~Constants.Flags.HIGH_RISK
				elseif state.score < Constants.Threshold.HIGH_RISK then
					state.flags = state.flags | Constants.Flags.SUSPICIOUS
					state.flags = state.flags & ~Constants.Flags.HIGH_RISK
				else
					state.flags = state.flags | Constants.Flags.SUSPICIOUS
					state.flags = state.flags | Constants.Flags.HIGH_RISK
				end
			end
		end
	end
end

---Return the raw active table (for central management)
function PlayerCache.GetActiveTable()
	return activeSet
end

return PlayerCache
