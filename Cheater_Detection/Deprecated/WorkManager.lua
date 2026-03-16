local WorkManager = {}
WorkManager.works = {}
WorkManager.sortedIdentifiers = {}
WorkManager.workLimit = 1
WorkManager.executedWorks = 0

local function getCurrentTick()
	return globals.TickCount()
end

--- Adds work to the WorkManager and executes it if possible
--- @param func function The function to be executed
--- @param args table The arguments to pass to the function
--- @param delay number The delay (in ticks) before the function should be executed
--- @param identifier string A unique identifier for the work
function WorkManager.addWork(func, args, delay, identifier)
	local currentTime = getCurrentTick()
	args = args or {}

	local work = WorkManager.works[identifier]

	-- Check if the work already exists
	if work then
		-- Update existing work details (function, delay, args)
		work.func = func
		work.delay = delay or 1
		work.args = args
		work.wasExecuted = false
	else
		-- Add new work
		WorkManager.works[identifier] = {
			func = func,
			delay = delay,
			args = args,
			lastExecuted = currentTime,
			wasExecuted = false,
			result = nil,
		}
		-- Insert identifier and sort works based on their delay, in descending order
		table.insert(WorkManager.sortedIdentifiers, identifier)
		table.sort(WorkManager.sortedIdentifiers, function(a, b)
			return WorkManager.works[a].delay > WorkManager.works[b].delay
		end)
	end

	-- Attempt to execute the work immediately if within the work limit
	work = WorkManager.works[identifier]
	if WorkManager.executedWorks < WorkManager.workLimit then
		if not work.wasExecuted and currentTime - work.lastExecuted >= work.delay then
			-- Execute the work
			work.result = { func(table.unpack(args)) }
			work.wasExecuted = true
			work.lastExecuted = currentTime
			WorkManager.executedWorks = WorkManager.executedWorks + 1
			return table.unpack(work.result)
		end
	end

	-- Return cached result if the work cannot be executed immediately
	return table.unpack(work.result or {})
end

--- Attempts to execute work if conditions are met
--- @param delay number The delay (in ticks) before the function should be executed again
--- @param identifier string A unique identifier for the work
--- @return boolean Whether the work was executed
function WorkManager.attemptWork(delay, identifier)
	local currentTime = getCurrentTick()

	-- Check if the work already exists and was executed recently
	if WorkManager.works[identifier] and currentTime - WorkManager.works[identifier].lastExecuted < delay then
		return false
	end

	-- If the work does not exist or the delay has passed, create/update the work entry
	if not WorkManager.works[identifier] then
		WorkManager.works[identifier] = {
			lastExecuted = currentTime,
			delay = delay,
		}
	else
		WorkManager.works[identifier].lastExecuted = currentTime
	end

	return true
end
--- @param delay number The delay (in ticks) to set for future calls
--- @param identifier string A unique identifier for the work
--- @return boolean Always returns true to indicate work was allowed
function WorkManager.forceWork(delay, identifier)
	local currentTime = getCurrentTick()

	-- Always allow execution by updating the lastExecuted time
	if not WorkManager.works[identifier] then
		WorkManager.works[identifier] = {
			lastExecuted = currentTime,
			delay = delay,
		}
	else
		WorkManager.works[identifier].lastExecuted = currentTime - delay -- Set to past to allow immediate execution
	end

	return true
end

--- Resets the cooldown for a work, allowing immediate execution on next attempt
--- @param identifier string A unique identifier for the work
--- @return boolean Always returns true to indicate reset was successful
function WorkManager.resetCooldown(identifier)
	local currentTime = getCurrentTick()

	-- Reset the cooldown by setting lastExecuted to the past
	-- This allows attemptWork to immediately allow execution on next call
	if not WorkManager.works[identifier] then
		WorkManager.works[identifier] = {
			lastExecuted = currentTime - 1000, -- Set far in past to guarantee immediate execution
			delay = 1, -- Default delay if not set
		}
	else
		WorkManager.works[identifier].lastExecuted = currentTime - 1000 -- Set far in past to guarantee immediate execution
	end

	return true
end

--- Sets the cooldown delay for a work identifier
--- @param identifier string A unique identifier for the work
--- @param newDelay number The new delay in ticks to set
--- @return boolean Always returns true to indicate the cooldown was set
function WorkManager.setWorkCooldown(identifier, newDelay)
	local currentTime = getCurrentTick()

	-- Create or update work entry with new delay
	if not WorkManager.works[identifier] then
		WorkManager.works[identifier] = {
			lastExecuted = currentTime,
			delay = newDelay,
		}
	else
		WorkManager.works[identifier].delay = newDelay
	end

	return true
end

--- Processes the works based on their priority
function WorkManager.processWorks()
	local currentTime = getCurrentTick()
	WorkManager.executedWorks = 0

	for _, identifier in ipairs(WorkManager.sortedIdentifiers) do
		local work = WorkManager.works[identifier]
		if not work.wasExecuted and currentTime - work.lastExecuted >= work.delay then
			-- Execute the work
			work.result = { work.func(table.unpack(work.args)) }
			work.wasExecuted = true
			work.lastExecuted = currentTime
			WorkManager.executedWorks = WorkManager.executedWorks + 1

			-- Stop if the work limit is reached
			if WorkManager.executedWorks >= WorkManager.workLimit then
				break
			end
		end
	end
end

--- Clears work by identifier
--- @param identifier string The identifier of the work to clear
function WorkManager.clearWork(identifier)
	if WorkManager.works[identifier] then
		WorkManager.works[identifier] = nil
		-- Remove from sorted identifiers list
		for i = #WorkManager.sortedIdentifiers, 1, -1 do
			if WorkManager.sortedIdentifiers[i] == identifier then
				table.remove(WorkManager.sortedIdentifiers, i)
				break
			end
		end
		return true
	end
	return false
end

return WorkManager
