--[[
    Fixed Task UI System - Ensures proper display of loading elements
]]

local Tasks = {
	isRunning = false,
	progress = 0,
	targetProgress = 0,
	message = "",
	status = "idle",
	currentSource = nil,
	completedSources = 0,
	totalSources = 0,
	completedTime = 0,

	-- UI configuration with adjusted dimensions
	UI = {
		Width = 300, -- Width of UI window
		Height = 90, -- Increased height to prevent text overlap
		BarHeight = 20, -- Height of progress bar
		Padding = 10, -- Padding inside window
		TitleSize = 18, -- Size of title font
		TextSize = 14, -- Size of regular text font
		BackgroundAlpha = 200, -- Background opacity (0-255)
		BorderAlpha = 150, -- Border opacity (0-255)
		ScreenOffset = 120, -- Distance from bottom of screen

		-- New positioning properties for better layout
		TitleOffset = 8, -- Title position from top
		StatusOffset = 35, -- Status message position from top
		BarBottomOffset = 15, -- Progress bar position from bottom
		TextSpacing = 8, -- Space between text elements
	},

	-- Animation settings
	Animation = {
		SmoothFactor = 0.7, -- Progress bar smoothing (higher = faster)
		FadeDelay = 3, -- Seconds before fading out after completion
		FadeDuration = 1, -- Seconds for fade out animation
	},
}

-- Initialize fonts - explicitly create each time instead of storing
function Tasks.InitializeFonts()
	Tasks.titleFont = draw.CreateFont("Verdana", Tasks.UI.TitleSize, 800) -- Bold font
	Tasks.textFont = draw.CreateFont("Verdana", Tasks.UI.TextSize, 400) -- Regular font
end

-- Initialize task tracking
function Tasks.Init(sourceCount)
	-- Initialize task state
	Tasks.totalSources = sourceCount or 0
	Tasks.completedSources = 0
	Tasks.progress = 0
	Tasks.targetProgress = 0
	Tasks.isRunning = true
	Tasks.status = "running"
	Tasks.message = "Loading Database"
	Tasks.currentSource = nil
	Tasks.completedTime = 0

	-- Make sure fonts are initialized
	Tasks.InitializeFonts()
end

-- Reset task system
function Tasks.Reset()
	-- Clean up any callbacks
	pcall(function()
		callbacks.Unregister("Draw", "TasksUpdateProgress")
	end)

	-- Reset state
	Tasks.isRunning = false
	Tasks.progress = 0
	Tasks.targetProgress = 0
	Tasks.status = "idle"
	Tasks.message = ""
	Tasks.currentSource = nil
	Tasks.completedSources = 0
	Tasks.totalSources = 0
	Tasks.completedTime = 0

	-- Force GC
	collectgarbage("collect")
end

-- Start processing a source
function Tasks.StartSource(sourceName)
	Tasks.currentSource = sourceName or "Unknown"
	Tasks.message = "Processing " .. Tasks.currentSource
end

-- Mark current source as complete
function Tasks.SourceDone()
	Tasks.completedSources = Tasks.completedSources + 1

	if Tasks.totalSources > 0 then
		Tasks.targetProgress = math.floor((Tasks.completedSources / Tasks.totalSources) * 100)
	end
end

-- Update progress with smoothing
function Tasks.UpdateProgress()
	-- Only update if running
	if not Tasks.isRunning then
		return
	end

	-- Smooth progress bar
	if Tasks.progress ~= Tasks.targetProgress then
		Tasks.progress = Tasks.progress + (Tasks.targetProgress - Tasks.progress) * Tasks.Animation.SmoothFactor
		if math.abs(Tasks.progress - Tasks.targetProgress) < 0.5 then
			Tasks.progress = Tasks.targetProgress
		end
	end

	-- Handle completion fade-out
	if Tasks.status == "complete" and Tasks.completedTime > 0 then
		if globals.RealTime() - Tasks.completedTime > Tasks.Animation.FadeDelay then
			Tasks.Reset()
		end
	end
end

-- Draw improved UI with fixed layout
function Tasks.DrawProgressUI()
	-- Skip if not running
	if not Tasks.isRunning then
		return
	end

	-- Make sure fonts are initialized
	Tasks.InitializeFonts()

	-- Get screen dimensions
	local screenWidth, screenHeight = draw.GetScreenSize()

	-- Calculate window position (centered horizontally, fixed distance from bottom)
	local width = Tasks.UI.Width
	local height = Tasks.UI.Height
	local x = math.floor((screenWidth - width) / 2)
	local y = math.floor(screenHeight - height - Tasks.UI.ScreenOffset)

	-- Draw background with alpha
	draw.Color(20, 20, 20, Tasks.UI.BackgroundAlpha)
	draw.FilledRect(x, y, x + width, y + height)

	-- Draw border
	draw.Color(60, 120, 255, Tasks.UI.BorderAlpha)
	draw.OutlinedRect(x, y, x + width, y + height)

	-- Draw title - moved up to prevent overlap
	draw.SetFont(Tasks.titleFont)
	draw.Color(255, 255, 255, 255)
	local titleText = "Database Update"
	local titleWidth = draw.GetTextSize(titleText)
	draw.Text(x + math.floor((width - titleWidth) / 2), y + Tasks.UI.TitleOffset, titleText)

	-- Calculate progress bar position from bottom of window
	local barPadding = Tasks.UI.Padding
	local barWidth = width - (barPadding * 2)
	local barHeight = Tasks.UI.BarHeight
	local barY = y + height - barHeight - Tasks.UI.BarBottomOffset

	-- Draw progress bar background
	draw.Color(40, 40, 40, 180)
	draw.FilledRect(x + barPadding, barY, x + barPadding + barWidth, barY + barHeight)

	-- Draw progress bar fill
	local fillWidth = math.floor((barWidth * Tasks.progress) / 100)
	draw.Color(30, 120, 255, 255)
	draw.FilledRect(x + barPadding, barY, x + barPadding + fillWidth, barY + barHeight)

	-- Draw progress percentage text
	draw.SetFont(Tasks.textFont)
	draw.Color(255, 255, 255, 255)
	local percent = string.format("%d%%", math.floor(Tasks.progress))
	local percentWidth = draw.GetTextSize(percent)
	draw.Text(
		x + barPadding + math.floor((barWidth - percentWidth) / 2),
		barY + math.floor((barHeight - Tasks.UI.TextSize) / 2),
		percent
	)

	-- Draw status message (if any) with proper positioning
	if Tasks.message and Tasks.message ~= "" then
		local message = Tasks.message
		if #message > 40 then
			message = message:sub(1, 37) .. "..."
		end

		draw.SetFont(Tasks.textFont)
		local messageWidth = draw.GetTextSize(message)
		-- Position message between title and progress bar
		draw.Text(
			x + math.floor((width - messageWidth) / 2),
			y + Tasks.UI.StatusOffset, -- Positioned right below the title
			message
		)
	end
end

-- Register automatic progress update (only once)
callbacks.Unregister("Draw", "TasksUpdateProgress")
callbacks.Register("Draw", "TasksUpdateProgress", Tasks.UpdateProgress)

return Tasks
