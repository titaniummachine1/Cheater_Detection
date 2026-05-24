--[[ Evidence System - Weight-based cheater detection with context-aware decay ]]
--
-- Categories:
--   Aim: Context-aware decay (looking at enemies, damage dealt, distance)
--   Exploit: Time-based decay (doubletap, recharge, fakelag, anti-aim)
--   Movement: Time-based decay (bhop, strafe, duck speed)

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local Database = require("Cheater_Detection.Database.Database")
local Logger = require("Cheater_Detection.Utils.Logger")
local Constants = require("Cheater_Detection.Core.constants")
local DirtySystem = require("Cheater_Detection.Core.DirtySystem")
local Events = require("Cheater_Detection.Core.Events")

-- Own evidence store (keyed by steamID64 string)
local evidenceStore = {}

--[[ Module Declaration ]]
local Evidence = {}

--[[ Configuration ]]
Evidence.Config = {
	-- Decay rates per second
	DecayRates = {
		Aim = {
			default = 1.0, -- Base decay per second
			lookingAtEnemy = 2.0, -- Extra decay when looking at enemy
			hurtingEnemy = 3.0, -- Extra decay when dealing damage
			closeAim = 1.5, -- Extra decay when aiming close to enemy
		},
		Exploit = {
			default = 1.0, -- Exploit evidence decays by 1 point per second when not refreshed
		},
		Movement = {
			default = 1.0, -- 1 decay per second for fake lag
		},
	},

	-- Thresholds
	Evidence_Tolerance = 50,   -- Evidence threshold % (0–100) to mark as cheater
	MinWeightFloor = 0,        -- Cannot decay below this
	AutoPriorityThreshold = 12.0, -- Evidence score threshold to trigger SUSPICIOUS flag
	ExploitAutoCheaterMin = 70, -- Very high so fake lag alone rarely goes CHEATER
	MethodScoreCaps = {
		fake_lag = 60.0,
	},

	-- Category mappings (only implemented detections)
	Categories = {
		-- Aim detection methods
		Aim = {
			"silent_aimbot",
		},
		-- Exploit detection methods
		Exploit = {
			"warp_dt",
			"fake_lag",
			"anti_aim",
			"manual_priority",
		},
		-- Movement detection methods
		Movement = {
			"bhop",
			"duck_speed",
		},
	},
}

--[[ Private Variables ]]
-- Lazy decay: no batch system. Decay is applied on access using elapsed real time.

local DetectionToggles = {
	anti_aim = "AntiAim",
	bhop = "Bhop",
	fake_lag = "Choke", -- Choke = Fake Lag in config
	warp_dt = "Warp",
	duck_speed = "DuckSpeed",
	silent_aimbot = "SilentAimbot",
	manual_priority = "AutoFlagPriorityTen",
}

local lastGlobalDecayTime = 0

local function isDetectionEnabled(detectionName)
	local menu = G.Menu and G.Menu.Advanced
	if not menu then
		return true
	end
	local key = DetectionToggles[detectionName]
	if not key then
		return true
	end
	local flag = menu[key]
	return flag ~= false
end

--[[ Helper Functions ]]

-- Pre-built reverse map: detectionName -> category (built once at load time)
local categoryByDetection = {}
do
	for category, methods in pairs(Evidence.Config.Categories) do
		for _, method in ipairs(methods) do
			categoryByDetection[method] = category
		end
	end
end

local function getCategory(detectionName)
	return categoryByDetection[detectionName] or "Movement"
end

local function getOrCreateEvidence(steamID)
	if not evidenceStore[steamID] then
		evidenceStore[steamID] = {
			TotalScore = 0,
			Reasons = {},
		}
	end
	return evidenceStore[steamID]
end

local function recalcTotalScore(evidence)
	local total = 0
	for _, reason in pairs(evidence.Reasons) do
		total = total + reason.Weight
	end
	evidence.TotalScore = total
end

local function applyReasonOptions(reason, opts)
	if not reason or not opts then
		return
	end
	if opts.manualDecay ~= nil then
		reason.ManualDecay = opts.manualDecay == true
	end
	if opts.decayRate then
		reason.DecayRate = opts.decayRate
	end
end

