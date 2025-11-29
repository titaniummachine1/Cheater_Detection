--[[ Custom Vote Reveal UI - TF2 Style ]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")

local VoteReveal = {}

-- User message IDs
local VoteStart = 46
local VotePass = 47
local VoteFailed = 48
local CallVoteFailed = 49

-- Team constants
local TEAM_UNASSIGNED = 0
local TEAM_SPECTATOR = 1
local TEAM_RED = 2
local TEAM_BLU = 3

-- Team colors (RGBA)
local TEAM_COLORS = {
	[TEAM_UNASSIGNED] = { 246, 215, 167, 255 },
	[TEAM_SPECTATOR] = { 207, 207, 196, 255 },
	[TEAM_RED] = { 207, 115, 108, 255 },
	[TEAM_BLU] = { 95, 143, 181, 255 },
}

-- Vote state
local activeVote = nil
local voteAlpha = 0
local targetAlpha = 0
local lastUpdateTime = 0

-- Fonts
local font_title = draw.CreateFont("Verdana", 14, 700, FONTFLAG_OUTLINE)
local font_body = draw.CreateFont("Verdana", 12, 400, FONTFLAG_OUTLINE)
local font_small = draw.CreateFont("Tahoma", 11, 400, FONTFLAG_OUTLINE)

--[[ Helper Functions ]]

local function getConfig()
	return G.Menu and G.Menu.Misc and G.Menu.Misc.Vote_Reveal or nil
end

local function localize(key, ...)
	local result = client.Localize(key)
	if not result or #result == 0 then
		return key
	end

	local args = { ... }
	local index = 0
	result = result:gsub("%%[acdglpsuwx%[%]]%d", function(capture)
		index = index + 1
		return args[index] or capture
	end)

	return result
end

local function getTeamName(teamIdx)
	local names = {
		[TEAM_UNASSIGNED] = "UNASSIGNED",
		[TEAM_SPECTATOR] = "SPECTATOR",
		[TEAM_RED] = "RED",
		[TEAM_BLU] = "BLU",
	}
	return names[teamIdx] or "UNKNOWN"
end

local function getPlayerScore(playerIdx)
	local pr = Common.PR
	if not pr or type(pr.GetScore) ~= "function" then
		return 0
	end
	local scoreboard = pr.GetScore()
	if not scoreboard then
		return 0
	end
	return scoreboard[playerIdx + 1] or 0
end

local function truncateText(text, maxWidth, font)
	draw.SetFont(font)
	local width = draw.GetTextSize(text)
	if width <= maxWidth then
		return text
	end

	-- Binary search for the right length
	local left, right = 1, #text
	while left < right do
		local mid = math.floor((left + right + 1) / 2)
		local sub = text:sub(1, mid) .. "..."
		local w = draw.GetTextSize(sub)
		if w <= maxWidth then
			left = mid
		else
			right = mid - 1
		end
	end

	return text:sub(1, left) .. "..."
end

--[[ Vote Tracking ]]

local function startVote(team, voteidx, callerIdx, dispStr, detailsStr, targetIdx)
	local options = { "Yes", "No" }

	activeVote = {
		voteIdx = voteidx,
		team = team,
		caller = client.GetPlayerNameByIndex(callerIdx) or "Unknown",
		callerIdx = callerIdx,
		reason = localize(dispStr, detailsStr),
		targetName = targetIdx > 0 and client.GetPlayerNameByIndex(targetIdx) or "",
		targetIdx = targetIdx,
		options = options,
		votes = {
			[1] = {}, -- Yes votes
			[2] = {}, -- No votes
		},
		counts = { 0, 0 },
		startTime = globals.RealTime(),
	}

	targetAlpha = 255

	-- Console output as backup
	local config = getConfig()
	if config and config.Output and config.Output.Console then
		print(string.format("[Vote] %s started vote: %s", activeVote.caller, activeVote.reason))
	end
end

local function castVote(voteOption, team, playerIdx, voteidx)
	if not activeVote or activeVote.voteIdx ~= voteidx then
		return
	end

	local option = voteOption + 1 -- TF2 uses 0-indexed
	if option < 1 or option > 2 then
		return
	end

	local playerName = client.GetPlayerNameByIndex(playerIdx)
	if not playerName then
		return
	end

	local score = getPlayerScore(playerIdx)
	local teamName = getTeamName(team)

	-- Add to vote list
	table.insert(activeVote.votes[option], {
		name = playerName,
		team = team,
		teamName = teamName,
		score = score,
		idx = playerIdx,
	})

	-- Console output
	local config = getConfig()
	if config and config.Output and config.Output.Console then
		print(string.format("[Vote] %s voted: %s (Score: %d)", playerName, activeVote.options[option], score))
	end
end

local function updateVoteCounts(voteidx, counts)
	if not activeVote or activeVote.voteIdx ~= voteidx then
		return
	end

	for i = 1, 5 do
		activeVote.counts[i] = counts[i] or 0
	end
end

local function endVote(reason)
	if not activeVote then
		return
	end

	-- Console output
	local config = getConfig()
	if config and config.Output and config.Output.Console then
		print(string.format("[Vote] Vote ended: %s", reason or ""))
		for i, voters in ipairs(activeVote.votes) do
			if #voters > 0 then
				print(string.format("  %s: %d", activeVote.options[i], #voters))
				for _, voter in ipairs(voters) do
					print(string.format("    - %s [%s] (Score: %d)", voter.name, voter.teamName, voter.score))
				end
			end
		end
	end

	targetAlpha = 0
end

--[[ Visual Rendering ]]

local function lerpAlpha(dt)
	local speed = 800 -- Alpha units per second
	if voteAlpha < targetAlpha then
		voteAlpha = math.min(targetAlpha, voteAlpha + speed * dt)
	elseif voteAlpha > targetAlpha then
		voteAlpha = math.max(targetAlpha, voteAlpha - speed * dt)
	end

	-- Clear vote when fully faded out
	if voteAlpha <= 0 and targetAlpha == 0 then
		activeVote = nil
	end
end

local function drawVoteUI()
	if not activeVote or voteAlpha <= 0 then
		return
	end

	local config = getConfig()
	if not config or not config.Enable then
		return
	end

	local alpha = math.floor(voteAlpha)

	-- UI dimensions
	local screenW, _ = draw.GetScreenSize()
	local boxW = 320
	local boxX = (screenW - boxW) / 2
	local boxY = 50
	local padding = 8
	local lineHeight = 16

	-- Calculate height based on voter count (up to 10 per side)
	local maxVotersPerSide = math.max(#activeVote.votes[1], #activeVote.votes[2])
	local voterListHeight = math.min(maxVotersPerSide, 10) * lineHeight
	local headerHeight = 65 -- Title + caller + YES/NO headers
	local boxH = headerHeight + voterListHeight + padding * 2

	-- Dark background
	draw.Color(20, 20, 25, math.floor(alpha * 0.95))
	draw.FilledRect(boxX, boxY, boxX + boxW, boxY + boxH)

	-- Subtle border
	draw.Color(60, 60, 70, alpha)
	draw.OutlinedRect(boxX, boxY, boxX + boxW, boxY + boxH)

	-- Title bar background (slightly lighter)
	draw.Color(35, 35, 40, alpha)
	draw.FilledRect(boxX + 1, boxY + 1, boxX + boxW - 1, boxY + 24)

	-- Vote type title (VOTE KICK, VOTE MAP, etc)
	draw.SetFont(font_title)
	draw.Color(255, 255, 255, alpha)
	local voteType = activeVote.reason:upper()
	local typeW = draw.GetTextSize(voteType)
	draw.Text(boxX + (boxW - typeW) / 2, boxY + 4, voteType)

	-- Caller info with team color
	local callerTeamColor = TEAM_COLORS[activeVote.team] or TEAM_COLORS[TEAM_UNASSIGNED]
	draw.SetFont(font_body)
	draw.Color(150, 150, 150, alpha)
	local callerLabel = "Called by: "
	local labelW = draw.GetTextSize(callerLabel)
	draw.Text(boxX + padding, boxY + 28, callerLabel)

	draw.Color(callerTeamColor[1], callerTeamColor[2], callerTeamColor[3], alpha)
	local callerName = truncateText(activeVote.caller, boxW - labelW - padding * 2, font_body)
	draw.Text(boxX + padding + labelW, boxY + 28, callerName)

	-- Target info (if kick vote)
	if activeVote.targetName and #activeVote.targetName > 0 then
		draw.Color(150, 150, 150, alpha)
		local targetLabel = "Target: "
		local tLabelW = draw.GetTextSize(targetLabel)
		draw.Text(boxX + padding, boxY + 44, targetLabel)

		draw.Color(255, 180, 80, alpha)
		local targetName = truncateText(activeVote.targetName, boxW - tLabelW - padding * 2, font_body)
		draw.Text(boxX + padding + tLabelW, boxY + 44, targetName)
	end

	-- Divider line
	local dividerY = boxY + headerHeight - 18
	draw.Color(50, 50, 60, alpha)
	draw.Line(boxX + padding, dividerY, boxX + boxW - padding, dividerY)

	-- YES / NO column headers
	local colWidth = (boxW - padding * 3) / 2
	local yesColX = boxX + padding
	local noColX = boxX + padding * 2 + colWidth

	draw.SetFont(font_body)
	draw.Color(80, 200, 80, alpha)
	draw.Text(yesColX, dividerY + 4, "YES")

	draw.Color(200, 80, 80, alpha)
	draw.Text(noColX, dividerY + 4, "NO")

	-- Vertical divider between columns
	local vertDivX = boxX + boxW / 2
	draw.Color(50, 50, 60, math.floor(alpha * 0.7))
	draw.Line(vertDivX, dividerY + 20, vertDivX, boxY + boxH - padding)

	-- Draw voter lists
	draw.SetFont(font_small)
	local listY = dividerY + 22
	local maxNameWidth = colWidth - 4

	-- Sort Yes voters by score
	local sortedYes = {}
	for i, v in ipairs(activeVote.votes[1]) do
		sortedYes[i] = v
	end
	table.sort(sortedYes, function(a, b)
		return a.score > b.score
	end)

	for i = 1, math.min(#sortedYes, 10) do
		local voter = sortedYes[i]
		local voterTeamColor = TEAM_COLORS[voter.team]
		draw.Color(voterTeamColor[1], voterTeamColor[2], voterTeamColor[3], alpha)
		local nameText = truncateText(voter.name, maxNameWidth, font_small)
		draw.Text(yesColX, listY + (i - 1) * lineHeight, nameText)
	end

	-- Sort No voters by score
	local sortedNo = {}
	for i, v in ipairs(activeVote.votes[2]) do
		sortedNo[i] = v
	end
	table.sort(sortedNo, function(a, b)
		return a.score > b.score
	end)

	for i = 1, math.min(#sortedNo, 10) do
		local voter = sortedNo[i]
		local voterTeamColor = TEAM_COLORS[voter.team]
		draw.Color(voterTeamColor[1], voterTeamColor[2], voterTeamColor[3], alpha)
		local nameText = truncateText(voter.name, maxNameWidth, font_small)
		draw.Text(noColX, listY + (i - 1) * lineHeight, nameText)
	end

	-- Vote count at bottom right
	draw.SetFont(font_small)
	draw.Color(120, 120, 130, alpha)
	local countText = string.format("%d / %d", activeVote.counts[1] or 0, activeVote.counts[2] or 0)
	local countW = draw.GetTextSize(countText)
	draw.Text(boxX + boxW - countW - padding, boxY + boxH - lineHeight, countText)
end

--[[ Event Handlers ]]

local function handleUserMessage(msg)
	local id = msg:GetID()

	if id == VoteStart then
		local team = msg:ReadByte()
		local voteidx = msg:ReadInt(32)
		local callerIdx = msg:ReadByte()
		local dispStr = msg:ReadString(64)
		local detailsStr = msg:ReadString(64)
		local targetPacked = msg:ReadByte()
		local targetIdx = math.floor(targetPacked / 2) -- bit shift right by 1

		startVote(team, voteidx, callerIdx, dispStr, detailsStr, targetIdx)
	elseif id == VotePass then
		local team = msg:ReadByte()
		local voteidx = msg:ReadInt(32)
		local dispStr = msg:ReadString(256)
		local detailsStr = msg:ReadString(256)

		local reason = localize(dispStr, detailsStr)
		endVote("Vote Passed: " .. reason)
	elseif id == VoteFailed then
		local team = msg:ReadByte()
		local voteidx = msg:ReadInt(32)
		local failReason = msg:ReadByte()

		endVote("Vote Failed")
	end
end

local function handleGameEvent(event)
	local eventName = event:GetName()

	if eventName == "vote_cast" then
		local option = event:GetInt("vote_option")
		local team = event:GetInt("team")
		local playerIdx = event:GetInt("entityid")
		local voteidx = event:GetInt("voteidx")

		castVote(option, team, playerIdx, voteidx)
	elseif eventName == "vote_changed" then
		local voteidx = event:GetInt("voteidx")
		local counts = {}
		for i = 1, 5 do
			counts[i] = event:GetInt("vote_option" .. i)
		end
		updateVoteCounts(voteidx, counts)
	elseif eventName == "vote_options" then
		-- Update option names if needed
		if activeVote then
			for i = 1, event:GetInt("count") do
				activeVote.options[i] = event:GetString("option" .. i)
			end
		end
	end
end

local function onDraw()
	local currentTime = globals.RealTime()
	local dt = currentTime - lastUpdateTime
	lastUpdateTime = currentTime

	lerpAlpha(dt)
	drawVoteUI()
end

--[[ Registration ]]

callbacks.Unregister("DispatchUserMessage", "CD_VoteReveal_UserMsg")
callbacks.Register("DispatchUserMessage", "CD_VoteReveal_UserMsg", handleUserMessage)

callbacks.Unregister("FireGameEvent", "CD_VoteReveal_Event")
callbacks.Register("FireGameEvent", "CD_VoteReveal_Event", handleGameEvent)

callbacks.Unregister("Draw", "CD_VoteReveal_Draw")
callbacks.Register("Draw", "CD_VoteReveal_Draw", onDraw)

return VoteReveal
