--[[ detectors/antiaim.lua
     Detects rage anti-aim via invalid pitch detection.
     Pitch outside ±89.9° = classic AA tell. 3 ticks = flag.
]]

local Constants       = require("Cheater_Detection.Core.constants")
local Common          = require("Cheater_Detection.Utils.Common")
local DetectorUtils   = require("Cheater_Detection.Utils.DetectorUtils")
local Events          = require("Cheater_Detection.Core.Events")
local G               = require("Cheater_Detection.Utils.Globals")
local PlayerCache     = require("Cheater_Detection.Core.player_cache")

local AntiAim         = {}

-- Config
local MAX_LEGIT_PITCH = 90
local HIT_WEIGHT      = 0.34
local DECAY_PER_TICK  = 0.05
local FLAG_THRESHOLD  = 1.0

-- State: playerID -> {score, lastDecay}
local pitchScores     = {}

-- Get unclamped pitch from tfnonlocaldata (server angles before client clamping)
-- This is the ONLY way to detect anti-aim, as viewangles are clamped to ±90
local function GetPitch(entity)
	if not entity then return nil end
	local angles = entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
	if angles then return angles.x end
	return nil
end

-- Apply time-based decay to score
local function ApplyDecay(state)
	local now = globals.RealTime()
	local elapsed = now - (state.lastDecay or now)
	if elapsed > 0 then
		local ticks = math.floor(elapsed / globals.TickInterval())
		state.score = math.max(0, state.score - (DECAY_PER_TICK * ticks))
		state.lastDecay = now
	end
end

function AntiAim.ProcessPlayer(playerState, cmd)
	if not playerState or not playerState.id then return end
	if not Common.IsPlayerConnected() then return end
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.AntiAim) then return end
	if playerState.id:sub(1, 4) == "BOT_" then return end

	local pdata = playerState.pdata
	if not pdata or not pdata.isAlive or pdata.isDormant then return end

	-- Skip friends and local player
	if not Common.IsDebugEnabled() then
		if playerState.isFriend or playerState.id == PlayerCache.GetLocalID() then
			return
		end
	end

	-- Already flagged
	if (playerState.flags & Constants.Flags.CHEATER) ~= 0 then return end

	-- Get state
	local state = pitchScores[playerState.id]
	if not state then
		state = { score = 0, lastDecay = globals.RealTime() }
		pitchScores[playerState.id] = state
	end

	-- Apply decay
	ApplyDecay(state)

	-- Get pitch from entity
	local pitch = GetPitch(playerState.wrap:GetEntity())
	if not pitch then return end

	-- Check for invalid pitch (90 or -90 exactly = AA)
	if pitch >= MAX_LEGIT_PITCH or pitch <= -MAX_LEGIT_PITCH then
		state.score = state.score + HIT_WEIGHT

		if state.score >= FLAG_THRESHOLD then
			DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER,
				string.format("Invalid pitch (%.1f°)", pitch))
			pitchScores[playerState.id] = nil
		end
	end
end

-- Cleanup
Events.Subscribe("OnPlayerDisconnect", function(id) pitchScores[id] = nil end)
Events.Subscribe("OnPlayerRemoved", function(id) pitchScores[id] = nil end)

return AntiAim
