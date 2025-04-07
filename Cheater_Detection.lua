local __bundle_require, __bundle_loaded, __bundle_register, __bundle_modules = (function(superRequire)
	local loadingPlaceholder = {[{}] = true}

	local register
	local modules = {}

	local require
	local loaded = {}

	register = function(name, body)
		if not modules[name] then
			modules[name] = body
		end
	end

	require = function(name)
		local loadedModule = loaded[name]

		if loadedModule then
			if loadedModule == loadingPlaceholder then
				return nil
			end
		else
			if not modules[name] then
				if not superRequire then
					local identifier = type(name) == 'string' and '\"' .. name .. '\"' or tostring(name)
					error('Tried to require ' .. identifier .. ', but no such module has been registered')
				else
					return superRequire(name)
				end
			end

			loaded[name] = loadingPlaceholder
			loadedModule = modules[name](require, loaded, register, modules)
			loaded[name] = loadedModule
		end

		return loadedModule
	end

	return require, loaded, register, modules
end)(require)
__bundle_register("__root", function(require, _LOADED, __bundle_register, __bundle_modules)
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

end)
__bundle_register("Cheater_Detection.Misc.Visuals.Menu", function(require, _LOADED, __bundle_register, __bundle_modules)
local Menu = {}

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")

local Lib = Common.Lib
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

local ImMenu = Common.ImMenu

-- Helper function for rounding coordinates
local function roundCoord(value)
	return math.floor(value + 0.5)
end

local function DrawMenu()
	ImMenu.BeginFrame(1)

	if G.Menu.Advanced.debug then
		draw.Color(255, 0, 0, 255)
		draw.SetFont(Fonts.Verdana)
		draw.Text(roundCoord(20), roundCoord(120), "Debug Mode!!! Some Features Might malfunction")
	end

	if gui.IsMenuOpen() and ImMenu.Begin("Cheater Detection", true) then
		-- Tabs for different sections
		ImMenu.BeginFrame(1)
		local tabs = { "Main", "Advanced", "Misc" }
		G.Menu.currentTab = ImMenu.TabControl(tabs, G.Menu.currentTab)
		ImMenu.EndFrame()

		draw.SetFont(Fonts.Verdana)
		draw.Color(255, 255, 255, 255)

		-- Main Configuration Tab
		if G.Menu.currentTab == "Main" then
			local Main = G.Menu.Main

			ImMenu.BeginFrame()
			Main.AutoMark = ImMenu.Checkbox("Auto Mark", Main.AutoMark)
			Main.partyCallaut = ImMenu.Checkbox("Party Callout", Main.partyCallaut)
			Main.Chat_Prefix = ImMenu.Checkbox("Chat Prefix", Main.Chat_Prefix)
			Main.Cheater_Tags = ImMenu.Checkbox("Cheater Tags", Main.Cheater_Tags)
			Main.JoinWarning = ImMenu.Checkbox("Join Warning", Main.JoinWarning)
			ImMenu.EndFrame()
		end

		-- Advanced Configuration Tab
		if G.Menu.currentTab == "Advanced" then
			local Advanced = G.Menu.Advanced

			ImMenu.BeginFrame()
			Advanced.Evicence_Tolerance = ImMenu.Slider("Evidence Tolerance", Advanced.Evicence_Tolerance, 1, 10)
			ImMenu.EndFrame()

			ImMenu.BeginFrame()
			Advanced.Choke = ImMenu.Checkbox("Choke Detection", Advanced.Choke)
			Advanced.Warp = ImMenu.Checkbox("Warp Detection", Advanced.Warp)
			Advanced.Bhop = ImMenu.Checkbox("Bhop Detection", Advanced.Bhop)
			ImMenu.EndFrame()

			ImMenu.BeginFrame()
			Advanced.Aimbot.enable = ImMenu.Checkbox("Aimbot Detection", Advanced.Aimbot.enable)
			if Advanced.Aimbot.enable then
				Advanced.Aimbot.silent = ImMenu.Checkbox("Silent Aim", Advanced.Aimbot.silent)
				Advanced.Aimbot.plain = ImMenu.Checkbox("Plain Aim", Advanced.Aimbot.plain)
				Advanced.Aimbot.smooth = ImMenu.Checkbox("Smooth Aim", Advanced.Aimbot.smooth)
			end
			ImMenu.EndFrame()

			ImMenu.BeginFrame()
			Advanced.triggerbot = ImMenu.Checkbox("Triggerbot Detection", Advanced.triggerbot)
			Advanced.AntyAim = ImMenu.Checkbox("Anty-Aim Detection", Advanced.AntyAim)
			Advanced.DuckSpeed = ImMenu.Checkbox("Duck Speed Detection", Advanced.DuckSpeed)
			Advanced.Strafe_bot = ImMenu.Checkbox("Strafe Bot Detection", Advanced.Strafe_bot)
			ImMenu.EndFrame()

			ImMenu.BeginFrame()
			Advanced.debug = ImMenu.Checkbox("Debug Mode", Advanced.debug)
			ImMenu.EndFrame()
		end

		-- Misc Configuration Tab
		if G.Menu.currentTab == "Misc" then
			local Misc = G.Menu.Misc

			ImMenu.BeginFrame(1)
			Misc.Autovote = ImMenu.Checkbox("Enable Auto Vote", Misc.Autovote)
			ImMenu.EndFrame()

			if Misc.Autovote then
				ImMenu.BeginFrame(1)
				Misc.intent.legit = ImMenu.Checkbox("Vote Legit Players", Misc.intent.legit)
				Misc.intent.cheater = ImMenu.Checkbox("Vote Cheaters", Misc.intent.cheater)
				Misc.intent.bot = ImMenu.Checkbox("Vote Bots", Misc.intent.bot)
				Misc.intent.friend = ImMenu.Checkbox("Exclude Friends", Misc.intent.friend)
				ImMenu.EndFrame()
			end

			ImMenu.BeginFrame(1)
			Misc.Vote_Reveal.Enable = ImMenu.Checkbox("Vote Reveal", Misc.Vote_Reveal.Enable)
			ImMenu.EndFrame()

			if Misc.Vote_Reveal.Enable then
				ImMenu.BeginFrame(1)
				Misc.Vote_Reveal.TargetTeam.MyTeam = ImMenu.Checkbox("My Team", Misc.Vote_Reveal.TargetTeam.MyTeam)
				Misc.Vote_Reveal.TargetTeam.enemyTeam =
					ImMenu.Checkbox("Enemy Team", Misc.Vote_Reveal.TargetTeam.enemyTeam)
				ImMenu.EndFrame()

				ImMenu.BeginFrame(1)
				Misc.Vote_Reveal.PartyChat = ImMenu.Checkbox("Party Chat", Misc.Vote_Reveal.PartyChat)
				Misc.Vote_Reveal.Console = ImMenu.Checkbox("Console Log", Misc.Vote_Reveal.Console)
				ImMenu.EndFrame()
			end

			-- Class Change Reveal moved to Misc as defined in Default_Config
			ImMenu.BeginFrame(1)
			Misc.Class_Change_Reveal.Enable = ImMenu.Checkbox("Class Change Reveal", Misc.Class_Change_Reveal.Enable)
			ImMenu.EndFrame()
			if Misc.Class_Change_Reveal.Enable then
				ImMenu.BeginFrame(1)
				Misc.Class_Change_Reveal.EnemyOnly = ImMenu.Checkbox("Enemy Only", Misc.Class_Change_Reveal.EnemyOnly)
				Misc.Class_Change_Reveal.PartyChat = ImMenu.Checkbox("Party Chat", Misc.Class_Change_Reveal.PartyChat)
				Misc.Class_Change_Reveal.Console = ImMenu.Checkbox("Console Log", Misc.Class_Change_Reveal.Console)
				ImMenu.EndFrame()
			end

			ImMenu.BeginFrame(1)
			Misc.Chat_notify = ImMenu.Checkbox("Chat Notifications", Misc.Chat_notify)
			ImMenu.EndFrame()
		end

		ImMenu.End()
	end
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "CD_MENU")
callbacks.Register("Draw", "CD_MENU", DrawMenu)

return Menu

end)
__bundle_register("Cheater_Detection.Utils.Globals", function(require, _LOADED, __bundle_register, __bundle_modules)
local Globals = {}

Globals.AutoVote = {
	Options = { "Yes", "No" },
	VoteCommand = "vote",
	VoteIdx = nil,
	VoteValue = nil, -- Set this to 1 for yes, 2 for no, or nil for off
}

--[[Shared Variables]]

Globals.players = {}
Globals.pLocal = nil
Globals.WLocal = nil
Globals.latin = nil
Globals.latout = nil

Globals.Menu = require("Cheater_Detection.Utils.DefaultConfig")

-- Global utility functions and UI helpers

local G = {
	Config = {
		DebugMode = false,
		ShowNotifications = true,
		NotificationDuration = 3,
		MaxMemoryUsageMB = 100, -- Target max memory usage
	},

	State = {
		LastNotification = 0,
		NotificationMessage = "",
		ProgressValue = 0,
		ProgressMessage = "",
		LastMemoryCheck = 0,
		MemoryCheckInterval = 5.0, -- Check memory every 5 seconds
	},

	-- Helper function for reliable integer coordinates
	RoundCoord = function(value)
		if not value then
			return 0
		end
		if type(value) ~= "number" then
			return 0
		end
		-- Check for NaN and infinity
		if value ~= value or value == math.huge or value == -math.huge then
			return 0
		end
		return math.floor(value + 0.5)
	end,
}

-- UI helper functions
G.UI = {
	-- Show a message in the UI and console
	ShowMessage = function(message, duration)
		if not message then
			return
		end

		-- Store for drawing
		G.State.NotificationMessage = message
		G.State.LastNotification = globals.RealTime()
		G.Config.NotificationDuration = duration or G.Config.NotificationDuration

		-- Also print to console
		print("[Cheater Detection] " .. message)
	end,

	-- Update progress indicator
	UpdateProgress = function(value, message)
		G.State.ProgressValue = value or G.State.ProgressValue
		G.State.ProgressMessage = message or G.State.ProgressMessage
	end,

	-- Draw notification if active
	DrawNotification = function()
		if not G.Config.ShowNotifications then
			return
		end

		local currentTime = globals.RealTime()
		local timeSinceNotification = currentTime - G.State.LastNotification

		-- If notification is expired, don't draw
		if timeSinceNotification > G.Config.NotificationDuration then
			return
		end

		-- Calculate fade-out
		local alpha = 255
		if timeSinceNotification > G.Config.NotificationDuration - 0.5 then
			alpha = math.floor(255 * (G.Config.NotificationDuration - timeSinceNotification) / 0.5)
		end

		-- Draw notification with integer coordinates
		local x, y = G.RoundCoord(20), G.RoundCoord(100)
		local padding = 10
		local message = G.State.NotificationMessage
		local width = draw.GetTextSize(message) + padding * 2

		-- Background
		draw.Color(20, 20, 20, math.min(200, alpha))
		draw.FilledRect(x, y, x + width, y + G.RoundCoord(30))

		-- Border
		draw.Color(80, 150, 255, alpha)
		draw.OutlinedRect(x, y, x + width, y + G.RoundCoord(30))

		-- Text
		draw.Color(255, 255, 255, alpha)
		draw.Text(G.RoundCoord(x + padding), G.RoundCoord(y + padding), message)
	end,

	-- Draw progress bar if active
	DrawProgressBar = function()
		if G.State.ProgressValue <= 0 then
			return
		end

		-- Draw progress bar at bottom of screen with integer coordinates
		local width = 300
		local height = 20
		local screenWidth, screenHeight = draw.GetScreenSize()
		local x = G.RoundCoord((screenWidth - width) / 2)
		local y = G.RoundCoord(screenHeight - height - 20)

		-- Background
		draw.Color(20, 20, 20, 200)
		draw.FilledRect(x, y, x + width, y + height)

		-- Progress fill
		local progressWidth = G.RoundCoord(width * (G.State.ProgressValue / 100))
		draw.Color(80, 150, 255, 255)
		draw.FilledRect(x, y, x + progressWidth, y + height)

		-- Border
		draw.Color(100, 170, 255, 255)
		draw.OutlinedRect(x, y, x + width, y + height)

		-- Progress text
		local percent = tostring(math.floor(G.State.ProgressValue)) .. "%"
		local textWidth = draw.GetTextSize(percent)
		draw.Color(255, 255, 255, 255)
		draw.Text(G.RoundCoord(x + (width - textWidth) / 2), G.RoundCoord(y + 3), percent)

		-- Message text
		if G.State.ProgressMessage and #G.State.ProgressMessage > 0 then
			draw.Text(x, G.RoundCoord(y - 15), G.State.ProgressMessage)
		end
	end,
}

-- Memory management helpers
G.Memory = {
	-- Check memory usage and perform cleanup if needed
	CheckMemory = function()
		local currentTime = globals.RealTime()
		if currentTime - G.State.LastMemoryCheck < G.State.MemoryCheckInterval then
			return
		end

		G.State.LastMemoryCheck = currentTime

		-- Check current memory usage
		local memoryUsage = collectgarbage("count") / 1024 -- MB

		-- If over threshold, perform cleanup
		if memoryUsage > G.Config.MaxMemoryUsageMB then
			-- Run incremental garbage collection
			collectgarbage("step", 1000) -- Run 1000 steps

			if G.Config.DebugMode then
				print(string.format("[Memory] Usage: %.2f MB - performing cleanup", memoryUsage))
			end
		end
	end,

	-- Force full cleanup
	ForceCleanup = function()
		collectgarbage("collect")
		collectgarbage("collect")

		if G.Config.DebugMode then
			print(string.format("[Memory] Forced cleanup - new usage: %.2f MB", collectgarbage("count") / 1024))
		end
	end,
}

-- Register draw callback for UI elements
callbacks.Register("Draw", "GlobalsUI", function()
	G.UI.DrawNotification()
	G.UI.DrawProgressBar()
	G.Memory.CheckMemory()
end)

return G

end)
__bundle_register("Cheater_Detection.Utils.DefaultConfig", function(require, _LOADED, __bundle_register, __bundle_modules)
local Default_Config = {
	currentTab = "Main",

	Main = {
		AutoMark = true,
		partyCallaut = true,
		Chat_Prefix = true,
		Cheater_Tags = true,
		JoinWarning = true,
	},

	Advanced = {
		Evicence_Tolerance = 5, --how many evidence more then average legit to mark as cheater
		Choke = true, --fakelag
		Warp = true,
		Bhop = true,
		Aimbot = {
			enable = true,
			silent = true,
			plain = true,
			smooth = true,
		},
		triggerbot = true,
		AntyAim = true,
		DuckSpeed = true,
		Strafe_bot = true,

		debug = false,
	},

	Misc = {
		Autovote = true,
		intent = {
			legit = true,
			cheater = true,
			bot = true,
			friend = false,
		},
		Vote_Reveal = {
			Enable = true,
			TargetTeam = {
				MyTeam = true,
				enemyTeam = true,
			},
			PartyChat = true,
			Console = true,
		},
		Class_Change_Reveal = {
			Enable = true,
			EnemyOnly = true,
			PartyChat = true,
			Console = true,
		},
		Chat_notify = true,
	},
}

return Default_Config

end)
__bundle_register("Cheater_Detection.Utils.Common", function(require, _LOADED, __bundle_register, __bundle_modules)
---@diagnostic disable: duplicate-set-field, undefined-field

-- Create and initialize the Common table first
local Common = {
	Lib = nil,
	ImMenu = nil,
	Json = nil,
	Log = nil,
	Notify = nil,
	TF2 = nil,
	Math = nil,
	Conversion = nil,
	WPlayer = nil,
	PR = nil,
	Helpers = nil,
}

if UnloadLib ~= nil then
	UnloadLib()
end

-- Unload the module if it's already loaded
if package.loaded["ImMenu"] then
	package.loaded["ImMenu"] = nil
end

--------------------------------------------------------------------------------------
--Library loading--
--------------------------------------------------------------------------------------

-- Function to download content from a URL
local function downloadFile(url)
	local success, body = pcall(http.Get, url)
	if not success or not body or body == "" then
		error("Failed to download file from " .. url .. ": " .. tostring(body))
	end
	return body
end

-- Load and validate library
local function loadlib(libName, libURL)
	if libName == "LNXlib" then
		-- First try to load local LNXlib if it exists
		local success, localLib = pcall(require, "lnxLib")

		if success and localLib then
			-- Local version exists and loaded successfully
			lnxLib = localLib
			print("Loaded local lnxLib")
		else
			-- Local version doesn't exist, download from GitHub
			print("Local lnxLib not found, downloading from GitHub...")
			local libContent

			-- Try to download with error handling
			local downloadSuccess, errorMsg = pcall(function()
				libContent = downloadFile(libURL)
				return true
			end)

			if not downloadSuccess or not libContent then
				error("Failed to download lnxLib: " .. tostring(errorMsg))
			end

			-- Execute downloaded code with error handling
			local executeSuccess, result = pcall(load, libContent)
			if not executeSuccess or not result then
				error("Failed to load lnxLib content: " .. tostring(result))
			end

			-- Execute the loaded code
			local runSuccess, lib = pcall(result)
			if not runSuccess or not lib then
				error("Failed to execute lnxLib: " .. tostring(lib))
			end

			-- Assign globally
			lnxLib = lib
			print("Downloaded and loaded lnxLib from GitHub")
		end

		-- Allow require("lnxLib") to return global
		package.preload["lnxLib"] = function()
			return lnxLib
		end

		return lnxLib
	else
		-- For ImMenu, load normally but modify its code first
		local libContent = downloadFile(libURL)
		if libName == "ImMenu" then
			-- Replace the header but keep rest of the code
			libContent = libContent:gsub(
				".-\n\nlocal Fonts", -- Match everything up to "local Fonts"
				"--[[ ImMenu ]]--\n\nlocal lnxLib = _G.lnxLib\nlocal Fonts" -- Replace with our simple header
			)
		end

		-- Execute modified code and capture return value
		local libFunction = assert(load(libContent))
		return libFunction() -- Return the module table
	end
end

--why
local latestLNXlib = "https://" .. "github.com/lnx00/Lmaobox-Library/releases/latest/download/lnxLib.lua"

-- Initialize libraries in order
Common.Lib = loadlib("LNXlib", latestLNXlib)
Common.ImMenu = require("Cheater_Detection.Libs.ImMenu")
Common.Json = require("Cheater_Detection.Libs.Json")

local G = require("Cheater_Detection.Utils.Globals")

-- Now initialize remaining Common fields using the loaded libraries
Common.Log = Common.Lib.Utils.Logger.new("Cheater Detection")
Common.Notify = Common.Lib.UI.Notify
Common.TF2 = Common.Lib.TF2
Common.Math = Common.Lib.Utils.Math
Common.Conversion = Common.Lib.Utils.Conversion
Common.WPlayer = Common.Lib.TF2.WPlayer
Common.PR = Common.Lib.TF2.PlayerResource
Common.Helpers = Common.Lib.TF2.Helpers

local cachedSteamIDs = {}
local lastTick = -1

function Common.GetSteamID64(Player)
	assert(Player, "Player is nil")

	local currentTick = globals.TickCount()
	local playerIndex = Player:GetIndex()

	-- Branchless cache reset
	cachedSteamIDs, lastTick = (lastTick ~= currentTick and {} or cachedSteamIDs), currentTick

	-- Retrieve cached result or calculate it
	local result = cachedSteamIDs[playerIndex]
		or (function()
			local playerInfo = assert(client.GetPlayerInfo(playerIndex), "Failed to get player info")
			local steamID = assert(playerInfo.SteamID, "Failed to get SteamID")
			return (playerInfo.IsBot or playerInfo.IsHLTV or steamID == "[U:1:0]") and playerInfo.UserID
				or assert(steam.ToSteamID64(steamID), "Failed to convert SteamID to SteamID64")
		end)()

	cachedSteamIDs[playerIndex] = result
	return result
end

function Common.IsCheater(playerInfo)
	local steamId = nil

	if type(playerInfo) == "number" and playerInfo < 101 then
		-- Assuming playerInfo is the index
		local targetIndex = playerInfo
		local targetPlayer = nil

		-- Find the player with the same index
		for _, player in ipairs(G.players) do
			if player:GetIndex() == targetIndex then
				targetPlayer = player
				break
			end
		end

		-- Check if the target player was found
		if targetPlayer then
			steamId = assert(Common.GetSteamID64(targetPlayer), "Failed to get SteamID64 for player")
		else
			return false
		end
	elseif type(playerInfo) == "number" then
		-- If playerInfo is a number, convert it to a string and check its length
		local steamIdStr = tostring(playerInfo)
		if #steamIdStr == 17 then
			steamId = playerInfo
		else
			return false
		end
	elseif playerInfo.GetIndex then
		-- If playerInfo is a player entity, get its SteamID64
		steamId = assert(Common.GetSteamID64(playerInfo), "Failed to get SteamID64 for player entity")
	else
		-- If playerInfo is neither a valid index, a valid SteamID64, nor a player entity, return false
		return false
	end

	if not steamId then
		return false
	end

	-- Check if the player is marked as a cheater based on various criteria
	local strikes = G.PlayerData[steamId] and G.PlayerData[steamId].info.Strikes or 0
	local isMarkedCheater = G.PlayerData[steamId] and G.PlayerData[steamId].info.isCheater
	local inDatabase = G.DataBase[steamId] ~= nil
	local priorityCheater = playerlist.GetPriority(steamId) == 10

	return isMarkedCheater or inDatabase or priorityCheater
end

function Common.IsFriend(entity)
	return (not G.Menu.Main.debug and Common.TF2.IsFriend(entity:GetIndex(), true)) -- Entity is a freind and party member
end

function Common.IsValidPlayer(entity, checkFriend)
	-- Check if the entity is a valid player
	if not entity or entity:IsDormant() or not entity:IsAlive() then
		return false -- Entity is not a valid player
	end

	if checkFriend and Common.IsFriend(entity) then
		return false -- Entity is a friend, skip
	end

	return true -- Entity is a valid player
end

-- Create a common record structure
function Common.createRecord(angle, position, headHitbox, bodyHitbox, simTime, onGround)
	return {
		Angle = angle,
		ViewPos = position,
		Hitboxes = {
			Head = headHitbox,
			Body = bodyHitbox,
		},
		SimTime = simTime,
		onGround = onGround,
	}
end

function Common.FromSteamid32To64(steamid32)
	return "[U:1:" .. steamid32 .. "]"
end

-- More robust SteamID conversion functions
function Common.SteamID3ToSteamID64(steamID3)
	if not steamID3 then
		return nil
	end

	-- Try to extract the numeric part from [U:1:12345]
	local accountID = steamID3:match("%[U:1:(%d+)%]")
	if not accountID then
		return nil
	end

	-- Safe steam API conversion with error handling
	local success, steamID64 = pcall(steam.ToSteamID64, steamID3)
	if success and steamID64 and #steamID64 == 17 then
		return steamID64
	end

	-- Fallback manual conversion if steam API fails
	-- SteamID64 = 76561197960265728 + accountID
	return tostring(76561197960265728 + tonumber(accountID))
end

-- Helper function to determine if the content is JSON
function Common.isJson(content)
	local firstChar = content:sub(1, 1)
	return firstChar == "{" or firstChar == "["
end

-- Safe integer rounding function for drawing coordinates
Common.RoundCoord = function(value)
	if not value then
		return 0
	end

	if type(value) ~= "number" then
		return 0
	end

	-- Check for NaN and infinity
	if value ~= value or value == math.huge or value == -math.huge then
		return 0
	end

	return math.floor(value + 0.5)
end

--[[ Callbacks ]]
local function OnUnload() -- Called when the script is unloaded
	UnloadLib() --unloading lualib
	engine.PlaySound("hl1/fvox/deactivated.wav") --deactivated
end

--[[ Unregister previous callbacks ]]
--
callbacks.Unregister("Unload", "CD_Unload") -- unregister the "Unload" callback
--[[ Register callbacks ]]
--
callbacks.Register("Unload", "CD_Unload", OnUnload) -- Register the "Unload" callback

--[[ Play sound when loaded ]]
--
engine.PlaySound("hl1/fvox/activated.wav")

return Common

end)
__bundle_register("Cheater_Detection.Libs.Json", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
David Kolf's JSON module for Lua 5.1 - 5.4

Version 2.6


For the documentation see the corresponding readme.txt or visit
<http://dkolf.de/src/dkjson-lua.fsl/>.

You can contact the author by sending an e-mail to 'david' at the
domain 'dkolf.de'.


Copyright (C) 2010-2021 David Heiko Kolf

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--]]

