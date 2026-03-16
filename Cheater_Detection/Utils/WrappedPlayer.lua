--[[ WrappedPlayer.lua ]]
--
-- Player entity wrapper with cached property access

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")

-- Safety: Polyfill Vector3 if missing (Lmaobox usually provides it globally)
local _Vector3 = Vector3 or function(x, y, z)
	return { x = x, y = y, z = z }
end

---@diagnostic disable: undefined-global, undefined-field, duplicate-doc-field
---@class WrappedPlayer
---@field _rawEntity Entity Raw entity object
local WrappedPlayer = {}

local WrapperPool = {}

local function hydrateWrapper(wrapped, entity, cachedSteamID)
	local currentIndex = entity:GetIndex()

	if wrapped._rawEntity and wrapped._cachedIndex == currentIndex then
		wrapped._rawEntity = entity
		wrapped._lastSeenTick = globals.TickCount()
		return wrapped
	end

	wrapped._rawEntity = entity
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
local function cacheValue(self, key, computeFn)
	-- Use rawget to bypass metatable and avoid name collisions with basePlayer methods
	if type(self) ~= "table" then
		return computeFn()
	end

	local currentTick = globals.TickCount()

	-- Access internal cache tables directly (bypassing metatable)
	local cacheTs = rawget(self, "_cacheTs")
	if not cacheTs then
		rawset(self, "_cacheTs", {})
		rawset(self, "_cache", {})
		cacheTs = rawget(self, "_cacheTs")
	end

	local cache = rawget(self, "_cache")
	local lastTick = cacheTs[key]

	-- Check if valid for this tick
	if lastTick == currentTick then
		return cache[key]
	end

	-- Compute and cache
	local result = computeFn()
	if result ~= nil then
		cache[key] = result
		cacheTs[key] = currentTick
	end
	return result
end

function WrappedPlayerMT.__index(self, key)
	return WrappedPlayer[key]
end

--- Creates a new WrappedPlayer from a TF2 entity
---@param entity Entity The entity to wrap
---@return WrappedPlayer|nil The wrapped player or nil if invalid
function WrappedPlayer.FromEntity(entity)
	if not entity or not entity:IsValid() then
		return nil
	end

	-- Use SteamID64 as the primary key for caching if available
	local steamID = Common.GetSteamID64(entity)
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
	local entity = entities.GetByIndex(index)
	return entity and WrappedPlayer.FromEntity(entity) or nil
end

--- Returns the player's display name via client.GetPlayerInfo
---@return string|nil
function WrappedPlayer:GetName()
	local idx = self._rawEntity and self._rawEntity:GetIndex()
	if not idx then
		return nil
	end
	local info = client.GetPlayerInfo(idx)
	return info and info.Name or nil
end

--- Returns the underlying raw entity
function WrappedPlayer:GetRawEntity()
	return self._rawEntity
end

--- Resets per-tick cache (No-op now, handled by timestamps)
function WrappedPlayer:ResetCache()
	-- No-op: We use timestamps now
end

function WrappedPlayer:GetBasePlayer()
	return self._rawEntity
end

function WrappedPlayer:GetIndex()
	assert(self._rawEntity, "WrappedPlayer:GetIndex: _rawEntity is nil")
	return self._rawEntity:GetIndex()
end

function WrappedPlayer:IsValid()
	return self._rawEntity and self._rawEntity:IsValid() or false
end

function WrappedPlayer:GetSimulationTime()
	if not self._rawEntity or not self._rawEntity:IsValid() then
		return nil
	end
	return self._rawEntity:GetPropFloat("m_flSimulationTime")
end

function WrappedPlayer:GetHitboxPos(hitboxIndex)
	-- SetupBones is the preferred API (GetHitboxes is deprecated)
	local bones = self._rawEntity:SetupBones()
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
	assert(self._rawEntity and self._rawEntity:IsValid(), "WrappedPlayer:GetPropInt: invalid entity")
	return self._rawEntity:GetPropInt(...)
end

function WrappedPlayer:GetPropFloat(...)
	assert(self._rawEntity and self._rawEntity:IsValid(), "WrappedPlayer:GetPropFloat: invalid entity")
	return self._rawEntity:GetPropFloat(...)
end

