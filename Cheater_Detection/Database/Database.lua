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
local Events = require("Cheater_Detection.Core.Events")

local EmbeddedDBs = {
	["d3fc0n6_embedded"]           = require("Cheater_Detection.Database.Static_Embeded_Databases.d3fc0n6_embedded"),
	["sleepy_main_embedded"]       = require("Cheater_Detection.Database.Static_Embeded_Databases.sleepy_main_embedded"),
	["sleepy_ext_embedded"]        = require("Cheater_Detection.Database.Static_Embeded_Databases.sleepy_ext_embedded"),
	["sleepy_nullc0re_embedded"]   = require(
		"Cheater_Detection.Database.Static_Embeded_Databases.sleepy_nullc0re_embedded"),
	["tf2bd_official_embedded"]    = require(
		"Cheater_Detection.Database.Static_Embeded_Databases.tf2bd_official_embedded"),
	["qfoxb_embedded"]             = require("Cheater_Detection.Database.Static_Embeded_Databases.qfoxb_embedded"),
	["joekiller_embedded"]         = require("Cheater_Detection.Database.Static_Embeded_Databases.joekiller_embedded"),
	["megascat_embedded"]          = require("Cheater_Detection.Database.Static_Embeded_Databases.megascat_embedded"),
	["external_combined_embedded"] = require(
		"Cheater_Detection.Database.Static_Embeded_Databases.external_combined_embedded"),
	["tfcl_combined_lua"]          = require("Cheater_Detection.Database.Static_Embeded_Databases.tfcl_combined_lua"),
}

-- Global lookup tables for embedded databases (shared across all databases)
local GlobalLookupTables = require("Cheater_Detection.Database.Static_Embeded_Databases.global_lookup_tables")

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
local ALIVE_IDLE_SAVE_INTERVAL = 45
local SLOW_SAVE_WARN_SECONDS = 0.015

local function nowSeconds()
	if globals and type(globals.RealTime) == "function" then
		local ok, t = pcall(globals.RealTime)
		if ok and type(t) == "number" then
			return t
		end
	end
	return os.clock()
end

local function ReapplyDetectedPriorities()
	if not G.DataBase then
		return
	end
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.AutoPriority == true) then
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
			local autoPriorityEnabled = G.Menu and G.Menu.Advanced and G.Menu.Advanced.AutoPriority == true
			if priority == 10 and autoPriorityEnabled then
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

local function serializeCompressedDatabase(normalizedData)
	local chunks = {}
	local count = 1
	chunks[count] =
	"return {\n    _Metadata = {\n        Version = 4,\n        Format = \"global_lookup\"\n    },\n    Data = {\n"
	count = count + 1

	local isFirst = true
	for k, entry in pairs(normalizedData) do
		local entryChunks = {}
		for i = 1, #entry do
			local val = entry[i]
			if type(val) == "string" then
				local escaped = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
				entryChunks[i] = '"' .. escaped .. '"'
			else
				entryChunks[i] = tostring(val)
			end
		end

		local line = '        ["' .. k .. '"] = {' .. table.concat(entryChunks, ", ") .. '}'
		if not isFirst then
			chunks[count - 1] = chunks[count - 1] .. ",\n"
		else
			isFirst = false
		end
		chunks[count] = line
		count = count + 1
	end

	chunks[count] = "\n    }\n}"
	return table.concat(chunks)
end

