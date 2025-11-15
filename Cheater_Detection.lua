local __bundle_require, __bundle_loaded, __bundle_register, __bundle_modules = (function(superRequire)
	local loadingPlaceholder = {[{}] = true}

	local register
	local modules = {}

	local require
	local loaded = {}

	register = function(name, body)
		if not modules[name] then
			modules[name] = body
		end
	end

	require = function(name)
		local loadedModule = loaded[name]

		if loadedModule then
			if loadedModule == loadingPlaceholder then
				return nil
			end
		else
			if not modules[name] then
				if not superRequire then
					local identifier = type(name) == 'string' and '\"' .. name .. '\"' or tostring(name)
					error('Tried to require ' .. identifier .. ', but no such module has been registered')
				else
					return superRequire(name)
				end
			end

			loaded[name] = loadingPlaceholder
			loadedModule = modules[name](require, loaded, register, modules)
			loaded[name] = loadedModule
		end

		return loadedModule
	end

	return require, loaded, register, modules
end)(require)
__bundle_register("__root", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Cheater Detection for Lmaobox Recode
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credits:
    LNX (github.com/lnx00) for base script
    Muqa for visuals and design assistance
    Alchemist for testing and party callout
]]

-- Check and disable anonymous mode if enabled (disrupts player detection)
if gui.GetValue("ANONYMOUSE MODE") == 1 then
	gui.SetValue("ANONYMOUSE MODE", 0)
	-- Send warning to local chat
	client.ChatPrintf(
		"\x04[CD]\x01 Anonymous mode disabled - it makes all players appear as bots and breaks detection!"
	)
end

--[[ Import core utilities ]]
local G = require("Cheater_Detection.Utils.Globals") --[[ Imported by: Main.lua ]]
local Common = require("Cheater_Detection.Utils.Common") --[[ Imported by: Main.lua ]]
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers") --[[ Imported by: Main.lua ]]

require("Cheater_Detection.Utils.Config") --[[ Imported by: Main.lua ]]
--[[ Import database system ]]
local Database = require("Cheater_Detection.Database.Database") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Database.Fetcher") --[[ Imported by: Main.lua ]]

--[[ Import evidence system ]]
local Evidence = require("Cheater_Detection.Core.Evidence_system") --[[ Imported by: Main.lua ]]

--[[ UI components ]]
require("Cheater_Detection.Misc.Visuals.Menu") --[[ Imported by: Main.lua ]]

--[[ Misc features ]]
require("Cheater_Detection.Misc.ChatPrefix") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Misc.JoinNotifications") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Utils.Commands") --[[ Imported by: Main.lua ]]
require("Cheater_Detection.Database.SteamHistory") --[[ Imported by: Main.lua ]]

--[[ Detection modules ]]
local AntiAim = require("Cheater_Detection.Detection Methods.anti_aim")
local Bhop = require("Cheater_Detection.Detection Methods.bhop")
local DuckSpeed = require("Cheater_Detection.Detection Methods.Duck_Speed")
local FakeLag = require("Cheater_Detection.Detection Methods.fake_lag")
local WarpDT = require("Cheater_Detection.Detection Methods.warp_dt")
local ManualPriority = require("Cheater_Detection.Detection Methods.manual_priority")

--[[ Variables ]]
local WPlayer, PR = Common.WPlayer, Common.PlayerResource

--[[ Update the player data every tick ]]
--
local function OnCreateMove(cmd)
	local DebugMode = G.Menu.Main.debug

	-- Use FastPlayers for optimized player fetching (required directly)
	local pLocal = FastPlayers.GetLocal() -- Get cached local player (still store in G for now)
	G.pLocal = pLocal -- Store for Evidence system to identify local player
	local allPlayers = FastPlayers.GetAll(not G.Menu.Advanced.debug) -- Exclude local unless debug mode

	if not pLocal then -- Need local player to proceed
		return
	end

	-- Check connection state and store in G
	local ConnectionState = Common.CheckConnectionState()

	--if not stable connection then dont do any checks
	if not ConnectionState.stable then
		return
	end

	-- Apply evidence decay (once per second)
	Evidence.ApplyDecay()

	-- Iterate over the cached list of players
	for _, Player in ipairs(allPlayers) do
		local steamID = Player:GetSteamID64()

		-- Skip if already confirmed cheater (optimization - database or marked)
		if Evidence.IsMarkedCheater(steamID) then
			goto continue
		end

		-- Push history for detection analysis
		Common.pushHistory(Player)

		-- Perform detection checks
		AntiAim.Check(Player)
		DuckSpeed.Check(Player)
		Bhop.Check(Player)
		FakeLag.Check(Player)
		WarpDT.Check(Player)
        ManualPriority.Check(Player)

		-- TODO: Implement remaining detection methods
		--warp_recharge_check(Player)
		--triggerbot_check(Player)
		--smooth_aimbot_check(Player)
		--plain_aimbot_check(Player)
		--strafe_bot_check(Player)
		--bot_walk_check(Player)

		::continue::
	end
end

--[[ Map Change Handler ]]
local function OnMapChange()
	-- Force save database on map change
	Database.ForceSave()

	-- Reload database on new map
	Database.LoadDatabase(false, true)

	if G.Menu.Advanced.debug then
		print("[CD] Map changed - Database saved and reloaded")
	end
end

--[[ Callbacks ]]
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)
callbacks.Register("FireGameEvent", "CD_MapChange", function(event)
	if
		event:GetName() == "game_newmap"
		or event:GetName() == "teamplay_round_start"
		or event:GetName() == "cs_round_start"
	then
		OnMapChange()
	end
end)

-- Clean up player data when they leave (centralized through evidence system)
callbacks.Register("FireGameEvent", "CD_PlayerDisconnect", function(event)
	if event:GetName() == "player_disconnect" then
		local steamID = tostring(event:GetInt("userid"))
		Evidence.OnPlayerLeave(steamID)
	end
end)

end)
__bundle_register("Cheater_Detection.Detection Methods.manual_priority", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Cheater Detection - Manual Priority Enforcement ]]
--
-- Awards evidence when a player is manually assigned priority 10 in Lmaobox.
-- Meant to integrate with the AutoFlagPriorityTen option to mark custom cheaters.

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local ManualPriority = {}

--[[ Configuration ]]
local DETECTION_NAME = "manual_priority"
local EVIDENCE_WEIGHT = 100 -- Immediate threshold push

-- Track last tick we awarded evidence per steamID to avoid double counting in same frame
local lastTriggerTick = {}

--[[ Helper Functions ]]
local function shouldRun()
	local advanced = G.Menu and G.Menu.Advanced
	return advanced and advanced.AutoFlagPriorityTen == true
end

local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

--[[ Public Functions ]]
function ManualPriority.Check(player)
	if not shouldRun() then
		return false
	end

	if not validatePlayer(player) then
		return false
	end

	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return false
	end
	steamID = tostring(steamID)

	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	local priority = playerlist.GetPriority(steamID)
	if priority ~= 10 then
		lastTriggerTick[steamID] = nil
		return false
	end

	local currentTick = globals.TickCount()
	if lastTriggerTick[steamID] == currentTick then
		return false
	end

	lastTriggerTick[steamID] = currentTick

	Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

	if G.Menu.Advanced.debug then
		print(string.format("[ManualPriority] %s flagged via priority 10", player:GetName() or steamID))
	end

	return true
end

return ManualPriority

end)
__bundle_register("Cheater_Detection.Core.Evidence_system", function(require, _LOADED, __bundle_register, __bundle_modules)
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
			"manual_priority",
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

--[[ Public Functions ]]

--- Get the current evidence threshold from menu
---@return number Current threshold value
function Evidence.GetThreshold()
	return G.Menu.Advanced.Evicence_Tolerance or Evidence.Config.MarkAsCheatThreshold
end

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

	-- Check if should mark as cheater (use global threshold function)
	local threshold = Evidence.GetThreshold()

	if G.Menu.Advanced.debug then
		print(
			string.format(
				"[Evidence] %s - Total: %.1f, Threshold: %.1f, Marked: %s",
				steamID,
				evidence.TotalScore,
				threshold,
				tostring(evidence.MarkedAsCheater)
			)
		)
	end

	if evidence.TotalScore >= threshold and not evidence.MarkedAsCheater then
		evidence.MarkedAsCheater = true
		state.info = state.info or {}
		state.info.IsCheater = true

		-- Get player name for database entry
		local playerName = (state.info and state.info.Name) or "Unknown"
		local allPlayers = FastPlayers.GetAll(true)
		for _, player in ipairs(allPlayers) do
			if tostring(player:GetSteamID64()) == steamID then
				local name = player.GetName and player:GetName()
				if name and name ~= "" then
					playerName = name
				end
				break
			end
		end

		-- Get primary detection reason (highest weight)
		local primaryReason = "Cheater" -- fallback
		local maxWeight = 0
		for detectionName, reasonData in pairs(evidence.Reasons) do
			if reasonData.Weight > maxWeight then
				maxWeight = reasonData.Weight
				-- Map detection names to user-friendly reasons
				local reasonMap = {
					["anti_aim"] = "Anti-Aim",
					["bhop"] = "Bhop",
					["fake_lag"] = "Fake Lag",
					["warp_dt"] = "Warp/Doubletap",
					["Duck_Speed"] = "Duck Speed",
					["strafe_bot"] = "Strafe Bot",
					["bot_walk"] = "Bot Walk",
					["silent_aimbot"] = "Silent Aimbot",
					["plain_aimbot"] = "Aimbot",
					["smooth_aimbot"] = "Smooth Aimbot",
					["triggerbot"] = "Triggerbot",
					["manual_priority"] = "Manual Priority",
				}
				primaryReason = reasonMap[detectionName] or detectionName
			end
		end

		-- Save to database
		local dbSuccess = Database.UpsertCheater(steamID, {
			name = playerName,
			reason = primaryReason, -- Use actual detection reason
			proof = "Evidence System",
			evidenceScore = evidence.TotalScore,
			reasons = evidence.Reasons,
			firstSeen = os.time(),
			lastSeen = os.time(),
		})

		-- Auto mark in lmaobox if enabled
		if G.Menu.Advanced.AutoMark then
			for _, player in ipairs(allPlayers) do
				if tostring(player:GetSteamID64()) == steamID then
					local localPlayer = FastPlayers.GetLocal()
					if not G.Menu.Advanced.debug and localPlayer and player == localPlayer then
						break
					end
					player.SetPriority = player.SetPriority
						or function(_, level)
							pcall(playerlist.SetPriority, player:GetRawEntity(), level)
						end
					player:SetPriority(10)
					if G.Menu.Advanced.debug then
						local pname = player.GetName and player:GetName() or "Unknown"
						print(string.format("[Evidence] Set priority 10 for %s", pname))
					end
					break
				end
			end
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
		if enemy:IsAlive() and not enemy:IsDormant() then
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
	local evidence = getOrCreateEvidence(steamID)
	if not evidence then
		return
	end
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
	local allPlayers = FastPlayers.GetAll(true) -- Include dormant players for decay

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
	evidence.Reasons[detectionName].Weight = math.max(0, evidence.Reasons[detectionName].Weight - decayAmount)

	-- Recalculate total if changed
	if oldWeight ~= evidence.Reasons[detectionName].Weight then
		local total = 0
		for _, reason in pairs(evidence.Reasons) do
			total = total + reason.Weight
		end
		evidence.TotalScore = total
		evidence.LastUpdateTick = globals.TickCount()

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

--- Clean up player data when they leave (centralized black box)
---@param steamID string Player's SteamID64
function Evidence.OnPlayerLeave(steamID)
	-- Clean up evidence data
	if G.PlayerData[steamID] then
		G.PlayerData[steamID] = nil
	end

	-- Detection module data cleanup is handled by script unload
	-- Individual modules' local data structures are cleaned up automatically
end

return Evidence

end)
__bundle_register("Cheater_Detection.Utils.Logger", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Cheater Detection - Logger System ]]

local G = require("Cheater_Detection.Utils.Globals")

local Logger = {}

-- Log levels
Logger.Levels = {
	DEBUG = 1,   -- Detailed debug info (off by default)
	INFO = 2,    -- General info (detections, database saves)
	WARNING = 3, -- Warnings
	ERROR = 4,   -- Errors
}

-- Color codes (RGBA)
local Colors = {
	DEBUG = {170, 170, 170, 255},   -- Gray
	INFO = {153, 204, 255, 255},    -- Light blue
	WARNING = {255, 170, 0, 255},   -- Orange
	ERROR = {255, 68, 68, 255},     -- Red
}

--- Check if log level is enabled
---@param level number Log level to check
---@return boolean
local function isLevelEnabled(level)
	if not G.Menu or not G.Menu.Advanced or not G.Menu.Advanced.LogLevel then
		return level >= Logger.Levels.INFO -- Default: INFO and above
	end
	
	-- Convert boolean table to level number: [Debug, Info, Warning, Error]
	local logLevelTable = G.Menu.Advanced.LogLevel
	local enabledLevel = Logger.Levels.INFO -- Default
	
	if type(logLevelTable) == "table" then
		for i = 1, 4 do
			if logLevelTable[i] then
				enabledLevel = i
				break
			end
		end
	elseif type(logLevelTable) == "number" then
		enabledLevel = logLevelTable
	end
	
	return level >= enabledLevel
end

--- Log a message with specified level
---@param level number Log level (Logger.Levels.X)
---@param category string Category/module name
---@param message string Message to log
function Logger.Log(level, category, message)
	if not isLevelEnabled(level) then
		return
	end
	
	local levelName = ""
	local color = nil
	
	if level == Logger.Levels.DEBUG then
		levelName = "DEBUG"
		color = Colors.DEBUG
	elseif level == Logger.Levels.INFO then
		levelName = "INFO"
		color = Colors.INFO
	elseif level == Logger.Levels.WARNING then
		levelName = "WARN"
		color = Colors.WARNING
	elseif level == Logger.Levels.ERROR then
		levelName = "ERROR"
		color = Colors.ERROR
	end
	
	if color then
		printc(color[1], color[2], color[3], color[4], string.format("[%s] [%s] %s", levelName, category, message))
	else
		print(string.format("[%s] [%s] %s", levelName, category, message))
	end
end

--- Convenience functions
function Logger.Debug(category, message)
	Logger.Log(Logger.Levels.DEBUG, category, message)
end

function Logger.Info(category, message)
	Logger.Log(Logger.Levels.INFO, category, message)
end

function Logger.Warning(category, message)
	Logger.Log(Logger.Levels.WARNING, category, message)
end

function Logger.Error(category, message)
	Logger.Log(Logger.Levels.ERROR, category, message)
end

return Logger

end)
__bundle_register("Cheater_Detection.Utils.Globals", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports first --]]
local G = {}
G.Menu = require("Cheater_Detection.Utils.DefaultConfig")

G.AutoVote = {
	Options = { "Yes", "No" },
	VoteCommand = "vote",
	VoteIdx = nil,
	VoteValue = nil, -- Set this to 1 for yes, 2 for no, or nil for off
}

--[[Shared Variables]]

G.PlayerData = {}

return G

end)
__bundle_register("Cheater_Detection.Utils.DefaultConfig", function(require, _LOADED, __bundle_register, __bundle_modules)
local Default_Config = {
	currentTab = "Main",

	Main = {
		Fetch_Database = true,
		AutoMark = true,
		AutoFetch = true, -- Automatically fetch database on startup
		partyCallaut = true,
		Chat_Prefix = true,
		Cheater_Tags = true,
	},

	Advanced = {
		Evicence_Tolerance = 100, -- Evidence score threshold to mark as cheater
		LogLevel = { false, true, false, false }, -- [Debug, Info, Warning, Error] (default: Info)
		debug = false, -- Debug mode (removes self from database, enables verbose logging)
		AutoFlagPriorityTen = false,
		Choke = true, --fakelag
		Warp = true,
		Bhop = true,
		Aimbot = {
			enable = true,
			silent = true,
			plain = true,
			smooth = true,
		},
		triggerbot = true,
		AntyAim = true,
		DuckSpeed = true,
		Strafe_bot = true,
	},

	Misc = {
		Autovote = true,
		AutovoteAutoCast = true,
		intent = {
			legit = true,
			cheater = true,
			bot = true,
			valve = true,
			friend = false,
		},
		Vote_Reveal = {
			Enable = true,
			TargetTeam = {
				MyTeam = true,
				enemyTeam = true,
			},
			Output = {
				PublicChat = false,
				PartyChat = true,
				ClientChat = true,
				Console = true,
			},
		},
		Class_Change_Reveal = {
			Enable = false,
			EnemyOnly = true,
			Output = {
				PublicChat = false,
				PartyChat = true,
				ClientChat = true,
				Console = true,
			},
		},
		Chat_notify = true,
		JoinNotifications = {
			Enable = true,
			CheckCheater = true,
			CheckValve = true,
			ValveAutoDisconnect = false,
			-- Default output channels (used if no override)
			DefaultOutput = {
				PublicChat = false,
				PartyChat = false,
				ClientChat = true,
				Console = true,
			},
			-- Cheater-specific overrides
			UseCheaterOverride = false,
			CheaterOverride = {
				PublicChat = false,
				PartyChat = false,
				ClientChat = true,
				Console = true,
			},
			-- Valve employee-specific overrides
			UseValveOverride = false,
			ValveOverride = {
				PublicChat = false,
				PartyChat = true,
				ClientChat = true,
				Console = true,
			},
		},
		SteamHistory = {
			Enable = false,
			ApiKey = "",
		},
	},
}

return Default_Config

end)
__bundle_register("Cheater_Detection.Database.Database", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Simplified Database.lua
    Direct implementation of database functionality using native Lua tables
    Stores only essential data: name and proof for each SteamID64
]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
-- [[ Imported by: Fetcher.lua (indirectly) ]]
local G = require("Cheater_Detection.Utils.Globals")
-- [[ Imported by: Fetcher.lua, Database.lua ]]
local Json = Common.Json
-- [[ Imported by: Database.lua ]]

--[[ Module Declaration ]]
local Database = {
	-- Configuration (Simplified)
	Config = {
		SaveOnExit = true,
		DebugMode = false,
		-- MaxEntries = 15000, -- Cleanup logic removed
	},

	-- State tracking (Simplified)
	State = {
		isDirty = false, -- Still potentially useful for SaveOnExit
		lastSave = 0,
		lastLoaded = 0,
		isInitialized = false,
	},
	-- Removed saveCount
}

--[[ Local Variables/Utilities ]]
local LogLevel = {
	ERROR = 1,
	WARNING = 2,
	SUCCESS = 3, -- Added Success level
	INFO = 4, -- Shifted Info down
	DEBUG = 5, -- Shifted Debug down
}

local currentLogLevel = LogLevel.INFO -- Default log level still includes SUCCESS
local showDebug = false -- Set to true to see all debug messages

