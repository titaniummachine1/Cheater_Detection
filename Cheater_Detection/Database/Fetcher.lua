---@diagnostic disable: undefined-global, undefined-field
--[[ Cheater Detection - Database Fetcher - Coroutine Async Version ]]
local Common = require("Cheater_Detection.Utils.Common")
-- [[ Imported by: Main.lua ]]
local G = require("Cheater_Detection.Utils.Globals")
-- [[ Imported by: None ]]
local Json = Common.Json
-- [[ Imported by: Fetcher.lua (indirectly via Common) ]]
local Database = require("Cheater_Detection.Database.Database") -- For SaveDatabase
-- [[ Imported by: Fetcher.lua ]]
local Sources = require("Cheater_Detection.Database.Sources") -- Require Sources
-- [[ Imported by: Fetcher.lua ]]
local Parsers = require("Cheater_Detection.Database.Parsers") -- Require Parsers
-- [[ Imported by: Fetcher.lua ]]

local Fetcher = {}

-- Define LogLevel locally within Fetcher
local LogLevel = {
	ERROR = 1,
	WARNING = 2,
	SUCCESS = 3,
	INFO = 4,
	DEBUG = 5,
}

-- Local Log function for Fetcher module (Defined early)
local function Log(level, message, color)
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true

	-- Determine if the message should be shown
	local shouldShow = false
	if isDebugMode then
		shouldShow = true -- Show all levels in debug mode
	elseif level <= LogLevel.SUCCESS then
		shouldShow = true -- Show ERROR, WARNING, SUCCESS in non-debug mode
	end

	if not shouldShow then
		return
	end

	local prefix = ""
	local defaultColor = { 255, 255, 255, 255 }

	if level == LogLevel.ERROR then
		prefix = "[FETCHER ERROR] "
		color = color or { 255, 100, 100, 255 } -- Red
	elseif level == LogLevel.WARNING then
		prefix = "[FETCHER WARNING] "
		color = color or { 255, 255, 100, 255 } -- Yellow
	elseif level == LogLevel.SUCCESS then
		prefix = "[FETCHER SUCCESS] "
		color = color or { 0, 255, 140, 255 } -- Bright Green
	elseif level == LogLevel.INFO then
		if not isDebugMode then
			return
		end
		prefix = "[FETCHER INFO] "
		color = color or { 100, 255, 255, 255 } -- Cyan
	elseif level == LogLevel.DEBUG then
		if not isDebugMode then
			return
		end
		prefix = "[FETCHER DEBUG] "
		color = color or { 180, 180, 180, 255 } -- Grey
	end

	color = color or defaultColor
	printc(color[1], color[2], color[3], color[4], prefix .. message)
end

-- Simplified State tracking
Fetcher.State = {
	isRunning = false,
	startTime = 0,
	results = {
		total_added = 0,
		total_updated = 0, -- Keep track of updates
		errors = 0,
	},
    coro = nil
}

-- Helper to bypass GitHub's strict TLS/User-Agent blocks for game clients
-- THIS is fixing the "Len: 0" error that ruined the previous fetch.
local function proxyGitHubUrl(url)
    if url:match("^https://raw%.githubusercontent%.com/") then
        return url:gsub("https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.*)", "https://cdn.jsdelivr.net/gh/%1/%2@%3/%4")
    end
    return url
end

local function isDatabaseEmpty()
	if type(G) ~= "table" or type(G.DataBase) ~= "table" then
		return true
	end
	return next(G.DataBase) == nil
end

local function isFetchStale()
	local menu = G and G.Menu and G.Menu.Main
	if not menu then
		return true
	end
	local lastFetch = tonumber(menu.LastFetchTimestamp) or 0
	return (os.time() - lastFetch) >= 3600
end

-- Helper function to check if all required modules are properly loaded
local function checkRequirements()
	Log(LogLevel.DEBUG, "[FETCHER] Checking requirements...") -- Use Log
	if type(G) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Globals module not loaded properly") -- Use Log
		return false
	end
	if type(G.DataBase) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: G.DataBase is not initialized") -- Use Log
		return false
	end
	if type(Database) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Database module not loaded properly") -- Use Log
		return false
	end
	if type(Database.SaveDatabase) ~= "function" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Database.SaveDatabase function missing") -- Use Log
		return false
	end
	if type(Sources) ~= "table" or type(Sources.GetActiveSources) ~= "function" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Sources module not loaded properly") -- Use Log
		return false
	end
	if type(Parsers) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Parsers module not loaded properly") -- Use Log
		return false
	end
	Log(LogLevel.DEBUG, "[FETCHER] All requirements satisfied") -- Use Log
	return true
