---@diagnostic disable: undefined-global, undefined-field
--[[ Cheater Detection - Database Fetcher - Coroutine Async Version ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Json = Common.Json
local Database = require("Cheater_Detection.Database.Database") -- For SaveDatabase
local Sources = require("Cheater_Detection.Database.Sources") -- Require Sources
local Parsers = require("Cheater_Detection.Database.Parsers") -- Require Parsers
local HttpQueue = require("Cheater_Detection.services.http_queue")
local Serializer = require("Cheater_Detection.Utils.Serializer")
local Logger = require("Cheater_Detection.Utils.Logger")

local Fetcher = {}

---- State tracking
Fetcher.State = {
	isRunning = false,
	mode = "IDLE", -- IDLE, LOCAL_SCAN, LOCAL_PARSE, ONLINE_FETCH, ONLINE_WAIT_RESPONSE, ONLINE_PARSE, WAITING, FINISH
	startTime = 0,
	results = {
		total_added = 0,
		total_updated = 0,
		errors = 0,
	},

	-- Processing state
	activeSources = {},
	sourceIdx = 0,
	localFiles = {},
	fileIdx = 0,
	playersToProcess = nil,
	rawIterator = nil, -- For incremental parsing of raw lists
	rawPendingSource = nil,
	pendingResponse = nil,
	pendingResponseReady = false,
	pendingSource = nil,
	entryIdx = 1,
	waitEndTime = 0,
	currentSourceStats = nil,
	onlineEnqueued = false,
	onlinePendingCount = 0,
	onlineResponses = {},
}

-- Bypasses GitHub blocks
local function proxyGitHubUrl(url)
	if url:match("^https://raw%.githubusercontent%.com/") then
		return url:gsub(
			"https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.*)",
			"https://cdn.jsdelivr.net/gh/%1/%2@%3/%4"
		)
	end
	return url
end

-- Returns true when frame-time budget restrictions on the fetcher can be
-- relaxed: either the local player is dead (no active gameplay to stutter)
-- or we are not connected to a game at all.
local function ShouldRelaxFrameLimits()
	local ok, localPlayer = pcall(entities.GetLocalPlayer)
	if not ok or not localPlayer then
		return true -- not in a game → safe to run freely
	end
	local aliveOk, alive = pcall(function()
		return localPlayer:IsAlive()
	end)
	return not (aliveOk and alive)
end

local function checkRequirements()
	if type(G) ~= "table" or type(G.DataBase) ~= "table" then
		return false
	end
	if type(Database) ~= "table" or type(Database.SaveDatabase) ~= "function" then
		return false
	end
	if type(Sources) ~= "table" or type(Sources.GetActiveSources) ~= "function" then
		return false
	end
	if type(Parsers) ~= "table" then
		return false
	end
	if type(HttpQueue) ~= "table" or type(HttpQueue.Enqueue) ~= "function" then
		return false
	end
	return true
end

local function onOnlineResponse(responseBody, errorMessage, source)
	local state = Fetcher.State
	if state.onlinePendingCount > 0 then
		state.onlinePendingCount = state.onlinePendingCount - 1
	end
	table.insert(state.onlineResponses, {
		source = source,
		body = responseBody,
		error = errorMessage,
	})
end

-- Logic for starting the process
function Fetcher.Start()
	if Fetcher.State.isRunning then
		return
	end
	if not checkRequirements() then
		return
	end

	Logger.Debug("Fetcher", "[FETCHER] Starting stutter-free state-machine fetch")
	Parsers.ResetStats()

	local state = Fetcher.State
	state.isRunning = true
	state.mode = "LOCAL_SCAN"
	state.startTime = globals.RealTime()
	state.results.total_added = 0
	state.results.total_updated = 0
	state.results.errors = 0
	state.activeSources = Sources.GetActiveSources()
	state.sourceIdx = 1
	state.fileIdx = 1
	state.entryIdx = 1
	state.pendingSource = nil
	state.pendingResponse = nil
	state.pendingResponseReady = false
	state.waitEndTime = 0
	state.onlineEnqueued = false
	state.onlinePendingCount = 0
	state.onlineResponses = {}
end

-- Core Tick function (called every frame from Draw/Scheduler)
function Fetcher.Tick()
	local state = Fetcher.State
	if not state.isRunning then
		return
	end

	-- Waiting state (non-blocking delay)
	if state.mode == "WAITING" then
		if globals.RealTime() >= state.waitEndTime then
			state.mode = state.nextMode or "FINISH"
		end
		return
	end

	--------------------------------------------------------
	-- STATE: LOCAL_SCAN
	--------------------------------------------------------
	if state.mode == "LOCAL_SCAN" then
		Logger.Debug("Fetcher", "[FETCHER] Scanning for local imports...")
		local importFolderName = "Lua Cheater_Detection/imports"
		if not filesystem then
			Logger.Error("Fetcher", "[FETCHER] filesystem API unavailable, skipping local scan")
			state.mode = "ONLINE_FETCH"
			return
		end

		-- Get absolute path for io.open (Standard Rule III.4)
		local _, fullImportPath = filesystem.CreateDirectory(importFolderName)
		state.fullImportPath = fullImportPath

		-- Safe Engine Access Probe
		local function SafeHas(obj, key)
			local ok, val = pcall(function()
				return obj[key]
			end)
			return ok and val ~= nil
		end

		local allFiles = nil

		-- Method 1: filesystem.Enumerate (Standard engine)
		if SafeHas(filesystem, "Enumerate") then
			local ok, result = pcall(filesystem.Enumerate, importFolderName .. "/*.*")
			if ok then
				allFiles = result
			end
		end

		-- Method 2: filesystem.List (lnxLib style)
		if not allFiles and SafeHas(filesystem, "List") then
			local ok, result = pcall(filesystem.List, importFolderName)
			if ok then
				allFiles = result
			end
		end

		-- Method 3: filesystem.EnumerateDirectory (Callback style)
		if not allFiles and SafeHas(filesystem, "EnumerateDirectory") then
			allFiles = {}
			pcall(filesystem.EnumerateDirectory, importFolderName, function(filename, attribs)
				table.insert(allFiles, filename)
			end)
		end

		if allFiles and #allFiles > 0 then
			local validFiles = {}
			for _, f in ipairs(allFiles) do
				if f:match("%.json$") or f:match("%.cfg$") or f:match("%.lua$") or f:match("%.txt$") then
					table.insert(validFiles, f)
				end
			end
			state.localFiles = validFiles
			state.fileIdx = 1
			state.mode = "LOCAL_READ"
		else
			state.mode = "ONLINE_FETCH"
		end

	--------------------------------------------------------
	-- STATE: LOCAL_READ
	--------------------------------------------------------
	elseif state.mode == "LOCAL_READ" then
		local fileName = state.localFiles[state.fileIdx]
		if not fileName then
			state.mode = "ONLINE_FETCH"
			return
		end

		-- Build absolute path for io.open
		local sep = package.config:sub(1, 1) or "/"
		local fullPath = state.fullImportPath .. sep .. fileName

		Logger.Debug("Fetcher", "[FETCHER] Reading local file: " .. fileName)

		-- Use Serializer.readFile
		local content = Serializer.readFile(fullPath)

		if content and content ~= "" then
			local players, err = nil, nil

			-- Support multiple formats
			if fileName:match("%.cfg$") or fileName:match("%.lua$") or fileName:match("%.txt$") then
				-- Try Lua loading
				local success, result = pcall(function()
					-- Try with return prepended (new format)
					local chunk = load("return " .. content)
					if chunk then
						local res = chunk()
						if res then
							return res
						end
					end

					-- Try raw load (old format)
					chunk = load(content)
					if chunk then
						return chunk()
					end
				end)
				if success and type(result) == "table" then
					players = result
				else
					err = "Failed to load Lua/CFG/TXT table"
				end
			else
				-- Attempt JSON
				players, err = Parsers.GetPlayersFromJSON(content)
			end

			-- FALLBACK: If JSON decode returned a number, it's likely a raw list of IDs
			if not players and err and err:find("returned number") then
				Logger.Debug("Fetcher", "[FETCHER] Local file appears to be raw IDs, switching to incremental raw parser")
				state.rawIterator = content:gmatch("[%w%[%]:_]+")
				state.playersToProcess = {}
				state.entryIdx = 1
				state.rawPendingSource = { name = fileName, cause = "Local Import (" .. fileName .. ")" }
				state.currentSourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
				state.mode = "RAW_INCREMENTAL"
				return
			end

			if players then
				state.playersToProcess = players
				state.entryIdx = 1
				state.currentSourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
				state.activeSource = { name = fileName, cause = "Local Import (" .. fileName .. ")" }
				state.mode = "LOCAL_PARSE"
			else
				Logger.Warning("Fetcher", "[FETCHER] Parse error in " .. fileName .. ": " .. tostring(err))
				state.fileIdx = state.fileIdx + 1
				state.mode = "LOCAL_READ"
			end
		else
			Logger.Warning("Fetcher", "[FETCHER] Failed to read or empty local file: " .. fileName)
			state.fileIdx = state.fileIdx + 1
			state.mode = "LOCAL_READ"
		end

	--------------------------------------------------------
	-- STATE: RAW_INCREMENTAL
	--------------------------------------------------------
	elseif state.mode == "RAW_INCREMENTAL" then
		local it = state.rawIterator
		local source = state.rawPendingSource
		if not it or not source then
			Logger.Error("Fetcher", "[FETCHER] RAW_INCREMENTAL state reached without iterator/source")
			state.mode = "ONLINE_FETCH"
			return
		end

		local count = 0
		-- When the local player is dead there is no gameplay to protect from
		-- frame spikes, so process the entire iterator in one go.
		local limit = ShouldRelaxFrameLimits() and math.huge or 500

		while count < limit do
			local word = it()
			if not word then
				state.mode = state.nextMode or "LOCAL_PARSE" -- Done prepping table
				state.activeSource = source
				state.rawIterator = nil
				state.rawPendingSource = nil
				state.nextMode = nil
				return
			end

			local sid64 = Parsers.GetSteamID64(word)
			if sid64 then
				if not state.playersToProcess then
					state.playersToProcess = {}
				end
				table.insert(
					state.playersToProcess,
					{ steamid = sid64, attributes = { source.name or source.cause or "Raw List" } }
				)
			end
			count = count + 1
		end

	--------------------------------------------------------
	-- STATE: LOCAL_PARSE / ONLINE_PARSE (Merged Logic)
	--------------------------------------------------------
	elseif state.mode == "LOCAL_PARSE" or state.mode == "ONLINE_PARSE" then
		local players = state.playersToProcess
		if not players then
			Logger.Error("Fetcher", "[FETCHER] playersToProcess missing in PARSE state")
			state.results.errors = state.results.errors + 1
			state.mode = "FINISH"
			return
		end
		local startIdx = state.entryIdx
		local count = 0
		-- When the local player is dead there is no active gameplay, so we can
		-- process the entire list without worrying about frame-time spikes.
		local chunkSize = ShouldRelaxFrameLimits() and math.huge or 20

		local isDirtyBefore = Database.State.isDirty
		local source = state.activeSource
		if not source then
			Logger.Error("Fetcher", "[FETCHER] activeSource missing in PARSE state")
			state.results.errors = state.results.errors + 1
			state.mode = "FINISH"
			return
		end

		-- SANITIZATION: Never allow URLs as staticID
		local sourceCause = source.cause or "Unknown Source"
		local staticID = source.sourceID or sourceCause or "Ext"
		if type(staticID) == "string" and (staticID:find("http") or #staticID > 25) then
			staticID = "Ext"
		end

		local s = state.currentSourceStats
		if not s then
			Logger.Error("Fetcher", "[FETCHER] currentSourceStats missing in PARSE state")
			state.results.errors = state.results.errors + 1
			state.mode = "FINISH"
			return
		end

		for i = startIdx, #players do
			count = count + 1
			state.entryIdx = i

			local player = players[i]
			s.processed = s.processed + 1
			if not player then
				s.errors = s.errors + 1
			else
				local added, updated, err, updName, updReason, updStatic =
					Parsers.ParseTF2BotDetector_MergeEntry(player, G.DataBase, staticID, sourceCause)

				if err then
					s.errors = s.errors + 1
				elseif added or updated then
					if added then
						s.added = s.added + 1
					end
					if updated then
						s.updated = s.updated + 1
						if updName then
							s.updName = (s.updName or 0) + 1
						end
						if updReason then
							s.updReason = (s.updReason or 0) + 1
						end
						if updStatic then
							s.updStatic = (s.updStatic or 0) + 1
						end
					end
					Database.State.isDirty = true
				else
					s.existing = s.existing + 1
				end
			end

			if count >= chunkSize then
				break
			end
		end

		if state.entryIdx >= #players then
			if not s or not source then
				Logger.Error("Fetcher", "[FETCHER] stats/source missing at PARSE end")
				state.mode = "FINISH"
				return
			end
			Parsers.AddSourceStats(
				source.name,
				s.processed,
				s.added,
				s.existing,
				s.errors,
				s.updated,
				s.updName or 0,
				s.updReason or 0,
				s.updStatic or 0
			)
			state.results.total_added = state.results.total_added + s.added
			state.results.total_updated = state.results.total_updated + s.updated
			state.results.errors = state.results.errors + s.errors

			if state.mode == "LOCAL_PARSE" then
				state.fileIdx = state.fileIdx + 1
				state.mode = "LOCAL_READ"
			else
				state.mode = "ONLINE_WAIT_RESPONSE"
			end
			state.playersToProcess = nil
		end

	--------------------------------------------------------
	-- STATE: ONLINE_FETCH
	--------------------------------------------------------
	elseif state.mode == "ONLINE_FETCH" then
		if state.onlineEnqueued then
			state.mode = "ONLINE_WAIT_RESPONSE"
			return
		end

		if not state.activeSources or #state.activeSources == 0 then
			state.mode = "FINISH"
			return
		end

		state.onlineEnqueued = true
		state.onlinePendingCount = 0
		state.onlineResponses = {}

		for _, source in ipairs(state.activeSources) do
			Logger.Debug("Fetcher", "[FETCHER] Fetching online source: " .. source.name)
			local fetchUrl = proxyGitHubUrl(source.url)
			local enqueued = HttpQueue.Enqueue(fetchUrl, onOnlineResponse, source, { noDelay = true })
			if enqueued then
				state.onlinePendingCount = state.onlinePendingCount + 1
			else
				Logger.Warning("Fetcher", "[FETCHER] Failed to queue source: " .. source.name)
				state.results.errors = state.results.errors + 1
			end
		end

		if state.onlinePendingCount <= 0 then
			state.mode = "FINISH"
			return
		end

		state.mode = "ONLINE_WAIT_RESPONSE"

	--------------------------------------------------------
	-- STATE: ONLINE_WAIT_RESPONSE
	--------------------------------------------------------
	elseif state.mode == "ONLINE_WAIT_RESPONSE" then
		if #state.onlineResponses == 0 then
			if state.onlinePendingCount <= 0 then
				state.mode = "FINISH"
			end
			return
		end

		local responsePacket = table.remove(state.onlineResponses, 1)
		local source = responsePacket and responsePacket.source or nil
		local response = responsePacket and responsePacket.body or nil
		local responseError = responsePacket and responsePacket.error or nil

		if responseError then
			Logger.Warning("Fetcher", "[FETCHER] Failed to fetch " .. (source and source.name or "unknown source"))
			state.results.errors = state.results.errors + 1
			return
		end

		if not source then
			Logger.Error("Fetcher", "[FETCHER] Missing source after HTTP response")
			state.results.errors = state.results.errors + 1
			return
		end

		if response and response ~= "" then
			-- Basic HTML check
			if response:match("<html") or response:match("<HTML") then
				Logger.Warning("Fetcher", "[FETCHER] HTML Error page from " .. source.name)
				state.results.errors = state.results.errors + 1
				return
			end

			local players, err = nil, nil

			-- Support multiple parser types (Rule III.2)
			if source.parser == "tf2db" then
				players, err = Parsers.GetPlayersFromJSON(response)
			elseif source.parser == "raw" then
				Logger.Debug("Fetcher", "[FETCHER] Online source is raw IDs, switching to incremental raw parser")
				state.rawIterator = response:gmatch("[%w%[%]:_]+")
				state.playersToProcess = {}
				state.entryIdx = 1
				state.rawPendingSource = source
				state.nextMode = "ONLINE_PARSE" -- Resume to online parse after prep
				state.currentSourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
				state.mode = "RAW_INCREMENTAL"
				return
			else
				err = "Unknown parser type: " .. tostring(source.parser)
			end

			if players then
				state.playersToProcess = players
				state.entryIdx = 1
				state.activeSource = source
				state.currentSourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
				state.mode = "ONLINE_PARSE"
			else
				Logger.Warning("Fetcher", "[FETCHER] Parse error in " .. source.name .. ": " .. tostring(err))
				state.results.errors = state.results.errors + 1
			end
		else
			Logger.Warning("Fetcher", "[FETCHER] Failed to fetch " .. source.name)
			state.results.errors = state.results.errors + 1
		end

	--------------------------------------------------------
	-- STATE: FINISH
	--------------------------------------------------------
	elseif state.mode == "FINISH" then
		Fetcher.FinishFetch()
		state.isRunning = false
		state.mode = "IDLE"
	end
end

-- Kept for internal file compatibility but refactored logic
function Fetcher.ImportLocal(isAsync)
	if isAsync then
		Fetcher.Start() -- Redirect to the safe state machine
	else
		-- Sync version only for small internal calls (unused normally now)
		Logger.Warning("Fetcher", "[FETCHER] Sync ImportLocal is deprecated. Use async.")
	end
end

function Fetcher.FinishFetch()
	local elapsedTime = globals.RealTime() - Fetcher.State.startTime
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	local results = Fetcher.State.results

	if isDebugMode then
		Logger.Debug(
			"Fetcher",
			string.format(
				"Fetch completed in %.2f seconds. Total Added: %d, Total Updated: %d, Errors: %d",
				elapsedTime,
				results.total_added,
				results.total_updated,
				results.errors
			)
		)
		Parsers.PrintStatsSummary()
	else
		printc(0, 255, 140, 255, string.format("Database entries processed: %d", Parsers.ParseStats.totalProcessed))
		printc(0, 255, 140, 255, string.format("Database entries added: %d", Parsers.ParseStats.totalAdded))
		if results.total_updated > 0 then
			printc(255, 255, 100, 255, string.format("Database entries updated: %d", results.total_updated))
		end
		if results.errors > 0 then
			printc(255, 100, 100, 255, "Errors encountered: " .. results.errors)
		end

		local count = 0
		for _ in pairs(G.DataBase) do
			count = count + 1
		end
		printc(0, 255, 140, 255, string.format("Total database entries: %d", count))
	end

	Fetcher.State.isRunning = false
	if Database.State.isDirty then
		Database.SaveDatabase()
	end
	Logger.Debug("Fetcher", "Fetch process finished")
end

function Fetcher.GetStatus()
	return { running = Fetcher.State.isRunning, mode = Fetcher.State.mode }
end

Logger.Debug("Fetcher", "[FETCHER] >>> Module execution finished. Returning Fetcher table.")
return Fetcher
