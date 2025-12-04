local Menu = {}

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")

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
	local tabs = { "Main", "Advanced", "Misc" }
	G.Menu.currentTab = TimMenu.TabControl("cd_main_tabs", tabs, G.Menu.currentTab)
	TimMenu.NextLine()

	-- Main Configuration Tab
	if G.Menu.currentTab == "Main" then
		local Main = G.Menu.Main
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("SteamHistory")
		G.Menu.Misc.SteamHistory = G.Menu.Misc.SteamHistory or {}
		local sh = G.Menu.Misc.SteamHistory
		sh.ApiKey = sh.ApiKey or ""
		if type(sh.Enable) ~= "boolean" then
			sh.Enable = false
		end
		local hasKey = sh.ApiKey ~= ""
		if not hasKey then
			sh.Enable = false
			TimMenu.Text("API Key Missing!")
			TimMenu.Text("Get key at: steamhistory.net")
			TimMenu.Text("Console cmd: steamhistory <key>")
		else
			sh.Enable = TimMenu.Checkbox("Enable SteamHistory", sh.Enable)
			TimMenu.Tooltip("Scan players via SteamHistory API.")
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Detection Automation")
		TimMenu.Tooltip("Download external cheater lists on demand.")
		TimMenu.NextLine()
		if type(Main.AutoPriority) ~= "boolean" then
			Main.AutoPriority = true
		end
		Main.AutoPriority = TimMenu.Checkbox("Auto Priority", Main.AutoPriority)
		TimMenu.Tooltip("Set priority 10 on detected cheaters (from evidence, database, or SteamHistory)")
		TimMenu.NextLine()
		if type(Main.partyCallaut) ~= "boolean" then
			Main.partyCallaut = true
		end
		Main.partyCallaut = TimMenu.Checkbox("Party Callouts", Main.partyCallaut)
		TimMenu.Tooltip("Share detections with your party through chat.")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Visual Feedback")
		if type(Main.Chat_Prefix) ~= "boolean" then
			Main.Chat_Prefix = true
		end
		Main.Chat_Prefix = TimMenu.Checkbox("Chat Prefix", Main.Chat_Prefix)
		TimMenu.Tooltip("Enable colored chat tags for cheaters, suspects, and Valve staff.")
		TimMenu.NextLine()
		if type(Main.Cheater_Tags) ~= "boolean" then
			Main.Cheater_Tags = true
		end
		Main.Cheater_Tags = TimMenu.Checkbox("Cheater Tags", Main.Cheater_Tags)
		TimMenu.Tooltip("Show floating world labels for confirmed cheaters.")
		TimMenu.EndSector()
		TimMenu.NextLine()

		Misc.JoinNotifications = Misc.JoinNotifications or {}
		local JNMain = Misc.JoinNotifications
		if type(JNMain.ValveAutoDisconnect) ~= "boolean" then
			JNMain.ValveAutoDisconnect = false
		end

		TimMenu.BeginSector("Valve Safety")
		JNMain.ValveAutoDisconnect = TimMenu.Checkbox("Auto Leave on Valve Join", JNMain.ValveAutoDisconnect)
		TimMenu.Tooltip("Disconnect automatically when a Valve employee enters the server")
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
		if type(Advanced.Choke) ~= "boolean" then
			Advanced.Choke = true
		end
		Advanced.Choke = TimMenu.Checkbox("Fake Lag Detection", Advanced.Choke)
		TimMenu.NextLine()
		if type(Advanced.Warp) ~= "boolean" then
			Advanced.Warp = true
		end
		Advanced.Warp = TimMenu.Checkbox("Warp/DT Detection", Advanced.Warp)
		TimMenu.NextLine()
		if type(Advanced.AntyAim) ~= "boolean" then
			Advanced.AntyAim = true
		end
		Advanced.AntyAim = TimMenu.Checkbox("Anti-Aim Detection", Advanced.AntyAim)
		TimMenu.EndSector()

		TimMenu.BeginSector("Aim Detection")
		if type(Advanced.SilentAimbot) ~= "boolean" then
			Advanced.SilentAimbot = true
		end
		Advanced.SilentAimbot = TimMenu.Checkbox("Silent Aimbot (Extrapolation)", Advanced.SilentAimbot)
		TimMenu.Tooltip("Detects silent aim using viewangle extrapolation (experimental)")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Movement Detection")
		if type(Advanced.Bhop) ~= "boolean" then
			Advanced.Bhop = true
		end
		Advanced.Bhop = TimMenu.Checkbox("Bhop Detection", Advanced.Bhop)
		TimMenu.NextLine()
		if type(Advanced.DuckSpeed) ~= "boolean" then
			Advanced.DuckSpeed = true
		end
		Advanced.DuckSpeed = TimMenu.Checkbox("Duck Speed Detection", Advanced.DuckSpeed)
		TimMenu.EndSector()

		TimMenu.NextLine()

		TimMenu.BeginSector("Debug")
		if type(Advanced.debug) ~= "boolean" then
			Advanced.debug = false
		end
		Advanced.debug = TimMenu.Checkbox("Debug Mode", Advanced.debug)
		TimMenu.Tooltip("Enables debug features (auto-removes self from database, enables verbose logging)")

		local logLevels = { "Debug", "Info", "Warning", "Error" }
		Advanced.LogLevel = TimMenu.Combo("Log Level", Advanced.LogLevel, logLevels)
		TimMenu.Tooltip("Set console output verbosity (Debug = everything, Error = only critical)")

		TimMenu.EndSector()
		TimMenu.NextLine()
	elseif G.Menu.currentTab == "Misc" then
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("Vote Automation")
		if type(Misc.Autovote) ~= "boolean" then
			Misc.Autovote = false
		end
		Misc.Autovote = TimMenu.Checkbox("Auto Vote", Misc.Autovote)
		TimMenu.Tooltip("Call votes automatically using your selected targets.")
		TimMenu.NextLine()
		if Misc.Autovote then
			Misc.intent = Misc.intent or {}
			-- Initialize if needed
			if type(Misc.intent.retaliation) ~= "boolean" then
				Misc.intent.retaliation = true
			end
			if type(Misc.intent.legit) ~= "boolean" then
				Misc.intent.legit = true
			end
			if type(Misc.intent.cheater) ~= "boolean" then
				Misc.intent.cheater = true
			end
			if type(Misc.intent.bot) ~= "boolean" then
				Misc.intent.bot = true
			end
			if type(Misc.intent.valve) ~= "boolean" then
				Misc.intent.valve = true
			end
			if type(Misc.intent.friend) ~= "boolean" then
				Misc.intent.friend = false
			end
			if type(Misc.AutovoteAutoCast) ~= "boolean" then
				Misc.AutovoteAutoCast = true
			end
			Misc.AutovoteAutoCast = TimMenu.Checkbox("Auto Cast Votes", Misc.AutovoteAutoCast)
			TimMenu.Tooltip("Continuously initiate votes using the configured target priority.")
			TimMenu.NextLine()

			-- Priority order: Retaliation > Bots > Cheaters > Valve > Legits > Friends
			local voteTargets =
				{ "Retaliation", "Bots (Cheat)", "Cheaters", "Valve Employees", "Legit Players", "Friends" }
			local voteTable = {
				Misc.intent.retaliation,
				Misc.intent.bot,
				Misc.intent.cheater,
				Misc.intent.valve,
				Misc.intent.legit,
				Misc.intent.friend,
			}
			voteTable = TimMenu.Combo("Vote Targets", voteTable, voteTargets)
			Misc.intent.retaliation = voteTable[1]
			Misc.intent.bot = voteTable[2]
			Misc.intent.cheater = voteTable[3]
			Misc.intent.valve = voteTable[4]
			Misc.intent.legit = voteTable[5]
			Misc.intent.friend = voteTable[6]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()

		TimMenu.BeginSector("Vote Reveal Alerts")
		Misc.Vote_Reveal = Misc.Vote_Reveal or {}
		if type(Misc.Vote_Reveal.Enable) ~= "boolean" then
			Misc.Vote_Reveal.Enable = false
		end
		Misc.Vote_Reveal.TargetTeam = Misc.Vote_Reveal.TargetTeam or {}
		Misc.Vote_Reveal.Enable = TimMenu.Checkbox("Vote Reveal", Misc.Vote_Reveal.Enable)
		TimMenu.Tooltip("Announce teammate votes and their targets across selected channels.")
		TimMenu.NextLine()
		if Misc.Vote_Reveal.Enable then
			-- Initialize if needed
			if type(Misc.Vote_Reveal.TargetTeam.MyTeam) ~= "boolean" then
				Misc.Vote_Reveal.TargetTeam.MyTeam = true
			end
			if type(Misc.Vote_Reveal.TargetTeam.enemyTeam) ~= "boolean" then
				Misc.Vote_Reveal.TargetTeam.enemyTeam = true
			end

			-- Initialize new output options
			Misc.Vote_Reveal.Output = Misc.Vote_Reveal.Output or {}
			if type(Misc.Vote_Reveal.Output.PublicChat) ~= "boolean" then
				Misc.Vote_Reveal.Output.PublicChat = false
			end
			if type(Misc.Vote_Reveal.Output.PartyChat) ~= "boolean" then
				Misc.Vote_Reveal.Output.PartyChat = true
			end
			if type(Misc.Vote_Reveal.Output.ClientChat) ~= "boolean" then
				Misc.Vote_Reveal.Output.ClientChat = false
			end
			if type(Misc.Vote_Reveal.Output.Console) ~= "boolean" then
				Misc.Vote_Reveal.Output.Console = true
			end

			local teamOptions = { "My Team", "Enemy Team" }
			local teamTable = { Misc.Vote_Reveal.TargetTeam.MyTeam, Misc.Vote_Reveal.TargetTeam.enemyTeam }
			teamTable = TimMenu.Combo("Target Teams", teamTable, teamOptions)
			Misc.Vote_Reveal.TargetTeam.MyTeam = teamTable[1]
			Misc.Vote_Reveal.TargetTeam.enemyTeam = teamTable[2]
			TimMenu.NextLine()

			local outputOptions = { "Public Chat", "Party Chat", "Client Chat", "Console" }
			local outputTable = {
				Misc.Vote_Reveal.Output.PublicChat,
				Misc.Vote_Reveal.Output.PartyChat,
				Misc.Vote_Reveal.Output.ClientChat,
				Misc.Vote_Reveal.Output.Console,
			}
			outputTable = TimMenu.Combo("Vote Output", outputTable, outputOptions)
			Misc.Vote_Reveal.Output.PublicChat = outputTable[1]
			Misc.Vote_Reveal.Output.PartyChat = outputTable[2]
			Misc.Vote_Reveal.Output.ClientChat = outputTable[3]
			Misc.Vote_Reveal.Output.Console = outputTable[4]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Join Alerts")
		-- Initialize JoinNotifications if needed
		Misc.JoinNotifications = Misc.JoinNotifications or {}
		local JN = Misc.JoinNotifications

		if type(JN.Enable) ~= "boolean" then
			JN.Enable = true
		end
		if type(JN.CheckCheater) ~= "boolean" then
			JN.CheckCheater = true
		end
		if type(JN.CheckValve) ~= "boolean" then
			JN.CheckValve = true
		end
		if type(JN.ValveAutoDisconnect) ~= "boolean" then
			JN.ValveAutoDisconnect = false
		end

		JN.Enable = TimMenu.Checkbox("Join Alerts", JN.Enable)
		TimMenu.Tooltip("Warn about cheaters or Valve employees joining the match.")
		TimMenu.NextLine()

		if JN.Enable then
			-- Target filters
			local notifTypes = { "Cheaters", "Valve" }
			local notifTable = { JN.CheckCheater, JN.CheckValve }
			notifTable = TimMenu.Combo("Notify For", notifTable, notifTypes)
			JN.CheckCheater = notifTable[1]
			JN.CheckValve = notifTable[2]
			TimMenu.NextLine()

			-- Default output channels
			JN.DefaultOutput = JN.DefaultOutput or {}
			if type(JN.DefaultOutput.PublicChat) ~= "boolean" then
				JN.DefaultOutput.PublicChat = false
			end
			if type(JN.DefaultOutput.PartyChat) ~= "boolean" then
				JN.DefaultOutput.PartyChat = true
			end
			if type(JN.DefaultOutput.ClientChat) ~= "boolean" then
				JN.DefaultOutput.ClientChat = false
			end
			if type(JN.DefaultOutput.Console) ~= "boolean" then
				JN.DefaultOutput.Console = true
			end

			local defaultOutputOptions = { "Public Chat", "Party Chat", "Client Chat", "Console" }
			local defaultOutputTable = {
				JN.DefaultOutput.PublicChat,
				JN.DefaultOutput.PartyChat,
				JN.DefaultOutput.ClientChat,
				JN.DefaultOutput.Console,
			}
			defaultOutputTable = TimMenu.Combo("Default Output", defaultOutputTable, defaultOutputOptions)
			JN.DefaultOutput.PublicChat = defaultOutputTable[1]
			JN.DefaultOutput.PartyChat = defaultOutputTable[2]
			JN.DefaultOutput.ClientChat = defaultOutputTable[3]
			JN.DefaultOutput.Console = defaultOutputTable[4]
			TimMenu.NextLine()

			-- Cheater override
			if type(JN.UseCheaterOverride) ~= "boolean" then
				JN.UseCheaterOverride = false
			end
			JN.UseCheaterOverride = TimMenu.Checkbox("Cheater Output Override", JN.UseCheaterOverride)
			TimMenu.Tooltip("Send cheater alerts to custom chat channels.")
			TimMenu.NextLine()

			if JN.UseCheaterOverride then
				JN.CheaterOverride = JN.CheaterOverride or {}
				if type(JN.CheaterOverride.PublicChat) ~= "boolean" then
					JN.CheaterOverride.PublicChat = false
				end
				if type(JN.CheaterOverride.PartyChat) ~= "boolean" then
					JN.CheaterOverride.PartyChat = true
				end
				if type(JN.CheaterOverride.ClientChat) ~= "boolean" then
					JN.CheaterOverride.ClientChat = false
				end
				if type(JN.CheaterOverride.Console) ~= "boolean" then
					JN.CheaterOverride.Console = true
				end

				local cheaterOutputTable = {
					JN.CheaterOverride.PublicChat,
					JN.CheaterOverride.PartyChat,
					JN.CheaterOverride.ClientChat,
					JN.CheaterOverride.Console,
				}
				cheaterOutputTable = TimMenu.Combo("Cheater Output", cheaterOutputTable, defaultOutputOptions)
				JN.CheaterOverride.PublicChat = cheaterOutputTable[1]
				JN.CheaterOverride.PartyChat = cheaterOutputTable[2]
				JN.CheaterOverride.ClientChat = cheaterOutputTable[3]
				JN.CheaterOverride.Console = cheaterOutputTable[4]
				TimMenu.NextLine()
			end

			-- Valve override
			if type(JN.UseValveOverride) ~= "boolean" then
				JN.UseValveOverride = false
			end
			JN.UseValveOverride = TimMenu.Checkbox("Valve Output Override", JN.UseValveOverride)
			TimMenu.Tooltip("Send Valve alerts to custom chat channels.")
			TimMenu.NextLine()

			if JN.UseValveOverride then
				JN.ValveOverride = JN.ValveOverride or {}
				if type(JN.ValveOverride.PublicChat) ~= "boolean" then
					JN.ValveOverride.PublicChat = false
				end
				if type(JN.ValveOverride.PartyChat) ~= "boolean" then
					JN.ValveOverride.PartyChat = false
				end
				if type(JN.ValveOverride.ClientChat) ~= "boolean" then
					JN.ValveOverride.ClientChat = true
				end
				if type(JN.ValveOverride.Console) ~= "boolean" then
					JN.ValveOverride.Console = true
				end

				local valveOutputTable = {
					JN.ValveOverride.PublicChat,
					JN.ValveOverride.PartyChat,
					JN.ValveOverride.ClientChat,
					JN.ValveOverride.Console,
				}
				valveOutputTable = TimMenu.Combo("Valve Output", valveOutputTable, defaultOutputOptions)
				JN.ValveOverride.PublicChat = valveOutputTable[1]
				JN.ValveOverride.PartyChat = valveOutputTable[2]
				JN.ValveOverride.ClientChat = valveOutputTable[3]
				JN.ValveOverride.Console = valveOutputTable[4]
				TimMenu.NextLine()
			end
		end
		TimMenu.EndSector()

		TimMenu.BeginSector("Class Change Alerts")
		Misc.Class_Change_Reveal.Enable = TimMenu.Checkbox("Class Change Reveal", Misc.Class_Change_Reveal.Enable)
		TimMenu.Tooltip("Notify when tracked players switch classes.")
		TimMenu.NextLine()
		if Misc.Class_Change_Reveal.Enable then
			-- Initialize if needed
			if type(Misc.Class_Change_Reveal.EnemyOnly) ~= "boolean" then
				Misc.Class_Change_Reveal.EnemyOnly = true
			end

			-- Initialize new output options
			Misc.Class_Change_Reveal.Output = Misc.Class_Change_Reveal.Output or {}
			if type(Misc.Class_Change_Reveal.Output.PublicChat) ~= "boolean" then
				Misc.Class_Change_Reveal.Output.PublicChat = false
			end
			if type(Misc.Class_Change_Reveal.Output.PartyChat) ~= "boolean" then
				Misc.Class_Change_Reveal.Output.PartyChat = true
			end
			if type(Misc.Class_Change_Reveal.Output.ClientChat) ~= "boolean" then
				Misc.Class_Change_Reveal.Output.ClientChat = false
			end
			if type(Misc.Class_Change_Reveal.Output.Console) ~= "boolean" then
				Misc.Class_Change_Reveal.Output.Console = true
			end

			Misc.Class_Change_Reveal.EnemyOnly = TimMenu.Checkbox("Enemy Team Only", Misc.Class_Change_Reveal.EnemyOnly)
			TimMenu.NextLine()

			local classOutputOptions = { "Public Chat", "Party Chat", "Client Chat", "Console" }
			local classOutputTable = {
				Misc.Class_Change_Reveal.Output.PublicChat,
				Misc.Class_Change_Reveal.Output.PartyChat,
				Misc.Class_Change_Reveal.Output.ClientChat,
				Misc.Class_Change_Reveal.Output.Console,
			}
			classOutputTable = TimMenu.Combo("Class Change Output", classOutputTable, classOutputOptions)
			Misc.Class_Change_Reveal.Output.PublicChat = classOutputTable[1]
			Misc.Class_Change_Reveal.Output.PartyChat = classOutputTable[2]
			Misc.Class_Change_Reveal.Output.ClientChat = classOutputTable[3]
			Misc.Class_Change_Reveal.Output.Console = classOutputTable[4]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		if TimMenu.Button("Fetch Database") then
			local Fetcher = require("Cheater_Detection.Database.Fetcher")
			Fetcher.Start()
		end

		TimMenu.NextLine()

		TimMenu.EndSector()
		TimMenu.NextLine()
	end

	-- Always end the menu
	TimMenu.End()

	TickProfiler.EndSection("Draw_Menu")
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "CD_MENU")
callbacks.Register("Draw", "CD_MENU", DrawMenu)

return Menu
