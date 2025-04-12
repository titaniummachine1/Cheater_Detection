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
		isInitialized = false,
	},
	-- Removed saveCount
}

-- Logger utility with severity levels
local LogLevel = {
	ERROR = 1,
	WARNING = 2,
	INFO = 3,
	DEBUG = 4,
}

local currentLogLevel = LogLevel.INFO -- Default log level
local showDebug = false -- Set to true to see all debug messages

-- Log function with severity level and colors
local function Log(level, message, color)
	-- Skip logging if message level is higher than current level
	if level > currentLogLevel and not showDebug then
		return
	end

	local prefix = ""
	local defaultColor = { 255, 255, 255, 255 }

	if level == LogLevel.ERROR then
		prefix = "[ERROR] "
		color = color or { 255, 100, 100, 255 }
	elseif level == LogLevel.WARNING then
		prefix = "[WARNING] "
		color = color or { 255, 255, 100, 255 }
	elseif level == LogLevel.INFO then
		prefix = "[INFO] "
		color = color or { 100, 255, 255, 255 }
	elseif level == LogLevel.DEBUG then
		prefix = "[DEBUG] "
		color = color or { 180, 180, 180, 255 }
	end

	if color then
		printc(color[1], color[2], color[3], color[4], prefix .. message)
	else
		print(prefix .. message)
	end
end

-- Find best path for database storage (saves as JSON now)
function Database.GetFilePath()
	-- Ensure base directory exists
	pcall(filesystem.CreateDirectory, "Lua Cheater_Detection")
	return "Lua Cheater_Detection/database.json" -- Hardcoded path for simplicity
end

-- Save the G.DataBase table to the JSON file
function Database.SaveDatabase()
	Log(LogLevel.DEBUG, "[DB] Starting database save operation")

	if not Database.State.isDirty then
		Log(LogLevel.DEBUG, "[DB] Database not dirty, skipping save")
		return
	end

	if type(G.DataBase) ~= "table" then
		Log(LogLevel.ERROR, "[DB] Cannot save: G.DataBase is not a table")
		return
	end

	local encodedData = Json.encode(G.DataBase)
	if not encodedData then
		Log(LogLevel.ERROR, "[DB] Failed to encode database to JSON")
		return
	end

	local filepath = Database.GetFilePath()
	Log(LogLevel.DEBUG, "[DB] Writing to file: " .. filepath)

	local file = io.open(filepath, "w")
	if not file then
		Log(LogLevel.ERROR, "[DB] Failed to open file for writing: " .. filepath)
		return
	end

	file:write(encodedData)
	file:close()

	encodedData = nil -- Clear reference for GC
	collectgarbage("collect")

	Database.State.isDirty = false
	Database.State.lastSave = os.time()

	Log(LogLevel.INFO, "[DB] Database saved successfully", { 0, 255, 140, 255 })
end

