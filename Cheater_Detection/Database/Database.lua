--[[
    Simplified Database.lua
    Direct implementation of database functionality using native Lua tables
    Stores only essential data: name and proof for each SteamID64
]]

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Json = Common.Json
-- local Database_Fetcher = require("Cheater_Detection.Database.Database_Fetcher") -- No longer needed here

--[[ Removed serializeTableToLuaString function as we now use JSON ]]

local Database = {
	-- Removed internal data storage
	-- data = {},

	-- Configuration (Simplified)
	Config = {
		SaveOnExit = true,
		DebugMode = false,
		-- MaxEntries = 15000, -- Cleanup logic removed
	},

	-- State tracking (Simplified)
	State = {
		isDirty = false, -- Still potentially useful for SaveOnExit
		lastSave = 0,
		lastLoaded = 0,
	},
	-- Removed saveCount
}

-- Removed Database.content metatable accessor

-- Removed HandleSetEntry function

-- Find best path for database storage (saves as JSON now)
function Database.GetFilePath()
	-- Ensure base directory exists
	pcall(filesystem.CreateDirectory, "Lua Cheater_Detection")
	return "Lua Cheater_Detection/database.json" -- Hardcoded path for simplicity
end

-- Save the G.DataBase table to the JSON file
function Database.SaveDatabase()
	print("[DB SOURCE SaveDatabase] >>> ENTERED SaveDatabase function.") -- ++DEBUG

	if not Database.State.isDirty then
		print("[DB SOURCE SaveDatabase] Database not dirty, skipping save.") -- ++DEBUG
		return -- No need to return true, just exit
	end

	if type(G.DataBase) ~= "table" then
		printc(255, 100, 100, 255, "[DB SOURCE Save JSON] Aborting: G.DataBase is not a table.") -- ++DEBUG
		return -- Exit if not a table
	end

	print("[DB SOURCE Save JSON] Encoding data to JSON...") -- ++DEBUG
	local encodedData = Json.encode(G.DataBase) -- Assumes this works
	print("[DB SOURCE Save JSON] Encode successful.") -- ++DEBUG

	-- Handle potential encode failure gracefully by checking result
	if not encodedData then
		printc(255, 100, 100, 255, "[DB SOURCE Save JSON] FAILED TO ENCODE database.") -- ++DEBUG
		return -- Exit if encoding failed
	end

	local filepath = Database.GetFilePath()
	print(string.format("[DB SOURCE Save JSON] Writing JSON to file: %s", filepath)) -- ++DEBUG

	-- Write directly using io functions, assume success mostly
	local file = io.open(filepath, "w")
	if not file then
		printc(255, 100, 100, 255, "[DB SOURCE Save JSON] FAILED TO OPEN FILE FOR WRITING: " .. filepath) -- ++DEBUG
		return -- Exit if file cannot be opened
	end

	-- Assume write works
	file:write(encodedData)
	print("[DB SOURCE Save JSON] Write operation performed.") -- ++DEBUG
	file:close()

	encodedData = nil -- Clear reference for GC
	collectgarbage("collect")

	print(string.format("[DB SOURCE Save JSON] Data written to %s", filepath)) -- ++DEBUG
	Database.State.isDirty = false
	Database.State.lastSave = os.time()

	printc(0, 255, 140, 255, "[" .. os.date("%H:%M:%S") .. "] [DB SOURCE] Saved JSON database.") -- ++DEBUG
	print("[DB SOURCE SaveDatabase] <<< EXITED SaveDatabase function.") -- ++DEBUG
	-- No explicit return needed
end

