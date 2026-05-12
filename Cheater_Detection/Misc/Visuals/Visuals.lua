--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Database = require("Cheater_Detection.Database.Database")
local TickProfiler = require("Cheater_Detection.Utils.TickProfiler")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local DirtySystem = require("Cheater_Detection.Core.DirtySystem")
local PlayerData = require("Cheater_Detection.Utils.PlayerData")

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

-- Cached tagged players - updated when dirty flags trigger
local taggedPlayersCache = {}
local cacheValid = false

-- Update cache for dirty players only
local function UpdateTaggedCache()
	-- Get players with dirty SCORE or FLAGS
	local dirtyPlayers = DirtySystem.GetDirtyPlayers(DirtySystem.FLAGS.SCORE | DirtySystem.FLAGS.FLAGS)
	
	if #dirtyPlayers == 0 and cacheValid then
		return -- No changes, use existing cache
	end
	
	-- Clear removed players from cache
	for id, _ in pairs(taggedPlayersCache) do
		if not PlayerCache.GetByID(id) then
			taggedPlayersCache[id] = nil
		end
	end
	
	-- Update only dirty players
	for _, id in ipairs(dirtyPlayers) do
		local state = PlayerCache.GetByID(id)
		if not state then
			taggedPlayersCache[id] = nil
		else
			local isCheater = Evidence.IsMarkedCheater(id)
			local evidenceScore = Evidence.GetScore(id)
			local threshold = G.Menu and G.Menu.Advanced and G.Menu.Advanced.Evidence_Tolerance or 100
			local halfThreshold = math.floor(threshold / 2)
			local isSuspicious = evidenceScore and evidenceScore >= halfThreshold
			
			if isCheater or isSuspicious then
				taggedPlayersCache[id] = {
					tagText = isCheater and "CHEATER" or "SUSPICIOUS",
					tr = isCheater and 255 or 255,
					tg = isCheater and 0 or 255,
					tb = isCheater and 0 or 0,
					ta = 255,
					isCheater = isCheater
				}
			else
				taggedPlayersCache[id] = nil
			end
		end
		
		-- Clear the dirty flags we processed
		DirtySystem.ClearDirty(id, DirtySystem.FLAGS.SCORE | DirtySystem.FLAGS.FLAGS)
	end
	
	cacheValid = true
end

--[[ Functions ]]
local function DrawVisuals()
	TickProfiler.BeginSection("Draw_Visuals")

	-- Check if feature is enabled
	if not G.Menu or not G.Menu.Main or not G.Menu.Main.Cheater_Tags then
		TickProfiler.EndSection("Draw_Visuals")
		return
	end

	local conVisible = engine.Con_IsVisible()
	local gameUIVisible = engine.IsGameUIVisible()
	if conVisible or gameUIVisible then
		TickProfiler.EndSection("Draw_Visuals")
		return
	end

	DRAW_COLOR(255, 255, 255, 255)
	DRAW_SETFONT(tahoma_bold)

	-- Update cache for dirty players only (O(changed) not O(all))
	UpdateTaggedCache()

	-- Render only cached tagged players
	for id, tagData in pairs(taggedPlayersCache) do
		-- Get entity safely via PlayerData
		local state = PlayerCache.GetByID(id)
		if not state or not state.pdata then
			goto continue
		end
		
		local ent = PlayerData.GetEntity(state.pdata)
		if not ent or not ent:IsValid() or not ent:IsAlive() or ent:IsDormant() then
			goto continue
		end

		local headPos = ent:GetEyePos()
		if not headPos then
			goto continue
		end
		headPos = headPos + PAD7
		headPos = (gui.GetValue("CLASS") == "icon" and gui.GetValue("AIM RESOLVER") == 0)
				and headPos + PAD17
			or headPos
		local feetPos = ent:GetAbsOrigin() - PAD7
		local headScreenPos, feetScreenPos = WORLD2SCREEN(headPos), WORLD2SCREEN(feetPos)

		if headScreenPos and feetScreenPos then
			local height = ABS(headScreenPos[2] - feetScreenPos[2])
			local width = height * 0.6
			local x = FLOOR(headScreenPos[1] - width * 0.5)
			local y = FLOOR(headScreenPos[2])
			local w = FLOOR(width)

			DRAW_COLOR(tagData.tr, tagData.tg, tagData.tb, tagData.ta)
			local tagWidth = DRAW_GETTEXTSIZE(tagData.tagText)
			y = (gui.GetValue("AIM RESOLVER") == 1) and y - 20 or y
			DRAW_TEXT(FLOOR(x + w / 2 - (tagWidth / 2)), y - 30, tagData.tagText)
		end

		::continue::
	end

	TickProfiler.EndSection("Draw_Visuals")
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", DrawVisuals) -- Register the "Draw" callback

return Visuals