function WrappedPlayer:GetPropVector(...)
	assert(self._rawEntity and self._rawEntity:IsValid(), "WrappedPlayer:GetPropVector: invalid entity")
	return self._rawEntity:GetPropVector(...)
end

function WrappedPlayer:GetPropBool(...)
	assert(self._rawEntity and self._rawEntity:IsValid(), "WrappedPlayer:GetPropBool: invalid entity")
	return self._rawEntity:GetPropBool(...)
end

function WrappedPlayer:GetPropEntity(...)
	assert(self._rawEntity and self._rawEntity:IsValid(), "WrappedPlayer:GetPropEntity: invalid entity")
	return self._rawEntity:GetPropEntity(...)
end

function WrappedPlayer:GetClass()
	assert(self._rawEntity and self._rawEntity:IsValid(), "WrappedPlayer:GetClass: invalid entity")
	return self._rawEntity:GetClass()
end

function WrappedPlayer:GetMins()
	assert(self._rawEntity and self._rawEntity:IsValid(), "WrappedPlayer:GetMins: invalid entity")
	return self._rawEntity:GetMins()
end

function WrappedPlayer:GetMaxs()
	assert(self._rawEntity and self._rawEntity:IsValid(), "WrappedPlayer:GetMaxs: invalid entity")
	return self._rawEntity:GetMaxs()
end

--- Checks if a given entity is valid
---@param checkFriend boolean? Check if the entity is a friend
---@param checkDormant boolean? Check if the entity is dormant
---@param skipEntity Entity? Optional entity to skip
---@return boolean Whether the entity is valid
function WrappedPlayer:IsValidPlayer(checkFriend, checkDormant, skipEntity)
	return Common.IsValidPlayer(self._rawEntity, checkFriend, checkDormant, skipEntity)
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
	local steamID = Common.GetSteamID64(self._rawEntity)
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

--- Returns PlayerState entry associated with this player
---@return table|nil
function WrappedPlayer:GetState()
	if not PlayerState then
		return nil
	end
	if not self._state then
		self._state = PlayerState.AttachWrappedPlayer(self)
	end
	return self._state
end

function WrappedPlayer:GetEvidence()
	local state = self:GetState()
	if not state then
		return nil
	end
	state.Evidence = state.Evidence or {}
	return state.Evidence
end

function WrappedPlayer:GetData()
	return self:GetState()
end

function WrappedPlayer:GetInfo()
	local state = self:GetState()
	if not state then
		return nil
	end
	state.info = state.info or {}
	return state.info
end

function WrappedPlayer:GetHistory()
	if not PlayerState then
		return nil
	end
	local steamID = self:GetSteamID64()
	if not steamID then
		return nil
	end
	return PlayerState.GetHistory(steamID)
end

function WrappedPlayer:PushHistory(record, maxHistory)
	if not PlayerState then
		return
	end
	local steamID = self:GetSteamID64()
	if not steamID then
		return
	end
	PlayerState.PushHistory(steamID, record, maxHistory or Common.MAX_HISTORY or 66)
end

--- Check if player is on the ground via m_fFlags
---@return boolean Whether the player is on the ground
function WrappedPlayer:IsOnGround()
	assert(self._rawEntity and self._rawEntity:IsValid(), "WrappedPlayer:IsOnGround: invalid entity")
	local flags = self._rawEntity:GetPropInt("m_fFlags")
	return (flags & FL_ONGROUND) ~= 0
end

function WrappedPlayer:IsAlive()
	return self._rawEntity and self._rawEntity:IsAlive() or false
end

function WrappedPlayer:IsDormant()
	return cacheValue(self, "isDormant", function()
		return self._rawEntity and self._rawEntity:IsDormant() or true
	end)
end

function WrappedPlayer:IsFriend(includeParty)
	return Common.IsFriend(self._rawEntity, includeParty)
end

function WrappedPlayer:IsEnemyOf(other)
	if not other or type(other.GetTeamNumber) ~= "function" then
		return false
	end
	local myTeam = self._rawEntity and self._rawEntity:GetTeamNumber()
	return myTeam ~= nil and myTeam ~= 0 and myTeam ~= other:GetTeamNumber()
end

--- Returns the view offset from the player's origin as a Vector3
---@return Vector3|nil The player's view offset
function WrappedPlayer:GetViewOffset()
	return cacheValue(self, "viewOffset", function()
		return self._rawEntity:GetPropVector("localdata", "m_vecViewOffset[0]")
	end)
