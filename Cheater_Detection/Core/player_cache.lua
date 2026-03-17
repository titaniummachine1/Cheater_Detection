--[[ Core/player_cache.lua
     Single source of truth for all per-player runtime state.
     Replaces separate FastPlayers + PlayerCache split.

     Detector API (CreateMove loop):
       PlayerCache.Get(ply)       → { id, wrap, flags, score, externalChecked, isFriend, history, current }
       PlayerCache.GetByID(id)    → same state table, lookup by steamID64 string

     View API (render / misc path — replaces FastPlayers):
       PlayerCache.GetAll(excludeLocal)  → WrappedPlayer[]
       PlayerCache.GetTeammates()        → WrappedPlayer[]
       PlayerCache.GetEnemies()          → WrappedPlayer[]
       PlayerCache.GetLocal()            → WrappedPlayer
       PlayerCache.GetBySteamID(id)      → WrappedPlayer
       PlayerCache.IsFriend(id)          → bool
]]

local Constants   = require("Cheater_Detection.Core.constants")
local WrappedPlayer = require("Cheater_Detection.Utils.WrappedPlayer")
local Common      = require("Cheater_Detection.Utils.Common")
local Events      = require("Cheater_Detection.Core.Events")
local G           = require("Cheater_Detection.Utils.Globals")

local PlayerCache = {}

-- ── Authoritative per-player state ───────────────────────────────────────────

---@type table<string, table>
local activeSet = {}

-- ── Lazy array views (rebuilt when arrDirty == true) ─────────────────────────

local arrAll     = {}
local arrNoLocal = {}
local arrTeam    = {}
local arrEnemy   = {}
local arrDirty   = true

local cachedLocal     = nil
local cachedLocalID   = nil
local cachedLocalTeam = nil

local function markDirty()
	arrDirty = true
end

local function refreshLocal()
	local raw = entities.GetLocalPlayer()
	if not raw or not raw:IsValid() then
		cachedLocal     = nil
		cachedLocalID   = nil
		cachedLocalTeam = nil
		return
	end
	cachedLocalTeam = raw:GetTeamNumber()
	if cachedLocal and cachedLocal:GetRawEntity() == raw then
		return
	end
	cachedLocal   = WrappedPlayer.FromEntity(raw)
	cachedLocalID = cachedLocal and tostring(Common.GetSteamID64(raw)) or nil
end

local function rebuildArrays()
	if not arrDirty then
		return
	end
	refreshLocal()

	local allN, noLocalN, teamN, enemyN = 0, 0, 0, 0
	for id, state in pairs(activeSet) do
		local wrap = state.wrap
		local ent  = wrap and wrap:GetRawEntity()
		if wrap and ent and ent:IsValid() and not ent:IsDormant() then
			allN = allN + 1
			arrAll[allN] = wrap

			if id ~= cachedLocalID then
				noLocalN = noLocalN + 1
				arrNoLocal[noLocalN] = wrap
			end

			if cachedLocalTeam then
				local t = ent:GetTeamNumber()
				if t == cachedLocalTeam then
					teamN = teamN + 1
					arrTeam[teamN] = wrap
				else
					enemyN = enemyN + 1
					arrEnemy[enemyN] = wrap
				end
			end
		end
	end

	-- Trim stale tail entries
	for i = allN     + 1, #arrAll     do arrAll[i]     = nil end
	for i = noLocalN + 1, #arrNoLocal do arrNoLocal[i] = nil end
	for i = teamN    + 1, #arrTeam    do arrTeam[i]    = nil end
	for i = enemyN   + 1, #arrEnemy   do arrEnemy[i]   = nil end

	arrDirty = false
end

-- ── Detector API ──────────────────────────────────────────────────────────────

---Get or create active state for a player (CreateMove / detector path)
---@param ply Entity
---@return table|nil
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
		local wrap = WrappedPlayer.FromEntity(ply)
		if not wrap then
			return nil
		end

		local dbEntry   = G.DataBase[id]
		local initFlags = dbEntry and dbEntry.Flags or Constants.Flags.NONE
		local initScore = dbEntry and dbEntry.Score  or 0

		local HARD_FLAGS = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.VALVE
		if (initFlags & HARD_FLAGS) ~= 0 then
			pcall(playerlist.SetPriority, id, 10)
		end

		activeSet[id] = {
			id              = id,
			wrap            = wrap,
			flags           = initFlags,
			score           = initScore,
			externalChecked = false,
			isFriend        = Common.IsFriend and Common.IsFriend(ply, true) or false,
			lastUpdate      = globals.TickCount(),
		}
		markDirty()
	end

	return activeSet[id]
