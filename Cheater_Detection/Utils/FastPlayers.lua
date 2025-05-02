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
function FastPlayers.GetAll(excludelocal)
	if FastPlayers.AllUpdated then
		return cachedAllPlayers
	end
	excludelocal = excludelocal and FastPlayers.GetLocal() or nil
	cachedAllPlayers = {}
	local debugMode = G.Menu.Advanced.debug
	for _, ent in pairs(entities.FindByClass("CTFPlayer") or {}) do
		if Common.IsValidPlayer(ent, debugMode, true, excludelocal) then
			local wrapped = WrappedPlayer.FromEntity(ent)
			if wrapped then
				cachedAllPlayers[#cachedAllPlayers + 1] = wrapped
			end
		end
	end
	FastPlayers.AllUpdated = true
	return cachedAllPlayers
end

--- Returns the local player as a CustomPlayer instance, cached after first wrap.
function FastPlayers.GetLocal()
	if not cachedLocal then
		local rawLocal = entities.GetLocalPlayer()
		cachedLocal = rawLocal and WrappedPlayer.FromEntity(rawLocal) or nil
	end
	return cachedLocal
end

--- Returns list of teammates, excluding a specified player or the local player by default.
---@param excludePlayer WrappedPlayer? Optional wrapped instance to exclude (default is local player)
---@return WrappedPlayer[]
function FastPlayers.GetTeammates(excludePlayer)
	if not FastPlayers.TeammatesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end
		cachedTeammates = {}
		-- Default exclusion is the local player
		local exclude = excludePlayer or FastPlayers.GetLocal()
		if exclude then
			local myTeam = exclude:GetTeamNumber()
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetTeamNumber() == myTeam and wp ~= exclude then
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
		cachedEnemies = {}
		local localWrapped = FastPlayers.GetLocal()
		if localWrapped then
			local myTeam = localWrapped:GetTeamNumber()
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
