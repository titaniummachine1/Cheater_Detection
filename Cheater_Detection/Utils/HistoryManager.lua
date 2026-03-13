--[[ HistoryManager.lua
     Circular-buffer history for per-player snapshots.
     Detections register how many ticks they need; capacity = max of all consumers.
     Records are preallocated and overwritten in-place — zero per-tick allocation.
     Exposes array-like read access via metatable so consumers iterate normally.
]]

local PlayerState = require("Cheater_Detection.Utils.PlayerState")
local Logger = require("Cheater_Detection.Utils.Logger")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")

local HistoryManager = {}

local consumers = {}
local activeFields = {}
local maxRetentionTicks = 0

local DEFAULT_RETENTION_TICKS = 33

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

--[[ Field Builders ]]

local function buildAngles(player) return player:GetEyeAngles() end
local function buildEyePos(player) return player:GetEyePos() end
local function buildHeadHitbox(player) return player.GetHitboxPos and player:GetHitboxPos(1) end
local function buildBodyHitbox(player) return player.GetHitboxPos and player:GetHitboxPos(4) end
local function buildSimTime(player) return player:GetSimulationTime() end
local function buildOnGround(player) return player:IsOnGround() end
local function buildVelocity(player) return player:GetVelocity() end
local function buildViewOffset(player) return player:GetViewOffset() end

local FIELD_BUILDERS = {
	[HistoryManager.Fields.Angles] = buildAngles,
	[HistoryManager.Fields.EyePosition] = buildEyePos,
	[HistoryManager.Fields.HeadHitbox] = buildHeadHitbox,
	[HistoryManager.Fields.BodyHitbox] = buildBodyHitbox,
	[HistoryManager.Fields.SimulationTime] = buildSimTime,
	[HistoryManager.Fields.OnGround] = buildOnGround,
	[HistoryManager.Fields.Velocity] = buildVelocity,
	[HistoryManager.Fields.ViewOffset] = buildViewOffset,
}

--[[ Ring buffer functions ]]

local function createRing(capacity)
	local buf = {}
	for i = 1, capacity do
		buf[i] = {
			tick = 0,
			-- Fields will be populated here
		}
	end
	
	return {
		_buf = buf,
		_head = 0,
		_count = 0,
		_capacity = capacity
	}
end

function HistoryManager.GetAt(ring, key)
	if not ring then return nil end
	local count = ring._count
	if key < 1 or key > count then
		return nil
	end
	local capacity = ring._capacity
	local head = ring._head
	local oldestSlot = (head - count) % capacity
	local slot = (oldestSlot + key - 1) % capacity + 1
	return ring._buf[slot]
end

function HistoryManager.GetCount(ring)
	return ring and ring._count or 0
end

local function ringPush(ring)
	local capacity = ring._capacity
	local head = ring._head
	local count = ring._count

	local nextHead = head % capacity + 1
	ring._head = nextHead

	if count < capacity then
		ring._count = count + 1
	end

	return ring._buf[nextHead]
end

local function ringClear(ring)
	ring._head = 0
	ring._count = 0
end

local function isRing(t)
	return type(t) == "table" and t._buf ~= nil
end

local function getCapacity()
	if maxRetentionTicks > 0 then
		return maxRetentionTicks
	end
	return DEFAULT_RETENTION_TICKS
end

local function recomputeRequirements()
	local newMax = 0
	local newFields = {}
	for _, spec in pairs(consumers) do
		if spec.retentionTicks > newMax then
			newMax = spec.retentionTicks
		end
		for field in pairs(spec.fields) do
			newFields[field] = true
		end
	end
	maxRetentionTicks = newMax
	activeFields = newFields
end

local function writeRecord(record, player)
	local hasData = false
	for field in pairs(activeFields) do
		local builder = FIELD_BUILDERS[field]
		if builder then
			local value = builder(player)
			record[field] = value
			if value ~= nil then
				hasData = true
			end
		end
	end
	record.tick = globals.TickCount()
	return hasData
end

local function ensureRing(state)
	local cap = getCapacity()
	local history = state.History

	if isRing(history) then
		if history._capacity == cap then
			return history
		end
		
		local newRing = createRing(cap)
		local oldCount = history._count
		local copyCount = math.min(oldCount, cap)
		local startIdx = oldCount - copyCount + 1
		
		for i = startIdx, oldCount do
			local src = HistoryManager.GetAt(history, i)
			if src then
				local dst = ringPush(newRing)
				for k, v in pairs(src) do
					dst[k] = v
				end
			end
		end
		state.History = newRing
		return newRing
	end

	local newRing = createRing(cap)

	if type(history) == "table" then
		local total = #history
		local copyCount = math.min(total, cap)
		local startIdx = total - copyCount + 1
		for i = startIdx, total do
			local src = history[i]
			if src then
				local dst = ringPush(newRing)
				for k, v in pairs(src) do
					dst[k] = v
				end
			end
		end
	end

	state.History = newRing
	return newRing
end

---@param name string
---@param spec { retentionTicks:number, fields:string[] }
function HistoryManager.RegisterConsumer(name, spec)
	assert(type(name) == "string" and name ~= "", "HistoryManager.RegisterConsumer requires a name")
	assert(type(spec) == "table", "HistoryManager.RegisterConsumer requires a spec table")

	local retention = math.max(1, tonumber(spec.retentionTicks) or DEFAULT_RETENTION_TICKS)
	local fieldSet = {}
	if type(spec.fields) == "table" then
		for _, field in ipairs(spec.fields) do
			if FIELD_BUILDERS[field] then
				fieldSet[field] = true
			else
				Logger.Warning(
					"HistoryManager",
					string.format("Unknown history field '%s' requested by %s", tostring(field), name)
				)
			end
		end
	end

	if not next(fieldSet) then
		Logger.Warning(
			"HistoryManager",
			string.format("Consumer %s registered without valid fields; ignoring registration", name)
		)
		return
	end

	consumers[name] = {
		retentionTicks = retention,
		fields = fieldSet,
	}

	recomputeRequirements()
end

---@param name string
function HistoryManager.UnregisterConsumer(name)
	if not consumers[name] then
		return
	end
	consumers[name] = nil
	recomputeRequirements()
end

---@param player table
function HistoryManager.Push(player)
	if not next(activeFields) then
		return
	end
	if not player or type(player.GetSteamID64) ~= "function" then
		return
	end

	local steamID = player:GetSteamID64()
	if not steamID then
		return
	end

	local state = PlayerState.GetOrCreate(steamID)
	if not state then
		return
	end

	local ring = ensureRing(state)

	TickProfiler.BeginSection("History_Write")
	local record = ringPush(ring)
	local hasData = writeRecord(record, player)
	TickProfiler.EndSection("History_Write")

	if hasData then
		state.Current = record
	end
end

---@return integer
function HistoryManager.GetRetentionTicks()
	return getCapacity()
end

---@return table<string, boolean>
function HistoryManager.GetActiveFields()
	local copy = {}
	for field in pairs(activeFields) do
		copy[field] = true
	end
	return copy
end

function HistoryManager.IsRing(t)
	return isRing(t)
end

function HistoryManager.ClearRing(ring)
	if isRing(ring) then
		ringClear(ring)
	end
end

return HistoryManager
