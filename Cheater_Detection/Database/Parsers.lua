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
	if not input then return nil end

	-- Optimization: Check if it's already a standard SteamID64 string (starts with 765, length ~17)
	local id_str = tostring(input):match("^%s*(765%d+)")
	if id_str and #id_str >= 17 then
		return id_str
	end

	-- Trim and handle standard SteamID formats
	id_str = tostring(input):match("^%s*(.-)%s*$")
	if not id_str or id_str == "" then return nil end

	-- Manual fallback for SteamID3 (common in community lists)
	local accountID = id_str:match("%[U:1:(%d+)%]")
	if accountID then
		accountID = tonumber(accountID)
		if accountID then
			return tostring(76561197960265728 + accountID)
		end
	end

	-- Expensive path: Only call engine/steam API if absolutely necessary
	if steam and steam.ToSteamID64 then
		local success, result = pcall(steam.ToSteamID64, id_str)
		if success and result then
			local result_str = tostring(result):match("(765%d+)")
			if result_str and #result_str >= 17 then
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

	local success, data = pcall(Json.decode, contentString)

	if not success then
		return nil, "JSON decode error: " .. tostring(data)
	end

	if type(data) ~= "table" then
		return nil, "JSON decode returned " .. type(data)
	end

	local players = data.players
	if not players then
		-- Fallback for root-level arrays
		if #data > 0 and data[1].steamid then
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
    if not player or type(player) ~= "table" then return false, false, true end

    -- Get the SteamID and convert to SteamID64
    local steamID64 = Parsers.GetSteamID64(player.steamid)
    if not steamID64 then return false, false, true end

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
    end

    -- Add to entries if not already there
    if existingEntries[steamID64] then
        -- "Stealer mode" - Update entry if it has better information
        local existingEntry = existingEntries[steamID64]
        local updated = false

        -- If existing entry has unknown name and this one has a name
        if (existingEntry.Name == "Unknown" or existingEntry.Name == nil)
            and playerName and playerName ~= "Unknown"
        then
            existingEntry.Name = playerName
            updated = true
        end

        -- If existing entry has unknown reason and this one has a reason
        if (existingEntry.Reason == "Unknown Source" or existingEntry.Reason == nil)
            and reason and reason ~= "Unknown Source"
        then
            existingEntry.Reason = reason
            updated = true
        end

        -- Mark as static if this is an external source
        if staticSource then
            -- FINAL SAFETY: Never store URLs
            if type(staticSource) == "string" and (staticSource:find("http") or #staticSource > 25) then
                staticSource = "Ext"
            end
            existingEntry.Static = staticSource
        end

        return false, updated, false
    else
        -- FINAL SAFETY: Never store URLs
        if type(staticSource) == "string" and (staticSource:find("http") or #staticSource > 25) then
            staticSource = "Ext"
        end
        existingEntries[steamID64] = {
            Name = playerName,
            Reason = reason,
            Static = staticSource or false
        }
        return true, false, false
    end
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
-- Returns: { [steamId64] = { Name="Unknown", Reason=cause, Static=sourceID }, ... } or nil, errorMsg
function Parsers.ParseRawIDs(contentString, cause, sourceID)
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
                    Static = sourceID or true
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
        if sourceStats then sourceStats.errors = (sourceStats.errors or 0) + 1 end
        return nil, err 
    end

	local entries = existingEntries or {}
	local stats = {
		processed = 0, added = 0, existing = 0, updated = 0, errors = 0,
	}

	-- Process each player (Old synchronous behavior, but with the new merge logic)
	for i = 1, #players do
		stats.processed = stats.processed + 1
		local added, updated, errorOccurred = Parsers.ParseTF2BotDetector_MergeEntry(players[i], entries, staticSource, defaultReason)
        
        if errorOccurred then stats.errors = stats.errors + 1
        elseif added then stats.added = stats.added + 1
        elseif updated then stats.updated = stats.updated + 1
        else stats.existing = stats.existing + 1 end
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
