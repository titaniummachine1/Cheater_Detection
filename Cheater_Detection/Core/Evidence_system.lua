--[[ Evidence System - Weight-based cheater detection with context-aware decay ]]
--
-- Categories:
--   Aim: Context-aware decay (looking at enemies, damage dealt, distance)
--   Exploit: Time-based decay (doubletap, recharge, fakelag, anti-aim)
--   Movement: Time-based decay (bhop, strafe, duck speed)

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")
local Database = require("Cheater_Detection.Database.Database")
local Logger = require("Cheater_Detection.Utils.Logger")

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
	MarkAsCheatThreshold = 100, -- Total weight to mark as cheater
	MinWeightFloor = 0, -- Cannot decay below this

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
			"Duck_Speed",
		},
	},
}

--[[ Private Variables ]]
local TICKS_PER_SECOND = 66 -- TF2 tickrate
local DECAY_BATCHES_PER_CYCLE = 6
local DECAY_INTERVAL_TICKS = math.max(1, math.floor(TICKS_PER_SECOND / DECAY_BATCHES_PER_CYCLE))
local DECAY_SECONDS_PER_BATCH = 1 / DECAY_BATCHES_PER_CYCLE
local lastDecayTick = 0 -- Simple tick-based rate limiting

local decayQueue = {}
local decayQueueIndex = {}
local decayCursor = 1
local decayQueueDirty = true

local DetectionToggles = {
	anti_aim = "AntyAim",
	bhop = "Bhop",
	fake_lag = "Choke", -- Choke = Fake Lag in config
	warp_dt = "Warp",
	Duck_Speed = "DuckSpeed",
	silent_aimbot = "SilentAimbot",
	manual_priority = "AutoFlagPriorityTen",
}

local function clearArray(tbl)
	for i = #tbl, 1, -1 do
		tbl[i] = nil
	end
end

local function clearMap(tbl)
	for key in pairs(tbl) do
		tbl[key] = nil
	end
end

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

