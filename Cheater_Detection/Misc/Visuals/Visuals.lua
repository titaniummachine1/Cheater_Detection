--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Database = require("Cheater_Detection.Database.Database")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")
local PlayerCache = require("Cheater_Detection.Core.player_cache")

local Visuals = {}

local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)
local Vec3 = Vector3
local FLOOR = math.floor
local ABS = math.abs
local WORLD2SCREEN = client.WorldToScreen
local DRAW_COLOR = draw.Color
local DRAW_SETFONT = draw.SetFont
local DRAW_GETTEXTSIZE = draw.GetTextSize
local DRAW_TEXT = draw.Text

local PAD7 = Vec3(0, 0, 7)
local PAD17 = Vec3(0, 0, 17)

--[[ Functions ]]
local function DrawVisuals()
	TickProfiler.BeginSection("Draw_Visuals")

	-- Check if feature is enabled
	if not G.Menu or not G.Menu.Main or not G.Menu.Main.Cheater_Tags then
		TickProfiler.EndSection("Draw_Visuals")
		return
	end

	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		TickProfiler.EndSection("Draw_Visuals")
		return
	end

	DRAW_COLOR(255, 255, 255, 255)
	DRAW_SETFONT(tahoma_bold)

	local players = PlayerCache.GetAll()
	for _, entity in ipairs(players) do
		local valid = entity and entity:IsValid() and not entity:IsDormant() and entity:IsAlive()
		if not valid then
			goto continue
		end

		local steamId = Common.GetSteamID64(entity)
		if not steamId then
			goto continue
		end

		-- Check if player is marked as cheater (Evidence system checks DB + Runtime)
		local isCheater = Evidence.IsMarkedCheater(steamId)

		-- Check if player has suspicious evidence (at half threshold)
		local evidenceScore = Evidence.GetScore(steamId)
		local threshold = G.Menu and G.Menu.Advanced and G.Menu.Advanced.Evidence_Tolerance or 100
		local isSuspicious = evidenceScore and evidenceScore >= math.floor(threshold / 2)

		-- Determine if we should show a tag and what type
		local showTag = isCheater or isSuspicious
		local tagText = nil
		local tr = 255
		local tg = 255
		local tb = 255
		local ta = 255
		if isCheater then
			tagText = "CHEATER"
			tr = 255
			tg = 0
			tb = 0
		elseif isSuspicious then
			tagText = "SUSPICIOUS"
			tr = 255
			tg = 255
			tb = 0
		else
			goto continue
		end

		if showTag then
			local headPos = entity:GetEyePos()
			if not headPos then
				goto continue
			end
			headPos = headPos + PAD7
			headPos = (gui.GetValue("CLASS") == "icon" and gui.GetValue("AIM RESOLVER") == 0)
					and headPos + PAD17
				or headPos
			local feetPos = entity:GetAbsOrigin() - PAD7
			local headScreenPos, feetScreenPos = WORLD2SCREEN(headPos), WORLD2SCREEN(feetPos)

			if headScreenPos and feetScreenPos then
				local height = ABS(headScreenPos[2] - feetScreenPos[2])
				local width = height * 0.6
				local x = FLOOR(headScreenPos[1] - width * 0.5)
				local y = FLOOR(headScreenPos[2])
				local w = FLOOR(width)

				DRAW_COLOR(tr, tg, tb, ta)
				local tagWidth = DRAW_GETTEXTSIZE(tagText)
				y = (gui.GetValue("AIM RESOLVER") == 1) and y - 20 or y
				DRAW_TEXT(FLOOR(x + w / 2 - (tagWidth / 2)), y - 30, tagText)
			end
		end

		::continue::
	end

	TickProfiler.EndSection("Draw_Visuals")
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", DrawVisuals) -- Register the "Draw" callback

return Visuals
