--[[ Cheater Detection - Chat Prefix Module ]]
-- Displays colored status tags before cheater names in chat

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Database = require("Cheater_Detection.Database.Database")

local ChatPrefix = {}

-- SayText2 message ID from E_UserMessage enum
local SayText2 = 4

---@param playerName string
---@return Entity?
local function GetPlayerFromName(playerName)
	for _, player in pairs(entities.FindByClass("CTFPlayer")) do
		if player:GetName() == playerName then
			return player
		end
	end
	return nil
end

---Convert RGB to hex color code for Source engine
---@param r number Red (0-255)
---@param g number Green (0-255)
---@param b number Blue (0-255)
---@return string Hex color code
local function rgbToHex(r, g, b)
	local hexadecimal = string.char(7) -- Use char(7) instead of \x07

	for _, value in pairs({ r, g, b }) do
		local hex = ""

		while value > 0 do
			local index = math.fmod(value, 16) + 1
			value = math.floor(value / 16)
			hex = string.sub("0123456789ABCDEF", index, index) .. hex
		end

		if string.len(hex) == 0 then
			hex = "00"
		elseif string.len(hex) == 1 then
			hex = "0" .. hex
		end

		hexadecimal = hexadecimal .. hex
	end

	print("DEBUG: rgbToHex result length=" .. #hexadecimal)
	return hexadecimal
end

---Change the message contents in the bit buffer
---@param bf BitBuffer
---@param text string
local function ChangeMessageContents(bf, text)
	if not bf or type(text) ~= "string" then
		print("DEBUG: ChangeMessageContents - invalid input!")
		return
	end

	print("DEBUG: ChangeMessageContents - writing string length=" .. #text)
	print("DEBUG: ChangeMessageContents - text bytes:")
	for i = 1, #text do
		print(string.format("  [%d] = %d (%s)", i, string.byte(text, i), string.sub(text, i, i)))
	end

	bf:SetCurBit(16)
	bf:WriteString(text)
	print("DEBUG: ChangeMessageContents - WriteString complete")
end

---Get cheater status for a player
---@param player Entity
---@return string|nil status "CHEATER" or "SUSPICIOUS" or nil
---@return table color RGB color {r, g, b}
local function GetCheaterStatus(player)
	if not player then
		return nil, { 255, 255, 255 }
	end

	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return nil, { 255, 255, 255 }
	end

	-- Check if marked by Evidence system
	local isMarkedCheater = Evidence.IsMarkedCheater(steamID)

	-- Check if in database
	local dbEntry = Database.GetCheater(steamID)
	local inDatabase = dbEntry ~= nil

	if isMarkedCheater or inDatabase then
		-- Red for confirmed cheater
		return "CHEATER", { 255, 0, 0 }
	end

	-- Check if has some evidence (suspicious)
	if G.PlayerData[steamID] and G.PlayerData[steamID].Evidence then
		local evidence = G.PlayerData[steamID].Evidence
		if evidence.TotalScore and evidence.TotalScore > 0 then
			-- Yellow for suspicious
			return "SUSPICIOUS", { 255, 255, 0 }
		end
	end

	return nil, { 255, 255, 255 }
end

---UserMessage callback to modify chat messages
---@param msg UserMessage
local function OnUserMessage(msg)
	-- Check if feature is enabled
	if not G.Menu or not G.Menu.Main or not G.Menu.Main.Chat_Prefix then
		return
	end

	-- Only process SayText2 messages (chat)
	if msg:GetID() ~= SayText2 then
		return
	end

	local bf = msg:GetBitBuffer()
	if not bf then
		return
	end

	bf:SetCurBit(8)

	-- Read chat data
	local chatType = string.sub(bf:ReadString(256), 2) -- Remove invisible char
	local playerName = bf:ReadString(256)
	local messageText = bf:ReadString(256)

	-- DEBUG: Print all received data
	print("=== CHAT DEBUG ===")
	print("chatType: " .. tostring(chatType))
	print("playerName: " .. tostring(playerName))
	print("messageText: " .. tostring(messageText))
	print("messageText length: " .. tostring(#messageText))

	-- Get player entity
	local player = GetPlayerFromName(playerName)
	if not player then
		print("DEBUG: Player entity not found!")
		return
	end

	-- Get cheater status
	local status, color = GetCheaterStatus(player)
	print("DEBUG: status=" .. tostring(status))

	if status then
		-- Build colored status tag
		local colorHex = rgbToHex(color[1], color[2], color[3])
		print("DEBUG: colorHex=" .. tostring(colorHex))

		-- Check if team message
		local isTeamMessage = chatType ~= "TF_Chat_All"
		print("DEBUG: isTeamMessage=" .. tostring(isTeamMessage))

		-- Build message: [COLORED_TAG] PlayerName :  message (chatType is NOT included in display)
		local newMessage = string.format("%s[%s]\x01 %s :  %s", colorHex, status, playerName, messageText)

		if isTeamMessage then
			newMessage = "(Team) " .. newMessage
		end

		print("DEBUG: final newMessage=" .. tostring(newMessage))
		ChangeMessageContents(bf, newMessage)
		print("=== END DEBUG ===")
	else
		print("DEBUG: No cheater status, not modifying message")
	end
end

--[[ Callbacks ]]
callbacks.Unregister("DispatchUserMessage", "CD_ChatPrefix")
callbacks.Register("DispatchUserMessage", "CD_ChatPrefix", OnUserMessage)

return ChatPrefix
