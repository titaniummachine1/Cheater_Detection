--[[
    Minimal Database_Fetcher.lua that just works
    No bloat, just gets data and adds it to the database
]]

local Common = require("Cheater_Detection.Utils.Common")
local Tasks = require("Cheater_Detection.Database.Tasks")
local Sources = require("Cheater_Detection.Database.Sources")
local Commands = Common.Lib.Utils.Commands -- Use existing Commands
local Json = Common.Json -- Added for JSON parsing

-- Helper function to convert SteamID3 or SteamID to SteamID64 if needed
-- Assumes a global or Common.steam table with ToSteamID64 exists
local function GetSteamID64(id_str)
	if not id_str then
		return nil
	end
	id_str = id_str:match("^%s*(.-)%s*$") -- Trim

	if id_str:match("^765611%d%d%d%d%d%d%d%d%d%d%d$") then
		return id_str -- Already SteamID64
	elseif id_str:match("^STEAM_0:[01]:%d+$") or id_str:match("^%[U:1:%d+%]$") then
		local success, result = pcall(steam.ToSteamID64, id_str) -- Assumes steam.ToSteamID64 exists
		if success and result then
			print(string.format("[Fetcher DEBUG Convert] Converted '%s' to '%s'", id_str, result))
			return result
		else
			print(string.format("[Fetcher DEBUG Convert] Failed to convert '%s'", id_str))
			return nil
		end
	else
		-- Optional: Could try Common.FromSteamid32To64 if applicable
		-- print(string.format("[Fetcher DEBUG Convert] Unrecognized format: '%s'", id_str))
		return nil
	end
end

-- Create fetcher object
local Fetcher = {
	Config = {
		AutoFetchOnLoad = false,
		ShowProgressBar = true,
		SourceDelay = 2, -- Fixed 2 second delay
		LinesPerFrame = 250, -- How many lines to process per frame (for non-JSON)
	},
	Sources = Sources.List,
	Tasks = Tasks, -- Keep reference for UI

	-- State variables for Draw-based processing
	isRunning = false,
	fetchState = "idle", -- idle, delaying, downloading, processing_json, processing_lines, saving, done, download_error
	currentSourceIndex = 0,
	currentSourceContentLines = nil, -- Table of lines from downloaded content (for line processing)
	currentSourceProcessedLineIndex = 0,
	currentSourceAddedCount = 0, -- Added count for the current source
	totalAdded = 0,
	databaseRef = nil,
	callbackRef = nil,
	isSilent = false,
	lastActionTime = 0,
	downloadCoroutine = nil, -- Coroutine for http.Get
	downloadContent = nil, -- Temp storage for downloaded content
}

-- Helper to reset fetch state
function Fetcher.ResetState()
	Fetcher.isRunning = false
	Fetcher.fetchState = "idle"
	Fetcher.currentSourceIndex = 0
	Fetcher.currentSourceContentLines = nil
	Fetcher.currentSourceProcessedLineIndex = 0
	Fetcher.currentSourceAddedCount = 0
	Fetcher.totalAdded = 0
	Fetcher.databaseRef = nil
	Fetcher.callbackRef = nil
	Fetcher.isSilent = false
	Fetcher.lastActionTime = 0
	Fetcher.downloadCoroutine = nil
	Fetcher.downloadContent = nil

	-- Reset Tasks UI state as well
	Tasks.Reset()

	-- Unregister callbacks safely
	pcall(function()
		callbacks.Unregister("Draw", "FetcherMain")
	end)
	pcall(function()
		callbacks.Unregister("Draw", "FetcherUI")
	end)
	pcall(function()
		callbacks.Unregister("Draw", "FetcherSaveDelay")
	end)
end

-- Function to split string by newline characters
local function splitlines(str)
	local lines = {}
	for line in str:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end
	return lines
end

