--[[ Imports first --]]
local Globals = {}
Globals.Menu = require("Cheater_Detection.Utils.DefaultConfig")

Globals.AutoVote = {
	Options = { "Yes", "No" },
	VoteCommand = "vote",
	VoteIdx = nil,
	VoteValue = nil, -- Set this to 1 for yes, 2 for no, or nil for off
}

--[[Shared Variables]]

Globals.players = {}
Globals.pLocal = nil
Globals.WLocal = nil
Globals.latin = nil
Globals.latout = nil

-- Global utility functions and UI helpers

local G = {
	Config = {
		DebugMode = false,
		ShowNotifications = true,
		NotificationDuration = 3,
		MaxMemoryUsageMB = 100, -- Target max memory usage
	},

	State = {
		LastNotification = 0,
		NotificationMessage = "",
		ProgressValue = 0,
		ProgressMessage = "",
		LastMemoryCheck = 0,
		MemoryCheckInterval = 5.0, -- Check memory every 5 seconds
	},

	-- Helper function for reliable integer coordinates
	RoundCoord = function(value)
		if not value then
			return 0
		end
		if type(value) ~= "number" then
			return 0
		end
		-- Check for NaN and infinity
		if value ~= value or value == math.huge or value == -math.huge then
			return 0
		end
		return math.floor(value + 0.5)
	end,
}

-- UI helper functions
G.UI = {
	-- Show a message in the UI and console
	ShowMessage = function(message, duration)
		if not message then
			return
		end

		-- Store for drawing
		G.State.NotificationMessage = message
		G.State.LastNotification = globals.RealTime()
		G.Config.NotificationDuration = duration or G.Config.NotificationDuration

		-- Also print to console
		print("[Cheater Detection] " .. message)
	end,

	-- Update progress indicator
	UpdateProgress = function(value, message)
		G.State.ProgressValue = value or G.State.ProgressValue
		G.State.ProgressMessage = message or G.State.ProgressMessage
	end,

	-- Draw notification if active
	DrawNotification = function()
		if not G.Config.ShowNotifications then
			return
		end

		local currentTime = globals.RealTime()
		local timeSinceNotification = currentTime - G.State.LastNotification

		-- If notification is expired, don't draw
		if timeSinceNotification > G.Config.NotificationDuration then
			return
		end

		-- Calculate fade-out
		local alpha = 255
		if timeSinceNotification > G.Config.NotificationDuration - 0.5 then
			alpha = math.floor(255 * (G.Config.NotificationDuration - timeSinceNotification) / 0.5)
		end

		-- Draw notification with integer coordinates
		local x, y = G.RoundCoord(20), G.RoundCoord(100)
		local padding = 10
		local message = G.State.NotificationMessage
		local width = draw.GetTextSize(message) + padding * 2

		-- Background
		draw.Color(20, 20, 20, math.min(200, alpha))
		draw.FilledRect(x, y, x + width, y + G.RoundCoord(30))

		-- Border
		draw.Color(80, 150, 255, alpha)
		draw.OutlinedRect(x, y, x + width, y + G.RoundCoord(30))

		-- Text
		draw.Color(255, 255, 255, alpha)
		draw.Text(G.RoundCoord(x + padding), G.RoundCoord(y + padding), message)
	end,

	-- Draw progress bar if active
	DrawProgressBar = function()
		if G.State.ProgressValue <= 0 then
			return
		end

		-- Draw progress bar at bottom of screen with integer coordinates
		local width = 300
		local height = 20
		local screenWidth, screenHeight = draw.GetScreenSize()
		local x = G.RoundCoord((screenWidth - width) / 2)
		local y = G.RoundCoord(screenHeight - height - 20)

		-- Background
		draw.Color(20, 20, 20, 200)
		draw.FilledRect(x, y, x + width, y + height)

		-- Progress fill
		local progressWidth = G.RoundCoord(width * (G.State.ProgressValue / 100))
		draw.Color(80, 150, 255, 255)
		draw.FilledRect(x, y, x + progressWidth, y + height)

		-- Border
		draw.Color(100, 170, 255, 255)
		draw.OutlinedRect(x, y, x + width, y + height)

		-- Progress text
		local percent = tostring(math.floor(G.State.ProgressValue)) .. "%"
		local textWidth = draw.GetTextSize(percent)
		draw.Color(255, 255, 255, 255)
		draw.Text(G.RoundCoord(x + (width - textWidth) / 2), G.RoundCoord(y + 3), percent)

		-- Message text
		if G.State.ProgressMessage and #G.State.ProgressMessage > 0 then
			draw.Text(x, G.RoundCoord(y - 15), G.State.ProgressMessage)
		end
	end,
}

-- Memory management helpers
G.Memory = {
	-- Check memory usage and perform cleanup if needed
	CheckMemory = function()
		local currentTime = globals.RealTime()
		if currentTime - G.State.LastMemoryCheck < G.State.MemoryCheckInterval then
			return
		end

		G.State.LastMemoryCheck = currentTime

		-- Check current memory usage
		local memoryUsage = collectgarbage("count") / 1024 -- MB

		-- If over threshold, perform cleanup
		if memoryUsage > G.Config.MaxMemoryUsageMB then
			-- Run incremental garbage collection
			collectgarbage("step", 1000) -- Run 1000 steps

			if G.Config.DebugMode then
				print(string.format("[Memory] Usage: %.2f MB - performing cleanup", memoryUsage))
			end
		end
	end,

	-- Force full cleanup
	ForceCleanup = function()
		collectgarbage("collect")
		collectgarbage("collect")

		if G.Config.DebugMode then
			print(string.format("[Memory] Forced cleanup - new usage: %.2f MB", collectgarbage("count") / 1024))
		end
	end,
}

-- Register draw callback for UI elements
callbacks.Register("Draw", "GlobalsUI", function()
	G.UI.DrawNotification()
	G.UI.DrawProgressBar()
	G.Memory.CheckMemory()
end)

return G
