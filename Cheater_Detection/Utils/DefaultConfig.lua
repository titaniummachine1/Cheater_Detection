local Default_Config = {
	currentTab = "Main",

	Main = {
		Fetch_Database = true,
		AutoMark = true,
		AutoFetch = true, -- Automatically fetch database on startup
		partyCallaut = true,
		Chat_Prefix = true,
		Cheater_Tags = true,
	},

	Advanced = {
		Evicence_Tolerance = 100, -- Evidence score threshold to mark as cheater
		LogLevel = { false, true, false, false }, -- [Debug, Info, Warning, Error] (default: Info)
		debug = false, -- Debug mode (removes self from database, enables verbose logging)
		Choke = true, --fakelag
		Warp = true,
		Bhop = true,
		Aimbot = {
			enable = true,
			silent = true,
			plain = true,
			smooth = true,
		},
		triggerbot = true,
		AntyAim = true,
		DuckSpeed = true,
		Strafe_bot = true,
	},

	Misc = {
		Autovote = true,
		AutovoteAutoCast = false,
		AutovoteVoteNo = false,
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
			-- Backwards compatibility
			PartyChat = true,
			Console = true,
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
			-- Backwards compatibility
			PartyChat = true,
			Console = true,
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
				PartyChat = true,
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
	},
}

return Default_Config
