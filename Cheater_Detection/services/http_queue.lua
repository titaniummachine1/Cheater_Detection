--[[ services/http_queue.lua
     Handles rate-limited HTTP requests to prevent API spam.
     Refactored to be robust and use the best available HTTP method.
]]

local Common = require("Cheater_Detection.Utils.Common")

local HttpQueue = {}

local Json = Common and Common.Json or nil

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
local activeTransport = nil
local activeBridgeRequestId = nil

local BRIDGE_PROTOCOL = "local-http-bridge-v1"
local BRIDGE_BASE = "http://127.0.0.1:17354"
local BRIDGE_STALL_LIMIT = 0.20
local BRIDGE_REMOTE_TIMEOUT_MS = 12000
local BRIDGE_REMOTE_MAX_BYTES = 2 * 1024 * 1024
local BRIDGE_POLL_INTERVAL = 0.0
local BRIDGE_ASSUME_HEALTHY_ON_LOAD = true
local BRIDGE_HEALTH_CHECK_INTERVAL = 10.0

local bridgeState = {
	alive = BRIDGE_ASSUME_HEALTHY_ON_LOAD,
	protocol = BRIDGE_ASSUME_HEALTHY_ON_LOAD and BRIDGE_PROTOCOL or nil,
	lastError = "",
	lastProbeAt = 0,
	nextProbeAt = 0,
	blockedUntilSafeWindow = false,
}

local lastLoggedTransportMode = "startup"
local lastLoggedBridgeAlive = BRIDGE_ASSUME_HEALTHY_ON_LOAD
local lastLoggedBridgeError = ""

local FinishActiveRequest

local function Now()
	local globalsTable = globals
	if globalsTable and type(globalsTable.RealTime) == "function" then
		local ok, value = pcall(globalsTable.RealTime)
		if ok and type(value) == "number" then
			return value
		end
	end
	return os.clock()
end

local function CanRunBlockingHTTPNow()
	local ok, localPlayer = pcall(entities.GetLocalPlayer)
	if not ok or not localPlayer then
		return true
	end

	local aliveOk, alive = pcall(function()
		return localPlayer:IsAlive()
	end)
	if not aliveOk then
		return false
	end

	return not alive
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

local function MarkBridgeOffline(errorMessage, now, blockUntilSafeWindow)
	local currentTime = type(now) == "number" and now or Now()
	bridgeState.alive = false
	bridgeState.protocol = nil
	bridgeState.lastError = errorMessage or "bridge offline"
	bridgeState.lastProbeAt = currentTime
	bridgeState.nextProbeAt = currentTime + BRIDGE_HEALTH_CHECK_INTERVAL
	if blockUntilSafeWindow then
		bridgeState.blockedUntilSafeWindow = true
	end
	LogBridgeState(false, bridgeState.lastError)
end

local function MarkBridgeAlive(protocol, now)
	bridgeState.alive = true
	bridgeState.protocol = protocol
	bridgeState.lastError = ""
	bridgeState.lastProbeAt = type(now) == "number" and now or Now()
	bridgeState.nextProbeAt = bridgeState.lastProbeAt + BRIDGE_HEALTH_CHECK_INTERVAL
	bridgeState.blockedUntilSafeWindow = false
	LogBridgeState(true, nil)
end

local function RefreshBridgeSafeWindowGate()
	if bridgeState.blockedUntilSafeWindow and CanRunBlockingHTTPNow() then
		bridgeState.blockedUntilSafeWindow = false
	end
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
	if not CanRunBlockingHTTPNow() then
		return bridgeState.alive == true, bridgeState.lastError ~= "" and bridgeState.lastError or nil
	end
	if bridgeState.blockedUntilSafeWindow and not CanRunBlockingHTTPNow() then
		return false, bridgeState.lastError ~= "" and bridgeState.lastError or "bridge offline"
	end
	if currentTime < bridgeState.nextProbeAt then
		return bridgeState.alive == true, bridgeState.lastError ~= "" and bridgeState.lastError or nil
	end

	local payload, err, stalled = BridgeJson("/health")
	if payload and payload.ok == true and payload.alive == true and payload.protocol == BRIDGE_PROTOCOL then
		MarkBridgeAlive(payload.protocol, currentTime)
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
	return bridgeState.alive == true and bridgeState.protocol == BRIDGE_PROTOCOL and
		not bridgeState.blockedUntilSafeWindow
