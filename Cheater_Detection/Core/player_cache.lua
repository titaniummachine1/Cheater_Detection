--[[ Core/player_cache.lua
     Single source of truth for all per-player runtime state.

     Architecture (Zero-Allocation Proxy Pattern):
       - SyncTick() runs once per tick: single FindByClass, pushes entity map
         to WrappedPlayer upvalue, manages proxy lifecycle.
       - Proxy (WrappedPlayer) is allocated ONCE on player join, freed on disconnect.
       - pdata fields (isAlive, onGround, flags, velocity, etc.) are read directly
         from the entity into the state table once per tick in SyncTick — plain
         table fields, no metatable, no per-tick allocation.
       - PlayerData.GetEntity(pdata) compatibility shim: pdata._index holds the
         entity index so duck_speed can call it without changes.

     Detector API:
       PlayerCache.Get(ply)       → state table (by entity, fallback path)
       PlayerCache.GetByID(id)    → state table (by steamID64 string)
       PlayerCache.GetActiveTable()→ raw activeSet for Main.lua iteration

     View API:
       PlayerCache.GetAll(excludeLocal) → WrappedPlayer[]
       PlayerCache.GetTeammates()       → WrappedPlayer[]
       PlayerCache.GetEnemies()         → WrappedPlayer[]
       PlayerCache.GetLocal()           → WrappedPlayer|nil
       PlayerCache.IsFriend(id)         → bool
]]

local Constants              = require("Cheater_Detection.Core.constants")
local WrappedPlayer          = require("Cheater_Detection.Utils.WrappedPlayer")
local Common                 = require("Cheater_Detection.Utils.Common")
local Events                 = require("Cheater_Detection.Core.Events")
local G                      = require("Cheater_Detection.Utils.Globals")
local DirtySystem            = require("Cheater_Detection.Core.DirtySystem")
local TickEntityCache        = require("Cheater_Detection.Utils.TickEntityCache")

local PlayerCache            = {}

---@type table<string, table>
local activeSet              = {}

local lastSyncTick           = -1

-- Reusable tick-scope tables — cleared in-place, never reallocated
local tickMap                = {}
local seenIDs                = {}

-- ── Score decay ───────────────────────────────────────────────────────────────
local SCORE_DECAY_HIGH_RISK  = 0.2
local SCORE_DECAY_SUSPICIOUS = 0.5
local SCORE_DECAY_INTERVAL   = 1.0
local HARD_FLAGS             = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.VALVE

-- ── Check-flags template (allocated once per new player) ──────────────────────
local function newCheckFlags()
	return {
		valveID64Checked      = false,
		valveSteam2Checked    = false,
		valveItemBadgeChecked = false,
		valveGroupChecked     = false,
		vacBanChecked         = false,
		commBanChecked        = false,
		steamHistoryChecked   = false,
		profileLookupQueued   = false,
	}
end

-- ── Auto-priority helpers ─────────────────────────────────────────────────────
local function isAutoPriorityEnabled()
	return G.Menu and G.Menu.Advanced and G.Menu.Advanced.AutoPriority == true
end

local function getSuspicionThreshold()
	local adv = G.Menu and G.Menu.Advanced
	local pct = adv and adv.SuspicionThreshold
	if pct == nil then
		local notifications = G.Menu and G.Menu.Notifications
		pct = notifications and notifications.SuspicionThreshold
	end
	if type(pct) ~= "number" then
		return Constants.Threshold.SUSPICIOUS
	end
	return math.max(0, math.min(100, pct))
end

local function applyAutoPriority(state, ent)
	if not state or not ent then return end
	if not isAutoPriorityEnabled() then return end

	if (state.flags & HARD_FLAGS) ~= 0 then
		pcall(playerlist.SetPriority, ent, 10)
		state.autoPrioritySusApplied = false
		return
	end

	local isSus = (state.flags & Constants.Flags.SUSPICIOUS) ~= 0
	if isSus then
		if not state.autoPrioritySusApplied then
			local ok, prio = pcall(playerlist.GetPriority, ent)
			if ok and type(prio) == "number" and prio < 1 then
				pcall(playerlist.SetPriority, ent, 1)
				state.autoPrioritySusApplied = true
			end
		end
	elseif state.autoPrioritySusApplied then
		local ok, prio = pcall(playerlist.GetPriority, ent)
		if ok and type(prio) == "number" and prio == 1 then
			pcall(playerlist.SetPriority, ent, 0)
		end
		state.autoPrioritySusApplied = false
	end
