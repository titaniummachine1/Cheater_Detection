--[[ detectors/fake_lag.lua
     Detects excessive packet choking (Fake Lag) by monitoring simulation time deltas.
]]

local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local Events = require("Cheater_Detection.Core.Events")

local FakeLag = {}

-- Cached sv_maxunlag value (seconds). TF2 default is 0.2 s.
-- Refreshed once per map change, round start, or local-player respawn so that
-- the threshold always matches the server's actual lag-compensation window.
local svMaxUnlag = 0.2

local function refreshCvarCache()
	local val = engine.GetConVar("sv_maxunlag")
	if type(val) == "number" and val > 0 then
		svMaxUnlag = val
	else
		print(string.format("[FakeLag] sv_maxunlag unavailable, using default %.2f s", svMaxUnlag))
	end
end

-- Seed the cache immediately so any per-tick detections before the first
-- game event already use the real server value (important on script reload).
refreshCvarCache()

-- Convert the cached sv_maxunlag seconds to the equivalent tick count for the
-- current server tick rate using the standard formula.
local function getMaxTickDelta()
	return math.floor(svMaxUnlag / globals.TickInterval() + 0.5)
end

-- Per-player tracking
local playerStats = {} -- id -> { lastSimTime, events = {tick1, tick2...} }

-- Refresh the CVar cache whenever the server/round context changes.
-- Registered for specific events to avoid unnecessary overhead.
local function onMapOrRoundRefresh(_event)
	refreshCvarCache()
end

local function onPlayerSpawnRefresh(event)
	-- Only refresh when the local player (re)spawns; other spawns are irrelevant.
	local spawnedEntity = entities.GetByUserID(event:GetInt("userid"))
	local localPlayer = entities.GetLocalPlayer()
	if spawnedEntity and localPlayer and spawnedEntity:GetIndex() == localPlayer:GetIndex() then
		refreshCvarCache()
	end
end

Events.Register("FireGameEvent", "FakeLag_CvarRefresh_Map",   onMapOrRoundRefresh, "game_newmap")
Events.Register("FireGameEvent", "FakeLag_CvarRefresh_Round", onMapOrRoundRefresh, "teamplay_round_start")
Events.Register("FireGameEvent", "FakeLag_CvarRefresh_Spawn", onPlayerSpawnRefresh, "player_spawn")

local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
end

function FakeLag.ProcessPlayer(playerState)
	if not playerState or not playerState.wrap or not playerState.id then
		return
	end

	-- Menu gate: cheapest check first
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.Choke) then
		return
	end

	-- Connection/FPS stability gate: remote sim times are unreliable when connection is bad
	if not Common.IsConnectionStableForDetection() then
		return
	end

	local entity = playerState.wrap:GetRawEntity()
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return
	end

	-- Skip bots. Skip local player unless debug mode is enabled for testing.
	if Common.IsBot(entity) or (entity == entities.GetLocalPlayer() and not Common.IsDebugEnabled()) then
		return
	end

	local id = playerState.id
	if not playerStats[id] then
		playerStats[id] = { lastSimTime = 0, events = {} }
	end
	local data = playerStats[id]

	local currentSimTime = playerState.wrap:GetSimulationTime()
	if not currentSimTime then
		return
	end

	if data.lastSimTime == 0 then
		data.lastSimTime = currentSimTime
		return
	end

	local delta = currentSimTime - data.lastSimTime

	-- Reject invalid deltas (respawn, lag comp, demo)
	if delta <= 0 or delta > 2 then
		data.lastSimTime = currentSimTime
		return
	end

	local deltaTicks = timeToTicks(delta)
	local curTick = globals.TickCount()

	-- Only record events that meet the threshold
	if deltaTicks >= getMaxTickDelta() then
		table.insert(data.events, { tick = curTick, amount = deltaTicks })

		-- Clean up events older than ~5 seconds
		while #data.events > 0 and (curTick - data.events[1].tick) > Constants.SecondsToTicks(5) do
			table.remove(data.events, 1)
		end

		-- Trigger suspicion ONLY if they choke in a rhythmic, repeating fashion
		-- (choking same amount of ticks for exact amount and repeating)
		if #data.events >= 3 then
			local consistent = true
			local firstAmount = data.events[1].amount
			for i = 2, #data.events do
				local diff = math.abs(data.events[i].amount - firstAmount)
				if diff > 1 then -- Stricter rhythm matching
					consistent = false
					break
				end
			end

			if consistent then
				-- ~0.333 s cooldown between adding weight/marking for FakeLag per suspect (≈22 ticks at 66 Hz)
				local lastFlag = data.lastFlagTick or 0
				if (curTick - lastFlag) < math.floor(22.0 / 66.0 / globals.TickInterval() + 0.5) then
					return
				end

				data.lastFlagTick = curTick
				local reason = string.format("Fake Lag (Rhythmic choke: %d ticks)", deltaTicks)
				DetectorUtils.ApplyPlayerFlag(playerState, 5, nil, reason)

				-- Clear events to wait for next sequence
				data.events = {}
			end
		end
	end

	data.lastSimTime = currentSimTime
end

-- Cleanup
Events.Subscribe("OnPlayerDisconnect", function(id)
	playerStats[id] = nil
end)

return FakeLag
