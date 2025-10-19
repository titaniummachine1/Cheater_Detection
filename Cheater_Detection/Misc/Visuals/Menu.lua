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
			-- Initialize if needed
			if type(Advanced.Aimbot.silent) ~= "boolean" then Advanced.Aimbot.silent = true end
			if type(Advanced.Aimbot.plain) ~= "boolean" then Advanced.Aimbot.plain = true end
			if type(Advanced.Aimbot.smooth) ~= "boolean" then Advanced.Aimbot.smooth = true end
			
			local aimbotTypes = {"Silent Aim", "Plain Aim", "Smooth Aim"}
			local aimbotTable = {Advanced.Aimbot.silent, Advanced.Aimbot.plain, Advanced.Aimbot.smooth}
			aimbotTable = TimMenu.Combo("Aimbot Types", aimbotTable, aimbotTypes)
			Advanced.Aimbot.silent = aimbotTable[1]
			Advanced.Aimbot.plain = aimbotTable[2]
			Advanced.Aimbot.smooth = aimbotTable[3]
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
			-- Initialize if needed
			if type(Misc.intent.legit) ~= "boolean" then Misc.intent.legit = true end
			if type(Misc.intent.cheater) ~= "boolean" then Misc.intent.cheater = true end
			if type(Misc.intent.bot) ~= "boolean" then Misc.intent.bot = true end
			if type(Misc.intent.friend) ~= "boolean" then Misc.intent.friend = false end
			
			local voteTargets = {"Legit Players", "Cheaters", "Bots", "Exclude Friends"}
			local voteTable = {Misc.intent.legit, Misc.intent.cheater, Misc.intent.bot, Misc.intent.friend}
			voteTable = TimMenu.Combo("Vote Targets", voteTable, voteTargets)
			Misc.intent.legit = voteTable[1]
			Misc.intent.cheater = voteTable[2]
			Misc.intent.bot = voteTable[3]
			Misc.intent.friend = voteTable[4]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Vote Reveal")
		Misc.Vote_Reveal.Enable = TimMenu.Checkbox("Enable Vote Reveal", Misc.Vote_Reveal.Enable)
		TimMenu.NextLine()
		if Misc.Vote_Reveal.Enable then
			-- Initialize if needed
			if type(Misc.Vote_Reveal.TargetTeam.MyTeam) ~= "boolean" then Misc.Vote_Reveal.TargetTeam.MyTeam = true end
			if type(Misc.Vote_Reveal.TargetTeam.enemyTeam) ~= "boolean" then Misc.Vote_Reveal.TargetTeam.enemyTeam = true end
			if type(Misc.Vote_Reveal.PartyChat) ~= "boolean" then Misc.Vote_Reveal.PartyChat = true end
			if type(Misc.Vote_Reveal.Console) ~= "boolean" then Misc.Vote_Reveal.Console = true end
			
			local teamOptions = {"My Team", "Enemy Team"}
			local teamTable = {Misc.Vote_Reveal.TargetTeam.MyTeam, Misc.Vote_Reveal.TargetTeam.enemyTeam}
			teamTable = TimMenu.Combo("Target Teams", teamTable, teamOptions)
			Misc.Vote_Reveal.TargetTeam.MyTeam = teamTable[1]
			Misc.Vote_Reveal.TargetTeam.enemyTeam = teamTable[2]
			TimMenu.NextLine()
			
			local outputOptions = {"Party Chat", "Console"}
			local outputTable = {Misc.Vote_Reveal.PartyChat, Misc.Vote_Reveal.Console}
			outputTable = TimMenu.Combo("Vote Output", outputTable, outputOptions)
			Misc.Vote_Reveal.PartyChat = outputTable[1]
			Misc.Vote_Reveal.Console = outputTable[2]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Class Change Reveal")
		Misc.Class_Change_Reveal.Enable = TimMenu.Checkbox("Enable Class Change Reveal", Misc.Class_Change_Reveal.Enable)
		TimMenu.NextLine()
		if Misc.Class_Change_Reveal.Enable then
			-- Initialize if needed
			if type(Misc.Class_Change_Reveal.EnemyOnly) ~= "boolean" then Misc.Class_Change_Reveal.EnemyOnly = true end
			if type(Misc.Class_Change_Reveal.PartyChat) ~= "boolean" then Misc.Class_Change_Reveal.PartyChat = true end
			if type(Misc.Class_Change_Reveal.Console) ~= "boolean" then Misc.Class_Change_Reveal.Console = true end
			
			Misc.Class_Change_Reveal.EnemyOnly = TimMenu.Checkbox("Enemy Team Only", Misc.Class_Change_Reveal.EnemyOnly)
			TimMenu.NextLine()
			
			local classOutputOptions = {"Party Chat", "Console"}
			local classOutputTable = {Misc.Class_Change_Reveal.PartyChat, Misc.Class_Change_Reveal.Console}
			classOutputTable = TimMenu.Combo("Class Change Output", classOutputTable, classOutputOptions)
			Misc.Class_Change_Reveal.PartyChat = classOutputTable[1]
			Misc.Class_Change_Reveal.Console = classOutputTable[2]
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