local function getCategoryDecayRate(category)
	category = category or "Movement"
	local rates = Evidence.Config.DecayRates
	if category == "Aim" then
		return (rates.Aim and rates.Aim.default) or 0
	elseif category == "Exploit" then
		return (rates.Exploit and rates.Exploit.default) or 0
	elseif category == "Movement" then
		return (rates.Movement and rates.Movement.default) or 0
	end
	return 0
end

local function getMethodScoreCap(detectionName)
	local caps = Evidence.Config.MethodScoreCaps
	if caps and caps[detectionName] then
		return caps[detectionName]
	end
	return 200.0
end

local function getEvidenceScoreCap(evidence)
	local cap = 0
	if evidence and evidence.Reasons then
		for method, reason in pairs(evidence.Reasons) do
			if reason.Weight and reason.Weight > 0 then
				cap = cap + getMethodScoreCap(method)
			end
		end
	end
	if cap <= 0 then
		return 200.0
	end
	return cap
end

local function getEvidencePercent(evidence)
	local cap = getEvidenceScoreCap(evidence)
	local score = evidence and evidence.TotalScore or 0
	return math.min(100, math.floor((score / cap) * 100 + 0.5))
end

local function getPrimaryMethod(evidence)
	local primaryMethod = "Exploit"
	local onlyFakeLag = true
	if evidence and evidence.Reasons then
		for method, reason in pairs(evidence.Reasons) do
			if reason.Weight > 0 then
				if method ~= "fake_lag" then
					onlyFakeLag = false
				end
				if method == "fake_lag" and primaryMethod == "Exploit" then
					primaryMethod = "Fake Lag"
				elseif method == "warp_dt" then
					primaryMethod = "Double Tap / Warp"
				elseif method == "anti_aim" then
					primaryMethod = "Anti-Aim"
				end
			end
		end
	end
	return primaryMethod, onlyFakeLag
end

local function syncPlayerStateFromEvidence(steamID, evidence)
	local playerState = PlayerCache.GetByID(steamID)
	if not playerState then
		return
	end

	local hardMask = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.COMM_BANNED | Constants.Flags.VALVE
	if (playerState.flags & hardMask) ~= 0 then
		return
	end

	local threshold = Evidence.GetThreshold(evidence)
	local cheaterThreshold = Evidence.GetCheaterThreshold(evidence)
	local displayScore = math.min(99, getEvidencePercent(evidence))
	local oldFlags = playerState.flags or 0
	local oldScore = playerState.score or 0
	local primaryMethod, onlyFakeLag = getPrimaryMethod(evidence)
	local shouldMarkSuspicious = evidence.TotalScore >= threshold
	local shouldMarkCheater = evidence.TotalScore >= cheaterThreshold and not onlyFakeLag

	if shouldMarkCheater then
		playerState.flags = (oldFlags | Constants.Flags.CHEATER) & ~Constants.Flags.SUSPICIOUS
		playerState.score = 100
	elseif shouldMarkSuspicious then
		playerState.flags = oldFlags | Constants.Flags.SUSPICIOUS
		playerState.score = math.max(Constants.Threshold.SUSPICIOUS, displayScore)
	else
		playerState.flags = oldFlags & ~Constants.Flags.SUSPICIOUS & ~Constants.Flags.HIGH_RISK
		playerState.score = displayScore
		evidence.AutoPriorityApplied = false
	end
	playerState.detectionReason = shouldMarkSuspicious and primaryMethod or nil

	if playerState.score ~= oldScore then
		DirtySystem.MarkDirty(steamID, "score")
	end
	if playerState.flags ~= oldFlags then
		DirtySystem.MarkDirty(steamID, "flags")
		Events.Publish("OnPlayerStateChange", playerState, primaryMethod)
	end
	if playerState.score ~= oldScore or playerState.flags ~= oldFlags then
		DirtySystem.MarkDirty(steamID, "session")
	end
end

--[[ Public Functions ]]

local function getMenuPercent(key, defaultValue)
	local adv = G.Menu and G.Menu.Advanced or nil
	local pct = adv and adv[key]
	if pct == nil and key == "SuspicionThreshold" then
		local notifications = G.Menu and G.Menu.Notifications or nil
		pct = notifications and notifications.SuspicionThreshold
	end
	if type(pct) ~= "number" then
		pct = defaultValue
	end
	return math.max(0, math.min(100, pct))
