--[[ HistoryManager.lua
     Tick-bucket circular buffer for player history.
     Architecture:
       - Circular buffer of tick-buckets
       - Each bucket: { [steamID] = { field1 = val, field2 = val, ... }, _tick = n }
       - Push does shallow-merge: only writes fields that are non-nil, preserves existing data
       - Overflow = clear bucket then overwrite
       - All detectors share same data source
]]

local PlayerCache = require("Cheater_Detection.Core.player_cache")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")

local HistoryManager = {}

HistoryManager.Fields = {
	Angles = "angles",
	EyePosition = "eye_pos",
	HeadHitbox = "hitbox_head",
	BodyHitbox = "hitbox_body",
	SimulationTime = "sim_time",
	OnGround = "on_ground",
	Velocity = "velocity",
	ViewOffset = "view_offset",
}

local activeFields = {}
local maxRetentionTicks = 0
local initialized = false

local ringBuffer = {}
local ringHead = 0
local ringCount = 0
local ringCapacity = 0

local function tryGetTFNonLocalEyeAngles(player)
	if not player or not player.GetPropFloat then
		return nil
	end
	local pitch = player:GetPropFloat("tfnonlocaldata", "m_angEyeAngles[0]")
	local yaw = player:GetPropFloat("tfnonlocaldata", "m_angEyeAngles[1]")
	if type(pitch) ~= "number" or type(yaw) ~= "number" then
		return nil
	end
	return { pitch = pitch, yaw = yaw }
end

local FIELD_BUILDERS = {
	[HistoryManager.Fields.Angles] = function(player)
		local localPlayer = entities.GetLocalPlayer and entities.GetLocalPlayer() or nil
		if localPlayer and localPlayer.IsValid and localPlayer:IsValid() then
			if localPlayer.GetIndex and player.GetIndex and localPlayer:GetIndex() == player:GetIndex() then
				local angNL = tryGetTFNonLocalEyeAngles(player)
				if angNL then
					return angNL
				end
			end
		end
		local ang = player.GetEyeAngles and player:GetEyeAngles()
		if not ang then
			return nil
		end
		local pitch = ang.pitch
		local yaw = ang.yaw
		if pitch == nil or yaw == nil then
			return nil
		end
		return { pitch = pitch, yaw = yaw }
	end,
	[HistoryManager.Fields.EyePosition] = function(player)
		return player.GetEyePos and player:GetEyePos()
	end,
	[HistoryManager.Fields.HeadHitbox] = function(player)
		return player.GetHitboxPos and player:GetHitboxPos(1)
	end,
	[HistoryManager.Fields.BodyHitbox] = function(player)
		return player.GetHitboxPos and player:GetHitboxPos(4)
	end,
	[HistoryManager.Fields.SimulationTime] = function(player)
		if player.GetSimulationTime then
			return player:GetSimulationTime()
		end
		if player.GetPropFloat then
			return player:GetPropFloat("m_flSimulationTime")
		end
		return nil
	end,
	[HistoryManager.Fields.OnGround] = function(player)
		return player.IsOnGround and player:IsOnGround()
	end,
	[HistoryManager.Fields.Velocity] = function(player)
		if player.GetVelocity then
			return player:GetVelocity()
		end
		if player.EstimateAbsVelocity then
			return player:EstimateAbsVelocity()
		end
		return nil
	end,
	[HistoryManager.Fields.ViewOffset] = function(player)
		return player.GetViewOffset and player:GetViewOffset()
	end,
}

local function clearBucket(bucket)
	for k in pairs(bucket) do
		bucket[k] = nil
	end
end

function HistoryManager.Initialize(retentionTicks, fields)
	if initialized and maxRetentionTicks == retentionTicks then
		return
	end

	maxRetentionTicks = retentionTicks or 33
	activeFields = fields or {}
	ringCapacity = maxRetentionTicks

	for i = 1, ringCapacity do
		ringBuffer[i] = {}
	end

	ringHead = 0
	ringCount = 0

	initialized = true
end

function HistoryManager.GetBucketAt(bufferOffset)
	if not initialized or bufferOffset < 0 or bufferOffset >= ringCount then
		return nil
	end
	local idx = (ringHead - bufferOffset - 1) % ringCapacity + 1
	return ringBuffer[idx]
end

function HistoryManager.GetPlayerDataInBucket(bucket, steamID)
	if not bucket then
		return nil
	end
	if not steamID then
		return nil
	end
	if not PlayerCache.GetByID(tostring(steamID)) then
		return nil
	end
	return bucket[steamID]
