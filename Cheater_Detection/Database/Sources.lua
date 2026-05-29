-- Source definitions with safer processing options

--[[ Imports ]]
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")
-- [[ Imported by: Fetcher.lua ]]

--[[ Module Declaration ]]
local Sources = {}

--[[ Local Variables/Utilities ]]
-- List of online sources to fetch (embedded databases are loaded directly by Database.lua)
Sources.List = {
	{
		name = "Masterbase Broadcasts",
		url = "https://megaanticheat.com/broadcasts",
		cause = "Masterbase Broadcast Conviction",
		parser = "broadcasts",
		sourceID = "masterbase_broadcasts",
		weight = 78
	},
	-- wgetJane's Biglist (primary source - large, actively updated bot list)
	{
		name = "TF2BD Community Biglist",
		url = "https://gist.githubusercontent.com/wgetJane/0bc01bd46d7695362253c5a2fa49f2e9/raw/playerlist.biglist.json",
		cause = "Bot (TF2BD Community Biglist)",
		parser = "tf2db",
		sourceID = "cc_biglist",
		weight = 100
	},
	-- Curated by Trusted-role members of the official TF2BD Discord (high verification bar)
	{
		name = "TF2BD Community Trusted",
		url = "https://trusted.roto.lol/v1/steamids",
		cause = "Cheater (TF2BD Trusted)",
		parser = "tf2db",
		sourceID = "cc_trusted",
		weight = 80
	},
	-- qfoxb / joekiller: embedded via rebuild_embedded_databases.py (no live fetch — avoids overlay bloat)
}

--[[ Helper/Private Functions (None) ]]

--[[ Public Module Functions ]]
-- Function to add a custom source
function Sources.AddSource(name, url, cause, parser, sourceID)
	if not name or not url or not cause or not parser then
		print("[Database Fetcher] Error: Missing required fields for new source")
		return false
	end

	if parser ~= "raw" and parser ~= "tf2db" and parser ~= "broadcasts" then
		print("[Database Fetcher] Error: Invalid parser type: " .. parser)
		return false
	end

	table.insert(Sources.List, {
		name = name,
		url = url,
		cause = cause,
		parser = parser,
		sourceID = sourceID or nil,
	})

	print("[Database Fetcher] Added new source: " .. name)
	return true
end

-- Utility function to enable/disable sources (e.g. for testing)
function Sources.DisableSource(sourceIndex)
	if sourceIndex < 1 or sourceIndex > #Sources.List then
		print("[Database Fetcher] Invalid source index: " .. tostring(sourceIndex))
		return false
	end

	local source = Sources.List[sourceIndex]
	source.__disabled = true
	print("[Database Fetcher] Disabled source: " .. source.name)
	return true
end

-- Get active sources (not disabled)
function Sources.GetActiveSources()
	local active = {}
	for _, source in ipairs(Sources.List) do
		if not source.__disabled then
			table.insert(active, source)
		end
	end
	return active
end

-- Get Valve employee list from local database
function Sources.GetValveEmployees()
	return ValveEmployees.List
end

-- Check if SteamID is Valve employee
function Sources.IsValveEmployee(steamID)
	return ValveEmployees.IsValveEmployee(steamID)
end

--[[ Self-Initialization (None) ]]

--[[ Callback Registration (None) ]]

return Sources
