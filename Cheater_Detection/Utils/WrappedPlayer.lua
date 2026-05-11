--[[ WrappedPlayer.lua ]]
--
-- Player entity wrapper with cached property access

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local TickEntityCache = require("Cheater_Detection.Utils.TickEntityCache")

-- Safety: Polyfill Vector3 if missing (Lmaobox usually provides it globally)
local _Vector3 = Vector3 or function(x, y, z)
	return { x = x, y = y, z = z }
end

---@diagnostic disable: undefined-global, undefined-field, duplicate-doc-field
---@class WrappedPlayer
local WrappedPlayer = {}

local WrapperPool = {}
local function getEntityByIndex(index)
	return TickEntityCache.GetPlayerByIndex(index)
end

local function hydrateWrapper(wrapped, entity, cachedSteamID)
	local currentIndex = entity:GetIndex()

	wrapped._cachedIndex = currentIndex
	wrapped._lastSeenTick = globals.TickCount()

	-- Initialize persistent cache tables if missing
	if not wrapped._cache then
		wrapped._cache = {}
	end
	if not wrapped._cacheTs then
		wrapped._cacheTs = {}
	end

	-- Get and cache SteamID once (reuse passed value to avoid duplicate conversion)
	if not wrapped._steamID64 then
		local steamID = cachedSteamID or Common.GetSteamID64(entity)
		if steamID then
			wrapped._steamID64 = steamID
		end
	end

	return wrapped
end

-- Instance metatable that forwards unknown lookups to the base WPlayer
local WrappedPlayerMT = {}

-- Optimized cacheValue using per-key timestamps
-- This avoids clearing the cache table every tick (saving cycles)
-- Old values stay in memory (minor leak) but are ignored if outdated
local function ensureCacheTables(self)
	local cacheTs = rawget(self, "_cacheTs")
	local cache = rawget(self, "_cache")
	if cacheTs and cache then
		return cache, cacheTs
	end
	cacheTs = {}
	cache = {}
	rawset(self, "_cacheTs", cacheTs)
	rawset(self, "_cache", cache)
	return cache, cacheTs
end

local function cacheGet(self, key, curTick)
	local cache, cacheTs = ensureCacheTables(self)
	if cacheTs[key] == curTick then
		return cache[key], true
	end
	return nil, false
end

local function cacheSet(self, key, curTick, value)
	local cache, cacheTs = ensureCacheTables(self)
	cache[key] = value
	cacheTs[key] = curTick
end

function WrappedPlayerMT.__index(self, key)
	return WrappedPlayer[key]
end

--- Creates a new WrappedPlayer from a TF2 entity
---@param entity Entity The entity to wrap
---@param cachedSteamID any? Optional precomputed SteamID64
---@return WrappedPlayer|nil The wrapped player or nil if invalid
function WrappedPlayer.FromEntity(entity, cachedSteamID)
	if not entity or not entity:IsValid() then
		return nil
	end

	-- Use SteamID64 as the primary key for caching if available
	local steamID = cachedSteamID or Common.GetSteamID64(entity)
	local key = steamID and tostring(steamID) or entity:GetIndex()

	local wrapped = WrapperPool[key]
	if not wrapped then
		wrapped = setmetatable({}, WrappedPlayerMT)
		WrapperPool[key] = wrapped
	end

	-- Pass steamID to avoid duplicate GetSteamID64 call in hydrateWrapper
	if not hydrateWrapper(wrapped, entity, steamID) then
		WrapperPool[key] = nil
		return nil
	end

	return wrapped
end

--- Create WrappedPlayer from index
---@param index number The entity index
---@return WrappedPlayer|nil The wrapped player or nil if invalid
function WrappedPlayer.FromIndex(index)
	local entity = getEntityByIndex(index)
	return entity and WrappedPlayer.FromEntity(entity) or nil
end