end

local function fetchSource(source)
	Log(LogLevel.INFO, string.format("[FETCHER] Fetching source: %s (%s)", source.name, source.url))

	local fetch_success, response_or_error = pcall(http.Get, source.url)
	if not fetch_success then
		Log(
			LogLevel.WARNING,
			string.format("[FETCHER] Failed to fetch data from %s: %s", source.name, tostring(response_or_error))
		)
		return nil, "fetch_failed"
	end

	if type(response_or_error) ~= "string" or response_or_error == "" then
		Log(LogLevel.WARNING, string.format("[FETCHER] Empty or invalid content from %s", source.name))
		return nil, "empty_response"
	end

    -- Detect HTML error pages (404, etc.)
    if response_or_error:match("<html") or response_or_error:match("<HTML") or response_or_error:match("<!DOCTYPE") then
        local detail = "HTML/Error Page detected"
        if response_or_error:match("404") then detail = "404 Not Found"
        elseif response_or_error:match("429") then detail = "429 Rate Limited"
        elseif response_or_error:match("503") then detail = "503 Service Unavailable" end
        Log(LogLevel.WARNING, string.format("[FETCHER] HTTP Error from %s: %s", source.name, detail))
        return nil, detail
    end

	Log(
		LogLevel.DEBUG,
		string.format("[FETCHER] Download successful from %s. Size: %d bytes", source.name, #response_or_error)
	)

	return response_or_error, nil
end

local function parseSource(source, response_content)
	Log(LogLevel.INFO, string.format("[FETCHER] Parsing source: %s", source.name))
	local sourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
	local added = 0
	local updated = 0
	local isDirtyBefore = Database.State.isDirty

	-- Parsing logic
	if source.parser == "raw" then
		local entries, errorMsg = Parsers.ParseRawIDs(response_content, source.cause)
		if entries then
			local processedCount, existingCount, addedCount, updatedCount = 0, 0, 0, 0
			for steamID64, entryData in pairs(entries) do
				processedCount = processedCount + 1
				if not G.DataBase[steamID64] then
					G.DataBase[steamID64] = entryData
					addedCount = addedCount + 1
				else
					existingCount = existingCount + 1
					local existingEntry = G.DataBase[steamID64]
					if
						(existingEntry.Name == "Unknown" or existingEntry.Name == nil)
						and entryData.Name
						and entryData.Name ~= "Unknown"
					then
						existingEntry.Name = entryData.Name
						updatedCount = updatedCount + 1
						Database.State.isDirty = true
					end
					if
						(existingEntry.Reason == "Unknown Source" or existingEntry.Reason == nil)
						and entryData.Reason
						and entryData.Reason ~= "Unknown Source"
					then
						existingEntry.Reason = entryData.Reason
						updatedCount = updatedCount + 1
						Database.State.isDirty = true
					end

                    -- Mark as static if this is an external source
                    if source.cause and (source.cause:find("Local Import") or source.url) then
                        existingEntry.Static = true
                    end
				end
                
                -- Mark new or updated entries as static if external
                if source.cause and (source.cause:find("Local Import") or source.url) then
                    if G.DataBase[steamID64] then
                        G.DataBase[steamID64].Static = true
                    end
                end

                -- Yield parsing to prevent frametime spikes
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
			Log(
				LogLevel.WARNING,
				string.format("[FETCHER] Error parsing %s: %s", source.name, errorMsg or "Unknown error")
			) 
			sourceStats.errors = sourceStats.errors + 1
		end
	elseif source.parser == "tf2db" then
        -- Use ParseTF2BotDetector for all TF2DB sources
        local isStatic = source.cause and (source.cause:find("Local Import") or source.url)
        local _, errorMsg, stats = Parsers.ParseTF2BotDetector(response_content, source.cause, G.DataBase, sourceStats, isStatic)
        if stats then
            added, updated = stats.added, stats.updated
            sourceStats = stats
        else
            Log(
                LogLevel.WARNING,
                string.format("[FETCHER] Error parsing %s: %s", source.name, errorMsg or "Unknown error")
            ) 
            sourceStats.errors = sourceStats.errors + 1
        end
	else
		Log( 
			LogLevel.ERROR,
			string.format("[FETCHER] Error: Unknown parser type '%s' for source %s", source.parser, source.name)
		)
		return 0, 0, 1 -- added, updated, errors
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

	if updated > 0 then
		Log(LogLevel.DEBUG, string.format("[FETCHER] %s: Added %d, Updated %d", source.name, added, updated)) 
	elseif added > 0 then
		Log(LogLevel.DEBUG, string.format("[FETCHER] %s: Added %d", source.name, added)) 
	else
		Log(LogLevel.DEBUG, string.format("[FETCHER] %s: No changes", source.name)) 
	end

	return added, updated, sourceStats.errors
end

-- Public Module Functions
function Fetcher.Start()
	Log(LogLevel.INFO, "[FETCHER] Starting ASYNC database fetch process")

	if Fetcher.State.isRunning then
		Log(LogLevel.WARNING, "[FETCHER] Fetch process already running, ignoring request")
		return
	end

	if not checkRequirements() then
		Log(LogLevel.ERROR, "[FETCHER] Requirements check failed, aborting fetch")
		return
	end

	Parsers.ResetStats()

	Fetcher.State.isRunning = true
	Fetcher.State.startTime = globals.RealTime()
	Fetcher.State.results.total_added = 0
	Fetcher.State.results.total_updated = 0
	Fetcher.State.results.errors = 0

	local active_sources = Sources.GetActiveSources()
	Log(LogLevel.INFO, string.format("[FETCHER] Found %d active sources", #active_sources))

	if #active_sources == 0 then
		Log(LogLevel.INFO, "[FETCHER] No active sources found, finishing immediately.")
		Fetcher.FinishFetch()
		return
	end

    -- Run the entire fetch and parse sequence inside a coroutine
    Fetcher.State.coro = coroutine.create(function()
        -- STEP 0: Process Local Imports ASYNC first
        Log(LogLevel.INFO, "[FETCHER] Processing local imports...")
        Fetcher.ImportLocal(true) 
        coroutine.yield()

        for i, source in ipairs(active_sources) do
            Log(LogLevel.DEBUG, string.format("[FETCHER] Processing source %d/%d: %s", i, #active_sources, source.name))
            
            -- Step 1: Fetch
            local response_content, err = fetchSource(source)
            if response_content then
                -- Step 2: Parse
                local added, updated, errors = parseSource(source, response_content)
                Fetcher.State.results.total_added = Fetcher.State.results.total_added + added
                Fetcher.State.results.total_updated = Fetcher.State.results.total_updated + updated
                Fetcher.State.results.errors = Fetcher.State.results.errors + errors
            else
                Fetcher.State.results.errors = Fetcher.State.results.errors + 1
                Parsers.AddSourceStats(source.name, 0, 0, 0, 1, 0)
            end
            
            -- Wait a moment between sources
            local waitEndTime = globals.RealTime() + 1.2
            while globals.RealTime() < waitEndTime do
                coroutine.yield()
            end
        end

        -- Fetch completed
        Fetcher.FinishFetch()
    end)
end

-- Core Tick function (call from scheduler)
function Fetcher.Tick()
    local coro = Fetcher.State.coro
    if not coro or type(coro) ~= "thread" then return end

    local status, err = coroutine.resume(coro)
    if not status then
        Log(LogLevel.ERROR, "[FETCHER] Coroutine error: " .. tostring(err))
        printc(255, 50, 50, 255, "[FETCHER ERROR] " .. tostring(err))
        Fetcher.State.isRunning = false
        Fetcher.State.coro = nil
    end

    if coroutine.status(coro) == "dead" then
        Fetcher.State.coro = nil
        Fetcher.State.isRunning = false
    end
end

function Fetcher.ImportLocal(isAsync)
    Log(LogLevel.INFO, "[FETCHER] Scanning for local imports in 'Lua Cheater_Detection/imports'...")
    
    -- Rule II.3: Mandatory Validation of engine objects
    assert(filesystem, "Fetcher.ImportLocal: filesystem engine object missing")
    
    local importPath = "Lua Cheater_Detection/imports"
    
    -- Use a helper to safely check for members on engine userdata
    local function SafeHas(obj, key)
        local ok, val = pcall(function() return obj[key] end)
        return ok and val ~= nil
    end

    -- Attempt to list files using multiple possible APIs to avoid crashes
    local files = nil
    
    -- Option 1: filesystem.List (Common in lnxlib)
    if not files and SafeHas(filesystem, "List") then
        local success, result = pcall(filesystem.List, importPath)
        if success then files = result end
    end
    
    -- Option 2: filesystem.Enumerate (Standard engine Enumerate)
    if not files and SafeHas(filesystem, "Enumerate") then
        local success, result = pcall(filesystem.Enumerate, importPath)
        if success then files = result end
    end

    -- If no files found or API incompatible, just early out (not a hard fail for the script)
    if not files or #files == 0 then 
        Log(LogLevel.DEBUG, "[FETCHER] No local import files found or directory missing.")
        return 
    end

    local totalAdded, totalUpdated = 0, 0
    for i = 1, #files do
        local fileName = files[i]
        assert(type(fileName) == "string", "Fetcher.ImportLocal: fileName is not a string")

        -- Only process JSON files
        if fileName:match("%.json$") then
            local fullPath = importPath .. "/" .. fileName
            
            -- Re-validate filesystem before Read
            assert(SafeHas(filesystem, "Read"), "Fetcher.ImportLocal: filesystem.Read missing")
            local readSuccess, content = pcall(filesystem.Read, fullPath)
            
            if readSuccess and content and content ~= "" then
                Log(LogLevel.INFO, "[FETCHER] Importing local file: " .. fileName)
                
                -- Reuse the tf2db parser logic via parseSource
                local sourceObj = {
                    name = fileName,
                    parser = "tf2db",
                    cause = "Local Import (" .. fileName .. ")"
                }
                
                -- parseSource handles the actual insertion and G.DataBase updates
                local added, updated, errors = parseSource(sourceObj, content)
                totalAdded = totalAdded + added
                totalUpdated = totalUpdated + updated

                -- Throttling for Async mode
                if isAsync then
                    local waitEndTime = globals.RealTime() + 1.2
                    while globals.RealTime() < waitEndTime do
                        coroutine.yield()
                    end
                end
            else
                Log(LogLevel.WARNING, "[FETCHER] Failed to read or empty local file: " .. fileName)
            end
        end
    end
    
    if totalAdded > 0 or totalUpdated > 0 then
        Log(LogLevel.SUCCESS, string.format("[FETCHER] Local import completed. Added: %d, Updated: %d", totalAdded, totalUpdated))
        -- Database.SaveDatabase() -- NO LONGER SAVING STATIC DATA!
    else
        Log(LogLevel.INFO, "[FETCHER] Local import finished with no changes.")
    end
end

function Fetcher.FinishFetch()
	local elapsedTime = globals.RealTime() - Fetcher.State.startTime

	-- Only show detailed debug output in debug mode (via Parsers.PrintStatsSummary)
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	if isDebugMode then
		Log(LogLevel.INFO, string.format("ASYNC Fetch completed in %.2f seconds. Total Added: %d, Total Updated: %d, Errors: %d",
			elapsedTime, Fetcher.State.results.total_added, Fetcher.State.results.total_updated, Fetcher.State.results.errors))
		Parsers.PrintStatsSummary()
	else
		printc(0, 255, 140, 255, string.format("Database entries processed: %d", Parsers.ParseStats.totalProcessed))
		printc(0, 255, 140, 255, string.format("Database entries added: %d", Parsers.ParseStats.totalAdded))

		if Parsers.ParseStats.totalErrors > 0 then
			printc(255, 100, 100, 255, string.format("Database errors: %d", Parsers.ParseStats.totalErrors))
		end

		local dbCount = 0
		if type(G.DataBase) == "table" then
			for _ in pairs(G.DataBase) do
				dbCount = dbCount + 1
			end
		end
		printc(0, 255, 140, 255, string.format("Total database entries: %d", dbCount))
	end

	if Database.State.isDirty then
		Log(LogLevel.INFO, "Changes detected, saving database")
		Database.SaveDatabase()
	else
		Log(LogLevel.INFO, "No changes detected, skipping database save")
	end

	local mainMenu = G and G.Menu and G.Menu.Main
	if mainMenu then
		mainMenu.LastFetchTimestamp = os.time()
	end

	Fetcher.State.isRunning = false
    Fetcher.State.coro = nil
	Log(LogLevel.DEBUG, "Fetch process finished")
end

function Fetcher.GetStatus()
	return {
		running = Fetcher.State.isRunning,
	}
end

Log(LogLevel.DEBUG, "[FETCHER] >>> Module execution finished. Returning Fetcher table.")
return Fetcher
