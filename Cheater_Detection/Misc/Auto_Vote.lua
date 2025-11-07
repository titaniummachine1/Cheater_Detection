local AutoVote = {}

local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local WrappedPlayer = require("Cheater_Detection.Utils.WrappedPlayer")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Sources = require("Cheater_Detection.Database.Sources")
local Logger = require("Cheater_Detection.Utils.Logger")

local LOG_CATEGORY = "AutoVote"

local bitLib = bit or bit32

local function shiftRight(value, bits)
	if bitLib and bitLib.rshift then
		return bitLib.rshift(value, bits)
	end
	return math.floor(value / (2 ^ bits))
end

-- User message IDs (TF2 specific)
local VoteStart = 46
local VotePass = 47
local VoteFailed = 48
local CallVoteFailed = 49

-- Prioritised voting order
local GROUP_PRIORITY = {
	"bot",
	"cheater",
	"valve",
	"legit",
}

local VOTE_OPTION_YES = 1
local VOTE_OPTION_NO = 2

local MIN_SECONDS_BETWEEN_CALLVOTES = 1.5

local State = {
	currentVoteIdx = nil,
	currentTarget = nil,
	lastVoteTime = 0,
	lastDecisionTick = 0,
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
	local basePlayer = player and player:GetBasePlayer()
	if not basePlayer then
		return false
	end
	if basePlayer.IsBot and basePlayer:IsBot() then
		return true
	end
	if basePlayer.IsFakeClient and basePlayer:IsFakeClient() then
		return true
	end
	if steamID then
		---@diagnostic disable-next-line: undefined-field
		local info = client.GetPlayerInfo(player:GetIndex())
		return info and (info.IsBot or info.IsHLTV) or false
	end
	return false
end

local function getGroupForPlayer(player)
	if not player then
		return nil
	end
	local config = getMenu()
	if not config then
		return nil
	end

	local entity = player:GetRawEntity()
	local steamID = player:GetSteamID64()

	if config.intent and config.intent.friend and isFriendEntity(entity) then
		return nil
	end

	if config.intent and config.intent.bot and isBot(player, steamID) then
		return "bot"
	end
	if config.intent and config.intent.cheater and getCheaterStatus(steamID) then
		return "cheater"
	end
	if config.intent and config.intent.valve and isValveEmployee(steamID) then
		return "valve"
	end
	if config.intent and config.intent.legit then
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
	local scoreboard = getScoreboard()
	local candidates = {}
	if not scoreboard then
		return candidates
	end

	local players = FastPlayers.GetAll(true)
	local localPlayer = FastPlayers.GetLocal()
	local localIndex = localPlayer and localPlayer:GetIndex()

	for _, player in ipairs(players) do
		---@diagnostic disable-next-line: undefined-field
		local index = player:GetIndex()
		if index ~= localIndex then
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
	return menu and menu.Autovote and menu.AutovoteAutoCast ~= false
end

local function preferredVoteOption()
	local menu = getMenu()
	if menu and menu.AutovoteVoteNo then
		return VOTE_OPTION_NO
	end
	return VOTE_OPTION_YES
end

local function issueVote(target)
	if not target or not target.player then
		return false
	end

	local localPlayer = FastPlayers.GetLocal()
	if not localPlayer then
		return false
	end

	---@diagnostic disable-next-line: undefined-field
	if target.player:GetTeamNumber() == localPlayer:GetTeamNumber() then
		return false
	end

	local targetEntity = target.player:GetRawEntity()
	if not targetEntity or not targetEntity:IsValid() then
		return false
	end

	local userid = targetEntity:GetPropInt("m_iUserID")
	if not userid or userid == 0 then
		return false
	end

	local voteOption = preferredVoteOption()
	client.Command(string.format("callvote kick %d", userid), true)
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
		expectedResult = voteOption,
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
		return VOTE_OPTION_NO
	end

	local wrapped = WrappedPlayer.FromEntity(entity)
	if not wrapped then
		return nil
	end

	local group = getGroupForPlayer(wrapped)
	if not group then
		return nil
	end

	return menu.AutovoteVoteNo and VOTE_OPTION_NO or VOTE_OPTION_YES
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
	local option = determineVoteOptionForEntity(targetEntity)
	if not option then
		logDebug("VoteStart received but no eligible automatic response")
		return
	end

	sendVote(voteIdx, option)
	local targetName = targetEntity and targetEntity:GetName() or "<unknown>"
	local voteType = option == VOTE_OPTION_YES and "YES" or "NO"
	logInfo(
		string.format(
			"Auto voted %s on %s (caller idx %d, team %d, reason %s)",
			voteType,
			targetName,
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
	end
end

function AutoVote.OnCreateMove()
	local menu = getMenu()
	if not menu then
		return
	end

	if menu.AutovoteCastNow then
		local success = AutoVote.ManualCast()
		menu.AutovoteCastNow = false
		if success then
			State.lastDecisionTick = globals.TickCount()
		end
	end

	if not shouldVoteAutomatically() then
		return
	end

	if State.currentTarget or State.currentVoteIdx then
		return
	end

	if globals.RealTime() - State.lastVoteTime < MIN_SECONDS_BETWEEN_CALLVOTES then
		return
	end

	if globals.TickCount() == State.lastDecisionTick then
		return
	end

	State.lastDecisionTick = globals.TickCount()

	local target = pickNextTarget()
	if not target then
		return
	end

	if issueVote(target) then
		logDebug("Attempted to initiate vote; awaiting VoteStart message")
	else
		logDebug("Failed to initiate vote after selecting candidate")
	end
end

function AutoVote.OnDispatchUserMessage(msg)
	local id = msg:GetID()
	if id == VoteStart then
		handleVoteStart(msg)
	elseif id == VotePass or id == VoteFailed or id == CallVoteFailed then
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
end

function AutoVote.ManualCast()
	local target = pickNextTarget()
	if not target then
		logInfo("Manual cast requested but no eligible targets were found")
		return false
	end
	local success = issueVote(target)
	if success then
		logInfo("Manual cast triggered a kick vote")
	else
		logInfo("Manual cast failed to issue a kick vote")
	end
	return success
end

return AutoVote
