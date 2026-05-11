local TickEntityCache = {}

local lastTick = -1
local playerIndexPresent = {}

local function clearMap(map)
	for k in pairs(map) do
		map[k] = nil
	end
end

function TickEntityCache.RefreshTick(curTick, playerEntities)
	if type(curTick) ~= "number" then
		return
	end
	if curTick == lastTick then
		return
	end
	lastTick = curTick

	clearMap(playerIndexPresent)

	if type(playerEntities) ~= "table" then
		return
	end

	for i = 1, #playerEntities do
		local ent = playerEntities[i]
		if ent and ent:IsValid() then
			local idx = ent:GetIndex()
			if idx then
				playerIndexPresent[idx] = true
			end
		end
	end
end

function TickEntityCache.GetPlayerByIndex(index)
	if type(index) ~= "number" then
		return nil
	end
	if globals.TickCount() ~= lastTick then
		return nil
	end
	if playerIndexPresent[index] ~= true then
		return nil
	end
	local ent = entities.GetByIndex(index)
	if not ent or not ent:IsValid() then
		return nil
	end
	return ent
end

function TickEntityCache.Invalidate()
	lastTick = -1
	clearMap(playerIndexPresent)
end

return TickEntityCache