---@alias JsonState { indent : boolean?, keyorder : integer[]?, level : integer?, buffer : string[]?, bufferlen : integer?, tables : table[]?, exception : function? }

-- global dependencies:
local pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset =
	pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset
local error, require, pcall, select = error, require, pcall, select
local floor, huge = math.floor, math.huge
local strrep, gsub, strsub, strbyte, strchar, strfind, strlen, strformat =
	string.rep, string.gsub, string.sub, string.byte, string.char, string.find, string.len, string.format
local strmatch = string.match
local concat = table.concat

---@class Json
local json = { version = "dkjson 2.6.1 L" }

local _ENV = nil -- blocking globals in Lua 5.2 and later

json.null = setmetatable({}, {
	__tojson = function()
		return "null"
	end,
})

local function isarray(tbl)
	local max, n, arraylen = 0, 0, 0
	for k, v in pairs(tbl) do
		if k == "n" and type(v) == "number" then
			arraylen = v
			if v > max then
				max = v
			end
		else
			if type(k) ~= "number" or k < 1 or floor(k) ~= k then
				return false
			end
			if k > max then
				max = k
			end
			n = n + 1
		end
	end
	if max > 10 and max > arraylen and max > n * 2 then
		return false -- don't create an array with too many holes
	end
	return true, max
end

local escapecodes = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function escapeutf8(uchar)
	local value = escapecodes[uchar]
	if value then
		return value
	end
	local a, b, c, d = strbyte(uchar, 1, 4)
	a, b, c, d = a or 0, b or 0, c or 0, d or 0
	if a <= 0x7f then
		value = a
	elseif 0xc0 <= a and a <= 0xdf and b >= 0x80 then
		value = (a - 0xc0) * 0x40 + b - 0x80
	elseif 0xe0 <= a and a <= 0xef and b >= 0x80 and c >= 0x80 then
		value = ((a - 0xe0) * 0x40 + b - 0x80) * 0x40 + c - 0x80
	elseif 0xf0 <= a and a <= 0xf7 and b >= 0x80 and c >= 0x80 and d >= 0x80 then
		value = (((a - 0xf0) * 0x40 + b - 0x80) * 0x40 + c - 0x80) * 0x40 + d - 0x80
	else
		return ""
	end
	if value <= 0xffff then
		return strformat("\\u%.4x", value)
	elseif value <= 0x10ffff then
		-- encode as UTF-16 surrogate pair
		value = value - 0x10000
		local highsur, lowsur = 0xD800 + floor(value / 0x400), 0xDC00 + (value % 0x400)
		return strformat("\\u%.4x\\u%.4x", highsur, lowsur)
	else
		return ""
	end
end

local function fsub(str, pattern, repl)
	-- gsub always builds a new string in a buffer, even when no match
	-- exists. First using find should be more efficient when most strings
	-- don't contain the pattern.
	if strfind(str, pattern) then
		return gsub(str, pattern, repl)
	else
		return str
	end
end

local function quotestring(value)
	-- based on the regexp "escapable" in https://github.com/douglascrockford/JSON-js
	value = fsub(value, '[%z\1-\31"\\\127]', escapeutf8)
	if strfind(value, "[\194\216\220\225\226\239]") then
		value = fsub(value, "\194[\128-\159\173]", escapeutf8)
		value = fsub(value, "\216[\128-\132]", escapeutf8)
		value = fsub(value, "\220\143", escapeutf8)
		value = fsub(value, "\225\158[\180\181]", escapeutf8)
		value = fsub(value, "\226\128[\140-\143\168-\175]", escapeutf8)
		value = fsub(value, "\226\129[\160-\175]", escapeutf8)
		value = fsub(value, "\239\187\191", escapeutf8)
		value = fsub(value, "\239\191[\176-\191]", escapeutf8)
	end
	return '"' .. value .. '"'
end
json.quotestring = quotestring

local function replace(str, o, n)
	local i, j = strfind(str, o, 1, true)
	if i then
		return strsub(str, 1, i - 1) .. n .. strsub(str, j + 1, -1)
	else
		return str
	end
end

-- locale independent num2str and str2num functions
local decpoint, numfilter

local function updatedecpoint()
	decpoint = strmatch(tostring(0.5), "([^05+])")
	-- build a filter that can be used to remove group separators
	numfilter = "[^0-9%-%+eE" .. gsub(decpoint, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "]+"
end

updatedecpoint()

local function num2str(num)
	return replace(fsub(tostring(num), numfilter, ""), decpoint, ".")
end

local function str2num(str)
	local num = tonumber(replace(str, ".", decpoint))
	if not num then
		updatedecpoint()
		num = tonumber(replace(str, ".", decpoint))
	end
	return num
end

local function addnewline2(level, buffer, buflen)
	buffer[buflen + 1] = "\n"
	buffer[buflen + 2] = strrep("  ", level)
	buflen = buflen + 2
	return buflen
end

function json.addnewline(state)
	if state.indent then
		state.bufferlen = addnewline2(state.level or 0, state.buffer, state.bufferlen or #state.buffer)
	end
end

local encode2 -- forward declaration

local function addpair(key, value, prev, indent, level, buffer, buflen, tables, globalorder, state)
	local kt = type(key)
	if kt ~= "string" and kt ~= "number" then
		return nil, "type '" .. kt .. "' is not supported as a key by JSON."
	end
	if prev then
		buflen = buflen + 1
		buffer[buflen] = ","
	end
	if indent then
		buflen = addnewline2(level, buffer, buflen)
	end
	buffer[buflen + 1] = quotestring(key)
	buffer[buflen + 2] = ":"
	return encode2(value, indent, level, buffer, buflen + 2, tables, globalorder, state)
end

local function appendcustom(res, buffer, state)
	local buflen = state.bufferlen
	if type(res) == "string" then
		buflen = buflen + 1
		buffer[buflen] = res
	end
	return buflen
end

local function exception(reason, value, state, buffer, buflen, defaultmessage)
	defaultmessage = defaultmessage or reason
	local handler = state.exception
	if not handler then
		return nil, defaultmessage
	else
		state.bufferlen = buflen
		local ret, msg = handler(reason, value, state, defaultmessage)
		if not ret then
			return nil, msg or defaultmessage
		end
		return appendcustom(ret, buffer, state)
	end
end

function json.encodeexception(reason, value, state, defaultmessage)
	return quotestring("<" .. defaultmessage .. ">")
end

encode2 = function(value, indent, level, buffer, buflen, tables, globalorder, state)
	local valtype = type(value)
	local valmeta = getmetatable(value)
	valmeta = type(valmeta) == "table" and valmeta -- only tables
	local valtojson = valmeta and valmeta.__tojson
	if valtojson then
		if tables[value] then
			return exception("reference cycle", value, state, buffer, buflen)
		end
		tables[value] = true
		state.bufferlen = buflen
		local ret, msg = valtojson(value, state)
		if not ret then
			return exception("custom encoder failed", value, state, buffer, buflen, msg)
		end
		tables[value] = nil
		buflen = appendcustom(ret, buffer, state)
	elseif value == nil then
		buflen = buflen + 1
		buffer[buflen] = "null"
	elseif valtype == "number" then
		local s
		if value ~= value or value >= huge or -value >= huge then
			-- This is the behaviour of the original JSON implementation.
			s = "null"
		else
			s = num2str(value)
		end
		buflen = buflen + 1
		buffer[buflen] = s
	elseif valtype == "boolean" then
		buflen = buflen + 1
		buffer[buflen] = value and "true" or "false"
	elseif valtype == "string" then
		buflen = buflen + 1
		buffer[buflen] = quotestring(value)
	elseif valtype == "table" then
		if tables[value] then
			return exception("reference cycle", value, state, buffer, buflen)
		end
		tables[value] = true
		level = level + 1
		local isa, n = isarray(value)
		if n == 0 and valmeta and valmeta.__jsontype == "object" then
			isa = false
		end
		local msg
		if isa then -- JSON array
			buflen = buflen + 1
			buffer[buflen] = "["
			for i = 1, n do
				buflen, msg = encode2(value[i], indent, level, buffer, buflen, tables, globalorder, state)
				if not buflen then
					return nil, msg
				end
				if i < n then
					buflen = buflen + 1
					buffer[buflen] = ","
				end
			end
			buflen = buflen + 1
			buffer[buflen] = "]"
		else -- JSON object
			local prev = false
			buflen = buflen + 1
			buffer[buflen] = "{"
			local order = valmeta and valmeta.__jsonorder or globalorder
			if order then
				local used = {}
				n = #order
				for i = 1, n do
					local k = order[i]
					local v = value[k]
					if v ~= nil then
						used[k] = true
						buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
						prev = true -- add a seperator before the next element
					end
				end
				for k, v in pairs(value) do
					if not used[k] then
						buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
						if not buflen then
							return nil, msg
						end
						prev = true -- add a seperator before the next element
					end
				end
			else -- unordered
				for k, v in pairs(value) do
					buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
					if not buflen then
						return nil, msg
					end
					prev = true -- add a seperator before the next element
				end
			end
			if indent then
				buflen = addnewline2(level - 1, buffer, buflen)
			end
			buflen = buflen + 1
			buffer[buflen] = "}"
		end
		tables[value] = nil
	else
		return exception(
			"unsupported type",
			value,
			state,
			buffer,
			buflen,
			"type '" .. valtype .. "' is not supported by JSON."
		)
	end
	return buflen
end

---Encodes a lua table to a JSON string.
---@param value any
---@param state? JsonState
---@return string|boolean
function json.encode(value, state)
	state = state or {}
	local oldbuffer = state.buffer
	local buffer = oldbuffer or {}
	state.buffer = buffer
	updatedecpoint()
	local ret, msg = encode2(
		value,
		state.indent,
		state.level or 0,
		buffer,
		state.bufferlen or 0,
		state.tables or {},
		state.keyorder,
		state
	)
	if not ret then
		error(msg, 2)
	elseif oldbuffer == buffer then
		state.bufferlen = ret
		return true
	else
		state.bufferlen = nil
		state.buffer = nil
		return concat(buffer)
	end
end

local function loc(str, where)
	local line, pos, linepos = 1, 1, 0
	while true do
		pos = strfind(str, "\n", pos, true)
		if pos and pos < where then
			line = line + 1
			linepos = pos
			pos = pos + 1
		else
			break
		end
	end
	return "line " .. line .. ", column " .. (where - linepos)
end

local function unterminated(str, what, where)
	return nil, strlen(str) + 1, "unterminated " .. what .. " at " .. loc(str, where)
end

local function scanwhite(str, pos)
	while true do
		pos = strfind(str, "%S", pos)
		if not pos then
			return nil
		end
		local sub2 = strsub(str, pos, pos + 1)
		if sub2 == "\239\187" and strsub(str, pos + 2, pos + 2) == "\191" then
			-- UTF-8 Byte Order Mark
			pos = pos + 3
		elseif sub2 == "//" then
			pos = strfind(str, "[\n\r]", pos + 2)
			if not pos then
				return nil
			end
		elseif sub2 == "/*" then
			pos = strfind(str, "*/", pos + 2)
			if not pos then
				return nil
			end
			pos = pos + 2
		else
			return pos
		end
	end
end

local escapechars = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	["b"] = "\b",
	["f"] = "\f",
	["n"] = "\n",
	["r"] = "\r",
	["t"] = "\t",
}

local function unichar(value)
	if value < 0 then
		return nil
	elseif value <= 0x007f then
		return strchar(value)
	elseif value <= 0x07ff then
		return strchar(0xc0 + floor(value / 0x40), 0x80 + (floor(value) % 0x40))
	elseif value <= 0xffff then
		return strchar(0xe0 + floor(value / 0x1000), 0x80 + (floor(value / 0x40) % 0x40), 0x80 + (floor(value) % 0x40))
	elseif value <= 0x10ffff then
		return strchar(
			0xf0 + floor(value / 0x40000),
			0x80 + (floor(value / 0x1000) % 0x40),
			0x80 + (floor(value / 0x40) % 0x40),
			0x80 + (floor(value) % 0x40)
		)
	else
		return nil
	end
end

local function scanstring(str, pos)
	local lastpos = pos + 1
	local buffer, n = {}, 0
	while true do
		local nextpos = strfind(str, '["\\]', lastpos)
		if not nextpos then
			return unterminated(str, "string", pos)
		end
		if nextpos > lastpos then
			n = n + 1
			buffer[n] = strsub(str, lastpos, nextpos - 1)
		end
		if strsub(str, nextpos, nextpos) == '"' then
			lastpos = nextpos + 1
			break
		else
			local escchar = strsub(str, nextpos + 1, nextpos + 1)
			local value
			if escchar == "u" then
				value = tonumber(strsub(str, nextpos + 2, nextpos + 5), 16)
				if value then
					local value2
					if 0xD800 <= value and value <= 0xDBff then
						-- we have the high surrogate of UTF-16. Check if there is a
						-- low surrogate escaped nearby to combine them.
						if strsub(str, nextpos + 6, nextpos + 7) == "\\u" then
							value2 = tonumber(strsub(str, nextpos + 8, nextpos + 11), 16)
							if value2 and 0xDC00 <= value2 and value2 <= 0xDFFF then
								value = (value - 0xD800) * 0x400 + (value2 - 0xDC00) + 0x10000
							else
								value2 = nil -- in case it was out of range for a low surrogate
							end
						end
					end
					value = value and unichar(value)
					if value then
						if value2 then
							lastpos = nextpos + 12
						else
							lastpos = nextpos + 6
						end
					end
				end
			end
			if not value then
				value = escapechars[escchar] or escchar
				lastpos = nextpos + 2
			end
			n = n + 1
			buffer[n] = value
		end
	end
	if n == 1 then
		return buffer[1], lastpos
	elseif n > 1 then
		return concat(buffer), lastpos
	else
		return "", lastpos
	end
end

local scanvalue -- forward declaration

local function scantable(what, closechar, str, startpos, nullval, objectmeta, arraymeta)
	local tbl, n = {}, 0
	local pos = startpos + 1
	if what == "object" then
		setmetatable(tbl, objectmeta)
	else
		setmetatable(tbl, arraymeta)
	end
	while true do
		pos = scanwhite(str, pos)
		if not pos then
			return unterminated(str, what, startpos)
		end
		local char = strsub(str, pos, pos)
		if char == closechar then
			return tbl, pos + 1
		end
		local val1, err
		val1, pos, err = scanvalue(str, pos, nullval, objectmeta, arraymeta)
		if err then
			return nil, pos, err
		end
		pos = scanwhite(str, pos)
		if not pos then
			return unterminated(str, what, startpos)
		end
		char = strsub(str, pos, pos)
		if char == ":" then
			if val1 == nil then
				return nil, pos, "cannot use nil as table index (at " .. loc(str, pos) .. ")"
			end
			pos = scanwhite(str, pos + 1)
			if not pos then
				return unterminated(str, what, startpos)
			end
			local val2
			val2, pos, err = scanvalue(str, pos, nullval, objectmeta, arraymeta)
			if err then
				return nil, pos, err
			end
			tbl[val1] = val2
			pos = scanwhite(str, pos)
			if not pos then
				return unterminated(str, what, startpos)
			end
			char = strsub(str, pos, pos)
		else
			n = n + 1
			tbl[n] = val1
		end
		if char == "," then
			pos = pos + 1
		end
	end
end

scanvalue = function(str, pos, nullval, objectmeta, arraymeta)
	pos = pos or 1
	pos = scanwhite(str, pos)
	if not pos then
		return nil, strlen(str) + 1, "no valid JSON value (reached the end)"
	end
	local char = strsub(str, pos, pos)
	if char == "{" then
		return scantable("object", "}", str, pos, nullval, objectmeta, arraymeta)
	elseif char == "[" then
		return scantable("array", "]", str, pos, nullval, objectmeta, arraymeta)
	elseif char == '"' then
		return scanstring(str, pos)
	else
		local pstart, pend = strfind(str, "^%-?[%d%.]+[eE]?[%+%-]?%d*", pos)
		if pstart then
			local number = str2num(strsub(str, pstart, pend))
			if number then
				return number, pend + 1
			end
		end
		pstart, pend = strfind(str, "^%a%w*", pos)
		if pstart then
			local name = strsub(str, pstart, pend)
			if name == "true" then
				return true, pend + 1
			elseif name == "false" then
				return false, pend + 1
			elseif name == "null" then
				return nullval, pend + 1
			end
		end
		return nil, pos, "no valid JSON value at " .. loc(str, pos)
	end
end

local function optionalmetatables(...)
	if select("#", ...) > 0 then
		return ...
	else
		return { __jsontype = "object" }, { __jsontype = "array" }
	end
end

---@param str string
---@param pos integer?
---@param nullval any?
---@param ... table?
function json.decode(str, pos, nullval, ...)
	local objectmeta, arraymeta = optionalmetatables(...)
	return scanvalue(str, pos, nullval, objectmeta, arraymeta)
end

return json

end)
__bundle_register("Cheater_Detection.Libs.ImMenu", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Immediate mode menu library for Lmaobox
    Author: github.com/lnx00
]]

