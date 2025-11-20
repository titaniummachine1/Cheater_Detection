--[[
	TickProfiler
	Lightweight internal profiler that measures time spent in labeled sections per tick
	and renders a top-right overlay while debug mode is enabled.
]]

local TickProfiler = {}

local sections = {}
local stacks = {}
local enabled = false

local font = draw.CreateFont("Tahoma", 12, 600, FONTFLAG_OUTLINE)
local overlayPadding = 12

local function now()
	return globals.RealTime()
end

local function reset()
	sections = {}
	stacks = {}
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

	stack[#stack + 1] = now()
end

function TickProfiler.EndSection(name)
	if not (enabled and name) then
		return
	end

	local stack = stacks[name]
	if not stack or #stack == 0 then
		return
	end

	local startTime = stack[#stack]
	stack[#stack] = nil

	local elapsed = now() - startTime
	if elapsed < 0 then
		elapsed = 0
	end

	local section = sections[name]
	if not section then
		section = { total = 0, samples = 0, average = 0, last = 0, peak = 0 }
		sections[name] = section
	end

	section.last = elapsed
	section.total = section.total + elapsed
	section.samples = section.samples + 1
	section.average = section.total / section.samples
	if elapsed > section.peak then
		section.peak = elapsed
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
	return sections
end

local function buildEntries()
	local entries = {}
	for name, data in pairs(sections) do
		entries[#entries + 1] = {
			name = name,
			average = data.average * 1000000, -- Convert to microseconds
			last = data.last * 1000000,
			peak = (data.peak or 0) * 1000000,
		}
	end
	table.sort(entries, function(a, b)
		if a.average == b.average then
			return a.name < b.name
		end
		return a.average > b.average
	end)
	return entries
end

local function drawOverlay()
	if not enabled then
		return
	end

	if engine.IsGameUIVisible() or engine.Con_IsVisible() then
		return
	end

	if next(sections) == nil then
		return
	end

	local entries = buildEntries()
	if #entries == 0 then
		return
	end

	draw.SetFont(font)
	local screenW = select(1, draw.GetScreenSize())
	local x = screenW - overlayPadding
	local y = overlayPadding

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
		else
			return string.format("%d B", bytes)
		end
	end

	-- Get memory usage
	local memUsed = collectgarbage("count") * 1024 -- Convert KB to bytes

	-- Draw memory header
	local memHeader = string.format("Lua Memory: %s", formatMemory(memUsed))
	local memWidth, memHeight = draw.GetTextSize(memHeader)
	draw.Color(255, 200, 100, 255)
	draw.Text(x - memWidth, y, memHeader)
	y = y + memHeight + 4

	local header = "Profiler (avg | last | max)"
	local headerWidth, headerHeight = draw.GetTextSize(header)
	draw.Color(255, 255, 255, 255)
	draw.Text(x - headerWidth, y, header)
	y = y + headerHeight + 2

	for _, entry in ipairs(entries) do
		local avgStr = formatTime(entry.average)
		local lastStr = formatTime(entry.last)
		local maxStr = formatTime(entry.peak)
		local text = string.format("%s | %s | %s | %s", entry.name, avgStr, lastStr, maxStr)
		local textWidth, textHeight = draw.GetTextSize(text)
		draw.Color(200, 200, 200, 255)
		draw.Text(x - textWidth, y, text)
		y = y + textHeight
	end
end

callbacks.Unregister("Draw", "CD_TickProfilerOverlay")
callbacks.Register("Draw", "CD_TickProfilerOverlay", drawOverlay)

return TickProfiler
