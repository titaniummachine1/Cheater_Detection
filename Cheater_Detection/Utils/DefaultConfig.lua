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
		SuspicionThreshold = 30,            -- Evidence percent needed to mark suspicious
		Evidence_Tolerance = 85,            -- Evidence percent needed to mark cheater
		AutoPriority = true,
		LogLevel = { false, true, false, false }, -- [Debug, Info, Warning, Error] (default: Info)
		debug = false,                      -- ON = detectors/evidence apply to LOCAL player for self-test; OFF = never scan yourself
		profiler = false,                   -- Performance Profiler (uses global Profiler library)
		-- Detection toggles (only for implemented detections)
		Choke = false,                      -- Fake Lag detection
		DoubleTap = false,                  -- Double tap detection (legacy key: Warp)
		Bhop = true,                        -- Bunny hop detection
		DuckSpeed = true,                   -- Duck speed detection
		AntiAim = true,                     -- Anti-aim detection
		SilentAimbot = false,               -- Disabled pending rework (forced off in Main.lua)
		Cosmetics = true,                   -- Cosmetic exploit detection
		AimLock = false,                    -- Disabled with SilentAimbot until rework
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
