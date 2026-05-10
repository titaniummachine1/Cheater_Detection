--[[ Core/player_cache.lua
     Single source of truth for all per-player runtime state.
     Replaces separate FastPlayers + PlayerCache split.

     Detector API (CreateMove loop):
       PlayerCache.Get(ply)       → { id, wrap, flags, score, externalChecked, checkFlags, isFriend, history, current }
       PlayerCache.GetByID(id)    → same state table, lookup by steamID64 string

     View API (render / misc path — replaces FastPlayers):
       PlayerCache.GetAll(excludeLocal)  → WrappedPlayer[]
       PlayerCache.GetTeammates()        → WrappedPlayer[]
       PlayerCache.GetEnemies()          → WrappedPlayer[]
       PlayerCache.GetLocal()            → WrappedPlayer
       PlayerCache.GetBySteamID(id)      → WrappedPlayer
       PlayerCache.IsFriend(id)          → bool
]]

local Constants       = require("Cheater_Detection.Core.constants")
local WrappedPlayer   = require("Cheater_Detection.Utils.WrappedPlayer")
local Common          = require("Cheater_Detection.Utils.Common")
local Events          = require("Cheater_Detection.Core.Events")
local G               = require("Cheater_Detection.Utils.Globals")

local PlayerCache     = {}

-- ── Authoritative per-player state ───────────────────────────────────────────

---@type table<string, table>
local activeSet       = {}

-- ── Lazy array views (rebuilt when arrDirty == true) ─────────────────────────

local arrAll          = {}
local arrNoLocal      = {}
local arrTeam         = {}
local arrEnemy        = {}
local arrDirty        = true

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
		-- Filter to only valid, non-dormant players for the view arrays
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
	for i = allN + 1, #arrAll do arrAll[i] = nil end
	for i = noLocalN + 1, #arrNoLocal do arrNoLocal[i] = nil end
	for i = teamN + 1, #arrTeam do arrTeam[i] = nil end
	for i = enemyN + 1, #arrEnemy do arrEnemy[i] = nil end

	arrDirty = false
end

-- ── Score decay constants (replaces Heartbeat periodic decay) ───────────────
-- Rates match original: 2pts per 10s heartbeat for HIGH_RISK, 5pts per 10s for SUSPICIOUS
local SCORE_DECAY_HIGH_RISK  = 0.2 -- points/sec
local SCORE_DECAY_SUSPICIOUS = 0.5 -- points/sec

local HARD_FLAGS             = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.VALVE
local SCORE_DECAY_INTERVAL   = 1.0 -- Decay every 1s

local function isAutoPriorityEnabled()
	if G.Menu and G.Menu.Advanced and G.Menu.Advanced.AutoPriority ~= nil then
		return G.Menu.Advanced.AutoPriority == true
	end
	if G.Menu and G.Menu.Main and G.Menu.Main.AutoPriority ~= nil then
		return G.Menu.Main.AutoPriority == true
	end
	return false
end

local function applyAutoPriority(state, ent)
	if not state or not ent or not ent:IsValid() then
		return
	end
	if not isAutoPriorityEnabled() then
		return
	end

	if (state.flags & HARD_FLAGS) ~= 0 then
		pcall(playerlist.SetPriority, ent, 10)
		state.autoPrioritySusApplied = false
		return
	end

	local isSus = (state.flags & Constants.Flags.SUSPICIOUS) ~= 0
	if isSus then
		if state.autoPrioritySusApplied ~= true then
			local okGet, prio = pcall(playerlist.GetPriority, ent)
			local currentPriority = okGet and type(prio) == "number" and prio or 0
			if currentPriority < 1 then
				pcall(playerlist.SetPriority, ent, 1)
				state.autoPrioritySusApplied = true
			end
		end
	else
		if state.autoPrioritySusApplied == true then
			local okGet, prio = pcall(playerlist.GetPriority, ent)
			local currentPriority = okGet and type(prio) == "number" and prio or 0
			if currentPriority == 1 then
				pcall(playerlist.SetPriority, ent, 0)
			end
			state.autoPrioritySusApplied = false
		end
	end
end

-- ── Detector API ──────────────────────────────────────────────────────────────

local function newCheckFlags()
	return {
		valveID64Checked = false,
		valveSteam2Checked = false,
		valveItemBadgeChecked = false,
		valveGroupChecked = false,
		vacBanChecked = false,
		commBanChecked = false,
		steamHistoryChecked = false,
		profileLookupQueued = false,
	}