end

--- Get the current suspicious evidence threshold from menu
---@param evidence table?
---@return number Current threshold value on this evidence stack's internal score scale
function Evidence.GetThreshold(evidence)
	local pct = getMenuPercent("SuspicionThreshold", 30)
	return getEvidenceScoreCap(evidence) * (pct / 100)
end

function Evidence.GetCheaterThreshold(evidence)
	local pct = getMenuPercent("Evidence_Tolerance", 85)
	return getEvidenceScoreCap(evidence) * (pct / 100)
end

function Evidence.GetMethodScoreCap(detectionName)
	return getMethodScoreCap(detectionName)
end

--- When evidence score crosses the configured % threshold, raise suspicion
--- and apply low auto-priority. Does NOT mark as a definitive CHEATER –
--- that requires a hard detection (anti-aim, etc.) going through its own path.
---@param steamID string
---@param evidence table
local function tryApplyAutoPriority(steamID, evidence)
	if not evidence then
		return
	end

	local threshold = Evidence.GetThreshold(evidence)
	local cheaterThreshold = Evidence.GetCheaterThreshold(evidence)

	Logger.Debug(
		"Evidence",
		string.format(
			"tryApplyAutoPriority: %s score=%.1f threshold=%.1f",
			steamID,
			evidence.TotalScore,
			threshold
		)
	)

	if evidence.TotalScore < threshold then
		Logger.Debug("Evidence",
			string.format("Score %.1f below threshold %.1f, returning", evidence.TotalScore, threshold))
		return
	end

	local shouldApplyPriority = not evidence.AutoPriorityApplied
	if not shouldApplyPriority then
		Logger.Debug("Evidence", "AutoPriority already applied, refreshing suspicious state only")
	end

	local playerName = "Unknown"
	local playerState = PlayerCache.GetByID(steamID)
	if playerState and playerState.wrap then
		local wrap = playerState.wrap
		if wrap.GetName and type(wrap.GetName) == "function" then
			local name = wrap:GetName()
			if name and name ~= "" then
				playerName = name
			end
		end
	end

	-- Set low suspicious priority if AutoPriority is enabled.
	local autoPriorityEnabled = false
	if G.Menu and G.Menu.Advanced and G.Menu.Advanced.AutoPriority ~= nil then
		autoPriorityEnabled = G.Menu.Advanced.AutoPriority == true
	elseif G.Menu and G.Menu.Main and G.Menu.Main.AutoPriority ~= nil then
		autoPriorityEnabled = G.Menu.Main.AutoPriority == true
	end

	Logger.Debug(
		"Evidence",
		string.format(
			"AutoPriority enabled: %s",
			tostring(autoPriorityEnabled)
		)
	)

	if true then
		if autoPriorityEnabled and shouldApplyPriority then
			Evidence.SetPriorityForSteamID(steamID, 1)
			evidence.AutoPriorityApplied = true
		end

		local playerState = PlayerCache.GetByID(steamID)
		if not playerState then
			Logger.Debug("Evidence", "PlayerCache state not found for " .. steamID)
			return
		end

		local displayScore = math.min(99, math.max(Constants.Threshold.SUSPICIOUS, getEvidencePercent(evidence)))
		local primaryMethod = "Exploit"
		local onlyFakeLag = true
		for method, reason in pairs(evidence.Reasons or {}) do
			if reason.Weight > 0 then
				if method ~= "fake_lag" then
					onlyFakeLag = false
				end
				if method == "fake_lag" and primaryMethod == "Exploit" then
					primaryMethod = "Fake Lag"
				elseif method == "warp_dt" then
					primaryMethod = "Double Tap / Warp"
				elseif method == "anti_aim" then
					primaryMethod = "Anti-Aim"
				end
			end
		end

		local oldFlags = playerState.flags or 0
		local oldScore = playerState.score or 0
		local shouldMarkCheater = evidence.TotalScore >= cheaterThreshold and not onlyFakeLag
		if shouldMarkCheater then
			playerState.flags = (oldFlags | Constants.Flags.CHEATER) & ~Constants.Flags.SUSPICIOUS
			playerState.score = 100
			if autoPriorityEnabled then
				Evidence.SetPriorityForSteamID(steamID, 10)
			end
		else
			playerState.flags = oldFlags | Constants.Flags.SUSPICIOUS
			playerState.score = math.max(oldScore, displayScore)
		end
		playerState.detectionReason = primaryMethod

		if playerState.score ~= oldScore then
			DirtySystem.MarkDirty(steamID, "score")
		end
		if playerState.flags ~= oldFlags then
			DirtySystem.MarkDirty(steamID, "flags")
			Events.Publish("OnPlayerStateChange", playerState, primaryMethod)
		end
		if playerState.score ~= oldScore or playerState.flags ~= oldFlags then
			DirtySystem.MarkDirty(steamID, "session")
		end

		Database.UpsertCheater(steamID, {
			name = playerName ~= "Unknown" and playerName or steamID,
			reason = primaryMethod,
			flags = playerState.flags,
			score = playerState.score,
		})

		Logger.Info(
			"Evidence",
			string.format(
				"%s flag set for %s (Score: %.1f >= %.1f) - %s evidence",
				shouldMarkCheater and "CHEATER" or "SUSPICIOUS",
				playerName,
				evidence.TotalScore,
				shouldMarkCheater and cheaterThreshold or threshold,
				primaryMethod
			)
		)
		if false then

		-- Set SUSPICIOUS flag for exploit evidence (DT, AA, fakelag) - not full CHEATER
		local wrap = PlayerCache.GetByID(steamID)
		if wrap then
			-- Convert evidence score (0-200) to playerState score (0-99) for display
			local displayScore = math.min(99, math.floor(evidence.TotalScore / 2))

			Logger.Debug("Evidence",
				string.format("Setting wrap.score to %d (evidence score %.1f)", displayScore, evidence.TotalScore))

			-- Try direct flag setting on wrap
			if wrap.SetFlag and type(wrap.SetFlag) == "function" then
				wrap:SetFlag(Constants.Flags.SUSPICIOUS, true)
				if wrap.SetScore then
					wrap:SetScore(displayScore)
				else
					wrap.score = displayScore
				end

				-- Mark score as dirty so visuals update
				local DirtySystem = require("Cheater_Detection.Core.DirtySystem")
				DirtySystem.MarkDirty(steamID, "score")
				DirtySystem.MarkDirty(steamID, "flags")
				Logger.Info(
					"Evidence",
					string.format(
						"SUSPICIOUS flag set for %s (Score: %.1f >= %.1f) – Exploit evidence",
						playerName,
						evidence.TotalScore,
						threshold
					)
				)
				-- Try setting through flags field
			elseif wrap.flags ~= nil then
				wrap.flags = wrap.flags | Constants.Flags.SUSPICIOUS
				wrap.score = displayScore
				Logger.Debug("Evidence", string.format("Setting wrap.score via flags field to %d", displayScore))

				-- Mark score as dirty so visuals update
				local DirtySystem = require("Cheater_Detection.Core.DirtySystem")
				DirtySystem.MarkDirty(steamID, "score")
				DirtySystem.MarkDirty(steamID, "flags")
				-- Store detection reason for display - use actual method name
				local primaryMethod = "Exploit"
				for method, reason in pairs(evidence.Reasons or {}) do
					if reason.Weight > 0 then
						if method == "fake_lag" then
							primaryMethod = "Fake Lag"
							break
						elseif method == "warp_dt" then
							primaryMethod = "Double Tap / Warp"
						elseif method == "anti_aim" then
							primaryMethod = "Anti-Aim"
						end
					end
				end
				wrap.detectionReason = primaryMethod
				Logger.Info(
					"Evidence",
					string.format(
						"SUSPICIOUS flag set for %s (Score: %.1f >= %.1f) – %s evidence (via flags field)",
						playerName,
						evidence.TotalScore,
						threshold,
						primaryMethod
					)
				)
			else
				Logger.Debug("Evidence", "Cannot set SUSPICIOUS flag - no SetFlag method or flags field on wrap")
			end
		else
			Logger.Debug("Evidence", "PlayerCache wrap not found for " .. steamID)
		end
		end
	else
		Logger.Debug("Evidence", "AutoPriority is disabled, not setting flag")
	end

	-- Debug breakdown of contributing detections
	if G.Menu.Advanced and G.Menu.Advanced.debug then
		for detName, reasonData in pairs(evidence.Reasons) do
			Logger.Debug(
				"Evidence",
				string.format(
					"  └ %s: weight=%.1f category=%s",
					detName,
					reasonData.Weight,
					tostring(reasonData.Category)
				)
			)
		end
	end
