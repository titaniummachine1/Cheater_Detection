--[[
	TickProfiler
	Lightweight internal profiler that measures time spent in labeled sections per tick
	and renders a bottom-left overlay while debug mode is enabled.
]]

local TickProfiler = {}

local sections = {}
local stacks = {}
local acc = {} -- Accumulator for rolling stats
local display = {} -- Display entries
local enabled = false
local lastSnapshot = 0
local SNAPSHOT_INTERVAL = 10 -- Update display every ~10 ticks for smoothness

-- Configuration
local SMOOTHING_FACTOR = 0.1 -- For EMA smoothing of display values
local SORT_DELAY = 33 -- Re-sort every ~0.5 seconds (33 ticks)
local lastSortTime = 0

local font = draw.CreateFont("Tahoma", 12, 600, FONTFLAG_OUTLINE)
local fontSmall = draw.CreateFont("Tahoma", 11, 400, FONTFLAG_OUTLINE)
local overlayPadding = 12

-- Color Palette
local COLORS = {
	GREY = { 150, 150, 150, 255 },
	WHITE = { 255, 255, 255, 255 },
	YELLOW = { 255, 200, 50, 255 },
	RED = { 255, 50, 50, 255 },
}

-- Helper: Linear Interpolation for Colors
local function LerpColor(t, c1, c2)
	return {
		math.floor(c1[1] + (c2[1] - c1[1]) * t),
		math.floor(c1[2] + (c2[2] - c1[2]) * t),
		math.floor(c1[3] + (c2[3] - c1[3]) * t),
		255,
	}
end

-- Helper: Get Color based on value and thresholds
local function GetColorForValue(val, t1, t2, t3)
	if val <= t1 then
		local t = val / t1
		return LerpColor(t, COLORS.GREY, COLORS.WHITE)
	elseif val <= t2 then
		local t = (val - t1) / (t2 - t1)
		return LerpColor(t, COLORS.WHITE, COLORS.YELLOW)
	else
		local t = math.min(1, (val - t2) / (t3 - t2))
		return LerpColor(t, COLORS.YELLOW, COLORS.RED)
	end
end

local function now()
	return globals.RealTime()
end

local function reset()
	sections = {}
	stacks = {}
	acc = {}
	display = {}
end

function TickProfiler.SetEnabled(state)
	local shouldEnable = state == true
	if shouldEnable == enabled then
		return
	end

	enabled = shouldEnable

	if not enabled then
		reset()
	end
end

function TickProfiler.IsEnabled()
	return enabled
end