function Database.SaveDatabase(force)
	local saveStartedAt = nowSeconds()
	if not G.DataBase then
		return
	end
	local localPlayer = entities.GetLocalPlayer()
	if not force and localPlayer and localPlayer:IsValid() and localPlayer:IsAlive() then
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
	Logger.Debug("Database", "[DB] Synchronous save to disk (global lookup format)...")
	ReapplyDetectedPriorities()

	-- Use global lookup tables for compression
	local normalizedData = {}

	for k, v in pairs(G.DataBase) do
		if type(v) == "table" and type(k) == "string" then
			if v[1] ~= nil and type(v[1]) == "number" then
				normalizedData[k] = v
			else
				-- Map Source to global lookup ID or inline string
				local sourceValue
				if type(v.Source) == "string" and v.Source ~= "" then
					local sourceID = GlobalLookupTables.Sources_rev and GlobalLookupTables.Sources_rev[v.Source]
					if sourceID then
						sourceValue = sourceID
					else
						sourceValue = v.Source
					end
				else
					sourceValue = 0
				end

				-- Map Reason to global lookup ID or inline string
				local reasonValue
				if type(v.Reason) == "string" and v.Reason ~= "" and v.Reason ~= "Unknown Source" then
					local reasonID = GlobalLookupTables.Reasons_rev and GlobalLookupTables.Reasons_rev[v.Reason]
					if reasonID then
						reasonValue = reasonID
					else
						reasonValue = v.Reason
					end
				else
					reasonValue = 0
				end

				-- Map Static to global lookup ID or inline string
				local staticValue
				if type(v.Static) == "string" and v.Static ~= "" and v.Static ~= false then
					local staticID = GlobalLookupTables.Statics_rev and GlobalLookupTables.Statics_rev[v.Static]
					if staticID then
						staticValue = staticID
					else
						staticValue = v.Static
					end
				else
					staticValue = 0
				end

				-- Map Name to global lookup ID or inline string
				local nameValue
				if v.Name and type(v.Name) == "string" and v.Name ~= "" then
					local nameID = GlobalLookupTables.Names_rev and GlobalLookupTables.Names_rev[v.Name]
					if nameID then
						nameValue = nameID
					else
						nameValue = v.Name
					end
				else
					nameValue = 0
				end

				-- Add Retaliation to Flags if present
				local flags = v.Flags or 0
				if v.Retaliation == true then
					flags = flags | Constants.Flags.RETALIATION
				end

				-- Build normalized array: { Flags, Source, Reason, Static, Name }
				local entry = {
					flags,
					sourceValue,
					reasonValue,
					staticValue,
					nameValue,
				}

				-- Add Timestamp only if present
				if v.Timestamp and v.Timestamp ~= 0 then
					entry[6] = v.Timestamp
				end

				-- Add Karma only if present
				if type(v.Karma) == "number" and v.Karma ~= 0 then
					local next_idx = entry[6] and 7 or 6
					entry[next_idx] = math.floor(v.Karma)
				end

				normalizedData[k] = entry
			end
		end
	end

	local encoded = serializeCompressedDatabase(normalizedData)
	if encoded then
		if Serializer.writeFile(filepath, encoded) then
			Database.State.isDirty = false
			Database.State.lastSave = os.time()
			Logger.Info("Database", "Database flushed to disk (global lookup): " .. filepath)
			local elapsed = nowSeconds() - saveStartedAt
			if elapsed >= SLOW_SAVE_WARN_SECONDS then
				Logger.Warning(
					"Database",
					string.format("[DB] Slow synchronous save detected: %.1f ms", elapsed * 1000)
				)
			end
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

	if eventName == "player_spawn" and Database.State.isDirty then
		local spawnUserID = event:GetInt("userid")
		local spawnEntity = entities.GetByUserID(spawnUserID)
		local isLocalSpawn = spawnEntity and localPlayer and spawnEntity:GetIndex() == localPlayer:GetIndex()
		if isLocalSpawn then
			Logger.Debug("Database", "[DB] Local player spawned; deferring dirty save until non-intrusive window")
		end
	end

	if eventName == "game_newmap" or eventName == "teamplay_round_start" or eventName == "round_end" then
		Logger.Debug("Database", "[DB] Session boundary event, scheduling save...")
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
		-- Never write to disk while alive; defer until death/disconnect/unload.
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
			-- Check if data is in normalized format (Version 2, 3 or 4)
			local isNormalized = decodedData._Metadata and (decodedData._Metadata.Format == "normalized" or decodedData._Metadata.Format == "global_lookup")
			local version = decodedData._Metadata and decodedData._Metadata.Version or 2

			if isNormalized then
				-- Decode normalized format back to verbose format for runtime compatibility
				local sources = (version >= 4 and GlobalLookupTables.Sources) or decodedData.Sources or {}
				local reasons = (version >= 4 and GlobalLookupTables.Reasons) or decodedData.Reasons or {}
				local statics = (version >= 4 and GlobalLookupTables.Statics) or decodedData.Statics or {}
				local names = (version >= 4 and GlobalLookupTables.Names) or decodedData.Names or {}
				local data = decodedData.Data or {}

				local expandedData = {}
				for steamID, entry in pairs(data) do
					if type(entry) == "table" and type(steamID) == "string" then
						local expanded = {}
						expanded.Flags = entry[1] or 0

						-- Decode Source: integer ID to string
						local sourceID = entry[2]
						if type(sourceID) == "number" and sourceID > 0 then
							expanded.Source = sources[sourceID] or "Unknown"
						elseif type(sourceID) == "string" then
							expanded.Source = sourceID
						else
							expanded.Source = "Unknown"
						end

						-- Decode Static: integer ID to string (Version 3: index 3)
						local staticID = entry[3]
						if type(staticID) == "number" and staticID > 0 then
							expanded.Static = statics[staticID] or false
						else
							expanded.Static = false
						end

						-- Decode Name: integer ID to string or raw string (Version 3: index 4)
						local nameValue = entry[4]
						if type(nameValue) == "number" and nameValue > 0 then
							expanded.Name = names[nameValue] or "Unknown"
						elseif type(nameValue) == "string" and nameValue ~= "" then
							expanded.Name = nameValue
						else
							expanded.Name = "Unknown"
						end

						-- Decode Reason: integer ID to string or raw string (Version 3: index 5)
						local reasonValue = entry[5]
						if type(reasonValue) == "number" and reasonValue > 0 then
							expanded.Reason = reasons[reasonValue] or "Unknown"
						elseif type(reasonValue) == "string" then
							expanded.Reason = reasonValue
						else
							expanded.Reason = "Cheater"
						end

						-- Decode Timestamp (Version 3: index 6, optional)
						-- Only set if present in file (saves runtime memory)
						if entry[6] and type(entry[6]) == "number" and entry[6] ~= 0 then
							expanded.Timestamp = entry[6]
						end

						-- Decode Karma (Version 3: index 6 or 7, optional)
						-- If Timestamp is missing, Karma is at index 6
						-- If Timestamp is present, Karma is at index 7
						if entry[6] and type(entry[6]) == "number" and entry[6] > 0 then
							-- entry[6] is Timestamp, check entry[7] for Karma
							if entry[7] then
								expanded.Karma = entry[7]
							end
						elseif entry[6] and type(entry[6]) == "number" and entry[6] < 0 then
							-- entry[6] could be negative Karma (unlikely but possible)
							expanded.Karma = entry[6]
						elseif entry[6] == nil and entry[7] then
							-- entry[6] is missing, entry[7] is Karma
							expanded.Karma = entry[7]
						elseif entry[6] == 0 and entry[7] then
							-- entry[6] is 0 (omitted Timestamp), entry[7] is Karma
							expanded.Karma = entry[7]
						end

						-- Decode Retaliation from Flags bit
						expanded.Retaliation = (expanded.Flags & Constants.Flags.RETALIATION) ~= 0
						if expanded.Retaliation then
							expanded.Flags = expanded.Flags & ~Constants.Flags.RETALIATION
						end

						expandedData[steamID] = expanded
					end
				end

				G.DataBase = expandedData
				local count = 0
				for _ in pairs(G.DataBase) do
					count = count + 1
				end
				Logger.Info("Database",
					string.format("[DB] Loaded %d entries from disk (normalized format v%d).", count, version))
			else
				-- Legacy format: use as-is
				G.DataBase = decodedData
				local count = 0
				for _ in pairs(G.DataBase) do
					count = count + 1
				end
				Logger.Info("Database", string.format("[DB] Loaded %d entries from disk (legacy format).", count))
			end
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
		local staticVal
		local isCompressed = (value[1] ~= nil and type(value[1]) == "number")
		if isCompressed then
			staticVal = value[4]
		else
			staticVal = value.Static
		end

		if type(staticVal) == "string" then
			if staticVal:find("http") or #staticVal > 25 then
				local found = false
				for pattern, id in pairs(migrationMap) do
					if staticVal:find(pattern) then
						if isCompressed then
							local globalID = GlobalLookupTables.Statics_rev and GlobalLookupTables.Statics_rev[id]
							value[4] = globalID or id
						else
							value.Static = id
						end
						found = true
						break
					end
				end

				if not found then
					if isCompressed then
						local globalID = GlobalLookupTables.Statics_rev and GlobalLookupTables.Statics_rev["Ext"]
						value[4] = globalID or "Ext"
					else
						value.Static = "Ext"
					end
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