end

function HistoryManager.GetPlayerFieldAt(bucket, steamID, fieldName)
	if not bucket or not steamID then
		return nil
	end
	if not PlayerCache.GetByID(tostring(steamID)) then
		return nil
	end
	local playerData = bucket[steamID]
	return playerData and playerData[fieldName]
end

function HistoryManager.GetTickAt(bufferOffset)
	local bucket = HistoryManager.GetBucketAt(bufferOffset)
	return bucket and bucket._tick or nil
end

function HistoryManager.GetRingCount()
	return ringCount
end

function HistoryManager.IsInitialized()
	return initialized
end

local lastTickCount = -1

function HistoryManager.NewTick()
	if not initialized then
		return
	end
	local curTick = globals.TickCount()
	if curTick == lastTickCount then
		return
	end
	lastTickCount = curTick

	ringHead = ringHead % ringCapacity + 1
	if ringCount < ringCapacity then
		ringCount = ringCount + 1
	end

	local currentBucket = ringBuffer[ringHead]
	clearBucket(currentBucket)
	currentBucket._tick = curTick
end

function HistoryManager.Push(player)
	if not initialized or not next(activeFields) then
		return
	end
	if not player or type(player.GetSteamID64) ~= "function" then
		return
	end

	local steamID = player:GetSteamID64()
	if not steamID then
		return
	end

	local state = PlayerCache.GetByID(tostring(steamID))
	if not state then
		return
	end

	TickProfiler.BeginSection("History_Write")

	local currentBucket = ringBuffer[ringHead]
	if not currentBucket or currentBucket._tick ~= globals.TickCount() then
		HistoryManager.NewTick()
		currentBucket = ringBuffer[ringHead]
	end

	local existingPlayerData = currentBucket[steamID]
	if not existingPlayerData then
		existingPlayerData = {}
		currentBucket[steamID] = existingPlayerData
	end

	for field in pairs(activeFields) do
		local builder = FIELD_BUILDERS[field]
		if builder then
			local value = builder(player)
			existingPlayerData[field] = value
		end
	end

	state.current = existingPlayerData

	TickProfiler.EndSection("History_Write")
end

function HistoryManager.MarkDamageDealt(steamID)
	if not initialized then
		return
	end
	local currentBucket = ringBuffer[ringHead]
	if not currentBucket then
		return
	end
	local playerData = currentBucket[steamID]
	if not playerData then
		playerData = {}
		currentBucket[steamID] = playerData
	end
	playerData.damageDealt = true
end

function HistoryManager.ClearPlayer(steamID)
	if not initialized then
		return
	end
	if not steamID then
		return
	end
	local id = tostring(steamID)
	for i = 1, ringCapacity do
		local bucket = ringBuffer[i]
		if bucket then
			bucket[id] = nil
		end
	end
end

function HistoryManager.PushAngles(steamID, pitch, yaw)
	if not initialized then
		return
	end
	if not steamID then
		return
	end

	local currentBucket = ringBuffer[ringHead]
	if not currentBucket or currentBucket._tick ~= globals.TickCount() then
		HistoryManager.NewTick()
		currentBucket = ringBuffer[ringHead]
	end
	if not currentBucket then
		return
	end

	local playerData = currentBucket[steamID]
	if not playerData then
		playerData = {}
		currentBucket[steamID] = playerData
	end

	if pitch ~= nil and yaw ~= nil then
		playerData[HistoryManager.Fields.Angles] = { pitch = pitch, yaw = yaw }
	end
end

function HistoryManager.GetRetentionTicks()
	return maxRetentionTicks
end

function HistoryManager.GetActiveFields()
	local copy = {}
	for field in pairs(activeFields) do
		copy[field] = true
	end
	return copy
end

function HistoryManager.DebugSetPlayerFieldAt(bufferOffset, steamID, fieldName, value)
	if not initialized then
		return false
	end
	if bufferOffset == nil or bufferOffset < 0 then
		return false
	end
	if not steamID or not fieldName then
		return false
	end
	local id = tostring(steamID)
	if not PlayerCache.GetByID(id) then
		return false
	end
	local bucket = HistoryManager.GetBucketAt(bufferOffset)
	if not bucket then
		return false
	end
	local playerData = bucket[id]
	if not playerData then
		playerData = {}
		bucket[id] = playerData
	end
	playerData[fieldName] = value
	return true
end

return HistoryManager