end

---Get state by steamID64 string (HistoryManager / warp_dt path)
---@param id string
---@return table|nil
function PlayerCache.GetByID(id)
	return activeSet[id]
end

---Remove a player from the active set (called on disconnect / heartbeat)
---@param id string
function PlayerCache.Remove(id)
	activeSet[id] = nil
	markDirty()
end

---Return the raw active state table (for central iteration)
function PlayerCache.GetActiveTable()
	return activeSet
end

-- ── Heartbeat / score decay ───────────────────────────────────────────────────

function PlayerCache.Heartbeat()
	for id, state in pairs(activeSet) do
		local ply = state.wrap and state.wrap:GetRawEntity()
		if not ply or not ply:IsValid() then
			activeSet[id] = nil
			markDirty()
		elseif state.score > 0 and (state.flags & Constants.Flags.CHEATER) == 0 then
			if (state.flags & Constants.Flags.HIGH_RISK) ~= 0 then
				state.score = math.max(0, state.score - 2)
			elseif (state.flags & Constants.Flags.SUSPICIOUS) ~= 0 then
				state.score = math.max(0, state.score - 5)
			end

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

function PlayerCache.ResetCheckedState()
	for _, state in pairs(activeSet) do
		state.externalChecked = false
	end
end

function PlayerCache.Cleanup()
	for k in pairs(activeSet) do
		activeSet[k] = nil
	end
	markDirty()
end

-- ── View API (replaces FastPlayers) ──────────────────────────────────────────

---@param excludeLocal boolean?
---@return table  WrappedPlayer[]
function PlayerCache.GetAll(excludeLocal)
	rebuildArrays()
	return excludeLocal and arrNoLocal or arrAll
end

---@return table|nil  WrappedPlayer
function PlayerCache.GetLocal()
	refreshLocal()
	return cachedLocal
end

---@return table  WrappedPlayer[]
function PlayerCache.GetTeammates()
	rebuildArrays()
	return arrTeam
end

---@return table  WrappedPlayer[]
function PlayerCache.GetEnemies()
	rebuildArrays()
	return arrEnemy
end

---@param id string  steamID64 string
---@return table|nil  WrappedPlayer
function PlayerCache.GetBySteamID(id)
	local state = activeSet[tostring(id)]
	return state and state.wrap or nil
end

---@param id string  steamID64 string
---@return boolean
function PlayerCache.IsFriend(id)
	local state = activeSet[tostring(id)]
	return state ~= nil and state.isFriend == true
end

-- ── Priority subscriber ───────────────────────────────────────────────────────

local RUNTIME_HARD_FLAGS = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.VALVE
Events.Subscribe("OnPlayerStateChange", function(playerState, _reason)
	assert(playerState,    "PlayerCache priority subscriber: playerState missing")
	assert(playerState.id, "PlayerCache priority subscriber: id missing")
	if (playerState.flags & RUNTIME_HARD_FLAGS) ~= 0 then
		pcall(playerlist.SetPriority, playerState.id, 10)
	end
end)

-- ── Lifecycle listeners (replaces FastPlayers' EventManager registrations) ────

local function onLifecycleEvent(_event)
	markDirty()
end

Events.Register("FireGameEvent", "PC_PlayerConnect",    onLifecycleEvent, "player_connect_client")
Events.Register("FireGameEvent", "PC_PlayerDisconnect", onLifecycleEvent, "player_disconnect")
Events.Register("FireGameEvent", "PC_PlayerTeam",       onLifecycleEvent, "player_team")
Events.Register("FireGameEvent", "PC_PlayerSpawn",      onLifecycleEvent, "player_spawn")
Events.Register("FireGameEvent", "PC_PlayerDeath",      onLifecycleEvent, "player_death")
Events.Register("FireGameEvent", "PC_NewMap",           onLifecycleEvent, "game_newmap")
Events.Register("FireGameEvent", "PC_RoundStart",       onLifecycleEvent, "teamplay_round_start")

return PlayerCache
