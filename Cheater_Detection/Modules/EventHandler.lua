
local EventHandler = {}

--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local Config = require("Cheater_Detection.Config")
local G = require("Cheater_Detection.Globals")

local Lib = Common.Lib

local TF2 = Common.TF2
local Math, Conversion = Common.Math, Common.Conversion
local WPlayer, PR = TF2.WPlayer, TF2.PlayerResource
local Helpers = Common.Helpers
local Log = Common.Log

-- Event hook function
local function event_hook(ev)
    local eventName = ev:GetName()

    if (eventName == "player_changeclass") and G.Menu.Visuals.Class_Change_Reveal.Enable then
        local player = entities.GetByUserID(ev:GetInt("userid"))
        if (player == nil) then return end

        local playerName = player:GetName()
        if Common.IsFriend(player) then return end --ignore friends

        if G.Menu.Visuals.Class_Change_Reveal.EnemyOnly then --ignore team
            if player:GetTeamNumber() == G.pLocal:GetTeamNumber() then return end
        end

        local classNumber = ev:GetInt("class")
        local classNames = {
            [1] = "Scout",
            [2] = "Sniper",
            [3] = "Soldier",
            [4] = "Demoman",
            [5] = "Medic",
            [6] = "Heavy",
            [7] = "Pyro",
            [8] = "Spy",
            [9] = "Engineer"
        }
        local className = classNames[classNumber] or "Unknown Class"
        local text = string.format("\x04[CD] \x03%s\x01 changed class to \x04%s", playerName, className)
        client.ChatPrintf(text)

        if G.Menu.Visuals.Class_Change_Reveal.PartyChat then
            client.Command( "say_party \"" .. text .. "\"", true );
        end

        if G.Menu.Visuals.Class_Change_Reveal.Console then
            printc(255,255,255,255, text)
        end
        return
    end

    if (eventName == "player_connect") then
        local player = entities.GetByUserID(ev:GetInt("userid"))
        if (player == nil) then return end

        local playerName = player:GetName()
        if Common.IsFriend(player) then return end --ignore friends

        if G.Menu.Visuals.Class_Change_Reveal.EnemyOnly
        and G.pLocal:GetTeamNumber() == player:GetTeamNumber() then --ignore team
            return
        end

        --run cehck for backgreound in database
        Detections.KnownCheater(player_spawned)
        return
    end

    --[[Vote Revealer]]--
    if (eventName == "vote_cast") then
        local player = entities.GetByIndex(event:GetInt("entityid"))
        if (player == nil) then return end

        local me = G.pLocal
        if (me == nil or me == player) then return end

        local processVote = false

        if (G.Menu.Visuals.Vote_Reveal.TargetTeam.MyTeam and me:GetTeamNumber() == player:GetTeamNumber()) then
            processVote = true
        elseif (G.Menu.Visuals.Vote_Reveal.TargetTeam.enemyTeam and me:GetTeamNumber() ~= player:GetTeamNumber()) then
            processVote = true
        end

        if not processVote then return end

        local vote_option = event:GetInt("vote_option")
        local optionColorCode = vote_option == 0 and "\x07" .. "00ff00" or "\x07" .. "ff0000" -- Green for Yes, Red for No
        local option = vote_option == 0 and "Yes" or "No"

        local playerinfo = client.GetPlayerInfo(player:GetIndex())
        if (playerinfo == nil) then return end

        local playername = playerinfo.Name
        local teamIdentifier = me:GetTeamNumber() == player:GetTeamNumber() and "[Same team vote]" or "[Other team vote]"

        local formattedText = string.format("\x01%s \x03%s \x01voted %s%s\x01!", teamIdentifier, playername, optionColorCode, option)

        -- Print to console with colors
        if G.Menu.Visuals.Vote_Reveal.Console then
            print(formattedText) -- This might need adjusting if console does not support colors
        end

        -- Print to party chat with colors
        if G.Menu.Visuals.Vote_Reveal.PartyChat then
            client.ChatPrintf(formattedText)
        end
    end

    -- Bot Name Checks and Cheater name checks
    if (eventName == "player_spawn") then
        local player = entities.GetByUserID(ev:GetInt("userid"))
        if (player == nil) then return end
 
        -- Skip if friend
        if Common.IsFriend(player) then return end

        --run cehck for backgreound in database
        Detections.KnownCheater(player)
        return
    end

    if (eventName == "teamplay_round_win") or (eventName == "world_status_changed") then
        --reset playerdata to not crash game after long sesion
        G.PlayerData = {}
        return
    end

    -- Handle game events
    if eventName == "player_death" or eventName == "player_hurt" then
        -- Initialize variables
        local isHeadshot, attacker, victim

        -- Get the entities involved in the event
        attacker = entities.GetByUserID(ev:GetInt("attacker"))
        victim = entities.GetByUserID(ev:GetInt("userid"))

        -- Skip if attacker or victim is nil, or if attacker is valid
        if not attacker or not victim or Common.IsValidPlayer(attacker, true) then return end
        local attackerID = Common.GetSteamID64(attacker)

        --ignore detected players
        if Common.IsCheater(attackerID) then return end
        --ignore non hitscan weapons
        if attacker:GetPropEntity("m_hActiveWeapon"):GetWeaponProjectileType() ~= 1 then return end

        -- Handle specific event types
        isHeadshot = (ev:GetInt("customkill") == TF_CUSTOM_AIM_HEADSHOT)
        if eventName == "player_death" and isHeadshot then --when killed with headshot
            --Get the most recent entry in the history table
            G.PlayerData[attackerID].History[#G.PlayerData[attackerID].History].FiredGun = 1
            --CheckAimbotFlick(hurtVictim , shooter)
            --print(true)
        else
            G.PlayerData[attackerID].History[#G.PlayerData[attackerID].History].FiredGun = 2
            --CheckAimbotFlick(hurtVictim , shooter)
        end

        return
    end
end

callbacks.Unregister("FireGameEvent", "CD_event_hook")                 -- unregister the "FireGameEvent" callback
callbacks.Register("FireGameEvent", "CD_event_hook", event_hook)         -- register the "FireGameEvent" callback

return EventHandler