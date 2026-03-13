---@diagnostic disable: undefined-global
--[[ Cheater Detection - Database Fetcher - Coroutine Async Version ]]
local Common = require("Cheater_Detection.Utils.Common")
-- [[ Imported by: Main.lua ]]
local G = require("Cheater_Detection.Utils.Globals")
-- [[ Imported by: None ]]
local Json = Common.Json
-- [[ Imported by: Fetcher.lua (indirectly via Common) ]]
local Database = require("Cheater_Detection.Database.Database")
-- [[ Imported by: Fetcher.lua ]]
local Sources = require("Cheater_Detection.Database.Sources")
-- [[ Imported by: Fetcher.lua ]]
local Parsers = require("Cheater_Detection.Database.Parsers")
-- [[ Imported by: Fetcher.lua ]]
local HttpQueue = require("Cheater_Detection.services.http_queue")
-- [[ Imported by: Fetcher.lua ]]

local Fetcher = {}

--[[ Constants ]]
-- Only re-fetch online sources if data is older than this many seconds (1 hour)
local FETCH_STALE_SECONDS = 3600
-- Minimum delay in seconds that must pass between sources to respect server rate limits.
-- The HttpQueue already enforces 1.2s between requests; this is an extra courtesy wait.
local INTER_SOURCE_DELAY = 0.0 -- set to 0: HttpQueue rate limiting is sufficient

--[[ Log Level Enum ]]
local LogLevel = {
	ERROR = 1,
	WARNING = 2,
	SUCCESS = 3,
	INFO = 4,
	DEBUG = 5,
}

--[[ Local Log helper ]]
local function Log(level, message, color)
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true

	local shouldShow = false
	if isDebugMode then
		shouldShow = true
	elseif level <= LogLevel.SUCCESS then
		shouldShow = true
	end

	if not shouldShow then return end

	local prefix = ""
	local defaultColor = { 255, 255, 255, 255 }

	if level == LogLevel.ERROR then
		prefix = "[CD FETCHER ERROR] "
		color = color or { 255, 100, 100, 255 }
	elseif level == LogLevel.WARNING then
		prefix = "[CD FETCHER WARNING] "
		color = color or { 255, 255, 100, 255 }
	elseif level == LogLevel.SUCCESS then
		prefix = "[CD FETCHER] "
		color = color or { 0, 255, 140, 255 }
	elseif level == LogLevel.INFO then
		if not isDebugMode then return end
		prefix = "[CD FETCHER INFO] "
		color = color or { 100, 255, 255, 255 }
	elseif level == LogLevel.DEBUG then
		if not isDebugMode then return end
		prefix = "[CD FETCHER DEBUG] "
		color = color or { 180, 180, 180, 255 }
	end

	color = color or defaultColor
	printc(color[1], color[2], color[3], color[4], prefix .. message)
end

--[[ State ]]
Fetcher.State = {
	isRunning = false,
	startTime = 0,
	results = {
		total_added = 0,
		total_updated = 0,
		errors = 0,
	},
	coro = nil,
}

--[[ Helpers ]]

local function checkRequirements()
	Log(LogLevel.DEBUG, "Checking requirements...")
	if type(G) ~= "table" then
		Log(LogLevel.ERROR, "CRITICAL: Globals module not loaded")
		return false
	end
	if type(G.DataBase) ~= "table" then
		Log(LogLevel.ERROR, "CRITICAL: G.DataBase not initialized")
		return false
	end
	if type(Database) ~= "table" then
		Log(LogLevel.ERROR, "CRITICAL: Database module not loaded")
		return false
	end
	if type(Database.SaveDatabase) ~= "function" then
		Log(LogLevel.ERROR, "CRITICAL: Database.SaveDatabase missing")
		return false
	end
	if type(Sources) ~= "table" or type(Sources.GetActiveSources) ~= "function" then
		Log(LogLevel.ERROR, "CRITICAL: Sources module not loaded")
		return false
	end
	if type(Parsers) ~= "table" then
		Log(LogLevel.ERROR, "CRITICAL: Parsers module not loaded")
		return false
	end
	Log(LogLevel.DEBUG, "All requirements satisfied")
	return true
