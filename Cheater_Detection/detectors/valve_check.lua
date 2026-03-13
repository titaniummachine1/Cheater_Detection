--[[ detectors/valve_check.lua
     Valve Employee Detector (adapted from v2.2)
     
     Detection Layers (in order):
       1. SteamID64 static list (instant, 260+ known employees)
       2. Item badge (DefIndex 11) or item quality (Quality 8) inspection
       3. Steam Group async membership check (paged, rate-limited via HttpQueue)
     
     Private Profile Safety:
       - Layer 3 ONLY marks VALVE if the profile XML *explicitly* contains
         the Group ID. Missing or empty data = no flag.
       - Bots are always skipped in normal mode.
]]

local SteamLookup = require("Cheater_Detection.services.steam_lookup")
local ValveData = require("Cheater_Detection.data.valve_data")
local Constants = require("Cheater_Detection.core.constants")
local EventBus = require("Cheater_Detection.core.event_bus")
local Common = require("Cheater_Detection.Utils.Common")
local Database = require("Cheater_Detection.Database.Database")

local ValveCheck = {}

-- Rate-limit item checks per player: once per 60s
local lastItemCheck = {}

-- Track which players had their group already checked this session
local groupCheckDone = {}

-- Layer 1: SteamID64 static lookup
local function isKnownValveID64(s64)
	if not s64 then return false end
	return ValveData.KnownSteamID64s[tostring(s64)] == true
end

-- Layer 1b: Legacy Steam2 lookup (manual list fallback)
local function isKnownValveIDSteam2(s2)
	if not s2 then return false end
	return ValveData.ManualIDsSteam2[s2] == true
end

-- Layer 2: Item + Badge check (pcall-safe)
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

-- Apply the VALVE flag and persist
local function applyValveFlag(playerState, reason)
	local oldFlags = playerState.flags
	playerState.flags = playerState.flags | Constants.Flags.VALVE

	if playerState.flags ~= oldFlags then
		-- Print to console exactly which SteamID matched and why
		printc(255, 215, 0, 255, string.format(
			"[ValveCheck] VALVE EMPLOYEE detected! SteamID64=%s Name=%s Reason=%s",
			playerState.id,
			playerState.wrap:GetName(),
			reason
		))
		Database.UpsertCheater(playerState.id, {
			name  = playerState.wrap:GetName(),
			reason = reason,
			flags  = playerState.flags,
			score  = playerState.score,
		})
		EventBus.Publish("OnPlayerStateChange", playerState, reason)
	end
end

-- Main processor called every frame per player (rate-limited internally)
function ValveCheck.ProcessPlayer(playerState)
	assert(playerState, "ValveCheck.ProcessPlayer: playerState missing")

	local id = playerState.id
	local now = globals.CurTime()

	-- ── Layer 1: SteamID64 instant check ──────────────────────────────────────
	if isKnownValveID64(id) then
		applyValveFlag(playerState, "Known Valve SteamID")
		return -- No need to do further checks
	end

	-- ── Layer 1b: Legacy Steam2 fallback ──────────────────────────────────────
	local ply = playerState.wrap:GetRawEntity()
	if ply then
		local s2 = Common.GetSteamID(ply)
		if isKnownValveIDSteam2(s2) then
			applyValveFlag(playerState, "Known Valve SteamID (Legacy)")
			return
		end
	end

	-- ── Layer 2: Item Check (throttled to once per 60s) ───────────────────────
	if not lastItemCheck[id] or (now - lastItemCheck[id] > 60) then
		lastItemCheck[id] = now
		if ply then
			local found, reason = checkPlayerItems(ply)
			if found then
				applyValveFlag(playerState, reason)
				return
			end
		end
	end

	-- ── Layer 3: Async Steam Group check (once per session per player) ────────
	if not groupCheckDone[id] and not playerState.externalChecked then
		groupCheckDone[id] = true

		SteamLookup.CheckProfileAsync(id, function(results)
			-- Only flag VALVE if the XML *contains* the GroupID
			-- This naturally handles private profiles (they return no group data)
			if results.isValve then
				applyValveFlag(playerState, "Valve Steam Group Member")
			end

			-- Also pick up ban flags from same call
			if results.vacBanned then
				local oldFlags = playerState.flags
				playerState.flags = playerState.flags | Constants.Flags.VAC_BANNED
				if playerState.flags ~= oldFlags then
					Database.UpsertCheater(id, {
						name  = playerState.wrap:GetName(),
						reason = "VAC Ban on Record",
						flags  = playerState.flags,
						score  = playerState.score,
					})
					EventBus.Publish("OnPlayerStateChange", playerState, "VAC Ban on Record")
				end
			end

			if results.tradeBanned then
				local oldFlags = playerState.flags
				playerState.flags = playerState.flags | Constants.Flags.COMM_BANNED
				if playerState.flags ~= oldFlags then
					Database.UpsertCheater(id, {
						name  = playerState.wrap:GetName(),
						reason = "Community/Trade Ban",
						flags  = playerState.flags,
						score  = playerState.score,
					})
					EventBus.Publish("OnPlayerStateChange", playerState, "Community/Trade Ban")
				end
			end

			playerState.externalChecked = true
			playerState.flags = playerState.flags | Constants.Flags.CHECKED
		end)
	end
end

-- Reset session state on new map
EventBus.Subscribe("OnPlayerDisconnect", function(id)
	lastItemCheck[id] = nil
	groupCheckDone[id] = nil
end)

return ValveCheck
