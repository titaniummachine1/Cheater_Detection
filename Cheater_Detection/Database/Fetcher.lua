--[[ Cheater Detection - Database Fetcher - Synchronous Simplified Version ]]
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
}

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

-- Process a single source and add its entries to the database

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

	-- Parsing logic (remains the same)
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
			) -- Use Log
			sourceStats.errors = sourceStats.errors + 1
		end
	elseif source.parser == "tf2db" then
		if source.url:find("tf2_bot_detector") and source.url:find("playerlist%.official%.json") then
			local _, errorMsg, stats = Parsers.ParseTF2BotDetector(response_content, source.cause, G.DataBase)
			if stats then
				added, updated = stats.added, stats.updated
				sourceStats = stats
			else
				Log(
					LogLevel.WARNING,
					string.format("[FETCHER] Error parsing %s: %s", source.name, errorMsg or "Unknown error")
				) -- Use Log
				sourceStats.errors = sourceStats.errors + 1
			end
		else
			local data, errorMsg = Parsers.ParseJsonTF2DB(response_content)
			if data and data.players then
				local processedCount, existingCount, addedCount, updatedCount = 0, 0, 0, 0
				for _, player in ipairs(data.players) do
					processedCount = processedCount + 1
					local steamID64 = player.steamid and Parsers.GetSteamID64(player.steamid) or nil
					if steamID64 then
						local playerName = (player.last_seen and player.last_seen.player_name) or "Unknown"
						local reason = source.cause or "Unknown Source"
						if player.attributes and #player.attributes > 0 then
							reason = player.attributes[1]:gsub("^%l", string.upper)
						end
						if not G.DataBase[steamID64] then
							G.DataBase[steamID64] = { Name = playerName, Reason = reason }
							addedCount = addedCount + 1
						else
							existingCount = existingCount + 1
							local existingEntry = G.DataBase[steamID64]
							if
								(existingEntry.Name == "Unknown" or existingEntry.Name == nil)
								and playerName
								and playerName ~= "Unknown"
							then
								existingEntry.Name = playerName
								updatedCount = updatedCount + 1
								Database.State.isDirty = true
							end
							if reason and reason ~= "Unknown Source" then
								local existingReason = existingEntry.Reason
								if not existingReason or existingReason == "Unknown Source" then
									existingEntry.Reason = reason
									updatedCount = updatedCount + 1
									Database.State.isDirty = true
								elseif existingReason ~= reason and not existingReason:find(reason, 1, true) then
									existingEntry.Reason = existingReason .. " | " .. reason
									updatedCount = updatedCount + 1
									Database.State.isDirty = true
								end
							end
						end
					else
						sourceStats.errors = sourceStats.errors + 1
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
				) -- Use Log
				sourceStats.errors = sourceStats.errors + 1
			end
		end
	else
		Log( -- Use Log
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
		Log(LogLevel.DEBUG, string.format("[FETCHER] %s: Added %d, Updated %d", source.name, added, updated)) -- Debug level
	elseif added > 0 then
		Log(LogLevel.DEBUG, string.format("[FETCHER] %s: Added %d", source.name, added)) -- Debug level
	else
		Log(LogLevel.DEBUG, string.format("[FETCHER] %s: No changes", source.name)) -- Debug level
	end

	return added, updated, sourceStats.errors
end

-- Public Module Functions
function Fetcher.Start()
	Log(LogLevel.INFO, "[FETCHER] Starting SYNC database fetch process") -- Use Log

	if Fetcher.State.isRunning then
		Log(LogLevel.WARNING, "[FETCHER] Fetch process already running, ignoring request") -- Use Log
		return
	end

	if not checkRequirements() then
		Log(LogLevel.ERROR, "[FETCHER] Requirements check failed, aborting fetch") -- Use Log
		return
	end

	Parsers.ResetStats()

	Fetcher.State.isRunning = true
	Fetcher.State.startTime = globals.RealTime()
	Fetcher.State.results.total_added = 0
	Fetcher.State.results.total_updated = 0
	Fetcher.State.results.errors = 0

	local active_sources = Sources.GetActiveSources()
	Log(LogLevel.INFO, string.format("[FETCHER] Found %d active sources", #active_sources)) -- Use Log

	if #active_sources == 0 then
		Log(LogLevel.INFO, "[FETCHER] No active sources found, finishing immediately.") -- Use Log
		Fetcher.FinishFetch()
		return
	end

	local fetchedResponses = {}

	for i, source in ipairs(active_sources) do
		Log(
			LogLevel.DEBUG,
			string.format("[FETCHER] [Pass 1] Fetching source %d/%d: %s", i, #active_sources, source.name)
		)
		local response_content = nil
		response_content = select(1, fetchSource(source))
		if response_content then
			table.insert(fetchedResponses, { source = source, response = response_content })
		else
			Fetcher.State.results.errors = Fetcher.State.results.errors + 1
			Parsers.AddSourceStats(source.name, 0, 0, 0, 1, 0)
		end
	end

	for index, payload in ipairs(fetchedResponses) do
		Log(
			LogLevel.DEBUG,
			string.format("[FETCHER] [Pass 2] Parsing source %d/%d: %s", index, #fetchedResponses, payload.source.name)
		)
		local added, updated, errors = parseSource(payload.source, payload.response)
		Fetcher.State.results.total_added = Fetcher.State.results.total_added + added
		Fetcher.State.results.total_updated = Fetcher.State.results.total_updated + updated
		Fetcher.State.results.errors = Fetcher.State.results.errors + errors
	end

	-- Fetch completed, call FinishFetch directly
	Fetcher.FinishFetch()
end

function Fetcher.FinishFetch()
	if not Fetcher.State.isRunning then
		return
	end

	local elapsedTime = globals.RealTime() - Fetcher.State.startTime

	-- Only show detailed debug output in debug mode (via Parsers.PrintStatsSummary)
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	if isDebugMode then
		-- Log the full details only in debug mode
		Log(
			LogLevel.INFO,
			string.format(
				"SYNC Fetch completed in %.2f seconds. Total Added: %d, Total Updated: %d, Errors: %d",
				elapsedTime,
				Fetcher.State.results.total_added,
				Fetcher.State.results.total_updated,
				Fetcher.State.results.errors
			)
		)

		-- Show detailed stats in debug mode
		Parsers.PrintStatsSummary()
	else
		-- User-friendly output with color coding and separate lines for key metrics
		-- Always show processed and added counts in green
		printc(0, 255, 140, 255, string.format("Database entries processed: %d", Parsers.ParseStats.totalProcessed))
		printc(0, 255, 140, 255, string.format("Database entries added: %d", Parsers.ParseStats.totalAdded))

		-- Only show errors if there are any (in red)
		if Parsers.ParseStats.totalErrors > 0 then
			printc(255, 100, 100, 255, string.format("Database errors: %d", Parsers.ParseStats.totalErrors))
		end

		-- Show database entry count in green
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

	Fetcher.State.isRunning = false
	Log(LogLevel.DEBUG, "Fetch process finished")
end

function Fetcher.GetStatus()
	return {
		running = Fetcher.State.isRunning,
	}
end

-- Self-Initialization
local function InitializeFetcher()
	Log(LogLevel.DEBUG, "[FETCHER] Checking if fetch on load is enabled...") -- Use Log (Updated message)
	-- Check G.Menu.Main.Fetch_Database instead of G.Config.AutoFetch
	if
		type(G) == "table"
		and type(G.Menu) == "table"
		and type(G.Menu.Main) == "table"
		and G.Menu.Main.Fetch_Database == true
	then
		Log(LogLevel.INFO, "[FETCHER] Fetch on load enabled, starting fetch process...") -- Use Log (Updated message)
		Fetcher.Start()
	else
		Log(LogLevel.INFO, "[FETCHER] Fetch on load disabled or not configured, skipping initial fetch.") -- Use Log (Updated message)
	end
end

InitializeFetcher()

Log(LogLevel.DEBUG, "[FETCHER] >>> Module execution finished. Returning Fetcher table.") -- Use Log (Debug)
return Fetcher
