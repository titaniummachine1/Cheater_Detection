---@diagnostic disable: undefined-global, undefined-field
--[[ Cheater Detection - Database Fetcher - Coroutine Async Version ]]
local Common = require("Cheater_Detection.Utils.Common")
-- [[ Imported by: Main.lua ]]
local G = require("Cheater_Detection.Utils.Globals")
-- [[ Imported by: None ]]
local Json = Common.Json
-- [[ Imported by: Fetcher.lua (indirectly via Common) ]]
local Database = require("Cheater_Detection.Database.Database") -- For SaveDatabase
-- [[ Imported by: Fetcher.lua ]]
local Sources = require("Cheater_Detection.Database.Sources") -- Require Sources
-- [[ Imported by: Fetcher.lua ]]
local Parsers = require("Cheater_Detection.Database.Parsers") -- Require Parsers
-- [[ Imported by: Fetcher.lua ]]

local Fetcher = {}

-- Define LogLevel locally within Fetcher
local LogLevel = {
	ERROR = 1,
	WARNING = 2,
	SUCCESS = 3,
	INFO = 4,
	DEBUG = 5,
}

-- Local Log function for Fetcher module (Defined early)
local function Log(level, message, color)
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true

	-- Determine if the message should be shown
	local shouldShow = false
	if isDebugMode then
		shouldShow = true -- Show all levels in debug mode
	elseif level <= LogLevel.SUCCESS then
		shouldShow = true -- Show ERROR, WARNING, SUCCESS in non-debug mode
	end

	if not shouldShow then
		return
	end

	local prefix = ""
	local defaultColor = { 255, 255, 255, 255 }

	if level == LogLevel.ERROR then
		prefix = "[FETCHER ERROR] "
		color = color or { 255, 100, 100, 255 } -- Red
	elseif level == LogLevel.WARNING then
		prefix = "[FETCHER WARNING] "
		color = color or { 255, 255, 100, 255 } -- Yellow
	elseif level == LogLevel.SUCCESS then
		prefix = "[FETCHER SUCCESS] "
		color = color or { 0, 255, 140, 255 } -- Bright Green
	elseif level == LogLevel.INFO then
		if not isDebugMode then
			return
		end
		prefix = "[FETCHER INFO] "
		color = color or { 100, 255, 255, 255 } -- Cyan
	elseif level == LogLevel.DEBUG then
		if not isDebugMode then
			return
		end
		prefix = "[FETCHER DEBUG] "
		color = color or { 180, 180, 180, 255 } -- Grey
	end

	color = color or defaultColor
	printc(color[1], color[2], color[3], color[4], prefix .. message)
end

---- State tracking
Fetcher.State = {
	isRunning = false,
    mode = "IDLE", -- IDLE, LOCAL_SCAN, LOCAL_PARSE, ONLINE_FETCH, ONLINE_PARSE, WAITING, FINISH
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
    entryIdx = 1,
    waitEndTime = 0,
    currentSourceStats = nil
}

-- Bypasses GitHub blocks
local function proxyGitHubUrl(url)
    if url:match("^https://raw%.githubusercontent%.com/") then
        return url:gsub("https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.*)", "https://cdn.jsdelivr.net/gh/%1/%2@%3/%4")
    end
    return url
end

local function checkRequirements()
	if type(G) ~= "table" or type(G.DataBase) ~= "table" then return false end
	if type(Database) ~= "table" or type(Database.SaveDatabase) ~= "function" then return false end
	if type(Sources) ~= "table" or type(Sources.GetActiveSources) ~= "function" then return false end
	if type(Parsers) ~= "table" then return false end
	return true
end

-- Logic for starting the process
function Fetcher.Start()
	if Fetcher.State.isRunning then return end
	if not checkRequirements() then return end

	Log(LogLevel.INFO, "[FETCHER] Starting stutter-free state-machine fetch")
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
    state.waitEndTime = 0
    Database.State.suppressFullSave = true
end

