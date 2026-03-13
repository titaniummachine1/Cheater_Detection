--[[ core/event_bus.lua
     Centralized notification system.
     Allows decoupling of modules while maintaining performance.
]]

local EventBus = {}

---@type table<string, function[]>
local subscribers = {}

---Register a callback for a specific event
---@param eventName string The name of the event (e.g., "PlayerHurt", "DecayHeartbeat")
---@param callback function The function to call when event is published
function EventBus.Subscribe(eventName, callback)
	assert(eventName, "EventBus.Subscribe: eventName missing")
	assert(type(callback) == "function", "EventBus.Subscribe: callback must be a function")

	subscribers[eventName] = subscribers[eventName] or {}
	table.insert(subscribers[eventName], callback)
end

---Publish an event to all subscribers
---@param eventName string The name of the event
---@param ... any Arguments to pass to the callbacks
function EventBus.Publish(eventName, ...)
	local subs = subscribers[eventName]
	if not subs then
		return
	end

	for i = 1, #subs do
		subs[i](...)
	end
end

---Remove all subscribers for an event
---@param eventName string
function EventBus.UnsubscribeAll(eventName)
	subscribers[eventName] = nil
end

---Clear all subscriptions (useful for script reload)
function EventBus.Reset()
	for k in pairs(subscribers) do
		subscribers[k] = nil
	end
end

return EventBus
