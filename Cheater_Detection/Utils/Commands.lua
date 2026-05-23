--[[ Command bridge ]]

local G = require("Cheater_Detection.Utils.Globals")
local ValveData = require("Cheater_Detection.data.valve_data")
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")
local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local SteamHistory = require("Cheater_Detection.Database.SteamHistory")
local Config = require("Cheater_Detection.Utils.Config")
local Common = require("Cheater_Detection.Utils.Common")

local Commands = {}
local registered = {}

function Commands.Register(name, callback)
	assert(type(name) == "string", "Commands.Register: name must be string")
	assert(type(callback) == "function", "Commands.Register: callback must be function")
	registered[name:lower()] = callback
end

local function onStringCmd(stringCmd)
	local raw = stringCmd:Get()
	if not raw or raw == "" then
		return
	end

	local parts = {}
	for word in raw:gmatch("%S+") do
		parts[#parts + 1] = word
	end

	local cmd = parts[1]
	if type(cmd) == "string" then
		cmd = cmd:lower()
	end

	if not cmd or not registered[cmd] then
		return
	end

	stringCmd:Set("")
	table.remove(parts, 1)
	registered[cmd](parts)
end

callbacks.Unregister("SendStringCmd", "CD_Commands")
callbacks.Register("SendStringCmd", "CD_Commands", onStringCmd)

local function setupSteamHistory()
	Commands.Register("steamhistory", function(args)
		G.Menu = G.Menu or {}
		G.Menu.Misc = G.Menu.Misc or {}
		G.Menu.Scanner = G.Menu.Scanner or {}
		G.Menu.Misc.SteamHistory = G.Menu.Misc.SteamHistory or {}
		local shell = G.Menu.Misc.SteamHistory

		local key = args and args[1] or nil
		if not key or key == "" then
			printc(255, 100, 100, 255, "[SteamHistory] Usage: steamhistory <api_key>")
			printc(255, 100, 100, 255, "[SteamHistory] Get your API key at: https://steamhistory.net/api")
			return
		end

		-- Validate key format (32 hex characters)
		-- Remove any whitespace that might have been copy-pasted
		key = key:gsub("%s", "")
		-- Check: exactly 32 hex characters (0-9, a-f, A-F)
		if #key ~= 32 or not key:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
			printc(255, 100, 100, 255, "[SteamHistory] Invalid API key format!")
			printc(255, 150, 100, 255, "[SteamHistory] Key must be 32 hexadecimal characters (0-9, a-f)")
			printc(200, 200, 200, 255, "[SteamHistory] Expected length: 32, got: " .. #key)
			printc(200, 200, 200, 255, "[SteamHistory] Get your API key at: https://steamhistory.net/api")
			return
		end
		-- Normalize to lowercase for storage
		key = key:lower()

		-- Validate key by making a test API call
		local testUrl = "https://steamhistory.net/api/sourcebans?key=" ..
			key .. "&shouldkey=0&steamids=76561197960287930"
		local valid = false
		local errMsg = nil

		-- Use pcall to handle any HTTP errors gracefully
		local ok, body = pcall(http.Get, testUrl)
		if not ok or type(body) ~= "string" or body == "" then
			errMsg = "API request failed (no response)"
		else
			-- Check for HTML error pages
			if body:match("^%s*<") or body:lower():find("<html", 1, true) then
				errMsg = "Invalid API key (authentication failed)"
			else
				-- Try to parse JSON
				local jsonOk, decoded = pcall(Common.Json.decode, body)
				if jsonOk and type(decoded) == "table" and decoded.response ~= nil then
					valid = true
				else
					errMsg = "Invalid API response (key may be invalid)"
				end
			end
		end

		if not valid then
			printc(255, 100, 100, 255, "[SteamHistory] API key validation failed!")
			printc(255, 150, 100, 255, "[SteamHistory] " .. tostring(errMsg or "Unknown error"))
			printc(200, 200, 200, 255, "[SteamHistory] Check your key at: https://steamhistory.net/api")
			return
		end

		shell.ApiKey = key
		shell.Enable = true -- Enable it automatically when key is set
		-- SteamHistory.IsEnabled() uses Scanner.SteamHistory as the runtime gate.
		G.Menu.Scanner.SteamHistory = true

		-- Force update in the module itself
		if SteamHistory and SteamHistory.OnApiKeyUpdated then
			SteamHistory.OnApiKeyUpdated()
		end

		-- Persist the change
		if Config and Config.CreateCFG then
			Config.CreateCFG()
		end

		printc(0, 255, 140, 255, "[SteamHistory] API key validated and stored!")
	end)

	Commands.Register("steamhistory_status", function(_args)
		local hasKey = SteamHistory and SteamHistory.HasKey and SteamHistory.HasKey() or false
		local enabled = SteamHistory and SteamHistory.IsEnabled and SteamHistory.IsEnabled() or false
		local tempDisabled = SteamHistory and SteamHistory.IsTemporarilyDisabled and SteamHistory.IsTemporarilyDisabled() or
			false

		printc(100, 220, 255, 255, "[SteamHistory] Status:")
		printc(200, 200, 200, 255, string.format("  hasKey           : %s", tostring(hasKey)))
		printc(200, 200, 200, 255,
			string.format("  scannerEnabled   : %s",
				tostring(G.Menu and G.Menu.Scanner and G.Menu.Scanner.SteamHistory == true)))
		printc(200, 200, 200, 255, string.format("  temporarilyOff   : %s", tostring(tempDisabled)))
		printc(200, 200, 200, 255, string.format("  effectiveEnabled : %s", tostring(enabled)))
	end)
end

setupSteamHistory()

local function setupDiagnostics()
	Commands.Register("valve_group_dump", function(_args)
		if SteamLookup and SteamLookup.DumpFetchedGroupIDs then
			SteamLookup.DumpFetchedGroupIDs(false)
		else
			printc(255, 100, 100, 255, "[SteamLookup] dump unavailable")
		end
	end)

	Commands.Register("valve_group_missing", function(_args)
		if SteamLookup and SteamLookup.DumpFetchedGroupIDs then
			SteamLookup.DumpFetchedGroupIDs(true)
		else
			printc(255, 100, 100, 255, "[SteamLookup] missing-dump unavailable")
		end
	end)

	Commands.Register("valve_group_status", function(_args)
		local fetched = (SteamLookup and SteamLookup.GetFetchedGroupIDs and SteamLookup.GetFetchedGroupIDs()) or {}
		local missing = (SteamLookup and SteamLookup.GetMissingFetchedIDs and SteamLookup.GetMissingFetchedIDs()) or {}
		local complete = SteamLookup and SteamLookup.IsGroupFetchComplete and SteamLookup.IsGroupFetchComplete()
		printc(100, 220, 255, 255, "[SteamLookup] Status:")
		printc(200, 200, 200, 255, string.format("  fetchComplete : %s", tostring(complete == true)))
		printc(200, 200, 200, 255, string.format("  fetchedIDs    : %d", #fetched))
		printc(200, 200, 200, 255, string.format("  missingStatic : %d", #missing))
		printc(200, 200, 200, 255, "  commands      : valve_group_dump / valve_group_missing")
	end)

	Commands.Register("cd_myid", function(_args)
		local localPlayer = entities.GetLocalPlayer()
		if not localPlayer then
			printc(255, 100, 100, 255, "[CD] Not in-game - no local player found")
			return
		end

		local idx = localPlayer:GetIndex()
		local info = client.GetPlayerInfo(idx)
		if not info then
			printc(255, 100, 100, 255, "[CD] GetPlayerInfo returned nil for local player")
			return
		end

		local steam2 = info.SteamID or "nil"
		local steam64 = steam.ToSteamID64 and steam.ToSteamID64(steam2) or "conversion unavailable"
		local userID = tostring(info.UserID)
		local isBot = tostring(info.IsBot)

		printc(100, 220, 255, 255, "[CD] Local player diagnostic:")
		printc(200, 200, 200, 255, string.format("  Steam2  : %s", steam2))
		printc(200, 200, 200, 255, string.format("  Steam64 : %s", tostring(steam64)))
		printc(200, 200, 200, 255, string.format("  UserID  : %s", userID))
		printc(200, 200, 200, 255, string.format("  IsBot   : %s", isBot))

		-- Check against both valve lists (same logic as valve_check layer 1)
		local idStr = tostring(steam64)
		local inValveData = ValveData.KnownSteamID64s[idStr] == true
		local inValveEmployees = type(ValveEmployees.List) == "table" and (ValveEmployees.List[idStr] ~= nil)

		local matchColor = (inValveData or inValveEmployees) and { 100, 255, 100, 255 } or { 255, 100, 100, 255 }
		printc(
			matchColor[1],
			matchColor[2],
			matchColor[3],
			matchColor[4],
			string.format("  valve_data.lua match    : %s", tostring(inValveData))
		)
		printc(
			matchColor[1],
			matchColor[2],
			matchColor[3],
			matchColor[4],
			string.format("  ValveEmployees.lua match: %s", tostring(inValveEmployees))
		)
		if not inValveData and not inValveEmployees then
			printc(255, 200, 100, 255, string.format('  !! Add "%s" to Database/ValveEmployees.lua', idStr))
		end
	end)
end

setupDiagnostics()

return Commands
