--[[ services/http_queue.lua
     Handles rate-limited HTTP requests to prevent API spam.
     Refactored to be robust and use the best available HTTP method.
]]

local Common = require("Cheater_Detection.Utils.Common")

local HttpQueue = {}

local Json = Common and Common.Json or nil

local queue = {}
local lastSerialDispatchTime = 0
local isAlive = true          -- Set to false on unload to guard in-flight callbacks
local REQUEST_DELAY = 1.2     -- 1.2s delay between requests (GitHub safety)
local GITHUB_REQUEST_DELAY = 1.2
local REQUEST_TIMEOUT = 120.0 -- Give enough time for a player to reach an unintrusive window
local REQUEST_RETRY_INTERVAL = 0.25
local STRICT_SINGLE_FLIGHT = false
local activeToken = 0
local activeDeadline = 0
local activeItem = nil
local activeNextRetry = 0
local activeLastError = ""
local activeAttemptCount = 0
local activeAttemptInFlight = false
local activeTransport = nil
local bridgeInFlight = {}
local bridgeInFlightCount = 0
local bridgeNextPollAt = 0

local BRIDGE_PROTOCOL = "local-http-bridge-v2"
local BRIDGE_PROTOCOL_FALLBACK = "local-http-bridge-v1"
local BRIDGE_BASE = "http://127.0.0.1:17354"
local BRIDGE_STALL_LIMIT = 0.20
local BRIDGE_REMOTE_TIMEOUT_MS = 12000
local BRIDGE_REMOTE_MAX_BYTES = 2 * 1024 * 1024
local BRIDGE_POLL_INTERVAL = 0.0
local BRIDGE_HEALTH_CHECK_INTERVAL = 10.0
local BRIDGE_STALL_PROBE_INTERVAL = 10.0 -- After a stall, retry on the normal cadence in safe windows
local SLOW_BLOCKING_HTTP_WARN_SECONDS = 0.015
local BRIDGE_ACTIVE_PARALLEL_LIMIT = 1
local BRIDGE_SAFE_WINDOW_PARALLEL_LIMIT = 20
local BRIDGE_ASYNC_PROBE_RETRY_INTERVAL = 2.0
local LOCAL_DEATH_SAFE_WINDOW_DELAY = 1.0

local bridgeState = {
	alive = false,
	protocol = nil,
	workers = 0,
	lastError = "bridge not yet probed",
	lastProbeAt = 0,
	nextProbeAt = 0,
	asyncProbeInFlight = false,
}

local lastLoggedTransportMode = "startup"
local lastLoggedBridgeAlive = false
local lastLoggedBridgeError = bridgeState.lastError
local blockingWindowState = {
	wasAlive = nil,
	deadSince = 0,
}

local FinishActiveRequest

local function Now()
	return globals.RealTime()
end

local function GetLocalPlayerEntity()
	local ok, localPlayer = pcall(entities.GetLocalPlayer)
	if not ok or not localPlayer then
		return nil
	end

	local isValidFn = localPlayer.IsValid
	if type(isValidFn) == "function" then
		local validOk, isValid = pcall(isValidFn, localPlayer)
		if not validOk or isValid ~= true then
			return nil
		end
	end

	return localPlayer
end


local function SafeEngineBoolean(methodName)
	local engineTable = engine
	if type(engineTable) ~= "table" then
		return false
	end

	local method = engineTable[methodName]
	if type(method) ~= "function" then
		return false
	end

	local ok, value = pcall(method)
	if not ok then
		return false
	end

	return value == true
end

local function GetServerIP()
	local engineTable = engine
	if type(engineTable) ~= "table" then
		return nil
	end

	local getServerIP = engineTable.GetServerIP
	if type(getServerIP) ~= "function" then
		return nil
	end

	local ok, serverIP = pcall(getServerIP)
	if not ok then
		return nil
	end

	return serverIP
end

local function ResetBlockingWindowState()
	blockingWindowState.wasAlive = nil
	blockingWindowState.deadSince = 0
end

