local AutoVote = {}

local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local WrappedPlayer = require("Cheater_Detection.Utils.WrappedPlayer")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Sources = require("Cheater_Detection.Database.Sources")
local Logger = require("Cheater_Detection.Utils.Logger")
local VoteReveal = require("Cheater_Detection.Misc.Vote_Revel")

local LOG_CATEGORY = "AutoVote"

-- User message IDs (TF2 specific)
local VoteStart = 46
local VotePass = 47
local VoteFailed = 48
local CallVoteFailed = 49

-- Prioritised voting order (highest to lowest priority)
local GROUP_PRIORITY = {
	"retaliation", -- Players who voted NO on my votes (highest priority)
	"bot", -- Cheat bots
	"cheater", -- Known cheaters
	"valve", -- Valve employees
	"legit", -- Legit players
	"friend", -- Friends (lowest priority)
}

local VOTE_OPTION_YES = 1
local VOTE_OPTION_NO = 2

local MIN_SECONDS_BETWEEN_CALLVOTES = 1.5

-- Track players who CALLED a vote against us: steamID -> true
-- These players go into "retaliation" group
local RetaliationCallers = {}

-- Track score penalties for players who voted against our interests: steamID -> score
-- Does NOT put them in retaliation group, just adds to their kick priority score
local ScorePenalties = {}

local State = {
	currentVoteIdx = nil,
	currentTarget = nil,
	lastVoteTime = 0,
	lastDecisionTick = 0,
	serverCooldownUntil = 0, -- Server-reported cooldown end time
	lastCooldownLog = 0,
	-- Exponential backoff for guessed cooldowns
	failureBackoff = 60, -- Start at 60 seconds (1 min)
	maxBackoff = 120, -- Max 2 minutes
	backoffUntil = 0,
	iCalledThisVote = false, -- Track if WE initiated the current vote
	voteSentTime = 0, -- When we sent the vote command
	voteTimeout = 3.0, -- Seconds to wait for server response
}

local function logInfo(message)
	Logger.Info(LOG_CATEGORY, message)
end

local function logDebug(message)
	Logger.Debug(LOG_CATEGORY, message)
end

--- Record the CALLER of a vote against us (goes into retaliation GROUP)
local function recordRetaliationCaller(callerSteamID, callerName)
	if not callerSteamID then
		return
	end
	RetaliationCallers[callerSteamID] = true
	logInfo(
		string.format("RETALIATION: %s CALLED a vote against us - added to retaliation group", callerName or "Unknown")
	)
end

--- Record score penalties for players who voted against our interests
--- Does NOT add them to retaliation group, just increases kick priority score
local function recordScorePenalties()
	local activeVote = VoteReveal.GetActiveVote()
	if not activeVote then
		return
	end

	-- Determine what WE would have voted
	local ourVoteOption = nil
	if State.iCalledThisVote then
		-- We initiated this vote, we want YES
		ourVoteOption = 1
	elseif State.currentTarget then
		-- We're voting on someone else's vote
		ourVoteOption = State.currentTarget.expectedResult
	else
		-- Check if we or our friends are the target
		local localPlayer = FastPlayers.GetLocal()
		local localSteamID = localPlayer and localPlayer:GetSteamID64()

		-- Check if target is us or our friend
		if activeVote.targetIdx then
			local targetEntity = entities.GetByIndex(activeVote.targetIdx)
			if targetEntity and targetEntity:IsValid() then
				local targetSteamID = targetEntity:GetSteamID64()
				if targetSteamID == localSteamID or isFriendEntity(targetEntity) then
					-- They're voting against us/friend - we want NO
					ourVoteOption = 2
				end
			end
		end
	end

	if not ourVoteOption then
		return -- Not our concern
	end

	-- Get players who voted against our interest
	local againstVoters = {}
	if ourVoteOption == 1 then
		-- We wanted YES, track NO voters
		againstVoters = VoteReveal.GetNoVoters()
	else
		-- We wanted NO, track YES voters
		againstVoters = VoteReveal.GetYesVoters()
	end

	for _, voter in ipairs(againstVoters) do
		if voter.steamID then
			ScorePenalties[voter.steamID] = (ScorePenalties[voter.steamID] or 0) + 10
			logInfo(
				string.format(
					"PENALTY: %s voted against our interest (+10 score, total: %d)",
					voter.name,
					ScorePenalties[voter.steamID]
				)
			)
		end
	end
end

