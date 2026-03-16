--[[ services/http_queue.lua
     Handles rate-limited HTTP requests to prevent API spam.
     Refactored to be robust and use the best available HTTP method.
]]

local HttpQueue = {}

local queue = {}
local isProcessing = false
local lastRequestTime = 0
local isAlive = true -- Set to false on unload to guard in-flight callbacks
local REQUEST_DELAY = 1.2 -- 1.2s delay between requests (GitHub safety)
local currentCoroutine = nil

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

--[[ Internal Coroutine Worker ]]
local function HttpWorker()
	while isAlive do
		if #queue > 0 then
			local now = globals.RealTime()
			local item = queue[1]
			local requiredDelay = REQUEST_DELAY
			if item and (item.noDelay or IsGitHubLikeURL(item.url)) then
				requiredDelay = 0
			end
			if (now - lastRequestTime) >= requiredDelay then
				item = table.remove(queue, 1)
				if item and type(item.callback) == "function" then
					isProcessing = true
					lastRequestTime = now

					local success, data = false, nil

					-- Ensure HTTP is initialized before request
					if not InitializeHTTP() then
						print("[HTTP QUEUE ERROR] http library unavailable")
						success = false
						data = "No HTTP Library"
					else
						-- http.GetAsync() fires its callback with an empty body in the current
						-- Lmaobox build (confirmed: GetAsync length=0 while Get length=24966+).
						-- Use http.Get() synchronously inside the coroutine; the coroutine yields
						-- between queue items so the main thread hitch is one request at a time.
						local syncOk, syncResult = pcall(http.Get, item.url)
						if syncOk and type(syncResult) == "string" and #syncResult > 0 then
							data = syncResult
							success = true
						else
							success = false
							data = syncOk and "http.Get() returned empty response" or tostring(syncResult)
						end
					end

					if not isAlive then
						break
					end

					if success then
						local cbStatus, cbErr = pcall(item.callback, data, nil, item.context)
						if not cbStatus then
							print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
						end
					else
						print("[HTTP QUEUE ERROR] Request failed: " .. tostring(data))
						local cbStatus, cbErr = pcall(item.callback, nil, tostring(data), item.context)
						if not cbStatus then
							print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
						end
					end

					isProcessing = false
				end
			end
		end

		::next_loop::
		coroutine.yield() -- Wait for next tick
	end
end

--[[ Public API ]]

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
	table.insert(queue, { url = url, callback = callback, context = context, noDelay = noDelay })
	return true
end

-- Main tick function to be called from the scheduler
function HttpQueue.Tick()
	if not isAlive then
		return
	end

	-- Initialize or restart coroutine if needed
	if not currentCoroutine or coroutine.status(currentCoroutine) == "dead" then
		currentCoroutine = coroutine.create(HttpWorker)
	end

	-- Resume worker
	local ok, err = coroutine.resume(currentCoroutine)
	if not ok then
		print("[HTTP QUEUE ERROR] Worker failed: " .. tostring(err))
		currentCoroutine = nil
	end
end

--[[ Cleanup ]]

callbacks.Unregister("Unload", "HttpQueue_Unload")
callbacks.Register("Unload", "HttpQueue_Unload", function()
	isAlive = false
	queue = {}
	isProcessing = false
	currentCoroutine = nil
end)

return HttpQueue
