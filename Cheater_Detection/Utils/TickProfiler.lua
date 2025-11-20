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
local SNAPSHOT_INTERVAL = 66 -- ~1 second at 66 ticks/sec

local font = draw.CreateFont("Tahoma", 12, 600, FONTFLAG_OUTLINE)
local overlayPadding = 12

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
	if not (enabled and name) then
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
	if not (enabled and name) then
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

	-- Initialize accumulator for this section if needed
	local section = acc[name]
	if not section then
		section = { total = 0, samples = 0, peak = 0, memTotal = 0, memPeak = 0, last = 0, memLast = 0 }
		acc[name] = section
	end

	-- Update accumulator
	section.last = elapsed
	section.total = section.total + elapsed
	section.samples = section.samples + 1
	if elapsed > section.peak then
		section.peak = elapsed
	end

	section.memLast = memDelta
	section.memTotal = section.memTotal + memDelta
	if memDelta > section.memPeak then
		section.memPeak = memDelta
	end
end

function TickProfiler.Measure(name, fn, ...)
	if type(fn) ~= "function" then
		return
	end

	TickProfiler.BeginSection(name)
	local ok, a, b, c, d = pcall(fn, ...)
	TickProfiler.EndSection(name)

	if not ok then
		error(a)
	end

	return a, b, c, d
end

function TickProfiler.Reset()
	reset()
end

function TickProfiler.GetSections()
	return acc
end

local function buildEntries()
	-- Check if it's time to snapshot (every 1 second)
	local currentTick = globals.TickCount()
	if currentTick - lastSnapshot >= SNAPSHOT_INTERVAL then
		lastSnapshot = currentTick
		display = {} -- Reset display table

		for name, data in pairs(acc) do
			local avg = data.samples > 0 and (data.total / data.samples) or 0
			display[#display + 1] = {
				name = name,
				average = avg * 1000000,
				last = data.last * 1000000,
				peak = data.peak * 1000000,
				memLast = data.memLast,
				memPeak = data.memPeak,
			}

			-- Reset accumulator for next window, but keep last values for continuity
			data.total = 0
			data.samples = 0
			data.peak = 0
			data.memTotal = 0
			data.memPeak = 0
		end

		-- Sort by importance: CreateMove first, then subsections, then Draw callbacks
		local function getSortPriority(name)
			if name == "CreateMove" then
				return 1
			end
			if name:match("^Detection_") then
				return 2
			end
			if name:match("^History_") then
				return 3
			end
			if name == "HistoryPush" then
				return 4
			end
			if name == "PlayerCleanup" then
				return 5
			end
			if name == "EvidenceDecay" then
				return 6
			end
			if name == "GarbageCollection" then
				return 7
			end
			if name:match("^Draw_") then
				return 8
			end
			return 9
		end

		table.sort(display, function(a, b)
			local priorityA = getSortPriority(a.name)
			local priorityB = getSortPriority(b.name)
			if priorityA ~= priorityB then
				return priorityA < priorityB
			end
			return a.name < b.name
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
		-- If no new entries (between snapshots), use the last display
		if #display == 0 then
			return
		end
		entries = display
	end

	draw.SetFont(font)
	local screenW, screenH = draw.GetScreenSize()
	local x = overlayPadding
	local y = screenH - overlayPadding

	-- Helper to format time with proper units
	local function formatTime(microseconds)
		if microseconds >= 1000 then
			return string.format("%.2f ms", microseconds / 1000)
		else
			return string.format("%.0f µs", microseconds)
		end
	end

	-- Helper to format memory
	local function formatMemory(bytes)
		if bytes >= 1024 * 1024 then
			return string.format("%.2f MB", bytes / (1024 * 1024))
		elseif bytes >= 1024 then
			return string.format("%.2f KB", bytes / 1024)
		elseif bytes >= 0 then
			return string.format("%d B", bytes)
		else
			return string.format("%d B", bytes) -- Negative means freed
		end
	end

	-- Draw from bottom to top
	for i = #entries, 1, -1 do
		local entry = entries[i]
		local avgStr = formatTime(entry.average)
		local lastStr = formatTime(entry.last)
		local maxStr = formatTime(entry.peak)
		local memLastStr = formatMemory(entry.memLast)
		local memPeakStr = formatMemory(entry.memPeak)

		local text = string.format("%s | %s/%s/%s | %s/%s", entry.name, avgStr, lastStr, maxStr, memLastStr, memPeakStr)
		local textWidth, textHeight = draw.GetTextSize(text)

		-- Color code by memory usage
		if entry.memLast > 10240 then -- More than 10KB
			draw.Color(255, 100, 100, 255) -- Red for high memory
		elseif entry.memLast > 1024 then -- More than 1KB
			draw.Color(255, 200, 100, 255) -- Orange for medium
		else
			draw.Color(200, 200, 200, 255) -- Gray for low
		end

		y = y - textHeight
		draw.Text(x, y, text)
	end

	-- Draw header above entries
	local header = "Section | Time (avg/last/max) | Mem (last/peak)"
	local headerWidth, headerHeight = draw.GetTextSize(header)
	y = y - headerHeight - 2
	draw.Color(255, 255, 255, 255)
	draw.Text(x, y, header)

	-- Get memory usage
	local memUsed = collectgarbage("count") * 1024 -- Convert KB to bytes

	-- Draw memory header above that
	local memHeader = string.format("Lua Memory: %s", formatMemory(memUsed))
	local memWidth, memHeight = draw.GetTextSize(memHeader)
	y = y - memHeight - 4
	draw.Color(255, 200, 100, 255)
	draw.Text(x, y, memHeader)
end

callbacks.Unregister("Draw", "CD_TickProfilerOverlay")
callbacks.Register("Draw", "CD_TickProfilerOverlay", drawOverlay)

return TickProfiler
