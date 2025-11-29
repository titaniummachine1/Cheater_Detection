local AutoVote = {}

local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local WrappedPlayer = require("Cheater_Detection.Utils.WrappedPlayer")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Sources = require("Cheater_Detection.Database.Sources")
local Logger = require("Cheater_Detection.Utils.Logger")

local LOG_CATEGORY = "AutoVote"

-- Bit operations fallback (bit library is often nil in Lmaobox)
local function shiftRight(value, bits)
	return math.floor(value / (2 ^ bits))
end

-- User message IDs (TF2 specific)
local VoteStart = 46
local VotePass = 47
local VoteFailed = 48
local CallVoteFailed = 49

-- Prioritised voting order (highest to lowest priority)
local GROUP_PRIORITY = {
	"bot", -- Cheat bots (highest priority)
	"cheater", -- Known cheaters
	"valve", -- Valve employees
	"legit", -- Legit players
	"friend", -- Friends (lowest priority)
}

local VOTE_OPTION_YES = 1

local MIN_SECONDS_BETWEEN_CALLVOTES = 1.5

local State = {
	currentVoteIdx = nil,
	currentTarget = nil,
	lastVoteTime = 0,
	lastDecisionTick = 0,
	serverCooldownUntil = 0, -- Server-reported cooldown end time
	lastCooldownLog = 0,
	-- Exponential backoff for non-cooldown failures
	failureBackoff = 2, -- Start at 2 seconds
	backoffUntil = 0,
	permanentlyDisabled = false, -- Disabled until reload
}

local function logInfo(message)
	Logger.Info(LOG_CATEGORY, message)
end

local function logDebug(message)
	Logger.Debug(LOG_CATEGORY, message)
end

local function resetVoteState()
	State.currentVoteIdx = nil
	State.currentTarget = nil
end

local function getMenu()
	return G.Menu and G.Menu.Misc or nil
end

local function isFriendEntity(entity)
	return entity and Common.IsFriend(entity) or false
end

local function isValveEmployee(steamID)
	return Sources.IsValveEmployee and Sources.IsValveEmployee(steamID)
end

local function getCheaterStatus(steamID)
	if not steamID then
		return false
	end
	if Evidence.IsMarkedCheater(steamID) then
		return true
	end
	return G.DataBase and G.DataBase[steamID] ~= nil
end

local function isBot(player, steamID)
	if not player then
		return false
	end

	-- Use client.GetPlayerInfo to check for bots (correct method)
	local idx = player:GetIndex()
	if idx then
		local info = client.GetPlayerInfo(idx)
		if info and (info.IsBot or info.IsHLTV) then
			return true
		end
	end

	-- Check if SteamID is invalid (bots have [U:1:0])
	if steamID and steamID == "[U:1:0]" then
		return true
	end

	return false
end

local function getGroupForPlayer(player)
	if not player then
		return nil
	end
	local config = getMenu()
	if not config or not config.intent then
		return nil
	end

	local entity = player:GetRawEntity()
	local steamID = player:GetSteamID64()
	local isFriend = isFriendEntity(entity)

	-- Check groups in priority order
	if config.intent.bot and isBot(player, steamID) then
		return "bot"
	end
	if config.intent.cheater and getCheaterStatus(steamID) then
		return "cheater"
	end
	if config.intent.valve and isValveEmployee(steamID) then
		return "valve"
	end
	-- Friends as separate lowest-priority group if enabled
	if config.intent.friend and isFriend then
		return "friend"
	end
	-- Legit players (non-friends) if enabled
	if config.intent.legit and not isFriend then
		return "legit"
	end

	return nil
end

local function getScoreboard()
	local pr = Common.PR
	if not pr or type(pr.GetScore) ~= "function" then
		return nil
	end
	return pr.GetScore()
end

local function collectCandidates()
	local scoreboard = getScoreboard() or {}
	local candidates = {}

	local players = FastPlayers.GetAll(true)
	local localPlayer = FastPlayers.GetLocal()
	if not localPlayer then
		return candidates
	end

	local localIndex = localPlayer:GetIndex()
	local localTeam = localPlayer:GetTeamNumber()

	-- Can only vote kick players on YOUR team
	if not localTeam or localTeam < 2 then
		return candidates -- Not on a valid team (spec/unassigned)
	end

	for _, player in ipairs(players) do
		local index = player:GetIndex()
		local playerTeam = player:GetTeamNumber()

		-- Skip self, skip players not on our team
		if index ~= localIndex and playerTeam == localTeam then
			local group = getGroupForPlayer(player)
			if group then
				local score = scoreboard[index + 1] or 0
				candidates[#candidates + 1] = {
					player = player,
					score = score,
					group = group,
				}
			end
		end
	end

	return candidates
end