--[[ Helper/Private Functions ]]
-- Log function with severity level and colors (Refactored to use Database's Log)
local function Log(level, message, color)
	-- Ensure Database and its Log function are available
	if Database and Database.Log then
		Database.Log(level, message, color)
	elseif G.Menu.Advanced.debug then
		-- Fallback to plain print if Database.Log is unavailable
		local prefixMap =
			{ [1] = "[ERROR] ", [2] = "[WARNING] ", [3] = "[SUCCESS] ", [4] = "[INFO] ", [5] = "[DEBUG] " }
		print((prefixMap[level] or "") .. message)
	end
end

-- Save database automatically when the script unloads (if dirty)
local function DatabaseAutoSaveOnUnload()
	Log(LogLevel.DEBUG, "[DB] Unloading database, saving data...")

	-- Always save on unload to prevent data loss
	if Database.Config.SaveOnExit then
		-- If not dirty, mark as dirty temporarily to force save
		local wasDirty = Database.State.isDirty
		Database.State.isDirty = true

		Log(LogLevel.INFO, "[DB] Saving database on exit")
		Database.SaveDatabase()

		-- Restore original dirty state if it wasn't modified
		if not wasDirty then
			Database.State.isDirty = false
		end
	else
		Log(LogLevel.WARNING, "[DB] SaveOnExit disabled, skipping final save")
	end
end

--[[ Public Module Functions ]]
-- Robust SetPriority with multiple fallback methods
-- Tries: entity -> index -> SteamID64 -> SteamID3
-- For database entries (not in-game), tries: SteamID64 -> SteamID3
function Database.SetPriority(target, priority, isInGame)
	if not target then
		Log(LogLevel.ERROR, "[DB] SetPriority: target is nil")
		return false
	end

	local success = false
	local lastError = nil

	-- Method 1: Try entity (only if in-game)
	if isInGame ~= false and type(target) == "userdata" then
		success, lastError = pcall(playerlist.SetPriority, target, priority)
		if success then
			Log(LogLevel.DEBUG, string.format("[DB] SetPriority via entity: priority=%d", priority))
			return true
		end
	end

	-- Method 2: Try index (only if in-game)
	if isInGame ~= false and type(target) == "number" and target < 101 then
		success, lastError = pcall(playerlist.SetPriority, target, priority)
		if success then
			Log(LogLevel.DEBUG, string.format("[DB] SetPriority via index %d: priority=%d", target, priority))
			return true
		end
	end

	-- Method 3: Try SteamID64
	local steamID64 = nil
	if type(target) == "string" and #target == 17 then
		steamID64 = target
	elseif type(target) == "userdata" then
		-- Try to get SteamID64 from entity
		steamID64 = Common.GetSteamID64(target)
	end

	if steamID64 then
		success, lastError = pcall(playerlist.SetPriority, steamID64, priority)
		if success then
			Log(LogLevel.DEBUG, string.format("[DB] SetPriority via SteamID64 %s: priority=%d", steamID64, priority))
			if priority == 10 then
				local menuAdvanced = G.Menu and G.Menu.Advanced
				local autoFlagEnabled = menuAdvanced and menuAdvanced.AutoFlagPriorityTen == true
				if autoFlagEnabled then
					local existing = Database.GetCheater(steamID64)
					if not existing then
						local name = "Manual Flag"
						local info = nil
						if type(target) == "userdata" then
							info = client.GetPlayerInfo and client.GetPlayerInfo(target:GetIndex())
						elseif type(target) == "number" and target < 101 then
							info = client.GetPlayerInfo and client.GetPlayerInfo(target)
						end
						if info and info.Name and info.Name ~= "" then
							name = info.Name
						end
						Database.UpsertCheater(steamID64, {
							name = name,
							reason = "Manual Priority 10",
						})
					end
				end
			end
			return true
		end
	end

	-- Method 4: Try SteamID3 conversion
	if steamID64 then
		-- Convert SteamID64 to SteamID3 format [U:1:XXXXXXXX]
		local accountID = tonumber(steamID64) - 76561197960265728
		if accountID and accountID > 0 then
			local steamID3 = string.format("[U:1:%d]", accountID)
			success, lastError = pcall(playerlist.SetPriority, steamID3, priority)
			if success then
				Log(LogLevel.DEBUG, string.format("[DB] SetPriority via SteamID3 %s: priority=%d", steamID3, priority))
				return true
			end
		end
	end

	-- All methods failed
	Log(
		LogLevel.ERROR,
		string.format(
			"[DB] SetPriority FAILED for target (type=%s): %s",
			type(target),
			tostring(lastError or "all methods failed")
		)
	)
	return false
end

-- Find best path for database storage (saves as JSON now)
function Database.GetFilePath()
	-- Ensure base directory exists
	pcall(filesystem.CreateDirectory, "Lua Cheater_Detection")
	return "Lua Cheater_Detection/database.json" -- Hardcoded path for simplicity
end

-- Save the G.DataBase table to the JSON file
function Database.SaveDatabase()
	Log(LogLevel.DEBUG, "[DB] Starting database save operation")

	if not Database.State.isDirty then
		Log(LogLevel.DEBUG, "[DB] Database not dirty, skipping save")
		return
	end

	if type(G.DataBase) ~= "table" then
		Log(LogLevel.ERROR, "[DB] Cannot save: G.DataBase is not a table")
		return
	end

	local encodedData
	if Json and Json.encode then -- Add nil check for Json.encode
		encodedData = Json.encode(G.DataBase)
	else
		Log(LogLevel.ERROR, "[DB] Json.encode function is not available!")
		return -- Cannot proceed without encoder
	end

	if not encodedData then
		Log(LogLevel.ERROR, "[DB] Failed to encode database to JSON")
		return
	end

	local filepath = Database.GetFilePath()
	Log(LogLevel.DEBUG, "[DB] Writing to file: " .. filepath)

	local file = io.open(filepath, "w")
	if not file then
		Log(LogLevel.ERROR, "[DB] Failed to open file for writing: " .. filepath)
		return
	end

	file:write(encodedData)
	file:close()

	--@diagnostic disable-next-line: cast-local-type -- Disable incorrect linter warning
	encodedData = nil -- Clear reference for GC

	Database.State.isDirty = false
	Database.State.lastSave = os.time()

	---@diagnostic disable-next-line: param-type-mismatch -- Disable incorrect linter warning
	Log(LogLevel.SUCCESS, "[DB] Database saved successfully")
end

-- Load the database from the JSON file
function Database.LoadDatabase(silent, force)
	-- Skip loading if recently loaded (within 10 seconds) unless forced
	local currentTime = os.time()
	if Database.State.isInitialized and not force and (currentTime - Database.State.lastLoaded < 10) then
		Log(LogLevel.DEBUG, "[DB] Skipping reload, database already loaded recently")
		return
	end

	Log(LogLevel.DEBUG, "[DB] Starting database load operation") -- Keep DEBUG
	local filePath = Database.GetFilePath()

	local file = io.open(filePath, "r")
	if not file then
		-- Always log warning if file missing, as it prevents loading
		Log(LogLevel.WARNING, "[DB] Database file not found, initializing empty database")
		G.DataBase = {}
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return
	end

	local content = file:read("*a")
	file:close()

	if not content or #content == 0 then
		-- Always log warning if file empty, as it means no data
		Log(LogLevel.WARNING, "[DB] Database file is empty, initializing empty database")
		G.DataBase = {}
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return
	end

	Log(LogLevel.DEBUG, "[DB] Decoding JSON content") -- Keep DEBUG
	local decodedData
	if Json and Json.decode then -- Add nil check for Json.decode
		decodedData = Json.decode(content)
	else
		-- Always log critical error
		Log(LogLevel.ERROR, "[DB] Json.decode function is not available!")
		G.DataBase = {} -- Fallback to empty DB
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return -- Cannot proceed without decoder
	end
	content = nil -- Clear content reference

	if type(decodedData) ~= "table" then
		-- Always log critical error
		Log(LogLevel.ERROR, "[DB] JSON decode failed or result is not a table")
		G.DataBase = {}
		Database.State.isDirty = true
		Database.State.lastLoaded = os.time()
		return
	end

	Log(LogLevel.DEBUG, "[DB] Starting database validation") -- Keep DEBUG
	local initialCount = 0
	for _ in pairs(decodedData) do
		initialCount = initialCount + 1
	end
	G.DataBase = decodedData -- Assign after counting

	local changesMade = false
	local entriesToRemove = {}
	local totalEntries = 0
	local passedCount = 0
	local failedCount = 0

	for steamID, value in pairs(G.DataBase) do
		totalEntries = totalEntries + 1
		if
			type(value) ~= "table"
			or type(steamID) ~= "string"
			or not steamID:match("^7656119%d+$")
			or #steamID ~= 17
		then
			failedCount = failedCount + 1
			table.insert(entriesToRemove, steamID)
		else
			passedCount = passedCount + 1
		end
		-- Removed periodic validation progress log
	end

	-- Always Log validation summary, color based on failures
	if failedCount > 0 then
		Log(
			LogLevel.WARNING, -- Yellow if failures
			string.format(
				"[DB] Validation finished: %d total, %d passed, %d FAILED",
				totalEntries,
				passedCount,
				failedCount
			)
		)
	elseif not silent then -- Only log non-failure summary if not silent
		Log(
			LogLevel.INFO, -- Cyan if no failures and not silent
			string.format(
				"[DB] Validation finished: %d total, %d passed, %d failed",
				totalEntries,
				passedCount,
				failedCount
			)
		)
	end

	-- Always log if removing entries (Warning)
	if #entriesToRemove > 0 then
		Log(LogLevel.WARNING, string.format("[DB] Removing %d invalid entries", #entriesToRemove))
		for _, key in ipairs(entriesToRemove) do
			G.DataBase[key] = nil
		end
		changesMade = true
	end

	Database.State.isDirty = changesMade
	Database.State.lastLoaded = os.time()
	Database.State.isInitialized = true

	-- Only log final success count if not silent
	if not silent then
		local finalCount = 0
		for _ in pairs(G.DataBase) do
			finalCount = finalCount + 1
		end
		-- Always print the final count summary using printc in green, regardless of debug mode
		Log(Database.LogLevel.SUCCESS, string.format("[DB] Database loaded with %d valid entries", finalCount))
	end
end

-- Simplified Initialize function that serves both internal and external needs
function Database.Initialize(silent)
	-- Skip if already initialized and not forcing
	if Database.State.isInitialized then
		Log(LogLevel.DEBUG, "[DB] Database already initialized, skipping")
		return
	end

	Log(LogLevel.DEBUG, "[DB] Initializing Database module...") -- Keep DEBUG

	-- Ensure G.DataBase exists as a table before loading
	if type(G.DataBase) ~= "table" then
		Log(LogLevel.DEBUG, "[DB] G.DataBase not found, initializing empty")
		G.DataBase = {}
	end

	-- Load the database (uses the updated LoadDatabase logging)
	Database.LoadDatabase(silent, false)

	-- Verify G.DataBase is initialized (LoadDatabase should ensure this)
	if not G.DataBase then
		-- Always log critical error
		Log(LogLevel.ERROR, "[DB] CRITICAL: G.DataBase is nil after LoadDatabase!")
		G.DataBase = {} -- Critical fallback
		Database.State.isDirty = true
	else
		Log(LogLevel.DEBUG, "[DB] G.DataBase initialized, type:" .. type(G.DataBase)) -- Keep DEBUG
	end

	-- Removed redundant final count log here, handled in LoadDatabase

	-- Always set local player priority to 0 and clear from database
	-- Debug mode is only a floodgate for detection, not for cleanup
	local localPlayer = entities.GetLocalPlayer()
	if localPlayer then
		-- Get SteamID64 for all operations
		local mySteamID = Common.GetSteamID64(localPlayer)
		if mySteamID then
			-- Always set priority to 0 using robust method
			local prioritySet = Database.SetPriority(localPlayer, 0, true)
			if prioritySet then
				Log(LogLevel.INFO, string.format("[DB] Set local player priority to 0 (SteamID64: %s)", mySteamID))
			else
				Log(
					LogLevel.WARNING,
					string.format("[DB] Failed to set local player priority (SteamID64: %s)", mySteamID)
				)
			end

			-- Always remove from database (debug mode controls detection, not cleanup)
			if G.DataBase[mySteamID] then
				G.DataBase[mySteamID] = nil
				Database.State.isDirty = true
				Log(
					LogLevel.SUCCESS,
					string.format("[DB] Removed local player from database (SteamID64: %s)", mySteamID)
				)
				-- Immediately save to persist cleanup
				Database.SaveDatabase()
				Log(LogLevel.INFO, "[DB] Database saved after local player cleanup")
			else
				Log(LogLevel.DEBUG, "[DB] Local player not in database")
			end
		else
			Log(LogLevel.WARNING, "[DB] Failed to get local player SteamID64")
		end
	else
		Log(LogLevel.WARNING, "[DB] Failed to get local player entity")
	end

	Log(LogLevel.DEBUG, "[DB] Database initialization complete.") -- Keep DEBUG
	Database.State.isInitialized = true
end

--[[ Self-Initialization ]]
-- Initial load and setup (silent=true to avoid verbose messages at load time)
Database.Initialize(true)

--- Upsert a cheater entry into the database (minimal format like fetched data)
---@param steamID string Player's SteamID64
---@param data table Cheater data (name, reason)
function Database.UpsertCheater(steamID, data)
	if not steamID or type(steamID) ~= "string" then
		Log(LogLevel.ERROR, "[DB] UpsertCheater: Invalid steamID")
		return false
	end

	if not steamID:match("^7656119%d+$") or #steamID ~= 17 then
		Log(LogLevel.ERROR, "[DB] UpsertCheater: Invalid steamID format: " .. steamID)
		return false
	end

	-- Ensure G.DataBase exists
	if type(G.DataBase) ~= "table" then
		G.DataBase = {}
	end

	-- Minimal format like fetched databases: just Name and Reason
	G.DataBase[steamID] = {
		Name = data.name or "Unknown",
		Reason = data.reason or "Cheater", -- Use provided reason, fallback to "Cheater" for imported data
	}

	-- Mark as dirty for save
	Database.State.isDirty = true

	-- Save immediately to prevent data loss on crashes
	Database.SaveDatabase()

	Log(
		LogLevel.INFO,
		string.format(
			"[DB] Added cheater: %s (%s) - Reason: %s",
			data.name or "Unknown",
			steamID,
			data.reason or "Cheater"
		)
	)

	return true
end

--- Get a cheater entry from the database
---@param steamID string Player's SteamID64
---@return table|nil Cheater data or nil if not found
function Database.GetCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then
		return nil
	end

	return G.DataBase[steamID]
end

--- Remove a cheater entry from the database
---@param steamID string Player's SteamID64
---@return boolean Success
function Database.RemoveCheater(steamID)
	if not steamID or type(G.DataBase) ~= "table" then
		return false
	end

	if G.DataBase[steamID] then
		G.DataBase[steamID] = nil
		Database.State.isDirty = true
		-- Save immediately to maintain database consistency
		Database.SaveDatabase()
		Log(LogLevel.INFO, "[DB] Removed cheater: " .. steamID)
		return true
	end

	return false
end

--- Force save the database (ignores dirty flag)
---@return boolean Success
function Database.ForceSave()
	local wasDirty = Database.State.isDirty
	Database.State.isDirty = true
	Database.SaveDatabase()
	if not wasDirty then
		Database.State.isDirty = false
	end
	return true
end

--[[ Callback Registration ]]
callbacks.Register("Unload", "DatabaseAutoSaveOnUnload", DatabaseAutoSaveOnUnload)

return Database

end)
__bundle_register("Cheater_Detection.Utils.Common", function(require, _LOADED, __bundle_register, __bundle_modules)
---@diagnostic disable: duplicate-set-field, undefined-field

--[[ Imports ]]
--
local Common = {
	Lib = nil,
	Json = nil,
	Log = nil,
	Notify = nil,
	TF2 = nil,
	Math = nil,
	Conversion = nil,
	WPlayer = nil,
	PR = nil,
	Helpers = nil,
}

-- Move requires here
Common.Json = require("Cheater_Detection.Libs.Json")
local G = require("Cheater_Detection.Utils.Globals")

if UnloadLib ~= nil then
	UnloadLib()
end

--------------------------------------------------------------------------------------
--Library loading--
--------------------------------------------------------------------------------------

--Function to download content from a URL
local function downloadFile(url)
	local success, body = pcall(http.Get, url)
	if not success or not body or body == "" then
		error("Failed to download file from " .. url .. ": " .. tostring(body))
	end
	return body
end

-- Load and validate library
local function loadlib(libName, libURL)
	local lnxLib = nil
	if libName == "lnxLib" then
		-- First try to load local LNXlib if it exists
		local success, localLib = pcall(require, "lnxLib")

		if success and localLib then
			-- Local version exists and loaded successfully
			lnxLib = localLib
			print("Loaded local lnxLib")
		else
			-- Local version doesn't exist, download from GitHub
			print("Local lnxLib not found, downloading from GitHub...")
			local libContent

			-- Try to download with error handling
			local downloadSuccess, errorMsg = pcall(function()
				libContent = downloadFile(libURL)
				return true
			end)

			if not downloadSuccess or not libContent then
				error("Failed to download lnxLib: " .. tostring(errorMsg))
			end

			-- Execute downloaded code with error handling
			local executeSuccess, result = pcall(load, libContent)
			if not executeSuccess or not result then
				error("Failed to load lnxLib content: " .. tostring(result))
			end

			-- Execute the loaded code
			local runSuccess, lib = pcall(result)
			if not runSuccess or not lib then
				error("Failed to execute lnxLib: " .. tostring(lib))
			end

			-- Assign globally
			lnxLib = lib
			print("Downloaded and loaded lnxLib from GitHub")
		end

		return lnxLib
	else
		error("Unsupported library: " .. libName)
	end
end

--why is this not working? added dpots tp prevent strign from makign this library link isntead of module in git comands so it doesnt break everything for git pull and stuff
local latestLNXlib = "https://" .. "github.com/lnx00/Lmaobox-Library/releases/latest/download/lnxLib.lua"
local lnxLib = loadlib("lnxLib", latestLNXlib)

if not lnxLib then
	error("Failed to load lnxLib")
end

Common.Lib = lnxLib

-- Now initialize remaining Common fields using the loaded libraries
Common.Log = Common.Lib.Utils.Logger.new("Cheater Detection")
Common.Notify = Common.Lib.UI.Notify
Common.TF2 = Common.Lib.TF2
Common.Math = Common.Lib.Utils.Math
Common.Conversion = Common.Lib.Utils.Conversion
Common.WPlayer = Common.TF2.WPlayer
Common.PR = Common.Lib.TF2.PlayerResource
Common.Helpers = Common.Lib.TF2.Helpers

-- Now using WrappedPlayer module instead of monkey patching

local cachedSteamIDs = {}
local lastTick = -1

function Common.IsFriend(entity)
	return (not G.Menu.Main.debug and Common.TF2.IsFriend(entity:GetIndex(), true)) -- Entity is a freind and party member
end

function Common.GetSteamID64(Player)
	assert(Player, "Player is nil")

	local currentTick = globals.TickCount()
	local playerIndex = Player:GetIndex()

	-- Branchless cache reset
	cachedSteamIDs, lastTick = (lastTick ~= currentTick and {} or cachedSteamIDs), currentTick

	-- Retrieve cached result or calculate it
	local result = cachedSteamIDs[playerIndex]
		or (function()
			local playerInfo = assert(client.GetPlayerInfo(playerIndex), "Failed to get player info")
			local steamID = assert(playerInfo.SteamID, "Failed to get SteamID")
			return (playerInfo.IsBot or playerInfo.IsHLTV or steamID == "[U:1:0]") and playerInfo.UserID
				or assert(steam.ToSteamID64(steamID), "Failed to convert SteamID to SteamID64")
		end)()

	cachedSteamIDs[playerIndex] = result
	return result
end

function Common.IsCheater(playerInfo)
	local steamId = nil

	if type(playerInfo) == "number" and playerInfo < 101 then
		-- Assuming playerInfo is the index
		local targetIndex = playerInfo
		local targetPlayer = nil

		-- Find the player with the same index
		for _, player in ipairs(G.players) do
			if player:GetIndex() == targetIndex then
				targetPlayer = player
				break
			end
		end

		-- Check if the target player was found
		if targetPlayer then
			steamId = assert(Common.GetSteamID64(targetPlayer), "Failed to get SteamID64 for player")
		else
			return false
		end
	elseif type(playerInfo) == "number" then
		-- If playerInfo is a number, convert it to a string and check its length
		local steamIdStr = tostring(playerInfo)
		if #steamIdStr == 17 then
			steamId = playerInfo
		else
			return false
		end
	elseif playerInfo.GetIndex then
		-- If playerInfo is a player entity, get its SteamID64
		steamId = assert(Common.GetSteamID64(playerInfo), "Failed to get SteamID64 for player entity")
	else
		-- If playerInfo is neither a valid index, a valid SteamID64, nor a player entity, return false
		return false
	end

	if not steamId then
		return false
	end

	-- Check if the player is marked as a cheater based on various criteria
	local strikes = G.PlayerData[steamId] and G.PlayerData[steamId].info.Strikes or 0
	local isMarkedCheater = G.PlayerData[steamId] and G.PlayerData[steamId].info.isCheater
	local inDatabase = G.DataBase[steamId] ~= nil
	local priorityCheater = playerlist.GetPriority(steamId) == 10

	return isMarkedCheater or inDatabase or priorityCheater
end

---@param entity Entity
---@param checkFriend boolean?
---@param checkDormant boolean?
---@param skipEntity Entity? Optional entity to skip (e.g., the local player)
function Common.IsValidPlayer(entity, checkFriend, checkDormant, skipEntity)
	-- Check if the entity is a valid player
	if
		not entity
		or not entity:IsValid()
		or not entity:IsAlive()
		or (checkDormant == true and entity:IsDormant() or checkDormant == nil and entity:IsDormant())
		or entity:GetTeamNumber() == TEAM_SPECTATOR
		or entity:GetTeamNumber() == TEAM_UNASSIGNED --can be simplified to entity:GetTeamNumber() > 1
		or (skipEntity and entity == skipEntity)
	then
		return false -- Entity is not a valid player
	end

	-- Skip friends unless debug mode is enabled
	if not G.Menu.Advanced.debug then
		if checkFriend == true and Common.IsFriend(entity) then
			return false -- Entity is a friend, skip
		elseif checkFriend == nil and Common.IsFriend(entity) then
			return false -- Entity is a friend, skip (default behavior)
		end
	end

	return true -- Entity is a valid player
end

-- Create a common record structure
function Common.createRecord(angle, position, headHitbox, bodyHitbox, simTime, onGround)
	return {
		Angle = angle,
		ViewPos = position,
		Hitboxes = {
			Head = headHitbox,
			Body = bodyHitbox,
		},
		SimTime = simTime,
		onGround = onGround,
	}
end

-- Maximum number of historical snapshots to keep per player
Common.MAX_HISTORY = 66

-- Convenience: build a record directly from a player wrapper/entity
---@param player table|Entity WrappedPlayer or entity implementing required methods
---@return table record
function Common.createRecordFromPlayer(player)
	if not player or type(player.GetEyeAngles) ~= "function" then
		return nil
	end

	return Common.createRecord(
		player:GetEyeAngles(),
		player:GetEyePos(),
		player:GetHitboxPos(1), -- Head
		player:GetHitboxPos(4), -- Body
		player:GetSimulationTime(),
		player:IsOnGround()
	)
end

-- Push snapshot into player's history and keep size bounded
---@param player Entity|table Wrapped player / entity
function Common.pushHistory(player)
	local steamid = player:GetSteamID64()
	if not steamid or not player then
		return
	end
	G.PlayerData[steamid] = G.PlayerData[steamid] or {}
	local pdata = G.PlayerData[steamid]
	pdata.History = pdata.History or {}

	local record = Common.createRecordFromPlayer(player)
	if not record then
		return
	end -- skip invalid player

	pdata.Current = record
	table.insert(pdata.History, record)

	if #pdata.History > Common.MAX_HISTORY then
		table.remove(pdata.History, 1)
	end
end

function Common.FromSteamid3To64(steamid3)
	if not steamid3 then
		return nil
	end

	local raw = tostring(steamid3)
	if raw == "" then
		return nil
	end

	-- Already SteamID64
	if raw:match("^7656119%d+$") then
		return raw
	end

	-- Handle SteamID2 format (STEAM_X:Y:Z)
	if raw:match("^STEAM_%d+:%d+:%d+$") then
		local ok, converted = pcall(steam.ToSteamID64, raw)
		return ok and tostring(converted) or nil
	end

	-- Ensure SteamID3 wrapped in brackets
	if not raw:match("^%[U:1:%d+%]$") then
		raw = string.format("[U:1:%s]", raw)
	end

	local ok, converted = pcall(steam.ToSteamID64, raw)
	return ok and tostring(converted) or nil
end

-- Helper function to determine if the content is JSON
function Common.isJson(content)
	local firstChar = content:sub(1, 1)
	return firstChar == "{" or firstChar == "["
end

-- Safe integer rounding function for drawing coordinates
Common.RoundCoord = function(value)
	if not value then
		return 0
	end

	if type(value) ~= "number" then
		return 0
	end

	-- Check for NaN and infinity
	if value ~= value or value == math.huge or value == -math.huge then
		return 0
	end

	return math.floor(value + 0.5)
end

local E_Flows = { FLOW_OUTGOING = 0, FLOW_INCOMING = 1, MAX_FLOWS = 2 }

function Common.CheckConnectionState()
	local netChannel = clientstate.GetNetChannel()
	if not netChannel then
		return { stable = false, reason = "No NetChannel" }
	end

	-- Check for timeout
	if netChannel:IsTimingOut() then
		return { stable = false, reason = "Timing out" }
	end

	-- If we're just playing a demo, consider connection perfectly stable and skip further checks
	if netChannel:IsPlayback() then
		return { stable = true, reason = "Demo" }
	end

	-- Check latency, choke, and loss (incoming) — only for real servers
	local latency = netChannel:GetAvgLatency(E_Flows.FLOW_INCOMING)
	local choke = netChannel:GetAvgChoke(E_Flows.FLOW_INCOMING)
	local loss = netChannel:GetAvgLoss(E_Flows.FLOW_INCOMING)
	-- Thresholds: adjust as needed
	if latency > 0.5 then
		return { stable = false, reason = string.format("High latency: %.2f", latency) }
	end
	if choke > 0.2 then
		return { stable = false, reason = string.format("High choke: %.2f", choke) }
	end
	if loss > 0.1 then
		return { stable = false, reason = string.format("High loss: %.2f", loss) }
	end

	return { stable = true }
end

--[[ Registrations and final actions ]]
--
local function OnUnload() -- Called when the script is unloaded
	UnloadLib() --unloading lualib
	engine.PlaySound("hl1/fvox/deactivated.wav") --deactivated
end

-- Unregister previous callbacks
callbacks.Unregister("Unload", "CD_Unload") -- unregister the "Unload" callback

-- Register callbacks
callbacks.Register("Unload", "CD_Unload", OnUnload) -- Register the "Unload" callback

-- Play sound when loaded
engine.PlaySound("hl1/fvox/activated.wav")

return Common

end)
__bundle_register("Cheater_Detection.Libs.Json", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
David Kolf's JSON module for Lua 5.1 - 5.4

Version 2.6


For the documentation see the corresponding readme.txt or visit
<http://dkolf.de/src/dkjson-lua.fsl/>.

You can contact the author by sending an e-mail to 'david' at the
domain 'dkolf.de'.


Copyright (C) 2010-2021 David Heiko Kolf

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--]]

---@alias JsonState { indent : boolean?, keyorder : integer[]?, level : integer?, buffer : string[]?, bufferlen : integer?, tables : table[]?, exception : function? }

-- global dependencies:
local pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset =
	pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset
local error, require, pcall, select = error, require, pcall, select
local floor, huge = math.floor, math.huge
local strrep, gsub, strsub, strbyte, strchar, strfind, strlen, strformat =
	string.rep, string.gsub, string.sub, string.byte, string.char, string.find, string.len, string.format
local strmatch = string.match
local concat = table.concat

---@class Json
local json = { version = "dkjson 2.6.1 L" }

local _ENV = nil -- blocking globals in Lua 5.2 and later

json.null = setmetatable({}, {
	__tojson = function()
		return "null"
	end,
})

local function isarray(tbl)
	local max, n, arraylen = 0, 0, 0
	for k, v in pairs(tbl) do
		if k == "n" and type(v) == "number" then
			arraylen = v
			if v > max then
				max = v
			end
		else
			if type(k) ~= "number" or k < 1 or floor(k) ~= k then
				return false
			end
			if k > max then
				max = k
			end
			n = n + 1
		end
	end
	if max > 10 and max > arraylen and max > n * 2 then
		return false -- don't create an array with too many holes
	end
	return true, max
end

local escapecodes = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function escapeutf8(uchar)
	local value = escapecodes[uchar]
	if value then
		return value
	end
	local a, b, c, d = strbyte(uchar, 1, 4)
	a, b, c, d = a or 0, b or 0, c or 0, d or 0
	if a <= 0x7f then
		value = a
	elseif 0xc0 <= a and a <= 0xdf and b >= 0x80 then
		value = (a - 0xc0) * 0x40 + b - 0x80
	elseif 0xe0 <= a and a <= 0xef and b >= 0x80 and c >= 0x80 then
		value = ((a - 0xe0) * 0x40 + b - 0x80) * 0x40 + c - 0x80
	elseif 0xf0 <= a and a <= 0xf7 and b >= 0x80 and c >= 0x80 and d >= 0x80 then
		value = (((a - 0xf0) * 0x40 + b - 0x80) * 0x40 + c - 0x80) * 0x40 + d - 0x80
	else
		return ""
	end
	if value <= 0xffff then
		return strformat("\\u%.4x", value)
	elseif value <= 0x10ffff then
		-- encode as UTF-16 surrogate pair
		value = value - 0x10000
		local highsur, lowsur = 0xD800 + floor(value / 0x400), 0xDC00 + (value % 0x400)
		return strformat("\\u%.4x\\u%.4x", highsur, lowsur)
	else
		return ""
	end
end

local function fsub(str, pattern, repl)
	-- gsub always builds a new string in a buffer, even when no match
	-- exists. First using find should be more efficient when most strings
	-- don't contain the pattern.
	if strfind(str, pattern) then
		return gsub(str, pattern, repl)
	else
		return str
	end
end

local function quotestring(value)
	-- based on the regexp "escapable" in https://github.com/douglascrockford/JSON-js
	value = fsub(value, '[%z\1-\31"\\\127]', escapeutf8)
	if strfind(value, "[\194\216\220\225\226\239]") then
		value = fsub(value, "\194[\128-\159\173]", escapeutf8)
		value = fsub(value, "\216[\128-\132]", escapeutf8)
		value = fsub(value, "\220\143", escapeutf8)
		value = fsub(value, "\225\158[\180\181]", escapeutf8)
		value = fsub(value, "\226\128[\140-\143\168-\175]", escapeutf8)
		value = fsub(value, "\226\129[\160-\175]", escapeutf8)
		value = fsub(value, "\239\187\191", escapeutf8)
		value = fsub(value, "\239\191[\176-\191]", escapeutf8)
	end
	return '"' .. value .. '"'
end
json.quotestring = quotestring

local function replace(str, o, n)
	local i, j = strfind(str, o, 1, true)
	if i then
		return strsub(str, 1, i - 1) .. n .. strsub(str, j + 1, -1)
	else
		return str
	end
end

-- locale independent num2str and str2num functions
local decpoint, numfilter

local function updatedecpoint()
	decpoint = strmatch(tostring(0.5), "([^05+])")
	-- build a filter that can be used to remove group separators
	numfilter = "[^0-9%-%+eE" .. gsub(decpoint, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "]+"
end

updatedecpoint()

local function num2str(num)
	return replace(fsub(tostring(num), numfilter, ""), decpoint, ".")
end

local function str2num(str)
	local num = tonumber(replace(str, ".", decpoint))
	if not num then
		updatedecpoint()
		num = tonumber(replace(str, ".", decpoint))
	end
	return num
end

local function addnewline2(level, buffer, buflen)
	buffer[buflen + 1] = "\n"
	buffer[buflen + 2] = strrep("  ", level)
	buflen = buflen + 2
	return buflen
end

function json.addnewline(state)
	if state.indent then
		state.bufferlen = addnewline2(state.level or 0, state.buffer, state.bufferlen or #state.buffer)
	end
end

local encode2 -- forward declaration

local function addpair(key, value, prev, indent, level, buffer, buflen, tables, globalorder, state)
	local kt = type(key)
	if kt ~= "string" and kt ~= "number" then
		return nil, "type '" .. kt .. "' is not supported as a key by JSON."
	end
	if prev then
		buflen = buflen + 1
		buffer[buflen] = ","
	end
	if indent then
		buflen = addnewline2(level, buffer, buflen)
	end
	buffer[buflen + 1] = quotestring(key)
	buffer[buflen + 2] = ":"
	return encode2(value, indent, level, buffer, buflen + 2, tables, globalorder, state)
end

local function appendcustom(res, buffer, state)
	local buflen = state.bufferlen
	if type(res) == "string" then
		buflen = buflen + 1
		buffer[buflen] = res
	end
	return buflen
end

local function exception(reason, value, state, buffer, buflen, defaultmessage)
	defaultmessage = defaultmessage or reason
	local handler = state.exception
	if not handler then
		return nil, defaultmessage
	else
		state.bufferlen = buflen
		local ret, msg = handler(reason, value, state, defaultmessage)
		if not ret then
			return nil, msg or defaultmessage
		end
		return appendcustom(ret, buffer, state)
	end
end

function json.encodeexception(reason, value, state, defaultmessage)
	return quotestring("<" .. defaultmessage .. ">")
end

encode2 = function(value, indent, level, buffer, buflen, tables, globalorder, state)
	local valtype = type(value)
	local valmeta = getmetatable(value)
	valmeta = type(valmeta) == "table" and valmeta -- only tables
	local valtojson = valmeta and valmeta.__tojson
	if valtojson then
		if tables[value] then
			return exception("reference cycle", value, state, buffer, buflen)
		end
		tables[value] = true
		state.bufferlen = buflen
		local ret, msg = valtojson(value, state)
		if not ret then
			return exception("custom encoder failed", value, state, buffer, buflen, msg)
		end
		tables[value] = nil
		buflen = appendcustom(ret, buffer, state)
	elseif value == nil then
		buflen = buflen + 1
		buffer[buflen] = "null"
	elseif valtype == "number" then
		local s
		if value ~= value or value >= huge or -value >= huge then
			-- This is the behaviour of the original JSON implementation.
			s = "null"
		else
			s = num2str(value)
		end
		buflen = buflen + 1
		buffer[buflen] = s
	elseif valtype == "boolean" then
		buflen = buflen + 1
		buffer[buflen] = value and "true" or "false"
	elseif valtype == "string" then
		buflen = buflen + 1
		buffer[buflen] = quotestring(value)
	elseif valtype == "table" then
		if tables[value] then
			return exception("reference cycle", value, state, buffer, buflen)
		end
		tables[value] = true
		level = level + 1
		local isa, n = isarray(value)
		if n == 0 and valmeta and valmeta.__jsontype == "object" then
			isa = false
		end
		local msg
		if isa then -- JSON array
			buflen = buflen + 1
			buffer[buflen] = "["
			for i = 1, n do
				buflen, msg = encode2(value[i], indent, level, buffer, buflen, tables, globalorder, state)
				if not buflen then
					return nil, msg
				end
				if i < n then
					buflen = buflen + 1
					buffer[buflen] = ","
				end
			end
			buflen = buflen + 1
			buffer[buflen] = "]"
		else -- JSON object
			local prev = false
			buflen = buflen + 1
			buffer[buflen] = "{"
			local order = valmeta and valmeta.__jsonorder or globalorder
			if order then
				local used = {}
				n = #order
				for i = 1, n do
					local k = order[i]
					local v = value[k]
					if v ~= nil then
						used[k] = true
						buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
						prev = true -- add a seperator before the next element
					end
				end
				for k, v in pairs(value) do
					if not used[k] then
						buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
						if not buflen then
							return nil, msg
						end
						prev = true -- add a seperator before the next element
					end
				end
			else -- unordered
				for k, v in pairs(value) do
					buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
					if not buflen then
						return nil, msg
					end
					prev = true -- add a seperator before the next element
				end
			end
			if indent then
				buflen = addnewline2(level - 1, buffer, buflen)
			end
			buflen = buflen + 1
			buffer[buflen] = "}"
		end
		tables[value] = nil
	else
		return exception(
			"unsupported type",
			value,
			state,
			buffer,
			buflen,
			"type '" .. valtype .. "' is not supported by JSON."
		)
	end
	return buflen
end

---Encodes a lua table to a JSON string.
---@param value any
---@param state? JsonState
---@return string|boolean
function json.encode(value, state)
	state = state or {}
	local oldbuffer = state.buffer
	local buffer = oldbuffer or {}
	state.buffer = buffer
	updatedecpoint()
	local ret, msg = encode2(
		value,
		state.indent,
		state.level or 0,
		buffer,
		state.bufferlen or 0,
		state.tables or {},
		state.keyorder,
		state
	)
	if not ret then
		error(msg, 2)
	elseif oldbuffer == buffer then
		state.bufferlen = ret
		return true
	else
		state.bufferlen = nil
		state.buffer = nil
		return concat(buffer)
	end
end

local function loc(str, where)
	local line, pos, linepos = 1, 1, 0
	while true do
		pos = strfind(str, "\n", pos, true)
		if pos and pos < where then
			line = line + 1
			linepos = pos
			pos = pos + 1
		else
			break
		end
	end
	return "line " .. line .. ", column " .. (where - linepos)
end

local function unterminated(str, what, where)
	return nil, strlen(str) + 1, "unterminated " .. what .. " at " .. loc(str, where)
end

local function scanwhite(str, pos)
	while true do
		pos = strfind(str, "%S", pos)
		if not pos then
			return nil
		end
		local sub2 = strsub(str, pos, pos + 1)
		if sub2 == "\239\187" and strsub(str, pos + 2, pos + 2) == "\191" then
			-- UTF-8 Byte Order Mark
			pos = pos + 3
		elseif sub2 == "//" then
			pos = strfind(str, "[\n\r]", pos + 2)
			if not pos then
				return nil
			end
		elseif sub2 == "/*" then
			pos = strfind(str, "*/", pos + 2)
			if not pos then
				return nil
			end
			pos = pos + 2
		else
			return pos
		end
	end
end

local escapechars = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	["b"] = "\b",
	["f"] = "\f",
	["n"] = "\n",
	["r"] = "\r",
	["t"] = "\t",
}

local function unichar(value)
	if value < 0 then
		return nil
	elseif value <= 0x007f then
		return strchar(value)
	elseif value <= 0x07ff then
		return strchar(0xc0 + floor(value / 0x40), 0x80 + (floor(value) % 0x40))
	elseif value <= 0xffff then
		return strchar(0xe0 + floor(value / 0x1000), 0x80 + (floor(value / 0x40) % 0x40), 0x80 + (floor(value) % 0x40))
	elseif value <= 0x10ffff then
		return strchar(
			0xf0 + floor(value / 0x40000),
			0x80 + (floor(value / 0x1000) % 0x40),
			0x80 + (floor(value / 0x40) % 0x40),
			0x80 + (floor(value) % 0x40)
		)
	else
		return nil
	end
end

local function scanstring(str, pos)
	local lastpos = pos + 1
	local buffer, n = {}, 0
	while true do
		local nextpos = strfind(str, '["\\]', lastpos)
		if not nextpos then
			return unterminated(str, "string", pos)
		end
		if nextpos > lastpos then
			n = n + 1
			buffer[n] = strsub(str, lastpos, nextpos - 1)
		end
		if strsub(str, nextpos, nextpos) == '"' then
			lastpos = nextpos + 1
			break
		else
			local escchar = strsub(str, nextpos + 1, nextpos + 1)
			local value
			if escchar == "u" then
				value = tonumber(strsub(str, nextpos + 2, nextpos + 5), 16)
				if value then
					local value2
					if 0xD800 <= value and value <= 0xDBff then
						-- we have the high surrogate of UTF-16. Check if there is a
						-- low surrogate escaped nearby to combine them.
						if strsub(str, nextpos + 6, nextpos + 7) == "\\u" then
							value2 = tonumber(strsub(str, nextpos + 8, nextpos + 11), 16)
							if value2 and 0xDC00 <= value2 and value2 <= 0xDFFF then
								value = (value - 0xD800) * 0x400 + (value2 - 0xDC00) + 0x10000
							else
								value2 = nil -- in case it was out of range for a low surrogate
							end
						end
					end
					value = value and unichar(value)
					if value then
						if value2 then
							lastpos = nextpos + 12
						else
							lastpos = nextpos + 6
						end
					end
				end
			end
			if not value then
				value = escapechars[escchar] or escchar
				lastpos = nextpos + 2
			end
			n = n + 1
			buffer[n] = value
		end
	end
	if n == 1 then
		return buffer[1], lastpos
	elseif n > 1 then
		return concat(buffer), lastpos
	else
		return "", lastpos
	end
end

local scanvalue -- forward declaration

local function scantable(what, closechar, str, startpos, nullval, objectmeta, arraymeta)
	local tbl, n = {}, 0
	local pos = startpos + 1
	if what == "object" then
		setmetatable(tbl, objectmeta)
	else
		setmetatable(tbl, arraymeta)
	end
	while true do
		pos = scanwhite(str, pos)
		if not pos then
			return unterminated(str, what, startpos)
		end
		local char = strsub(str, pos, pos)
		if char == closechar then
			return tbl, pos + 1
		end
		local val1, err
		val1, pos, err = scanvalue(str, pos, nullval, objectmeta, arraymeta)
		if err then
			return nil, pos, err
		end
		pos = scanwhite(str, pos)
		if not pos then
			return unterminated(str, what, startpos)
		end
		char = strsub(str, pos, pos)
		if char == ":" then
			if val1 == nil then
				return nil, pos, "cannot use nil as table index (at " .. loc(str, pos) .. ")"
			end
			pos = scanwhite(str, pos + 1)
			if not pos then
				return unterminated(str, what, startpos)
			end
			local val2
			val2, pos, err = scanvalue(str, pos, nullval, objectmeta, arraymeta)
			if err then
				return nil, pos, err
			end
			tbl[val1] = val2
			pos = scanwhite(str, pos)
			if not pos then
				return unterminated(str, what, startpos)
			end
			char = strsub(str, pos, pos)
		else
			n = n + 1
			tbl[n] = val1
		end
		if char == "," then
			pos = pos + 1
		end
	end
end

scanvalue = function(str, pos, nullval, objectmeta, arraymeta)
	pos = pos or 1
	pos = scanwhite(str, pos)
	if not pos then
		return nil, strlen(str) + 1, "no valid JSON value (reached the end)"
	end
	local char = strsub(str, pos, pos)
	if char == "{" then
		return scantable("object", "}", str, pos, nullval, objectmeta, arraymeta)
	elseif char == "[" then
		return scantable("array", "]", str, pos, nullval, objectmeta, arraymeta)
	elseif char == '"' then
		return scanstring(str, pos)
	else
		local pstart, pend = strfind(str, "^%-?[%d%.]+[eE]?[%+%-]?%d*", pos)
		if pstart then
			local number = str2num(strsub(str, pstart, pend))
			if number then
				return number, pend + 1
			end
		end
		pstart, pend = strfind(str, "^%a%w*", pos)
		if pstart then
			local name = strsub(str, pstart, pend)
			if name == "true" then
				return true, pend + 1
			elseif name == "false" then
				return false, pend + 1
			elseif name == "null" then
				return nullval, pend + 1
			end
		end
		return nil, pos, "no valid JSON value at " .. loc(str, pos)
	end
end

local function optionalmetatables(...)
	if select("#", ...) > 0 then
		return ...
	else
		return { __jsontype = "object" }, { __jsontype = "array" }
	end
end

---@param str string
---@param pos integer?
---@param nullval any?
---@param ... table?
function json.decode(str, pos, nullval, ...)
	local objectmeta, arraymeta = optionalmetatables(...)
	return scanvalue(str, pos, nullval, objectmeta, arraymeta)
end

return json

end)
__bundle_register("Cheater_Detection.Utils.PlayerState", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ PlayerState.lua
     Central storage for per-player runtime data.
     Ensures a single source of truth that is populated only for
     players currently in the server.
]]

