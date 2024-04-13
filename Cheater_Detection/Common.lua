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

-- Create a common record structure
function Common.createRecord(angle, position, headHitbox, bodyHitbox, simTime, onGround)
    return {
        Angle = angle,
        Position = position,
        Hitboxes = {
        Head = headHitbox,
            Body = bodyHitbox,
        },
        SimTime = simTime,
        onGround = onGround
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