--[[
    Database Migration Script
    Converts legacy verbose database format to normalized format
    This reduces file size from ~5.5MB to ~1.3MB by eliminating string repetition
]]

local Common = require("Cheater_Detection.Utils.Common")
local Serializer = require("Cheater_Detection.Utils.Serializer")
local Logger = require("Cheater_Detection.Utils.Logger")

local function getDatabasePath()
	local _, fullPath = filesystem.CreateDirectory("Lua Cheater_Detection")
	if type(fullPath) == "string" then
		local sep = package.config:sub(1, 1) or "\\"
		return fullPath .. sep .. "database.txt"
	end
	return "Lua Cheater_Detection/database.txt"
end

local function loadLegacyDatabase()
	local filePath = getDatabasePath()
	local content = Serializer.readFile(filePath)

	if not content or #content == 0 then
		Logger.Error("Migration", "No database file found or file is empty")
		return nil
	end

	local success, decodedData = pcall(function()
		-- Try Lua load with return prepended
		local chunk, err = load("return " .. content)
		if not chunk then
			error("Lua parse error: " .. tostring(err))
		end
		local success, result = pcall(chunk)
		if not success then
			error("Lua execution error: " .. tostring(result))
		end
		if type(result) == "table" then
			return result
		end

		-- Try raw Lua load
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

		-- Fallback to JSON
		local decodedJson = Common.Json.decode(content)
		if type(decodedJson) == "table" then
			return decodedJson
		end

		error("Failed to decode content in any format.")
	end)

	if not success or type(decodedData) ~= "table" then
		Logger.Error("Migration", "Failed to load database: " .. tostring(decodedData))
		return nil
	end

	-- Check if already normalized
	if decodedData._Metadata and decodedData._Metadata.Format == "normalized" then
		Logger.Info("Migration", "Database is already in normalized format")
		return nil
	end

	return decodedData
end

local function normalizeDatabase(legacyData)
	if not legacyData then
		return nil
	end

	-- Build lookup tables for normalization
	local sourceMap = {}
	local reasonMap = {}
	local staticMap = {}
	local nameMap = {}
	local sourceNextID = 1
	local reasonNextID = 1
	local staticNextID = 1
	local nameNextID = 1

	local normalizedData = {}
	local entryCount = 0

	for steamID, v in pairs(legacyData) do
		if type(v) == "table" and type(steamID) == "string" and steamID:match("^7656119%d+$") then
			entryCount = entryCount + 1

			-- Map Source to ID
			local sourceID = 0
			if type(v.Source) == "string" and v.Source ~= "" then
				if not sourceMap[v.Source] then
					sourceMap[v.Source] = sourceNextID
					sourceNextID = sourceNextID + 1
				end
				sourceID = sourceMap[v.Source]
			end

			-- Map Reason to ID or use raw string if unique/long
			local reasonValue = 0
			if type(v.Reason) == "string" and v.Reason ~= "" and v.Reason ~= "Unknown Source" then
				-- Use raw string for unique local detections
				if #v.Reason > 40 or v.Reason:match("%d+.*tick") or v.Reason:match("%d+.*ms") then
					reasonValue = v.Reason
				else
					if not reasonMap[v.Reason] then
						reasonMap[v.Reason] = reasonNextID
						reasonNextID = reasonNextID + 1
					end
					reasonValue = reasonMap[v.Reason]
				end
			end

			-- Map Static to ID
			local staticID = 0
			if type(v.Static) == "string" and v.Static ~= "" and v.Static ~= false then
				if not staticMap[v.Static] then
					staticMap[v.Static] = staticNextID
					staticNextID = staticNextID + 1
				end
				staticID = staticMap[v.Static]
			end

			-- Map Name to ID
			local nameID = 0
			if v.Name and v.Name ~= "Unknown" and v.Name ~= tostring(steamID) then
				if not nameMap[v.Name] then
					nameMap[v.Name] = nameNextID
					nameNextID = nameNextID + 1
				end
				nameID = nameMap[v.Name]
			end

			-- Build normalized array
			local entry = {
				v.Flags or 0,
				sourceID,
				reasonValue,
				staticID,
				nameID,
				v.Timestamp or 0,
			}

			-- Add optional fields
			if v.Score and v.Score ~= 0 then
				entry[7] = v.Score
			end
			if type(v.Karma) == "number" and v.Karma > 0 then
				entry[8] = math.floor(v.Karma)
			end
			if v.Retaliation == true then
				entry[9] = 1
			end

			normalizedData[steamID] = entry
		end
	end

	-- Build reverse maps
	local sourceArray = {}
	for source, id in pairs(sourceMap) do
		sourceArray[id] = source
	end

	local reasonArray = {}
	for reason, id in pairs(reasonMap) do
		reasonArray[id] = reason
	end

	local staticArray = {}
	for static, id in pairs(staticMap) do
		staticArray[id] = static
	end

	local nameArray = {}
	for name, id in pairs(nameMap) do
		nameArray[id] = name
	end

	-- Build normalized table
	local normalizedTable = {
		_Metadata = {
			Version = 2,
			Format = "normalized",
		},
		Sources = sourceArray,
		Reasons = reasonArray,
		Statics = staticArray,
		Names = nameArray,
		Data = normalizedData,
	}

	Logger.Info("Migration", string.format("Normalized %d entries", entryCount))
	Logger.Info("Migration", string.format("Unique sources: %d, reasons: %d, statics: %d, names: %d",
		#sourceArray, #reasonArray, #staticArray, #nameArray))

	return normalizedTable
end

local function saveNormalizedDatabase(normalizedData)
	if not normalizedData then
		return false
	end

	local filepath = getDatabasePath()
	local encoded = Serializer.serializeTable(normalizedData)

	if not encoded then
		Logger.Error("Migration", "Failed to serialize normalized database")
		return false
	end

	if Serializer.writeFile(filepath, encoded) then
		Logger.Info("Migration", "Successfully saved normalized database to: " .. filepath)
		return true
	else
		Logger.Error("Migration", "Failed to write normalized database to: " .. filepath)
		return false
	end
end

local function runMigration()
	Logger.Info("Migration", "Starting database migration to normalized format...")

	local legacyData = loadLegacyDatabase()
	if not legacyData then
		Logger.Warning("Migration", "No migration needed or failed to load database")
		return
	end

	local normalizedData = normalizeDatabase(legacyData)
	if not normalizedData then
		Logger.Error("Migration", "Failed to normalize database")
		return
	end

	if saveNormalizedDatabase(normalizedData) then
		Logger.Info("Migration", "Migration completed successfully!")
		Logger.Info("Migration", "The database will now load faster and use less disk space.")
	else
		Logger.Error("Migration", "Migration failed during save")
	end
end

-- Run migration
runMigration()
