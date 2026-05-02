--[[
    Simplified Database.lua
    Direct implementation of database functionality using native Lua tables
    Stores only essential data: name and proof for each SteamID64
    Now uses Serializer for Lua table format instead of JSON.
]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Constants = require("Cheater_Detection.Core.constants")
local Serializer = require("Cheater_Detection.Utils.Serializer")
local Logger = require("Cheater_Detection.Utils.Logger")

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

local HARD_PRIORITY_FLAGS = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.VALVE
local LOCAL_DEAD_SAVE_INTERVAL = 3
local MIN_NONFORCED_SAVE_INTERVAL = 20
local EFFECTIVE_DEAD_AUTOSAVE_INTERVAL = math.max(LOCAL_DEAD_SAVE_INTERVAL, MIN_NONFORCED_SAVE_INTERVAL)

local function ReapplyDetectedPriorities()
	if not G.DataBase then
		return
	end
	if not (G.Menu and G.Menu.Main and G.Menu.Main.AutoPriority) then
		return
	end

	for steamID, entry in pairs(G.DataBase) do
		local flags = type(entry) == "table" and tonumber(entry.Flags or 0) or 0
		if type(steamID) == "string" and (flags & HARD_PRIORITY_FLAGS) ~= 0 then
			pcall(playerlist.SetPriority, steamID, 10)
		end
	end
end

--[[ Public Module Functions ]]

function Database.SetPriority(target, priority)
	if not target then
		return false
	end

	-- Try entity or numeric index directly
	if type(target) == "userdata" or (type(target) == "number" and target < 101) then
		local ok, err = pcall(playerlist.SetPriority, target, priority)
		if ok then
			return true
		end
		Logger.Error(
			"Database",
			string.format(
				"[DB] SetPriority(entity/index) failed for target=%s priority=%s err=%s",
				tostring(target),
				tostring(priority),
				tostring(err)
			)
		)
	end

	-- Resolve to SteamID64 and try
	local steamID64
	if type(target) == "string" and #target == 17 then
		steamID64 = target
	elseif type(target) == "userdata" then
		steamID64 = Common.GetSteamID64(target)
	end

	if steamID64 then
		local ok, err = pcall(playerlist.SetPriority, steamID64, priority)
		if ok then
			if priority == 10 and G.Menu and G.Menu.Main and G.Menu.Main.AutoPriority then
				Database.UpsertCheater(steamID64, {
					name = "Manual Flag",
					reason = "Manual Priority 10",
				})
			end
			return true
		end
		Logger.Error(
			"Database",
			string.format(
				"[DB] SetPriority(steamID64) failed for id=%s priority=%s err=%s",
				tostring(steamID64),
				tostring(priority),
				tostring(err)
			)
		)
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

function Database.SaveDatabase(force)
	if not G.DataBase then
		return
	end
	if not force and not Database.State.isDirty then
		return
	end
	if not force and Database.State.lastSave ~= 0 then
		local elapsed = os.time() - Database.State.lastSave
		if elapsed < MIN_NONFORCED_SAVE_INTERVAL then
			return
		end
	end

	local filepath = Database.GetFilePath()
	Logger.Debug("Database", "[DB] Synchronous save to disk...")
	ReapplyDetectedPriorities()

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
			Logger.Info("Database", "Database flushed to disk: " .. filepath)
		else
			Logger.Error("Database", "[DB] Failed to write database: " .. filepath)
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
			Logger.Debug("Database", "[DB] Local player died, save deferred by autosave throttle")
		end
	end

	if eventName == "game_newmap" or eventName == "teamplay_round_start" or eventName == "round_end" then
		Logger.Debug("Database", "[DB] Session boundary event, triggering save...")
		Database.SaveDatabase()
	end
end

callbacks.Unregister("FireGameEvent", "Database_Events")
callbacks.Register("FireGameEvent", "Database_Events", OnFireEvent)

local function OnCreateMoveAutoSave()
	if not Database.State.isDirty then
		return
	end

	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsValid() then
		return
	end

	if localPlayer:IsAlive() then
		return
	end

	local now = os.time()
	if Database.State.lastSave ~= 0 and (now - Database.State.lastSave) < EFFECTIVE_DEAD_AUTOSAVE_INTERVAL then
		return
	end

	Logger.Debug(
		"Database",
		string.format("[DB] Local player is dead, triggering save (interval=%ds)...", EFFECTIVE_DEAD_AUTOSAVE_INTERVAL)
	)
	Database.SaveDatabase()
end

callbacks.Unregister("CreateMove", "Database_LocalDeadAutoSave")
callbacks.Register("CreateMove", "Database_LocalDeadAutoSave", OnCreateMoveAutoSave)

function Database.LoadDatabase(silent, force)
	if Database.State.isInitialized and not force then
		return
	end

	Logger.Debug("Database", "[DB] Loading database...")
	local filePath = Database.GetFilePath()

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
					Logger.Debug("Database", "[DB] Migrating old JSON database to new format...")
				end
			else
				Logger.Debug("Database", "[DB] Migrating .cfg database to .txt format...")
			end
		else
			Logger.Debug("Database", "[DB] Migrating .lua database to .txt format...")
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
			Logger.Error("Database", "[DB] Load Failed: " .. tostring(decodedData))
			Logger.Warning("Database", "[DB] Data might be corrupted. Resetting database base layer.")
			G.DataBase = {}
		else
			-- PRE-ALLOCATION OPTIMIZATION:
			-- Use the loaded table as the base memory for G.DataBase
			-- Fetcher will now update this table in-place rather than creating new entries
			G.DataBase = decodedData
			local count = 0
			for _ in pairs(G.DataBase) do
				count = count + 1
			end
			Logger.Info("Database", string.format("[DB] Loaded %d entries from disk.", count))
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
	Logger.Info("Database", string.format("[DB] Database ready: %d entries", total - #entriesToRemove))

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
		Logger.Info("Database", string.format("[DB] Aggressively sanitized %d entries (stripped URLs)", sanitized))
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
			Database.SetPriority(localPlayer, 0)
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
		Logger.Debug("Database", "[DB] Removed cheater: " .. steamID)
		return true
	end
	return false
end

function Database.ForceSave()
	Database.SaveDatabase(true)
	return true
end

local function DatabaseAutoSaveOnUnload()
	if not G.DataBase then
		return
	end

	-- Simple synchronous save on unload
	Database.SaveDatabase(true)
end

callbacks.Unregister("Unload", "DatabaseAutoSaveOnUnload") -- Ensure no duplicates
callbacks.Register("Unload", "DatabaseAutoSaveOnUnload", DatabaseAutoSaveOnUnload)

-- Self-init
Database.Initialize(true)

G.Database = Database -- Global access for UI

return Database
