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
		TimMenu.NextLine()

		if Main.Cheater_Tags then
			Main.TagFilters = Main.TagFilters or {}
			local tf = Main.TagFilters
			if type(tf.ShowValve)   ~= "boolean" then tf.ShowValve   = true end
			if type(tf.ShowCheater) ~= "boolean" then tf.ShowCheater = true end
			if type(tf.ShowVac)     ~= "boolean" then tf.ShowVac     = true end
			if type(tf.ShowSus)     ~= "boolean" then tf.ShowSus     = true end

			tf.ShowValve   = TimMenu.Checkbox("  Valve Employee", tf.ShowValve)
			TimMenu.NextLine()
			tf.ShowCheater = TimMenu.Checkbox("  Cheater", tf.ShowCheater)
			TimMenu.NextLine()
			tf.ShowVac     = TimMenu.Checkbox("  VAC Banned", tf.ShowVac)
			TimMenu.NextLine()
			tf.ShowSus     = TimMenu.Checkbox("  Suspicious", tf.ShowSus)
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
		if type(N.SuspicionCooldown) ~= "number" then N.SuspicionCooldown = 10 end
		if type(N.SuspicionThreshold) ~= "number" then N.SuspicionThreshold = 30 end

		TimMenu.BeginSector("General")
		N.Enable = TimMenu.Checkbox("Enable Notifications", N.Enable)
		TimMenu.Tooltip("Master toggle for all detection notifications.")
		TimMenu.EndSector()
		TimMenu.NextLine()

		if N.Enable then
			TimMenu.BeginSector("Suspicion Alerts")
			N.SuspicionCooldown = TimMenu.Slider("Cooldown (s)", N.SuspicionCooldown, 5, 60, 1)
			TimMenu.Tooltip("Min. seconds between suspicion % update notifications per player.")
			TimMenu.NextLine()
			N.SuspicionThreshold = TimMenu.Slider("Min. Sus % to Alert", N.SuspicionThreshold, 10, 99, 1)
			TimMenu.Tooltip("Only notify if suspicion exceeds this %.")
			TimMenu.EndSector()
			TimMenu.NextLine()

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

			TimMenu.BeginSector("Output Channels")
			TimMenu.Text("Where to send detection alerts:")
			TimMenu.NextLine()
			DrawChannelCombo("Active Channels", N.Channels)
			TimMenu.EndSector()
			TimMenu.NextLine()

			-- Per-type overrides
			N.Overrides = N.Overrides or {}
			local OV = N.Overrides

			TimMenu.BeginSector("Override: Confirmed Cheater")
			if type(OV.UseCheaterOverride) ~= "boolean" then OV.UseCheaterOverride = false end
			OV.UseCheaterOverride = TimMenu.Checkbox("Custom Channels for Cheater", OV.UseCheaterOverride)
			TimMenu.Tooltip("Override output channels for confirmed cheater detections.")
			TimMenu.NextLine()
			if OV.UseCheaterOverride then
				OV.Cheater = OV.Cheater or { LocalChat=true, PublicChat=false, Party=false, Toast=true, Console=true }
				if type(OV.Cheater.LocalChat)  ~= "boolean" then OV.Cheater.LocalChat  = true  end
				if type(OV.Cheater.PublicChat) ~= "boolean" then OV.Cheater.PublicChat = false end
				if type(OV.Cheater.Party)      ~= "boolean" then OV.Cheater.Party      = false end
				if type(OV.Cheater.Toast)      ~= "boolean" then OV.Cheater.Toast      = true  end
				if type(OV.Cheater.Console)    ~= "boolean" then OV.Cheater.Console    = true  end
				DrawChannelCombo("Cheater Channels", OV.Cheater)
			end
			TimMenu.EndSector()
			TimMenu.NextLine()

			TimMenu.BeginSector("Override: Valve Employee")
			if type(OV.UseValveOverride) ~= "boolean" then OV.UseValveOverride = false end
			OV.UseValveOverride = TimMenu.Checkbox("Custom Channels for Valve", OV.UseValveOverride)
			TimMenu.Tooltip("Override output channels for Valve employee detections.")
			TimMenu.NextLine()
			if OV.UseValveOverride then
				OV.Valve = OV.Valve or { LocalChat=true, PublicChat=false, Party=true, Toast=true, Console=true }
				if type(OV.Valve.LocalChat)  ~= "boolean" then OV.Valve.LocalChat  = true  end
				if type(OV.Valve.PublicChat) ~= "boolean" then OV.Valve.PublicChat = false end
				if type(OV.Valve.Party)      ~= "boolean" then OV.Valve.Party      = true  end
				if type(OV.Valve.Toast)      ~= "boolean" then OV.Valve.Toast      = true  end
				if type(OV.Valve.Console)    ~= "boolean" then OV.Valve.Console    = true  end
				DrawChannelCombo("Valve Channels", OV.Valve)
			end
			TimMenu.EndSector()
			TimMenu.NextLine()

			-- ---- Join Alerts (moved here from Misc tab) ----
			local Misc = G.Menu.Misc or {}
			Misc.JoinNotifications = Misc.JoinNotifications or {}
			local JN = Misc.JoinNotifications
			if type(JN.Enable) ~= "boolean" then JN.Enable = true end
			if type(JN.CheckCheater) ~= "boolean" then JN.CheckCheater = true end
			if type(JN.CheckValve) ~= "boolean" then JN.CheckValve = true end

			TimMenu.BeginSector("Join Alerts")
			JN.Enable = TimMenu.Checkbox("Alert on Player Join", JN.Enable)
			TimMenu.Tooltip("Warn when a cheater or Valve employee joins the match.")
			TimMenu.NextLine()
			if JN.Enable then
				JN.CheckCheater = TimMenu.Checkbox("Cheaters", JN.CheckCheater)
				TimMenu.SameLine()
				JN.CheckValve = TimMenu.Checkbox("Valve Employees", JN.CheckValve)
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