end

local function isFetchStale()
	local menu = G and G.Menu and G.Menu.Main
	if not menu then return true end
	local lastFetch = tonumber(menu.LastFetchTimestamp) or 0
	return (os.time() - lastFetch) >= FETCH_STALE_SECONDS
end

-- Fetches one source via HttpQueue, yielding the coroutine while waiting for the response.
-- Returns: responseContent (string or nil), errorMessage (string or nil)
local function fetchSource(source)
	Log(LogLevel.INFO, string.format("Fetching source: %s", source.name))

	local responseContent = nil
	local isDone = false

	-- HttpQueue.Enqueue is non-blocking. The callback fires when the HTTP response arrives.
	-- HttpQueue.Tick() is called every draw frame by Scheduler.Tick() (before Fetcher.Tick()),
	-- so the response will arrive within a frame or two after the request completes.
	HttpQueue.Enqueue(source.url, function(data)
		responseContent = data
		isDone = true
	end)

	-- Yield until the response callback fires. The scheduler drives this.
	while not isDone do
		coroutine.yield()
	end

	if not responseContent or responseContent == "" then
		Log(LogLevel.WARNING, string.format("No response from: %s", source.name))
		return nil, "empty_response"
	end

	-- Detect HTML error pages (404, rate limits, etc.)
	local lc = responseContent:sub(1, 200):lower()
	if lc:match("<html") or lc:match("<!doctype") then
		local detail = "HTML/Error Page"
		if lc:match("404") then detail = "404 Not Found"
		elseif lc:match("429") then detail = "429 Rate Limited"
		elseif lc:match("503") then detail = "503 Unavailable"
		end
		Log(LogLevel.WARNING, string.format("HTTP Error from %s: %s", source.name, detail))
		return nil, detail
	end

	Log(LogLevel.DEBUG, string.format("Downloaded %s: %d bytes", source.name, #responseContent))
	return responseContent, nil
end

-- Parses downloaded content into G.DataBase.
-- Returns: added (int), updated (int), errors (int)
local function parseSource(source, responseContent)
	Log(LogLevel.INFO, string.format("Parsing source: %s", source.name))
	local sourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
	local added = 0
	local updated = 0
	local isDirtyBefore = Database.State.isDirty

	if source.parser == "raw" then
		local entries, errorMsg = Parsers.ParseRawIDs(responseContent, source.cause)
		if entries then
			local processedCount = 0
			local addedCount = 0
			local updatedCount = 0
			local existingCount = 0
			for steamID64, entryData in pairs(entries) do
				processedCount = processedCount + 1
				if not G.DataBase[steamID64] then
					G.DataBase[steamID64] = entryData
					addedCount = addedCount + 1
				else
					existingCount = existingCount + 1
					local existingEntry = G.DataBase[steamID64]
					if (existingEntry.Name == "Unknown" or existingEntry.Name == nil)
						and entryData.Name and entryData.Name ~= "Unknown"
					then
						existingEntry.Name = entryData.Name
						updatedCount = updatedCount + 1
						Database.State.isDirty = true
					end
					if (existingEntry.Reason == "Unknown Source" or existingEntry.Reason == nil)
						and entryData.Reason and entryData.Reason ~= "Unknown Source"
					then
						existingEntry.Reason = entryData.Reason
						updatedCount = updatedCount + 1
						Database.State.isDirty = true
					end
				end
				-- Yield every 500 entries to prevent frame time spikes
				if processedCount % 500 == 0 then
					coroutine.yield()
				end
			end
			added = addedCount
			updated = updatedCount
			sourceStats.processed = processedCount
			sourceStats.added = addedCount
			sourceStats.existing = existingCount
			sourceStats.updated = updatedCount
		else
			Log(LogLevel.WARNING, string.format("Parse error %s: %s", source.name, errorMsg or "Unknown"))
			sourceStats.errors = sourceStats.errors + 1
		end
	elseif source.parser == "tf2db" then
		local _, errorMsg, stats = Parsers.ParseTF2BotDetector(responseContent, source.cause, G.DataBase, sourceStats)
		if stats then
			added = stats.added
			updated = stats.updated
			sourceStats = stats
		else
			Log(LogLevel.WARNING, string.format("Parse error %s: %s", source.name, errorMsg or "Unknown"))
			sourceStats.errors = sourceStats.errors + 1
		end
	else
		Log(LogLevel.ERROR, string.format("Unknown parser '%s' for source %s", source.parser, source.name))
		return 0, 0, 1
	end

	Parsers.AddSourceStats(
		source.name,
		sourceStats.processed,
		sourceStats.added,
		sourceStats.existing,
		sourceStats.errors,
		sourceStats.updated
	)

	if (added > 0 or updated > 0) and not isDirtyBefore then
		Database.State.isDirty = true
	end

	if added > 0 or updated > 0 then
		Log(LogLevel.DEBUG, string.format("%s: +%d added, ~%d updated", source.name, added, updated))
	else
		Log(LogLevel.DEBUG, string.format("%s: No changes", source.name))
	end

	return added, updated, sourceStats.errors
end

-- Scans the local imports directory and merges any .json/.txt files into the database.
local function importLocalFiles()
	Log(LogLevel.INFO, "Scanning local imports folder...")
	pcall(filesystem.CreateDirectory, "Lua Cheater_Detection")
	pcall(filesystem.CreateDirectory, "Lua Cheater_Detection/imports")

	local files = {}
	pcall(filesystem.EnumerateDirectory, "Lua Cheater_Detection/imports/*", function(filename, _attributes)
		if filename:match("%.json$") or filename:match("%.txt$") then
			table.insert(files, filename)
		end
	end)

	if #files == 0 then
		Log(LogLevel.DEBUG, "No local import files found")
		return
	end

	local totalImported = 0
	for _, filename in ipairs(files) do
		local path = "Lua Cheater_Detection/imports/" .. filename
		Log(LogLevel.DEBUG, "Local import: " .. filename)

		local file = io.open(path, "r")
		if file then
			local content = file:read("*a")
			file:close()
			if content and content ~= "" then
				local parserType = filename:match("%.json$") and "tf2db" or "raw"
				local added = parseSource(
					{ name = filename, parser = parserType, cause = "Local Import" },
					content
				)
				totalImported = totalImported + (added or 0)
			end
		end
		coroutine.yield() -- Yield after each file
	end

	if totalImported > 0 then
		Log(LogLevel.SUCCESS, string.format("Imported %d new entries from local files", totalImported))
	end
end

--[[ Public Module Functions ]]

-- Starts the async database fetch process.
-- Creates a coroutine that is driven by Fetcher.Tick() every draw frame.
-- Step 1: Local file imports
-- Step 2: Online source fetches (rate-limited via HttpQueue)
-- Step 3: Save database if anything changed
function Fetcher.Start()
	if Fetcher.State.isRunning then
		Log(LogLevel.DEBUG, "Already running — ignoring duplicate Start() call")
		return
	end

	if not checkRequirements() then
		Log(LogLevel.ERROR, "Requirements check failed — aborting fetch")
		return
	end

	if not isFetchStale() then
		Log(LogLevel.INFO, "Database is fresh (fetched < 1 hour ago) — skipping online update")
		return
	end

	Parsers.ResetStats()

	Fetcher.State.isRunning = true
	Fetcher.State.startTime = globals.RealTime()
	Fetcher.State.results.total_added = 0
	Fetcher.State.results.total_updated = 0
	Fetcher.State.results.errors = 0

	local activeSources = Sources.GetActiveSources()
	Log(LogLevel.INFO, string.format("Starting ASYNC database fetch: %d online sources", #activeSources))

	Fetcher.State.coro = coroutine.create(function()
		-- Step 1: Local imports (synchronous but yields during heavy loops)
		importLocalFiles()

		-- Step 2: Online sources (each fetch yields until HttpQueue delivers the response)
		for i, source in ipairs(activeSources) do
			Log(LogLevel.INFO, string.format("Source %d/%d: %s", i, #activeSources, source.name))

			local responseContent, _err = fetchSource(source)
			if responseContent then
				local added, updated, errors = parseSource(source, responseContent)
				Fetcher.State.results.total_added = Fetcher.State.results.total_added + (added or 0)
				Fetcher.State.results.total_updated = Fetcher.State.results.total_updated + (updated or 0)
				Fetcher.State.results.errors = Fetcher.State.results.errors + (errors or 0)
			else
				Fetcher.State.results.errors = Fetcher.State.results.errors + 1
				Parsers.AddSourceStats(source.name, 0, 0, 0, 1, 0)
			end

			-- Yield between sources. ParseTF2BotDetector already yields before
			-- its Json.decode, but this extra yield ensures the game gets a
			-- full frame after the entire parse+iteration completes before we
			-- start fetching the next source.
			coroutine.yield()
		end

		-- Step 3: Finish
		Fetcher.FinishFetch()
	end)
end

-- Called every draw frame by Scheduler.Tick().
-- Drives the fetch coroutine one step at a time.
function Fetcher.Tick()
	local coro = Fetcher.State.coro
	if not coro or type(coro) ~= "thread" then return end
	if coroutine.status(coro) == "dead" then
		Fetcher.State.coro = nil
		Fetcher.State.isRunning = false
		return
	end

	local ok, err = coroutine.resume(coro)
	if not ok then
		printc(255, 50, 50, 255, "[CD FETCHER ERROR] Coroutine crashed: " .. tostring(err))
		Fetcher.State.isRunning = false
		Fetcher.State.coro = nil
	end
end

-- Called at the end of the coroutine after all sources are processed.
function Fetcher.FinishFetch()
	local elapsed = globals.RealTime() - Fetcher.State.startTime

	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	if isDebugMode then
		Log(LogLevel.INFO, string.format(
			"Fetch complete in %.1fs — Added: %d, Updated: %d, Errors: %d",
			elapsed,
			Fetcher.State.results.total_added,
			Fetcher.State.results.total_updated,
			Fetcher.State.results.errors
		))
		Parsers.PrintStatsSummary()
	else
		printc(0, 255, 140, 255, string.format(
			"[CD] Database update complete: +%d new, ~%d updated (%d total entries)",
			Parsers.ParseStats.totalAdded,
			Parsers.ParseStats.totalUpdated or 0,
			(function()
				local count = 0
				if type(G.DataBase) == "table" then
					for _ in pairs(G.DataBase) do count = count + 1 end
				end
				return count
			end)()
		))
		if Parsers.ParseStats.totalErrors > 0 then
			printc(255, 150, 0, 255, string.format("[CD] %d source errors during fetch", Parsers.ParseStats.totalErrors))
		end
	end

	-- Save if anything changed. This is a runtime (non-unload) save so there is no size cap.
	if Database.State.isDirty then
		Log(LogLevel.INFO, "Changes detected — saving database")
		Database.SaveDatabase(false)
	else
		Log(LogLevel.INFO, "No changes detected — skipping save")
	end

	-- Record fetch timestamp so we don't re-fetch for another hour
	local mainMenu = G and G.Menu and G.Menu.Main
	if mainMenu then
		mainMenu.LastFetchTimestamp = os.time()
	end

	Fetcher.State.isRunning = false
	Fetcher.State.coro = nil
	Log(LogLevel.DEBUG, "Fetch coroutine finished")
end

function Fetcher.GetStatus()
	return {
		running = Fetcher.State.isRunning,
	}
end

Log(LogLevel.DEBUG, ">>> Module execution finished. Returning Fetcher table.")
return Fetcher
