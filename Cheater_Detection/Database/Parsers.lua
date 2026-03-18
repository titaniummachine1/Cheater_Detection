---@diagnostic disable: undefined-global, undefined-field
local Common = require("Cheater_Detection.Utils.Common")
-- [[ Imported by: Fetcher.lua (indirectly) ]]
local Json = Common.Json
-- [[ Imported by: Parsers.lua ]]

local G = require("Cheater_Detection.Utils.Globals")
-- [[ Imported by: Fetcher.lua, Parsers.lua ]]

local Parsers = {}


-- Stats tracking for parser operations
Parsers.ParseStats = {
	sources = {},
	totalProcessed = 0,
	totalAdded = 0,
	totalExisting = 0,
	totalErrors = 0,
	totalUpdated = 0,
}

-- Reset stats for a new parsing session
function Parsers.ResetStats()
	Parsers.ParseStats = {
		sources = {},
		totalProcessed = 0,
		totalAdded = 0,
		totalExisting = 0,
		totalErrors = 0,
		totalUpdated = 0,
	}
end

-- Add stats for a source
function Parsers.AddSourceStats(sourceName, processed, added, existing, errors, updated, updName, updReason, updStatic)
	Parsers.ParseStats.sources[sourceName] = {
		processed = processed or 0,
		added = added or 0,
		existing = existing or 0,
		errors = errors or 0,
		updated = updated or 0,
		updName = updName or 0,
		updReason = updReason or 0,
		updStatic = updStatic or 0,
	}

	-- Update totals
	Parsers.ParseStats.totalProcessed = Parsers.ParseStats.totalProcessed + processed
	Parsers.ParseStats.totalAdded = Parsers.ParseStats.totalAdded + added
	Parsers.ParseStats.totalExisting = Parsers.ParseStats.totalExisting + existing
	Parsers.ParseStats.totalErrors = Parsers.ParseStats.totalErrors + errors
	-- Add updating to totals if it exists
	Parsers.ParseStats.totalUpdated = (Parsers.ParseStats.totalUpdated or 0) + (updated or 0)
end

-- Get a formatted summary of all parsing statistics
function Parsers.GetStatsSummary()
	local summary = "[PARSE STATS SUMMARY]\n"

	-- Add per-source stats
	for sourceName, stats in pairs(Parsers.ParseStats.sources) do
		-- Check if source has any updates to report
		local updatesInfo = ""
		if stats.updated and stats.updated > 0 then
			local breakdown = string.format(
				" (name=%d/reason=%d/static=%d)",
				stats.updName or 0,
				stats.updReason or 0,
				stats.updStatic or 0
			)
			updatesInfo = string.format(", Updated: %d%s", stats.updated, breakdown)
		end

		summary = summary
			.. string.format(
				"[Source: %s] Processed: %d, Added: %d, Already Exists: %d%s, Errors: %d\n",
				sourceName,
				stats.processed,
				stats.added,
				stats.existing,
				updatesInfo,
				stats.errors
			)
	end

	-- Calculate total updates
	local totalUpdated = 0
	for _, stats in pairs(Parsers.ParseStats.sources) do
		totalUpdated = totalUpdated + (stats.updated or 0)
	end

	-- Add total stats with updates info
	local totalUpdatesInfo = ""
	if totalUpdated > 0 then
		totalUpdatesInfo = string.format(", Updated: %d", totalUpdated)
	end

	summary = summary
		.. string.format(
			"[TOTAL] Processed: %d, Added: %d, Already Exists: %d%s, Errors: %d",
			Parsers.ParseStats.totalProcessed,
			Parsers.ParseStats.totalAdded,
			Parsers.ParseStats.totalExisting,
			totalUpdatesInfo,
			Parsers.ParseStats.totalErrors
		)

	return summary
end

-- Formats and prints a statistics bundle for all parsing operations
function Parsers.PrintStatsSummary()
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	-- Only print the summary if in debug mode
	if isDebugMode then
		local summary = Parsers.GetStatsSummary()
		if summary then
			print(summary) -- Keep using plain print for multi-line debug summary
		end

	end
end

local steamIDCache = {}

