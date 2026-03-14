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
local AsyncSaver = require("Cheater_Detection.Utils.async_saver")

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
		logEntries = 0,
        suppressFullSave = false, -- If true, SaveDatabase will only append to log even if triggers met
        isSaving = false,        -- True if an async save is in progress
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
	local ok, fullPath = pcall(filesystem.CreateDirectory, "Lua Cheater_Detection")
    if ok and fullPath and type(fullPath) == "string" then
        local sep = package.config:sub(1, 1) or "\\"
        return fullPath .. sep .. "database.json"
    end
	return "Lua Cheater_Detection/database.json" -- Fallback
end

function Database.GetLogPath()
	local ok, fullPath = pcall(filesystem.CreateDirectory, "Lua Cheater_Detection")
    if ok and fullPath and type(fullPath) == "string" then
        local sep = package.config:sub(1, 1) or "\\"
        return fullPath .. sep .. "database_updates.jsonl"
    end
	return "Lua Cheater_Detection/database_updates.jsonl" -- Fallback
end

-- Efficiently appends a change to the log file instead of rewriting the entire DB
function Database.AppendChange(steamID, data, isRemoval)
    if not steamID then return end
    
    local logPath = Database.GetLogPath()
    local change = {
        id = steamID,
        data = not isRemoval and data or nil,
        op = isRemoval and "DEL" or "SET",
        ts = os.time()
    }

    if not Json or not Json.encode then
        Log(LogLevel.ERROR, "[DB] Json.encode unavailable for logging!")
        return
    end

    local success, encoded = pcall(Json.encode, change)
    if success and type(encoded) == "string" then
        AsyncSaver.Append(logPath, encoded, function(ok, err)
            if ok then
                Database.State.logEntries = Database.State.logEntries + 1
                Database.State.isDirty = true
            else
                Log(LogLevel.ERROR, "[DB] Async Append failed: " .. tostring(err))
            end
        end)
    else
        Log(LogLevel.ERROR, "[DB] Failed to encode log entry for " .. steamID)
    end
    
    -- Optimized trigger logic: only check if we are not already saving
    if Database.State.isSaving then return end

    -- CONSOLIDATION LOGIC
    local currentTime = os.time()
    local timeSinceLastSave = currentTime - Database.State.lastSave
    local isHardEvidence = false
    if data and data.Flags then
        isHardEvidence = (data.Flags & Constants.Flags.CHEATER) ~= 0
    end

    -- Trigger full save if:
    -- 1. Cooldown (10s) passed AND (100+ entries OR Hard Evidence)
    -- 2. OR Log is getting dangerously large (1000+ entries) and 60s passed
    local entries = Database.State.logEntries
    if timeSinceLastSave >= 10 and not Database.State.suppressFullSave then
        if (entries >= 100 or isHardEvidence) then
            -- Avoid saving too often if we are in a massive fetch
            if entries > 1000 and timeSinceLastSave < 60 then
                -- Wait for 60s for massive logs to reduce IO burst
            else
                Database.SaveDatabase()
            end
        end
    end
end

function Database.SaveDatabase()
	if not G.DataBase or Database.State.isSaving then
		return
	end

    local filepath = Database.GetFilePath()
    Log(LogLevel.DEBUG, "[DB] Initiating async save (chunked optimization + encoding)...")
    
    Database.State.isSaving = true
    
    -- Pass the raw database; AsyncSaver will handle the cleaning loop in chunks
    AsyncSaver.Save(filepath, G.DataBase, function(success, err)
        Database.State.isSaving = false
        if not success then
            Log(LogLevel.ERROR, "[DB] Async Save failed: " .. tostring(err))
            return
        end

        -- After successful full save, we can clear the log
        local logPath = Database.GetLogPath()
        if logPath then
            local logFile = io.open(logPath, "w")
            if logFile then
                logFile:close()
                Database.State.logEntries = 0
            end
        end

        Database.State.isDirty = false
        Database.State.lastSave = os.time()
        Log(LogLevel.SUCCESS, string.format("[DB SUCCESS] Database consolidated and flushed to disk asynchronously: %s", filepath))
    end)
end