end

-- ── View arrays (rebuilt when membership changes) ─────────────────────────────
local arrAll          = {}
local arrNoLocal      = {}
local arrTeam         = {}
local arrEnemy        = {}
local arrDirty        = true

local cachedLocal     = nil
local cachedLocalID   = nil
local cachedLocalTeam = nil

local function rebuildArrays()
	if not arrDirty then return end

	local raw = entities.GetLocalPlayer()
	if raw and raw:IsValid() then
		cachedLocalTeam = raw:GetTeamNumber()
		local lid = tostring(Common.GetSteamID64(raw))
		if lid ~= cachedLocalID then
			cachedLocalID = lid
			cachedLocal   = activeSet[lid] and activeSet[lid].wrap or nil
		end
	else
		cachedLocal, cachedLocalID, cachedLocalTeam = nil, nil, nil
	end

	local allN, noLocalN, teamN, enemyN = 0, 0, 0, 0
	for id, state in pairs(activeSet) do
		local wrap = state.wrap
		if wrap and not state.pdata.isDormant then
			allN = allN + 1
			arrAll[allN] = wrap

			if id ~= cachedLocalID then
				noLocalN = noLocalN + 1
				arrNoLocal[noLocalN] = wrap
			end

			if cachedLocalTeam then
				local t = state.pdata._teamNum
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

	for i = allN + 1, #arrAll do arrAll[i] = nil end
	for i = noLocalN + 1, #arrNoLocal do arrNoLocal[i] = nil end
	for i = teamN + 1, #arrTeam do arrTeam[i] = nil end
	for i = enemyN + 1, #arrEnemy do arrEnemy[i] = nil end

	arrDirty = false
end

-- ── Core sync ─────────────────────────────────────────────────────────────────

