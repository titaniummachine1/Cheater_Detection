--[[ Join/Leave Notifications for Cheaters and Valve Employees ]]

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local Sources = require("Cheater_Detection.Database.Sources")

--[[ Module Declaration ]]
local JoinNotifications = {}

--[[ Helper Functions ]]

-- Send message to configured output channels
local function SendToChannels(message, outputConfig)
	if not outputConfig then
		return
	end

	-- Public chat
	if outputConfig.PublicChat then
		client.ChatSay(message)
	end

	-- Party/Team chat
	if outputConfig.PartyChat then
		client.ChatTeamSay(message)
	end

	-- Client chat (only visible to you)
	if outputConfig.ClientChat then
		local _ = client.ChatPrintf(message)
	end

	-- Console
	if outputConfig.Console then
		print(message)
	end
end

-- Get effective output config with override support
local function GetEffectiveOutput(defaultOutput, overrideOutput, useOverride)
	if useOverride and overrideOutput then
		return overrideOutput
	end
	return defaultOutput
end

--[[ Event Handlers ]]

-- Handle player connect event
local function OnPlayerConnect(event)
	if event:GetName() ~= "player_connect" then
		return
	end

	local config = G.Menu.Misc.JoinNotifications
	if not config or not config.Enable then
		return
	end

	-- Get player info from event
	local name = event:GetString("name")
	local networkid = event:GetString("networkid")
	local userid = event:GetInt("userid")

	-- Extract SteamID64 from networkid (format: [U:1:XXXXXXXX])
	-- Convert to SteamID64: 76561197960265728 + accountID
	local accountID = networkid:match("%[U:1:(%d+)%]")
	if not accountID then
		return
	end

	local steamID64 = tostring(76561197960265728 + tonumber(accountID))

	-- Check if Valve employee (higher priority)
	if config.CheckValve and Sources.IsValveEmployee(steamID64) then
		local output = GetEffectiveOutput(
			config.DefaultOutput,
			config.ValveOverride,
			config.UseValveOverride
		)

		local message = string.format("[VALVE EMPLOYEE] %s joined the server", name)
		SendToChannels(message, output)

		-- Auto-disconnect if enabled
		if config.ValveAutoDisconnect then
			client.Command("disconnect")
			print("[CD] Auto-disconnected due to Valve employee joining")
		end

		return
	end

	-- Check if cheater in database
	if config.CheckCheater then
		local cheaterData = Database.GetCheater(steamID64)
		if cheaterData then
			local output = GetEffectiveOutput(
				config.DefaultOutput,
				config.CheaterOverride,
				config.UseCheaterOverride
			)

			local reason = cheaterData.Reason or "Unknown"
			local message = string.format("[CHEATER] %s joined - Reason: %s", name, reason)
			SendToChannels(message, output)
		end
	end
end

--[[ Callback Registration ]]
callbacks.Unregister("FireGameEvent", "CD_JoinNotifications")
callbacks.Register("FireGameEvent", "CD_JoinNotifications", OnPlayerConnect)

return JoinNotifications
