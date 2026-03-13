--[[ actions/visuals.lua
     Handles ESP-like tags for cheaters and suspicious players.
]]

local Constants = require("Cheater_Detection.core.constants")
local PlayerCache = require("Cheater_Detection.core.player_cache")

local Visuals = {}

local fontTag = draw.CreateFont("Tahoma", 12, 800, 0x200) -- Using 0x200 directly for Outline

-- Safety: Polyfills for Lmaobox types if globals are missing
local _Vector3 = Vector3 or function(x, y, z) return {x=x, y=y, z=z} end

local function WorldToScreen(pos)
	local screenPos = client.WorldToScreen(pos)
	if screenPos then
		return screenPos[1], screenPos[2]
	end
	return nil, nil
end

function Visuals.DrawTags()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	local players = PlayerCache.GetAll()
	for i = 1, #players do
		local pState = players[i]
		local ent = pState.wrap:GetRawEntity()

		if ent and ent:IsValid() and not ent:IsDormant() and ent:IsAlive() then
			local flags = pState.flags
			local score = pState.score
			
			local isValve = (flags & Constants.Flags.VALVE) ~= 0
			local isCheater = (flags & Constants.Flags.CHEATER) ~= 0
			local isSus = (flags & Constants.Flags.SUSPICIOUS) ~= 0 or (score >= Constants.Threshold.SUSPICIOUS)

			if isValve or isCheater or isSus then
				-- Calculate head position for the tag
				local absOrigin = ent:GetAbsOrigin()
				local viewOffset = ent:GetPropVector("localdata", "m_vecViewOffset[0]")
				local headPos = absOrigin + viewOffset + _Vector3(0, 0, 15)
				local x, y = WorldToScreen(headPos)

				if x and y then
					draw.SetFont(fontTag)
					
					if isValve then
						draw.Color(255, 215, 0, 255) -- Gold
						local text = "VALVE EMPLOYEE"
						local tw, th = draw.GetTextSize(text)
						draw.Text(math.floor(x - tw/2), math.floor(y - th), text)
					elseif isCheater then
						draw.Color(255, 0, 0, 255)
						local text = "CHEATER"
						local tw, th = draw.GetTextSize(text)
						draw.Text(math.floor(x - tw/2), math.floor(y - th), text)
					elseif isSus then
						draw.Color(255, 255, 0, 255)
						-- Show % capped to 99
						local displayScore = math.min(99, math.floor(score))
						local text = string.format("SUSPICIOUS (%d%%)", displayScore)
						local tw, th = draw.GetTextSize(text)
						draw.Text(math.floor(x - tw/2), math.floor(y - th), text)
					end
				end
			end
		end
	end
end

return Visuals
