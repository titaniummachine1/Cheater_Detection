--[[ detectors/valve_check.lua
     Valve Employee Detector

     Detection Layers (run every ProcessPlayer tick):
       1. SteamID64 static list (instant)
       2. Item badge / Valve-quality item (throttled: every 30s)
       3. Async Steam Group + ban profile check
          - Retried every PROFILE_RECHECK_INTERVAL seconds if not yet confirmed
          - A failed/empty HTTP response does NOT permanently set externalChecked;
            the player will be re-queued on the next interval.

     Console debug output (requires G.Menu.Advanced.debug = true):
       Logs every check attempt, result, and skip reason.
]]

local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local ValveData     = require("Cheater_Detection.data.valve_data")
local ValveEmployees = require("Cheater_Detection.Database.ValveEmployees")
local Constants     = require("Cheater_Detection.core.constants")
local EventBus      = require("Cheater_Detection.core.event_bus")
local Common        = require("Cheater_Detection.Utils.Common")
local Database      = require("Cheater_Detection.Database.Database")
local Logger        = require("Cheater_Detection.Utils.Logger")
local G             = require("Cheater_Detection.Utils.Globals")
local FastPlayers   = require("Cheater_Detection.Utils.FastPlayers")

local ValveCheck = {}

-- How often (seconds) to re-attempt the async profile check per player
local PROFILE_RECHECK_INTERVAL = 120 -- Re-verify every 2 minutes

-- Track last item check time per player: id -> CurTime
local lastItemCheck = {}

-- Track last async profile-check TIME per player: id -> CurTime
-- (NOT a boolean; we re-check periodically even after success)
local lastProfileCheck = {}

-- Layer 1: Check both static tables (valve_data AND ValveEmployees)
local function isKnownValveID64(s64)
	if not s64 then return false end
	local key = tostring(s64)
	if ValveData.KnownSteamID64s[key] == true then return true end
	if ValveEmployees.IsEmployee and ValveEmployees.IsEmployee(key) then return true end
	if type(ValveEmployees.List) == "table" and ValveEmployees.List[key] then return true end
	return false
end

-- Layer 1b: Legacy Steam2 fallback
local function isKnownValveIDSteam2(s2)
	return s2 ~= nil and ValveData.ManualIDsSteam2[s2] == true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Apply VALVE flag (idempotent – only logs/saves on first apply)
-- ──────────────────────────────────────────────────────────────────────────────
local function applyValveFlag(playerState, reason)
	local oldFlags = playerState.flags
	playerState.flags = playerState.flags | Constants.Flags.VALVE

	if playerState.flags ~= oldFlags then
		printc(255, 215, 0, 255, string.format(
			"[ValveCheck] VALVE EMPLOYEE detected! SteamID64=%s  Name=%s  Reason=%s",
			playerState.id, playerState.wrap:GetName(), reason
		))
		Database.UpsertCheater(playerState.id, {
			name   = playerState.wrap:GetName(),
			reason = reason,
			flags  = playerState.flags,
			score  = playerState.score,
		})
		EventBus.Publish("OnPlayerStateChange", playerState, reason)
	end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Apply VAC ban flag
-- ──────────────────────────────────────────────────────────────────────────────
local function applyVacFlag(playerState)
	local oldFlags = playerState.flags
	playerState.flags = playerState.flags | Constants.Flags.VAC_BANNED
	if playerState.flags ~= oldFlags then
		Logger.Info("ValveCheck", string.format(
			"VAC ban confirmed – SteamID64=%s  Name=%s",
			playerState.id, playerState.wrap:GetName()
		))
		Database.UpsertCheater(playerState.id, {
			name   = playerState.wrap:GetName(),
			reason = "VAC Ban on Record",
			flags  = playerState.flags,
			score  = playerState.score,
		})
		EventBus.Publish("OnPlayerStateChange", playerState, "VAC Ban on Record")
	end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Apply Community/Trade ban flag
-- ──────────────────────────────────────────────────────────────────────────────
local function applyCommBanFlag(playerState)
	local oldFlags = playerState.flags
	playerState.flags = playerState.flags | Constants.Flags.COMM_BANNED
	if playerState.flags ~= oldFlags then
		Logger.Info("ValveCheck", string.format(
			"Community/Trade ban confirmed – SteamID64=%s  Name=%s",
			playerState.id, playerState.wrap:GetName()
		))
		Database.UpsertCheater(playerState.id, {
			name   = playerState.wrap:GetName(),
			reason = "Community/Trade Ban",
			flags  = playerState.flags,
			score  = playerState.score,
		})
		EventBus.Publish("OnPlayerStateChange", playerState, "Community/Trade Ban")
	end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Layer 2: Item + Badge check (pcall-safe)
