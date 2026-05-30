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
local ReasonWeightResolver = require("Cheater_Detection.Utils.ReasonWeightResolver")

local UNIFIED_EMBED_MODULE = "Cheater_Detection.Database.Static_Embeded_Databases.unified_embedded"

-- Fallback when unified_embedded.lua is missing or invalid (dev checkout without rebuild).
local LEGACY_EMBED_MODULES = {
	"d3fc0n6_embedded",
	"sleepy_main_embedded",
	"sleepy_ext_embedded",
	"sleepy_nullc0re_embedded",
	"tf2bd_official_embedded",
	"qfoxb_embedded",
	"joekiller_embedded",
	"megascat_embedded",
	"external_combined_embedded",
	"tfcl_combined_lua",
	"local_64ids_embedded",
	"local_k13imz_embedded",
	"local_text_embedded",
}

local EmbeddedDBs = {}
local embeddedLoadMode = "none" -- "unified" | "legacy" | "none"

local function tryRequireEmbed(modulePath)
	local ok, result = pcall(require, modulePath)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

local function resolveEmbeddedSources()
	local unified = tryRequireEmbed(UNIFIED_EMBED_MODULE)
	if unified and type(unified.Data) == "table" then
		EmbeddedDBs.unified_embedded = unified
		embeddedLoadMode = "unified"
		return
	end

	Logger.Warning("Database",
		"[DB] unified_embedded missing or invalid — falling back to per-source embed files")
	for _, moduleName in ipairs(LEGACY_EMBED_MODULES) do
		local modulePath = "Cheater_Detection.Database.Static_Embeded_Databases." .. moduleName
		local embeddedDB = tryRequireEmbed(modulePath)
		if embeddedDB then
			EmbeddedDBs[moduleName] = embeddedDB
		end
	end

	if next(EmbeddedDBs) then
		embeddedLoadMode = "legacy"
	else
		embeddedLoadMode = "none"
	end
end

resolveEmbeddedSources()

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

-- Disk-bound deltas only (embedded lists are not re-saved here)
Database.Overlay = {}
Database.EmbeddedBaseline = {}

-- Cache for decoded database entries (avoids repeated decoding of compressed entries)
local decodedCache = {}
local cacheHits = 0
local cacheMisses = 0

local HARD_PRIORITY_FLAGS = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.VALVE
local LOCAL_DEAD_SAVE_INTERVAL = 3
local MIN_NONFORCED_SAVE_INTERVAL = 20
local EFFECTIVE_DEAD_AUTOSAVE_INTERVAL = math.max(LOCAL_DEAD_SAVE_INTERVAL, MIN_NONFORCED_SAVE_INTERVAL)
local ALIVE_IDLE_SAVE_INTERVAL = 45
local SLOW_SAVE_WARN_SECONDS = 0.015

local function nowSeconds()
	if globals and type(globals.RealTime) == "function" then
		local t = globals.RealTime()
		if type(t) == "number" then
			return t
		end
	end
	return os.clock()
end

local function copyEntry(entry)
	if type(entry) ~= "table" then
		return nil
	end
	if type(entry[1]) == "number" then
		local copy = {}
		for i = 1, #entry do
			copy[i] = entry[i]
		end
		return copy
	end
	return {
		Name = entry.Name,
		Reason = entry.Reason,
		Source = entry.Source,
		Static = entry.Static,
		Flags = entry.Flags,
		Score = entry.Score,
		Timestamp = entry.Timestamp,
		Karma = entry.Karma,
		Retaliation = entry.Retaliation,
	}
end

local function getEntryFlags(entry)
	if type(entry) ~= "table" then
		return 0
	end
	if type(entry[1]) == "number" then
		return tonumber(entry[1]) or 0
	end
	return tonumber(entry.Flags) or 0
end

local BAN_FLAG_MASK = Constants.Flags.VAC_BANNED | Constants.Flags.COMM_BANNED
local DATABASE_FILE_KIND = "database"

local function getEntryKarma(entry)
	if type(entry) ~= "table" then
		return 0
	end
	if type(entry[1]) == "number" then
		local slot6 = entry[6]
		if type(slot6) == "number" then
			if slot6 > 1000 then
				return type(entry[7]) == "number" and entry[7] or 0
			end
			return slot6
		end
		return 0
	end
	return type(entry.Karma) == "number" and entry.Karma or 0
