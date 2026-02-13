--[[ Command bridge ]]

local G = require("Cheater_Detection.Utils.Globals")
local Logger = require("Cheater_Detection.Utils.Logger")

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
		local shell = G.Menu and G.Menu.Misc and G.Menu.Misc.SteamHistory
		if not shell then
			Logger.Error("Commands", "SteamHistory menu state missing")
			return
		end

		local key = args and args[1] or nil
		if not key or key == "" then
			Logger.Warning("Commands", "Usage: steamhistory <api_key>")
			return
		end

		shell.ApiKey = key
		shell.Enable = false
		Logger.Info("Commands", "SteamHistory API key stored")
	end)
end

setupSteamHistory()

return Commands