function Database.LoadDatabase(silent, force)
	if Database.State.isInitialized and not force then return end

	Log(LogLevel.INFO, "[DB] Loading database...")
	local filePath = Database.GetFilePath()
    local logPath = Database.GetLogPath()

	local file = (filePath and io.open(filePath, "r")) or nil
    local content = nil
	if file then
        content = file:read("*a")
        file:close()
    end

	if not content or #content == 0 then
		G.DataBase = {}
    else
        local success, decodedData = pcall(function()
            if not Json or not Json.decode then return nil end
            return Json.decode(content)
        end)
        content = nil

        if not success or type(decodedData) ~= "table" then
            Log(LogLevel.ERROR, "[DB] JSON Decode Failed (Corrupted file?): " .. tostring(decodedData))
            Log(LogLevel.WARNING, "[DB] Resetting database base layer.")
            G.DataBase = {}
        else
            G.DataBase = decodedData
        end
	end

    -- REPLAY LOGS: Apply any 1/15th of the entries that were saved in the log
    local logFile = (logPath and io.open(logPath, "r")) or nil
    if logFile then
        Log(LogLevel.INFO, "[DB] Replaying updates log...")
        local replayCount = 0
        for line in logFile:lines() do
            if #line > 2 then
                local ok, entry = pcall(Json.decode, line)
                if ok and type(entry) == "table" and entry.id then
                    if entry.op == "DEL" then
                        G.DataBase[entry.id] = nil
                    elseif entry.op == "SET" and type(entry.data) == "table" then
                        G.DataBase[entry.id] = entry.data
                    end
                    replayCount = replayCount + 1
                end
            end
        end
        logFile:close()
        Database.State.logEntries = replayCount
        if replayCount > 0 then
            Log(LogLevel.SUCCESS, string.format("[DB] Applied %d changes from log", replayCount))
        end
    end

    local entriesToRemove = {}
    local total = 0
    
    -- Hardcoded migration map for common long URLs to save space
    local migrationMap = {
        ["megacheaterdb"] = "mega_scat",
        ["official"] = "tf2bd_off",
        ["qfoxb"] = "qfoxb",
        ["joekiller"] = "joekiller",
        ["rgl%-gg"] = "sleepy_rgl",
        ["CheaterFriend"] = "d3_friend",
        ["TacobotList"] = "d3_taco",
        ["Group"] = "d3_group"
    }

    for steamID, value in pairs(G.DataBase) do
        total = total + 1
        if type(value) ~= "table" or type(steamID) ~= "string" or not steamID:match("^7656119%d+$") then
            table.insert(entriesToRemove, steamID)
        else
            -- DATABASE COMPRESSION: Migrate and sanitize URLs/Long strings
            if type(value.Static) == "string" then
                local staticVal = value.Static
                if staticVal:find("http") or #staticVal > 25 then
                    local found = false
                    for pattern, id in pairs(migrationMap) do
                        if staticVal:find(pattern) then
                            value.Static = id
                            found = true
                            Database.State.isDirty = true
                            break
                        end
                    end
                    
                    if not found then
                        value.Static = "Ext"
                        Database.State.isDirty = true
                    end
                end
            end
        end
    end

    for _, key in ipairs(entriesToRemove) do
        G.DataBase[key] = nil
    end

    Database.State.lastLoaded = os.time()
    Log(LogLevel.SUCCESS, string.format("[DB] Database ready: %d entries", total - #entriesToRemove))
    
    Database.SanitizeAll()
    Database.ClearLocalPlayer()
    Database.State.isInitialized = true
end

function Database.SanitizeAll()
    if not G.DataBase then return end
    
    local migrationMap = {
        ["megacheaterdb"] = "mega_scat",
        ["official"] = "tf2bd_off",
        ["qfoxb"] = "qfoxb",
        ["joekiller"] = "joekiller",
        ["rgl%-gg"] = "sleepy_rgl",
        ["CheaterFriend"] = "d3_friend",
        ["TacobotList"] = "d3_taco",
        ["Group"] = "d3_group"
    }

    local sanitized = 0
    for _, value in pairs(G.DataBase) do
        if type(value.Static) == "string" then
            local staticVal = value.Static
            if staticVal:find("http") or #staticVal > 25 then
                local found = false
                for pattern, id in pairs(migrationMap) do
                    if staticVal:find(pattern) then
                        value.Static = id
                        found = true
                        break
                    end
                end
                
                if not found then
                    value.Static = "Ext"
                end
                sanitized = sanitized + 1
                Database.State.isDirty = true
            end
        end
    end

    if sanitized > 0 then
        Log(LogLevel.SUCCESS, string.format("[DB] Aggressively sanitized %d entries (stripped URLs)", sanitized))
        Database.SaveDatabase() -- Force flush to clean the file immediately
    end
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

    -- DATABASE COMPRESSION: Sanitize URL identifiers before storage
    if type(data.Static) == "string" then
        if data.Static:find("http") or #data.Static > 25 then
            data.Static = "Ext"
        end
    end

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
        Static = data.Static or false
	}

	Database.State.isDirty = true
	
	Database.AppendChange(steamID, G.DataBase[steamID], false)

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
		Database.AppendChange(steamID, nil, true)
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

-- Self-init
Database.Initialize(true)

return Database
