--[[ Command bridge ]] 

local G = require("Cheater_Detection.Utils.Globals")
local Logger = require("Cheater_Detection.Utils.Logger")
local Common = require("Cheater_Detection.Utils.Common")

local lnxCommands = Common.Lib and Common.Lib.Utils and Common.Lib.Utils.Commands

local Commands = {}

local function ensureLnxCommands()
	if not lnxCommands then
		lnxCommands = Common.Lib and Common.Lib.Utils and Common.Lib.Utils.Commands
	end
	return lnxCommands
end

local function RegisterSteamHistory()
	local bridge = ensureLnxCommands()
	if not bridge or Commands._steamHistoryRegistered then
		return
	end

	Commands._steamHistoryRegistered = true
	bridge.Register("steamhistory", function(args)
		local shell = G.Menu and G.Menu.Misc and G.Menu.Misc.SteamHistory
		if not shell then
			Logger.Error("Commands", "SteamHistory menu state missing; config not initialised")
			return
		end

		local key = args and args:popFront() or nil
		if not key or key == "" then
			Logger.Warning("Commands", "Usage: steamhistory <api_key>")
			return
		end

		shell.ApiKey = key
		shell.Enable = false
		Logger.Info("Commands", "SteamHistory API key stored (scanning disabled until toggled)")
	end)
end

function Commands.Setup()
	if ensureLnxCommands() then
		RegisterSteamHistory()
	else
		Logger.Error("Commands", "lnxLib command subsystem unavailable; steam history command skipped")
	end
end

Commands.Setup()

return Commands
