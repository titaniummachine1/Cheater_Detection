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

local function NormalizeSteamID64(rawID)
	if not rawID then
		return nil
	end

	local steamID = tostring(rawID)
	if steamID:match("^7656119%d+$") and #steamID == 17 then
		return steamID
	end

	return nil
end

--[[ Helper Functions ]]

local function escapeForCommand(text)
	return text and text:gsub("\\", "\\\\"):gsub('"', '\\"') or ""
end

local function SendPartyChatMessage(message)
	if not message or message == "" then
		return
	end
	client.Command(string.format('say_party "%s"', escapeForCommand(message)), true)
end

-- message configuration table expects:
-- { label = string, labelColor = string (color code), plainPrefix = string, name = string, tail = string, allowParty = boolean }
local function SendAlert(outputConfig, messageConfig)
	if not outputConfig or not messageConfig then
		return
	end

	local label = messageConfig.label or "CHEATER"
	local labelColor = messageConfig.labelColor or "\x07FFFFFF"
	local plainPrefix = messageConfig.plainPrefix or "Player"
	local name = messageConfig.name or "Unknown"
	local tail = messageConfig.tail or ""
	local allowParty = messageConfig.allowParty ~= false

	local tailText = tail ~= "" and (" " .. tail) or ""

	local messagePlain = string.format("%s %s%s", plainPrefix, name, tailText)
	local messageBracketed = string.format("[CD] [%s] %s%s", label, name, tailText)
	local messageColored =
		string.format("\x073EFF3E[CD]\x01 %s[%s]\x01 \x03%s\x01%s", labelColor, label, name, tailText)

	if outputConfig.Console then
		print(messageBracketed)
	end

	local sentToExternalChannel = false
	local allowParty = messageConfig.allowParty
	if allowParty == nil then allowParty = true end

	if allowParty and outputConfig.Party then
		SendPartyChatMessage(messageColored)
		sentToExternalChannel = true
	end

	if outputConfig.PublicChat then
		client.Command(string.format('say "%s"', escapeForCommand(messagePlain)), true)
		sentToExternalChannel = true
	end

	if outputConfig.LocalChat and not sentToExternalChannel then
		if not client.ChatPrintf(messageColored) then
			print("[CD] Failed to send client chat message")
		end
	elseif not outputConfig.PublicChat and not outputConfig.LocalChat then
		-- Ensure local feedback even if only console output was requested
		if not client.ChatPrintf(messageColored) then
			print("[CD] Failed to send fallback client chat message")
		end
	end

	if outputConfig.Toast then
		local ok, lnx = pcall(require, "lnxLib")
		if ok and lnx and lnx.UI and lnx.UI.Notifications then
			pcall(lnx.UI.Notifications.Add, messagePlain)
		end
	end
end

local function GetEffectiveOutput(defaultOutput, overrideOutput, useOverride)
	if useOverride and overrideOutput then
		return overrideOutput
	end
	return defaultOutput
end

local function GetJoinNotificationsConfig()
	local config = G.Menu and G.Menu.Misc and G.Menu.Misc.JoinNotifications
	if not config or not config.Enable then
		return nil
	end

	if type(config.ValveAutoDisconnect) ~= "boolean" then
		return nil
	end

	return config
end

local function DispatchCheaterAlert(config, params)
	if not config or not config.CheckCheater then
		return false
	end

	local reason = params.reason or "Unknown"
	local tail = params.tail or string.format("is in the server (Suspected of: %s)", reason)
	local allowParty = params.allowParty
	if allowParty == nil then
		allowParty = false
	end

	local output = GetEffectiveOutput(config.DefaultOutput, config.CheaterOverride, config.UseCheaterOverride)

	SendAlert(output, {
		label = "CHEATER",
		labelColor = "\x07FF0000",
		plainPrefix = params.plainPrefix or "Cheater",
		name = params.name or "Unknown",
		tail = tail,
		allowParty = allowParty,
	})

	return true
end

