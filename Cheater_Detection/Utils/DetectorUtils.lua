--[[ Utils/DetectorUtils.lua
     Shared helpers used by every detector to eliminate the repeated
     flag-update → database-persist → event-dispatch pattern.
]]

local Constants = require("Cheater_Detection.Core.constants")
local Database = require("Cheater_Detection.Database.Database")
local Events = require("Cheater_Detection.Core.Events")
local DirtySystem = require("Cheater_Detection.Core.DirtySystem")

local DetectorUtils = {}

--- Apply a score increment plus any appropriate flags to a player state, then
--- persist the change to the database and fire OnPlayerStateChange when the
--- flag set actually changes.
---
--- For hard detections (e.g. anti-aim, duck-speed exploit) pass
--- `Constants.Flags.CHEATER` as `hardFlag` and `100` as `score`.
--- For probabilistic detections pass `nil` for `hardFlag` and a small
--- positive number for `scoreIncrement`; the SUSPICIOUS / HIGH_RISK flags
--- are set automatically based on the resulting total score.
---
---@param playerState  table   The active player-cache entry for this player.
---@param scoreIncrement number Score points to add (capped at 99 for probabilistic,
---                             or overridden to 100 for CHEATER flag).
---@param hardFlag     number|nil  A Constants.Flags value to force-set directly
---                               (e.g. CHEATER).  When nil only threshold flags are applied.
---@param reason       string  Human-readable detection reason (stored in DB).
---@return boolean flagsChanged  True when the flag set changed (new threshold crossed).
function DetectorUtils.ApplyPlayerFlag(playerState, scoreIncrement, hardFlag, reason)
	local oldFlags = playerState.flags
	local oldScore = playerState.score or 0

	if hardFlag then
		if (hardFlag & Constants.Flags.CHEATER) ~= 0 then
			playerState.flags = playerState.flags & ~Constants.Flags.SUSPICIOUS
			playerState.flags = playerState.flags & ~Constants.Flags.HIGH_RISK
		end
		playerState.flags = playerState.flags | hardFlag
		playerState.score = 100
	else
		local nextScore = (playerState.score or 0) + (scoreIncrement or 0)
		playerState.score = math.max(0, math.min(99, nextScore))

		if playerState.score >= Constants.Threshold.HIGH_RISK then
			playerState.flags = playerState.flags | Constants.Flags.HIGH_RISK
			playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
		elseif playerState.score >= Constants.Threshold.SUSPICIOUS then
			playerState.flags = playerState.flags | Constants.Flags.SUSPICIOUS
		end
	end

	local effectiveReason = reason
	if not hardFlag and scoreIncrement and scoreIncrement < 0 then
		local existing = Database.GetCheater(playerState.id)
		if existing and type(existing.Reason) == "string" and existing.Reason ~= "" then
			effectiveReason = existing.Reason
		end
	end

	Database.UpsertCheater(playerState.id, {
		name = playerState.wrap:GetName(),
		reason = effectiveReason,
		flags = playerState.flags,
		score = playerState.score,
	})

	local flagsChanged = playerState.flags ~= oldFlags
	local scoreChanged = playerState.score ~= (oldScore or 0)
	
	-- Auto-mark dirty for systems that need to react to changes
	if flagsChanged or scoreChanged then
		local dirtyMask = 0
		if flagsChanged then
			dirtyMask = dirtyMask | DirtySystem.FLAGS.FLAGS
		end
		if scoreChanged then
			dirtyMask = dirtyMask | DirtySystem.FLAGS.SCORE
		end
		-- Mark for session persistence - player data changed
		dirtyMask = dirtyMask | DirtySystem.FLAGS.SESSION
		DirtySystem.MarkDirty(playerState.id, dirtyMask)
	end
	
	if flagsChanged then
		Events.Publish("OnPlayerStateChange", playerState, reason)
	end

	return flagsChanged
end

return DetectorUtils
