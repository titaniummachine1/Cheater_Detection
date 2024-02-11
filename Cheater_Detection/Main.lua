--[[
    Cheater Detection for Lmaobox Recode
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credits:
    LNX (github.com/lnx00) for base script
    Muqa for visuals and design assistance
    Alchemist for testing and party callout
]]

--[[ Annotations ]]
---@alias PlayerData { Angle: EulerAngles[], Position: Vector3[], SimTime: number[] }


--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local Config = require("Cheater_Detection.Config")
local Visuals = require("Cheater_Detection.Visuals")
local Detections = require("Cheater_Detection.Detections")

local Lib = Common.Lib

local TF2 = Lib.TF2
local Math, Conversion = Lib.Utils.Math, Lib.Utils.Conversion
local WPlayer, WPR = TF2.WPlayer, TF2.WPlayerResource
local Helpers = Lib.TF2.Helpers

-- Unload package for debugging
Lib.Utils.UnloadPackages("Cheater_Detection")

local Notify, FS, Fonts, Commands, Timer = Lib.UI.Notify, Lib.Utils.FileSystem, Lib.UI.Fonts, Lib.Utils.Commands, Lib.Utils.Timer
local Log = Lib.Utils.Logger.new("Cheater_Detection")
Log.Level = 0

--[[ Variables ]]
local latin, latout = 0, 0
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)
local pLocal = entities.GetLocalPlayer()
local WLocal = WPlayer.FromEntity(pLocal)
local connectionState = 0
local players = entities.FindByClass("CTFPlayer")

local packetloss = false

if pLocal then --debugging
    playerlist.SetPriority(pLocal, 0)
end

--[[ Config ]]
local Menu = {}
local DataBase = Config.LoadDatabase()

--[[ Functions ]]
local function OnCreateMove(cmd)
    -- Inside your OnCreateMove or similar function where you check for input
    if input.IsButtonPressed(KEY_INSERT) then  -- Replace 72 with the actual key code for the button you want to use
        Visuals.toggleMenu() --toggle the menu
    end

    Menu, DataBase, players, pLocal, WLocal, latin, latout, connectionState, packetloss = Detections.UpdateData()
end

--[[ Callbacks ]]
local function OnUnload() -- Called when the script is unloaded
    if DataBase then
        -- Check all suspects and erase those without strikes
        for steamId, record in pairs(Config.GetDatabase()) do
            print(record.isCheater)
            if record and record.strikes < 1 then
                Config.ClearSuspect(steamId)
            else
                DataBase[steamId].EntityData = nil -- Sclear entitydata
            end
        end

        if Menu.Main.debug and pLocal then
            Config.ClearSuspect(Detections.GetSteamID(pLocal)) -- Clear the local if debug is enabled
        end
            Config.SaveDatabase(DataBase) -- Save the database
    else
        Config.SaveDatabase()
    end
    if Menu then
        Config.CreateCFG(Menu) -- Save the configurations
    else
        Config.CreateCFG() -- Save the configurations
    end
    UnloadLib() --unloading lualib
    client.Command('play "ui/buttonclickrelease"', true) -- Play the "buttonclickrelease" sound
end

--[[ Unregister previous callbacks ]]--
callbacks.Unregister("CreateMove", "Cheater_detection")                     -- unregister the "CreateMove" callback
callbacks.Unregister("Unload", "CD_Unload")                                -- unregister the "Unload" callback

--[[ Register callbacks ]]--
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)        -- register the "CreateMove" callback
callbacks.Register("Unload", "CD_Unload", OnUnload)                         -- Register the "Unload" callback

--[[ Play sound when loaded ]]--
client.Command('play "ui/buttonclick"', true) -- Play the "buttonclick" sound when the script is loaded