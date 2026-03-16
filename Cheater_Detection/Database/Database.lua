--[[
    Simplified Database.lua
    Direct implementation of database functionality using native Lua tables
    Stores only essential data: name and proof for each SteamID64
    Now uses Serializer for Lua table format instead of JSON.
]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Constants = require("Cheater_Detection.core.constants")
local Serializer = require("Cheater_Detection.Utils.Serializer")

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
		suppressFullSave = false, -- Unused in simplified version
		isSaving = false, -- Unused in simplified version
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

	if not shouldShow then
		return
	end

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

local function SaveMetadata()
end

local function LoadMetadata()
end

--[[ Public Module Functions ]]

-- Robust SetPriority with multiple fallback methods
function Database.SetPriority(target, priority, isInGame)
	if not target then
		return false
	end

	local success = false
	local lastError = nil

	-- Method 1: Try entity (only if in-game)
	if isInGame ~= false and type(target) == "userdata" then
		success, lastError = pcall(playerlist.SetPriority, target, priority)
		if success then
			return true
		end
	end

	-- Method 2: Try index (only if in-game)
	if isInGame ~= false and type(target) == "number" and target < 101 then
		success, lastError = pcall(playerlist.SetPriority, target, priority)
		if success then
			return true
		end
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
			if success then
				return true
			end
		end
	end

	return false
end

function Database.GetFilePath()
	local _, fullPath = filesystem.CreateDirectory("Lua Cheater_Detection")
	if type(fullPath) == "string" then
		local sep = package.config:sub(1, 1) or "\\"
		return fullPath .. sep .. "database.txt"
	end
	return "Lua Cheater_Detection/database.txt" -- Fallback
end

function Database.GetLogPath()
	local _, fullPath = filesystem.CreateDirectory("Lua Cheater_Detection")
	if type(fullPath) == "string" then
		local sep = package.config:sub(1, 1) or "\\"
		return fullPath .. sep .. "database_updates.txtl"
	end
	return "Lua Cheater_Detection/database_updates.txtl" -- Fallback
end

-- Simplified: Just mark as dirty for future sync save
function Database.AppendChange(steamID, data, isRemoval)
	if not steamID then
		return
	end

	Database.State.isDirty = true
end

function Database.SaveDatabase()
	if not G.DataBase or not Database.State.isDirty then
		return
	end

	local filepath = Database.GetFilePath()
	Log(LogLevel.DEBUG, "[DB] Synchronous save to disk...")

	local cleanedData = {}
	for k, v in pairs(G.DataBase) do
		if type(v) == "table" and type(k) == "string" then
			local clean = {}
			if v.Name and v.Name ~= "Unknown" and v.Name ~= tostring(k) then
				clean.Name = v.Name
			end
			if v.Reason and v.Reason ~= "Unknown Source" then
				clean.Reason = v.Reason
			end
			if v.Static then
				clean.Static = v.Static
			end
			if v.Flags and v.Flags ~= 0 then
				clean.Flags = v.Flags
			end
			if v.Score and v.Score ~= 0 then
				clean.Score = v.Score
			end
			cleanedData[k] = clean
		end
	end

	local encoded = Serializer.serializeTable(cleanedData)
	if encoded then
		if Serializer.writeFile(filepath, encoded) then
			Database.State.isDirty = false
			Database.State.lastSave = os.time()
			Log(LogLevel.SUCCESS, "Database flushed to disk: " .. filepath)
		else
			Log(LogLevel.ERROR, "[DB] Failed to write database: " .. filepath)
		end
	end
end

local function OnFireEvent(event)
	local eventName = event:GetName()
	local localPlayer = entities.GetLocalPlayer()

	-- Trigger save on local player death
	if eventName == "player_death" then
		local victimID = event:GetInt("userid")
		local victimEntity = entities.GetByUserID(victimID)

		local isLocalDeath = victimEntity and localPlayer and victimEntity:GetIndex() == localPlayer:GetIndex()
		if isLocalDeath then
			Log(LogLevel.DEBUG, "[DB] Local player died, triggering save...")
			Database.SaveDatabase()
		end
	end

	-- Trigger save when local player spawns (respawn after death)
	if eventName == "player_spawn" then
		local spawnedID = event:GetInt("userid")
		local spawnedEntity = entities.GetByUserID(spawnedID)

		local isLocalSpawn = spawnedEntity and localPlayer and spawnedEntity:GetIndex() == localPlayer:GetIndex()
		if isLocalSpawn then
			Log(LogLevel.DEBUG, "[DB] Local player spawned, triggering save...")
			Database.SaveDatabase()
		end
	end

	-- Trigger save on map change only (not round_start — fires every round)
	if eventName == "game_newmap" then
		Log(LogLevel.DEBUG, "[DB] Map change, triggering save...")
		Database.SaveDatabase()
	end
end

callbacks.Unregister("FireGameEvent", "Database_Events")
callbacks.Register("FireGameEvent", "Database_Events", OnFireEvent)

function Database.LoadDatabase(silent, force)
	if Database.State.isInitialized and not force then
		return
	end
	LoadMetadata()

	Log(LogLevel.INFO, "[DB] Loading database...")
	local filePath = Database.GetFilePath()
	local logPath = Database.GetLogPath()

	-- Try loading .txt first, fallback to .lua, .cfg or .json if not found (for migration)
	local content = Serializer.readFile(filePath)
	if not content then
		local luaPath = filePath:gsub("%.txt$", ".lua")
		content = Serializer.readFile(luaPath)
		if not content then
			local cfgPath = filePath:gsub("%.txt$", ".cfg")
			content = Serializer.readFile(cfgPath)
			if not content then
				local oldPath = filePath:gsub("%.txt$", ".json")
				local oldFile = io.open(oldPath, "r")
				if oldFile then
					content = oldFile:read("*a")
					oldFile:close()
					Log(LogLevel.INFO, "[DB] Migrating old JSON database to new format...")
				end
			else
				Log(LogLevel.INFO, "[DB] Migrating .cfg database to .txt format...")
			end
		else
			Log(LogLevel.INFO, "[DB] Migrating .lua database to .txt format...")
		end
	end

	if not content or #content == 0 then
		G.DataBase = {}
	else
		local success, decodedData = pcall(function()
			-- Try Lua load with return prepended (new format)
			local chunk, err = load("return " .. content)
			if not chunk then
				error("Lua parse error (prepended return): " .. tostring(err))
			end
			local success, result = pcall(chunk)
			if not success then
				error("Lua execution error (prepended return): " .. tostring(result))
			end
			if type(result) == "table" then
				return result
			end

			-- Try raw Lua load (old format)
			chunk, err = load(content)
			if not chunk then
				error("Lua parse error (raw): " .. tostring(err))
			end
			success, result = pcall(chunk)
			if not success then
				error("Lua execution error (raw): " .. tostring(result))
			end
			if type(result) == "table" then
				return result
			end

			-- Fallback to JSON for migration
			local decodedJson = Common.Json.decode(content)
			if type(decodedJson) == "table" then
				return decodedJson
			end

			error("Failed to decode content in any format.")
		end)
		content = nil

		if not success or type(decodedData) ~= "table" then
			Log(LogLevel.ERROR, "[DB] Load Failed: " .. tostring(decodedData))
			Log(LogLevel.WARNING, "[DB] Data might be corrupted. Resetting database base layer.")
			G.DataBase = {}
		else
			-- PRE-ALLOCATION OPTIMIZATION:
			-- Use the loaded table as the base memory for G.DataBase
			-- Fetcher will now update this table in-place rather than creating new entries
			G.DataBase = decodedData
			local count = 0
			for _ in pairs(G.DataBase) do count = count + 1 end
			Log(LogLevel.SUCCESS, string.format("[DB] Loaded %d entries from disk.", count))
		end
	end

	local entriesToRemove = {}
	local total = 0

	for steamID, value in pairs(G.DataBase) do
		total = total + 1
		if type(value) ~= "table" or type(steamID) ~= "string" or not steamID:match("^7656119%d+$") then
			table.insert(entriesToRemove, steamID)
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
	if not G.DataBase then
		return
	end

	local migrationMap = {
		["megacheaterdb"] = "mega_scat",
		["official"] = "tf2bd_off",
		["qfoxb"] = "qfoxb",
		["joekiller"] = "joekiller",
		["rgl%-gg"] = "sleepy_rgl",
		["CheaterFriend"] = "d3_friend",
		["TacobotList"] = "d3_taco",
		["Group"] = "d3_group",
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
		-- isDirty is already set by UpsertCheater; save will happen on next natural trigger
	end
end

function Database.Initialize(silent)
	if Database.State.isInitialized then
		return
	end
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
	if not steamID or type(steamID) ~= "string" then
		return false
	end
	if steamID:sub(1, 4) == "BOT_" then
		return false
	end
	if not steamID:match("^7656119%d+$") or #steamID ~= 17 then
		return false
	end

	if type(G.DataBase) ~= "table" then
		G.DataBase = {}
	end

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
		Static = data.Static or false,
	}

	Database.State.isDirty = true

	Database.AppendChange(steamID, G.DataBase[steamID], false)

	return true
end

function Database.GetCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then
		return nil
	end
	return G.DataBase[steamID]
end

function Database.RemoveCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then
		return false
	end
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
	if not G.DataBase or not Database.State.isDirty then
		return
	end

	-- Simple synchronous save on unload
	Database.SaveDatabase()
end

callbacks.Unregister("Unload", "DatabaseAutoSaveOnUnload") -- Ensure no duplicates
callbacks.Register("Unload", "DatabaseAutoSaveOnUnload", DatabaseAutoSaveOnUnload)

-- Self-init
Database.Initialize(true)

G.Database = Database -- Global access for UI

return Database