local function pickNextTarget()
	local candidates = collectCandidates()
	if #candidates == 0 then
		return nil
	end

	table.sort(candidates, function(a, b)
		if a.group == b.group then
			return a.score > b.score
		end
		local aPriority, bPriority = 99, 99
		for i, name in ipairs(GROUP_PRIORITY) do
			if a.group == name then
				aPriority = i
			end
			if b.group == name then
				bPriority = i
			end
		end
		if aPriority == bPriority then
			return a.score > b.score
		end
		return aPriority < bPriority
	end)

	return candidates[1]
end

local function shouldVoteAutomatically()
	local menu = getMenu()
	local result = menu and menu.Autovote and menu.AutovoteAutoCast ~= false
	if not result then
		logDebug(
			string.format(
				"Auto-cast disabled: menu=%s, Autovote=%s, AutovoteAutoCast=%s",
				tostring(menu ~= nil),
				tostring(menu and menu.Autovote),
				tostring(menu and menu.AutovoteAutoCast)
			)
		)
	end
	return result
end

local function issueVote(target)
	if not target or not target.player then
		return false
	end

	-- Team check already done in collectCandidates
	local targetEntity = target.player:GetRawEntity()
	if not targetEntity or not targetEntity:IsValid() then
		return false
	end

	local idx = targetEntity:GetIndex()
	if not idx then
		return false
	end

	local info = client.GetPlayerInfo(idx)
	if not info or not info.UserID then
		return false
	end

	client.Command(string.format("callvote kick %d", info.UserID), true)
	logInfo(
		string.format(
			"Initiated vote on %s [%s] (group: %s, score: %d)",
			target.player:GetName(),
			target.player:GetSteamID64(),
			target.group,
			target.score
		)
	)

	State.currentTarget = {
		steamID = target.player:GetSteamID64(),
		group = target.group,
		expectedResult = VOTE_OPTION_YES,
	}
	State.lastVoteTime = globals.RealTime()
	return true
end

local function sendVote(voteIdx, option)
	client.Command(string.format("vote %d option%d", voteIdx, option), true)
end

local function determineVoteOptionForEntity(entity)
	local menu = getMenu()
	if not menu or not menu.Autovote then
		return nil
	end

	if not entity or not entity:IsValid() then
		return nil
	end

	if menu.intent and menu.intent.friend and isFriendEntity(entity) then
		return nil
	end

	local wrapped = WrappedPlayer.FromEntity(entity)
	if not wrapped then
		return nil
	end

	local group = getGroupForPlayer(wrapped)
	if not group then
		return nil
	end

	return VOTE_OPTION_YES
end

local function handleVoteStart(msg)
	local menu = getMenu()
	local team = msg:ReadByte()
	local voteIdx = msg:ReadInt(32)
	local callerIdx = msg:ReadByte()
	local dispStr = msg:ReadString(64)
	local detailsStr = msg:ReadString(64)
	local targetPacked = msg:ReadByte()
	local targetIdx = shiftRight(targetPacked, 1)

	State.currentVoteIdx = voteIdx

	if State.currentTarget then
		local option = State.currentTarget.expectedResult or VOTE_OPTION_YES
		sendVote(voteIdx, option)
		logInfo(string.format("Voting option %d on vote %d (expected result)", option, voteIdx))
		return
	end

	if not menu or not menu.Autovote then
		return
	end

	local targetEntity = entities.GetByIndex(targetIdx)
	logDebug(
		string.format(
			"VoteStart: voteIdx=%d, team=%d, callerIdx=%d, targetIdx=%d, disp=%s",
			voteIdx,
			team,
			callerIdx,
			targetIdx,
			dispStr
		)
	)

	local option = determineVoteOptionForEntity(targetEntity)
	if not option then
		logDebug("VoteStart received but no eligible automatic response")
		return
	end

	sendVote(voteIdx, option)
	logInfo(
		string.format(
			"Auto voted %s on %s (caller idx %d, team %d, reason %s)",
			option == VOTE_OPTION_YES and "YES" or "NO",
			client.GetPlayerNameByIndex(targetIdx) or "Unknown",
			callerIdx,
			team,
			dispStr
		)
	)
end

local function handleVoteEnd()
	resetVoteState()
end

local function onVoteEvent(event)
	local name = event:GetName()

	if name == "round_end" or name == "game_newmap" then
		resetVoteState()
		return
	end

	-- Vote started successfully
	if name == "vote_started" then
		local issue = event:GetString("issue")
		local param1 = event:GetString("param1")
		local initiator = event:GetInt("initiator")
		logInfo(string.format("Vote started: %s (%s) by entity %d", issue or "?", param1 or "?", initiator or -1))
		-- Reset backoff on successful vote start
		State.failureBackoff = 2
		return
	end

	-- Vote passed
	if name == "vote_passed" then
		local details = event:GetString("details")
		local param1 = event:GetString("param1")
		logInfo(string.format("Vote passed: %s (%s)", details or "?", param1 or "?"))
		resetVoteState()
		return
	end

	-- Vote failed (client-side event)
	if name == "vote_failed" then
		logInfo("Vote failed (not enough votes or cancelled)")
		resetVoteState()
		return
	end

	-- Vote ended
	if name == "vote_ended" then
		resetVoteState()
		return
	end
