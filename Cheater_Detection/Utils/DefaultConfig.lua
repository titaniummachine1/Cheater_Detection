local Default_Config = {
	currentTab = "Main",

	Main = {
		Fetch_Database = true,
		AutoPriority = true, -- Auto set priority 10 on detected cheaters
		AutoFetch = true, -- Automatically fetch database on startup
		LastFetchTimestamp = 0,
		partyCallaut = true,
		Chat_Prefix = true,
		Cheater_Tags = true,
	},

	Advanced = {
		Evicence_Tolerance = 100, -- Evidence score threshold to mark as cheater
		LogLevel = { false, true, false, false }, -- [Debug, Info, Warning, Error] (default: Info)
		debug = false, -- Debug mode (removes self from database, enables verbose logging)
		-- Detection toggles (only for implemented detections)
		Choke = true, -- Fake Lag detection
		Warp = true, -- Warp/DT detection
		Bhop = true, -- Bunny hop detection
		DuckSpeed = true, -- Duck speed detection
		AntyAim = true, -- Anti-aim detection
		SilentAimbot = true, -- Silent aimbot (extrapolation) detection
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
				PublicChat = false,
				PartyChat = false,
				ClientChat = true,
				Console = true,
			},
			-- Cheater-specific overrides
			UseCheaterOverride = false,
			CheaterOverride = {
				PublicChat = false,
				PartyChat = false,
				ClientChat = true,
				Console = true,
			},
			-- Valve employee-specific overrides
			UseValveOverride = false,
			ValveOverride = {
				PublicChat = false,
				PartyChat = true,
				ClientChat = true,
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
