--[[ Join/Leave Notifications for Cheaters and Valve Employees ]]

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local Sources = require("Cheater_Detection.Database.Sources")
local Common = require("Cheater_Detection.Utils.Common")

--[[ Module Declaration ]]
local JoinNotifications = {}

--[[ State ]]
local hasValidatedOnLoad = false

--[[ Helper Functions ]]

-- Send message to configured output channels
-- messageBracketed: includes [CHEATER] or [VALVE EMPLOYEE] prefix
-- messagePlain: plain text for public/party (no brackets to avoid ChatPrefix interference)
local function SendToChannels(messageBracketed, messagePlain, outputConfig)
	if not outputConfig then
		return
	end

	-- Client chat (only visible to you) - use bracketed version
	if outputConfig.ClientChat then
		if not client.ChatPrintf(messageBracketed) then
			print("[CD] Failed to send client chat message")
		end
	end

	-- Public chat (visible to everyone) - use plain to avoid ChatPrefix double-prefix
	if outputConfig.PublicChat then
		client.ChatSay(messagePlain)
	end

	-- Party/Team chat - use plain to avoid ChatPrefix double-prefix
	if outputConfig.PartyChat then
		client.ChatTeamSay(messagePlain)
	end

	-- Console - use bracketed version
	if outputConfig.Console then
		print(messageBracketed)
	end
end

-- Get effective output config with override support
local function GetEffectiveOutput(defaultOutput, overrideOutput, useOverride)
	if useOverride and overrideOutput then
		return overrideOutput
	end
	return defaultOutput
end

-- Check all players currently in the game for Valve employees and cheaters
-- If Valve found and auto-disconnect enabled, leave server
local function ValidateAllPlayers()
	local config = G.Menu and G.Menu.Misc and G.Menu.Misc.JoinNotifications
	if not config or not config.Enable then
		return
	end

	-- Safety check: ensure ValveAutoDisconnect is a boolean (config loaded)
	if type(config.ValveAutoDisconnect) ~= "boolean" then
		return -- Config not fully loaded yet
	end

	local players = entities.FindByClass("CTFPlayer")
	for _, player in ipairs(players) do
		if player and player:IsValid() then
			local steamID64 = Common.GetSteamID64(player)
			if steamID64 then
				-- Check Valve employee first (higher priority)
				if config.CheckValve and Sources.IsValveEmployee(steamID64) then
					local output = GetEffectiveOutput(
						config.DefaultOutput,
						config.ValveOverride,
						config.UseValveOverride
					)
					
					-- Show notification
					if config.ValveAutoDisconnect then
						local msgBracket = string.format("[VALVE EMPLOYEE] %s is in the server - Leaving game", player:GetName())
						local msgPlain = string.format("Valve employee %s is in the server - Leaving game", player:GetName())
						SendToChannels(msgBracket, msgPlain, output)
						-- Leave the game
						client.Command("disconnect", true)
						return
					else
						local msgBracket = string.format("[VALVE EMPLOYEE] %s is in the server", player:GetName())
						local msgPlain = string.format("Valve employee %s is in the server", player:GetName())
						SendToChannels(msgBracket, msgPlain, output)
					end
				-- Check if cheater in database
				elseif config.CheckCheater then
					local cheaterData = Database.GetCheater(steamID64)
					if cheaterData then
						local output = GetEffectiveOutput(
							config.DefaultOutput,
							config.CheaterOverride,
							config.UseCheaterOverride
						)

						local reason = cheaterData.Reason or "Unknown"
						local msgBracket = string.format("[CHEATER] %s is in the server (Suspected of: %s)", player:GetName(), reason)
						local msgPlain = string.format("Cheater %s is in the server (Suspected of: %s)", player:GetName(), reason)
						SendToChannels(msgBracket, msgPlain, output)
					end
				end
			end
		end
	end
end

--[[ Event Handlers ]]