-- Process a JSON data structure (e.g., from bots.tf)
function Fetcher.ProcessJsonData(jsonData, source, db)
	local addedCount = 0
	if not jsonData or type(jsonData) ~= "table" then
		print(string.format("[Fetcher ERROR JSON] Invalid JSON data received for %s", source.name))
		return 0
	end

	-- Heuristic check for bots.tf structure (or similar list-based JSON)
	local players = jsonData.players or jsonData -- Adapt if root is the list
	if type(players) ~= "table" then
		print(string.format("[Fetcher ERROR JSON] Could not find player list in JSON for %s", source.name))
		return 0
	end

	print(string.format("[Fetcher DEBUG JSON] Processing %d potential players from %s", #players, source.name))

	for i, playerEntry in ipairs(players) do
		if type(playerEntry) == "table" and playerEntry.steamid then
			local steamID64 = GetSteamID64(playerEntry.steamid) -- Use conversion helper

			if steamID64 then
				print(
					string.format(
						"[Fetcher DEBUG JSON Check] steamID64: %s, DB entry exists: %s",
						tostring(steamID64),
						tostring(db.data[steamID64])
					)
				)
				if not db.data[steamID64] then
					print(string.format("[Fetcher DEBUG JSON ADD] Attempting to add: %s", steamID64))
					local success, err = pcall(db.HandleSetEntry, steamID64, {
						Name = "Unknown", -- Can potentially extract name if available: playerEntry.last_seen and playerEntry.last_seen.player_name or "Unknown"
						Reason = source.cause, -- Can potentially extract attributes: playerEntry.attributes and table.concat(playerEntry.attributes, ", ") or source.cause
					})
					if success then
						addedCount = addedCount + 1
						print(string.format("[Fetcher DEBUG JSON ADD] Successfully added: %s", steamID64))
						pcall(function()
							playerlist.SetPriority(steamID64, 10)
						end)
					else
						print(string.format("[Fetcher ERROR JSON ADD] Failed to add %s: %s", steamID64, tostring(err)))
					end
				end
			else
				print(
					string.format(
						"[Fetcher DEBUG JSON] Skipping invalid/unconvertible SteamID: %s",
						tostring(playerEntry.steamid)
					)
				)
			end
		else
			print(string.format("[Fetcher DEBUG JSON] Skipping invalid player entry at index %d", i))
		end
	end
	return addedCount
end

-- Processes a single line based on parser type (used for 'raw' or JSON fallback)
function Fetcher.ProcessLine(line, source, database)
	local added = false
	line = line:match("^%s*(.-)%s*$") -- Trim whitespace

	-- Skip comments and empty lines
	if line == "" or line:match("^%-%-") or line:match("^#") or line:match("^//") then
		return false
	end

	local steamID64 = nil
	if source.parser == "raw" then
		-- Try to convert different formats to SteamID64
		steamID64 = GetSteamID64(line)
		if steamID64 then
			print(
				string.format(
					"[Fetcher DEBUG RAW] Extracted/Converted: %s, Exists in DB: %s",
					steamID64,
					tostring(database.data[steamID64])
				)
			)
		else
			print(string.format("[Fetcher DEBUG RAW] Invalid format or failed conversion: %s", line))
		end
	elseif source.parser == "tf2db" then
		-- This is now a fallback if JSON parsing failed, try simple regex
		local extractedId = line:match("(765611%d%d%d%d%d%d%d%d%d%d%d)") -- General match
		steamID64 = GetSteamID64(extractedId) -- Attempt conversion just in case
		if steamID64 then
			print(
				string.format(
					"[Fetcher DEBUG TF2DB Fallback] Extracted/Converted: %s, Exists in DB: %s",
					steamID64,
					tostring(database.data[steamID64])
				)
			)
		else
			-- Don't print "No match found" here as it's expected for most lines in JSON fallback
			-- print(string.format("[Fetcher DEBUG TF2DB Fallback] No valid ID found in line: %s", line))
		end
	end

	-- Add valid IDs to database if not already present
	print(
		string.format(
			"[Fetcher DEBUG Check] steamID64: %s, DB entry exists: %s",
			tostring(steamID64),
			tostring(database.data[steamID64])
		)
	)
	if steamID64 and not database.data[steamID64] then -- Use database instance here
		-- DEBUG: Log before attempting to add
		print(string.format("[Fetcher DEBUG ADD] Attempting to add: %s", steamID64))
		local success, err = pcall(database.HandleSetEntry, steamID64, { -- Use database instance here
			Name = "Unknown", -- Set name to Unknown as requested
			Reason = source.cause,
		})
		if success then
			added = true
			-- DEBUG: Log successful addition
			print(string.format("[Fetcher DEBUG ADD] Successfully added: %s", steamID64))
			-- Set player priority (optional, keep pcall)
			pcall(function()
				playerlist.SetPriority(steamID64, 10)
			end)
		else
			-- DEBUG: Log failure to add
			print(string.format("[Fetcher ERROR ADD] Failed to add %s: %s", steamID64, tostring(err)))
		end
	end

	return added
end

-- Main processing function called by Draw callback
function Fetcher.ProcessStep()
	if not Fetcher.isRunning then
		Fetcher.ResetState() -- Ensure cleanup if stopped externally
		return
	end

	local db = Fetcher.databaseRef
	if not db then
		print("[Fetcher] Error: Database reference lost.")
		Fetcher.ResetState()
		return
	end

	local currentTime = globals.RealTime()
	local source = Fetcher.Sources[Fetcher.currentSourceIndex]
	local sourceName = source and (source.name or "Unknown Source") or "Finalizing"

	-- State Machine
	if Fetcher.fetchState == "delaying" then
		local elapsed = currentTime - Fetcher.lastActionTime
		local remaining = math.ceil(Fetcher.Config.SourceDelay - elapsed)
		if elapsed >= Fetcher.Config.SourceDelay then
			Fetcher.fetchState = "downloading"
			Fetcher.downloadCoroutine = nil -- Ensure coroutine is reset before starting new download
			Fetcher.downloadContent = nil
			Tasks.StartSource(sourceName) -- Update progress when starting download attempt
			Tasks.targetProgress = (Fetcher.currentSourceIndex - 1) / #Fetcher.Sources * 100
			Tasks.message = "Starting download from " .. sourceName .. "..."
		else
			Tasks.message = "Waiting " .. remaining .. "s between requests..."
		end
	elseif Fetcher.fetchState == "downloading" then
		-- Start download coroutine if not already started
		if not Fetcher.downloadCoroutine then
			Tasks.message = "Starting download from " .. sourceName .. "..." -- Initial message
			Fetcher.downloadCoroutine = coroutine.create(function(url)
				local ok, res1, res2 = pcall(http.Get, url)
				if not ok then
					return false, res1
				end
				return true, res1, res2
			end)
			Fetcher.downloadContent = nil -- Clear previous content
		end

		-- Resume the download coroutine
		local status, coroutine_ran_ok, get_pcall_ok, result1, result2 =
			pcall(coroutine.resume, Fetcher.downloadCoroutine, source.url)

		if not status then -- Error resuming coroutine itself (very rare)
			print("[Fetcher] Error resuming download coroutine: " .. tostring(coroutine_ran_ok)) -- coroutine_ran_ok here is the error msg
			Fetcher.fetchState = "download_error"
		elseif coroutine.status(Fetcher.downloadCoroutine) == "suspended" then
			Tasks.message = "Downloading from " .. sourceName .. "... (in progress)"
		elseif coroutine.status(Fetcher.downloadCoroutine) == "dead" then
			Fetcher.downloadCoroutine = nil -- Clear the finished coroutine

			if not coroutine_ran_ok then
				print(
					"[Fetcher] Error inside download coroutine function for "
						.. sourceName
						.. ": "
						.. tostring(get_pcall_ok)
				)
				Fetcher.fetchState = "download_error"
			elseif not get_pcall_ok then
				print("[Fetcher] Failed http.Get for " .. sourceName .. ". Reason: " .. tostring(result1))
				Fetcher.fetchState = "download_error"
			elseif type(result1) == "string" then
				print(
					string.format(
						"[Fetcher DEBUG] Received content from %s (first 200 chars): %s",
						sourceName,
						result1:sub(1, 200)
					)
				)

				if #result1 > 0 then
					-- Success! Store content and decide processing method
					Fetcher.downloadContent = result1 -- Store full content
					result1 = nil -- Allow GC for the potentially large string copy
					collectgarbage("collect")

					Fetcher.currentSourceAddedCount = 0 -- Reset count for this source

					-- Decide processing method based on parser type
					if source.parser == "tf2db" then
						Fetcher.fetchState = "processing_json" -- Try JSON first
						Tasks.message = "Attempting JSON parse for " .. sourceName
					else -- Assume 'raw' or other line-based
						Fetcher.fetchState = "processing_lines"
						Fetcher.currentSourceContentLines = splitlines(Fetcher.downloadContent)
						Fetcher.downloadContent = nil -- Content split into lines, free original
						collectgarbage("collect")
						Fetcher.currentSourceProcessedLineIndex = 1
						Tasks.message = "Processing lines for " .. sourceName
					end
				else
					print("[Fetcher] Failed to download from " .. sourceName .. ". Reason: Returned empty string")
					Fetcher.fetchState = "download_error"
				end
			else
				-- Handle other http.Get failures (nil, false, etc.)
				local failureReason = "Unknown http.Get failure"
				if result1 == nil then
					failureReason = "Returned nil" .. (result2 and (" (Info: " .. tostring(result2) .. ")") or "")
				elseif result1 == false then
					failureReason = "Returned false" .. (result2 and (" (Info: " .. tostring(result2) .. ")") or "")
				else
					failureReason = "Returned type: "
						.. type(result1)
						.. " ("
						.. tostring(result1)
						.. ")"
						.. (result2 and (", Info: " .. tostring(result2)) or "")
				end
				print("[Fetcher] Failed to download from " .. sourceName .. ". Reason: " .. failureReason)
				Fetcher.fetchState = "download_error"
			end
			Fetcher.lastActionTime = currentTime -- Update time after download attempt finished
		end -- End of coroutine status check
	elseif Fetcher.fetchState == "download_error" then
		-- Handle download error (skip to next source)
		print("[Fetcher] Skipping source due to download error: " .. sourceName)
		-- **Print count before skipping**
		print(
			"[Fetcher] Added " .. Fetcher.currentSourceAddedCount .. " entries from " .. sourceName .. " (before skip)"
		)
		Fetcher.totalAdded = Fetcher.totalAdded + Fetcher.currentSourceAddedCount -- Add to total even if skipped

		Fetcher.currentSourceIndex = Fetcher.currentSourceIndex + 1
		Fetcher.lastActionTime = currentTime
		if Fetcher.currentSourceIndex > #Fetcher.Sources then
			Fetcher.fetchState = "saving"
		else
			Fetcher.fetchState = "delaying"
		end
		Fetcher.downloadCoroutine = nil
		Fetcher.downloadContent = nil
	elseif Fetcher.fetchState == "processing_json" then
		-- Attempt to parse the stored content as JSON
		local success, jsonData = pcall(Json.decode, Fetcher.downloadContent)
		Fetcher.downloadContent = nil -- Clear original content string
		collectgarbage("collect")

		if success and jsonData then
			print("[Fetcher] Successfully parsed JSON for " .. sourceName)
			-- Process the JSON data structure (this might take time, but not frame-limited here)
			local addedFromJson = Fetcher.ProcessJsonData(jsonData, source, db)
			Fetcher.currentSourceAddedCount = Fetcher.currentSourceAddedCount + addedFromJson
			print("[Fetcher] Finished processing JSON for " .. sourceName)
			-- Since JSON processing is done in one go, move to next source/state
			Fetcher.fetchState = "source_done"
		else
			-- JSON parsing failed, fall back to line processing
			print("[Fetcher] Failed to parse JSON for " .. sourceName .. ". Falling back to line processing.")
			-- Resplit the original content (need to refetch or store it differently?)
			-- For now, let's just skip this source if JSON fails and it was tf2db
			-- TODO: Re-evaluate if fallback line processing is desired/possible after failed JSON parse
			print("[Fetcher] Skipping source " .. sourceName .. " after failed JSON parse.")
			Fetcher.fetchState = "source_done" -- Treat as done, even though failed
		end
	elseif Fetcher.fetchState == "processing_lines" then
		-- Process lines per frame (for 'raw' or 'tf2db' fallback)
		local linesProcessedThisFrame = 0
		local totalLines = #Fetcher.currentSourceContentLines

		while
			linesProcessedThisFrame < Fetcher.Config.LinesPerFrame
			and Fetcher.currentSourceProcessedLineIndex <= totalLines
		do
			local line = Fetcher.currentSourceContentLines[Fetcher.currentSourceProcessedLineIndex]
			if Fetcher.ProcessLine(line, source, db) then
				Fetcher.currentSourceAddedCount = Fetcher.currentSourceAddedCount + 1
				-- Fetcher.totalAdded = Fetcher.totalAdded + 1 -- Move totalAdded increment to 'source_done'
			end
			Fetcher.currentSourceProcessedLineIndex = Fetcher.currentSourceProcessedLineIndex + 1
			linesProcessedThisFrame = linesProcessedThisFrame + 1
		end

		Tasks.message = string.format(
			"Processing Lines %s: %d / %d (%d added)",
			sourceName,
			Fetcher.currentSourceProcessedLineIndex - 1,
			totalLines,
			Fetcher.currentSourceAddedCount
		)

		if Fetcher.currentSourceProcessedLineIndex > totalLines then
			Fetcher.currentSourceContentLines = nil -- Allow GC
			collectgarbage("collect")
			Fetcher.fetchState = "source_done" -- Finished processing lines for this source
		end
	elseif Fetcher.fetchState == "source_done" then
		-- This state is reached after processing_json or processing_lines finishes
		print("[Fetcher] Added " .. Fetcher.currentSourceAddedCount .. " entries from " .. sourceName)
		Tasks.SourceDone() -- Mark source done in UI tracker
		Fetcher.totalAdded = Fetcher.totalAdded + Fetcher.currentSourceAddedCount -- Add source total to overall total

		-- Move to next source or finish
		Fetcher.currentSourceIndex = Fetcher.currentSourceIndex + 1
		Fetcher.lastActionTime = currentTime
		if Fetcher.currentSourceIndex > #Fetcher.Sources then
			Fetcher.fetchState = "saving" -- All sources processed
		else
			Fetcher.fetchState = "delaying" -- Need to delay before next source
		end
	elseif Fetcher.fetchState == "saving" then
		Tasks.message = "Finalizing..."
		Tasks.targetProgress = 100
		if Fetcher.totalAdded > 0 then
			db.State.isDirty = true
			pcall(function()
				callbacks.Unregister("Draw", "FetcherSaveDelay")
			end)
			callbacks.Register("Draw", "FetcherSaveDelay", function()
				callbacks.Unregister("Draw", "FetcherSaveDelay")
				if db and db.SaveDatabase then
					print("[Fetcher] Saving database changes...")
					db.SaveDatabase()
				else
					print("[Fetcher] Error: Could not save database.")
				end
				Fetcher.fetchState = "done"
				Fetcher.lastActionTime = globals.RealTime()
			end)
			Fetcher.fetchState = "waiting_save"
			Tasks.message = "Saving Database..."
		else
			Fetcher.fetchState = "done"
			Fetcher.lastActionTime = currentTime
		end
	elseif Fetcher.fetchState == "waiting_save" then
		Tasks.message = "Saving Database..."
	elseif Fetcher.fetchState == "done" then
		Tasks.status = "complete"
		Tasks.message = "Update Complete: Added " .. Fetcher.totalAdded .. " entries"
		Tasks.completedTime = Fetcher.lastActionTime

		print("[Fetcher] " .. Tasks.message)

		if Fetcher.callbackRef and type(Fetcher.callbackRef) == "function" then
			pcall(Fetcher.callbackRef, Fetcher.totalAdded)
		end

		Fetcher.ResetState() -- Final cleanup
	end
end

-- UI Drawing Function
function Fetcher.DrawUI()
	if Fetcher.isRunning and not Fetcher.isSilent then
		pcall(Tasks.DrawProgressUI)
	else
		-- Auto-unregister if no longer needed
		pcall(function()
			callbacks.Unregister("Draw", "FetcherUI")
		end)
	end
end

-- Start the fetch process (replaces FetchAll)
function Fetcher.StartFetch(database, callback, silent)
	-- Don't start if already running
	if Fetcher.isRunning then
		print("[Fetcher] Fetch operation already in progress.")
		return false
	end

	-- Ensure database is provided
	if not database then
		print("[Fetcher] Error: Database object not provided for fetching.")
		return false
	end

	-- Reset state and initialize
	Fetcher.ResetState() -- Clean slate
	Tasks.Init(#Fetcher.Sources) -- Init UI tasks

	Fetcher.isRunning = true
	Fetcher.isSilent = silent or false
	Fetcher.databaseRef = database
	Fetcher.callbackRef = callback
	Fetcher.totalAdded = 0
	Fetcher.currentSourceIndex = 1 -- Start with the first source
	Fetcher.lastActionTime = globals.RealTime()

	-- Initial state depends on whether there are sources
	if #Fetcher.Sources > 0 then
		Fetcher.fetchState = "downloading" -- Start downloading first source immediately (no initial delay)
		Tasks.StartSource(Fetcher.Sources[1].name or "Unknown Source") -- Update UI task for first source
		Tasks.targetProgress = 0 -- Start progress at 0
		Tasks.message = "Starting download..."
	else
		Fetcher.fetchState = "saving" -- No sources, go directly to saving/completion
		Tasks.message = "No sources configured."
	end

	-- Register necessary Draw callbacks
	callbacks.Register("Draw", "FetcherMain", Fetcher.ProcessStep)
	if not Fetcher.isSilent then
		callbacks.Register("Draw", "FetcherUI", Fetcher.DrawUI)
	end

	print("[Fetcher] Starting database update...")
	return true
end

-- Auto fetch handler
function Fetcher.AutoFetch(database)
	if not database then
		local success, db = pcall(function()
			return require("Cheater_Detection.Database.Database")
		end)

		if not success or not db then
			print("[Fetcher] AutoFetch failed: Could not load Database module.")
			return false
		end
		database = db
	end

	print("[Fetcher] Starting AutoFetch...")
	-- Use the new StartFetch function
	return Fetcher.StartFetch(database, function(totalAdded)
		if totalAdded > 0 then
			printc(80, 200, 120, 255, "[Database] Auto-updated with " .. totalAdded .. " new entries")
		else
			print("[Fetcher] AutoFetch complete: No new entries added.")
		end
	end, not Fetcher.Config.ShowProgressBar)
end

-- Register only essential commands
Commands.Register("cd_fetch", function()
	if not Fetcher.isRunning then
		local Database = require("Cheater_Detection.Database.Database")
		if not Database then
			print("[cd_fetch] Error: Could not load Database module.")
			return
		end
		Fetcher.StartFetch(Database, function(totalAdded) -- Add a simple callback for manual fetch
			print("[Fetcher] Manual fetch complete. Added " .. totalAdded .. " entries.")
		end)
	else
		print("[Database Fetcher] A fetch operation is already in progress")
	end
end, "Fetch all cheater lists and update the database")

Commands.Register("cd_cancel", function()
	if Fetcher.isRunning then
		print("[Database Fetcher] Cancelling operation...")
		Fetcher.ResetState() -- Resets state and unregisters callbacks
		print("[Database Fetcher] Cancelled fetch operation.")
	else
		print("[Database Fetcher] No fetch operation is currently running.")
	end
end, "Cancel any running fetch operations")

-- Auto-fetch on load if enabled
if Fetcher.Config.AutoFetchOnLoad then
	pcall(function()
		callbacks.Unregister("Draw", "FetcherAutoLoad")
	end)

	-- Delay auto-fetch slightly to allow other scripts to load
	callbacks.Register("Draw", "FetcherAutoLoad", function()
		callbacks.Unregister("Draw", "FetcherAutoLoad")
		print("[Fetcher] Triggering AutoFetch on load...")
		Fetcher.AutoFetch()
	end)
end

return Fetcher
