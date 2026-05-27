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
local WrappedPlayerMT    = { __index = WrappedPlayer }

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
		local ent = self:GetRawEntity()
		return ent ~= nil and ent:IsAlive()
	end)
end

function WrappedPlayer:IsDormant()
	return self:_getCached("isDormant", function()
		local ent = self:GetRawEntity()
		return ent == nil or ent:IsDormant()
	end)
end

function WrappedPlayer:IsOnGround()
	return self:_getCached("isOnGround", function()
		local ent = self:GetRawEntity()
		if not ent then return false end
		local f = ent:GetPropInt("m_fFlags")
		return f ~= nil and (f & FL_ONGROUND) ~= 0
	end)
end

function WrappedPlayer:IsFriend(includeParty)
	return self:_getCached("isFriend_" .. tostring(includeParty), function()
		local ent = self:GetRawEntity()
		if not ent then return false end
		return Common.IsFriend(ent, includeParty)
	end)
end

function WrappedPlayer:IsValidPlayer(checkFriend, checkDormant, skipEntity)
	local ent = self:GetRawEntity()
	if not ent then return false end
	return Common.IsValidPlayer(ent, checkFriend, checkDormant, skipEntity)
end

function WrappedPlayer:IsEnemyOf(other)
	if not other or type(other.GetTeamNumber) ~= "function" then return false end
	local ent = self:GetRawEntity()
	local myTeam = ent and ent:GetTeamNumber()
	return myTeam ~= nil and myTeam ~= 0 and myTeam ~= other:GetTeamNumber()
end

function WrappedPlayer:GetTeamNumber()
	return self:_getCached("teamNumber", function()
		local ent = self:GetRawEntity()
		return ent and ent:GetTeamNumber() or nil
	end)
end

function WrappedPlayer:GetAbsOrigin()
	return self:_getCached("absOrigin", function()
		local ent = self:GetRawEntity()
		return ent and ent:GetAbsOrigin() or nil
	end)
end

function WrappedPlayer:GetVelocity()
	return self:_getCached("velocity", function()
		local ent = self:GetRawEntity()
		return ent and ent:EstimateAbsVelocity() or nil
	end)
end

function WrappedPlayer:GetViewOffset()
	return self:_getCached("viewOffset", function()
		local ent = self:GetRawEntity()
		return ent and ent:GetPropVector("localdata", "m_vecViewOffset[0]") or nil
	end)
end

function WrappedPlayer:GetEyePos()
	return self:_getCached("eyePos", function()
		local ent = self:GetRawEntity()
		if not ent then return nil end
		local origin = ent:GetAbsOrigin()
		local offset = ent:GetPropVector("localdata", "m_vecViewOffset[0]")
		if origin and offset then return origin + offset end
		return nil
	end)
end

function WrappedPlayer:GetEyeAngles()
	return self:_getCached("eyeAngles", function()
		local ent = self:GetRawEntity()
		if not ent then return nil end
		if ent:GetIndex() == localPlayerIndex() then
			return engine.GetViewAngles()
		end
		local ang = ent:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
		if ang then return EulerAngles(ang.x, ang.y, ang.z) end
		ang = ent:GetPropVector("m_angEyeAngles[0]")
		if ang then return EulerAngles(ang.x, ang.y, ang.z) end
		return nil
	end)
end

function WrappedPlayer:GetSimulationTime()
	return self:_getCached("simTime", function()
		local ent = self:GetRawEntity()
		return ent and ent:GetPropFloat("m_flSimulationTime") or nil
	end)
end

function WrappedPlayer:GetHitboxPos(hitboxIndex)
	local ent = self:GetRawEntity()
	if not ent or not ent:IsAlive() or ent:IsDormant() then return nil end
	-- GetHitboxes returns world-space hitbox bounds: { [idx] = {mins, maxs} }
	local hitboxes = ent:GetHitboxes()
	if not hitboxes then return nil end
	local box = hitboxes[hitboxIndex]
	if not box or not box[1] or not box[2] then return nil end
	-- Return center of hitbox bounds
	return (box[1] + box[2]) * 0.5
end

function WrappedPlayer:GetLookPos()
	local eyePos = self:GetEyePos()
	local eyeAng = self:GetEyeAngles()
	if not eyePos or not eyeAng then return nil end
	local targetPos = eyePos + eyeAng:Forward() * 8192
	local tr = engine.TraceLine(eyePos, targetPos, MASK_SHOT)
	return tr and tr.endpos or nil
end

function WrappedPlayer:GetActiveWeapon()
	local ent = self:GetRawEntity()
	return ent and ent:GetPropEntity("m_hActiveWeapon") or nil
end

function WrappedPlayer:GetActiveWeaponID()
	local weapon = self:GetActiveWeapon()
	if weapon and weapon.GetWeaponID then return weapon:GetWeaponID() end
	return nil
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
	local ent = self:GetRawEntity()
	return ent and ent:GetPropInt("m_iObserverMode") or nil
end

function WrappedPlayer:GetObserverTarget()
	local ent = self:GetRawEntity()
	if not ent then return nil end
	local target = ent:GetPropEntity("m_hObserverTarget")
	if not target then return nil end
	local sid64 = Common.GetSteamID64(target)
	if not sid64 then return nil end
	local state = PlayerCache.GetByID(tostring(sid64))
	return state and state.wrap or nil
end

function WrappedPlayer:GetNextAttack()
	local ent = self:GetRawEntity()
	return ent and ent:GetPropFloat("m_flNextAttack") or nil
end

function WrappedPlayer:GetPropInt(...)
	local ent = self:GetRawEntity()
	return ent and ent:GetPropInt(...) or nil
end

function WrappedPlayer:GetPropFloat(...)
	local ent = self:GetRawEntity()
	return ent and ent:GetPropFloat(...) or nil
end

function WrappedPlayer:GetPropVector(...)
	local ent = self:GetRawEntity()
	return ent and ent:GetPropVector(...) or nil
end

function WrappedPlayer:GetPropBool(...)
	local ent = self:GetRawEntity()
	return ent and ent:GetPropBool(...) or nil
end

function WrappedPlayer:GetPropEntity(...)
	local ent = self:GetRawEntity()
	return ent and ent:GetPropEntity(...) or nil
end

function WrappedPlayer:GetClass()
	local ent = self:GetRawEntity()
	return ent and ent:GetClass() or nil
end

function WrappedPlayer:GetMins()
	local ent = self:GetRawEntity()
	return ent and ent:GetMins() or nil
end

function WrappedPlayer:GetMaxs()
	local ent = self:GetRawEntity()
	return ent and ent:GetMaxs() or nil
end

function WrappedPlayer:GetBasePlayer()
	return self:GetRawEntity()
end

function WrappedPlayer:SetPriority(level)
	if not level then return false end
	local ent = self:GetRawEntity()
	if not ent then return false end
	playerlist.SetPriority(ent, level)
	return true
end

--- No-op kept for call-site compatibility.
function WrappedPlayer:ResetCache() end

return WrappedPlayer
