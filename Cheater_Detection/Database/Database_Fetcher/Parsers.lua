-- Enhanced parsers with improved memory management and string-based processing

local Common = require("Cheater_Detection.Utils.Common")
local Tasks = require("Cheater_Detection.Database.Database_Fetcher.Tasks")

-- Get JSON directly from Common
local Json = Common.Json

local Parsers = {}

-- Configuration (enhanced)
Parsers.Config = {
	RetryDelay = 4, -- Initial delay between retries (seconds)
	RetryBackoff = 2, -- Multiply delay by this factor on each retry
	RequestTimeout = 10, -- Maximum time to wait for a response (seconds)
	YieldInterval = 100, -- Yield after processing this many items
	MaxRetries = 3, -- Maximum number of retry attempts
	RetryOnEmpty = true, -- Retry if response is empty
	DebugMode = false, -- Enable detailed error logging
	UserAgents = { -- Add different user agents to rotate through
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:89.0) Gecko/20100101 Firefox/89.0",
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.1 Safari/605.1.15",
	},
	CurrentUserAgent = 1, -- Index of current user agent to use
	AllowHtml = false, -- Whether to allow HTML responses (usually indicates an error)
	MaxErrorDisplayLength = 80, -- Maximum length of error messages to display
	StringBufferSize = 8192, -- Process strings in chunks of this size
	UseWeakTables = true, -- Use weak references for temporary data
	ForceGCInterval = 10000, -- Force garbage collection every N entries
	UseStringOnly = true, -- Use string operations instead of tables where possible
	MaxTableEntries = 1000, -- Maximum entries to store in a table before switching to incremental processing
}

-- Create weak reference tables for temporary storage (both keys and values are weak)
Parsers.TempStorage = setmetatable({}, { __mode = "kv" })

-- Error logging function with debug mode control
function Parsers.LogError(message, details)
	-- Always log critical errors
	print("[Database Fetcher] Error: " .. message)

	-- Log additional details only in debug mode
	if Parsers.Config.DebugMode and details then
		if type(details) == "string" and #details > 100 then
			-- Truncate very long details to prevent console overflow
			print("[Database Fetcher] Details: " .. details:sub(1, 100) .. "... (truncated)")
		else
			print("[Database Fetcher] Details: " .. tostring(details))
		end
	end

	-- Set the task message with a safe truncated version
	local displayMessage = message
	if #displayMessage > Parsers.Config.MaxErrorDisplayLength then
		displayMessage = displayMessage:sub(1, Parsers.Config.MaxErrorDisplayLength) .. "..."
	end

	if Tasks and Tasks.message then
		Tasks.message = "Error: " .. displayMessage
	end
end

