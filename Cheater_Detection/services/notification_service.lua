--[[ services/notification_service.lua
     Centralized notification system for all detections.
     
     Channels:
       LocalChat  = client.ChatPrintf   (only you see it)
       PublicChat = client.Command("say ...")  (whole server sees it)
       Party      = client.Command("tf_party_chat ...")
       Toast      = lnxLib UI.Notifications (corner pop-up via optional lnxLib)
       Console    = print()
]]

local EventBus = require("Cheater_Detection.core.event_bus")
local Constants = require("Cheater_Detection.core.constants")
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")

local NotificationService = {}

-- Global rate limiter (safety net against unexpected event bursts)
local lastNotifyTimes = {} -- Array of timestamps for global frequency limiting

-- lnxLib toast helper (safe fallback if lnxLib not loaded)
local lnxNotifs = nil
local function TryGetLNX()
	if lnxNotifs then
		return lnxNotifs
	end
	local ok, lnx = pcall(require, "lnxLib")
	if ok and lnx and lnx.UI and lnx.UI.Notifications then
		lnxNotifs = lnx.UI.Notifications
	end
	return lnxNotifs
end

-- Resolve which channels table to use for a given detection type
local function ResolveChannels(cfg, isValve, isCheater)
	local OV = cfg.Overrides or {}

	if isCheater and OV.UseCheaterOverride and OV.Cheater then
		return OV.Cheater
	end

	if isValve and OV.UseValveOverride and OV.Valve then
		return OV.Valve
	end

	return cfg.Channels
end

-- Send to all requested channels
local function Dispatch(channels, colorMsg, plainMsg)
	if channels.Console then
		print("[CD] " .. plainMsg)
	end

	-- LocalChat: only visible to the local player (uses ChatPrintf / client chat)
	if channels.LocalChat then
		client.ChatPrintf(colorMsg)
	end

	-- PublicChat: broadcasts to the entire server in public say
	if channels.PublicChat then
		client.Command("say " .. plainMsg, true)
	end

	-- Party: broadcasts to your party chat only
	if channels.Party then
		client.Command('tf_party_chat "' .. plainMsg .. '"', true)
	end

	-- Toast: lnxLib corner notification pop-up
	if channels.Toast then
		local notifs = TryGetLNX()
		if notifs then
			pcall(notifs.Add, plainMsg)
		end
	end
end

local function OnStateChange(playerState, reason)
	local cfg = G.Menu and G.Menu.Notifications
	if not cfg or not cfg.Enable then
		return
	end

	local id = playerState.id
	local name = playerState.wrap:GetName()
	local flags = playerState.flags
	local score = playerState.score
	local now = globals.CurTime()

	-- Frequency Limit: Max 10 per second globally to prevent spam
	lastNotifyTimes = lastNotifyTimes or {}
	-- Clean up old entries in frequency buffer
	for i = #lastNotifyTimes, 1, -1 do
		if now - lastNotifyTimes[i] > 1 then
			table.remove(lastNotifyTimes, i)
		end
	end

	-- If we already sent 10 in the last second, drop this one
	if #lastNotifyTimes >= 10 then
		return
	end

	local isCheater = (flags & Constants.Flags.CHEATER) ~= 0
	local isValve = (flags & Constants.Flags.VALVE) ~= 0
	local isVacBanned = (flags & Constants.Flags.VAC_BANNED) ~= 0
	local isCommBanned = (flags & Constants.Flags.COMM_BANNED) ~= 0
	local isSus = (flags & Constants.Flags.SUSPICIOUS) ~= 0

	-- Hard detections (Cheater/Valve/Ban) ignore the per-player score threshold but still respect global freq limit
	local isHard = isCheater or isValve or isVacBanned or isCommBanned

	if not isHard then
		local minScore = type(cfg.SuspicionThreshold) == "number" and cfg.SuspicionThreshold or 30
		if score < minScore then
			return
		end
	end

	table.insert(lastNotifyTimes, now)

	-- Build messages
	local colorMsg = ""
	local plainMsg = ""

	if isValve then
		colorMsg = string.format("\x07FFD700[VALVE]\x01 %s is a Valve Employee!", name)
		plainMsg = string.format("[VALVE] %s is a Valve Employee!", name)
	elseif isCheater then
		colorMsg = string.format("\x07FF0000[DETECTION]\x01 %s is Cheating! (%s)", name, reason or "")
		plainMsg = string.format("[DETECTION] %s is Cheating! (%s)", name, reason or "")
	elseif isVacBanned then
		colorMsg = string.format("\x07FFB300[BAN]\x01 %s has a VAC ban on record!", name)
		plainMsg = string.format("[BAN] %s has a VAC ban on record!", name)
	elseif isCommBanned then
		colorMsg = string.format("\x07FFB300[BAN]\x01 %s has a Community/Trade ban!", name)
		plainMsg = string.format("[BAN] %s has a Community/Trade ban!", name)
	elseif isSus then
		local displayScore = math.min(99, math.floor(score))
		colorMsg = string.format(
			"\x07FFD500[SUSPICIOUS]\x01 %s is %d%% likely cheating (%s)",
			name,
			displayScore,
			reason or ""
		)
		plainMsg = string.format("[SUSPICIOUS] %s is %d%% likely cheating (%s)", name, displayScore, reason or "")
	end

	if colorMsg == "" then
		return
	end

	-- Cleanup self in debug mode to ensure fresh tests
	if
		(G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug)
		and id == tostring(Common.GetSteamID64(entities.GetLocalPlayer()))
	then
		local Database = require("Cheater_Detection.Database.Database")
		Database.RemoveCheater(id)
	end

	local channels = ResolveChannels(cfg, isValve, isCheater)
	Dispatch(channels, colorMsg, plainMsg)
end

function NotificationService.Init()
	EventBus.Subscribe("OnPlayerStateChange", OnStateChange)
end

return NotificationService
