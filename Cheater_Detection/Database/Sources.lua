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
		name = "Masterbase Broadcasts",
		url = "https://megaanticheat.com/broadcasts",
		cause = "Masterbase Broadcast Conviction",
		parser = "broadcasts",
		sourceID = "masterbase_broadcasts"
	},
	{
		name = "MegaScaterbomb",
		url =
		"https://raw.githubusercontent.com/ill5-com/megascatterbomb-tf2-cheater-database/main/megascatterbomb-tf2-cheater-database.min.json",
		cause = "Cheater (MegaScaterbomb)",
		parser = "ill5db",
		sourceID = "mega_scat"
	},
	{
		name = "d3fc0n6 Cheater List",
		url = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
		cause = "D3fc0n6 Cheater List",
		parser = "raw",
		sourceID = "d3_cheat",
		embedded = "d3fc0n6_embedded"
	},
	{
		name = "Sleepy Cheater List",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.sleepy.json",
		cause = "Sleepy Cheater List",
		parser = "tf2db",
		sourceID = "sleepy_main",
		embedded = "sleepy_main_embedded"
	},
	{
		name = "Sleepy External List",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.sleepy-external.json",
		cause = "Sleepy External",
		parser = "tf2db",
		sourceID = "sleepy_ext",
		embedded = "sleepy_ext_embedded"
	},
	{
		name = "Sleepy Nullc0re List",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.nullc0re.json",
		cause = "Sleepy Nullc0re",
		parser = "tf2db",
		sourceID = "sleepy_nullc0re",
		embedded = "sleepy_nullc0re_embedded"
	},
	{
		name = "TF2BD Official",
		url = "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json",
		cause = "TF2BD Official",
		parser = "tf2db",
		sourceID = "tf2bd_off",
		embedded = "tf2bd_official_embedded"
	},
	{
		name = "qfoxb Player List",
		url = "https://raw.githubusercontent.com/qfoxb/tf2bd-lists/main/playerlist.qfoxb.json",
		cause = "TF2BD Community (qfoxb)",
		parser = "tf2db",
		sourceID = "qfoxb",
		embedded = "qfoxb_embedded"
	},
	{
		name = "joekiller Player List",
		url = "https://raw.githubusercontent.com/joekiller/joekiller-list/main/playerlist.joekiller.json",
		cause = "TF2BD Community (joekiller)",
		parser = "tf2db",
		sourceID = "joekiller",
		embedded = "joekiller_embedded"
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

	if parser ~= "raw" and parser ~= "tf2db" and parser ~= "broadcasts" and parser ~= "ill5db" then
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

-- Get active sources (not disabled, not embedded)
function Sources.GetActiveSources()
	local active = {}
	for _, source in ipairs(Sources.List) do
		if not source.__disabled and not source.embedded then
			table.insert(active, source)
		end
	end
	return active
end

-- Get sources that have a local embedded Lua database
function Sources.GetEmbeddedSources()
	local embedded = {}
	for _, source in ipairs(Sources.List) do
		if source.embedded then
			table.insert(embedded, source)
		end
	end
	return embedded
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
