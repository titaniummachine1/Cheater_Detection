--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local G = require("Cheater_Detection.Globals")
local Config = {}

local Log = Common.Log
local Lib = Common.Lib
local Notify = Common.Notify
local Json = Common.Json
local Menu = G.Menu
Log.Level = 0

local Lua__fullPath = GetScriptName()
local Lua__fileName = Lua__fullPath:match("\\([^\\]-)$"):gsub("%.lua$", "")
local folder_name = string.format([[Lua %s]], Lua__fileName)

function Config.GetFilePath()
    local success, fullPath = filesystem.CreateDirectory(folder_name)
    return tostring(fullPath .. "/config.cfg")
end

function Config.CreateCFG(table)
    if not table then
        table = G.Default_Menu
    end

    local filepath = Config.GetFilePath()
    local file = io.open(filepath, "w")  -- Define the file variable here
    local filePathstring = tostring(Config.GetFilePath())
    local shortFilePath = filePathstring:match(".*\\(.*\\.*)$")

    if file then
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

        local serializedConfig = serializeTable(table)
        file:write(serializedConfig)
        file:close()

        local successMessage = shortFilePath
        printc(100, 183, 0, 255, "Succes Saving Config: Path:" .. successMessage)
        Notify.Simple("Success! Saved Config to:", successMessage, 5)
    else
        local errorMessage = "Failed to open: " .. tostring(shortFilePath)
        printc( 255, 0, 0, 255, errorMessage)
        Notify.Simple("Error", errorMessage, 5)
    end
end

-- Function to check if all expected keys exist in the loaded config
local function checkAllKeysExist(expectedMenu, loadedMenu)
    for key, value in pairs(expectedMenu) do
        -- If the key from the expected menu does not exist in the loaded menu, return false
        if loadedMenu[key] == nil then
            return false
        end

        -- If the value is a table, check the keys in the nested table
        if type(value) == "table" then
            local result = checkAllKeysExist(value, loadedMenu[key])
            if not result then
                return false
            end
        end
    end
    return true
end

function Config.LoadCFG()
    local filepath = Config.GetFilePath()
    local file = io.open(filepath, "r")
    local filePathstring = tostring(Config.GetFilePath())
    local shortFilePath = filePathstring:match(".*\\(.*\\.*)$")

    if file then
        local content = file:read("*a")
        file:close()
        local chunk, err = load("return " .. content)
        if chunk then
            local loadedMenu = chunk()
            if checkAllKeysExist(G.Default_Menu, loadedMenu) and not input.IsButtonDown(KEY_LSHIFT) then
                local successMessage = shortFilePath
                printc(100, 183, 0, 255, "Succes Loading Config: Path:" .. successMessage)
                Notify.Simple("Success! Loaded Config from", successMessage, 5)

                G.Menu = loadedMenu
            elseif input.IsButtonDown(KEY_LSHIFT) then
                local warningMessage = "Creating a new config."
                printc( 255, 0, 0, 255, warningMessage)
                Notify.Simple("Warning", warningMessage, 5)
                Config.CreateCFG(G.Default_Menu) -- Save the config

                G.Menu = G.Default_Menu
            else
                local warningMessage = "Config is outdated or invalid. Creating a new config."
                printc( 255, 0, 0, 255, warningMessage)
                Notify.Simple("Warning", warningMessage, 5)
                Config.CreateCFG(G.Default_Menu) -- Save the config

                G.Menu = G.Default_Menu
            end
        else
            local errorMessage = "Error executing configuration file: " .. tostring(err)
            printc( 255, 0, 0, 255, errorMessage)
            Notify.Simple("Error", errorMessage, 5)
            Config.CreateCFG(G.Default_Menu) -- Save the config

            G.Menu = G.Default_Menu
        end
    else
        local warningMessage = "Config file not found. Creating a new config."
        printc( 255, 0, 0, 255, warningMessage)
        Notify.Simple("Warning", warningMessage, 5)
        Config.CreateCFG(G.Default_Menu) -- Save the config

        G.Menu = G.Default_Menu
    end
end

function Config.SaveDatabase(DataBaseTable)
    DataBaseTable = DataBaseTable or G.DataBase or {}
    local filepath = Config.GetFilePath():gsub("config.cfg", "database.json")
    local file = io.open(filepath, "w")

    if file then
        -- Create a new table to store unique records
        local uniqueDataBase = {}

        -- Iterate over the database table
        for steamId, data in pairs(DataBaseTable) do
            -- If the record doesn't exist in the unique database, add it
            if not uniqueDataBase[steamId] then
                uniqueDataBase[steamId] = data
            end
        end

        local serializedDatabase = Json.encode(uniqueDataBase)
        file:write(serializedDatabase)
        file:close()
        printc(255, 183, 0, 255, "["..os.date("%H:%M:%S").."] Saved Database to ".. tostring(filepath))
    else
        print("Failed to save database. Creating a new database.")
        Config.SaveDatabase()
    end
end

