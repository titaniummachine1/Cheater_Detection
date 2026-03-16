--[[ FastPlayers — event-driven player cache with per-tick validation ]]

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")
local WrappedPlayer = require("Cheater_Detection.Utils.WrappedPlayer")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")
local EventManager = require("Cheater_Detection.Utils.EventManager")

local FastPlayers = {}

--[[ Primary store: SteamID64 → WrappedPlayer ]]
local playersBySteam = {}
local friendsBySteam = {}

--[[ Derived arrays — rebuilt lazily from playersBySteam ]]
local arrayAll = {}
local arrayAllNoLocal = {}
local arrayTeammates = {}
local arrayEnemies = {}

local cachedLocal = nil
local cachedLocalSteam = nil
local cachedLocalTeam = nil

local dirty = true
local derivedDirty = true
local validateTick = -1

local function markDirty()
	dirty = true
	derivedDirty = true
end

local function isEntityPlayable(ent)
	return ent and ent:IsValid() and ent:IsAlive() and not ent:IsDormant()
end

local function refreshLocal()
	local raw = entities.GetLocalPlayer()
	if not raw or not raw:IsValid() then
		cachedLocal = nil
		cachedLocalSteam = nil
		cachedLocalTeam = nil
		return
	end

	if cachedLocal and cachedLocal._rawEntity == raw then
		cachedLocalTeam = raw:GetTeamNumber()
		return
	end

	cachedLocal = WrappedPlayer.FromEntity(raw)
	if cachedLocal then
		cachedLocalSteam = cachedLocal:GetSteamID64()
		cachedLocalTeam = raw:GetTeamNumber()
	else
		cachedLocalSteam = nil
		cachedLocalTeam = nil
	end
end

local function fullRebuild()
	TickProfiler.BeginSection("FP_FullRebuild")

	refreshLocal()

	local oldPlayers = playersBySteam
	playersBySteam = {}
	friendsBySteam = {}

	local entList = entities.FindByClass("CTFPlayer") or {}
	for _, ent in pairs(entList) do
		if ent and ent:IsValid() and not ent:IsDormant() then
			local steamID = Common.GetSteamID64(ent)
			if steamID and Common.IsSteamID64(steamID) then
				local steamStr = tostring(steamID)
				local wrapped = oldPlayers[steamStr]
				if wrapped then
					wrapped._rawEntity = ent
					wrapped._lastSeenTick = globals.TickCount()
				else
					wrapped = WrappedPlayer.FromEntity(ent)
				end

				if wrapped then
					playersBySteam[steamStr] = wrapped
					PlayerState.AttachWrappedPlayer(wrapped)

					local isFriend = Common.IsFriend(ent, true)
					if isFriend then
						friendsBySteam[steamStr] = true
					end
				end
			end
		end
	end

	WrappedPlayer.PruneInactive(globals.TickCount())

	dirty = false
	derivedDirty = true
	TickProfiler.EndSection("FP_FullRebuild")
end