-- ──────────────────────────────────────────────────────────────────────────────
local function checkPlayerItems(ply)
	for slot = 0, 18 do
		local okEnt, ent = pcall(ply.GetEntityForLoadoutSlot, ply, slot)
		if okEnt and ent then
			local okQ, quality = pcall(ent.GetPropInt, ent, "m_iEntityQuality")
			local okD, defIdx  = pcall(ent.GetPropInt, ent, "m_iItemDefinitionIndex")

			if okQ and quality == ValveData.QualityID then
				return true, "Valve-Quality Item (slot " .. slot .. ")"
			end
			if okD and defIdx == ValveData.BadgeDefIndex then
				return true, "Valve Employee Badge (slot " .. slot .. ")"
			end
		end
	end
	return false, ""
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Main processor
-- ──────────────────────────────────────────────────────────────────────────────
function ValveCheck.ProcessPlayer(playerState)
	assert(playerState, "ValveCheck.ProcessPlayer: playerState missing")

	local id  = playerState.id
	local now = globals.CurTime()
	local isDebug = G and G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug

	-- Skip local player unless debug mode is enabled
	if not isDebug then
		local localPlayer = FastPlayers.GetLocal()
		if localPlayer then
			local localSteamID = localPlayer:GetSteamID64()
			if localSteamID and tostring(localSteamID) == tostring(id) then
				return -- Skip local player check
			end
		end
	end

	-- ── Layer 1: SteamID64 instant check ──────────────────────────────────────
	-- Always log in debug so user can verify their ID matches what the engine sees
	if isDebug then
		Logger.Debug("ValveCheck", string.format(
			"Processing ID=%s Name=%s  inKnownList=%s",
			tostring(id), playerState.wrap:GetName(), tostring(isKnownValveID64(id))
		))
	end

	if isKnownValveID64(id) then
		applyValveFlag(playerState, "Known Valve SteamID")
		return
	end

	-- ── Layer 1b: Legacy Steam2 fallback ──────────────────────────────────────
	local ply = playerState.wrap:GetRawEntity()
	if ply then
		local s2 = Common.GetSteamID(ply)
		if isKnownValveIDSteam2(s2) then
			if isDebug then Logger.Debug("ValveCheck", id .. " matched legacy Steam2 list (" .. tostring(s2) .. ")") end
			applyValveFlag(playerState, "Known Valve SteamID (Legacy)")
			return
		end
	end

	-- ── Layer 2: Item / Badge check (every 30s) ─────────────────────────────
	local lastItem = lastItemCheck[id]
	if not lastItem or (now - lastItem > 30) then
		lastItemCheck[id] = now
		if ply then
			if isDebug then Logger.Debug("ValveCheck", id .. " – running item/badge check") end
			local found, reason = checkPlayerItems(ply)
			if found then
				if isDebug then Logger.Debug("ValveCheck", id .. " – item/badge HIT: " .. reason) end
				applyValveFlag(playerState, reason)
				return
			else
				if isDebug then Logger.Debug("ValveCheck", id .. " – item/badge: no match") end
			end
		end
	end

	-- ── Layer 3: Async profile check (VAC / Comm ban / Valve Group) ──────────
	-- Retry every PROFILE_RECHECK_INTERVAL seconds regardless of previous outcome.
	-- This means failed HTTP responses don't permanently skip a player.
	local lastProfile = lastProfileCheck[id]
	if not lastProfile or (now - lastProfile > PROFILE_RECHECK_INTERVAL) then
		lastProfileCheck[id] = now
		if isDebug then Logger.Debug("ValveCheck", id .. " – queuing async profile check") end

		SteamLookup.CheckProfileAsync(id, function(results)
			if not results then
				if isDebug then Logger.Debug("ValveCheck", id .. " – async profile check returned nil (HTTP failed)") end
				-- Reset timer so it retries sooner (10s) instead of waiting 2 min
				lastProfileCheck[id] = now - (PROFILE_RECHECK_INTERVAL - 10)
				return
			end

			if isDebug then
				Logger.Debug("ValveCheck", string.format(
					"%s – profile check result: isValve=%s vacBanned=%s tradeBanned=%s",
					id, tostring(results.isValve), tostring(results.vacBanned), tostring(results.tradeBanned)
				))
			end

			if results.isValve then
				applyValveFlag(playerState, "Valve Steam Group Member")
			end
			if results.vacBanned then
				applyVacFlag(playerState)
			end
			if results.tradeBanned then
				applyCommBanFlag(playerState)
			end

			-- Mark CHECKED flag only when we actually got a valid response
			playerState.externalChecked = true
			playerState.flags = playerState.flags | Constants.Flags.CHECKED
		end)
	end
end

-- Reset per-player timers on disconnect so rejoining players are re-checked
EventBus.Subscribe("OnPlayerDisconnect", function(id)
	lastItemCheck[id]   = nil
	lastProfileCheck[id] = nil
end)

return ValveCheck
