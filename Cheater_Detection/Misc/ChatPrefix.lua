--[[ Cheater Detection - Chat Prefix Module ]]
-- Displays colored status tags before cheater names in chat

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Database = require("Cheater_Detection.Database.Database")
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")

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
	local hexadecimal = "\x07"

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

	return hexadecimal
end

---Clear the entire bit buffer
---@param bf BitBuffer
local function ClearBuffer(bf)
	local len = bf:GetDataBitsLength()
	bf:SetCurBit(0)
	for i = 0, len do
		bf:WriteBit(0)
	end
	bf:SetCurBit(0)
end

---Get cheater status for a player
---@param player Entity
---@return string|nil status "CHEATER", "SUSPICIOUS", "VALVE" or nil
---@return table color RGB color {r, g, b}
local function GetCheaterStatus(player)
	if not player then
		return nil, { 255, 255, 255 }
	end

	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return nil, { 255, 255, 255 }
	end

	-- Check if Valve employee first (takes priority)
	local isValve, valveName = ValveEmployees.IsValveEmployee(steamID)
	if isValve then
		-- Purple for Valve employee (Valve quality item color #8650AC)
		return "VALVE", { 134, 80, 172 }
	end

	-- Check if marked by Evidence system
	local isMarkedCheater = Evidence.IsMarkedCheater(steamID)

	-- Check if player is in database
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

	bf:SetCurBit(0)

	-- Read chat data (must skip 2 bytes first to avoid invisible char in chatType)
	local wantsToChat = bf:ReadByte() -- Byte 0-7: wants to chat flag
	local clientIndex = bf:ReadByte() -- Byte 8-15: client index
	local chatType = bf:ReadString(256) -- Now clean (no invisible char) - e.g. "TF_Chat_Team"
	local playerName = bf:ReadString(256)
	local messageText = bf:ReadString(256)

	-- Get player entity
	local player = GetPlayerFromName(playerName)
	if not player then
		return
	end

	-- Get cheater status
	local status, color = GetCheaterStatus(player)

	if status then
		-- Build complete colored string with full control
		local colorHex = rgbToHex(color[1], color[2], color[3])

		-- Get team color
		local teamColor = "\x01" -- Default white
		local playerTeam = player:GetTeamNumber()
		if playerTeam == 2 then
			teamColor = "\x07FF4040" -- RED team
		elseif playerTeam == 3 then
			teamColor = "\x0799CCFF" -- BLU team
		end

		-- Detect team chat based on chatType
		local teamPrefix = ""
		if chatType ~= "TF_Chat_All" and chatType ~= "" then
			-- Team message - add (Team) prefix
			-- Note: Can't get exact localized text, but we know it's team chat
			teamPrefix = "\x01(Team) "
		end

		-- Build message with colored tag
		local tag = string.format("\x01[%s%s\x01]", colorHex, status)
		local chatMessage = string.format("%s%s %s%s\x01 :  %s", teamPrefix, tag, teamColor, playerName, messageText)

		-- Print to chat and clear original
		client.ChatPrintf(chatMessage)

		-- Clear original message so it doesn't show
		ClearBuffer(bf)
		bf:SetCurBit(0)
		bf:WriteByte(wantsToChat)
		bf:WriteByte(clientIndex)
		bf:WriteString("")
	end
end

--[[ Callbacks ]]
callbacks.Unregister("DispatchUserMessage", "CD_ChatPrefix")
callbacks.Register("DispatchUserMessage", "CD_ChatPrefix", OnUserMessage)

return ChatPrefix
