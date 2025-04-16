--[[ Cheater Detection - Database Fetcher - Synchronous Simplified Version ]]
print("[FETCHER SOURCE] >>> Module Start") -- ++DEBUG

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
	print("[FETCHER SOURCE] Checking requirements...")
	if type(G) ~= "table" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Globals module not loaded properly")
		return false
	end
	if type(G.DataBase) ~= "table" then
		print("[FETCHER SOURCE] CRITICAL ERROR: G.DataBase is not initialized")
		return false
	end
	if type(Database) ~= "table" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Database module not loaded properly")
		return false
	end
	if type(Database.SaveDatabase) ~= "function" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Database.SaveDatabase function missing")
		return false
	end
	if type(Sources) ~= "table" or type(Sources.GetActiveSources) ~= "function" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Sources module not loaded properly")
		return false
	end
	if type(Parsers) ~= "table" then
		print("[FETCHER SOURCE] CRITICAL ERROR: Parsers module not loaded properly")
		return false
	end
	print("[FETCHER SOURCE] All requirements satisfied")
	return true
end

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
		return 0, 0, 1 -- added, updated, errors
	end

	local response_content = response_content_or_error
	if type(response_content) ~= "string" or response_content == "" then
		print(string.format("[FETCHER SOURCE] Empty or invalid content from %s", source.name))
		return 0, 0, 1 -- added, updated, errors
	end

	print(string.format("[FETCHER SOURCE] Download successful from %s. Size: %d bytes", source.name, #response_content))

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
				added = addedCount
				updated = updatedCount
				sourceStats.processed = processedCount
				sourceStats.added = addedCount
				sourceStats.existing = existingCount
				sourceStats.updated = updatedCount
			else
				print(string.format("[FETCHER SOURCE] Error parsing %s: %s", source.name, errorMsg or "Unknown error"))
				sourceStats.errors = sourceStats.errors + 1
			end
		end
	else
		print(
			string.format("[FETCHER SOURCE] Error: Unknown parser type '%s' for source %s", source.parser, source.name)
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
		print(string.format("[FETCHER SOURCE] %s: Added %d, Updated %d", source.name, added, updated))
	elseif added > 0 then
		print(string.format("[FETCHER SOURCE] %s: Added %d", source.name, added))
	else
		print(string.format("[FETCHER SOURCE] %s: No changes", source.name))
	end

	response_content = nil
	return added, updated, sourceStats.errors
end

-- Public Module Functions
function Fetcher.Start()
	print("[FETCHER SOURCE] Starting SYNC database fetch process")

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
	Fetcher.State.results.total_updated = 0
	Fetcher.State.results.errors = 0

	local active_sources = Sources.GetActiveSources()
	print(string.format("[FETCHER SOURCE] Found %d active sources", #active_sources))

	if #active_sources == 0 then
		print("[FETCHER SOURCE] No active sources found, finishing immediately.")
		Fetcher.FinishFetch()
		return
	end

	-- Process each source synchronously
	for i, source in ipairs(active_sources) do
		print(string.format("[FETCHER SOURCE] Processing source %d/%d: %s", i, #active_sources, source.name))
		local added, updated, errors = processSource(source)
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
	print(
		string.format(
			"[FETCHER SOURCE] SYNC Fetch process completed in %.2f seconds. Total Added: %d, Total Updated: %d, Errors: %d",
			elapsedTime,
			Fetcher.State.results.total_added,
			Fetcher.State.results.total_updated,
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

function Fetcher.GetStatus()
	return {
		running = Fetcher.State.isRunning,
	}
end

-- Self-Initialization
local function InitializeFetcher()
	print("[FETCHER SOURCE] Checking if auto-fetch is enabled...")
	if type(G) == "table" and type(G.Config) == "table" and G.Config.AutoFetch then
		print("[FETCHER SOURCE] Auto-fetch enabled, starting fetch process...")
		Fetcher.Start()
	else
		print("[FETCHER SOURCE] Auto-fetch disabled or not configured, skipping initial fetch.")
	end
end

-- Callback Registration
local function DelayedInit()
	callbacks.Unregister("Draw", "fetcher_init_callback") -- Run only once
	InitializeFetcher()
end

callbacks.Register("Draw", "fetcher_init_callback", DelayedInit)

print("[FETCHER SOURCE] >>> Module execution finished. Returning Fetcher table.") -- ++DEBUG
return Fetcher