local function CanRunBlockingHTTPNow(now)
	local currentTime = type(now) == "number" and now or Now()
	if SafeEngineBoolean("IsGameUIVisible") then
		ResetBlockingWindowState()
		return true
	end
	if SafeEngineBoolean("Con_IsVisible") then
		ResetBlockingWindowState()
		return true
	end

	local serverIP = GetServerIP()
	if serverIP == nil or serverIP == "" then
		ResetBlockingWindowState()
		return true
	end

	local localPlayer = GetLocalPlayerEntity()
	if not localPlayer then
		ResetBlockingWindowState()
		return true
	end

	local isAliveFn = localPlayer.IsAlive
	if type(isAliveFn) ~= "function" then
		ResetBlockingWindowState()
		return false
	end

	local aliveOk, alive = pcall(isAliveFn, localPlayer)
	if not aliveOk then
		ResetBlockingWindowState()
		return false
	end

	if alive == true then
		blockingWindowState.wasAlive = true
		blockingWindowState.deadSince = 0
		return false
	end

	if blockingWindowState.wasAlive ~= false then
		blockingWindowState.wasAlive = false
		blockingWindowState.deadSince = currentTime
		return false
	end

	if blockingWindowState.deadSince <= 0 then
		blockingWindowState.deadSince = currentTime
		return false
	end

	return (currentTime - blockingWindowState.deadSince) >= LOCAL_DEATH_SAFE_WINDOW_DELAY
end

local function IsLocalPlayerAliveNow()
	local localPlayer = GetLocalPlayerEntity()
	if not localPlayer then
		return false
	end

	local isAliveFn = localPlayer.IsAlive
	if type(isAliveFn) ~= "function" then
		return false
	end

	local aliveOk, alive = pcall(isAliveFn, localPlayer)
	if not aliveOk then
		return false
	end

	return alive == true
end

local function UrlEncode(value)
	if type(value) ~= "string" then
		return nil
	end
	return string.gsub(value, "([^%w%-_%.~])", function(character)
		return string.format("%%%02X", string.byte(character))
	end)
end

local function DecodeBridgePayload(body)
	if type(body) ~= "string" then
		return nil, "bridge response body is not string"
	end
	if body == "" then
		return nil, "empty response from bridge"
	end
	if type(Json) ~= "table" or type(Json.decode) ~= "function" then
		return nil, "bridge json decoder missing"
	end

	local ok, decoded = pcall(Json.decode, body)
	if not ok or type(decoded) ~= "table" then
		return nil, "invalid json from bridge"
	end

	return decoded, nil
end

local function LogTransportMode(mode, detail)
	if lastLoggedTransportMode == mode then
		return
	end
	lastLoggedTransportMode = mode
	if type(detail) == "string" and detail ~= "" then
		print(string.format("[HTTP QUEUE] transport=%s %s", mode, detail))
		return
	end
	print(string.format("[HTTP QUEUE] transport=%s", mode))
end

local function LogBridgeState(alive, detail)
	local detailText = type(detail) == "string" and detail or ""
	if lastLoggedBridgeAlive == alive and lastLoggedBridgeError == detailText then
		return
	end
	lastLoggedBridgeAlive = alive
	lastLoggedBridgeError = detailText
	if alive then
		print("[HTTP QUEUE] bridge confirmed")
		return
	end
	if detailText ~= "" then
		print(string.format("[HTTP QUEUE] bridge offline: %s", detailText))
		return
	end
	print("[HTTP QUEUE] bridge offline")
end

local function MarkBridgeOffline(errorMessage, now, stalled)
	local currentTime = type(now) == "number" and now or Now()
	bridgeState.alive = false
	bridgeState.protocol = nil
	bridgeState.workers = 0
	bridgeState.lastError = errorMessage or "bridge offline"
	bridgeState.lastProbeAt = currentTime
	-- A stall means the server is not listening at all; back off much longer to avoid
	-- repeated 2-second freezes from synchronous http.Get calls to a closed port.
	local probeInterval = stalled and BRIDGE_STALL_PROBE_INTERVAL or BRIDGE_HEALTH_CHECK_INTERVAL
	bridgeState.nextProbeAt = currentTime + probeInterval
	LogBridgeState(false, bridgeState.lastError)
end

local function MarkBridgeAlive(protocol, now, workers)
	bridgeState.alive = true
	bridgeState.protocol = protocol
	if type(workers) == "number" and workers >= 1 then
		bridgeState.workers = math.floor(workers)
	elseif bridgeState.workers < 1 then
		bridgeState.workers = BRIDGE_ACTIVE_PARALLEL_LIMIT
	end
	bridgeState.lastError = ""
	bridgeState.lastProbeAt = type(now) == "number" and now or Now()
	bridgeState.nextProbeAt = bridgeState.lastProbeAt + BRIDGE_HEALTH_CHECK_INTERVAL
	LogBridgeState(true, nil)