local G = require("Cheater_Detection.Utils.Globals")
local DefaultPlayerData = require("Cheater_Detection.Utils.DefaultPlayerData")

local PlayerState = {}

---@type table<string, table>
local ActivePlayers = {}
G.PlayerData = ActivePlayers -- Maintain backwards compatibility

local function newVector(vec)
	if not vec then
		return Vector3(0, 0, 0)
	end
	return Vector3(vec.x, vec.y, vec.z)
end

local function newAngles(ang)
	if not ang then
		return EulerAngles(0, 0, 0)
	end
	return EulerAngles(ang.x, ang.y, ang.z)
end

local function createHistoryRecord()
	return {
		Angle = EulerAngles(0, 0, 0),
		Hitboxes = {
			Head = Vector3(0, 0, 0),
			Body = Vector3(0, 0, 0),
		},
		SimTime = 0,
		onGround = true,
		StdDev = 1,
		FiredGun = false,
	}
end

local function createCurrent()
	return {
		Angle = EulerAngles(0, 0, 0),
		Hitboxes = {
			Head = Vector3(0, 0, 0),
			Body = Vector3(0, 0, 0),
		},
		SimTime = 0,
		onGround = true,
		FiredGun = false,
	}
end

local function createInfo()
	return {
		Name = "Unknown",
		IsCheater = false,
		bhop = 0,
		LastOnGround = true,
		LastVelocity = Vector3(0, 0, 0),
		LastStrike = 0,
	}
end

local function createEvidence()
	return {
		TotalScore = 0,
		LastUpdateTick = 0,
		Reasons = {},
	}
end

local function createState()
	return {
		Entity = nil,
		info = createInfo(),
		Evidence = createEvidence(),
		Current = createCurrent(),
		History = { createHistoryRecord() },
		LastSeenTick = 0,
	}
end

---Return the internal storage table (legacy compatibility)
---@return table<string, table>
function PlayerState.GetTable()
	return ActivePlayers
end

---Create or fetch a player's state table
---@param steamID string
---@return table|nil
function PlayerState.Get(steamID)
	if not steamID then
		return nil
	end
	return ActivePlayers[tostring(steamID)]
end

function PlayerState.GetOrCreate(steamID)
	if not steamID then
		return nil
	end

	steamID = tostring(steamID)
	local state = ActivePlayers[steamID]
	if not state then
		state = createState()
		ActivePlayers[steamID] = state
	end

	state.LastSeenTick = globals.TickCount()
	return state
end

function PlayerState.GetHistory(steamID)
	local state = PlayerState.GetOrCreate(steamID)
	if not state then
		return nil
	end
	state.History = state.History or { createHistoryRecord() }
	return state.History
end

function PlayerState.PushHistory(steamID, record, maxHistory)
	if not steamID or not record then
		return
	end
	local state = PlayerState.GetOrCreate(steamID)
	if not state then
		return
	end
	state.History = state.History or {}
	state.History[#state.History + 1] = record
	state.Current = record
	local limit = maxHistory or 66
	if #state.History > limit then
		table.remove(state.History, 1)
	end
end

---Attach runtime info from a WrappedPlayer to its state table
---@param wrapped table
---@return table|nil
function PlayerState.AttachWrappedPlayer(wrapped)
	if not wrapped or type(wrapped.GetSteamID64) ~= "function" then
		return nil
	end

	local steamID = wrapped:GetSteamID64()
	if not steamID then
		return nil
	end

	local state = PlayerState.GetOrCreate(steamID)
	if not state then
		return nil
	end
	state.Entity = wrapped:GetRawEntity()

	state.info = state.info or createInfo()

	if wrapped.GetName then
		local name = wrapped:GetName()
		if name and name ~= "" then
			state.info.Name = name
		end
	end

	if wrapped.GetTeamNumber then
		state.info.Team = wrapped:GetTeamNumber()
	end

	return state
end

---Ensure only actively tracked players remain in memory
---@param activeSet table<string, boolean>
function PlayerState.TrimToActive(activeSet)
	if not activeSet then
		return
	end

	for steamID in pairs(ActivePlayers) do
		if not activeSet[steamID] then
			ActivePlayers[steamID] = nil
		end
	end
end

---Remove every tracked player (e.g., on disconnect/map change)
function PlayerState.Reset()
	for steamID in pairs(ActivePlayers) do
		ActivePlayers[steamID] = nil
	end
end

return PlayerState

end)
__bundle_register("Cheater_Detection.Utils.DefaultPlayerData", function(require, _LOADED, __bundle_register, __bundle_modules)
PlayerData = {}

--[[ Annotations ]]
--- @alias TickData { Angle: EulerAngles, Position: Vector3, SimTime: number }
--- @alias PlayerHistory { Ticks: TickData[] }
--- @alias PlayerCurrent { Angle: EulerAngles, Position: Vector3, SimTime: number }
--- @alias PlayerState { Strikes: number, IsCheater: boolean }
--- @alias Globals.PlayerData table<number, { Entity: any, History: PlayerHistory, Current: PlayerCurrent, Info: PlayerState }>
PlayerData.DefaultPlayerData = {
	Entity = nil,
	info = {
		Name = "NN",
		IsCheater = false,
		bhop = 0,
		LastOnGround = true,
		LastVelocity = Vector3(0, 0, 0),
		LastStrike = 0,
	},

	Evidence = {
		TotalScore = 0,
		LastUpdateTick = 0,
		Reasons = {
			-- Populated dynamically by detections
		},
	},

	Current = {
		Angle = EulerAngles(0, 0, 0),
		Hitboxes = {
			Head = Vector3(0, 0, 0),
			Body = Vector3(0, 0, 0),
		},
		SimTime = 0,
		onGround = true,
		FiredGun = false,
	},

	History = {
		{
			Angle = EulerAngles(0, 0, 0),
			Hitboxes = {
				Head = Vector3(0, 0, 0),
				Body = Vector3(0, 0, 0),
			},
			SimTime = 0,
			onGround = true,
			StdDev = 1,
			FiredGun = false,
		},
	},
}

PlayerData.defaultRecord = {
	Name = "NN",
	Reason = "Unknown Source",
	Date = "",
}

return PlayerData

end)
__bundle_register("Cheater_Detection.Utils.FastPlayers", function(require, _LOADED, __bundle_register, __bundle_modules)
-- fastplayers.lua ─────────────────────────────────────────────────────────
-- FastPlayers: Simplified per-tick cached player lists.
-- On each CreateMove tick, caches reset; lists built on demand.

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")
local WrappedPlayer = require("Cheater_Detection.Utils.WrappedPlayer")

--[[ Module Declaration ]]
local FastPlayers = {}

--[[ Local Caches ]]
local cachedAllPlayers
local cachedTeammates
local cachedEnemies
local cachedLocal
local activeSteamIDs = {}

FastPlayers.AllUpdated = false
FastPlayers.TeammatesUpdated = false
FastPlayers.EnemiesUpdated = false

--[[ Private: Reset per-tick caches ]]
local function ResetCaches()
	cachedAllPlayers = nil
	cachedTeammates = nil
	cachedEnemies = nil
	cachedLocal = nil
	activeSteamIDs = {}
	FastPlayers.AllUpdated = false
	FastPlayers.TeammatesUpdated = false
	FastPlayers.EnemiesUpdated = false
end

--[[ Public API ]]

--- Returns list of valid players once per tick.
---@param excludelocal boolean? Pass true to exclude local player, false to include
---@return WrappedPlayer[]
function FastPlayers.GetAll(excludelocal)
	if FastPlayers.AllUpdated then
		return cachedAllPlayers
	end
	excludelocal = excludelocal and FastPlayers.GetLocal() or nil
	cachedAllPlayers = {}
	activeSteamIDs = {}

	-- Use Common.IsValidPlayer as single source of truth
	-- Pass nil for checkFriend to use debug mode logic internally
	-- Pass false for checkDormant to include dormant players (we want to track them)
	for _, ent in pairs(entities.FindByClass("CTFPlayer") or {}) do
		if Common.IsValidPlayer(ent, nil, false, excludelocal) then
			local wrapped = WrappedPlayer.FromEntity(ent)
			if wrapped then
				cachedAllPlayers[#cachedAllPlayers + 1] = wrapped
				local steamID = wrapped:GetSteamID64()
				if steamID then
					activeSteamIDs[steamID] = true
				end
			end
		end
	end

	if PlayerState and PlayerState.TrimToActive then
		PlayerState.TrimToActive(activeSteamIDs)
	end
	FastPlayers.AllUpdated = true
	return cachedAllPlayers
end

--- Returns the local player as a WrappedPlayer instance, cached after first wrap.
---@return WrappedPlayer?
function FastPlayers.GetLocal()
	if not cachedLocal then
		local rawLocal = entities.GetLocalPlayer()
		cachedLocal = rawLocal and WrappedPlayer.FromEntity(rawLocal) or nil
	end
	return cachedLocal
end

--- Returns list of teammates, optionally excluding a player (or the local player).
---@param exclude boolean|WrappedPlayer? Pass `true` to exclude the local player, or a WrappedPlayer instance to exclude that specific teammate. Omit/nil to include everyone.
---@return WrappedPlayer[]
function FastPlayers.GetTeammates(exclude)
	if not FastPlayers.TeammatesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end

		cachedTeammates = {}

		-- Determine which player (if any) to exclude
		local localPlayer = FastPlayers.GetLocal()
		local excludePlayer = nil
		if exclude == true then
			excludePlayer = localPlayer -- explicitly exclude self
		elseif type(exclude) == "table" then
			excludePlayer = exclude
		end

		-- Use local player's team for filtering
		local myTeam = localPlayer and localPlayer:GetTeamNumber() or nil
		if myTeam then
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetTeamNumber() == myTeam and wp ~= excludePlayer then
					cachedTeammates[#cachedTeammates + 1] = wp
				end
			end
		end

		FastPlayers.TeammatesUpdated = true
	end
	return cachedTeammates
end

--- Returns list of enemies (players on a different team).
---@return WrappedPlayer[]
function FastPlayers.GetEnemies()
	if not FastPlayers.EnemiesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end
		cachedEnemies = {}
		local pLocal = FastPlayers.GetLocal()
		if pLocal then
			local myTeam = pLocal:GetTeamNumber()
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetTeamNumber() ~= myTeam then
					cachedEnemies[#cachedEnemies + 1] = wp
				end
			end
		end
		FastPlayers.EnemiesUpdated = true
	end
	return cachedEnemies
end

--[[ Initialization ]]
-- Reset caches at the start of every CreateMove tick.
callbacks.Register("CreateMove", "FastPlayers_ResetCaches", ResetCaches)

return FastPlayers

end)
__bundle_register("Cheater_Detection.Utils.WrappedPlayer", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ WrappedPlayer.lua ]]
--
-- A proper wrapper for player entities that extends lnxLib's WPlayer

-- Get required modules
local Common = require("Cheater_Detection.Utils.Common")
local PlayerState = require("Cheater_Detection.Utils.PlayerState")

assert(Common, "Common is nil")
local WPlayer = Common.WPlayer
assert(WPlayer, "WPlayer is nil")

---@class WrappedPlayer
---@field _basePlayer table Base WPlayer from lnxLib
---@field _rawEntity Entity Raw entity object
local WrappedPlayer = {}

-- Instance metatable that forwards unknown lookups to the base WPlayer
local WrappedPlayerMT = {}

local function cacheValue(cache, key, computeFn)
	local cached = cache[key]
	if cached ~= nil then
		return cached
	end
	local result = computeFn()
	if result ~= nil then
		cache[key] = result
	end
	return result
end

local function wrapCall(target, method)
	if type(method) ~= "function" then
		return method
	end
	return function(_, ...)
		return method(target, ...)
	end
end

function WrappedPlayerMT.__index(self, key)
	-- 1) Custom helpers defined on WrappedPlayer
	local custom = WrappedPlayer[key]
	if custom ~= nil then
		return custom
	end

	-- 2) Fallback to lnxLib WPlayer (already proxies to raw entity)
	local basePlayer = rawget(self, "_basePlayer")
	if basePlayer then
		local value = basePlayer[key]
		if value ~= nil then
			return wrapCall(basePlayer, value)
		end
	end

	-- 3) Expose raw entity fields as a last resort
	local rawEntity = rawget(self, "_rawEntity")
	if rawEntity then
		local rawValue = rawEntity[key]
		if rawValue ~= nil then
			return wrapCall(rawEntity, rawValue)
		end
	end

	return nil
