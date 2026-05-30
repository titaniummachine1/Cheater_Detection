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
	-- Simtime ring: 25 ticks => 24 delta pairs. Scans read only newest N gaps (see GetSimDeltaDeltas).
	-- Live tune: cd_simhistory <ticks>  (floor = GetSimtimeMinRetentionTicks()).
	Simtime = {
		retentionTicks = 25,
		fields = { HistoryManager.Fields.SimulationTime },
	},
}

DetectionConfig.DefaultRetentionTicks = 24

-- Per-detector scan depths (clamped to retention - 1). Ring sized for DT (24), not FL (20).
DetectionConfig.SimtimeScanTargets = {
	FlScanDeltas          = 20, -- rhythm/sustained/choke-hold windows <= 20
	DtRecentScanDeltas    = 24, -- DT band [24,34); one gap can be 24t
	DtWatchingScanDeltas  = 24,
}

function DetectionConfig.GetRetentionTicks()
	local maxTicks = DetectionConfig.DefaultRetentionTicks
	for _, spec in pairs(DetectionConfig.Detectors) do
		if spec.retentionTicks > maxTicks then
			maxTicks = spec.retentionTicks
		end
	end
	return maxTicks
end

function DetectionConfig.GetSimtimeRetentionTicks()
	local spec = DetectionConfig.Detectors.Simtime
	return spec and spec.retentionTicks or DetectionConfig.DefaultRetentionTicks
end

function DetectionConfig.GetSimtimeMaxDeltaPairs()
	return math.max(0, DetectionConfig.GetSimtimeRetentionTicks() - 1)
end

--- Smallest ring that fits all configured simtime scan depths.
function DetectionConfig.GetSimtimeMinRetentionTicks()
	local targets = DetectionConfig.SimtimeScanTargets
	return math.max(
		targets.FlScanDeltas + 1,
		targets.DtRecentScanDeltas + 1,
		targets.DtWatchingScanDeltas + 1)
end

function DetectionConfig.GetSimtimeMaxScanDeltas()
	local targets = DetectionConfig.SimtimeScanTargets
	return math.max(
		targets.FlScanDeltas,
		targets.DtRecentScanDeltas,
		targets.DtWatchingScanDeltas)
end

--- Effective scan windows after clamping to ring size (FakeLag / DoubleTap).
function DetectionConfig.GetSimtimeScanLimits()
	local targets = DetectionConfig.SimtimeScanTargets
	local maxPairs = DetectionConfig.GetSimtimeMaxDeltaPairs()
	local function clampScan(requested)
		return math.min(math.max(1, requested), maxPairs)
	end
	return {
		retentionTicks = DetectionConfig.GetSimtimeRetentionTicks(),
		maxDeltaPairs  = maxPairs,
		flScan         = clampScan(targets.FlScanDeltas),
		dtRecent       = clampScan(targets.DtRecentScanDeltas),
		dtWatching     = clampScan(targets.DtWatchingScanDeltas),
	}
end

function DetectionConfig.SetSimtimeRetentionTicks(ticks)
	local targets = DetectionConfig.SimtimeScanTargets
	local minRetention = DetectionConfig.GetSimtimeMinRetentionTicks()
	local maxScan = DetectionConfig.GetSimtimeMaxScanDeltas()
	local n = math.floor(tonumber(ticks) or 0)
	if n < minRetention then
		return false, string.format(
			"retention must be >= %d (FL scan %d, DT scan %d)",
			minRetention, targets.FlScanDeltas, targets.DtRecentScanDeltas)
	end
	if (n - 1) < maxScan then
		return false, string.format(
			"retention %d only gives %d pairs; need >= %d for max scan depth %d",
			n, n - 1, minRetention, maxScan)
	end
	DetectionConfig.Detectors.Simtime.retentionTicks = n
	DetectionConfig.RegisterWithHistoryManager()
	return true, nil
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