end

local function setEntryFlags(entry, flags)
	if type(entry) ~= "table" then
		return
	end
	if type(entry[1]) == "number" then
		entry[1] = flags
	else
		entry.Flags = flags
	end
end

local function getEntryRetaliation(entry)
	if type(entry) ~= "table" then
		return false
	end
	if type(entry[1]) == "number" then
		return (getEntryFlags(entry) & Constants.Flags.RETALIATION) ~= 0
	end
	return entry.Retaliation == true
end

local function setEntryKarma(entry, karma)
	if type(entry) ~= "table" or type(karma) ~= "number" or karma <= 0 then
		return
	end
	karma = math.floor(karma)
	if type(entry[1]) == "number" then
		local slot6 = entry[6]
		if type(slot6) == "number" and slot6 > 1000 then
			entry[7] = karma
		else
			entry[6] = karma
		end
		return
	end
	entry.Karma = karma
end

local function setEntryRetaliation(entry, isRetaliation)
	if type(entry) ~= "table" then
		return
	end
	if type(entry[1]) == "number" then
		local flags = getEntryFlags(entry)
		if isRetaliation then
			setEntryFlags(entry, flags | Constants.Flags.RETALIATION)
		else
			setEntryFlags(entry, flags & ~Constants.Flags.RETALIATION)
		end
		return
	end
	entry.Retaliation = isRetaliation == true
end

local function entriesEquivalent(entryA, entryB)
	if not entryA or not entryB then
		return false
	end
	if getEntryFlags(entryA) ~= getEntryFlags(entryB) then
		return false
	end
	if getEntryKarma(entryA) ~= getEntryKarma(entryB) then
		return false
	end
	if getEntryRetaliation(entryA) ~= getEntryRetaliation(entryB) then
		return false
	end
	local reasonA = Database.ResolveReason(entryA)
	local reasonB = Database.ResolveReason(entryB)
	if type(reasonA) == "string" and type(reasonB) == "string" then
		if reasonA:lower() ~= reasonB:lower() then
			return false
		end
	elseif reasonA ~= reasonB then
		return false
	end
	local staticA = Database.ResolveStatic(entryA)
	local staticB = Database.ResolveStatic(entryB)
	if type(staticA) == "string" and type(staticB) == "string" then
		if staticA:lower() ~= staticB:lower() then
			return false
		end
	elseif staticA ~= staticB then
		return false
	end
	return true
end

--- True when entry carries stronger evidence than the build-time embed row for this SteamID.
function Database.EntryBeatsBaseline(steamID, entry)
	if type(entry) ~= "table" or type(steamID) ~= "string" then
		return false
	end
	local baseline = Database.EmbeddedBaseline and Database.EmbeddedBaseline[steamID]
	if not baseline then
		return true
	end
	if entriesEquivalent(entry, baseline) then
		return false
	end
	local baseReason = Database.ResolveReason(baseline)
	local curReason = Database.ResolveReason(entry)
	local baseStatic = Database.ResolveStatic(baseline)
	local curStatic = Database.ResolveStatic(entry)
	if ReasonWeightResolver.ShouldOverrideEvidence(baseReason, curReason, baseStatic, curStatic) then
		return true
	end
	return getEntryFlags(entry) ~= getEntryFlags(baseline)
end

--- True when local database file should keep karma / retaliation not present in embed.
function Database.HasLocalDatabaseDelta(steamID, entry)
	if type(entry) ~= "table" or type(steamID) ~= "string" then
		return false
	end

	local curKarma = getEntryKarma(entry)
	local curRetaliation = getEntryRetaliation(entry)
	local baseline = Database.EmbeddedBaseline and Database.EmbeddedBaseline[steamID]
	local baseKarma = baseline and getEntryKarma(baseline) or 0
	local baseRetaliation = baseline and getEntryRetaliation(baseline) or false

	if curKarma > baseKarma then
		return true
	end
	if curRetaliation and not baseRetaliation then
		return true
	end

	if not baseline and (curKarma > 0 or curRetaliation) then
		return true
	end

	local staticID = Database.ResolveStatic(entry)
	if type(staticID) == "string" and staticID == "RetaliationKarma" and curKarma > 0 then
		return true
	end

	return false
