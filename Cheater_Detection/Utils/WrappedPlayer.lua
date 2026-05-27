--[[ WrappedPlayer.lua
     Persistent proxy per player. Allocated once on join, freed on disconnect.
     All engine method calls resolve through activeTickEntities — a file-level
     upvalue that PlayerCache overwrites at the top of every tick via
     WrappedPlayer._SetTickEntities(). No per-tick table allocations.
]]
---@diagnostic disable: undefined-global, undefined-field

local Common             = require("Cheater_Detection.Utils.Common")
local PlayerCache        = require("Cheater_Detection.Core.player_cache")

---@class WrappedPlayer
---@field index number
---@field _steamID64 string
---@field _steamID3 string
---@field _name string
---@field _chargeDataCache table
---@field _cache table
---@field _cacheTick number
local WrappedPlayer      = {}
local WrappedPlayerMT    = {
	__index = function(self, key)
		-- Check explicit methods first
		local method = WrappedPlayer[key]
		if method then return method end
		-- Fall back to raw entity method (for rare/uncommon properties)
		local ent = activeTickEntities[self.index]
		if ent and ent[key] then
			return function(_, ...)
				return ent[key](ent, ...)
			end
		end
		return nil
	end
}

local _currentCacheTick  = -1

local Vec3               = Vector3
local BONE_MASK_HITBOX   = 0x7ff00
local localPlayerIndex   = client.GetLocalPlayerIndex

-- The volatile tick map: [entityIndex] = raw_entity
-- Replaced wholesale by PlayerCache.SyncTick every tick.
local activeTickEntities = {}

--- Called by PlayerCache.SyncTick at the start of every tick.
--- Replaces the upvalue pointer — zero allocation, zero iteration.
function WrappedPlayer._SetTickEntities(map)
	activeTickEntities = map
end

--- Allocate one proxy per player on join. Never call inside the hot loop.
---@param entIndex number
---@param steamID64 string
---@param steamID3 string
---@param name string
---@return WrappedPlayer
function WrappedPlayer.New(entIndex, steamID64, steamID3, name)
	local self            = setmetatable({}, WrappedPlayerMT)
	self.index            = entIndex
	self._steamID64       = steamID64
	self._steamID3        = steamID3
	self._name            = name
	self._chargeDataCache = { ChargeBegin = 0, ChargedDamage = 0 }
	self._cache           = {} -- Lazy property cache: [key] = value
	self._cacheTick       = -1 -- Tick when cache was last cleared
	return self
end

---Internal: ensure cache is fresh for current tick, then return/get cache value
---@param key string Cache key
---@param fetchFn function Function to call if cache miss
---@return any
function WrappedPlayer:_getCached(key, fetchFn)
	local curTick = globals.TickCount()
	if curTick ~= self._cacheTick then
		-- New tick: clear cache
		self._cache = {}
		self._cacheTick = curTick
	end
	local cached = self._cache[key]
	if cached ~= nil or self._cache[key] ~= nil then
		return cached
	end
	local value = fetchFn()
	self._cache[key] = value
	return value
end

--- Returns the entity for this proxy if it is present this tick.
---@return Entity|nil
function WrappedPlayer:GetRawEntity()
	return activeTickEntities[self.index]
end

--- Returns the display name. Cached on join; only queries engine when name is missing.
---@return string|nil
function WrappedPlayer:GetName()
	if self._name and self._name ~= "" then
		return self._name
	end
	local info = client.GetPlayerInfo(self.index)
	if info and info.Name and info.Name ~= "" then
		self._name = info.Name
	end
	return self._name
end

function WrappedPlayer:GetIndex()
	return self.index
end

function WrappedPlayer:GetSteamID64()
	return self._steamID64
end

function WrappedPlayer:GetSteamID3()
	return self._steamID3
end

function WrappedPlayer:IsValid()
	return activeTickEntities[self.index] ~= nil
end

function WrappedPlayer:IsAlive()
	return self:_getCached("isAlive", function()
		-- m_lifeState: 0=alive, 1=dying, 2=dead, 3=respawnable
		return entities.GetPlayer(self.index):GetPropInt("m_lifeState") == 0
	end)
end

function WrappedPlayer:IsDormant()
	return self:_getCached("isDormant", function()
		return entities.GetPlayer(self.index):IsDormant()
	end)
end

function WrappedPlayer:IsOnGround()
	return self:_getCached("isOnGround", function()
		return (entities.GetPlayer(self.index):GetPropInt("m_fFlags") & FL_ONGROUND) ~= 0
	end)
