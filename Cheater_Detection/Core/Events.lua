--[[ Core/Events.lua
     Unified event system.  Two responsibilities:
       1. Internal pub/sub between modules  (Subscribe / Publish / UnsubscribeAll / Reset).
       2. Engine callback mux — lets multiple modules register handlers for
          CreateMove / Draw / FireGameEvent / DispatchUserMessage / Unload
          without clobbering each other.

     Drop-in replacement for both Core/event_bus.lua AND Utils/EventManager.lua.
     Callers using EventBus: rename local var from EventBus  → Events.
     Callers using EventManager: rename local var from EventManager → Events.
]]

local Events = {}

-- ── 1. Internal pub/sub ───────────────────────────────────────────────────────

---@type table<string, function[]>
local subscribers = {}

---Register a callback for a specific internal event
---@param eventName string
---@param callback function
function Events.Subscribe(eventName, callback)
	assert(eventName, "Events.Subscribe: eventName missing")
	assert(type(callback) == "function", "Events.Subscribe: callback must be a function")
	subscribers[eventName] = subscribers[eventName] or {}
	pcall(function() table.insert(subscribers[eventName], callback) end)
end

---Publish an internal event to all subscribers
---@param eventName string
---@param ... any
function Events.Publish(eventName, ...)
	local subs = subscribers[eventName]
	if not subs then
		return
	end
	for i = 1, #subs do
		subs[i](...)
	end
end

---Remove all subscribers for a named event
---@param eventName string
function Events.UnsubscribeAll(eventName)
	subscribers[eventName] = nil
end

---Clear all internal subscriptions (call on script reload)
function Events.Reset()
	for k in pairs(subscribers) do
		subscribers[k] = nil
	end
end

-- ── 2. Engine callback multiplexer ────────────────────────────────────────────

local handlers = {
	CreateMove          = {},
	Draw                = {},
	FireGameEvent       = {},
	DispatchUserMessage = {},
	Unload              = {},
}

local function dispatchFireGameEvent(event)
	local eventName = event:GetName()
	for _, handler in pairs(handlers.FireGameEvent) do
		if not handler.filter or handler.filter == eventName or handler.filter == "*" then
			local ok, err = pcall(handler.callback, event)
			if not ok then
				print(string.format("[Events] FireGameEvent handler error: %s", err))
			end
		end
	end
end

local function dispatchGeneric(eventType, ...)
	for _, handler in pairs(handlers[eventType]) do
		local ok, err = pcall(handler.callback, ...)
		if not ok then
			print(string.format("[Events] %s handler error: %s", eventType, err))
		end
	end
end

function Events.DispatchFireGameEvent(event)
	dispatchFireGameEvent(event)
end

function Events.DispatchEngineEvent(eventType, ...)
	if not handlers[eventType] then
		return false
	end
	dispatchGeneric(eventType, ...)
	return true
end

---Register a handler for an engine event type
---@param eventType string  "CreateMove"|"Draw"|"FireGameEvent"|"DispatchUserMessage"|"Unload"
---@param handlerName string  Unique name (e.g. "SilentAim_Death")
---@param callback function
---@param filter string?  Event name filter (FireGameEvent only; use "*" for all)
---@return boolean
function Events.Register(eventType, handlerName, callback, filter)
	assert(eventType, "Events.Register: eventType missing")
	assert(handlerName, "Events.Register: handlerName missing")
	assert(type(callback) == "function", "Events.Register: callback must be a function")
	if not handlers[eventType] then
		print(string.format("[Events] Unknown engine event type: %s", eventType))
		return false
	end
	handlers[eventType][handlerName] = { callback = callback, filter = filter }
	return true
end

---Unregister a handler
---@param eventType string
---@param handlerName string
function Events.Unregister(eventType, handlerName)
	if handlers[eventType] then
		handlers[eventType][handlerName] = nil
	end
end

---Get count of registered engine-callback handlers (for debugging)
---@param eventType string?  nil = return all counts as a table
---@return number|table
function Events.GetHandlerCount(eventType)
	if eventType then
		local count = 0
		for _ in pairs(handlers[eventType] or {}) do
			count = count + 1
		end
		return count
	end
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

return Events
