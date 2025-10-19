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

-- Color codes (RGBA)
local Colors = {
	DEBUG = {170, 170, 170, 255},   -- Gray
	INFO = {153, 204, 255, 255},    -- Light blue
	WARNING = {255, 170, 0, 255},   -- Orange
	ERROR = {255, 68, 68, 255},     -- Red
}

--- Check if log level is enabled
---@param level number Log level to check
---@return boolean
local function isLevelEnabled(level)
	if not G.Menu or not G.Menu.Advanced or not G.Menu.Advanced.LogLevel then
		return level >= Logger.Levels.INFO -- Default: INFO and above
	end
	
	-- Convert boolean table to level number: [Debug, Info, Warning, Error]
	local logLevelTable = G.Menu.Advanced.LogLevel
	local enabledLevel = Logger.Levels.INFO -- Default
	
	if type(logLevelTable) == "table" then
		for i = 1, 4 do
			if logLevelTable[i] then
				enabledLevel = i
				break
			end
		end
	elseif type(logLevelTable) == "number" then
		enabledLevel = logLevelTable
	end
	
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
	local color = nil
	
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
	
	if color then
		printc(color[1], color[2], color[3], color[4], string.format("[%s] [%s] %s", levelName, category, message))
	else
		print(string.format("[%s] [%s] %s", levelName, category, message))
	end
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
