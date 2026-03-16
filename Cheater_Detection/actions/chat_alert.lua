--[[ actions/chat_alert.lua
     Handles chat notifications for detections and state changes.
]]

local EventBus = require("Cheater_Detection.core.event_bus")
local Constants = require("Cheater_Detection.core.constants")

local ChatAlert = {}

local function OnStateChange(playerState, reason)
	local name = playerState.wrap:GetName()
	local id = playerState.id
	local flags = playerState.flags

	-- Individual status checks
	if (flags & Constants.Flags.VALVE) ~= 0 then
		client.ChatPrintf(string.format("\x07FFD700[WARNING]\x01 Valve Employee: \x0700FF00%s \x01(%s)", name, id))
	end

	if (flags & Constants.Flags.CHEATER) ~= 0 then
		client.ChatPrintf(
			string.format(
				"\x07FF0000[DETECTION]\x01 Confirmed Cheater: \x0700FF00%s \x01(%s) \x07AAAAAA[%s]",
				name,
				id,
				reason
			)
		)
	elseif (flags & Constants.Flags.SUSPICIOUS) ~= 0 then
		local displayScore = math.min(99, math.floor(playerState.score))
		client.ChatPrintf(
			string.format(
				"\x07FFD500[SUSPICIOUS]\x01 %s is likely cheating \x07AAAAAA(%d%%) \x01[\x04%s\x01]",
				name,
				displayScore,
				reason
			)
		)
	end

	if (flags & Constants.Flags.VAC_BANNED) ~= 0 then
		client.ChatPrintf(string.format("\x07FFB300[BAN]\x01 %s has a VAC ban on record!", name))
	end

	if (flags & Constants.Flags.COMM_BANNED) ~= 0 then
		client.ChatPrintf(string.format("\x07FFB300[BAN]\x01 %s has a Community/Trade ban!", name))
	end
end

function ChatAlert.Init()
	EventBus.Subscribe("OnPlayerStateChange", OnStateChange)
end

return ChatAlert
