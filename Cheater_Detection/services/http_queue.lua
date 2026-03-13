--[[ services/http_queue.lua
     Handles rate-limited HTTP requests to prevent API spam.
]]

local EventBus = require("Cheater_Detection.core.event_bus")

local HttpQueue = {}

local queue = {}
local isProcessing = false
local lastRequestTime = 0
local REQUEST_DELAY = 1.0 -- Seconds between requests

function HttpQueue.Enqueue(url, callback)
	table.insert(queue, { url = url, callback = callback })
	if not isProcessing then
		HttpQueue.Process()
	end
end

function HttpQueue.Process()
	if #queue == 0 then
		isProcessing = false
		return
	end

	isProcessing = true
	local now = globals.RealTime()
	local diff = now - lastRequestTime

	if diff < REQUEST_DELAY then
		-- Wait and try again
		return
	end

	local item = table.remove(queue, 1)
	lastRequestTime = now

	http.GetAsync(item.url, function(data)
		pcall(item.callback, data)
		-- Process next after some time
	end)
end

-- Hook into scheduler tick
EventBus.Subscribe("OneSecondTick", function()
	if #queue > 0 then
		HttpQueue.Process()
	end
end)

return HttpQueue
