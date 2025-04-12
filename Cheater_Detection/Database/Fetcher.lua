--[[ Cheater Detection - Database Fetcher - Coroutine Version ]]
print("[FETCHER SOURCE] >>> Module Start") -- ++DEBUG

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Json = Common.Json
print("[FETCHER SOURCE] Attempting to require Database module...") -- ++DEBUG
local Database = require("Cheater_Detection.Database.Database") -- For SaveDatabase
print("[FETCHER SOURCE] Database module require result: Type =", type(Database)) -- ++DEBUG
local Sources = require("Cheater_Detection.Database.Sources") -- Require Sources
local Parsers = require("Cheater_Detection.Database.Parsers") -- Require Parsers

local Fetcher = {}

-- State tracking
Fetcher.State = {
	isRunning = false,
	startTime = 0,
	totalSources = 0,
	completedSources = 0,
	activeCoroutines = {},
	sourcesStatus = {},
	results = {
		total_added = 0,
		errors = 0,
	},
}

-- Helper function to check if all required modules are properly loaded
local function checkRequirements()
	print("[FETCHER SOURCE] Checking requirements...")

	-- Check G.DataBase
	if type(G) ~= "table" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Globals module not loaded properly")
		return false
	end

	if type(G.DataBase) ~= "table" then
		print("[FETCHER SOURCE] CRITICAL ERROR: G.DataBase is not initialized")
		return false
	end

	-- Check Database module
	if type(Database) ~= "table" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Database module not loaded properly")
		return false
	end

	if type(Database.SaveDatabase) ~= "function" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Database.SaveDatabase function missing")
		return false
	end

	-- Check Sources module
	if type(Sources) ~= "table" or type(Sources.GetActiveSources) ~= "function" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Sources module not loaded properly")
		return false
	end

	-- Check Parsers module
	if type(Parsers) ~= "table" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Parsers module not loaded properly")
		return false
	end

	print("[FETCHER SOURCE] All requirements satisfied")
	return true
end

-- Helper function to convert SteamID3 or SteamID to SteamID64 if needed
local function GetSteamID64(id_str)
	if not id_str then
		return nil
	end
	id_str = id_str:match("^%s*(.-)%s*$") -- Trim

	-- Direct SteamID64 match
	if id_str:match("^7656119%d%d%d%d%d%d%d%d%d%d$") then
		return id_str -- Already SteamID64
	elseif id_str:match("^STEAM_0:[01]:%d+$") or id_str:match("^%[U:1:%d+%]$") then
		local success, result = pcall(steam.ToSteamID64, id_str)
		return success and result or nil
	else
		-- Check if it's already a valid numeric SteamID64
		local numeric_id = tonumber(id_str)
		if
			numeric_id
			and tostring(numeric_id) == id_str
			and numeric_id > 76500000000000000
			and numeric_id < 77000000000000000
		then
			return id_str
		end
		return nil -- Unrecognized format
	end
end

-- Coroutine-based HTTP fetch with timeout detection
local function fetchUrl(url)
	local co = coroutine.create(function()
		local success, content_or_error = pcall(http.Get, url)
		coroutine.yield(success, content_or_error)
	end)

	-- Add to active coroutines list with timestamp
	Fetcher.State.activeCoroutines[co] = {
		startTime = globals.RealTime(),
		url = url,
		status = "running",
	}

	-- Resume the coroutine
	local resume_success, yield_success, yield_content_or_error = coroutine.resume(co)

	-- Update the coroutine status
	if Fetcher.State.activeCoroutines[co] then
		Fetcher.State.activeCoroutines[co].status = "completed"
		Fetcher.State.activeCoroutines[co] = nil -- Remove from active list
	end

	-- Return the result
	if not resume_success then
		return false, "Coroutine resume error: " .. tostring(yield_success)
	end

	return yield_success, yield_content_or_error
end

