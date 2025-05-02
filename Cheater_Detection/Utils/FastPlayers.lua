-- fastplayers.lua ─────────────────────────────────────────────────────────
-- FastPlayers: Simplified per-tick cached player lists.
-- On each CreateMove tick, caches reset; lists built on demand.

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local WrappedPlayer = require("Cheater_Detection.Utils.WrappedPlayer")

--[[ Module Declaration ]]
local FastPlayers = {}

--[[ Local Caches ]]
local cachedAllPlayers
local cachedAllMap
local cachedTeammates
local cachedEnemies
local lastAllExcludeFlag

FastPlayers.AllUpdated = false
FastPlayers.TeammatesUpdated = false
FastPlayers.EnemiesUpdated = false

--[[ Private: Reset per-tick caches ]]
local function ResetCaches()
	cachedAllPlayers = nil
	cachedAllMap = nil
	cachedTeammates = nil
	cachedEnemies = nil
	FastPlayers.AllUpdated = false
	FastPlayers.TeammatesUpdated = false
	FastPlayers.EnemiesUpdated = false
	lastAllExcludeFlag = nil
end

--[[ Public API ]]

--- Returns list of valid players, builds cache on first access this tick or when excludeLocal changes.
---@param excludeLocal boolean? Exclude the local player if true.
---@return WrappedPlayer[]
function FastPlayers.GetAll(excludeLocal)
	excludeLocal = excludeLocal and true or false
	local rawLocal = entities.GetLocalPlayer()
	local localIndex = rawLocal and rawLocal:GetIndex() or -1
	-- Rebuild if first access this tick or excludeLocal toggled
	if not FastPlayers.AllUpdated or excludeLocal ~= lastAllExcludeFlag then
		local players, map = {}, {}
		local debugMode = G.Menu.Advanced.debug
		for _, ent in pairs(entities.FindByClass("CTFPlayer") or {}) do
			if Common.IsValidPlayer(ent, debugMode, true) then
				local wrapped = WrappedPlayer.FromEntity(ent)
				if wrapped then
					players[#players + 1] = wrapped
					map[idx] = wrapped
				end
			end
		end
		cachedAllPlayers = players
		cachedAllMap = map
		FastPlayers.AllUpdated = true
		lastAllExcludeFlag = excludeLocal
	end
	return cachedAllPlayers
end

--- Returns map of entityIndex->WrappedPlayer, ensures cache
function FastPlayers.GetIndexMap()
	if not FastPlayers.AllUpdated then
		FastPlayers.GetAll(false)
	end
	return cachedAllMap
end

--- Returns single WrappedPlayer by index, ensures cache
function FastPlayers.GetByIndex(index)
	if not FastPlayers.AllUpdated then
		FastPlayers.GetAll(false)
	end
	return cachedAllMap and cachedAllMap[index] or nil
end

--- Returns the local player WrappedPlayer, ensures cache
function FastPlayers.GetLocal()
	local rawLocal = entities.GetLocalPlayer()
	local idx = rawLocal and rawLocal:GetIndex() or -1
	return FastPlayers.GetByIndex(idx)
end

--- Returns list of teammates (excluding local), builds cache on first access this tick.
function FastPlayers.GetTeammates()
	if not FastPlayers.TeammatesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll(false)
		end
		cachedTeammates = {}
		local localWrapped = FastPlayers.GetLocal()
		if localWrapped then
			local myTeam = localWrapped:GetTeamNumber()
			local localIndex = localWrapped:GetIndex()
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetIndex() ~= localIndex and wp:GetTeamNumber() == myTeam then
					cachedTeammates[#cachedTeammates + 1] = wp
				end
			end
		end
		FastPlayers.TeammatesUpdated = true
	end
	return cachedTeammates
end

--- Returns list of enemies (excluding local), builds cache on first access this tick.
function FastPlayers.GetEnemies()
	if not FastPlayers.EnemiesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll(false)
		end
		cachedEnemies = {}
		local localWrapped = FastPlayers.GetLocal()
		if localWrapped then
			local myTeam = localWrapped:GetTeamNumber()
			local localIndex = localWrapped:GetIndex()
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetIndex() ~= localIndex and wp:GetTeamNumber() ~= myTeam then
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