end

--- Creates a new WrappedPlayer from a TF2 entity
---@param entity Entity The entity to wrap
---@return WrappedPlayer|nil The wrapped player or nil if invalid
function WrappedPlayer.FromEntity(entity)
	if not entity or not entity:IsValid() then
		return nil
	end

	local basePlayer = WPlayer.FromEntity(entity)
	if not basePlayer then
		return nil
	end

	local wrapped = setmetatable({}, WrappedPlayerMT)
	wrapped._basePlayer = basePlayer -- Store the lnxLib player wrapper
	wrapped._rawEntity = entity -- Store the raw entity directly
	wrapped._cache = {}
	wrapped._cacheTick = -1
	wrapped._steamID64 = nil
	wrapped._steamID3 = nil
	wrapped._state = nil

	if PlayerState then
		wrapped._state = PlayerState.AttachWrappedPlayer(wrapped)
	end

	return wrapped
end

--- Create WrappedPlayer from index
---@param index number The entity index
---@return WrappedPlayer|nil The wrapped player or nil if invalid
function WrappedPlayer.FromIndex(index)
	local entity = entities.GetByIndex(index)
	return entity and WrappedPlayer.FromEntity(entity) or nil
end

--- Returns the underlying raw entity
function WrappedPlayer:GetRawEntity()
	return self._rawEntity
end

--- Resets per-tick cache (called automatically via Cache())
function WrappedPlayer:ResetCache()
	self._cache = {}
	self._cacheTick = globals.TickCount()
end

--- Retrieve a per-tick cache table unique to this wrapper
---@return table
function WrappedPlayer:Cache()
	local tick = globals.TickCount()
	if self._cacheTick ~= tick then
		self:ResetCache()
	end
	return self._cache
end

--- Returns the base WPlayer from lnxLib
function WrappedPlayer:GetBasePlayer()
	return self._basePlayer
end

--- Checks if a given entity is valid
---@param checkFriend boolean? Check if the entity is a friend
---@param checkDormant boolean? Check if the entity is dormant
---@param skipEntity Entity? Optional entity to skip
---@return boolean Whether the entity is valid
function WrappedPlayer:IsValidPlayer(checkFriend, checkDormant, skipEntity)
	return Common.IsValidPlayer(self._rawEntity, checkFriend, checkDormant, skipEntity)
end

--- Get SteamID64 for this player object
---@return string|number The player's SteamID64
function WrappedPlayer:GetSteamID64()
	if not self._steamID64 then
		local steamID = Common.GetSteamID64(self._basePlayer)
		if steamID then
			self._steamID64 = tostring(steamID)
		end
	end
	return self._steamID64
end

--- Get SteamID3 for this player object
---@return string|nil
function WrappedPlayer:GetSteamID3()
	if not self._steamID3 then
		local steamID64 = self:GetSteamID64()
		local numeric = tonumber(steamID64)
		if numeric then
			local accountID = numeric - 76561197960265728
			if accountID and accountID >= 0 then
				self._steamID3 = string.format("[U:1:%d]", accountID)
			end
		end
	end
	return self._steamID3
end

--- Returns PlayerState entry associated with this player
---@return table|nil
function WrappedPlayer:GetState()
	if not PlayerState then
		return nil
	end
	if not self._state then
		self._state = PlayerState.AttachWrappedPlayer(self)
	end
	return self._state
end

function WrappedPlayer:GetEvidence()
	local state = self:GetState()
	if not state then
		return nil
	end
	state.Evidence = state.Evidence or {}
	return state.Evidence
end

function WrappedPlayer:GetData()
	return self:GetState()
end

function WrappedPlayer:GetInfo()
	local state = self:GetState()
	if not state then
		return nil
	end
	state.info = state.info or {}
	return state.info
end

function WrappedPlayer:GetHistory()
	if not PlayerState then
		return nil
	end
	local steamID = self:GetSteamID64()
	if not steamID then
		return nil
	end
	return PlayerState.GetHistory(steamID)
end

function WrappedPlayer:PushHistory(record, maxHistory)
	if not PlayerState then
		return
	end
	local steamID = self:GetSteamID64()
	if not steamID then
		return
	end
	PlayerState.PushHistory(steamID, record, maxHistory or Common.MAX_HISTORY or 66)
end

--- Check if player is on the ground via m_fFlags
---@return boolean Whether the player is on the ground
function WrappedPlayer:IsOnGround()
	local flags = self._basePlayer:GetPropInt("m_fFlags")
	return (flags & FL_ONGROUND) ~= 0
end

function WrappedPlayer:IsAlive()
	return self._rawEntity and self._rawEntity:IsAlive() or false
end

function WrappedPlayer:IsDormant()
	local cache = self:Cache()
	return cacheValue(cache, "isDormant", function()
		return self._rawEntity and self._rawEntity:IsDormant() or true
	end)
end

function WrappedPlayer:IsFriend(includeParty)
	return Common.IsFriend(self._rawEntity, includeParty)
end

function WrappedPlayer:IsEnemyOf(other)
	if not other or type(other.GetTeamNumber) ~= "function" then
		return false
	end
	local myTeam = self._rawEntity and self._rawEntity:GetTeamNumber()
	return myTeam ~= nil and myTeam ~= 0 and myTeam ~= other:GetTeamNumber()
end

--- Returns the view offset from the player's origin as a Vector3
---@return Vector3 The player's view offset
function WrappedPlayer:GetViewOffset()
	local cache = self:Cache()
	return cacheValue(cache, "viewOffset", function()
		return self._basePlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
	end)
end

--- Returns the player's eye position in world coordinates
---@return Vector3 The player's eye position
function WrappedPlayer:GetEyePos()
	local cache = self:Cache()
	return cacheValue(cache, "eyePos", function()
		local origin = self:GetAbsOrigin()
		local offset = self:GetViewOffset()
		if origin and offset then
			return origin + offset
		end
		return nil
	end)
end

--- Returns the player's eye angles as an EulerAngles object
---@return EulerAngles The player's eye angles
function WrappedPlayer:GetEyeAngles()
	local cache = self:Cache()
	return cacheValue(cache, "eyeAngles", function()
		local ang = self._basePlayer:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
		if ang then
			return EulerAngles(ang.x, ang.y, ang.z)
		end
		return nil
	end)
end

function WrappedPlayer:GetAbsOrigin()
	local cache = self:Cache()
	return cacheValue(cache, "absOrigin", function()
		return self._basePlayer:GetAbsOrigin()
	end)
end

function WrappedPlayer:GetVelocity()
	local cache = self:Cache()
	return cacheValue(cache, "velocity", function()
		return self._basePlayer:EstimateAbsVelocity()
	end)
end

--- Returns the world position the player is looking at by tracing a ray
---@return Vector3|nil The look position or nil if trace failed
function WrappedPlayer:GetLookPos()
	local cache = self:Cache()
	return cacheValue(cache, "lookPos", function()
		local eyePos = self:GetEyePos()
		local eyeAng = self:GetEyeAngles()
		if not eyePos or not eyeAng then
			return nil
		end
		local targetPos = eyePos + eyeAng:Forward() * 8192
		local tr = engine.TraceLine(eyePos, targetPos, MASK_SHOT)
		return tr and tr.endpos or nil
	end)
end

--- Returns the currently active weapon wrapper
---@return table|nil The active weapon wrapper or nil
function WrappedPlayer:GetActiveWeapon()
	local w = self._basePlayer:GetPropEntity("m_hActiveWeapon")
	return w and Common.WWeapon.FromEntity(w) or nil
end

function WrappedPlayer:GetActiveWeaponID()
	local cache = self:Cache()
	return cacheValue(cache, "weaponID", function()
		local weapon = self:GetActiveWeapon()
		if weapon and weapon.GetWeaponID then
			return weapon:GetWeaponID()
		end
		return nil
	end)
end

function WrappedPlayer:GetWeaponChargeData()
	local cache = self:Cache()
	return cacheValue(cache, "weaponCharge", function()
		local weapon = self:GetActiveWeapon()
		if not weapon then
			return nil
		end
		return {
			ChargeBegin = weapon.GetChargeBeginTime and weapon:GetChargeBeginTime() or 0,
			ChargedDamage = weapon.GetChargedDamage and weapon:GetChargedDamage() or 0,
		}
	end)
end

--- Returns the player's observer mode
---@return number The observer mode
function WrappedPlayer:GetObserverMode()
	return self._basePlayer:GetPropInt("m_iObserverMode")
end

--- Returns the player's observer target wrapper
---@return WrappedPlayer|nil The observer target or nil
function WrappedPlayer:GetObserverTarget()
	local target = self._basePlayer:GetPropEntity("m_hObserverTarget")
	return target and WrappedPlayer.FromEntity(target) or nil
end

--- Returns the next attack time
---@return number The next attack time
function WrappedPlayer:GetNextAttack()
	return self._basePlayer:GetPropFloat("m_flNextAttack")
end

function WrappedPlayer:SetPriority(level)
	if not level then
		return false
	end
	local success = pcall(playerlist.SetPriority, self._rawEntity or self._basePlayer, level)
	return success
end

function WrappedPlayer:IsCheater()
	local info = self:GetInfo()
	return info and info.IsCheater == true or false
end

function WrappedPlayer:MarkCheater(reason)
	local info = self:GetInfo()
	if not info then
		return
	end
	info.IsCheater = true
	info.CheaterReason = reason or info.CheaterReason
end

return WrappedPlayer

end)
__bundle_register("Cheater_Detection.Detection Methods.warp_dt", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Cheater Detection - Warp / Doubletap Detection ]]
--
-- Detects time manipulation exploits using statistical analysis of simulation time
-- Uses standard deviation of tick deltas to identify sequence burst patterns

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local WarpDT = {}

--[[ Configuration ]]
local DETECTION_NAME = "warp_dt"
local EVIDENCE_WEIGHT = 30 -- Very high - blatant exploit
local HISTORY_SIZE = 33 -- Ticks to analyze
local MIN_DELTA_SAMPLES = 30 -- Minimum samples for statistical analysis
local WARP_STDDEV_SIGNATURE = -132 -- Specific standard deviation value indicating warp
local TICK_TOLERANCE = 13 -- Tolerance for tick interval checks

-- Per-player state tracking
local playerWarpData = {}

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

local function initPlayerData(steamID)
	if not playerWarpData[steamID] then
		playerWarpData[steamID] = {
			simTimes = {},
			stdDevList = {},
			lastTickCount = nil,
		}
	end
end

local function timeToTicks(time)
	return Common.Conversion.Time_to_Ticks(time)
end

--[[ Public Functions ]]
function WarpDT.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.Warp then
		return false
	end

	-- Validate player
	if not validatePlayer(player) then
		return false
	end

	-- Get steamID for tracking
	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return false
	end

	-- Skip if already marked as cheater
	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	-- Initialize tracking data
	initPlayerData(steamID)
	local data = playerWarpData[steamID]

	-- Get simulation time in ticks
	local simTime = player:GetSimulationTime()
	if not simTime then
		return false
	end

	local simTimeTicks = timeToTicks(simTime)
	table.insert(data.simTimes, simTimeTicks)

	-- Keep history bounded
	if #data.simTimes > HISTORY_SIZE then
		table.remove(data.simTimes, 1)
	end

	-- Need enough data for analysis
	if #data.simTimes < HISTORY_SIZE then
		return false
	end

	-- Calculate tick deltas
	local deltaTicks = {}
	for i = 2, #data.simTimes do
		local delta = data.simTimes[i] - data.simTimes[i - 1]
		table.insert(deltaTicks, delta)
	end

	if #deltaTicks < MIN_DELTA_SAMPLES then
		return false
	end

	-- Calculate mean delta
	local meanDelta = 0
	for _, delta in ipairs(deltaTicks) do
		meanDelta = meanDelta + delta
	end
	meanDelta = meanDelta / #deltaTicks

	-- Calculate variance
	local sumSquaredDiff = 0
	for _, delta in ipairs(deltaTicks) do
		local diff = delta - meanDelta
		sumSquaredDiff = sumSquaredDiff + diff * diff
	end

	local variance = sumSquaredDiff / (#deltaTicks - 1)
	local stdDev = math.sqrt(variance)

	-- Clamp to detect warp signature
	stdDev = math.max(-132, stdDev)

	-- Check tick interval consistency (avoid false positives from script lag)
	local currentTick = globals.TickCount()
	if not data.lastTickCount then
		data.lastTickCount = currentTick
	else
		local tickInterval = globals.TickInterval()
		local expectedInterval = (currentTick - data.lastTickCount) / tickInterval

		-- If ticks are inconsistent, may be our own lag - skip
		if math.abs(currentTick - data.lastTickCount) < expectedInterval + TICK_TOLERANCE then
			data.lastTickCount = currentTick
			return false
		end

		data.lastTickCount = currentTick
	end

	-- Detect warp signature
	if stdDev == WARP_STDDEV_SIGNATURE then
		Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

		if G.Menu.Advanced.debug then
			print(string.format("[WarpDT] %s - Sequence burst detected (stdDev: %.0f)", player:GetName(), stdDev))
		end

		return true
	end

	-- Track standard deviation history
	table.insert(data.stdDevList, stdDev)
	if #data.stdDevList > HISTORY_SIZE then
		table.remove(data.stdDevList, 1)
	end

	return false
end

return WarpDT

end)
__bundle_register("Cheater_Detection.Detection Methods.fake_lag", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Cheater Detection - Fake Lag Detection ]]
--
-- Detects packet choking (fakelag, doubletap) by monitoring simulation time delta

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local FakeLag = {}

--[[ Configuration ]]
local DETECTION_NAME = "fake_lag"
local EVIDENCE_WEIGHT = 22 -- High weight - exploit
local MAX_TICK_DELTA = 8 -- From old script's MaxTickDelta default

-- Per-player state tracking
local playerSimTimeData = {}

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

local function initPlayerData(steamID)
	if not playerSimTimeData[steamID] then
		playerSimTimeData[steamID] = {
			lastSimTime = nil,
		}
	end
end

local function timeToTicks(time)
	return math.floor(time / globals.TickInterval() + 0.5)
end

--[[ Public Functions ]]
function FakeLag.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.Choke then
		return false
	end

	-- Validate player
	if not validatePlayer(player) then
		return false
	end

	-- Get steamID for tracking
	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return false
	end

	-- Skip if already marked as cheater
	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	-- Initialize tracking data
	initPlayerData(steamID)
	local data = playerSimTimeData[steamID]

	-- Get current simulation time
	local currentSimTime = player:GetSimulationTime()
	if not currentSimTime then
		return false
	end

	-- Need previous simtime for comparison
	if not data.lastSimTime then
		data.lastSimTime = currentSimTime
		return false
	end

	-- Calculate delta
	local delta = currentSimTime - data.lastSimTime

	-- Skip if rewinding (demo playback or local player lag compensation)
	if delta == 0 then
		return false
	end

	-- Convert to ticks
	local deltaTicks = timeToTicks(delta)

	-- Detect excessive tick delta (choking packets)
	if deltaTicks >= MAX_TICK_DELTA then
		Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

		if G.Menu.Advanced.debug then
			print(string.format(
				"[FakeLag] %s - Tick delta: %d (threshold: %d)",
				player:GetName(),
				deltaTicks,
				MAX_TICK_DELTA
			))
		end

		data.lastSimTime = currentSimTime
		return true
	end

	-- Update last simtime
	data.lastSimTime = currentSimTime
	return false
end

return FakeLag

end)
__bundle_register("Cheater_Detection.Detection Methods.Duck_Speed", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Cheater Detection - Duck Speed Detection ]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local DuckSpeed = {}

--[[ Configuration ]]
local DETECTION_NAME = "Duck_Speed"
local EVIDENCE_WEIGHT = 20 -- Higher weight - movement exploit
local VIOLATION_TICKS_REQUIRED = 66 -- 1 second of violation
local DUCK_SPEED_MULTIPLIER = 0.66 -- TF2 duck speed penalty
local FULLY_CROUCHED_VIEW_OFFSET = 45 -- View offset Z when fully crouched

-- Per-player state tracking
local playerDuckData = {}

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

local function initPlayerData(steamID)
	if not playerDuckData[steamID] then
		playerDuckData[steamID] = {
			violationTicks = 0,
			lastDecayTick = 0,
		}
	end
end

--[[ Public Functions ]]
function DuckSpeed.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.DuckSpeed then
		return false
	end

	-- Validate player
	if not validatePlayer(player) then
		return false
	end

	-- Get steamID for tracking
	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return false
	end

	-- Skip if already marked as cheater
	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	-- Initialize tracking data
	initPlayerData(steamID)
	local data = playerDuckData[steamID]

	-- Get raw entity for prop access
	local entity = player:GetRawEntity()
	if not entity then
		return false
	end

	-- Check flags
	local flags = player:GetPropInt("m_fFlags")
	local onGround = (flags & FL_ONGROUND) ~= 0
	local ducking = (flags & FL_DUCKING) ~= 0

	-- Only check when on ground and ducking
	if not (onGround and ducking) then
		data.violationTicks = 0
		return false
	end

	-- Get max speed and current velocity
	local maxSpeed = entity:GetPropFloat("m_flMaxspeed")
	local velocity = entity:EstimateAbsVelocity()

	if not maxSpeed or not velocity then
		return false
	end

	local currentSpeed = velocity:Length()
	local maxDuckSpeed = maxSpeed * DUCK_SPEED_MULTIPLIER

	-- Check if exceeding duck speed limit
	if currentSpeed >= maxDuckSpeed then
		-- Verify fully crouched via view offset
		local viewOffset = player:GetViewOffset()
		if viewOffset and math.floor(viewOffset.z) == FULLY_CROUCHED_VIEW_OFFSET then
			data.violationTicks = data.violationTicks + 1

			-- Require sustained violation (1 second = 66 ticks)
			if data.violationTicks >= VIOLATION_TICKS_REQUIRED then
				Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

				if G.Menu.Advanced.debug then
					print(
						string.format(
							"[DuckSpeed] %s - Speed: %.1f / Max: %.1f (%.0f%% over limit)",
							player:GetName(),
							currentSpeed,
							maxDuckSpeed,
							(currentSpeed / maxDuckSpeed - 1) * 100
						)
					)
				end

				-- Reset counter
				data.violationTicks = 0
				return true
			end
		end
	else
		-- Reset if not violating
		data.violationTicks = 0
	end

	return false
end

return DuckSpeed

end)
__bundle_register("Cheater_Detection.Detection Methods.bhop", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Cheater Detection - Bunny Hop Detection ]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")

--[[ Module Declaration ]]
local Bhop = {}

--[[ Configuration ]]
local DETECTION_NAME = "bhop"
local EVIDENCE_WEIGHT_BASE = 5
local DECAY_AMOUNT = 2.0 -- Weight to remove on failed bhop

-- Per-player state tracking
local playerBhopData = {}

local function initPlayerData(steamID)
	if not playerBhopData[steamID] then
		playerBhopData[steamID] = {
			lastOnGround = true, -- Track last ground state
			lastVelocityZ = 0, -- Track last velocity for jump detection
		}
	end
end

--[[ Public Functions ]]
function Bhop.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.Bhop then
		return false
	end

	-- Validate player
	if not Common.IsValidPlayer(player, true, false) then
		return false
	end

	-- Get steamID for tracking
	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return false
	end

	-- Skip if already marked as cheater
	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	-- Initialize tracking data
	initPlayerData(steamID)
	local data = playerBhopData[steamID]

	-- Get raw entity for velocity access
	local entity = player:GetRawEntity()
	if not entity then
		return false
	end

	-- Get velocity for jump detection
	local velocity = entity:EstimateAbsVelocity()
	if not velocity then
		return false
	end

	-- Check ground state (matches old CheckBhop logic)
	local flags = player:GetPropInt("m_fFlags")
	local onGround = (flags & FL_ONGROUND) ~= 0

	if onGround then
		-- Player on ground - reset bhop counter and apply decay if they were airborne before
		if not data.lastOnGround then
			Evidence.ApplyDecayForMethod(steamID, DETECTION_NAME, DECAY_AMOUNT)

			if G.Menu.Advanced.debug then
				print(string.format("[Bhop] %s - Landed -%.1f evidence", player:GetName(), DECAY_AMOUNT))
			end
		end
		data.lastOnGround = true
	else
		-- Player in air - check if they jumped (velocity increased AND exact jump values)
		if data.lastOnGround and data.lastVelocityZ < velocity.z and (velocity.z == 271 or velocity.z == 277) then
			-- Jump detected - add weight immediately
			Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT_BASE)

			if G.Menu.Advanced.debug then
				print(
					string.format(
						"[Bhop] %s - Bhop detected (vel.z: %.0f) +%.1f evidence",
						player:GetName(),
						velocity.z,
						EVIDENCE_WEIGHT_BASE
					)
				)
			end

			return true
		end
		data.lastOnGround = false
	end

	-- Store current velocity for next tick comparison
	data.lastVelocityZ = velocity.z

	return false
end

return Bhop

end)
__bundle_register("Cheater_Detection.Detection Methods.anti_aim", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Cheater Detection - Anti-Aim Detection ]]

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Logger = require("Cheater_Detection.Utils.Logger")

--[[ Module Declaration ]]
local AntiAim = {}

--[[ Configuration ]]
local DETECTION_NAME = "anti_aim"
local EVIDENCE_WEIGHT = 25 -- High weight - this is plain cheating
local MIN_DETECTIONS = 1 -- Instant evidence on first detection

-- Invalid pitch thresholds
local INVALID_PITCH_MIN = -90
local INVALID_PITCH_MAX = 90
local EXACT_PITCH_SUSPECT = 89.000 -- Common rage AA value

--[[ Helper Functions ]]
local function validatePlayer(player)
	if not player or not player:IsValid() or not player:IsAlive() then
		return false
	end
	return true
end

