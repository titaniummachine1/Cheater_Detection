--[[ Cheater Detection - Database Fetcher - Simplified Version ]]
print("[FETCHER SOURCE] >>> Module Start") -- ++DEBUG

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Json = Common.Json
local Database = require("Cheater_Detection.Database.Database") -- For SaveDatabase
local Sources = require("Cheater_Detection.Database.Sources") -- Require Sources
local Parsers = require("Cheater_Detection.Database.Parsers") -- Require Parsers

local Fetcher = {}

-- Simplified State tracking
Fetcher.State = {
	isRunning = false,
	startTime = 0,
	results = {
		total_added = 0,
		errors = 0,
	},
	-- Removed totalSources, completedSources, activeCoroutines, sourcesStatus
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
-- Removed, use Parsers.GetSteamID64 directly if needed elsewhere or keep Parsers dependency

-- Coroutine-based HTTP fetch with timeout detection
-- Removed fetchUrl function

-- Process a single source and add its entries to the database
local function processSource(source)
	print(string.format("[FETCHER SOURCE] Processing source: %s (%s)", source.name, source.url))

	-- Fetch the URL directly using pcall
	local fetch_success, response_content_or_error = pcall(http.Get, source.url)

	if not fetch_success then
		print(
			string.format(
				"[FETCHER SOURCE] Failed to fetch data from %s: %s",
				source.name,
				tostring(response_content_or_error)
			)
		)
		Fetcher.State.results.errors = Fetcher.State.results.errors + 1
		return 0, 0 -- Return added, updated
	end

	local response_content = response_content_or_error
	if type(response_content) ~= "string" or response_content == "" then
		print(string.format("[FETCHER SOURCE] Empty or invalid content from %s", source.name))
		Fetcher.State.results.errors = Fetcher.State.results.errors + 1
		return 0, 0 -- Return added, updated
	end

	print(string.format("[FETCHER SOURCE] Download successful from %s. Size: %d bytes", source.name, #response_content))

	-- Create source stats object for tracking
	local sourceStats = {
		processed = 0,
		added = 0,
		existing = 0,
		updated = 0,
		errors = 0,
	}

	local added = 0
	local updated = 0
	local isDirtyBefore = Database.State.isDirty

	-- Determine which parser to use and parse the content
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
			added, updated = addedCount, updatedCount
			sourceStats = {
				processed = processedCount,
				added = addedCount,
				existing = existingCount,
				updated = updatedCount,
				errors = 0,
			}
		else
			print(string.format("[FETCHER SOURCE] Error parsing %s: %s", source.name, errorMsg or "Unknown error"))
			sourceStats.errors = sourceStats.errors + 1
		end
	elseif source.parser == "tf2db" then
		if source.url:find("tf2_bot_detector") and source.url:find("playerlist%.official%.json") then
			local _, errorMsg, stats = Parsers.ParseTF2BotDetector(response_content, source.cause, G.DataBase)
			if stats then
				added, updated = stats.added, stats.updated
				sourceStats = stats
			else
				print(string.format("[FETCHER SOURCE] Error parsing %s: %s", source.name, errorMsg or "Unknown error"))
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
				added, updated = addedCount, updatedCount
				sourceStats = {
					processed = processedCount,
					added = addedCount,
					existing = existingCount,
					updated = updatedCount,
					errors = sourceStats.errors,
				}
			else
				print(string.format("[FETCHER SOURCE] Error parsing %s: %s", source.name, errorMsg or "Unknown error"))
				sourceStats.errors = sourceStats.errors + 1
			end
		end
	else
		print(
			string.format("[FETCHER SOURCE] Error: Unknown parser type '%s' for source %s", source.parser, source.name)
		)
		Fetcher.State.results.errors = Fetcher.State.results.errors + 1
		return 0, 0 -- Return added, updated
	end

	-- Record source stats
	Parsers.AddSourceStats(
		source.name,
		sourceStats.processed,
		sourceStats.added,
		sourceStats.existing,
		sourceStats.errors,
		sourceStats.updated
	)

	-- Check if database changed (additions or updates)
	if (added > 0 or updated > 0) and not isDirtyBefore then
		Database.State.isDirty = true
	end

	-- Print detailed summary for this source
	if updated > 0 then
		print(string.format("[FETCHER SOURCE] %s: Added %d, Updated %d", source.name, added, updated))
	elseif added > 0 then
		print(string.format("[FETCHER SOURCE] %s: Added %d", source.name, added))
	else
		print(string.format("[FETCHER SOURCE] %s: No changes", source.name))
	end

	response_content = nil -- Enable GC
	return added, updated -- Return changes from this source
end

-- Monitor function - Removed

-- Start the fetch process (Simplified)
function Fetcher.Start()
	print("[FETCHER SOURCE] Starting database fetch process")

	if Fetcher.State.isRunning then
		print("[FETCHER SOURCE] Fetch process already running, ignoring request")
		return
	end

	if not checkRequirements() then
		print("[FETCHER SOURCE] Requirements check failed, aborting fetch")
		return
	end

	Parsers.ResetStats()

	Fetcher.State.isRunning = true
	Fetcher.State.startTime = globals.RealTime()
	Fetcher.State.results.total_added = 0
	Fetcher.State.results.errors = 0
	local total_updated = 0 -- Track total updates across all sources

	local active_sources = Sources.GetActiveSources()
	print(string.format("[FETCHER SOURCE] Found %d active sources", #active_sources))

	-- Process each source synchronously
	for i, source in ipairs(active_sources) do
		print(string.format("[FETCHER SOURCE] Processing source %d/%d: %s", i, #active_sources, source.name))
		local added, updated = processSource(source)
		Fetcher.State.results.total_added = Fetcher.State.results.total_added + added
		total_updated = total_updated + updated
	end

	-- Fetch completed, call FinishFetch directly
	Fetcher.FinishFetch(total_updated)
end

-- Complete the fetch process and save the database (Simplified)
function Fetcher.FinishFetch(totalUpdated)
	if not Fetcher.State.isRunning then
		return
	end

	local elapsedTime = globals.RealTime() - Fetcher.State.startTime
	print(
		string.format(
			"[FETCHER SOURCE] Fetch process completed in %.2f seconds. Total Added: %d, Total Updated: %d, Errors: %d",
			elapsedTime,
			Fetcher.State.results.total_added,
			totalUpdated or 0,
			Fetcher.State.results.errors
		)
	)

	Parsers.PrintStatsSummary()

	if Database.State.isDirty then
		print("[FETCHER SOURCE] Changes detected, saving database")
		Database.SaveDatabase()
	else
		print("[FETCHER SOURCE] No changes detected, skipping database save")
	end

	Fetcher.State.isRunning = false
	print("[FETCHER SOURCE] Fetch process finished")
end

-- Get current fetch status (Simplified)
function Fetcher.GetStatus()
	return {
		running = Fetcher.State.isRunning,
		-- No longer tracking detailed progress
	}
end

-- Automatic initialization on module loading (Simplified)
local function InitializeFetcher()
	print("[FETCHER SOURCE] Checking if auto-fetch is enabled...")
	-- Ensure G and G.Config are checked before accessing AutoFetch
	if type(G) == "table" and type(G.Config) == "table" and G.Config.AutoFetch then
		print("[FETCHER SOURCE] Auto-fetch enabled, starting fetch process...")
		Fetcher.Start()
	else
		print("[FETCHER SOURCE] Auto-fetch disabled or not configured, skipping initial fetch.")
	end
end

-- Delayed initialization (simplified, no longer needs separate function)
callbacks.Register("Draw", "fetcher_init_callback", function()
	callbacks.Unregister("Draw", "fetcher_init_callback") -- Run only once
	InitializeFetcher()
end)

print("[FETCHER SOURCE] >>> Module execution finished. Returning Fetcher table.") -- ++DEBUG
return Fetcher
