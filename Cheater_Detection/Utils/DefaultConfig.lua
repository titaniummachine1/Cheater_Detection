local Default_Config = {
	currentTab = "Main",

	Main = {
		Fetch_Database = true,
		AutoMark = true,
		AutoFetch = true, -- Automatically fetch database on startup
		partyCallaut = true,
		Chat_Prefix = true,
		Cheater_Tags = true,
		JoinWarning = true,
	},

	Advanced = {
		Evicence_Tolerance = 100, -- Evidence score threshold to mark as cheater
		LogLevel = {false, true, false, false}, -- [Debug, Info, Warning, Error] (default: Info)
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
		intent = {
			legit = true,
			cheater = true,
			bot = true,
			friend = false,
		},
		Vote_Reveal = {
			Enable = true,
			TargetTeam = {
				MyTeam = true,
				enemyTeam = true,
			},
			PartyChat = true,
			Console = true,
		},
		Class_Change_Reveal = {
			Enable = true,
			EnemyOnly = true,
			PartyChat = true,
			Console = true,
		},
		Chat_notify = true,
	},
}

return Default_Config
