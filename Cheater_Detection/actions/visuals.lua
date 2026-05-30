--[[ actions/visuals.lua
     Handles ESP-like tags for cheaters and suspicious players.
     World tags: client.WorldToScreen + draw.TextShadow (see lmaobox docs).
     Local self-test: HUD overlay (first-person cannot place text over your own head).
]]

local Constants = require("Cheater_Detection.Core.constants")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")

local Visuals = {}

local fontTag = draw.CreateFont("Tahoma", 12, 800, 0x200)
local fontHud = draw.CreateFont("Tahoma", 14, 800, 0x200)
local LINE_HEIGHT = 14
local Vec3 = Vector3
local FLOOR = math.floor
local WORLD_TO_SCREEN = client.WorldToScreen
local DRAW_COLOR = draw.Color
local DRAW_SETFONT = draw.SetFont
local DRAW_GETTEXTSIZE = draw.GetTextSize
local DRAW_TEXTSHADOW = draw.TextShadow
local DRAW_FILLEDRECT = draw.FilledRect

local MAX_TAGS = 3

local function buildTagList(flags, score)
	local cfg = G.Menu and G.Menu.Main and G.Menu.Main.TagFilters
	local tags = {}

	local isValve = (flags & Constants.Flags.VALVE) ~= 0
	local isCheater = (flags & Constants.Flags.CHEATER) ~= 0
	local isVac = (flags & Constants.Flags.VAC_BANNED) ~= 0
	local isSus = (flags & Constants.Flags.SUSPICIOUS) ~= 0 or (score >= Constants.Threshold.SUSPICIOUS)

	local showValve = not cfg or cfg[1] ~= false
	local showCheater = not cfg or cfg[2] ~= false
	local showVac = not cfg or cfg[3] ~= false
	local showSus = not cfg or cfg[4] ~= false

	if isValve and showValve then
		tags[#tags + 1] = { text = "VALVE EMPLOYEE", r = 255, g = 215, b = 0 }
	end
	if isCheater and showCheater then
		tags[#tags + 1] = { text = "CHEATER", r = 255, g = 50, b = 50 }
	end
	if isVac and showVac then
		tags[#tags + 1] = { text = "VAC BANNED", r = 255, g = 120, b = 0 }
	end
	if isSus and showSus and not isCheater then
		local displayScore = math.min(99, math.floor(score))
		tags[#tags + 1] = { text = string.format("SUSPICIOUS (%d%%)", displayScore), r = 255, g = 255, b = 0 }
	elseif isSus and showSus and isCheater then
		tags[#tags + 1] = { text = string.format("SUSPICIOUS (%d%%)", math.min(99, math.floor(score))), r = 255, g = 255, b = 0 }
	end

	while #tags > MAX_TAGS do
		tags[#tags] = nil
	end

	return tags
end

-- Anchor above head (lnxLib-style: eye offset + padding), then WorldToScreen.
local function getTagScreenPosition(wrap)
	local ent = wrap and wrap.GetEntity and wrap:GetEntity()
	if not ent or not ent.IsValid or not ent:IsValid() then
		return nil
	end

	local origin = ent:GetAbsOrigin()
	if not origin then
		return nil
	end

	local anchor = origin + Vec3(0, 0, 75)
	local viewOff = ent:GetPropVector("localdata", "m_vecViewOffset[0]")
	if viewOff then
		anchor = origin + viewOff + Vec3(0, 0, 18)
	end

	local screenPos = WORLD_TO_SCREEN(anchor)
	if not screenPos then
		return nil
	end

	local x, y = screenPos[1], screenPos[2]
	if not x or not y then
		return nil
	end

	local screenW, screenH = draw.GetScreenSize()
	if not screenW or not screenH then
		return x, y
	end
	if x < -64 or y < -64 or x > screenW + 64 or y > screenH + 64 then
		return nil
	end

	return x, y
end

local function drawWorldTagStack(tagList, centerX, topY)
	DRAW_SETFONT(fontTag)
	local totalHeight = (#tagList - 1) * LINE_HEIGHT
	local startY = FLOOR(topY - totalHeight)

	for j = 1, #tagList do
		local tag = tagList[j]
		DRAW_COLOR(tag.r, tag.g, tag.b, 255)
		local tw, th = DRAW_GETTEXTSIZE(tag.text)
		local tx = FLOOR(centerX - tw * 0.5)
		local ty = startY - th + (j - 1) * LINE_HEIGHT
		DRAW_TEXTSHADOW(tx, ty, tag.text)
	end
end

-- Local player: HUD at top-center (works in first person; debug self-test).
local function drawLocalPlayerHud(tagList, reason)
	local screenW, screenH = draw.GetScreenSize()
	if not screenW or screenW <= 0 then
		return
	end

	DRAW_SETFONT(fontHud)

	local maxW = 0
	local totalH = 0
	if Common.IsDebugEnabled() then
		local tw, th = DRAW_GETTEXTSIZE("=== CD SELF-TEST (Debug Mode) ===")
		if tw > maxW then maxW = tw end
		totalH = totalH + th + 4
	end
	for j = 1, #tagList do
		local tw, th = DRAW_GETTEXTSIZE(tagList[j].text)
		if tw > maxW then maxW = tw end
		totalH = totalH + th + 4
	end
	if reason and reason ~= "" then
		local tw, th = DRAW_GETTEXTSIZE(reason)
		if tw > maxW then maxW = tw end
		totalH = totalH + th + 4
	end

	local pad = 8
	local boxW = maxW + pad * 2
	local boxH = totalH + pad * 2
	local boxX = FLOOR(screenW * 0.5 - boxW * 0.5)
	local boxY = 72

	DRAW_COLOR(0, 0, 0, 160)
	DRAW_FILLEDRECT(boxX, boxY, boxX + boxW, boxY + boxH)

	local textY = boxY + pad
	if Common.IsDebugEnabled() then
		local header = "=== CD SELF-TEST (Debug Mode) ==="
		DRAW_COLOR(255, 200, 80, 255)
		local tw, th = DRAW_GETTEXTSIZE(header)
		DRAW_TEXTSHADOW(FLOOR(screenW * 0.5 - tw * 0.5), textY, header)
		textY = textY + th + 4
	end

	for j = 1, #tagList do
		local tag = tagList[j]
		DRAW_COLOR(tag.r, tag.g, tag.b, 255)
		local tw, th = DRAW_GETTEXTSIZE(tag.text)
		DRAW_TEXTSHADOW(FLOOR(screenW * 0.5 - tw * 0.5), textY, tag.text)
		textY = textY + th + 4
	end

	if reason and reason ~= "" then
		DRAW_COLOR(200, 200, 200, 255)
		local tw, th = DRAW_GETTEXTSIZE(reason)
		DRAW_TEXTSHADOW(FLOOR(screenW * 0.5 - tw * 0.5), textY, reason)
	end
end

function Visuals.DrawTags()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsValid() then
		return
	end
	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	local tagsEnabled = G.Menu and G.Menu.Main and G.Menu.Main.Cheater_Tags
	if tagsEnabled == false then
		return
	end

	local localID = PlayerCache.GetLocalID()
	local stateTable = PlayerCache.GetActiveTable()

	for _, pState in pairs(stateTable) do
		local wrap = pState.wrap
		if not wrap or not wrap.IsValid or not wrap:IsValid() then
			goto continue
		end
		if wrap:IsDormant() or not wrap:IsAlive() then
			goto continue
		end

		local flags = pState.flags or 0
		local score = pState.score or 0
		local tagList = buildTagList(flags, score)
		if #tagList == 0 then
			goto continue
		end

		local isLocal = localID and pState.id == localID
		if isLocal then
			drawLocalPlayerHud(tagList, pState.detectionReason)
		end

		local x, y = getTagScreenPosition(wrap)
		if x and y then
			drawWorldTagStack(tagList, x, y)
		end

		::continue::
	end
end

return Visuals