-- Core Tick function (called every frame from Draw/Scheduler)
function Fetcher.Tick()
    local state = Fetcher.State
    if not state.isRunning then return end

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
        Log(LogLevel.INFO, "[FETCHER] Scanning for local imports...")
        local importFolderName = "Lua Cheater_Detection/imports"
        assert(filesystem, "filesystem missing")
        
        -- Get absolute path for io.open (Standard Rule III.4)
        local _, fullImportPath = filesystem.CreateDirectory(importFolderName)
        state.fullImportPath = fullImportPath

        -- Safe Engine Access Probe
        local function SafeHas(obj, key)
            local ok, val = pcall(function() return obj[key] end)
            return ok and val ~= nil
        end

        local files = nil
        
        -- Method 1: filesystem.Enumerate (Standard engine)
        if SafeHas(filesystem, "Enumerate") then
            local ok, result = pcall(filesystem.Enumerate, importFolderName .. "/*.json")
            if ok then files = result end
        end

        -- Method 2: filesystem.List (lnxLib style)
        if not files and SafeHas(filesystem, "List") then
            local ok, result = pcall(filesystem.List, importFolderName)
            if ok then 
                files = {}
                for i=1, #result do
                    if result[i]:match("%.json$") then table.insert(files, result[i]) end
                end
            end
        end

        -- Method 3: filesystem.EnumerateDirectory (Callback style)
        if not files and SafeHas(filesystem, "EnumerateDirectory") then
            files = {}
            pcall(filesystem.EnumerateDirectory, importFolderName, function(filename, attribs)
                if filename:match("%.json$") then table.insert(files, filename) end
            end)
        end

        if files and #files > 0 then
            state.localFiles = files
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

        Log(LogLevel.INFO, "[FETCHER] Reading local file: " .. fileName)
        
        -- Use io.open (more reliable than filesystem.Read on some versions)
        local ok, content = pcall(function()
            local f = io.open(fullPath, "r")
            if not f then return nil end
            local txt = f:read("*a")
            f:close()
            return txt
        end)

        if ok and content and content ~= "" then
            local players, err = nil, nil
            
            -- Attempt JSON first for local imports
            players, err = Parsers.GetPlayersFromJSON(content)
            
            -- FALLBACK: If JSON decode returned a number, it's likely a raw list of IDs
            if not players and err and err:find("returned number") then
                Log(LogLevel.DEBUG, "[FETCHER] Local file appears to be raw IDs, switching to incremental raw parser")
                state.rawIterator = content:gmatch("[^\n\r]+")
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
                Log(LogLevel.WARNING, "[FETCHER] Parse error in " .. fileName .. ": " .. tostring(err))
                state.fileIdx = state.fileIdx + 1
                state.mode = "LOCAL_READ"
            end
        else
            Log(LogLevel.WARNING, "[FETCHER] Failed to read or empty local file: " .. fileName)
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
            Log(LogLevel.ERROR, "[FETCHER] RAW_INCREMENTAL state reached without iterator/source")
            state.mode = "ONLINE_FETCH"
            return
        end

        local count = 0
        local limit = 500 -- Parse 500 lines per frame (very fast)
        
        while count < limit do
            local line = it()
            if not line then
                state.mode = state.nextMode or "LOCAL_PARSE" -- Done prepping table
                state.activeSource = source
                state.rawIterator = nil
                state.rawPendingSource = nil
                state.nextMode = nil
                return
            end
            
            local sid64 = Parsers.ParseRawLine(line)
            if sid64 then
                if not state.playersToProcess then state.playersToProcess = {} end
                table.insert(state.playersToProcess, { steamid = sid64, attributes = { source.name or source.cause or "Raw List" } })
            end
            count = count + 1
        end

    --------------------------------------------------------
    -- STATE: LOCAL_PARSE / ONLINE_PARSE (Merged Logic)
    --------------------------------------------------------
    elseif state.mode == "LOCAL_PARSE" or state.mode == "ONLINE_PARSE" then
        local players = state.playersToProcess
        local startIdx = state.entryIdx
        local count = 0
        local chunkSize = 20 -- STRICT 20 entries per frame to eliminate stutters

        local isDirtyBefore = Database.State.isDirty
        local source = state.activeSource
        assert(source, "Fetcher.Tick: activeSource missing in PARSE state")
        
        -- SANITIZATION: Never allow URLs as staticID
        local staticID = source.sourceID or source.cause or "Ext"
        if type(staticID) == "string" and (staticID:find("http") or #staticID > 25) then
            staticID = "Ext"
        end

        local s = state.currentSourceStats
        assert(s, "Fetcher.Tick: currentSourceStats missing in PARSE state")

        for i = startIdx, #players do
            count = count + 1
            state.entryIdx = i
            
            local added, updated, err = Parsers.ParseTF2BotDetector_MergeEntry(players[i], G.DataBase, staticID, source.cause)
            
            s.processed = s.processed + 1
            if err then 
                s.errors = s.errors + 1
            elseif added or updated then 
                if added then s.added = s.added + 1 end
                if updated then s.updated = s.updated + 1 end
                Database.State.isDirty = true -- Ensure the DB knows it needs saving!
            else 
                s.existing = s.existing + 1 
            end

            if count >= chunkSize then break end
        end

        if Database.State.isDirty and not isDirtyBefore then
            -- Carry over dirty state to results if needed (currently global)
        end

        -- Finished this file/source?
        if state.entryIdx >= #players then
            local s = state.currentSourceStats
            assert(s and source, "Fetcher.Tick: stats/source missing at PARSE end")
            Parsers.AddSourceStats(source.name, s.processed, s.added, s.existing, s.errors, s.updated)
            state.results.total_added = state.results.total_added + s.added
            state.results.total_updated = state.results.total_updated + s.updated
            state.results.errors = state.results.errors + s.errors
            
            if state.mode == "LOCAL_PARSE" then
                state.fileIdx = state.fileIdx + 1
                state.mode = "LOCAL_READ"
            else
                state.sourceIdx = state.sourceIdx + 1
                -- Wait a bit before next fetch to allow UI to breathe and log to append
                state.mode = "WAITING"
                state.nextMode = "ONLINE_FETCH"
                state.waitEndTime = globals.RealTime() + 1.5
            end
            state.playersToProcess = nil
        end

    --------------------------------------------------------
    -- STATE: ONLINE_FETCH
    --------------------------------------------------------
    elseif state.mode == "ONLINE_FETCH" then
        local source = state.activeSources[state.sourceIdx]
        if not source then
            state.mode = "FINISH"
            return
        end

        Log(LogLevel.INFO, "[FETCHER] Fetching online source: " .. source.name)
        local fetchUrl = proxyGitHubUrl(source.url)
        local ok, response = pcall(http.Get, fetchUrl)
        
        if ok and response and response ~= "" then
            -- Basic HTML check
            if response:match("<html") or response:match("<HTML") then
                Log(LogLevel.WARNING, "[FETCHER] HTML Error page from " .. source.name)
                state.results.errors = state.results.errors + 1
                state.sourceIdx = state.sourceIdx + 1
            else
                local players, err = nil, nil
                
                -- Support multiple parser types (Rule III.2)
                if source.parser == "tf2db" then
                    players, err = Parsers.GetPlayersFromJSON(response)
                elseif source.parser == "raw" then
                    Log(LogLevel.DEBUG, "[FETCHER] Online source is raw IDs, switching to incremental raw parser")
                    state.rawIterator = response:gmatch("[^\n\r]+")
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
                    Log(LogLevel.WARNING, "[FETCHER] Parse error in " .. source.name .. ": " .. tostring(err))
                    state.results.errors = state.results.errors + 1
                    state.sourceIdx = state.sourceIdx + 1
                end
            end
        else
            Log(LogLevel.WARNING, "[FETCHER] Failed to fetch " .. source.name)
            state.results.errors = state.results.errors + 1
            state.sourceIdx = state.sourceIdx + 1
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
        Log(LogLevel.WARNING, "[FETCHER] Sync ImportLocal is deprecated. Use async.")
    end
end

function Fetcher.FinishFetch()
	local elapsedTime = globals.RealTime() - Fetcher.State.startTime
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
    local results = Fetcher.State.results

	if isDebugMode then
		Log(LogLevel.INFO, string.format("Fetch completed in %.2f seconds. Total Added: %d, Total Updated: %d, Errors: %d",
			elapsedTime, results.total_added, results.total_updated, results.errors))
		Parsers.PrintStatsSummary()
	else
		printc(0, 255, 140, 255, string.format("Database entries processed: %d", Parsers.ParseStats.totalProcessed))
		printc(0, 255, 140, 255, string.format("Database entries added: %d", Parsers.ParseStats.totalAdded))
		if results.errors > 0 then printc(255, 100, 100, 255, "Errors encountered: " .. results.errors) end
        
        local count = 0
        for _ in pairs(G.DataBase) do count = count + 1 end
		printc(0, 255, 140, 255, string.format("Total database entries: %d", count))
	end

	if Database.State.isDirty then
		Log(LogLevel.INFO, "[FETCHER] Changes detected, saving database...")
		Database.SaveDatabase()
	else
        Log(LogLevel.DEBUG, "[FETCHER] No changes detected (isDirty=false), skipping save")
	end

	local mainMenu = G and G.Menu and G.Menu.Main
	if mainMenu then mainMenu.LastFetchTimestamp = os.time() end

	Fetcher.State.isRunning = false
    Database.State.suppressFullSave = false
	Log(LogLevel.DEBUG, "Fetch process finished")
end

function Fetcher.GetStatus()
	return { running = Fetcher.State.isRunning, mode = Fetcher.State.mode }
end

Log(LogLevel.DEBUG, "[FETCHER] >>> Module execution finished. Returning Fetcher table.")
return Fetcher
