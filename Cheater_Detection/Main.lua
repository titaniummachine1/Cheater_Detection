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
local Database = require("Cheater_Detection.Database.Database") -- Require simplified DB
local Fetcher = require("Cheater_Detection.Database.Fetcher") -- Require simplified Fetcher

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

	-- Initialize database by loading it
	print("[Cheater Detection] Initializing - Loading Database...")
	-- Pass true for silent loading, false for not forcing reload
	-- This will be ignored if database is already initialized internally
	Database.LoadDatabase(false, false)

	-- G.DataBase should now be populated (or initialized as {} if file not found)
	if not G.DataBase then
		printc(255, 0, 0, 255, "[Cheater Detection] CRITICAL: G.DataBase is nil after LoadDatabase!")
		G.DataBase = {} -- Fallback
	else
		print("[Cheater Detection] G.DataBase initialized, type:", type(G.DataBase))
	end

	-- Trigger initial fetch (optional, can be manual)
	print("[Cheater Detection] Initializing - Starting Fetcher...")
	Fetcher.Start() -- Uncomment to auto-fetch on load

	-- Clear local player from cheater list (for debugging)
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer then
		local mySteamID = Common.GetSteamID64(localPlayer)
		pcall(playerlist.SetPriority, mySteamID, 0) -- Use pcall for safety
	end

	-- Print initialization message
	local entryCount = 0
	if G.DataBase and type(G.DataBase) == "table" then
		for _ in pairs(G.DataBase) do
			entryCount = entryCount + 1
		end
	end

	if entryCount == 0 then
		printc(255, 100, 100, 255, "[Cheater Detection] No database entries found. Fetch data or check logs.")
	else
		printc(
			100,
			255,
			100,
			255,
			string.format("[Cheater Detection] Initialized with %d database entries", entryCount)
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
			-- Simplified version doesn't have GetRecord, access G.DataBase directly
			local record = G.DataBase and G.DataBase[query]
			if record then
				found = true
				print(string.format("[Database] Found record for SteamID: %s", query))
				print(string.format("  Name: %s", record.Name or "Unknown"))
				print(string.format("  Reason: %s", record.Reason or "Unknown"))
			end
		end

		-- If not found by SteamID, search by name
		if not found then
			local matches = 0
			if G.DataBase and type(G.DataBase) == "table" then
				for steamId, data in pairs(G.DataBase) do
					if type(data) == "table" and data.Name and data.Name:lower():find(query:lower()) then
						matches = matches + 1
						print(string.format("[Database] Match %d: %s (SteamID: %s)", matches, data.Name, steamId))
						print(string.format("  Reason: %s", data.Reason or "Unknown"))

						if matches >= 5 then
							print("[Database] Found more matches, showing first 5 only")
							break
						end
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
			-- warn("Failed to get SteamID for player %s", entity:GetName() or "nil") -- Commented out warn
			goto continue -- Use goto instead of return
		end

		-- Check if player is a known cheater in database
		if G.DataBase and G.DataBase[steamid] then
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
			local isOnGround = bit.band(entityFlags, FL_ONGROUND) ~= 0 -- Correct bitwise check
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
			-- if Detections then
			-- 	Detections.CheckAngles(wrappedPlayer, entity)
			-- 	Detections.CheckDuckSpeed(wrappedPlayer, entity)
			-- 	Detections.CheckBunnyHop(wrappedPlayer, entity)
			-- 	Detections.CheckPacketChoke(wrappedPlayer, entity)
			-- 	Detections.CheckSequenceBurst(wrappedPlayer, entity)
			-- end

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
		-- Pass true for force parameter to ensure reload happens
		return Database.LoadDatabase and Database.LoadDatabase(false, true)
	end,

	UpdateDatabase = function()
		print("[Cheater Detection] Triggering manual database update...")
		return Fetcher.Start and Fetcher.Start() -- Call simplified Fetcher.Start
	end,

	-- GetDatabaseStats = Database.GetStats, -- Removed, simplified DB doesn't have GetStats
}