--[[ Public Functions ]]
function AntiAim.Check(player)
	-- Skip if detection disabled in menu
	if not G.Menu.Advanced.AntyAim then
		return false
	end

	-- Validate player
	if not validatePlayer(player) then
		return false
	end

	-- Get steamID for tracking
	local steamID = Common.GetSteamID64(player)
	if not steamID then
		return false
	end

	-- Skip if already marked as cheater
	if Evidence.IsMarkedCheater(steamID) then
		return false
	end

	-- Get eye angles
	local angles = player:GetEyeAngles()
	if not angles then
		return false
	end

	local detected = false
	local detectionReason = nil
	-- Enhanced detection with cheat fingerprinting
	if angles.pitch > 89.4 or angles.pitch < -89.4 then
		-- Specific cheat pattern detection
		if angles.pitch % 3256 == 0 then
			detected = true
			detectionReason = "LBOX AA (Center)"
		elseif angles.pitch % 271 == 0 then
			detected = true
			detectionReason = "RIJIN AA"
		elseif angles.pitch % 90 == 0 then
			detected = true
			detectionReason = "AA (Up/Down)"
		else
			-- Generic invalid pitch
			detected = true
			detectionReason = "Anti-Aim"
		end
	end

	-- Add evidence immediately (exploits = instant flag)
	if detected then
		Evidence.AddEvidence(steamID, DETECTION_NAME, EVIDENCE_WEIGHT)

		if G.Menu.Advanced.debug then
			print(
				string.format(
					"[AntiAim] %s - Detected %s (pitch: %.3f) +%.1f evidence",
					player:GetName(),
					detectionReason,
					angles.pitch,
					EVIDENCE_WEIGHT
				)
			)
		end

		Logger.Info(
			"AntiAim",
			string.format("%s detected using %s (pitch: %.3f)", player:GetName(), detectionReason, angles.pitch)
		)
		return true
	end

	return false
end

return AntiAim

end)
__bundle_register("Cheater_Detection.Database.SteamHistory", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ SteamHistory.lua
	Performs SteamHistory API lookups for players in the current match.
	Scans all players once when enabled, then scans newcomers as they join.
]]

local SteamHistory = {}

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local FastPlayers = require("Cheater_Detection.Utils.FastPlayers")
local Database = require("Cheater_Detection.Database.Database")
local JoinNotifications = require("Cheater_Detection.Misc.JoinNotifications")
local Json = Common.Json

--[[ Constants ]]
local KEYWORDS = {
	"[stac]",
	"smac ",
	"cheat",
	"hack",
	"aimbot",
}

local API_TEMPLATE = "https://steamhistory.net/api/sourcebans?key=%s&shouldkey=0&steamids=%s"
local MAX_BATCH = 25
local MIN_INTERVAL = 1.5 -- seconds between batches to avoid spamming the API

--[[ Internal State ]]
local state = {
	enabled = false,
	initialQueued = false,
	pending = {},
	scanned = {},
	lastBatchTime = 0,
	scanning = false,
	apiKey = nil,
}

--[[ Helper Functions ]]
local function getConfig()
	local menu = G.Menu
	return menu and menu.Misc and menu.Misc.SteamHistory or nil
end

local function normalizeSteamID64(rawID)
	if not rawID then
		return nil
	end

	local steamID = tostring(rawID)
	if type(steamID) ~= "string" or not steamID:match("^7656119%d+$") then
		return nil
	end

	return steamID
end

local function getScoreboardName(steamID)
	local maxClients = (globals and globals.MaxClients and globals.MaxClients()) or 32
	for i = 1, maxClients do
		local info = client.GetPlayerInfo(i)
		if info and info.SteamID then
			local infoSteamID = info.SteamID
			local converted = nil
			if infoSteamID:match("^7656119%d+$") then
				converted = normalizeSteamID64(infoSteamID)
			elseif infoSteamID:match("%[U:1:%d+%]") then
				converted = normalizeSteamID64(Common.FromSteamid3To64(infoSteamID))
			end
			if converted == steamID then
				return info.Name
			end
		end
	end
	return nil
end

local function getPlayerNameBySteamID(steamID)
	local scoreboardName = getScoreboardName(steamID)
	if scoreboardName and scoreboardName ~= "" then
		return scoreboardName
	end
	for _, player in ipairs(FastPlayers.GetAll(false)) do
		local id = normalizeSteamID64(player:GetSteamID64())
		if id == steamID then
			local raw = player.GetRawEntity and player:GetRawEntity() or nil
			if raw and raw:IsValid() and raw.GetName then
				local rawName = raw:GetName()
				if type(rawName) == "string" and rawName ~= "" then
					return rawName
				end
			end
		end
	end
	return nil
end

local function printInfo(color, text)
	printc(color[1], color[2], color[3], color[4], text)
end

local function queueSteamID(steamID, context)
	if not steamID then
		return false
	end
	steamID = normalizeSteamID64(steamID)
	if not steamID then
		return false
	end
	if state.scanned[steamID] or state.pending[steamID] then
		return false
	end
	state.pending[steamID] = {
		name = context and context.name or nil,
		queuedAt = globals.RealTime(),
	}
	return true
end

local function resetState(clearScanned)
	state.pending = {}
	if clearScanned then
		state.scanned = {}
	end
	state.initialQueued = false
	state.lastBatchTime = 0
	state.scanning = false
end

local function queueCurrentPlayers()
	local queued = 0
	local maxClients = (globals and globals.MaxClients and globals.MaxClients()) or 32
	for i = 1, maxClients do
		local info = client.GetPlayerInfo(i)
		if info and info.SteamID then
			local steamID64 = nil
			local steamIDStr = tostring(info.SteamID)
			if steamIDStr:match("^7656119%d+$") then
				steamID64 = normalizeSteamID64(steamIDStr)
			elseif steamIDStr:match("%[U:1:%d+%]") then
				steamID64 = normalizeSteamID64(Common.FromSteamid3To64(steamIDStr))
			end
			if steamID64 then
				local contextName = info.Name
				if queueSteamID(steamID64, { name = contextName }) then
					queued = queued + 1
				end
			end
		end
	end

	if queued > 0 then
		printInfo(
			{ 0, 200, 255, 255 },
			string.format("[SteamHistory] Queued %d player%s for scanning", queued, queued == 1 and "" or "s")
		)
	end
end

local function popBatch()
	local ids = {}
	local contexts = {}
	for steamID, ctx in pairs(state.pending) do
		ids[#ids + 1] = steamID
		contexts[steamID] = ctx
		state.pending[steamID] = nil
		if #ids >= MAX_BATCH then
			break
		end
	end
	return ids, contexts
end

local function matchesKeyword(reason)
	if not reason or reason == "" then
		return false
	end
	local lower = reason:lower()
	for _, keyword in ipairs(KEYWORDS) do
		if lower:find(keyword, 1, true) then
			return true
		end
	end
	return false
end

local function flagPlayer(steamID, context, entry)
	local reason = entry.BanReason or "Unknown reason"
	local name = context and context.name
		or entry.PersonaName
		or getPlayerNameBySteamID(steamID)
		or string.format("Player %s", steamID)
	printInfo({ 255, 120, 120, 255 }, string.format("[SteamHistory] %s flagged (%s)", name, reason))

	local formattedReason = string.format("SteamHistory (%s)", reason)
	-- Update database and player priority for visibility
	Database.UpsertCheater(steamID, {
		name = name,
		reason = formattedReason,
	})
	Database.SetPriority(steamID, 10, false)

	JoinNotifications.SendCheaterAlert({
		name = name,
		reason = formattedReason,
		tail = string.format("is in the server (Suspected of: %s)", formattedReason),
		allowParty = false,
	})
end

local function handleBatchResponse(ids, contexts, responseTable)
	local responseMap = {}
	if type(responseTable) == "table" then
		if responseTable.response and type(responseTable.response) == "table" then
			responseTable = responseTable.response
		end

		for _, entry in pairs(responseTable) do
			local steamID = normalizeSteamID64(entry.SteamID or entry.steamid or entry.id)
			if steamID then
				responseMap[steamID] = entry
			end
		end
	end

	local flagged = 0
	for _, steamID in ipairs(ids) do
		if type(steamID) ~= "string" then
			steamID = tostring(steamID)
		end
		state.scanned[steamID] = true
		local entry = responseMap[steamID]
		local context = contexts[steamID] or {}
		if entry and matchesKeyword(entry.BanReason or "") then
			flagged = flagged + 1
			flagPlayer(steamID, context, entry)
		end
	end

	local passed = #ids - flagged
	printInfo(
		flagged > 0 and { 255, 200, 120, 255 } or { 0, 200, 255, 255 },
		string.format("[SteamHistory] Batch: %d flagged, %d clean", flagged, passed)
	)
end

local function requestBatch()
	local cfg = getConfig()
	if not cfg or not cfg.ApiKey or cfg.ApiKey == "" then
		return
	end

	local ids, contexts = popBatch()
	if #ids == 0 then
		return
	end

	state.scanning = true
	state.lastBatchTime = globals.RealTime()

	local url = string.format(API_TEMPLATE, cfg.ApiKey, table.concat(ids, ","))
	local success, body = pcall(http.Get, url)
	if not success or type(body) ~= "string" or body == "" then
		printInfo({ 255, 100, 100, 255 }, string.format("[SteamHistory] Request failed: %s", tostring(body)))
		-- Requeue the batch for another attempt later
		if contexts then
			for steamID, ctx in pairs(contexts) do
				state.pending[steamID] = ctx
			end
		end
		state.scanning = false
		return
	end

	local ok, decoded = pcall(Json.decode, body)
	if not ok or type(decoded) ~= "table" then
		printInfo({ 255, 100, 100, 255 }, "[SteamHistory] Failed to decode SteamHistory response")
		if contexts then
			for steamID, ctx in pairs(contexts) do
				state.pending[steamID] = ctx
			end
		end
		state.scanning = false
		return
	end

	handleBatchResponse(ids, contexts, decoded)
	state.scanning = false
end

local function refreshEnabled()
	local cfg = getConfig()
	local apiKey = cfg and cfg.ApiKey or nil
	apiKey = apiKey ~= "" and apiKey or nil

	if apiKey ~= state.apiKey then
		state.apiKey = apiKey
		resetState(true)
	end

	local enabled = cfg and cfg.Enable and apiKey ~= nil
	if enabled ~= state.enabled then
		state.enabled = enabled
		if enabled then
			printInfo({ 0, 200, 255, 255 }, "[SteamHistory] SteamHistory scanning enabled")
		else
			printInfo({ 200, 200, 200, 255 }, "[SteamHistory] SteamHistory scanning disabled")
			resetState(false)
		end
	end

	return state.enabled
end

--[[ Event Handlers ]]
local function onPlayerConnect(event)
	if event:GetName() ~= "player_connect" then
		return
	end

	if not state.enabled then
		return
	end

	local networkid = event:GetString("networkid")
	local steamID = normalizeSteamID64(Common.FromSteamid3To64(networkid))
	if not steamID then
		return
	end

	queueSteamID(steamID, { name = event:GetString("name") })
end

local function onGameEvent(event)
	local name = event:GetName()
	if name == "player_connect" then
		onPlayerConnect(event)
	elseif name == "game_newmap" or name == "teamplay_round_start" then
		resetState(true)
	end
end

local function onCreateMove()
	if not refreshEnabled() then
		return
	end

	if not state.initialQueued then
		queueCurrentPlayers()
		state.initialQueued = true
	end

	if state.scanning then
		return
	end

	if next(state.pending) and globals.RealTime() - state.lastBatchTime >= MIN_INTERVAL then
		requestBatch()
	end
end

--[[ Public API ]]
function SteamHistory.OnApiKeyUpdated()
	resetState(true)
	refreshEnabled()
end

function SteamHistory.QueueRescan()
	resetState(true)
end

--[[ Callback Registration ]]
callbacks.Unregister("FireGameEvent", "CD_SteamHistory_Events")
callbacks.Register("FireGameEvent", "CD_SteamHistory_Events", onGameEvent)

callbacks.Unregister("CreateMove", "CD_SteamHistory_OnCreateMove")
callbacks.Register("CreateMove", "CD_SteamHistory_OnCreateMove", onCreateMove)

return SteamHistory

end)
__bundle_register("Cheater_Detection.Misc.JoinNotifications", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Join/Leave Notifications for Cheaters and Valve Employees ]]

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Database = require("Cheater_Detection.Database.Database")
local Sources = require("Cheater_Detection.Database.Sources")
local Common = require("Cheater_Detection.Utils.Common")

--[[ Module Declaration ]]
local JoinNotifications = {}

--[[ State ]]
local hasValidatedOnLoad = false

local function NormalizeSteamID64(rawID)
	if not rawID then
		return nil
	end

	local steamID = tostring(rawID)
	if steamID:match("^7656119%d+$") and #steamID == 17 then
		return steamID
	end

	return nil
end

--[[ Helper Functions ]]

local function escapeForCommand(text)
	return text and text:gsub("\\", "\\\\"):gsub('"', '\\"') or ""
end

local function SendPartyChatMessage(message)
	if not message or message == "" then
		return
	end
	client.Command(string.format('say_party "%s"', escapeForCommand(message)), true)
end

-- message configuration table expects:
-- { label = string, labelColor = string (color code), plainPrefix = string, name = string, tail = string, allowParty = boolean }
local function SendAlert(outputConfig, messageConfig)
	if not outputConfig or not messageConfig then
		return
	end

	local label = messageConfig.label or "CHEATER"
	local labelColor = messageConfig.labelColor or "\x07FFFFFF"
	local plainPrefix = messageConfig.plainPrefix or "Player"
	local name = messageConfig.name or "Unknown"
	local tail = messageConfig.tail or ""
	local allowParty = messageConfig.allowParty ~= false

	local tailText = tail ~= "" and (" " .. tail) or ""

	local messagePlain = string.format("%s %s%s", plainPrefix, name, tailText)
	local messageBracketed = string.format("[CD] [%s] %s%s", label, name, tailText)
	local messageColored =
		string.format("\x073EFF3E[CD]\x01 %s[%s]\x01 \x03%s\x01%s", labelColor, label, name, tailText)

	if outputConfig.Console then
		print(messageBracketed)
	end

	local sentToExternalChannel = false
	local allowParty = messageConfig.allowParty
	if allowParty == nil then
		allowParty = true
	end

	if allowParty and outputConfig.PartyChat then
		SendPartyChatMessage(messageColored)
		sentToExternalChannel = true
	end

	if outputConfig.ClientChat and not sentToExternalChannel then
		if not client.ChatPrintf(messageColored) then
			print("[CD] Failed to send client chat message")
		end
	elseif not outputConfig.PublicChat and not outputConfig.ClientChat then
		-- Ensure local feedback even if only console output was requested
		if not client.ChatPrintf(messageColored) then
			print("[CD] Failed to send fallback client chat message")
		end
	end
end

local function GetEffectiveOutput(defaultOutput, overrideOutput, useOverride)
	if useOverride and overrideOutput then
		return overrideOutput
	end
	return defaultOutput
end

local function GetJoinNotificationsConfig()
	local config = G.Menu and G.Menu.Misc and G.Menu.Misc.JoinNotifications
	if not config or not config.Enable then
		return nil
	end

	if type(config.ValveAutoDisconnect) ~= "boolean" then
		return nil
	end

	return config
end

local function DispatchCheaterAlert(config, params)
	if not config or not config.CheckCheater then
		return false
	end

	local reason = params.reason or "Unknown"
	local tail = params.tail or string.format("is in the server (Suspected of: %s)", reason)
	local allowParty = params.allowParty
	if allowParty == nil then
		allowParty = false
	end

	local output = GetEffectiveOutput(config.DefaultOutput, config.CheaterOverride, config.UseCheaterOverride)

	SendAlert(output, {
		label = "CHEATER",
		labelColor = "\x07FF0000",
		plainPrefix = params.plainPrefix or "Cheater",
		name = params.name or "Unknown",
		tail = tail,
		allowParty = allowParty,
	})

	return true
end

local function DispatchValveAlert(config, params)
	if not config or not config.CheckValve then
		return false
	end

	local tail = params.tail or "is in the server"
	local allowParty = params.allowParty
	if allowParty == nil then
		allowParty = false
	end

	local output = GetEffectiveOutput(config.DefaultOutput, config.ValveOverride, config.UseValveOverride)
	SendAlert(output, {
		label = "VALVE",
		labelColor = "\x078650AC",
		plainPrefix = params.plainPrefix or "Valve employee",
		name = params.name or "Unknown",
		tail = tail,
		allowParty = allowParty,
	})

	return true
end

function JoinNotifications.SendCheaterAlert(params)
	local config = GetJoinNotificationsConfig()
	if not config then
		return false
	end

	return DispatchCheaterAlert(config, params or {})
end

function JoinNotifications.SendValveAlert(params)
	local config = GetJoinNotificationsConfig()
	if not config then
		return false
	end

	return DispatchValveAlert(config, params or {})
end

-- Check all players currently in the game for Valve employees and cheaters
-- If Valve found and auto-disconnect enabled, leave server
local function ValidateAllPlayers()
	local config = GetJoinNotificationsConfig()
	if not config then
		return -- Config not fully loaded yet
	end

	local players = entities.FindByClass("CTFPlayer")
	for _, player in ipairs(players) do
		if player and player:IsValid() then
			local steamID64 = NormalizeSteamID64(Common.GetSteamID64(player))
			if steamID64 then
				-- Check Valve employee first (higher priority)
				if config.CheckValve and Sources.IsValveEmployee(steamID64) then
					local alertSent = DispatchValveAlert(config, {
						name = player:GetName(),
						tail = config.ValveAutoDisconnect and "is in the server - Leaving game" or "is in the server",
						allowParty = false,
					})
					if alertSent and config.ValveAutoDisconnect then
						client.Command("disconnect", true)
						return
					end
				-- Check if cheater in database
				elseif config.CheckCheater then
					local cheaterData = Database.GetCheater(steamID64)
					if cheaterData then
						DispatchCheaterAlert(config, {
							name = player:GetName(),
							reason = cheaterData.Reason,
							allowParty = false,
						})
					end
				end
			end
		end
	end
end

--[[ Event Handlers ]]

-- Handle player connect event
local function OnPlayerConnect(event)
	if event:GetName() ~= "player_connect" then
		return
	end

	local config = GetJoinNotificationsConfig()
	if not config then
		return
	end

	-- Get player info from event
	local name = event:GetString("name")
	local networkid = event:GetString("networkid")

	-- Extract SteamID64 from networkid (format: [U:1:XXXXXXXX])
	local steamID64 = NormalizeSteamID64(Common.FromSteamid3To64(networkid))
	if not steamID64 then
		return
	end

	-- Check if Valve employee (higher priority)
	if config.CheckValve and Sources.IsValveEmployee(steamID64) then
		local tail = config.ValveAutoDisconnect and "joined - Leaving game" or "joined"
		local alertSent = DispatchValveAlert(config, {
			name = name,
			tail = tail,
			allowParty = false,
		})
		if alertSent and config.ValveAutoDisconnect then
			client.Command("disconnect", true)
		end
		return
	end

	-- Check if cheater in database
	if config.CheckCheater then
		local cheaterData = Database.GetCheater(steamID64)
		if cheaterData then
			local reason = cheaterData.Reason or "Unknown"
			DispatchCheaterAlert(config, {
				name = name,
				reason = reason,
				tail = string.format("joined (Suspected of: %s)", reason),
				allowParty = false,
			})
		end
	end
end

-- Handle player disconnect event
local function OnPlayerDisconnect(event)
	if event:GetName() ~= "player_disconnect" then
		return
	end

	local config = GetJoinNotificationsConfig()
	if not config then
		return
	end

	-- Get player info from event
	local name = event:GetString("name")
	local networkid = event:GetString("networkid")

	-- Extract SteamID64 from networkid (format: [U:1:XXXXXXXX])
	local steamID64 = NormalizeSteamID64(Common.FromSteamid3To64(networkid))
	if not steamID64 then
		return
	end

	-- Don't show disconnect messages for Valve employees (we left the game)
	-- Only check cheaters
	if config.CheckCheater then
		local cheaterData = Database.GetCheater(steamID64)
		if cheaterData then
			local reason = cheaterData.Reason or "Unknown"
			DispatchCheaterAlert(config, {
				name = name,
				reason = reason,
				tail = string.format("left (Suspected of: %s)", reason),
			})
		end
	end
end

-- Master event handler for both connect and disconnect
local function OnGameEvent(event)
	local eventName = event:GetName()

	if eventName == "player_connect" then
		OnPlayerConnect(event)
	elseif eventName == "player_disconnect" then
		OnPlayerDisconnect(event)
	end
end

--[[ CreateMove Callback for Initial Validation ]]
local function OnCreateMove()
	-- Run validation once on first tick after config is loaded
	if not hasValidatedOnLoad then
		local config = G.Menu and G.Menu.Misc and G.Menu.Misc.JoinNotifications
		-- Check if config is loaded (has boolean ValveAutoDisconnect)
		if config and type(config.ValveAutoDisconnect) == "boolean" then
			ValidateAllPlayers()
			hasValidatedOnLoad = true
			-- Unregister after first run
			callbacks.Unregister("CreateMove", "CD_JoinNotifications_Init")
		end
	end
end

--[[ Callback Registration ]]
callbacks.Unregister("FireGameEvent", "CD_JoinNotifications")
callbacks.Register("FireGameEvent", "CD_JoinNotifications", OnGameEvent)

-- Register CreateMove to validate existing players on first tick
callbacks.Unregister("CreateMove", "CD_JoinNotifications_Init")
callbacks.Register("CreateMove", "CD_JoinNotifications_Init", OnCreateMove)

return JoinNotifications

end)
__bundle_register("Cheater_Detection.Database.Sources", function(require, _LOADED, __bundle_register, __bundle_modules)
-- Source definitions with safer processing options

--[[ Imports ]]
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")
-- [[ Imported by: Fetcher.lua ]]

--[[ Module Declaration ]]
local Sources = {}

--[[ Local Variables/Utilities ]]
-- List of available sources
Sources.List = {
	{
		name = "d3fc0n6 Cheater List",
		url = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
		cause = "Cheater Friend",
		parser = "raw",
	},
	{
		name = "d3fc0n6 Tacobot List",
		url = "https://raw.githubusercontent.com/d3fc0n6/TacobotList/master/64ids",
		cause = "Cheater Tacobot",
		parser = "raw",
	},
	{
		name = "d3fc0n6 Group List",
		url = "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/Group/64ids",
		cause = "Suspected (Group Member)",
		parser = "raw",
	},
	{
		name = "Sleepy List RGL",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.rgl-gg.json",
		cause = "Sleepy RGL",
		parser = "tf2db",
	},
	{
		name = "bot detector (Official)",
		url = "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json",
		cause = "Bot (bot detector)",
		parser = "tf2db", -- Use tf2db parser for this JSON source
	},
	{
		name = "MegaScaterbomb (Scraped)",
		url = "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/refs/heads/main/playerlist.megacheaterdb.json",
		cause = "Cheater (MegaScaterbomb)",
		parser = "tf2db", -- Use tf2db parser for this JSON source
	},
	{
		name = "qfoxb Player List",
		url = "https://raw.githubusercontent.com/qfoxb/tf2bd-lists/main/playerlist.qfoxb.json",
		cause = "TF2BD Community (qfoxb)",
		parser = "tf2db",
	},
	{
		name = "joekiller Player List",
		url = "https://raw.githubusercontent.com/joekiller/joekiller-list/main/playerlist.joekiller.json",
		cause = "TF2BD Community (joekiller)",
		parser = "tf2db",
	},
}

--[[ Helper/Private Functions (None) ]]

--[[ Public Module Functions ]]
-- Function to add a custom source
function Sources.AddSource(name, url, cause, parser)
	if not name or not url or not cause or not parser then
		print("[Database Fetcher] Error: Missing required fields for new source")
		return false
	end

	if parser ~= "raw" and parser ~= "tf2db" then
		print("[Database Fetcher] Error: Invalid parser type: " .. parser)
		return false
	end

	table.insert(Sources.List, {
		name = name,
		url = url,
		cause = cause,
		parser = parser,
	})

	print("[Database Fetcher] Added new source: " .. name)
	return true
end

-- Utility function to enable/disable sources (e.g. for testing)
function Sources.DisableSource(sourceIndex)
	if sourceIndex < 1 or sourceIndex > #Sources.List then
		print("[Database Fetcher] Invalid source index: " .. tostring(sourceIndex))
		return false
	end

	local source = Sources.List[sourceIndex]
	source.__disabled = true
	print("[Database Fetcher] Disabled source: " .. source.name)
	return true
end

-- Get active sources (not disabled)
function Sources.GetActiveSources()
	local active = {}
	for i, source in ipairs(Sources.List) do
		if not source.__disabled then
			table.insert(active, source)
		end
	end
	return active
end

-- Get Valve employee list from local database
function Sources.GetValveEmployees()
	return ValveEmployees.List
end

-- Check if SteamID is Valve employee
function Sources.IsValveEmployee(steamID)
	return ValveEmployees.IsValveEmployee(steamID)
end

--[[ Self-Initialization (None) ]]

--[[ Callback Registration (None) ]]

return Sources

end)
__bundle_register("Cheater_Detection.Database.ValveEmployees", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Valve Employee SteamID64 Database ]]
-- Source: https://steamdb.info/badge/11 (Valve Employee Badge)
-- Total: 20 confirmed (640 total available)

