local Default_Config = {
	currentTab = "Main",

	Main = {
		Fetch_Database = true,
		AutoFetch = true,
		Chat_Prefix = true,
		Cheater_Tags = true,
		TagFilters = { true, true, true, true }, -- [1]=Valve [2]=Cheater [3]=VAC [4]=Sus
		AutoSync = true,                   -- Automatically fetch databases on startup
		ValveCheck = true,                 -- Valve employee detection
	},

	Scanner = {
		SteamHistory = true,
		ValveCheck = true,
	},

	Advanced = {
		Evidence_Tolerance = 15,            -- Evidence score threshold to mark as cheater (lowered for testing)
		AutoPriority = true,
		LogLevel = { false, true, false, false }, -- [Debug, Info, Warning, Error] (default: Info)
		debug = false,                      -- Debug mode (removes self from database, enables verbose logging)
		profiler = false,                   -- Tick profiler (measure performance, can cause lag)
		-- Detection toggles (only for implemented detections)
		Choke = false,                      -- Fake Lag detection
		Warp = false,                       -- Warp/DT detection
		Bhop = true,                        -- Bunny hop detection
		DuckSpeed = true,                   -- Duck speed detection
		AntiAim = true,                     -- Anti-aim detection
		SilentAimbot = true,                -- Silent aimbot (extrapolation) detection
		Cosmetics = true,                   -- Cosmetic exploit detection
		AimLock = true,                     -- AimLock detection (requires SilentAimbot)
	},

	Notifications = {
		Enable = true,
		SuspicionCooldown = 10, -- Seconds between per-player suspicion update notifications
		Channels = {
			LocalChat = true, -- Only you see it (client.ChatPrintf)
			PublicChat = false, -- Entire server sees it (say)
			Party = true, -- Your party only (say_party)
			Toast = true, -- lnxLib corner pop-up
			Console = true, -- Console print
		},
		Overrides = {
			UseCheaterOverride = false,
			Cheater = {
				LocalChat = true,
				PublicChat = false,
				Party = false,
				Toast = true,
				Console = true,
			},
			UseValveOverride = false,
			Valve = {
				LocalChat = true,
				PublicChat = false,
				Party = false,
				Toast = true,
				Console = true,
			},
		},
		SuspicionThreshold = 30, -- Only notify above this %
	},

	Misc = {
		Autovote = true,
		AutovoteAutoCast = false,
		intent = {
			retaliation = false,
			legit = false,
			cheater = true,
			bot = true,
			valve = false,
			friend = false,
		},
		Vote_Reveal = {
			Enable = true,
			Indicator = true,
			AutoLeaveOnGuaranteedLocalKick = true,
			TargetTeam = {
				MyTeam = true,
				enemyTeam = true,
			},
			Output = {
				PublicChat = false,
				PartyChat = true,
				ClientChat = true,
				Console = true,
			},
		},
		Class_Change_Reveal = {
			Enable = false,
			EnemyOnly = true,
			Output = {
				PublicChat = false,
				PartyChat = true,
				ClientChat = true,
				Console = true,
			},
		},
		Chat_notify = true,
		JoinNotifications = {
			Enable = true,
			CheckCheater = true,
			CheckValve = true,
			ValveAutoDisconnect = true,
			-- Default output channels (used if no override)
			DefaultOutput = {
				LocalChat = true,
				PublicChat = false,
				Party = true,
				Toast = true,
				Console = true,
			},
			-- Cheater-specific overrides
			UseCheaterOverride = false,
			CheaterOverride = {
				LocalChat = true,
				PublicChat = false,
				Party = false,
				Toast = false,
				Console = true,
			},
			-- Valve employee-specific overrides
			UseValveOverride = false,
			ValveOverride = {
				LocalChat = true,
				PublicChat = false,
				Party = true,
				Toast = false,
				Console = true,
			},
		},
		SteamHistory = {
			Enable = false,
			ApiKey = "",
		},
		Privacy = {
			YouFriendTags = true,
			MuteBotChat = false,
			BlockServerMessages = false,
		},
	},
}

return Default_Config
