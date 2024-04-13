--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local G = require("Cheater_Detection.Globals")
local Config = require("Cheater_Detection.Config")

local Visuals = {}

local Log = Common.Log
local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)
local Disable = true

--[[ Functions ]]

local function DrawVisuals()
        if (not engine.Con_IsVisible() and not engine.IsGameUIVisible()) then

            draw.Color(255, 255, 255, 255)
            draw.SetFont(tahoma_bold)

            if Disable then return end --temporary disable for visuals

            if RuntimeData then
                for steamId, data in pairs(RuntimeData) do
                    local entity = data.EntityData.entity
                    local strikes = data.strikes
                    local detected = data.isCheater

                    if not entity or not entity:IsValid() or entity:IsDormant() or not entity:IsAlive() then goto continue end
                    if strikes >= math.floor(G.Menu.StrikeLimit / 2) then
                        local tagText, tagColor
                        local padding = Vector3(0, 0, 7)
                        local headPos = (entity:GetAbsOrigin() + entity:GetPropVector("localdata", "m_vecViewOffset[0]")) + padding
                        if gui.GetValue("CLASS") == "icon" and gui.GetValue("AIM RESOLVER") == 0 then
                            headPos = headPos + Vector3(0, 0, 17)
                        end
                        local feetPos = entity:GetAbsOrigin() - padding
                        local headScreenPos = client.WorldToScreen(headPos)
                        local feetScreenPos = client.WorldToScreen(feetPos)
                        if headScreenPos ~= nil and feetScreenPos ~= nil then
                            local height = math.abs(headScreenPos[2] - feetScreenPos[2])
                            local width = height * 0.6
                            local x = math.floor(headScreenPos[1] - width * 0.5)
                            local y = math.floor(headScreenPos[2])
                            local w = math.floor(width)
                            local h = math.floor(height)
                            if detected then
                                tagText = "CHEATER"
                                tagColor = {255,0,0,255}
                            else
                                tagText = "SUSPICIOUS"
                                tagColor = {255,255,0,255}
                            end
                            draw.Color(table.unpack(tagColor))
                            local tagWidth, tagHeight = draw.GetTextSize(tagText)
                            if gui.GetValue("AIM RESOLVER") == 1 then --fix bug when arrow of resolver clips with tag
                                y = y - 20
                            end
                            draw.Text(math.floor(x + w / 2 - (tagWidth / 2)), y - 30, tagText)
                        end
                    end
                    ::continue::
                end
            end
        end
    end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw")                                   -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", DrawVisuals)                              -- Register the "Draw" callback 

return Visuals