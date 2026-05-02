--[[ services/steam_lookup.lua
     Handles external Steam API lookups (Valve Group, Bans, etc.)
]]

local Events = require("Cheater_Detection.Core.Events")
local ValveData = require("Cheater_Detection.data.valve_data")
local Constants = require("Cheater_Detection.Core.constants")

local HttpQueue = require("Cheater_Detection.services.http_queue")

local SteamLookup = {}

local autoFetchedID64s = {} -- s64 string -> true
local fetchState = {
	done = false,
	inProgress = false,
	nextPage = 1,
	totalFetched = 0,
	cooldownUntil = 0,
}
local MAX_FETCH_PAGES = 3

--- Parse <steamID64> tags from Valve Group XML (stores as s64 string)
local function parseGroupXML(xml)
	if not xml or #xml == 0 then
		return 0
	end
	local count = 0
	for s64 in xml:gmatch("<steamID64>(%d+)</steamID64>") do
		if not autoFetchedID64s[s64] then
			autoFetchedID64s[s64] = true
			count = count + 1
		end
	end
	return count
end

--- Tick one page of Valve group fetching (call from scheduler, paced with 3s gaps)
function SteamLookup.TickGroupFetch()
	if fetchState.done or fetchState.inProgress then
		return
	end

	local now = globals.RealTime()
	if now < fetchState.cooldownUntil then
		return
	end

	if fetchState.nextPage > MAX_FETCH_PAGES then
		fetchState.done = true
		print(string.format("[SteamLookup] Group fetch done: %d IDs loaded.", fetchState.totalFetched))
		return
	end

	fetchState.inProgress = true
	local page = fetchState.nextPage
	local url = "https://steamcommunity.com/gid/" .. ValveData.GroupID .. "/memberslistxml/?xml=1&p=" .. page

	local enqueued = HttpQueue.Enqueue(url, function(data)
		local found = parseGroupXML(data or "")
		fetchState.totalFetched = fetchState.totalFetched + found
		fetchState.nextPage = page + 1
		fetchState.inProgress = false
		fetchState.cooldownUntil = globals.RealTime() + 3.0
		print(string.format("[SteamLookup] Page %d: +%d Valve group IDs", page, found))
	end, nil, { noDelay = true, highPriority = true })

	if not enqueued then
		fetchState.inProgress = false
		fetchState.cooldownUntil = globals.RealTime() + 0.25
	end
end

--- Kick off the group fetch on startup
function SteamLookup.RefreshValveGroup()
	fetchState.done = false
	fetchState.inProgress = false
	fetchState.nextPage = 1
	fetchState.totalFetched = 0
	fetchState.cooldownUntil = 0
	SteamLookup.TickGroupFetch()
end

--- Check if a SteamID64 was fetched from the Valve Steam Group
function SteamLookup.IsGroupMemberID64(s64)
	return autoFetchedID64s[tostring(s64)] == true
end

--- True once all configured Valve group pages have been fetched.
function SteamLookup.IsGroupFetchComplete()
	return fetchState.done == true
end

--- Check if a Steam2 ID is in the manual Valve list (legacy)
function SteamLookup.IsValveID(s2)
	return ValveData.ManualIDsSteam2 and ValveData.ManualIDsSteam2[s2] or false
end

--- Async profile check for specific group membership or bans
function SteamLookup.CheckProfileAsync(steamID64, callback)
	local url = "https://steamcommunity.com/profiles/" .. steamID64 .. "/?xml=1"
	local enqueued = HttpQueue.Enqueue(url, function(data)
		if type(callback) ~= "function" then
			print("[SteamLookup] CheckProfileAsync called without valid callback")
			return
		end

		if not data or data == "" then
			print(string.format("[SteamLookup] Empty profile response for %s", tostring(steamID64)))
			callback(nil)
			return
		end

		if type(data) ~= "string" then
			print(
				string.format("[SteamLookup] Invalid profile response type for %s: %s", tostring(steamID64), type(data))
			)
			callback(nil)
			return
		end

		if data:find("<html", 1, true) or data:find("<title", 1, true) then
			print(string.format("[SteamLookup] HTML/error profile response for %s", tostring(steamID64)))
			callback(nil)
			return
		end

		local result = {
			isValve = data:find(ValveData.GroupID, 1, true) ~= nil,
			vacBanned = data:find("<vacBanned>1</vacBanned>", 1, true) ~= nil,
			tradeBanned = data:find("<tradeBanState>Banned</tradeBanState>", 1, true) ~= nil,
		}

		callback(result)
	end, nil, { noDelay = true, highPriority = true })

	if not enqueued and type(callback) == "function" then
		callback(nil)
	end
end

return SteamLookup
