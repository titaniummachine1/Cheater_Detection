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

	-- Category mappings
	Categories = {
		-- Aim detection methods
		Aim = {
			"silent_aimbot",
			"plain_aimbot",
			"smooth_aimbot",
			"triggerbot",
		},
		-- Exploit detection methods
		Exploit = {
			"warp_dt",
			"warp_recharge",
			"fake_lag",
			"anti_aim",
		},
		-- Movement detection methods
		Movement = {
			"bhop",
			"strafe_bot",
			"Duck_Speed",
			"bot_walk",
		},
	},
}

--[[ Private Variables ]]
local lastDecayTick = 0
local TICKS_PER_SECOND = 66 -- TF2 tickrate

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

-- Initialize player evidence data if needed
local function initPlayerEvidence(steamID)
	if not G.PlayerData[steamID] then
		G.PlayerData[steamID] = {}
	end

	if not G.PlayerData[steamID].Evidence then
		G.PlayerData[steamID].Evidence = {
			TotalScore = 0,
			LastUpdateTick = globals.TickCount(),
			Reasons = {}, -- Per-detection weight stacks
			MarkedAsCheater = false,
		}
	end
end

--[[ Public Functions ]]

--- Add evidence weight for a specific detection
---@param steamID string Player's SteamID64
---@param detectionName string Detection method name
---@param weight number Weight to add
function Evidence.AddEvidence(steamID, detectionName, weight)
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

	-- Skip local player (prevent self-detection even if debug mode is on)
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer then
		local localSteamID = Common.GetSteamID64(localPlayer)
		if localSteamID and tostring(localSteamID) == steamID then
			return -- Skip local player
		end
	end

	-- Debug: Log successful evidence add
	Logger.Debug("Evidence", string.format("Adding %.1f evidence for %s (method: %s)", 
		weight, steamID, detectionName))

	initPlayerEvidence(steamID)

	local evidence = G.PlayerData[steamID].Evidence

	-- Initialize detection stack if needed
	if not evidence.Reasons[detectionName] then
		evidence.Reasons[detectionName] = {
			Weight = 0,
			Category = getCategory(detectionName),
			LastAddedTick = globals.TickCount(),
		}
	end

	-- Add weight
	evidence.Reasons[detectionName].Weight = evidence.Reasons[detectionName].Weight + weight
	evidence.Reasons[detectionName].LastAddedTick = globals.TickCount()

	-- Recalculate total
	local total = 0
	for _, reason in pairs(evidence.Reasons) do
		total = total + reason.Weight
	end
	evidence.TotalScore = total
	evidence.LastUpdateTick = globals.TickCount()

	-- Check if should mark as cheater (use menu threshold)
	local threshold = G.Menu.Advanced.Evicence_Tolerance or Evidence.Config.MarkAsCheatThreshold
	if evidence.TotalScore >= threshold and not evidence.MarkedAsCheater then
		evidence.MarkedAsCheater = true
		G.PlayerData[steamID].info = G.PlayerData[steamID].info or {}
		G.PlayerData[steamID].info.IsCheater = true

		-- Get player name for database entry
		local playerName = "Unknown"
		local allPlayers = FastPlayers.GetAll(true)
		for _, player in ipairs(allPlayers) do
			if tostring(player:GetSteamID64()) == steamID then
				playerName = player:GetName() or "Unknown"
				break
			end
		end

		-- Get primary detection reason (highest weight)
		local primaryReason = "Cheater"
		local maxWeight = 0
		for reasonName, reasonData in pairs(evidence.Reasons) do
			if reasonData.Weight > maxWeight then
				maxWeight = reasonData.Weight
				-- Convert detection name to readable format
				if reasonName == "anti_aim" then
					primaryReason = "Anti-Aim"
				elseif reasonName == "fake_lag" then
					primaryReason = "Fake Lag"
				elseif reasonName == "warp_dt" then
					primaryReason = "Warp/DT"
				elseif reasonName == "bhop" then
					primaryReason = "Bhop"
				elseif reasonName == "Duck_Speed" then
					primaryReason = "Duck Speed"
				else
					-- Generic conversion: "some_name" -> "Some Name"
					primaryReason = reasonName:gsub("_", " "):gsub("^%l", string.upper)
				end
			end
		end

		-- Write to database for persistence (minimal format)
		local dbSuccess = Database.UpsertCheater(steamID, {
			name = playerName,
			reason = primaryReason,
		})

		if G.Menu.Main.AutoMark then
			local success = pcall(playerlist.SetPriority, steamID, 10)
			
			if dbSuccess then
				Logger.Info("Detection", string.format("Marked %s as cheater (Reason: %s, Score: %.1f)", 
					playerName, primaryReason, evidence.TotalScore))
			else
				Logger.Error("Detection", string.format("Failed to save %s to database", playerName))
			end
		end
	end
end

