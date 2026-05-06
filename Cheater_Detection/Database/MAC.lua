--[[ Database/MAC.lua
    Local backend integration removed.
    This module is intentionally disabled and performs no network activity.
]]

local MAC = {}

local DISABLED_MESSAGE = "MAC local backend integration removed (disabled)."

-- Clean up any previous registrations from older versions of this module.
callbacks.Unregister("FireGameEvent", "CD_MAC_Events")
callbacks.Unregister("CreateMove", "CD_MAC_OnCreateMove")

function MAC.IsEnabled()
    return false
end

function MAC.GetStatusText()
    return "MAC: Disabled (local backend removed)"
end

function MAC.GetBaseURL()
    return "disabled"
end

function MAC.GetApiKey()
    return nil
end

function MAC.SetBaseURL(_url)
    return false, DISABLED_MESSAGE
end

function MAC.SetApiKey(_apiKey)
    return false, DISABLED_MESSAGE
end

function MAC.ClearApiKey()
    return true
end

function MAC.QueueRescan()
    return false, DISABLED_MESSAGE
end

return MAC
