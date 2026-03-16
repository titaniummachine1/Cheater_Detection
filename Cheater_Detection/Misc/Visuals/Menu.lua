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
		Main.AutoSync = TimMenu.Checkbox("Auto-Sync Databases", Main.AutoSync)
		Main.ValveCheck = TimMenu.Checkbox("Valve Employee Check", Main.ValveCheck)

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
		Advanced.AutoPriority = TimMenu.Checkbox("Auto Priority", Advanced.AutoPriority)
		Main.partyCallaut = TimMenu.Checkbox("Party Callouts", Main.partyCallaut)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Visual Feedback")
		Main.Chat_Prefix = TimMenu.Checkbox("Chat Prefix", Main.Chat_Prefix)
		Main.Cheater_Tags = TimMenu.Checkbox("Cheater Tags", Main.Cheater_Tags)
		
		if Main.Cheater_Tags then
			Main.TagFilters = TimMenu.Combo("Visible Tags", Main.TagFilters or {true, true, true, true}, { "Valve", "Cheater", "VAC", "Suspicious" })
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Valve Safety")
		Misc.JoinNotifications = Misc.JoinNotifications or {}
		local JN = Misc.JoinNotifications
		JN.ValveAutoDisconnect = TimMenu.Checkbox("Auto Leave on Valve Join", JN.ValveAutoDisconnect)
		TimMenu.EndSector()

	-- Advanced Configuration Tab
	elseif G.Menu.currentTab == "Advanced" then
		local Advanced = G.Menu.Advanced

		TimMenu.BeginSector("Evidence System")
		Advanced.Evicence_Tolerance = TimMenu.Slider("Evidence Threshold %", Advanced.Evicence_Tolerance or 50, 0, 100, 1)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Exploit Detection")
		Advanced.Choke = TimMenu.Checkbox("Fake Lag Detection", Advanced.Choke)
		Advanced.Warp = TimMenu.Checkbox("Warp/DT Detection", Advanced.Warp)
		Advanced.AntyAim = TimMenu.Checkbox("Anti-Aim Detection", Advanced.AntyAim)
		TimMenu.EndSector()

		TimMenu.BeginSector("Aim Detection")
		Advanced.SilentAimbot = TimMenu.Checkbox("Silent Aimbot (Extrapolation)", Advanced.SilentAimbot)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Movement Detection")
		Advanced.Bhop = TimMenu.Checkbox("Bhop Detection", Advanced.Bhop)
		Advanced.DuckSpeed = TimMenu.Checkbox("Duck Speed Detection", Advanced.DuckSpeed)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Debug")
		Advanced.debug = TimMenu.Checkbox("Debug Mode", Advanced.debug)
		local logLevels = { "Debug", "Info", "Warning", "Error" }
		Advanced.LogLevel = TimMenu.Combo("Log Level", Advanced.LogLevel, logLevels)
		TimMenu.EndSector()

	-- Notifications Tab
	elseif G.Menu.currentTab == "Notifications" then
		local N = G.Menu.Notifications or {}

		TimMenu.BeginSector("Master Switch")
		N.Enable = TimMenu.Checkbox("Enable System-Wide Notifications", N.Enable)
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
			N.SuspicionThreshold = TimMenu.Slider("Alert Threshold %", N.SuspicionThreshold or 30, 5, 95, 5)
			N.SuspicionCooldown = TimMenu.Slider("Spam Cooldown (s)", N.SuspicionCooldown or 10, 5, 120, 5)
			TimMenu.EndSector()
			TimMenu.NextLine()

			TimMenu.BeginSector("Conditional Overrides")
			N.Overrides = N.Overrides or {}
			local OV = N.Overrides
			OV.UseCheaterOverride = TimMenu.Checkbox("Unique Channels for Confirmed Cheaters", OV.UseCheaterOverride)
			OV.UseValveOverride = TimMenu.Checkbox("Unique Channels for Valve Employees", OV.UseValveOverride)
			TimMenu.EndSector()
			TimMenu.NextLine()

			TimMenu.BeginSector("Join & Discovery Alerts")
			local Misc = G.Menu.Misc or {}
			Misc.JoinNotifications = Misc.JoinNotifications or {}
			local JN = Misc.JoinNotifications
			JN.Enable = TimMenu.Checkbox("Notify on Player Connections", JN.Enable)
			
			if JN.Enable then
				JN.CheckCheater = TimMenu.Checkbox("Alert for Cheaters", JN.CheckCheater)
				TimMenu.SameLine()
				JN.CheckValve = TimMenu.Checkbox("Alert for Valve", JN.CheckValve)
				TimMenu.NextLine()
			end
			TimMenu.EndSector()
		end

	-- Misc Tab
	elseif G.Menu.currentTab == "Misc" then
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("Vote Automation")
		Misc.Autovote = TimMenu.Checkbox("Auto Vote", Misc.Autovote)
		if Misc.Autovote then
			Misc.AutovoteAutoCast = TimMenu.Checkbox("Auto Cast Votes", Misc.AutovoteAutoCast)
			
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
		Misc.Vote_Reveal.Enable = TimMenu.Checkbox("Vote Reveal", Misc.Vote_Reveal.Enable)
		
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
		Misc.Class_Change_Reveal.Enable = TimMenu.Checkbox("Class Change Reveal", Misc.Class_Change_Reveal.Enable)
		
		if Misc.Class_Change_Reveal.Enable then
			Misc.Class_Change_Reveal.EnemyOnly = TimMenu.Checkbox("Enemy Team Only", Misc.Class_Change_Reveal.EnemyOnly ~= false)
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