end

local function StartBridgeRequest(item, now)
	local encodedUrl = UrlEncode(item.url)
	if encodedUrl == nil then
		return false, "bridge url encode failed"
	end

	local timeoutMs = item.bridgeTimeoutMs or BRIDGE_REMOTE_TIMEOUT_MS
	local maxBytes = item.bridgeMaxBytes or BRIDGE_REMOTE_MAX_BYTES
	local path = string.format(
		"/submit?url=%s&timeout_ms=%d&max_bytes=%d",
		encodedUrl,
		timeoutMs,
		maxBytes
	)

	local payload, err, stalled = BridgeJson(path)
	if not payload or payload.ok ~= true or type(payload.id) ~= "string" then
		local errorMessage = err
		if errorMessage == nil and payload and type(payload.error) == "string" then
			errorMessage = payload.error
		end
		MarkBridgeOffline(errorMessage or "bridge submit failed", now, stalled)
		return false, bridgeState.lastError
	end

	activeTransport = "bridge"
	activeBridgeRequestId = payload.id
	activeNextRetry = now + BRIDGE_POLL_INTERVAL
	activeLastError = ""
	MarkBridgeAlive(bridgeState.protocol or BRIDGE_PROTOCOL, now)
	LogTransportMode("bridge", nil)
	return true, nil
end

local function FallbackToBlockingTransport(now, errorMessage)
	activeTransport = "blocking"
	activeBridgeRequestId = nil
	activeNextRetry = type(now) == "number" and now or Now()
	activeLastError = errorMessage or activeLastError
	activeAttemptInFlight = false
	LogTransportMode("blocking", activeLastError)
end

local function PollBridgeResult(now)
	if type(activeBridgeRequestId) ~= "string" or activeBridgeRequestId == "" then
		FallbackToBlockingTransport(now, "bridge request id missing")
		return
	end

	local encodedId = UrlEncode(activeBridgeRequestId)
	if encodedId == nil then
		FallbackToBlockingTransport(now, "bridge request id encode failed")
		return
	end

	local payload, err, stalled = BridgeJson("/result?id=" .. encodedId)
	if payload == nil then
		MarkBridgeOffline(err or "bridge result failed", now, stalled)
		FallbackToBlockingTransport(now, bridgeState.lastError)
		return
	end
	if payload.ok ~= true then
		local errorMessage = type(payload.error) == "string" and payload.error or "bridge result failed"
		MarkBridgeOffline(errorMessage, now, stalled)
		FallbackToBlockingTransport(now, bridgeState.lastError)
		return
	end
	MarkBridgeAlive(bridgeState.protocol or BRIDGE_PROTOCOL, now)
	if payload.done ~= true then
		activeNextRetry = now + BRIDGE_POLL_INTERVAL
		return
	end

	local item = activeItem
	activeTransport = nil
	activeBridgeRequestId = nil
	if payload.success == true and type(payload.data) == "string" then
		FinishActiveRequest(item, payload.data, nil)
		return
	end
	FinishActiveRequest(item, nil, payload.error or "remote request failed")
end

local function ResetActiveRequestState()
	isProcessing = false
	activeItem = nil
	activeAttemptInFlight = false
	activeNextRetry = 0
	activeLastError = ""
	activeAttemptCount = 0
	activeDeadline = 0
	activeTransport = nil
	activeBridgeRequestId = nil
end

FinishActiveRequest = function(item, responseBody, errorMessage)
	local cbStatus, cbErr = pcall(item.callback, responseBody, errorMessage, item.context)
	if not cbStatus then
		print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(cbErr))
	end
	ResetActiveRequestState()
