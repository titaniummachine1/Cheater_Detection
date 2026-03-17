--[[ actions/chat_alert.lua
     Handles chat notifications for detections and state changes.
]]

local Events = require("Cheater_Detection.Core.Events")
local Constants = require("Cheater_Detection.Core.constants")

local ChatAlert = {}

local function OnStateChange(playerState, reason)
	local name = playerState.wrap:GetName()
	local id = playerState.id
	local flags = playerState.flags

	-- Individual status checks
	if (flags & Constants.Flags.VALVE) ~= 0 then
		local msg = string.format("\x07FFD700[WARNING]\x01 Valve Employee: \x0700FF00%s \x01(%s)", name, id)
		client.ChatPrintf("%s", msg) ---@diagnostic disable-line: redundant-parameter
	end

	if (flags & Constants.Flags.CHEATER) ~= 0 then
		local msg = string.format(
			"\x07FF0000[DETECTION]\x01 Confirmed Cheater: \x0700FF00%s \x01(%s) \x07AAAAAA[%s]",
			name,
			id,
			reason
		)
		client.ChatPrintf("%s", msg) ---@diagnostic disable-line: redundant-parameter
	elseif (flags & Constants.Flags.SUSPICIOUS) ~= 0 then
		local displayScore = math.min(99, math.floor(playerState.score))
		local msg = string.format(
			"\x07FFD500[SUSPICIOUS]\x01 %s is likely cheating \x07AAAAAA(%d pct) \x01[\x04%s\x01]",
			name,
			displayScore,
			reason
		)
		client.ChatPrintf("%s", msg) ---@diagnostic disable-line: redundant-parameter
	end

	if (flags & Constants.Flags.VAC_BANNED) ~= 0 then
		local msg = string.format("\x07FFB300[BAN]\x01 %s has a VAC ban on record!", name)
		client.ChatPrintf("%s", msg) ---@diagnostic disable-line: redundant-parameter
	end

	if (flags & Constants.Flags.COMM_BANNED) ~= 0 then
		local msg = string.format("\x07FFB300[BAN]\x01 %s has a Community/Trade ban!", name)
		client.ChatPrintf("%s", msg) ---@diagnostic disable-line: redundant-parameter
	end
end

function ChatAlert.Init()
	Events.Subscribe("OnPlayerStateChange", OnStateChange)
end

return ChatAlert
