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
function Parsers.AddSourceStats(sourceName, processed, added, existing, errors, updated)
	Parsers.ParseStats.sources[sourceName] = {
		processed = processed or 0,
		added = added or 0,
		existing = existing or 0,
		errors = errors or 0,
		updated = updated or 0,
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
			updatesInfo = string.format(", Updated: %d", stats.updated)
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
--[[ DEPRECATED: Printing is now handled by Fetcher using GetStatsSummary and Database.Log
function Parsers.PrintStatsSummary()
	print(Parsers.GetStatsSummary())
end
]]
-- Restore the function
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

-- Robust SteamID conversion function (moved from Fetcher)
-- Handles SteamID64, SteamID3 ([U:1:xxxx]), SteamID2 (STEAM_0:x:xxxx)
function Parsers.GetSteamID64(input)
	if not input then
		return nil
	end

	local id_str = tostring(input):match("^%s*(.-)%s*$") -- Trim
	if not id_str then
		return nil
	end

	-- 1. Check if it's a plain numeric ID that's in the valid SteamID64 range
	if id_str:match("^%d+$") then
		local num = tonumber(id_str)
		if num and num >= 76500000000000000 and num <= 77000000000000000 then
			return id_str
		end
	end

	-- 2. Validate against standard SteamID64 format
	if id_str:match("^7656119%d+$") and string.len(id_str) >= 17 then
		return id_str
	end

	-- 3. Try conversion using built-in function (handles SteamID2, SteamID3)
	local steamID64_from_pcall = nil
	if steam and steam.ToSteamID64 then -- Ensure steam API is available
		local success, result = pcall(steam.ToSteamID64, id_str)

		-- Check if pcall succeeded AND the result is usable (string or number)
		local result_str = nil
		if success and result then
			-- Convert to string if necessary
			if type(result) == "number" then
				result_str = tostring(result)
			elseif type(result) == "string" then
				result_str = result
			end

			-- If we got a usable string, trim and validate it
			if result_str then
				local trimmed_result = result_str:match("^%s*(.-)%s*$")

				-- Check if this is a valid SteamID64 by numeric range instead of strict pattern
				if trimmed_result and trimmed_result:match("^%d+$") then
					local num = tonumber(trimmed_result)
					if num and num >= 76561197960265728 and num <= 77000000000000000 then -- Corrected range
						return trimmed_result
					end
				end
			end
		else
			-- Debug print statement removed
			-- Log(LogLevel.DEBUG, "[PARSERS] steam API or steam.ToSteamID64 not available for conversion attempt")
		end
	else
		-- Debug print statement removed
		-- Log(LogLevel.DEBUG, "[PARSERS] steam API or steam.ToSteamID64 not available for conversion attempt")
	end

	-- If conversion via pcall was successful, return that result
	if steamID64_from_pcall then
		return steamID64_from_pcall
	end

	-- 4. Manual fallback for SteamID3 (only if steps 1 & 2 failed)
	local accountID = id_str:match("%[U:1:(%d+)%]")
	if accountID then
		accountID = tonumber(accountID)
		if accountID then
			local steamID64 = tostring(76561197960265728 + accountID)
			return steamID64
		end
	end

	-- 5. All attempts failed
	return nil
end

-- Parses a JSON string (specifically bots.tf format expected)
-- Returns: { players = { { steamid="...", attributes={...}, last_seen={player_name="..."} }, ... } } or nil, errorMsg
function Parsers.ParseJsonTF2DB(contentString)
	if not contentString or contentString == "" then
		return nil, "Empty content string"
	end

	-- Ensure the JSON decoder is available before calling pcall
	if not Json or type(Json.decode) ~= "function" then
		return nil, "JSON decode function is unavailable"
	end

	local success, data = pcall(Json.decode, contentString)

	if not success or type(data) ~= "table" then
		return nil, "JSON decode failed: " .. tostring(data)
	end

	if not data.players or type(data.players) ~= "table" then
		-- Allow if the root object itself is the list of players
		if type(data) == "table" and #data > 0 and type(data[1]) == "table" and data[1].steamid then
			return { players = data }, nil -- Wrap it for consistency
		end
		return nil, "JSON missing 'players' array"
	end

	return data, nil
end

-- Parses a single line from a raw list
-- Returns: steamID64 string or nil
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
	local steamID64 = Parsers.GetSteamID64(trimmedLine)
	return steamID64
end

-- Parses a raw text file containing one SteamID per line
-- Returns: { [steamId64] = { Name="Unknown", Reason=cause }, ... } or nil, errorMsg
function Parsers.ParseRawIDs(contentString, cause)
	local entries = {}
	if not contentString or contentString == "" then
		return entries -- Return empty table, not an error
	end

	local default_reason = cause or "Unknown Source"
	local lineCount = 0
	local addedCount = 0

	-- Iterate over each line in the content string
	for line in contentString:gmatch("[^\n\r]+") do
		lineCount = lineCount + 1
		local steamID64 = Parsers.ParseRawLine(line)
		if steamID64 then
			if not entries[steamID64] then -- Avoid duplicates within the same file
				entries[steamID64] = {
					Name = "Unknown", -- Raw lists usually don't have names
					Reason = default_reason,
				}
				addedCount = addedCount + 1
			end
		end
	end

	return entries, nil -- Return the table of entries
end

-- Parse TF2 Bot Detector JSON format and convert to our database format
-- Returns: { [steamid64] = { Name="...", Reason="..." }, ... } or nil, errorMsg
function Parsers.ParseTF2BotDetector(contentString, defaultReason, existingEntries, sourceStats)
	if not contentString or contentString == "" then
		if sourceStats then
			sourceStats.errors = (sourceStats.errors or 0) + 1
		end
		return nil, "Empty content string"
	end

	local entries = existingEntries or {}
	local stats = {
		processed = 0,
		added = 0,
		existing = 0,
		updated = 0, -- New field to track updated entries
		errors = 0,
	}

	-- Try to decode JSON
	-- Ensure the JSON decoder is available before calling pcall
	if not Json or type(Json.decode) ~= "function" then
		if sourceStats then
			sourceStats.errors = (sourceStats.errors or 0) + 1
		end
		return nil, "JSON decode function is unavailable"
	end

	local success, data = pcall(Json.decode, contentString)

	if not success or type(data) ~= "table" then
		if sourceStats then
			sourceStats.errors = (sourceStats.errors or 0) + 1
		end
		return nil, "JSON decode failed: " .. tostring(data)
	end

	-- Find the players array
	local players = data.players
	if not players then
		if sourceStats then
			sourceStats.errors = (sourceStats.errors or 0) + 1
		end
		return nil, "JSON missing 'players' array"
	end

	-- Process each player
	for _, player in ipairs(players) do
		stats.processed = stats.processed + 1

		-- Get the SteamID and convert to SteamID64
		local steamID64 = Parsers.GetSteamID64(player.steamid)
		if steamID64 then
			-- Determine player name (from last_seen if available)
			local playerName = "Unknown"
			if player.last_seen and player.last_seen.player_name then
				playerName = player.last_seen.player_name
			end

			-- Get the first attribute as the reason
			local reason = defaultReason or "Unknown Source"
			if player.attributes and #player.attributes > 0 then
				-- Use first attribute, capitalized
				local firstAttribute = player.attributes[1]
				reason = firstAttribute:gsub("^%l", string.upper) -- Capitalize first letter

				-- Only use default reason if no attributes available
				-- NOT overriding attribute with defaultReason anymore
			end

			-- Add to entries if not already there
			if entries[steamID64] then
				stats.existing = stats.existing + 1

				-- "Stealer mode" - Update entry if it has better information
				local existingEntry = entries[steamID64]
				local updated = false

				-- If existing entry has unknown name and this one has a name
				if
					(existingEntry.Name == "Unknown" or existingEntry.Name == nil)
					and playerName
					and playerName ~= "Unknown"
				then
					existingEntry.Name = playerName
					updated = true
				end

				-- If existing entry has unknown reason and this one has a reason
				if
					(existingEntry.Reason == "Unknown Source" or existingEntry.Reason == nil)
					and reason
					and reason ~= "Unknown Source"
				then
					existingEntry.Reason = reason
					updated = true
				end

				-- Increment update counter if we made changes
				if updated then
					stats.updated = stats.updated + 1
				end
			else
				entries[steamID64] = {
					Name = playerName,
					Reason = reason,
				}
				stats.added = stats.added + 1
			end
		else
			stats.errors = stats.errors + 1
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