--- Returns the player's display name via client.GetPlayerInfo
---@return string|nil
function WrappedPlayer:GetName()
	local ent = getEntityByIndex(rawget(self, "_cachedIndex"))
	local idx = ent and ent:GetIndex()
	if not idx then
		return nil
	end
	local info = client.GetPlayerInfo(idx)
	return info and info.Name or nil
end

--- Returns the underlying raw entity
function WrappedPlayer:GetRawEntity()
	return getEntityByIndex(rawget(self, "_cachedIndex"))
end

--- Resets per-tick cache (no-op: per-tick expiry is handled by timestamps)
function WrappedPlayer:ResetCache()
end

function WrappedPlayer:GetBasePlayer()
	return self:GetRawEntity()
end

function WrappedPlayer:GetIndex()
	return rawget(self, "_cachedIndex")
end

function WrappedPlayer:IsValid()
	return self:GetRawEntity() ~= nil
end

function WrappedPlayer:GetSimulationTime()
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	return ent:GetPropFloat("m_flSimulationTime")
end

function WrappedPlayer:GetHitboxPos(hitboxIndex)
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	if not ent:IsAlive() then
		return nil
	end
	if ent:IsDormant() then
		return nil
	end
	-- SetupBones is the preferred API (GetHitboxes is deprecated)
	local bones = ent:SetupBones()
	if not bones then
		return nil
	end
	-- bones is a table of matrices. Each matrix has [1..3] rows of [1..4] cols.
	-- The translation (position) is stored in column 4 of each row: [row][4].
	-- We read the 4th column of each row to get the world position of this bone.
	local matrix = bones[hitboxIndex]
	if not matrix then
		return nil
	end
	return _Vector3(matrix[1][4], matrix[2][4], matrix[3][4])
end

function WrappedPlayer:GetPropInt(...)
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	return ent:GetPropInt(...)
end

function WrappedPlayer:GetPropFloat(...)
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	return ent:GetPropFloat(...)
end

function WrappedPlayer:GetPropVector(...)
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	return ent:GetPropVector(...)
end

function WrappedPlayer:GetPropBool(...)
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	return ent:GetPropBool(...)
end

function WrappedPlayer:GetPropEntity(...)
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	return ent:GetPropEntity(...)
end

function WrappedPlayer:GetClass()
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	return ent:GetClass()
end

function WrappedPlayer:GetMins()
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	return ent:GetMins()
end

function WrappedPlayer:GetMaxs()
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	return ent:GetMaxs()
end

--- Checks if a given entity is valid
---@param checkFriend boolean? Check if the entity is a friend
---@param checkDormant boolean? Check if the entity is dormant
---@param skipEntity Entity? Optional entity to skip
---@return boolean Whether the entity is valid
function WrappedPlayer:IsValidPlayer(checkFriend, checkDormant, skipEntity)
	return Common.IsValidPlayer(self:GetRawEntity(), checkFriend, checkDormant, skipEntity)
end