end

local function mergeEntryIntoBaseline(baseline, steamID, entry)
	local existing = baseline[steamID]
	if not existing then
		baseline[steamID] = copyEntry(entry)
		return
	end
	local existingReason = Database.ResolveReason(existing)
	local incomingReason = Database.ResolveReason(entry)
	local existingStatic = Database.ResolveStatic(existing)
	local incomingStatic = Database.ResolveStatic(entry)
	if ReasonWeightResolver.ShouldOverrideEvidence(existingReason, incomingReason, existingStatic, incomingStatic) then
		baseline[steamID] = copyEntry(entry)
	end
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
			playerlist.SetPriority(steamID, 10)
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
		local success, err = playerlist.SetPriority(target, priority)
		if success then
			return true
		end
		Logger.ErrorFmt("Database", "[DB] SetPriority(entity/index) failed for target=%s priority=%s err=%s",
			tostring(target), tostring(priority), tostring(err))
	end

	-- Resolve to SteamID64 and try
	local steamID64
	if type(target) == "string" and #target == 17 then
		steamID64 = target
	elseif type(target) == "userdata" then
		steamID64 = Common.GetSteamID64(target)
	end

	if steamID64 then
		local success, err = playerlist.SetPriority(steamID64, priority)
		if success then
			local autoPriorityEnabled = G.Menu and G.Menu.Advanced and G.Menu.Advanced.AutoPriority == true
			if priority == 10 and autoPriorityEnabled then
				Database.UpsertCheater(steamID64, {
					name = "Manual Flag",
					reason = "Manual Priority 10",
				})
			end
			return true
		end
		Logger.ErrorFmt("Database", "[DB] SetPriority(steamID64) failed for id=%s priority=%s err=%s",
			tostring(steamID64), tostring(priority), tostring(err))
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
	"return {\n    _Metadata = {\n        Version = 5,\n        Format = \"global_lookup\",\n        Kind = \"" .. DATABASE_FILE_KIND .. "\"\n    },\n    Data = {\n"
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
	if type(Database.Overlay) ~= "table" then
		Database.Overlay = {}
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
	local entryCount = 0
	for _ in pairs(Database.Overlay) do
		entryCount = entryCount + 1
	end
	Logger.Debug("Database", string.format("[DB] Saving database (%d entries)...", entryCount))
	ReapplyDetectedPriorities()

	-- Use global lookup tables for compression
	local normalizedData = {}

	for k, v in pairs(Database.Overlay) do
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
			Logger.Info("Database", string.format("Database saved (%d entries): %s", entryCount, filepath))
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
		Logger.Debug("Database", "[DB] Session boundary event, marking dirty (save when safe)...")
		Database.State.isDirty = true
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
	if force then
		Database.State.isInitialized = false
	end
	Database.Initialize(silent)
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

local function ingestEmbeddedDBIntoBaseline(baseline, embeddedDB, dbName)
	if type(embeddedDB) ~= "table" then
		return 0
	end

	local usesGlobalFormat = embeddedDB.Data ~= nil and embeddedDB.Sources == nil
	local added = 0

	if usesGlobalFormat then
		for steamID, entry in pairs(embeddedDB.Data) do
			if type(steamID) == "string" and steamID:match("^7656119%d+$") and type(entry) == "table" then
				mergeEntryIntoBaseline(baseline, steamID, entry)
				added = added + 1
			end
		end
	else
		for steamID, entry in pairs(embeddedDB) do
			if type(steamID) == "string" and steamID:match("^7656119%d+$") and type(entry) == "table" then
				mergeEntryIntoBaseline(baseline, steamID, {
					Name = entry.Name or "Unknown",
					Reason = entry.Reason or "Cheater",
					Source = entry.Source or "Embedded",
					Static = entry.Static or dbName,
					Flags = entry.Flags or 0,
				})
				added = added + 1
			end
		end
	end

	return added
end

