local Common = require("Cheater_Detection.Utils.Common")
local Commands = Common.Lib.Utils.Commands
local Sources = require("Cheater_Detection.Database.Database_Fetcher.Sources")
local Tasks = require("Cheater_Detection.Database.Database_Fetcher.Tasks")
local Parsers = require("Cheater_Detection.Database.Database_Fetcher.Parsers")

local Fetcher = {}
Fetcher.Tasks = Tasks
Fetcher.Sources = Sources.List

-- Fetch from a specific source (non-coroutine version)
function Fetcher.FetchSource(source, database)
	if not source or not source.url or not source.parser or not source.cause then
		print("[Database Fetcher] Invalid source configuration")
		return 0
	end

	print(string.format("[Database Fetcher] Fetching from %s...", source.name))

	-- Ensure compatibility between different database versions
	if database.data and not database.content then
		-- Create the content accessor if it doesn't exist
		if type(database.content) ~= "table" then
			print("[Database Fetcher] Adding accessor to database.data")
			database.content = setmetatable({}, {
				__index = function(_, key)
					return database.data[key]
				end,
				__newindex = function(_, key, value)
					if database.HandleSetEntry then
						database.HandleSetEntry(key, value)
					else
						database.data[key] = value
						if database.State then
							database.State.isDirty = true
						end
					end
				end,
				__pairs = function()
					return pairs(database.data)
				end,
			})
		end
	elseif database.content and not database.data then
		-- If database only has content but no data, ensure data points to content
		database.data = database.content
	end

	-- Regular HTTP request (non-coroutine)
	local content
	local success, result = pcall(http.Get, source.url)

	if success and result and #result > 0 then
		content = result
	else
		print(string.format("[Database Fetcher] Failed to fetch from %s", source.name))
		return 0
	end

	-- Parse the content based on specified parser
	local count = 0

	if source.parser == "raw" then
		count = Parsers.ParseRawIDList(content, database, source.name, source.cause)
	elseif source.parser == "tf2db" then
		count = Parsers.ParseTF2DB(content, database, source.name, source.cause)
	else
		print(string.format("[Database Fetcher] Unknown parser type: %s", source.parser))
		return 0
	end

	-- Explicitly mark the database as dirty if entries were added
	if count > 0 and database.State then
		database.State.isDirty = true
		print(string.format("[Database Fetcher] Marked database as dirty after adding %d entries", count))
	end

	print(string.format("[Database Fetcher] Added %d entries from %s", count, source.name))
	return count
end

