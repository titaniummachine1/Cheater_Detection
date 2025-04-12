--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local json = require("Cheater_Detection.Libs.Json")
local Default_Config = require("Cheater_Detection.Utils.DefaultConfig")

local Config = {}

local Log = Common.Log
local Notify = Common.Notify
Log.Level = 0

local script_name = GetScriptName():match("([^/\\]+)%.lua$")
local folder_name = string.format([[Lua %s]], script_name)

--[[ Helper Functions ]]
function Config.GetFilePath()
	local success, fullPath = filesystem.CreateDirectory(folder_name)
	return fullPath .. "/config.cfg"
end

local function checkAllKeysExist(expectedMenu, loadedMenu)
	for key, value in pairs(expectedMenu) do
		if loadedMenu[key] == nil then
			return false
		end
		if type(value) == "table" then
			local result = checkAllKeysExist(value, loadedMenu[key])
			if not result then
				return false
			end
		end
	end
	return true
end

--[[ Configuration Functions ]]
function Config.CreateCFG(cfgTable)
	cfgTable = cfgTable or Default_Config
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "w")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local serializedConfig = json.encode(cfgTable)
		file:write(serializedConfig)
		file:close()
		printc(100, 183, 0, 255, "Success Saving Config: Path: " .. shortFilePath)
		Notify.Simple("Success! Saved Config to:", shortFilePath, 5)
	else
		local errorMessage = "Failed to open: " .. shortFilePath
		printc(255, 0, 0, 255, errorMessage)
		Notify.Simple("Error", errorMessage, 5)
	end
end

function Config.LoadCFG()
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "r")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local content = file:read("*a")
		file:close()
		local loadedCfg = json.decode(content)
		if loadedCfg and checkAllKeysExist(Default_Config, loadedCfg) and not input.IsButtonDown(KEY_LSHIFT) then
			printc(100, 183, 0, 255, "Success Loading Config: Path: " .. shortFilePath)
			Notify.Simple("Success! Loaded Config from", shortFilePath, 5)
			G.Menu = loadedCfg
		else
			local warningMessage = input.IsButtonDown(KEY_LSHIFT) and "Creating a new config."
				or "Config is outdated or invalid. Resetting to default."
			printc(255, 0, 0, 255, warningMessage)
			Notify.Simple("Warning", warningMessage, 5)
			Config.CreateCFG(Default_Config)
			G.Menu = Default_Config
		end
	else
		local warningMessage = "Config file not found. Creating a new config."
		printc(255, 0, 0, 255, warningMessage)
		Notify.Simple("Warning", warningMessage, 5)
		Config.CreateCFG(Default_Config)
		G.Menu = Default_Config
	end
end

-- Save configuration automatically when the script unloads
callbacks.Register("Unload", "ConfigAutoSaveOnUnload", function()
	print("[CONFIG] Unloading script, saving configuration...")

	-- Save the current configuration state
	if G.Menu then
		Config.CreateCFG(G.Menu)
	else
		printc(255, 0, 0, 255, "[CONFIG] Warning: Unable to save config, G.Menu is nil")
	end
end)

return Config
