local Menu = {}

local G = require("Cheater_Detection.Utils.Globals")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")
local SteamHistory = require("Cheater_Detection.Database.SteamHistory")
local MAC = require("Cheater_Detection.Database.MAC")
local HttpQueue = require("Cheater_Detection.services.http_queue")

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

local function EditNotificationChannels(label, channels)
	local options = { "Local Chat", "Public Chat", "Party", "Toast", "Console" }
	local values = {
		channels.LocalChat == true,
		channels.PublicChat == true,
		channels.Party == true,
		channels.Toast == true,
		channels.Console == true,
	}
	values = TimMenu.Combo(label, values, options)
	channels.LocalChat = values[1]
	channels.PublicChat = values[2]
	channels.Party = values[3]
	channels.Toast = values[4]
	channels.Console = values[5]
	TimMenu.NextLine()
	return channels
end

local function EditJoinNotificationChannels(label, channels)
	channels.LocalChat = channels.LocalChat == true or channels.ClientChat == true
	channels.Party = channels.Party == true or channels.PartyChat == true
	channels.Toast = channels.Toast == true
	EditNotificationChannels(label, channels)
	channels.ClientChat = channels.LocalChat
	channels.PartyChat = channels.Party
	return channels
end

local function EnsureMenuState()
	G.Menu = G.Menu or {}
	G.Menu.Main = G.Menu.Main or {}
	G.Menu.Scanner = G.Menu.Scanner or {}
	G.Menu.Advanced = G.Menu.Advanced or {}
	G.Menu.Notifications = G.Menu.Notifications or {}
	G.Menu.Misc = G.Menu.Misc or {}
	G.Menu.currentTab = G.Menu.currentTab or "Main"
end