-- Robust SteamID conversion function (moved from Fetcher)
-- Handles SteamID64, SteamID3 ([U:1:xxxx]), SteamID2 (STEAM_0:x:xxxx)
function Parsers.GetSteamID64(input)
	if not input then
		return nil
	end

	if steamIDCache[input] then
		return steamIDCache[input]
	end

	-- Optimization: Check if it's already a standard SteamID64 string (starts with 765, length ~17)
	local id_str = tostring(input):match("^%s*(765%d+)")
	if id_str and #id_str >= 17 then
		return id_str
	end

	-- Trim and handle standard SteamID formats
	id_str = tostring(input):match("^%s*(.-)%s*$")
	if not id_str or id_str == "" then
		return nil
	end

	-- Manual fallback for SteamID3 (common in community lists)
	local accountID = id_str:match("%[U:1:(%d+)%]")
	if accountID then
		accountID = tonumber(accountID)
		if accountID then
			local result = tostring(76561197960265728 + accountID)
			steamIDCache[input] = result
			return result
		end
	end

	-- Expensive path: Only call engine/steam API if absolutely necessary
	if steam and steam.ToSteamID64 then
		local success, result = pcall(steam.ToSteamID64, id_str)
		if success and result then
			local result_str = tostring(result):match("(765%d+)")
			if result_str and #result_str >= 17 then
				steamIDCache[input] = result_str
				return result_str
			end
		end
	end

	return nil
end

-- Decodes a JSON string and returns the players array for chunked processing
-- Returns: playersArray or nil, errorMsg
function Parsers.GetPlayersFromJSON(contentString)
	if not contentString or contentString == "" then
		return nil, "Empty content string"
	end

	if not Json or type(Json.decode) ~= "function" then
		return nil, "JSON decode function is unavailable"
	end

	-- Strip UTF-8 BOM (EF BB BF) that some GitHub raw files include
	local stripped = contentString:gsub("^\xEF\xBB\xBF", "")

	-- Skip obvious HTML error pages (CDN/proxy failures)
	if stripped:match("^%s*<!") or stripped:match("^%s*<html") then
		return nil, "Response is HTML (likely CDN error page), length=" .. #stripped
	end

	local success, data = pcall(Json.decode, stripped)

	if not success then
		return nil, "JSON decode error: " .. tostring(data)
	end

	if type(data) ~= "table" then
		return nil, "JSON decode returned " .. type(data)
	end

	local players = data.players
	if not players then
		-- Fallback for root-level arrays
		if #data > 0 and data[1] and data[1].steamid then
			players = data
		end
	end

	if not players then
		return nil, "JSON missing 'players' array"
	end

	return players, nil
end

