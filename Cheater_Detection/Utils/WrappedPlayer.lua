-- Cheater_Detection/Core/WrappedPlayer.lua
-- Provides a wrapper class for player entities to add helper methods.

local WrappedPlayer = {}
WrappedPlayer.__index = WrappedPlayer

-- Define player flag constants (ensure these are correct for TF2/Lmaobox)
local FL_ONGROUND = 1 -- Example, verify correct value

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

-- Get player index
--- @return number
function WrappedPlayer:GetIndex()
	return self._rawEntity:GetIndex()
end

-- Get User ID
--- @return number or nil
function WrappedPlayer:GetUserID()
	local index = self:GetIndex()
	local info = client.GetPlayerInfo(index)
	return info and info.UserID or nil
end

-- Get team number
--- @return number
function WrappedPlayer:GetTeamNumber()
	return self._rawEntity:GetTeamNumber()
end

-- Check if alive
--- @return boolean
function WrappedPlayer:IsAlive()
	return self._rawEntity:IsAlive()
end

-- Get health
--- @return number
function WrappedPlayer:GetHealth()
	return self._rawEntity:GetHealth()
end

-- Get origin
--- @return Vector3
function WrappedPlayer:GetAbsOrigin()
	return self._rawEntity:GetAbsOrigin()
end

-- Check if player is on the ground using correct bitwise check
--- @return boolean
function WrappedPlayer:IsOnGround()
	local flags = self._rawEntity:GetPropInt("m_fFlags")
	-- Use correct bitwise AND check, comparing result to 0 (non-zero)
	return (flags & FL_ONGROUND) ~= 0
end

-- Add more wrapper methods as needed, mirroring the lnxLib example
-- or adding custom functionality. Examples:
-- function WrappedPlayer:GetEyePos() ... end
-- function WrappedPlayer:GetHitboxPos(hitboxID) ... end
-- function WrappedPlayer:GetActiveWeapon() ... end

print("[WrappedPlayer] Module loaded.")
return WrappedPlayer