end

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
		local initScore = dbEntry and dbEntry.Score or 0

		activeSet[id] = {
			id              = id,
			wrap            = wrap,
			flags           = initFlags,
			score           = initScore,
			externalChecked = false,
			checkFlags      = newCheckFlags(),
			isFriend        = Common.IsFriend and Common.IsFriend(ply, true) or false,
			lastUpdate      = globals.TickCount(),
			lastScoreDecay  = globals.RealTime(),
			autoPrioritySusApplied = false,
		}
		markDirty()

		applyAutoPriority(activeSet[id], ply)
	end

	-- Lazy score decay: apply elapsed-time decay periodically
	local state = activeSet[id]
	if not state.checkFlags then
		state.checkFlags = newCheckFlags()
	end
	local now = globals.RealTime()
	local lastDecay = state.lastScoreDecay or now
	local elapsedSinceDecay = now - lastDecay

	if elapsedSinceDecay >= SCORE_DECAY_INTERVAL and state.score > 0 and (state.flags & Constants.Flags.CHEATER) == 0 then
		local rate = 0
		if (state.flags & Constants.Flags.HIGH_RISK) ~= 0 then
			rate = SCORE_DECAY_HIGH_RISK
		elseif (state.flags & Constants.Flags.SUSPICIOUS) ~= 0 then
			rate = SCORE_DECAY_SUSPICIOUS
		end
		if rate > 0 then
			state.score = math.max(0, state.score - rate * elapsedSinceDecay)
			if state.score < Constants.Threshold.SUSPICIOUS then
				state.flags = (state.flags & ~Constants.Flags.SUSPICIOUS) & ~Constants.Flags.HIGH_RISK
			elseif state.score < Constants.Threshold.HIGH_RISK then
				state.flags = (state.flags | Constants.Flags.SUSPICIOUS) & ~Constants.Flags.HIGH_RISK
			else
				state.flags = state.flags | Constants.Flags.SUSPICIOUS | Constants.Flags.HIGH_RISK
			end
		end
		state.lastScoreDecay = now
		applyAutoPriority(state, ply)
	end

	return state
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
-- Score decay is now lazy (applied in Get() using elapsed RealTime).
-- Invalid player eviction is handled lazily: rebuildArrays() skips invalid
-- entities; Get() returns nil for invalid entities; Remove() handles disconnects.

function PlayerCache.ResetCheckedState()
	for _, state in pairs(activeSet) do
		state.externalChecked = false
		state.itemChecked = false
		state.profileChecked = false
		state.checkFlags = newCheckFlags()
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
	assert(playerState, "PlayerCache priority subscriber: playerState missing")
	assert(playerState.id, "PlayerCache priority subscriber: id missing")
	local wrap = playerState.wrap
	local ent = wrap and wrap:GetRawEntity()
	if not ent or not ent:IsValid() then
		return
	end

	if (playerState.flags & RUNTIME_HARD_FLAGS) ~= 0 then
		pcall(playerlist.SetPriority, ent, 10)
		playerState.autoPrioritySusApplied = false
		return
	end

	applyAutoPriority(playerState, ent)
end)

-- ── Periodic validation (every 1s) ───────────────────────────────────────────
-- Authoritative player list sync: get live players from FindByClass, remove
-- any orphaned entries in activeSet. Catches player rotation leaks that events miss.

local lastValidationTick = 0
local VALIDATION_INTERVAL_TICKS = Constants.SecondsToTicks(1.0)

function PlayerCache.ValidateStates()
	local now = globals.TickCount()
	if now - lastValidationTick < VALIDATION_INTERVAL_TICKS then
		return
	end
	lastValidationTick = now

	-- Memory management: prune inactive wrappers
	if WrappedPlayer.PruneInactive then
		pcall(WrappedPlayer.PruneInactive, now)
	end

	-- Get authoritative list of live players
	local liveEntities = entities.FindByClass("CTFPlayer") or {}
	local liveIDs = {}

	for _, ent in pairs(liveEntities) do
		if ent and ent:IsValid() then
			local steamID = Common.GetSteamID64(ent)
			if steamID then
				liveIDs[tostring(steamID)] = true
			end
		end
	end

	-- Remove any activeSet entries not in the live list
	local toRemove = {}
	for id, state in pairs(activeSet) do
		if not liveIDs[id] then
			toRemove[#toRemove + 1] = id
		end
	end

	for _, id in ipairs(toRemove) do
		activeSet[id] = nil
	end

	if #toRemove > 0 then
		markDirty()
	end
end

-- ── Lifecycle listeners (replaces FastPlayers' EventManager registrations) ────

local function onLifecycleEvent(_event)
	markDirty()
end

Events.Register("FireGameEvent", "PC_PlayerConnect", onLifecycleEvent, "player_connect_client")
Events.Register("FireGameEvent", "PC_PlayerDisconnect", onLifecycleEvent, "player_disconnect")
Events.Register("FireGameEvent", "PC_PlayerTeam", onLifecycleEvent, "player_team")
Events.Register("FireGameEvent", "PC_PlayerSpawn", onLifecycleEvent, "player_spawn")
Events.Register("FireGameEvent", "PC_PlayerDeath", onLifecycleEvent, "player_death")
Events.Register("FireGameEvent", "PC_NewMap", onLifecycleEvent, "game_newmap")
Events.Register("FireGameEvent", "PC_RoundStart", onLifecycleEvent, "teamplay_round_start")

return PlayerCache