local function resetVoteState()
	State.currentVoteIdx = nil
	State.currentTarget = nil
	State.iCalledThisVote = false
	State.voteSentTime = 0 -- Clear timeout tracking
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

	-- HIGHEST PRIORITY: Retaliation - players who CALLED a vote against us
	if steamID and RetaliationCallers[steamID] then
		return "retaliation"
	end

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

				-- Add score penalty for players who voted against our interests
				local steamID = player:GetSteamID64()
				if steamID and ScorePenalties[steamID] then
					score = score + ScorePenalties[steamID]
				end

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
		return false
	end

	-- Check if we're in a casual game mode
	local isCasual = gamerules.IsMatchTypeCasual()
	if not isCasual then
		logDebug("Auto-vote disabled: not in casual game mode")
		return false
	end

	return true
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
	State.iCalledThisVote = true -- Track that WE initiated this vote
	State.voteSentTime = globals.RealTime() -- Track when we sent the command
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
	-- Check if we're in a casual game mode before processing votes
	local isCasual = gamerules.IsMatchTypeCasual()
	if not isCasual then
		logDebug("Vote handling disabled: not in casual game mode")
		return
	end

	local menu = getMenu()
	local team = msg:ReadByte()
	local voteIdx = msg:ReadInt(32)
	local callerIdx = msg:ReadByte()
	local dispStr = msg:ReadString(64)
	local detailsStr = msg:ReadString(64)
	local targetPacked = msg:ReadByte()
	local targetIdx = targetPacked >> 1

	State.currentVoteIdx = voteIdx

	-- Check if someone is CALLING a vote against US or our FRIEND
	local localPlayer = FastPlayers.GetLocal()
	local localIndex = localPlayer and localPlayer:GetIndex() or -1
	local localSteamID = localPlayer and localPlayer:GetSteamID64()

	local voteTargetEntity = entities.GetByIndex(targetIdx)
	if voteTargetEntity and voteTargetEntity:IsValid() and callerIdx ~= localIndex then
		local voteTargetSteamID = voteTargetEntity:GetSteamID64()
		-- Is this a vote against US?
		if voteTargetSteamID == localSteamID then
			-- Get caller info and add to retaliation group
			local callerEntity = entities.GetByIndex(callerIdx)
			if callerEntity and callerEntity:IsValid() then
				local callerSteamID = callerEntity:GetSteamID64()
				local callerName = client.GetPlayerNameByIndex(callerIdx)
				recordRetaliationCaller(callerSteamID, callerName)
			end
		-- Is this a vote against our FRIEND?
		elseif isFriendEntity(voteTargetEntity) then
			local callerEntity = entities.GetByIndex(callerIdx)
			if callerEntity and callerEntity:IsValid() then
				local callerSteamID = callerEntity:GetSteamID64()
				local callerName = client.GetPlayerNameByIndex(callerIdx)
				recordRetaliationCaller(callerSteamID, callerName)
			end
		end
	end

	-- Check if this is the vote WE initiated
	if State.currentTarget and State.voteSentTime > 0 then
		local localPlayer = FastPlayers.GetLocal()
		-- GetIndex() is forwarded to WPlayer via metatable (lint warning is false positive)
		local localIndex = localPlayer and localPlayer:GetIndex() or -1

		-- Check if we're the caller AND it matches our target
		if callerIdx == localIndex then
			local targetEntity = entities.GetByIndex(targetIdx)
			if targetEntity and targetEntity:IsValid() then
				-- GetSteamID64() is forwarded to WPlayer via metatable (lint warning is false positive)
				local targetSteamID = targetEntity:GetSteamID64()
				if targetSteamID == State.currentTarget.steamID then
					-- This is DEFINITELY our vote! Clear timeout and proceed
					State.voteSentTime = 0
					local option = State.currentTarget.expectedResult or VOTE_OPTION_YES
					sendVote(voteIdx, option)
					logInfo(string.format("OUR vote started - Voting option %d on vote %d", option, voteIdx))
					return
				end
			end
		end
		-- Not our vote - someone else started a vote
		logDebug(string.format("Vote started by player %d while we were waiting", callerIdx))
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

--- Handle vote failure with retaliation tracking and cooldown
local function handleVoteFailed()
	-- Record score penalties for players who voted against our interests
	recordScorePenalties()

	-- Assume 60s cooldown if we don't have explicit cooldown
	local now = globals.RealTime()
	if State.serverCooldownUntil < now then
		State.serverCooldownUntil = now + State.failureBackoff
		logInfo(string.format("Vote failed - cooldown %ds (backoff)", State.failureBackoff))

		-- Exponential backoff: increase for next time, max 2 minutes
		State.failureBackoff = math.min(State.failureBackoff * 2, State.maxBackoff)
	end

	resetVoteState()
end