end

function WrappedPlayer:IsFriend(includeParty)
	return self:_getCached("isFriend_" .. tostring(includeParty), function()
		return Common.IsFriend(entities.GetPlayer(self.index), includeParty)
	end)
end

function WrappedPlayer:IsValidPlayer(checkFriend, checkDormant, skipEntity)
	return Common.IsValidPlayer(entities.GetPlayer(self.index), checkFriend, checkDormant, skipEntity)
end

function WrappedPlayer:IsEnemyOf(other)
	if not other or type(other.GetTeamNumber) ~= "function" then return false end
	local myTeam = entities.GetPlayer(self.index):GetTeamNumber()
	return myTeam ~= 0 and myTeam ~= other:GetTeamNumber()
end

function WrappedPlayer:GetTeamNumber()
	return self:_getCached("teamNumber", function()
		return entities.GetPlayer(self.index):GetTeamNumber()
	end)
end

function WrappedPlayer:GetAbsOrigin()
	return self:_getCached("absOrigin", function()
		return entities.GetPlayer(self.index):GetAbsOrigin()
	end)
end

function WrappedPlayer:GetVelocity()
	return self:_getCached("velocity", function()
		return entities.GetPlayer(self.index):EstimateAbsVelocity()
	end)
end

function WrappedPlayer:GetViewOffset()
	return self:_getCached("viewOffset", function()
		return entities.GetPlayer(self.index):GetPropVector("localdata", "m_vecViewOffset[0]")
	end)
end

function WrappedPlayer:GetEyePos()
	return self:_getCached("eyePos", function()
		return self:GetAbsOrigin() + self:GetViewOffset()
	end)
end

function WrappedPlayer:GetEyeAngles()
	return self:_getCached("eyeAngles", function()
		if self.index == localPlayerIndex() then
			return engine.GetViewAngles()
		end
		local a = entities.GetPlayer(self.index):GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
		return EulerAngles(a.x, a.y, a.z)
	end)
end

function WrappedPlayer:GetSimulationTime()
	return self:_getCached("simTime", function()
		return entities.GetPlayer(self.index):GetPropFloat("m_flSimulationTime")
	end)
end

function WrappedPlayer:GetHitboxPos(hitboxIndex)
	local hitbox = entities.GetPlayer(self.index):GetHitboxes()[hitboxIndex]
	if not hitbox then return nil end
	return (hitbox[1] + hitbox[2]) * 0.5
end

function WrappedPlayer:GetLookPos()
	local eyePos = self:GetEyePos()
	local trace = engine.TraceLine(eyePos, eyePos + self:GetEyeAngles():Forward() * 8192, MASK_SHOT)
	return trace.endpos
end

function WrappedPlayer:GetActiveWeapon()
	return entities.GetPlayer(self.index):GetPropEntity("m_hActiveWeapon")
end

function WrappedPlayer:GetActiveWeaponID()
	local wpn = self:GetActiveWeapon()
	return wpn and wpn:GetWeaponID()
end

function WrappedPlayer:GetWeaponChargeData()
	local weapon = self:GetActiveWeapon()
	if not weapon then return nil end
	local cache         = self._chargeDataCache
	cache.ChargeBegin   = weapon.GetChargeBeginTime and weapon:GetChargeBeginTime() or 0
	cache.ChargedDamage = weapon.GetChargedDamage and weapon:GetChargedDamage() or 0
	return cache
end

function WrappedPlayer:GetObserverMode()
	return entities.GetPlayer(self.index):GetPropInt("m_iObserverMode")
end

function WrappedPlayer:GetObserverTarget()
	local target = entities.GetPlayer(self.index):GetPropEntity("m_hObserverTarget")
	if not target then return nil end
	local sid64 = Common.GetSteamID64(target)
	if not sid64 then return nil end
	local state = PlayerCache.GetByID(tostring(sid64))
	return state and state.wrap
end

function WrappedPlayer:GetNextAttack()
	return entities.GetPlayer(self.index):GetPropFloat("m_flNextAttack")
end

-- GetPropInt, GetPropFloat, GetPropVector, GetPropBool, GetPropEntity
-- GetClass, GetMins, GetMaxs are handled by metatable __index forwarding

function WrappedPlayer:SetPriority(level)
	if not level then return false end
	playerlist.SetPriority(entities.GetPlayer(self.index), level)
	return true
end

--- No-op kept for call-site compatibility.
function WrappedPlayer:ResetCache() end

return WrappedPlayer