local ValveEmployees = {}

-- SteamID64 list of confirmed Valve employees
ValveEmployees.List = {
	["76561197960265729"] = "Valve Employee",
	["76561197960265730"] = "Valve Employee",
	["76561197960265731"] = "Valve Employee",
	["76561197960265733"] = "Valve Employee",
	["76561197960265738"] = "Valve Employee",
	["76561197960265740"] = "Valve Employee",
	["76561197960265743"] = "Valve Employee",
	["76561197960265749"] = "Valve Employee",
	["76561197960265754"] = "Valve Employee",
	["76561197960265838"] = "Valve Employee",
	["76561197960268402"] = "Valve Employee",
	["76561197960277670"] = "Valve Employee",
	["76561197960303386"] = "Valve Employee",
	["76561197960405535"] = "Valve Employee",
	["76561197960423941"] = "Valve Employee",
	["76561197960434622"] = "Valve Employee",
	["76561197960435530"] = "Valve Employee",
	["76561197960549564"] = "Valve Employee",
	["76561197960563532"] = "Valve Employee",
	["76561197960860649"] = "Valve Employee",
	["76561197962146232"] = "Valve Employee",
	["76561197962313932"] = "Valve Employee",
	["76561197962413930"] = "Valve Employee",
	["76561197962783665"] = "Valve Employee",
	["76561197962844216"] = "Valve Employee",
	["76561197963156385"] = "Valve Employee",
	["76561197964165126"] = "Valve Employee",
	["76561197964279229"] = "Valve Employee",
	["76561197964620212"] = "Valve Employee",
	["76561197966460010"] = "Valve Employee",
	["76561197966465612"] = "Valve Employee",
	["76561197967144365"] = "Valve Employee",
	["76561197967346751"] = "Valve Employee",
	["76561197967713982"] = "Valve Employee",
	["76561197968151197"] = "Valve Employee",
	["76561197968282875"] = "Valve Employee",
	["76561197968376527"] = "Valve Employee",
	["76561197968459473"] = "Valve Employee",
	["76561197968575517"] = "Valve Employee",
	["76561197969262523"] = "Valve Employee",
	["76561197969266938"] = "Valve Employee",
	["76561197969321754"] = "Valve Employee",
	["76561197969400141"] = "Valve Employee",
	["76561197969518075"] = "Valve Employee",
	["76561197970285523"] = "Valve Employee",
	["76561197970323416"] = "Valve Employee",
	["76561197970530062"] = "Valve Employee",
	["76561197970565175"] = "Valve Employee",
	["76561197970892150"] = "Valve Employee",
	["76561197970968871"] = "Valve Employee",
	["76561197971025345"] = "Valve Employee",
	["76561197971049296"] = "Valve Employee",
	["76561197971400048"] = "Valve Employee",
	["76561197972196250"] = "Valve Employee",
	["76561197972291076"] = "Valve Employee",
	["76561197972370889"] = "Valve Employee",
	["76561197972491988"] = "Valve Employee",
	["76561197972495328"] = "Valve Employee",
	["76561197972755855"] = "Valve Employee",
	["76561197974593417"] = "Valve Employee",
	["76561197975914763"] = "Valve Employee",
	["76561197978022608"] = "Valve Employee",
	["76561197978027217"] = "Valve Employee",
	["76561197978236369"] = "Valve Employee",
	["76561197978290786"] = "Valve Employee",
	["76561197980258575"] = "Valve Employee",
	["76561197980482295"] = "Valve Employee",
	["76561197980632230"] = "Valve Employee",
	["76561197980865448"] = "Valve Employee",
	["76561197981291930"] = "Valve Employee",
	["76561197982227246"] = "Valve Employee",
	["76561197982261816"] = "Valve Employee",
	["76561197983311154"] = "Valve Employee",
	["76561197984212648"] = "Valve Employee",
	["76561197984437106"] = "Valve Employee",
	["76561197984447638"] = "Valve Employee",
	["76561197984751122"] = "Valve Employee",
	["76561197984929530"] = "Valve Employee",
	["76561197985607672"] = "Valve Employee",
	["76561197985627266"] = "Valve Employee",
	["76561197985993448"] = "Valve Employee",
	["76561197988745128"] = "Valve Employee",
	["76561197989577350"] = "Valve Employee",
	["76561197989728462"] = "Valve Employee",
	["76561197989808853"] = "Valve Employee",
	["76561197991390878"] = "Valve Employee",
	["76561197991564203"] = "Valve Employee",
	["76561197991899002"] = "Valve Employee",
	["76561197992169608"] = "Valve Employee",
	["76561197992219796"] = "Valve Employee",
	["76561197992637080"] = "Valve Employee",
	["76561197992681877"] = "Valve Employee",
	["76561197993032363"] = "Valve Employee",
	["76561197993404877"] = "Valve Employee",
	["76561197993596757"] = "Valve Employee",
	["76561197994632741"] = "Valve Employee",
	["76561197994871291"] = "Valve Employee",
	["76561197995010660"] = "Valve Employee",
	["76561197995776067"] = "Valve Employee",
	["76561197996448297"] = "Valve Employee",
	["76561197998511283"] = "Valve Employee",
	["76561197999000345"] = "Valve Employee",
	["76561197999858467"] = "Valve Employee",
	["76561198000613142"] = "Valve Employee",
	["76561198000613320"] = "Valve Employee",
	["76561198001549544"] = "Valve Employee",
	["76561198002413878"] = "Valve Employee",
	["76561198002423550"] = "Valve Employee",
	["76561198003204775"] = "Valve Employee",
	["76561198003417858"] = "Valve Employee",
	["76561198005028443"] = "Valve Employee",
	["76561198005121830"] = "Valve Employee",
	["76561198005342326"] = "Valve Employee",
	["76561198007657496"] = "Valve Employee",
	["76561198007695232"] = "Valve Employee",
	["76561198007696304"] = "Valve Employee",
	["76561198007705538"] = "Valve Employee",
	["76561198008217263"] = "Valve Employee",
	["76561198010062752"] = "Valve Employee",
	["76561198011062689"] = "Valve Employee",
	["76561198011361633"] = "Valve Employee",
	["76561198012148855"] = "Valve Employee",
	["76561198014182596"] = "Valve Employee",
	["76561198014646169"] = "Valve Employee",
	["76561198015158492"] = "Valve Employee",
	["76561198015260835"] = "Valve Employee",
	["76561198018064800"] = "Valve Employee",
	["76561198024119021"] = "Valve Employee",
	["76561198024119077"] = "Valve Employee",
	["76561198024119145"] = "Valve Employee",
	["76561198024119167"] = "Valve Employee",
	["76561198024119209"] = "Valve Employee",
	["76561198024119233"] = "Valve Employee",
	["76561198024119271"] = "Valve Employee",
	["76561198024119297"] = "Valve Employee",
	["76561198024149438"] = "Valve Employee",
	["76561198024187698"] = "Valve Employee",
	["76561198024402255"] = "Valve Employee",
	["76561198025064924"] = "Valve Employee",
	["76561198025468274"] = "Valve Employee",
	["76561198028573551"] = "Valve Employee",
	["76561198032490515"] = "Valve Employee",
	["76561198033146086"] = "Valve Employee",
	["76561198034808425"] = "Valve Employee",
	["76561198035001517"] = "Valve Employee",
	["76561198035286712"] = "Valve Employee",
	["76561198035288254"] = "Valve Employee",
	["76561198035422241"] = "Valve Employee",
	["76561198036759436"] = "Valve Employee",
	["76561198036913483"] = "Valve Employee",
	["76561198037075467"] = "Valve Employee",
	["76561198040445104"] = "Valve Employee",
	["76561198040900440"] = "Valve Employee",
	["76561198041710321"] = "Valve Employee",
	["76561198042626325"] = "Valve Employee",
	["76561198043656028"] = "Valve Employee",
	["76561198044595610"] = "Valve Employee",
	["76561198049584723"] = "Valve Employee",
	["76561198050594319"] = "Valve Employee",
	["76561198050715070"] = "Valve Employee",
	["76561198053546821"] = "Valve Employee",
	["76561198054073580"] = "Valve Employee",
	["76561198057387218"] = "Valve Employee",
	["76561198058528666"] = "Valve Employee",
	["76561198059223364"] = "Valve Employee",
	["76561198059343190"] = "Valve Employee",
	["76561198059694970"] = "Valve Employee",
	["76561198060668058"] = "Valve Employee",
	["76561198062125817"] = "Valve Employee",
	["76561198063543351"] = "Valve Employee",
	["76561198067204391"] = "Valve Employee",
	["76561198071493110"] = "Valve Employee",
	["76561198072243069"] = "Valve Employee",
	["76561198078021748"] = "Valve Employee",
	["76561198078024435"] = "Valve Employee",
	["76561198078035812"] = "Valve Employee",
	["76561198078228212"] = "Valve Employee",
	["76561198080174103"] = "Valve Employee",
	["76561198080912220"] = "Valve Employee",
	["76561198082857351"] = "Valve Employee",
	["76561198083228609"] = "Valve Employee",
	["76561198085177245"] = "Valve Employee",
	["76561198087246319"] = "Valve Employee",
	["76561198088081180"] = "Valve Employee",
	["76561198092412249"] = "Valve Employee",
	["76561198099775662"] = "Valve Employee",
	["76561198105633837"] = "Valve Employee",
	["76561198106284854"] = "Valve Employee",
	["76561198109437065"] = "Valve Employee",
	["76561198113964952"] = "Valve Employee",
	["76561198114561718"] = "Valve Employee",
	["76561198131186854"] = "Valve Employee",
	["76561198135833552"] = "Valve Employee",
	["76561198140935475"] = "Valve Employee",
	["76561198151901386"] = "Valve Employee",
	["76561198166130601"] = "Valve Employee",
	["76561198198282850"] = "Valve Employee",
	["76561198213106087"] = "Valve Employee",
	["76561198226485216"] = "Valve Employee",
	["76561198229291124"] = "Valve Employee",
	["76561198261314581"] = "Valve Employee",
	["76561198263786141"] = "Valve Employee",
	["76561198264031608"] = "Valve Employee",
	["76561198288977529"] = "Valve Employee",
	["76561198302566477"] = "Valve Employee",
	["76561198317891370"] = "Valve Employee",
	["76561198321452086"] = "Valve Employee",
	["76561198343860118"] = "Valve Employee",
	["76561198348711414"] = "Valve Employee",
	["76561198393844333"] = "Valve Employee",
	["76561198434829252"] = "Valve Employee",
	["76561198438289006"] = "Valve Employee",
	["76561198450401134"] = "Valve Employee",
	["76561198451127273"] = "Valve Employee",
	["76561198452053414"] = "Valve Employee",
	["76561198452899854"] = "Valve Employee",
	["76561198802256302"] = "Valve Employee",
	["76561198833054485"] = "Valve Employee",
	["76561198846285573"] = "Valve Employee",
	["76561198859895108"] = "Valve Employee",
	["76561198870432598"] = "Valve Employee",
	["76561198870775610"] = "Valve Employee",
	["76561198873502276"] = "Valve Employee",
	["76561198913388547"] = "Valve Employee",
	["76561198963127805"] = "Valve Employee",
	["76561198965919037"] = "Valve Employee",
	["76561198966950608"] = "Valve Employee",
	["76561198967346694"] = "Valve Employee",
	["76561198973062365"] = "Valve Employee",
	["76561198976679037"] = "Valve Employee",
	["76561198985183773"] = "Valve Employee",
	["76561199020521906"] = "Valve Employee",
	["76561199022293871"] = "Valve Employee",
	["76561199040187169"] = "Valve Employee",
	["76561199043975533"] = "Valve Employee",
	["76561199087803912"] = "Valve Employee",
	["76561199089249923"] = "Valve Employee",
	["76561199090326330"] = "Valve Employee",
	["76561199094829145"] = "Valve Employee",
	["76561199113010392"] = "Valve Employee",
	["76561199113204258"] = "Valve Employee",
	["76561199113498441"] = "Valve Employee",
	["76561199114963316"] = "Valve Employee",
	["76561199118553400"] = "Valve Employee",
	["76561199144449036"] = "Valve Employee",
	["76561199149854583"] = "Valve Employee",
	["76561199163993853"] = "Valve Employee",
	["76561199181174636"] = "Valve Employee",
	["76561199195394860"] = "Valve Employee",
	["76561199211175744"] = "Valve Employee",
	["76561199215769499"] = "Valve Employee",
	["76561199273762413"] = "Valve Employee",
	["76561199333946732"] = "Valve Employee",
	["76561199370270521"] = "Valve Employee",
	["76561199392211477"] = "Valve Employee",
	["76561199499120513"] = "Valve Employee",
	["76561199524745654"] = "Valve Employee",
	["76561199526219225"] = "Valve Employee",
	["76561199544394428"] = "Valve Employee",
	["76561199557784411"] = "Valve Employee",
	["76561199571838040"] = "Valve Employee",
	["76561199690380138"] = "Valve Employee",
}

---Check if a SteamID64 belongs to a Valve employee
---@param steamID string|number SteamID64
---@return boolean isValve True if the player is a Valve employee
---@return string|nil name Valve employee name if found
function ValveEmployees.IsValveEmployee(steamID)
	local steamIDStr = tostring(steamID)
	local name = ValveEmployees.List[steamIDStr]
	return name ~= nil
end

return ValveEmployees

end)
__bundle_register("Cheater_Detection.Utils.Commands", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Command bridge ]] 

local G = require("Cheater_Detection.Utils.Globals")
local Logger = require("Cheater_Detection.Utils.Logger")
local Common = require("Cheater_Detection.Utils.Common")

local lnxCommands = Common.Lib and Common.Lib.Utils and Common.Lib.Utils.Commands

local Commands = {}

local function ensureLnxCommands()
	if not lnxCommands then
		lnxCommands = Common.Lib and Common.Lib.Utils and Common.Lib.Utils.Commands
	end
	return lnxCommands
end

local function RegisterSteamHistory()
	local bridge = ensureLnxCommands()
	if not bridge or Commands._steamHistoryRegistered then
		return
	end

	Commands._steamHistoryRegistered = true
	bridge.Register("steamhistory", function(args)
		local shell = G.Menu and G.Menu.Misc and G.Menu.Misc.SteamHistory
		if not shell then
			Logger.Error("Commands", "SteamHistory menu state missing; config not initialised")
			return
		end

		local key = args and args:popFront() or nil
		if not key or key == "" then
			Logger.Warning("Commands", "Usage: steamhistory <api_key>")
			return
		end

		shell.ApiKey = key
		shell.Enable = false
		Logger.Info("Commands", "SteamHistory API key stored (scanning disabled until toggled)")
	end)
end

function Commands.Setup()
	if ensureLnxCommands() then
		RegisterSteamHistory()
	else
		Logger.Error("Commands", "lnxLib command subsystem unavailable; steam history command skipped")
	end
end

Commands.Setup()

return Commands

end)
__bundle_register("Cheater_Detection.Misc.ChatPrefix", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Cheater Detection - Chat Prefix Module ]]
-- Displays colored status tags before cheater names in chat

--[[ Imports ]]
local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")
local Evidence = require("Cheater_Detection.Core.Evidence_system")
local Database = require("Cheater_Detection.Database.Database")
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")

local ChatPrefix = {}

-- SayText2 message ID from E_UserMessage enum
local SayText2 = 4

---@param playerName string
---@return Entity?
local function GetPlayerFromName(playerName)
	for _, player in pairs(entities.FindByClass("CTFPlayer")) do
		if player:GetName() == playerName then
			return player
		end
	end
	return nil
end

---Convert RGB to hex color code for Source engine
---@param r number Red (0-255)
---@param g number Green (0-255)
---@param b number Blue (0-255)
---@return string Hex color code
local function rgbToHex(r, g, b)
	local hexadecimal = "\x07"

	for _, value in pairs({ r, g, b }) do
		local hex = ""

		while value > 0 do
			local index = math.fmod(value, 16) + 1
			value = math.floor(value / 16)
			hex = string.sub("0123456789ABCDEF", index, index) .. hex
		end

		if string.len(hex) == 0 then
			hex = "00"
		elseif string.len(hex) == 1 then
			hex = "0" .. hex
		end

		hexadecimal = hexadecimal .. hex
	end

	return hexadecimal
end

---Clear the entire bit buffer
---@param bf BitBuffer
local function ClearBuffer(bf)
	local len = bf:GetDataBitsLength()
	bf:SetCurBit(0)
	for i = 0, len do
		bf:WriteBit(0)
	end
	bf:SetCurBit(0)
end