function TickProfiler.BeginSection(name)
	if not enabled then
		return
	end

	local stack = stacks[name]
	if not stack then
		stack = {}
		stacks[name] = stack
	end

	-- Record start time and memory
	local startTime = now()
	local startMem = collectgarbage("count") * 1024 -- Convert to bytes
	stack[#stack + 1] = { time = startTime, mem = startMem }
end

function TickProfiler.EndSection(name)
	if not enabled then
		return
	end

	local stack = stacks[name]
	if not stack or #stack == 0 then
		return
	end

	local startData = stack[#stack]
	stack[#stack] = nil

	local elapsed = now() - startData.time
	if elapsed < 0 then
		elapsed = 0
	end

	-- Calculate memory delta
	local endMem = collectgarbage("count") * 1024
	local memDelta = endMem - startData.mem
	-- Don't clamp memory delta to 0, negative means freed memory (which is good/interesting)

	-- Initialize accumulator for this section if needed
	local section = acc[name]
	if not section then
		section = {
			total = 0,
			samples = 0,
			peak = 0,
			memTotal = 0,
			memPeak = 0,
			-- Display values (smoothed)
			dispAvg = 0,
			dispPeak = 0,
			dispMemAvg = 0,
			dispMemPeak = 0,
		}
		acc[name] = section
	end

	-- Update accumulator
	section.total = section.total + elapsed
	section.samples = section.samples + 1
	if elapsed > section.peak then
		section.peak = elapsed
	end

	section.memTotal = section.memTotal + memDelta
	if memDelta > section.memPeak then
		section.memPeak = memDelta
	end
end

-- Alias for Measure
function TickProfiler.Guard(name, fn, ...)
	return TickProfiler.Measure(name, fn, ...)
end

function TickProfiler.Measure(name, fn, ...)
	if not enabled then
		return fn(...)
	end
	if type(fn) ~= "function" then
		return
	end

	TickProfiler.BeginSection(name)
	local results = { pcall(fn, ...) }
	TickProfiler.EndSection(name)

	if not results[1] then
		error(results[2])
	end

	return table.unpack(results, 2)
end

function TickProfiler.Reset()
	reset()
end

function TickProfiler.GetSections()
	return acc
end

local function buildEntries()
	local currentTick = globals.TickCount()

	-- Update smoothed values periodically
	if currentTick - lastSnapshot >= SNAPSHOT_INTERVAL then
		lastSnapshot = currentTick

		for name, data in pairs(acc) do
			local avg = data.samples > 0 and (data.total / data.samples) or 0
			local memAvg = data.samples > 0 and (data.memTotal / data.samples) or 0

			-- Apply smoothing (EMA)
			data.dispAvg = data.dispAvg + (avg - data.dispAvg) * SMOOTHING_FACTOR
			data.dispPeak = data.dispPeak + (data.peak - data.dispPeak) * SMOOTHING_FACTOR
			data.dispMemAvg = data.dispMemAvg + (memAvg - data.dispMemAvg) * SMOOTHING_FACTOR
			data.dispMemPeak = data.dispMemPeak + (data.memPeak - data.dispMemPeak) * SMOOTHING_FACTOR

			-- Reset accumulators for next window
			data.total = 0
			data.samples = 0
			data.peak = 0
			data.memTotal = 0
			data.memPeak = 0
		end
	end

	-- Re-sort periodically to prevent jumping
	if currentTick - lastSortTime >= SORT_DELAY then
		lastSortTime = currentTick
		display = {}

		for name, data in pairs(acc) do
			display[#display + 1] = {
				name = name,
				timeAvg = data.dispAvg * 1000000, -- Convert to microseconds
				timePeak = data.dispPeak * 1000000,
				memAvg = data.dispMemAvg,
				memPeak = data.dispMemPeak,
			}
		end

		table.sort(display, function(a, b)
			-- Sort by Time Avg descending, then Memory Avg descending
			if math.abs(a.timeAvg - b.timeAvg) > 10 then -- 10us threshold for stability
				return a.timeAvg > b.timeAvg
			end
			return a.memAvg > b.memAvg
		end)
	end

	return display
end

local function drawOverlay()
	if not enabled then
		return
	end
	if engine.IsGameUIVisible() or engine.Con_IsVisible() then
		return
	end

	local entries = buildEntries()
	if #entries == 0 then
		return
	end

	draw.SetFont(font)
	local screenW, screenH = draw.GetScreenSize()
	local x = overlayPadding
	local lineHeight = 14

	-- Calculate total height needed
	local headerHeight = lineHeight + 4
	local statsHeight = lineHeight + 4
	local entriesHeight = #entries * lineHeight
	local totalHeight = entriesHeight + headerHeight + statsHeight + overlayPadding

	-- Start from bottom, but ensure we don't overflow top of screen
	local y = screenH - overlayPadding
	local minY = overlayPadding + totalHeight

	-- If we would overflow, start from the top instead
	if minY > screenH then
		y = totalHeight
	end

	-- Helper to format time
	local function formatTime(microseconds)
		if microseconds >= 1000 then
			return string.format("%6.2f ms", microseconds / 1000)
		else
			return string.format("%6.0f µs", microseconds)
		end
	end

	-- Helper to format memory (with sign for negative)
	local function formatMemory(bytes)
		local sign = bytes < 0 and "-" or " "
		local absBytes = math.abs(bytes)

		if absBytes >= 1024 * 1024 then
			return string.format("%s%5.2f MB", sign, absBytes / (1024 * 1024))
		elseif absBytes >= 1024 then
			return string.format("%s%5.2f KB", sign, absBytes / 1024)
		else
			return string.format("%s%5.0f B ", sign, absBytes)
		end
	end

	-- Calculate total measured memory
	local totalMeasuredMem = 0
	for _, entry in ipairs(entries) do
		totalMeasuredMem = totalMeasuredMem + entry.memAvg
	end

	-- Draw entries from bottom to top
	for i = #entries, 1, -1 do
		local entry = entries[i]

		-- Colors
		-- Time: 50us (White) -> 500us (Yellow) -> 2ms (Red)
		local timeColor = GetColorForValue(entry.timeAvg, 50, 500, 2000)

		-- Mem: Handle negative (freed memory) as green, positive uses the gradient
		local memColor
		if entry.memAvg < 0 then
			-- Negative memory (freed) = green (good thing)
			memColor = { 100, 255, 100, 255 }
		else
			-- Positive: 100B (White) -> 1KB (Yellow) -> 10KB (Red)
			memColor = GetColorForValue(entry.memAvg, 100, 1024, 10240)
		end

		local tAvgStr = formatTime(entry.timeAvg)
		local tPeakStr = formatTime(entry.timePeak)
		local mAvgStr = formatMemory(entry.memAvg)
		local mPeakStr = formatMemory(entry.memPeak)

		-- Draw Columns
		local curX = x

		-- Time Avg
		draw.Color(timeColor[1], timeColor[2], timeColor[3], 255)
		draw.Text(curX, y, tAvgStr)
		curX = curX + 70

		-- Time Peak
		draw.Color(150, 150, 150, 255) -- Peak is less important, keep greyish
		draw.Text(curX, y, tPeakStr)
		curX = curX + 70

		-- Separator
		draw.Color(100, 100, 100, 255)
		draw.Text(curX, y, "|")
		curX = curX + 15

		-- Mem Avg
		draw.Color(memColor[1], memColor[2], memColor[3], 255)
		draw.Text(curX, y, mAvgStr)
		curX = curX + 70

		-- Mem Peak
		draw.Color(150, 150, 150, 255)
		draw.Text(curX, y, mPeakStr)
		curX = curX + 70

		-- Separator
		draw.Color(100, 100, 100, 255)
		draw.Text(curX, y, "|")
		curX = curX + 15

		-- Name
		draw.Color(255, 255, 255, 255)
		draw.Text(curX, y, entry.name)

		y = y - lineHeight
	end

	-- Draw Header
	y = y - lineHeight - 4
	draw.SetFont(fontSmall)
	draw.Color(200, 200, 200, 255)

	-- Manual spacing to match columns roughly
	local curX = x
	draw.Text(curX, y, "Time Avg")
	curX = curX + 70
	draw.Text(curX, y, "Time Peak")
	curX = curX + 85
	draw.Text(curX, y, "Mem Avg")
	curX = curX + 70
	draw.Text(curX, y, "Mem Peak")
	curX = curX + 85
	draw.Text(curX, y, "Section Name")

	-- Draw Global Stats
	y = y - lineHeight - 4
	local memUsed = collectgarbage("count") * 1024
	local memStr = string.format("Lua Total: %s | Measured: %s", formatMemory(memUsed), formatMemory(totalMeasuredMem))
	draw.Color(255, 200, 100, 255)
	draw.Text(x, y, memStr)
end

callbacks.Unregister("Draw", "CD_TickProfilerOverlay")
callbacks.Register("Draw", "CD_TickProfilerOverlay", drawOverlay)

return TickProfiler