end

--- Add evidence weight for a specific detection
---@param steamID string Player's SteamID64
---@param detectionName string Detection method name
---@param weight number Weight to add
function Evidence.AddEvidence(steamID, detectionName, weight, opts)
	if not steamID or not detectionName or not weight then
		return
	end

	steamID = tostring(steamID)

	-- Skip local player unless debug mode is enabled
	if not G.Menu.Advanced.debug then
		local localPlayer = PlayerCache.GetLocal()
		if localPlayer then
			local localSteamID = localPlayer:GetSteamID64()
			if localSteamID and tostring(localSteamID) == steamID then
				return -- Skip local player
			end
		end
	end

	-- Debug: Log successful evidence add
	Logger.Debug("Evidence", string.format("Adding %.1f evidence for %s (method: %s)", weight, steamID, detectionName))

	local evidence = getOrCreateEvidence(steamID)
	if not evidence then
		return
	end

	-- Initialize detection stack if needed
	if not evidence.Reasons[detectionName] then
		evidence.Reasons[detectionName] = {
			Weight = 0,
			Category = getCategory(detectionName),
			LastDecayTime = globals.RealTime(),
		}
	end
	applyReasonOptions(evidence.Reasons[detectionName], opts)

	-- Apply accumulated lazy decay before adding new weight
	local reason = evidence.Reasons[detectionName]
	if reason.ManualDecay ~= true then
		local now = globals.RealTime()
		local elapsed = now - (reason.LastDecayTime or now)
		if elapsed > 0 then
			local rate = reason.DecayRate or getCategoryDecayRate(reason.Category)
			if rate > 0 then
				reason.Weight = math.max(0, reason.Weight - rate * elapsed)
			end
		end
		reason.LastDecayTime = now
	end

	-- Add weight
	reason.Weight = math.max(0, reason.Weight + weight)
	evidence.Dirty = true

	-- Recalculate total and check if player should be marked
	recalcTotalScore(evidence)

	-- Debug: log total score after adding evidence
	Logger.Debug(
		"Evidence",
		string.format(
			"Total score for %s: %.1f (added %.1f for %s)",
			steamID,
			evidence.TotalScore,
			weight,
			detectionName
		)
	)

	tryApplyAutoPriority(steamID, evidence)