end

-- Track last log time to avoid spam
local lastStatusLog = 0
local STATUS_LOG_INTERVAL = 5.0

function AutoVote.OnCreateMove()
	local menu = getMenu()
	if not menu then
		return
	end

	if not shouldVoteAutomatically() then
		return
	end

	-- Permanently disabled due to too many failures
	if State.permanentlyDisabled then
		return
	end

	-- Vote already in progress
	if State.currentTarget or State.currentVoteIdx then
		return
	end

	local now = globals.RealTime()

	-- Check exponential backoff from non-cooldown failures
	if State.backoffUntil > now then
		local remaining = math.ceil(State.backoffUntil - now)
		if now - State.lastCooldownLog > 10 then
			State.lastCooldownLog = now
			logInfo(
				string.format("Backoff active: %d seconds left (next backoff: %ds)", remaining, State.failureBackoff)
			)
		end
		return
	end

	-- Check server-reported cooldown
	if State.serverCooldownUntil > now then
		local remaining = math.ceil(State.serverCooldownUntil - now)
		-- Log cooldown every 10 seconds
		if now - State.lastCooldownLog > 10 then
			State.lastCooldownLog = now
			logInfo(string.format("Waiting for vote cooldown: %d seconds left", remaining))
		end
		return
	end

	-- Local cooldown between vote attempts
	local timeSinceLastVote = now - State.lastVoteTime
	if timeSinceLastVote < MIN_SECONDS_BETWEEN_CALLVOTES then
		return
	end

	-- Rate limit per tick
	if globals.TickCount() == State.lastDecisionTick then
		return
	end

	State.lastDecisionTick = globals.TickCount()

	local target = pickNextTarget()
	if not target then
		-- Log status periodically
		if globals.RealTime() - lastStatusLog > STATUS_LOG_INTERVAL then
			lastStatusLog = globals.RealTime()
			local candidates = collectCandidates()
			if #candidates == 0 then
				logInfo("No vote targets on your team (check intent settings)")
			end
		end
		return
	end

	logInfo(
		string.format(
			"Attempting vote on %s [%s] (group: %s, score: %d)",
			target.player:GetName(),
			target.player:GetSteamID64(),
			target.group,
			target.score
		)
	)

	if issueVote(target) then
		logInfo("Vote command sent - waiting for server response...")
	else
		logInfo("Cannot vote - target may be on enemy team or invalid")
	end
end

function AutoVote.OnDispatchUserMessage(msg)
	local id = msg:GetID()
	if id == VoteStart then
		handleVoteStart(msg)
	elseif id == VotePass or id == VoteFailed then
		handleVoteEnd()
	elseif id == CallVoteFailed then
		-- Parse cooldown from server response
		local reason = msg:ReadByte()
		local cooldownSeconds = msg:ReadInt(16)
		if cooldownSeconds and cooldownSeconds > 0 then
			-- Server reported cooldown - use it directly, reset backoff
			State.serverCooldownUntil = globals.RealTime() + cooldownSeconds
			State.failureBackoff = 2 -- Reset backoff on successful cooldown info
			logInfo(string.format("Vote on cooldown: %d seconds remaining", cooldownSeconds))
		else
			-- Non-cooldown failure - apply exponential backoff
			State.backoffUntil = globals.RealTime() + State.failureBackoff
			logInfo(
				string.format("Vote failed (reason %d) - backing off %d seconds", reason or 0, State.failureBackoff)
			)

			-- Double the backoff for next time (exponential)
			State.failureBackoff = math.min(State.failureBackoff * 2, 300)

			-- If backoff reaches 5 minutes (300s), disable permanently
			if State.failureBackoff >= 300 then
				State.permanentlyDisabled = true
				logInfo("AutoVote disabled - too many failures. Re-enable in menu or reload script.")
			end
		end
		handleVoteEnd()
	end
end

function AutoVote.OnFireGameEvent(event)
	onVoteEvent(event)
end

function AutoVote.Reset()
	resetVoteState()
	State.lastVoteTime = 0
	State.lastDecisionTick = 0
	State.serverCooldownUntil = 0
	State.lastCooldownLog = 0
	State.failureBackoff = 2
	State.backoffUntil = 0
	State.permanentlyDisabled = false
	logInfo("AutoVote reset - backoff cleared")
end

-- Register callbacks to enable auto-voting
callbacks.Register("CreateMove", "CD_AutoVote_CreateMove", AutoVote.OnCreateMove)
callbacks.Register("DispatchUserMessage", "CD_AutoVote_UserMsg", AutoVote.OnDispatchUserMessage)
callbacks.Register("FireGameEvent", "CD_AutoVote_Event", AutoVote.OnFireGameEvent)

return AutoVote