---Get cheater status for a player
---@param player Entity
---@return string|nil status "CHEATER", "SUSPICIOUS", "VALVE" or nil
---@return table color RGB color {r, g, b}
local function GetCheaterStatus(player)
	if not player then
		return nil, { 255, 255, 255 }
	end

	local steamID = tostring(Common.GetSteamID64(player))
	if not steamID then
		return nil, { 255, 255, 255 }
	end

	-- Check if Valve employee first (takes priority)
	local isValve, valveName = ValveEmployees.IsValveEmployee(steamID)
	if isValve then
		-- Purple for Valve employee (Valve quality item color #8650AC)
		return "VALVE", { 134, 80, 172 }
	end

	-- Check if marked by Evidence system
	local isMarkedCheater = Evidence.IsMarkedCheater(steamID)

	-- Check if player is in database
	local dbEntry = Database.GetCheater(steamID)
	local inDatabase = dbEntry ~= nil

	if isMarkedCheater or inDatabase then
		-- Red for confirmed cheater
		return "CHEATER", { 255, 0, 0 }
	end

	-- Check if has some evidence (suspicious)
	if G.PlayerData[steamID] and G.PlayerData[steamID].Evidence then
		local evidence = G.PlayerData[steamID].Evidence
		if evidence.TotalScore and evidence.TotalScore > 0 then
			-- Yellow for suspicious
			return "SUSPICIOUS", { 255, 255, 0 }
		end
	end

	return nil, { 255, 255, 255 }
end

---UserMessage callback to modify chat messages
---@param msg UserMessage
local function OnUserMessage(msg)
	-- Check if feature is enabled
	if not G.Menu or not G.Menu.Main or not G.Menu.Main.Chat_Prefix then
		return
	end

	-- Only process SayText2 messages (chat)
	if msg:GetID() ~= SayText2 then
		return
	end

	local bf = msg:GetBitBuffer()
	if not bf then
		return
	end

	bf:SetCurBit(0)

	-- Read chat data (TF2's actual SayText2 structure)
	local wantsToChat = bf:ReadByte() -- Byte 0-7: wants to chat flag
	local clientIndex = bf:ReadByte() -- Byte 8-15: client index
	local isChat = bf:ReadByte() -- Byte 16-23: chat flag (THIS WAS MISSING!)
	local chatType = bf:ReadString(256) -- Now properly aligned - e.g. "TF_Chat_Team"
	local playerName = bf:ReadString(256)
	local messageText = bf:ReadString(256)

	-- Get player entity
	local player = GetPlayerFromName(playerName)
	if not player then
		return
	end

	-- Get cheater status
	local status, color = GetCheaterStatus(player)

	-- Check if this is a [CD] system message (after getting status to allow override)
	if messageText:find("%[CD%]") then
		-- System message - display without prefix
		if not client.ChatPrintf(messageText) then
			print("[CD] Failed to send system message")
		end
		
		-- Wipe original payload so nothing extra prints
		ClearBuffer(bf)
		bf:SetCurBit(0)
		return
	end

	if status then
		-- Build colored output for ChatPrintf
		local colorHex = rgbToHex(color[1], color[2], color[3])
		local tag = string.format("\x01[%s%s\x01]", colorHex, status)
		local teamColor = "\x01"
		local team = player:GetTeamNumber()
		if team == 2 then
			teamColor = "\x07FF4040"
		elseif team == 3 then
			teamColor = "\x0799CCFF"
		end
		local name = string.format("%s%s", teamColor, playerName)
		local formatted = string.format("%s %s\x01 :  %s", tag, name, messageText)

		if not client.ChatPrintf(formatted) then
			print("[CD] Failed to send chat prefix message")
		end

		-- Wipe original payload so nothing extra prints
		ClearBuffer(bf)
		bf:SetCurBit(0)
		return
	end
end

--[[ Callbacks ]]
callbacks.Unregister("DispatchUserMessage", "CD_ChatPrefix")
callbacks.Register("DispatchUserMessage", "CD_ChatPrefix", OnUserMessage)

return ChatPrefix

end)
__bundle_register("Cheater_Detection.Misc.Visuals.Menu", function(require, _LOADED, __bundle_register, __bundle_modules)
local Menu = {}

local Common = require("Cheater_Detection.Utils.Common")
local G = require("Cheater_Detection.Utils.Globals")

local Lib = Common.Lib
local Fonts = Lib.UI.Fonts

-- Try to load TimMenu (assumes it's installed globally in Lmaobox)
local TimMenu = nil
local timMenuLoaded, timMenuModule = pcall(require, "TimMenu")
if timMenuLoaded and timMenuModule then
	TimMenu = timMenuModule
	print("[CD] TimMenu loaded successfully")
else
	error("[CD] TimMenu not found! Please install TimMenu to %localappdata%\\lmaobox\\Scripts\\TimMenu.lua")
end

local function DrawMenu()
	-- Only draw when the Lmaobox menu is open
	if not gui.IsMenuOpen() then
		return
	end

	-- Debug mode indicator (drawn outside TimMenu window)
	if G.Menu.Advanced.debug then
		draw.Color(255, 0, 0, 255)
		draw.SetFont(Fonts.Verdana)
		draw.Text(20, 120, "Debug Mode!!! Some Features Might malfunction")
	end

	-- Begin the menu and store the result
	if not TimMenu.Begin("Cheater Detection") then
		return
	end

	-- Tabs for different sections
	local tabs = { "Main", "Advanced", "Misc" }
	G.Menu.currentTab = TimMenu.TabControl("cd_main_tabs", tabs, G.Menu.currentTab)
	TimMenu.NextLine()

	-- Main Configuration Tab
	if G.Menu.currentTab == "Main" then
		local Main = G.Menu.Main
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("Detection Automation")
		Main.Fetch_Database = TimMenu.Checkbox("Fetch Database", Main.Fetch_Database)
		TimMenu.Tooltip("Download external cheater lists on demand.")
		TimMenu.NextLine()
		Main.AutoMark = TimMenu.Checkbox("Auto Mark", Main.AutoMark)
		TimMenu.Tooltip("Mark players automatically once evidence passes the threshold.")
		TimMenu.NextLine()
		Main.partyCallaut = TimMenu.Checkbox("Party Callouts", Main.partyCallaut)
		TimMenu.Tooltip("Share detections with your party through chat.")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Visual Feedback")
		Main.Chat_Prefix = TimMenu.Checkbox("Chat Prefix", Main.Chat_Prefix)
		TimMenu.Tooltip("Enable colored chat tags for cheaters, suspects, and Valve staff.")
		TimMenu.NextLine()
		Main.Cheater_Tags = TimMenu.Checkbox("Cheater Tags", Main.Cheater_Tags)
		TimMenu.Tooltip("Show floating world labels for confirmed cheaters.")
		TimMenu.EndSector()
		TimMenu.NextLine()

		Misc.JoinNotifications = Misc.JoinNotifications or {}
		local JNMain = Misc.JoinNotifications
		if type(JNMain.ValveAutoDisconnect) ~= "boolean" then
			JNMain.ValveAutoDisconnect = false
		end

		TimMenu.BeginSector("Valve Safety")
		JNMain.ValveAutoDisconnect = TimMenu.Checkbox("Auto Leave on Valve Join", JNMain.ValveAutoDisconnect)
		TimMenu.Tooltip("Disconnect automatically when a Valve employee enters the server")
		TimMenu.EndSector()
		TimMenu.NextLine()
	elseif G.Menu.currentTab == "Advanced" then
		local Advanced = G.Menu.Advanced

		TimMenu.BeginSector("Evidence System")
		-- Initialize with default value if nil
		Advanced.Evicence_Tolerance = Advanced.Evicence_Tolerance or 100
		Advanced.Evicence_Tolerance = TimMenu.Slider("Evidence Tolerance", Advanced.Evicence_Tolerance, 1, 200, 1)
		TimMenu.Tooltip("Threshold for marking players as cheaters (higher = more strict)")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Exploit Detection")
		Advanced.AutoFlagPriorityTen = TimMenu.Checkbox("priority Detection", Advanced.AutoFlagPriorityTen)
		TimMenu.Tooltip(
			"When enabled, setting player priority to 10 will store them in the database as a known cheater."
		)
		Advanced.Choke = TimMenu.Checkbox("Fake Lag Detection", Advanced.Choke)
		TimMenu.NextLine()
		Advanced.Warp = TimMenu.Checkbox("Warp/DT Detection", Advanced.Warp)
		TimMenu.NextLine()
		Advanced.AntyAim = TimMenu.Checkbox("Anti-Aim Detection", Advanced.AntyAim)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Movement Detection")
		Advanced.Bhop = TimMenu.Checkbox("Bhop Detection", Advanced.Bhop)
		TimMenu.NextLine()
		Advanced.DuckSpeed = TimMenu.Checkbox("Duck Speed Detection", Advanced.DuckSpeed)
		TimMenu.NextLine()
		Advanced.Strafe_bot = TimMenu.Checkbox("Strafe Bot Detection", Advanced.Strafe_bot)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Aim Detection")
		Advanced.Aimbot.enable = TimMenu.Checkbox("Enable Aimbot Detection", Advanced.Aimbot.enable)
		TimMenu.NextLine()
		if Advanced.Aimbot.enable then
			-- Initialize if needed
			if type(Advanced.Aimbot.silent) ~= "boolean" then
				Advanced.Aimbot.silent = true
			end
			if type(Advanced.Aimbot.plain) ~= "boolean" then
				Advanced.Aimbot.plain = true
			end
			if type(Advanced.Aimbot.smooth) ~= "boolean" then
				Advanced.Aimbot.smooth = true
			end

			local aimbotTypes = { "Silent Aim", "Plain Aim", "Smooth Aim" }
			local aimbotTable = { Advanced.Aimbot.silent, Advanced.Aimbot.plain, Advanced.Aimbot.smooth }
			aimbotTable = TimMenu.Combo("Aimbot Types", aimbotTable, aimbotTypes)
			Advanced.Aimbot.silent = aimbotTable[1]
			Advanced.Aimbot.plain = aimbotTable[2]
			Advanced.Aimbot.smooth = aimbotTable[3]
			TimMenu.NextLine()
		end
		Advanced.triggerbot = TimMenu.Checkbox("Triggerbot Detection", Advanced.triggerbot)
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Logging")
		local logLevels = { "Debug", "Info", "Warning", "Error" }
		Advanced.LogLevel = TimMenu.Combo("Log Level", Advanced.LogLevel, logLevels)
		TimMenu.Tooltip("Set console output verbosity (Debug = everything, Error = only critical)")
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Debug")
		if type(Advanced.debug) ~= "boolean" then
			Advanced.debug = false
		end
		Advanced.debug = TimMenu.Checkbox("Debug Mode", Advanced.debug)
		TimMenu.Tooltip("Enables debug features (auto-removes self from database, enables verbose logging)")
		TimMenu.EndSector()
		TimMenu.NextLine()
	elseif G.Menu.currentTab == "Misc" then
		local Misc = G.Menu.Misc

		TimMenu.BeginSector("Vote Automation")
		Misc.Autovote = TimMenu.Checkbox("Auto Vote", Misc.Autovote)
		TimMenu.Tooltip("Call votes automatically using your selected targets.")
		TimMenu.NextLine()
		if Misc.Autovote then
			Misc.intent = Misc.intent or {}
			-- Initialize if needed
			if type(Misc.intent.legit) ~= "boolean" then
				Misc.intent.legit = true
			end
			if type(Misc.intent.cheater) ~= "boolean" then
				Misc.intent.cheater = true
			end
			if type(Misc.intent.bot) ~= "boolean" then
				Misc.intent.bot = true
			end
			if type(Misc.intent.valve) ~= "boolean" then
				Misc.intent.valve = true
			end
			if type(Misc.intent.friend) ~= "boolean" then
				Misc.intent.friend = false
			end
			if type(Misc.AutovoteAutoCast) ~= "boolean" then
				Misc.AutovoteAutoCast = true
			end
			Misc.AutovoteAutoCast = TimMenu.Checkbox("Auto Cast Votes", Misc.AutovoteAutoCast)
			TimMenu.Tooltip("Continuously initiate votes using the configured target priority.")
			TimMenu.NextLine()

			local voteTargets = { "Legit Players", "Cheaters", "Bots", "Valve Employees", "Exclude Friends" }
			local voteTable = {
				Misc.intent.legit,
				Misc.intent.cheater,
				Misc.intent.bot,
				Misc.intent.valve,
				Misc.intent.friend,
			}
			voteTable = TimMenu.Combo("Vote Targets", voteTable, voteTargets)
			Misc.intent.legit = voteTable[1]
			Misc.intent.cheater = voteTable[2]
			Misc.intent.bot = voteTable[3]
			Misc.intent.valve = voteTable[4]
			Misc.intent.friend = voteTable[5]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()

		TimMenu.BeginSector("Vote Reveal Alerts")
		Misc.Vote_Reveal.Enable = TimMenu.Checkbox("Vote Reveal", Misc.Vote_Reveal.Enable)
		TimMenu.Tooltip("Announce teammate votes and their targets across selected channels.")
		TimMenu.NextLine()
		if Misc.Vote_Reveal.Enable then
			-- Initialize if needed
			if type(Misc.Vote_Reveal.TargetTeam.MyTeam) ~= "boolean" then
				Misc.Vote_Reveal.TargetTeam.MyTeam = true
			end
			if type(Misc.Vote_Reveal.TargetTeam.enemyTeam) ~= "boolean" then
				Misc.Vote_Reveal.TargetTeam.enemyTeam = true
			end

			-- Initialize new output options
			Misc.Vote_Reveal.Output = Misc.Vote_Reveal.Output or {}
			if type(Misc.Vote_Reveal.Output.PublicChat) ~= "boolean" then
				Misc.Vote_Reveal.Output.PublicChat = false
			end
			if type(Misc.Vote_Reveal.Output.PartyChat) ~= "boolean" then
				Misc.Vote_Reveal.Output.PartyChat = true
			end
			if type(Misc.Vote_Reveal.Output.ClientChat) ~= "boolean" then
				Misc.Vote_Reveal.Output.ClientChat = false
			end
			if type(Misc.Vote_Reveal.Output.Console) ~= "boolean" then
				Misc.Vote_Reveal.Output.Console = true
			end

			local teamOptions = { "My Team", "Enemy Team" }
			local teamTable = { Misc.Vote_Reveal.TargetTeam.MyTeam, Misc.Vote_Reveal.TargetTeam.enemyTeam }
			teamTable = TimMenu.Combo("Target Teams", teamTable, teamOptions)
			Misc.Vote_Reveal.TargetTeam.MyTeam = teamTable[1]
			Misc.Vote_Reveal.TargetTeam.enemyTeam = teamTable[2]
			TimMenu.NextLine()

			local outputOptions = { "Public Chat", "Party Chat", "Client Chat", "Console" }
			local outputTable = {
				Misc.Vote_Reveal.Output.PublicChat,
				Misc.Vote_Reveal.Output.PartyChat,
				Misc.Vote_Reveal.Output.ClientChat,
				Misc.Vote_Reveal.Output.Console,
			}
			outputTable = TimMenu.Combo("Vote Output", outputTable, outputOptions)
			Misc.Vote_Reveal.Output.PublicChat = outputTable[1]
			Misc.Vote_Reveal.Output.PartyChat = outputTable[2]
			Misc.Vote_Reveal.Output.ClientChat = outputTable[3]
			Misc.Vote_Reveal.Output.Console = outputTable[4]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()
		TimMenu.NextLine()

		TimMenu.BeginSector("Join Alerts")
		-- Initialize JoinNotifications if needed
		Misc.JoinNotifications = Misc.JoinNotifications or {}
		local JN = Misc.JoinNotifications

		if type(JN.Enable) ~= "boolean" then
			JN.Enable = true
		end
		if type(JN.CheckCheater) ~= "boolean" then
			JN.CheckCheater = true
		end
		if type(JN.CheckValve) ~= "boolean" then
			JN.CheckValve = true
		end
		if type(JN.ValveAutoDisconnect) ~= "boolean" then
			JN.ValveAutoDisconnect = false
		end

		JN.Enable = TimMenu.Checkbox("Join Alerts", JN.Enable)
		TimMenu.Tooltip("Warn about cheaters or Valve employees joining the match.")
		TimMenu.NextLine()

		if JN.Enable then
			-- Target filters
			local notifTypes = { "Cheaters", "Valve" }
			local notifTable = { JN.CheckCheater, JN.CheckValve }
			notifTable = TimMenu.Combo("Notify For", notifTable, notifTypes)
			JN.CheckCheater = notifTable[1]
			JN.CheckValve = notifTable[2]
			TimMenu.NextLine()

			-- Default output channels
			JN.DefaultOutput = JN.DefaultOutput or {}
			if type(JN.DefaultOutput.PublicChat) ~= "boolean" then
				JN.DefaultOutput.PublicChat = false
			end
			if type(JN.DefaultOutput.PartyChat) ~= "boolean" then
				JN.DefaultOutput.PartyChat = true
			end
			if type(JN.DefaultOutput.ClientChat) ~= "boolean" then
				JN.DefaultOutput.ClientChat = false
			end
			if type(JN.DefaultOutput.Console) ~= "boolean" then
				JN.DefaultOutput.Console = true
			end

			local defaultOutputOptions = { "Public Chat", "Party Chat", "Client Chat", "Console" }
			local defaultOutputTable = {
				JN.DefaultOutput.PublicChat,
				JN.DefaultOutput.PartyChat,
				JN.DefaultOutput.ClientChat,
				JN.DefaultOutput.Console,
			}
			defaultOutputTable = TimMenu.Combo("Default Output", defaultOutputTable, defaultOutputOptions)
			JN.DefaultOutput.PublicChat = defaultOutputTable[1]
			JN.DefaultOutput.PartyChat = defaultOutputTable[2]
			JN.DefaultOutput.ClientChat = defaultOutputTable[3]
			JN.DefaultOutput.Console = defaultOutputTable[4]
			TimMenu.NextLine()

			-- Cheater override
			if type(JN.UseCheaterOverride) ~= "boolean" then
				JN.UseCheaterOverride = false
			end
			JN.UseCheaterOverride = TimMenu.Checkbox("Cheater Output Override", JN.UseCheaterOverride)
			TimMenu.Tooltip("Send cheater alerts to custom chat channels.")
			TimMenu.NextLine()

			if JN.UseCheaterOverride then
				JN.CheaterOverride = JN.CheaterOverride or {}
				if type(JN.CheaterOverride.PublicChat) ~= "boolean" then
					JN.CheaterOverride.PublicChat = false
				end
				if type(JN.CheaterOverride.PartyChat) ~= "boolean" then
					JN.CheaterOverride.PartyChat = true
				end
				if type(JN.CheaterOverride.ClientChat) ~= "boolean" then
					JN.CheaterOverride.ClientChat = false
				end
				if type(JN.CheaterOverride.Console) ~= "boolean" then
					JN.CheaterOverride.Console = true
				end

				local cheaterOutputTable = {
					JN.CheaterOverride.PublicChat,
					JN.CheaterOverride.PartyChat,
					JN.CheaterOverride.ClientChat,
					JN.CheaterOverride.Console,
				}
				cheaterOutputTable = TimMenu.Combo("Cheater Output", cheaterOutputTable, defaultOutputOptions)
				JN.CheaterOverride.PublicChat = cheaterOutputTable[1]
				JN.CheaterOverride.PartyChat = cheaterOutputTable[2]
				JN.CheaterOverride.ClientChat = cheaterOutputTable[3]
				JN.CheaterOverride.Console = cheaterOutputTable[4]
				TimMenu.NextLine()
			end

			-- Valve override
			if type(JN.UseValveOverride) ~= "boolean" then
				JN.UseValveOverride = false
			end
			JN.UseValveOverride = TimMenu.Checkbox("Valve Output Override", JN.UseValveOverride)
			TimMenu.Tooltip("Send Valve alerts to custom chat channels.")
			TimMenu.NextLine()

			if JN.UseValveOverride then
				JN.ValveOverride = JN.ValveOverride or {}
				if type(JN.ValveOverride.PublicChat) ~= "boolean" then
					JN.ValveOverride.PublicChat = false
				end
				if type(JN.ValveOverride.PartyChat) ~= "boolean" then
					JN.ValveOverride.PartyChat = false
				end
				if type(JN.ValveOverride.ClientChat) ~= "boolean" then
					JN.ValveOverride.ClientChat = true
				end
				if type(JN.ValveOverride.Console) ~= "boolean" then
					JN.ValveOverride.Console = true
				end

				local valveOutputTable = {
					JN.ValveOverride.PublicChat,
					JN.ValveOverride.PartyChat,
					JN.ValveOverride.ClientChat,
					JN.ValveOverride.Console,
				}
				valveOutputTable = TimMenu.Combo("Valve Output", valveOutputTable, defaultOutputOptions)
				JN.ValveOverride.PublicChat = valveOutputTable[1]
				JN.ValveOverride.PartyChat = valveOutputTable[2]
				JN.ValveOverride.ClientChat = valveOutputTable[3]
				JN.ValveOverride.Console = valveOutputTable[4]
				TimMenu.NextLine()
			end
		end
		TimMenu.EndSector()

		TimMenu.BeginSector("Class Change Alerts")
		Misc.Class_Change_Reveal.Enable = TimMenu.Checkbox("Class Change Reveal", Misc.Class_Change_Reveal.Enable)
		TimMenu.Tooltip("Notify when tracked players switch classes.")
		TimMenu.NextLine()
		if Misc.Class_Change_Reveal.Enable then
			-- Initialize if needed
			if type(Misc.Class_Change_Reveal.EnemyOnly) ~= "boolean" then
				Misc.Class_Change_Reveal.EnemyOnly = true
			end

			-- Initialize new output options
			Misc.Class_Change_Reveal.Output = Misc.Class_Change_Reveal.Output or {}
			if type(Misc.Class_Change_Reveal.Output.PublicChat) ~= "boolean" then
				Misc.Class_Change_Reveal.Output.PublicChat = false
			end
			if type(Misc.Class_Change_Reveal.Output.PartyChat) ~= "boolean" then
				Misc.Class_Change_Reveal.Output.PartyChat = true
			end
			if type(Misc.Class_Change_Reveal.Output.ClientChat) ~= "boolean" then
				Misc.Class_Change_Reveal.Output.ClientChat = false
			end
			if type(Misc.Class_Change_Reveal.Output.Console) ~= "boolean" then
				Misc.Class_Change_Reveal.Output.Console = true
			end

			Misc.Class_Change_Reveal.EnemyOnly = TimMenu.Checkbox("Enemy Team Only", Misc.Class_Change_Reveal.EnemyOnly)
			TimMenu.NextLine()

			local classOutputOptions = { "Public Chat", "Party Chat", "Client Chat", "Console" }
			local classOutputTable = {
				Misc.Class_Change_Reveal.Output.PublicChat,
				Misc.Class_Change_Reveal.Output.PartyChat,
				Misc.Class_Change_Reveal.Output.ClientChat,
				Misc.Class_Change_Reveal.Output.Console,
			}
			classOutputTable = TimMenu.Combo("Class Change Output", classOutputTable, classOutputOptions)
			Misc.Class_Change_Reveal.Output.PublicChat = classOutputTable[1]
			Misc.Class_Change_Reveal.Output.PartyChat = classOutputTable[2]
			Misc.Class_Change_Reveal.Output.ClientChat = classOutputTable[3]
			Misc.Class_Change_Reveal.Output.Console = classOutputTable[4]
			TimMenu.NextLine()
		end
		TimMenu.EndSector()

		TimMenu.NextLine()

		TimMenu.BeginSector("SteamHistory")
		Misc.SteamHistory = Misc.SteamHistory or {}
		local sh = Misc.SteamHistory
		sh.ApiKey = sh.ApiKey or ""
		if type(sh.Enable) ~= "boolean" then
			sh.Enable = false
		end
		local hasKey = sh.ApiKey ~= ""
		if not hasKey then
			sh.Enable = false
			TimMenu.Text("SteamHistory API key missing. Use: steamhistory <key>")
			TimMenu.Tooltip("Paste your SteamHistory key in the console to unlock scanning.")
		else
			sh.Enable = TimMenu.Checkbox("Enable SteamHistory scans", sh.Enable)
			TimMenu.Tooltip("Scan everyone in the server immediately and any newcomers who join after you.")
			goto steam_history_sector_end
		end
		TimMenu.NextLine()
		TimMenu.Text("Enter your SteamHistory key to unlock automatic scanning.")
		::steam_history_sector_end::
		TimMenu.NextLine()
		TimMenu.EndSector()
		TimMenu.NextLine()
	end

	-- Always end the menu
	TimMenu.End()
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "CD_MENU")
callbacks.Register("Draw", "CD_MENU", DrawMenu)

return Menu

end)
__bundle_register("Cheater_Detection.Database.Fetcher", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Cheater Detection - Database Fetcher - Synchronous Simplified Version ]]
local Common = require("Cheater_Detection.Utils.Common")
-- [[ Imported by: Main.lua ]]
local G = require("Cheater_Detection.Utils.Globals")
-- [[ Imported by: None ]]
local Json = Common.Json
-- [[ Imported by: Fetcher.lua (indirectly via Common) ]]
local Database = require("Cheater_Detection.Database.Database") -- For SaveDatabase
-- [[ Imported by: Fetcher.lua ]]
local Sources = require("Cheater_Detection.Database.Sources") -- Require Sources
-- [[ Imported by: Fetcher.lua ]]
local Parsers = require("Cheater_Detection.Database.Parsers") -- Require Parsers
-- [[ Imported by: Fetcher.lua ]]

local Fetcher = {}

-- Define LogLevel locally within Fetcher
local LogLevel = {
	ERROR = 1,
	WARNING = 2,
	SUCCESS = 3,
	INFO = 4,
	DEBUG = 5,
}

-- Local Log function for Fetcher module (Defined early)
local function Log(level, message, color)
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true

	-- Determine if the message should be shown
	local shouldShow = false
	if isDebugMode then
		shouldShow = true -- Show all levels in debug mode
	elseif level <= LogLevel.SUCCESS then
		shouldShow = true -- Show ERROR, WARNING, SUCCESS in non-debug mode
	end

	if not shouldShow then
		return
	end

	local prefix = ""
	local defaultColor = { 255, 255, 255, 255 }

	if level == LogLevel.ERROR then
		prefix = "[FETCHER ERROR] "
		color = color or { 255, 100, 100, 255 } -- Red
	elseif level == LogLevel.WARNING then
		prefix = "[FETCHER WARNING] "
		color = color or { 255, 255, 100, 255 } -- Yellow
	elseif level == LogLevel.SUCCESS then
		prefix = "[FETCHER SUCCESS] "
		color = color or { 0, 255, 140, 255 } -- Bright Green
	elseif level == LogLevel.INFO then
		if not isDebugMode then
			return
		end
		prefix = "[FETCHER INFO] "
		color = color or { 100, 255, 255, 255 } -- Cyan
	elseif level == LogLevel.DEBUG then
		if not isDebugMode then
			return
		end
		prefix = "[FETCHER DEBUG] "
		color = color or { 180, 180, 180, 255 } -- Grey
	end

	color = color or defaultColor
	printc(color[1], color[2], color[3], color[4], prefix .. message)
end

-- Simplified State tracking
Fetcher.State = {
	isRunning = false,
	startTime = 0,
	results = {
		total_added = 0,
		total_updated = 0, -- Keep track of updates
		errors = 0,
	},
}

-- Helper function to check if all required modules are properly loaded
local function checkRequirements()
	Log(LogLevel.DEBUG, "[FETCHER] Checking requirements...") -- Use Log
	if type(G) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Globals module not loaded properly") -- Use Log
		return false
	end
	if type(G.DataBase) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: G.DataBase is not initialized") -- Use Log
		return false
	end
	if type(Database) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Database module not loaded properly") -- Use Log
		return false
	end
	if type(Database.SaveDatabase) ~= "function" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Database.SaveDatabase function missing") -- Use Log
		return false
	end
	if type(Sources) ~= "table" or type(Sources.GetActiveSources) ~= "function" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Sources module not loaded properly") -- Use Log
		return false
	end
	if type(Parsers) ~= "table" then
		Log(LogLevel.ERROR, "[FETCHER] CRITICAL ERROR: Parsers module not loaded properly") -- Use Log
		return false
	end
	Log(LogLevel.DEBUG, "[FETCHER] All requirements satisfied") -- Use Log
	return true
end