-- Processes a single player entry into the database
-- Returns: wasAdded, wasUpdated, wasError
function Parsers.ParseTF2BotDetector_MergeEntry(player, existingEntries, staticSource, defaultReason)
	if not player or type(player) ~= "table" then
		return false, false, true
	end

	-- Get the SteamID and convert to SteamID64
	local steamID64 = Parsers.GetSteamID64(player.steamid)
	if not steamID64 then
		return false, false, true
	end

	-- Determine player name (from last_seen if available)
	local playerName = "Unknown"
	if player.last_seen and player.last_seen.player_name then
		local rawName = player.last_seen.player_name
		-- Reject names that are just the SteamID64 itself (some sources use ID as placeholder)
		local isSteamID = type(rawName) == "string" and rawName:match("^7656119%d%d%d%d%d%d%d%d%d%d$")
		if not isSteamID then
			playerName = rawName
		end
	end

	-- Get the first attribute as the reason
	local reason = defaultReason or "Unknown Source"
	if player.attributes and #player.attributes > 0 then
		-- Use first attribute, capitalized
		local firstAttribute = player.attributes[1]
		reason = firstAttribute:gsub("^%l", string.upper) -- Capitalize first letter
	end

	-- Add to entries if not already there
	if existingEntries[steamID64] then
		-- IN-PLACE UPDATE OPTIMIZATION:
		-- Data is pre-allocated from database.txt load. Update existing entry fields.
		local existingEntry = existingEntries[steamID64]
		local updName, updReason, updStatic = false, false, false


		-- If existing entry has unknown name and this one has a name
		if
			(existingEntry.Name == "Unknown" or existingEntry.Name == nil)
			and playerName
			and playerName ~= "Unknown"
		then
			existingEntry.Name = playerName
			updName = true
		end

		-- If existing entry has unknown reason and this one has a reason
		if
			(existingEntry.Reason == "Unknown Source" or existingEntry.Reason == nil)
			and reason
			and reason ~= "Unknown Source"
		then
			existingEntry.Reason = reason
			updReason = true
		end

		-- Mark as static if this is an external source
		if staticSource then
			-- FINAL SAFETY: Never store URLs
			if type(staticSource) == "string" and (staticSource:find("http") or #staticSource > 25) then
				staticSource = "Ext"
			end
			local hasStatic = existingEntry.Static ~= nil
				and existingEntry.Static ~= false
				and existingEntry.Static ~= ""
			if not hasStatic then
				existingEntry.Static = staticSource
				updStatic = true
			end
		end

		local updated = updName or updReason or updStatic


		return false, updated, false, updName, updReason, updStatic
	else
		-- Pre-allocation: Entry doesn't exist, create it in the existing table
		existingEntries[steamID64] = {
			Name = playerName or "Unknown",
			Reason = reason or "Unknown Source",
			Static = staticSource or false,
			Timestamp = os.time(),
		}
		return true, false, false, false, false, false
	end
end

-- Parses a single line from a raw list
-- Returns: steamID64 string or nil (Note: can return multiple if we refactor, but for now it's used line-by-line)
function Parsers.ParseRawLine(lineString)
	if not lineString then
		return nil
	end

	local trimmedLine = lineString:match("^%s*(.-)%s*$") or ""

	-- Skip comments, empty lines
	if trimmedLine == "" or trimmedLine:match("^%-%-") or trimmedLine:match("^#") or trimmedLine:match("^//") then
		return nil
	end

	-- Attempt to get SteamID64
	-- If the line contains multiple IDs, we just try the first one for now,
	-- but GetSteamID64 is robust enough to find it.
	local steamID64 = Parsers.GetSteamID64(trimmedLine)
	return steamID64
end

-- Parses a raw text file containing SteamIDs (one or more per line)
-- Returns: { [steamId64] = { Name="Unknown", Reason=cause, Static=sourceID }, ... } or nil, errorMsg
function Parsers.ParseRawIDs(contentString, cause, sourceID)
	local entries = {}
	if not contentString or contentString == "" then
		return entries -- Return empty table, not an error
	end

	local default_reason = cause or "Unknown Source"
	local lineCount = 0
	local addedCount = 0

	-- Iterate over each word (potential SteamID) in the content string
	-- This handles both line-separated and space-separated lists
	for word in contentString:gmatch("[%w%[%]:_]+") do
		local steamID64 = Parsers.GetSteamID64(word)
		if steamID64 then
			if not entries[steamID64] then -- Avoid duplicates within the same file
				entries[steamID64] = {
					Name = "Unknown", -- Raw lists usually don't have names
					Reason = default_reason,
					Static = sourceID or true,
				}
				addedCount = addedCount + 1
			end
		end
	end

	return entries, nil -- Return the table of entries
end

-- Parse TF2 Bot Detector JSON format and convert to our database format (Legacy shim, now uses chunked logic internally if called)
-- Returns: { [steamid64] = { Name="...", Reason="..." }, ... } or nil, errorMsg
function Parsers.ParseTF2BotDetector(contentString, defaultReason, existingEntries, sourceStats, staticSource)
	local players, err = Parsers.GetPlayersFromJSON(contentString)
	if not players then
		if sourceStats then
			sourceStats.errors = (sourceStats.errors or 0) + 1
		end
		return nil, err
	end

	local entries = existingEntries or {}
	local stats = {
		processed = 0,
		added = 0,
		existing = 0,
		updated = 0,
		errors = 0,
	}

	-- Process each player (Old synchronous behavior, but with the new merge logic)
	for i = 1, #players do
		stats.processed = stats.processed + 1
		local added, updated, errorOccurred =
			Parsers.ParseTF2BotDetector_MergeEntry(players[i], entries, staticSource, defaultReason)

		if errorOccurred then
			stats.errors = stats.errors + 1
		elseif added then
			stats.added = stats.added + 1
		elseif updated then
			stats.updated = stats.updated + 1
		else
			stats.existing = stats.existing + 1
		end
	end

	-- Update source stats if provided
	if sourceStats then
		sourceStats.processed = (sourceStats.processed or 0) + stats.processed
		sourceStats.added = (sourceStats.added or 0) + stats.added
		sourceStats.existing = (sourceStats.existing or 0) + stats.existing
		sourceStats.updated = (sourceStats.updated or 0) + stats.updated
		sourceStats.errors = (sourceStats.errors or 0) + stats.errors
	end

	return entries, nil, stats
end

return Parsers
