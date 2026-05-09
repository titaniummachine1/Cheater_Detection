---@diagnostic disable: undefined-global, undefined-field
--[[ Cheater Detection - Database Fetcher - Coroutine Async Version ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Json = Common.Json
local Database = require("Cheater_Detection.Database.Database") -- For SaveDatabase
local Sources = require("Cheater_Detection.Database.Sources")   -- Require Sources
local Parsers = require("Cheater_Detection.Database.Parsers")   -- Require Parsers
local HttpQueue = require("Cheater_Detection.services.http_queue")
local Serializer = require("Cheater_Detection.Utils.Serializer")
local Logger = require("Cheater_Detection.Utils.Logger")

local Fetcher = {}
-- Stability-first mode: do not hammer the same source on nil JSON payloads.
local MAX_JSON_NIL_RETRIES = 0
-- Seconds to wait between sequential online source fetches to avoid
-- hammering the HTTP subsystem when safe-window blocking requests run.
local INTER_SOURCE_DELAY = 3.0
local ONLINE_ACTIVE_FETCH_LIMIT = 1
local ONLINE_SAFE_WINDOW_FETCH_LIMIT = 20

---- State tracking
Fetcher.State = {
	isRunning = false,
	mode = "IDLE", -- IDLE, LOCAL_SCAN, LOCAL_READ, LOCAL_PARSE, ONLINE_FETCH, ONLINE_WAIT_RESPONSE, ONLINE_PARSE, WAITING, FINISH
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
	rawText = nil, -- raw response text to parse incrementally
	rawPos = 1, -- current byte position in rawText
	rawPendingSource = nil,
	pendingResponse = nil,
	pendingResponseReady = false,
	pendingSource = nil,
	entryIdx = 1,
	waitEndTime = 0,
	currentSourceStats = nil,
	onlineEnqueued = false,
	onlinePendingCount = 0,
	onlineCompletedCount = 0,
	onlineResponses = {},
	onlineNilRetryCount = {},
	lastOnlineFetchTime = 0,
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

local function buildFetchUrl(source)
	if type(source) ~= "table" then
		return nil, "invalid source"
	end
	if type(source.url) ~= "string" or source.url == "" then
		return nil, "missing source url"
	end
	-- broadcasts endpoint is public, no auth needed
	if source.parser == "broadcasts" then
		return source.url, nil
	end
	return proxyGitHubUrl(source.url), nil
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
	-- Only relax when we can positively confirm the player is dead.
	-- If the IsAlive() call itself errors, keep throttle active (assume alive).
	if not aliveOk then
		return false
	end
	return not alive
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

local function GetOnlineFetchParallelLimit()
	if HttpQueue.IsBridgeAlive() then
		return ONLINE_SAFE_WINDOW_FETCH_LIMIT
	end
	if ShouldRelaxFrameLimits() then
		return ONLINE_SAFE_WINDOW_FETCH_LIMIT
	end
	return ONLINE_ACTIVE_FETCH_LIMIT
end

local function GetOnlineFetchDispatchDelay()
	if HttpQueue.IsBridgeAlive() then
		return 0.0
	end
	if ShouldRelaxFrameLimits() then
		return 0.0
	end
	return INTER_SOURCE_DELAY
end

local function TotalOnlineSources(state)
	if type(state.activeSources) ~= "table" then
		return 0
	end
	return #state.activeSources
end

local function CompleteOnlineSource(state)
	state.onlineCompletedCount = state.onlineCompletedCount + 1
	if state.sourceIdx <= TotalOnlineSources(state) and state.onlinePendingCount < GetOnlineFetchParallelLimit() then
		state.mode = "ONLINE_FETCH"
		return
	end
	if #state.onlineResponses > 0 or state.onlinePendingCount > 0 then
		state.mode = "ONLINE_WAIT_RESPONSE"
		return
	end
	state.mode = "FINISH"
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
	state.rawText = nil
	state.rawPos = 1
	state.rawPendingSource = nil
	state.pendingResponse = nil
	state.pendingResponseReady = false
	state.waitEndTime = 0
	state.onlineEnqueued = false

	state.onlinePendingCount = 0
	state.onlineCompletedCount = 0
	state.onlineResponses = {}
	state.onlineNilRetryCount = {}
	state.lastOnlineFetchTime = 0
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
				Logger.Debug("Fetcher", "[FETCHER] Local file appears to be raw IDs, parsing incrementally")
				state.rawText = content
				state.rawPos = 1
				state.rawPendingSource = { name = fileName, cause = "Local Import (" .. fileName .. ")" }
				state.playersToProcess = {}
				state.entryIdx = 1
				state.currentSourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
				state.nextMode = "LOCAL_PARSE"
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
		-- Parses a raw SteamID64 text blob N tokens per tick using
		-- string.find + position counter (no closure / coroutine).
		--------------------------------------------------------
	elseif state.mode == "RAW_INCREMENTAL" then
		local rawText = state.rawText
		local source = state.rawPendingSource
		assert(rawText, "RAW_INCREMENTAL: rawText missing")
		assert(source, "RAW_INCREMENTAL: rawPendingSource missing")

		local TOKENS_PER_TICK = ShouldRelaxFrameLimits() and 5000 or 500
		local pos = state.rawPos
		local count = 0
		local len = #rawText
		local label = source.name or source.cause or "Raw List"

		while count < TOKENS_PER_TICK and pos <= len do
			local s, e = rawText:find("[%w%[%]%:_]+", pos)
			if not s then
				pos = len + 1
				break
			end
			local word = rawText:sub(s, e)
			pos = e + 1
			count = count + 1
			local sid64 = Parsers.GetSteamID64(word)
			if sid64 then
				table.insert(state.playersToProcess, { steamid = sid64, attributes = { label } })
			end
		end

		state.rawPos = pos

		if pos > len then
			-- Done — hand off to parse state
			state.activeSource = source
			state.entryIdx = 1
			state.rawText = nil
			state.rawPendingSource = nil
			state.mode = state.nextMode or "LOCAL_PARSE"
			state.nextMode = nil
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
			-- Advance entryIdx to the next entry to process so that on the
			-- following tick we resume from here, not re-process entry i.
			state.entryIdx = i + 1

			local player = players[i]
			s.processed = s.processed + 1
			if not player then
				s.errors = s.errors + 1
			else
				local added, updated, err, updName, updReason, updStatic =
					Parsers.ParseTF2BotDetector_MergeEntry(player, G.DataBase, staticID, sourceCause, source.name)

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

		if state.entryIdx > #players then
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

			Logger.Debug(
				"Fetcher",
				string.format(
					"[FETCHER] Source done: %s processed=%d added=%d updated=%d existing=%d errors=%d",
					tostring(source.name),
					s.processed,
					s.added,
					s.updated,
					s.existing,
					s.errors
				)
			)

			if state.mode == "LOCAL_PARSE" then
				state.fileIdx = state.fileIdx + 1
				state.mode = "LOCAL_READ"
			else
				CompleteOnlineSource(state)
			end
			state.playersToProcess = nil
		end

		--------------------------------------------------------
		-- STATE: ONLINE_FETCH
		--------------------------------------------------------
	elseif state.mode == "ONLINE_FETCH" then
		if not state.activeSources or #state.activeSources == 0 then
			state.mode = "FINISH"
			return
		end

		if state.sourceIdx > #state.activeSources then
			if #state.onlineResponses > 0 or state.onlinePendingCount > 0 then
				state.mode = "ONLINE_WAIT_RESPONSE"
			else
				state.mode = "FINISH"
			end
			return
		end

		-- Keep the live-game path serial, but allow safe windows to fill the
		-- bridge queue with multiple source fetches at once.
		local now = globals.RealTime()
		local dispatchDelay = GetOnlineFetchDispatchDelay()
		if dispatchDelay > 0 and (now - state.lastOnlineFetchTime) < dispatchDelay then
			return
		end

		local parallelLimit = GetOnlineFetchParallelLimit()
		while state.sourceIdx <= #state.activeSources and state.onlinePendingCount < parallelLimit do
			local source = state.activeSources[state.sourceIdx]
			if type(source) ~= "table" then
				Logger.Warning("Fetcher", "[FETCHER] Invalid source at index " .. tostring(state.sourceIdx))
				state.results.errors = state.results.errors + 1
				state.sourceIdx = state.sourceIdx + 1
				state.onlineCompletedCount = state.onlineCompletedCount + 1
			else
				local fetchUrl, fetchErr = buildFetchUrl(source)
				if not fetchUrl then
					Logger.Warning("Fetcher", "[FETCHER] Skipping source " .. source.name .. ": " .. tostring(fetchErr))
					state.sourceIdx = state.sourceIdx + 1
					state.onlineCompletedCount = state.onlineCompletedCount + 1
				else
					local enqueued = HttpQueue.Enqueue(fetchUrl, onOnlineResponse, source, { noDelay = true })
					if not enqueued then
						-- Strict queue mode can reject while another module is using HTTP.
						-- Stay on ONLINE_FETCH and retry this same source next tick.
						break
					end

					Logger.Debug("Fetcher", "[FETCHER] Fetching online source: " .. source.name)
					state.lastOnlineFetchTime = globals.RealTime()
					state.onlinePendingCount = state.onlinePendingCount + 1
					state.sourceIdx = state.sourceIdx + 1
					if dispatchDelay > 0 then
						break
					end
				end
			end
		end

		if #state.onlineResponses > 0 or state.onlinePendingCount > 0 then
			state.mode = "ONLINE_WAIT_RESPONSE"
			return
		end

		if state.sourceIdx > #state.activeSources then
			state.mode = "FINISH"
		end

		--------------------------------------------------------
		-- STATE: ONLINE_WAIT_RESPONSE
		--------------------------------------------------------
	elseif state.mode == "ONLINE_WAIT_RESPONSE" then
		if #state.onlineResponses == 0 then
			if state.sourceIdx <= #state.activeSources and state.onlinePendingCount < GetOnlineFetchParallelLimit() then
				state.mode = "ONLINE_FETCH"
				return
			end
			if state.onlinePendingCount == 0 and state.onlineCompletedCount >= TotalOnlineSources(state) then
				state.mode = "FINISH"
			end
			return
		end

		local responsePacket = table.remove(state.onlineResponses, 1)
		local source = responsePacket and responsePacket.source or nil
		local response = responsePacket and responsePacket.body or nil
		local responseError = responsePacket and responsePacket.error or nil
		local sourceName = (type(source) == "table" and source.name) or tostring(source)

		if type(source) ~= "table" then
			Logger.Warning("Fetcher", "[FETCHER] Invalid source context from HTTP queue: " .. sourceName)
			state.results.errors = state.results.errors + 1
			CompleteOnlineSource(state)
			return
		end

		if responseError then
			Logger.Warning("Fetcher", "[FETCHER] Failed to fetch " .. sourceName .. ": " .. tostring(responseError))
			state.results.errors = state.results.errors + 1
			CompleteOnlineSource(state)
			return
		end

		if not source then
			Logger.Error("Fetcher", "[FETCHER] Missing source after HTTP response")
			state.results.errors = state.results.errors + 1
			CompleteOnlineSource(state)
			return
		end

		if response and response ~= "" then
			-- Basic HTML check
			if response:match("<html") or response:match("<HTML") then
				Logger.Warning("Fetcher", "[FETCHER] HTML Error page from " .. sourceName)
				state.results.errors = state.results.errors + 1
				CompleteOnlineSource(state)
				return
			end

			local players, err = nil, nil

			-- Support multiple parser types (Rule III.2)
			if source.parser == "tf2db" then
				players, err = Parsers.GetPlayersFromJSON(response)
			elseif source.parser == "ill5db" then
				players, err = Parsers.GetPlayersFromIll5DB(response, source.cause)
			elseif source.parser == "broadcasts" then
				players, err = Parsers.GetPlayersFromBroadcasts(response, source.cause)
			elseif source.parser == "raw" then
				Logger.Debug("Fetcher", "[FETCHER] Online source is raw IDs, parsing incrementally")
				state.rawText = response
				state.rawPos = 1
				state.rawPendingSource = source
				state.playersToProcess = {}
				state.entryIdx = 1
				state.currentSourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
				state.nextMode = "ONLINE_PARSE"
				state.mode = "RAW_INCREMENTAL"
				return
			else
				err = "Unknown parser type: " .. tostring(source.parser)
			end

			if players then
				state.onlineNilRetryCount[sourceName] = 0
				state.playersToProcess = players
				state.entryIdx = 1
				state.activeSource = source
				state.currentSourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
				state.mode = "ONLINE_PARSE"
			else
				local errText = tostring(err)
				if errText:find("JSON decode returned nil", 1, true) then
					local retryCount = (state.onlineNilRetryCount[sourceName] or 0) + 1
					state.onlineNilRetryCount[sourceName] = retryCount

					if retryCount <= MAX_JSON_NIL_RETRIES then
						local fetchUrl, fetchErr = buildFetchUrl(source)
						if not fetchUrl then
							Logger.Warning("Fetcher",
								"[FETCHER] Retry skipped for " .. sourceName .. ": " .. tostring(fetchErr))
							state.results.errors = state.results.errors + 1
							CompleteOnlineSource(state)
							return
						end
						local reEnqueued = HttpQueue.Enqueue(fetchUrl, onOnlineResponse, source, { noDelay = true })
						if reEnqueued then
							state.onlinePendingCount = state.onlinePendingCount + 1
							Logger.Debug(
								"Fetcher",
								string.format(
									"[FETCHER] %s parse returned nil, retrying async fetch (%d/%d)",
									sourceName,
									retryCount,
									MAX_JSON_NIL_RETRIES
								)
							)
						else
							Logger.Warning("Fetcher", "[FETCHER] Retry enqueue failed for " .. sourceName)
							state.results.errors = state.results.errors + 1
							CompleteOnlineSource(state)
						end
					else
						Logger.Warning(
							"Fetcher",
							string.format(
								"[FETCHER] Parse error in %s after %d retries: %s -- source skipped for stability",
								sourceName,
								retryCount - 1,
								errText
							)
						)
						state.results.errors = state.results.errors + 1
						CompleteOnlineSource(state)
					end
				else
					Logger.Warning("Fetcher", "[FETCHER] Parse error in " .. sourceName .. ": " .. errText)
					state.results.errors = state.results.errors + 1
					CompleteOnlineSource(state)
				end
			end
		else
			Logger.Warning("Fetcher", "[FETCHER] Failed to fetch " .. sourceName .. " (empty response)")
			state.results.errors = state.results.errors + 1
			CompleteOnlineSource(state)
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

	-- Always show high-level summary to user
	printc(0, 255, 140, 255, string.format("Database entries processed: %d", Parsers.ParseStats.totalProcessed))
	printc(0, 255, 140, 255, string.format("Database entries added: %d", Parsers.ParseStats.totalAdded))
	if results.total_updated > 0 then
		printc(255, 255, 100, 255, string.format("Database entries updated: %d", results.total_updated))
	end
	if results.errors > 0 then
		printc(255, 100, 100, 255, "Errors encountered: " .. results.errors)
	end

	local dbCount = 0
	for _ in pairs(G.DataBase) do
		dbCount = dbCount + 1
	end
	printc(0, 255, 140, 255, string.format("Total database entries: %d", dbCount))

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
