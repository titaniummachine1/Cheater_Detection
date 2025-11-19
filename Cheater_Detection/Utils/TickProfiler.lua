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
			average = data.average * 1000,
			last = data.last * 1000,
			peak = (data.peak or 0) * 1000,
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

	local header = "Profiler (avg | last | max ms)"
	local headerWidth, headerHeight = draw.GetTextSize(header)
	draw.Color(255, 255, 255, 255)
	draw.Text(x - headerWidth, y, header)
	y = y + headerHeight + 2

	for _, entry in ipairs(entries) do
		local text = string.format("%s | %.3f | %.3f | %.3f", entry.name, entry.average, entry.last, entry.peak)
		local textWidth, textHeight = draw.GetTextSize(text)
		draw.Color(200, 200, 200, 255)
		draw.Text(x - textWidth, y, text)
		y = y + textHeight
	end
end

callbacks.Unregister("Draw", "CD_TickProfilerOverlay")
callbacks.Register("Draw", "CD_TickProfilerOverlay", drawOverlay)

return TickProfiler