-- Load the database from the JSON file
function Database.LoadDatabase(silent, force)
	-- Skip loading if recently loaded (within 10 seconds) unless forced
	local currentTime = os.time()
	if Database.State.isInitialized and not force and (currentTime - Database.State.lastLoaded < 10) then
		Log(LogLevel.DEBUG, "[DB] Skipping reload, database already loaded recently")
		return
	end

	Log(LogLevel.DEBUG, "[DB] Starting database load operation")
	local filePath = Database.GetFilePath()

	local file = io.open(filePath, "r")
	if not file then
		if not silent then
			Log(LogLevel.WARNING, "[DB] Database file not found, initializing empty database")
		end
		G.DataBase = {}
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return
	end

	local content = file:read("*a")
	file:close()

	if not content or #content == 0 then
		if not silent then
			Log(LogLevel.WARNING, "[DB] Database file is empty, initializing empty database")
		end
		G.DataBase = {}
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return
	end

	Log(LogLevel.DEBUG, "[DB] Decoding JSON content")
	local decodedData = Json.decode(content)
	content = nil
	collectgarbage("collect")

	if type(decodedData) ~= "table" then
		if not silent then
			Log(LogLevel.ERROR, "[DB] JSON decode failed or result is not a table")
		end
		G.DataBase = {}
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return
	end

	-- Count initial entries for reporting
	local initialCount = 0
	for _ in pairs(decodedData) do
		initialCount = initialCount + 1
	end

	Log(LogLevel.DEBUG, string.format("[DB] Decoded %d entries from JSON", initialCount))
	G.DataBase = decodedData

	-- Validation with progress reporting
	Log(LogLevel.DEBUG, "[DB] Starting database validation")
	local changesMade = false
	local entriesToRemove = {}
	local totalEntries = 0
	local passedCount = 0
	local failedCount = 0

	-- Process entries in batches
	for steamID, value in pairs(G.DataBase) do
		totalEntries = totalEntries + 1

		-- Basic validation (ensure it's a table and key looks like a SteamID64)
		if type(value) ~= "table" or type(steamID) ~= "string" or not steamID:match("^765611%d+$") then
			failedCount = failedCount + 1
			table.insert(entriesToRemove, steamID)
		else
			passedCount = passedCount + 1
		end

		-- Print batch progress less frequently for large databases
		if totalEntries % 1000 == 0 then
			Log(
				LogLevel.DEBUG,
				string.format(
					"[DB] Validated %d entries so far (%d passed, %d failed)",
					totalEntries,
					passedCount,
					failedCount
				)
			)
		end
	end

	-- Final validation summary
	Log(
		LogLevel.INFO,
		string.format("[DB] Validated %d entries (%d passed, %d failed)", totalEntries, passedCount, failedCount)
	)

	if #entriesToRemove > 0 then
		if not silent then
			Log(LogLevel.WARNING, string.format("[DB] Removing %d invalid entries", #entriesToRemove))
		end
		for _, key in ipairs(entriesToRemove) do
			G.DataBase[key] = nil
		end
		changesMade = true
	end

	Database.State.isDirty = changesMade
	Database.State.lastLoaded = os.time()
	Database.State.isInitialized = true

	if not silent then
		local finalCount = 0
		for _ in pairs(G.DataBase) do
			finalCount = finalCount + 1
		end
		Log(
			LogLevel.INFO,
			string.format("[DB] Database loaded with %d valid entries", finalCount),
			{ 0, 255, 140, 255 }
		)
	end

	collectgarbage("collect")
end

-- Simplified Initialize function
local function InitializeDatabase()
	-- Skip if already initialized
	if Database.State.isInitialized then
		Log(LogLevel.DEBUG, "[DB] Database already initialized, skipping")
		return
	end

	Log(LogLevel.DEBUG, "[DB] Initializing database module")

	-- Ensure G.DataBase exists as a table before loading
	if type(G.DataBase) ~= "table" then
		Log(LogLevel.DEBUG, "[DB] G.DataBase not found, initializing empty")
		G.DataBase = {}
	end

	-- Load existing data
	Database.LoadDatabase()
	Log(LogLevel.DEBUG, "[DB] Database initialization complete")
end

-- Save database automatically when the script unloads (if dirty)
callbacks.Register("Unload", "DatabaseAutoSaveOnUnload", function()
	Log(LogLevel.DEBUG, "[DB] Unloading database, saving data...")

	-- Always save on unload to prevent data loss
	if Database.Config.SaveOnExit then
		-- If not dirty, mark as dirty temporarily to force save
		local wasDirty = Database.State.isDirty
		Database.State.isDirty = true

		Log(LogLevel.INFO, "[DB] Saving database on exit")
		Database.SaveDatabase()

		-- Restore original dirty state if it wasn't modified
		if not wasDirty then
			Database.State.isDirty = false
		end
	else
		Log(LogLevel.WARNING, "[DB] SaveOnExit disabled, skipping final save")
	end
end)

-- Initial load and setup
InitializeDatabase()

Log(LogLevel.DEBUG, "[DB] Module initialization complete")

--[[ Add Initialize function here ]]
--
function Database.Initialize(silent)
	Log(LogLevel.DEBUG, "[DB] Initializing Database module...")

	-- Load the database (this function handles creating an empty one if needed)
	Database.LoadDatabase(silent, false)

	-- Verify G.DataBase is initialized (LoadDatabase should ensure this)
	if not G.DataBase then
		Log(LogLevel.ERROR, "[DB] CRITICAL: G.DataBase is nil after LoadDatabase!")
		G.DataBase = {} -- Critical fallback
		Database.State.isDirty = true
	else
		Log(LogLevel.DEBUG, "[DB] G.DataBase initialized, type:" .. type(G.DataBase))
	end

	local entryCount = 0
	if type(G.DataBase) == "table" then
		for _ in pairs(G.DataBase) do
			entryCount = entryCount + 1
		end
	end

	if not silent then
		if entryCount == 0 then
			Log(LogLevel.WARNING, "[DB] Database is empty or could not be loaded. Fetch data or check logs.")
		else
			Log(
				LogLevel.INFO,
				string.format("[DB] Initialized with %d database entries", entryCount),
				{ 0, 255, 140, 255 }
			)
		end
	end

	Log(LogLevel.DEBUG, "[DB] Database initialization complete.")
end

return Database
