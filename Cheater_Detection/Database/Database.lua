--[[
    Simplified Database.lua
    Direct implementation of database functionality using native Lua tables
    Stores only essential data: name and proof for each SteamID64
]]

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Json = Common.Json
local Database_Fetcher = require("Cheater_Detection.Database.Database_Fetcher")

-- Helper function to serialize a Lua table into a string format
local function serializeTableToLuaString(tbl, level)
	level = level or 0
	local indent = string.rep("  ", level)
	local result = "{\n"

	local keys = {}
	for k in pairs(tbl) do
		table.insert(keys, k)
	end
	table.sort(keys) -- Sort keys for consistent output

	for i, key in ipairs(keys) do
		local value = tbl[key]
		result = result .. indent .. "  "

		-- Format key (assuming keys are SteamID64 strings)
		result = result .. '["' .. tostring(key) .. '"] = '

		-- Format value (assuming value is a table with Name and Reason)
		if type(value) == "table" then
			local nameStr = value.Name or "Unknown"
			local reasonStr = value.Reason or value.proof or "Unknown" -- Use Reason primarily

			-- Escape quotes and backslashes in strings
			nameStr = nameStr:gsub('[\\"]', "\\%1")
			reasonStr = reasonStr:gsub('[\\"]', "\\%1")

			result = result .. '{ Name = "' .. nameStr .. '", Reason = "' .. reasonStr .. '" }'
		else
			-- Fallback for unexpected data types (shouldn't happen with proper structure)
			result = result .. '"' .. tostring(value):gsub('[\\"]', "\\%1") .. '"'
		end

		-- Add comma if not the last element
		if i < #keys then
			result = result .. ","
		end
		result = result .. "\n"
	end

	result = result .. indent .. "}"
	return result
end

local Database = {
	-- Internal data storage (direct table)
	data = {},

	-- Configuration
	Config = {
		AutoSave = true,
		SaveInterval = 300, -- 5 minutes
		DebugMode = false,
		MaxEntries = 15000, -- Maximum entries to prevent memory issues
	},

	-- State tracking
	State = {
		entriesCount = 0,
		isDirty = false,
		lastSave = 0,
	},
}

-- Create the content accessor with metatable for cleaner API
Database.content = setmetatable({}, {
	__index = function(_, key)
		return Database.data[key]
	end,

	__newindex = function(_, key, value)
		Database.HandleSetEntry(key, value)
	end,

	__pairs = function()
		return pairs(Database.data)
	end,
})

-- Handle setting an entry with optimized record updating
function Database.HandleSetEntry(key, value)
	-- Skip nil values or invalid keys
	if not key then
		return
	end

	-- Get existing entry
	local existing = Database.data[key]

	-- If removing an entry
	if value == nil then
		if existing then
			Database.data[key] = nil
			Database.State.entriesCount = Database.State.entriesCount - 1
			Database.State.isDirty = true
		end
		return
	end

	-- Ensure key is a valid SteamID64 format before adding/updating
	if type(key) ~= "string" or not key:match("^765611%d{11}$") then
		-- Optionally print a warning for invalid keys?
		-- print("[Database] Warning: Attempted to set entry with invalid SteamID64 key: " .. tostring(key))
		return
	end

	-- If adding a new entry
	if not existing then
		-- Simplified data structure - keep only Name and Reason
		Database.data[key] = {
			Name = type(value) == "table" and (value.Name or "Unknown") or "Unknown",
			Reason = type(value) == "table" and (value.Reason or value.proof or value.cause or "Unknown") or "Unknown", -- Prioritize Reason
		}

		Database.State.entriesCount = Database.State.entriesCount + 1
		Database.State.isDirty = true
	else
		-- Update existing entry but only if the new data has better information
		if type(value) == "table" then
			-- Only update name if the new name is better
			if value.Name and value.Name ~= "Unknown" and (not existing.Name or existing.Name == "Unknown") then
				existing.Name = value.Name
				Database.State.isDirty = true
			end

			-- Only update Reason if the new Reason is better
			local newReason = value.Reason or value.proof or value.cause
			if newReason and newReason ~= "Unknown" and (not existing.Reason or existing.Reason == "Unknown") then
				existing.Reason = newReason -- Use Reason field
				Database.State.isDirty = true
			end
		end
	end

	-- Auto-save if enabled and enough time has passed
	if Database.Config.AutoSave and Database.State.isDirty then
		local currentTime = os.time()
		if currentTime - Database.State.lastSave >= Database.Config.SaveInterval then
			Database.SaveDatabase()
		end
	end
end

-- Find best path for database storage
function Database.GetFilePath()
	local possibleFolders = {
		"Lua Cheater_Detection",
		"Lua Scripts/Cheater_Detection",
		"lbox/Cheater_Detection",
		"lmaobox/Cheater_Detection",
		".",
	}

	-- Define the filename we want to use
	local filename = "/database.lua"

	-- Try to find existing folder first
	for _, folder in ipairs(possibleFolders) do
		local potentialPath = folder .. filename
		if pcall(function()
			return filesystem.GetFileSize(potentialPath)
		end) then
			-- Found existing file in this folder
			local success, fullPath = pcall(filesystem.FullPath, folder) -- Get full path for consistency
			if success and fullPath then
				return fullPath .. filename
			else
				return potentialPath -- Fallback to relative path if FullPath fails
			end
		end
		-- Also check if the directory itself exists, even if the file doesn't yet
		if pcall(function()
			return filesystem.GetFileSize(folder)
		end) then
			local success, fullPath = pcall(filesystem.FullPath, folder)
			if success and fullPath then
				return fullPath .. filename
			else
				return folder .. filename
			end
		end
	end

	-- Try to create folders if none exist
	local preferredFolder = possibleFolders[1] -- Use the first one as preferred
	local success, fullPath = pcall(filesystem.CreateDirectory, preferredFolder)
	if success and fullPath then
		return fullPath .. filename
	elseif success then -- CreateDirectory might return true but empty path on failure in some cases?
		return preferredFolder .. filename
	end

	-- Last resort: current directory
	print("[Database] Warning: Could not find or create a suitable directory. Using current directory.")
	return "." .. filename
end

-- Save database to disk using Lua table serialization
function Database.SaveDatabase()
	-- Ensure the database has been initialized at least once
	if not Database.data then
		print("[Database] Cannot save, database not initialized.")
		return false
	end

	-- Skip saving if no entries or not dirty
	if Database.State.entriesCount == 0 then
		if Database.Config.DebugMode then
			print("[Database] No entries to save.")
		end
		return true -- Nothing to do, considered successful
	end

	if not Database.State.isDirty then
		if Database.Config.DebugMode then
			print("[Database] Database is not dirty, skipping save.")
		end
		return true -- Nothing to do, considered successful
	end

	local filePath = Database.GetFilePath()
	local tempPath = filePath .. ".tmp"
	local backupPath = filePath .. ".bak"

	if G and G.UI and G.UI.ShowMessage then
		G.UI.ShowMessage("Saving database...")
	end

	-- Stage 1: Serialize the data table to a Lua string
	local serializedData = nil
	local serializeSuccess, errMsg = pcall(function()
		serializedData = "-- Cheater Detection Database v1\nreturn " .. serializeTableToLuaString(Database.data)
	end)

	if not serializeSuccess or not serializedData then
		print("[Database] Failed to serialize database data: " .. tostring(errMsg or "Unknown error"))
		return false
	end

	-- Stage 2: Write serialized data to temporary file
	local writeSuccess, writeErrMsg = pcall(function()
		local tempFile = io.open(tempPath, "w")
		if not tempFile then
			error("Failed to open temporary file: " .. tempPath)
		end
		tempFile:write(serializedData)
		tempFile:close()
	end)

	serializedData = nil -- Allow GC
	collectgarbage("collect")

	if not writeSuccess then
		print("[Database] Failed to write to temporary file: " .. tostring(writeErrMsg))
		pcall(os.remove, tempPath) -- Attempt cleanup
		return false
	end

	-- Stage 3: Safely replace the original file
	local replaceSuccess = false
	local replaceErrMsg = "Unknown replacement error"

	-- Create backup
	local backupSuccess, backupErr = pcall(function()
		local fileExists = pcall(function()
			return filesystem.GetFileSize(filePath)
		end)
		if fileExists then
			os.rename(filePath, backupPath)
		end
	end)
	if not backupSuccess then
		print("[Database] Warning: Failed to create backup file ('" .. backupPath .. "'): " .. tostring(backupErr))
		-- Continue anyway, but log the warning
	end

	-- Rename temp file to final file path
	local renameSuccess, renameErr = pcall(os.rename, tempPath, filePath)
	if renameSuccess then
		replaceSuccess = true
	else
		replaceErrMsg = tostring(renameErr)
		-- Attempt manual copy if rename fails (less atomic)
		print("[Database] Warning: os.rename failed ('" .. replaceErrMsg .. "'). Attempting manual copy.")
		local manualCopySuccess, manualCopyErr = pcall(function()
			local tempFileRead = io.open(tempPath, "rb")
			if not tempFileRead then
				error("Cannot open temp file for read.")
			end
			local content = tempFileRead:read("*a")
			tempFileRead:close()
			local finalFileWrite = io.open(filePath, "wb")
			if not finalFileWrite then
				error("Cannot open final file for write.")
			end
			finalFileWrite:write(content)
			finalFileWrite:close()
		end)

		if manualCopySuccess then
			replaceSuccess = true
			pcall(os.remove, tempPath) -- Clean up temp file after copy
		else
			replaceErrMsg = "Manual copy failed: " .. tostring(manualCopyErr)
			-- Attempt to restore backup if rename and copy failed
			local restoreBackupSuccess, restoreBackupErr = pcall(os.rename, backupPath, filePath)
			if not restoreBackupSuccess then
				print(
					"[Database] CRITICAL ERROR: Failed to save database and failed to restore backup ('"
						.. tostring(restoreBackupErr)
						.. "'). Data may be lost or corrupted."
				)
			else
				print("[Database] Error saving database, but backup restored.")
			end
		end
	end

	if replaceSuccess then
		-- Update state
		Database.State.isDirty = false
		Database.State.lastSave = os.time()
		if G and G.UI and G.UI.ShowMessage then
			G.UI.ShowMessage("Database saved with " .. Database.State.entriesCount .. " entries!")
		end
		if Database.Config.DebugMode then
			print(string.format("[Database] Saved %d entries to %s", Database.State.entriesCount, filePath))
		end
		-- Optionally remove backup on success?
		-- pcall(os.remove, backupPath)
	else
		print("[Database] FAILED TO SAVE DATABASE. Error: " .. replaceErrMsg)
		-- Ensure state reflects failure
		Database.State.isDirty = true -- Still dirty as save failed
	end

	collectgarbage("collect")
	return replaceSuccess
end

-- Get a player record
function Database.GetRecord(steamId)
	return Database.data[steamId] -- Access data directly
end

-- Get proof for a player
function Database.GetReason(steamId) -- Renamed from GetProof
	local record = Database.data[steamId] -- Access data directly
	return record and record.Reason or "Unknown"
end

-- Get name for a player
function Database.GetName(steamId)
	local record = Database.data[steamId] -- Access data directly
	return record and record.Name or "Unknown"
end

-- Check if player is in database
function Database.Contains(steamId)
	return Database.data[steamId] ~= nil
end

-- Set a player as suspect
function Database.SetSuspect(steamId, data)
	if not steamId then
		return
	end

	-- Create minimal data structure
	local minimalData = {
		Name = (data and data.Name) or "Unknown",
		Reason = (data and (data.Reason or data.proof or data.cause)) or "Unknown", -- Use Reason
	}

	-- Store data using HandleSetEntry to ensure consistency
	Database.HandleSetEntry(steamId, minimalData)

	-- Also set priority in playerlist
	pcall(playerlist.SetPriority, steamId, 10)
end

-- Clear a player from suspect list
function Database.ClearSuspect(steamId)
	if Database.content[steamId] then
		Database.content[steamId] = nil
		playerlist.SetPriority(steamId, 0)
	end
end

-- Get database stats
function Database.GetStats()
	-- Count entries by Reason type
	local reasonStats = {}
	for steamID, entry in pairs(Database.data) do
		local reason = entry.Reason or "Unknown"
		reasonStats[reason] = (reasonStats[reason] or 0) + 1
	end

	return {
		entryCount = Database.State.entriesCount,
		isDirty = Database.State.isDirty,
		lastSave = Database.State.lastSave,
		memoryMB = collectgarbage("count") / 1024,
		proofTypes = reasonStats, -- Keep original name for now if used elsewhere, but contains reasons
		reasonTypes = reasonStats, -- Add new name for clarity
	}
end

-- Clean database by removing least important entries (Simplified Logic)
function Database.Cleanup(maxEntries)
	maxEntries = maxEntries or Database.Config.MaxEntries

	-- If we're under the limit, no need to clean
	if Database.State.entriesCount <= maxEntries then
		return 0
	end

	print(
		string.format("[Database] Cleaning up entries (Current: %d, Max: %d)", Database.State.entriesCount, maxEntries)
	)
	local toRemoveCount = Database.State.entriesCount - maxEntries
	local removedCount = 0

	-- Simple approach: Remove entries arbitrarily until limit is met.
	-- A more sophisticated approach (like keeping specific sources) could be added if needed.
	local keysToRemove = {}
	for steamId in pairs(Database.data) do
		table.insert(keysToRemove, steamId)
		if #keysToRemove >= toRemoveCount then
			break -- Collected enough keys to remove
		end
	end

	-- Remove the selected entries
	for _, steamId in ipairs(keysToRemove) do
		Database.HandleSetEntry(steamId, nil) -- Use HandleSetEntry to correctly decrement count and set dirty flag
		removedCount = removedCount + 1
	end

	-- Save the cleaned database immediately if changes were made
	if removedCount > 0 then -- Check if any were actually removed (HandleSetEntry might skip if already nil)
		print(string.format("[Database] Removed %d entries during cleanup.", removedCount))
		Database.SaveDatabase()
	elseif Database.Config.DebugMode then
		print("[Database] Cleanup ran but no entries needed removal or were already nil.")
	end

	return removedCount
end

-- Register database commands
local function RegisterCommands()
	local Commands = Common.Lib.Utils.Commands

	-- Database stats command
	Commands.Register("cd_db_stats", function()
		local stats = Database.GetStats()
		print(string.format("[Database] Total entries: %d", stats.entryCount))
		print(string.format("[Database] Memory usage: %.2f MB", stats.memoryMB))

		-- Show proof type breakdown
		print("[Database] Proof type breakdown:")
		for proofType, count in pairs(stats.proofTypes) do
			if count > 10 then -- Only show categories with more than 10 entries
				print(string.format("  - %s: %d", proofType, count))
			end
		end
	end, "Show database statistics")

	-- Database cleanup command
	Commands.Register("cd_db_cleanup", function(args)
		local limit = tonumber(args[1]) or Database.Config.MaxEntries
		local beforeCount = Database.State.entriesCount
		local removed = Database.Cleanup(limit)

		print(
			string.format(
				"[Database] Cleaned %d entries (from %d to %d)",
				removed,
				beforeCount,
				Database.State.entriesCount
			)
		)
	end, "Clean the database to stay under entry limit")
end

-- Auto-save on unload
local function OnUnload()
	if Database.State.isDirty then
		Database.SaveDatabase()
	end
end

-- Simplified Initialize function
local function InitializeDatabase()
	print("[Database] Initializing...")

	-- Set initial state
	Database.State = {
		entriesCount = 0,
		isDirty = false,
		lastSave = 0,
	}
	Database.data = Database.data or {} -- Ensure data table exists

	-- Load existing data from file
	local loadSuccess = Database.LoadDatabase()

	if not loadSuccess then
		printc(
			255,
			100,
			100,
			255,
			"[Database] Warning: Failed to load database file properly. Starting potentially empty."
		)
		-- Save an empty file if load failed completely and no backup worked
		if Database.State.entriesCount == 0 then
			Database.State.isDirty = true -- Mark as dirty to force save
			Database.SaveDatabase()
		end
	end

	-- Clean up if over limit after loading
	if Database.State.entriesCount > Database.Config.MaxEntries then
		local removed = Database.Cleanup()
		if removed > 0 and Database.Config.DebugMode then
			print(
				string.format(
					"[Database] Cleaned %d entries after loading to stay under limit (%d).",
					removed,
					Database.Config.MaxEntries
				)
			)
		end
	end

	-- Check for AutoFetch *after* loading
	pcall(function()
		if Database_Fetcher and Database_Fetcher.Config and Database_Fetcher.Config.AutoFetchOnLoad then
			print("[Database] Triggering AutoFetch after initialization.")
			Database_Fetcher.StartFetch(Database, function(added) -- Use StartFetch
				if added > 0 then
					printc(80, 200, 120, 255, "[Database] AutoFetch added " .. added .. " new entries.")
					-- Save is handled by the fetcher itself now
				else
					print("[Database] AutoFetch finished, no new entries added.")
				end
			end, true) -- Run silently
		end
	end)
end

-- Load database from disk using Lua's load function
function Database.LoadDatabase(silent)
	local filePath = Database.GetFilePath()

	-- Check if file exists
	local fileExists = pcall(function()
		return filesystem.GetFileSize(filePath)
	end)
	if not fileExists then
		if not silent then
			print("[Database] Database file not found: " .. filePath .. ". Creating new database.")
		end
		Database.data = {} -- Initialize empty table
		Database.State.entriesCount = 0
		Database.State.isDirty = false -- New database isn't dirty yet
		Database.State.lastSave = 0
		collectgarbage("collect")
		return true -- Successfully "loaded" an empty database
	end

	-- Load the Lua file content
	local loadedData = nil
	local success, result = pcall(function()
		local chunk = loadfile(filePath)
		if chunk then
			return chunk()
		else
			error("Failed to load database chunk from " .. filePath)
		end
	end)

	if not success then
		if not silent then
			print("[Database] Failed to load/parse database file ('" .. filePath .. "'): " .. tostring(result))
			print("[Database] Attempting to load backup: " .. filePath .. ".bak")
		end
		-- Attempt to load backup
		local backupFilePath = filePath .. ".bak"
		local backupExists = pcall(function()
			return filesystem.GetFileSize(backupFilePath)
		end)
		if backupExists then
			local backupSuccess, backupResult = pcall(function()
				local chunk = loadfile(backupFilePath)
				if chunk then
					return chunk()
				else
					error("Failed to load backup chunk.")
				end
			end)
			if backupSuccess and type(backupResult) == "table" then
				if not silent then
					printc(255, 165, 0, 255, "[Database] Successfully loaded from backup file.")
				end
				success = true
				result = backupResult
				-- Optionally try to restore the main file from backup here
				pcall(function()
					local bf = io.open(backupFilePath, "rb")
					if bf then
						local content = bf:read("*a")
						bf:close()
						local mf = io.open(filePath, "wb")
						if mf then
							mf:write(content)
							mf:close()
						end
					end
				end)
			else
				if not silent then
					print("[Database] Failed to load backup file: " .. tostring(backupResult))
				end
			end
		else
			if not silent then
				print("[Database] Backup file not found.")
			end
		end

		-- If both fail, start with empty
		if not success then
			printc(
				255,
				0,
				0,
				255,
				"[Database] CRITICAL: Failed to load main database and backup. Starting with an empty database."
			)
			Database.data = {}
			Database.State.entriesCount = 0
			Database.State.isDirty = true -- Mark dirty as we failed to load
			Database.State.lastSave = 0
			return false -- Indicate load failure
		end
	end

	-- Validate loaded data
	if type(result) ~= "table" then
		if not silent then
			print("[Database] Loaded data is not a table. Starting with an empty database.")
		end
		Database.data = {}
		Database.State.entriesCount = 0
		Database.State.isDirty = true
		Database.State.lastSave = 0
		return false -- Indicate load failure
	end

	-- Successfully loaded data
	Database.data = result

	-- Recalculate entry count and enforce structure
	local count = 0
	local entriesToRemove = {}
	for steamID, value in pairs(Database.data) do
		-- Basic validation
		if type(steamID) ~= "string" or not steamID:match("^765611") or type(value) ~= "table" or not value.Reason then -- Check for Reason field now
			table.insert(entriesToRemove, steamID)
		else
			count = count + 1
			-- Ensure Name exists
			if not value.Name then
				value.Name = "Unknown"
			end
			-- Remove old 'Reason' field if it exists
			if value.Reason then
				value.Reason = nil
			end
		end
	end

	-- Remove invalid entries
	if #entriesToRemove > 0 then
		if not silent then
			print("[Database] Removing " .. #entriesToRemove .. " invalid entries during load.")
		end
		for _, key in ipairs(entriesToRemove) do
			Database.data[key] = nil
		end
		Database.State.isDirty = true -- Mark dirty if we removed entries
	else
		Database.State.isDirty = false -- Loaded cleanly
	end

	Database.State.entriesCount = count
	Database.State.lastSave = os.time() -- Treat load time as last save time

	if not silent then
		printc(
			0,
			255,
			140,
			255,
			"[" .. os.date("%H:%M:%S") .. "] Loaded Database with " .. Database.State.entriesCount .. " entries"
		)
	end

	collectgarbage("collect")
	return true
end

InitializeDatabase() -- Initialize the database when this module is loaded
RegisterCommands() -- Register commands
callbacks.Register("Unload", "CDDatabase_Unload", OnUnload) -- Register unload callback

return Database
