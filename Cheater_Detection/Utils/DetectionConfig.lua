--[[ DetectionConfig.lua
     Centralized configuration for all detection modules.
     Specifies history requirements (retention ticks and fields) per detector.
     Read by HistoryManager to size the ring buffer once at init.
]]

local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

local DetectionConfig = {}

DetectionConfig.Detectors = {
	-- ~5 ticks pre-shot extrapolation + shot + 3 post; fire tick eye patched via ApplyFireSnapshot.
	SilentAim = {
		retentionTicks = 12,
		fields = {
			HistoryManager.Fields.Angles,
			HistoryManager.Fields.EyePosition,
		},
	},
	FakeLag = {
		retentionTicks = 40, -- room for 3+ choke→release cycles plus stalls between
		fields = { HistoryManager.Fields.SimulationTime },
	},
	-- Double Tap: same simtime ring; burst scan needs depth when FL masks delta[1].
	DoubleTap = {
		retentionTicks = 40,
		fields = { HistoryManager.Fields.SimulationTime },
	},
}

DetectionConfig.DefaultRetentionTicks = 24

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

--- Record all history fields required by a detector for this tick (deduped inside HistoryManager).
function DetectionConfig.RecordHistory(player, detectorName)
	if not player then return end
	local spec = DetectionConfig.Detectors[detectorName]
	if not spec or not spec.fields then return end
	HistoryManager.RequestFields(player, spec.fields)
end

return DetectionConfig
