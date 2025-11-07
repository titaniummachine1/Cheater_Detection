local Menu = {}

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local AdvancedLayout = require("Cheater_Detection.Utils.AdvancedLayout")

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
	if G.Menu.Advanced.debug then
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
	G.Menu.currentTab = AdvancedLayout.CreateTabbedSection(tabs, G.Menu.currentTab, {
		Main = function()
			drawMainTab()
		end,
		Advanced = function()
			drawAdvancedTab()
		end,
		Misc = function()
			drawMiscTab()
		end,
	})

	-- Always end the menu
	TimMenu.End()
end

local function drawMainTab()
	local Main = G.Menu.Main
	local Misc = G.Menu.Misc

	-- Create sectors in rows for better organization
	-- First row: Database & Detection | Visual Settings
	AdvancedLayout.CreateSectorRow({
		{
			title = "Database & Detection",
			content = function()
				AdvancedLayout.CreateCheckbox("Fetch Database", Main, "Fetch_Database")
				AdvancedLayout.StandardizeSpacing()
				AdvancedLayout.CreateCheckbox("Auto Mark", Main, "AutoMark")
				AdvancedLayout.StandardizeSpacing()
				AdvancedLayout.CreateCheckbox("Party Callout", Main, "partyCallaut")
			end,
		},
		{
			title = "Visual Settings",
			content = function()
				AdvancedLayout.CreateCheckbox("Chat Prefix", Main, "Chat_Prefix")
				AdvancedLayout.StandardizeSpacing()
				AdvancedLayout.CreateCheckbox("Cheater Tags", Main, "Cheater_Tags")
				AdvancedLayout.StandardizeSpacing()
				AdvancedLayout.CreateCheckbox("Join Warning", Main, "JoinWarning")
			end,
		},
	})

	-- Second row: Valve Safety (standalone)
	Misc.JoinNotifications = Misc.JoinNotifications or {}
	local JNMain = Misc.JoinNotifications
	if type(JNMain.ValveAutoDisconnect) ~= "boolean" then
		JNMain.ValveAutoDisconnect = false
	end

	AdvancedLayout.BeginSector("Valve Safety")
	AdvancedLayout.CreateCheckbox(
		"Auto Leave on Valve Join",
		JNMain,
		"ValveAutoDisconnect",
		"Disconnect automatically when a Valve employee enters the server"
	)
	AdvancedLayout.EndSector()
end

local function drawAdvancedTab()
	local Advanced = G.Menu.Advanced

	-- Create sectors in rows for better organization
	-- First row: Evidence System | Exploit Detection
	AdvancedLayout.CreateSectorRow({
		{
			title = "Evidence System",
			content = function()
				AdvancedLayout.CreateSlider(
					"Evidence Tolerance",
					Advanced,
					"Evicence_Tolerance",
					1,
					200,
					100,
					1,
					"Threshold for marking players as cheaters (higher = more strict)"
				)
			end,
		},
		{
			title = "Exploit Detection",
			content = function()
				AdvancedLayout.CreateCheckbox("Fake Lag Detection", Advanced, "Choke")
				AdvancedLayout.StandardizeSpacing()
				AdvancedLayout.CreateCheckbox("Warp/DT Detection", Advanced, "Warp")
				AdvancedLayout.StandardizeSpacing()
				AdvancedLayout.CreateCheckbox("Anti-Aim Detection", Advanced, "AntyAim")
			end,
		},
	})

	-- Second row: Movement Detection | Aim Detection
	AdvancedLayout.CreateSectorRow({
		{
			title = "Movement Detection",
			content = function()
				AdvancedLayout.CreateCheckbox("Bhop Detection", Advanced, "Bhop")
				AdvancedLayout.StandardizeSpacing()
				AdvancedLayout.CreateCheckbox("Duck Speed Detection", Advanced, "DuckSpeed")
				AdvancedLayout.StandardizeSpacing()
				AdvancedLayout.CreateCheckbox("Strafe Bot Detection", Advanced, "Strafe_bot")
			end,
		},
		{
			title = "Aim Detection",
			content = function()
				AdvancedLayout.CreateCheckbox("Enable Aimbot Detection", Advanced, "Aimbot.enable")
				if Advanced.Aimbot.enable then
					AdvancedLayout.StandardizeSpacing()

					-- Initialize aimbot options if needed
					if type(Advanced.Aimbot.silent) ~= "boolean" then
						Advanced.Aimbot.silent = true
					end
					if type(Advanced.Aimbot.plain) ~= "boolean" then
						Advanced.Aimbot.plain = true
					end
					if type(Advanced.Aimbot.smooth) ~= "boolean" then
						Advanced.Aimbot.smooth = true
					end

					local aimbotTypes = { "Silent Aim", "Plain Aim", "Smooth Aim" }
					AdvancedLayout.CreateMultiCombo("Aimbot Types", aimbotTypes, Advanced, "Aimbot")
				end
				AdvancedLayout.StandardizeSpacing()
				AdvancedLayout.CreateCheckbox("Triggerbot Detection", Advanced, "triggerbot")
			end,
		},
	})

	-- Third row: Logging | Debug
	AdvancedLayout.CreateSectorRow({
		{
			title = "Logging",
			content = function()
				local logLevels = { "Debug", "Info", "Warning", "Error" }
				AdvancedLayout.CreateCombo(
					"Log Level",
					logLevels,
					Advanced,
					"LogLevel",
					"Set console output verbosity (Debug = everything, Error = only critical)"
				)
			end,
		},
		{
			title = "Debug",
			content = function()
				if type(Advanced.debug) ~= "boolean" then
					Advanced.debug = false
				end
				AdvancedLayout.CreateCheckbox(
					"Debug Mode",
					Advanced,
					"debug",
					"Enables debug features (auto-removes self from database, verbose logging)"
				)
			end,
		},
	})
