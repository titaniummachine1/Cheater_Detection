--[[ HistoryManager.lua
     Player-centric circular buffer for tick history.
       - Each player has their own circular buffer: playerHistories[steamID]
       - Buffer is an ipairs-traversable array: [1]=current tick, [2]=1 tick ago, etc.
       - Circular overwrite: new data overwrites oldest when buffer full
       - No per-tick bucket clearing needed
]]

local PlayerCache       = require("Cheater_Detection.Core.player_cache")

local HistoryManager    = {}

HistoryManager.Fields   = {
	Angles = "angles",
	EyePosition = "eye_pos",
	HeadHitbox = "hitbox_head",
	BodyHitbox = "hitbox_body",
	SimulationTime = "sim_time",
	OnGround = "on_ground",
	Velocity = "velocity",
	ViewOffset = "view_offset",
}

local activeFields      = {}
local _hasActiveFields  = false
local maxRetentionTicks = 0
local initialized       = false

-- playerHistories[steamID] = { [1]=current, [2]=prev, ..., _head=N, _count=N, _tick=N }
local playerHistories   = {}

-- Field builders that mutate an existing slot table in-place to avoid allocation.
-- Each receives (player, record) and writes directly into record[field].
local function reuseVec(record, field, v)
	if not v then
		record[field] = nil
		return
	end
	local t = record[field]
	if type(t) ~= "table" then
		t = {}
		record[field] = t
	end
	t.x = v.x
	t.y = v.y
	t.z = v.z
end

local FIELD_WRITERS = {
	[HistoryManager.Fields.Angles] = function(player, record, field)
		local ang = player:GetEyeAngles()
		if not ang then
			record[field] = nil
			return
		end
		local t = record[field]
		if type(t) ~= "table" then
			t = {}
			record[field] = t
		end
		t.pitch = ang.pitch
		t.yaw   = ang.yaw
	end,
	[HistoryManager.Fields.EyePosition] = function(player, record, field)
		reuseVec(record, field, player:GetEyePos())
	end,
	[HistoryManager.Fields.HeadHitbox] = function(player, record, field)
		reuseVec(record, field, player:GetHitboxPos(1))
	end,
	[HistoryManager.Fields.BodyHitbox] = function(player, record, field)
		reuseVec(record, field, player:GetHitboxPos(4))
	end,
	[HistoryManager.Fields.SimulationTime] = function(player, record, field)
		record[field] = player:GetSimulationTime()
	end,
	[HistoryManager.Fields.OnGround] = function(player, record, field)
		record[field] = player:IsOnGround()
	end,
	[HistoryManager.Fields.Velocity] = function(player, record, field)
		reuseVec(record, field, player:GetVelocity())
	end,
	[HistoryManager.Fields.ViewOffset] = function(player, record, field)
		reuseVec(record, field, player:GetViewOffset())
	end,
}

function HistoryManager.Initialize(retentionTicks, fields)
	if initialized and maxRetentionTicks == retentionTicks then
		return
	end

	maxRetentionTicks = retentionTicks or 33
	activeFields = fields or {}
	_hasActiveFields = next(activeFields) ~= nil
	if not _hasActiveFields then
		print(
			"[HistoryManager WARNING] No active fields configured — was DetectionConfig.RegisterWithHistoryManager() called?")
	end

	for steamID, history in pairs(playerHistories) do
		history._head = 1
		history._count = 0
		history._lastTick = -1
		for i = 1, maxRetentionTicks do
			history[i] = nil
		end
	end

	initialized = true
end

-- Get player's full history array. Use ipairs to traverse.
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

-- Get specific record by offset (0=current, 1=1 tick ago, etc.)
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

-- Direct record access by offset on already-retrieved history object.
function HistoryManager.GetRecordAt(history, offset)
	local idx = recordIndexForOffset(history, offset)
	return idx and history[idx]
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
end

-- PER-FIELD LAZY RECORDING
-- Track which fields are already stored for current tick to avoid re-calculation
-- [steamID] = { [field] = tickWhenStored, ... }
local _storedFieldsByPlayer = {}

-- Request a field be recorded for a player. If already recorded this tick, returns immediately.
-- Detectors call this to request fields on-demand instead of pre-recording all fields.
function HistoryManager.RequestField(player, field)
	if not _hasActiveFields then return nil end
	if not activeFields[field] then return nil end

	local steamID = tostring(player:GetSteamID64())
	local curTick = globals.TickCount()

	-- Check if field already stored this tick
	local stored = _storedFieldsByPlayer[steamID]
	if stored and stored[field] == curTick then
		return nil -- Already recorded, skip
	end

	-- Ensure we have a history for this player
	local history = playerHistories[steamID]
	if not history then
		history = { _head = 0, _count = 0, _lastTick = -1 }
		playerHistories[steamID] = history
	end

	-- Lazily advance this player's circular-buffer head once per tick
	if history._lastTick ~= curTick then
		history._head = (history._head % maxRetentionTicks) + 1
		if history._count < maxRetentionTicks then
			history._count = history._count + 1
		end
		history._lastTick = curTick
		-- Clear stored fields tracking when advancing to new tick slot
		if stored then
			for f in pairs(stored) do
				stored[f] = nil
			end
		end
	end

	-- Reuse existing slot table
	local headSlot = history._head
	local record = history[headSlot]
	if type(record) ~= "table" then
		record = {}
	end

	-- Record the field
	local writer = FIELD_WRITERS[field]
	if writer then
		writer(player, record, field)
	end

	-- Mark field as stored for this tick
	if not stored then
		stored = {}
		_storedFieldsByPlayer[steamID] = stored
	end
	stored[field] = curTick
	record._tick = curTick
	history[history._head] = record

	return record[field]
end

-- Legacy Push - records all active fields at once. Use RequestField for per-field lazy recording.
function HistoryManager.Push(player)
	if not _hasActiveFields then return end

	for field in pairs(activeFields) do
		HistoryManager.RequestField(player, field)
	end
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
	local id = tostring(steamID)
	playerHistories[id] = nil
	_storedFieldsByPlayer[id] = nil
end

function HistoryManager.PushAngles(steamID, pitch, yaw)
	if not initialized or not steamID then
		return
	end

	local history = playerHistories[tostring(steamID)]
	if not history then
		history = { _head = 0, _count = 0, _lastTick = -1 }
		playerHistories[tostring(steamID)] = history
	end

	local curTick = globals.TickCount()

	if history._lastTick ~= curTick then
		history._head = (history._head % maxRetentionTicks) + 1
		if history._count < maxRetentionTicks then
			history._count = history._count + 1
		end
		history._lastTick = curTick
	end

	local record = history[history._head]
	if type(record) ~= "table" then
		record = {}
	end
	local angField = HistoryManager.Fields.Angles
	local t = record[angField]
	if type(t) ~= "table" then
		t = {}
		record[angField] = t
	end
	t.pitch                = pitch
	t.yaw                  = yaw
	record._tick           = curTick
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

-- Debug function to set a field in a player's history
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
