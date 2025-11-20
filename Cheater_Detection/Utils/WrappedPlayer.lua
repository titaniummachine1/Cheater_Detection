--[[ WrappedPlayer.lua ]]
--
-- A proper wrapper for player entities that extends lnxLib's WPlayer

-- Get required modules
local Common = require("Cheater_Detection.Utils.Common")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")

assert(Common, "Common is nil")
local WPlayer = Common.WPlayer
assert(WPlayer, "WPlayer is nil")

---@class WrappedPlayer
---@field _basePlayer table Base WPlayer from lnxLib
---@field _rawEntity Entity Raw entity object
local WrappedPlayer = {}

local WrapperPool = {}

local function hydrateWrapper(wrapped, entity)
	-- Optimization: Reuse existing WPlayer if it matches the entity index
	-- We assume 'entity' is valid because it came from FindByClass
	if wrapped._basePlayer then
		-- Update the raw entity reference (in case userdata changed)
		wrapped._rawEntity = entity
		wrapped._lastSeenTick = globals.TickCount()
		return wrapped
	end

	local basePlayer = WPlayer.FromEntity(entity)
	if not basePlayer then
		return nil
	end

	-- Minimal per-instance data (cache created on-demand)
	wrapped._basePlayer = basePlayer
	wrapped._rawEntity = entity
	wrapped._cacheTick = -1
	wrapped._lastSeenTick = globals.TickCount()

	-- Get and cache SteamID once
	local steamID = Common.GetSteamID64(basePlayer)
	if steamID then
		steamID = tostring(steamID)
		wrapped._steamID64 = steamID

		-- Attach PlayerState only if needed
		if PlayerState then
			wrapped._state = PlayerState.AttachWrappedPlayer(wrapped)
		end
	end

	return wrapped
end

-- Instance metatable that forwards unknown lookups to the base WPlayer
local WrappedPlayerMT = {}

local function cacheValue(cache, key, computeFn)
	local cached = cache[key]
	if cached ~= nil then
		return cached
	end
	local result = computeFn()
	if result ~= nil then
		cache[key] = result
	end
	return result
end

local function wrapCall(target, method)
	if type(method) ~= "function" then
		return method
	end
	return function(_, ...)
		return method(target, ...)
	end
end

function WrappedPlayerMT.__index(self, key)
	-- 1) Custom helpers defined on WrappedPlayer
	local custom = WrappedPlayer[key]
	if custom ~= nil then
		return custom
	end

	-- 2) Fallback to lnxLib WPlayer (already proxies to raw entity)
	local basePlayer = rawget(self, "_basePlayer")
	if basePlayer then
		local value = basePlayer[key]
		if value ~= nil then
			return wrapCall(basePlayer, value)
		end
	end

	-- 3) Expose raw entity fields as a last resort
	local rawEntity = rawget(self, "_rawEntity")
	if rawEntity then
		local rawValue = rawEntity[key]
		if rawValue ~= nil then
			return wrapCall(rawEntity, rawValue)
		end
	end

	return nil
end

--- Creates a new WrappedPlayer from a TF2 entity
---@param entity Entity The entity to wrap
---@return WrappedPlayer|nil The wrapped player or nil if invalid
function WrappedPlayer.FromEntity(entity)
	if not entity or not entity:IsValid() then
		return nil
	end

	local index = entity:GetIndex()
	if not index then
		return nil
	end

	local wrapped = WrapperPool[index]
	if not wrapped then
		wrapped = setmetatable({}, WrappedPlayerMT)
		WrapperPool[index] = wrapped
	end

	if not hydrateWrapper(wrapped, entity) then
		WrapperPool[index] = nil
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

--- Returns the underlying raw entity
function WrappedPlayer:GetRawEntity()
	return self._rawEntity
end

--- Resets per-tick cache (called automatically via Cache())
function WrappedPlayer:ResetCache()
	self._cache = {}
	self._cacheTick = globals.TickCount()
end

