--[[ core/constants.lua
     Centralized constants for the new architecture.
]]

local Constants = {}

-- [[ Player States ]]
Constants.Flags = {
	NONE = 0,
	CHECKED = 1, -- External check done
	SUSPICIOUS = 2, -- (Probabilistic) Score > Threshold
	CHEATER = 4, -- (Hard) 100% physically impossible feat
	VALVE = 8, -- Confirmed Valve
	COMM_BANNED = 16, -- Community banned
	VAC_BANNED = 32, -- VAC banned
	HIGH_RISK = 64, -- Extremely likely cheater (Score > 70)
}

-- [[ Suspicion Thresholds ]]
Constants.Threshold = {
	SUSPICIOUS = 30, -- Threshold to show "Sus" tag and %
	HIGH_RISK = 70,   -- Threshold for high risk decay logic
}

-- [[ Engine Constants ]]
Constants.DECAY_INTERVAL_SECONDS = 10 -- Base heartbeat decay interval

-- [[ Dynamic Tick Conversion ]]
-- Converts a duration in seconds to the equivalent tick count for the current tick rate.
-- Formula: math.floor(seconds / globals.TickInterval() + 0.5)
-- This ensures correctness if the server tick rate differs from the standard 66 Hz.
function Constants.SecondsToTicks(seconds)
	return math.floor(seconds / globals.TickInterval() + 0.5)
end

-- [[ Bhop Detection ]] 
Constants.BHOP_MAX_GROUND_TICKS = 1 -- Frame perfect (0 or 1 tick on ground)
Constants.BHOP_MIN_CONSECUTIVE_SUCCESS = 2 -- How many times in a row it must happen before we start adding score

-- [[ Bitmask for Database Persistence ]]
Constants.PERSISTENT_MASK = Constants.Flags.CHEATER | Constants.Flags.VALVE | Constants.Flags.VAC_BANNED | Constants.Flags.COMM_BANNED | Constants.Flags.SUSPICIOUS

return Constants
