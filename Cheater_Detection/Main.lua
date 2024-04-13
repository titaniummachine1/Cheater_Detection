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
local G = require("Cheater_Detection.Globals")
local Config = require("Cheater_Detection.Config")
local Detections = require("Cheater_Detection.Detections")
require("Cheater_Detection.Visuals") --wake up the visuals
local Menu = require("Cheater_Detection.Menu")--wake up the menu

--[[ Variables ]]
local TF2 = Common.Lib.TF2
local Math, Conversion = Common.Lib.Utils.Math, Common.Lib.Utils.Conversion
local WPlayer, WPR = TF2.WPlayer, TF2.WPlayerResource
local Helpers = Common.Lib.TF2.Helpers
local Disable = true

if pLocal then --debugging
    playerlist.SetPriority(pLocal, 0)
end

Config.LoadCFG() --load config on load of script
Config.LoadDatabase() --load database inicialy

--[[ Functions ]]
local function OnCreateMove(cmd)
    if input.IsButtonPressed(KEY_INSERT) then
        Menu.toggleMenu() --toggle the menu
    end

    -- update every tick
    local DebugMode = G.Menu.Main.debug
    G.pLocal = entities.GetLocalPlayer()
    G.players = entities.FindByClass("CTFPlayer")
    if not G.players then return end

    if Disable then return end --temporary disable

    G.WLocal = WPlayer.FromEntity(G.pLocal)
    G.latin, G.latout = clientstate.GetLatencyIn() * 1000, clientstate.GetLatencyOut() * 1000 -- Convert to ms
    G.connectionState = entities.GetPlayerResources():GetPropDataTableInt("m_iConnectionState")[G.WLocal:GetIndex()]

        for _, entity in ipairs(players) do
            -- Skip if entity is nil, dormant, dead, or a friend (in non-debug mode)
            if not entity or entity:IsDormant() or not entity:IsAlive() or (not DebugMode and TF2.IsFriend(entity:GetIndex(), true)) then
                goto continue
            end
    
            -- Get the steamid for the player after the entity check
            local steamid = Detections.GetSteamID(entity)
    
            -- If the record doesn't exist or doesn't have playerData, initialize it with defaultRecord
            if not G.PlayerData[steamid] then
                if steamid then
                    G.PlayerData[steamid] = defaultRecord -- Assuming defaultRecord structure
                else
                    Log:Warn("Failed to get SteamID for player %s", entity:GetName() or "nil")
                    goto continue
                end
            end

            -- Create a local reference to the record
            local Record = G.PlayerData[steamid]

            if not Record then
                Record = G.defaultRecord
            end

            --Skip if player is detected as a cheater
            if Config.IsKnownCheater(steamid) then
                --print(Record.Name .. " or ".. entity:GetName() .. " is detected as a cheater")
                goto continue
            end

            local player = WPlayer.FromEntity(entity)
            local ViewAngles = player:GetEyeAngles()

            -- Initialize the AngleHistory table if it doesn't exist
            Record.AngleHistory = Record.AngleHistory or {}

            -- Store the player's view angle history
            table.insert(Record.AngleHistory, ViewAngles)
            if #Record.AngleHistory > 6 then
                table.remove(Record.AngleHistory, 1)
            end

            -- Perform checks on the player
            Detections.CheckAngles(player, entity)
            Detections.CheckDuckSpeed(player, entity)
            Detections.CheckBunnyHop(player, entity)
            Detections.CheckChoke(player, entity)
    
            ::continue::
        end
end

--[[ Unregister previous callbacks ]]--
callbacks.Unregister("CreateMove", "Cheater_detection")                     -- unregister the "CreateMove" callback

--[[ Register callbacks ]]--
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)        -- register the "CreateMove" callback

--[[ Play sound when loaded ]]--
client.Command('play "ui/buttonclick"', true) -- Play the "buttonclick" sound when the script is loaded