-- Handle player connect event
local function OnPlayerConnect(event)
	if event:GetName() ~= "player_connect" then
		return
	end

	local config = G.Menu and G.Menu.Misc and G.Menu.Misc.JoinNotifications
	if not config or not config.Enable then
		return
	end

	-- Safety check: ensure config is fully loaded
	if type(config.ValveAutoDisconnect) ~= "boolean" then
		return
	end

	-- Get player info from event
	local name = event:GetString("name")
	local networkid = event:GetString("networkid")
	
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

		-- Show notification and optionally leave
		if config.ValveAutoDisconnect then
			local msgBracket = string.format("[VALVE EMPLOYEE] %s joined - Leaving game", name)
			local msgPlain = string.format("Valve employee %s joined - Leaving game", name)
			SendToChannels(msgBracket, msgPlain, output)
			-- Leave the game
			client.Command("disconnect", true)
		else
			local msgBracket = string.format("[VALVE EMPLOYEE] %s joined", name)
			local msgPlain = string.format("Valve employee %s joined", name)
			SendToChannels(msgBracket, msgPlain, output)
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
			local msgBracket = string.format("[CHEATER] %s joined (Suspected of: %s)", name, reason)
			local msgPlain = string.format("Cheater %s joined (Suspected of: %s)", name, reason)
			SendToChannels(msgBracket, msgPlain, output)
		end
	end
end

-- Handle player disconnect event
local function OnPlayerDisconnect(event)
	if event:GetName() ~= "player_disconnect" then
		return
	end

	local config = G.Menu and G.Menu.Misc and G.Menu.Misc.JoinNotifications
	if not config or not config.Enable then
		return
	end

	-- Safety check: ensure config is fully loaded
	if type(config.ValveAutoDisconnect) ~= "boolean" then
		return
	end

	-- Get player info from event
	local name = event:GetString("name")
	local networkid = event:GetString("networkid")
	
	-- Extract SteamID64 from networkid (format: [U:1:XXXXXXXX])
	local accountID = networkid:match("%[U:1:(%d+)%]")
	if not accountID then
		return
	end

	local steamID64 = tostring(76561197960265728 + tonumber(accountID))

	-- Don't show disconnect messages for Valve employees (we left the game)
	-- Only check cheaters
	if config.CheckCheater then
		local cheaterData = Database.GetCheater(steamID64)
		if cheaterData then
			local output = GetEffectiveOutput(
				config.DefaultOutput,
				config.CheaterOverride,
				config.UseCheaterOverride
			)

			local detectionReason = cheaterData.Reason or "Unknown"
			local msgBracket = string.format("[CHEATER] %s left (Suspected of: %s)", name, detectionReason)
			local msgPlain = string.format("Cheater %s left (Suspected of: %s)", name, detectionReason)
			SendToChannels(msgBracket, msgPlain, output)
		end
	end
end

-- Master event handler for both connect and disconnect
local function OnGameEvent(event)
	local eventName = event:GetName()
	
	if eventName == "player_connect" then
		OnPlayerConnect(event)
	elseif eventName == "player_disconnect" then
		OnPlayerDisconnect(event)
	end
end

--[[ CreateMove Callback for Initial Validation ]]
local function OnCreateMove()
	-- Run validation once on first tick after config is loaded
	if not hasValidatedOnLoad then
		local config = G.Menu and G.Menu.Misc and G.Menu.Misc.JoinNotifications
		-- Check if config is loaded (has boolean ValveAutoDisconnect)
		if config and type(config.ValveAutoDisconnect) == "boolean" then
			ValidateAllPlayers()
			hasValidatedOnLoad = true
			-- Unregister after first run
			callbacks.Unregister("CreateMove", "CD_JoinNotifications_Init")
		end
	end
end

--[[ Callback Registration ]]
callbacks.Unregister("FireGameEvent", "CD_JoinNotifications")
callbacks.Register("FireGameEvent", "CD_JoinNotifications", OnGameEvent)

-- Register CreateMove to validate existing players on first tick
callbacks.Unregister("CreateMove", "CD_JoinNotifications_Init")
callbacks.Register("CreateMove", "CD_JoinNotifications_Init", OnCreateMove)

return JoinNotifications
