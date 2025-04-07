--[[
    Minimal Database_Fetcher.lua that just works
    No bloat, just gets data and adds it to the database
]]

local Common = require("Cheater_Detection.Utils.Common")
local Tasks = require("Cheater_Detection.Database.Tasks")
local Sources = require("Cheater_Detection.Database.Sources")
local Commands = Common.Lib.Utils.Commands -- Use existing Commands

-- Create fetcher object
local Fetcher = {
	Config = {
		AutoFetchOnLoad = false,
		ShowProgressBar = true,
		SourceDelay = 2, -- Fixed 2 second delay
		LinesPerFrame = 250, -- How many lines to process per frame
	},
	Sources = Sources.List,
	Tasks = Tasks, -- Keep reference for UI

	-- State variables for Draw-based processing
	isRunning = false,
	fetchState = "idle", -- idle, delaying, downloading, processing, saving, done, download_error
	currentSourceIndex = 0,
	currentSourceContentLines = nil, -- Table of lines from downloaded content
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
	for line in str:gmatch("[^\\r\\n]+") do
		table.insert(lines, line)
	end
	return lines
end

-- Processes a single line based on parser type
function Fetcher.ProcessLine(line, source, database)
	local added = false
	line = line:match("^%s*(.-)%s*$") -- Trim whitespace

	-- Skip comments and empty lines
	if line == "" or line:match("^%-%-") or line:match("^#") or line:match("^//") then
		return false
	end

	local steamID64 = nil
	if source.parser == "raw" then
		-- Check if line is a valid SteamID64
		if line:match("^7656119%d+$") and #line >= 17 then -- Stricter check for SteamID64 format
			steamID64 = line
			-- DEBUG: Print extracted ID and DB check result
			-- print(string.format("[Fetcher DEBUG RAW] Extracted: %s, Exists in DB: %s", steamID64, tostring(Database.data[steamID64])))
			-- else -- Optional DEBUG for lines failing the raw check
			-- print(string.format("[Fetcher DEBUG RAW] Invalid format or length: %s", line))
		end
	elseif source.parser == "tf2db" then
		-- Improved regex to find "steamid": "..." pattern within the line, handling potential whitespace
		-- It captures the SteamID64 part.
		local extractedId = line:match('"steamid"%s*:%s*"?(7656119%d+)"?') -- Capture SteamID64 directly

		if extractedId then
			-- DEBUG: Print extracted ID and DB check result
			-- print(string.format("[Fetcher DEBUG TF2DB] Extracted: %s, Exists in DB: %s", extractedId, tostring(Database.data[extractedId])))
			steamID64 = extractedId -- Already SteamID64
			-- else -- Optional DEBUG for lines failing the tf2db check
			-- print(string.format("[Fetcher DEBUG TF2DB] No match found in line: %s", line))
		end
		-- Note: No steam.ToSteamID64 conversion needed as we target SteamID64 directly from the JSON structure
	end

	-- Add valid IDs to database if not already present
	if steamID64 and not Database.data[steamID64] then
		-- DEBUG: Log before attempting to add
		-- print(string.format("[Fetcher DEBUG ADD] Attempting to add: %s", steamID64))
		local success, err = pcall(Database.HandleSetEntry, steamID64, {
			Name = "Unknown", -- Set name to Unknown as requested
			Reason = source.cause,
		})
		if success then
			added = true
			-- DEBUG: Log successful addition
			-- print(string.format("[Fetcher DEBUG ADD] Successfully added: %s", steamID64))
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
			-- Update progress immediately for download state
			Tasks.StartSource(sourceName)
			Tasks.targetProgress = (Fetcher.currentSourceIndex - 1) / #Fetcher.Sources * 100
		else
			Tasks.message = "Waiting " .. remaining .. "s between requests..."
		end
	elseif Fetcher.fetchState == "downloading" then
		-- Start download coroutine if not already started
		if not Fetcher.downloadCoroutine then
			Tasks.message = "Starting download from " .. sourceName .. "..."
			Fetcher.downloadCoroutine = coroutine.create(function(url) -- Pass URL to coroutine
				-- Directly call http.Get; pcall is handled outside now
				return http.Get(url)
			end)
			Fetcher.downloadContent = nil -- Clear previous content
		end

		-- Resume the download coroutine
		-- status: pcall success/fail; coroutine_success: coroutine ran ok; http_results...: return values from http.Get
		local status, coroutine_success, http_result1, http_result2 =
			pcall(coroutine.resume, Fetcher.downloadCoroutine, source.url)

		if not status then -- Error resuming coroutine itself (rare)
			print("[Fetcher] Error resuming download coroutine: " .. tostring(coroutine_success)) -- coroutine_success here is the error msg
			Fetcher.fetchState = "download_error"
			Fetcher.lastActionTime = currentTime
		elseif coroutine.status(Fetcher.downloadCoroutine) == "suspended" then
			-- Still downloading, update message maybe?
			Tasks.message = "Downloading from " .. sourceName .. "... (in progress)"
		elseif coroutine.status(Fetcher.downloadCoroutine) == "dead" then
			-- Coroutine finished
			Fetcher.downloadCoroutine = nil -- Clear the finished coroutine

			if not coroutine_success then
				-- Error *inside* the coroutine (e.g., http.Get itself errored)
				print("[Fetcher] Error inside download coroutine for " .. sourceName .. ": " .. tostring(http_result1)) -- http_result1 has error
				Fetcher.fetchState = "download_error"
			-- Check the actual results from http.Get
			elseif type(http_result1) == "string" then -- Check if it's a string first
				-- TEMP DEBUG: Print start of received content
				print(
					string.format(
						"[Fetcher DEBUG] Received content from %s (first 200 chars): %s",
						sourceName,
						http_result1:sub(1, 200)
					)
				)

				if #http_result1 > 0 then
					-- Success! Got non-empty string content
					Fetcher.currentSourceContentLines = splitlines(http_result1)
					http_result1 = nil -- Allow garbage collection
					Fetcher.currentSourceProcessedLineIndex = 1
					Fetcher.currentSourceAddedCount = 0
					Fetcher.fetchState = "processing"
					Tasks.message = "Processing " .. sourceName
					collectgarbage("collect")
				else
					-- It was an empty string
					local failureReason = "Returned empty string"
					print("[Fetcher] Failed to download from " .. sourceName .. ". Reason: " .. failureReason)
					Fetcher.fetchState = "download_error"
				end
			else
				-- http.Get returned something other than a string
				local failureReason = "Unknown failure"
				if http_result1 == nil then
					-- It explicitly returned nil, often indicates a more severe connection issue?
					failureReason = "Returned nil"
						.. (http_result2 and (" (Info: " .. tostring(http_result2) .. ")") or "")
				elseif http_result1 == false then
					-- Explicitly returned false, likely indicates HTTP error (4xx, 5xx, redirect?)
					failureReason = "Returned false"
						.. (http_result2 and (" (Info: " .. tostring(http_result2) .. ")") or "")
				else
					failureReason = "Returned type: " .. type(http_result1) .. " (" .. tostring(http_result1) .. ")"
				end
				print("[Fetcher] Failed to download from " .. sourceName .. ". Reason: " .. failureReason)
				Fetcher.fetchState = "download_error"
			end
			Fetcher.lastActionTime = currentTime -- Update time after download attempt finished
		end
	elseif Fetcher.fetchState == "download_error" then
		-- Handle download error (e.g., skip to next source)
		print("[Fetcher] Skipping source due to download error: " .. sourceName)
		Fetcher.currentSourceIndex = Fetcher.currentSourceIndex + 1
		Fetcher.lastActionTime = currentTime
		if Fetcher.currentSourceIndex > #Fetcher.Sources then
			Fetcher.fetchState = "saving" -- Move to saving state if last source failed
		else
			Fetcher.fetchState = "delaying" -- Delay before next source
		end
		-- Ensure download coroutine is cleared if it somehow still exists
		Fetcher.downloadCoroutine = nil
		Fetcher.downloadContent = nil
	elseif Fetcher.fetchState == "processing" then
		local linesProcessedThisFrame = 0
		local totalLines = #Fetcher.currentSourceContentLines

		while
			linesProcessedThisFrame < Fetcher.Config.LinesPerFrame
			and Fetcher.currentSourceProcessedLineIndex <= totalLines
		do
			local line = Fetcher.currentSourceContentLines[Fetcher.currentSourceProcessedLineIndex]
			if Fetcher.ProcessLine(line, source, db) then
				Fetcher.currentSourceAddedCount = Fetcher.currentSourceAddedCount + 1
				Fetcher.totalAdded = Fetcher.totalAdded + 1
			end
			Fetcher.currentSourceProcessedLineIndex = Fetcher.currentSourceProcessedLineIndex + 1
			linesProcessedThisFrame = linesProcessedThisFrame + 1
		end

		-- Update progress message
		Tasks.message = string.format(
			"Processing %s: %d / %d lines (%d added)",
			sourceName,
			Fetcher.currentSourceProcessedLineIndex - 1,
			totalLines,
			Fetcher.currentSourceAddedCount
		)

		-- Check if finished processing this source
		if Fetcher.currentSourceProcessedLineIndex > totalLines then
			print("[Fetcher] Added " .. Fetcher.currentSourceAddedCount .. " entries from " .. sourceName)
			Tasks.SourceDone() -- Mark source done in UI tracker
			Fetcher.currentSourceContentLines = nil -- Allow GC
			collectgarbage("collect")

			-- Move to next source or finish
			Fetcher.currentSourceIndex = Fetcher.currentSourceIndex + 1
			Fetcher.lastActionTime = currentTime
			if Fetcher.currentSourceIndex > #Fetcher.Sources then
				Fetcher.fetchState = "saving" -- All sources processed
			else
				Fetcher.fetchState = "delaying" -- Need to delay before next source
			end
		end
	elseif Fetcher.fetchState == "saving" then
		Tasks.message = "Finalizing..."
		Tasks.targetProgress = 100 -- Ensure progress bar shows 100%
		if Fetcher.totalAdded > 0 then
			db.State.isDirty = true -- Ensure marked dirty
			-- Schedule save for next frame to avoid issues within Draw
			pcall(function()
				callbacks.Unregister("Draw", "FetcherSaveDelay")
			end)
			callbacks.Register("Draw", "FetcherSaveDelay", function()
				callbacks.Unregister("Draw", "FetcherSaveDelay")
				if db and db.SaveDatabase then -- Check if db and function exist
					print("[Fetcher] Saving database changes...")
					db.SaveDatabase()
				else
					print("[Fetcher] Error: Could not save database.")
				end
				Fetcher.fetchState = "done" -- Move to done state *after* save attempt
				Fetcher.lastActionTime = globals.RealTime()
			end)
			-- Set state to an intermediate 'waiting_save' to prevent immediate transition to 'done'
			Fetcher.fetchState = "waiting_save"
			Tasks.message = "Saving Database..."
		else
			-- No changes, just mark as done
			Fetcher.fetchState = "done"
			Fetcher.lastActionTime = currentTime
		end
	elseif Fetcher.fetchState == "waiting_save" then
		-- Do nothing, wait for the FetcherSaveDelay callback to trigger
		Tasks.message = "Saving Database..."
	elseif Fetcher.fetchState == "done" then
		Tasks.status = "complete"
		Tasks.message = "Update Complete: Added " .. Fetcher.totalAdded .. " entries"
		Tasks.completedTime = Fetcher.lastActionTime

		print("[Fetcher] " .. Tasks.message)

		-- Run callback if provided
		if Fetcher.callbackRef and type(Fetcher.callbackRef) == "function" then
			pcall(Fetcher.callbackRef, Fetcher.totalAdded)
		end

		-- Final cleanup
		Fetcher.ResetState() -- This also unregisters callbacks
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
