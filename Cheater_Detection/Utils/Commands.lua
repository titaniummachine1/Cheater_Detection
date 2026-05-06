--[[ Command bridge ]]

local G = require("Cheater_Detection.Utils.Globals")
local ValveData = require("Cheater_Detection.data.valve_data")
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")
local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local SteamHistory = require("Cheater_Detection.Database.SteamHistory")
local MAC = require("Cheater_Detection.Database.MAC")
local Config = require("Cheater_Detection.Utils.Config")

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
			printc(255, 100, 100, 255, "[SteamHistory] Get your key at: https://steamhistory.net")
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

		printc(0, 255, 140, 255, "[SteamHistory] API key stored and module enabled!")
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

local function setupMAC()
	local function setMacApiKey(key)
		G.Menu = G.Menu or {}
		G.Menu.Scanner = G.Menu.Scanner or {}
		G.Menu.Misc = G.Menu.Misc or {}
		G.Menu.Misc.MAC = G.Menu.Misc.MAC or {}

		if type(key) == "string" then
			key = key:match("^%s*(.-)%s*$")
		end
		if not key or key == "" then
			printc(255, 100, 100, 255, "[MAC] Usage: mac_key <api_key>")
			return
		end

		G.Menu.Scanner.MAC = true
		local ok, err = MAC.SetApiKey(key)
		if not ok then
			printc(255, 100, 100, 255, "[MAC] Invalid API key: " .. tostring(err))
			return
		end

		if Config and Config.CreateCFG then
			Config.CreateCFG()
		end

		printc(0, 255, 140, 255, "[MAC] API key stored and scanner enabled")
	end

	Commands.Register("mac", function(args)
		local key = args and args[1] or nil
		G.Menu = G.Menu or {}
		G.Menu.Scanner = G.Menu.Scanner or {}
		G.Menu.Misc = G.Menu.Misc or {}
		G.Menu.Misc.MAC = G.Menu.Misc.MAC or {}

		if type(key) == "string" then
			key = key:match("^%s*(.-)%s*$")
		end

		if key == "off" or key == "disable" then
			G.Menu.Scanner.MAC = false
			if Config and Config.CreateCFG then
				Config.CreateCFG()
			end
			printc(200, 200, 200, 255, "[MAC] Scanner disabled")
			return
		end

		if key == "clear" or key == "none" or key == "nokey" then
			G.Menu.Scanner.MAC = true
			if MAC and MAC.ClearApiKey then
				MAC.ClearApiKey()
			end
			if Config and Config.CreateCFG then
				Config.CreateCFG()
			end
			printc(0, 255, 140, 255, "[MAC] API key cleared; scanner enabled in no-key mode")
			return
		end

		if not key or key == "" then
			G.Menu.Scanner.MAC = true
			if MAC and MAC.ClearApiKey then
				MAC.ClearApiKey()
			end
			if Config and Config.CreateCFG then
				Config.CreateCFG()
			end
			printc(0, 255, 140, 255, "[MAC] Scanner enabled (no API key mode)")
			printc(200, 200, 200, 255, "[MAC] Public cheater lists come from Auto-Sync Databases")
			printc(100, 220, 255, 255, "[MAC] Optional: mac <api_key> to set key, mac clear to remove key")
			return
		end

		G.Menu.Scanner.MAC = true

		local ok, err = MAC.SetApiKey(key)
		if not ok then
			printc(255, 100, 100, 255, "[MAC] Invalid API key: " .. tostring(err))
			return
		end

		if Config and Config.CreateCFG then
			Config.CreateCFG()
		end

		printc(0, 255, 140, 255, "[MAC] API key stored and scanner enabled")
	end)

	Commands.Register("mac_key", function(args)
		setMacApiKey(args and args[1] or nil)
	end)

	Commands.Register("mb", function(args)
		setMacApiKey(args and args[1] or nil)
	end)

	Commands.Register("mac_url", function(args)
		local url = args and args[1] or nil
		if not url or url == "" then
			local currentURL = MAC and MAC.GetBaseURL and MAC.GetBaseURL() or "unknown"
			printc(100, 220, 255, 255, "[MAC] Usage: mac_url <base_url>")
			printc(255, 200, 120, 255, "[MAC] Endpoint should expose mac/user/v1 (client-backend API)")
			printc(200, 200, 200, 255, "[MAC] Current URL: " .. tostring(currentURL))
			return
		end

		G.Menu = G.Menu or {}
		G.Menu.Scanner = G.Menu.Scanner or {}
		G.Menu.Scanner.MAC = true
		G.Menu.Misc = G.Menu.Misc or {}
		G.Menu.Misc.MAC = G.Menu.Misc.MAC or {}

		local ok, err = MAC.SetBaseURL(url)
		if not ok then
			printc(255, 100, 100, 255, "[MAC] Invalid URL: " .. tostring(err))
			return
		end

		if Config and Config.CreateCFG then
			Config.CreateCFG()
		end

		printc(0, 255, 140, 255, "[MAC] URL stored and scanner enabled: " .. tostring(MAC.GetBaseURL()))
	end)

	Commands.Register("mac_status", function(_args)
		local scannerEnabled = G.Menu and G.Menu.Scanner and G.Menu.Scanner.MAC == true
		local baseURL = MAC and MAC.GetBaseURL and MAC.GetBaseURL() or "unknown"
		local apiKey = MAC and MAC.GetApiKey and MAC.GetApiKey() or nil
		local status = MAC and MAC.GetStatusText and MAC.GetStatusText() or "MAC unavailable"

		printc(100, 220, 255, 255, "[MAC] Status:")
		printc(200, 200, 200, 255, string.format("  scannerEnabled : %s", tostring(scannerEnabled)))
		printc(200, 200, 200, 255, string.format("  baseURL        : %s", tostring(baseURL)))
		printc(200, 200, 200, 255,
			string.format("  hasApiKey      : %s", tostring(type(apiKey) == "string" and apiKey ~= "")))
		printc(200, 200, 200, 255, string.format("  moduleStatus   : %s", tostring(status)))
	end)

	Commands.Register("mac_rescan", function(_args)
		if MAC and MAC.QueueRescan then
			MAC.QueueRescan()
			printc(0, 200, 255, 255, "[MAC] Rescan queued")
		end
	end)
end

setupMAC()

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
