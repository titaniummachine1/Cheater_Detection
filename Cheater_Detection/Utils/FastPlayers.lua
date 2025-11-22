-- fastplayers.lua ─────────────────────────────────────────────────────────
-- FastPlayers: Simplified per-tick cached player lists.
-- Caches self-manage on demand to minimize overhead.

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")
local WrappedPlayer = require("Cheater_Detection.Utils.WrappedPlayer")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")

--[[ Module Declaration ]]
local FastPlayers = {}

--[[ Local Caches ]]
local cachedAllPlayers = {}
local cachedTeammates = {}
local cachedEnemies = {}
local cachedLocal
local activeSteamIDs = {}
local lastEntityIndices = {} -- Track entity indices from last tick

-- Cache State
local lastUpdateTick = -1
local cachedExcludeLocal = nil

FastPlayers.TeammatesUpdated = false
FastPlayers.EnemiesUpdated = false

--[[ Public API ]]

--- Returns list of valid players, updating cache if necessary.
---@param excludelocal boolean? Pass true to exclude local player, false to include
---@return WrappedPlayer[]
function FastPlayers.GetAll(excludelocal)
	local currentTick = globals.TickCount()

	-- Check if cache is outdated or if the exclusion criteria changed
	if currentTick > lastUpdateTick or cachedExcludeLocal ~= excludelocal then
		local excludePlayer = excludelocal and FastPlayers.GetLocal() or nil

		TickProfiler.BeginSection("FP_FindByClass")
		local entities_list = entities.FindByClass("CTFPlayer") or {}
		local entityCount = #entities_list
		TickProfiler.EndSection("FP_FindByClass")

		-- Fast path: If entity count matches and we have cache (and exclusion mode didn't change), assume no change
		-- Note: We only use fast path if exclusion mode matches, otherwise we MUST rebuild
		TickProfiler.BeginSection("FP_CheckChange")
		local lastCount = #lastEntityIndices
		-- We force rebuild if exclusion mode changed because the list content is different
		local exclusionChanged = (cachedExcludeLocal ~= excludelocal)
		local needsRebuild = exclusionChanged
			or (entityCount ~= lastCount)
			or (#cachedAllPlayers == 0)
			or (currentTick > lastUpdateTick)
		TickProfiler.EndSection("FP_CheckChange")

		-- Actually, the logic above is slightly redundant.
		-- If currentTick > lastUpdateTick, we are here.
		-- We should check if we can reuse the PREVIOUS tick's data?
		-- The user wants to avoid "cycling code".
		-- But if it's a new tick, we MUST validate the entities.
		-- However, we can optimize the wrapping part.

		-- Let's simplify: If we are here, we ARE rebuilding the list for this tick.
		-- But we can optimize by checking if the entity list actually changed from the last time we built it.
		-- But since we don't run every tick, "last time" might be 10 ticks ago.

		TickProfiler.BeginSection("FP_Rebuild")

		-- Clear old data
		cachedAllPlayers = {}
		activeSteamIDs = {}
		lastEntityIndices = {}

		-- Build new player list and indices
		for _, ent in pairs(entities_list) do
			local excludeEntity = excludePlayer and excludePlayer.GetRawEntity and excludePlayer:GetRawEntity() or nil
			if Common.IsValidPlayer(ent, nil, false, excludeEntity) then
				local wrapped = WrappedPlayer.FromEntity(ent)
				if wrapped then
					cachedAllPlayers[#cachedAllPlayers + 1] = wrapped
					lastEntityIndices[#lastEntityIndices + 1] = ent:GetIndex()

					local steamID = wrapped:GetSteamID64()
					if steamID then
						activeSteamIDs[steamID] = true
					end
				end
			end
		end

		-- Clean up disconnected players from wrapper pool
		if WrappedPlayer and WrappedPlayer.PruneInactive then
			WrappedPlayer.PruneInactive(currentTick)
		end

		TickProfiler.EndSection("FP_Rebuild")

		-- Update state
		lastUpdateTick = currentTick
		cachedExcludeLocal = excludelocal

		-- Invalidate derived caches
		cachedTeammates = {}
		cachedEnemies = {}
		FastPlayers.TeammatesUpdated = false
		FastPlayers.EnemiesUpdated = false

		-- No periodic trimming - PlayerState persists until player_disconnect event
	end

	return cachedAllPlayers
end

--- Returns the local player as a WrappedPlayer instance.
---@return WrappedPlayer?
function FastPlayers.GetLocal()
	-- Always check validity, but reuse wrapper if possible
	if not cachedLocal or not cachedLocal:IsValid() then
		local rawLocal = entities.GetLocalPlayer()
		cachedLocal = rawLocal and WrappedPlayer.FromEntity(rawLocal) or nil
	else
		-- Ensure the wrapper is up to date for this tick (handled by WrappedPlayer internally usually, but good to be safe)
		-- WrappedPlayer.FromEntity will just return the existing wrapper if valid
		local rawLocal = entities.GetLocalPlayer()
		if rawLocal and rawLocal:GetIndex() ~= cachedLocal:GetIndex() then
			cachedLocal = WrappedPlayer.FromEntity(rawLocal)
		end
	end
	return cachedLocal
end

--- Returns list of teammates, optionally excluding a player (or the local player).
---@param exclude boolean|WrappedPlayer? Pass `true` to exclude the local player, or a WrappedPlayer instance to exclude that specific teammate. Omit/nil to include everyone.
---@return WrappedPlayer[]
function FastPlayers.GetTeammates(exclude)
	-- Ensure main list is up to date
	FastPlayers.GetAll()

	if not FastPlayers.TeammatesUpdated then
		-- cachedTeammates is already cleared in GetAll rebuild

		-- Determine which player (if any) to exclude
		local localPlayer = FastPlayers.GetLocal()
		local excludePlayer = nil
		if exclude == true then
			excludePlayer = localPlayer -- explicitly exclude self
		elseif type(exclude) == "table" then
			excludePlayer = exclude
		end

		-- Use local player's team for filtering
		local myTeam = localPlayer and localPlayer:GetTeamNumber() or nil
		if myTeam then
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetTeamNumber() == myTeam and wp ~= excludePlayer then
					cachedTeammates[#cachedTeammates + 1] = wp
				end
			end
		end

		FastPlayers.TeammatesUpdated = true
	end
	return cachedTeammates
end

--- Returns list of enemies (players on a different team).
---@return WrappedPlayer[]
function FastPlayers.GetEnemies()
	-- Ensure main list is up to date
	FastPlayers.GetAll()

	if not FastPlayers.EnemiesUpdated then
		-- cachedEnemies is already cleared in GetAll rebuild
		local pLocal = FastPlayers.GetLocal()
		if pLocal then
			local myTeam = pLocal:GetTeamNumber()
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetTeamNumber() ~= myTeam then
					cachedEnemies[#cachedEnemies + 1] = wp
				end
			end
		end
		FastPlayers.EnemiesUpdated = true
	end
	return cachedEnemies
end

return FastPlayers