-- Get the global lnxLib instance instead of requiring Common
if not lnxLib then
    error("lnxLib not found. Make sure it's loaded before ImMenu")
end

local Fonts, Notify = lnxLib.UI.Fonts, lnxLib.UI.Notify
local KeyHelper, Input, Timer = lnxLib.Utils.KeyHelper, lnxLib.Utils.Input, lnxLib.Utils.Timer

-- Annotation aliases
---@alias ImItemID string
---@alias ImPos { X : integer, Y : integer }
---@alias ImWindow { X : integer, Y : integer, W : integer, H : integer }
---@alias ImFrame { X : integer, Y : integer, W : integer, H : integer, A : integer }
---@alias ImColor table<integer, integer, integer, integer?>
---@alias ImStyle any

--[[ Globals ]]
---@enum ImAlign
ImAlign = { Vertical = 0, Horizontal = 1 }

---@class ImMenu
---@field public Cursor ImPos
---@field public ActiveItem ImItemID|nil
ImMenu = {
    Cursor = { X = 0, Y = 0 },
    ActiveItem = nil,
    ActivePopup = nil
}

--[[ Variables ]]
local screenWidth, screenHeight = draw.GetScreenSize()
local dragPos = { X = 0, Y = 0 }
local lastKey = { Key = 0, Time = 0 }
local inPopup = false

-- Input Helpers
MouseHelper = KeyHelper.new(MOUSE_LEFT)
EnterHelper = KeyHelper.new(KEY_ENTER)
LeftArrow = KeyHelper.new(KEY_LEFT)
RightArrow = KeyHelper.new(KEY_RIGHT)

---@type table<string, ImWindow>
Windows = {}

---@type function[]
LateDrawList = {}

---@type ImColor[]
Colors = {
    Title = { 55, 100, 215, 255 },
    Text = { 255, 255, 255, 255 },
    Window = { 30, 30, 30, 255 },
    Item = { 50, 50, 50, 255 },
    ItemHover = { 60, 60, 60, 255 },
    ItemActive = { 70, 70, 70, 255 },
    Highlight = { 180, 180, 180, 100 },
    HighlightActive = { 240, 240, 240, 140 },
    WindowBorder = { 55, 100, 215, 255 },
    FrameBorder = { 0, 0, 0, 200 },
    Border = { 0, 0, 0, 200 }
}

---@type ImStyle[]
Style = {
    Font = Fonts.Verdana,
    ItemPadding = 5,
    ItemMargin = 5,
    FramePadding = 5,
    ItemSize = nil,
    WindowBorder = true,
    FrameBorder = false,
    ButtonBorder = false,
    CheckboxBorder = false,
    SliderBorder = false,
    Border = false,
    Popup = false
}

-- Stacks
WindowStack = Stack.new()
FrameStack = Stack.new()
ColorStack = Stack.new()
StyleStack = Stack.new()

--[[ Private Functions ]]
---@param color ImColor
local function UnpackColor(color)
    return color[1], color[2], color[3], color[4] or 255
end

-- Returns a pressed key suitable for operations (function keys, arrows, etc.)
---@return integer?
function GetOperationKey()
    for i = KEY_F1, KEY_F12 do
        if input.IsButtonDown(i) then
            return i
        end
    end
    for _, key in ipairs({
        KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, 
        KEY_PAGEUP, KEY_PAGEDOWN, KEY_INSERT, KEY_DELETE, KEY_ESCAPE
    }) do
        if input.IsButtonDown(key) then
            return key
        end
    end
    return nil
end

---@return integer?
local function GetInput()
    local key = Input.GetPressedKey() or GetOperationKey()
    if not key then
        lastKey.Key = 0
        return nil
    end

    if key == lastKey.Key then
        if lastKey.Time + 0.5 < globals.RealTime() then
            return key
        else
            return nil
        end
    end

    lastKey.Key = key
    lastKey.Time = globals.RealTime()
    return key
end

--[[ Public Getters ]]

---@return number
function ImMenu.GetVersion() return 0.66 end

---@return ImStyle[]
function ImMenu.GetStyle() return table.readOnly(Style) end

---@return ImColor[]
function ImMenu.GetColors() return table.readOnly(Colors) end

---@return ImWindow
function ImMenu.GetCurrentWindow() return WindowStack:peek() end

---@return ImFrame
function ImMenu.GetCurrentFrame() return FrameStack:peek() end

--[[ Public Setters ]]
-- Push a color to the stack
---@param key string
---@param color ImColor
function ImMenu.PushColor(key, color)
    ColorStack:push({ Key = key, Value = Colors[key] })
    Colors[key] = color
end

-- Pop the last color from the stack
---@param amount? integer
function ImMenu.PopColor(amount)
    amount = amount or 1
    for _ = 1, amount do
        local color = ColorStack:pop()
        Colors[color.Key] = color.Value
    end
end

-- Push a style to the stack
---@param key string
---@param style ImStyle
function ImMenu.PushStyle(key, style)
    StyleStack:push({ Key = key, Value = Style[key] })
    Style[key] = style
end

-- Pop the last style from the stack
---@param amount? integer
function ImMenu.PopStyle(amount)
    amount = amount or 1
    for _ = 1, amount do
        local style = StyleStack:pop()
        Style[style.Key] = style.Value
    end
end

--[[ Public Functions ]]
-- Creates a new color attribute
---@param key string
---@param value any
function ImMenu.AddColor(key, value)
    Colors[key] = value
end

-- Creates a new style attribute
---@param key string
---@param value any
function ImMenu.AddStyle(key, value)
    Style[key] = value
end

-- Runs all late draw functions
function ImMenu.LateDraw()
    draw.Color(255, 255, 255, 255)

    -- Run all late draw functions
    for _, func in ipairs(LateDrawList) do
        func()
    end

    LateDrawList = {}
end

-- Updates the cursor and current frame size
---@param w integer
---@param h integer
function ImMenu.UpdateCursor(w, h)
    local frame = ImMenu.GetCurrentFrame()
    if frame then
        if frame.A == 0 then
            -- Horizontal
            ImMenu.Cursor.Y = ImMenu.Cursor.Y + h + Style.ItemMargin
            frame.W = math.max(frame.W, w)
            frame.H = math.max(frame.H, ImMenu.Cursor.Y - frame.Y)
        elseif frame.A == 1 then
            -- Vertical
            ImMenu.Cursor.X = ImMenu.Cursor.X + w + Style.ItemMargin
            frame.W = math.max(frame.W, ImMenu.Cursor.X - frame.X)
            frame.H = math.max(frame.H, h)
        end
    else
        -- TODO: It shouldn't be allowed to draw outside of a frame
        ImMenu.Cursor.Y = ImMenu.Cursor.Y + h + Style.ItemMargin
    end
end

-- Updates the next color depending on the interaction state
---@param hovered boolean
---@param active boolean
function ImMenu.InteractionColor(hovered, active)
    if active then
        draw.Color(UnpackColor(Colors.ItemActive))
    elseif hovered then
        draw.Color(UnpackColor(Colors.ItemHover))
    else
        draw.Color(UnpackColor(Colors.Item))
    end
end

---@param width integer
---@param height integer
---@return integer width, integer height
function ImMenu.GetSize(width, height)
    if Style.ItemSize ~= nil then
        width, height = Style.ItemSize[1], Style.ItemSize[2]
    end

    return width, height
end

-- Returns whether the element is clicked or active
---@param x number
---@param y number
---@param width number
---@param height number
---@param id string
---@return boolean hovered, boolean clicked, boolean active
function ImMenu.GetInteraction(x, y, width, height, id)
    -- Is a different element active?
    if ImMenu.ActiveItem ~= nil and ImMenu.ActiveItem ~= id then
        return false, false, false
    end

    -- Is a popup active?
    if ImMenu.ActivePopup ~= nil and not inPopup then
        return false, false, false
    end

    local hovered = Input.MouseInBounds(x, y, x + width, y + height) or id == ImMenu.ActiveItem
    local clicked = hovered and (MouseHelper:Pressed() or EnterHelper:Pressed())
    local active = hovered and (MouseHelper:Down() or EnterHelper:Down())

    -- Should this element be active?
    if active and ImMenu.ActiveItem == nil then
        ImMenu.ActiveItem = id
    end

    -- Is this element no longer active?
    if ImMenu.ActiveItem == id and not active then
        ImMenu.ActiveItem = nil
    end

    return hovered, clicked, active
end

---@param text string
function ImMenu.GetLabel(text)
    for label in text:gmatch("(.+)###(.+)") do
        return label
    end

    return text
end

---@param size? number
function ImMenu.Space(size)
    size = size or Style.ItemMargin
    ImMenu.UpdateCursor(size, size)
end

