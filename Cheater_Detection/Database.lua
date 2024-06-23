--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local G = require("Cheater_Detection.Globals")

local Database = {}

--local Notify = Common.Notify
local Json = Common.Json
local Log = Common.Log

Log.Level = 0

local Lua__fullPath = GetScriptName()
local Lua__fileName = Lua__fullPath:match("\\([^\\]-)$"):gsub("%.lua$", "")
local folder_name = string.format([[Lua %s]], Lua__fileName)

function Database.GetFilePath()
    local success, fullPath = filesystem.CreateDirectory(folder_name)
    return tostring(fullPath .. "/config.cfg")
end

function Database.SaveDatabase(DataBaseTable)
    -- Use the provided DataBaseTable or fallback to G.DataBase or an empty table
    DataBaseTable = DataBaseTable or G.DataBase or {}

    -- Get the file path and replace "config.cfg" with "database.json"
    local filepath = Database.GetFilePath():gsub("config.cfg", "database.json")

    -- Attempt to open the file in write mode
    local file, err = io.open(filepath, "w")

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

        -- Serialize the unique database to JSON
        local serializedDatabase = Json.encode(uniqueDataBase)

        -- Write the serialized database to the file
        file:write(serializedDatabase)

        -- Close the file
        file:close()

        -- Print a success message with a timestamp
        printc(255, 183, 0, 255, "["..os.date("%H:%M:%S").."] Saved Database to ".. tostring(filepath))
    else
        -- Print the error message if file opening failed
        print("Failed to save database. Error: " .. tostring(err))
    end
end

function Database.LoadDatabase()
    local filepath = Database.GetFilePath():gsub("config.cfg", "database.json")
    local file, err = io.open(filepath, "r")

    if file then
        local content = file:read("*a")
        file:close()

        local loadedDatabase, pos, decodeErr = Json.decode(content, 1, nil)

        if decodeErr then
            print("Error loading database:", decodeErr)
        else
            printc(0, 255, 140, 255, "["..os.date("%H:%M:%S").."] Loaded Database from ".. tostring(filepath))
            G.DataBase = loadedDatabase or {}
        end
    else
        print("Failed to load database. Error: " .. tostring(err))
        G.DataBase = {}
        Database.SaveDatabase()
    end
end


-- Enhance data update checking and handling
function Database.updateDatabase(steamID64, playerData)
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
function Database.processRawIDs(content)
    for line in content:gmatch("[^\r\n]+") do
        local steamID = trim(line)  -- Use the newly defined trim function
        if steamID:match("^%d+$") then
            if steamID:len() > 10 then
                Database.updateDatabase(steamID, {
                    Name = "Unknown", cause = "Known Cheater", date = os.date("%Y-%m-%d %H:%M:%S")
                })
            else
                local steam3 = Common.FromSteamid32To64(steamID)
                local steamID64 = steam.ToSteamID64(steam3)
                Database.updateDatabase(steamID64, {
                    Name = "Unknown", cause = "Known Cheater", date = os.date("%Y-%m-%d %H:%M:%S")
                })
            end
        end
    end
end


-- Process each item in the imported data
function Database.processImportedData(data)
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
            Database.updateDatabase(steamID64, playerDetails)
        end
    end
end

-- Simplify file handling using a utility function
function Database.readFromFile(filePath)
    local file = io.open(filePath, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

function Database.importDatabase()
    -- Get the base directory, ensuring that the path ends with a separator.
    local baseFilePath = Database.GetFilePath():gsub("config%.cfg", "")  -- Make sure to escape the dot in "config.cfg".

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
        local content = Database.readFromFile(fullPath)
        if content then
            if Common.isJson(content) then
                local data, err = Json.decode(content)
                if data then
                    Database.processImportedData(data)
                else
                    print("Error decoding JSON from file:", err)
                end
            else
                Database.processRawIDs(content)
            end
        end
    end)
end

function Database.GetRecord(steamId)
    return G.DataBase[steamId]
end

function Database.GetStrikes(steamId)
    return G.DataBase[steamId].strikes
end

function Database.GetCause(steamId)
    return G.DataBase[steamId].cause
end

function Database.GetDate(steamId)
    return G.DataBase[steamId].date
end

function Database.PushSuspect(steamId, data)
    G.DataBase[steamId] = data
end

function Database.ClearSuspect(steamId)
    local status, err = pcall(function()
        if G.DataBase[steamId] then 
            G.DataBase[steamId] = nil
        end
    end)

    if not status then
        print("Failed to clear suspect: " .. err)
    end
end

return Database