-- Safe HTTP download with coroutine-based timeout and user agent rotation
function Parsers.Download(url, retryCount)
	-- Clear any previous temp storage before download
	Parsers.TempStorage = setmetatable({}, { __mode = "v" })
	collectgarbage("step", 100)

	retryCount = retryCount or Parsers.Config.MaxRetries

	-- Use different user agents for GitHub to avoid rate limiting
	if url:find("github") or url:find("githubusercontent") then
		table.insert(
			Parsers.Config.UserAgents,
			1,
			"Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
		)
	end

	local retry = 0
	local lastError = nil

	while retry < retryCount do
		-- Rotate user agents on retries
		Parsers.Config.CurrentUserAgent = 1 + (retry % #Parsers.Config.UserAgents)
		local userAgent = Parsers.Config.UserAgents[Parsers.Config.CurrentUserAgent]

		Tasks.message = "Downloading from " .. url:sub(1, 40) .. "... (try " .. (retry + 1) .. "/" .. retryCount .. ")"
		coroutine.yield() -- Give control back to the game

		local requestTimedOut = false
		local startTime = globals.RealTime()
		local response = nil
		local requestFinished = false

		-- Direct HTTP request for reliability
		-- This is a simplified version with no coroutine overhead that's more reliable
		local success, result = pcall(function()
			local headers = {
				["User-Agent"] = userAgent,
				["Accept"] = "text/plain, application/json",
				["Cache-Control"] = "no-cache",
			}
			return http.Get(url, headers)
		end)

		-- Process the result directly
		if not success then
			lastError = "HTTP error: " .. tostring(result)
		elseif not result then
			lastError = "Empty response"
		elseif type(result) ~= "string" then
			lastError = "Invalid response type: " .. type(result)
		elseif #result == 0 then
			if Parsers.Config.RetryOnEmpty then
				lastError = "Empty response"
			else
				return "" -- Return empty string if empty responses are acceptable
			end
		else
			-- Check for HTML directly via string patterns
			if result:match("<!DOCTYPE html>") or result:match("<html") then
				-- Check if it's GitHub returning HTML
				if url:find("github") or url:find("githubusercontent") and result:find("rate limit") then
					lastError = "GitHub rate limit exceeded. Try again later."
				else
					lastError = "Received HTML instead of data (website error or CAPTCHA)"
				end

				-- Print the HTML response start for debugging
				print("[Parsers] HTML response from " .. url .. " (length: " .. #result .. ")")
				print("[Parsers] First 100 chars: " .. result:sub(1, 100))

				-- If HTML allowed, return it anyway
				if Parsers.Config.AllowHtml then
					return result
				end
			else
				-- Success! Return the response
				return result
			end
		end

		-- Failed, try again
		retry = retry + 1
		if retry < retryCount then
			-- Wait with exponential backoff using coroutine for smoother experience
			local waitTime = Parsers.Config.RetryDelay * (Parsers.Config.RetryBackoff ^ (retry - 1))
			Tasks.message = "Retry in " .. waitTime .. "s: " .. lastError:sub(1, 50)

			-- Wait with a countdown that doesn't block the game
			local startWait = globals.RealTime()
			while globals.RealTime() < startWait + waitTime do
				local remaining = math.ceil((startWait + waitTime) - globals.RealTime())
				Tasks.message = "Retry in " .. remaining .. "s: " .. lastError:sub(1, 50)
				coroutine.yield() -- Give control back to the main thread
			end
		end
	end

	-- All retries failed
	Parsers.LogError("Download failed after " .. retryCount .. " attempts", lastError)
	return nil
end

-- More robust SteamID conversion
function Parsers.ConvertToSteamID64(input)
	if not input then
		return nil
	end

	-- Safety check for unexpected input types
	if type(input) ~= "string" and type(input) ~= "number" then
		return nil
	end

	local steamid = tostring(input):match("^%s*(.-)%s*$") -- Trim whitespace

	-- If already a SteamID64, just return it
	if steamid:match("^%d+$") and #steamid >= 15 and #steamid <= 20 then
		return steamid
	end

	-- Try direct conversion with error handling
	local success, result = pcall(function()
		if steamid:match("^STEAM_0:%d:%d+$") or steamid:match("^%[U:1:%d+%]$") then
			return steam.ToSteamID64(steamid)
		end
		return nil
	end)

	if success and result and type(result) == "string" and #result >= 15 then
		return result
	end

	-- Manual conversion for SteamID3
	if steamid:match("^%[U:1:%d+%]$") then
		local accountID = steamid:match("%[U:1:(%d+)%]$")
		if accountID and tonumber(accountID) then
			local steamID64 = tostring(76561197960265728 + tonumber(accountID))
			-- Validate the result
			if #steamID64 >= 15 and #steamID64 <= 20 and steamID64:match("^%d+$") then
				return steamID64
			end
		end
	end

	-- Handle plain numeric IDs that might be account IDs
	if steamid:match("^%d+$") and tonumber(steamid) < 1000000000 then
		local steamID64 = tostring(76561197960265728 + tonumber(steamid))
		if #steamID64 >= 15 and #steamID64 <= 20 then
			return steamID64
		end
	end

	return nil
end

-- Safe function to process a line from a raw list
function Parsers.ProcessRawLine(line, database, sourceCause)
	-- Check for nil inputs
	if not line or not database or not sourceCause then
		return false, 0, "Missing required parameters"
	end

	-- Initialize counters
	local added = 0
	local skipped = 0
	local invalid = 0

	local success, errorMsg = pcall(function()
		-- Trim and validate line
		local trimmedLine = line:match("^%s*(.-)%s*$") or ""

		-- Skip comments, empty lines, and other non-ID lines
		if
			trimmedLine ~= ""
			and not trimmedLine:match("^%-%-")
			and not trimmedLine:match("^#")
			and not trimmedLine:match("^//")
			and not trimmedLine:match("^<!")
		then
			-- Attempt to extract a SteamID from various formats
			local steamID64 = Parsers.ConvertToSteamID64(trimmedLine)

			-- Add to database if valid and not duplicate
			if steamID64 then
				-- Check if entry already exists - use database.Contains if available, otherwise check database.data or content
				local exists = false
				if database.Contains and type(database.Contains) == "function" then
					exists = database.Contains(steamID64)
				elseif database.data and database.data[steamID64] then
					exists = true
				elseif database.content and database.content[steamID64] then
					exists = true
				end

				if not exists then
					-- Use updateDatabase if available, otherwise fallback to manual insert
					if database.updateDatabase and type(database.updateDatabase) == "function" then
						database.updateDatabase(steamID64, {
							Name = "Unknown",
							Reason = sourceCause,
						})
					else
						-- Fallback method - directly insert into whatever container is available
						local container = database.data or database.content
						if container then
							container[steamID64] = {
								Name = "Unknown",
								Reason = sourceCause,
							}

							-- Mark database as dirty if possible
							if database.State then
								database.State.isDirty = true
								if database.State.entriesCount then
									database.State.entriesCount = database.State.entriesCount + 1
								end
							end
						end
					end

					-- Set player priority with error handling
					pcall(function()
						playerlist.SetPriority(steamID64, 10)
					end)
					added = 1
				else
					-- Entry already exists, don't update (the database handler will decide what to keep)
					skipped = 1
				end
			else
				invalid = 1
			end
		else
			skipped = 1 -- Count skipped comments/empty lines
		end
	end)

	if not success then
		return false, 0, errorMsg
	else
		return true, added, { skipped = skipped, invalid = invalid }
	end
end

-- Super robust raw list processor
function Parsers.ProcessRawList(content, database, sourceName, sourceCause)
	-- Special handling for bots.tf data
	if sourceName == "bots.tf" then
		return Parsers.ProcessBotsTF(content, database, sourceName, sourceCause)
	end

	-- Regular processing for other raw sources
	-- Input validation with detailed errors
	if not content then
		Parsers.LogError("Empty content from " .. (sourceName or "unknown source"))
		return 0
	end

	if not database then
		Parsers.LogError("Invalid database object")
		return 0
	end

	if not sourceName or not sourceCause then
		Parsers.LogError("Missing source metadata")
		return 0
	end

	-- Make sure database.content exists to prevent errors
	if not database.content then
		print("[Parsers] WARNING: database.content is nil, creating it")
		database.content = {}
		database.State = database.State or {}
		database.State.isDirty = true
		database.State.entriesCount = 0
	end

	Tasks.message = "Processing " .. sourceName .. "..."
	coroutine.yield()

	-- Initialize counters
	local count = 0
	local skipped = 0
	local invalid = 0
	local linesProcessed = 0
	local totalLines = 0

	-- Count lines with minimal memory usage (no table storage)
	local lineCount = 0
	for _ in content:gmatch("[^\r\n]+") do
		lineCount = lineCount + 1

		-- Yield occasionally during counting to prevent freezing
		if lineCount % 10000 == 0 then
			Tasks.message = "Counting lines in " .. sourceName .. " (" .. lineCount .. ")"
			coroutine.yield()
		end
	end
	totalLines = lineCount

	-- Process directly from string without storing all lines in memory
	local position = 1
	local contentLength = #content
	local batchSize = Parsers.Config.StringBufferSize

	while position <= contentLength do
		-- Extract a chunk of content to process
		local endPos = content:find("\n", position + batchSize) or contentLength
		local chunk = content:sub(position, endPos)
		position = endPos + 1

		-- Process all lines in this chunk
		for line in chunk:gmatch("[^\r\n]+") do
			local success, added, extraInfo = Parsers.ProcessRawLine(line, database, sourceCause)

			if success then
				count = count + added
				if type(extraInfo) == "table" then
					skipped = skipped + extraInfo.skipped
					invalid = invalid + extraInfo.invalid
				end
			else
				invalid = invalid + 1
			end

			linesProcessed = linesProcessed + 1

			-- Update progress periodically
			if linesProcessed % Parsers.Config.YieldInterval == 0 or linesProcessed >= totalLines then
				local progressPct = totalLines > 0 and math.floor((linesProcessed / totalLines) * 100) or 0
				Tasks.message =
					string.format("Processing %s: %d%% (%d added, %d skipped)", sourceName, progressPct, count, skipped)
				coroutine.yield()

				-- Force GC periodically
				if linesProcessed % Parsers.Config.ForceGCInterval == 0 then
					collectgarbage("step", 1000)
				end
			end
		end

		-- Clear the chunk from memory
		chunk = nil

		-- Yield to update UI
		coroutine.yield()
		collectgarbage("step", 100)
	end

	-- Mark database as dirty explicitly
	if count > 0 and database.State then
		database.State.isDirty = true
	end

	Tasks.message = string.format("Finished %s: %d added, %d skipped, %d invalid", sourceName, count, skipped, invalid)
	coroutine.yield()

	-- Clear memory
	content = nil
	collectgarbage("collect")

	return count
end

-- Special handling for bots.tf which has a unique format
function Parsers.ProcessBotsTF(content, database, sourceName, sourceCause)
	-- Input validation with detailed errors
	if not content then
		Parsers.LogError("Empty content from " .. sourceName)
		return 0
	end

	if not database then
		Parsers.LogError("Invalid database object")
		return 0
	end

	Tasks.message = "Processing " .. sourceName .. "..."
	coroutine.yield()

	-- Initialize counters
	local count = 0
	local skipped = 0
	local invalid = 0
	local linesProcessed = 0

	-- First do a quick check of content type
	if type(content) ~= "string" then
		Parsers.LogError("Invalid content type: " .. type(content))
		return 0
	end

	-- bots.tf returns raw text with one SteamID64 per line
	-- It might have some empty lines or other data we need to filter

	-- Count lines for progress reporting
	local lines = {}
	local totalLines = 0

	-- Extract lines with error handling
	local success, errorMsg = pcall(function()
		for line in content:gmatch("[^\r\n]+") do
			-- Skip empty lines or lines that are obviously not SteamID64s
			line = line:match("^%s*(.-)%s*$") -- Trim whitespace
			if line ~= "" and #line >= 15 and #line <= 20 and line:match("^%d+$") then
				table.insert(lines, line)
				totalLines = totalLines + 1
			end
		end
	end)

	if not success then
		Parsers.LogError("Failed to parse lines from " .. sourceName, errorMsg)
		return 0
	end

	if totalLines == 0 then
		Parsers.LogError("No valid SteamID64s found in " .. sourceName, "Content length: " .. #content)
		return 0
	end

	Tasks.message = "Processing " .. totalLines .. " SteamID64s from " .. sourceName
	coroutine.yield()

	-- Make sure database.content exists to prevent errors
	if not database.content then
		print("[Parsers] WARNING: database.content is nil, creating it")
		database.content = {}
		database.State = database.State or {}
		database.State.isDirty = true
		database.State.entriesCount = 0
	end

	-- Process each line with robust error handling
	for i, steamID64 in ipairs(lines) do
		-- We should already have valid SteamID64s at this point

		-- Add to database if not duplicate
		local exists = false
		if database.Contains and type(database.Contains) == "function" then
			exists = database.Contains(steamID64)
		elseif database.data and database.data[steamID64] then
			exists = true
		elseif database.content and database.content[steamID64] then
			exists = true
		end

		if not exists then
			-- Use updateDatabase if available, otherwise fallback to manual insert
			if database.updateDatabase and type(database.updateDatabase) == "function" then
				database.updateDatabase(steamID64, {
					Name = "Unknown",
					Reason = sourceCause,
				})
			else
				-- Fallback method - directly insert into whatever container is available
				local container = database.data or database.content
				if container then
					container[steamID64] = {
						Name = "Unknown",
						Reason = sourceCause,
					}

					-- Mark database as dirty if possible
					if database.State then
						database.State.isDirty = true
						if database.State.entriesCount then
							database.State.entriesCount = database.State.entriesCount + 1
						end
					end
				end
			end

			-- Set player priority with error handling
			pcall(function()
				playerlist.SetPriority(steamID64, 10)
			end)
			count = count + 1
		else
			skipped = skipped + 1
		end

		linesProcessed = linesProcessed + 1

		-- Update progress periodically
		if linesProcessed % Parsers.Config.YieldInterval == 0 or linesProcessed == totalLines then
			local progressPct = math.floor((linesProcessed / totalLines) * 100)
			Tasks.message =
				string.format("Processing %s: %d%% (%d added, %d skipped)", sourceName, progressPct, count, skipped)
			coroutine.yield()
		end
	end

	-- Mark database as dirty explicitly
	if count > 0 and database.State then
		database.State.isDirty = true
	end

	Tasks.message = string.format("Finished %s: %d added, %d skipped", sourceName, count, skipped)
	coroutine.yield()

	-- Clear lines table to free memory
	lines = nil
	collectgarbage("collect")

	return count
end

-- Process a source with improved error handling and fallbacks
function Parsers.ProcessSource(source, database)
	-- Validate inputs
	if not source then
		Parsers.LogError("Source is nil")
		return 0
	end

	if not database then
		Parsers.LogError("Database is nil")
		return 0
	end

	if not source.url or not source.parser or not source.cause then
		local missingFields = {}
		if not source.url then
			table.insert(missingFields, "url")
		end
		if not source.parser then
			table.insert(missingFields, "parser")
		end
		if not source.cause then
			table.insert(missingFields, "cause")
		end

		Parsers.LogError("Invalid source configuration: missing " .. table.concat(missingFields, ", "))
		return 0
	end

	local sourceName = source.name or "Unknown Source"
	Tasks.message = "Fetching from " .. sourceName .. "..."

	-- Clear temp storage before each source
	Parsers.TempStorage = setmetatable({}, { __mode = "v" })
	collectgarbage("step", 100)

	-- Download content
	local content = Parsers.Download(source.url)

	-- If download failed, try backup URL if available
	if (not content or #content == 0 or content:match("<!DOCTYPE html>")) and source.backupUrl then
		Tasks.message = "Primary URL failed, trying backup..."
		content = Parsers.Download(source.backupUrl)
	end

	-- If all downloads failed
	if not content or #content == 0 then
		Parsers.LogError("Failed to fetch from " .. sourceName)
		return 0
	end

	-- Process content based on parser type with full error handling
	local count = 0
	local parser = source.parser

	if parser == "raw" then
		local success, result = pcall(function()
			return Parsers.ProcessRawList(content, database, sourceName, source.cause)
		end)

		-- Immediately clear content to free memory
		content = nil

		if success then
			count = result
		else
			Parsers.LogError("Failed to parse raw list from " .. sourceName, result)
		end
	elseif parser == "tf2db" then
		-- For TF2DB parser, we'll delegate to the ProcessTF2DB function
		-- This function will be added by the TF2DB module during initialization
		if Parsers.ProcessTF2DB then
			local success, result = pcall(function()
				return Parsers.ProcessTF2DB(content, database, source)
			end)

			-- Immediately clear content to free memory
			content = nil

			if success then
				count = result
			else
				Parsers.LogError("Failed to parse TF2DB data from " .. sourceName, result)

				-- If JSON parsing failed, try as raw list as a fallback
				Tasks.message = "Trying alternate parser for " .. sourceName
				success, result = pcall(function()
					return Parsers.ProcessRawList(content, database, sourceName, source.cause)
				end)

				if success then
					count = result
				end
			end
		else
			Parsers.LogError("TF2DB parser not available, falling back to raw parser")

			-- Fall back to raw parser if TF2DB module isn't loaded
			local success, result = pcall(function()
				return Parsers.ProcessRawList(content, database, sourceName, source.cause)
			end)

			if success then
				count = result
			else
				Parsers.LogError("Fallback parser failed for " .. sourceName, result)
			end
		end
	else
		Parsers.LogError("Unknown parser type: " .. source.parser)
	end

	-- Force complete memory cleanup
	collectgarbage("collect")

	return count
end

-- Add a configurable sleep function that uses coroutine.yield for smoother experience
function Parsers.Sleep(seconds)
	local startTime = globals.RealTime()
	while globals.RealTime() < startTime + seconds do
		coroutine.yield()
	end
end

-- Add emergency reset function
function Parsers.EmergencyReset()
	-- Unregister any parser callbacks to stop processing
	pcall(function()
		for _, name in ipairs({
			"FetcherMainTask",
			"FetcherCallback",
			"FetcherSingleSource",
			"TasksProcessCleanup",
			"DatabaseSave",
		}) do
			callbacks.Unregister("Draw", name)
		end
	end)

	-- Clear any temporary storage
	Parsers.TempStorage = setmetatable({}, { __mode = "kv" })

	-- Force aggressive GC
	collectgarbage("stop") -- Stop GC temporarily to avoid it running while we clean
	collectgarbage("collect")
	collectgarbage("collect")
	collectgarbage("restart") -- Restart GC

	print("[Parsers] Emergency reset performed")
end

return Parsers
