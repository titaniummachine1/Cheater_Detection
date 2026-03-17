--[[ actions/visuals.lua
     Handles ESP-like tags for cheaters and suspicious players.
     Supports stacking up to 3 tags per player, filtered by user config.
]]

local Constants = require("Cheater_Detection.Core.constants")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local G = require("Cheater_Detection.Utils.Globals")

local Visuals = {}

local fontTag = draw.CreateFont("Tahoma", 12, 800, 0x200)
local LINE_HEIGHT = 14 -- Pixels between stacked tag lines

-- Safety: Polyfills for Lmaobox types if globals are missing
local _Vector3 = Vector3 or function(x, y, z)
	return { x = x, y = y, z = z }
end

local function WorldToScreen(pos)
	local screenPos = client.WorldToScreen(pos)
	if screenPos then
		return screenPos[1], screenPos[2]
	end
	return nil, nil
end

-- Build the ordered list of tags to show for this player
-- Returns: array of { text, r, g, b } up to MAX_TAGS entries
local MAX_TAGS = 3

local function buildTagList(flags, score)
	local cfg = G.Menu and G.Menu.Main and G.Menu.Main.TagFilters
	local tags = {}

	local isValve = (flags & Constants.Flags.VALVE) ~= 0
	local isCheater = (flags & Constants.Flags.CHEATER) ~= 0
	local isVac = (flags & Constants.Flags.VAC_BANNED) ~= 0
	local isSus = (flags & Constants.Flags.SUSPICIOUS) ~= 0 or (score >= Constants.Threshold.SUSPICIOUS)

	-- cfg is a boolean array: [1]=Valve, [2]=Cheater, [3]=VAC, [4]=Suspicious
	-- If nil/missing, default to showing all
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
	if isSus and showSus then
		local displayScore = math.min(99, math.floor(score))
		tags[#tags + 1] = { text = string.format("SUSPICIOUS (%d%%)", displayScore), r = 255, g = 255, b = 0 }
	end

	-- Clamp to MAX_TAGS
	while #tags > MAX_TAGS do
		tags[#tags] = nil
	end

	return tags
end

function Visuals.DrawTags()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	local tagsEnabled = G.Menu and G.Menu.Main and G.Menu.Main.Cheater_Tags
	if tagsEnabled == false then
		return
	end

	local stateTable = PlayerCache.GetActiveTable()
	for _, pState in pairs(stateTable) do
		local wrap = pState.wrap
		if not wrap then goto continue end
		local ent = wrap:GetRawEntity()

		if ent and ent:IsValid() and not ent:IsDormant() and ent:IsAlive() then
			local flags = pState.flags
			local score = pState.score

			local tagList = buildTagList(flags, score)
			if #tagList > 0 then
				-- DEBUG: Log when tags are being drawn for a player
				if G.Menu.Advanced.debug and ent == pLocal then
					-- print(string.format("[Visuals] Drawing %d tags for local player", #tagList))
				end

				-- Calculate head position for the tag stack
				local absOrigin = ent:GetAbsOrigin()
				-- Fallback view offset if m_vecViewOffset[0] is not found
				local viewOffset = ent:GetPropVector("localdata", "m_vecViewOffset[0]")
				local headPos = absOrigin + viewOffset + _Vector3(0, 0, 15)
				local x, y = WorldToScreen(headPos)

				if x and y then
					draw.SetFont(fontTag)
					-- Draw tags top-down, each offset upward from the previous
					local totalHeight = (#tagList - 1) * LINE_HEIGHT
					local startY = math.floor(y - totalHeight)

					for j = 1, #tagList do
						local tag = tagList[j]
						draw.Color(tag.r, tag.g, tag.b, 255)
						local tw, th = draw.GetTextSize(tag.text)
						draw.Text(math.floor(x - tw / 2), startY - th + (j - 1) * LINE_HEIGHT, tag.text)
					end
				end
			end
		end
		::continue::
	end
end

return Visuals