function Database.BuildEmbeddedBaseline()
	Database.EmbeddedBaseline = {}
	local baseline = Database.EmbeddedBaseline

	if embeddedLoadMode == "none" then
		Logger.Error("Database",
			"[DB] No embedded databases loaded — run external_sources/rebuild_embedded_databases.py")
		return
	end

	local totalIngested = 0
	if embeddedLoadMode == "unified" then
		totalIngested = ingestEmbeddedDBIntoBaseline(baseline, EmbeddedDBs.unified_embedded, "unified_embedded")
	else
		for dbName, embeddedDB in pairs(EmbeddedDBs) do
			totalIngested = totalIngested + ingestEmbeddedDBIntoBaseline(baseline, embeddedDB, dbName)
		end
	end

	local count = 0
	for _ in pairs(baseline) do
		count = count + 1
	end

	if count == 0 then
		Logger.Error("Database",
			"[DB] Embedded baseline is empty — rebuild embeds with rebuild_embedded_databases.py")
	else
		Logger.Debug("Database",
			string.format("[DB] Embedded baseline built: %d entries (%s, %d rows ingested)",
				count, embeddedLoadMode, totalIngested))
	end
end

function Database.ShouldPersistEntry(steamID, entry, options)
	if type(entry) ~= "table" or type(steamID) ~= "string" then
		return false
	end
	if Database.HasLocalDatabaseDelta(steamID, entry) then
		return true
	end
	return Database.EntryBeatsBaseline(steamID, entry)
end

--- Refresh runtime fields from live profile scans without touching overlay.
--- No-op when the player is not already in G.DataBase (no memory spent on clean unknowns).
function Database.UpdateRuntimeMemory(steamID, updates)
	if type(steamID) ~= "string" or not steamID:match("^7656119%d+$") then
		return false
	end
	if type(updates) ~= "table" or type(G.DataBase) ~= "table" then
		return false
	end

	local entry = G.DataBase[steamID]
	if not entry then
		return false
	end

	local changed = false

	if type(updates.Name) == "string" and updates.Name ~= "" and updates.Name ~= "Unknown" then
		if type(entry[1]) == "number" then
			local currentName = entry[5]
			if type(currentName) == "number" then
				currentName = GlobalLookupTables.Names[currentName]
			end
			if currentName ~= updates.Name then
				entry[5] = updates.Name
				changed = true
			end
		elseif entry.Name ~= updates.Name then
			entry.Name = updates.Name
			changed = true
		end
	end

	if changed then
		decodedCache[steamID] = nil
	end

	return changed
end

--- Merge VAC/community-ban flags into runtime DB without touching embed reason/name/static.
--- Overlay persists only when new ban flags beat the build-time embed row.
function Database.ApplyBanFlags(steamID, banFlags)
	if type(steamID) ~= "string" or not steamID:match("^7656119%d+$") then
		return false
	end
	if type(banFlags) ~= "number" then
		return false
	end

	local bitsToApply = banFlags & BAN_FLAG_MASK
	if bitsToApply == 0 then
		return false
	end

	if type(G.DataBase) ~= "table" then
		G.DataBase = {}
	end

	local existing = G.DataBase[steamID]
	if existing then
		local oldFlags = getEntryFlags(existing)
		local merged = oldFlags | bitsToApply
		if merged == oldFlags then
			return false
		end
		setEntryFlags(existing, merged)
		decodedCache[steamID] = nil
		Database.SyncOverlayEntry(steamID)
		Database.State.isDirty = true
		return true
	end

	-- New row only when a ban is found — never cache clean players.
	local reason = (bitsToApply & Constants.Flags.VAC_BANNED) ~= 0 and "VAC Ban" or "Community/Trade Ban"
	G.DataBase[steamID] = {
		Name = "Unknown",
		Reason = reason,
		Source = "SteamHistory",
		Static = "vac_ban",
		Flags = bitsToApply,
		Timestamp = os.time(),
	}
	decodedCache[steamID] = nil
	Database.SyncOverlayEntry(steamID)
	Database.State.isDirty = true
	return true
end