end

local function RefreshBridgeSafeWindowGate()
	-- Legacy no-op: bridge recovery is now allowed while alive.
end

local function DirectHttpGet(url)
	return http.Get(url)
end

local function HttpGet(url)
	local ok, bodyOrErr = pcall(DirectHttpGet, url)
	if not ok then
		return nil, tostring(bodyOrErr)
	end
	return bodyOrErr, nil
end

local function StartAsyncBridgeHealthProbe(now)
	if bridgeState.asyncProbeInFlight == true then
		return false
	end
	if type(http) ~= "table" or type(http.GetAsync) ~= "function" then
		return false
	end

	bridgeState.asyncProbeInFlight = true
	bridgeState.nextProbeAt = (type(now) == "number" and now or Now()) + BRIDGE_ASYNC_PROBE_RETRY_INTERVAL

	local function OnBridgeHealthResponse(body)
		bridgeState.asyncProbeInFlight = false
		local currentTime = Now()
		local payload, decodeErr = DecodeBridgePayload(body)
		local protocol = payload and payload.protocol or nil
		local protocolOk = protocol == BRIDGE_PROTOCOL or protocol == BRIDGE_PROTOCOL_FALLBACK
		if payload and payload.ok == true and payload.alive == true and protocolOk then
			MarkBridgeAlive(protocol, currentTime, payload.workers)
			return
		end

		local errorMessage = decodeErr
		if errorMessage == nil and payload and type(payload.error) == "string" then
			errorMessage = payload.error
		end
		MarkBridgeOffline(errorMessage or "bridge offline", currentTime, false)
	end

	local ok = pcall(http.GetAsync, BRIDGE_BASE .. "/health", OnBridgeHealthResponse)
	if not ok then
		bridgeState.asyncProbeInFlight = false
		MarkBridgeOffline("bridge async probe dispatch failed", now, false)
		return false
	end

	return true
end

local function BridgeGet(path)
	local startedAt = Now()
	local bodyOrErr, err = HttpGet(BRIDGE_BASE .. path)
	local elapsed = Now() - startedAt
	local stalled = elapsed > BRIDGE_STALL_LIMIT
	if stalled then
		return nil, string.format("bridge call stalled for %.3fs", elapsed), true
	end
	if err ~= nil then
		return nil, err, false
	end

	return bodyOrErr, nil, false
end

local function BridgeJson(path)
	local body, err, stalled = BridgeGet(path)
	if body == nil then
		return nil, err, stalled
	end

	local payload, decodeErr = DecodeBridgePayload(body)
	if payload == nil then
		return nil, decodeErr, stalled
	end

	return payload, nil, stalled
end

local function ProbeBridge(now)
	local currentTime = type(now) == "number" and now or Now()
	RefreshBridgeSafeWindowGate()
	if currentTime < bridgeState.nextProbeAt then
		return bridgeState.alive == true, bridgeState.lastError ~= "" and bridgeState.lastError or nil
	end

	local payload, err, stalled = BridgeJson("/health")
	local protocol = payload and payload.protocol or nil
	local protocolOk = protocol == BRIDGE_PROTOCOL or protocol == BRIDGE_PROTOCOL_FALLBACK
	if payload and payload.ok == true and payload.alive == true and protocolOk then
		MarkBridgeAlive(payload.protocol, currentTime, payload.workers)
		return true, nil
	end

	local errorMessage = err
	if errorMessage == nil and payload and type(payload.error) == "string" then
		errorMessage = payload.error
	end
	MarkBridgeOffline(errorMessage or "bridge offline", currentTime, stalled)
	return false, bridgeState.lastError
end

local function CanUseBridgeTransport()
	RefreshBridgeSafeWindowGate()
	if bridgeState.alive ~= true or bridgeState.lastProbeAt <= 0 then
		return false
	end
	return bridgeState.protocol == BRIDGE_PROTOCOL or bridgeState.protocol == BRIDGE_PROTOCOL_FALLBACK
end

