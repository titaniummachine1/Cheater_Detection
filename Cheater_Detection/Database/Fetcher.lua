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

-- Synchronous parsing wrapper (Safe-Chunking)
local function parseSourceSync(source, content)
	Log(LogLevel.INFO, string.format("[FETCHER] Parsing: %s", source.name))

	local stats = { added = 0, updated = 0, errors = 0 }
	local defaultReason = source.cause or "Unknown Source"

	local success, err = pcall(function()
		if source.parser == "raw" then
            local count = 0
			for line in content:gmatch("[^\n\r]+") do
				count = count + 1
				local steamID64 = Parsers.GetSteamID64(line)
				
				if steamID64 then
					if not G.DataBase[steamID64] then
						G.DataBase[steamID64] = {
							Name = "Unknown",
							Reason = defaultReason,
						}
						stats.added = stats.added + 1
						Database.State.isDirty = true
					end
				else
                    local trimmed = line:match("^%s*(.-)%s*$")
                    if trimmed ~= "" and not trimmed:match("^[#/-]") then
                        stats.errors = stats.errors + 1
                    end
				end

                -- Yield every 500 entries to prevent game freeze/watchdog crash
                if count % 500 == 0 then
                    coroutine.yield()
                end
			end
		elseif source.parser == "tf2db" then
			local data, parseErr = Parsers.ParseJsonTF2DB(content)
			if not data or not data.players then
				error(parseErr or "TF2DB Parser failed")
			end

			for i = 1, #data.players do
                local player = data.players[i]
				local steamID64 = Parsers.GetSteamID64(player.steamid)
				if steamID64 then
					local playerName = player.last_seen and player.last_seen.player_name or "Unknown"
					local reason = defaultReason
					if player.attributes and #player.attributes > 0 then
						reason = player.attributes[1]:gsub("^%l", string.upper)
					end

					if not G.DataBase[steamID64] then
						G.DataBase[steamID64] = {
							Name = playerName or "Unknown",
							Reason = reason,
						}
						stats.added = stats.added + 1
						Database.State.isDirty = true
					else
						local existing = G.DataBase[steamID64]
						if (existing.Name == "Unknown" or not existing.Name) and playerName ~= "Unknown" then
							existing.Name = playerName
							stats.updated = stats.updated + 1
							Database.State.isDirty = true
						end
					end
				else
					stats.errors = stats.errors + 1
				end

                -- Yield for large JSON files too
                if i % 300 == 0 then
                    coroutine.yield()
                end
			end
            data = nil
		else
			stats.errors = 1
		end
	end)

    content = nil 

	if not success then
		Log(LogLevel.WARNING, "[FETCHER] Parsing error: " .. string.sub(tostring(err), 1, 100))
		return 0, 0, 1
	end

	return stats.added, stats.updated, stats.errors
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

            if data and type(data) == "string" and #data > 2 then
                local a, u, e = parseSourceSync(source, data)
                Fetcher.State.results.total_added = Fetcher.State.results.total_added + a
                Fetcher.State.results.total_updated = Fetcher.State.results.total_updated + u
                Fetcher.State.results.errors = Fetcher.State.results.errors + e
                Parsers.AddSourceStats(source.name, 0, a, 0, e, u) 
            else
                local detail = data and ("Len: " .. #tostring(data)) or "NIL"
                if type(data) == "string" and #data > 0 then
                    detail = detail .. " | Prev: " .. string.sub(data, 1, 30):gsub("[%c%s]+", " ")
                end
                Log(LogLevel.WARNING, string.format("[FETCHER] Invalid data from %s (%s)", source.name, detail))
                Fetcher.State.results.errors = Fetcher.State.results.errors + 1
            end
            
            -- Yield one more time to let the game breathe between sources
            coroutine.yield()
        end

        Fetcher.FinishFetch()
    end)
end

local lastTick = 0

function Fetcher.Tick()
    local coro = Fetcher.State.coro
    if not coro or type(coro) ~= "thread" then return end

    local currentTick = globals.TickCount()
    if currentTick == lastTick then return end 
    lastTick = currentTick
    
    local status, err = coroutine.resume(coro)
    if not status then
        Log(LogLevel.ERROR, "[FETCHER] Coroutine error: " .. tostring(err))
        Fetcher.State.isRunning = false
        Fetcher.State.coro = nil
        return
    end

    if type(coro) == "thread" and coroutine.status(coro) == "dead" then
        local wasRunning = Fetcher.State.isRunning
        Fetcher.State.coro = nil
        if wasRunning then
            Fetcher.State.isRunning = false
            Log(LogLevel.DEBUG, "[FETCHER] Coroutine finished normally")
        end
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
