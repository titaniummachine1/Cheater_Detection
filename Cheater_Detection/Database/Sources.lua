-- Source definitions with safer processing options

--[[ Imports (None) ]]
-- No direct imports needed
-- [[ Imported by: Fetcher.lua ]]

--[[ Module Declaration ]]
local Sources = {}

--[[ Local Variables/Utilities ]]
-- List of available sources
Sources.List = {
	{
		name = "d3fc0n6 Cheater List",
		url = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
		cause = "Cheater Friend",
		parser = "raw",
	},
	{
		name = "d3fc0n6 Tacobot List",
		url = "https://raw.githubusercontent.com/d3fc0n6/TacobotList/master/64ids",
		cause = "Cheater Tacobot",
		parser = "raw",
	},
	{
		name = "d3fc0n6 Group List",
		url = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/Group/64ids",
		cause = "Suspected (Group Member)",
		parser = "raw",
	},
	{
		name = "Sleepy List RGL",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.rgl-gg.json",
		cause = "Sleepy RGL",
		parser = "tf2db",
	},
	{
		name = "bot detector (Official)",
		url = "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json",
		cause = "Bot (bot detector)",
		parser = "tf2db", -- Use tf2db parser for this JSON source
	},
	{
		name = "MegaScaterbomb (Scraped)",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/refs/heads/main/playerlist.megacheaterdb.json",
		cause = "Cheater (MegaScaterbomb)",
		parser = "tf2db", -- Use tf2db parser for this JSON source
	},
	{
		name = "qfoxb Player List",
		url = "https://raw.githubusercontent.com/qfoxb/tf2bd-lists/main/playerlist.qfoxb.json",
		cause = "TF2BD Community (qfoxb)",
		parser = "tf2db",
	},
	{
		name = "joekiller Player List",
		url = "https://raw.githubusercontent.com/joekiller/joekiller-list/main/playerlist.joekiller.json",
		cause = "TF2BD Community (joekiller)",
		parser = "tf2db",
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

	if parser ~= "raw" and parser ~= "tf2db" then
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

--[[ Self-Initialization (None) ]]

--[[ Callback Registration (None) ]]

return Sources