local function StartBridgeRequest(item, now)
	local encodedUrl = UrlEncode(item.url)
	if encodedUrl == nil then
		return false, "bridge url encode failed"
	end

	local method = tostring(item.method or "GET")
	if method == "" then
		method = "GET"
	end
	method = method:upper()

	local body = tostring(item.body or "")
	local contentType = tostring(item.contentType or "")

	local timeoutMs = item.bridgeTimeoutMs or BRIDGE_REMOTE_TIMEOUT_MS
	local maxBytes = item.bridgeMaxBytes or BRIDGE_REMOTE_MAX_BYTES
	local path
	if method == "GET" and body == "" and contentType == "" then
		path = string.format(
			"/submit?url=%s&timeout_ms=%d&max_bytes=%d",
			encodedUrl,
			timeoutMs,
			maxBytes
		)
	else
		local encodedMethod = UrlEncode(method)
		if encodedMethod == nil then
			return false, "bridge method encode failed"
		end

		local encodedBody = UrlEncode(body)
		if encodedBody == nil then
			return false, "bridge body encode failed"
		end

		local encodedContentType = UrlEncode(contentType)
		if encodedContentType == nil then
			return false, "bridge content-type encode failed"
		end

		path = string.format(
			"/submit_json?url=%s&method=%s&content_type=%s&body=%s&timeout_ms=%d&max_bytes=%d",
			encodedUrl,
			encodedMethod,
			encodedContentType,
			encodedBody,
			timeoutMs,
			maxBytes
		)
	end

	local payload, err, stalled = BridgeJson(path)
	if not payload or payload.ok ~= true or type(payload.id) ~= "string" then
		local errorMessage = err
		if errorMessage == nil and payload and type(payload.error) == "string" then
			errorMessage = payload.error
		end
		MarkBridgeOffline(errorMessage or "bridge submit failed", now, stalled)
		return false, bridgeState.lastError
	end

	MarkBridgeAlive(bridgeState.protocol or BRIDGE_PROTOCOL, now, bridgeState.workers)
	LogTransportMode("bridge", nil)
	return payload.id, nil
end

local function InvokeCallback(item, responseBody, errorMessage)
	local cbStatus, cbErr = pcall(item.callback, responseBody, errorMessage, item.context)
	if not cbStatus then
		print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
	end
end


local function RegisterBridgeRequest(requestId, item, now)
	bridgeInFlight[requestId] = {
		id = requestId,
		item = item,
		deadline = now + REQUEST_TIMEOUT,
	}
	bridgeInFlightCount = bridgeInFlightCount + 1
	bridgeNextPollAt = now + BRIDGE_POLL_INTERVAL
end

local function TakeBridgeRequest(requestId)
	local job = bridgeInFlight[requestId]
	if not job then
		return nil
	end
	bridgeInFlight[requestId] = nil
	if bridgeInFlightCount > 0 then
		bridgeInFlightCount = bridgeInFlightCount - 1
	end
	if bridgeInFlightCount == 0 then
		bridgeNextPollAt = 0
	end
	return job
end

local function FinishBridgeRequest(requestId, responseBody, errorMessage)
	local job = TakeBridgeRequest(requestId)
	if not job or not job.item then
		return
	end
	InvokeCallback(job.item, responseBody, errorMessage)
end

local function GetItemMethod(item)
	local method = tostring(item and item.method or "GET")
	if method ~= "" then
		method = method:upper()
	end
	return method
end

local function ItemSupportsBlocking(item)
	local method = GetItemMethod(item)
	local body = tostring(item and item.body or "")
	return (method == "" or method == "GET") and body == ""
end

