--[[ Cheater Detection - Database Fetcher - Synchronous Simplified Version ]]
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

local HttpQueue = require("Cheater_Detection.services.http_queue")

local Fetcher = {}

-- Define LogLevel locally within Fetcher
local LogLevel = {
	ERROR = 1,
	WARNING = 2,
	SUCCESS = 3,
	INFO = 4,
	DEBUG = 5,
}

-- Local Log function for Fetcher module
local function Log(level, message, color)
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	local shouldShow = isDebugMode or (level <= LogLevel.SUCCESS)

	if not shouldShow then return end

	local prefix = ""
	local defaultColor = { 255, 255, 255, 255 }

	if level == LogLevel.ERROR then
		prefix = "[FETCHER ERROR] "
		color = color or { 255, 100, 100, 255 }
	elseif level == LogLevel.WARNING then
		prefix = "[FETCHER WARNING] "
		color = color or { 255, 255, 100, 255 }
	elseif level == LogLevel.SUCCESS then
		prefix = "[FETCHER SUCCESS] "
		color = color or { 0, 255, 140, 255 }
	elseif level == LogLevel.INFO then
		prefix = "[FETCHER INFO] "
		color = color or { 100, 255, 255, 255 }
	elseif level == LogLevel.DEBUG then
		prefix = "[FETCHER DEBUG] "
		color = color or { 180, 180, 180, 255 }
	end

	color = color or defaultColor
	printc(color[1], color[2], color[3], color[4], prefix .. message)
end

-- State tracking
Fetcher.State = {
	isRunning = false,
	startTime = 0,
	results = {
		total_added = 0,
		total_updated = 0,
		errors = 0,
	},
    coro = nil
}

-- Async parsing wrapper
local function parseSourceAsync(source, content)
    Log(LogLevel.INFO, string.format("[FETCHER] Async Parsing: %s", source.name))
    
    -- For now, we still call the sync parsers, but since it's only one source at a time
    -- and the HTTP part is already async, it should be significantly better.
    -- If parsing still freezes, we can further subdivide Parsers.
    local added, updated, errors = select(1, pcall(function()
        if source.parser == "raw" then
            local entries, err = Parsers.ParseRawIDs(content, source.cause)
            if not entries then error(err) end
            
            local a, u = 0, 0
            for id, data in pairs(entries) do
                if not G.DataBase[id] then
                    G.DataBase[id] = data
                    a = a + 1
                    Database.State.isDirty = true
                else
                    -- Update logic (simplified)
                    local existing = G.DataBase[id]
                    if (existing.Name == "Unknown" and data.Name ~= "Unknown") then
                        existing.Name = data.Name
                        u = u + 1
                        Database.State.isDirty = true
                    end
                end
            end
            return a, u, 0
        elseif source.parser == "tf2db" then
            local _, err, stats = Parsers.ParseTF2BotDetector(content, source.cause, G.DataBase)
            if not stats then error(err) end
            return stats.added, stats.updated, stats.errors
        end
        return 0, 0, 1
    end))
    
    if type(added) ~= "number" then
        Log(LogLevel.WARNING, "[FETCHER] Parsing error: " .. tostring(updated))
        return 0, 0, 1
    end
    
    return added, updated, errors
end

-- Helper function to check if all required modules are properly loaded
local function checkRequirements()
	Log(LogLevel.DEBUG, "[FETCHER] Checking requirements...")
	if type(G) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Globals module not loaded properly")
		return false
	end
	if type(G.DataBase) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: G.DataBase is not initialized")
		return false
	end
	if type(Database) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Database module not loaded properly")
		return false
	end
	if type(Database.SaveDatabase) ~= "function" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Database.SaveDatabase function missing")
		return false
	end
	if type(Sources) ~= "table" or type(Sources.GetActiveSources) ~= "function" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Sources module not loaded properly")
		return false
	end
	if type(Parsers) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Parsers module not loaded properly")
		return false
	end
	return true
end

function Fetcher.Start()
	if Fetcher.State.isRunning then
		Log(LogLevel.WARNING, "[FETCHER] Fetch process already running")
		return
	end

	if not checkRequirements() then return end

	Parsers.ResetStats()
	Fetcher.State.isRunning = true
	Fetcher.State.startTime = globals.RealTime()
	Fetcher.State.results.total_added = 0
	Fetcher.State.results.total_updated = 0
	Fetcher.State.results.errors = 0

	local active_sources = Sources.GetActiveSources()
	Log(LogLevel.INFO, string.format("[FETCHER] Starting ASYNC fetch for %d sources", #active_sources))

    Fetcher.State.coro = coroutine.create(function()
        for i, source in ipairs(active_sources) do
            Log(LogLevel.DEBUG, string.format("[FETCHER] Enqueueing %s (%d/%d)", source.name, i, #active_sources))
            
            local data = nil
            local done = false
            
            HttpQueue.Enqueue(source.url, function(content)
                data = content
                done = true
            end)

            -- Wait for data without freezing
            while not done do
                coroutine.yield()
            end

            if data then
                local a, u, e = parseSourceAsync(source, data)
                Fetcher.State.results.total_added = Fetcher.State.results.total_added + a
                Fetcher.State.results.total_updated = Fetcher.State.results.total_updated + u
                Fetcher.State.results.errors = Fetcher.State.results.errors + e
                Parsers.AddSourceStats(source.name, 0, a, 0, e, u) -- Partial stats
            else
                Log(LogLevel.WARNING, "[FETCHER] No data received from " .. source.name)
                Fetcher.State.results.errors = Fetcher.State.results.errors + 1
            end
            
            -- Yield one more time to let the game breathe between sources
            coroutine.yield()
        end

        Fetcher.FinishFetch()
    end)
end

function Fetcher.Tick()
    if not Fetcher.State.coro then return end
    
    local ok, err = coroutine.resume(Fetcher.State.coro)
    if not ok then
        Log(LogLevel.ERROR, "[FETCHER] Coroutine error: " .. tostring(err))
        Fetcher.State.isRunning = false
        Fetcher.State.coro = nil
    elseif coroutine.status(Fetcher.State.coro) == "dead" then
        Fetcher.State.coro = nil
    end
end

function Fetcher.FinishFetch()
	local elapsedTime = globals.RealTime() - Fetcher.State.startTime
	local results = Fetcher.State.results

	Log(LogLevel.SUCCESS, string.format(
		"ASYNC Fetch completed in %.2f seconds. Total Added: %d, Total Updated: %d, Errors: %d",
		elapsedTime, results.total_added, results.total_updated, results.errors
	))

	if Database.State.isDirty then
		Log(LogLevel.INFO, "Saving changes to database...")
		Database.SaveDatabase()
	end

	local mainMenu = G and G.Menu and G.Menu.Main
	if mainMenu then
		mainMenu.LastFetchTimestamp = os.time()
	end

	Fetcher.State.isRunning = false
    Fetcher.State.coro = nil
end

function Fetcher.GetStatus()
	return {
		running = Fetcher.State.isRunning,
        progress = Fetcher.State.coro ~= nil
	}
end

-- InitializeFetcher removed (Manual fetch only)
-- local function InitializeFetcher() ... end
-- InitializeFetcher()

Log(LogLevel.DEBUG, "[FETCHER] >>> Module execution finished. Returning Fetcher table.") -- Use Log (Debug)
return Fetcher
