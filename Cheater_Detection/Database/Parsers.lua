local Common = require("Cheater_Detection.Utils.Common")
local Json = Common.Json

local Parsers = {}

-- Robust SteamID conversion function (moved from Fetcher)
-- Handles SteamID64, SteamID3 ([U:1:xxxx]), SteamID2 (STEAM_0:x:xxxx)
function Parsers.GetSteamID64(input)
	if not input then
		return nil
	end

	local id_str = tostring(input):match("^%s*(.-)%s*$") -- Trim
	print(string.format("[Parser GetSteamID64 DBG] Input: '%s', Trimmed: '%s'", tostring(input), id_str)) -- ++DEBUG
	if not id_str then
		return nil
	end

	-- 1. Check if it's a plain numeric ID that's in the valid SteamID64 range
	if id_str:match("^%d+$") then
		local num = tonumber(id_str)
		if num and num >= 76500000000000000 and num <= 77000000000000000 then
			print("[Parser GetSteamID64 DBG] Valid numeric SteamID64 detected directly.") -- ++DEBUG
			return id_str
		end
	end

	-- 2. Validate against standard SteamID64 format
	if id_str:match("^7656119%d+$") and string.len(id_str) >= 17 then
		print("[Parser GetSteamID64 DBG] Matched SteamID64 format directly.") -- ++DEBUG
		return id_str
	end

	-- 3. Try conversion using built-in function (handles SteamID2, SteamID3)
	local steamID64_from_pcall = nil
	if steam and steam.ToSteamID64 then -- Ensure steam API is available
		local success, result = pcall(steam.ToSteamID64, id_str)
		print(
			string.format(
				"[Parser GetSteamID64 DBG] pcall(steam.ToSteamID64) success: %s, result: %s",
				tostring(success),
				tostring(result)
			)
		) -- ++DEBUG
		print(string.format("[Parser GetSteamID64 DBG] Type of pcall result: %s", type(result))) -- ++DEBUG

		-- Check if pcall succeeded AND the result is usable (string or number)
		local result_str = nil
		if success and result then
			-- Convert to string if necessary
			if type(result) == "number" then
				result_str = tostring(result)
				print("[Parser GetSteamID64 DBG] Converted number result to string.") -- ++DEBUG
			elseif type(result) == "string" then
				result_str = result
			else
				print("[Parser GetSteamID64 DBG] pcall result type was unexpected: " .. type(result)) -- ++DEBUG
				-- result_str remains nil
			end

			-- If we got a usable string, trim and validate it
			if result_str then
				local trimmed_result = result_str:match("^%s*(.-)%s*$")
				print(
					string.format(
						"[Parser GetSteamID64 DBG] Trimmed pcall result string for matching: '%s'",
						trimmed_result
					)
				) -- ++DEBUG

				-- Check if this is a valid SteamID64 by numeric range instead of strict pattern
				if trimmed_result and trimmed_result:match("^%d+$") then
					local num = tonumber(trimmed_result)
					if num and num >= 76500000000000000 and num <= 77000000000000000 then
						print("[Parser GetSteamID64 DBG] Valid SteamID64 range detected from pcall result.") -- ++DEBUG
						return trimmed_result
					else
						print("[Parser GetSteamID64 DBG] Numeric result from pcall not in valid SteamID64 range.") -- ++DEBUG
					end
				else
					print("[Parser GetSteamID64 DBG] Trimmed pcall result not a valid numeric string.") -- ++DEBUG
				end
			end
		else
			print("[Parser GetSteamID64 DBG] pcall failed or result was nil.") -- ++DEBUG
		end
	else
		print("[Parser GetSteamID64 DBG] steam or steam.ToSteamID64 not available.") -- ++DEBUG
	end

	-- If conversion via pcall was successful, return that result
	if steamID64_from_pcall then
		return steamID64_from_pcall
	end

	-- 4. Manual fallback for SteamID3 (only if steps 1 & 2 failed)
	print("[Parser GetSteamID64 DBG] Proceeding to manual SteamID3 check...") -- ++DEBUG
	local accountID = id_str:match("%[U:1:(%d+)%]")
	print(string.format("[Parser GetSteamID64 DBG] Manual SteamID3 match result: %s", tostring(accountID))) -- ++DEBUG
	if accountID then
		accountID = tonumber(accountID)
		if accountID then
			local steamID64 = tostring(76561197960265728 + accountID)
			print(string.format("[Parser GetSteamID64 DBG] Manual SteamID3 calculated: %s", steamID64)) -- ++DEBUG
			return steamID64
		end
	end

	-- 5. All attempts failed
	print("[Parser GetSteamID64 DBG] Failed all conversion attempts.") -- ++DEBUG
	return nil
end

-- Parses a JSON string (specifically bots.tf format expected)
-- Returns: { players = { { steamid="...", attributes={...}, last_seen={player_name="..."} }, ... } } or nil, errorMsg
function Parsers.ParseJsonTF2DB(contentString)
	if not contentString or contentString == "" then
		return nil, "Empty content string"
	end

	-- print("[Parser DBG] Attempting JSON decode...")
	local success, data = pcall(Json.decode, contentString)

	if not success or type(data) ~= "table" then
		-- print(string.format("[Parser ERR] JSON decode failed: %s", tostring(data)))
		return nil, "JSON decode failed: " .. tostring(data)
	end

	-- Validate structure (very basic check for players list)
	if data.players and type(data.players) == "table" then
		print(string.format("[Parser ParseJsonTF2DB DBG] Found %d players in data.players table.", #data.players)) -- ++DEBUG
	else
		print("[Parser ParseJsonTF2DB DBG] data.players field not found or not a table.") -- ++DEBUG
	end

	if not data.players or type(data.players) ~= "table" then
		-- Allow if the root object itself is the list of players
		if type(data) == "table" and #data > 0 and type(data[1]) == "table" and data[1].steamid then
			-- print("[Parser DBG] JSON data is array of players at root.")
			return { players = data }, nil -- Wrap it for consistency
		end
		-- print("[Parser ERR] JSON missing 'players' array.")
		return nil, "JSON missing 'players' array"
	end

	-- print("[Parser DBG] JSON decode successful.")
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
	print(
		string.format(
			"[Parser ParseRawLine DBG] Input line: '%s', Result steamID64: %s",
			lineString,
			tostring(steamID64)
		)
	) -- ++DEBUG
	return steamID64
end

-- Parses a raw text file containing one SteamID per line
-- Returns: { [steamId64] = { Name="Unknown", Reason=cause }, ... } or nil, errorMsg
function Parsers.ParseRawIDs(contentString, cause)
	local entries = {}
	if not contentString or contentString == "" then
		print("[Parser WRN] ParseRawIDs received empty content.") -- ++DEBUG
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

	print(
		string.format("[Parser DBG] ParseRawIDs processed %d lines, added %d unique SteamIDs.", lineCount, addedCount)
	) -- ++DEBUG
	return entries, nil -- Return the table of entries
end

return Parsers
