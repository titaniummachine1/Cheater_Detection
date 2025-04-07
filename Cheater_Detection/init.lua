--[[
    Main Entry Point for Cheater Detection
    Handles proper module loading, unloading, and global cleanup
]]

-- Global unload function to clean up resources
local function UnloadCheaterDetection()
	print("[Cheater Detection] Unloading modules and cleaning up resources...")

	-- Attempt to save database if it's dirty
	pcall(function()
		local Database = package.loaded["Cheater_Detection.Database.Database"]
		if Database and Database.State and Database.State.isDirty then
			print("[Cheater Detection] Saving database before unload...")
			Database.SaveDatabase()
		end
	end)

	-- Step 2: Clear all module references from package.loaded
	local modulePrefix = "Cheater_Detection"
	local modulesToClear = {}
	for moduleName in pairs(package.loaded) do
		if moduleName:find("^" .. modulePrefix) then
			table.insert(modulesToClear, moduleName)
		end
	end

	for _, moduleName in ipairs(modulesToClear) do
		package.loaded[moduleName] = nil
		-- Also clear potential globals created by require (using common patterns)
		local globalName = moduleName:match("[^.]+") == modulePrefix and moduleName:match("[^.]+$")
			or moduleName:gsub("%.", "_")
		if globalName and _G[globalName] then
			_G[globalName] = nil
		end
	end

	-- Step 3: Clear specific global tables and variables if they exist
	local globalsToClear = { "G", "Menu", "CheaterDetection" }
	for _, globalName in ipairs(globalsToClear) do
		if _G[globalName] then
			_G[globalName] = nil
		end
	end

	-- Step 4: Force garbage collection
	collectgarbage("collect")

	print("[Cheater Detection] Unload complete.")
end

-- Handle module unloading if it's already loaded
if package.loaded["Cheater_Detection"] then
	UnloadCheaterDetection()
	package.loaded["Cheater_Detection"] = nil
end

-- Register the unload function to run on script unload
callbacks.Register("Unload", "CD_Unload", UnloadCheaterDetection)

-- Create the module with added validation functions
local CheaterDetection = {
	Version = "2.0.1-refactored", -- Update version
	UnloadModule = UnloadCheaterDetection,
}

-- Load the main module
local success, Main = pcall(require, "Cheater_Detection.Main")
if not success or not Main then
	error("[Cheater Detection] Failed to load Main module: " .. tostring(Main))
else
	-- Export public methods from Main
	CheaterDetection.ReloadDatabase = Main.ReloadDatabase
	CheaterDetection.UpdateDatabase = Main.UpdateDatabase
	CheaterDetection.GetDatabaseStats = Main.GetDatabaseStats
	-- CheaterDetection.ValidateDatabase = function() -- Removed as validation logic changed
	--    local DBManager = require("Cheater_Detection.Database.Manager")
	--    return DBManager.ValidateDatabase()
	-- end
end

-- Print initialization message with safe coordinates
printc(0, 255, 140, 255, string.format("[Cheater Detection] Initialized version %s", CheaterDetection.Version))

-- Return the module
return CheaterDetection