-- Process a single source and add its entries to the database
local function processSource(source)
	Log(LogLevel.INFO, string.format("[FETCHER] Processing source: %s (%s)", source.name, source.url)) -- Use Log

	-- Fetch the URL directly using pcall
	local fetch_success, response_content_or_error = pcall(http.Get, source.url)

	if not fetch_success then
		Log( -- Use Log
			LogLevel.WARNING, -- Log as Warning instead of Error, maybe temporary network issue
			string.format(
				"[FETCHER] Failed to fetch data from %s: %s",
				source.name,
				tostring(response_content_or_error)
			)
		)
		return 0, 0, 1 -- added, updated, errors
	end

	local response_content = response_content_or_error
	if type(response_content) ~= "string" or response_content == "" then
		Log(LogLevel.WARNING, string.format("[FETCHER] Empty or invalid content from %s", source.name)) -- Use Log
		return 0, 0, 1 -- added, updated, errors
	end

	Log(
		LogLevel.DEBUG,
		string.format("[FETCHER] Download successful from %s. Size: %d bytes", source.name, #response_content)
	) -- Use Log (Debug)

	local sourceStats = { processed = 0, added = 0, existing = 0, updated = 0, errors = 0 }
	local added = 0
	local updated = 0
	local isDirtyBefore = Database.State.isDirty

	-- Parsing logic (remains the same)
	if source.parser == "raw" then
		local entries, errorMsg = Parsers.ParseRawIDs(response_content, source.cause)
		if entries then
			local processedCount, existingCount, addedCount, updatedCount = 0, 0, 0, 0
			for steamID64, entryData in pairs(entries) do
				processedCount = processedCount + 1
				if not G.DataBase[steamID64] then
					G.DataBase[steamID64] = entryData
					addedCount = addedCount + 1
				else
					existingCount = existingCount + 1
					local existingEntry = G.DataBase[steamID64]
					if
						(existingEntry.Name == "Unknown" or existingEntry.Name == nil)
						and entryData.Name
						and entryData.Name ~= "Unknown"
					then
						existingEntry.Name = entryData.Name
						updatedCount = updatedCount + 1
						Database.State.isDirty = true
					end
					if
						(existingEntry.Reason == "Unknown Source" or existingEntry.Reason == nil)
						and entryData.Reason
						and entryData.Reason ~= "Unknown Source"
					then
						existingEntry.Reason = entryData.Reason
						updatedCount = updatedCount + 1
						Database.State.isDirty = true
					end
				end
			end
			added = addedCount
			updated = updatedCount
			sourceStats.processed = processedCount
			sourceStats.added = addedCount
			sourceStats.existing = existingCount
			sourceStats.updated = updatedCount
		else
			Log(
				LogLevel.WARNING,
				string.format("[FETCHER] Error parsing %s: %s", source.name, errorMsg or "Unknown error")
			) -- Use Log
			sourceStats.errors = sourceStats.errors + 1
		end
	elseif source.parser == "tf2db" then
		if source.url:find("tf2_bot_detector") and source.url:find("playerlist%.official%.json") then
			local _, errorMsg, stats = Parsers.ParseTF2BotDetector(response_content, source.cause, G.DataBase)
			if stats then
				added, updated = stats.added, stats.updated
				sourceStats = stats
			else
				Log(
					LogLevel.WARNING,
					string.format("[FETCHER] Error parsing %s: %s", source.name, errorMsg or "Unknown error")
				) -- Use Log
				sourceStats.errors = sourceStats.errors + 1
			end
		else
			local data, errorMsg = Parsers.ParseJsonTF2DB(response_content)
			if data and data.players then
				local processedCount, existingCount, addedCount, updatedCount = 0, 0, 0, 0
				for _, player in ipairs(data.players) do
					processedCount = processedCount + 1
					local steamID64 = player.steamid and Parsers.GetSteamID64(player.steamid) or nil
					if steamID64 then
						local playerName = (player.last_seen and player.last_seen.player_name) or "Unknown"
						local reason = source.cause or "Unknown Source"
						if player.attributes and #player.attributes > 0 then
							reason = player.attributes[1]:gsub("^%l", string.upper)
						end
						if not G.DataBase[steamID64] then
							G.DataBase[steamID64] = { Name = playerName, Reason = reason }
							addedCount = addedCount + 1
						else
							existingCount = existingCount + 1
							local existingEntry = G.DataBase[steamID64]
							if
								(existingEntry.Name == "Unknown" or existingEntry.Name == nil)
								and playerName
								and playerName ~= "Unknown"
							then
								existingEntry.Name = playerName
								updatedCount = updatedCount + 1
								Database.State.isDirty = true
							end
							if reason and reason ~= "Unknown Source" then
								local existingReason = existingEntry.Reason
								if not existingReason or existingReason == "Unknown Source" then
									existingEntry.Reason = reason
									updatedCount = updatedCount + 1
									Database.State.isDirty = true
								elseif existingReason ~= reason and not existingReason:find(reason, 1, true) then
									existingEntry.Reason = existingReason .. " | " .. reason
									updatedCount = updatedCount + 1
									Database.State.isDirty = true
								end
							end
						end
					else
						sourceStats.errors = sourceStats.errors + 1
					end
				end
				added = addedCount
				updated = updatedCount
				sourceStats.processed = processedCount
				sourceStats.added = addedCount
				sourceStats.existing = existingCount
				sourceStats.updated = updatedCount
			else
				Log(
					LogLevel.WARNING,
					string.format("[FETCHER] Error parsing %s: %s", source.name, errorMsg or "Unknown error")
				) -- Use Log
				sourceStats.errors = sourceStats.errors + 1
			end
		end
	else
		Log( -- Use Log
			LogLevel.ERROR,
			string.format("[FETCHER] Error: Unknown parser type '%s' for source %s", source.parser, source.name)
		)
		return 0, 0, 1 -- added, updated, errors
	end

	Parsers.AddSourceStats(
		source.name,
		sourceStats.processed,
		sourceStats.added,
		sourceStats.existing,
		sourceStats.errors,
		sourceStats.updated
	)

	if (added > 0 or updated > 0) and not isDirtyBefore then
		Database.State.isDirty = true
	end

	if updated > 0 then
		Log(LogLevel.DEBUG, string.format("[FETCHER] %s: Added %d, Updated %d", source.name, added, updated)) -- Debug level
	elseif added > 0 then
		Log(LogLevel.DEBUG, string.format("[FETCHER] %s: Added %d", source.name, added)) -- Debug level
	else
		Log(LogLevel.DEBUG, string.format("[FETCHER] %s: No changes", source.name)) -- Debug level
	end

	-- response_content = nil -- Commented out to avoid linter type mismatch warning
	return added, updated, sourceStats.errors
end

-- Public Module Functions
function Fetcher.Start()
	Log(LogLevel.INFO, "[FETCHER] Starting SYNC database fetch process") -- Use Log

	if Fetcher.State.isRunning then
		Log(LogLevel.WARNING, "[FETCHER] Fetch process already running, ignoring request") -- Use Log
		return
	end

	if not checkRequirements() then
		Log(LogLevel.ERROR, "[FETCHER] Requirements check failed, aborting fetch") -- Use Log
		return
	end

	Parsers.ResetStats()

	Fetcher.State.isRunning = true
	Fetcher.State.startTime = globals.RealTime()
	Fetcher.State.results.total_added = 0
	Fetcher.State.results.total_updated = 0
	Fetcher.State.results.errors = 0

	local active_sources = Sources.GetActiveSources()
	Log(LogLevel.INFO, string.format("[FETCHER] Found %d active sources", #active_sources)) -- Use Log

	if #active_sources == 0 then
		Log(LogLevel.INFO, "[FETCHER] No active sources found, finishing immediately.") -- Use Log
		Fetcher.FinishFetch()
		return
	end

	-- Process each source synchronously
	for i, source in ipairs(active_sources) do
		Log(LogLevel.DEBUG, string.format("[FETCHER] Processing source %d/%d: %s", i, #active_sources, source.name)) -- Use Log (Debug)
		local added, updated, errors = processSource(source)
		Fetcher.State.results.total_added = Fetcher.State.results.total_added + added
		Fetcher.State.results.total_updated = Fetcher.State.results.total_updated + updated
		Fetcher.State.results.errors = Fetcher.State.results.errors + errors
	end

	-- Fetch completed, call FinishFetch directly
	Fetcher.FinishFetch()
end

function Fetcher.FinishFetch()
	if not Fetcher.State.isRunning then
		return
	end

	local elapsedTime = globals.RealTime() - Fetcher.State.startTime

	-- Only show detailed debug output in debug mode (via Parsers.PrintStatsSummary)
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	if isDebugMode then
		-- Log the full details only in debug mode
		Log(
			LogLevel.INFO,
			string.format(
				"SYNC Fetch completed in %.2f seconds. Total Added: %d, Total Updated: %d, Errors: %d",
				elapsedTime,
				Fetcher.State.results.total_added,
				Fetcher.State.results.total_updated,
				Fetcher.State.results.errors
			)
		)

		-- Show detailed stats in debug mode
		Parsers.PrintStatsSummary()
	else
		-- User-friendly output with color coding and separate lines for key metrics
		-- Always show processed and added counts in green
		printc(0, 255, 140, 255, string.format("Database entries processed: %d", Parsers.ParseStats.totalProcessed))
		printc(0, 255, 140, 255, string.format("Database entries added: %d", Parsers.ParseStats.totalAdded))

		-- Only show errors if there are any (in red)
		if Parsers.ParseStats.totalErrors > 0 then
			printc(255, 100, 100, 255, string.format("Database errors: %d", Parsers.ParseStats.totalErrors))
		end

		-- Show database entry count in green
		local dbCount = 0
		if type(G.DataBase) == "table" then
			for _ in pairs(G.DataBase) do
				dbCount = dbCount + 1
			end
		end
		printc(0, 255, 140, 255, string.format("Total database entries: %d", dbCount))
	end

	if Database.State.isDirty then
		Log(LogLevel.INFO, "Changes detected, saving database")
		Database.SaveDatabase()
	else
		Log(LogLevel.INFO, "No changes detected, skipping database save")
	end

	Fetcher.State.isRunning = false
	Log(LogLevel.DEBUG, "Fetch process finished")
end

function Fetcher.GetStatus()
	return {
		running = Fetcher.State.isRunning,
	}
end

-- Self-Initialization
local function InitializeFetcher()
	Log(LogLevel.DEBUG, "[FETCHER] Checking if fetch on load is enabled...") -- Use Log (Updated message)
	-- Check G.Menu.Main.Fetch_Database instead of G.Config.AutoFetch
	if
		type(G) == "table"
		and type(G.Menu) == "table"
		and type(G.Menu.Main) == "table"
		and G.Menu.Main.Fetch_Database == true
	then
		Log(LogLevel.INFO, "[FETCHER] Fetch on load enabled, starting fetch process...") -- Use Log (Updated message)
		Fetcher.Start()
	else
		Log(LogLevel.INFO, "[FETCHER] Fetch on load disabled or not configured, skipping initial fetch.") -- Use Log (Updated message)
	end
end

InitializeFetcher()

Log(LogLevel.DEBUG, "[FETCHER] >>> Module execution finished. Returning Fetcher table.") -- Use Log (Debug)
return Fetcher

end)
__bundle_register("Cheater_Detection.Database.Parsers", function(require, _LOADED, __bundle_register, __bundle_modules)
local Common = require("Cheater_Detection.Utils.Common")
-- [[ Imported by: Fetcher.lua (indirectly) ]]
local Json = Common.Json
-- [[ Imported by: Parsers.lua ]]

local G = require("Cheater_Detection.Utils.Globals")
-- [[ Imported by: Fetcher.lua, Parsers.lua ]]

local Parsers = {}

-- Stats tracking for parser operations
Parsers.ParseStats = {
	sources = {},
	totalProcessed = 0,
	totalAdded = 0,
	totalExisting = 0,
	totalErrors = 0,
	totalUpdated = 0,
}

-- Reset stats for a new parsing session
function Parsers.ResetStats()
	Parsers.ParseStats = {
		sources = {},
		totalProcessed = 0,
		totalAdded = 0,
		totalExisting = 0,
		totalErrors = 0,
		totalUpdated = 0,
	}
end

-- Add stats for a source
function Parsers.AddSourceStats(sourceName, processed, added, existing, errors, updated)
	Parsers.ParseStats.sources[sourceName] = {
		processed = processed or 0,
		added = added or 0,
		existing = existing or 0,
		errors = errors or 0,
		updated = updated or 0,
	}

	-- Update totals
	Parsers.ParseStats.totalProcessed = Parsers.ParseStats.totalProcessed + processed
	Parsers.ParseStats.totalAdded = Parsers.ParseStats.totalAdded + added
	Parsers.ParseStats.totalExisting = Parsers.ParseStats.totalExisting + existing
	Parsers.ParseStats.totalErrors = Parsers.ParseStats.totalErrors + errors
	-- Add updating to totals if it exists
	Parsers.ParseStats.totalUpdated = (Parsers.ParseStats.totalUpdated or 0) + (updated or 0)
end

-- Get a formatted summary of all parsing statistics
function Parsers.GetStatsSummary()
	local summary = "[PARSE STATS SUMMARY]\n"

	-- Add per-source stats
	for sourceName, stats in pairs(Parsers.ParseStats.sources) do
		-- Check if source has any updates to report
		local updatesInfo = ""
		if stats.updated and stats.updated > 0 then
			updatesInfo = string.format(", Updated: %d", stats.updated)
		end

		summary = summary
			.. string.format(
				"[Source: %s] Processed: %d, Added: %d, Already Exists: %d%s, Errors: %d\n",
				sourceName,
				stats.processed,
				stats.added,
				stats.existing,
				updatesInfo,
				stats.errors
			)
	end

	-- Calculate total updates
	local totalUpdated = 0
	for _, stats in pairs(Parsers.ParseStats.sources) do
		totalUpdated = totalUpdated + (stats.updated or 0)
	end

	-- Add total stats with updates info
	local totalUpdatesInfo = ""
	if totalUpdated > 0 then
		totalUpdatesInfo = string.format(", Updated: %d", totalUpdated)
	end

	summary = summary
		.. string.format(
			"[TOTAL] Processed: %d, Added: %d, Already Exists: %d%s, Errors: %d",
			Parsers.ParseStats.totalProcessed,
			Parsers.ParseStats.totalAdded,
			Parsers.ParseStats.totalExisting,
			totalUpdatesInfo,
			Parsers.ParseStats.totalErrors
		)

	return summary
end

-- Formats and prints a statistics bundle for all parsing operations
--[[ DEPRECATED: Printing is now handled by Fetcher using GetStatsSummary and Database.Log
function Parsers.PrintStatsSummary()
	print(Parsers.GetStatsSummary())
end
]]
-- Restore the function
function Parsers.PrintStatsSummary()
	local isDebugMode = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug == true
	-- Only print the summary if in debug mode
	if isDebugMode then
		local summary = Parsers.GetStatsSummary()
		if summary then
			print(summary) -- Keep using plain print for multi-line debug summary
		end
	end
end

-- Robust SteamID conversion function (moved from Fetcher)
-- Handles SteamID64, SteamID3 ([U:1:xxxx]), SteamID2 (STEAM_0:x:xxxx)
function Parsers.GetSteamID64(input)
	if not input then
		return nil
	end

	local id_str = tostring(input):match("^%s*(.-)%s*$") -- Trim
	if not id_str then
		return nil
	end

	-- 1. Check if it's a plain numeric ID that's in the valid SteamID64 range
	if id_str:match("^%d+$") then
		local num = tonumber(id_str)
		if num and num >= 76500000000000000 and num <= 77000000000000000 then
			return id_str
		end
	end

	-- 2. Validate against standard SteamID64 format
	if id_str:match("^7656119%d+$") and string.len(id_str) >= 17 then
		return id_str
	end

	-- 3. Try conversion using built-in function (handles SteamID2, SteamID3)
	local steamID64_from_pcall = nil
	if steam and steam.ToSteamID64 then -- Ensure steam API is available
		local success, result = pcall(steam.ToSteamID64, id_str)

		-- Check if pcall succeeded AND the result is usable (string or number)
		local result_str = nil
		if success and result then
			-- Convert to string if necessary
			if type(result) == "number" then
				result_str = tostring(result)
			elseif type(result) == "string" then
				result_str = result
			end

			-- If we got a usable string, trim and validate it
			if result_str then
				local trimmed_result = result_str:match("^%s*(.-)%s*$")

				-- Check if this is a valid SteamID64 by numeric range instead of strict pattern
				if trimmed_result and trimmed_result:match("^%d+$") then
					local num = tonumber(trimmed_result)
					if num and num >= 76561197960265728 and num <= 77000000000000000 then -- Corrected range
						return trimmed_result
					end
				end
			end
		else
			-- Debug print statement removed
			-- Log(LogLevel.DEBUG, "[PARSERS] steam API or steam.ToSteamID64 not available for conversion attempt")
		end
	else
		-- Debug print statement removed
		-- Log(LogLevel.DEBUG, "[PARSERS] steam API or steam.ToSteamID64 not available for conversion attempt")
	end

	-- If conversion via pcall was successful, return that result
	if steamID64_from_pcall then
		return steamID64_from_pcall
	end

	-- 4. Manual fallback for SteamID3 (only if steps 1 & 2 failed)
	local accountID = id_str:match("%[U:1:(%d+)%]")
	if accountID then
		accountID = tonumber(accountID)
		if accountID then
			local steamID64 = tostring(76561197960265728 + accountID)
			return steamID64
		end
	end

	-- 5. All attempts failed
	return nil
end

-- Parses a JSON string (specifically bots.tf format expected)
-- Returns: { players = { { steamid="...", attributes={...}, last_seen={player_name="..."} }, ... } } or nil, errorMsg
function Parsers.ParseJsonTF2DB(contentString)
	if not contentString or contentString == "" then
		return nil, "Empty content string"
	end

	-- Ensure the JSON decoder is available before calling pcall
	if not Json or type(Json.decode) ~= "function" then
		return nil, "JSON decode function is unavailable"
	end

	local success, data = pcall(Json.decode, contentString)

	if not success or type(data) ~= "table" then
		return nil, "JSON decode failed: " .. tostring(data)
	end

	if not data.players or type(data.players) ~= "table" then
		-- Allow if the root object itself is the list of players
		if type(data) == "table" and #data > 0 and type(data[1]) == "table" and data[1].steamid then
			return { players = data }, nil -- Wrap it for consistency
		end
		return nil, "JSON missing 'players' array"
	end

	return data, nil
end

-- Parses a single line from a raw list
-- Returns: steamID64 string or nil
function Parsers.ParseRawLine(lineString)
	if not lineString then
		return nil
	end

	local trimmedLine = lineString:match("^%s*(.-)%s*$") or ""

	-- Skip comments, empty lines
	if trimmedLine == "" or trimmedLine:match("^%-%-") or trimmedLine:match("^#") or trimmedLine:match("^//") then
		return nil
	end

	-- Attempt to get SteamID64
	local steamID64 = Parsers.GetSteamID64(trimmedLine)
	return steamID64
end

-- Parses a raw text file containing one SteamID per line
-- Returns: { [steamId64] = { Name="Unknown", Reason=cause }, ... } or nil, errorMsg
function Parsers.ParseRawIDs(contentString, cause)
	local entries = {}
	if not contentString or contentString == "" then
		return entries -- Return empty table, not an error
	end

	local default_reason = cause or "Unknown Source"
	local lineCount = 0
	local addedCount = 0

	-- Iterate over each line in the content string
	for line in contentString:gmatch("[^\n\r]+") do
		lineCount = lineCount + 1
		local steamID64 = Parsers.ParseRawLine(line)
		if steamID64 then
			if not entries[steamID64] then -- Avoid duplicates within the same file
				entries[steamID64] = {
					Name = "Unknown", -- Raw lists usually don't have names
					Reason = default_reason,
				}
				addedCount = addedCount + 1
			end
		end
	end

	return entries, nil -- Return the table of entries
end

-- Parse TF2 Bot Detector JSON format and convert to our database format
-- Returns: { [steamid64] = { Name="...", Reason="..." }, ... } or nil, errorMsg
function Parsers.ParseTF2BotDetector(contentString, defaultReason, existingEntries, sourceStats)
	if not contentString or contentString == "" then
		if sourceStats then
			sourceStats.errors = (sourceStats.errors or 0) + 1
		end
		return nil, "Empty content string"
	end

	local entries = existingEntries or {}
	local stats = {
		processed = 0,
		added = 0,
		existing = 0,
		updated = 0, -- New field to track updated entries
		errors = 0,
	}

	-- Try to decode JSON
	-- Ensure the JSON decoder is available before calling pcall
	if not Json or type(Json.decode) ~= "function" then
		if sourceStats then
			sourceStats.errors = (sourceStats.errors or 0) + 1
		end
		return nil, "JSON decode function is unavailable"
	end

	local success, data = pcall(Json.decode, contentString)

	if not success or type(data) ~= "table" then
		if sourceStats then
			sourceStats.errors = (sourceStats.errors or 0) + 1
		end
		return nil, "JSON decode failed: " .. tostring(data)
	end

	-- Find the players array
	local players = data.players
	if not players then
		if sourceStats then
			sourceStats.errors = (sourceStats.errors or 0) + 1
		end
		return nil, "JSON missing 'players' array"
	end

	-- Process each player
	for _, player in ipairs(players) do
		stats.processed = stats.processed + 1

		-- Get the SteamID and convert to SteamID64
		local steamID64 = Parsers.GetSteamID64(player.steamid)
		if steamID64 then
			-- Determine player name (from last_seen if available)
			local playerName = "Unknown"
			if player.last_seen and player.last_seen.player_name then
				playerName = player.last_seen.player_name
			end

			-- Get the first attribute as the reason
			local reason = defaultReason or "Unknown Source"
			if player.attributes and #player.attributes > 0 then
				-- Use first attribute, capitalized
				local firstAttribute = player.attributes[1]
				reason = firstAttribute:gsub("^%l", string.upper) -- Capitalize first letter

				-- Only use default reason if no attributes available
				-- NOT overriding attribute with defaultReason anymore
			end

			-- Add to entries if not already there
			if entries[steamID64] then
				stats.existing = stats.existing + 1

				-- "Stealer mode" - Update entry if it has better information
				local existingEntry = entries[steamID64]
				local updated = false

				-- If existing entry has unknown name and this one has a name
				if
					(existingEntry.Name == "Unknown" or existingEntry.Name == nil)
					and playerName
					and playerName ~= "Unknown"
				then
					existingEntry.Name = playerName
					updated = true
				end

				-- If existing entry has unknown reason and this one has a reason
				if
					(existingEntry.Reason == "Unknown Source" or existingEntry.Reason == nil)
					and reason
					and reason ~= "Unknown Source"
				then
					existingEntry.Reason = reason
					updated = true
				end

				-- Increment update counter if we made changes
				if updated then
					stats.updated = stats.updated + 1
				end
			else
				entries[steamID64] = {
					Name = playerName,
					Reason = reason,
				}
				stats.added = stats.added + 1
			end
		else
			stats.errors = stats.errors + 1
		end
	end

	-- Update source stats if provided
	if sourceStats then
		sourceStats.processed = (sourceStats.processed or 0) + stats.processed
		sourceStats.added = (sourceStats.added or 0) + stats.added
		sourceStats.existing = (sourceStats.existing or 0) + stats.existing
		sourceStats.updated = (sourceStats.updated or 0) + stats.updated
		sourceStats.errors = (sourceStats.errors or 0) + stats.errors
	end

	return entries, nil, stats
end

return Parsers

end)
__bundle_register("Cheater_Detection.Utils.Config", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")

local Common = require("Cheater_Detection.Utils.Common")
local json = require("Cheater_Detection.Libs.Json")
local Default_Config = require("Cheater_Detection.Utils.DefaultConfig")

local Config = {}

local Log = Common.Log
local Notify = Common.Notify
Log.Level = 0

local script_name = GetScriptName():match("([^/\\]+)%.lua$")
local folder_name = string.format([[Lua %s]], script_name)

--[[ Helper Functions ]]
function Config.GetFilePath()
	-- Note: filesystem.CreateDirectory() returns true only if it created a new directory,
	-- not if the directory already exists. The function succeeds in both cases, but
	-- returns different boolean values.
	local CreatedDirectory, fullPath = filesystem.CreateDirectory(folder_name)
	return fullPath .. "/config.cfg"
end

local function checkAllKeysExist(expectedMenu, loadedMenu)
	if type(expectedMenu) ~= "table" then
		return true
	end
	if type(loadedMenu) ~= "table" then
		return false
	end

	for key, value in pairs(expectedMenu) do
		local loadedValue = loadedMenu[key]
		if loadedValue == nil then
			return false
		end
		if type(value) == "table" then
			if not checkAllKeysExist(value, loadedValue) then
				return false
			end
		end
	end

	return true
end

--[[ Configuration Functions ]]
function Config.CreateCFG(cfgTable)
	cfgTable = cfgTable or Default_Config
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "w")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local serializedConfig = json.encode(cfgTable)
		file:write(serializedConfig)
		file:close()
		printc(100, 183, 0, 255, "Success Saving Config: Path: " .. shortFilePath)
		Common.Notify.Simple("Success! Saved Config to:", shortFilePath, 5)
	else
		local errorMessage = "Failed to open: " .. shortFilePath
		printc(255, 0, 0, 255, errorMessage)
		Common.Notify.Simple("Error", errorMessage, 5)
	end
end

function Config.LoadCFG()
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "r")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local content = file:read("*a")
		file:close()
		local loadedCfg = json.decode(content)

		if loadedCfg and checkAllKeysExist(Default_Config, loadedCfg) and not input.IsButtonDown(KEY_LSHIFT) then
			printc(100, 183, 0, 255, "Success Loading Config: Path: " .. shortFilePath)
			Common.Notify.Simple("Success! Loaded Config from", shortFilePath, 5)
			G.Menu = loadedCfg
		else
			local warningMessage = input.IsButtonDown(KEY_LSHIFT) and "Creating a new config."
				or "Config is outdated or invalid. Resetting to default."
			printc(255, 0, 0, 255, warningMessage)
			Common.Notify.Simple("Warning", warningMessage, 5)
			Config.CreateCFG(Default_Config)
			G.Menu = Default_Config
		end
	else
		local warningMessage = "Config file not found. Creating a new config."
		printc(255, 0, 0, 255, warningMessage)
		Common.Notify.Simple("Warning", warningMessage, 5)
		Config.CreateCFG(Default_Config)
		G.Menu = Default_Config
	end

	-- Set G.Config with key settings for other modules
	G.Config = G.Config or {}
	G.Config.AutoFetch = G.Menu.Main.AutoFetch -- Pull from Menu settings
end

--load on load
Config.LoadCFG()

-- Save configuration automatically when the script unloads
local function ConfigAutoSaveOnUnload()
	print("[CONFIG] Unloading script, saving configuration...")

	-- Save the current configuration state
	if G.Menu then
		Config.CreateCFG(G.Menu)
	else
		printc(255, 0, 0, 255, "[CONFIG] Warning: Unable to save config, G.Menu is nil")
	end
end

callbacks.Register("Unload", "ConfigAutoSaveOnUnload", ConfigAutoSaveOnUnload)

return Config

end)
return __bundle_require("__root")