--[[
    Simplified Database.lua
    Direct implementation of database functionality using native Lua tables
    Stores only essential data: name and proof for each SteamID64
]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Constants = require("Cheater_Detection.core.constants")
local Json = Common.Json

--[[ Module Declaration ]]
local Database = {
	Config = {
		SaveOnExit = true,
		DebugMode = false,
	},

	State = {
		isDirty = false,
		lastSave = 0,
		lastLoaded = 0,
		isInitialized = false,
	},
}

--[[ Local Variables/Utilities ]]
local LogLevel = {
	ERROR = 1,
	WARNING = 2,
	SUCCESS = 3,
	INFO = 4,
	DEBUG = 5,
}

local function Log(level, message, color)
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	local shouldShow = isDebugMode or (level <= LogLevel.SUCCESS)

	if not shouldShow then return end

	local prefix = ""
	local defaultColor = { 255, 255, 255, 255 }

	if level == LogLevel.ERROR then
		prefix = "[DB ERROR] "
		color = color or { 255, 100, 100, 255 }
	elseif level == LogLevel.WARNING then
		prefix = "[DB WARNING] "
		color = color or { 255, 255, 100, 255 }
	elseif level == LogLevel.SUCCESS then
		prefix = "[DB SUCCESS] "
		color = color or { 0, 255, 140, 255 }
	elseif level == LogLevel.INFO then
		prefix = "[DB INFO] "
		color = color or { 100, 255, 255, 255 }
	elseif level == LogLevel.DEBUG then
		prefix = "[DB DEBUG] "
		color = color or { 180, 180, 180, 255 }
	end

	color = color or defaultColor
	printc(color[1], color[2], color[3], color[4], prefix .. message)
end

--[[ Public Module Functions ]]

-- Robust SetPriority with multiple fallback methods
function Database.SetPriority(target, priority, isInGame)
	if not target then return false end

	local success = false
	local lastError = nil

	-- Method 1: Try entity (only if in-game)
	if isInGame ~= false and type(target) == "userdata" then
		success, lastError = pcall(playerlist.SetPriority, target, priority)
		if success then return true end
	end

	-- Method 2: Try index (only if in-game)
	if isInGame ~= false and type(target) == "number" and target < 101 then
		success, lastError = pcall(playerlist.SetPriority, target, priority)
		if success then return true end
	end

	-- Method 3: Try SteamID64
	local steamID64 = nil
	if type(target) == "string" and #target == 17 then
		steamID64 = target
	elseif type(target) == "userdata" then
		steamID64 = Common.GetSteamID64(target)
	end

	if steamID64 then
		success, lastError = pcall(playerlist.SetPriority, steamID64, priority)
		if success then
			if priority == 10 then
				local menuMain = G.Menu and G.Menu.Main
				if menuMain and menuMain.AutoPriority then
					Database.UpsertCheater(steamID64, {
						name = "Manual Flag",
						reason = "Manual Priority 10",
					})
				end
			end
			return true
		end
	end

	-- Method 4: Try SteamID3 conversion
	if steamID64 then
		local accountID = tonumber(steamID64) - 76561197960265728
		if accountID and accountID > 0 then
			local steamID3 = string.format("[U:1:%d]", accountID)
			success, lastError = pcall(playerlist.SetPriority, steamID3, priority)
			if success then return true end
		end
	end

	return false
end

function Database.GetFilePath()
	pcall(filesystem.CreateDirectory, "Lua Cheater_Detection")
	return "Lua Cheater_Detection/database.json" 
end

function Database.SaveDatabase()
	if not G.DataBase then
		return
	end

	local encodedData = nil
	if Json and Json.encode then
		-- Unified Database Persistence: Save EVERYTHING to database.json
		local saveTable = G.DataBase
		local count = 0
		for _ in pairs(saveTable) do
			count = count + 1
		end

		local success, result = pcall(Json.encode, saveTable)
		if success and type(result) == "string" then
			encodedData = result
			Log(LogLevel.DEBUG, string.format("[DB] Encoded %d entries for saving", count))
		else
			Log(LogLevel.ERROR, "[DB] Json.encode failed: " .. tostring(result))
			return
		end
	else
		Log(LogLevel.ERROR, "[DB] Json.encode unavailable!")
		return
	end

	local filepath = Database.GetFilePath()
	
	local file = io.open(filepath, "w")
	if not file then
		Log(LogLevel.ERROR, "[DB] Failed to open file for writing: " .. filepath)
		return
	end

	file:write(encodedData)
	file:close()
	encodedData = nil

	Database.State.isDirty = false
	Database.State.lastSave = os.time()
	Log(LogLevel.SUCCESS, "[DB] Database flushed to disk")
end

function Database.LoadDatabase(silent, force)
	if Database.State.isInitialized and not force then return end

	Log(LogLevel.INFO, "[DB] Loading database...")
	local filePath = Database.GetFilePath()

	local file = io.open(filePath, "r")
	if not file then
		G.DataBase = {}
		Database.State.isInitialized = true
		return
	end

	local content = file:read("*a")
	file:close()

	if not content or #content == 0 then
		G.DataBase = {}
		Database.State.isInitialized = true
		return
	end

	local success, decodedData = pcall(function()
        if not Json or not Json.decode then return nil end
        return Json.decode(content)
    end)
	content = nil

	if not success or type(decodedData) ~= "table" then
		Log(LogLevel.ERROR, "[DB] JSON Decode Failed (Corrupted file?): " .. tostring(decodedData))
        Log(LogLevel.WARNING, "[DB] Resetting database to prevent undefined behavior.")
		G.DataBase = {}
		Database.State.isInitialized = true
        Database.State.isDirty = true -- Flag for a clean save later
		return
	end

    G.DataBase = decodedData
    local entriesToRemove = {}
    local total = 0
    
    for steamID, value in pairs(G.DataBase) do
        total = total + 1
        if type(value) ~= "table" or type(steamID) ~= "string" or not steamID:match("^7656119%d+$") then
            table.insert(entriesToRemove, steamID)
        else
            -- DATA INTEGRITY: Strip Static flag if it was accidentally saved to disk
            -- Anything in database.json is by definition persistent
            if value.Static then
                value.Static = nil
                Database.State.isDirty = true
            end
        end
    end

    for _, key in ipairs(entriesToRemove) do
        G.DataBase[key] = nil
    end

    Database.State.lastLoaded = os.time()
    Log(LogLevel.SUCCESS, string.format("[DB] Database ready: %d entries", total - #entriesToRemove))
    Database.ClearLocalPlayer()
    Database.State.isInitialized = true
end

function Database.Initialize(silent)
	if Database.State.isInitialized then return end
	if type(G.DataBase) ~= "table" then
		G.DataBase = {}
	end
	Database.LoadDatabase(silent, false)
end

function Database.ClearLocalPlayer()
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer then
		local mySteamID = Common.GetSteamID64(localPlayer)
		if mySteamID then
			Database.SetPriority(localPlayer, 0, true)
            if G.DataBase[mySteamID] then
                G.DataBase[mySteamID] = nil
                Database.State.isDirty = true
            end
		end
	end
end

function Database.UpsertCheater(steamID, data)
	if not steamID or type(steamID) ~= "string" then return false end
	if steamID:sub(1, 4) == "BOT_" then return false end
	if not steamID:match("^7656119%d+$") or #steamID ~= 17 then return false end

	if type(G.DataBase) ~= "table" then G.DataBase = {} end

	local persistentFlags = 0
	if data.flags then
		persistentFlags = data.flags & Constants.PERSISTENT_MASK
	end

	local existing = G.DataBase[steamID]
	local currentTime = os.time()
    local score = data.score or 0

	if existing then
		local scoreDelta = math.abs(score - (existing.Score or 0))
		local timeDelta = currentTime - (existing.Timestamp or 0)
		local reasonChanged = data.reason ~= existing.Reason
		
		if scoreDelta < 1 and timeDelta < 3600 and not reasonChanged and persistentFlags == existing.Flags then 
			return false 
		end
	end

	G.DataBase[steamID] = {
		Name = data.name or "Unknown",
		Reason = data.reason or "Cheater",
		Flags = persistentFlags,
		Score = score,
		Timestamp = currentTime,
	}

	Database.State.isDirty = true
	
	-- Instant Save on Hard Detections or Max Suspicion (>= 99)
	local isHardDetection = (persistentFlags & (Constants.Flags.VALVE | Constants.Flags.VAC_BANNED)) ~= 0
    local isMaxSuspicion = score >= 99

	if isHardDetection or isMaxSuspicion or (data.reason and data.reason:find("VAC")) then
		Database.SaveDatabase()
	end

	return true
end

function Database.GetCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then return nil end
	return G.DataBase[steamID]
end

function Database.RemoveCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then return false end
	if G.DataBase[steamID] then
		G.DataBase[steamID] = nil
		Database.State.isDirty = true
		Log(LogLevel.INFO, "[DB] Removed cheater: " .. steamID)
		Database.SaveDatabase() -- Save immediately on manual remove
		return true
	end
	return false
end

function Database.ForceSave()
	Database.State.isDirty = true
	Database.SaveDatabase()
	return true
end

local function DatabaseAutoSaveOnUnload()
	Log(LogLevel.INFO, "[DB] Unloading script, ensuring database is saved...")
	if Database.State.isDirty then
		Database.SaveDatabase()
	end
end

callbacks.Unregister("Unload", "DatabaseAutoSaveOnUnload") -- Ensure no duplicates
callbacks.Register("Unload", "DatabaseAutoSaveOnUnload", DatabaseAutoSaveOnUnload)

-- Set Priority 10 on start for all existing DB entries!
local function syncPlayerListOnLoad()
	if not G.DataBase then return end
	local count = 0
	for id, _ in pairs(G.DataBase) do
		pcall(playerlist.SetPriority, id, 10)
		count = count + 1
	end
	if count > 0 then
		Log(LogLevel.DEBUG, string.format("[DB] Synced %d entries to engine playerlist", count))
	end
end

-- Self-init
Database.Initialize(true)
syncPlayerListOnLoad()

return Database