function Database.PruneOverlayAgainstBaseline()
	if type(Database.Overlay) ~= "table" then
		return 0
	end

	local pruned = 0
	local refreshed = 0
	for steamID, overlayEntry in pairs(Database.Overlay) do
		-- Prefer runtime evidence: overlay can lag behind G.DataBase after fetch/validation.
		local runtimeEntry = G.DataBase and G.DataBase[steamID]
		local persistEntry = runtimeEntry or overlayEntry
		if not Database.ShouldPersistEntry(steamID, persistEntry, nil) then
			Database.Overlay[steamID] = nil
			pruned = pruned + 1
			Database.State.isDirty = true
		elseif runtimeEntry and not entriesEquivalent(runtimeEntry, overlayEntry) then
			Database.SyncOverlayEntry(steamID)
			refreshed = refreshed + 1
		end
	end

	if pruned > 0 then
		Logger.Info("Database",
			string.format("[DB] Pruned %d database entries already covered by embedded baseline", pruned))
	end
	if refreshed > 0 then
		Logger.Debug("Database",
			string.format("[DB] Refreshed %d stale database entries from runtime", refreshed))
	end

	return pruned
end

function Database.SyncOverlayEntry(steamID, options)
	if type(steamID) ~= "string" or not steamID:match("^7656119%d+$") then
		return
	end
	if type(Database.Overlay) ~= "table" then
		Database.Overlay = {}
	end

	local entry = G.DataBase and G.DataBase[steamID]
	if not entry then
		if Database.Overlay[steamID] then
			Database.Overlay[steamID] = nil
			Database.State.isDirty = true
		end
		return
	end

	if Database.ShouldPersistEntry(steamID, entry, options) then
		local snapshot = copyEntry(entry)
		if not entriesEquivalent(snapshot, Database.Overlay[steamID]) then
			Database.Overlay[steamID] = snapshot
			Database.State.isDirty = true
		end
	elseif Database.Overlay[steamID] then
		Database.Overlay[steamID] = nil
		Database.State.isDirty = true
	end
end

local function mergeLocalDatabaseDeltaIntoRuntime(existing, diskEntry)
	if type(existing) ~= "table" or type(diskEntry) ~= "table" then
		return false
	end

	local changed = false
	local diskKarma = getEntryKarma(diskEntry)
	if diskKarma > getEntryKarma(existing) then
		setEntryKarma(existing, diskKarma)
		changed = true
	end
	if getEntryRetaliation(diskEntry) and not getEntryRetaliation(existing) then
		setEntryRetaliation(existing, true)
		changed = true
	end

	return changed
end

function Database.ApplyOverlayToDataBase()
	if type(Database.Overlay) ~= "table" or type(G.DataBase) ~= "table" then
		return
	end

	local applied = 0
	for steamID, entry in pairs(Database.Overlay) do
		if type(entry) == "table" and steamID:match("^7656119%d+$") then
			local existing = G.DataBase[steamID]
			if not existing then
				G.DataBase[steamID] = copyEntry(entry)
				applied = applied + 1
			else
				local existingReason = Database.ResolveReason(existing)
				local overlayReason = Database.ResolveReason(entry)
				local existingStatic = Database.ResolveStatic(existing)
				local overlayStatic = Database.ResolveStatic(entry)
				if ReasonWeightResolver.ShouldOverrideEvidence(existingReason, overlayReason, existingStatic, overlayStatic) then
					G.DataBase[steamID] = copyEntry(entry)
					applied = applied + 1
				elseif mergeLocalDatabaseDeltaIntoRuntime(existing, entry) then
					decodedCache[steamID] = nil
					applied = applied + 1
				end
			end
		end
	end

	if applied > 0 then
		Logger.Debug("Database", string.format("[DB] Database file applied to runtime: %d entries merged", applied))
	end
end

function Database.SanitizeLoadedDatabase(rewriteMetadata)
	if type(Database.Overlay) ~= "table" then
		return 0
	end

	local kept = 0
	local pruned = 0
	for steamID, entry in pairs(Database.Overlay) do
		if type(steamID) == "string" and steamID:match("^7656119%d+$") and type(entry) == "table" then
			if Database.ShouldPersistEntry(steamID, entry, nil) then
				kept = kept + 1
			else
				Database.Overlay[steamID] = nil
				pruned = pruned + 1
				Database.State.isDirty = true
			end
		else
			Database.Overlay[steamID] = nil
			pruned = pruned + 1
			Database.State.isDirty = true
		end
	end

	if pruned > 0 then
		Logger.Info("Database",
			string.format("[DB] Sanitized database file: kept %d, removed %d redundant entries", kept, pruned))
	end
	if rewriteMetadata then
		Database.State.isDirty = true
	end

	if Database.State.isDirty and (pruned > 0 or rewriteMetadata) then
		Database.SaveDatabase(true)
	end

	return pruned
