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
require("Cheater_Detection.Modules.EventHandler") --wake up the visuals
local Menu = require("Cheater_Detection.Menu")--wake up the menu

--[[ Variables ]]
local TF2 = Common.TF2
local Math, Conversion = Common.Math, Common.Conversion
local WPlayer, PR = TF2.WPlayer, TF2.PlayerResource
local Helpers = Common.Helpers
local Disable = false

playerlist.SetPriority(G.pLocal, 0)


Config.LoadCFG() --load config on load of script
Config.LoadDatabase() --load database inicialy
Config.importDatabase() --import the database if needed

--[[ Update the player data every tick ]]--
local function OnCreateMove(cmd)
    Menu.HandleMenuShow() --to ensure it doesnt get skipped dues to lag in fps

    local DebugMode = G.Menu.Main.debug
    G.pLocal = entities.GetLocalPlayer()
    G.players = entities.FindByClass("CTFPlayer")
    if not G.pLocal then return end
    if not G.players then return end

    G.WLocal = WPlayer.FromEntity(G.pLocal)
    G.latin, G.latout = clientstate.GetLatencyIn() * 1000, clientstate.GetLatencyOut() * 1000 -- Convert to ms
    G.connectionState = PR.GetConnectionState()[G.pLocal:GetIndex()]

    --if Disable then return end --temporary disable

    for _, entity in ipairs(G.players) do
        -- Get the steamid for the player
        local steamid = Common.GetSteamID64(entity)
        if not steamid then
            Log:Warn("Failed to get SteamID for player %s", entity:GetName() or "nil")
        end

        if steamid and Common.IsValidPlayer(entity, false) then
            -- If the record doesn't exist or doesn't have playerData, initialize it with defaultRecord
            if steamid and not G.PlayerData[steamid] then
                G.PlayerData[steamid] = G.DefaultPlayerData -- Assuming defaultRecord structure
            end

            if not skip or not steamid then
                -- Get the player and entity properties
                local wrappedPlayer = WPlayer.FromEntity(entity)
                local viewAngles = wrappedPlayer:GetEyeAngles()
                local entityFlags = entity:GetPropInt("m_fFlags")
                local isOnGround = entityFlags & FL_ONGROUND == 1
                local headHitboxPosition = wrappedPlayer:GetHitboxPos(1)
                local bodyHitboxPosition = wrappedPlayer:GetHitboxPos(4)
                local ViewPos = wrappedPlayer:GetEyePos()
                local simulationTime = wrappedPlayer:GetSimulationTime()

                --dont try to detect already detected player
                if not Common.IsCheater(steamid) and not Common.IsFriend(entity) then
                    -- Initialize the current record
                    G.PlayerData[steamid].Current = Common.createRecord(viewAngles, ViewPos, headHitboxPosition, bodyHitboxPosition, simulationTime, isOnGround)

                    -- Perform checks on the player
                    Detections.CheckAngles(wrappedPlayer, entity)
                    Detections.CheckDuckSpeed(wrappedPlayer, entity)
                    Detections.CheckBunnyHop(wrappedPlayer, entity)
                    Detections.CheckPacketManipulation(wrappedPlayer, entity)
                else
                    -- Initialize the current record with just backtrack data
                    G.PlayerData[steamid].Current = Common.createRecord(nil, nil, headHitboxPosition, bodyHitboxPosition, simulationTime, nil)
                end

                --[[after detections has run and code ended for this tick update history]]
                --Initialize the history table if it doesn't exist
                G.PlayerData[steamid].History = G.PlayerData[steamid].History or {}

                -- Insert the new current record into the history table
                table.insert(G.PlayerData[steamid].History, G.PlayerData[steamid].Current)

                -- Keep the history table size to a maximum of 66
                if #G.PlayerData[steamid].History > 66 then
                    table.remove(G.PlayerData[steamid].History, 1)
                end
            end
        end
    end
end

--[[ Unregister previous callbacks ]]--
callbacks.Unregister("CreateMove", "Cheater_detection")                     -- unregister the "CreateMove" callback

--[[ Register callbacks ]]--
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)        -- register the "CreateMove" callback

--[[ Play sound when loaded ]]--
client.Command('play "ui/buttonclick"', true) -- Play the "buttonclick" sound when the script is loaded