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
}

-- [[ Suspicion Thresholds ]]
Constants.Threshold = {
	SUSPICIOUS = 30, -- Threshold to show "Sus" tag and %
}

-- [[ Engine Constants ]]
Constants.TICKS_PER_SECOND = 66
Constants.DECAY_INTERVAL_SECONDS = 10 -- Base heartbeat decay interval

-- [[ Bitmask for Database Persistence ]]
Constants.PERSISTENT_MASK = Constants.Flags.CHEATER | Constants.Flags.VALVE | Constants.Flags.VAC_BANNED | Constants.Flags.COMM_BANNED | Constants.Flags.SUSPICIOUS

return Constants