end

--- Returns the player's eye position in world coordinates
---@return Vector3|nil The player's eye position
function WrappedPlayer:GetEyePos()
	return cacheValue(self, "eyePos", function()
		local origin = self:GetAbsOrigin()
		local offset = self:GetViewOffset()
		if origin and offset then
			return origin + offset
		end
		return nil
	end)
end

--- Returns the player's eye angles as an EulerAngles object
---@return EulerAngles|nil The player's eye angles
function WrappedPlayer:GetEyeAngles()
	return cacheValue(self, "eyeAngles", function()
		-- Local player: always use engine view angles, never read netprop (causes DataTable warnings).
		if self._rawEntity:GetIndex() == client.GetLocalPlayerIndex() then
			return engine.GetViewAngles()
		end

		local ang = self._rawEntity:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
		if ang then
			return EulerAngles(ang.x, ang.y, ang.z)
		end

		ang = self._rawEntity:GetPropVector("m_angEyeAngles[0]")
		if ang then
			return EulerAngles(ang.x, ang.y, ang.z)
		end

		return nil
	end)
end

function WrappedPlayer:GetAbsOrigin()
	return cacheValue(self, "absOrigin", function()
		return self._rawEntity:GetAbsOrigin()
	end)
end

function WrappedPlayer:GetVelocity()
	return cacheValue(self, "velocity", function()
		return self._rawEntity:EstimateAbsVelocity()
	end)
end

--- Returns the world position the player is looking at by tracing a ray
---@return Vector3|nil The look position or nil if trace failed
function WrappedPlayer:GetLookPos()
	return cacheValue(self, "lookPos", function()
		local eyePos = self:GetEyePos()
		local eyeAng = self:GetEyeAngles()
		if not eyePos or not eyeAng then
			return nil
		end
		local targetPos = eyePos + eyeAng:Forward() * 8192
		local tr = engine.TraceLine(eyePos, targetPos, MASK_SHOT)
		return tr and tr.endpos or nil
	end)
end

--- Returns the currently active weapon wrapper
---@return table|nil The active weapon wrapper or nil
function WrappedPlayer:GetActiveWeapon()
	return self._rawEntity:GetPropEntity("m_hActiveWeapon")
end

function WrappedPlayer:GetActiveWeaponID()
	return cacheValue(self, "weaponID", function()
		local weapon = self:GetActiveWeapon()
		if weapon and weapon.GetWeaponID then
			return weapon:GetWeaponID()
		end
		return nil
	end)
end

function WrappedPlayer:GetWeaponChargeData()
	return cacheValue(self, "weaponCharge", function()
		local weapon = self:GetActiveWeapon()
		if not weapon then
			return nil
		end
		return {
			ChargeBegin = weapon.GetChargeBeginTime and weapon:GetChargeBeginTime() or 0,
			ChargedDamage = weapon.GetChargedDamage and weapon:GetChargedDamage() or 0,
		}
	end)
end

--- Returns the player's observer mode
---@return number The observer mode
function WrappedPlayer:GetObserverMode()
	return self._rawEntity:GetPropInt("m_iObserverMode")
end

--- Returns the player's observer target wrapper
---@return WrappedPlayer|nil The observer target or nil
function WrappedPlayer:GetObserverTarget()
	local target = self._rawEntity:GetPropEntity("m_hObserverTarget")
	return target and WrappedPlayer.FromEntity(target) or nil
end

--- Returns the next attack time
---@return number The next attack time
function WrappedPlayer:GetNextAttack()
	return self._rawEntity:GetPropFloat("m_flNextAttack")
end

function WrappedPlayer:GetTeamNumber()
	return self._rawEntity:GetTeamNumber()
end

function WrappedPlayer:SetPriority(level)
	if not level then
		return false
	end
	local success = pcall(playerlist.SetPriority, self._rawEntity, level)
	return success
end

function WrappedPlayer:IsCheater()
	local info = self:GetInfo()
	return info and info.IsCheater or false
end

function WrappedPlayer:MarkCheater(reason)
	local info = self:GetInfo()
	if not info then
		return
	end
	info.IsCheater = true
	info.CheaterReason = reason or info.CheaterReason
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
