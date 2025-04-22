local Menu = {}

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")

local Lib = Common.Lib
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

local ImMenu = require("Cheater_Detection.Libs.ImMenu")

-- Helper function for rounding coordinates
local function roundCoord(value)
	return math.floor(value + 0.5)
end

local function DrawMenu()
	ImMenu.BeginFrame(1)

	if G.Menu.Advanced.debug then
		draw.Color(255, 0, 0, 255)
		draw.SetFont(Fonts.Verdana)
		draw.Text(roundCoord(20), roundCoord(120), "Debug Mode!!! Some Features Might malfunction")
	end

	if gui.IsMenuOpen() and ImMenu.Begin("Cheater Detection", true) then
		-- Tabs for different sections
		ImMenu.BeginFrame(1)
			local tabs = { "Main", "Advanced", "Misc"}
			G.Menu.currentTab = ImMenu.TabControl(tabs, G.Menu.currentTab)
		ImMenu.EndFrame()

		draw.SetFont(Fonts.Verdana)
		draw.Color(255, 255, 255, 255)

		-- Main Configuration Tab
		if G.Menu.currentTab == "Main" then
			local Main = G.Menu.Main

			ImMenu.BeginFrame()
			Main.AutoMark = ImMenu.Checkbox("Auto Mark", Main.AutoMark)
			Main.partyCallaut = ImMenu.Checkbox("Party Callout", Main.partyCallaut)
			Main.Chat_Prefix = ImMenu.Checkbox("Chat Prefix", Main.Chat_Prefix)
			Main.Cheater_Tags = ImMenu.Checkbox("Cheater Tags", Main.Cheater_Tags)
			Main.JoinWarning = ImMenu.Checkbox("Join Warning", Main.JoinWarning)
			ImMenu.EndFrame()
		end

		-- Advanced Configuration Tab
		if G.Menu.currentTab == "Advanced" then
			local Advanced = G.Menu.Advanced

			ImMenu.BeginFrame()
			Advanced.Evicence_Tolerance = ImMenu.Slider("Evidence Tolerance", Advanced.Evicence_Tolerance, 1, 10)
			ImMenu.EndFrame()

			ImMenu.BeginFrame()
			Advanced.Choke = ImMenu.Checkbox("Choke Detection", Advanced.Choke)
			Advanced.Warp = ImMenu.Checkbox("Warp Detection", Advanced.Warp)
			Advanced.Bhop = ImMenu.Checkbox("Bhop Detection", Advanced.Bhop)
			ImMenu.EndFrame()

			ImMenu.BeginFrame()
			Advanced.Aimbot.enable = ImMenu.Checkbox("Aimbot Detection", Advanced.Aimbot.enable)
			if Advanced.Aimbot.enable then
				Advanced.Aimbot.silent = ImMenu.Checkbox("Silent Aim", Advanced.Aimbot.silent)
				Advanced.Aimbot.plain = ImMenu.Checkbox("Plain Aim", Advanced.Aimbot.plain)
				Advanced.Aimbot.smooth = ImMenu.Checkbox("Smooth Aim", Advanced.Aimbot.smooth)
			end
			ImMenu.EndFrame()

			ImMenu.BeginFrame()
			Advanced.triggerbot = ImMenu.Checkbox("Triggerbot Detection", Advanced.triggerbot)
			Advanced.AntyAim = ImMenu.Checkbox("Anty-Aim Detection", Advanced.AntyAim)
			Advanced.DuckSpeed = ImMenu.Checkbox("Duck Speed Detection", Advanced.DuckSpeed)
			Advanced.Strafe_bot = ImMenu.Checkbox("Strafe Bot Detection", Advanced.Strafe_bot)
			ImMenu.EndFrame()

			ImMenu.BeginFrame()
			Advanced.debug = ImMenu.Checkbox("Debug Mode", Advanced.debug)
			ImMenu.EndFrame()
		end

		-- Misc Configuration Tab
		if G.Menu.currentTab == "Misc" then
			local Misc = G.Menu.Misc

			ImMenu.BeginFrame(1)
			Misc.Autovote = ImMenu.Checkbox("Enable Auto Vote", Misc.Autovote)
			ImMenu.EndFrame()

			if Misc.Autovote then
				ImMenu.BeginFrame(1)
				Misc.intent.legit = ImMenu.Checkbox("Vote Legit Players", Misc.intent.legit)
				Misc.intent.cheater = ImMenu.Checkbox("Vote Cheaters", Misc.intent.cheater)
				Misc.intent.bot = ImMenu.Checkbox("Vote Bots", Misc.intent.bot)
				Misc.intent.friend = ImMenu.Checkbox("Exclude Friends", Misc.intent.friend)
				ImMenu.EndFrame()
			end

			ImMenu.BeginFrame(1)
			Misc.Vote_Reveal.Enable = ImMenu.Checkbox("Vote Reveal", Misc.Vote_Reveal.Enable)
			ImMenu.EndFrame()

			if Misc.Vote_Reveal.Enable then
				ImMenu.BeginFrame(1)
				Misc.Vote_Reveal.TargetTeam.MyTeam = ImMenu.Checkbox("My Team", Misc.Vote_Reveal.TargetTeam.MyTeam)
				Misc.Vote_Reveal.TargetTeam.enemyTeam =
					ImMenu.Checkbox("Enemy Team", Misc.Vote_Reveal.TargetTeam.enemyTeam)
				ImMenu.EndFrame()

				ImMenu.BeginFrame(1)
				Misc.Vote_Reveal.PartyChat = ImMenu.Checkbox("Party Chat", Misc.Vote_Reveal.PartyChat)
				Misc.Vote_Reveal.Console = ImMenu.Checkbox("Console Log", Misc.Vote_Reveal.Console)
				ImMenu.EndFrame()
			end

			-- Class Change Reveal moved to Misc as defined in Default_Config
			ImMenu.BeginFrame(1)
			Misc.Class_Change_Reveal.Enable = ImMenu.Checkbox("Class Change Reveal", Misc.Class_Change_Reveal.Enable)
			ImMenu.EndFrame()
			if Misc.Class_Change_Reveal.Enable then
				ImMenu.BeginFrame(1)
				Misc.Class_Change_Reveal.EnemyOnly = ImMenu.Checkbox("Enemy Only", Misc.Class_Change_Reveal.EnemyOnly)
				Misc.Class_Change_Reveal.PartyChat = ImMenu.Checkbox("Party Chat", Misc.Class_Change_Reveal.PartyChat)
				Misc.Class_Change_Reveal.Console = ImMenu.Checkbox("Console Log", Misc.Class_Change_Reveal.Console)
				ImMenu.EndFrame()
			end

			ImMenu.BeginFrame(1)
			Misc.Chat_notify = ImMenu.Checkbox("Chat Notifications", Misc.Chat_notify)
			ImMenu.EndFrame()
		end

		ImMenu.End()
	end
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "CD_MENU")
callbacks.Register("Draw", "CD_MENU", DrawMenu)

return Menu
