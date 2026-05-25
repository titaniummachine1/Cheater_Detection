--[[ HistoryManager.lua
     Player-centric circular buffer for tick history.

     NEW Architecture:
       - Each player has their own circular buffer: playerHistories[steamID]
       - Buffer is an ipairs-traversable array: [1]=current tick, [2]=1 tick ago, etc.
       - Circular overwrite: new data overwrites oldest when buffer full
       - No per-tick bucket clearing needed

     Old API Compatibility:
       - GetBucketAt(offset) -> adapter to new structure
       - GetPlayerDataInBucket(bucket, steamID) -> adapter
]]

local PlayerCache         = require("Cheater_Detection.Core.player_cache")
local G                   = require("Cheater_Detection.Utils.Globals")

local HistoryManager      = {}

HistoryManager.Fields     = {
	Angles = "angles",
	EyePosition = "eye_pos",
	HeadHitbox = "hitbox_head",
	BodyHitbox = "hitbox_body",
	SimulationTime = "sim_time",
	OnGround = "on_ground",
	Velocity = "velocity",
	ViewOffset = "view_offset",
}

local activeFields        = {}
local maxRetentionTicks   = 0
local initialized         = false

local tickLocalPlayer     = nil
local tickLocalPlayerTick = -1

-- Cache for detector enablement to avoid menu lookups every tick
local lastCheckTick       = -1
local historyEnabled      = false

local function isHistoryEnabled()
	local curTick = globals.TickCount()
	if curTick ~= lastCheckTick then
		lastCheckTick = curTick
		local menu = G.Menu
		local adv = menu and menu.Advanced
		-- History needed for SilentAim, WarpDT, FakeLag, AntiAim
		historyEnabled = (adv and (adv.SilentAimbot or adv["Warp"] or adv.Choke or adv.AntiAim)) == true
	end
	return historyEnabled
end

local function getTickLocalPlayer()
	local curTick = globals.TickCount()
	if curTick ~= tickLocalPlayerTick then
		tickLocalPlayerTick = curTick
		tickLocalPlayer     = entities.GetLocalPlayer()
	end
	return tickLocalPlayer
end

-- NEW: Player-centric storage
-- playerHistories[steamID] = { [1]=current, [2]=prev, ..., _head=N, _count=N, _tick=N }
local playerHistories = {}

-- For old API compatibility: we maintain a "virtual" tick-based view
-- This maps tick offsets to the player history indices
local currentTickNum = -1

local function tryGetTFNonLocalEyeAngles(player)
	if not player or not player.GetPropFloat then
		return nil
	end
	local pitch = player:GetPropFloat("tfnonlocaldata", "m_angEyeAngles[0]")
	local yaw = player:GetPropFloat("tfnonlocaldata", "m_angEyeAngles[1]")
	if type(pitch) ~= "number" or type(yaw) ~= "number" then
		return nil
	end
	return pitch, yaw
end