end

local function decodeDatabaseFileContent(content)
	if not content or #content == 0 then
		return nil
	end

	local success, decodedData = pcall(function()
		local chunk, err = load("return " .. content)
		if not chunk then
			error("Lua parse error (prepended return): " .. tostring(err))
		end
		local ok, result = pcall(chunk)
		if not ok then
			error("Lua execution error (prepended return): " .. tostring(result))
		end
		if type(result) == "table" then
			return result
		end

		chunk, err = load(content)
		if not chunk then
			error("Lua parse error (raw): " .. tostring(err))
		end
		ok, result = pcall(chunk)
		if not ok then
			error("Lua execution error (raw): " .. tostring(result))
		end
		if type(result) == "table" then
			return result
		end

		local decodedJson = Common.Json.decode(content)
		if type(decodedJson) == "table" then
			return decodedJson
		end

		error("Failed to decode content in any format.")
	end)

	if not success or type(decodedData) ~= "table" then
		return nil, decodedData
	end
	return decodedData
end

local function extractDataTableFromDecoded(decodedData)
	if type(decodedData) ~= "table" then
		return {}
	end
	if decodedData._Metadata and decodedData.Data and type(decodedData.Data) == "table" then
		return decodedData.Data
	end
	return decodedData
end

function Database.MigrateLegacyFullToOverlay(legacyData, filePath)
	local legacyTable = extractDataTableFromDecoded(legacyData)
	local kept = 0
	local skipped = 0
	Database.Overlay = {}

	for steamID, entry in pairs(legacyTable) do
		if type(steamID) == "string" and steamID:match("^7656119%d+$") and type(entry) == "table" then
			if Database.ShouldPersistEntry(steamID, entry, nil) then
				Database.Overlay[steamID] = copyEntry(entry)
				kept = kept + 1
			else
				skipped = skipped + 1
			end
		end
	end

	Logger.Info("Database",
		string.format("[DB] Migrated legacy database: %d entries kept, %d embedded duplicates skipped",
			kept, skipped))

	if filePath and type(filePath) == "string" then
		local backupPath = filePath .. ".bak"
		local ok, err = os.rename(filePath, backupPath)
		if ok then
			Logger.Info("Database", "[DB] Legacy database backed up to: " .. backupPath)
		else
			Logger.Warning("Database", "[DB] Could not rename legacy database: " .. tostring(err))
		end
	end

	Database.State.isDirty = true
	Database.SaveDatabase(true)
end

function Database.LoadDatabaseFromDisk(silent)
	local filePath = Database.GetFilePath()
	if not silent then
		Logger.Debug("Database", "[DB] Loading database from disk...")
	end

	local content = Serializer.readFile(filePath)
	if not content then
		local luaPath = filePath:gsub("%.txt$", ".lua")
		content = Serializer.readFile(luaPath)
	end

	if not content or #content == 0 then
		Database.Overlay = {}
		return
	end

	local decodedData, decodeErr = decodeDatabaseFileContent(content)
	content = nil

	if not decodedData then
		Logger.Error("Database", "[DB] Database load failed: " .. tostring(decodeErr))
		Database.Overlay = {}
		return
	end

	local metadata = decodedData._Metadata
	local fileKind = metadata and metadata.Kind or nil
	local isPersistedDatabase = fileKind == DATABASE_FILE_KIND or fileKind == "overlay"
	local dataTable = extractDataTableFromDecoded(decodedData)

	if isPersistedDatabase then
		Database.Overlay = dataTable
		local count = 0
		for _ in pairs(Database.Overlay) do
			count = count + 1
		end
		Logger.Info("Database", string.format("[DB] Loaded database: %d entries", count))
		Database.SanitizeLoadedDatabase(fileKind == "overlay")
		return
	end

	Logger.Info("Database", "[DB] Legacy full database detected; migrating to database format...")
	Database.MigrateLegacyFullToOverlay(decodedData, filePath)
end

function Database.LoadOverlayFromDisk(silent)
	Database.LoadDatabaseFromDisk(silent)
end

