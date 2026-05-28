--[[ core/constants.lua
     Centralized constants for the new architecture.
]]

local Constants = {}

-- [[ Player States ]]
Constants.Flags = {
	NONE = 0,
	CHECKED = 1,    -- External check done
	SUSPICIOUS = 2, -- (Probabilistic) Score > Threshold
	CHEATER = 4,    -- (Hard) 100% physically impossible feat
	VALVE = 8,      -- Confirmed Valve
	COMM_BANNED = 16, -- Community banned
	VAC_BANNED = 32, -- VAC banned
	HIGH_RISK = 64, -- Extremely likely cheater (Score > 70)
	BOT = 128,      -- Confirmed bot (from bot lists)
	RETALIATION = 256, -- Has retaliation data
}

-- [[ Suspicion Thresholds ]]
Constants.Threshold = {
	SUSPICIOUS = 30, -- Threshold to show "Sus" tag and %
	HIGH_RISK = 70, -- Threshold for high risk decay logic
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
Constants.BHOP_MAX_GROUND_TICKS = 1        -- Frame perfect (0 or 1 tick on ground)
Constants.BHOP_MIN_CONSECUTIVE_SUCCESS = 2 -- How many times in a row it must happen before we start adding score

-- [[ Bitmask for Database Persistence ]]
Constants.PERSISTENT_MASK = Constants.Flags.CHEATER | Constants.Flags.VALVE | Constants.Flags.VAC_BANNED |
	Constants.Flags.COMM_BANNED | Constants.Flags.SUSPICIOUS | Constants.Flags.BOT

-- [[ Source Weight System ]]
-- Higher weight = more authoritative. When multiple sources mark the same player,
-- the highest-weight source's reason is preserved. Lower-weight sources cannot
-- override or dilute higher-weight detections.
Constants.SourceWeights = {
	-- Local real-time detectors (highest authority - physically impossible feats)
	["local_detector"] = 100,
	["manual_flag"] = 95,

	-- Valve official
	["valve_official"] = 110,

	-- VAC / Game Ban confirmed
	["vac_ban"] = 85,

	-- Trusted curated lists (high verification bar)
	["cc_trusted"] = 80,
	["masterbase_broadcasts"] = 79,
	["mega_scat"] = 78,

	-- Established community lists
	["tf2bd_off"] = 75,
	["sleepy_main"] = 65,
	["sleepy_nullc0re"] = 65,
	["d3_cheat"] = 60,
	["qfoxb"] = 55,
	["joekiller"] = 55,


	-- Broader community lists
	["sleepy_ext"] = 40,
	["external_combined"] = 35,
	["tfcl_combined"] = 30,

	-- Bot lists (informational, not cheat-detection)
	["cc_biglist"] = 29,

	-- Unknown / fallback
	["unknown"] = 0,
}

-- [[ Reason Category Weights ]]
-- Used to score reason strings by their semantic category.
-- When comparing two reasons, the one with the higher category weight wins.
-- Patterns are checked in order; first match wins.
Constants.ReasonCategoryWeights = {
	-- Hard cheats (physically impossible)
	{ pattern = "ANGLE ANALYTICAL",        weight = 100 },
	{ pattern = "OBB PITCH",               weight = 100 },
	{ pattern = "SPEEDHACK",               weight = 100 },
	{ pattern = "TICKBASE ABUSE",          weight = 100 },
	{ pattern = "ANTI.AIM",                weight = 98 },
	{ pattern = "anti.aim",                weight = 98 },
	{ pattern = "ANTI_AIM",                weight = 98 },
	{ pattern = "anti_aim",                weight = 98 },
	{ pattern = "Anti-Aim",                weight = 98 },
	{ pattern = "anti-aim",                weight = 98 },
	{ pattern = "AntiAim",                 weight = 98 },
	{ pattern = "Aimbot",                  weight = 98 },
	{ pattern = "aimbot",                  weight = 98 },
	{ pattern = "Silent",                  weight = 97 },
	{ pattern = "silent",                  weight = 97 },
	{ pattern = "Warp",                    weight = 96 },
	{ pattern = "warp",                    weight = 96 },
	{ pattern = "Doubletap",               weight = 96 },
	{ pattern = "doubletap",               weight = 96 },
	{ pattern = "Fake Lag",                weight = 90 },
	{ pattern = "fake_lag",                weight = 90 },
	{ pattern = "Choke",                   weight = 90 },
	{ pattern = "Duck Speed",              weight = 85 },
	{ pattern = "duck_speed",              weight = 85 },
	{ pattern = "Bhop",                    weight = 80 },
	{ pattern = "bhop",                    weight = 80 },

	-- Missing hard cheats (fill gaps)
	{ pattern = "Spinbot",                 weight = 98 },
	{ pattern = "spinbot",                 weight = 98 },
	{ pattern = "Backtrack",               weight = 98 },
	{ pattern = "backtrack",               weight = 98 },
	{ pattern = "Triggerbot",              weight = 97 },
	{ pattern = "triggerbot",              weight = 97 },
	{ pattern = "Trigger",                 weight = 97 },
	{ pattern = "trigger",                 weight = 97 },
	{ pattern = "Wallhack",                weight = 95 },
	{ pattern = "wallhack",                weight = 95 },
	{ pattern = "ESP",                     weight = 95 },
	{ pattern = "esp",                     weight = 95 },
	{ pattern = "Crithack",                weight = 90 },
	{ pattern = "crithack",                weight = 90 },
	{ pattern = "Autostrafe",              weight = 85 },
	{ pattern = "autostrafe",              weight = 85 },
	{ pattern = "Auto strafe",             weight = 85 },
	{ pattern = "auto strafe",             weight = 85 },
	{ pattern = "Resolver",                weight = 90 },
	{ pattern = "resolver",                weight = 90 },
	{ pattern = "Edge Jump",               weight = 80 },
	{ pattern = "edge jump",               weight = 80 },
	{ pattern = "Edge-Jump",               weight = 80 },
	{ pattern = "edge-jump",               weight = 80 },
	{ pattern = "Edgejump",                weight = 80 },
	{ pattern = "edgejump",                weight = 80 },
	{ pattern = "Noisemaker",              weight = 75 },
	{ pattern = "noisemaker",              weight = 75 },
	{ pattern = "Noise maker",             weight = 75 },
	{ pattern = "noise maker",             weight = 75 },

	-- Valve / VAC confirmed
	{ pattern = "VALVe",                   weight = 110 },
	{ pattern = "Valve",                   weight = 110 },
	{ pattern = "VAC",                     weight = 90 },
	{ pattern = "Game Ban",                weight = 88 },

	-- Cheater marks from trusted sources
	{ pattern = "Cheater (TF2BD Trusted)", weight = 85 },
	{ pattern = "Cheater (Rijin)",         weight = 75 },
	{ pattern = "Cheater (Rijin Alias)",   weight = 75 },
	{ pattern = "Cheater (Sleepy",         weight = 65 },
	{ pattern = "Cheater (qfoxb)",         weight = 60 },
	{ pattern = "Cheater (joekiller)",     weight = 60 },
	{ pattern = "Cheater (d3fc0n6)",       weight = 60 },
	{ pattern = "Cheater",                 weight = 50 },

	-- Exploiter marks
	{ pattern = "Exploiter",               weight = 55 },
	{ pattern = "exploiter",               weight = 55 },

	-- Suspicious (lower confidence)
	{ pattern = "Suspicious",              weight = 30 },
	{ pattern = "suspicious",              weight = 30 },

	-- Bot marks (high priority - distinguish bots from real players)
	{ pattern = "Not a Bot",               weight = 0 },
	{ pattern = "not a bot",               weight = 0 },
	{ pattern = "Bot (",                   weight = 85 },
	{ pattern = "BOT SUBMITTED",           weight = 85 },

	-- Generic / low-quality marks
	{ pattern = "TOO MANY INFRACTIONS",    weight = 10 },
	{ pattern = "Racist",                  weight = 5 },
	{ pattern = "racist",                  weight = 5 },
	{ pattern = "Grief",                   weight = 5 },
	{ pattern = "grief",                   weight = 5 },
	{ pattern = "suboptimal",              weight = 2 },
	{ pattern = "Suboptimal",              weight = 2 },

	-- Fallback
	{ pattern = "Unknown",                 weight = 0 },
}

-- [[ Dirty Flags for Change Tracking ]]
-- Used by DirtySystem to track what changed on a player (avoid iterating all players)
Constants.DirtyFlags = {
	NONE = 0,
	SCORE = 1,      -- Score changed (needs visuals update)
	FLAGS = 2,      -- Flags changed (needs visuals + notifications)
	CHECKS = 4,     -- Check flags changed (needs valve_check processing)
	SESSION = 8,    -- Session state changed (needs persistence)
	PRIORITY = 16,  -- Priority changed (needs playerlist update)
	CONNECTED = 32, -- Player just connected (needs init processing)
	DISCONNECTED = 64, -- Player disconnected (needs cleanup)
	ALL = 127,      -- All dirty flags combined
}

return Constants
