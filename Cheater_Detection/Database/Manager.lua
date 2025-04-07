--[[ 
    Database Manager module - Centralized control of database operations
]]

-- Import required components
local Common = require("Cheater_Detection.Utils.Common")
local Commands = Common.Lib.Utils.Commands
local Database = require("Cheater_Detection.Database.Database") -- Require at top level
local Fetcher = require("Cheater_Detection.Database.Database_Fetcher") -- Require at top level

-- Create the Manager object
local Manager = {
	-- Configuration options
	Config = {
		AutoFetchOnLoad = true, -- Auto fetch database updates on script load
		CheckInterval = 24, -- Hours between auto updates
		LastCheck = 0, -- Timestamp of last update check
		MaxEntries = 20000, -- Maximum number of database entries
	},
}

-- Modified initialize function to use correct load and fetch functions
function Manager.Initialize(options)
	-- Apply any provided options
	if options then
		for k, v in pairs(options) do
			Manager.Config[k] = v
		end
	end

	-- Auto fetch if enabled
	if Manager.Config.AutoFetchOnLoad then
		-- Schedule update for next frame to avoid initialization issues
		callbacks.Register("Draw", "CDDatabaseManager_InitialUpdate", function()
			callbacks.Unregister("Draw", "CDDatabaseManager_InitialUpdate")

			printc(100, 200, 255, 255, "[Database Manager] Triggering AutoFetch...")
			Fetcher.StartFetch(Database, function(added)
				if added > 0 then
					printc(80, 200, 120, 255, "[Database Manager] Initial fetch added " .. added .. " entries.")
				else
					print("[Database Manager] Initial fetch complete, no new entries.")
				end
			end, true) -- Use StartFetch, run silently
		end)
	end

	-- Return the database module itself
	return Database
end

-- Force an immediate database update
function Manager.UpdateDatabase()
	print("[Database Manager] Starting manual database update...")
	return Fetcher.StartFetch(Database, function(added) -- Use StartFetch
		print("[Database Manager] Manual update complete. Added " .. added .. " entries.")
	end, false) -- Run with UI progress shown
end

-- Get database stats
function Manager.GetStats()
	return Database.GetStats()
end

return Manager
