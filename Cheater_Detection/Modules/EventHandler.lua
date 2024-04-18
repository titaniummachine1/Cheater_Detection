
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

    -- Bot Name Checks and Cheater name checks
    if eventName == "player_spawn" or eventName == "teamplay_round_win" or eventName == "player_changeclass" or eventName == "world_status_changed" then
        local player_spawned = entities.GetByUserID(ev:GetInt("userid"))
        -- Skip if attacker or victim is nil, or if attacker is valid
        if Common.IsFriend(player_spawned) then return end

        Detections.KnownCheater(player_spawned)
    end

    -- Initialize variables
    local isHeadshot, attacker, victim

    -- Handle game events
    if eventName == "player_death" or eventName == "player_hurt" then
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
    end
end

callbacks.Unregister("FireGameEvent", "unique_event_hook")                 -- unregister the "FireGameEvent" callback
callbacks.Register("FireGameEvent", "unique_event_hook", event_hook)         -- register the "FireGameEvent" callback

return EventHandler