local function onVoteEvent(event)
	local name = event:GetName()

	if name == "round_end" or name == "game_newmap" then
		resetVoteState()
		return
	end

	-- Vote started successfully - reset backoff
	if name == "vote_started" then
		local issue = event:GetString("issue")
		local param1 = event:GetString("param1")
		local initiator = event:GetInt("initiator")
		logInfo(string.format("Vote started: %s (%s) by entity %d", issue or "?", param1 or "?", initiator or -1))
		State.failureBackoff = 60 -- Reset backoff on success
		return
	end

	-- Vote passed - success, reset backoff
	if name == "vote_passed" then
		local details = event:GetString("details")
		local param1 = event:GetString("param1")
		logInfo(string.format("Vote passed: %s (%s)", details or "?", param1 or "?"))
		State.failureBackoff = 60 -- Reset backoff on success
		resetVoteState()
		return
	end

	-- Vote failed (not enough votes) - record retaliation
	if name == "vote_failed" then
		logInfo("Vote failed (not enough votes)")
		handleVoteFailed()
		return
	end

	-- Vote ended (generic)
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

	-- Check for timeout on vote we sent
	if State.voteSentTime > 0 then
		local now = globals.RealTime()
		if now - State.voteSentTime > State.voteTimeout then
			-- Server didn't respond within timeout - assume silent rejection
			logInfo(string.format("Vote timeout after %.1fs - server silently rejected", State.voteTimeout))
			State.serverCooldownUntil = now + State.failureBackoff
			logInfo(string.format("Cooldown: %ds (estimated from timeout)", State.failureBackoff))

			-- Exponential backoff
			State.failureBackoff = math.min(State.failureBackoff * 2, State.maxBackoff)

			-- Reset vote state
			resetVoteState()
			return
		end
	end

	-- Vote already in progress
	if State.currentTarget or State.currentVoteIdx then
		return
	end

	local now = globals.RealTime()

	-- Check cooldown (either server-reported or backoff-estimated)
	if State.serverCooldownUntil > now then
		local remaining = math.ceil(State.serverCooldownUntil - now)
		-- Log cooldown every 10 seconds
		if now - State.lastCooldownLog > 10 then
			State.lastCooldownLog = now
			logInfo(string.format("Cooldown: %d seconds left (next backoff: %ds)", remaining, State.failureBackoff))
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
	elseif id == VotePass then
		-- Vote passed - reset backoff
		State.failureBackoff = 60
		handleVoteEnd()
	elseif id == VoteFailed then
		-- Vote failed (not enough YES votes) - record retaliation
		logInfo("VoteFailed user message received")
		handleVoteFailed()
	elseif id == CallVoteFailed then
		-- Try ALL possible data formats from TF2 server
		local cooldownFound = false
		local cooldownTime = 0
		local reason = -1

		-- Method 1: Standard TF2 format (reason:byte, time:short)
		reason = msg:ReadByte()
		local time1 = msg:ReadInt(16)
		logInfo(string.format("CallVoteFailed FORMAT1: reason=%d, time=%d", reason or -1, time1 or -1))

		if time1 and time1 > 0 and time1 <= 300 then
			cooldownFound = true
			cooldownTime = time1
			logInfo(string.format("VALID COOLDOWN: %d seconds (format1)", cooldownTime))
		end

		-- Method 2: Try reading as float (some servers might use float)
		-- Note: Can't reset message position, so this is just for reference
		-- We would need separate message handlers for different formats

		-- Method 3: Check if reason itself might be the cooldown (some servers)
		if not cooldownFound and reason and reason > 0 and reason <= 300 then
			cooldownFound = true
			cooldownTime = reason
			logInfo(string.format("VALID COOLDOWN: %d seconds (reason-as-time)", cooldownTime))
		end

		-- Additional debug info
		logInfo(
			string.format(
				"CallVoteFailed SUMMARY: id=%d, reason=%d, time=%d, valid=%s",
				id,
				reason or -1,
				time1 or -1,
				tostring(cooldownFound)
			)
		)

		-- Apply cooldown if found, otherwise use backoff
		if cooldownFound and cooldownTime > 0 then
			State.serverCooldownUntil = globals.RealTime() + cooldownTime
			State.failureBackoff = 60 -- Reset backoff since we got real data
			logInfo(string.format("Vote cooldown: %d seconds (server confirmed)", cooldownTime))
		else
			-- No valid cooldown - use backoff
			State.serverCooldownUntil = globals.RealTime() + State.failureBackoff
			logInfo(
				string.format("Vote rejected (reason %d) - cooldown %ds (estimated)", reason or 0, State.failureBackoff)
			)

			-- Exponential backoff: increase for next time, max 2 minutes
			State.failureBackoff = math.min(State.failureBackoff * 2, State.maxBackoff)
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
	State.failureBackoff = 60 -- Reset to 60s
	State.voteSentTime = 0 -- Clear timeout
	-- Don't clear RetaliationCallers/ScorePenalties - they persist for the session
	logInfo("AutoVote reset - cooldown cleared")
end

--- Get current retaliation data (for debugging)
function AutoVote.GetRetaliationData()
	return {
		callers = RetaliationCallers,
		penalties = ScorePenalties,
	}
end

-- Register callbacks to enable auto-voting
callbacks.Register("CreateMove", "CD_AutoVote_CreateMove", AutoVote.OnCreateMove)
callbacks.Register("DispatchUserMessage", "CD_AutoVote_UserMsg", AutoVote.OnDispatchUserMessage)
callbacks.Register("FireGameEvent", "CD_AutoVote_Event", AutoVote.OnFireGameEvent)

return AutoVote
