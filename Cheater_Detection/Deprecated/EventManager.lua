--[[ EventManager.lua - Centralized event handling ]]
--
-- Manages all game events with single callback registration per event type.
-- Allows multiple handlers per event without redundant hook overhead.

local EventManager = {}

-- Handler storage: [eventType][handlerName] = { filter = "event_name", callback = function }
local handlers = {
	CreateMove = {},
	Draw = {},
	FireGameEvent = {},
	DispatchUserMessage = {},
	Unload = {},
}

-- Registered callback names for cleanup
local registeredCallbacks = {}

--[[ Private Functions ]]

-- Dispatcher for FireGameEvent (filters by event name)
local function dispatchFireGameEvent(event)
	local eventName = event:GetName()
	for _, handler in pairs(handlers.FireGameEvent) do
		if not handler.filter or handler.filter == eventName or handler.filter == "*" then
			local success, err = pcall(handler.callback, event)
			if not success then
				print(string.format("[EventManager] Error in FireGameEvent handler: %s", err))
			end
		end
	end
end

-- Generic dispatcher (no filtering)
local function dispatchGeneric(eventType, ...)
	for _, handler in pairs(handlers[eventType]) do
		local success, err = pcall(handler.callback, ...)
		if not success then
			print(string.format("[EventManager] Error in %s handler: %s", eventType, err))
		end
	end
end

--[[ Public API ]]

--- Register a handler for an event
---@param eventType string Event type: "CreateMove", "Draw", "FireGameEvent", etc.
---@param handlerName string Unique handler name (e.g., "Database_MapChange")
---@param callback function Handler function
---@param filter string? Optional event name filter (for FireGameEvent only)
function EventManager.Register(eventType, handlerName, callback, filter)
	if not handlers[eventType] then
		print(string.format("[EventManager] Unknown event type: %s", eventType))
		return false
	end

	-- Store handler
	handlers[eventType][handlerName] = {
		callback = callback,
		filter = filter,
	}

	-- Register actual callback if not already registered
	if not registeredCallbacks[eventType] then
		local callbackName = "CD_EventManager_" .. eventType

		-- Unregister old callback if exists
		callbacks.Unregister(eventType, callbackName)

		-- Register new callback with dispatcher
		if eventType == "FireGameEvent" then
			callbacks.Register(eventType, callbackName, dispatchFireGameEvent)
		else
			callbacks.Register(eventType, callbackName, function(...)
				dispatchGeneric(eventType, ...)
			end)
		end

		registeredCallbacks[eventType] = callbackName
	end

	return true
end

--- Unregister a handler
---@param eventType string Event type
---@param handlerName string Handler name to remove
function EventManager.Unregister(eventType, handlerName)
	if handlers[eventType] then
		handlers[eventType][handlerName] = nil
	end
end

--- Get count of registered handlers for debugging
---@param eventType string? Optional event type, nil = all types
---@return number|table Count or table of counts
function EventManager.GetHandlerCount(eventType)
	if eventType then
		local count = 0
		for _ in pairs(handlers[eventType] or {}) do
			count = count + 1
		end
		return count
	else
		local counts = {}
		for evType, handlerList in pairs(handlers) do
			local count = 0
			for _ in pairs(handlerList) do
				count = count + 1
			end
			counts[evType] = count
		end
		return counts
	end
end

-- NOTE: No cleanup needed on Unload.
-- Lmaobox automatically cleans up all callbacks when the script unloads.
-- Calling callbacks.Unregister() during Unload causes crashes.

return EventManager