end

--- No-op kept for API compatibility – decay is now lazy (applied on AddEvidence/GetScore).
local function applyDecayToEvidence(steamID, evidence, now)
	if not evidence or not evidence.Reasons then
		return false
	end

	local changed = false
	for _, reason in pairs(evidence.Reasons) do
		if reason.ManualDecay ~= true then
			local elapsed = now - (reason.LastDecayTime or now)
			if elapsed > 0 then
				local rate = reason.DecayRate or getCategoryDecayRate(reason.Category)
				if rate > 0 and reason.Weight > 0 then
					local oldWeight = reason.Weight
					reason.Weight = math.max(0, reason.Weight - rate * elapsed)
					if reason.Weight ~= oldWeight then
						changed = true
					end
				end
				reason.LastDecayTime = now
			end
		end
	end

	if changed then
		recalcTotalScore(evidence)
		evidence.Dirty = true
		syncPlayerStateFromEvidence(steamID, evidence)
	end
	return changed
end

function Evidence.ApplyDecay()
	local now = globals.RealTime()
	if (now - lastGlobalDecayTime) < 1.0 then
		return
	end
	lastGlobalDecayTime = now

	for steamID, evidence in pairs(evidenceStore) do
		applyDecayToEvidence(steamID, evidence, now)
	end
end

--- Check if player is marked as cheater (for detection skip optimization)
---@param steamID string Player's SteamID64
---@return boolean True if player is confirmed cheater
function Evidence.IsMarkedCheater(steamID)
	if not steamID then
		return false
	end

	-- Ensure steamID is a string for table lookup
	steamID = tostring(steamID)

	-- 1. Check player_cache first (pre-cached, zero allocation)
	local state = PlayerCache.GetByID(steamID)
	if state then
		local hardMask = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.COMM_BANNED
		if (state.flags & hardMask) ~= 0 then
			return true
		end
	end

	-- 2. Fallback: Check database with strict hard-evidence flags only.
	local entry = Database.GetCheater(steamID)
	if entry then
		local flags = tonumber(entry.Flags or 0) or 0
		local hardMask = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.COMM_BANNED
		if (flags & hardMask) ~= 0 then
			return true
		end
	end

	-- 3. Check playerlist priority
	local priority = playerlist.GetPriority(steamID)
	if priority == 10 then
		return true
	end

	return false