end

local function drawMiscTab()
	local Misc = G.Menu.Misc

	-- Auto Vote section (standalone - takes full width)
	AdvancedLayout.BeginSector("Auto Vote")
	AdvancedLayout.CreateCheckbox("Enable Auto Vote", Misc, "Autovote")
	if Misc.Autovote then
		AdvancedLayout.StandardizeSpacing()

		-- Initialize vote intent if needed
		if type(Misc.intent.legit) ~= "boolean" then
			Misc.intent.legit = true
		end
		if type(Misc.intent.cheater) ~= "boolean" then
			Misc.intent.cheater = true
		end
		if type(Misc.intent.bot) ~= "boolean" then
			Misc.intent.bot = true
		end
		if type(Misc.intent.friend) ~= "boolean" then
			Misc.intent.friend = false
		end

		local voteTargets = { "Legit Players", "Cheaters", "Bots", "Exclude Friends" }
		AdvancedLayout.CreateMultiCombo("Vote Targets", voteTargets, Misc, "intent")
	end
	AdvancedLayout.EndSector()

	-- Vote Reveal and Class Change in same row
	AdvancedLayout.CreateSectorRow({
		{
			title = "Vote Reveal",
			content = function()
				AdvancedLayout.CreateCheckbox("Enable Vote Reveal", Misc, "Vote_Reveal.Enable")
				if Misc.Vote_Reveal.Enable then
					AdvancedLayout.StandardizeSpacing()

					-- Initialize target teams if needed
					if type(Misc.Vote_Reveal.TargetTeam.MyTeam) ~= "boolean" then
						Misc.Vote_Reveal.TargetTeam.MyTeam = true
					end
					if type(Misc.Vote_Reveal.TargetTeam.enemyTeam) ~= "boolean" then
						Misc.Vote_Reveal.TargetTeam.enemyTeam = true
					end

					local teamOptions = { "My Team", "Enemy Team" }
					AdvancedLayout.CreateMultiCombo("Target Teams", teamOptions, Misc, "Vote_Reveal.TargetTeam")

					-- Output options
					AdvancedLayout.CreateOutputSection("Vote Output", Misc.Vote_Reveal, "")

					-- Maintain backwards compatibility
					Misc.Vote_Reveal.PartyChat = Misc.Vote_Reveal.Output.PartyChat
					Misc.Vote_Reveal.Console = Misc.Vote_Reveal.Output.Console
				end
			end,
		},
		{
			title = "Class Change Reveal",
			content = function()
				AdvancedLayout.CreateCheckbox("Enable Class Change Reveal", Misc, "Class_Change_Reveal.Enable")
				if Misc.Class_Change_Reveal.Enable then
					AdvancedLayout.StandardizeSpacing()

					-- Initialize enemy only setting if needed
					if type(Misc.Class_Change_Reveal.EnemyOnly) ~= "boolean" then
						Misc.Class_Change_Reveal.EnemyOnly = true
					end

					AdvancedLayout.CreateCheckbox("Enemy Team Only", Misc, "Class_Change_Reveal.EnemyOnly")

					-- Output options
					AdvancedLayout.CreateOutputSection("Class Change Output", Misc.Class_Change_Reveal, "")

					-- Maintain backwards compatibility
					Misc.Class_Change_Reveal.PartyChat = Misc.Class_Change_Reveal.Output.PartyChat
					Misc.Class_Change_Reveal.Console = Misc.Class_Change_Reveal.Output.Console
				end
			end,
		},
	})

	-- Join Notifications (standalone - complex section)
	AdvancedLayout.BeginSector("Join Notifications")

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

	AdvancedLayout.CreateCheckbox("Enable Join Notifications", JN, "Enable")
	if JN.Enable then
		AdvancedLayout.StandardizeSpacing()

		-- Target filters
		local notifTypes = { "Cheaters", "Valve" }
		AdvancedLayout.CreateMultiCombo("Notify For", notifTypes, JN, "Check")

		-- Default output channels
		AdvancedLayout.CreateOutputSection("Default Output", JN, "Default")

		-- Cheater override
		AdvancedLayout.CreateConditionalSection("Override Cheater Output", JN.UseCheaterOverride, function()
			AdvancedLayout.CreateOutputSection("Cheater Output", JN, "CheaterOverride")
		end, true)

		if JN.UseCheaterOverride then
			AdvancedLayout.StandardizeSpacing()
		end

		-- Valve override
		AdvancedLayout.CreateConditionalSection("Override Valve Employee Output", JN.UseValveOverride, function()
			AdvancedLayout.CreateOutputSection("Valve Output", JN, "ValveOverride")
		end)
	end

	AdvancedLayout.EndSector()
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "CD_MENU")
callbacks.Register("Draw", "CD_MENU", DrawMenu)

return Menu