--- Calculate aim decay multiplier based on player context
---@param player table WrappedPlayer instance
---@return number Decay multiplier
local function calculateAimDecay(player)
	if not player or not player:IsValid() then
		return Evidence.Config.DecayRates.Aim.default
	end

	local multiplier = Evidence.Config.DecayRates.Aim.default
	local eyePos = player:GetEyePos()
	local eyeAngles = player:GetEyeAngles()

	if not eyePos or not eyeAngles then
		return multiplier
	end

	local forward = eyeAngles:Forward()
	local enemies = FastPlayers.GetEnemies()

	local closestDist = math.huge
	local isLookingAtEnemy = false

	-- Check if looking at any enemy
	for _, enemy in ipairs(enemies) do
		if enemy:IsValid() and enemy:IsAlive() then
			local enemyPos = enemy:GetAbsOrigin()
			local toEnemy = enemyPos - eyePos
			local dist = toEnemy:Length()

			if dist < closestDist then
				closestDist = dist
			end

			-- Normalize toEnemy vector
			local len = toEnemy:Length()
			if len > 0 then
				toEnemy = toEnemy / len

				-- Calculate dot product (cos of angle)
				local dot = forward.x * toEnemy.x + forward.y * toEnemy.y + forward.z * toEnemy.z

				-- If aiming within ~30 degrees of enemy
				if dot > 0.86 then -- cos(30°) ≈ 0.86
					isLookingAtEnemy = true

					-- Closer aim = more decay
					if dot > 0.98 then -- cos(11°) ≈ 0.98 (very close aim)
						multiplier = multiplier + Evidence.Config.DecayRates.Aim.closeAim
					end
				end
			end
		end
	end

	if isLookingAtEnemy then
		multiplier = multiplier + Evidence.Config.DecayRates.Aim.lookingAtEnemy
	end

	-- TODO: Add extra decay when dealing damage (requires damage event tracking)
	-- This would be: multiplier = multiplier + Evidence.Config.DecayRates.Aim.hurtingEnemy

	return multiplier
end

--- Apply decay to a single player's evidence
---@param steamID string Player's SteamID64
---@param player table WrappedPlayer instance
---@param deltaTime number Time elapsed in seconds
local function decayPlayerEvidence(steamID, player, deltaTime)
	if not G.PlayerData[steamID] or not G.PlayerData[steamID].Evidence then
		return
	end

	local evidence = G.PlayerData[steamID].Evidence
	local changed = false

	-- Calculate context-specific decay for Aim category
	local aimDecayRate = calculateAimDecay(player)

	-- Apply decay to each detection reason
	for detectionName, reason in pairs(evidence.Reasons) do
		if reason.Weight > Evidence.Config.MinWeightFloor then
			local decayAmount = 0

			if reason.Category == "Aim" then
				decayAmount = aimDecayRate * deltaTime
			elseif reason.Category == "Exploit" then
				decayAmount = Evidence.Config.DecayRates.Exploit.default * deltaTime
			elseif reason.Category == "Movement" then
				decayAmount = Evidence.Config.DecayRates.Movement.default * deltaTime
			else
				decayAmount = 1.0 * deltaTime -- Fallback
			end

			reason.Weight = math.max(Evidence.Config.MinWeightFloor, reason.Weight - decayAmount)
			changed = true
		end
	end

	-- Recalculate total if changed
	if changed then
		local total = 0
		for _, reason in pairs(evidence.Reasons) do
			total = total + reason.Weight
		end
		evidence.TotalScore = total
		evidence.LastUpdateTick = globals.TickCount()
	end
end

--- Apply decay to all players (called per second)
function Evidence.ApplyDecay()
	local currentTick = globals.TickCount()

	-- Calculate time since last decay
	if lastDecayTick == 0 then
		lastDecayTick = currentTick
		return
	end

	local ticksDelta = currentTick - lastDecayTick

	-- Only decay once per second (66 ticks)
	if ticksDelta < TICKS_PER_SECOND then
		return
	end

	local deltaTime = ticksDelta / TICKS_PER_SECOND -- Convert to seconds
	lastDecayTick = currentTick

	-- Get all players and decay their evidence
	local allPlayers = FastPlayers.GetAll(true) -- Exclude local

	for _, player in ipairs(allPlayers) do
		local steamID = player:GetSteamID64()
		if steamID then
			-- Skip if already marked as cheater and in database (optimization)
			local skipDecay = G.DataBase[steamID] ~= nil

			if not skipDecay then
				decayPlayerEvidence(steamID, player, deltaTime)
			end
		end
	end
end

--- Check if player is marked as cheater (for detection skip optimization)
---@param steamID string Player's SteamID64
---@return boolean True if player is confirmed cheater
function Evidence.IsMarkedCheater(steamID)
	if not steamID then
		return false
	end

	-- Ensure steamID is a string
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

	local evidence = G.PlayerData[steamID].Evidence

	-- Initialize detection stack if needed
	if not evidence.Reasons[detectionName] then
		evidence.Reasons[detectionName] = {
			Weight = 0,
			Category = getCategory(detectionName),
			LastAddedTick = globals.TickCount(),
		}
	end

	-- Apply decay (minimum 0)
	local oldWeight = evidence.Reasons[detectionName].Weight
	evidence.Reasons[detectionName].Weight = math.max(Evidence.Config.MinWeightFloor, 
		evidence.Reasons[detectionName].Weight - decayAmount)

	-- Recalculate total if changed
	if oldWeight ~= evidence.Reasons[detectionName].Weight then
		local total = 0
		for _, reason in pairs(evidence.Reasons) do
			total = total + reason.Weight
		end
		evidence.TotalScore = total
		evidence.LastUpdateTick = globals.TickCount()

		-- Debug: Log decay
		Logger.Debug("Evidence", string.format("Decayed %.1f evidence for %s (method: %s, old: %.1f, new: %.1f)", 
			decayAmount, steamID, detectionName, oldWeight, evidence.Reasons[detectionName].Weight))
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
	
	if not G.PlayerData[steamID] or not G.PlayerData[steamID].Evidence or not G.PlayerData[steamID].Evidence.Reasons then
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
---@return table Evidence details
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

return Evidence
