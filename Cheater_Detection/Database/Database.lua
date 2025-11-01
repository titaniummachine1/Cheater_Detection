--[[
    Simplified Database.lua
    Direct implementation of database functionality using native Lua tables
    Stores only essential data: name and proof for each SteamID64
]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
-- [[ Imported by: Fetcher.lua (indirectly) ]]
local G = require("Cheater_Detection.Utils.Globals")
-- [[ Imported by: Fetcher.lua, Database.lua ]]
local Json = Common.Json
-- [[ Imported by: Database.lua ]]

--[[ Module Declaration ]]
local Database = {
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

--[[ Local Variables/Utilities ]]
local LogLevel = {
	ERROR = 1,
	WARNING = 2,
	SUCCESS = 3, -- Added Success level
	INFO = 4, -- Shifted Info down
	DEBUG = 5, -- Shifted Debug down
}

local currentLogLevel = LogLevel.INFO -- Default log level still includes SUCCESS
local showDebug = false -- Set to true to see all debug messages

--[[ Helper/Private Functions ]]
-- Log function with severity level and colors (Refactored to use Database's Log)
local function Log(level, message, color)
	-- Ensure Database and its Log function are available
	if Database and Database.Log then
		Database.Log(level, message, color)
	elseif G.Menu.Advanced.debug then
		-- Fallback to plain print if Database.Log is unavailable
		local prefixMap =
			{ [1] = "[ERROR] ", [2] = "[WARNING] ", [3] = "[SUCCESS] ", [4] = "[INFO] ", [5] = "[DEBUG] " }
		print((prefixMap[level] or "") .. message)
	end
end

-- Save database automatically when the script unloads (if dirty)
local function DatabaseAutoSaveOnUnload()
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
end

--[[ Public Module Functions ]]
-- Robust SetPriority with multiple fallback methods
-- Tries: entity -> index -> SteamID64 -> SteamID3
-- For database entries (not in-game), tries: SteamID64 -> SteamID3
function Database.SetPriority(target, priority, isInGame)
	if not target then
		Log(LogLevel.ERROR, "[DB] SetPriority: target is nil")
		return false
	end

	local success = false
	local lastError = nil

	-- Method 1: Try entity (only if in-game)
	if isInGame ~= false and type(target) == "userdata" then
		success, lastError = pcall(playerlist.SetPriority, target, priority)
		if success then
			Log(LogLevel.DEBUG, string.format("[DB] SetPriority via entity: priority=%d", priority))
			return true
		end
	end

	-- Method 2: Try index (only if in-game)
	if isInGame ~= false and type(target) == "number" and target < 101 then
		success, lastError = pcall(playerlist.SetPriority, target, priority)
		if success then
			Log(LogLevel.DEBUG, string.format("[DB] SetPriority via index %d: priority=%d", target, priority))
			return true
		end
	end

	-- Method 3: Try SteamID64
	local steamID64 = nil
	if type(target) == "string" and #target == 17 then
		steamID64 = target
	elseif type(target) == "userdata" then
		-- Try to get SteamID64 from entity
		steamID64 = Common.GetSteamID64(target)
	end

	if steamID64 then
		success, lastError = pcall(playerlist.SetPriority, steamID64, priority)
		if success then
			Log(LogLevel.DEBUG, string.format("[DB] SetPriority via SteamID64 %s: priority=%d", steamID64, priority))
			return true
		end
	end

	-- Method 4: Try SteamID3 conversion
	if steamID64 then
		-- Convert SteamID64 to SteamID3 format [U:1:XXXXXXXX]
		local accountID = tonumber(steamID64) - 76561197960265728
		if accountID and accountID > 0 then
			local steamID3 = string.format("[U:1:%d]", accountID)
			success, lastError = pcall(playerlist.SetPriority, steamID3, priority)
			if success then
				Log(LogLevel.DEBUG, string.format("[DB] SetPriority via SteamID3 %s: priority=%d", steamID3, priority))
				return true
			end
		end
	end

	-- All methods failed
	Log(
		LogLevel.ERROR,
		string.format(
			"[DB] SetPriority FAILED for target (type=%s): %s",
			type(target),
			tostring(lastError or "all methods failed")
		)
	)
	return false
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

	local encodedData
	if Json and Json.encode then -- Add nil check for Json.encode
		encodedData = Json.encode(G.DataBase)
	else
		Log(LogLevel.ERROR, "[DB] Json.encode function is not available!")
		return -- Cannot proceed without encoder
	end

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

	--@diagnostic disable-next-line: cast-local-type -- Disable incorrect linter warning
	encodedData = nil -- Clear reference for GC

	Database.State.isDirty = false
	Database.State.lastSave = os.time()

	---@diagnostic disable-next-line: param-type-mismatch -- Disable incorrect linter warning
	Log(LogLevel.SUCCESS, "[DB] Database saved successfully")
end

-- Load the database from the JSON file
function Database.LoadDatabase(silent, force)
	-- Skip loading if recently loaded (within 10 seconds) unless forced
	local currentTime = os.time()
	if Database.State.isInitialized and not force and (currentTime - Database.State.lastLoaded < 10) then
		Log(LogLevel.DEBUG, "[DB] Skipping reload, database already loaded recently")
		return
	end

	Log(LogLevel.DEBUG, "[DB] Starting database load operation") -- Keep DEBUG
	local filePath = Database.GetFilePath()

	local file = io.open(filePath, "r")
	if not file then
		-- Always log warning if file missing, as it prevents loading
		Log(LogLevel.WARNING, "[DB] Database file not found, initializing empty database")
		G.DataBase = {}
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return
	end

	local content = file:read("*a")
	file:close()

	if not content or #content == 0 then
		-- Always log warning if file empty, as it means no data
		Log(LogLevel.WARNING, "[DB] Database file is empty, initializing empty database")
		G.DataBase = {}
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return
	end

	Log(LogLevel.DEBUG, "[DB] Decoding JSON content") -- Keep DEBUG
	local decodedData
	if Json and Json.decode then -- Add nil check for Json.decode
		decodedData = Json.decode(content)
	else
		-- Always log critical error
		Log(LogLevel.ERROR, "[DB] Json.decode function is not available!")
		G.DataBase = {} -- Fallback to empty DB
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return -- Cannot proceed without decoder
	end
	content = nil -- Clear content reference

	if type(decodedData) ~= "table" then
		-- Always log critical error
		Log(LogLevel.ERROR, "[DB] JSON decode failed or result is not a table")
		G.DataBase = {}
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return
	end

	Log(LogLevel.DEBUG, "[DB] Starting database validation") -- Keep DEBUG
	local initialCount = 0
	for _ in pairs(decodedData) do
		initialCount = initialCount + 1
	end
	G.DataBase = decodedData -- Assign after counting

	local changesMade = false
	local entriesToRemove = {}
	local totalEntries = 0
	local passedCount = 0
	local failedCount = 0

	for steamID, value in pairs(G.DataBase) do
		totalEntries = totalEntries + 1
		if
			type(value) ~= "table"
			or type(steamID) ~= "string"
			or not steamID:match("^7656119%d+$")
			or #steamID ~= 17
		then
			failedCount = failedCount + 1
			table.insert(entriesToRemove, steamID)
		else
			passedCount = passedCount + 1
		end
		-- Removed periodic validation progress log
	end

	-- Always Log validation summary, color based on failures
	if failedCount > 0 then
		Log(
			LogLevel.WARNING, -- Yellow if failures
			string.format(
				"[DB] Validation finished: %d total, %d passed, %d FAILED",
				totalEntries,
				passedCount,
				failedCount
			)
		)
	elseif not silent then -- Only log non-failure summary if not silent
		Log(
			LogLevel.INFO, -- Cyan if no failures and not silent
			string.format(
				"[DB] Validation finished: %d total, %d passed, %d failed",
				totalEntries,
				passedCount,
				failedCount
			)
		)
	end

	-- Always log if removing entries (Warning)
	if #entriesToRemove > 0 then
		Log(LogLevel.WARNING, string.format("[DB] Removing %d invalid entries", #entriesToRemove))
		for _, key in ipairs(entriesToRemove) do
			G.DataBase[key] = nil
		end
		changesMade = true
	end

	Database.State.isDirty = changesMade
	Database.State.lastLoaded = os.time()
	Database.State.isInitialized = true

	-- Only log final success count if not silent
	if not silent then
		local finalCount = 0
		for _ in pairs(G.DataBase) do
			finalCount = finalCount + 1
		end
		-- Always print the final count summary using printc in green, regardless of debug mode
		Log(Database.LogLevel.SUCCESS, string.format("[DB] Database loaded with %d valid entries", finalCount))
	end
end

-- Simplified Initialize function that serves both internal and external needs
function Database.Initialize(silent)
	-- Skip if already initialized and not forcing
	if Database.State.isInitialized then
		Log(LogLevel.DEBUG, "[DB] Database already initialized, skipping")
		return
	end

	Log(LogLevel.DEBUG, "[DB] Initializing Database module...") -- Keep DEBUG

	-- Ensure G.DataBase exists as a table before loading
	if type(G.DataBase) ~= "table" then
		Log(LogLevel.DEBUG, "[DB] G.DataBase not found, initializing empty")
		G.DataBase = {}
	end

	-- Load the database (uses the updated LoadDatabase logging)
	Database.LoadDatabase(silent, false)

	-- Verify G.DataBase is initialized (LoadDatabase should ensure this)
	if not G.DataBase then
		-- Always log critical error
		Log(LogLevel.ERROR, "[DB] CRITICAL: G.DataBase is nil after LoadDatabase!")
		G.DataBase = {} -- Critical fallback
		Database.State.isDirty = true
	else
		Log(LogLevel.DEBUG, "[DB] G.DataBase initialized, type:" .. type(G.DataBase)) -- Keep DEBUG
	end

	-- Removed redundant final count log here, handled in LoadDatabase

	-- Always set local player priority to 0 and clear from database
	-- Debug mode is only a floodgate for detection, not for cleanup
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer then
		-- Get SteamID64 for all operations
		local mySteamID = Common.GetSteamID64(localPlayer)
		if mySteamID then
			-- Always set priority to 0 using robust method
			local prioritySet = Database.SetPriority(localPlayer, 0, true)
			if prioritySet then
				Log(LogLevel.INFO, string.format("[DB] Set local player priority to 0 (SteamID64: %s)", mySteamID))
			else
				Log(
					LogLevel.WARNING,
					string.format("[DB] Failed to set local player priority (SteamID64: %s)", mySteamID)
				)
			end

			-- Always remove from database (debug mode controls detection, not cleanup)
			if G.DataBase[mySteamID] then
				G.DataBase[mySteamID] = nil
				Database.State.isDirty = true
				Log(
					LogLevel.SUCCESS,
					string.format("[DB] Removed local player from database (SteamID64: %s)", mySteamID)
				)
				-- Immediately save to persist cleanup
				Database.SaveDatabase()
				Log(LogLevel.INFO, "[DB] Database saved after local player cleanup")
			else
				Log(LogLevel.DEBUG, "[DB] Local player not in database")
			end
		else
			Log(LogLevel.WARNING, "[DB] Failed to get local player SteamID64")
		end
	else
		Log(LogLevel.WARNING, "[DB] Failed to get local player entity")
	end

	Log(LogLevel.DEBUG, "[DB] Database initialization complete.") -- Keep DEBUG
	Database.State.isInitialized = true
end

--[[ Self-Initialization ]]
-- Initial load and setup (silent=true to avoid verbose messages at load time)
Database.Initialize(true)

--- Upsert a cheater entry into the database (minimal format like fetched data)
---@param steamID string Player's SteamID64
---@param data table Cheater data (name, reason)
function Database.UpsertCheater(steamID, data)
	if not steamID or type(steamID) ~= "string" then
		Log(LogLevel.ERROR, "[DB] UpsertCheater: Invalid steamID")
		return false
	end

	if not steamID:match("^7656119%d+$") or #steamID ~= 17 then
		Log(LogLevel.ERROR, "[DB] UpsertCheater: Invalid steamID format: " .. steamID)
		return false
	end

	-- Ensure G.DataBase exists
	if type(G.DataBase) ~= "table" then
		G.DataBase = {}
	end

	-- Minimal format like fetched databases: just Name and Reason
	G.DataBase[steamID] = {
		Name = data.name or "Unknown",
		Reason = data.reason or "Cheater", -- Use provided reason, fallback to "Cheater" for imported data
	}

	-- Mark as dirty for save
	Database.State.isDirty = true

	-- Save immediately to prevent data loss on crashes
	Database.SaveDatabase()

	Log(
		LogLevel.INFO,
		string.format(
			"[DB] Added cheater: %s (%s) - Reason: %s",
			data.name or "Unknown",
			steamID,
			data.reason or "Cheater"
		)
	)

	return true
end

--- Get a cheater entry from the database
---@param steamID string Player's SteamID64
---@return table|nil Cheater data or nil if not found
function Database.GetCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then
		return nil
	end

	return G.DataBase[steamID]
end

--- Remove a cheater entry from the database
---@param steamID string Player's SteamID64
---@return boolean Success
function Database.RemoveCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then
		return false
	end

	if G.DataBase[steamID] then
		G.DataBase[steamID] = nil
		Database.State.isDirty = true
		-- Save immediately to maintain database consistency
		Database.SaveDatabase()
		Log(LogLevel.INFO, "[DB] Removed cheater: " .. steamID)
		return true
	end

	return false
end

--- Force save the database (ignores dirty flag)
---@return boolean Success
function Database.ForceSave()
	local wasDirty = Database.State.isDirty
	Database.State.isDirty = true
	Database.SaveDatabase()
	if not wasDirty then
		Database.State.isDirty = false
	end
	return true
end

--[[ Callback Registration ]]
callbacks.Register("Unload", "DatabaseAutoSaveOnUnload", DatabaseAutoSaveOnUnload)

return Database