function Database.LoadEmbeddedDatabases()
	local totalNew = 0

	for dbName, embeddedDB in pairs(EmbeddedDBs) do
		if type(embeddedDB) == "table" then
			-- Check if database uses global lookup format (has Data field, no individual lookup tables)
			local usesGlobalFormat = embeddedDB.Data ~= nil and embeddedDB.Sources == nil

			if usesGlobalFormat then
				-- New format: Data arrays reference global lookup IDs
				local added = 0
				for steamID, entry in pairs(embeddedDB.Data) do
					if type(steamID) == "string" and steamID:match("^7656119%d+$") and type(entry) == "table" then
						if not G.DataBase[steamID] then
							G.DataBase[steamID] = entry
							added = added + 1
						end
					end
				end
				totalNew = totalNew + added
				Logger.Debug("Database",
					string.format("[DB] Embedded '%s' (global format): +%d new entries", dbName, added))
			else
				-- Legacy format: individual lookup tables per file
				local added = 0
				for steamID, entry in pairs(embeddedDB) do
					if type(steamID) == "string" and steamID:match("^7656119%d+$") and type(entry) == "table" then
						if not G.DataBase[steamID] then
							G.DataBase[steamID] = {
								Name = entry.Name or "Unknown",
								Reason = entry.Reason or "Cheater",
								Source = entry.Source or "Embedded",
								Static = entry.Static or dbName,
								Flags = entry.Flags or 0,
							}
							added = added + 1
						end
					end
				end
				totalNew = totalNew + added
				Logger.Debug("Database",
					string.format("[DB] Embedded '%s' (legacy format): +%d new entries", dbName, added))
			end
		end
	end

	if totalNew > 0 then
		Database.State.isDirty = true
		Logger.Info("Database", string.format("[DB] Embedded DBs loaded: %d new entries", totalNew))
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
	Database.LoadEmbeddedDatabases()
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

