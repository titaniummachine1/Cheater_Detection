-- Source definitions with safer processing options

--[[ Imports ]]
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")
-- [[ Imported by: Fetcher.lua ]]

--[[ Module Declaration ]]
local Sources = {}

--[[ Local Variables/Utilities ]]
-- List of available sources
Sources.List = {
	{
		name = "d3fc0n6 Cheater List",
		url = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
		cause = "D3fc0n6 Cheater List",
		parser = "raw",
		sourceID = "d3_cheat"
	},
	{
		name = "Sleepy Cheater List",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.sleepy.json",
		cause = "Sleepy Cheater List",
		parser = "tf2db",
		sourceID = "sleepy_main"
	},
	{
		name = "Sleepy External List",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.sleepy-external.json",
		cause = "Sleepy External",
		parser = "tf2db",
		sourceID = "sleepy_ext"
	},
	{
		name = "Sleepy Nullc0re List",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.nullc0re.json",
		cause = "Sleepy Nullc0re",
		parser = "tf2db",
		sourceID = "sleepy_nullc0re"
	},
	{
		name = "TF2BD Official",
		url = "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json",
		cause = "TF2BD Official",
		parser = "tf2db",
		sourceID = "tf2bd_off"
	},
	{
		name = "MegaScaterbomb",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/refs/heads/main/playerlist.megacheaterdb.json",
		cause = "Cheater (MegaScaterbomb)",
		parser = "tf2db",
		sourceID = "mega_scat"
	},
	{
		name = "Masterbase Broadcasts",
		url = "https://masterbase.megascatterbomb.com/broadcasts",
		cause = "Masterbase Broadcast Conviction",
		parser = "broadcasts",
		sourceID = "masterbase_broadcasts"
	},
	{
		name = "qfoxb Player List",
		url = "https://raw.githubusercontent.com/qfoxb/tf2bd-lists/main/playerlist.qfoxb.json",
		cause = "TF2BD Community (qfoxb)",
		parser = "tf2db",
		sourceID = "qfoxb"
	},
	{
		name = "joekiller Player List",
		url = "https://raw.githubusercontent.com/joekiller/joekiller-list/main/playerlist.joekiller.json",
		cause = "TF2BD Community (joekiller)",
		parser = "tf2db",
		sourceID = "joekiller"
	},
}

--[[ Helper/Private Functions (None) ]]

--[[ Public Module Functions ]]
-- Function to add a custom source
function Sources.AddSource(name, url, cause, parser)
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
	for i, source in ipairs(Sources.List) do
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
