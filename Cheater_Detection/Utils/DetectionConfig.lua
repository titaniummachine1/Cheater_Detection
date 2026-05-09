--[[ DetectionConfig.lua
     Centralized configuration for all detection modules.
     Specifies history requirements (retention ticks and fields) per detector.
     Read by HistoryManager to size the ring buffer once at init.
]]

local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

local DetectionConfig = {}

DetectionConfig.Detectors = {
	WarpDT = {
		retentionTicks = 33,
		fields = { HistoryManager.Fields.SimulationTime },
	},
	SilentAim = {
		retentionTicks = 10,
		fields = {
			HistoryManager.Fields.Angles,
			HistoryManager.Fields.EyePosition,
		},
	},
	FakeLag = {
		retentionTicks = 33,
		fields = { HistoryManager.Fields.SimulationTime },
	},
}

DetectionConfig.DefaultRetentionTicks = 33

function DetectionConfig.GetRetentionTicks()
	local maxTicks = DetectionConfig.DefaultRetentionTicks
	for _, spec in pairs(DetectionConfig.Detectors) do
		if spec.retentionTicks > maxTicks then
			maxTicks = spec.retentionTicks
		end
	end
	return maxTicks
end

function DetectionConfig.GetActiveFields()
	local fields = {}
	for _, spec in pairs(DetectionConfig.Detectors) do
		for _, field in ipairs(spec.fields) do
			fields[field] = true
		end
	end
	return fields
end

function DetectionConfig.RegisterWithHistoryManager()
	local retentionTicks = DetectionConfig.GetRetentionTicks()
	local activeFields = DetectionConfig.GetActiveFields()

	HistoryManager.Initialize(retentionTicks, activeFields)
end

return DetectionConfig
