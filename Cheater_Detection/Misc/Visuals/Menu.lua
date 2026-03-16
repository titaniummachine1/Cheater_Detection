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
	local tabs = { "Detections", "Automation", "Visuals", "Misc" }
	G.Menu.currentTab = TimMenu.TabControl("cd_main_tabs", tabs, G.Menu.currentTab)
	TimMenu.NextLine()

	-- Detections Tab (Logic & Toggles)
	if G.Menu.currentTab == "Detections" then
		local Advanced = G.Menu.Advanced

		TimMenu.BeginSector("Scanner Settings")
		local Main = G.Menu.Main
		if type(Main.AutoSync) ~= "boolean" then Main.AutoSync = true end
		Main.AutoSync = TimMenu.Checkbox("Auto-Sync Databases", Main.AutoSync)
		TimMenu.Tooltip("Automatically fetch online cheater lists on startup.")
		
		G.Menu.Scanner = G.Menu.Scanner or { ValveCheck = true }
		G.Menu.Scanner.ValveCheck = TimMenu.Checkbox("Valve Employee Check", G.Menu.Scanner.ValveCheck)
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

		TimMenu.BeginSector("Exploit Detection")
		if type(Advanced.Choke) ~= "boolean" then Advanced.Choke = true end
		Advanced.Choke = TimMenu.Checkbox("Fake Lag Detection", Advanced.Choke)
		if type(Advanced.Warp) ~= "boolean" then Advanced.Warp = true end
		Advanced.Warp = TimMenu.Checkbox("Warp/DT Detection", Advanced.Warp)
		if type(Advanced.AntyAim) ~= "boolean" then Advanced.AntyAim = true end
		Advanced.AntyAim = TimMenu.Checkbox("Anti-Aim Detection", Advanced.AntyAim)
		TimMenu.EndSector()

		TimMenu.BeginSector("Combat Detection")
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

	-- Automation Tab (Votes & Responses)
	elseif G.Menu.currentTab == "Automation" then
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("Vote Management")
		if type(Misc.Autovote) ~= "boolean" then Misc.Autovote = false end
		Misc.Autovote = TimMenu.Checkbox("Auto Call Votes", Misc.Autovote)
		TimMenu.Tooltip("Call votes automatically using your selected targets.")
		
		if Misc.Autovote then
			if type(Misc.AutovoteAutoCast) ~= "boolean" then Misc.AutovoteAutoCast = true end
			Misc.AutovoteAutoCast = TimMenu.Checkbox("Auto Cast Votes", Misc.AutovoteAutoCast)
			TimMenu.Tooltip("Continuously initiate votes using the configured target priority.")
			
			Misc.intent = Misc.intent or {}
			local voteTargets = { "Retaliation", "Bots", "Cheaters", "Valve", "Legit", "Friends" }
			local voteTable = {
				Misc.intent.retaliation ~= false,
				Misc.intent.bot ~= false,
				Misc.intent.cheater ~= false,
				Misc.intent.valve ~= false,
				Misc.intent.legit ~= false,
				Misc.intent.friend == true,
			}
			voteTable = TimMenu.Combo("Kick Priority", voteTable, voteTargets)
			Misc.intent.retaliation, Misc.intent.bot, Misc.intent.cheater, Misc.intent.valve, Misc.intent.legit, Misc.intent.friend = 
				voteTable[1], voteTable[2], voteTable[3], voteTable[4], voteTable[5], voteTable[6]
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Safety Automation")
		Misc.JoinNotifications = Misc.JoinNotifications or {}
		local JN = Misc.JoinNotifications
		if type(JN.ValveAutoDisconnect) ~= "boolean" then JN.ValveAutoDisconnect = false end
		JN.ValveAutoDisconnect = TimMenu.Checkbox("Auto Leave on Valve Join", JN.ValveAutoDisconnect)
		TimMenu.Tooltip("Disconnect automatically when a Valve employee enters the server.")
		TimMenu.EndSector()

	-- Visuals & Notifications Tab
	elseif G.Menu.currentTab == "Visuals" then
		local Main = G.Menu.Main
		local N = G.Menu.Notifications or {}

		TimMenu.BeginSector("Feedback Overlays")
		if type(Main.Chat_Prefix) ~= "boolean" then Main.Chat_Prefix = true end
		Main.Chat_Prefix = TimMenu.Checkbox("Chat Prefix", Main.Chat_Prefix)
		if type(Main.Cheater_Tags) ~= "boolean" then Main.Cheater_Tags = true end
		Main.Cheater_Tags = TimMenu.Checkbox("World Tags", Main.Cheater_Tags)
		
		if Main.Cheater_Tags then
			Main.TagFilters = Main.TagFilters or {true, true, true, true}
			Main.TagFilters = TimMenu.Combo("Visible Tags", Main.TagFilters, { "Valve", "Cheater", "VAC", "Suspicious" })
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Notification Settings")
		if type(N.Enable) ~= "boolean" then N.Enable = true end
		N.Enable = TimMenu.Checkbox("Enable System-Wide Alerts", N.Enable)
		
		if N.Enable then
			local channelOptions = { "Local Chat", "Public Chat", "Party", "Log Toast", "Console" }
			N.Channels = N.Channels or {LocalChat=true, PublicChat=false, Party=false, Toast=true, Console=true}
			local ch = N.Channels
			local act = { ch.LocalChat, ch.PublicChat, ch.Party, ch.Toast, ch.Console }
			act = TimMenu.Combo("Output Channels", act, channelOptions)
			ch.LocalChat, ch.PublicChat, ch.Party, ch.Toast, ch.Console = act[1], act[2], act[3], act[4], act[5]
		end
		TimMenu.EndSector()

	-- Misc Tab (Summary & Tools)
	elseif G.Menu.currentTab == "Misc" then
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("Vote Reveal")
		Misc.Vote_Reveal = Misc.Vote_Reveal or {}
		if type(Misc.Vote_Reveal.Enable) ~= "boolean" then Misc.Vote_Reveal.Enable = false end
		Misc.Vote_Reveal.Enable = TimMenu.Checkbox("Show Real-Time Progress", Misc.Vote_Reveal.Enable)
		TimMenu.Tooltip("Show a visual UI of ongoing votes and who is voting.")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("System Summary")
		local dbCount = 0
		if type(G.DataBase) == "table" then
			for _ in pairs(G.DataBase) do dbCount = dbCount + 1 end
		end
		TimMenu.Text("Database Entries: " .. dbCount)
		TimMenu.NextLine()
		
		local Advanced = G.Menu.Advanced
		if type(Advanced.debug) ~= "boolean" then Advanced.debug = false end
		Advanced.debug = TimMenu.Checkbox("Developer Debug Mode", Advanced.debug)
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
