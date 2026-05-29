--[[ ReasonWeightResolver.lua
     Scores reason strings by their semantic category weight.
     Used to ensure the most important detection reason is always displayed.
]]

local Constants = require("Cheater_Detection.Core.constants")

local ReasonWeightResolver = {}

local categoryWeights = Constants.ReasonCategoryWeights

--- Score a reason string by matching against category weight patterns.
--- Uses the highest matching weight so merged reasons like "Cheater | Bot (...)" keep bot priority.
---@param reason string|nil The reason string to score
---@return number weight
function ReasonWeightResolver.ScoreReason(reason)
	if type(reason) ~= "string" or reason == "" then
		return 0
	end

	-- "Not a Bot (...)" contains "Bot (" — treat explicit clears before max-match scoring.
	if reason:find("Not a Bot", 1, true) or reason:find("not a bot", 1, true) then
		return 0
	end

	local best = 0
	for _, entry in ipairs(categoryWeights) do
		if reason:find(entry.pattern, 1, true) and entry.weight > best then
			best = entry.weight
		end
	end

	return best
end

--- Compare two reasons and return the one with higher weight.
--- If weights are equal, returns the first (existing) reason.
---@param reasonA string|nil
---@param reasonB string|nil
---@return string|nil bestReason
function ReasonWeightResolver.PickBestReason(reasonA, reasonB)
	local weightA = ReasonWeightResolver.ScoreReason(reasonA)
	local weightB = ReasonWeightResolver.ScoreReason(reasonB)

	if weightA >= weightB then
		return reasonA
	end
	return reasonB
end

--- Check if reasonB should override reasonA based on weight comparison.
--- Returns true only if reasonB has strictly higher weight.
---@param reasonA string|nil
---@param reasonB string|nil
---@return boolean shouldOverride
function ReasonWeightResolver.ShouldOverride(reasonA, reasonB)
	local weightA = ReasonWeightResolver.ScoreReason(reasonA)
	local weightB = ReasonWeightResolver.ScoreReason(reasonB)
	return weightB > weightA
end

--- Get the source weight for a given source identifier.
---@param sourceID string|nil
---@return number weight
function ReasonWeightResolver.GetSourceWeight(sourceID)
	if type(sourceID) ~= "string" then
		return 0
	end
	return Constants.SourceWeights[sourceID] or 0
end

--- Compare two source IDs and return the one with higher weight.
---@param sourceA string|nil
---@param sourceB string|nil
---@return string|nil bestSource
function ReasonWeightResolver.PickBestSource(sourceA, sourceB)
	local weightA = ReasonWeightResolver.GetSourceWeight(sourceA)
	local weightB = ReasonWeightResolver.GetSourceWeight(sourceB)

	if weightA >= weightB then
		return sourceA
	end
	return sourceB
end

--- Check if incoming evidence should override existing evidence.
--- Reason weight is primary; source/static weight only breaks equal-reason ties.
---@param reasonA string|nil Existing reason
---@param reasonB string|nil Incoming reason
---@param sourceA string|nil Existing static/source ID
---@param sourceB string|nil Incoming static/source ID
---@return boolean shouldOverride
function ReasonWeightResolver.ShouldOverrideEvidence(reasonA, reasonB, sourceA, sourceB)
	local reasonWeightA = ReasonWeightResolver.ScoreReason(reasonA)
	local reasonWeightB = ReasonWeightResolver.ScoreReason(reasonB)

	if reasonWeightB ~= reasonWeightA then
		return reasonWeightB > reasonWeightA
	end

	local sourceWeightA = ReasonWeightResolver.GetSourceWeight(sourceA)
	local sourceWeightB = ReasonWeightResolver.GetSourceWeight(sourceB)
	return sourceWeightB > sourceWeightA
end

return ReasonWeightResolver
