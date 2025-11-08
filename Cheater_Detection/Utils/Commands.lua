--[[
    Simple Commands Utility
    Provides command registration with automatic overwrite
]]

local Commands = {}

local G = require("Cheater_Detection.Utils.Globals")
local Logger = require("Cheater_Detection.Utils.Logger")

-- Store registered commands
Commands.registered = {}

-- Register a command (always overwrite existing)
function Commands.Register(name, callback, helpText)
	-- Register the command, overriding any existing one
	Commands.registered[name] = {
		callback = callback,
		helpText = helpText or "No description available",
	}

	-- Register with the engine
	client.Command_Register(name, function(args)
		local cmd = Commands.registered[name]
		if cmd and type(cmd.callback) == "function" then
			cmd.callback(args)
		end
	end)
end

Commands.Register(
	"steamhistory",
	function(args)
		local shell = G.Menu and G.Menu.Misc and G.Menu.Misc.SteamHistory
		if not shell then
			Logger.Error("Commands", "SteamHistory config not initialised (G.Menu.Misc missing)")
			return
		end

		local key = args and args[1] or nil
		if not key or key == "" then
			Logger.Warning("Commands", "Usage: steamhistory <api_key>")
			return
		end

		shell.ApiKey = key
		Logger.Info("Commands", "SteamHistory API key updated")
	end,
	"Update SteamHistory API key"
)

-- Unregister a command
function Commands.Unregister(name)
	if Commands.registered[name] then
		client.Command_Unregister(name)
		Commands.registered[name] = nil
		return true
	end
	return false
end

-- Get help text for a command
function Commands.GetHelp(name)
	local cmd = Commands.registered[name]
	return cmd and cmd.helpText or "Command not found"
end

-- List all registered commands
function Commands.List()
	local result = {}
	for name, _ in pairs(Commands.registered) do
		table.insert(result, name)
	end
	return result
end

return Commands
