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

local function isEnabled()
	local cfg = getConfig()
	return cfg and cfg.Enable
end

local function isIndicatorEnabled()
	local cfg = getConfig()
	if not cfg then
		return false
	end
	if cfg.Indicator == nil then
		return true
	end
	return cfg.Indicator == true
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

	-- For kick votes, detailsStr is the target name. If targetIdx is valid, we prefer engine name.
	local targetName = ""
	if targetIdx > 0 then
		targetName = client.GetPlayerNameByIndex(targetIdx) or detailsStr
	elseif dispStr:lower():find("kick") then
		targetName = detailsStr
	end

	activeVote = {
		voteIdx = voteidx,
		team = team,
		caller = client.GetPlayerNameByIndex(callerIdx) or "Unknown",
		callerIdx = callerIdx,
		reason = localize(dispStr, detailsStr),
		targetName = targetName,
		targetIdx = targetIdx,
		options = options,
		votes = {
			[1] = {}, -- Yes votes
			[2] = {}, -- No votes
		},
		counts = { 0, 0, 0, 0, 0 },
		startTime = globals.RealTime(),
		autoLeftGuaranteedKick = false,
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

-- Simplify vote type text
local function getVoteTypeText(reason)
	local lower = reason:lower()
	if lower:find("kick") then
		return "VOTE KICK"
	elseif lower:find("map") or lower:find("nextlevel") then
		return "VOTE MAP"
	elseif lower:find("scramble") then
		return "VOTE SCRAMBLE"
	elseif lower:find("restart") then
		return "VOTE RESTART"
	else
		return "VOTE"
	end
end

local function countEligibleTeamVoters(team)
	if type(team) ~= "number" or team <= TEAM_SPECTATOR then
		return 0
	end

	local eligible = 0
	local maxClients = (globals and globals.MaxClients and globals.MaxClients()) or 32
	for i = 1, maxClients do
		local info = client.GetPlayerInfo(i)
		if info and not info.IsBot and not info.IsHLTV then
			local player = entities.GetByIndex(i)
			if player and player.IsValid and player:IsValid() and player.GetTeamNumber then
				if player:GetTeamNumber() == team then
					eligible = eligible + 1
				end
			end
		end
	end

	return eligible
end

local function getVoteOutcomeState(yesCount, noCount, totalEligible)
	if totalEligible <= 0 then
		return "uncertain", yesCount, noCount, 0
	end

	local neededToPass = math.floor(totalEligible / 2) + 1
	local votesCast = yesCount + noCount
	local remaining = totalEligible - votesCast
	if remaining < 0 then
		remaining = 0
	end

	if yesCount >= neededToPass then
		return "pass", yesCount, noCount, neededToPass
	end

	local maxPossibleYes = yesCount + remaining
	if maxPossibleYes < neededToPass then
		return "fail", yesCount, noCount, neededToPass
	end

	return "uncertain", yesCount, noCount, neededToPass
end

local function shouldAutoLeaveGuaranteedKick(outcomeState)
	if outcomeState ~= "pass" then
		return false
	end

	if not activeVote or activeVote.autoLeftGuaranteedKick then
		return false
	end

	local cfg = getConfig()
	if not cfg or cfg.AutoLeaveOnGuaranteedLocalKick ~= true then
		return false
	end

	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer.IsValid or not localPlayer:IsValid() then
		return false
	end

	if activeVote.targetIdx ~= localPlayer:GetIndex() then
		return false
	end

	return true
end

local function drawVoteUI()
	if not activeVote or voteAlpha <= 0 then
		return
	end

	if not isEnabled() or not isIndicatorEnabled() then
		return
	end

	local alpha = math.floor(voteAlpha)

	-- UI dimensions (floor all to avoid sub-pixel rendering)
	local screenW, _ = draw.GetScreenSize()
	local boxW = 280
	local boxX = math.floor((screenW - boxW) / 2)
	local boxY = 55
	local pad = 12
	local lineH = 18
	local bottomBarsH = 34

	-- Calculate height
	local maxVoters = math.max(#activeVote.votes[1], #activeVote.votes[2])
	local voterRows = math.min(maxVoters, 8)
	local hasTarget = activeVote.targetName and #activeVote.targetName > 0
	local headerH = hasTarget and 70 or 52
	local boxH = headerH + (voterRows * lineH) + pad + bottomBarsH

	-- Background
	draw.Color(18, 18, 22, math.floor(alpha * 0.96))
	draw.FilledRect(boxX, boxY, boxX + boxW, boxY + boxH)

	-- Border
	draw.Color(55, 55, 65, alpha)
	draw.OutlinedRect(boxX, boxY, boxX + boxW, boxY + boxH)

	-- Title bar
	draw.Color(30, 30, 38, alpha)
	draw.FilledRect(boxX + 1, boxY + 1, boxX + boxW - 1, boxY + 26)

	-- Title text
	draw.SetFont(font_title)
	draw.Color(255, 255, 255, alpha)
	local voteType = getVoteTypeText(activeVote.reason)
	local typeW = draw.GetTextSize(voteType)
	draw.Text(math.floor(boxX + (boxW - typeW) / 2), boxY + 5, voteType)

	-- Caller line
	local callerY = boxY + 32
	local callerTeamColor = TEAM_COLORS[activeVote.team] or TEAM_COLORS[TEAM_UNASSIGNED]
	draw.SetFont(font_body)
	draw.Color(100, 100, 110, alpha)
	draw.Text(boxX + pad, callerY, "By:")
	draw.Color(callerTeamColor[1], callerTeamColor[2], callerTeamColor[3], alpha)
	local callerName = truncateText(activeVote.caller, boxW - pad * 2 - 30, font_body)
	draw.Text(boxX + pad + 28, callerY, callerName)

	-- Target line (if kick vote)
	local contentY = callerY + 18
	if hasTarget then
		draw.Color(100, 100, 110, alpha)
		draw.Text(boxX + pad, contentY, "On:")
		draw.Color(255, 170, 70, alpha)
		local targetName = truncateText(activeVote.targetName, boxW - pad * 2 - 30, font_body)
		draw.Text(boxX + pad + 28, contentY, targetName)
		contentY = contentY + 20
	end

	-- Horizontal divider
	draw.Color(45, 45, 55, alpha)
	draw.Line(boxX + pad, contentY, boxX + boxW - pad, contentY)

	-- Column setup (floor to avoid sub-pixel)
	local colW = math.floor((boxW - pad * 2) / 2)
	local yesX = boxX + pad
	local divX = math.floor(boxX + boxW / 2)
	local noX = divX + 5

	-- YES / NO headers
	contentY = contentY + 6
	draw.SetFont(font_body)
	draw.Color(70, 180, 70, alpha)
	draw.Text(yesX, contentY, "YES")
	draw.Color(180, 70, 70, alpha)
	draw.Text(noX, contentY, "NO")

	-- Vertical divider
	draw.Color(45, 45, 55, math.floor(alpha * 0.6))
	draw.Line(divX, contentY + 18, divX, boxY + boxH - pad - 14)

	-- Voter lists
	draw.SetFont(font_small)
	local listY = contentY + 20
	local nameW = colW - 8

	-- Yes voters
	local sortedYes = {}
	for i, v in ipairs(activeVote.votes[1]) do
		sortedYes[i] = v
	end
	table.sort(sortedYes, function(a, b)
		return a.score > b.score
	end)

	for i = 1, math.min(#sortedYes, 8) do
		local v = sortedYes[i]
		local tc = TEAM_COLORS[v.team]
		draw.Color(tc[1], tc[2], tc[3], alpha)
		draw.Text(yesX, listY + (i - 1) * lineH, truncateText(v.name, nameW, font_small))
	end

	-- No voters
	local sortedNo = {}
	for i, v in ipairs(activeVote.votes[2]) do
		sortedNo[i] = v
	end
	table.sort(sortedNo, function(a, b)
		return a.score > b.score
	end)

	for i = 1, math.min(#sortedNo, 8) do
		local v = sortedNo[i]
		local tc = TEAM_COLORS[v.team]
		draw.Color(tc[1], tc[2], tc[3], alpha)
		draw.Text(noX, listY + (i - 1) * lineH, truncateText(v.name, nameW, font_small))
	end

	-- Vote count (bottom right)
	draw.SetFont(font_small)
	draw.Color(90, 90, 100, alpha)
	local yesCount = activeVote.counts[1] or 0
	local noCount = activeVote.counts[2] or 0
	local countText = string.format("%d/%d", yesCount, noCount)
	local countW = draw.GetTextSize(countText)
	draw.Text(boxX + boxW - countW - pad, boxY + boxH - 30, countText)

	-- Bars (below voter lists)
	local barH = 5
	local barW = boxW - pad * 2
	local barX = boxX + pad
	local barY = boxY + boxH - 24

	-- Vote split bar background
	draw.Color(30, 30, 35, alpha)
	draw.FilledRect(barX, barY, barX + barW, barY + barH)

	-- Calculate progress
	-- TF2 vote kick usually requires a majority of connected players on the team
	-- We'll use the counts from the message for visual feedback
	local totalPossible = yesCount + noCount
	if totalPossible > 0 then
		local yesRatio = yesCount / totalPossible
		local yesWidth = math.floor(barW * yesRatio)

		-- YES portion (Green)
		draw.Color(70, 180, 70, alpha)
		draw.FilledRect(barX, barY, barX + yesWidth, barY + barH)

		-- NO portion (Red) - the rest of the bar if there are NO votes
		if noCount > 0 then
			draw.Color(180, 70, 70, alpha)
			draw.FilledRect(barX + yesWidth, barY, barX + barW, barY + barH)
		end
	end

	-- Guaranteed outcome bar (green=locked pass, red=locked fail, gray=still undecided)
	local totalEligible = countEligibleTeamVoters(activeVote.team)
	local outcomeState = getVoteOutcomeState(yesCount, noCount, totalEligible)
	local outcomeY = barY + 10
	draw.Color(30, 30, 35, alpha)
	draw.FilledRect(barX, outcomeY, barX + barW, outcomeY + barH)

	if outcomeState == "pass" then
		draw.Color(70, 180, 70, alpha)
		draw.FilledRect(barX, outcomeY, barX + barW, outcomeY + barH)
	elseif outcomeState == "fail" then
		draw.Color(180, 70, 70, alpha)
		draw.FilledRect(barX, outcomeY, barX + barW, outcomeY + barH)
	else
		draw.Color(130, 130, 140, alpha)
		draw.FilledRect(barX, outcomeY, barX + barW, outcomeY + barH)
	end

	if shouldAutoLeaveGuaranteedKick(outcomeState) then
		activeVote.autoLeftGuaranteedKick = true
		client.Command("disconnect", true)
	end
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
		local targetIdx = targetPacked >> 1

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

	if eventName == "vote_started" then
		-- Fallback for servers/builds where VoteStart usermessage is not delivered reliably.
		local team = event:GetInt("team")
		local voteidx = event:GetInt("voteidx")
		local callerIdx = event:GetInt("entityid")
		local dispStr = event:GetString("issue") or "#TF_vote_kick_player_other"
		local detailsStr = event:GetString("param1") or ""
		local targetIdx = event:GetInt("target")

		if voteidx and voteidx > 0 then
			startVote(team, voteidx, callerIdx, dispStr, detailsStr, targetIdx)
		end
	elseif eventName == "vote_cast" then
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

--[[ Public API ]]

--- Get the current active vote data (for retaliation tracking)
function VoteReveal.GetActiveVote()
	return activeVote
end

--- Get who voted No on the current/last vote
--- Returns list of {idx, name, steamID} or empty table
function VoteReveal.GetNoVoters()
	if not activeVote or not activeVote.votes or not activeVote.votes[2] then
		return {}
	end

	local noVoters = {}
	for _, voter in ipairs(activeVote.votes[2]) do
		local steamID = nil
		if voter.idx then
			local info = client.GetPlayerInfo(voter.idx)
			if info and info.SteamID then
				-- Convert SteamID3 to SteamID64
				local accountID = tonumber(info.SteamID:match("%[U:1:(%d+)%]"))
				if accountID then
					steamID = tostring(76561197960265728 + accountID)
				end
			end
		end
		table.insert(noVoters, {
			idx = voter.idx,
			name = voter.name,
			steamID = steamID,
		})
	end
	return noVoters
end

--- Get who voted Yes on the current/last vote
--- Returns list of {idx, name, steamID} or empty table
function VoteReveal.GetYesVoters()
	if not activeVote or not activeVote.votes or not activeVote.votes[1] then
		return {}
	end

	local yesVoters = {}
	for _, voter in ipairs(activeVote.votes[1]) do
		local steamID = nil
		if voter.idx then
			local info = client.GetPlayerInfo(voter.idx)
			if info and info.SteamID then
				-- Convert SteamID3 to SteamID64
				local accountID = tonumber(info.SteamID:match("%[U:1:(%d+)%]"))
				if accountID then
					steamID = tostring(76561197960265728 + accountID)
				end
			end
		end
		table.insert(yesVoters, {
			idx = voter.idx,
			name = voter.name,
			steamID = steamID,
		})
	end
	return yesVoters
end

--[[ Registration ]]

callbacks.Unregister("DispatchUserMessage", "CD_VoteReveal_UserMsg")
callbacks.Register("DispatchUserMessage", "CD_VoteReveal_UserMsg", handleUserMessage)

callbacks.Unregister("FireGameEvent", "CD_VoteReveal_Event")
callbacks.Register("FireGameEvent", "CD_VoteReveal_Event", handleGameEvent)

callbacks.Unregister("Draw", "CD_VoteReveal_Draw")
callbacks.Register("Draw", "CD_VoteReveal_Draw", onDraw)

return VoteReveal
