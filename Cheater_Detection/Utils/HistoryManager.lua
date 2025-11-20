--[[ HistoryManager.lua
     Centralized history sampling orchestrator.
     Detections declare how many ticks of history they need and which fields.
     The manager captures only the required data, trims old entries, and reuses
     record tables to minimize garbage churn.
]]

local PlayerState = require("Cheater_Detection.Utils.PlayerState")
local Logger = require("Cheater_Detection.Utils.Logger")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")

---@class HistoryManager
local HistoryManager = {}

local recordPool = {}
local consumers = {}
local activeFields = {}
local maxRetentionTicks = 0

local DEFAULT_RETENTION_TICKS = 33 -- Reduced from 66 to save memory

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

local FIELD_BUILDERS = {
	[HistoryManager.Fields.Angles] = function(player)
		return player:GetEyeAngles()
	end,
	[HistoryManager.Fields.EyePosition] = function(player)
		return player:GetEyePos()
	end,
	[HistoryManager.Fields.HeadHitbox] = function(player)
		return player.GetHitboxPos and player:GetHitboxPos(1) or nil
	end,
	[HistoryManager.Fields.BodyHitbox] = function(player)
		return player.GetHitboxPos and player:GetHitboxPos(4) or nil
	end,
	[HistoryManager.Fields.SimulationTime] = function(player)
		return player:GetSimulationTime()
	end,
	[HistoryManager.Fields.OnGround] = function(player)
		return player:IsOnGround()
	end,
	[HistoryManager.Fields.Velocity] = function(player)
		return player:GetVelocity()
	end,
	[HistoryManager.Fields.ViewOffset] = function(player)
		return player:GetViewOffset()
	end,
}

local function acquireRecord()
	local record = recordPool[#recordPool]
	if record then
		recordPool[#recordPool] = nil
		return record
	end
	return {}
end

local function recycleRecord(record)
	for key in pairs(record) do
		record[key] = nil
	end
	recordPool[#recordPool + 1] = record
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

local function buildRecord(player)
	local record = acquireRecord()
	local hasData = false
	for field in pairs(activeFields) do
		local builder = FIELD_BUILDERS[field]
		if builder then
			local value = builder(player)
			if value ~= nil then
				record[field] = value
				hasData = true
			else
				record[field] = nil
			end
		end
	end
	record.tick = globals.TickCount()
	return hasData and record or nil
end

local function trimHistory(history)
	local limit = (maxRetentionTicks > 0 and maxRetentionTicks) or DEFAULT_RETENTION_TICKS
	while #history > limit do
		recycleRecord(table.remove(history, 1))
	end
end

---Register a detection/module that needs history data.
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

---Unregister a consumer (e.g., when detection unloads).
---@param name string
function HistoryManager.UnregisterConsumer(name)
	if not consumers[name] then
		return
	end
	consumers[name] = nil
	recomputeRequirements()
end

---Push a snapshot for the given player if any fields are active.
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

	TickProfiler.BeginSection("History_BuildRecord")
	local record = buildRecord(player)
	TickProfiler.EndSection("History_BuildRecord")

	if not record then
		return
	end

	local state = PlayerState.GetOrCreate(steamID)
	if not state then
		recycleRecord(record)
		return
	end

	state.History = state.History or {}
	state.History[#state.History + 1] = record
	state.Current = record

	TickProfiler.BeginSection("History_Trim")
	trimHistory(state.History)
	TickProfiler.EndSection("History_Trim")
end

---Expose current retention tick count (max of all consumers).
---@return integer
function HistoryManager.GetRetentionTicks()
	return (maxRetentionTicks > 0 and maxRetentionTicks) or DEFAULT_RETENTION_TICKS
end

---Expose currently active field set (copy).
---@return table<string, boolean>
function HistoryManager.GetActiveFields()
	local copy = {}
	for field in pairs(activeFields) do
		copy[field] = true
	end
	return copy
end

local function ensureLegacyConsumer()
	if activeFields and next(activeFields) then
		return
	end

	HistoryManager.RegisterConsumer("__legacy_default", {
		retentionTicks = DEFAULT_RETENTION_TICKS,
		fields = {
			HistoryManager.Fields.Angles,
			HistoryManager.Fields.EyePosition,
			HistoryManager.Fields.HeadHitbox,
			HistoryManager.Fields.BodyHitbox,
			HistoryManager.Fields.SimulationTime,
			HistoryManager.Fields.OnGround,
		},
	})
end

ensureLegacyConsumer()

function HistoryManager.RemoveLegacyConsumer()
	if consumers.__legacy_default then
		consumers.__legacy_default = nil
		recomputeRequirements()
	end
end

return HistoryManager