-- Fetch all sources with coroutine support
function Fetcher.FetchAll(database, callback)
	-- Initialize
	database = database or {}

	-- Ensure compatibility between different database versions
	if database.data and not database.content then
		-- Create the content accessor if it doesn't exist
		if type(database.content) ~= "table" then
			print("[Database Fetcher] Adding accessor to database.data")
			database.content = setmetatable({}, {
				__index = function(_, key)
					return database.data[key]
				end,
				__newindex = function(_, key, value)
					if database.HandleSetEntry then
						database.HandleSetEntry(key, value)
					else
						database.data[key] = value
						if database.State then
							database.State.isDirty = true
						end
					end
				end,
				__pairs = function()
					return pairs(database.data)
				end,
			})
		end
	elseif database.content and not database.data then
		-- If database only has content but no data, ensure data points to content
		database.data = database.content
	end

	-- Make sure the database interface is consistent
	if not database.updateDatabase and database.HandleSetEntry then
		database.updateDatabase = function(steamID64, details)
			database.HandleSetEntry(steamID64, details)
		end
	end

	-- Set callback to run when all tasks complete
	Tasks.callback = function(totalAddedResult)
		if type(totalAddedResult) == "number" and totalAddedResult > 0 then
			-- Explicitly mark the database as dirty
			if database.State then
				database.State.isDirty = true
			end

			-- Try to save the database explicitly
			if database.SaveDatabase and type(database.SaveDatabase) == "function" then
				print("[Database Fetcher] Saving database after fetch...")
				local saveResult = database.SaveDatabase()
				if not saveResult then
					print("[Database Fetcher] WARNING: Database save failed after fetch")
				end
			end
		end

		-- Call the original callback
		if callback then
			callback(totalAddedResult)
		end
	end

	-- Clear any existing tasks
	Tasks.queue = {}
	Tasks.current = nil
	Tasks.isRunning = true
	Tasks.status = "initializing"
	Tasks.progress = 0
	Tasks.message = "Preparing to fetch sources..."

	local totalAdded = 0

	-- Add a task for each source
	for i, source in ipairs(Fetcher.Sources) do
		Tasks.Add(function()
			local count = Parsers.CoFetchSource(source, database)
			totalAdded = totalAdded + count
			return count
		end, "Fetching " .. source.name, 1)
	end

	-- Final task to save the database
	Tasks.Add(function()
		Tasks.message = "Processing complete! Added " .. totalAdded .. " entries."
		return totalAdded
	end, "Finalizing", 0.5)

	print(string.format("[Database Fetcher] Queued %d sources for fetching", #Fetcher.Sources))

	-- Return immediately, the tasks will run across frames
	return true
end

-- Download a single list (non-coroutine version)
function Fetcher.DownloadList(url, filename)
	if not url or not filename then
		return false
	end

	-- Create import directory
	local basePath = string.format("Lua %s", GetScriptName():match("([^/\\]+)%.lua$"):gsub("%.lua$", ""))
	local importPath = basePath .. "/import/"
	filesystem.CreateDirectory(importPath)

	-- Download content
	print(string.format("[Database Fetcher] Downloading from %s...", url))

	local success, content = pcall(http.Get, url)
	if not success or not content or #content == 0 then
		print("[Database Fetcher] Download failed")
		return false
	end

	-- Save to file
	local filepath = importPath .. filename
	local file = io.open(filepath, "w")
	if not file then
		print("[Database Fetcher] Failed to create file: " .. filepath)
		return false
	end

	file:write(content)
	file:close()

	print(string.format("[Database Fetcher] Successfully downloaded to %s", filepath))
	return true
end

-- Register commands
local function RegisterCommands()
	-- Get the database module
	local function getDatabase()
		return require("Cheater_Detection.Database.Database")
	end

	-- Fetch all sources command
	Commands.Register("cd_fetch_all", function()
		-- Only start if not already running
		if not Tasks.isRunning then
			local Database = getDatabase()

			Fetcher.FetchAll(Database, function(totalAdded)
				if totalAdded > 0 then
					Database.SaveDatabase()
					print("[Database Fetcher] Database saved with " .. totalAdded .. " new entries")
					printc(0, 255, 0, 255, "[Database Fetcher] Update complete: Added " .. totalAdded .. " entries")
				else
					print("[Database Fetcher] No new entries were added")
				end
			end)
		else
			print("[Database Fetcher] A fetch operation is already in progress")
		end
	end, "Fetch all cheater lists and update the database")

	-- Download list command
	Commands.Register("cd_download_list", function(args)
		-- Only start if not already running
		if not Tasks.isRunning then
			if #args < 2 then
				print("Usage: cd_download_list <url> <filename>")
				return
			end

			local url = args[1]
			local filename = args[2]

			-- Add the download task
			Tasks.Add(function()
				return Parsers.CoDownloadList(url, filename)
			end, "Downloading " .. filename, 1)

			Tasks.callback = function(result)
				if result then
					printc(0, 255, 0, 255, "[Database Fetcher] Download complete: " .. filename)
				else
					printc(255, 0, 0, 255, "[Database Fetcher] Download failed: " .. filename)
				end
			end

			print("[Database Fetcher] Starting download from " .. url)
		else
			print("[Database Fetcher] A task is already in progress")
		end
	end, "Download a list from URL and save to import folder")

	-- List all available sources command
	Commands.Register("cd_list_sources", function()
		print("[Database Fetcher] Available sources:")
		for i, source in ipairs(Fetcher.Sources) do
			print(string.format("%d. %s (%s)", i, source.name, source.cause))
		end
	end, "List all available database sources")

	-- Fetch a specific source command
	Commands.Register("cd_fetch_source", function(args)
		if #args < 1 then
			print("Usage: cd_fetch_source <source_index>")
			return
		end

		local sourceIndex = tonumber(args[1])
		if not sourceIndex or sourceIndex < 1 or sourceIndex > #Fetcher.Sources then
			print("Invalid source index. Use cd_list_sources to see available sources.")
			return
		end

		local source = Fetcher.Sources[sourceIndex]
		local Database = getDatabase()

		print(string.format("[Database Fetcher] Fetching from %s...", source.name))
		local added = Fetcher.FetchSource(source, Database)

		if added > 0 then
			Database.SaveDatabase()
			print(string.format("[Database Fetcher] Added %d entries from %s", added, source.name))
		else
			print(string.format("[Database Fetcher] No new entries added from %s", source.name))
		end
	end, "Fetch from a specific database source")
end

-- IMPORTANT: We do NOT register the Draw callback here
-- The main Database_Fetcher.lua file manages the drawing
-- This prevents duplicate progress bars from being drawn

-- Register commands when the script is loaded
RegisterCommands()

return Fetcher