local function DrainBridgeRequestsToFallback(errorMessage)
	local fallbackItems = {}
	local failedItems = {}

	for requestId, job in pairs(bridgeInFlight) do
		bridgeInFlight[requestId] = nil
		if ItemSupportsBlocking(job and job.item) then
			fallbackItems[#fallbackItems + 1] = job.item
		else
			failedItems[#failedItems + 1] = job
		end
	end

	bridgeInFlightCount = 0
	bridgeNextPollAt = 0

	for index = #fallbackItems, 1, -1 do
		table.insert(queue, 1, fallbackItems[index])
	end

	if #fallbackItems > 0 then
		LogTransportMode("blocking", errorMessage)
	end

	for index = 1, #failedItems do
		local failedJob = failedItems[index]
		if failedJob and failedJob.item then
			InvokeCallback(failedJob.item, nil, errorMessage or "bridge transport unavailable")
		end
	end
end

local function BuildBridgeResultBatchPath(limit)
	local parts = {}
	local count = 0

	for requestId in pairs(bridgeInFlight) do
		local encodedId = UrlEncode(requestId)
		if encodedId ~= nil then
			parts[#parts + 1] = "id=" .. encodedId
			count = count + 1
		end
		if count >= limit then
			break
		end
	end

	if count == 0 then
		return nil
	end

	return "/result_batch?" .. table.concat(parts, "&")
end

local function GetBridgeParallelLimit(canRunBlocking)
	if not canRunBlocking then
		return BRIDGE_ACTIVE_PARALLEL_LIMIT
	end

	local workers = bridgeState.workers
	if type(workers) ~= "number" or workers < 1 then
		workers = BRIDGE_ACTIVE_PARALLEL_LIMIT
	end

	workers = math.floor(workers)
	if workers < BRIDGE_ACTIVE_PARALLEL_LIMIT then
		workers = BRIDGE_ACTIVE_PARALLEL_LIMIT
	end
	if workers > BRIDGE_SAFE_WINDOW_PARALLEL_LIMIT then
		workers = BRIDGE_SAFE_WINDOW_PARALLEL_LIMIT
	end

	return workers
end

local function PollBridgeResults(now, canRunBlocking)
	if bridgeInFlightCount < 1 then
		return false
	end

	local pollLimit = GetBridgeParallelLimit(canRunBlocking)
	local path = BuildBridgeResultBatchPath(pollLimit)
	if path == nil then
		return false
	end

	local payload, err, stalled = BridgeJson(path)
	if payload == nil or payload.ok ~= true or type(payload.items) ~= "table" then
		local errorMessage = err
		if errorMessage == nil and payload and type(payload.error) == "string" then
			errorMessage = payload.error
		end
		MarkBridgeOffline(errorMessage or "bridge result failed", now, stalled)
		DrainBridgeRequestsToFallback(bridgeState.lastError)
		return true
	end

	MarkBridgeAlive(bridgeState.protocol or BRIDGE_PROTOCOL, now, bridgeState.workers)

	local items = payload.items
	for index = 1, #items do
		local result = items[index]
		local requestId = type(result) == "table" and result.id or nil
		if type(requestId) == "string" and requestId ~= "" and bridgeInFlight[requestId] ~= nil then
			if result.ok ~= true then
				local errorMessage = type(result.error) == "string" and result.error or "bridge result failed"
				FinishBridgeRequest(requestId, nil, errorMessage)
			elseif result.done == true then
				if result.success == true and type(result.data) == "string" then
					FinishBridgeRequest(requestId, result.data, nil)
				else
					FinishBridgeRequest(requestId, nil, result.error or "remote request failed")
				end
			end
		end
	end

	bridgeNextPollAt = now + BRIDGE_POLL_INTERVAL
	return true
end

local function ResetActiveRequestState()
	activeItem = nil
	activeAttemptInFlight = false
	activeNextRetry = 0
	activeLastError = ""
	activeAttemptCount = 0
	activeDeadline = 0
	activeTransport = nil
end

FinishActiveRequest = function(item, responseBody, errorMessage)
	InvokeCallback(item, responseBody, errorMessage)
	ResetActiveRequestState()
end

local function DispatchBlockingAttempt()
	if activeAttemptInFlight or not activeItem then
		return
	end

	local method = tostring(activeItem.method or "GET")
	if method ~= "" then
		method = method:upper()
	end
	if method ~= "" and method ~= "GET" then
		FinishActiveRequest(activeItem, nil, "blocking transport only supports GET")
		return
	end

	if tostring(activeItem.body or "") ~= "" then
		FinishActiveRequest(activeItem, nil, "blocking transport does not support request body")
		return
	end

	if not CanRunBlockingHTTPNow(Now()) then
		return
	end

	activeAttemptCount = activeAttemptCount + 1
	activeAttemptInFlight = true
	local item = activeItem
	if IsLocalPlayerAliveNow() then
		print(
			string.format(
				"[HTTP QUEUE WARN] blocking http.Get attempted while local player alive; url=%s",
				tostring(item and item.url)
			)
		)
	end
	local startedAt = Now()
	local dataOrErr, err = HttpGet(item.url)
	local elapsed = Now() - startedAt
	activeAttemptInFlight = false
	if elapsed > SLOW_BLOCKING_HTTP_WARN_SECONDS then
		print(
			string.format(
				"[HTTP QUEUE WARN] slow blocking http.Get %.1fms url=%s",
				elapsed * 1000,
				tostring(item and item.url)
			)
		)
	end

	if err ~= nil then
		activeLastError = "Get call failed: " .. tostring(err)
		activeNextRetry = Now() + REQUEST_RETRY_INTERVAL
		return
	end

	if type(dataOrErr) == "string" and #dataOrErr > 0 then
		FinishActiveRequest(item, dataOrErr, nil)
		return
	end

	activeLastError = "Get returned empty/invalid response"
	activeNextRetry = Now() + REQUEST_RETRY_INTERVAL
end

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

local function GetRequiredDelay(item)
	local requiredDelay = REQUEST_DELAY
	if item and item.noDelay then
		requiredDelay = 0
	end
	if item and IsGitHubLikeURL(item.url) and requiredDelay < GITHUB_REQUEST_DELAY then
		requiredDelay = GITHUB_REQUEST_DELAY
	end
	return requiredDelay
end

local function TryStartBridgeRequests(now, canRunBlocking)
	if #queue == 0 then
		return false
	end

	local parallelLimit = GetBridgeParallelLimit(canRunBlocking)
	if bridgeInFlightCount >= parallelLimit then
		return false
	end

	local allowBurst = canRunBlocking == true
	local startedAny = false

	while #queue > 0 and bridgeInFlightCount < parallelLimit do
		local item = queue[1]
		if not item then
			table.remove(queue, 1)
		elseif type(item.callback) ~= "function" then
			table.remove(queue, 1)
		else
			if not allowBurst then
				local requiredDelay = GetRequiredDelay(item)
				if (now - lastSerialDispatchTime) < requiredDelay then
					return startedAny
				end
			end

			item = table.remove(queue, 1)
			local requestId, bridgeErr = StartBridgeRequest(item, now)
			if requestId then
				RegisterBridgeRequest(requestId, item, now)
				startedAny = true
				if not allowBurst then
					lastSerialDispatchTime = now
					return true
				end
			elseif not ItemSupportsBlocking(item) then
				InvokeCallback(item, nil, bridgeErr or "bridge submit failed")
			else
				table.insert(queue, 1, item)
				return startedAny
			end
		end
	end

	return startedAny
end

local function TryStartBlockingRequest(now)
	if activeItem ~= nil then
		return false
	end

	while #queue > 0 do
		local item = queue[1]
		if not item then
			table.remove(queue, 1)
		elseif type(item.callback) ~= "function" then
			table.remove(queue, 1)
		elseif not ItemSupportsBlocking(item) then
			item = table.remove(queue, 1)
			InvokeCallback(item, nil, "bridge transport required for non-GET request")
			return true
		else
			local requiredDelay = GetRequiredDelay(item)
			if (now - lastSerialDispatchTime) < requiredDelay then
				return false
			end

			item = table.remove(queue, 1)
			activeToken = activeToken + 1
			activeDeadline = now + REQUEST_TIMEOUT
			activeItem = item
			activeNextRetry = now
			activeLastError = ""
			activeAttemptCount = 0
			activeAttemptInFlight = false
			activeTransport = "blocking"
			lastSerialDispatchTime = now
			LogTransportMode("blocking", nil)
			DispatchBlockingAttempt()
			return true
		end
	end

	return false
end

local function ExpireBridgeRequests(now)
	if bridgeInFlightCount < 1 then
		return false
	end

	local expiredIds = {}
	for requestId, job in pairs(bridgeInFlight) do
		if job and now >= job.deadline then
			expiredIds[#expiredIds + 1] = requestId
		end
	end

	for index = 1, #expiredIds do
		local requestId = expiredIds[index]
		local job = bridgeInFlight[requestId]
		if job and job.item then
			local err = "HTTP request timed out after " .. tostring(REQUEST_TIMEOUT) .. "s"
			print("[HTTP QUEUE ERROR] " .. err .. " url=" .. tostring(job.item.url))
			FinishBridgeRequest(requestId, nil, err)
		end
	end

	return #expiredIds > 0
end

local function ProcessNextRequest(now, canRunBlocking)
	if activeItem ~= nil or #queue == 0 then
		return
	end

	if CanUseBridgeTransport() then
		local startedBridge = TryStartBridgeRequests(now, canRunBlocking)
		if CanUseBridgeTransport() then
			if startedBridge or bridgeInFlightCount > 0 then
				return
			end
			if not canRunBlocking then
				return
			end
		end
	end

	if not canRunBlocking then
		return
	end

	TryStartBlockingRequest(now)
end

--[[ Public API ]]

function HttpQueue.IsBusy()
	return activeItem ~= nil or activeAttemptInFlight or bridgeInFlightCount > 0 or #queue > 0
end

function HttpQueue.IsBridgeAlive()
	return CanUseBridgeTransport()
end

function HttpQueue.IsBridgeConfirmed()
	return CanUseBridgeTransport()
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
	local highPriority = false
	local bridgeTimeoutMs = nil
	local bridgeMaxBytes = nil
	local method = "GET"
	local body = ""
	local contentType = ""
	if type(options) == "table" and options.noDelay == true then
		noDelay = true
	end
	if type(options) == "table" and options.highPriority == true then
		highPriority = true
	end
	if type(options) == "table" and type(options.bridgeTimeoutMs) == "number" then
		bridgeTimeoutMs = math.floor(options.bridgeTimeoutMs)
	end
	if type(options) == "table" and type(options.bridgeMaxBytes) == "number" then
		bridgeMaxBytes = math.floor(options.bridgeMaxBytes)
	end
	if type(options) == "table" and type(options.method) == "string" and options.method ~= "" then
		method = options.method:upper()
	end
	if type(options) == "table" and type(options.body) == "string" then
		body = options.body
	end
	if type(options) == "table" and type(options.contentType) == "string" then
		contentType = options.contentType
	end

	if STRICT_SINGLE_FLIGHT and HttpQueue.IsBusy() then
		return false
	end

	local item = {
		url = url,
		callback = callback,
		context = context,
		noDelay = noDelay,
		method = method,
		body = body,
		contentType = contentType,
		bridgeTimeoutMs = bridgeTimeoutMs,
		bridgeMaxBytes = bridgeMaxBytes,
	}

	if highPriority then
		table.insert(queue, 1, item)
	else
		table.insert(queue, item)
	end
	return true
end

-- Main tick function to be called from the scheduler
function HttpQueue.Tick()
	if not isAlive then
		return
	end

	local now = Now()
	RefreshBridgeSafeWindowGate()
	local canProbeNow = CanRunBlockingHTTPNow()
	if bridgeState.alive ~= true and not canProbeNow and now >= bridgeState.nextProbeAt then
		StartAsyncBridgeHealthProbe(now)
	end
	-- Only probe bridge in safe windows (player dead / not in game).
	-- Never probe while alive: http.Get to localhost is blocking and causes hitches.
	if activeItem == nil and bridgeInFlightCount == 0 and canProbeNow and now >= bridgeState.nextProbeAt then
		ProbeBridge(now)
	end

	-- Only time out an item if at least one real attempt has been made.
	-- Items with 0 attempts are waiting for an unintrusive window; timing them out
	-- would discard requests that haven't had a chance to run yet.
	if activeItem and now >= activeDeadline and activeAttemptCount > 0 then
		local timedOutItem = activeItem
		local err = "HTTP request timed out after "
		err = err .. tostring(REQUEST_TIMEOUT) .. "s"
		if activeLastError ~= "" then
			err = err .. " (last error: " .. activeLastError .. ")"
		end
		err = err .. " attempts=" .. tostring(activeAttemptCount)
		print("[HTTP QUEUE ERROR] " .. err .. " url=" .. tostring(timedOutItem.url))
		activeToken = activeToken + 1
		FinishActiveRequest(timedOutItem, nil, err)
	elseif activeItem and activeTransport == "blocking" and (not activeAttemptInFlight) and now >= activeNextRetry then
		DispatchBlockingAttempt()
	end

	if bridgeInFlightCount > 0 and now >= bridgeNextPollAt then
		PollBridgeResults(now, canProbeNow)
		if not canProbeNow then
			return
		end
	end

	if ExpireBridgeRequests(now) and not canProbeNow then
		return
	end

	ProcessNextRequest(now, canProbeNow)
end

--[[ Cleanup ]]

local function OnHttpQueueUnload()
	isAlive = false
	queue = {}
	activeItem = nil
	activeAttemptInFlight = false
	activeNextRetry = 0
	activeLastError = ""
	activeAttemptCount = 0
	activeDeadline = 0
	bridgeInFlight = {}
	bridgeInFlightCount = 0
	bridgeNextPollAt = 0
	bridgeState.asyncProbeInFlight = false
	ResetBlockingWindowState()
end

callbacks.Unregister("Unload", "HttpQueue_Unload")
callbacks.Register("Unload", "HttpQueue_Unload", OnHttpQueueUnload)

return HttpQueue
