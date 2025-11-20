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
	local screenW, screenH = draw.GetScreenSize()
	local boxW = 350
	local boxX = (screenW - boxW) / 2
	local boxY = 50
	local padding = 10
	local lineHeight = 18

	-- Team color for background
	local teamColor = TEAM_COLORS[activeVote.team] or TEAM_COLORS[TEAM_UNASSIGNED]
	local bgR, bgG, bgB = teamColor[1], teamColor[2], teamColor[3]

	-- Calculate height based on voter count (up to 12 per side)
	local maxVotersPerSide = math.max(#activeVote.votes[1], #activeVote.votes[2])
	local voterListHeight = math.min(maxVotersPerSide, 12) * lineHeight
	local boxH = 80 + voterListHeight + padding * 3

	-- Draw background with team color tint
	draw.Color(bgR, bgG, bgB, math.floor(alpha * 0.7))
	draw.FilledRect(boxX, boxY, boxX + boxW, boxY + boxH)

	-- Draw border
	draw.Color(255, 255, 255, alpha)
	draw.OutlinedRect(boxX, boxY, boxX + boxW, boxY + boxH)

	-- Draw title background
	draw.Color(30, 30, 30, math.floor(alpha * 0.8))
	draw.FilledRect(boxX, boxY, boxX + boxW, boxY + 30)

	-- Draw vote reason
	draw.SetFont(font_title)
	draw.Color(255, 255, 255, alpha)
	local reasonText = truncateText(activeVote.reason, boxW - padding * 2, font_title)
	local textW = draw.GetTextSize(reasonText)
	draw.Text(boxX + (boxW - textW) / 2, boxY + 8, reasonText)

	-- Draw white divider line (vertical center)
	local dividerX = boxX + boxW / 2
	draw.Color(255, 255, 255, math.floor(alpha * 0.5))
	draw.Line(dividerX, boxY + 35, dividerX, boxY + boxH - 25)

	-- Draw Yes/No headers
	draw.SetFont(font_body)
	draw.Color(100, 255, 100, alpha)
	local yesW = draw.GetTextSize("YES")
	draw.Text(boxX + (boxW / 4) - yesW / 2, boxY + 38, "YES")

	draw.Color(255, 100, 100, alpha)
	local noW = draw.GetTextSize("NO")
	draw.Text(boxX + (boxW * 3 / 4) - noW / 2, boxY + 38, "NO")

	-- Draw voter lists (sorted by score, highest first)
	draw.SetFont(font_small)
	local yesX = boxX + padding
	local noX = dividerX + padding
	local listY = boxY + 60
	local maxWidth = (boxW / 2) - padding * 2

	-- Sort and draw Yes voters
	local sortedYes = {}
	for i, v in ipairs(activeVote.votes[1]) do
		sortedYes[i] = v
	end
	table.sort(sortedYes, function(a, b)
		return a.score > b.score
	end)

	for i = 1, math.min(#sortedYes, 12) do
		local voter = sortedYes[i]
		local voterTeamColor = TEAM_COLORS[voter.team]
		draw.Color(voterTeamColor[1], voterTeamColor[2], voterTeamColor[3], alpha)
		local nameText = truncateText(voter.name, maxWidth, font_small)
		draw.Text(yesX, listY + (i - 1) * lineHeight, nameText)
	end

	-- Sort and draw No voters
	local sortedNo = {}
	for i, v in ipairs(activeVote.votes[2]) do
		sortedNo[i] = v
	end
	table.sort(sortedNo, function(a, b)
		return a.score > b.score
	end)

	for i = 1, math.min(#sortedNo, 12) do
		local voter = sortedNo[i]
		local voterTeamColor = TEAM_COLORS[voter.team]
		draw.Color(voterTeamColor[1], voterTeamColor[2], voterTeamColor[3], alpha)
		local nameText = truncateText(voter.name, maxWidth, font_small)
		draw.Text(noX, listY + (i - 1) * lineHeight, nameText)
	end

	-- Draw target name at bottom (if kick vote)
	if activeVote.targetName and #activeVote.targetName > 0 then
		draw.SetFont(font_body)
		draw.Color(255, 200, 100, alpha)
		local targetText = truncateText("Target: " .. activeVote.targetName, boxW - padding * 2, font_body)
		local targetW = draw.GetTextSize(targetText)
		draw.Text(boxX + (boxW - targetW) / 2, boxY + boxH - 20, targetText)
	end

	-- Draw vote counts
	draw.SetFont(font_small)
	draw.Color(255, 255, 255, math.floor(alpha * 0.8))
	local countText = string.format("[%d/%d]", activeVote.counts[1] or 0, activeVote.counts[2] or 0)
	local countW = draw.GetTextSize(countText)
	draw.Text(boxX + (boxW - countW) / 2, boxY + boxH - 38, countText)
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
		local targetIdx = bit.rshift(targetPacked, 1) or 0

		startVote(team, voteidx, callerIdx, dispStr, detailsStr, targetIdx)
	elseif id == VotePass then
		local team = msg:ReadByte()
		local voteidx = msg:ReadInt(32)
		local dispStr = msg.ReadString(256)
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
