--[[ Command bridge ]]

local G = require("Cheater_Detection.Utils.Globals")
local Logger = require("Cheater_Detection.Utils.Logger")
local ValveData = require("Cheater_Detection.data.valve_data")
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")

local Commands = {}
local registered = {}

function Commands.Register(name, callback)
	assert(type(name) == "string", "Commands.Register: name must be string")
	assert(type(callback) == "function", "Commands.Register: callback must be function")
	registered[name] = callback
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
        
		-- Force update in the module itself
		local SteamHistory = require("Cheater_Detection.Database.SteamHistory")
		if SteamHistory and SteamHistory.OnApiKeyUpdated then
			SteamHistory.OnApiKeyUpdated()
		end

        -- Persist the change
        local Config = require("Cheater_Detection.Utils.Config")
        if Config and Config.CreateCFG then
            Config.CreateCFG()
        end

		printc(0, 255, 140, 255, "[SteamHistory] API key stored and module enabled!")
	end)
end

setupSteamHistory()

local function setupDiagnostics()
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

		local steam2  = info.SteamID or "nil"
		local steam64 = steam.ToSteamID64 and steam.ToSteamID64(steam2) or "conversion unavailable"
		local userID  = tostring(info.UserID)
		local isBot   = tostring(info.IsBot)

		printc(100, 220, 255, 255, "[CD] Local player diagnostic:")
		printc(200, 200, 200, 255, string.format("  Steam2  : %s", steam2))
		printc(200, 200, 200, 255, string.format("  Steam64 : %s", tostring(steam64)))
		printc(200, 200, 200, 255, string.format("  UserID  : %s", userID))
		printc(200, 200, 200, 255, string.format("  IsBot   : %s", isBot))

		-- Check against both valve lists (same logic as valve_check layer 1)
		local idStr = tostring(steam64)
		local inValveData     = ValveData.KnownSteamID64s[idStr] == true
		local inValveEmployees = type(ValveEmployees.List) == "table" and (ValveEmployees.List[idStr] ~= nil)

		local matchColor = (inValveData or inValveEmployees) and {100, 255, 100, 255} or {255, 100, 100, 255}
		printc(matchColor[1], matchColor[2], matchColor[3], matchColor[4], string.format(
			"  valve_data.lua match    : %s",    tostring(inValveData)
		))
		printc(matchColor[1], matchColor[2], matchColor[3], matchColor[4], string.format(
			"  ValveEmployees.lua match: %s",    tostring(inValveEmployees)
		))
		if not inValveData and not inValveEmployees then
			printc(255, 200, 100, 255, string.format(
				"  !! Add \"%s\" to Database/ValveEmployees.lua", idStr
			))
		end
	end)
end

setupDiagnostics()

return Commands
