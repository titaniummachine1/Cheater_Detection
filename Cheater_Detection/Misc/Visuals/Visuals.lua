--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Database = require("Cheater_Detection.Database.Database")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")

local Visuals = {}

local Lib = Common.Lib
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

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

	draw.Color(255, 255, 255, 255)
	draw.SetFont(tahoma_bold)

	local players = FastPlayers.GetAll()
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

		-- Determine if we should show a tag
		local showTag = isCheater
		local tagText = isCheater and "CHEATER" or "SUSPICIOUS"
		local tagColor = isCheater and { 255, 0, 0, 255 } or { 255, 255, 0, 255 }

		if showTag then
			local padding = Vector3(0, 0, 7)
			local headPos = (entity:GetAbsOrigin() + entity:GetPropVector("localdata", "m_vecViewOffset[0]")) + padding
			headPos = (gui.GetValue("CLASS") == "icon" and gui.GetValue("AIM RESOLVER") == 0)
					and headPos + Vector3(0, 0, 17)
				or headPos
			local feetPos = entity:GetAbsOrigin() - padding
			local headScreenPos, feetScreenPos = client.WorldToScreen(headPos), client.WorldToScreen(feetPos)

			if headScreenPos and feetScreenPos then
				local height = math.abs(headScreenPos[2] - feetScreenPos[2])
				local width = height * 0.6
				local x, y = math.floor(headScreenPos[1] - width * 0.5), math.floor(headScreenPos[2])
				local w, h = math.floor(width), math.floor(height)

				draw.Color(table.unpack(tagColor))
				local tagWidth, tagHeight = draw.GetTextSize(tagText)
				y = (gui.GetValue("AIM RESOLVER") == 1) and y - 20 or y
				draw.Text(math.floor(x + w / 2 - (tagWidth / 2)), y - 30, tagText)
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
