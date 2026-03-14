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
        G.Menu.Scanner = G.Menu.Scanner or { SteamHistory = false, ValveCheck = true }
        local sc = G.Menu.Scanner
        
        -- Valve check toggle
        sc.ValveCheck = TimMenu.Checkbox("Valve Check", sc.ValveCheck)
        TimMenu.Tooltip("Verify if players are Valve employees via profiles and items.")

        -- SteamHistory section inside scanner
		Misc.SteamHistory = Misc.SteamHistory or {}
		local sh = Misc.SteamHistory
		sh.ApiKey = sh.ApiKey or ""
		local hasKey = sh.ApiKey ~= ""
		
		if not hasKey then
			sc.SteamHistory = false
			TimMenu.Text("SteamHistory: API Key Missing!")
			TimMenu.Tooltip("Get key at steamhistory.net and set via console: steamhistory <key>")
		else
			sc.SteamHistory = TimMenu.Checkbox("Steam History", sc.SteamHistory)
			TimMenu.Tooltip("Scan players via SteamHistory API (requires API Key).")
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
		TimMenu.NextLine()

		if Main.Cheater_Tags then
			Main.TagFilters = Main.TagFilters or {}
			local tf = Main.TagFilters
			-- TagFilters stored as a Combo-compatible boolean array
			-- [1]=Valve, [2]=Cheater, [3]=VAC, [4]=Suspicious
			if type(tf[1]) ~= "boolean" then tf[1] = true end
			if type(tf[2]) ~= "boolean" then tf[2] = true end
			if type(tf[3]) ~= "boolean" then tf[3] = true end
			if type(tf[4]) ~= "boolean" then tf[4] = true end
			Main.TagFilters = TimMenu.Combo("Visible Tags", tf, { "Valve", "Cheater", "VAC", "Suspicious" })
			TimMenu.NextLine()
		end
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
		-- Stored as 0–100 %; internally scaled x2 to match the evidence score range
		if type(Advanced.Evicence_Tolerance) ~= "number" then
			Advanced.Evicence_Tolerance = 50
		end
		-- Clamp legacy values > 100 down to the new scale
		if Advanced.Evicence_Tolerance > 100 then
			Advanced.Evicence_Tolerance = 50
		end
		Advanced.Evicence_Tolerance = TimMenu.Slider("Evidence Threshold %", Advanced.Evicence_Tolerance, 0, 100, 1)
		TimMenu.Tooltip("Minimum suspicion % required to auto-mark a player as a cheater (higher = stricter)")
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
	elseif G.Menu.currentTab == "Notifications" then
		G.Menu.Notifications = G.Menu.Notifications or {}
		local N = G.Menu.Notifications

		-- Defaults: migrate old key names on first load
		if type(N.Enable) ~= "boolean" then N.Enable = true end
		N.Channels = N.Channels or {}
		if type(N.Channels.LocalChat)  ~= "boolean" then N.Channels.LocalChat  = true  end
		if type(N.Channels.PublicChat) ~= "boolean" then N.Channels.PublicChat = false end
		if type(N.Channels.Party)      ~= "boolean" then N.Channels.Party      = false end
		if type(N.Channels.Toast)      ~= "boolean" then N.Channels.Toast      = true  end
		if type(N.Channels.Console)    ~= "boolean" then N.Channels.Console    = true  end
		if type(N.SuspicionCooldown) ~= "number" then N.SuspicionCooldown = 15 end
		if type(N.SuspicionThreshold) ~= "number" then N.SuspicionThreshold = 30 end

		TimMenu.BeginSector("Master Switch")
		N.Enable = TimMenu.Checkbox("Enable System-Wide Notifications", N.Enable)
		TimMenu.Tooltip("Master toggle for all chat and visual alerts.")
		TimMenu.EndSector()
		TimMenu.NextLine()

		if N.Enable then
			-- Helper for drawing consistent channel lists
			local channelOptions = { "Local Chat", "Public Chat", "Party", "Log Toast", "Console Log" }
			local function DrawChannelList(label, ch)
				local act = { ch.LocalChat, ch.PublicChat, ch.Party, ch.Toast, ch.Console }
				act = TimMenu.Combo(label, act, channelOptions)
				ch.LocalChat = act[1]
				ch.PublicChat = act[2]
				ch.Party = act[3]
				ch.Toast = act[4]
				ch.Console = act[5]
				TimMenu.NextLine()
			end

			-- 1. Main Output Configuration
			TimMenu.BeginSector("Global Output Settings")
			TimMenu.Text("Default channels for all detections:")
			TimMenu.NextLine()
			DrawChannelList("Active Channels", N.Channels)
			
			TimMenu.Text("Suspicion Filtering:")
			TimMenu.NextLine()
			N.SuspicionThreshold = TimMenu.Slider("Alert Threshold %", N.SuspicionThreshold, 5, 95, 5)
			TimMenu.Tooltip("Only notify if a player's suspicion score exceeds this percentage.")
			TimMenu.NextLine()
			N.SuspicionCooldown = TimMenu.Slider("Spam Cooldown (s)", N.SuspicionCooldown, 5, 120, 5)
			TimMenu.Tooltip("Wait this long before updating a player's suspicion alert in chat.")
			TimMenu.EndSector()
			TimMenu.NextLine()

			-- 2. conditional situational overrides
			TimMenu.BeginSector("Conditional Overrides")
			N.Overrides = N.Overrides or {}
			local OV = N.Overrides

			-- Cheater Override
			if type(OV.UseCheaterOverride) ~= "boolean" then OV.UseCheaterOverride = false end
			OV.UseCheaterOverride = TimMenu.Checkbox("Unique Channels for Confirmed Cheaters", OV.UseCheaterOverride)
			TimMenu.Tooltip("Use different chat channels when a player is 100% caught cheating.")
			TimMenu.NextLine()
			if OV.UseCheaterOverride then
				OV.Cheater = OV.Cheater or { LocalChat=true, PublicChat=false, Party=false, Toast=true, Console=true }
				DrawChannelList("-> Cheater Output", OV.Cheater)
			end

			-- Valve Override
			if type(OV.UseValveOverride) ~= "boolean" then OV.UseValveOverride = false end
			OV.UseValveOverride = TimMenu.Checkbox("Unique Channels for Valve Employees", OV.UseValveOverride)
			TimMenu.Tooltip("Use different chat channels for Valve detections.")
			TimMenu.NextLine()
			if OV.UseValveOverride then
				OV.Valve = OV.Valve or { LocalChat=true, PublicChat=false, Party=true, Toast=true, Console=true }
				DrawChannelList("-> Valve Output", OV.Valve)
			end
			TimMenu.EndSector()
			TimMenu.NextLine()

			-- 3. Join Alerts
			TimMenu.BeginSector("Join & Discovery Alerts")
			local Misc = G.Menu.Misc or {}
			Misc.JoinNotifications = Misc.JoinNotifications or {}
			local JN = Misc.JoinNotifications
			if type(JN.Enable) ~= "boolean" then JN.Enable = true end
			if type(JN.CheckCheater) ~= "boolean" then JN.CheckCheater = true end
			if type(JN.CheckValve) ~= "boolean" then JN.CheckValve = true end

			JN.Enable = TimMenu.Checkbox("Notify on Player Connections", JN.Enable)
			TimMenu.Tooltip("Warning popups when a labeled player joins the server mid-game.")
			TimMenu.NextLine()
			if JN.Enable then
				JN.CheckCheater = TimMenu.Checkbox("Alert for Cheaters", JN.CheckCheater)
				TimMenu.SameLine()
				JN.CheckValve = TimMenu.Checkbox("Alert for Valve", JN.CheckValve)
				TimMenu.NextLine()
			end
			TimMenu.EndSector()
			TimMenu.NextLine()
		end

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

		local channelOptions = { "Local Chat", "Public Chat", "Party", "Notification", "Console" }
		local function DrawChannelCombo(label, ch)
			local act = { ch.LocalChat, ch.PublicChat, ch.Party, ch.Toast, ch.Console }
			act = TimMenu.Combo(label, act, channelOptions)
			ch.LocalChat = act[1]
			ch.PublicChat = act[2]
			ch.Party = act[3]
			ch.Toast = act[4]
			ch.Console = act[5]
			TimMenu.NextLine()
		end

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
			if type(Misc.Vote_Reveal.TargetTeam.MyTeam) ~= "boolean" then Misc.Vote_Reveal.TargetTeam.MyTeam = true end
			if type(Misc.Vote_Reveal.TargetTeam.enemyTeam) ~= "boolean" then Misc.Vote_Reveal.TargetTeam.enemyTeam = true end

			Misc.Vote_Reveal.Output = Misc.Vote_Reveal.Output or {}
			local vo = Misc.Vote_Reveal.Output
			if type(vo.LocalChat)  ~= "boolean" then vo.LocalChat  = true  end
			if type(vo.PublicChat) ~= "boolean" then vo.PublicChat = false end
			if type(vo.Party)      ~= "boolean" then vo.Party      = false end
			if type(vo.Toast)      ~= "boolean" then vo.Toast      = true  end
			if type(vo.Console)    ~= "boolean" then vo.Console    = true  end

			local teamOptions = { "My Team", "Enemy Team" }
			local teamTable = { Misc.Vote_Reveal.TargetTeam.MyTeam, Misc.Vote_Reveal.TargetTeam.enemyTeam }
			teamTable = TimMenu.Combo("Target Teams", teamTable, teamOptions)
			Misc.Vote_Reveal.TargetTeam.MyTeam = teamTable[1]
			Misc.Vote_Reveal.TargetTeam.enemyTeam = teamTable[2]
			TimMenu.NextLine()

			DrawChannelCombo("Vote Output", vo)
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Class Change Alerts")
		Misc.Class_Change_Reveal = Misc.Class_Change_Reveal or {}
		if type(Misc.Class_Change_Reveal.Enable) ~= "boolean" then
			Misc.Class_Change_Reveal.Enable = false
		end
		Misc.Class_Change_Reveal.Enable = TimMenu.Checkbox("Class Change Reveal", Misc.Class_Change_Reveal.Enable)
		TimMenu.Tooltip("Notify when tracked players switch classes.")
		TimMenu.NextLine()
		if Misc.Class_Change_Reveal.Enable then
			if type(Misc.Class_Change_Reveal.EnemyOnly) ~= "boolean" then
				Misc.Class_Change_Reveal.EnemyOnly = true
			end

			Misc.Class_Change_Reveal.Output = Misc.Class_Change_Reveal.Output or {}
			local co = Misc.Class_Change_Reveal.Output
			if type(co.LocalChat)  ~= "boolean" then co.LocalChat  = true  end
			if type(co.PublicChat) ~= "boolean" then co.PublicChat = false end
			if type(co.Party)      ~= "boolean" then co.Party      = false end
			if type(co.Toast)      ~= "boolean" then co.Toast      = true  end
			if type(co.Console)    ~= "boolean" then co.Console    = true  end

			Misc.Class_Change_Reveal.EnemyOnly = TimMenu.Checkbox("Enemy Team Only", Misc.Class_Change_Reveal.EnemyOnly)
			TimMenu.NextLine()

			DrawChannelCombo("Class Change Output", co)
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Summary")
		local dbCount = 0
		if type(G.DataBase) == "table" then
			for _ in pairs(G.DataBase) do
				dbCount = dbCount + 1
			end
		end
		TimMenu.Text("Database Entries: " .. tostring(dbCount))
		TimMenu.NextLine()
		
		local lastFetch = G and G.Menu and G.Menu.Main and G.Menu.Main.LastFetchTimestamp
		if lastFetch then
			TimMenu.Text("Last Sync: " .. os.date("%H:%M:%S", lastFetch))
		else
			TimMenu.Text("Last Sync: Never")
		end
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