-- Load the database from the JSON file
function Database.LoadDatabase(silent)
	print("[DB SOURCE Loaddatabase] >>> ENTERED Loaddatabase function.") -- ++DEBUG
	local filePath = Database.GetFilePath()

	local file = io.open(filePath, "r")

	if not file then
		if not silent then
			print("[DB SOURCE Load JSON] Database file not found: " .. filePath .. ". Initializing empty database.") -- ++DEBUG
		end
		G.DataBase = {}
		Database.State.isDirty = true -- Mark dirty so it's saved on exit
		Database.State.lastLoaded = os.time()
		print("[DB SOURCE Loaddatabase] <<< EXITED Loaddatabase (file not found).") -- ++DEBUG
		return -- Exit, database is empty
	end

	print("[DB SOURCE Load JSON] File opened. Reading content...") -- ++DEBUG
	local content = file:read("*a")
	file:close()
	print("[DB SOURCE Load JSON] File read and closed.") -- ++DEBUG

	if not content or #content == 0 then
		if not silent then
			print("[DB SOURCE Load JSON] Database file is empty: " .. filePath .. ". Initializing empty database.") -- ++DEBUG
		end
		G.DataBase = {}
		Database.State.isDirty = true -- Mark dirty
		Database.State.lastLoaded = os.time()
		print("[DB SOURCE Loaddatabase] <<< EXITED Loaddatabase (empty file).") -- ++DEBUG
		return -- Exit, database is empty
	end

	print("[DB SOURCE Load JSON] Decoding JSON content...") -- ++DEBUG
	local decodedData = Json.decode(content)
	content = nil
	collectgarbage("collect")

	-- ++DEBUG: Check decoded data type and initial count
	if decodedData then
		local decodedType = type(decodedData)
		local initialDecodedCount = 0
		if decodedType == "table" then
			for _ in pairs(decodedData) do
				initialDecodedCount = initialDecodedCount + 1
			end
		end
		print(
			string.format(
				"[DB SOURCE Load JSON DEBUG] Decoded data type: %s, Initial entry count: %d",
				decodedType,
				initialDecodedCount
			)
		) -- ++DEBUG
	else
		print("[DB SOURCE Load JSON DEBUG] decodedData is nil after Json.decode") -- ++DEBUG
	end

	-- Check if decode result is a table
	if type(decodedData) ~= "table" then
		if not silent then
			printc(255, 100, 100, 255, "[DB SOURCE Load JSON] Error: Decode result is not a table. File: " .. filePath) -- ++DEBUG
		end
		print("[DB SOURCE Load JSON] Decode failed or result not a table.") -- ++DEBUG
		G.DataBase = {} -- Initialize empty
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		print("[DB SOURCE Loaddatabase] <<< EXITED Loaddatabase (decode failed or not table).") -- ++DEBUG
		return -- Exit, database is empty
	end

	print("[DB SOURCE Load JSON] Decode successful.") -- ++DEBUG
	G.DataBase = decodedData
	-- ++DEBUG: Check G.DataBase immediately after assignment
	local gdbType = type(G.DataBase)
	local gdbCount = 0
	if gdbType == "table" then
		for _ in pairs(G.DataBase) do
			gdbCount = gdbCount + 1
		end
	end
	print(string.format("[DB SOURCE Loaddatabase DEBUG] G.DataBase type post-assign: %s, Count: %d", gdbType, gdbCount)) -- ++DEBUG

	print("[DB SOURCE Loaddatabase] Assigned decoded data to G.DataBase.") -- ++DEBUG

	-- Validation (Keep existing validation logic for data integrity)
	print("[DB SOURCE Loaddatabase] Starting validation...") -- ++DEBUG
	local changesMade = false
	local entriesToRemove = {}
	local initialCount = 0
	for steamID, value in pairs(G.DataBase) do
		initialCount = initialCount + 1
		print(
			string.format(
				"[DB SOURCE Validation DEBUG] Processing Key: %s, Value Type: %s",
				tostring(steamID),
				type(value)
			)
		) -- ++DEBUG
		-- Basic validation (ensure it's a table and key looks like a SteamID64)
		if type(value) ~= "table" or type(steamID) ~= "string" or not steamID:match("^765611%d+$") then
			print(string.format("[DB SOURCE Validation DEBUG] FAILED initial check for Key: %s", tostring(steamID))) -- ++DEBUG
			if not silent then
				print(
					string.format(
						"[DB SOURCE Load JSON] Invalid entry found: Key=%s, Type=%s. Removing.",
						tostring(steamID),
						type(value)
					)
				) -- ++DEBUG
			end
			table.insert(entriesToRemove, steamID)
		else
			print(string.format("[DB SOURCE Validation DEBUG] PASSED initial check for Key: %s", tostring(steamID))) -- ++DEBUG
			-- Optional: Ensure standard fields exist (uncomment if needed)
			-- if not value.Name then value.Name = "Unknown"; changesMade = true end
			-- if not value.Reason then value.Reason = "Unknown"; changesMade = true end
		end
	end
	print(string.format("[DB SOURCE Loaddatabase] Validation checked %d entries.", initialCount)) -- ++DEBUG
	print(string.format("[DB SOURCE Loaddatabase DEBUG] Total entries marked for removal: %d", #entriesToRemove)) -- ++DEBUG

	if #entriesToRemove > 0 then
		if not silent then
			print("[DB SOURCE Load JSON] Removing " .. #entriesToRemove .. " invalid entries during load.") -- ++DEBUG
		end
		for _, key in ipairs(entriesToRemove) do
			G.DataBase[key] = nil
		end
		changesMade = true
	end

	Database.State.isDirty = changesMade -- Only dirty if validation changed things
	Database.State.lastLoaded = os.time()
	print(string.format("[DB SOURCE Loaddatabase] Finished validation. isDirty = %s", tostring(Database.State.isDirty))) -- ++DEBUG

	if not silent then
		local finalCount = 0
		for _ in pairs(G.DataBase) do
			finalCount = finalCount + 1
		end -- Recount after removal
		printc(
			0,
			255,
			140,
			255,
			"[" .. os.date("%H:%M:%S") .. "] [DB SOURCE] Loaded JSON Database with " .. finalCount .. " valid entries."
		) -- ++DEBUG
	end

	collectgarbage("collect")
	print("[DB SOURCE Loaddatabase] <<< EXITED Loaddatabase function successfully.") -- ++DEBUG
	-- No explicit return needed
end

-- Simplified Initialize function
local function InitializeDatabase()
	print("[DB SOURCE Initialize] >>> ENTERED Initialize function.") -- ++DEBUG
	print("[Database] Initializing JSON Database Module...") -- ++DEBUG

	-- Ensure G.DataBase exists as a table before loading
	if type(G.DataBase) ~= "table" then
		print("[DB SOURCE Initialize] G.DataBase not found or not a table. Initializing empty.") -- ++DEBUG
		G.DataBase = {}
	end

	-- Load existing data. LoadDatabase handles initializing empty if needed.
	Database.LoadDatabase() -- Assume LoadDatabase prints relevant info
	print("[DB SOURCE Initialize] LoadDatabase finished execution.") -- ++DEBUG

	print("[DB SOURCE Initialize] <<< EXITED Initialize function.") -- ++DEBUG
end

-- Removed RegisterCommands (can be re-added if simple commands are needed)

-- Removed GetRecord, GetReason, GetName, Contains, updateDatabase, GetStats, Cleanup

-- Save database automatically when the script unloads (if dirty)
callbacks.Register("Unload", "DatabaseAutoSaveOnUnload", function()
	print("[DB SOURCE Unload] >>> Checking if save needed...") -- ++DEBUG
	if Database.Config.SaveOnExit and Database.State and Database.State.isDirty then
		print("[DB SOURCE Unload] Database is dirty, attempting save...") -- ++DEBUG
		Database.SaveDatabase()
	else
		print("[DB SOURCE Unload] Database not dirty or SaveOnExit disabled, no save needed.") -- ++DEBUG
	end
end)

-- Initial load and setup
InitializeDatabase() -- Call the local function to load/initialize

print("[DB SOURCE] >>> Module execution finished. Returning Database table.") -- ++DEBUG
return Database -- Return the module table (even though most functions are removed)
