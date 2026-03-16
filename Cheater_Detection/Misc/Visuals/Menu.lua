local Menu = {}

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")

local Fonts = {
	Verdana = draw.CreateFont("Verdana", 14, 510),
}

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
	TickProfiler.BeginSection("Draw_Menu")

	-- Debug mode indicator (drawn outside TimMenu window)
	if G.Menu.Advanced.debug then
		draw.Color(255, 0, 0, 255)
		draw.SetFont(Fonts.Verdana)
		draw.Text(20, 120, "Debug Mode!!! Some Features Might malfunction")
	end

	-- Begin the menu - visibility directly tied to Lmaobox menu state
	if not TimMenu.Begin("Cheater Detection", gui.IsMenuOpen()) then
		return
	end

	-- Tabs for different sections
	local tabs = { "Main", "Advanced", "Notifications", "Misc" }
	G.Menu.currentTab = TimMenu.TabControl("cd_main_tabs", tabs, G.Menu.currentTab)
	TimMenu.NextLine()

	-- Main Configuration Tab
	if G.Menu.currentTab == "Main" then
		local Main = G.Menu.Main
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("Player Scanner")
		if type(Main.AutoSync) ~= "boolean" then Main.AutoSync = true end
		Main.AutoSync = TimMenu.Checkbox("Auto-Sync Databases", Main.AutoSync)
		TimMenu.Tooltip("Automatically fetch online cheater lists on startup.")
		
		if type(Main.ValveCheck) ~= "boolean" then Main.ValveCheck = true end
		Main.ValveCheck = TimMenu.Checkbox("Valve Employee Check", Main.ValveCheck)
		TimMenu.Tooltip("Perform background identity checks for Valve employees.")
		
		local SteamHistory = require("Cheater_Detection.Database.SteamHistory")
		local shStatus = "Ready"
		if not SteamHistory.HasKey() then
			shStatus = "API key missing"
		elseif SteamHistory.IsTemporarilyDisabled() then
			shStatus = "Rate limited (Wait)"
		end
		TimMenu.Text("SteamHistory: " .. shStatus)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Detection Automation")
		local Advanced = G.Menu.Advanced
		if type(Advanced.AutoPriority) ~= "boolean" then Advanced.AutoPriority = true end
		Advanced.AutoPriority = TimMenu.Checkbox("Auto Priority", Advanced.AutoPriority)
		TimMenu.Tooltip("Automatically set high priority for marked cheaters.")

		if type(Main.partyCallaut) ~= "boolean" then Main.partyCallaut = true end
		Main.partyCallaut = TimMenu.Checkbox("Party Callouts", Main.partyCallaut)
		TimMenu.Tooltip("Share detections with your party through chat.")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Visual Feedback")
		if type(Main.Chat_Prefix) ~= "boolean" then Main.Chat_Prefix = true end
		Main.Chat_Prefix = TimMenu.Checkbox("Chat Prefix", Main.Chat_Prefix)
		if type(Main.Cheater_Tags) ~= "boolean" then Main.Cheater_Tags = true end
		Main.Cheater_Tags = TimMenu.Checkbox("Cheater Tags", Main.Cheater_Tags)
		
		if Main.Cheater_Tags then
			Main.TagFilters = Main.TagFilters or {true, true, true, true}
			Main.TagFilters = TimMenu.Combo("Visible Tags", Main.TagFilters, { "Valve", "Cheater", "VAC", "Suspicious" })
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Valve Safety")
		Misc.JoinNotifications = Misc.JoinNotifications or {}
		local JN = Misc.JoinNotifications
		if type(JN.ValveAutoDisconnect) ~= "boolean" then JN.ValveAutoDisconnect = false end
		JN.ValveAutoDisconnect = TimMenu.Checkbox("Auto Leave on Valve Join", JN.ValveAutoDisconnect)
		TimMenu.Tooltip("Disconnect automatically when a Valve employee enters the server.")
		TimMenu.EndSector()

	-- Advanced Configuration Tab
	elseif G.Menu.currentTab == "Advanced" then
		local Advanced = G.Menu.Advanced

		TimMenu.BeginSector("Evidence System")
		if type(Advanced.Evicence_Tolerance) ~= "number" then Advanced.Evicence_Tolerance = 50 end
		Advanced.Evicence_Tolerance = TimMenu.Slider("Evidence Threshold %", Advanced.Evicence_Tolerance, 0, 100, 1)
		TimMenu.Tooltip("Minimum suspicion % required to auto-mark a player as a cheater (higher = stricter)")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Exploit Detection")
		if type(Advanced.Choke) ~= "boolean" then Advanced.Choke = true end
		Advanced.Choke = TimMenu.Checkbox("Fake Lag Detection", Advanced.Choke)
		if type(Advanced.Warp) ~= "boolean" then Advanced.Warp = true end
		Advanced.Warp = TimMenu.Checkbox("Warp/DT Detection", Advanced.Warp)
		if type(Advanced.AntyAim) ~= "boolean" then Advanced.AntyAim = true end
		Advanced.AntyAim = TimMenu.Checkbox("Anti-Aim Detection", Advanced.AntyAim)
		TimMenu.EndSector()

		TimMenu.BeginSector("Aim Detection")
		if type(Advanced.SilentAimbot) ~= "boolean" then Advanced.SilentAimbot = true end
		Advanced.SilentAimbot = TimMenu.Checkbox("Silent Aimbot (Extrapolation)", Advanced.SilentAimbot)
		TimMenu.Tooltip("Detects silent aim using viewangle extrapolation (experimental)")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Movement Detection")
		if type(Advanced.Bhop) ~= "boolean" then Advanced.Bhop = true end
		Advanced.Bhop = TimMenu.Checkbox("Bhop Detection", Advanced.Bhop)
		if type(Advanced.DuckSpeed) ~= "boolean" then Advanced.DuckSpeed = true end
		Advanced.DuckSpeed = TimMenu.Checkbox("Duck Speed Detection", Advanced.DuckSpeed)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Debug")
		if type(Advanced.debug) ~= "boolean" then Advanced.debug = false end
		Advanced.debug = TimMenu.Checkbox("Debug Mode", Advanced.debug)
		
		local logLevels = { "Debug", "Info", "Warning", "Error" }
		Advanced.LogLevel = TimMenu.Combo("Log Level", Advanced.LogLevel, logLevels)
		TimMenu.EndSector()

	-- Notifications Tab
	elseif G.Menu.currentTab == "Notifications" then
		local N = G.Menu.Notifications or {}

		TimMenu.BeginSector("Master Switch")
		if type(N.Enable) ~= "boolean" then N.Enable = true end
		N.Enable = TimMenu.Checkbox("Enable System-Wide Notifications", N.Enable)
		TimMenu.Tooltip("Master toggle for all chat and visual alerts.")
		TimMenu.EndSector()
		TimMenu.NextLine()

		if N.Enable then
			TimMenu.BeginSector("Global Output Settings")
			local channelOptions = { "Local Chat", "Public Chat", "Party", "Log Toast", "Console Log" }
			N.Channels = N.Channels or {LocalChat=true, PublicChat=false, Party=false, Toast=true, Console=true}
			local ch = N.Channels
			local act = { ch.LocalChat, ch.PublicChat, ch.Party, ch.Toast, ch.Console }
			act = TimMenu.Combo("Default channels for all detections", act, channelOptions)
			ch.LocalChat, ch.PublicChat, ch.Party, ch.Toast, ch.Console = act[1], act[2], act[3], act[4], act[5]
			
			TimMenu.Text("Suspicion Filtering:")
			TimMenu.NextLine()
			if type(N.SuspicionThreshold) ~= "number" then N.SuspicionThreshold = 30 end
			N.SuspicionThreshold = TimMenu.Slider("Alert Threshold %", N.SuspicionThreshold, 5, 95, 5)
			TimMenu.Tooltip("Only notify if a player's suspicion score exceeds this percentage.")
			TimMenu.NextLine()
			if type(N.SuspicionCooldown) ~= "number" then N.SuspicionCooldown = 10 end
			N.SuspicionCooldown = TimMenu.Slider("Spam Cooldown (s)", N.SuspicionCooldown, 5, 120, 5)
			TimMenu.Tooltip("Wait this long before updating a player's suspicion alert in chat.")
			TimMenu.EndSector()
			TimMenu.NextLine()

			TimMenu.BeginSector("Conditional Overrides")
			N.Overrides = N.Overrides or {}
			local OV = N.Overrides
			if type(OV.UseCheaterOverride) ~= "boolean" then OV.UseCheaterOverride = false end
			OV.UseCheaterOverride = TimMenu.Checkbox("Unique Channels for Confirmed Cheaters", OV.UseCheaterOverride)
			TimMenu.Tooltip("Use different chat channels when a player is 100% caught cheating.")
			TimMenu.NextLine()
			
			if type(OV.UseValveOverride) ~= "boolean" then OV.UseValveOverride = false end
			OV.UseValveOverride = TimMenu.Checkbox("Unique Channels for Valve Employees", OV.UseValveOverride)
			TimMenu.Tooltip("Use different chat channels for Valve detections.")
			TimMenu.EndSector()
			TimMenu.NextLine()

			TimMenu.BeginSector("Join & Discovery Alerts")
			local Misc = G.Menu.Misc or {}
			Misc.JoinNotifications = Misc.JoinNotifications or {}
			local JN = Misc.JoinNotifications
			if type(JN.Enable) ~= "boolean" then JN.Enable = true end
			JN.Enable = TimMenu.Checkbox("Notify on Player Connections", JN.Enable)
			TimMenu.Tooltip("Warning popups when a labeled player joins the server mid-game.")
			TimMenu.NextLine()
			
			if JN.Enable then
				if type(JN.CheckCheater) ~= "boolean" then JN.CheckCheater = true end
				JN.CheckCheater = TimMenu.Checkbox("Alert for Cheaters", JN.CheckCheater)
				TimMenu.SameLine()
				if type(JN.CheckValve) ~= "boolean" then JN.CheckValve = true end
				JN.CheckValve = TimMenu.Checkbox("Alert for Valve", JN.CheckValve)
				TimMenu.NextLine()
			end
			TimMenu.EndSector()
		end

	-- Misc Tab
	elseif G.Menu.currentTab == "Misc" then
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("Vote Automation")
		if type(Misc.Autovote) ~= "boolean" then Misc.Autovote = false end
		Misc.Autovote = TimMenu.Checkbox("Auto Vote", Misc.Autovote)
		TimMenu.Tooltip("Call votes automatically using your selected targets.")
		TimMenu.NextLine()
		if Misc.Autovote then
			if type(Misc.AutovoteAutoCast) ~= "boolean" then Misc.AutovoteAutoCast = true end
			Misc.AutovoteAutoCast = TimMenu.Checkbox("Auto Cast Votes", Misc.AutovoteAutoCast)
			TimMenu.Tooltip("Continuously initiate votes using the configured target priority.")
			TimMenu.NextLine()
			
			Misc.intent = Misc.intent or {}
			local voteTargets = { "Retaliation", "Bots (Cheat)", "Cheaters", "Valve Employees", "Legit Players", "Friends" }
			local voteTable = {
				Misc.intent.retaliation ~= false,
				Misc.intent.bot ~= false,
				Misc.intent.cheater ~= false,
				Misc.intent.valve ~= false,
				Misc.intent.legit ~= false,
				Misc.intent.friend == true,
			}
			voteTable = TimMenu.Combo("Vote Targets", voteTable, voteTargets)
			Misc.intent.retaliation, Misc.intent.bot, Misc.intent.cheater, Misc.intent.valve, Misc.intent.legit, Misc.intent.friend = 
				voteTable[1], voteTable[2], voteTable[3], voteTable[4], voteTable[5], voteTable[6]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Vote Reveal Alerts")
		Misc.Vote_Reveal = Misc.Vote_Reveal or {}
		if type(Misc.Vote_Reveal.Enable) ~= "boolean" then Misc.Vote_Reveal.Enable = false end
		Misc.Vote_Reveal.Enable = TimMenu.Checkbox("Vote Reveal", Misc.Vote_Reveal.Enable)
		TimMenu.Tooltip("Announce teammate votes and their targets across selected channels.")
		TimMenu.NextLine()
		
		if Misc.Vote_Reveal.Enable then
			Misc.Vote_Reveal.TargetTeam = Misc.Vote_Reveal.TargetTeam or { MyTeam = true, enemyTeam = true }
			local teamOptions = { "My Team", "Enemy Team" }
			local teamTable = { Misc.Vote_Reveal.TargetTeam.MyTeam, Misc.Vote_Reveal.TargetTeam.enemyTeam }
			teamTable = TimMenu.Combo("Target Teams", teamTable, teamOptions)
			Misc.Vote_Reveal.TargetTeam.MyTeam, Misc.Vote_Reveal.TargetTeam.enemyTeam = teamTable[1], teamTable[2]
			TimMenu.NextLine()
			
			Misc.Vote_Reveal.Output = Misc.Vote_Reveal.Output or { LocalChat = true, Toast = true, Console = true }
			local vo = Misc.Vote_Reveal.Output
			local channelOptions = { "Local Chat", "Public Chat", "Party", "Notification", "Console" }
			local act = { vo.LocalChat, vo.PublicChat, vo.Party, vo.Toast, vo.Console }
			act = TimMenu.Combo("Vote Output", act, channelOptions)
			vo.LocalChat, vo.PublicChat, vo.Party, vo.Toast, vo.Console = act[1], act[2], act[3], act[4], act[5]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Class Change Alerts")
		Misc.Class_Change_Reveal = Misc.Class_Change_Reveal or {}
		if type(Misc.Class_Change_Reveal.Enable) ~= "boolean" then Misc.Class_Change_Reveal.Enable = false end
		Misc.Class_Change_Reveal.Enable = TimMenu.Checkbox("Class Change Reveal", Misc.Class_Change_Reveal.Enable)
		TimMenu.Tooltip("Notify when tracked players switch classes.")
		TimMenu.NextLine()
		
		if Misc.Class_Change_Reveal.Enable then
			Misc.Class_Change_Reveal.EnemyOnly = type(Misc.Class_Change_Reveal.EnemyOnly) ~= "boolean" or Misc.Class_Change_Reveal.EnemyOnly
			Misc.Class_Change_Reveal.EnemyOnly = TimMenu.Checkbox("Enemy Team Only", Misc.Class_Change_Reveal.EnemyOnly)
			TimMenu.NextLine()
			
			Misc.Class_Change_Reveal.Output = Misc.Class_Change_Reveal.Output or { LocalChat = true, Toast = true, Console = true }
			local co = Misc.Class_Change_Reveal.Output
			local channelOptions = { "Local Chat", "Public Chat", "Party", "Notification", "Console" }
			local act = { co.LocalChat, co.PublicChat, co.Party, co.Toast, co.Console }
			act = TimMenu.Combo("Class Change Output", act, channelOptions)
			co.LocalChat, co.PublicChat, co.Party, co.Toast, co.Console = act[1], act[2], act[3], act[4], act[5]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Summary")
		local dbCount = 0
		if type(G.DataBase) == "table" then
			for _ in pairs(G.DataBase) do dbCount = dbCount + 1 end
		end
		TimMenu.Text("Database Entries: " .. dbCount)
		TimMenu.NextLine()
		
		local lastFetch = G.Database and G.Database.State and G.Database.State.lastSave
		if lastFetch and lastFetch > 0 then
			TimMenu.Text("Last Sync: " .. os.date("%H:%M:%S", lastFetch))
		else
			TimMenu.Text("Last Sync: Never")
		end
		TimMenu.EndSector()
	end

	-- Always end the menu
	TimMenu.End()

	TickProfiler.EndSection("Draw_Menu")
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "CD_MENU")
callbacks.Register("Draw", "CD_MENU", DrawMenu)

return Menu
