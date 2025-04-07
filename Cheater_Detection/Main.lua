--[[
    Cheater Detection for Lmaobox Recode
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credits:
    LNX (github.com/lnx00) for base script
    Muqa for visuals and design assistance
    Alchemist for testing and party callout
]]

--[[ Import core utilities ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Config = require("Cheater_Detection.Utils.Config")

--[[ Import database system ]]
local DBManager = require("Cheater_Detection.Database.Manager")

--[[ UI components ]]
require("Cheater_Detection.Misc.Visuals.Menu")

--[[ Detection modules (uncomment when needed) ]]
--local Detections = require("Cheater_Detection.Detections")
--require("Cheater_Detection.Visuals")
--require("Cheater_Detection.Modules.EventHandler")

--[[ Variables ]]
local WPlayer, PR = Common.WPlayer, Common.PlayerResource
local Commands = Common.Lib.Utils.Commands

--[[ Initialize systems ]]
local function InitializeSystems()
	-- Load config
	Config.LoadCFG()

	-- Initialize database system through manager (this handles loading, importing and auto-fetching)
	G.Database = DBManager.Initialize({ -- DBManager.Initialize now returns the Database module itself
		AutoFetchOnLoad = true, -- Automatically fetch updates on startup
		CheckInterval = 24, -- Check for updates every 24 hours
	})

	-- Clear local player from cheater list (for debugging)
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer then
		local mySteamID = Common.GetSteamID64(localPlayer)
		pcall(playerlist.SetPriority, mySteamID, 0) -- Use pcall for safety
	end

	-- Print initialization message
	local dbStats = DBManager.GetStats()
	-- Check entryCount instead of totalEntries
	if not dbStats or not dbStats.entryCount or dbStats.entryCount == 0 then
		printc(255, 100, 100, 255, "[Cheater Detection] No database entries found. Please update the database.")
	else
		printc(
			100,
			255,
			100,
			255,
			string.format("[Cheater Detection] Initialized with %d database entries", dbStats.entryCount)
		)
	end

	-- Register console commands for database management
	Commands.Register("cd_check", function(args)
		if #args < 1 then
			print("Usage: cd_check <steamid or name fragment>")
			return
		end

		local query = args[1]
		local found = false

		-- Check if it's a valid SteamID
		if query:match("^%d+$") and #query >= 17 then
			-- Access Database module directly via G.Database
			local record = G.Database.GetRecord(query)
			if record then
				found = true
				print(string.format("[Database] Found record for SteamID: %s", query))
				print(string.format("  Name: %s", record.Name or "Unknown"))
				print(string.format("  Reason: %s", record.Reason or "Unknown")) -- Use Reason
				-- print(string.format("  Date: %s", record.date or "Unknown")) -- Date is not stored
			end
		end

		-- If not found by SteamID, search by name
		if not found then
			local matches = 0
			for steamId, data in pairs(G.Database.data or {}) do -- Iterate over G.Database.data
				if data.Name and data.Name:lower():find(query:lower()) then
					matches = matches + 1
					print(string.format("[Database] Match %d: %s (SteamID: %s)", matches, data.Name, steamId))
					print(string.format("  Reason: %s", data.Reason or "Unknown")) -- Use Reason
					-- print(string.format("  Date: %s", data.date or "Unknown")) -- Date is not stored

					-- Limit to 5 matches to avoid spam
					if matches >= 5 then
						print(string.format("[Database] Found more matches, showing first 5 only"))
						break
					end
				end
			end

			if matches == 0 then
				print(string.format("[Database] No records found for: %s", query))
			end
		end
	end, "Check if a player is in the cheat database")
end

--[[ Update the player data every tick ]]
--
local function OnCreateMove(cmd)
	local DebugMode = G.Menu.Main.debug
	G.pLocal = entities.GetLocalPlayer()
	G.players = entities.FindByClass("CTFPlayer")
	if not G.pLocal or not G.players then
		return
	end

	G.WLocal = WPlayer.FromEntity(G.pLocal)
	G.connectionState = PR.GetConnectionState()[G.pLocal:GetIndex()]

	for _, entity in ipairs(G.players) do
		-- Get the steamid for the player
		local steamid = Common.GetSteamID64(entity)
		if not steamid then
			warn("Failed to get SteamID for player %s", entity:GetName() or "nil")
			return
		end

		-- Check if player is a known cheater in database
		if G.Database and G.Database.GetRecord(steamid) then
			-- Player is in database, mark them
			local priority = playerlist.GetPriority(steamid)
			if priority < 10 then
				playerlist.SetPriority(steamid, 10)
			end
			-- Skip detection checks for known cheaters
			goto continue
		end

		if Common.IsValidPlayer(entity, true) and not Common.IsCheater(steamid) then
			-- Initialize player data if it doesn't exist
			if not G.PlayerData[steamid] then
				G.PlayerData[steamid] = G.DefaultPlayerData
			end

			local wrappedPlayer = WPlayer.FromEntity(entity)
			local viewAngles = wrappedPlayer:GetEyeAngles()
			local entityFlags = entity:GetPropInt("m_fFlags")
			local isOnGround = entityFlags & FL_ONGROUND == FL_ONGROUND
			local headHitboxPosition = wrappedPlayer:GetHitboxPos(1)
			local bodyHitboxPosition = wrappedPlayer:GetHitboxPos(4)
			local viewPos = wrappedPlayer:GetEyePos()
			local simulationTime = wrappedPlayer:GetSimulationTime()

			-- Gather player data
			G.PlayerData[steamid].Current = Common.createRecord(
				viewAngles,
				viewPos,
				headHitboxPosition,
				bodyHitboxPosition,
				simulationTime,
				isOnGround
			)

			-- Perform detection checks (when Detections module is enabled)
			if Detections then
				Detections.CheckAngles(wrappedPlayer, entity)
				Detections.CheckDuckSpeed(wrappedPlayer, entity)
				Detections.CheckBunnyHop(wrappedPlayer, entity)
				Detections.CheckPacketChoke(wrappedPlayer, entity)
				Detections.CheckSequenceBurst(wrappedPlayer, entity)
			end

			-- Update history
			G.PlayerData[steamid].History = G.PlayerData[steamid].History or {}
			table.insert(G.PlayerData[steamid].History, G.PlayerData[steamid].Current)

			-- Keep the history table size to a maximum of 66
			if #G.PlayerData[steamid].History > 66 then
				table.remove(G.PlayerData[steamid].History, 1)
			end
		end

		::continue::
	end
end

--[[ Callbacks ]]
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)

-- Initialize everything on script load
InitializeSystems()

-- Provide global access to main module functions
return {
	ReloadDatabase = function()
		print("[Cheater Detection] Reloading database...")
		-- Directly call the LoadDatabase function from the Database module
		return G.Database.LoadDatabase()
	end,

	UpdateDatabase = function()
		print("[Cheater Detection] Triggering manual database update...")
		return DBManager.UpdateDatabase() -- Manager handles triggering the fetcher
	end,

	GetDatabaseStats = DBManager.GetStats,
}