end

--- Apply manual decay to a specific detection method for a player
---@param steamID string Player's SteamID64
---@param detectionName string Detection method name
---@param decayAmount number Amount to decay
function Evidence.ApplyDecayForMethod(steamID, detectionName, decayAmount)
	if not steamID or not detectionName or not decayAmount then
		return
	end

	steamID = tostring(steamID)

	local evidence = getOrCreateEvidence(steamID)
	if not evidence then
		return
	end

	-- Initialize detection stack if needed
	if not evidence.Reasons[detectionName] then
		evidence.Reasons[detectionName] = {
			Weight = 0,
			Category = getCategory(detectionName),
			LastDecayTime = globals.RealTime(),
		}
	end
	local reason = evidence.Reasons[detectionName]
	reason.ManualDecay = true

	-- Apply decay (minimum 0)
	local oldWeight = reason.Weight
	reason.Weight = math.max(0, reason.Weight - decayAmount)

	-- Recalculate total if changed
	if oldWeight ~= reason.Weight then
		evidence.Dirty = true
		recalcTotalScore(evidence)

		tryApplyAutoPriority(steamID, evidence)

		-- Debug: Log decay
		Logger.Debug(
			"Evidence",
			string.format(
				"Decayed %.1f evidence for %s (method: %s, old: %.1f, new: %.1f)",
				decayAmount,
				steamID,
				detectionName,
				oldWeight,
				evidence.Reasons[detectionName].Weight
			)
		)
	end
end

--- Get current evidence score for a player
---@param steamID string Player's SteamID64
---@return number Total evidence score
function Evidence.GetScore(steamID)
	if not steamID then
		return 0
	end

	-- Ensure steamID is a string
	steamID = tostring(steamID)

	local evidence = evidenceStore[steamID]
	if not evidence then
		return 0
	end
	return evidence.TotalScore or 0
end

--- Get current evidence weight for a specific detection method
---@param steamID string Player's SteamID64
---@param detectionName string Detection method name
---@return number Current weight for this method
function Evidence.GetMethodWeight(steamID, detectionName)
	if not steamID or not detectionName then
		return 0
	end

	-- Ensure steamID is a string
	steamID = tostring(steamID)

	local evidence = evidenceStore[steamID]
	if not evidence or not evidence.Reasons then
		return 0
	end
	local methodData = evidence.Reasons[detectionName]
	if not methodData then
		return 0
	end
	return methodData.Weight or 0
end

--- Get detailed evidence breakdown for a player
---@param steamID string Player's SteamID64
---@return table? Evidence details
function Evidence.GetDetails(steamID)
	if not steamID then
		return nil
	end

	-- Ensure steamID is a string
	steamID = tostring(steamID)

	return evidenceStore[steamID]
end

--- Clean up player data when they leave (centralized black box)
---@param steamID string Player's SteamID64
function Evidence.OnPlayerLeave(steamID)
	-- Clean up evidence data
	evidenceStore[steamID] = nil
end

--- Set playerlist priority for a player by SteamID
---@param steamID string Player's SteamID64
---@param priority number Priority level to set (10 = cheater)
function Evidence.SetPriorityForSteamID(steamID, priority)
	if not steamID then
		return false
	end
	steamID = tostring(steamID)

	local playerState = PlayerCache.GetByID(steamID)
	if not playerState then
		return false
	end

	local wrap = playerState.wrap
	local entity = wrap and wrap.GetRawEntity and wrap:GetRawEntity() or nil

	if not entity then
		return false
	end

	local success = playerlist.SetPriority(entity, priority)
	if success then
		local name = wrap.GetName and wrap:GetName() or steamID
		Logger.Info("Evidence", string.format("Set priority %d for %s", priority, name))
		return true
	end
	return false
end

return Evidence
