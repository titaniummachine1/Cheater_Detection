---@class Common
local Common = {}

pcall(UnloadLib) -- if it fails then forget about it it means it wasnt loaded in first place and were clean

---@type boolean, LNXlib
local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
assert(Lib.GetVersion() >= 1.0, "LNXlib version is too old, please update it!")
Common.Lib = Lib
Common.Log = Lib.Utils.Logger.new("Cheater Detection")
Common.Notify = Lib.UI.Notify
-- Require Json.lua directly
Common.Json = require("Cheater_Detection.Modules.Json")

function Common.GetSteamID(Player)
    if Player then
        local playerInfo = client.GetPlayerInfo(Player:GetIndex())
        local steamID = playerInfo.SteamID
        if steamID then
            local steamID64 = steam.ToSteamID64(steamID)
            return steamID64
        end
    end
    Log.Warn("Failed to get SteamID for player %s", Player:GetName() or "nil")
    return nil
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