function Database.PurgeFriendsAndSelf()
	if type(G.DataBase) ~= "table" then
		return 0
	end

	local purged = 0

	-- Remove local player
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer then
		local mySteamID = tostring(Common.GetSteamID64(localPlayer) or "")
		if mySteamID:match("^7656119%d+$") then
			if G.DataBase[mySteamID] then
				G.DataBase[mySteamID] = nil
				purged = purged + 1
				Database.State.isDirty = true
			end
			pcall(playerlist.SetPriority, localPlayer, 0)
		end
	end

	-- Remove all Steam friends
	local ok, friends = pcall(steam.GetFriends)
	if ok and type(friends) == "table" then
		for _, steamID3 in ipairs(friends) do
			local steamID64 = Common.FromSteamid3To64(tostring(steamID3))
			if steamID64 and steamID64:match("^7656119%d+$") and G.DataBase[steamID64] then
				G.DataBase[steamID64] = nil
				purged = purged + 1
				Database.State.isDirty = true
			end
		end
	end

	if purged > 0 then
		Logger.Info("Database", string.format("[DB] Purged %d friend/self entries from database", purged))
	end

	return purged
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

	local existing = Database.GetCheater(steamID)
	local currentTime = os.time()
	local score = data.score or 0
	local incomingKarma = nil
	if type(data.Karma) == "number" then
		incomingKarma = math.floor(data.Karma)
	end
	local incomingRetaliation = nil
	if type(data.Retaliation) == "boolean" then
		incomingRetaliation = data.Retaliation
	end

	if existing then
		local scoreDelta = math.abs(score - (existing.Score or 0))
		local timeDelta = currentTime - (existing.Timestamp or 0)
		local reasonChanged = data.reason ~= existing.Reason
		local existingKarma = type(existing.Karma) == "number" and existing.Karma or 0
		local existingRetaliation = existing.Retaliation == true
		local effectiveKarma = incomingKarma
		if effectiveKarma == nil then
			effectiveKarma = existingKarma
		end
		local effectiveRetaliation = incomingRetaliation
		if effectiveRetaliation == nil then
			effectiveRetaliation = existingRetaliation
		end
		local karmaChanged = effectiveKarma ~= existingKarma
		local retaliationChanged = effectiveRetaliation ~= existingRetaliation

		if scoreDelta < 1 and timeDelta < 3600 and not reasonChanged and persistentFlags == existing.Flags and not karmaChanged and not retaliationChanged then
			return false
		end
	end

	local finalKarma = incomingKarma
	if finalKarma == nil and type(existing) == "table" and type(existing.Karma) == "number" then
		finalKarma = existing.Karma
	end
	local finalRetaliation = incomingRetaliation
	if finalRetaliation == nil and type(existing) == "table" and type(existing.Retaliation) == "boolean" then
		finalRetaliation = existing.Retaliation
	end

	-- Caller is responsible for providing data.source. Inherit from existing if not supplied.
	local finalSource = data.source
	if not finalSource and existing and type(existing.Source) == "string" then
		finalSource = existing.Source
	end

	G.DataBase[steamID] = {
		Name = data.name or "Unknown",
		Reason = data.reason or "Cheater",
		Source = finalSource,
		Flags = persistentFlags,
		Score = score,
		Timestamp = currentTime,
		Static = data.Static or false,
		Karma = finalKarma,
		Retaliation = finalRetaliation,
	}

	Database.State.isDirty = true

	return true
