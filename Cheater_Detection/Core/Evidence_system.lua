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

	-- No decay until this many seconds after LastDecayTime (HoldDecay resets the clock).
	MethodDecayGraceSec = 60.0,

	-- Per-method decay (weight/sec). double_tap: ~1 usage (30) per minute when idle.
	MethodDecayPerSec = {
		double_tap = 30.0 / 60.0,
		warp_dt    = 30.0 / 60.0,
		fake_lag   = 5.0 / 60.0, -- ~one FL credit (5 pts) per minute idle
		bhop       = 2.0 / 60.0,
		duck_speed = 5.0 / 60.0,
	},

	-- Thresholds
	Evidence_Tolerance = 50,   -- Evidence threshold % (0–100) to mark as cheater
	MinWeightFloor = 0,        -- Cannot decay below this
	AutoPriorityThreshold = 12.0, -- Evidence score threshold to trigger SUSPICIOUS flag
	ExploitAutoCheaterMin = 70, -- Per-method % of cap; also marks CHEATER (see isExploitAtAutoCheaterMin)
	MethodScoreCaps = {
		fake_lag    = 120.0, -- ~24 credits at 5 pts (stricter than old 60 cap)
		double_tap  = 300.0, -- ~10 usages at DT_USAGE_WEIGHT (30) in double_tap.lua
		warp_dt     = 300.0,
		bhop        = 60.0,
		duck_speed  = 100.0,
	},

	-- Category mappings (only implemented detections)
	Categories = {
		-- Aim detection methods
		Aim = {
			"silent_aimbot",
		},
		-- Exploit detection methods
		Exploit = {
			"double_tap",
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
	double_tap = "DoubleTap",
	warp_dt = "DoubleTap",
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

local function getCategoryDecayRate(category)
	assert(category, "getCategoryDecayRate: category missing")
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

local function getMethodDecayRate(detectionName, category)
	local perMethod = Evidence.Config.MethodDecayPerSec
	if detectionName and perMethod and perMethod[detectionName] then
		return perMethod[detectionName]
	end
	return getCategoryDecayRate(category)
end

local function getDecayGraceSec()
	return Evidence.Config.MethodDecayGraceSec or 60.0
end

local function applyWeightDecay(reason, detectionName, methodName, now)
	if not reason or reason.ManualDecay == true then
		return false
	end

	local elapsed = now - (reason.LastDecayTime or now)
	local grace = getDecayGraceSec()
	if elapsed <= grace then
		return false
	end

	local rate = reason.DecayRate or getMethodDecayRate(methodName or detectionName, reason.Category)
	if not isDetectionEnabled(methodName or detectionName) then
		rate = rate * 5.0
	end
	if rate <= 0 or reason.Weight <= 0 then
		reason.LastDecayTime = now
		return false
	end

	local oldWeight = reason.Weight
	reason.Weight = math.max(
		Evidence.Config.MinWeightFloor,
		reason.Weight - rate * (elapsed - grace)
	)
	reason.LastDecayTime = now
	return reason.Weight ~= oldWeight
end

local function applyLazyDecayToReason(reason, detectionName)
	applyWeightDecay(reason, detectionName, detectionName, globals.RealTime())
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

-- Cheater line uses strongest active method cap so a little fake_lag weight does not
-- inflate the bar when double_tap is already near cap (sum cap would be 300+120=420).
local function getEvidenceMaxMethodCap(evidence)
	local maxCap = 0
	if evidence and evidence.Reasons then
		for method, reason in pairs(evidence.Reasons) do
			if reason.Weight and reason.Weight > 0 then
				maxCap = math.max(maxCap, getMethodScoreCap(method))
			end
		end
	end
	if maxCap <= 0 then
		return 200.0
	end
	return maxCap
end

local exploitMethodSet = nil
local function isExploitMethod(detectionName)
	if not exploitMethodSet then
		exploitMethodSet = {}
		for _, name in ipairs(Evidence.Config.Categories.Exploit or {}) do
			exploitMethodSet[name] = true
		end
	end
	return exploitMethodSet[detectionName] == true
end

local function isExploitAtAutoCheaterMin(evidence)
	local minPct = Evidence.Config.ExploitAutoCheaterMin or 70
	if not evidence or not evidence.Reasons then
		return false
	end
	for method, reason in pairs(evidence.Reasons) do
		if isExploitMethod(method) and reason.Weight and reason.Weight > 0 then
			local cap = getMethodScoreCap(method)
			if reason.Weight >= cap * (minPct / 100) then
				return true
			end
		end
	end
	return false
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
				elseif method == "double_tap" or method == "warp_dt" then
					primaryMethod = "Double Tap"
				elseif method == "anti_aim" then
					primaryMethod = "Anti-Aim"
				elseif method == "duck_speed" then
					primaryMethod = "Duck Speed"
				elseif method == "bhop" then
					primaryMethod = "Bhop"
				end
			end
		end
	end
	return primaryMethod, onlyFakeLag
end

local function syncPlayerStateFromEvidence(steamID, evidence)
	assert(steamID, "syncPlayerStateFromEvidence: steamID missing")
	assert(evidence, "syncPlayerStateFromEvidence: evidence missing")
	local playerState = PlayerCache.GetByID(steamID)
	if not playerState then
		return
	end

	local hardMask = Constants.Flags.CHEATER | Constants.Flags.VAC_BANNED | Constants.Flags.COMM_BANNED |
		Constants.Flags.VALVE
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
	local shouldMarkCheater = evidence.TotalScore >= cheaterThreshold
		or isExploitAtAutoCheaterMin(evidence)

	-- Track active evidence to prevent double-decay in player_cache
	if evidence.TotalScore > 0 then
		playerState.hasActiveEvidence = true
	else
		playerState.hasActiveEvidence = nil
	end

	local newFlags = oldFlags
	local newScore = displayScore

	if shouldMarkCheater then
		newFlags = (oldFlags | Constants.Flags.CHEATER) & ~Constants.Flags.SUSPICIOUS
		newScore = 100
	elseif shouldMarkSuspicious then
		newFlags = oldFlags | Constants.Flags.SUSPICIOUS
		newScore = math.max(1, displayScore) -- minimum 1% suspicion display for feedback
	else
		newFlags = oldFlags & ~Constants.Flags.SUSPICIOUS & ~Constants.Flags.HIGH_RISK
		newScore = displayScore
		evidence.AutoPriorityApplied = false
	end

	playerState.flags = newFlags
	playerState.score = newScore
	playerState.detectionReason = shouldMarkSuspicious and primaryMethod or nil

	if playerState.score ~= oldScore then
		DirtySystem.MarkDirty(steamID, "score")
	end

	if playerState.flags ~= oldFlags then
		DirtySystem.MarkDirty(steamID, "flags")
		Events.Publish("OnPlayerStateChange", playerState, primaryMethod)

		-- Log transition to Suspicious or Cheater
		local name = playerState.wrap:GetName() or steamID
		if (newFlags & Constants.Flags.CHEATER) ~= 0 and (oldFlags & Constants.Flags.CHEATER) == 0 then
			Logger.Info(
				"Evidence",
				string.format(
					"CHEATER flag set for %s (Score: %.1f >= %.1f) - %s evidence",
					name,
					evidence.TotalScore,
					cheaterThreshold,
					primaryMethod
				)
			)
		elseif (newFlags & Constants.Flags.SUSPICIOUS) ~= 0 and (oldFlags & Constants.Flags.SUSPICIOUS) == 0 then
			Logger.Info(
				"Evidence",
				string.format(
					"SUSPICIOUS flag set for %s (Score: %.1f >= %.1f) - %s evidence",
					name,
					evidence.TotalScore,
					threshold,
					primaryMethod
				)
			)
		end
	end

	if playerState.score ~= oldScore or playerState.flags ~= oldFlags then
		DirtySystem.MarkDirty(steamID, "session")

		-- Automatically upsert database entry to keep persistent state synchronized
		local name = playerState.wrap:GetName() or steamID
		Database.UpsertCheater(steamID, {
			name = name ~= "Unknown" and name or steamID,
			reason = primaryMethod,
			flags = playerState.flags,
			score = playerState.score,
		})
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
	return getEvidenceMaxMethodCap(evidence) * (pct / 100)
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
	assert(steamID, "tryApplyAutoPriority: steamID missing")
	assert(evidence, "tryApplyAutoPriority: evidence missing")

	local threshold = Evidence.GetThreshold(evidence)
	Logger.Debug(
		"Evidence",
		string.format(
			"tryApplyAutoPriority: %s score=%.1f threshold=%.1f",
			steamID,
			evidence.TotalScore,
			threshold
		)
	)

	-- Always sync player state first
	syncPlayerStateFromEvidence(steamID, evidence)

	local playerState = PlayerCache.GetByID(steamID)
	if not playerState then
		return
	end

	-- Set low suspicious priority if AutoPriority is enabled.
	local autoPriorityEnabled = false
	if G.Menu and G.Menu.Advanced and G.Menu.Advanced.AutoPriority ~= nil then
		autoPriorityEnabled = G.Menu.Advanced.AutoPriority == true
	elseif G.Menu and G.Menu.Main and G.Menu.Main.AutoPriority ~= nil then
		autoPriorityEnabled = G.Menu.Main.AutoPriority == true
	end

	if autoPriorityEnabled then
		local isCheater = (playerState.flags & Constants.Flags.CHEATER) ~= 0
		local isSus = (playerState.flags & Constants.Flags.SUSPICIOUS) ~= 0

		if isCheater then
			Evidence.SetPriorityForSteamID(steamID, 10)
		elseif isSus and not evidence.AutoPriorityApplied then
			Evidence.SetPriorityForSteamID(steamID, 1)
			evidence.AutoPriorityApplied = true
			print(string.format("[CD] heads up: (%s) might be cheating", playerState.wrap:GetName() or steamID))
		end
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

	if detectionName == "fake_lag" then
		local adv = G.Menu and G.Menu.Advanced
		if not adv or adv.Choke ~= true then
			return
		end
	elseif not isDetectionEnabled(detectionName) then
		return
	end

	steamID = tostring(steamID)

	-- DEBUG MODE: evidence on local player is allowed (self-test). Off = never flag yourself.
	local localID = PlayerCache.GetLocalID()
	if localID and steamID == localID and not Common.IsDebugEnabled() then
		return
	end

	-- Debug: Log successful evidence add
	Logger.Debug("Evidence", string.format("Adding %.1f evidence for %s (method: %s)", weight, steamID, detectionName))

	local evidence = getOrCreateEvidence(steamID)
	if not evidence then
		return
	end

	-- Initialize detection stack if needed
	if not evidence.Reasons[detectionName] then
		local category = getCategory(detectionName)
		evidence.Reasons[detectionName] = {
			Weight = 0,
			Category = category,
			LastDecayTime = globals.RealTime(),
			DecayRate = getMethodDecayRate(detectionName, category),
		}
	end
	applyReasonOptions(evidence.Reasons[detectionName], opts)

	-- Apply accumulated lazy decay before adding new weight
	local reason = evidence.Reasons[detectionName]
	applyLazyDecayToReason(reason, detectionName)

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

	-- Skip decay entirely for confirmed cheaters: the CHEATER flag cannot be
	-- downgraded by score decay (syncPlayerStateFromEvidence guards against it),
	-- so computing decay is wasted work once the flag is set.
	local state = PlayerCache.GetByID(steamID)
	if state then
		if (state.flags & Constants.Flags.CHEATER) ~= 0 then
			return false
		end
		local pdata = state.pdata
		if pdata and (pdata.isDormant or not pdata.isAlive) then
			return false
		end
	end

	local changed = false
	for methodName, reason in pairs(evidence.Reasons) do
		if applyWeightDecay(reason, methodName, methodName, now) then
			changed = true
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

--- Pause time-based decay while a detection is still actively firing (e.g. ongoing fakelag).
---@param steamID string Player's SteamID64
---@param detectionName string Detection method name
function Evidence.HoldDecayForMethod(steamID, detectionName)
	if not steamID or not detectionName then
		return
	end
	if not isDetectionEnabled(detectionName) then
		return
	end

	steamID = tostring(steamID)
	local evidence = evidenceStore[steamID]
	if not evidence or not evidence.Reasons then
		return
	end
	local reason = evidence.Reasons[detectionName]
	if not reason or reason.ManualDecay == true then
		return
	end
	reason.LastDecayTime = globals.RealTime()
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

--- Drop runtime evidence stack (used for local player when debug mode is OFF).
---@param steamID string
function Evidence.ClearPlayer(steamID)
	if not steamID then
		return
	end
	steamID = tostring(steamID)
	evidenceStore[steamID] = nil

	local playerState = PlayerCache.GetByID(steamID)
	if not playerState then
		return
	end

	playerState.hasActiveEvidence = nil
	local hardMask = Constants.Flags.CHEATER | Constants.Flags.SUSPICIOUS | Constants.Flags.HIGH_RISK
	if (playerState.flags & hardMask) ~= 0 or (playerState.score or 0) > 0 then
		playerState.flags = (playerState.flags or 0) & ~hardMask
		playerState.score = 0
		playerState.detectionReason = nil
		playerState.wrap:SetPriority(0)
		DirtySystem.MarkDirty(steamID, "flags")
		DirtySystem.MarkDirty(steamID, "score")
	end
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

	local ent = playerState.wrap:GetEntity()
	if not ent or not ent:IsValid() then
		return false
	end
	local success = playerlist.SetPriority(ent, priority)
	if success then
		local name = playerState.wrap:GetName() or steamID
		Logger.Info("Evidence", string.format("Set priority %d for %s", priority, name))
		return true
	end
	return false
end

return Evidence