end

local function DispatchBlockingAttempt()
	if activeAttemptInFlight or not activeItem then
		return
	end

	if not CanRunBlockingHTTPNow() then
		return
	end

	activeAttemptCount = activeAttemptCount + 1
	activeAttemptInFlight = true
	local item = activeItem
	local dataOrErr, err = HttpGet(item.url)
	activeAttemptInFlight = false

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

local function ProcessNextRequest()
	if isProcessing or #queue == 0 then
		return
	end

	local now = Now()
	local item = queue[1]
	local requiredDelay = REQUEST_DELAY
	if item and (item.noDelay or IsGitHubLikeURL(item.url)) then
		requiredDelay = 0
	end
	if (now - lastRequestTime) < requiredDelay then
		return
	end

	local canRunBlocking = CanRunBlockingHTTPNow()
	local canUseBridge = CanUseBridgeTransport()
	if not canUseBridge and canRunBlocking and now >= bridgeState.nextProbeAt then
		ProbeBridge(now)
		canUseBridge = CanUseBridgeTransport()
	end

	if not canUseBridge and not canRunBlocking then
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
	activeTransport = nil
	activeBridgeRequestId = nil

	if canUseBridge then
		local started, bridgeErr = StartBridgeRequest(item, now)
		if started then
			return
		end
		if not CanRunBlockingHTTPNow() then
			FallbackToBlockingTransport(now, bridgeErr)
			return
		end
	end

	activeTransport = "blocking"
	DispatchBlockingAttempt()
end

--[[ Public API ]]

function HttpQueue.IsBusy()
	return isProcessing or activeAttemptInFlight or #queue > 0
end

function HttpQueue.IsBridgeAlive()
	return bridgeState.alive == true and bridgeState.protocol == BRIDGE_PROTOCOL
end

function HttpQueue.IsBridgeConfirmed()
	return HttpQueue.IsBridgeAlive() and bridgeState.lastProbeAt > 0
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
	local bridgeTimeoutMs = nil
	local bridgeMaxBytes = nil
	if type(options) == "table" and options.noDelay == true then
		noDelay = true
	end
	if type(options) == "table" and type(options.bridgeTimeoutMs) == "number" then
		bridgeTimeoutMs = math.floor(options.bridgeTimeoutMs)
	end
	if type(options) == "table" and type(options.bridgeMaxBytes) == "number" then
		bridgeMaxBytes = math.floor(options.bridgeMaxBytes)
	end

	if STRICT_SINGLE_FLIGHT and HttpQueue.IsBusy() then
		return false
	end

	table.insert(queue, {
		url = url,
		callback = callback,
		context = context,
		noDelay = noDelay,
		bridgeTimeoutMs = bridgeTimeoutMs,
		bridgeMaxBytes = bridgeMaxBytes,
	})
	return true
end

-- Main tick function to be called from the scheduler
function HttpQueue.Tick()
	if not isAlive then
		return
	end

	local now = Now()
	RefreshBridgeSafeWindowGate()
	if (not isProcessing) and now >= bridgeState.nextProbeAt then
		ProbeBridge(now)
	end

	if isProcessing and activeItem and now >= activeDeadline then
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
	elseif isProcessing and activeItem and activeTransport == "bridge" and now >= activeNextRetry then
		PollBridgeResult(now)
	elseif isProcessing and activeItem and activeTransport == "blocking" and (not activeAttemptInFlight) and now >= activeNextRetry then
		DispatchBlockingAttempt()
	end

	ProcessNextRequest()
end

--[[ Cleanup ]]

local function OnHttpQueueUnload()
	isAlive = false
	queue = {}
	isProcessing = false
	activeItem = nil
	activeAttemptInFlight = false
	activeNextRetry = 0
	activeLastError = ""
	activeAttemptCount = 0
	activeDeadline = 0
end

callbacks.Unregister("Unload", "HttpQueue_Unload")
callbacks.Register("Unload", "HttpQueue_Unload", OnHttpQueueUnload)

return HttpQueue