function Config.LoadDatabase()
    local filepath = Config.GetFilePath():gsub("config.cfg", "database.json")
    local file = io.open(filepath, "r")

    if file then
        local content = file:read("*a")
        file:close()
        local loadedDatabase, pos, err = Json.decode(content, 1, nil)
        if err then
            print("Error loading database:", err)
        else
            printc(0, 255, 140, 255, "["..os.date("%H:%M:%S").."] Loaded Database from ".. tostring(filepath))
            G.DataBase = loadedDatabase
        end
    else
        print("Failed to load database. Creating a new database.")
        G.DataBase = {}
        Config.SaveDatabase()
    end
end

-- Enhance data update checking and handling
function Config.updateDatabase(steamID64, playerData)
    local existingData = G.DataBase[steamID64]
    if existingData then
        for key, value in pairs(playerData) do
            existingData[key] = value
        end
        return
    end
    G.DataBase[steamID64] = playerData
end

-- Utility function to trim whitespace from both ends of a string
local function trim(s)
    return s:match('^%s*(.*%S)') or ''
end

-- Function to process raw ID data
function Config.processRawIDs(content)
    for line in content:gmatch("[^\r\n]+") do
        local steamID = trim(line)  -- Use the newly defined trim function
        if steamID:match("^%d+$") then
            if steamID:len() > 10 then
                Config.updateDatabase(steamID, {
                    Name = "Unknown", cause = "Known Cheater", date = os.date("%Y-%m-%d %H:%M:%S")
                })
            else
                local steam3 = Common.FromSteamid32To64(steamID)
                local steamID64 = steam.ToSteamID64(steam3)
                Config.updateDatabase(steamID64, {
                    Name = "Unknown", cause = "Known Cheater", date = os.date("%Y-%m-%d %H:%M:%S")
                })
            end
        end
    end
end


-- Process each item in the imported data
function Config.processImportedData(data)
    if data and data.players then
        for _, player in ipairs(data.players) do
            local steamID64
            local playerDetails = {
                Name = player.name or "NN",
                cause = (player.attributes and table.concat(player.attributes, ", ")) or player.cause or "Known Cheater",
                date = player.date or os.date("%Y-%m-%d %H:%M:%S")
            }
            if player.steamid:match("^%[U:1:%d+%]$") then
                steamID64 = steam.ToSteamID64(player.steamid)
            elseif player.steamid:match("^%d+$") then
                local steam3 = Common.FromSteamid32To64(player.steamid)
                steamID64 = steam.ToSteamID64(steam3)
            else
                steamID64 = player.steamid  -- Already SteamID64
            end
            Config.updateDatabase(steamID64, playerDetails)
        end
    end
end

-- Simplify file handling using a utility function
function Config.readFromFile(filePath)
    local file = io.open(filePath, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

function Config.importDatabase()
    -- Get the base directory, ensuring that the path ends with a separator.
    local baseFilePath = Config.GetFilePath():gsub("config%.cfg", "")  -- Make sure to escape the dot in "config.cfg".

    -- Append the 'import/' folder path correctly.
    local importPath = baseFilePath .. "import/"

    -- Ensure the import directory exists
    local success, directoryPath = filesystem.CreateDirectory(importPath)
    if not directoryPath then
        print("Failed to create or access import directory:", directoryPath)
        return
    end

    -- Enumerate all files in the import directory
    filesystem.EnumerateDirectory(importPath, function(filename, attributes)
        local fullPath = importPath .. filename
        local content = Config.readFromFile(fullPath)
        if content then
            if Common.isJson(content) then
                local data, err = Json.decode(content)
                if data then
                    Config.processImportedData(data)
                else
                    print("Error decoding JSON from file:", err)
                end
            else
                Config.processRawIDs(content)
            end
        end
    end)
end

function Config.IsKnownCheater(steamId)
    return G.DataBase[steamId] ~= nil
end

function Config.GetRecord(steamId)
    return G.DataBase[steamId]
end

function Config.GetStrikes(steamId)
    return G.DataBase[steamId].strikes
end

function Config.GetCause(steamId)
    return G.DataBase[steamId].cause
end

function Config.GetDate(steamId)
    return G.DataBase[steamId].date
end

function Config.PushSuspect(steamId, data)
    G.DataBase[steamId] = data
end

function Config.ClearSuspect(steamId)
    if G.DataBase[steamId] then
        G.DataBase[steamId] = nil
    end
end

--[[ Callbacks ]]
local function OnUnload() -- Called when the script is unloaded
    Config.CreateCFG(G.Menu) -- Save the configurations

    if G.DataBase then
        if G.Menu.Main.debug then
            Config.ClearSuspect(Common.GetSteamID(G.pLocal)) -- Clear the local if debug is enabled
        end

        Config.SaveDatabase(G.DataBase) -- Save the database
    else
        Config.SaveDatabase()
    end
end

--[[ Unregister previous callbacks ]]--
callbacks.Unregister("Unload", "CD_Unload")                                -- unregister the "Unload" callback
--[[ Register callbacks ]]--
callbacks.Register("Unload", "CD_Unload", OnUnload)                         -- Register the "Unload" callback


return Config