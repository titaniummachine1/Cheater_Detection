--[[ detectors/fake_lag.lua
     Detects excessive packet choking (Fake Lag) by monitoring simulation time deltas.
     Uses shared tick-bucket history from HistoryManager.
     Uses lazy PlayerData - NO direct entity API calls.
]]

local Constants = require("Cheater_Detection.Core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Events = require("Cheater_Detection.Core.Events")
local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")
local PlayerData = require("Cheater_Detection.Utils.PlayerData")

local FakeLag = {}

local svMaxUnlag = 0.2
local FAKELAG_COOLDOWN_TICKS_66HZ = 22.0
local RHYTHM_MIN_EVENTS = 3

local playerCooldowns = {}

local function refreshCvarCache()
	local val = client.GetConVar("sv_maxunlag")
	if type(val) == "number" and val > 0 then
		svMaxUnlag = val
	end
end

refreshCvarCache()

local function getMaxTickDelta()
	return math.floor(svMaxUnlag / globals.TickInterval() + 0.5)
end

local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
end

local function onMapOrRoundRefresh(_event)
	refreshCvarCache()
end

local function onPlayerSpawnRefresh(event)
	local spawnedEntity = entities.GetByUserID(event:GetInt("userid"))
	local localPlayer = entities.GetLocalPlayer()
	if spawnedEntity and localPlayer and spawnedEntity:GetIndex() == localPlayer:GetIndex() then
		refreshCvarCache()
	end
end

Events.Register("FireGameEvent", "FakeLag_CvarRefresh_Map", onMapOrRoundRefresh, "game_newmap")
Events.Register("FireGameEvent", "FakeLag_CvarRefresh_Round", onMapOrRoundRefresh, "teamplay_round_start")
Events.Register("FireGameEvent", "FakeLag_CvarRefresh_Spawn", onPlayerSpawnRefresh, "player_spawn")

function FakeLag.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then
		return
	end

	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.Choke) then
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

	local id = playerState.id
	
	-- Check bot using steamID prefix (safe, no entity needed)
	if id:sub(1, 4) == "BOT_" then
		return
	end
	
	-- Skip local player
	if id == tostring(Common.GetSteamID64(entities.GetLocalPlayer())) and not Common.IsDebugEnabled() then
		return
	end

	local ringCount = HistoryManager.GetRingCount()
	if ringCount < 5 then
		return
	end

	local simTimes = {}
	local ticks = {}
	for i = 0, ringCount - 1 do
		local bucket = HistoryManager.GetBucketAt(i)
		local tick = HistoryManager.GetTickAt(i)
		local simTime = HistoryManager.GetPlayerFieldAt(bucket, id, HistoryManager.Fields.SimulationTime)
		if simTime then
			simTimes[#simTimes + 1] = simTime
			ticks[#ticks + 1] = tick
		end
	end

	if #simTimes < 5 then
		return
	end

	local deltaTicks = {}
	for i = 1, #simTimes - 1 do
		-- simTimes[i] is newer than simTimes[i+1]
		local delta = simTimes[i] - simTimes[i + 1]
		if delta > 0 and delta <= 2 then
			deltaTicks[#deltaTicks + 1] = timeToTicks(delta)
		end
	end

	local curTick = globals.TickCount()
	local cooldownTicks = math.floor(FAKELAG_COOLDOWN_TICKS_66HZ / 66.0 / globals.TickInterval() + 0.5)

	local function checkAndApply()
		if #deltaTicks < RHYTHM_MIN_EVENTS then
			return
		end

		local firstDelta = deltaTicks[1]
		if firstDelta <= 1 then
			return
		end

		local consistent = true
		for i = 2, #deltaTicks do
			if math.abs(deltaTicks[i] - firstDelta) > 1 then
				consistent = false
				break
			end
		end

		if consistent then
			local lastFlag = playerCooldowns[id] or 0
			if (curTick - lastFlag) < cooldownTicks then
				return
			end

			playerCooldowns[id] = curTick
			local reason = string.format("Fake Lag (Rhythmic choke: %d ticks)", firstDelta)
			DetectorUtils.ApplyPlayerFlag(playerState, 5, nil, reason)

			if Common.IsDebugEnabled() then
				print(string.format("[FakeLag] %s rhythmic choke detected: %d ticks", id, firstDelta))
			end
		end
	end

	checkAndApply()
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	playerCooldowns[id] = nil
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	playerCooldowns[id] = nil
end)

return FakeLag
