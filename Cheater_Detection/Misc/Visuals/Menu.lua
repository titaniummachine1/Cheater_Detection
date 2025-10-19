local Menu = {}

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")

local Lib = Common.Lib
local Fonts = Lib.UI.Fonts

-- Try to load TimMenu (assumes it's installed globally in Lmaobox)
local TimMenu = nil
local timMenuLoaded, timMenuModule = pcall(require, "TimMenu")
if timMenuLoaded and timMenuModule then
	TimMenu = timMenuModule
	print("[CD] TimMenu loaded successfully")
else
	error("[CD] TimMenu not found! Please install TimMenu to %localappdata%\\lmaobox\\Scripts\\TimMenu.lua")
end

local function DrawMenu()
	-- Only draw when the Lmaobox menu is open
	if not gui.IsMenuOpen() then
		return
	end

	-- Debug mode indicator (drawn outside TimMenu window)
	local debugMode = false
	if type(G.Menu.Advanced.LogLevel) == "table" and G.Menu.Advanced.LogLevel[1] then
		debugMode = true
	end
	
	if debugMode then
		draw.Color(255, 0, 0, 255)
		draw.SetFont(Fonts.Verdana)
		draw.Text(20, 120, "Debug Mode!!! Some Features Might malfunction")
	end

	-- Begin the menu and store the result
	if not TimMenu.Begin("Cheater Detection") then
		return
	end

	-- Tabs for different sections
	local tabs = { "Main", "Advanced", "Misc" }
	G.Menu.currentTab = TimMenu.TabControl("cd_main_tabs", tabs, G.Menu.currentTab)
	TimMenu.NextLine()

	-- Main Configuration Tab
	if G.Menu.currentTab == "Main" then
		local Main = G.Menu.Main

		TimMenu.BeginSector("Database & Detection")
		Main.Fetch_Database = TimMenu.Checkbox("Fetch Database", Main.Fetch_Database)
		TimMenu.NextLine()
		Main.AutoMark = TimMenu.Checkbox("Auto Mark", Main.AutoMark)
		TimMenu.NextLine()
		Main.partyCallaut = TimMenu.Checkbox("Party Callout", Main.partyCallaut)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Visual Settings")
		Main.Chat_Prefix = TimMenu.Checkbox("Chat Prefix", Main.Chat_Prefix)
		TimMenu.NextLine()
		Main.Cheater_Tags = TimMenu.Checkbox("Cheater Tags", Main.Cheater_Tags)
		TimMenu.NextLine()
		Main.JoinWarning = TimMenu.Checkbox("Join Warning", Main.JoinWarning)
		TimMenu.EndSector()
		TimMenu.NextLine()
	elseif G.Menu.currentTab == "Advanced" then
		local Advanced = G.Menu.Advanced

		TimMenu.BeginSector("Evidence System")
		-- Initialize with default value if nil
		Advanced.Evicence_Tolerance = Advanced.Evicence_Tolerance or 100
		Advanced.Evicence_Tolerance = TimMenu.Slider("Evidence Tolerance", Advanced.Evicence_Tolerance, 1, 200, 1)
		TimMenu.Tooltip("Threshold for marking players as cheaters (higher = more strict)")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Exploit Detection")
		Advanced.Choke = TimMenu.Checkbox("Fake Lag Detection", Advanced.Choke)
		TimMenu.NextLine()
		Advanced.Warp = TimMenu.Checkbox("Warp/DT Detection", Advanced.Warp)
		TimMenu.NextLine()
		Advanced.AntyAim = TimMenu.Checkbox("Anti-Aim Detection", Advanced.AntyAim)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Movement Detection")
		Advanced.Bhop = TimMenu.Checkbox("Bhop Detection", Advanced.Bhop)
		TimMenu.NextLine()
		Advanced.DuckSpeed = TimMenu.Checkbox("Duck Speed Detection", Advanced.DuckSpeed)
		TimMenu.NextLine()
		Advanced.Strafe_bot = TimMenu.Checkbox("Strafe Bot Detection", Advanced.Strafe_bot)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Aim Detection")
		Advanced.Aimbot.enable = TimMenu.Checkbox("Enable Aimbot Detection", Advanced.Aimbot.enable)
		TimMenu.NextLine()
		if Advanced.Aimbot.enable then
			Advanced.Aimbot.silent = TimMenu.Checkbox("  Silent Aim", Advanced.Aimbot.silent)
			TimMenu.NextLine()
			Advanced.Aimbot.plain = TimMenu.Checkbox("  Plain Aim", Advanced.Aimbot.plain)
			TimMenu.NextLine()
			Advanced.Aimbot.smooth = TimMenu.Checkbox("  Smooth Aim", Advanced.Aimbot.smooth)
			TimMenu.NextLine()
		end
		Advanced.triggerbot = TimMenu.Checkbox("Triggerbot Detection", Advanced.triggerbot)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Logging")
		local logLevels = {"Debug", "Info", "Warning", "Error"}
		Advanced.LogLevel = TimMenu.Combo("Log Level", Advanced.LogLevel, logLevels)
		TimMenu.Tooltip("Debug: All details | Info: Detections & saves | Warning: Issues | Error: Critical errors")
		TimMenu.EndSector()
		TimMenu.NextLine()
	elseif G.Menu.currentTab == "Misc" then
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("Auto Vote")
		Misc.Autovote = TimMenu.Checkbox("Enable Auto Vote", Misc.Autovote)
		TimMenu.NextLine()
		if Misc.Autovote then
			Misc.intent.legit = TimMenu.Checkbox("  Vote Legit Players", Misc.intent.legit)
			TimMenu.NextLine()
			Misc.intent.cheater = TimMenu.Checkbox("  Vote Cheaters", Misc.intent.cheater)
			TimMenu.NextLine()
			Misc.intent.bot = TimMenu.Checkbox("  Vote Bots", Misc.intent.bot)
			TimMenu.NextLine()
			Misc.intent.friend = TimMenu.Checkbox("  Exclude Friends", Misc.intent.friend)
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Vote Reveal")
		Misc.Vote_Reveal.Enable = TimMenu.Checkbox("Enable Vote Reveal", Misc.Vote_Reveal.Enable)
		TimMenu.NextLine()
		if Misc.Vote_Reveal.Enable then
			Misc.Vote_Reveal.TargetTeam.MyTeam = TimMenu.Checkbox("  My Team", Misc.Vote_Reveal.TargetTeam.MyTeam)
			TimMenu.NextLine()
			Misc.Vote_Reveal.TargetTeam.enemyTeam =
				TimMenu.Checkbox("  Enemy Team", Misc.Vote_Reveal.TargetTeam.enemyTeam)
			TimMenu.NextLine()
			Misc.Vote_Reveal.PartyChat = TimMenu.Checkbox("  Party Chat", Misc.Vote_Reveal.PartyChat)
			TimMenu.NextLine()
			Misc.Vote_Reveal.Console = TimMenu.Checkbox("  Console Log", Misc.Vote_Reveal.Console)
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Class Change Reveal")
		Misc.Class_Change_Reveal.Enable =
			TimMenu.Checkbox("Enable Class Change Reveal", Misc.Class_Change_Reveal.Enable)
		TimMenu.NextLine()
		if Misc.Class_Change_Reveal.Enable then
			Misc.Class_Change_Reveal.EnemyOnly = TimMenu.Checkbox("  Enemy Only", Misc.Class_Change_Reveal.EnemyOnly)
			TimMenu.NextLine()
			Misc.Class_Change_Reveal.PartyChat = TimMenu.Checkbox("  Party Chat", Misc.Class_Change_Reveal.PartyChat)
			TimMenu.NextLine()
			Misc.Class_Change_Reveal.Console = TimMenu.Checkbox("  Console Log", Misc.Class_Change_Reveal.Console)
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Notifications")
		Misc.Chat_notify = TimMenu.Checkbox("Chat Notifications", Misc.Chat_notify)
		TimMenu.EndSector()
		TimMenu.NextLine()
	end

	-- Always end the menu
	TimMenu.End()
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "CD_MENU")
callbacks.Register("Draw", "CD_MENU", DrawMenu)

return Menu
