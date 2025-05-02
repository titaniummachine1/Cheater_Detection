-- Cheater_Detection/Core/WrappedPlayer.lua
-- Provides a wrapper class for player entities to add helper methods.

local WrappedPlayer = {}
WrappedPlayer.__index = WrappedPlayer

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")

--[[ Constructor ]]

-- Creates a WrappedPlayer from a given native Entity
-- @param entity (Entity) The raw player entity.
-- @return WrappedPlayer or nil if invalid
function WrappedPlayer.FromEntity(entity)
	if not entity or not entity:IsValid() then
		-- Returning nil might be safer depending on usage
		-- print("[WrappedPlayer] Warning: Attempted to wrap invalid entity.")
		return nil
	end

	local self = setmetatable({}, WrappedPlayer)
	-- Crucially store the raw entity as _rawEntity for FastPlayers compatibility
	self._rawEntity = entity
	return self
end

--[[ Wrapper Methods ]]
-- Add methods here that operate on self._rawEntity

-- Returns the underlying raw entity (useful for debugging or specific cases)
--- @return Entity
function WrappedPlayer:GetRawEntity()
	return self._rawEntity
end

---@param entity Entity
---@param checkFriend boolean?
---@param checkDormant boolean?
---@param skipEntity Entity? Optional entity to skip (e.g., the local player)
function WrappedPlayer:IsValidPlayer(entity, checkFriend, checkDormant, skipEntity)
	return Common.IsValidPlayer(entity, checkFriend, checkDormant, skipEntity)
end

-- Get SteamID64
--- @return number|string
function WrappedPlayer:GetSteamID64()
	return Common.GetSteamID64(self)
end

-- Check if player is on the ground using correct bitwise check
--- @return boolean
function WrappedPlayer:IsOnGround()
	local flags = self._rawEntity:GetPropInt("m_fFlags")
	-- Use correct bitwise AND check, comparing result to 0 (non-zero)
	return (flags & FL_ONGROUND) ~= 0
end

-- Returns the view offset from the player's origin as a Vector3
function WrappedPlayer:GetViewOffset()
	return self._rawEntity:GetPropVector("localdata", "m_vecViewOffset[0]")
end

-- Returns the player's eye position in world coordinates
function WrappedPlayer:GetEyePos()
	return self:GetAbsOrigin() + self:GetViewOffset()
end

-- Returns the player's eye angles as an EulerAngles object
function WrappedPlayer:GetEyeAngles()
	local ang = self._rawEntity:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
	return EulerAngles(ang.x, ang.y, ang.z)
end

-- Returns the world position the player is looking at by tracing a ray
function WrappedPlayer:GetLookPos()
	local eyePos = self:GetEyePos()
	local eyeAng = self:GetEyeAngles()
	local targetPos = eyePos + eyeAng:Forward() * 8192
	local tr = engine.TraceLine(eyePos, targetPos, MASK_SHOT)
	return tr and tr.endpos or nil
end

function WrappedPlayer:GetActiveWeapon()
	local w = self._rawEntity:GetPropEntity("m_hActiveWeapon")
	return w and WrappedWeapon.FromEntity(w) or nil
end

function WrappedPlayer:GetObserverMode()
	return self._rawEntity:GetPropInt("m_iObserverMode")
end

function WrappedPlayer:GetObserverTarget()
	local target = self._rawEntity:GetPropEntity("m_hObserverTarget")
	return WrappedPlayer.FromEntity(target)
end

function WrappedPlayer:GetNextAttack()
	return self._rawEntity:GetPropFloat("m_flNextAttack")
end

-- Hitbox-related helper methods
function WrappedPlayer:GetHitboxes()
	return engine.GetHitboxes(self._rawEntity)
end

function WrappedPlayer:GetHitboxPos(hitboxID)
	local hitboxes = self:GetHitboxes()
	local hb = hitboxes and hitboxes[hitboxID]
	if not hb then
		return nil
	end
	return (hb[1] + hb[2]) * 0.5
end

return WrappedPlayer