--- Retrieve a per-tick cache table unique to this wrapper
---@return table
function WrappedPlayer:Cache()
	local tick = globals.TickCount()
	if self._cacheTick ~= tick then
		-- Lazy-init cache (save memory if never used)
		self._cache = {}
		self._cacheTick = tick
	end
	return self._cache
end

--- Returns the base WPlayer from lnxLib
function WrappedPlayer:GetBasePlayer()
	return self._basePlayer
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
---@return string|number The player's SteamID64
function WrappedPlayer:GetSteamID64()
	if not self._steamID64 then
		local steamID = Common.GetSteamID64(self._basePlayer)
		if steamID then
			self._steamID64 = tostring(steamID)
		end
	end
	return self._steamID64
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
	local flags = self._basePlayer:GetPropInt("m_fFlags")
	return (flags & FL_ONGROUND) ~= 0
end

function WrappedPlayer:IsAlive()
	return self._rawEntity and self._rawEntity:IsAlive() or false
end

function WrappedPlayer:IsDormant()
	local cache = self:Cache()
	return cacheValue(cache, "isDormant", function()
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
---@return Vector3 The player's view offset
function WrappedPlayer:GetViewOffset()
	local cache = self:Cache()
	return cacheValue(cache, "viewOffset", function()
		return self._basePlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
	end)
end

--- Returns the player's eye position in world coordinates
---@return Vector3 The player's eye position
function WrappedPlayer:GetEyePos()
	local cache = self:Cache()
	return cacheValue(cache, "eyePos", function()
		local origin = self:GetAbsOrigin()
		local offset = self:GetViewOffset()
		if origin and offset then
			return origin + offset
		end
		return nil
	end)
end

--- Returns the player's eye angles as an EulerAngles object
---@return EulerAngles The player's eye angles
function WrappedPlayer:GetEyeAngles()
	local cache = self:Cache()
	return cacheValue(cache, "eyeAngles", function()
		local ang = self._basePlayer:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
		if ang then
			return EulerAngles(ang.x, ang.y, ang.z)
		end
		return nil
	end)
end

function WrappedPlayer:GetAbsOrigin()
	local cache = self:Cache()
	return cacheValue(cache, "absOrigin", function()
		return self._basePlayer:GetAbsOrigin()
	end)
end

function WrappedPlayer:GetVelocity()
	local cache = self:Cache()
	return cacheValue(cache, "velocity", function()
		return self._basePlayer:EstimateAbsVelocity()
	end)
end

--- Returns the world position the player is looking at by tracing a ray
---@return Vector3|nil The look position or nil if trace failed
function WrappedPlayer:GetLookPos()
	local cache = self:Cache()
	return cacheValue(cache, "lookPos", function()
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
	local w = self._basePlayer:GetPropEntity("m_hActiveWeapon")
	return w and Common.WWeapon.FromEntity(w) or nil
end

function WrappedPlayer:GetActiveWeaponID()
	local cache = self:Cache()
	return cacheValue(cache, "weaponID", function()
		local weapon = self:GetActiveWeapon()
		if weapon and weapon.GetWeaponID then
			return weapon:GetWeaponID()
		end
		return nil
	end)
end

function WrappedPlayer:GetWeaponChargeData()
	local cache = self:Cache()
	return cacheValue(cache, "weaponCharge", function()
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
	return self._basePlayer:GetPropInt("m_iObserverMode")
end

--- Returns the player's observer target wrapper
---@return WrappedPlayer|nil The observer target or nil
function WrappedPlayer:GetObserverTarget()
	local target = self._basePlayer:GetPropEntity("m_hObserverTarget")
	return target and WrappedPlayer.FromEntity(target) or nil
end

--- Returns the next attack time
---@return number The next attack time
function WrappedPlayer:GetNextAttack()
	return self._basePlayer:GetPropFloat("m_flNextAttack")
end

function WrappedPlayer:GetTeamNumber()
	return self._basePlayer:GetTeamNumber()
end

function WrappedPlayer:SetPriority(level)
	if not level then
		return false
	end
	local success = pcall(playerlist.SetPriority, self._rawEntity or self._basePlayer, level)
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
