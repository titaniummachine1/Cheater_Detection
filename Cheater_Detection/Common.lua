---@diagnostic disable: duplicate-set-field, undefined-field
---@class Common
local Common = {}

pcall(UnloadLib) -- if it fails then forget about it it means it wasnt loaded in first place and were clean

local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
assert(Lib.GetVersion() >= 1.0, "LNXlib version is too old, please update it!")

Common.Lib = Lib
Common.Log = Lib.Utils.Logger.new("Cheater Detection")
Common.Notify = Lib.UI.Notify
Common.TF2 = Common.Lib.TF2
Common.Math, Common.Conversion = Common.Lib.Utils.Math, Common.Lib.Utils.Conversion
Common.WPlayer, Common.PR = Common.TF2.WPlayer, Common.TF2.PlayerResource
Common.Helpers = Common.TF2.Helpers

local G = require("Cheater_Detection.Globals")
-- Require Json.lua directly
Common.Json = require("Cheater_Detection.Modules.Json")

function Common.GetSteamID64(Player)
    if Player then
        local playerInfo = client.GetPlayerInfo(Player:GetIndex())
        local steamID = playerInfo.SteamID
        if steamID then
            --Check if the steamID matches the format of a bot (SteamID3 format [U:1:0])
            if playerInfo.IsBot or playerInfo.IsHLTV or steamID == "[U:1:0]" then  -- Handle bot cases
                return playerInfo.UserID  -- Return the bot's name instead of its SteamID
            end

            -- Convert and return the SteamID64 for regular players
            local steamID64 = steam.ToSteamID64(steamID)
            return steamID64
        end
    end
    Log.Warn("Failed to get SteamID for player %s", Player:GetName() or "nil")
    return nil
end

function Common.IsCheater(playerInfo)
    local steamId = nil

    if type(playerInfo) == "number" and playerInfo < 101 then --we got index not steamid
        -- If playerInfo is a number, convert it to a string and check its length
        local steamIdStr = tostring(playerInfo)
        if #steamIdStr == 17 then
            -- If the string representation of playerInfo is 17 characters long, it's a valid SteamID64
            steamId = playerInfo
        else
            local targetIndex = playerInfo -- assuming playerInfo is the index
            local targetPlayer = nil
            for _, player in ipairs(G.players) do
                if player:GetIndex() == targetIndex then
                    targetPlayer = player
                    break
                end
            end
            -- Now targetPlayer is the player with the same index, or nil if no such player was found
            steamId = Common.GetSteamID64(targetPlayer)
        end
    elseif type(playerInfo) == "number" then
        -- If playerInfo is a number, convert it to a string and check its length
        local steamIdStr = tostring(playerInfo)
        if #steamIdStr == 17 then
            -- If the string representation of playerInfo is 17 characters long, it's a valid SteamID64
            steamId = playerInfo
        end
    elseif playerInfo.GetIndex then
        -- If playerInfo is a player entity, get its SteamID64
        steamId = Common.GetSteamID64(playerInfo)
    else
        -- If playerInfo is neither a valid index, a valid SteamID64, nor a player entity, return false
        return false
    end

    if playerlist.GetPriority(steamId) == 10 then
        return true
    end

    -- Check if player is in database or marked as cheater
    local inDatabase = G.DataBase[steamId] ~= nil
    local isMarkedCheater = G.PlayerData[steamId] ~= nil and G.PlayerData[steamId].info ~= nil and G.PlayerData[steamId].info.IsCheater == true

    return inDatabase or isMarkedCheater
end

function Common.IsFriend(entity)
    return (not G.Menu.Main.debug and TF2.IsFriend(entity:GetIndex(), true)) -- Entity is a freind and party member
end

function Common.IsValidPlayer(entity, checkFriend)
    -- Check if the entity is a valid player
    if not entity or entity:IsDormant() or not entity:IsAlive() then
        return false -- Entity is not a valid player
    end

    if checkFriend and Common.IsFriend(entity) then
        return false -- Entity is a friend, skip
    end

    return true -- Entity is a valid player
end

-- Create a common record structure
function Common.createRecord(angle, position, headHitbox, bodyHitbox, simTime, onGround)
    return {
        Angle = angle,
        ViewPos = position,
        Hitboxes = {
        Head = headHitbox,
            Body = bodyHitbox,
        },
        SimTime = simTime,
        onGround = onGround,
    }
end

function Common.FromSteamid32To64(steamid32)
    return "[U:1:" .. steamid32 .. "]"
end

-- Helper function to determine if the content is JSON
function Common.isJson(content)
    local firstChar = content:sub(1, 1)
    return firstChar == "{" or firstChar == "["
end

--[[ Callbacks ]]
local function OnUnload() -- Called when the script is unloaded
    UnloadLib() --unloading lualib
    client.Command('play "ui/buttonclickrelease"', true) -- Play the "buttonclickrelease" sound
end

--[[ Unregister previous callbacks ]]--
callbacks.Unregister("Unload", "CD_Unload")                                -- unregister the "Unload" callback
--[[ Register callbacks ]]--
callbacks.Register("Unload", "CD_Unload", OnUnload)                         -- Register the "Unload" callback

return Common