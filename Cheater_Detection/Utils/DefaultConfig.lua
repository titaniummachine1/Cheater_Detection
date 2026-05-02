local Default_Config = {
	currentTab = "Main",

	Main = {
		Fetch_Database = true,
		AutoPriority = true,
		AutoFetch = true,
		partyCallaut = true,
		Chat_Prefix = true,
		Cheater_Tags = true,
		TagFilters = { true, true, true, true }, -- [1]=Valve [2]=Cheater [3]=VAC [4]=Sus
		AutoSync = true, -- Automatically fetch databases on startup
	},

	Scanner = {
		SteamHistory = false,
		ValveCheck = true,
	},

	Advanced = {
		Evidence_Tolerance = 100, -- Evidence score threshold to mark as cheater
		LogLevel = { false, true, false, false }, -- [Debug, Info, Warning, Error] (default: Info)
		debug = false, -- Debug mode (removes self from database, enables verbose logging)
		-- Detection toggles (only for implemented detections)
		Choke = true, -- Fake Lag detection
		Warp = true, -- Warp/DT detection
		Bhop = true, -- Bunny hop detection
		DuckSpeed = true, -- Duck speed detection
		AntiAim = true, -- Anti-aim detection
		SilentAimbot = true, -- Silent aimbot (extrapolation) detection
	},

	Notifications = {
		Enable = true,
		SuspicionCooldown = 10, -- Seconds between per-player suspicion update notifications
		Channels = {
			LocalChat = true, -- Only you see it (client.ChatPrintf)
			PublicChat = false, -- Entire server sees it (say)
			Party = false, -- Your party only (say_party)
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
		AutovoteAutoCast = true,
		intent = {
			legit = true,
			cheater = true,
			bot = true,
			valve = true,
			friend = false,
		},
		Vote_Reveal = {
			Enable = true,
			Indicator = true,
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
			ValveAutoDisconnect = false,
			-- Default output channels (used if no override)
			DefaultOutput = {
				LocalChat = true,
				PublicChat = false,
				Party = false,
				Toast = false,
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
	},
}

return Default_Config
