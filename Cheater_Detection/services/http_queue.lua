--[[ services/http_queue.lua
     Handles rate-limited HTTP requests to prevent API spam.
]]

local EventBus = require("Cheater_Detection.core.event_bus")

local HttpQueue = {}

local queue = {}
local isProcessing = false
local lastRequestTime = 0
local REQUEST_DELAY = 0.1 -- 100ms between requests (Fast but safe)

function HttpQueue.Enqueue(url, callback)
	table.insert(queue, { url = url, callback = callback })
end

function HttpQueue.Process()
	if #queue == 0 or isProcessing then
		return
	end

	local now = globals.RealTime()
	if (now - lastRequestTime) < REQUEST_DELAY then
		return
	end

	local item = table.remove(queue, 1)
	isProcessing = true
	lastRequestTime = now

	http.GetAsync(item.url, function(data)
		isProcessing = false -- Allow next request
		local status, err = pcall(item.callback, data)
		if not status then
			print("[HTTP QUEUE ERROR] Callback failed: " .. tostring(err))
		end
	end)
end

-- Tick function to be called from the scheduler
function HttpQueue.Tick()
	HttpQueue.Process()
end

-- Legacy support for OneSecondTick if still used
EventBus.Subscribe("OneSecondTick", function()
	HttpQueue.Tick()
end)

return HttpQueue
