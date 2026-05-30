--[[ Core/CombatEvents.lua
     Centralised hub for combat game events.

     Resolves entities, SteamIDs and weapon info ONCE per event, then
     publishes clean structured payloads that detectors subscribe to via
     Events.Subscribe — eliminating the redundant entity/SteamID lookups
     that previously happened independently in every detector.

     Published events
     ─────────────────
     "OnHitscanHit"  – every valid hitscan player_hurt event
       Payload fields:
         attackerID        string   SteamID64 of the attacker
         victimID          string   SteamID64 of the victim
         attackerEnt       Entity   attacker entity (valid at event time)
         victimEnt         Entity   victim entity   (valid at event time)
         attackerUID       int      attacker userid  (for per-uid throttles)
         tickCount         int      globals.TickCount() at event time
         weaponID          int      event weaponid field
         weaponName        string   event weapon string field
         weaponClass       string   HitscanInfo classification string
         weaponSpread      number   HitscanInfo spread
         projType          int      HitscanInfo.FIREMODE constant
         damage            int      damageamount from event
         crit              bool     true if crit hit
         minicrit          bool     true if minicrit hit
         victimHealthAfter int      victim HP after the hit

     Fire detection: Core/FireTickTracker.lua ("OnPlayerFired" via weapon_fire + CTEFireBullets).
]]

local Events      = require("Cheater_Detection.Core.Events")
local Common      = require("Cheater_Detection.Utils.Common")
local HitscanInfo = require("Cheater_Detection.Utils.HitscanInfo")

local CombatEvents = {}

-- ── player_hurt → OnHitscanHit ─────────────────────────────────────────────

local function onPlayerHurt(event)
	local attackerUID = event:GetInt("attacker")
	local victimUID   = event:GetInt("userid")
	if not attackerUID or not victimUID or attackerUID == victimUID then return end

	local attackerEnt = entities.GetByUserID(attackerUID)
	if not attackerEnt or not attackerEnt:IsValid() then return end

	local victimEnt = entities.GetByUserID(victimUID)
	if not victimEnt or not victimEnt:IsValid() then return end

	local attackerID = tostring(Common.GetSteamID64(attackerEnt))
	if not Common.IsTrackablePlayerID(attackerID) then return end

	-- Victim may be a bot (no real SteamID). Keep the event — attacker-side
	-- detectors (DoubleTap, etc.) only need the attacker. Pass victimID as-is.
	local victimID = tostring(Common.GetSteamID64(victimEnt) or victimEnt:GetIndex())

	local weaponID   = event:GetInt("weaponid")
	local weaponName = event.GetString and event:GetString("weapon") or nil
	local isHitscan, weaponClass, weaponSpread, projType =
		HitscanInfo.Classify(attackerEnt, weaponName, weaponID)

	if not isHitscan then return end

	Events.Publish("OnHitscanHit", {
		attackerID        = attackerID,
		victimID          = victimID,
		attackerEnt       = attackerEnt,
		victimEnt         = victimEnt,
		attackerUID       = attackerUID,
		tickCount         = globals.TickCount(),
		weaponID          = weaponID,
		weaponName        = weaponName,
		weaponClass       = weaponClass,
		weaponSpread      = weaponSpread,
		projType          = projType,
		damage            = event:GetInt("damageamount") or 0,
		crit              = (event:GetInt("crit") or 0) ~= 0,
		minicrit          = (event:GetInt("minicrit") or 0) ~= 0,
		victimHealthAfter = event:GetInt("health") or 0,
	})
end

Events.Register("FireGameEvent", "CombatEvents_PlayerHurt", onPlayerHurt, "player_hurt")

return CombatEvents