function PlayerCache.SyncTick()
	local curTick = globals.TickCount()
	if curTick == lastSyncTick then return end
	lastSyncTick = curTick

	local liveEnts = entities.FindByClass("CTFPlayer") or {}

	-- Clear reusable tables in-place (no reallocation)
	for k in pairs(tickMap) do tickMap[k] = nil end
	for k in pairs(seenIDs) do seenIDs[k] = nil end

	local now        = globals.RealTime()
	local anyNew     = false
	local anyRemoved = false

	-- Single pass: build tickMap + process state simultaneously
	for i = 1, #liveEnts do
		local ent = liveEnts[i]
		if not ent then goto nextEnt end

		tickMap[ent:GetIndex()] = ent

		local steamID = Common.GetSteamID64(ent)
		if not steamID then goto nextEnt end
		local id = tostring(steamID)
		seenIDs[id] = true

		local state = activeSet[id]
		if not state then
			-- New player — allocate proxy once
			local info       = client.GetPlayerInfo(ent:GetIndex())
			local steam3     = info and info.SteamID or ""
			local name       = info and info.Name or id
			local dbEntry    = G.Database and G.Database.GetCheater(id) or nil
			local initFlags  = dbEntry and dbEntry.Flags or Constants.Flags.NONE
			local initScore  = dbEntry and dbEntry.Score or 0

			local proxy      = WrappedPlayer.New(ent:GetIndex(), id, steam3, name)

			-- Minimal pdata shim — plain table, no metatable
			-- Holds current-tick property snapshot + _index for PlayerData.GetEntity compat
			local pdata      = {
				_index     = ent:GetIndex(),
				isAlive    = ent:IsAlive(),
				isDormant  = ent:IsDormant(),
				onGround   = false,
				flags      = 0,
				velocity   = nil,
				viewOffset = nil,
				simTime    = nil,
				_teamNum   = ent:GetTeamNumber(),
			}
			local mfFlags    = ent:GetPropInt("m_fFlags") or 0
			pdata.flags      = mfFlags
			pdata.onGround   = (mfFlags & 1) ~= 0
			pdata.velocity   = ent:EstimateAbsVelocity()
			pdata.viewOffset = ent:GetPropVector("localdata", "m_vecViewOffset[0]")
			pdata.simTime    = ent:GetPropFloat("m_flSimulationTime")

			state            = {
				id                     = id,
				entityIndex            = ent:GetIndex(),
				pdata                  = pdata,
				wrap                   = proxy,
				flags                  = initFlags,
				score                  = initScore,
				externalChecked        = false,
				checkFlags             = newCheckFlags(),
				isFriend               = Common.IsFriend and Common.IsFriend(ent, true) or false,
				lastUpdate             = curTick,
				lastScoreDecay         = now,
				autoPrioritySusApplied = false,
				wasDormant             = ent:IsDormant(),
			}
			activeSet[id]    = state
			anyNew           = true
			DirtySystem.MarkDirty(id, "connected")
			DirtySystem.MarkDirty(id, "score")
			DirtySystem.MarkDirty(id, "flags")
			DirtySystem.MarkDirty(id, "checks")
			applyAutoPriority(state, ent)
		else
			-- Existing player — minimal refresh, most properties are lazy-cached via wrap
			local pdata      = state.pdata
			pdata._index     = ent:GetIndex()

			-- Only read simTime to detect if player moved (for lazy Vector3 prop updates)
			local newSimTime = ent:GetPropFloat("m_flSimulationTime")
			if newSimTime ~= pdata.simTime then
				-- Player moved: update cached timestamp (actual props fetched lazily via wrap)
				pdata.simTime = newSimTime
			end

			-- Update proxy slot index (handles reconnect/team switch)
			state.wrap.index  = ent:GetIndex()
			state.entityIndex = ent:GetIndex()
			state.lastUpdate  = curTick

			-- Refresh lazy state flags for detectors that check before wrap access
			pdata.isAlive     = ent:IsAlive()
			pdata.isDormant   = ent:IsDormant()

			-- Lazy score decay
			if state.score > 0 and (state.flags & Constants.Flags.CHEATER) == 0 and not state.hasActiveEvidence then
				local elapsed = now - (state.lastScoreDecay or now)
				if elapsed >= SCORE_DECAY_INTERVAL then
					local rate = 0
					if (state.flags & Constants.Flags.HIGH_RISK) ~= 0 then
						rate = SCORE_DECAY_HIGH_RISK
					elseif (state.flags & Constants.Flags.SUSPICIOUS) ~= 0 then
						rate = SCORE_DECAY_SUSPICIOUS
					end
					if rate > 0 then
						local prevScore = state.score
						local prevFlags = state.flags
						state.score = math.max(0, state.score - rate * elapsed)
						local susThreshold = getSuspicionThreshold()
						if state.score < susThreshold then
							state.flags = (state.flags & ~Constants.Flags.SUSPICIOUS) & ~Constants.Flags.HIGH_RISK
						elseif state.score < Constants.Threshold.HIGH_RISK then
							state.flags = (state.flags | Constants.Flags.SUSPICIOUS) & ~Constants.Flags.HIGH_RISK
						else
							state.flags = state.flags | Constants.Flags.SUSPICIOUS | Constants.Flags.HIGH_RISK
						end
						if state.score ~= prevScore then
							DirtySystem.MarkDirty(id, "score")
						end
						if state.flags ~= prevFlags then
							DirtySystem.MarkDirty(id, "flags")
						end
					end
					state.lastScoreDecay = now
				end
			end
		end

		::nextEnt::
	end

	-- Push completed map to WrappedPlayer upvalue and legacy cache
	WrappedPlayer._SetTickEntities(tickMap)
	TickEntityCache.RefreshFromTickMap(curTick, tickMap)

	-- Prune disconnected players
	for id in pairs(activeSet) do
		if not seenIDs[id] then
			Events.Publish("OnPlayerRemoved", id, "missing_from_findbyclass")
			activeSet[id] = nil
			anyRemoved = true
		end
	end

	if anyNew or anyRemoved then
		arrDirty = true
	end
end

-- ── Fallback Get() by entity (Main.lua hot loop uses GetActiveTable directly) ─

---@param ply Entity
---@return table|nil
function PlayerCache.Get(ply)
	if not ply or not ply:IsValid() then return nil end
	local steamID = Common.GetSteamID64(ply)
	if not steamID then return nil end
	return activeSet[tostring(steamID)]
end

---@param id string
---@return table|nil
function PlayerCache.GetByID(id)
	return activeSet[id]
end