-- Process a single source and add its entries to the database
local function processSource(source)
	print(string.format("[FETCHER SOURCE] Processing source: %s (%s)", source.name, source.url))

	-- Update source status
	Fetcher.State.sourcesStatus[source.name] = {
		status = "fetching",
		url = source.url,
		startTime = globals.RealTime(),
	}

	-- Fetch the URL
	local fetch_success, response_content_or_error = fetchUrl(source.url)

	-- Update source status
	Fetcher.State.sourcesStatus[source.name].status = fetch_success and "parsing" or "fetch_failed"

	if not fetch_success then
		print(
			string.format(
				"[FETCHER SOURCE] Failed to fetch data from %s: %s",
				source.name,
				tostring(response_content_or_error)
			)
		)
		Fetcher.State.results.errors = Fetcher.State.results.errors + 1
		return 0
	end

	local response_content = response_content_or_error
	if type(response_content) ~= "string" or response_content == "" then
		print(string.format("[FETCHER SOURCE] Empty or invalid content from %s", source.name))
		Fetcher.State.sourcesStatus[source.name].status = "invalid_content"
		Fetcher.State.results.errors = Fetcher.State.results.errors + 1
		return 0
	end

	print(string.format("[FETCHER SOURCE] Download successful from %s. Size: %d bytes", source.name, #response_content))

	-- Determine which parser to use
	local parse_function = nil
	if source.parser == "raw" then
		parse_function = Parsers.ParseRawIDs
	elseif source.parser == "tf2db" then
		parse_function = Parsers.ParseJsonTF2DB
	else
		print(
			string.format("[FETCHER SOURCE] Error: Unknown parser type '%s' for source %s", source.parser, source.name)
		)
		Fetcher.State.sourcesStatus[source.name].status = "unknown_parser"
		Fetcher.State.results.errors = Fetcher.State.results.errors + 1
		return 0
	end

	-- Parse the content
	local parse_success, entries = pcall(parse_function, response_content, source.cause)
	response_content = nil -- Allow GC

	if not parse_success then
		print(string.format("[FETCHER SOURCE] Failed to parse content from %s: %s", source.name, tostring(entries)))
		Fetcher.State.sourcesStatus[source.name].status = "parse_failed"
		Fetcher.State.results.errors = Fetcher.State.results.errors + 1
		return 0
	end

	-- Process the entries
	local added_count = 0
	if type(entries) == "table" then
		local current_source_added = 0

		for steamId64_from_parser, record in pairs(entries) do
			local steamId64 = GetSteamID64(tostring(steamId64_from_parser))
			if steamId64 then
				-- Only add if the SteamID is NOT already in the local database
				if not G.DataBase[steamId64] then
					G.DataBase[steamId64] = {
						Name = record.Name or "Unknown",
						Reason = record.Reason or record.cause or "Unknown",
					}
					current_source_added = current_source_added + 1
					Database.State.isDirty = true -- Mark dirty only when adding a new entry
					-- Removed the 'else' block that handled updating existing entries
				end
			end
		end

		added_count = current_source_added
		-- Removed redundant Database.State.isDirty assignment here
	else
		print(string.format("[FETCHER SOURCE] Warning: Parser for %s returned invalid data type", source.name))
	end

	-- Update source status
	Fetcher.State.sourcesStatus[source.name].status = "completed"
	Fetcher.State.sourcesStatus[source.name].entriesAdded = added_count
	Fetcher.State.completedSources = Fetcher.State.completedSources + 1

	print(string.format("[FETCHER SOURCE] Added %d new entries from %s", added_count, source.name))
	return added_count
end

-- Monitor function that gets called each frame to check on fetch progress
local function monitorFetchProgress()
	if not Fetcher.State.isRunning then
		callbacks.Unregister("Draw", "fetcher_monitor_callback")
		return
	end

	-- Check if we've been running too long (over 60 seconds)
	local currentTime = globals.RealTime()
	local elapsedTime = currentTime - Fetcher.State.startTime

	if elapsedTime > 60 then
		print("[FETCHER SOURCE] WARNING: Fetch operation running for over 60 seconds, may be stalled")
	end

	-- Check for any stalled coroutines (running for over 10 seconds)
	for co, info in pairs(Fetcher.State.activeCoroutines) do
		local coRunTime = currentTime - info.startTime
		if coRunTime > 10 and info.status == "running" then
			print(
				string.format(
					"[FETCHER SOURCE] WARNING: Coroutine for URL %s may be stalled (running for %.1f seconds)",
					info.url,
					coRunTime
				)
			)
			-- Could add forced termination of stuck coroutines here if needed
		end
	end

	-- Check if all sources are processed
	if Fetcher.State.completedSources >= Fetcher.State.totalSources then
		Fetcher.FinishFetch()
	end
end

-- Start the fetch process
function Fetcher.Start()
	print("[FETCHER SOURCE] Starting database fetch process")

	-- Check if already running
	if Fetcher.State.isRunning then
		print("[FETCHER SOURCE] Fetch process already running, ignoring request")
		return
	end

	-- Check requirements first
	if not checkRequirements() then
		print("[FETCHER SOURCE] Requirements check failed, aborting fetch")
		return
	end

	-- Initialize state
	Fetcher.State.isRunning = true
	Fetcher.State.startTime = globals.RealTime()
	Fetcher.State.completedSources = 0
	Fetcher.State.activeCoroutines = {}
	Fetcher.State.sourcesStatus = {}
	Fetcher.State.results.total_added = 0
	Fetcher.State.results.errors = 0

	-- Get active sources
	local active_sources = Sources.GetActiveSources()
	Fetcher.State.totalSources = #active_sources

	print(string.format("[FETCHER SOURCE] Found %d active sources", #active_sources))

	-- Set up progress monitoring
	callbacks.Register("Draw", "fetcher_monitor_callback", monitorFetchProgress)

	-- Process each source
	for _, source in ipairs(active_sources) do
		local added = processSource(source)
		Fetcher.State.results.total_added = Fetcher.State.results.total_added + added
	end

	-- The monitorFetchProgress function will call FinishFetch when all sources are processed
end

-- Complete the fetch process and save the database
function Fetcher.FinishFetch()
	if not Fetcher.State.isRunning then
		return
	end

	print(
		string.format(
			"[FETCHER SOURCE] Fetch process completed. Added %d entries with %d errors",
			Fetcher.State.results.total_added,
			Fetcher.State.results.errors
		)
	)

	-- Save database if needed
	if Database.State.isDirty then
		print("[FETCHER SOURCE] Saving database as changes were detected")
		Database.SaveDatabase()
	else
		print("[FETCHER SOURCE] No changes detected, skipping database save")
	end

	-- Clean up
	Fetcher.State.isRunning = false
	collectgarbage("collect")

	-- Unregister the monitor callback
	callbacks.Unregister("Draw", "fetcher_monitor_callback")

	print("[FETCHER SOURCE] Fetch process finished")
end

-- Get current fetch status
function Fetcher.GetStatus()
	local status = {
		running = Fetcher.State.isRunning,
		elapsed = Fetcher.State.isRunning and (globals.RealTime() - Fetcher.State.startTime) or 0,
		totalSources = Fetcher.State.totalSources,
		completedSources = Fetcher.State.completedSources,
		activeCoroutines = #Fetcher.State.activeCoroutines,
		totalAdded = Fetcher.State.results.total_added,
		errors = Fetcher.State.results.errors,
	}

	return status
end

print("[FETCHER SOURCE] >>> Module execution finished. Returning Fetcher table.") -- ++DEBUG
return Fetcher
