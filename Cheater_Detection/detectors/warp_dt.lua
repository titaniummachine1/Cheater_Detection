--[[ detectors/warp_dt.lua
     Detects warp/dt exploits by monitoring simulation time deltas.
     Uses shared tick-bucket history from HistoryManager.
     Uses lazy PlayerData - NO direct entity API calls.
]]

local Constants = require("Cheater_Detection.Core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Events = require("Cheater_Detection.Core.Events")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local Common = require("Cheater_Detection.Utils.Common")
local PlayerData = require("Cheater_Detection.Utils.PlayerData")

local WarpDT = {}

local SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD = 3

local BURST_MIN_TICKS_66HZ = 18.0
local BURST_MAX_TICKS_66HZ = 64.0
local WARP_COOLDOWN_TICKS_66HZ = 24.0

local playerStats = {}

local lastServerHitchTick = -math.huge

local function getServerHitchWindow()
	return math.floor(1.0 / globals.TickInterval() + 0.5)
end

local function isInHitchWindow(curTick)
	return (curTick - lastServerHitchTick) < getServerHitchWindow()
end

local burstThisTick = {}
local lastBurstCleanTick = 0

local function recordBurst(tick, id)
	if not burstThisTick[tick] then
		burstThisTick[tick] = {}
	end
	burstThisTick[tick][#burstThisTick[tick] + 1] = id
end

local function isServerHitch(tick)
	local list = burstThisTick[tick]
	return list and #list >= SIMULTANEOUS_BURST_SUPPRESS_THRESHOLD
end

local function cleanBurstTable(curTick)
	if (curTick - lastBurstCleanTick) < 4 then
		return
	end
	lastBurstCleanTick = curTick
	for tick in pairs(burstThisTick) do
		if (curTick - tick) > 3 then
			burstThisTick[tick] = nil
		end
	end
end

local function timeToTicks(time)
	return math.floor(0.5 + time / globals.TickInterval())
end

function WarpDT.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then
		return
	end

	local menu = G.Menu
	local advanced = menu and menu.Advanced or nil
	local warpEnabled = advanced and advanced["Warp"] == true or false
	if not warpEnabled then
		return
	end

	if not Common.IsConnectionStableForDetection() then
		return
	end

	local pdata = playerState.pdata
	local isAlive = pdata.isAlive
	
	-- If data is stale, skip this tick
	if isAlive == nil then
		return
	end
	
	if not isAlive then
		return
	end

	local isDebug = Common.IsDebugEnabled()
	local id = playerState.id
	
	-- Check bot using steamID prefix (safe, no entity needed)
	if id:sub(1, 4) == "BOT_" then
		return
	end
	
	-- Skip local player
	if id == tostring(Common.GetSteamID64(entities.GetLocalPlayer())) and not isDebug then
		return
	end

	if not playerStats[id] then
		playerStats[id] = { events = {} }
	end
	local data = playerStats[id]

	if (playerState.flags & Constants.Flags.CHEATER) ~= 0 then
		return
	end

	local ringCount = HistoryManager.GetRingCount()
	if ringCount < 10 then
		return
	end

	local simTicks = {}
	for i = 0, ringCount - 1 do
		local bucket = HistoryManager.GetBucketAt(i)
		local simTime = HistoryManager.GetPlayerFieldAt(bucket, id, HistoryManager.Fields.SimulationTime)
		if simTime then
			simTicks[#simTicks + 1] = timeToTicks(simTime)
		end
	end

	if #simTicks < 10 then
		return
	end

	local deltaTicks = {}
	for i = 1, #simTicks - 1 do
		-- simTicks[i] is newer than simTicks[i+1]
		deltaTicks[#deltaTicks + 1] = simTicks[i] - simTicks[i + 1]
	end

	local burstMin = math.floor(BURST_MIN_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
	local burstMax = math.floor(BURST_MAX_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
	local burstAmount = 0
	for _, d in ipairs(deltaTicks) do
		if d > burstMin and d < burstMax then
			burstAmount = d
			break
		end
	end

	local curTick = globals.TickCount()
	cleanBurstTable(curTick)

	if burstAmount > 0 then
		recordBurst(curTick, id)

		if isInHitchWindow(curTick) then
			return
		end

		local cooldownTicks = math.floor(WARP_COOLDOWN_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)
		if not data.lastWarpTick or (curTick - data.lastWarpTick) > cooldownTicks then
			if isServerHitch(curTick) then
				lastServerHitchTick = curTick
				data.lastWarpTick = curTick
				if isDebug then
					print(string.format("[WarpDT] server hitch suppressed burst for %s (tick=%d)", id, curTick))
				end
				return
			end

			data.lastWarpTick = curTick
			data.events[#data.events + 1] = curTick

			local reason = "Warp/DT (Packet Burst)"
			local increment = (#data.events >= 2) and 15 or 5
			DetectorUtils.ApplyPlayerFlag(playerState, increment, nil, reason)

			if isDebug then
				print(string.format("[WarpDT] %s packet burst detected: %d ticks", id, burstAmount))
			end

			while #data.events > 0 and (curTick - data.events[1]) > Constants.SecondsToTicks(10) do
				table.remove(data.events, 1)
			end

			if #data.events >= 2 then
				table.remove(data.events, 1)
			end
		end
	end
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	playerStats[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerStats[id] = nil
end)

return WarpDT