function ImMenu.Separator()
    local x, y = ImMenu.Cursor.X, ImMenu.Cursor.Y
    local currentWindow = ImMenu.GetCurrentWindow()
    local width = currentWindow.W - Style.FramePadding * 2
    local height = Style.ItemMargin * 2

    draw.Color(UnpackColor(Colors.WindowBorder))
    draw.Line(x, y + height // 2, x + width, y + height // 2)

    ImMenu.UpdateCursor(width, height)
end


-- Begins a new frame
---@param titleOrAlign string|integer
---@param align? integer
function ImMenu.BeginFrame(titleOrAlign, align)
    local title = nil
    if type(titleOrAlign) == "string" then
        title = titleOrAlign
    elseif type(titleOrAlign) == "number" then
        align = titleOrAlign
    end
    align = align or 0

    local frame = {
        X = ImMenu.Cursor.X,
        Y = ImMenu.Cursor.Y,
        W = 0,
        H = 0,
        A = align,
        Title = title,
        Children = {}
    }

    FrameStack:push(frame)
    
    -- Apply padding
    ImMenu.Cursor.X = ImMenu.Cursor.X + Style.FramePadding
    ImMenu.Cursor.Y = ImMenu.Cursor.Y + Style.FramePadding

    -- Draw title if provided
    if title then
        local txtWidth, txtHeight = draw.GetTextSize(title)
        frame.TitleHeight = txtHeight + Style.FramePadding * 2

        -- Calculate frame width to the right side of the menu
        local currentWindow = ImMenu.GetCurrentWindow()
        local frameWidth = currentWindow.W - Style.FramePadding * 4

        -- Draw title background
        draw.Color(UnpackColor(Colors.Title))
        draw.FilledRect(frame.X, frame.Y, frame.X + frameWidth, frame.Y + frame.TitleHeight)

        -- Draw title text centered
        draw.Color(UnpackColor(Colors.Text))
        local textX = frame.X + (frameWidth - txtWidth) // 2
        draw.Text(textX, frame.Y + Style.FramePadding, title)

        -- Draw frame background
        draw.Color(UnpackColor(Colors.Title))
        draw.FilledRect(frame.X, frame.Y + frame.TitleHeight, frame.X + frameWidth, frame.Y + frame.H + frame.TitleHeight)

        ImMenu.Space(5)
        ImMenu.Cursor.Y = ImMenu.Cursor.Y + frame.TitleHeight + Style.ItemMargin
    end
end


-- Ends the current frame
---@return ImFrame frame
function ImMenu.EndFrame()
    ---@type ImFrame
    local frame = FrameStack:pop()

    -- Process children
    for _, child in ipairs(frame.Children) do
        child.W = math.max(child.W, ImMenu.Cursor.X - child.X)
        child.H = ImMenu.Cursor.Y - child.Y
        frame.W = math.max(frame.W, child.W)
        frame.H = frame.H + child.H + Style.ItemMargin

        -- Draw child frame background and border
        draw.Color(UnpackColor(Colors.Item))
        draw.FilledRect(child.X, child.Y, child.X + child.W, child.Y + child.H)
        if Style.FrameBorder then
            draw.Color(UnpackColor(Colors.FrameBorder))
            draw.OutlinedRect(child.X, child.Y, child.X + child.W, child.Y + child.H)
        end
    end

    ImMenu.Cursor.X = frame.X
    ImMenu.Cursor.Y = frame.Y

    -- Apply padding
    if frame.A == 0 then
        -- Horizontal
        frame.W = frame.W + Style.FramePadding * 2
        frame.H = frame.H + Style.FramePadding - Style.ItemMargin
    elseif frame.A == 1 then
        -- Vertical
        frame.H = frame.H + Style.FramePadding * 2
        frame.W = frame.W + Style.FramePadding - Style.ItemMargin
    end

    -- Update the cursor
    ImMenu.UpdateCursor(frame.W, frame.H)

    return frame
end

-- Load a bold font
local BoldFont = draw.CreateFont("Verdana Bold", 18, 800)

-- Begins a new window
---@param title string
---@param visible? boolean
---@return boolean visible
function ImMenu.Begin(title, visible)
    local isVisible = (visible == nil) or visible
    if not isVisible then return false end

    -- Create the window if it doesn't exist
    if not Windows[title] then
        Windows[title] = {
            X = 50,
            Y = 150,
            W = 100,
            H = 100
        }
    end

    -- Initialize the window
    local window = Windows[title]
    draw.SetFont(BoldFont)  -- Set the bold font before getting text size
    local titleText = ImMenu.GetLabel(title)
    local txtWidth, txtHeight = draw.GetTextSize(titleText)
    local titleHeight = txtHeight + Style.ItemPadding
    local hovered, clicked, active = ImMenu.GetInteraction(window.X, window.Y, window.W, titleHeight, title)

    -- Title bar
    draw.Color(table.unpack(Colors.Title))
    draw.OutlinedRect(window.X, window.Y, window.X + window.W, window.Y + window.H)
    draw.FilledRect(window.X, window.Y, window.X + window.W, window.Y + titleHeight)

    -- Title text with shadow and bold font
    local titleX = window.X + (window.W // 2) - (txtWidth // 2)
    local titleY = window.Y + (titleHeight // 2) - (txtHeight // 2)

    draw.TextShadow(titleX + 1, titleY + 1, titleText)  -- Draw shadow

    draw.Color(255, 255, 255, 255)  -- Dark text color
    draw.Text(titleX, titleY, titleText)

    -- Background
    draw.Color(table.unpack(Colors.Window))
    draw.FilledRect(window.X, window.Y + titleHeight, window.X + window.W, window.Y + window.H + titleHeight)

    -- Border
    if Style.WindowBorder then
        draw.Color(UnpackColor(Colors.WindowBorder))
        draw.OutlinedRect(window.X, window.Y, window.X + window.W, window.Y + window.H + titleHeight)
        draw.Line(window.X, window.Y + titleHeight, window.X + window.W, window.Y + titleHeight)
    end

    -- Mouse drag
    local mX, mY = table.unpack(input.GetMousePos())
    if clicked then
        window.DragPos = { X = mX - window.X, Y = mY - window.Y }
        window.IsDragging = true
    elseif not input.IsButtonDown(MOUSE_LEFT) and not clicked then
        window.IsDragging = false
    end

    if window.IsDragging then
        window.X = math.clamp(mX - window.DragPos.X, 0, screenWidth - window.W)
        window.Y = math.clamp(mY - window.DragPos.Y, 0, screenHeight - window.H - titleHeight)
    end

    -- Update the cursor
    ImMenu.Cursor.X = window.X
    ImMenu.Cursor.Y = window.Y + titleHeight

    ImMenu.BeginFrame()

    -- Store and push the window
    Windows[title] = window
    WindowStack:push(window)

    return true
end


-- Ends the current window
---@return ImWindow
function ImMenu.End()
    ---@type ImFrame
    local frame = ImMenu.EndFrame()
    local window = WindowStack:pop()

    -- Update the window size
    window.W = frame.W
    window.H = frame.H

    -- Draw late draw list
    ImMenu.LateDraw()

    return window
end

-- Runs the given function after the current window has been drawn
function ImMenu.DrawLate(func)
    table.insert(LateDrawList, func)
end

---@param x integer
---@param y integer
---@param func function
function ImMenu.Popup(x, y, func)
    ImMenu.DrawLate(function()
        inPopup = true

        -- Prepare cursor
        ImMenu.Cursor.X = x
        ImMenu.Cursor.Y = y

        -- Draw the popup | TODO: Add a popup frame background
        ImMenu.PushStyle("FramePadding", 0)
        ImMenu.PushStyle("ItemMargin", 0)
        ImMenu.BeginFrame()
        func()
        local frame = ImMenu.EndFrame()
        ImMenu.PopStyle(2)

        -- Close the popup if clicked outside of it
        if not Input.MouseInBounds(frame.X, frame.Y, frame.X + frame.W, frame.Y + frame.H) and MouseHelper:Pressed() then
            ImMenu.ActivePopup = nil
        end

        inPopup = false
    end)
end

-- Draw a label
---@param text string
function ImMenu.Text(text)
    local x, y = ImMenu.Cursor.X, ImMenu.Cursor.Y
    local label = ImMenu.GetLabel(text)
    local txtWidth, txtHeight = draw.GetTextSize(label)
    local width, height = ImMenu.GetSize(txtWidth, txtHeight)

    if type(Colors.Text) == "table" then
        draw.Color(math.floor(Colors.Text[1] or 0), math.floor(Colors.Text[2] or 0), math.floor(Colors.Text[3] or 0), math.floor(Colors.Text[4] or 255))
    end
    draw.Text(math.floor(x + (width - txtWidth) / 2), math.floor(y + (height - txtHeight) / 2), label)

    ImMenu.UpdateCursor(width, height)
end

---@param text string
---@param state boolean
---@return boolean state, boolean clicked
function ImMenu.Checkbox(text, state)
    local x, y = ImMenu.Cursor.X, ImMenu.Cursor.Y
    local label = ImMenu.GetLabel(text)
    local txtWidth, txtHeight = draw.GetTextSize(label)
    local boxSize = txtHeight + Style.ItemPadding * 2
    local width, height = ImMenu.GetSize(boxSize + Style.ItemMargin + txtWidth, boxSize)
    local hovered, clicked, active = ImMenu.GetInteraction(x, y, width, height, text)

    -- Box
    ImMenu.InteractionColor(hovered, active)
    draw.FilledRect(math.floor(x), math.floor(y), math.floor(x + boxSize), math.floor(y + boxSize))

    -- Border
    if Style.CheckboxBorder and type(Colors.Border) == "table" then
        draw.Color(math.floor(Colors.Border[1] or 0), math.floor(Colors.Border[2] or 0), math.floor(Colors.Border[3] or 0), math.floor(Colors.Border[4] or 255))
        draw.OutlinedRect(math.floor(x), math.floor(y), math.floor(x + boxSize), math.floor(y + boxSize))
    end

    -- Check
    if state then
        if type(Colors.Highlight) == "table" then
            draw.Color(math.floor(Colors.Highlight[1] or 0), math.floor(Colors.Highlight[2] or 0), math.floor(Colors.Highlight[3] or 0), math.floor(Colors.Highlight[4] or 255))
        end
        draw.FilledRect(math.floor(x + Style.ItemPadding), math.floor(y + Style.ItemPadding), math.floor(x + boxSize - Style.ItemPadding), math.floor(y + boxSize - Style.ItemPadding))
    end

    -- Text
    if type(Colors.Text) == "table" then
        draw.Color(math.floor(Colors.Text[1] or 0), math.floor(Colors.Text[2] or 0), math.floor(Colors.Text[3] or 0), math.floor(Colors.Text[4] or 255))
    end
    draw.Text(math.floor(x + boxSize + Style.ItemMargin), math.floor(y + (height - txtHeight) / 2), label)

    -- Update State
    if clicked then
        state = not state
    end

    ImMenu.UpdateCursor(width, height)
    return state, clicked
end

-- Draws a button
---@param text string
---@return boolean clicked, boolean active
function ImMenu.Button(text)
    -- Ensure text is a string
    if type(text) ~= "string" then
        error("Expected 'text' to be a string, got " .. type(text))
    end

    local x, y = ImMenu.Cursor.X, ImMenu.Cursor.Y
    local label = ImMenu.GetLabel(text)
    local txtWidth, txtHeight = draw.GetTextSize(label)
    local width, height = ImMenu.GetSize(txtWidth + Style.ItemPadding * 2, txtHeight + Style.ItemPadding * 2)
    local hovered, clicked, active = ImMenu.GetInteraction(x, y, width, height, text)

    -- Background
    ImMenu.InteractionColor(hovered, active)
    draw.FilledRect(math.floor(x), math.floor(y), math.floor(x + width), math.floor(y + height))

    if Style.ButtonBorder and type(Colors.Border) == "table" then
        draw.Color(math.floor(Colors.Border[1] or 0), math.floor(Colors.Border[2] or 0), math.floor(Colors.Border[3] or 0), math.floor(Colors.Border[4] or 255))
        draw.OutlinedRect(math.floor(x), math.floor(y), math.floor(x + width), math.floor(y + height))
    end

    -- Text
    if type(Colors.Text) == "table" then
        draw.Color(math.floor(Colors.Text[1] or 0), math.floor(Colors.Text[2] or 0), math.floor(Colors.Text[3] or 0), math.floor(Colors.Text[4] or 255))
    end
    draw.Text(math.floor(x + (width - txtWidth) / 2), math.floor(y + (height - txtHeight) / 2), label)

    if clicked then
        ImMenu.ActiveItem = nil
    end

    ImMenu.UpdateCursor(width, height)
    return clicked, active
end


---@param id Texture
function ImMenu.Texture(id)
    local x, y = ImMenu.Cursor.X, ImMenu.Cursor.Y
    local width, height = ImMenu.GetSize(draw.GetTextureSize(id))

    draw.Color(255, 255, 255, 255)
    draw.TexturedRect(id, x, y, x + width, y + height)

    if Style.Border then
        draw.Color(UnpackColor(Colors.Border))
        draw.OutlinedRect(x, y, x + width, y + height)
    end

    ImMenu.UpdateCursor(width, height)
end

-- Draws a slider that changes a value with fancy visual effects and text shadow
---@param text string
---@param value number
---@param min number
---@param max number
---@param step? number
---@return number value, boolean clicked
function ImMenu.Slider(text, value, min, max, step)
    step = step or 1
    local x, y = ImMenu.Cursor.X, ImMenu.Cursor.Y
    local label = string.format("%s: %s", ImMenu.GetLabel(text), value)
    local txtWidth, txtHeight = draw.GetTextSize(label)
    local width, height = ImMenu.GetSize(250, txtHeight + Style.ItemPadding * 2)
    local sliderWidth = math.floor(width * (value - min) / (max - min))
    local hovered, clicked, active = ImMenu.GetInteraction(x, y, width, height, text)

    -- Ensure sliderWidth is within bounds
    sliderWidth = math.max(0, math.min(sliderWidth, width))

    -- Background
    ImMenu.InteractionColor(hovered, active)
    draw.FilledRect(x, y, x + width, y + height)

    -- Slider
    draw.Color(UnpackColor(Colors.Highlight))
    draw.FilledRect(x, y, x + sliderWidth, y + height)

    -- Border
    if Style.SliderBorder then
        draw.Color(UnpackColor(Colors.Border))
        draw.OutlinedRect(x, y, x + width, y + height)
    end

    -- Add a glow effect at the end of the slider
    if sliderWidth > 1 then
        draw.Color(255, 255, 255, 150)
        draw.FilledRect(x + sliderWidth - 2, y - 2, x + sliderWidth + 2, y + height + 2)
    end


    -- Text with shadow
    draw.Color(0, 0, 0, 150)  -- Shadow color
    draw.TextShadow(x + (width // 2) - (txtWidth // 2) + 1, y + (height // 2) - (txtHeight // 2) + 1, label)  -- Draw shadow

    -- Higher contrast text color
    draw.Color(255, 255, 255, 255)  -- White color for the text
    draw.Text(x + (width // 2) - (txtWidth // 2), y + (height // 2) - (txtHeight // 2), label)


    -- Update Value
    if active then
        -- Mouse drag
        local mX, mY = table.unpack(input.GetMousePos())
        local percent = math.clamp((mX - x) / width, 0, 1)
        value = math.round((min + (max - min) * percent) / step) * step
    elseif hovered then
        -- Arrow keys
        if LeftArrow:Pressed() then
            value = math.max(value - step, min)
        elseif RightArrow:Pressed() then
            value = math.min(value + step, max)
        end
    end

    ImMenu.UpdateCursor(width, height)
    return value, clicked
end

-- Quadratic easing function for interpolation
local function easeInOutQuad(t)
    if t < 0.5 then
        return 2 * t * t
    else
        return -1 + (4 - 2 * t) * t
    end
end

-- Unpack a color from table
local function UnpackColor(color)
    return math.floor(color[1]), math.floor(color[2]), math.floor(color[3]), math.floor(color[4] or 255)
end

-- Draws a progress bar with fancy visual effects
---@param value number
---@param min number
---@param max number
---@param interpolate boolean optional
function ImMenu.Progress(value, min, max, interpolate)
    interpolate = interpolate or false

    local x, y = math.floor(ImMenu.Cursor.X or 0), math.floor(ImMenu.Cursor.Y or 0)
    local width, height = ImMenu.GetSize(250, 15)

    -- Ensure width and height are integers and not nil
    width = math.floor(width or 250)
    height = math.floor(height or 15)

    -- Ensure progress value is within bounds
    value = math.max(min, math.min(max, value))
    local targetProgressWidth = math.floor(width * (value - min) / (max - min))

    -- Initialize progress tracking if needed
    if not ImMenu.ProgressState then
        ImMenu.ProgressState = {
            currentWidth = targetProgressWidth,
            lastTargetWidth = targetProgressWidth,
            lastTick = globals.TickCount()
        }
    end

    -- Interpolation logic
    if interpolate then
        local currentTick = globals.TickCount()
        local elapsedTicks = currentTick - ImMenu.ProgressState.lastTick

        -- Adjust speed based on the distance from the target
        local distance = math.abs(targetProgressWidth - ImMenu.ProgressState.currentWidth)
        local speed = math.max(0.5, distance / 10) -- Adjust the divisor for speed control

        -- Smooth interpolation to the target value
        ImMenu.ProgressState.currentWidth = ImMenu.ProgressState.currentWidth + (targetProgressWidth - ImMenu.ProgressState.currentWidth) * easeInOutQuad(math.min(elapsedTicks / 10, 1))

        -- Update last target width and last tick for continuous interpolation
        ImMenu.ProgressState.lastTargetWidth = targetProgressWidth
        ImMenu.ProgressState.lastTick = currentTick
    else
        ImMenu.ProgressState.currentWidth = targetProgressWidth
    end

    local progressWidth = math.floor(ImMenu.ProgressState.currentWidth)

    -- Ensure progressWidth is within bounds
    progressWidth = math.max(0, math.min(progressWidth, width))

    -- Background
    draw.Color(UnpackColor(Colors.Item))
    draw.FilledRect(x, y, x + width, y + height)

    -- Progress
    draw.Color(0, 255, 0, 255)  -- Solid green color
    draw.FilledRect(x, y, x + progressWidth, y + height)

    -- Border
    if Style.Border then
        draw.Color(UnpackColor(Colors.Border))
        draw.OutlinedRect(x, y, x + width, y + height)
    end

    -- Add a thinner glow effect at the end of the progress bar
    if progressWidth > 0 then
        draw.Color(255, 255, 255, 150)
        draw.FilledRect(x + progressWidth - 1, y - 1, x + progressWidth + 1, y + height + 1)
    end

    ImMenu.UpdateCursor(width, height)
end



---@param label string
---@param text string
---@param charLimit? integer
---@return string text
function ImMenu.TextInput(label, text, charLimit)
    charLimit = charLimit or 50  -- Set default character limit to 50

    -- Initialize static variables for cursor and writing mode
    if not ImMenu.TextInputState then
        ImMenu.TextInputState = {
            cursorPos = #text,
            blinkTimer = globals.RealTime(),
            isWriting = false
        }
    end

    local state = ImMenu.TextInputState
    local x, y = ImMenu.Cursor.X, ImMenu.Cursor.Y
    local txtWidth, txtHeight = draw.GetTextSize(text)
    local defaultWidth, defaultHeight = 250, txtHeight + Style.ItemPadding * 2
    local width = math.max(defaultWidth, txtWidth + Style.ItemPadding * 2)
    local height = defaultHeight
    local txtY = y + (height // 2) - (txtHeight // 2)
    local hovered, clicked, active = ImMenu.GetInteraction(x, y, width, height, label)

    -- Toggle writing mode
    if clicked then
        state.isWriting = not state.isWriting
    elseif MouseHelper:Pressed() and not hovered and state.isWriting then
        state.isWriting = false
    end

    -- Adjust the width dynamically based on text size
    txtWidth, txtHeight = draw.GetTextSize(text)
    width = math.max(defaultWidth, txtWidth + Style.ItemPadding * 2)

    -- Background
    ImMenu.InteractionColor(hovered, state.isWriting)
    draw.FilledRect(x, y, x + width, y + height)

    -- Border
    draw.Color(UnpackColor(Colors.Border))
    draw.OutlinedRect(x, y, x + width, y + height)

    -- Text rendering
    draw.Color(UnpackColor(Colors.Text))
    local displayText = text
    local cursorX = x + Style.ItemPadding + draw.GetTextSize(text:sub(1, state.cursorPos))
    draw.Text(x + Style.ItemPadding, txtY, displayText)

    -- Simple blinking cursor
    if state.isWriting then
        local blinkPeriod = 1.0
        local shouldShowCursor = (globals.RealTime() - state.blinkTimer) % blinkPeriod < blinkPeriod / 2
        if shouldShowCursor then
            draw.Color(UnpackColor(Colors.Highlight))
            draw.FilledRect(cursorX, txtY, cursorX + 2, txtY + txtHeight)
        end
    end

    -- Text Input
    if state.isWriting then
        local key = GetInput()
        if key then
            if key == KEY_BACKSPACE then
                if state.cursorPos > 0 then
                    text = text:sub(1, state.cursorPos - 1) .. text:sub(state.cursorPos + 1)
                    state.cursorPos = math.max(0, state.cursorPos - 1)
                end
            elseif key == KEY_LEFT then
                state.cursorPos = math.max(0, state.cursorPos - 1)
            elseif key == KEY_RIGHT then
                state.cursorPos = math.min(#text, state.cursorPos + 1)
            elseif key == KEY_DELETE then
                if state.cursorPos < #text then
                    text = text:sub(1, state.cursorPos) .. text:sub(state.cursorPos + 2)
                end
            elseif key == KEY_HOME then
                state.cursorPos = 0
            elseif key == KEY_END then
                state.cursorPos = #text
            elseif key == KEY_SPACE then
                if #text < charLimit then
                    text = text:sub(1, state.cursorPos) .. " " .. text:sub(state.cursorPos + 1)
                    state.cursorPos = state.cursorPos + 1
                end
            elseif key == KEY_TAB then
                if #text < charLimit then
                    text = text:sub(1, state.cursorPos) .. "\t" .. text:sub(state.cursorPos + 1)
                    state.cursorPos = state.cursorPos + 1
                end
            else
                local char = Input.KeyToChar(key)
                if char and #text < charLimit then
                    if input.IsButtonDown(KEY_LSHIFT) then
                        char = char:upper()
                    else
                        char = char:lower()
                    end
                    text = text:sub(1, state.cursorPos) .. char .. text:sub(state.cursorPos + 1)
                    state.cursorPos = state.cursorPos + 1
                end
            end
            state.blinkTimer = globals.RealTime()  -- Reset blink timer on input
        end
    end

    -- Adjust cursor for the next item
    ImMenu.UpdateCursor(width, height)
    return text
end


---@param selected integer
---@param options any[]
---@return integer selected
function ImMenu.Option(selected, options)
    -- Check if the inputs are of the correct type
    if type(selected) ~= "number" then
        error("Expected a number for 'selected', got " .. type(selected))
    end
    if type(options) ~= "table" then
        error("Expected a table for 'options', got " .. type(options))
    end

    -- Handle empty options
    if #options == 0 then
        error("Options table is empty")
    end

    local txtWidth, txtHeight = draw.GetTextSize("#")
    local btnSize = txtHeight + 2 * Style.ItemPadding
    local width, height = ImMenu.GetSize(250, txtHeight)

    -- Begin frame for the option control
    ImMenu.PushStyle("ItemSize", { btnSize, btnSize })
    ImMenu.PushStyle("FramePadding", 0)
    ImMenu.BeginFrame(ImAlign.Horizontal)

    -- Last Item button
    if ImMenu.Button("<###prev") then
        selected = ((selected - 2) % #options) + 1
        print("Selected previous option:", selected)
    end

    -- Current Item display
    ImMenu.PushStyle("ItemSize", { width - (2 * btnSize) - (2 * Style.ItemMargin), btnSize })
    if options[selected] then
        ImMenu.Text(tostring(options[selected]))
    else
        ImMenu.Text("Invalid selection")
    end
    ImMenu.PopStyle()

    -- Next Item button
    if ImMenu.Button(">###next") then
        selected = (selected % #options) + 1
        print("Selected next option:", selected)
    end

    -- End frame and pop styles
    ImMenu.EndFrame()
    ImMenu.PopStyle(2)

    return selected
end


---@param text string
---@param items string[]
function ImMenu.List(text, items)
    local txtWidth, txtHeight = draw.GetTextSize(text)
    local width, height = ImMenu.GetSize(250, txtHeight + Style.ItemPadding * 2)

    ImMenu.PushStyle("FramePadding", 0)
    ImMenu.PushStyle("ItemSize", { width, height })
    ImMenu.BeginFrame()

    -- Title
    ImMenu.Text(text)

    -- Items
    for _, item in ipairs(items) do
        ImMenu.Button(tostring(item))
    end

    ImMenu.EndFrame()
    ImMenu.PopStyle(2)
end


---@param text string
---@param selected table
---@param options string[]
---@return table selected
function ImMenu.Combo(text, selected, options)
    local txtWidth, txtHeight = draw.GetTextSize(text)
    local width, height = ImMenu.GetSize(250, txtHeight + Style.ItemPadding * 2)

    -- Dropdown button
    ImMenu.PushStyle("ItemSize", { width, height })
    if ImMenu.Button(text) then
        ImMenu.ActivePopup = text
    end

    -- Dropdown popup
    if ImMenu.ActivePopup == text then
        ImMenu.Popup(ImMenu.Cursor.X, ImMenu.Cursor.Y, function()
            ImMenu.PushStyle("ItemSize", { width, height })

            for i, option in ipairs(options) do
                local isSelected = selected[i] or false
                if isSelected then
                    ImMenu.PushColor("Item", Colors.ItemActive) -- Highlight selected option
                end

                if ImMenu.Button(tostring(option)) then
                    selected[i] = not selected[i]
                end

                if isSelected then
                    ImMenu.PopColor()
                end
            end

            ImMenu.PopStyle(1)
        end)
    end

    ImMenu.PopStyle()

    return selected
end

---@param tabs table<string, boolean>|table<number, string>
---@param currentTab string
---@return string currentTab
function ImMenu.TabControl(tabs, currentTab)
    if type(tabs) ~= "table" then
        error("Expected 'tabs' to be a table, got " .. type(tabs))
    end
    if type(currentTab) ~= "string" then
        error("Expected 'currentTab' to be a string, got " .. type(currentTab))
    end

    ImMenu.PushStyle("FramePadding", 5)
    ImMenu.PushStyle("ItemSize", {100, 25})
    ImMenu.PushStyle("Spacing", {5, 5})
    ImMenu.BeginFrame(1)

    -- Use ipairs if 'tabs' is an array, otherwise use pairs.
    if #tabs > 0 then
        for _, tabName in ipairs(tabs) do
            if ImMenu.Button(tabName) then
                currentTab = tabName
            end
        end
    else
        for tabName, _ in pairs(tabs) do
            if ImMenu.Button(tabName) then
                currentTab = tabName
            end
        end
    end

    ImMenu.EndFrame()
    ImMenu.PopStyle(3)

    return currentTab
end

local function GetPressedkeyAndMouse()
    local pressedKey = Input.GetPressedKey()
        if not pressedKey then
            -- Check for standard mouse buttons
            if input.IsButtonDown(MOUSE_LEFT) then return MOUSE_LEFT end
            if input.IsButtonDown(MOUSE_RIGHT) then return MOUSE_RIGHT end
            if input.IsButtonDown(MOUSE_MIDDLE) then return MOUSE_MIDDLE end

            -- Check for additional mouse buttons
            for i = 1, 10 do
                if input.IsButtonDown(MOUSE_FIRST + i - 1) then return MOUSE_FIRST + i - 1 end
            end
        end
    return pressedKey
end

local bindTimers = {}
local bindDelays = {}
local keybindStates = {}
local keybindModes = {}
local keybindActiveStates = {}
local keybindModeSelection = {}

---@param text string
function ImMenu.GetKeybind(text)
    local mode = keybindModes[text]
    local keybind = keybindStates[text] and GetPressedkeyAndMouse() or 0

    if mode == "Always On" then
        return true
    elseif mode == "Always Off" then
        return false
    elseif mode == "Press to Toggle" then
        if input.IsButtonDown(keybind) and not bindTimers[text .. "_Toggle"] then
            keybindActiveStates[text] = not keybindActiveStates[text]
            bindTimers[text .. "_Toggle"] = os.clock() + 0.25
        end
        if bindTimers[text .. "_Toggle"] and os.clock() > bindTimers[text .. "_Toggle"] then
            bindTimers[text .. "_Toggle"] = nil
        end
        return keybindActiveStates[text]
    elseif mode == "Hold to Use" then
        return input.IsButtonDown(keybind)
    end

    return false
end

---@param text string
function ImMenu.Keybind(text)
    local x, y = ImMenu.Cursor.X, ImMenu.Cursor.Y
    local defaultWidth, height = ImMenu.GetSize(250, 25)

    -- Initialize state for this keybind
    if not bindTimers[text] then
        bindTimers[text] = 0
        bindDelays[text] = 0.25  -- Delay of 0.25 seconds
        keybindStates[text] = "Always On"
        keybindModes[text] = "Always On"
        keybindActiveStates[text] = true
        keybindModeSelection[text] = false
    end

    -- Determine the label based on the current state
    local displayLabel = keybindStates[text]
    if keybindStates[text] == "Press The Key" then
        displayLabel = "Press the key"
    end

    local label = text .. ": " .. displayLabel .. " (" .. keybindModes[text] .. ")"
    local txtWidth, txtHeight = draw.GetTextSize(label)
    local width = math.max(defaultWidth, txtWidth + Style.ItemPadding * 2)
    local hovered, clicked, active = ImMenu.GetInteraction(x, y, width, height, text)

    -- Background
    ImMenu.InteractionColor(hovered, active)
    draw.FilledRect(x, y, x + width, y + height)

    -- Border
    if Style.ButtonBorder then
        draw.Color(UnpackColor(Colors.Highlight))
        draw.OutlinedRect(x, y, x + width, y + height)
    end

    -- Handle key binding process
    if keybindStates[text] ~= "Press The Key" and clicked then
        bindTimers[text] = os.clock() + bindDelays[text]
        keybindStates[text] = "Press The Key"
    end

    if keybindStates[text] == "Press The Key" then
        if os.clock() >= bindTimers[text] then
            local pressedKey = GetPressedkeyAndMouse()
            if pressedKey then
                if pressedKey == KEY_ESCAPE then
                    -- Reset keybind if the Escape key is pressed
                    keybindStates[text] = "Always On"
                    keybindModes[text] = "Always On"
                    Notify.Simple("Keybind Success", "Bound Key: " .. keybindStates[text], 2)
                else
                    -- Update keybind with the pressed key
                    keybindStates[text] = Input.GetKeyName(pressedKey)
                    Notify.Simple("Keybind Success", "Bound Key: " .. keybindStates[text], 2)
                end
            end
        end
    end

    -- Right-click to select mode
    if input.IsButtonPressed(MOUSE_RIGHT) and Input.MouseInBounds(x, y, x + width, y + height) then
        ImMenu.ActivePopup = text .. "_Mode"
    end

    if ImMenu.ActivePopup == text .. "_Mode" then
        ImMenu.Popup(ImMenu.Cursor.X + width + 1, ImMenu.Cursor.Y, function()
            if ImMenu.Button("Always On") then
                keybindModes[text] = "Always On"
                ImMenu.ActivePopup = nil
            elseif ImMenu.Button("Always Off") then
                keybindModes[text] = "Always Off"
                ImMenu.ActivePopup = nil
            elseif ImMenu.Button("Press to Toggle") then
                keybindModes[text] = "Press to Toggle"
                ImMenu.ActivePopup = nil
            elseif ImMenu.Button("Hold to Use") then
                keybindModes[text] = "Hold to Use"
                ImMenu.ActivePopup = nil
            end
        end)
    end

    -- Display the current keybind name and mode
    label = text .. ": " .. displayLabel .. " (" .. keybindModes[text] .. ")"
    txtWidth, txtHeight = draw.GetTextSize(label)
    draw.Color(UnpackColor(Colors.Text))
    draw.Text(x + (width // 2) - (txtWidth // 2), y + (height // 2) - (txtHeight // 2), label)

    ImMenu.UpdateCursor(width, height)
end


lnxLib.UI.Notify.Simple("ImMenu loaded", string.format("Version: %.2f", ImMenu.GetVersion()))

return ImMenu
end)
__bundle_register("Cheater_Detection.Database.Manager", function(require, _LOADED, __bundle_register, __bundle_modules)
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

end)
__bundle_register("Cheater_Detection.Database.Database_Fetcher", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Minimal Database_Fetcher.lua that just works
    No bloat, just gets data and adds it to the database
]]

local Common = require("Cheater_Detection.Utils.Common")
local Tasks = require("Cheater_Detection.Database.Tasks")
local Sources = require("Cheater_Detection.Database.Sources")
local Commands = Common.Lib.Utils.Commands -- Use existing Commands
local Json = Common.Json -- Added for JSON parsing

-- Helper function to convert SteamID3 or SteamID to SteamID64 if needed
-- Assumes a global or Common.steam table with ToSteamID64 exists
local function GetSteamID64(id_str)
	if not id_str then
		return nil
	end
	id_str = id_str:match("^%s*(.-)%s*$") -- Trim

	if id_str:match("^765611%d%d%d%d%d%d%d%d%d%d%d$") then
		return id_str -- Already SteamID64
	elseif id_str:match("^STEAM_0:[01]:%d+$") or id_str:match("^%[U:1:%d+%]$") then
		local success, result = pcall(steam.ToSteamID64, id_str) -- Assumes steam.ToSteamID64 exists
		if success and result then
			print(string.format("[Fetcher DEBUG Convert] Converted '%s' to '%s'", id_str, result))
			return result
		else
			print(string.format("[Fetcher DEBUG Convert] Failed to convert '%s'", id_str))
			return nil
		end
	else
		-- Optional: Could try Common.FromSteamid32To64 if applicable
		-- print(string.format("[Fetcher DEBUG Convert] Unrecognized format: '%s'", id_str))
		return nil
	end
end

-- Create fetcher object
local Fetcher = {
	Config = {
		AutoFetchOnLoad = false,
		ShowProgressBar = true,
		SourceDelay = 2, -- Fixed 2 second delay
		LinesPerFrame = 250, -- How many lines to process per frame (for non-JSON)
	},
	Sources = Sources.List,
	Tasks = Tasks, -- Keep reference for UI

	-- State variables for Draw-based processing
	isRunning = false,
	fetchState = "idle", -- idle, delaying, downloading, processing_json, processing_lines, saving, done, download_error
	currentSourceIndex = 0,
	currentSourceContentLines = nil, -- Table of lines from downloaded content (for line processing)
	currentSourceProcessedLineIndex = 0,
	currentSourceAddedCount = 0, -- Added count for the current source
	totalAdded = 0,
	databaseRef = nil,
	callbackRef = nil,
	isSilent = false,
	lastActionTime = 0,
	downloadCoroutine = nil, -- Coroutine for http.Get
	downloadContent = nil, -- Temp storage for downloaded content
}

-- Helper to reset fetch state
function Fetcher.ResetState()
	Fetcher.isRunning = false
	Fetcher.fetchState = "idle"
	Fetcher.currentSourceIndex = 0
	Fetcher.currentSourceContentLines = nil
	Fetcher.currentSourceProcessedLineIndex = 0
	Fetcher.currentSourceAddedCount = 0
	Fetcher.totalAdded = 0
	Fetcher.databaseRef = nil
	Fetcher.callbackRef = nil
	Fetcher.isSilent = false
	Fetcher.lastActionTime = 0
	Fetcher.downloadCoroutine = nil
	Fetcher.downloadContent = nil

	-- Reset Tasks UI state as well
	Tasks.Reset()

	-- Unregister callbacks safely
	pcall(function()
		callbacks.Unregister("Draw", "FetcherMain")
	end)
	pcall(function()
		callbacks.Unregister("Draw", "FetcherUI")
	end)
	pcall(function()
		callbacks.Unregister("Draw", "FetcherSaveDelay")
	end)
end

-- Function to split string by newline characters
local function splitlines(str)
	local lines = {}
	for line in str:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end
	return lines
end

-- Process a JSON data structure (e.g., from bots.tf)
function Fetcher.ProcessJsonData(jsonData, source, db)
	local addedCount = 0
	if not jsonData or type(jsonData) ~= "table" then
		print(string.format("[Fetcher ERROR JSON] Invalid JSON data received for %s", source.name))
		return 0
	end

	-- Heuristic check for bots.tf structure (or similar list-based JSON)
	local players = jsonData.players or jsonData -- Adapt if root is the list
	if type(players) ~= "table" then
		print(string.format("[Fetcher ERROR JSON] Could not find player list in JSON for %s", source.name))
		return 0
	end

	print(string.format("[Fetcher DEBUG JSON] Processing %d potential players from %s", #players, source.name))

	for i, playerEntry in ipairs(players) do
		if type(playerEntry) == "table" and playerEntry.steamid then
			local steamID64 = GetSteamID64(playerEntry.steamid) -- Use conversion helper

			if steamID64 then
				print(
					string.format(
						"[Fetcher DEBUG JSON Check] steamID64: %s, DB entry exists: %s",
						tostring(steamID64),
						tostring(db.data[steamID64])
					)
				)
				if not db.data[steamID64] then
					print(string.format("[Fetcher DEBUG JSON ADD] Attempting to add: %s", steamID64))
					local success, err = pcall(db.HandleSetEntry, steamID64, {
						Name = "Unknown", -- Can potentially extract name if available: playerEntry.last_seen and playerEntry.last_seen.player_name or "Unknown"
						Reason = source.cause, -- Can potentially extract attributes: playerEntry.attributes and table.concat(playerEntry.attributes, ", ") or source.cause
					})
					if success then
						addedCount = addedCount + 1
						print(string.format("[Fetcher DEBUG JSON ADD] Successfully added: %s", steamID64))
						pcall(function()
							playerlist.SetPriority(steamID64, 10)
						end)
					else
						print(string.format("[Fetcher ERROR JSON ADD] Failed to add %s: %s", steamID64, tostring(err)))
					end
				end
			else
				print(
					string.format(
						"[Fetcher DEBUG JSON] Skipping invalid/unconvertible SteamID: %s",
						tostring(playerEntry.steamid)
					)
				)
			end
		else
			print(string.format("[Fetcher DEBUG JSON] Skipping invalid player entry at index %d", i))
		end
	end
	return addedCount
end

-- Processes a single line based on parser type (used for 'raw' or JSON fallback)
function Fetcher.ProcessLine(line, source, database)
	local added = false
	line = line:match("^%s*(.-)%s*$") -- Trim whitespace

	-- Skip comments and empty lines
	if line == "" or line:match("^%-%-") or line:match("^#") or line:match("^//") then
		return false
	end

	local steamID64 = nil
	if source.parser == "raw" then
		-- Try to convert different formats to SteamID64
		steamID64 = GetSteamID64(line)
		if steamID64 then
			print(
				string.format(
					"[Fetcher DEBUG RAW] Extracted/Converted: %s, Exists in DB: %s",
					steamID64,
					tostring(database.data[steamID64])
				)
			)
		else
			print(string.format("[Fetcher DEBUG RAW] Invalid format or failed conversion: %s", line))
		end
	elseif source.parser == "tf2db" then
		-- This is now a fallback if JSON parsing failed, try simple regex
		local extractedId = line:match("(765611%d%d%d%d%d%d%d%d%d%d%d)") -- General match
		steamID64 = GetSteamID64(extractedId) -- Attempt conversion just in case
		if steamID64 then
			print(
				string.format(
					"[Fetcher DEBUG TF2DB Fallback] Extracted/Converted: %s, Exists in DB: %s",
					steamID64,
					tostring(database.data[steamID64])
				)
			)
		else
			-- Don't print "No match found" here as it's expected for most lines in JSON fallback
			-- print(string.format("[Fetcher DEBUG TF2DB Fallback] No valid ID found in line: %s", line))
		end
	end

	-- Add valid IDs to database if not already present
	print(
		string.format(
			"[Fetcher DEBUG Check] steamID64: %s, DB entry exists: %s",
			tostring(steamID64),
			tostring(database.data[steamID64])
		)
	)
	if steamID64 and not database.data[steamID64] then -- Use database instance here
		-- DEBUG: Log before attempting to add
		print(string.format("[Fetcher DEBUG ADD] Attempting to add: %s", steamID64))
		local success, err = pcall(database.HandleSetEntry, steamID64, { -- Use database instance here
			Name = "Unknown", -- Set name to Unknown as requested
			Reason = source.cause,
		})
		if success then
			added = true
			-- DEBUG: Log successful addition
			print(string.format("[Fetcher DEBUG ADD] Successfully added: %s", steamID64))
			-- Set player priority (optional, keep pcall)
			pcall(function()
				playerlist.SetPriority(steamID64, 10)
			end)
		else
			-- DEBUG: Log failure to add
			print(string.format("[Fetcher ERROR ADD] Failed to add %s: %s", steamID64, tostring(err)))
		end
	end

	return added
end

-- Main processing function called by Draw callback
function Fetcher.ProcessStep()
	if not Fetcher.isRunning then
		Fetcher.ResetState() -- Ensure cleanup if stopped externally
		return
	end

	local db = Fetcher.databaseRef
	if not db then
		print("[Fetcher] Error: Database reference lost.")
		Fetcher.ResetState()
		return
	end

	local currentTime = globals.RealTime()
	local source = Fetcher.Sources[Fetcher.currentSourceIndex]
	local sourceName = source and (source.name or "Unknown Source") or "Finalizing"

	-- State Machine
	if Fetcher.fetchState == "delaying" then
		local elapsed = currentTime - Fetcher.lastActionTime
		local remaining = math.ceil(Fetcher.Config.SourceDelay - elapsed)
		if elapsed >= Fetcher.Config.SourceDelay then
			Fetcher.fetchState = "downloading"
			Fetcher.downloadCoroutine = nil -- Ensure coroutine is reset before starting new download
			Fetcher.downloadContent = nil
			Tasks.StartSource(sourceName) -- Update progress when starting download attempt
			Tasks.targetProgress = (Fetcher.currentSourceIndex - 1) / #Fetcher.Sources * 100
			Tasks.message = "Starting download from " .. sourceName .. "..."
		else
			Tasks.message = "Waiting " .. remaining .. "s between requests..."
		end
	elseif Fetcher.fetchState == "downloading" then
		-- Start download coroutine if not already started
		if not Fetcher.downloadCoroutine then
			Tasks.message = "Starting download from " .. sourceName .. "..." -- Initial message
			Fetcher.downloadCoroutine = coroutine.create(function(url)
				local ok, res1, res2 = pcall(http.Get, url)
				if not ok then
					return false, res1
				end
				return true, res1, res2
			end)
			Fetcher.downloadContent = nil -- Clear previous content
		end

		-- Resume the download coroutine
		local status, coroutine_ran_ok, get_pcall_ok, result1, result2 =
			pcall(coroutine.resume, Fetcher.downloadCoroutine, source.url)

		if not status then -- Error resuming coroutine itself (very rare)
			print("[Fetcher] Error resuming download coroutine: " .. tostring(coroutine_ran_ok)) -- coroutine_ran_ok here is the error msg
			Fetcher.fetchState = "download_error"
		elseif coroutine.status(Fetcher.downloadCoroutine) == "suspended" then
			Tasks.message = "Downloading from " .. sourceName .. "... (in progress)"
		elseif coroutine.status(Fetcher.downloadCoroutine) == "dead" then
			Fetcher.downloadCoroutine = nil -- Clear the finished coroutine

			if not coroutine_ran_ok then
				print(
					"[Fetcher] Error inside download coroutine function for "
						.. sourceName
						.. ": "
						.. tostring(get_pcall_ok)
				)
				Fetcher.fetchState = "download_error"
			elseif not get_pcall_ok then
				print("[Fetcher] Failed http.Get for " .. sourceName .. ". Reason: " .. tostring(result1))
				Fetcher.fetchState = "download_error"
			elseif type(result1) == "string" then
				print(
					string.format(
						"[Fetcher DEBUG] Received content from %s (first 200 chars): %s",
						sourceName,
						result1:sub(1, 200)
					)
				)

				if #result1 > 0 then
					-- Success! Store content and decide processing method
					Fetcher.downloadContent = result1 -- Store full content
					result1 = nil -- Allow GC for the potentially large string copy
					collectgarbage("collect")

					Fetcher.currentSourceAddedCount = 0 -- Reset count for this source

					-- Decide processing method based on parser type
					if source.parser == "tf2db" then
						Fetcher.fetchState = "processing_json" -- Try JSON first
						Tasks.message = "Attempting JSON parse for " .. sourceName
					else -- Assume 'raw' or other line-based
						Fetcher.fetchState = "processing_lines"
						Fetcher.currentSourceContentLines = splitlines(Fetcher.downloadContent)
						Fetcher.downloadContent = nil -- Content split into lines, free original
						collectgarbage("collect")
						Fetcher.currentSourceProcessedLineIndex = 1
						Tasks.message = "Processing lines for " .. sourceName
					end
				else
					print("[Fetcher] Failed to download from " .. sourceName .. ". Reason: Returned empty string")
					Fetcher.fetchState = "download_error"
				end
			else
				-- Handle other http.Get failures (nil, false, etc.)
				local failureReason = "Unknown http.Get failure"
				if result1 == nil then
					failureReason = "Returned nil" .. (result2 and (" (Info: " .. tostring(result2) .. ")") or "")
				elseif result1 == false then
					failureReason = "Returned false" .. (result2 and (" (Info: " .. tostring(result2) .. ")") or "")
				else
					failureReason = "Returned type: "
						.. type(result1)
						.. " ("
						.. tostring(result1)
						.. ")"
						.. (result2 and (", Info: " .. tostring(result2)) or "")
				end
				print("[Fetcher] Failed to download from " .. sourceName .. ". Reason: " .. failureReason)
				Fetcher.fetchState = "download_error"
			end
			Fetcher.lastActionTime = currentTime -- Update time after download attempt finished
		end -- End of coroutine status check
	elseif Fetcher.fetchState == "download_error" then
		-- Handle download error (skip to next source)
		print("[Fetcher] Skipping source due to download error: " .. sourceName)
		-- **Print count before skipping**
		print(
			"[Fetcher] Added " .. Fetcher.currentSourceAddedCount .. " entries from " .. sourceName .. " (before skip)"
		)
		Fetcher.totalAdded = Fetcher.totalAdded + Fetcher.currentSourceAddedCount -- Add to total even if skipped

		Fetcher.currentSourceIndex = Fetcher.currentSourceIndex + 1
		Fetcher.lastActionTime = currentTime
		if Fetcher.currentSourceIndex > #Fetcher.Sources then
			Fetcher.fetchState = "saving"
		else
			Fetcher.fetchState = "delaying"
		end
		Fetcher.downloadCoroutine = nil
		Fetcher.downloadContent = nil
	elseif Fetcher.fetchState == "processing_json" then
		-- Attempt to parse the stored content as JSON
		local success, jsonData = pcall(Json.decode, Fetcher.downloadContent)
		Fetcher.downloadContent = nil -- Clear original content string
		collectgarbage("collect")

		if success and jsonData then
			print("[Fetcher] Successfully parsed JSON for " .. sourceName)
			-- Process the JSON data structure (this might take time, but not frame-limited here)
			local addedFromJson = Fetcher.ProcessJsonData(jsonData, source, db)
			Fetcher.currentSourceAddedCount = Fetcher.currentSourceAddedCount + addedFromJson
			print("[Fetcher] Finished processing JSON for " .. sourceName)
			-- Since JSON processing is done in one go, move to next source/state
			Fetcher.fetchState = "source_done"
		else
			-- JSON parsing failed, fall back to line processing
			print("[Fetcher] Failed to parse JSON for " .. sourceName .. ". Falling back to line processing.")
			-- Resplit the original content (need to refetch or store it differently?)
			-- For now, let's just skip this source if JSON fails and it was tf2db
			-- TODO: Re-evaluate if fallback line processing is desired/possible after failed JSON parse
			print("[Fetcher] Skipping source " .. sourceName .. " after failed JSON parse.")
			Fetcher.fetchState = "source_done" -- Treat as done, even though failed
		end
	elseif Fetcher.fetchState == "processing_lines" then
		-- Process lines per frame (for 'raw' or 'tf2db' fallback)
		local linesProcessedThisFrame = 0
		local totalLines = #Fetcher.currentSourceContentLines

		while
			linesProcessedThisFrame < Fetcher.Config.LinesPerFrame
			and Fetcher.currentSourceProcessedLineIndex <= totalLines
		do
			local line = Fetcher.currentSourceContentLines[Fetcher.currentSourceProcessedLineIndex]
			if Fetcher.ProcessLine(line, source, db) then
				Fetcher.currentSourceAddedCount = Fetcher.currentSourceAddedCount + 1
				-- Fetcher.totalAdded = Fetcher.totalAdded + 1 -- Move totalAdded increment to 'source_done'
			end
			Fetcher.currentSourceProcessedLineIndex = Fetcher.currentSourceProcessedLineIndex + 1
			linesProcessedThisFrame = linesProcessedThisFrame + 1
		end

		Tasks.message = string.format(
			"Processing Lines %s: %d / %d (%d added)",
			sourceName,
			Fetcher.currentSourceProcessedLineIndex - 1,
			totalLines,
			Fetcher.currentSourceAddedCount
		)

		if Fetcher.currentSourceProcessedLineIndex > totalLines then
			Fetcher.currentSourceContentLines = nil -- Allow GC
			collectgarbage("collect")
			Fetcher.fetchState = "source_done" -- Finished processing lines for this source
		end
	elseif Fetcher.fetchState == "source_done" then
		-- This state is reached after processing_json or processing_lines finishes
		print("[Fetcher] Added " .. Fetcher.currentSourceAddedCount .. " entries from " .. sourceName)
		Tasks.SourceDone() -- Mark source done in UI tracker
		Fetcher.totalAdded = Fetcher.totalAdded + Fetcher.currentSourceAddedCount -- Add source total to overall total

		-- Move to next source or finish
		Fetcher.currentSourceIndex = Fetcher.currentSourceIndex + 1
		Fetcher.lastActionTime = currentTime
		if Fetcher.currentSourceIndex > #Fetcher.Sources then
			Fetcher.fetchState = "saving" -- All sources processed
		else
			Fetcher.fetchState = "delaying" -- Need to delay before next source
		end
	elseif Fetcher.fetchState == "saving" then
		Tasks.message = "Finalizing..."
		Tasks.targetProgress = 100
		if Fetcher.totalAdded > 0 then
			db.State.isDirty = true
			pcall(function()
				callbacks.Unregister("Draw", "FetcherSaveDelay")
			end)
			callbacks.Register("Draw", "FetcherSaveDelay", function()
				callbacks.Unregister("Draw", "FetcherSaveDelay")
				if db and db.SaveDatabase then
					print("[Fetcher] Saving database changes...")
					db.SaveDatabase()
				else
					print("[Fetcher] Error: Could not save database.")
				end
				Fetcher.fetchState = "done"
				Fetcher.lastActionTime = globals.RealTime()
			end)
			Fetcher.fetchState = "waiting_save"
			Tasks.message = "Saving Database..."
		else
			Fetcher.fetchState = "done"
			Fetcher.lastActionTime = currentTime
		end
	elseif Fetcher.fetchState == "waiting_save" then
		Tasks.message = "Saving Database..."
	elseif Fetcher.fetchState == "done" then
		Tasks.status = "complete"
		Tasks.message = "Update Complete: Added " .. Fetcher.totalAdded .. " entries"
		Tasks.completedTime = Fetcher.lastActionTime

		print("[Fetcher] " .. Tasks.message)

		if Fetcher.callbackRef and type(Fetcher.callbackRef) == "function" then
			pcall(Fetcher.callbackRef, Fetcher.totalAdded)
		end

		Fetcher.ResetState() -- Final cleanup
	end
end

-- UI Drawing Function
function Fetcher.DrawUI()
	if Fetcher.isRunning and not Fetcher.isSilent then
		pcall(Tasks.DrawProgressUI)
	else
		-- Auto-unregister if no longer needed
		pcall(function()
			callbacks.Unregister("Draw", "FetcherUI")
		end)
	end
end

-- Start the fetch process (replaces FetchAll)
function Fetcher.StartFetch(database, callback, silent)
	-- Don't start if already running
	if Fetcher.isRunning then
		print("[Fetcher] Fetch operation already in progress.")
		return false
	end

	-- Ensure database is provided
	if not database then
		print("[Fetcher] Error: Database object not provided for fetching.")
		return false
	end

	-- Reset state and initialize
	Fetcher.ResetState() -- Clean slate
	Tasks.Init(#Fetcher.Sources) -- Init UI tasks

	Fetcher.isRunning = true
	Fetcher.isSilent = silent or false
	Fetcher.databaseRef = database
	Fetcher.callbackRef = callback
	Fetcher.totalAdded = 0
	Fetcher.currentSourceIndex = 1 -- Start with the first source
	Fetcher.lastActionTime = globals.RealTime()

	-- Initial state depends on whether there are sources
	if #Fetcher.Sources > 0 then
		Fetcher.fetchState = "downloading" -- Start downloading first source immediately (no initial delay)
		Tasks.StartSource(Fetcher.Sources[1].name or "Unknown Source") -- Update UI task for first source
		Tasks.targetProgress = 0 -- Start progress at 0
		Tasks.message = "Starting download..."
	else
		Fetcher.fetchState = "saving" -- No sources, go directly to saving/completion
		Tasks.message = "No sources configured."
	end

	-- Register necessary Draw callbacks
	callbacks.Register("Draw", "FetcherMain", Fetcher.ProcessStep)
	if not Fetcher.isSilent then
		callbacks.Register("Draw", "FetcherUI", Fetcher.DrawUI)
	end

	print("[Fetcher] Starting database update...")
	return true
end

-- Auto fetch handler
function Fetcher.AutoFetch(database)
	if not database then
		local success, db = pcall(function()
			return require("Cheater_Detection.Database.Database")
		end)

		if not success or not db then
			print("[Fetcher] AutoFetch failed: Could not load Database module.")
			return false
		end
		database = db
	end

	print("[Fetcher] Starting AutoFetch...")
	-- Use the new StartFetch function
	return Fetcher.StartFetch(database, function(totalAdded)
		if totalAdded > 0 then
			printc(80, 200, 120, 255, "[Database] Auto-updated with " .. totalAdded .. " new entries")
		else
			print("[Fetcher] AutoFetch complete: No new entries added.")
		end
	end, not Fetcher.Config.ShowProgressBar)
end

-- Register only essential commands
Commands.Register("cd_fetch", function()
	if not Fetcher.isRunning then
		local Database = require("Cheater_Detection.Database.Database")
		if not Database then
			print("[cd_fetch] Error: Could not load Database module.")
			return
		end
		Fetcher.StartFetch(Database, function(totalAdded) -- Add a simple callback for manual fetch
			print("[Fetcher] Manual fetch complete. Added " .. totalAdded .. " entries.")
		end)
	else
		print("[Database Fetcher] A fetch operation is already in progress")
	end
end, "Fetch all cheater lists and update the database")

Commands.Register("cd_cancel", function()
	if Fetcher.isRunning then
		print("[Database Fetcher] Cancelling operation...")
		Fetcher.ResetState() -- Resets state and unregisters callbacks
		print("[Database Fetcher] Cancelled fetch operation.")
	else
		print("[Database Fetcher] No fetch operation is currently running.")
	end
end, "Cancel any running fetch operations")

-- Auto-fetch on load if enabled
if Fetcher.Config.AutoFetchOnLoad then
	pcall(function()
		callbacks.Unregister("Draw", "FetcherAutoLoad")
	end)

	-- Delay auto-fetch slightly to allow other scripts to load
	callbacks.Register("Draw", "FetcherAutoLoad", function()
		callbacks.Unregister("Draw", "FetcherAutoLoad")
		print("[Fetcher] Triggering AutoFetch on load...")
		Fetcher.AutoFetch()
	end)
end

return Fetcher

end)
__bundle_register("Cheater_Detection.Database.Database", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Simplified Database.lua
    Direct implementation of database functionality using native Lua tables
    Stores only essential data: name and proof for each SteamID64
]]

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Json = Common.Json
local Database_Fetcher = require("Cheater_Detection.Database.Database_Fetcher")

-- Helper function to serialize a Lua table into a string format
local function serializeTableToLuaString(tbl, level)
	level = level or 0
	local indent = string.rep("  ", level)
	local result = "{\n"

	local keys = {}
	for k in pairs(tbl) do
		table.insert(keys, k)
	end
	table.sort(keys) -- Sort keys for consistent output

	for i, key in ipairs(keys) do
		local value = tbl[key]
		result = result .. indent .. "  "

		-- Format key (assuming keys are SteamID64 strings)
		result = result .. '["' .. tostring(key) .. '"] = '

		-- Format value (assuming value is a table with Name and Reason)
		if type(value) == "table" then
			local nameStr = value.Name or "Unknown"
			local reasonStr = value.Reason or value.proof or "Unknown" -- Use Reason primarily

			-- Escape quotes and backslashes in strings
			nameStr = nameStr:gsub('[\\"]', "\\%1")
			reasonStr = reasonStr:gsub('[\\"]', "\\%1")

			result = result .. '{ Name = "' .. nameStr .. '", Reason = "' .. reasonStr .. '" }'
		else
			-- Fallback for unexpected data types (shouldn't happen with proper structure)
			result = result .. '"' .. tostring(value):gsub('[\\"]', "\\%1") .. '"'
		end

		-- Add comma if not the last element
		if i < #keys then
			result = result .. ","
		end
		result = result .. "\n"
	end

	result = result .. indent .. "}"
	return result
end

local Database = {
	-- Internal data storage (direct table)
	data = {},

	-- Configuration
	Config = {
		AutoSave = true,
		SaveInterval = 300, -- 5 minutes
		DebugMode = false,
		MaxEntries = 15000, -- Maximum entries to prevent memory issues
	},

	-- State tracking
	State = {
		entriesCount = 0,
		isDirty = false,
		lastSave = 0,
	},
}

-- Create the content accessor with metatable for cleaner API
Database.content = setmetatable({}, {
	__index = function(_, key)
		return Database.data[key]
	end,

	__newindex = function(_, key, value)
		Database.HandleSetEntry(key, value)
	end,

	__pairs = function()
		return pairs(Database.data)
	end,
})

-- Handle setting an entry with optimized record updating
function Database.HandleSetEntry(key, value)
	-- DEBUG: Log function call
	-- print(string.format("[Database DEBUG Call] HandleSetEntry called with key: %s, value type: %s", tostring(key), type(value)))

	-- Skip nil values or invalid keys
	if not key then
		return
	end

	-- Ensure key is a valid SteamID64 format before adding/updating
	if type(key) ~= "string" or not key:match("^765611%d{11}$") then
		-- DEBUG: Log invalid key rejection
		-- print(string.format("[Database DEBUG Reject] Invalid SteamID64 format for key: %s", tostring(key)))
		-- Optionally print a warning for invalid keys?
		-- print("[Database] Warning: Attempted to set entry with invalid SteamID64 key: " .. tostring(key))
		return
	end
	-- DEBUG: Log key validation success
	-- print(string.format("[Database DEBUG Valid] Key %s passed validation.", key))

	-- Get existing entry
	local existing = Database.data[key]

	-- If removing an entry
	if value == nil then
		if existing then
			Database.data[key] = nil
			Database.State.entriesCount = Database.State.entriesCount - 1
			Database.State.isDirty = true
		end
		return
	end

	-- If adding a new entry
	if not existing then
		-- DEBUG: Log adding new entry
		-- print(string.format("[Database DEBUG ADD] Adding new entry for key: %s", key))
		-- Simplified data structure - keep only Name and Reason
		Database.data[key] = {
			Name = type(value) == "table" and (value.Name or "Unknown") or "Unknown",
			Reason = type(value) == "table" and (value.Reason or value.proof or value.cause or "Unknown") or "Unknown", -- Prioritize Reason
		}
		-- DEBUG: Log entry after add attempt
		-- print(string.format("[Database DEBUG Added] Entry state for %s: Name='%s', Reason='%s'", key, Database.data[key].Name, Database.data[key].Reason))

		Database.State.entriesCount = Database.State.entriesCount + 1
		Database.State.isDirty = true
	else
		-- DEBUG: Log updating existing entry
		-- print(string.format("[Database DEBUG Update] Updating existing entry for key: %s", key))
		-- Update existing entry but only if the new data has better information
		if type(value) == "table" then
			-- Only update name if the new name is better
			if value.Name and value.Name ~= "Unknown" and (not existing.Name or existing.Name == "Unknown") then
				existing.Name = value.Name
				Database.State.isDirty = true
			end

			-- Only update Reason if the new Reason is better
			local newReason = value.Reason or value.proof or value.cause
			if newReason and newReason ~= "Unknown" and (not existing.Reason or existing.Reason == "Unknown") then
				existing.Reason = newReason -- Use Reason field
				Database.State.isDirty = true
			end
		end
	end

	-- Auto-save if enabled and enough time has passed
	if Database.Config.AutoSave and Database.State.isDirty then
		local currentTime = os.time()
		if currentTime - Database.State.lastSave >= Database.Config.SaveInterval then
			Database.SaveDatabase()
		end
	end
end

-- Find best path for database storage
function Database.GetFilePath()
	local possibleFolders = {
		"Lua Cheater_Detection",
		"Lua Scripts/Cheater_Detection",
		"lbox/Cheater_Detection",
		"lmaobox/Cheater_Detection",
		".",
	}

	-- Define the filename we want to use
	local filename = "/database.lua"

	-- Try to find existing folder first
	for _, folder in ipairs(possibleFolders) do
		local potentialPath = folder .. filename
		if pcall(function()
			return filesystem.GetFileSize(potentialPath)
		end) then
			-- Found existing file in this folder
			local success, fullPath = pcall(filesystem.FullPath, folder) -- Get full path for consistency
			if success and fullPath then
				return fullPath .. filename
			else
				return potentialPath -- Fallback to relative path if FullPath fails
			end
		end
		-- Also check if the directory itself exists, even if the file doesn't yet
		if pcall(function()
			return filesystem.GetFileSize(folder)
		end) then
			local success, fullPath = pcall(filesystem.FullPath, folder)
			if success and fullPath then
				return fullPath .. filename
			else
				return folder .. filename
			end
		end
	end

	-- Try to create folders if none exist
	local preferredFolder = possibleFolders[1] -- Use the first one as preferred
	local success, fullPath = pcall(filesystem.CreateDirectory, preferredFolder)
	if success and fullPath then
		return fullPath .. filename
	elseif success then -- CreateDirectory might return true but empty path on failure in some cases?
		return preferredFolder .. filename
	end

	-- Last resort: current directory
	print("[Database] Warning: Could not find or create a suitable directory. Using current directory.")
	return "." .. filename
end

-- Save database to disk using Lua table serialization
function Database.SaveDatabase()
	-- Ensure the database has been initialized at least once
	if not Database.data then
		print("[Database] Cannot save, database not initialized.")
		return false
	end

	-- Skip saving if no entries or not dirty
	if Database.State.entriesCount == 0 then
		if Database.Config.DebugMode then
			print("[Database] No entries to save.")
		end
		return true -- Nothing to do, considered successful
	end

	if not Database.State.isDirty then
		if Database.Config.DebugMode then
			print("[Database] Database is not dirty, skipping save.")
		end
		return true -- Nothing to do, considered successful
	end

	local filePath = Database.GetFilePath()
	local tempPath = filePath .. ".tmp"
	local backupPath = filePath .. ".bak"

	if G and G.UI and G.UI.ShowMessage then
		G.UI.ShowMessage("Saving database...")
	end

	-- Stage 1: Serialize the data table to a Lua string
	local serializedData = nil
	local serializeSuccess, errMsg = pcall(function()
		serializedData = "-- Cheater Detection Database v1\nreturn " .. serializeTableToLuaString(Database.data)
	end)

	if not serializeSuccess or not serializedData then
		print("[Database] Failed to serialize database data: " .. tostring(errMsg or "Unknown error"))
		return false
	end

	-- Stage 2: Write serialized data to temporary file
	local writeSuccess, writeErrMsg = pcall(function()
		local tempFile = io.open(tempPath, "w")
		if not tempFile then
			error("Failed to open temporary file: " .. tempPath)
		end
		tempFile:write(serializedData)
		tempFile:close()
	end)

	serializedData = nil -- Allow GC
	collectgarbage("collect")

	if not writeSuccess then
		print("[Database] Failed to write to temporary file: " .. tostring(writeErrMsg))
		pcall(os.remove, tempPath) -- Attempt cleanup
		return false
	end

	-- Stage 3: Safely replace the original file
	local replaceSuccess = false
	local replaceErrMsg = "Unknown replacement error"

	-- Create backup
	local backupSuccess, backupErr = pcall(function()
		local fileExists = pcall(function()
			return filesystem.GetFileSize(filePath)
		end)
		if fileExists then
			os.rename(filePath, backupPath)
		end
	end)
	if not backupSuccess then
		print("[Database] Warning: Failed to create backup file ('" .. backupPath .. "'): " .. tostring(backupErr))
		-- Continue anyway, but log the warning
	end

	-- Rename temp file to final file path
	local renameSuccess, renameErr = pcall(os.rename, tempPath, filePath)
	if renameSuccess then
		replaceSuccess = true
	else
		replaceErrMsg = tostring(renameErr)
		-- Attempt manual copy if rename fails (less atomic)
		print("[Database] Warning: os.rename failed ('" .. replaceErrMsg .. "'). Attempting manual copy.")
		local manualCopySuccess, manualCopyErr = pcall(function()
			local tempFileRead = io.open(tempPath, "rb")
			if not tempFileRead then
				error("Cannot open temp file for read.")
			end
			local content = tempFileRead:read("*a")
			tempFileRead:close()
			local finalFileWrite = io.open(filePath, "wb")
			if not finalFileWrite then
				error("Cannot open final file for write.")
			end
			finalFileWrite:write(content)
			finalFileWrite:close()
		end)

		if manualCopySuccess then
			replaceSuccess = true
			pcall(os.remove, tempPath) -- Clean up temp file after copy
		else
			replaceErrMsg = "Manual copy failed: " .. tostring(manualCopyErr)
			-- Attempt to restore backup if rename and copy failed
			local restoreBackupSuccess, restoreBackupErr = pcall(os.rename, backupPath, filePath)
			if not restoreBackupSuccess then
				print(
					"[Database] CRITICAL ERROR: Failed to save database and failed to restore backup ('"
						.. tostring(restoreBackupErr)
						.. "'). Data may be lost or corrupted."
				)
			else
				print("[Database] Error saving database, but backup restored.")
			end
		end
	end

	if replaceSuccess then
		-- Update state
		Database.State.isDirty = false
		Database.State.lastSave = os.time()
		if G and G.UI and G.UI.ShowMessage then
			G.UI.ShowMessage("Database saved with " .. Database.State.entriesCount .. " entries!")
		end
		if Database.Config.DebugMode then
			print(string.format("[Database] Saved %d entries to %s", Database.State.entriesCount, filePath))
		end
		-- Optionally remove backup on success?
		-- pcall(os.remove, backupPath)
	else
		print("[Database] FAILED TO SAVE DATABASE. Error: " .. replaceErrMsg)
		-- Ensure state reflects failure
		Database.State.isDirty = true -- Still dirty as save failed
	end

	collectgarbage("collect")
	return replaceSuccess
end

-- Get a player record
function Database.GetRecord(steamId)
	return Database.data[steamId] -- Access data directly
end

-- Get proof for a player
function Database.GetReason(steamId) -- Renamed from GetProof
	local record = Database.data[steamId] -- Access data directly
	return record and record.Reason or "Unknown"
end

-- Get name for a player
function Database.GetName(steamId)
	local record = Database.data[steamId] -- Access data directly
	return record and record.Name or "Unknown"
end

-- Check if player is in database
function Database.Contains(steamId)
	return Database.data[steamId] ~= nil
end

-- Set a player as suspect
function Database.SetSuspect(steamId, data)
	if not steamId then
		return
	end

	-- Create minimal data structure
	local minimalData = {
		Name = (data and data.Name) or "Unknown",
		Reason = (data and (data.Reason or data.proof or data.cause)) or "Unknown", -- Use Reason
	}

	-- Store data using HandleSetEntry to ensure consistency
	Database.HandleSetEntry(steamId, minimalData)

	-- Also set priority in playerlist
	pcall(playerlist.SetPriority, steamId, 10)
end

-- Clear a player from suspect list
function Database.ClearSuspect(steamId)
	if Database.content[steamId] then
		Database.content[steamId] = nil
		playerlist.SetPriority(steamId, 0)
	end
end

-- Get database stats
function Database.GetStats()
	-- Count entries by Reason type
	local reasonStats = {}
	for steamID, entry in pairs(Database.data) do
		local reason = entry.Reason or "Unknown"
		reasonStats[reason] = (reasonStats[reason] or 0) + 1
	end

	return {
		entryCount = Database.State.entriesCount,
		isDirty = Database.State.isDirty,
		lastSave = Database.State.lastSave,
		memoryMB = collectgarbage("count") / 1024,
		proofTypes = reasonStats, -- Keep original name for now if used elsewhere, but contains reasons
		reasonTypes = reasonStats, -- Add new name for clarity
	}
end

-- Clean database by removing least important entries (Simplified Logic)
function Database.Cleanup(maxEntries)
	maxEntries = maxEntries or Database.Config.MaxEntries

	-- If we're under the limit, no need to clean
	if Database.State.entriesCount <= maxEntries then
		return 0
	end

	print(
		string.format("[Database] Cleaning up entries (Current: %d, Max: %d)", Database.State.entriesCount, maxEntries)
	)
	local toRemoveCount = Database.State.entriesCount - maxEntries
	local removedCount = 0

	-- Simple approach: Remove entries arbitrarily until limit is met.
	-- A more sophisticated approach (like keeping specific sources) could be added if needed.
	local keysToRemove = {}
	for steamId in pairs(Database.data) do
		table.insert(keysToRemove, steamId)
		if #keysToRemove >= toRemoveCount then
			break -- Collected enough keys to remove
		end
	end

	-- Remove the selected entries
	for _, steamId in ipairs(keysToRemove) do
		Database.HandleSetEntry(steamId, nil) -- Use HandleSetEntry to correctly decrement count and set dirty flag
		removedCount = removedCount + 1
	end

	-- Save the cleaned database immediately if changes were made
	if removedCount > 0 then -- Check if any were actually removed (HandleSetEntry might skip if already nil)
		print(string.format("[Database] Removed %d entries during cleanup.", removedCount))
		Database.SaveDatabase()
	elseif Database.Config.DebugMode then
		print("[Database] Cleanup ran but no entries needed removal or were already nil.")
	end

	return removedCount
end

-- Register database commands
local function RegisterCommands()
	local Commands = Common.Lib.Utils.Commands

	-- Database stats command
	Commands.Register("cd_db_stats", function()
		local stats = Database.GetStats()
		print(string.format("[Database] Total entries: %d", stats.entryCount))
		print(string.format("[Database] Memory usage: %.2f MB", stats.memoryMB))

		-- Show proof type breakdown
		print("[Database] Proof type breakdown:")
		for proofType, count in pairs(stats.proofTypes) do
			if count > 10 then -- Only show categories with more than 10 entries
				print(string.format("  - %s: %d", proofType, count))
			end
		end
	end, "Show database statistics")

	-- Database cleanup command
	Commands.Register("cd_db_cleanup", function(args)
		local limit = tonumber(args[1]) or Database.Config.MaxEntries
		local beforeCount = Database.State.entriesCount
		local removed = Database.Cleanup(limit)

		print(
			string.format(
				"[Database] Cleaned %d entries (from %d to %d)",
				removed,
				beforeCount,
				Database.State.entriesCount
			)
		)
	end, "Clean the database to stay under entry limit")
end

-- Auto-save on unload
local function OnUnload()
	if Database.State.isDirty then
		Database.SaveDatabase()
	end
end

-- Simplified Initialize function
local function InitializeDatabase()
	print("[Database] Initializing...")

	-- Set initial state
	Database.State = {
		entriesCount = 0,
		isDirty = false,
		lastSave = 0,
	}
	Database.data = Database.data or {} -- Ensure data table exists

	-- Load existing data from file
	local loadSuccess = Database.LoadDatabase()

	if not loadSuccess then
		printc(
			255,
			100,
			100,
			255,
			"[Database] Warning: Failed to load database file properly. Starting potentially empty."
		)
		-- Save an empty file if load failed completely and no backup worked
		if Database.State.entriesCount == 0 then
			Database.State.isDirty = true -- Mark as dirty to force save
			Database.SaveDatabase()
		end
	end

	-- Clean up if over limit after loading
	if Database.State.entriesCount > Database.Config.MaxEntries then
		local removed = Database.Cleanup()
		if removed > 0 and Database.Config.DebugMode then
			print(
				string.format(
					"[Database] Cleaned %d entries after loading to stay under limit (%d).",
					removed,
					Database.Config.MaxEntries
				)
			)
		end
	end

	-- Check for AutoFetch *after* loading
	pcall(function()
		if Database_Fetcher and Database_Fetcher.Config and Database_Fetcher.Config.AutoFetchOnLoad then
			print("[Database] Triggering AutoFetch after initialization.")
			Database_Fetcher.StartFetch(Database, function(added) -- Use StartFetch
				if added > 0 then
					printc(80, 200, 120, 255, "[Database] AutoFetch added " .. added .. " new entries.")
					-- Save is handled by the fetcher itself now
				else
					print("[Database] AutoFetch finished, no new entries added.")
				end
			end, true) -- Run silently
		end
	end)
end

-- Load database from disk using Lua's load function
function Database.LoadDatabase(silent)
	local filePath = Database.GetFilePath()

	-- Check if file exists
	local fileExists = pcall(function()
		return filesystem.GetFileSize(filePath)
	end)
	if not fileExists then
		if not silent then
			print("[Database] Database file not found: " .. filePath .. ". Creating new database.")
		end
		Database.data = {} -- Initialize empty table
		Database.State.entriesCount = 0
		Database.State.isDirty = false -- New database isn't dirty yet
		Database.State.lastSave = 0
		collectgarbage("collect")
		return true -- Successfully "loaded" an empty database
	end

	-- Load the Lua file content
	local loadedData = nil
	local success, result = pcall(function()
		local chunk = loadfile(filePath)
		if chunk then
			return chunk()
		else
			error("Failed to load database chunk from " .. filePath)
		end
	end)

	if not success then
		if not silent then
			print("[Database] Failed to load/parse database file ('" .. filePath .. "'): " .. tostring(result))
			print("[Database] Attempting to load backup: " .. filePath .. ".bak")
		end
		-- Attempt to load backup
		local backupFilePath = filePath .. ".bak"
		local backupExists = pcall(function()
			return filesystem.GetFileSize(backupFilePath)
		end)
		if backupExists then
			local backupSuccess, backupResult = pcall(function()
				local chunk = loadfile(backupFilePath)
				if chunk then
					return chunk()
				else
					error("Failed to load backup chunk.")
				end
			end)
			if backupSuccess and type(backupResult) == "table" then
				if not silent then
					printc(255, 165, 0, 255, "[Database] Successfully loaded from backup file.")
				end
				success = true
				result = backupResult
				-- Optionally try to restore the main file from backup here
				pcall(function()
					local bf = io.open(backupFilePath, "rb")
					if bf then
						local content = bf:read("*a")
						bf:close()
						local mf = io.open(filePath, "wb")
						if mf then
							mf:write(content)
							mf:close()
						end
					end
				end)
			else
				if not silent then
					print("[Database] Failed to load backup file: " .. tostring(backupResult))
				end
			end
		else
			if not silent then
				print("[Database] Backup file not found.")
			end
		end

		-- If both fail, start with empty
		if not success then
			printc(
				255,
				0,
				0,
				255,
				"[Database] CRITICAL: Failed to load main database and backup. Starting with an empty database."
			)
			Database.data = {}
			Database.State.entriesCount = 0
			Database.State.isDirty = true -- Mark dirty as we failed to load
			Database.State.lastSave = 0
			return false -- Indicate load failure
		end
	end

	-- Validate loaded data
	if type(result) ~= "table" then
		if not silent then
			print("[Database] Loaded data is not a table. Starting with an empty database.")
		end
		Database.data = {}
		Database.State.entriesCount = 0
		Database.State.isDirty = true
		Database.State.lastSave = 0
		return false -- Indicate load failure
	end

	-- Successfully loaded data
	Database.data = result

	-- Recalculate entry count and enforce structure
	local count = 0
	local entriesToRemove = {}
	for steamID, value in pairs(Database.data) do
		-- Basic validation
		if type(steamID) ~= "string" or not steamID:match("^765611") or type(value) ~= "table" or not value.Reason then -- Check for Reason field now
			table.insert(entriesToRemove, steamID)
		else
			count = count + 1
			-- Ensure Name exists
			if not value.Name then
				value.Name = "Unknown"
			end
			-- Remove old 'Reason' field if it exists
			if value.Reason then
				value.Reason = nil
			end
		end
	end

	-- Remove invalid entries
	if #entriesToRemove > 0 then
		if not silent then
			print("[Database] Removing " .. #entriesToRemove .. " invalid entries during load.")
		end
		for _, key in ipairs(entriesToRemove) do
			Database.data[key] = nil
		end
		Database.State.isDirty = true -- Mark dirty if we removed entries
	else
		Database.State.isDirty = false -- Loaded cleanly
	end

	Database.State.entriesCount = count
	Database.State.lastSave = os.time() -- Treat load time as last save time

	if not silent then
		printc(
			0,
			255,
			140,
			255,
			"[" .. os.date("%H:%M:%S") .. "] Loaded Database with " .. Database.State.entriesCount .. " entries"
		)
	end

	collectgarbage("collect")
	return true
end

-- Save database automatically when the script unloads
callbacks.Register("Unload", "DatabaseAutoSaveOnUnload", function()
	print("[Database] Script unloading, attempting to save database...")
	-- Call SaveDatabase directly. Force save even if interval hasn't passed,
	-- but respect the isDirty flag check within SaveDatabase itself.
	if Database.State and Database.State.isDirty then
		Database.SaveDatabase()
		print("[Database] Save attempted on unload.")
	else
		print("[Database] Database not dirty, no save needed on unload.")
	end
end)

-- Initial load
Database.Initialize()

return Database

end)
__bundle_register("Cheater_Detection.Database.Sources", function(require, _LOADED, __bundle_register, __bundle_modules)
-- Source definitions with safer processing options

local Sources = {}

-- List of available sources
Sources.List = {
	{
		name = "d3fc0n6 Cheater List",
		url = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
		cause = "Cheater Friend (d3fc0n6)",
		parser = "raw",
	},
	{
		name = "d3fc0n6 Tacobot List",
		url = "https://raw.githubusercontent.com/d3fc0n6/TacobotList/master/64ids",
		cause = "Tacobot (d3fc0n6)",
		parser = "raw",
	},
	-- Potentially problematic sources last
	{
		name = "bots.tf (Official)",
		url = "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json",
		cause = "Bot (bots.tf)",
		parser = "tf2db", -- Use tf2db parser for this JSON source
	},
}

-- Function to add a custom source
function Sources.AddSource(name, url, cause, parser)
	if not name or not url or not cause or not parser then
		print("[Database Fetcher] Error: Missing required fields for new source")
		return false
	end

	if parser ~= "raw" and parser ~= "tf2db" then
		print("[Database Fetcher] Error: Invalid parser type: " .. parser)
		return false
	end

	table.insert(Sources.List, {
		name = name,
		url = url,
		cause = cause,
		parser = parser,
	})

	print("[Database Fetcher] Added new source: " .. name)
	return true
end

-- Utility function to enable/disable sources (e.g. for testing)
function Sources.DisableSource(sourceIndex)
	if sourceIndex < 1 or sourceIndex > #Sources.List then
		print("[Database Fetcher] Invalid source index: " .. tostring(sourceIndex))
		return false
	end

	local source = Sources.List[sourceIndex]
	source.__disabled = true
	print("[Database Fetcher] Disabled source: " .. source.name)
	return true
end

-- Get active sources (not disabled)
function Sources.GetActiveSources()
	local active = {}
	for i, source in ipairs(Sources.List) do
		if not source.__disabled then
			table.insert(active, source)
		end
	end
	return active
end

return Sources

end)
__bundle_register("Cheater_Detection.Database.Tasks", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Fixed Task UI System - Ensures proper display of loading elements
]]

local Tasks = {
	isRunning = false,
	progress = 0,
	targetProgress = 0,
	message = "",
	status = "idle",
	currentSource = nil,
	completedSources = 0,
	totalSources = 0,
	completedTime = 0,

	-- UI configuration with adjusted dimensions
	UI = {
		Width = 300, -- Width of UI window
		Height = 90, -- Increased height to prevent text overlap
		BarHeight = 20, -- Height of progress bar
		Padding = 10, -- Padding inside window
		TitleSize = 18, -- Size of title font
		TextSize = 14, -- Size of regular text font
		BackgroundAlpha = 200, -- Background opacity (0-255)
		BorderAlpha = 150, -- Border opacity (0-255)
		ScreenOffset = 120, -- Distance from bottom of screen

		-- New positioning properties for better layout
		TitleOffset = 8, -- Title position from top
		StatusOffset = 35, -- Status message position from top
		BarBottomOffset = 15, -- Progress bar position from bottom
		TextSpacing = 8, -- Space between text elements
	},

	-- Animation settings
	Animation = {
		SmoothFactor = 0.7, -- Progress bar smoothing (higher = faster)
		FadeDelay = 3, -- Seconds before fading out after completion
		FadeDuration = 1, -- Seconds for fade out animation
	},
}

-- Initialize fonts - explicitly create each time instead of storing
function Tasks.InitializeFonts()
	Tasks.titleFont = draw.CreateFont("Verdana", Tasks.UI.TitleSize, 800) -- Bold font
	Tasks.textFont = draw.CreateFont("Verdana", Tasks.UI.TextSize, 400) -- Regular font
end

-- Initialize task tracking
function Tasks.Init(sourceCount)
	-- Initialize task state
	Tasks.totalSources = sourceCount or 0
	Tasks.completedSources = 0
	Tasks.progress = 0
	Tasks.targetProgress = 0
	Tasks.isRunning = true
	Tasks.status = "running"
	Tasks.message = "Loading Database"
	Tasks.currentSource = nil
	Tasks.completedTime = 0

	-- Make sure fonts are initialized
	Tasks.InitializeFonts()
end

-- Reset task system
function Tasks.Reset()
	-- Clean up any callbacks
	pcall(function()
		callbacks.Unregister("Draw", "TasksUpdateProgress")
	end)

	-- Reset state
	Tasks.isRunning = false
	Tasks.progress = 0
	Tasks.targetProgress = 0
	Tasks.status = "idle"
	Tasks.message = ""
	Tasks.currentSource = nil
	Tasks.completedSources = 0
	Tasks.totalSources = 0
	Tasks.completedTime = 0

	-- Force GC
	collectgarbage("collect")
end

-- Start processing a source
function Tasks.StartSource(sourceName)
	Tasks.currentSource = sourceName or "Unknown"
	Tasks.message = "Processing " .. Tasks.currentSource
end

-- Mark current source as complete
function Tasks.SourceDone()
	Tasks.completedSources = Tasks.completedSources + 1

	if Tasks.totalSources > 0 then
		Tasks.targetProgress = math.floor((Tasks.completedSources / Tasks.totalSources) * 100)
	end
end

-- Update progress with smoothing
function Tasks.UpdateProgress()
	-- Only update if running
	if not Tasks.isRunning then
		return
	end

	-- Smooth progress bar
	if Tasks.progress ~= Tasks.targetProgress then
		Tasks.progress = Tasks.progress + (Tasks.targetProgress - Tasks.progress) * Tasks.Animation.SmoothFactor
		if math.abs(Tasks.progress - Tasks.targetProgress) < 0.5 then
			Tasks.progress = Tasks.targetProgress
		end
	end

	-- Handle completion fade-out
	if Tasks.status == "complete" and Tasks.completedTime > 0 then
		if globals.RealTime() - Tasks.completedTime > Tasks.Animation.FadeDelay then
			Tasks.Reset()
		end
	end
end

-- Draw improved UI with fixed layout
function Tasks.DrawProgressUI()
	-- Skip if not running
	if not Tasks.isRunning then
		return
	end

	-- Make sure fonts are initialized
	Tasks.InitializeFonts()

	-- Get screen dimensions
	local screenWidth, screenHeight = draw.GetScreenSize()

	-- Calculate window position (centered horizontally, fixed distance from bottom)
	local width = Tasks.UI.Width
	local height = Tasks.UI.Height
	local x = math.floor((screenWidth - width) / 2)
	local y = math.floor(screenHeight - height - Tasks.UI.ScreenOffset)

	-- Draw background with alpha
	draw.Color(20, 20, 20, Tasks.UI.BackgroundAlpha)
	draw.FilledRect(x, y, x + width, y + height)

	-- Draw border
	draw.Color(60, 120, 255, Tasks.UI.BorderAlpha)
	draw.OutlinedRect(x, y, x + width, y + height)

	-- Draw title - moved up to prevent overlap
	draw.SetFont(Tasks.titleFont)
	draw.Color(255, 255, 255, 255)
	local titleText = "Database Update"
	local titleWidth = draw.GetTextSize(titleText)
	draw.Text(x + math.floor((width - titleWidth) / 2), y + Tasks.UI.TitleOffset, titleText)

	-- Calculate progress bar position from bottom of window
	local barPadding = Tasks.UI.Padding
	local barWidth = width - (barPadding * 2)
	local barHeight = Tasks.UI.BarHeight
	local barY = y + height - barHeight - Tasks.UI.BarBottomOffset

	-- Draw progress bar background
	draw.Color(40, 40, 40, 180)
	draw.FilledRect(x + barPadding, barY, x + barPadding + barWidth, barY + barHeight)

	-- Draw progress bar fill
	local fillWidth = math.floor((barWidth * Tasks.progress) / 100)
	draw.Color(30, 120, 255, 255)
	draw.FilledRect(x + barPadding, barY, x + barPadding + fillWidth, barY + barHeight)

	-- Draw progress percentage text
	draw.SetFont(Tasks.textFont)
	draw.Color(255, 255, 255, 255)
	local percent = string.format("%d%%", math.floor(Tasks.progress))
	local percentWidth = draw.GetTextSize(percent)
	draw.Text(
		x + barPadding + math.floor((barWidth - percentWidth) / 2),
		barY + math.floor((barHeight - Tasks.UI.TextSize) / 2),
		percent
	)

	-- Draw status message (if any) with proper positioning
	if Tasks.message and Tasks.message ~= "" then
		local message = Tasks.message
		if #message > 40 then
			message = message:sub(1, 37) .. "..."
		end

		draw.SetFont(Tasks.textFont)
		local messageWidth = draw.GetTextSize(message)
		-- Position message between title and progress bar
		draw.Text(
			x + math.floor((width - messageWidth) / 2),
			y + Tasks.UI.StatusOffset, -- Positioned right below the title
			message
		)
	end
end

-- Register automatic progress update (only once)
callbacks.Unregister("Draw", "TasksUpdateProgress")
callbacks.Register("Draw", "TasksUpdateProgress", Tasks.UpdateProgress)

return Tasks

end)
__bundle_register("Cheater_Detection.Utils.Config", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local json = require("Cheater_Detection.Libs.Json")
local Default_Config = require("Cheater_Detection.Utils.DefaultConfig")

local Config = {}

local Log = Common.Log
local Notify = Common.Notify
Log.Level = 0

local script_name = GetScriptName():match("([^/\\]+)%.lua$")
local folder_name = string.format([[Lua %s]], script_name)

--[[ Helper Functions ]]
function Config.GetFilePath()
	local success, fullPath = filesystem.CreateDirectory(folder_name)
	return fullPath .. "/config.cfg"
end

local function checkAllKeysExist(expectedMenu, loadedMenu)
	for key, value in pairs(expectedMenu) do
		if loadedMenu[key] == nil then
			return false
		end
		if type(value) == "table" then
			local result = checkAllKeysExist(value, loadedMenu[key])
			if not result then
				return false
			end
		end
	end
	return true
end

--[[ Configuration Functions ]]
function Config.CreateCFG(cfgTable)
	cfgTable = cfgTable or Default_Config
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "w")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local serializedConfig = json.encode(cfgTable)
		file:write(serializedConfig)
		file:close()
		printc(100, 183, 0, 255, "Success Saving Config: Path: " .. shortFilePath)
		Notify.Simple("Success! Saved Config to:", shortFilePath, 5)
	else
		local errorMessage = "Failed to open: " .. shortFilePath
		printc(255, 0, 0, 255, errorMessage)
		Notify.Simple("Error", errorMessage, 5)
	end
end

function Config.LoadCFG()
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "r")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local content = file:read("*a")
		file:close()
		local loadedCfg = json.decode(content)
		if loadedCfg and checkAllKeysExist(Default_Config, loadedCfg) and not input.IsButtonDown(KEY_LSHIFT) then
			printc(100, 183, 0, 255, "Success Loading Config: Path: " .. shortFilePath)
			Notify.Simple("Success! Loaded Config from", shortFilePath, 5)
			G.Menu = loadedCfg
		else
			local warningMessage = input.IsButtonDown(KEY_LSHIFT) and "Creating a new config."
				or "Config is outdated or invalid. Resetting to default."
			printc(255, 0, 0, 255, warningMessage)
			Notify.Simple("Warning", warningMessage, 5)
			Config.CreateCFG(Default_Config)
			G.Menu = Default_Config
		end
	else
		local warningMessage = "Config file not found. Creating a new config."
		printc(255, 0, 0, 255, warningMessage)
		Notify.Simple("Warning", warningMessage, 5)
		Config.CreateCFG(Default_Config)
		G.Menu = Default_Config
	end
end

return Config

end)
return __bundle_require("__root")