--[[
    Cheater Detection for Lmaobox Recode
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credits:
    LNX (github.com/lnx00) for base script
    Muqa for visuals and design assistance
    Alchemist for testing and party callout
]]

--[[ actiave the script Modules]]
local Common = require("Cheater_Detection.Common")
local Config = require("Cheater_Detection.Config")
local Visuals = require("Cheater_Detection.Visuals")
--local Detections = require("Cheater_Detection.Detections")

--[[ Variables ]]

if pLocal then --debugging
    playerlist.SetPriority(pLocal, 0)
end

--[[ Functions ]]
local function OnCreateMove(cmd)
    if input.IsButtonPressed(KEY_INSERT) then
        Visuals.toggleMenu() --toggle the menu
    end
end

--[[ Unregister previous callbacks ]]--
callbacks.Unregister("CreateMove", "Cheater_detection")                     -- unregister the "CreateMove" callback

--[[ Register callbacks ]]--
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)        -- register the "CreateMove" callback

--[[ Play sound when loaded ]]--
client.Command('play "ui/buttonclick"', true) -- Play the "buttonclick" sound when the script is loaded