function Database.LoadEmbeddedDatabases()
	if embeddedLoadMode == "none" then
		Logger.Error("Database",
			"[DB] Cannot load embedded player data — run external_sources/rebuild_embedded_databases.py")
		return
	end

	local totalNew = 0
	local totalOverridden = 0

	local function loadFromEmbeddedDB(embeddedDB, dbName)
		if type(embeddedDB) ~= "table" then
			return
		end

		local usesGlobalFormat = embeddedDB.Data ~= nil and embeddedDB.Sources == nil
		if usesGlobalFormat then
			for steamID, entry in pairs(embeddedDB.Data) do
				if type(steamID) == "string" and steamID:match("^7656119%d+$") and type(entry) == "table" then
					local existing = G.DataBase[steamID]
					if not existing then
						G.DataBase[steamID] = entry
						totalNew = totalNew + 1
					else
						local existingReason = Database.ResolveReason(existing)
						local incomingReason = Database.ResolveReason(entry)
						local existingStatic = Database.ResolveStatic(existing)
						local incomingStatic = Database.ResolveStatic(entry)
						if ReasonWeightResolver.ShouldOverrideEvidence(
							existingReason, incomingReason, existingStatic, incomingStatic) then
							G.DataBase[steamID] = entry
							totalOverridden = totalOverridden + 1
						end
					end
				end
			end
			return
		end

		for steamID, entry in pairs(embeddedDB) do
			if type(steamID) == "string" and steamID:match("^7656119%d+$") and type(entry) == "table" then
				local existing = G.DataBase[steamID]
				if not existing then
					G.DataBase[steamID] = {
						Name = entry.Name or "Unknown",
						Reason = entry.Reason or "Cheater",
						Source = entry.Source or "Embedded",
						Static = entry.Static or dbName,
						Flags = entry.Flags or 0,
					}
					totalNew = totalNew + 1
				else
					local existingReason = Database.ResolveReason(existing)
					local incomingReason = entry.Reason or "Cheater"
					local existingStatic = Database.ResolveStatic(existing)
					local incomingStatic = entry.Static or dbName
					if ReasonWeightResolver.ShouldOverrideEvidence(
						existingReason, incomingReason, existingStatic, incomingStatic) then
						G.DataBase[steamID] = {
							Name = entry.Name or existing.Name or "Unknown",
							Reason = incomingReason,
							Source = entry.Source or existing.Source or "Embedded",
							Static = entry.Static or existing.Static or dbName,
							Flags = entry.Flags or existing.Flags or 0,
						}
						totalOverridden = totalOverridden + 1
					end
				end
			end
		end
	end

	if embeddedLoadMode == "unified" then
		loadFromEmbeddedDB(EmbeddedDBs.unified_embedded, "unified_embedded")
		local count = 0
		for _ in pairs(G.DataBase) do
			count = count + 1
		end
		if count == 0 then
			Logger.Error("Database",
				"[DB] unified_embedded loaded zero entries — rebuild embeds with rebuild_embedded_databases.py")
		else
			Logger.Info("Database",
				string.format("[DB] Unified embedded loaded: %d entries (pre-merged at build time)", count))
		end
		return
	end

	for dbName, embeddedDB in pairs(EmbeddedDBs) do
		loadFromEmbeddedDB(embeddedDB, dbName)
	end

	local count = 0
	for _ in pairs(G.DataBase) do
		count = count + 1
	end

	if count == 0 then
		Logger.Error("Database",
			"[DB] Legacy embed fallback loaded zero entries — rebuild embeds with rebuild_embedded_databases.py")
	elseif totalNew > 0 or totalOverridden > 0 then
		Logger.Info("Database",
			string.format("[DB] Legacy embeds loaded: %d entries (+ %d new, %d overridden)", count, totalNew, totalOverridden))
	else
		Logger.Info("Database", string.format("[DB] Legacy embeds loaded: %d entries", count))
	end
end

--- Resolve a reason string from a database entry (handles both compressed and verbose formats)
---@param entry table
---@return string|nil
function Database.ResolveReason(entry)
	if not entry then
		return nil
	end
	-- Compressed format: entry[3] is reason ID
	if entry[1] ~= nil and type(entry[1]) == "number" then
		local reasonID = entry[3]
		if type(reasonID) == "number" then
			return GlobalLookupTables.Reasons[reasonID]
		end
		return reasonID
	end
	-- Verbose format
	return entry.Reason
