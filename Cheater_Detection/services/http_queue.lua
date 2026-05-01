--[[ services/http_queue.lua
     Handles rate-limited HTTP requests to prevent API spam.
     Refactored to be robust and use the best available HTTP method.
]]

local HttpQueue = {}

local queue = {}
local isProcessing = false
local lastRequestTime = 0
local isAlive = true      -- Set to false on unload to guard in-flight callbacks
local REQUEST_DELAY = 1.2 -- 1.2s delay between requests (GitHub safety)
local REQUEST_TIMEOUT = 30.0
local REQUEST_RETRY_INTERVAL = 0.25
local STRICT_SINGLE_FLIGHT = true
local activeToken = 0
local activeDeadline = 0
local activeItem = nil
local activeNextRetry = 0
local activeLastError = ""
local activeAttemptCount = 0
local activeAttemptInFlight = false

local function IsGitHubLikeURL(url)
	if type(url) ~= "string" then
		return false
	end
	if url:find("raw%.githubusercontent%.com") then
		return true
	end
	if url:find("cdn%.jsdelivr%.net/gh/") then
		return true
	end
	return false
end

-- Try to ensure http library is available
local function InitializeHTTP()
	-- 1. Check global http (highest priority)
	if http and (type(http) == "userdata" or type(http) == "table") then
		return true
	end

	-- 2. Try to require "http"
	local status, lib = pcall(require, "http")
	if status and (type(lib) == "userdata" or type(lib) == "table") then
		http = lib
		return true
	end

	-- 3. Check if it's in Common fallback
	local commonStatus, Common = pcall(require, "Cheater_Detection.Utils.Common")
	if commonStatus and Common and Common.http then
		http = Common.http
		return true
	end

	return false
end

-- Force initialization on module load
InitializeHTTP()

local function ProcessNextRequest()
	if isProcessing or #queue == 0 then
		return
	end

	local now = globals.RealTime()
	local item = queue[1]
	local requiredDelay = REQUEST_DELAY
	if item and (item.noDelay or IsGitHubLikeURL(item.url)) then
		requiredDelay = 0
	end
	if (now - lastRequestTime) < requiredDelay then
		return
	end

	item = table.remove(queue, 1)
	if not item or type(item.callback) ~= "function" then
		return
	end

	isProcessing = true
	lastRequestTime = now
	activeToken = activeToken + 1
	activeDeadline = now + REQUEST_TIMEOUT
	activeItem = item
	activeNextRetry = now
	activeLastError = ""
	activeAttemptCount = 0
	activeAttemptInFlight = false
	local myToken = activeToken

	if not InitializeHTTP() then
		local cbStatus, cbErr = pcall(item.callback, nil, "No HTTP Library", item.context)
		if not cbStatus then
			print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
		end
		isProcessing = false
		activeItem = nil
		activeAttemptInFlight = false
		return
	end

	local function dispatchAsyncAttempt()
		if activeAttemptInFlight then
			return
		end

		activeAttemptCount = activeAttemptCount + 1
		activeAttemptInFlight = true
		local asyncOk, asyncErr = pcall(function()
			http.GetAsync(item.url, function(data)
				-- Ignore stale callback from timed-out or superseded request.
				if myToken ~= activeToken then
					return
				end

				activeAttemptInFlight = false

				if type(data) == "string" and #data > 0 then
					local cbStatus, cbErr = pcall(item.callback, data, nil, item.context)
					if not cbStatus then
						print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
					end
					isProcessing = false
					activeItem = nil
					activeAttemptInFlight = false
					activeNextRetry = 0
					activeLastError = ""
					return
				end

				-- Empty payload is treated as "not ready yet" in this runtime.
				activeLastError = "GetAsync returned empty/invalid response"
				activeNextRetry = globals.RealTime() + REQUEST_RETRY_INTERVAL
			end)
		end)

		if not asyncOk then
			activeAttemptInFlight = false
			activeLastError = "GetAsync call failed: " .. tostring(asyncErr)
			activeNextRetry = globals.RealTime() + REQUEST_RETRY_INTERVAL
		end
	end

	dispatchAsyncAttempt()
end

--[[ Public API ]]

function HttpQueue.IsBusy()
	return isProcessing or activeAttemptInFlight or #queue > 0
end

function HttpQueue.Enqueue(url, callback, context, options)
	if type(callback) ~= "function" then
		print(
			"[HTTP QUEUE ERROR] Enqueue callback must be function, got: "
			.. tostring(type(callback))
			.. " url="
			.. tostring(url)
		)
		return false
	end
	local noDelay = false
	if type(options) == "table" and options.noDelay == true then
		noDelay = true
	end

	if STRICT_SINGLE_FLIGHT and HttpQueue.IsBusy() then
		return false
	end

	table.insert(queue, { url = url, callback = callback, context = context, noDelay = noDelay })
	return true
end

-- Main tick function to be called from the scheduler
function HttpQueue.Tick()
	if not isAlive then
		return
	end

	if isProcessing and activeItem and globals.RealTime() >= activeDeadline then
		local timedOutItem = activeItem
		local err = "HTTP request timed out after "
		err = err .. tostring(REQUEST_TIMEOUT) .. "s"
		if activeLastError ~= "" then
			err = err .. " (last error: " .. activeLastError .. ")"
		end
		err = err .. " attempts=" .. tostring(activeAttemptCount)
		print("[HTTP QUEUE ERROR] " .. err .. " url=" .. tostring(timedOutItem.url))
		local cbStatus, cbErr = pcall(timedOutItem.callback, nil, err, timedOutItem.context)
		if not cbStatus then
			print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
		end
		activeToken = activeToken + 1
		isProcessing = false
		activeItem = nil
		activeAttemptInFlight = false
		activeNextRetry = 0
		activeLastError = ""
		activeAttemptCount = 0
	elseif
		isProcessing
		and activeItem
		and (not activeAttemptInFlight)
		and globals.RealTime() >= activeNextRetry
	then
		-- Re-dispatch async call until we get non-empty payload or timeout.
		activeAttemptCount = activeAttemptCount + 1
		activeAttemptInFlight = true
		local myToken = activeToken
		local item = activeItem
		local asyncOk, asyncErr = pcall(function()
			http.GetAsync(item.url, function(data)
				if myToken ~= activeToken then
					return
				end
				activeAttemptInFlight = false
				if type(data) == "string" and #data > 0 then
					local cbStatus, cbErr = pcall(item.callback, data, nil, item.context)
					if not cbStatus then
						print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
					end
					isProcessing = false
					activeItem = nil
					activeAttemptInFlight = false
					activeNextRetry = 0
					activeLastError = ""
					return
				end
				activeLastError = "GetAsync returned empty/invalid response"
				activeNextRetry = globals.RealTime() + REQUEST_RETRY_INTERVAL
			end)
		end)
		if not asyncOk then
			activeAttemptInFlight = false
			activeLastError = "GetAsync call failed: " .. tostring(asyncErr)
			activeNextRetry = globals.RealTime() + REQUEST_RETRY_INTERVAL
		end
	end

	ProcessNextRequest()
end

--[[ Cleanup ]]

callbacks.Unregister("Unload", "HttpQueue_Unload")
callbacks.Register("Unload", "HttpQueue_Unload", function()
	isAlive = false
	queue = {}
	isProcessing = false
	activeItem = nil
	activeAttemptInFlight = false
	activeNextRetry = 0
	activeLastError = ""
	activeAttemptCount = 0
end)

return HttpQueue
