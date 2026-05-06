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
			default = 0.5, -- Slow decay for exploits
		},
		Movement = {
			default = 0.8, -- Medium decay for movement
		},
	},

	-- Thresholds
	Evidence_Tolerance = 50, -- Evidence threshold % (0–100) to mark as cheater
	MinWeightFloor = 0,   -- Cannot decay below this

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

--[[ Public Functions ]]

--- Get the current evidence threshold from menu
---@return number Current threshold value (internal 0-200 score scale)
function Evidence.GetThreshold()
	-- Stored as 0–100 % in the menu; multiply by 2 to map to the internal score scale
	local pct = G.Menu.Advanced.Evidence_Tolerance
	if type(pct) ~= "number" then
		pct = 50 -- default 50%
	end
	if pct > 100 then
		pct = 50 -- clamp legacy raw value
	end
	return pct * 2
end

--- When evidence score crosses the configured % threshold, raise suspicion
--- and apply auto-priority (priority 10). Does NOT mark as a definitive CHEATER –
--- that requires a hard detection (anti-aim, etc.) going through its own path.
---@param steamID string
---@param evidence table
local function tryApplyAutoPriority(steamID, evidence)
	if not evidence then
		return
	end

	local threshold = Evidence.GetThreshold()

	if evidence.TotalScore < threshold then
		return
	end

	-- Already raised priority this session? Skip to avoid spam.
	if evidence.AutoPriorityApplied then
		return
	end
	evidence.AutoPriorityApplied = true

	local playerName = "Unknown"
	local wrap = PlayerCache.GetBySteamID(steamID)
	if wrap then
		local name = wrap:GetName()
		if name and name ~= "" then
			playerName = name
		end
	end

	-- Set priority 10 if AutoPriority is enabled
	if G.Menu.Main and G.Menu.Main.AutoPriority then
		Evidence.SetPriorityForSteamID(steamID, 10)
		Logger.Info(
			"Evidence",
			string.format(
				"Auto-priority 10 applied to %s (Score: %.1f >= %.1f) – SUSPICIOUS",
				playerName,
				evidence.TotalScore,
				threshold
			)
		)
	else
		Logger.Debug(
			"Evidence",
			string.format(
				"%s crossed suspicion threshold (%.1f >= %.1f) but AutoPriority is off",
				playerName,
				evidence.TotalScore,
				threshold
			)
		)
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

	-- Convert to string and validate SteamID64 format
	steamID = tostring(steamID)

	-- SteamID64 must be 17 digits starting with 7656119 (valid Steam accounts)
	-- Silently skip bots/invalid IDs (they won't match this pattern)
	if not steamID:match("^7656119%d+$") or #steamID ~= 17 then
		return -- Skip silently (bots return UserID instead of SteamID64)
	end

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
	reason.Weight = reason.Weight + weight
	evidence.Dirty = true

	-- Recalculate total and check if player should be marked
	recalcTotalScore(evidence)

	tryApplyAutoPriority(steamID, evidence)
end

--- No-op kept for API compatibility – decay is now lazy (applied on AddEvidence/GetScore).
function Evidence.ApplyDecay()
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

	-- Check database first (known cheater lists)
	if G.DataBase[steamID] then
		return true
	end

	-- Check playerlist priority
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

	-- Convert to string and validate SteamID64 format
	steamID = tostring(steamID)

	if not steamID:match("^7656119%d+$") or #steamID ~= 17 then
		return
	end

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

	local wrap = PlayerCache.GetBySteamID(steamID)
	if not wrap then
		return false
	end
	local entity = wrap:GetRawEntity()
	if not entity then
		return false
	end
	local success = pcall(playerlist.SetPriority, entity, priority)
	if success then
		Logger.Info("Evidence", string.format("Set priority %d for %s", priority, wrap:GetName() or steamID))
		return true
	end
	return false
end

return Evidence