end

--- Resolve a static/source ID from a database entry (handles compressed and verbose formats)
---@param entry table
---@return string|nil
function Database.ResolveStatic(entry)
	if not entry then
		return nil
	end
	-- Compressed format: entry[4] is static ID
	if entry[1] ~= nil and type(entry[1]) == "number" then
		local staticID = entry[4]
		if type(staticID) == "number" then
			return GlobalLookupTables.Statics[staticID]
		end
		return staticID
	end
	-- Verbose format
	return entry.Static
end

function Database.Initialize(silent)
	if Database.State.isInitialized then
		return
	end
	G.DataBase = {}
	Database.Overlay = {}
	decodedCache = {}
	cacheHits = 0
	cacheMisses = 0
	Database.State.isDirty = false

	Database.BuildEmbeddedBaseline()
	Database.LoadDatabaseFromDisk(silent)
	Database.LoadEmbeddedDatabases()
	Database.ApplyOverlayToDataBase()
	Database.PruneOverlayAgainstBaseline()

	local total = 0
	for _ in pairs(G.DataBase) do
		total = total + 1
	end
	Database.State.lastLoaded = os.time()
	Logger.Info("Database", string.format("[DB] Database ready: %d runtime entries", total))

	Database.SanitizeAll()
	Database.ClearLocalPlayer()
	Database.State.isInitialized = true
end

function Database.ClearLocalPlayer()
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer then
		local mySteamID = Common.GetSteamID64(localPlayer)
		if mySteamID then
			Database.SetPriority(localPlayer, 0)
			if G.DataBase[mySteamID] then
				G.DataBase[mySteamID] = nil
				Database.SyncOverlayEntry(mySteamID)
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
				Database.SyncOverlayEntry(mySteamID)
			end
			playerlist.SetPriority(localPlayer, 0)
		end
	end

	-- Remove all Steam friends
	local friends = steam.GetFriends()
	if type(friends) == "table" then
		for _, steamID3 in ipairs(friends) do
			local steamID64 = Common.FromSteamid3To64(tostring(steamID3))
			if steamID64 and steamID64:match("^7656119%d+$") and G.DataBase[steamID64] then
				G.DataBase[steamID64] = nil
				purged = purged + 1
				Database.SyncOverlayEntry(steamID64)
			end
		end
	end

	if purged > 0 then
		Logger.Info("Database", string.format("[DB] Purged %d friend/self entries from database", purged))
	end

	return purged
end

-- Runtime upsert (detectors, SteamHistory source-ban hits): updates G.DataBase always;
-- overlay/database.txt only when EntryBeatsBaseline (new evidence vs embed).
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

		-- Reason weights apply only to list/fetch merges (Parsers) and embedded DB load below.
		-- Runtime callers (detectors, Valve, SteamHistory) pass authoritative updates as-is.
		local reasonChanged = data.reason ~= nil and data.reason ~= existing.Reason

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

	local finalReason = data.reason
	if not finalReason and existing and existing.Reason then
		finalReason = existing.Reason
	end
	if not finalReason then
		finalReason = "Cheater"
	end

	local finalStatic = data.Static
	if finalStatic == nil and existing then
		finalStatic = existing.Static
	end
	if finalStatic == nil then
		finalStatic = false
	end

	G.DataBase[steamID] = {
		Name = data.name or (existing and existing.Name) or "Unknown",
		Reason = finalReason,
		Source = finalSource,
		Flags = persistentFlags,
		Score = score,
		Timestamp = currentTime,
		Static = finalStatic,
		Karma = finalKarma,
		Retaliation = finalRetaliation,
	}

	-- Overlay only when evidence beats embed; runtime memory is always updated above.
	Database.SyncOverlayEntry(steamID)

	return true
end

function Database.GetCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then
		return nil
	end

	-- Check cache first
	local cached = decodedCache[steamID]
	if cached then
		cacheHits = cacheHits + 1
		return cached
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

	-- Cache the decoded entry
	decodedCache[steamID] = entry
	cacheMisses = cacheMisses + 1

	return entry
end

function Database.RemoveCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then
		return false
	end
	if G.DataBase[steamID] then
		G.DataBase[steamID] = nil
		decodedCache[steamID] = nil
		Database.SyncOverlayEntry(steamID)
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