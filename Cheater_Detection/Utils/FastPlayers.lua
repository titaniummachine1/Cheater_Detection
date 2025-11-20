-- fastplayers.lua ─────────────────────────────────────────────────────────
-- FastPlayers: Simplified per-tick cached player lists.
-- On each CreateMove tick, caches reset; lists built on demand.

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

FastPlayers.AllUpdated = false
FastPlayers.TeammatesUpdated = false
FastPlayers.EnemiesUpdated = false

-- Helper to check if entity list changed
local function entityListChanged(currentIndices)
	if #currentIndices ~= #lastEntityIndices then
		return true
	end
	for i = 1, #currentIndices do
		if currentIndices[i] ~= lastEntityIndices[i] then
			return true
		end
	end
	return false
end

--[[ Private: Reset per-tick caches ]]
local function ResetCaches()
	-- Don't clear cachedAllPlayers - we'll only rebuild if entity list changed
	for k in pairs(cachedTeammates) do
		cachedTeammates[k] = nil
	end
	for k in pairs(cachedEnemies) do
		cachedEnemies[k] = nil
	end
	cachedLocal = nil
	FastPlayers.AllUpdated = false
	FastPlayers.TeammatesUpdated = false
	FastPlayers.EnemiesUpdated = false
	if WrappedPlayer and WrappedPlayer.PruneInactive then
		WrappedPlayer.PruneInactive(globals.TickCount())
	end
end

--[[ Public API ]]

--- Returns list of valid players once per tick.
---@param excludelocal boolean? Pass true to exclude local player, false to include
---@return WrappedPlayer[]
function FastPlayers.GetAll(excludelocal)
	if FastPlayers.AllUpdated then
		return cachedAllPlayers
	end

	local excludePlayer = excludelocal and FastPlayers.GetLocal() or nil

	TickProfiler.BeginSection("FP_FindByClass")
	local entities_list = entities.FindByClass("CTFPlayer") or {}
	local entityCount = #entities_list
	TickProfiler.EndSection("FP_FindByClass")

	-- Fast path: If entity count matches and we have cache, assume no change
	-- This saves building the indices table (21KB/tick)
	TickProfiler.BeginSection("FP_CheckChange")
	local lastCount = #lastEntityIndices
	local needsRebuild = (entityCount ~= lastCount) or (#cachedAllPlayers == 0)
	TickProfiler.EndSection("FP_CheckChange")

	if needsRebuild then
		-- Full rebuild path
		TickProfiler.BeginSection("FP_Rebuild")

		-- Clear old data
		for k in pairs(cachedAllPlayers) do
			cachedAllPlayers[k] = nil
		end
		for k in pairs(activeSteamIDs) do
			activeSteamIDs[k] = nil
		end
		for k in pairs(lastEntityIndices) do
			lastEntityIndices[k] = nil
		end

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

		TickProfiler.EndSection("FP_Rebuild")
	else
		-- Cache hit - reuse wrapped players
		TickProfiler.BeginSection("FP_ValidateCache")
		for k in pairs(activeSteamIDs) do
			activeSteamIDs[k] = nil
		end
		for _, wrapped in ipairs(cachedAllPlayers) do
			local steamID = wrapped:GetSteamID64()
			if steamID then
				activeSteamIDs[steamID] = true
			end
		end
		TickProfiler.EndSection("FP_ValidateCache")
	end

	if PlayerState and PlayerState.TrimToActive then
		PlayerState.TrimToActive(activeSteamIDs)
	end
	FastPlayers.AllUpdated = true
	return cachedAllPlayers
end

--- Returns the local player as a WrappedPlayer instance, cached after first wrap.
---@return WrappedPlayer?
function FastPlayers.GetLocal()
	if not cachedLocal then
		local rawLocal = entities.GetLocalPlayer()
		cachedLocal = rawLocal and WrappedPlayer.FromEntity(rawLocal) or nil
	end
	return cachedLocal
end

--- Returns list of teammates, optionally excluding a player (or the local player).
---@param exclude boolean|WrappedPlayer? Pass `true` to exclude the local player, or a WrappedPlayer instance to exclude that specific teammate. Omit/nil to include everyone.
---@return WrappedPlayer[]
function FastPlayers.GetTeammates(exclude)
	if not FastPlayers.TeammatesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end

		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end

		-- cachedTeammates is already cleared in ResetCaches

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
	if not FastPlayers.EnemiesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end
		-- cachedEnemies is already cleared in ResetCaches
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

--[[ Initialization ]]
-- Reset caches at the start of every CreateMove tick.
callbacks.Register("CreateMove", "FastPlayers_ResetCaches", ResetCaches)

return FastPlayers
