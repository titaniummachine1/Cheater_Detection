--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local G = require("Cheater_Detection.Globals")
local Config = {}

local Log = Common.Log
local Notify = Common.Notify
Log.Level = 0

local Lua__fullPath = GetScriptName()
local Lua__fileName = Lua__fullPath:match("\\([^\\]-)$"):gsub("%.lua$", "")
local folder_name = string.format([[Lua %s]], Lua__fileName)

--[[ Helper Functions ]]
function Config.GetFilePath()
    local success, fullPath = filesystem.CreateDirectory(folder_name)
    return fullPath .. "/config.cfg"
end

local function serializeTable(tbl, level)
    level = level or 0
    local result = string.rep("    ", level) .. "{\n"
    for key, value in pairs(tbl) do
        result = result .. string.rep("    ", level + 1)
        if type(key) == "string" then
            result = result .. '["' .. key .. '"] = '
        else
            result = result .. "[" .. key .. "] = "
        end
        if type(value) == "table" then
            result = result .. serializeTable(value, level + 1) .. ",\n"
        elseif type(value) == "string" then
            result = result .. '"' .. value .. '",\n'
        else
            result = result .. tostring(value) .. ",\n"
        end
    end
    result = result .. string.rep("    ", level) .. "}"
    return result
end

local function checkAllKeysExist(expectedMenu, loadedMenu)
    for key, value in pairs(expectedMenu) do
        if loadedMenu[key] == nil then
            return false
        end
        if type(value) == "table" then
            local result = checkAllKeysExist(value, loadedMenu[key])
            if not result then
                return false
            end
        end
    end
    return true
end

--[[ Configuration Functions ]]
function Config.CreateCFG(table)
    table = table or G.Default_Menu

    local filepath = Config.GetFilePath()
    local file = io.open(filepath, "w")
    local shortFilePath = filepath:match(".*\\(.*\\.*)$")

    if file then
        local serializedConfig = serializeTable(table)
        file:write(serializedConfig)
        file:close()

        printc(100, 183, 0, 255, "Success Saving Config: Path: " .. shortFilePath)
        Notify.Simple("Success! Saved Config to:", shortFilePath, 5)
    else
        local errorMessage = "Failed to open: " .. shortFilePath
        printc(255, 0, 0, 255, errorMessage)
        Notify.Simple("Error", errorMessage, 5)
    end
end

function Config.LoadCFG()
    local filepath = Config.GetFilePath()
    local file = io.open(filepath, "r")
    local shortFilePath = filepath:match(".*\\(.*\\.*)$")

    if file then
        local content = file:read("*a")
        file:close()
        local chunk, err = load("return " .. content)
        if chunk then
            local loadedMenu = chunk()
            if checkAllKeysExist(G.Default_Menu, loadedMenu) and not input.IsButtonDown(KEY_LSHIFT) then
                printc(100, 183, 0, 255, "Success Loading Config: Path: " .. shortFilePath)
                Notify.Simple("Success! Loaded Config from", shortFilePath, 5)
                G.Menu = loadedMenu
            else
                local warningMessage = input.IsButtonDown(KEY_LSHIFT) and "Creating a new config." or "Config is outdated or invalid. Creating a new config."
                printc(255, 0, 0, 255, warningMessage)
                Notify.Simple("Warning", warningMessage, 5)
                Config.CreateCFG(G.Default_Menu)
                G.Menu = G.Default_Menu
            end
        else
            local errorMessage = "Error executing configuration file: " .. tostring(err)
            printc(255, 0, 0, 255, errorMessage)
            Notify.Simple("Error", errorMessage, 5)
            Config.CreateCFG(G.Default_Menu)
            G.Menu = G.Default_Menu
        end
    else
        local warningMessage = "Config file not found. Creating a new config."
        printc(255, 0, 0, 255, warningMessage)
        Notify.Simple("Warning", warningMessage, 5)
        Config.CreateCFG(G.Default_Menu)
        G.Menu = G.Default_Menu
    end
end

return Config