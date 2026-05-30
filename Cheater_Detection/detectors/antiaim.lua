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

-- Fast check: returns true if this player needs anti-aim checking.
-- Skips: bots, already flagged cheaters, friends, local player, dormant/dead
function AntiAim.HasWork(playerState)
	if not playerState or not playerState.id then return false end
	local id = playerState.id

	-- Skip bots
	if id:sub(1, 4) == "BOT_" then return false end

	-- Skip already flagged cheaters (no point re-checking)
	if (playerState.flags & Constants.Flags.CHEATER) ~= 0 then return false end

	local pdata = playerState.pdata
	if not pdata or not pdata.isAlive or pdata.isDormant then return false end

	-- Skip friends and local player (unless debug)
	if not Common.IsDebugEnabled() then
		if playerState.isFriend or id == PlayerCache.GetLocalID() then
			return false
		end
	end

	return true
end

function AntiAim.ProcessPlayer(playerState, cmd)
	if not playerState or not playerState.id then return end
	if not Common.IsPlayerConnected() then return end
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.AntiAim) then return end

	-- Fast path: HasWork checks all skip conditions
	if not AntiAim.HasWork(playerState) then return end

	local id = playerState.id

	-- Get state (or create if tracking)
	local state = pitchScores[id]
	if not state then
		state = { score = 0, lastDecay = globals.RealTime() }
		pitchScores[id] = state
	end

	-- Apply decay
	ApplyDecay(state)

	-- Get pitch from entity (only expensive call)
	local pitch = GetPitch(playerState.wrap:GetEntity())
	if not pitch then return end

	-- Check for invalid pitch (90 or -90 exactly = AA)
	if pitch >= MAX_LEGIT_PITCH or pitch <= -MAX_LEGIT_PITCH then
		state.score = state.score + HIT_WEIGHT

		if state.score >= FLAG_THRESHOLD then
			DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER,
				string.format("Invalid pitch (%.1f°)", pitch))
			pitchScores[id] = nil
		end
	end
end

-- Cleanup
Events.Subscribe("OnPlayerDisconnect", function(id) pitchScores[id] = nil end)
Events.Subscribe("OnPlayerRemoved", function(id) pitchScores[id] = nil end)

return AntiAim
