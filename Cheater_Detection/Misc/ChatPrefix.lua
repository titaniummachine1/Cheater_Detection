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
	local maxClients = globals.MaxClients()
	for i = 1, maxClients do
		local info = client.GetPlayerInfo(i)
		if info and info.Name == playerName then
			return entities.GetByIndex(i)
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

	local steamID = tostring(Common.GetSteamID64(player))
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
	local evidence = Evidence.GetDetails(steamID)
	if evidence and evidence.TotalScore and evidence.TotalScore > 0 then
		-- Yellow for suspicious (has evidence but not marked yet)
		return "SUSPICIOUS", { 255, 255, 0 }
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

	-- Read chat data (TF2's actual SayText2 structure)
	local wantsToChat = bf:ReadByte() -- Byte 0-7: wants to chat flag
	local clientIndex = bf:ReadByte() -- Byte 8-15: client index
	local isChat = bf:ReadByte() -- Byte 16-23: chat flag (THIS WAS MISSING!)
	local chatType = bf:ReadString(256) -- Now properly aligned - e.g. "TF_Chat_Team"
	local playerName = bf:ReadString(256)
	local messageText = bf:ReadString(256)

	-- Get player entity
	local player = GetPlayerFromName(playerName)
	if not player then
		return
	end

	-- Get cheater status
	local status, color = GetCheaterStatus(player)

	-- Check if this is a [CD] system message (after getting status to allow override)
	if messageText:find("%[CD%]") then
		-- System message - display without prefix
		if not client.ChatPrintf(messageText) then
			print("[CD] Failed to send system message")
		end

		-- Wipe original payload so nothing extra prints
		ClearBuffer(bf)
		bf:SetCurBit(0)
		return
	end

	if status then
		-- Build colored output for ChatPrintf
		local colorHex = rgbToHex(color[1], color[2], color[3])
		local tag = string.format("\x01[%s%s\x01]", colorHex, status)
		local teamColor = "\x01"
		local team = player:GetTeamNumber()
		if team == 2 then
			teamColor = "\x07FF4040"
		elseif team == 3 then
			teamColor = "\x0799CCFF"
		end
		local name = string.format("%s%s", teamColor, playerName)
		local formatted = string.format("%s %s\x01 :  %s", tag, name, messageText)

		if not client.ChatPrintf(formatted) then
			print("[CD] Failed to send chat prefix message")
		end

		-- Wipe original payload so nothing extra prints
		ClearBuffer(bf)
		bf:SetCurBit(0)
		return
	end
end

--[[ Callbacks ]]
callbacks.Unregister("DispatchUserMessage", "CD_ChatPrefix")
callbacks.Register("DispatchUserMessage", "CD_ChatPrefix", OnUserMessage)

return ChatPrefix
