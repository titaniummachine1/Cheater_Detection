local AutoVote = {}

local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Logger = require("Cheater_Detection.Utils.Logger")

local Log = Logger("AutoVote")

--[[ Constants ]]
local TEAM_SPECTATOR = 1

local GROUP_PRIORITY = {
	"bot",
	"cheater",
	"valve",
	"legit",
}

local VOTE_OPTION_YES = 1
local VOTE_OPTION_NO = 2

--[[ Module State ]]
local State = {
	currentVoteIdx = nil,
	currentTarget = nil,
	lastVoteTime = 0,
	autoCasting = false,
	didVoteThisTick = false,
	lastDecisionTick = 0,
}

local function resetVoteState()
	State.currentVoteIdx = nil
	State.currentTarget = nil
	State.didVoteThisTick = false
end

local function isFriend(player)
	local raw = player and player:GetRawEntity()
	return raw and Common.IsFriend(raw) or false
end

local function isValveEmployee(steamID)
	local Sources = require("Cheater_Detection.Database.Sources")
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
	local raw = player and player:GetBasePlayer()
	if not raw then
		return false
	end
	if raw.IsBot and raw:IsBot() then
		return true
	end
	if raw.IsFakeClient and raw:IsFakeClient() then
		return true
	end
	if not steamID then
		return false
	end
	local info = client.GetPlayerInfo(player:GetIndex())
	return info and (info.IsBot or info.IsHLTV) or false
end

local function getGroupForPlayer(player)
	if not player then
		return nil
	end
	local steamID = player:GetSteamID64()
	if steamID and G.Menu.Misc.intent.friend and Common.IsFriend(player:GetRawEntity()) then
		return nil
	end
	if G.Menu.Misc.intent.bot and isBot(player, steamID) then
		return "bot"
	end
	if G.Menu.Misc.intent.cheater and getCheaterStatus(steamID) then
		return "cheater"
	end
	if G.Menu.Misc.intent.valve and isValveEmployee(steamID) then
		return "valve"
	end
	if G.Menu.Misc.intent.legit then
		return "legit"
	end
	return nil
end

local function collectCandidates()
	local scoreboard = Common.PR.GetScore()
	local candidates = {}
	if not scoreboard then
		return candidates
	end
	local players = FastPlayers.GetAll(true)
	local localPlayer = FastPlayers.GetLocal()
	local localIndex = localPlayer and localPlayer:GetIndex()
	for _, player in ipairs(players) do
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

local function issueVote(target)
	if not target or not target.player then
		return false
	end
	local localPlayer = FastPlayers.GetLocal()
	if not localPlayer then
		return false
	end
	local targetEntity = target.player:GetRawEntity()
	if not targetEntity then
		return false
	end
	local userid = targetEntity:GetPropInt("m_iUserID")
	if not userid or userid == 0 then
		return false
	end
	local voteType = G.Menu.Misc.AutovoteVote or VOTE_OPTION_YES
	local command = string.format("callvote kick %d", userid)
	client.Command(command, true)
	Log:Info(string.format("Called kick vote on %s [%s] (group: %s, score: %d)", target.player:GetName(), target.player:GetSteamID64(), target.group, target.score))
	State.currentTarget = {
		steamID = target.player:GetSteamID64(),
		group = target.group,
		expectedResult = voteType,
	}
	State.autoCasting = true
	State.lastVoteTime = globals.RealTime()
	return true
end

local function shouldVoteAutomatically()
	return G.Menu.Misc.Autovote and G.Menu.Misc.AutovoteAutoCast == true
end

function AutoVote.OnCreateMove()
	State.didVoteThisTick = false
	if not G.Menu.Misc.Autovote then
		return
	end
	if globals.TickCount() == State.lastDecisionTick then
		return
	end
	State.lastDecisionTick = globals.TickCount()
	if not shouldVoteAutomatically() then
		return
	end
	if State.currentVoteIdx then
		return
	end
	local target = pickNextTarget()
	if target then
		LocalPlayer = FastPlayers.GetLocal()
		if LocalPlayer and target.player:GetTeamNumber() ~= LocalPlayer:GetTeamNumber() then
			issueVote(target)
		end
	else
		State.autoCasting = false
	end
end

local function handleVoteStart(msg)
	local voteIdx = msg:ReadInt(32)
	msg:ReadByte() -- team
	msg:ReadByte() -- entidx
	msg:ReadString(64) -- display
	msg:ReadString(64) -- details
	msg:ReadByte() -- target

	State.currentVoteIdx = voteIdx
	State.didVoteThisTick = true
	if State.currentTarget then
		local option = State.currentTarget.expectedResult or VOTE_OPTION_YES
		local cmd = string.format("vote %d option%d", voteIdx, option)
		client.Command(cmd, true)
		Log:Info(string.format("Auto voting option %d for vote idx %d", option, voteIdx))
	else
		State.autoCasting = false
	end
end

local function handleVoteEnd()
	resetVoteState()
end

local function onVoteEvent(event)
	local name = event:GetName()
	if name == "vote_options" then
		State.didVoteThisTick = true
	elseif name == "vote_changed" then
		State.didVoteThisTick = true
	elseif name == "vote_cast" then
		State.didVoteThisTick = true
	elseif name == "round_end" or name == "game_newmap" then
		resetVoteState()
	end
end

function AutoVote.OnDispatchUserMessage(msg)
	local id = msg:GetID()
	if id == VoteStart then
		handleVoteStart(msg)
	elseif id == VotePass or id == VoteFailed then
		handleVoteEnd()
	elseif id == CallVoteFailed then
		handleVoteEnd()
	end
end

function AutoVote.OnFireGameEvent(event)
	onVoteEvent(event)
end

function AutoVote.Reset()
	resetVoteState()
	State.autoCasting = false
	State.lastDecisionTick = 0
	State.lastVoteTime = 0
end

function AutoVote.ManualCast()
	local target = pickNextTarget()
	if target then
		return issueVote(target)
	end
	return false
end

return AutoVote
