--[[ services/http_queue.lua
     Handles rate-limited HTTP requests to prevent API spam.
]]

local EventBus = require("Cheater_Detection.core.event_bus")

local HttpQueue = {}

local queue = {}
local isProcessing = false
local lastRequestTime = 0
local REQUEST_DELAY = 1.0 -- 1 second between requests (Safe for GitHub)

function HttpQueue.Enqueue(url, callback)
	table.insert(queue, { url = url, callback = callback })
end

function HttpQueue.Process()
	if #queue == 0 then
		return
	end

    local now = globals.RealTime()

    -- Safety: If stuck processing for more than 10 seconds, reset lock
    if isProcessing and (now - lastRequestTime > 10) then
        print("[HTTP QUEUE] Request timeout, resetting lock...")
        isProcessing = false
    end

    if isProcessing then
        return
    end

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
