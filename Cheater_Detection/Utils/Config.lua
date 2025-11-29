--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")

local Common = require("Cheater_Detection.Utils.Common")
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
	-- Note: filesystem.CreateDirectory() returns true only if it created a new directory,
	-- not if the directory already exists. The function succeeds in both cases, but
	-- returns different boolean values.
	local CreatedDirectory, fullPath = filesystem.CreateDirectory(folder_name)
	return fullPath .. "/config.cfg"
end

local function checkAllKeysExist(expectedMenu, loadedMenu)
	if type(expectedMenu) ~= "table" then
		return true
	end
	if type(loadedMenu) ~= "table" then
		return false
	end

	for key, value in pairs(expectedMenu) do
		local loadedValue = loadedMenu[key]
		if loadedValue == nil then
			return false
		end
		if type(value) == "table" then
			if not checkAllKeysExist(value, loadedValue) then
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
	local shortFilePath = filepath:match(".*\\(.*.*)$")

	-- Try to encode config
	local success, serializedConfig = pcall(json.encode, cfgTable)
	if not success then
		local errorMessage = "Failed to encode config: " .. tostring(serializedConfig)
		printc(255, 0, 0, 255, errorMessage)
		print("[CONFIG] Error details: " .. tostring(serializedConfig))
		return false
	end

	local file = io.open(filepath, "w")
	if file then
		file:write(serializedConfig)
		file:close()
		printc(100, 183, 0, 255, "Success Saving Config: Path: " .. shortFilePath)
		Common.Notify.Simple("Success! Saved Config to:", shortFilePath, 5)
		return true
	else
		local errorMessage = "Failed to open: " .. shortFilePath
		printc(255, 0, 0, 255, errorMessage)
		Common.Notify.Simple("Error", errorMessage, 5)
		return false
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
			Common.Notify.Simple("Success! Loaded Config from", shortFilePath, 5)
			G.Menu = loadedCfg
		else
			local warningMessage = input.IsButtonDown(KEY_LSHIFT) and "Creating a new config."
				or "Config is outdated or invalid. Resetting to default."
			printc(255, 0, 0, 255, warningMessage)
			Common.Notify.Simple("Warning", warningMessage, 5)
			Config.CreateCFG(Default_Config)
			G.Menu = Default_Config
		end
	else
		local warningMessage = "Config file not found. Creating a new config."
		printc(255, 0, 0, 255, warningMessage)
		Common.Notify.Simple("Warning", warningMessage, 5)
		Config.CreateCFG(Default_Config)
		G.Menu = Default_Config
	end

	-- Set G.Config with key settings for other modules
	G.Config = G.Config or {}
	G.Config.AutoFetch = G.Menu.Main.AutoFetch -- Pull from Menu settings
end

--load on load
Config.LoadCFG()

-- Save configuration automatically when the script unloads
local function ConfigAutoSaveOnUnload()
	-- Use only basic print, no printc or other functions that might be GC'd
	print("[CONFIG] Unloading script, saving configuration...")

	-- Create a localized, self-contained JSON encoder to avoid GC issues
	local function safeJsonEncode(tbl, indent)
		indent = indent or ""
		local result = "{\n"
		local first = true

		for key, value in pairs(tbl) do
			if not first then
				result = result .. ",\n"
			end
			first = false

			-- Key
			if type(key) == "string" then
				result = result .. indent .. '  "' .. key .. '": '
			else
				result = result .. indent .. "  [" .. tostring(key) .. "]: "
			end

			-- Value
			if type(value) == "table" then
				result = result .. safeJsonEncode(value, indent .. "  ")
			elseif type(value) == "string" then
				result = result .. '"' .. value .. '"'
			elseif type(value) == "boolean" then
				result = result .. (value and "true" or "false")
			elseif type(value) == "number" then
				result = result .. tostring(value)
			else
				result = result .. "null"
			end
		end

		result = result .. "\n" .. indent .. "}"
		return result
	end

	-- Safety checks - use only basic Lua, no external modules
	if not G or not G.Menu then
		print("[CONFIG] Warning: G.Menu is nil, cannot save config")
		return
	end

	-- Get filepath using only filesystem (should still be available)
	local success, fullPath = pcall(filesystem.CreateDirectory, folder_name)

	-- If CreateDirectory fails, we assume the directory already exists (since we created it on load)
	-- and try to construct the path manually if fullPath is missing.
	-- filesystem.CreateDirectory returns (success, path) or (false/nil)

	local filepath
	if fullPath then
		filepath = fullPath .. "/config.cfg"
	else
		-- Fallback: try to construct path if we can't get it from CreateDirectory
		-- This might fail if folder_name is not absolute, but it's worth a try or we just skip
		-- Better approach: If we can't get the path, we can't save.
		-- But wait, the error "Cannot create directory" implies it failed.
		-- Let's try to use the relative path if fullPath is nil?
		-- io.open works with relative paths usually relative to the game folder or lua folder.
		-- But Lmaobox filesystem is sandboxed.

		-- If we failed to create/get directory, we probably can't save.
		-- But let's try one more thing: check if we have a cached path from load?
		-- We don't have access to Config.GetFilePath() result easily here without calling it.
		-- Let's just try to use the folder_name directly?
		-- actually, filesystem.CreateDirectory returns the absolute path.

		print("[CONFIG] Warning: Could not verify directory, attempting to save anyway...")
		-- We can't easily guess the absolute path if CreateDirectory failed to return it.
		-- However, we can try to use the folder_name relative path if io.open supports it.
		filepath = folder_name .. "/config.cfg"
	end

	-- Try to encode and save
	success, result = pcall(function()
		local encoded = safeJsonEncode(G.Menu)
		local file = io.open(filepath, "w")
		if file then
			file:write(encoded)
			file:close()
			print("[CONFIG] Config saved successfully to: " .. filepath)
			return true
		else
			print("[CONFIG] ERROR: Cannot open file for writing: " .. tostring(filepath))
			return false
		end
	end)

	if not success then
		print("[CONFIG] ERROR during save: " .. tostring(result))
		print("[CONFIG] Config NOT saved, but script unloading safely")
	end
end

callbacks.Register("Unload", "ConfigAutoSaveOnUnload", ConfigAutoSaveOnUnload)

return Config