local function DispatchValveAlert(config, params)
	if not config or not config.CheckValve then
		return false
	end

	local tail = params.tail or "is in the server"
	local allowParty = params.allowParty
	if allowParty == nil then
		allowParty = false
	end

	local output = GetEffectiveOutput(config.DefaultOutput, config.ValveOverride, config.UseValveOverride)
	SendAlert(output, {
		label = "VALVE",
		labelColor = "\x078650AC",
		plainPrefix = params.plainPrefix or "Valve employee",
		name = params.name or "Unknown",
		tail = tail,
		allowParty = allowParty,
	})

	return true
end

function JoinNotifications.SendCheaterAlert(params)
	local config = GetJoinNotificationsConfig()
	if not config then
		return false
	end

	return DispatchCheaterAlert(config, params or {})
end

function JoinNotifications.SendValveAlert(params)
	local config = GetJoinNotificationsConfig()
	if not config then
		return false
	end

	return DispatchValveAlert(config, params or {})
end

-- Check all players currently in the game for Valve employees and cheaters
-- If Valve found and auto-disconnect enabled, leave server
local function ValidateAllPlayers()
	local config = GetJoinNotificationsConfig()
	if not config then
		return -- Config not fully loaded yet
	end

	local players = entities.FindByClass("CTFPlayer")
	for _, player in ipairs(players) do
		if player and player:IsValid() then
			local steamID64 = NormalizeSteamID64(Common.GetSteamID64(player))
			if steamID64 then
				-- Check Valve employee first (higher priority)
				if config.CheckValve and Sources.IsValveEmployee(steamID64) then
					local alertSent = DispatchValveAlert(config, {
						name = player:GetName(),
						tail = config.ValveAutoDisconnect and "is in the server - Leaving game" or "is in the server",
						allowParty = false,
					})
					if alertSent and config.ValveAutoDisconnect then
						client.Command("disconnect", true)
						return
					end
				-- Check if cheater in database
				elseif config.CheckCheater then
					local cheaterData = Database.GetCheater(steamID64)
					if cheaterData then
						DispatchCheaterAlert(config, {
							name = player:GetName(),
							reason = cheaterData.Reason,
							allowParty = false,
						})
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

	local config = GetJoinNotificationsConfig()
	if not config then
		return
	end

	-- Get player info from event
	local name = event:GetString("name")
	local networkid = event:GetString("networkid")

	-- Extract SteamID64 from networkid (format: [U:1:XXXXXXXX])
	local steamID64 = NormalizeSteamID64(Common.FromSteamid3To64(networkid))
	if not steamID64 then
		return
	end

	-- Check if Valve employee (higher priority)
	if config.CheckValve and Sources.IsValveEmployee(steamID64) then
		local tail = config.ValveAutoDisconnect and "joined - Leaving game" or "joined"
		local alertSent = DispatchValveAlert(config, {
			name = name,
			tail = tail,
			allowParty = false,
		})
		if alertSent and config.ValveAutoDisconnect then
			client.Command("disconnect", true)
		end
		return
	end

	-- Check if cheater in database
	if config.CheckCheater then
		local cheaterData = Database.GetCheater(steamID64)
		if cheaterData then
			local reason = cheaterData.Reason or "Unknown"
			DispatchCheaterAlert(config, {
				name = name,
				reason = reason,
				tail = string.format("joined (Suspected of: %s)", reason),
				allowParty = false,
			})
		end
	end
end

-- Handle player disconnect event
local function OnPlayerDisconnect(event)
	if event:GetName() ~= "player_disconnect" then
		return
	end

	local config = GetJoinNotificationsConfig()
	if not config then
		return
	end

	-- Get player info from event
	local name = event:GetString("name")
	local networkid = event:GetString("networkid")

	-- Extract SteamID64 from networkid (format: [U:1:XXXXXXXX])
	local steamID64 = NormalizeSteamID64(Common.FromSteamid3To64(networkid))
	if not steamID64 then
		return
	end

	-- Don't show disconnect messages for Valve employees (we left the game)
	-- Only check cheaters
	if config.CheckCheater then
		local cheaterData = Database.GetCheater(steamID64)
		if cheaterData then
			local reason = cheaterData.Reason or "Unknown"
			DispatchCheaterAlert(config, {
				name = name,
				reason = reason,
				tail = string.format("left (Suspected of: %s)", reason),
			})
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