local FIELD_BUILDERS = {
	[HistoryManager.Fields.Angles] = function(player)
		local localPlayer = getTickLocalPlayer()
		if localPlayer and localPlayer.IsValid and localPlayer:IsValid() then
			if localPlayer.GetIndex and player.GetIndex and localPlayer:GetIndex() == player:GetIndex() then
				local pitchNL, yawNL = tryGetTFNonLocalEyeAngles(player)
				if pitchNL ~= nil and yawNL ~= nil then
					return pitchNL, yawNL
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
		return pitch, yaw
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

function HistoryManager.Initialize(retentionTicks, fields)
	if initialized and maxRetentionTicks == retentionTicks then
		return
	end

	maxRetentionTicks = retentionTicks or 33
	activeFields = fields or {}

	-- Clear existing histories if capacity changed
	for steamID, history in pairs(playerHistories) do
		-- Reinitialize with new capacity
		history._head = 1
		history._count = 0
		for i = 1, maxRetentionTicks do
			history[i] = nil
		end
	end

	initialized = true
end

-- NEW API: Get player's full history array (ipairs-friendly)
-- Returns: { [1]=current, [2]=prev, ..., _head, _count, _tick }
-- Use ipairs to traverse: for i, record in ipairs(history) do ... end
function HistoryManager.GetPlayerHistory(steamID)
	if not initialized or not steamID then
		return nil
	end
	return playerHistories[tostring(steamID)]
end

-- Circular buffer index: offset 0 = newest (_head), 1 = one tick ago, etc.
local function recordIndexForOffset(history, offset)
	if not history or offset < 0 or offset >= history._count then
		return nil
	end
	local idx = history._head - offset
	while idx < 1 do
		idx = idx + maxRetentionTicks
	end
	return idx
end

-- Walk records newest-first. callback(offset, record) — stop if it returns false.
function HistoryManager.ForEachRecordNewestFirst(history, maxRecords, callback)
	if not history or not callback or history._count == 0 then
		return
	end
	local limit = math.min(history._count, maxRecords or history._count)
	for offset = 0, limit - 1 do
		local idx = recordIndexForOffset(history, offset)
		local record = idx and history[idx]
		if record and callback(offset, record) == false then
			return
		end
	end
end

-- NEW API: Get specific record from player history by offset
-- offset=0: current tick, offset=1: 1 tick ago, etc.
function HistoryManager.GetPlayerRecordAt(steamID, offset)
	if not initialized or not steamID then
		return nil
	end
	local history = playerHistories[tostring(steamID)]
	if not history then
		return nil
	end

	local idx = recordIndexForOffset(history, offset)
	if not idx then
		return nil
	end

	return history[idx]
end

-- Get the maximum history depth across all players
function HistoryManager.GetRingCount()
	if not initialized then
		return 0
	end
	local maxCount = 0
	for _, history in pairs(playerHistories) do
		if history._count > maxCount then
			maxCount = history._count
		end
	end
	return maxCount
end

function HistoryManager.IsInitialized()
	return initialized
end

-- Direct record access by offset on an already-retrieved history object.
-- Avoids the steamID table lookup that GetPlayerRecordAt performs.
-- offset 0 = newest, 1 = one tick ago, etc.
function HistoryManager.GetRecordAt(history, offset)
	local idx = recordIndexForOffset(history, offset)
	return idx and history[idx]
end

local lastTickCount = -1

function HistoryManager.NewTick()
	if not initialized then
		return
	end
	if not isHistoryEnabled() then
		return
	end
	local curTick = globals.TickCount()
	if curTick == lastTickCount then
		return
	end
	lastTickCount = curTick
	currentTickNum = curTick

	-- Advance each player's circular buffer
	for steamID, history in pairs(playerHistories) do
		-- Move head forward (circular)
		history._head = (history._head % maxRetentionTicks) + 1
		-- Increase count until max
		if history._count < maxRetentionTicks then
			history._count = history._count + 1
		end
		-- Keep the slot table alive so Push can reuse it (avoids per-tick allocation)
	end
end

function HistoryManager.Push(player)
	if not initialized or not next(activeFields) then
		return
	end
	if not isHistoryEnabled() then
		return
	end
	if not player or type(player.GetSteamID64) ~= "function" then
		return
	end

	local steamIDRaw = player:GetSteamID64()
	if not steamIDRaw then
		return
	end

	local steamID = tostring(steamIDRaw)
	local state = PlayerCache.GetByID(steamID)
	if not state then
		return
	end

	-- Ensure we have a history for this player
	local history = playerHistories[steamID]
	if not history then
		history = { _head = 0, _count = 0 }
		playerHistories[steamID] = history
	end

	local curTick = globals.TickCount()
	if curTick ~= lastTickCount then
		HistoryManager.NewTick()
	end

	-- Reuse existing slot table to avoid per-tick allocation
	local headSlot = history._head
	local record   = history[headSlot]
	if type(record) ~= "table" then
		record = {}
	end

	for field in pairs(activeFields) do
		local builder = FIELD_BUILDERS[field]
		if builder then
			if field == HistoryManager.Fields.Angles then
				local pitch, yaw = builder(player)
				if pitch ~= nil and yaw ~= nil then
					local a = record[field]
					if type(a) ~= "table" then
						a = {}
						record[field] = a
					end
					a.pitch = pitch
					a.yaw   = yaw
				else
					record[field] = nil
				end
			else
				record[field] = builder(player)
			end
		end
	end

	record._tick = curTick

	-- Write at current head position
	history[history._head] = record

	state.current = record
end

function HistoryManager.MarkDamageDealt(steamID)
	if not initialized or not steamID then
		return
	end

	local history = playerHistories[tostring(steamID)]
	if not history or history._count == 0 then
		return
	end

	-- Mark at current head position
	local record = history[history._head]
	if record then
		record.damageDealt = true
	end
end

function HistoryManager.ClearPlayer(steamID)
	if not initialized or not steamID then
		return
	end
	playerHistories[tostring(steamID)] = nil
end

function HistoryManager.PushAngles(steamID, pitch, yaw)
	if not initialized or not steamID then
		return
	end

	local history = playerHistories[tostring(steamID)]
	if not history then
		history = { _head = 0, _count = 0 }
		playerHistories[tostring(steamID)] = history
	end

	local curTick = globals.TickCount()
	if curTick ~= lastTickCount then
		HistoryManager.NewTick()
	end

	local record = history[history._head] or {}
	record[HistoryManager.Fields.Angles] = { pitch = pitch, yaw = yaw }
	record._tick = curTick
	history[history._head] = record
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

-- NEW API: Debug function to set a field in a player's history
function HistoryManager.DebugSetPlayerFieldAt(bufferOffset, steamID, fieldName, value)
	if not initialized or bufferOffset == nil or bufferOffset < 0 then
		return false
	end
	if not steamID or not fieldName then
		return false
	end
	local id = tostring(steamID)
	if not PlayerCache.GetByID(id) then
		return false
	end

	local history = playerHistories[id]
	if not history then
		return false
	end

	local idx = bufferOffset + 1
	if idx > history._count then
		return false
	end

	history[idx][fieldName] = value
	return true
end

return HistoryManager