--- Get SteamID64 for this player object
---@return string|number|nil The player's SteamID64, or nil if unavailable
function WrappedPlayer:GetSteamID64()
	-- Use rawget to access the cached value directly
	-- This is CRITICAL to prevent infinite recursion if self._steamID64 triggers __index
	local cached = rawget(self, "_steamID64")
	if cached then
		return cached
	end

	-- If not in cache (which shouldn't happen often due to hydrateWrapper), try to fetch it
	local steamID = Common.GetSteamID64(self:GetRawEntity())
	if steamID then
		self._steamID64 = steamID
		return steamID
	end

	return nil
end

--- Get SteamID3 for this player object
---@return string|nil
function WrappedPlayer:GetSteamID3()
	if not self._steamID3 then
		local steamID64 = self:GetSteamID64()
		local numeric = tonumber(steamID64)
		if numeric then
			local accountID = numeric - 76561197960265728
			if accountID and accountID >= 0 then
				self._steamID3 = string.format("[U:1:%d]", accountID)
			end
		end
	end
	return self._steamID3
end

--- Check if player is on the ground via m_fFlags
---@return boolean Whether the player is on the ground
function WrappedPlayer:IsOnGround()
	local ent = self:GetRawEntity()
	if not ent then
		return false
	end
	local flags = ent:GetPropInt("m_fFlags")
	return (flags & FL_ONGROUND) ~= 0
end

function WrappedPlayer:IsAlive()
	local ent = self:GetRawEntity()
	return ent ~= nil and ent:IsAlive() or false
end

function WrappedPlayer:IsDormant()
	local curTick = globals.TickCount()
	local v, ok = cacheGet(self, "isDormant", curTick)
	if ok then
		return v == true
	end
	local ent = self:GetRawEntity()
	local result = (ent == nil) or ent:IsDormant()
	cacheSet(self, "isDormant", curTick, result)
	return result
end

function WrappedPlayer:IsFriend(includeParty)
	return Common.IsFriend(self:GetRawEntity(), includeParty)
end

function WrappedPlayer:IsEnemyOf(other)
	if not other or type(other.GetTeamNumber) ~= "function" then
		return false
	end
	local ent = self:GetRawEntity()
	local myTeam = ent and ent:GetTeamNumber() or nil
	return myTeam ~= nil and myTeam ~= 0 and myTeam ~= other:GetTeamNumber()
end

--- Returns the view offset from the player's origin as a Vector3
---@return Vector3|nil The player's view offset
function WrappedPlayer:GetViewOffset()
	local curTick = globals.TickCount()
	local v, ok = cacheGet(self, "viewOffset", curTick)
	if ok then
		return v
	end
	local ent = self:GetRawEntity()
	local result = nil
	if ent then
		result = ent:GetPropVector("localdata", "m_vecViewOffset[0]")
	end
	cacheSet(self, "viewOffset", curTick, result)
	return result
end

--- Returns the player's eye position in world coordinates
---@return Vector3|nil The player's eye position
function WrappedPlayer:GetEyePos()
	local curTick = globals.TickCount()
	local v, ok = cacheGet(self, "eyePos", curTick)
	if ok then
		return v
	end
	local origin = self:GetAbsOrigin()
	local offset = self:GetViewOffset()
	local result = nil
	if origin and offset then
		result = origin + offset
	end
	cacheSet(self, "eyePos", curTick, result)
	return result
end

--- Returns the player's eye angles as an EulerAngles object
---@return EulerAngles|nil The player's eye angles
function WrappedPlayer:GetEyeAngles()
	local curTick = globals.TickCount()
	local v, ok = cacheGet(self, "eyeAngles", curTick)
	if ok then
		return v
	end
	local ent = self:GetRawEntity()
	local result = nil
	if ent then
		if ent:GetIndex() == client.GetLocalPlayerIndex() then
			result = engine.GetViewAngles()
		else
			local ang = ent:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
			if ang then
				result = EulerAngles(ang.x, ang.y, ang.z)
			else
				ang = ent:GetPropVector("m_angEyeAngles[0]")
				if ang then
					result = EulerAngles(ang.x, ang.y, ang.z)
				end
			end
		end
	end
	cacheSet(self, "eyeAngles", curTick, result)
	return result
end

function WrappedPlayer:GetAbsOrigin()
	local curTick = globals.TickCount()
	local v, ok = cacheGet(self, "absOrigin", curTick)
	if ok then
		return v
	end
	local ent = self:GetRawEntity()
	local result = ent and ent:GetAbsOrigin() or nil
	cacheSet(self, "absOrigin", curTick, result)
	return result
end

function WrappedPlayer:GetVelocity()
	local curTick = globals.TickCount()
	local v, ok = cacheGet(self, "velocity", curTick)
	if ok then
		return v
	end
	local ent = self:GetRawEntity()
	local result = ent and ent:EstimateAbsVelocity() or nil
	cacheSet(self, "velocity", curTick, result)
	return result
end

--- Returns the world position the player is looking at by tracing a ray
---@return Vector3|nil The look position or nil if trace failed
function WrappedPlayer:GetLookPos()
	local curTick = globals.TickCount()
	local v, ok = cacheGet(self, "lookPos", curTick)
	if ok then
		return v
	end
	local eyePos = self:GetEyePos()
	local eyeAng = self:GetEyeAngles()
	local result = nil
	if eyePos and eyeAng then
		local targetPos = eyePos + eyeAng:Forward() * 8192
		local tr = engine.TraceLine(eyePos, targetPos, MASK_SHOT)
		if tr then
			result = tr.endpos
		end
	end
	cacheSet(self, "lookPos", curTick, result)
	return result
end

--- Returns the currently active weapon wrapper
---@return table|nil The active weapon wrapper or nil
function WrappedPlayer:GetActiveWeapon()
	local ent = self:GetRawEntity()
	return ent and ent:GetPropEntity("m_hActiveWeapon") or nil
end

function WrappedPlayer:GetActiveWeaponID()
	local curTick = globals.TickCount()
	local v, ok = cacheGet(self, "weaponID", curTick)
	if ok then
		return v
	end
	local weapon = self:GetActiveWeapon()
	local result = nil
	if weapon and weapon.GetWeaponID then
		result = weapon:GetWeaponID()
	end
	cacheSet(self, "weaponID", curTick, result)
	return result
end

function WrappedPlayer:GetWeaponChargeData()
	local curTick = globals.TickCount()
	local v, ok = cacheGet(self, "weaponCharge", curTick)
	if ok then
		return v
	end

	local weapon = self:GetActiveWeapon()
	if not weapon then
		cacheSet(self, "weaponCharge", curTick, nil)
		return nil
	end

	local cache, _ = ensureCacheTables(self)
	local data = cache["weaponCharge"]
	if type(data) ~= "table" then
		data = { ChargeBegin = 0, ChargedDamage = 0 }
		cache["weaponCharge"] = data
	end

	local chargeBegin = 0
	if weapon.GetChargeBeginTime then
		chargeBegin = weapon:GetChargeBeginTime() or 0
	end
	local chargedDamage = 0
	if weapon.GetChargedDamage then
		chargedDamage = weapon:GetChargedDamage() or 0
	end

	data.ChargeBegin = chargeBegin
	data.ChargedDamage = chargedDamage

	cacheSet(self, "weaponCharge", curTick, data)
	return data
end

--- Returns the player's observer mode
---@return number The observer mode
function WrappedPlayer:GetObserverMode()
	local ent = self:GetRawEntity()
	return ent and ent:GetPropInt("m_iObserverMode") or nil
end

--- Returns the player's observer target wrapper
---@return WrappedPlayer|nil The observer target or nil
function WrappedPlayer:GetObserverTarget()
	local ent = self:GetRawEntity()
	if not ent then
		return nil
	end
	local target = ent:GetPropEntity("m_hObserverTarget")
	return target and WrappedPlayer.FromEntity(target) or nil
end

--- Returns the next attack time
---@return number The next attack time
function WrappedPlayer:GetNextAttack()
	local ent = self:GetRawEntity()
	return ent and ent:GetPropFloat("m_flNextAttack") or nil
end

function WrappedPlayer:GetTeamNumber()
	local ent = self:GetRawEntity()
	return ent and ent:GetTeamNumber() or nil
end

function WrappedPlayer:SetPriority(level)
	if not level then
		return false
	end
	local ent = self:GetRawEntity()
	if not ent then
		return false
	end
	playerlist.SetPriority(ent, level)
	return true
end

function WrappedPlayer.PruneInactive(currentTick)
	currentTick = currentTick or globals.TickCount()
	-- Allow 1 tick grace period so we don't wipe the pool before updating it
	local threshold = currentTick - 1
	for index, wrapped in pairs(WrapperPool) do
		if not wrapped or wrapped._lastSeenTick < threshold then
			WrapperPool[index] = nil
		end
	end
end

function WrappedPlayer.ResetPool()
	for index in pairs(WrapperPool) do
		WrapperPool[index] = nil
	end
end

return WrappedPlayer
