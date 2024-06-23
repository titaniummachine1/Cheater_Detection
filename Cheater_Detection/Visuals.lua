--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local G = require("Cheater_Detection.Globals")

local Visuals = {}

local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)
local Disable = false

--[[ Functions ]]
local function DrawVisuals()
    if not (engine.Con_IsVisible() or engine.IsGameUIVisible() or Disable) then
        draw.Color(255, 255, 255, 255)
        draw.SetFont(tahoma_bold)

        for _, entity in ipairs(G.players) do
            local valid = entity and entity:IsValid() and not entity:IsDormant() and entity:IsAlive()
            local steamId = valid and Common.GetSteamID64(entity) or nil

            local strikes = steamId and G.PlayerData[steamId] and G.PlayerData[steamId].info.Strikes or 0
            local isCheater = steamId and (strikes >= G.Menu.Main.StrikeLimit or Common.IsCheater(steamId)) or false
            local detected = isCheater or (G.PlayerData[steamId] and G.PlayerData[steamId].info.IsCheater) or false

            local showTag = valid and (strikes >= G.Menu.Main.StrikeLimit / 2)
            local tagText = detected and "CHEATER" or "SUSPICIOUS"
            local tagColor = detected and {255, 0, 0, 255} or {255, 255, 0, 255}

            if showTag then
                local padding = Vector3(0, 0, 7)
                local headPos = (entity:GetAbsOrigin() + entity:GetPropVector("localdata", "m_vecViewOffset[0]")) + padding
                headPos = (gui.GetValue("CLASS") == "icon" and gui.GetValue("AIM RESOLVER") == 0) and headPos + Vector3(0, 0, 17) or headPos
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
        end
    end
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", DrawVisuals) -- Register the "Draw" callback 

return Visuals