---@param id string
function PlayerCache.Remove(id, reason)
	local key = tostring(id)
	DirtySystem.MarkDirty(key, "disconnected")
	Events.Publish("OnPlayerRemoved", key, reason or "explicit_remove")
	activeSet[key] = nil
	arrDirty = true
end

function PlayerCache.GetActiveTable()
	return activeSet
end

function PlayerCache.ResetCheckedState()
	for _, state in pairs(activeSet) do
		state.externalChecked = false
		state.itemChecked     = false
		state.profileChecked  = false
		state.checkFlags      = newCheckFlags()
	end
end

function PlayerCache.Cleanup()
	for k in pairs(activeSet) do activeSet[k] = nil end
	arrDirty = true
end

-- ── View API ──────────────────────────────────────────────────────────────────

---@param excludeLocal boolean?
---@return table
function PlayerCache.GetAll(excludeLocal)
	rebuildArrays()
	return excludeLocal and arrNoLocal or arrAll
end

---@return table|nil
function PlayerCache.GetLocal()
	local raw = entities.GetLocalPlayer()
	if not raw or not raw:IsValid() then return nil end
	local id = tostring(Common.GetSteamID64(raw))
	return activeSet[id] and activeSet[id].wrap or nil
end

---@return string|nil
function PlayerCache.GetLocalID()
	return cachedLocalID
end

---@return table
function PlayerCache.GetTeammates()
	rebuildArrays()
	return arrTeam
end

---@return table
function PlayerCache.GetEnemies()
	rebuildArrays()
	return arrEnemy
end

---@param id string
---@return boolean
function PlayerCache.IsFriend(id)
	local state = activeSet[tostring(id)]
	return state ~= nil and state.isFriend == true
end

---@param id string
---@return number|nil
function PlayerCache.GetEntityIndex(id)
	local state = activeSet[tostring(id)]
	return state and state.entityIndex or nil
end

-- ── Priority subscriber ───────────────────────────────────────────────────────

local RUNTIME_HARD_FLAGS = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.VALVE
Events.Subscribe("OnPlayerStateChange", function(playerState, _reason)
	if not playerState or not playerState.id then return end
	local ent = playerState.wrap and playerState.wrap:GetRawEntity()
	if not ent or not ent:IsValid() then return end
	if (playerState.flags & RUNTIME_HARD_FLAGS) ~= 0 then
		pcall(playerlist.SetPriority, ent, 10)
		playerState.autoPrioritySusApplied = false
		return
	end
	applyAutoPriority(playerState, ent)
end)

-- ── ValidateStates: kept as no-op stub (SyncTick handles eviction) ────────────
function PlayerCache.ValidateStates() end

-- ── Lifecycle dirty-marking (keeps view arrays fresh) ────────────────────────
local function onLifecycleEvent(_event) arrDirty = true end

local function onPlayerSpawnOrClassChange(event)
	arrDirty = true
	local uid = event:GetInt("userid")
	if not uid then return end
	local ent = entities.GetByUserID(uid)
	if not ent or not ent:IsValid() then return end
	local steamID = Common.GetSteamID64(ent)
	if not steamID then return end
	local state = activeSet[tostring(steamID)]
	if state then
		state.wearablesScanned = nil
	end
end

local function onNewMapOrRoundStart()
	arrDirty = true
	for _, state in pairs(activeSet) do
		state.wearablesScanned = nil
	end
end

Events.Register("FireGameEvent", "PC_PlayerConnect", onLifecycleEvent, "player_connect_client")
Events.Register("FireGameEvent", "PC_PlayerDisconnect", onLifecycleEvent, "player_disconnect")
Events.Register("FireGameEvent", "PC_PlayerTeam", onLifecycleEvent, "player_team")
Events.Register("FireGameEvent", "PC_PlayerSpawn", onPlayerSpawnOrClassChange, "player_spawn")
Events.Register("FireGameEvent", "PC_PlayerChangeClass", onPlayerSpawnOrClassChange, "player_changeclass")
Events.Register("FireGameEvent", "PC_PlayerDeath", onLifecycleEvent, "player_death")
Events.Register("FireGameEvent", "PC_NewMap", onNewMapOrRoundStart, "game_newmap")
Events.Register("FireGameEvent", "PC_RoundStart", onNewMapOrRoundStart, "teamplay_round_start")

return PlayerCache