local function validateExisting()
	local currentTick = globals.TickCount()
	if validateTick == currentTick then
		return
	end
	validateTick = currentTick

	TickProfiler.BeginSection("FP_Validate")

	refreshLocal()

	local removals = nil
	for steamStr, wrapped in pairs(playersBySteam) do
		local ent = wrapped._rawEntity
		if not isEntityPlayable(ent) then
			if not removals then
				removals = {}
			end
			removals[#removals + 1] = steamStr
		end
	end

	if removals then
		for i = 1, #removals do
			playersBySteam[removals[i]] = nil
			friendsBySteam[removals[i]] = nil
		end
		derivedDirty = true
	end

	TickProfiler.EndSection("FP_Validate")
end

local function rebuildDerived()
	if not derivedDirty then
		return
	end

	TickProfiler.BeginSection("FP_RebuildDerived")

	local allIdx = 0
	local allNoLocalIdx = 0
	local teamIdx = 0
	local enemyIdx = 0

	for steamStr, wrapped in pairs(playersBySteam) do
		allIdx = allIdx + 1
		arrayAll[allIdx] = wrapped

		if steamStr ~= tostring(cachedLocalSteam) then
			allNoLocalIdx = allNoLocalIdx + 1
			arrayAllNoLocal[allNoLocalIdx] = wrapped
		end

		if cachedLocalTeam then
			local ent = wrapped._rawEntity
			if ent and ent:IsValid() then
				local team = ent:GetTeamNumber()
				if team == cachedLocalTeam then
					teamIdx = teamIdx + 1
					arrayTeammates[teamIdx] = wrapped
				else
					enemyIdx = enemyIdx + 1
					arrayEnemies[enemyIdx] = wrapped
				end
			end
		end
	end

	for i = allIdx + 1, #arrayAll do
		arrayAll[i] = nil
	end
	for i = allNoLocalIdx + 1, #arrayAllNoLocal do
		arrayAllNoLocal[i] = nil
	end
	for i = teamIdx + 1, #arrayTeammates do
		arrayTeammates[i] = nil
	end
	for i = enemyIdx + 1, #arrayEnemies do
		arrayEnemies[i] = nil
	end

	derivedDirty = false
	TickProfiler.EndSection("FP_RebuildDerived")
end

local function ensureValid()
	if dirty then
		fullRebuild()
	end
	validateExisting()
	rebuildDerived()
end

---@param excludelocal boolean?
---@return WrappedPlayer[]
function FastPlayers.GetAll(excludelocal)
	ensureValid()
	if excludelocal then
		return arrayAllNoLocal
	end
	return arrayAll
end

---@return WrappedPlayer?
function FastPlayers.GetLocal()
	refreshLocal()
	return cachedLocal
end

---@param exclude boolean|WrappedPlayer?
---@return WrappedPlayer[]
function FastPlayers.GetTeammates(exclude)
	ensureValid()

	if exclude == true and cachedLocal then
		local filtered = {}
		local n = 0
		for i = 1, #arrayTeammates do
			if arrayTeammates[i] ~= cachedLocal then
				n = n + 1
				filtered[n] = arrayTeammates[i]
			end
		end
		return filtered
	elseif type(exclude) == "table" then
		local filtered = {}
		local n = 0
		for i = 1, #arrayTeammates do
			if arrayTeammates[i] ~= exclude then
				n = n + 1
				filtered[n] = arrayTeammates[i]
			end
		end
		return filtered
	end

	return arrayTeammates
end

---@return WrappedPlayer[]
function FastPlayers.GetEnemies()
	ensureValid()
	return arrayEnemies
end

---@param steamID string
---@return WrappedPlayer?
function FastPlayers.GetBySteamID(steamID)
	return playersBySteam[tostring(steamID)]
end

---@param steamID string
---@return boolean
function FastPlayers.IsFriend(steamID)
	return friendsBySteam[tostring(steamID)] == true
end

function FastPlayers.ForceRebuild()
	markDirty()
end

--[[ Event handlers — only these trigger full rebuilds ]]

local function onPlayerLifecycleEvent(event)
	markDirty()
end

EventManager.Register("FireGameEvent", "FP_PlayerConnect", onPlayerLifecycleEvent, "player_connect_client")
EventManager.Register("FireGameEvent", "FP_PlayerDisconnect", onPlayerLifecycleEvent, "player_disconnect")
EventManager.Register("FireGameEvent", "FP_PlayerTeam", onPlayerLifecycleEvent, "player_team")
EventManager.Register("FireGameEvent", "FP_PlayerSpawn", onPlayerLifecycleEvent, "player_spawn")
EventManager.Register("FireGameEvent", "FP_PlayerDeath", onPlayerLifecycleEvent, "player_death")
EventManager.Register("FireGameEvent", "FP_NewMap", onPlayerLifecycleEvent, "game_newmap")
EventManager.Register("FireGameEvent", "FP_RoundStart", onPlayerLifecycleEvent, "teamplay_round_start")

return FastPlayers