local function refreshDecayQueue()
	clearArray(decayQueue)
	clearMap(decayQueueIndex)
	decayCursor = 1
	decayQueueDirty = false

	if not PlayerState or not PlayerState.GetTable then
		return
	end

	for steamID, state in pairs(PlayerState.GetTable()) do
		if state and state.Evidence and state.Evidence.Reasons and next(state.Evidence.Reasons) ~= nil then
			decayQueue[#decayQueue + 1] = steamID
			decayQueueIndex[steamID] = true
		end
	end
end

local function markDecayQueueDirty()
	decayQueueDirty = true
end

local function ensureDecayQueue()
	if decayQueueDirty then
		refreshDecayQueue()
	end
end

local function enqueueForDecay(steamID)
	if not steamID then
		return
	end

	steamID = tostring(steamID)
	if decayQueueIndex[steamID] then
		return
	end

	decayQueue[#decayQueue + 1] = steamID
	decayQueueIndex[steamID] = true
end

local function removeFromDecayQueue(steamID)
	if not steamID then
		return
	end
	steamID = tostring(steamID)
	if not decayQueueIndex[steamID] then
		return
	end
	decayQueueIndex[steamID] = nil
	markDecayQueueDirty()
end

--[[ Helper Functions ]]

-- Get category for a detection method
local function getCategory(detectionName)
	for category, methods in pairs(Evidence.Config.Categories) do
		for _, method in ipairs(methods) do
			if method == detectionName then
				return category
			end
		end
	end
	return "Movement" -- Default fallback
end

local function getOrCreateEvidence(steamID)
	if not PlayerState then
		return nil, nil
	end
	local state = PlayerState.GetOrCreate(steamID)
	if not state then
		return nil, nil
	end
	state.Evidence = state.Evidence
		or {
			TotalScore = 0,
			LastUpdateTick = globals.TickCount(),
			Reasons = {},
			MarkedAsCheater = false,
		}
	return state.Evidence, state
end

local function initPlayerEvidence(steamID)
	return getOrCreateEvidence(steamID)
end

local function recalcTotalScore(evidence)
	local total = 0
	for _, reason in pairs(evidence.Reasons) do
		total = total + reason.Weight
	end
	evidence.TotalScore = total
	evidence.LastUpdateTick = globals.TickCount()
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
---@return number Current threshold value
function Evidence.GetThreshold()
	return G.Menu.Advanced.Evicence_Tolerance or Evidence.Config.MarkAsCheatThreshold
end

--- Try to mark player as cheater if threshold is exceeded
---@param steamID string Player's SteamID64
---@param evidence table? Evidence data
---@param state table? Player state
local function tryMarkCheater(steamID, evidence, state)
	if not evidence or evidence.MarkedAsCheater then
		return
	end

	local threshold = Evidence.GetThreshold()

	if evidence.TotalScore < threshold then
		return
	end

	evidence.MarkedAsCheater = true
	state = state or select(2, getOrCreateEvidence(steamID)) or {}
	state.info = state.info or {}
	state.info.IsCheater = true

	-- Use name from state.info (already populated by PlayerState.AttachWrappedPlayer)
	local playerName = (state.info and state.info.Name) or "Unknown"

	-- Fallback: search FastPlayers if name not in state (don't exclude local player)
	if playerName == "Unknown" then
		local allPlayers = FastPlayers.GetAll(false)
		for _, player in ipairs(allPlayers) do
			if tostring(player:GetSteamID64()) == steamID then
				local name = player.GetName and player:GetName()
				if name and name ~= "" then
					playerName = name
					-- Update state for future use
					if state.info then
						state.info.Name = name
					end
				end
				break
			end
		end
	end

	local primaryReason = "Cheater"
	local maxWeight = 0
	for detectionName, reasonData in pairs(evidence.Reasons) do
		if reasonData.Weight > maxWeight then
			maxWeight = reasonData.Weight
			local reasonMap = {
				["anti_aim"] = "Anti-Aim",
				["bhop"] = "Bhop",
				["fake_lag"] = "Fake Lag",
				["warp_dt"] = "Warp/Doubletap",
				["Duck_Speed"] = "Duck Speed",
				["silent_aimbot"] = "Silent Aimbot",
				["manual_priority"] = "Manual Priority",
			}
			primaryReason = reasonMap[detectionName] or detectionName
		end
	end

	Database.UpsertCheater(steamID, {
		name = playerName,
		reason = primaryReason,
		proof = "Evidence System",
		evidenceScore = evidence.TotalScore,
		reasons = evidence.Reasons,
		firstSeen = os.time(),
		lastSeen = os.time(),
	})

	-- Immediate save after marking cheater (critical moment, prevents data loss)
	Database.SaveDatabase()

	-- Set priority 10 if AutoPriority enabled
	if G.Menu.Main and G.Menu.Main.AutoPriority then
		Evidence.SetPriorityForSteamID(steamID, 10)
	end

	if G.Menu.Advanced.debug then
		print(
			string.format(
				"[Evidence] MARKED %s as cheater (Score: %.1f >= %.1f) - Saved to database",
				playerName,
				evidence.TotalScore,
				threshold
			)
		)
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
		local localPlayer = entities.GetLocalPlayer()
		if localPlayer then
			local localSteamID = Common.GetSteamID64(localPlayer)
			if localSteamID and tostring(localSteamID) == steamID then
				return -- Skip local player
			end
		end
	end

	-- Debug: Log successful evidence add
	Logger.Debug("Evidence", string.format("Adding %.1f evidence for %s (method: %s)", weight, steamID, detectionName))

	local evidence, state = getOrCreateEvidence(steamID)
	if not evidence then
		return
	end

	-- Initialize detection stack if needed
	if not evidence.Reasons[detectionName] then
		evidence.Reasons[detectionName] = {
			Weight = 0,
			Category = getCategory(detectionName),
			LastAddedTick = globals.TickCount(),
		}
	end
	applyReasonOptions(evidence.Reasons[detectionName], opts)

	-- Add weight
	evidence.Reasons[detectionName].Weight = evidence.Reasons[detectionName].Weight + weight
	evidence.Reasons[detectionName].LastAddedTick = globals.TickCount()
	evidence.Dirty = true

	-- Recalculate total and check if player should be marked
	recalcTotalScore(evidence)

	tryMarkCheater(steamID, evidence, state)

	enqueueForDecay(steamID)
end

local function processEvidenceState(steamID, state, deltaTime)
	if not state or not state.Evidence then
		return false
	end
	local evidence = state.Evidence
	if not evidence.Reasons or next(evidence.Reasons) == nil then
		evidence.Dirty = false
		return false
	end

	local changed = false
	local minFloor = Evidence.Config.MinWeightFloor or 0
	local toRemove = {}
	local hasReasons = false

	if deltaTime > 0 then
		for detectionName, reason in pairs(evidence.Reasons) do
			local detectionEnabled = isDetectionEnabled(detectionName)
			if detectionEnabled and reason.ManualDecay ~= true and reason.Weight > minFloor then
				local rate = reason.DecayRate or getCategoryDecayRate(reason.Category)
				if rate > 0 then
					local newWeight = math.max(minFloor, reason.Weight - rate * deltaTime)
					if newWeight ~= reason.Weight then
						reason.Weight = newWeight
						changed = true
					end
				end
			end

			if reason.ManualDecay ~= true and reason.Weight <= minFloor then
				toRemove[#toRemove + 1] = detectionName
			else
				hasReasons = true
			end
		end
	else
		hasReasons = true
	end

	for _, detectionName in ipairs(toRemove) do
		evidence.Reasons[detectionName] = nil
		changed = true
	end

	if evidence.Dirty or changed then
		recalcTotalScore(evidence)
		evidence.Dirty = false
		tryMarkCheater(steamID, evidence, state)
	end

	return hasReasons and next(evidence.Reasons) ~= nil
end

local function processDecayBatch()
	ensureDecayQueue()
	local queueSize = #decayQueue
	if queueSize == 0 then
		return
	end

	local batchSize = math.max(1, math.ceil(queueSize / DECAY_BATCHES_PER_CYCLE))
	local processed = 0

	while processed < batchSize and queueSize > 0 do
		if decayCursor > queueSize then
			decayCursor = 1
			queueSize = #decayQueue
			if queueSize == 0 then
				break
			end
		end

		local steamID = decayQueue[decayCursor]
		decayCursor = decayCursor + 1
		if steamID then
			local state = PlayerState and PlayerState.Get and PlayerState.Get(steamID)
			if state and state.Evidence and state.Evidence.Reasons and next(state.Evidence.Reasons) ~= nil then
				local hasReasons = processEvidenceState(steamID, state, DECAY_SECONDS_PER_BATCH)
				if not hasReasons then
					removeFromDecayQueue(steamID)
				end
			else
				removeFromDecayQueue(steamID)
			end
		end
		processed = processed + 1
	end
end

--- Apply decay to all players (called per tick, internally rate-limited)
function Evidence.ApplyDecay()
	local currentTick = globals.TickCount()
	if currentTick - lastDecayTick >= DECAY_INTERVAL_TICKS then
		lastDecayTick = currentTick
		processDecayBatch()
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

	-- Check database first (known cheater lists)
	if G.DataBase[steamID] then
		return true
	end

	-- Check if marked by evidence system
	if G.PlayerData[steamID] and G.PlayerData[steamID].Evidence then
		return G.PlayerData[steamID].Evidence.MarkedAsCheater
	end

	-- Check playerlist priority
	local priority = playerlist.GetPriority(steamID)
	if priority == 10 then
		return true
	end

	if PlayerState then
		local state = PlayerState.Get(steamID)
		if state and state.Evidence then
			return state.Evidence.MarkedAsCheater == true
		end
	end

	return false
end

--- Apply decay to a specific detection method for a player
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

	initPlayerEvidence(steamID)

	local evidence, state = getOrCreateEvidence(steamID)
	if not evidence then
		return
	end

	-- Initialize detection stack if needed
	if not evidence.Reasons[detectionName] then
		evidence.Reasons[detectionName] = {
			Weight = 0,
			Category = getCategory(detectionName),
			LastAddedTick = globals.TickCount(),
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
		enqueueForDecay(steamID)
		tryMarkCheater(steamID, evidence, state)

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

	if not G.PlayerData[steamID] or not G.PlayerData[steamID].Evidence then
		return 0
	end

	return G.PlayerData[steamID].Evidence.TotalScore or 0
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

	if
		not G.PlayerData[steamID]
		or not G.PlayerData[steamID].Evidence
		or not G.PlayerData[steamID].Evidence.Reasons
	then
		return 0
	end

	local methodData = G.PlayerData[steamID].Evidence.Reasons[detectionName]
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

	if not G.PlayerData[steamID] or not G.PlayerData[steamID].Evidence then
		return nil
	end

	return G.PlayerData[steamID].Evidence
end

--- Clean up player data when they leave (centralized black box)
---@param steamID string Player's SteamID64
function Evidence.OnPlayerLeave(steamID)
	-- Clean up evidence data
	if G.PlayerData[steamID] then
		G.PlayerData[steamID] = nil
	end
	removeFromDecayQueue(steamID)

	-- Detection module data cleanup is handled by script unload
	-- Individual modules' local data structures are cleaned up automatically
end

--- Set playerlist priority for a player by SteamID
---@param steamID string Player's SteamID64
---@param priority number Priority level to set (10 = cheater)
function Evidence.SetPriorityForSteamID(steamID, priority)
	if not steamID then
		return false
	end
	steamID = tostring(steamID)

	local allPlayers = FastPlayers.GetAll(false)
	for _, player in ipairs(allPlayers) do
		if tostring(player:GetSteamID64()) == steamID then
			local entity = player:GetRawEntity()
			if entity then
				local success = pcall(playerlist.SetPriority, entity, priority)
				if success then
					Logger.Info(
						"Evidence",
						string.format("Set priority %d for %s", priority, player:GetName() or steamID)
					)
					return true
				end
			end
			break
		end
	end
	return false
end

return Evidence