end

function Database.GetCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then
		return nil
	end
	local entry = G.DataBase[steamID]
	if not entry then return nil end

	-- Decode compressed entries on-the-fly
	if entry[1] ~= nil and type(entry[1]) == "number" then
		local flags = entry[1] or 0
		local sourceID = entry[2]
		local reasonID = entry[3]
		local staticID = entry[4]
		local nameID = entry[5]

		local source = type(sourceID) == "number" and GlobalLookupTables.Sources[sourceID] or sourceID or "Unknown"
		local reason = type(reasonID) == "number" and GlobalLookupTables.Reasons[reasonID] or reasonID or "Cheater"
		local static = type(staticID) == "number" and GlobalLookupTables.Statics[staticID] or staticID or false
		local name = type(nameID) == "number" and GlobalLookupTables.Names[nameID] or nameID or "Unknown"

		local ret = {
			Flags = flags,
			Source = source,
			Reason = reason,
			Static = static,
			Name = name,
		}

		if entry[6] and type(entry[6]) == "number" then
			if entry[6] > 1000 then -- Timestamp
				ret.Timestamp = entry[6]
				if entry[7] then ret.Karma = entry[7] end
			else
				ret.Karma = entry[6]
			end
		end

		local hasRetal = (flags & Constants.Flags.RETALIATION) ~= 0
		if hasRetal then
			ret.Retaliation = true
			ret.Flags = flags & ~Constants.Flags.RETALIATION
		end

		return ret
	end

	return entry
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

callbacks.Unregister("Unload", "DatabaseAutoSaveOnUnload")
callbacks.Register("Unload", "DatabaseAutoSaveOnUnload", DatabaseAutoSaveOnUnload)

-- Self-init
Database.Initialize(true)

G.Database = Database -- Global access for UI

return Database
