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
local cachedTeammates
local cachedEnemies
local cachedLocal

FastPlayers.AllUpdated = false
FastPlayers.TeammatesUpdated = false
FastPlayers.EnemiesUpdated = false

--[[ Private: Reset per-tick caches ]]
local function ResetCaches()
	cachedAllPlayers = nil
	cachedTeammates = nil
	cachedEnemies = nil
	cachedLocal = nil
	FastPlayers.AllUpdated = false
	FastPlayers.TeammatesUpdated = false
	FastPlayers.EnemiesUpdated = false
end

--[[ Public API ]]

--- Returns list of valid, non-dormant players once per tick.
---@return WrappedPlayer[]
function FastPlayers.GetAll()
	if FastPlayers.AllUpdated then
		return cachedAllPlayers
	end
	cachedAllPlayers = {}
	local debugMode = G.Menu.Advanced.debug
	for _, ent in pairs(entities.FindByClass("CTFPlayer") or {}) do
		if Common.IsValidPlayer(ent, debugMode, true) then
			local wrapped = WrappedPlayer.FromEntity(ent)
			if wrapped then
				cachedAllPlayers[#cachedAllPlayers + 1] = wrapped
			end
		end
	end
	FastPlayers.AllUpdated = true
	return cachedAllPlayers
end

--- Returns the local player as a WrappedPlayer instance, cached after first wrap.
function FastPlayers.GetLocal()
	-- Return cached local if already wrapped
	if cachedLocal then
		return cachedLocal
	end
	-- Wrap the raw local player entity directly
	local pLocal = entities.GetLocalPlayer()
	local wrapped = pLocal and WrappedPlayer.FromEntity(pLocal) or nil
	cachedLocal = wrapped
	return wrapped
end

--- Returns list of teammates (excluding local), builds cache on first access this tick.
function FastPlayers.GetTeammates()
	if not FastPlayers.TeammatesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end
		cachedTeammates = {}
		local localWrapped = FastPlayers.GetLocal()
		if localWrapped then
			local myTeam = localWrapped:GetTeamNumber()
			for _, wp in ipairs(cachedAllPlayers) do
				if wp ~= localWrapped and wp:GetTeamNumber() == myTeam then
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
			FastPlayers.GetAll()
		end
		cachedEnemies = {}

		local myTeam = FastPlayers.GetLocal():GetTeamNumber()
		for _, wp in ipairs(cachedAllPlayers) do
			if wp ~= localWrapped and wp:GetTeamNumber() ~= myTeam then
				cachedEnemies[#cachedEnemies + 1] = wp
			end
		end
	end
	FastPlayers.EnemiesUpdated = true
	return cachedEnemies
end

--[[ Initialization ]]
-- Reset caches at the start of every CreateMove tick.
callbacks.Register("CreateMove", "FastPlayers_ResetCaches", ResetCaches)

return FastPlayers
