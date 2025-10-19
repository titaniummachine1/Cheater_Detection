--[[ Cheater Detection - Logger System ]]

local G = require("Cheater_Detection.Utils.Globals")

local Logger = {}

-- Log levels
Logger.Levels = {
	DEBUG = 1,   -- Detailed debug info (off by default)
	INFO = 2,    -- General info (detections, database saves)
	WARNING = 3, -- Warnings
	ERROR = 4,   -- Errors
}

-- Color codes for console
local Colors = {
	DEBUG = "\x07AAAAAA",   -- Gray
	INFO = "\x0799CCFF",    -- Light blue
	WARNING = "\x07FFAA00", -- Orange
	ERROR = "\x07FF4444",   -- Red
	RESET = "\x07FFFFFF",   -- White
}

--- Check if log level is enabled
---@param level number Log level to check
---@return boolean
local function isLevelEnabled(level)
	if not G.Menu or not G.Menu.Advanced or not G.Menu.Advanced.LogLevel then
		return level >= Logger.Levels.INFO -- Default: INFO and above
	end
	
	local enabledLevel = G.Menu.Advanced.LogLevel
	return level >= enabledLevel
end

--- Log a message with specified level
---@param level number Log level (Logger.Levels.X)
---@param category string Category/module name
---@param message string Message to log
function Logger.Log(level, category, message)
	if not isLevelEnabled(level) then
		return
	end
	
	local levelName = ""
	local color = Colors.RESET
	
	if level == Logger.Levels.DEBUG then
		levelName = "DEBUG"
		color = Colors.DEBUG
	elseif level == Logger.Levels.INFO then
		levelName = "INFO"
		color = Colors.INFO
	elseif level == Logger.Levels.WARNING then
		levelName = "WARN"
		color = Colors.WARNING
	elseif level == Logger.Levels.ERROR then
		levelName = "ERROR"
		color = Colors.ERROR
	end
	
	print(string.format("%s[%s] [%s]%s %s", color, levelName, category, Colors.RESET, message))
end

--- Convenience functions
function Logger.Debug(category, message)
	Logger.Log(Logger.Levels.DEBUG, category, message)
end

function Logger.Info(category, message)
	Logger.Log(Logger.Levels.INFO, category, message)
end

function Logger.Warning(category, message)
	Logger.Log(Logger.Levels.WARNING, category, message)
end

function Logger.Error(category, message)
	Logger.Log(Logger.Levels.ERROR, category, message)
end

return Logger