local function DrawMenu()
	TickProfiler.BeginSection("Draw_Menu")
	EnsureMenuState()

	if G.Menu.Advanced.debug and not gui.IsMenuOpen() then
		draw.Color(255, 0, 0, 255)
		draw.SetFont(Fonts.Verdana)
		draw.Text(20, 120, "Debug Mode!!! Some Features Might malfunction")
	end

	if not TimMenu.Begin("Cheater Detection", gui.IsMenuOpen()) then
		TickProfiler.EndSection("Draw_Menu")
		return
	end

	local Main = G.Menu.Main
	local Scanner = G.Menu.Scanner
	local Advanced = G.Menu.Advanced
	local Notifications = G.Menu.Notifications
	local Misc = G.Menu.Misc

	G.Menu.currentTab =
		TimMenu.TabControl("cd_main_tabs", { "Main", "Advanced", "Notifications", "Misc" }, G.Menu.currentTab)
	TimMenu.NextLine()
	if G.Menu.currentTab == "Main" then
		TimMenu.BeginSector("Player Scanner")
		Misc.JoinNotifications = Misc.JoinNotifications or {}
		local JN = Misc.JoinNotifications
		Main.AutoSync = TimMenu.Checkbox("Auto-Sync Databases", Main.AutoSync == true)
		TimMenu.NextLine()
		Main.ValveCheck = TimMenu.Checkbox("Valve Employee Check", Main.ValveCheck == true)
		TimMenu.NextLine()
		JN.ValveAutoDisconnect = TimMenu.Checkbox("Auto Leave If Valve Employee Detected", JN.ValveAutoDisconnect == true)
		TimMenu.NextLine()

		local shStatus = "Ready"
		if not SteamHistory.HasKey() then
			shStatus = "API key missing"
		elseif SteamHistory.IsTemporarilyDisabled() then
			shStatus = "Rate limited (Wait)"
		end
		TimMenu.Text("SteamHistory: " .. shStatus)
		TimMenu.NextLine()
		TimMenu.Text("Public cheater lists are fetched by Auto-Sync Databases")
		TimMenu.EndSector()

		TimMenu.BeginSector("Detection Automation")
		Advanced.AutoPriority = TimMenu.Checkbox("Auto Priority", Advanced.AutoPriority == true)
		TimMenu.NextLine()
		Main.partyCallaut = TimMenu.Checkbox("Party Callouts", Main.partyCallaut == true)
		TimMenu.NextLine()
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Visual Feedback")
		Main.Chat_Prefix = TimMenu.Checkbox("Chat Prefix", Main.Chat_Prefix == true)
		TimMenu.NextLine()
		Main.Cheater_Tags = TimMenu.Checkbox("Cheater Tags", Main.Cheater_Tags == true)
		TimMenu.NextLine()

		if Main.Cheater_Tags then
			Main.TagFilters = TimMenu.Combo(
				"Visible Tags",
				Main.TagFilters or { true, true, true, true },
				{ "Valve", "Cheater", "VAC", "Suspicious" }
			)
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()
	elseif G.Menu.currentTab == "Advanced" then
		TimMenu.BeginSector("Evidence System")
		Advanced.Evidence_Tolerance =
			TimMenu.Slider("Evidence Threshold %", Advanced.Evidence_Tolerance or 50, 0, 100, 1)
		TimMenu.NextLine()
		TimMenu.EndSector()

		TimMenu.BeginSector("Debug")
		Advanced.debug = TimMenu.Checkbox("Debug Mode", Advanced.debug == true)
		TimMenu.NextLine()
		Advanced.LogLevel = TimMenu.Combo(
			"Log Level",
			Advanced.LogLevel or { false, true, false, false },
			{ "Debug", "Info", "Warning", "Error" }
		)
		TimMenu.NextLine()
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Exploit Detection")
		Advanced.Choke = TimMenu.Checkbox("Fake Lag Detection", Advanced.Choke == true)
		TimMenu.NextLine()
		Advanced.Warp = TimMenu.Checkbox("Warp/DT Detection", Advanced.Warp == true)
		TimMenu.NextLine()
		Advanced.AntiAim = TimMenu.Checkbox("Anti-Aim Detection", Advanced.AntiAim == true)
		TimMenu.NextLine()
		TimMenu.EndSector()

		TimMenu.BeginSector("Movement Detection")
		Advanced.Bhop = TimMenu.Checkbox("Bhop Detection", Advanced.Bhop == true)
		TimMenu.NextLine()
		Advanced.DuckSpeed = TimMenu.Checkbox("Duck Speed Detection", Advanced.DuckSpeed == true)
		TimMenu.NextLine()
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Aim Detection")
		Advanced.SilentAimbot = TimMenu.Checkbox("Silent Aimbot (Extrapolation)", Advanced.SilentAimbot == true)
		TimMenu.NextLine()
		TimMenu.EndSector()
		TimMenu.NextLine()
	elseif G.Menu.currentTab == "Notifications" then
		local N = Notifications
		Misc.JoinNotifications = Misc.JoinNotifications or {}
		local JN = Misc.JoinNotifications

		TimMenu.BeginSector("Master Switch")
		N.Enable = TimMenu.Checkbox("Enable System-Wide Notifications", N.Enable == true)
		TimMenu.NextLine()
		TimMenu.EndSector()
		TimMenu.NextLine()

		if not N.Enable then
			TimMenu.BeginSector("Notifications Disabled")
			TimMenu.Text("Enable notifications to configure channels.")
			TimMenu.EndSector()
			TimMenu.NextLine()
		else
			TimMenu.BeginSector("Detection Alerts")
			N.Channels = N.Channels
				or { LocalChat = true, PublicChat = false, Party = false, Toast = true, Console = true }
			EditNotificationChannels("Detection channels", N.Channels)
			TimMenu.Text("Suspicion Filtering:")
			TimMenu.NextLine()
			N.SuspicionThreshold = TimMenu.Slider("Alert Threshold %", N.SuspicionThreshold or 30, 5, 95, 5)
			TimMenu.NextLine()
			N.SuspicionCooldown = TimMenu.Slider("Spam Cooldown (s)", N.SuspicionCooldown or 10, 5, 120, 5)
			TimMenu.NextLine()
			TimMenu.EndSector()
			TimMenu.NextLine()

			TimMenu.BeginSector("Detection Overrides")
			N.Overrides = N.Overrides or {}
			local OV = N.Overrides
			OV.Cheater = OV.Cheater
				or { LocalChat = true, PublicChat = false, Party = false, Toast = true, Console = true }
			OV.Valve = OV.Valve or { LocalChat = true, PublicChat = false, Party = false, Toast = true, Console = true }
			OV.UseCheaterOverride = TimMenu.Checkbox("Cheater override", OV.UseCheaterOverride == true)
			TimMenu.NextLine()
			if OV.UseCheaterOverride then
				EditNotificationChannels("Cheater channels", OV.Cheater)
			end
			OV.UseValveOverride = TimMenu.Checkbox("Valve override", OV.UseValveOverride == true)
			TimMenu.NextLine()
			if OV.UseValveOverride then
				EditNotificationChannels("Valve channels", OV.Valve)
			end
			TimMenu.EndSector()

			TimMenu.BeginSector("Presence Alerts")
			JN.Enable = TimMenu.Checkbox("Enable join/server alerts", JN.Enable == true)
			TimMenu.NextLine()

			if JN.Enable then
				JN.CheckCheater = TimMenu.Checkbox("Cheater alerts", JN.CheckCheater == true)
				TimMenu.NextLine()
				JN.CheckValve = TimMenu.Checkbox("Valve alerts", JN.CheckValve == true)
				TimMenu.NextLine()
				JN.DefaultOutput = JN.DefaultOutput
					or { LocalChat = true, PublicChat = false, Party = false, Toast = false, Console = true }
				JN.CheaterOverride = JN.CheaterOverride
					or { LocalChat = true, PublicChat = false, Party = false, Toast = false, Console = true }
				JN.ValveOverride = JN.ValveOverride
					or { LocalChat = true, PublicChat = false, Party = true, Toast = false, Console = true }
				EditJoinNotificationChannels("Presence channels", JN.DefaultOutput)
				JN.UseCheaterOverride = TimMenu.Checkbox("Cheater presence override", JN.UseCheaterOverride == true)
				TimMenu.NextLine()
				if JN.UseCheaterOverride then
					EditJoinNotificationChannels("Join cheater channels", JN.CheaterOverride)
				end
				JN.UseValveOverride = TimMenu.Checkbox("Valve presence override", JN.UseValveOverride == true)
				TimMenu.NextLine()
				if JN.UseValveOverride then
					EditJoinNotificationChannels("Join valve channels", JN.ValveOverride)
				end
			end
			TimMenu.EndSector()
			TimMenu.NextLine()
		end
	else
		TimMenu.BeginSector("Vote Automation")
		Misc.Autovote = TimMenu.Checkbox("Auto Vote", Misc.Autovote == true)
		TimMenu.NextLine()
		if Misc.Autovote then
			Misc.AutovoteAutoCast = TimMenu.Checkbox("Auto Cast Votes", Misc.AutovoteAutoCast == true)
			TimMenu.NextLine()

			Misc.intent = Misc.intent or {}
			local voteTargets =
			{ "Retaliation", "Bots (Cheat)", "Cheaters", "Valve Employees", "Legit Players", "Friends" }
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

		TimMenu.BeginSector("Summary")
		local dbCount = 0
		if type(G.DataBase) == "table" then
			for _ in pairs(G.DataBase) do
				dbCount = dbCount + 1
			end
		end
		TimMenu.Text("Database Entries: " .. dbCount)
		TimMenu.NextLine()

		local lastFetch = G.Database and G.Database.State and G.Database.State.lastSave
		if lastFetch and lastFetch > 0 then
			TimMenu.Text("Last Sync: " .. os.date("%H:%M:%S", lastFetch))
		else
			TimMenu.Text("Last Sync: Never")
		end
		TimMenu.NextLine()

		local bridgeText = "Bridge: Offline (safe fallback)"
		if HttpQueue and HttpQueue.IsBridgeAlive and HttpQueue.IsBridgeAlive() then
			bridgeText = "Bridge: Connected (local)"
		end
		TimMenu.Text(bridgeText)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Vote Reveal Alerts")
		Misc.Vote_Reveal = Misc.Vote_Reveal or {}
		Misc.Vote_Reveal.Enable = TimMenu.Checkbox("Vote Reveal", Misc.Vote_Reveal.Enable == true)
		TimMenu.NextLine()

		if Misc.Vote_Reveal.Enable then
			Misc.Vote_Reveal.Indicator = TimMenu.Checkbox("Vote Indicator", Misc.Vote_Reveal.Indicator == true)
			TimMenu.NextLine()
			Misc.Vote_Reveal.TargetTeam = Misc.Vote_Reveal.TargetTeam or { MyTeam = true, enemyTeam = true }
			local teamTable =
			{ Misc.Vote_Reveal.TargetTeam.MyTeam == true, Misc.Vote_Reveal.TargetTeam.enemyTeam == true }
			teamTable = TimMenu.Combo("Target Teams", teamTable, { "My Team", "Enemy Team" })
			Misc.Vote_Reveal.TargetTeam.MyTeam, Misc.Vote_Reveal.TargetTeam.enemyTeam = teamTable[1], teamTable[2]
			TimMenu.NextLine()
			Misc.Vote_Reveal.Output = Misc.Vote_Reveal.Output or { LocalChat = true, Toast = true, Console = true }
			local vo = Misc.Vote_Reveal.Output
			local act = {
				vo.LocalChat == true,
				vo.PublicChat == true,
				vo.Party == true,
				vo.Toast == true,
				vo.Console == true,
			}
			act = TimMenu.Combo("Vote Output", act, { "Local Chat", "Public Chat", "Party", "Notification", "Console" })
			vo.LocalChat, vo.PublicChat, vo.Party, vo.Toast, vo.Console = act[1], act[2], act[3], act[4], act[5]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()

		TimMenu.BeginSector("Class Change Alerts")
		Misc.Class_Change_Reveal = Misc.Class_Change_Reveal or {}
		Misc.Class_Change_Reveal.Enable =
			TimMenu.Checkbox("Class Change Reveal", Misc.Class_Change_Reveal.Enable == true)
		TimMenu.NextLine()
		if Misc.Class_Change_Reveal.Enable then
			Misc.Class_Change_Reveal.EnemyOnly =
				TimMenu.Checkbox("Enemy Team Only", Misc.Class_Change_Reveal.EnemyOnly ~= false)
			TimMenu.NextLine()
			Misc.Class_Change_Reveal.Output = Misc.Class_Change_Reveal.Output
				or { LocalChat = true, Toast = true, Console = true }
			local co = Misc.Class_Change_Reveal.Output
			local act = {
				co.LocalChat == true,
				co.PublicChat == true,
				co.Party == true,
				co.Toast == true,
				co.Console == true,
			}
			act = TimMenu.Combo(
				"Class Change Output",
				act,
				{ "Local Chat", "Public Chat", "Party", "Notification", "Console" }
			)
			co.LocalChat, co.PublicChat, co.Party, co.Toast, co.Console = act[1], act[2], act[3], act[4], act[5]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()
	end

	TimMenu.End()
	TickProfiler.EndSection("Draw_Menu")
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "CD_MENU")
callbacks.Register("Draw", "CD_MENU", DrawMenu)

return Menu
