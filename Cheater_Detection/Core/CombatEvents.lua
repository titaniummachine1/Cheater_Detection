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

     "OnFireBullets" – every CTEFireBullets temp-entity observation
       Payload fields:
         shooterID   string   SteamID64 of the shooter
         shooterEnt  Entity   shooter entity
         shooterIdx  int      entity index (key for fireShotCache)
         eyePos      Vector3? shooter eye position at fire time (may be nil)
         tickCount   int      globals.TickCount() when observed
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
	if not attackerID or not attackerID:match("^7656119%d+$") then return end

	local victimID = tostring(Common.GetSteamID64(victimEnt))
	if not victimID or not victimID:match("^7656119%d+$") then return end

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

-- ── ProcessTempEntities → OnFireBullets ────────────────────────────────────

local function onProcessTempEntities(teTable)
	if type(teTable) ~= "table" then return end

	local curTick     = globals.TickCount()
	local localPlayer = entities.GetLocalPlayer()
	local localIdx    = localPlayer and localPlayer:GetIndex() or -1

	for ent in pairs(teTable) do
		if ent:GetNetworkName() == "CTEFireBullets" then
			local shooterIdx = ent:GetPropInt("m_iPlayer") + 1
			if shooterIdx > 1 and shooterIdx ~= localIdx then
				local shooter = entities.GetByIndex(shooterIdx)
				if shooter and shooter:IsValid() and shooter:IsAlive() and not shooter:IsDormant() then
					local shooterID = tostring(Common.GetSteamID64(shooter))
					if shooterID and shooterID:match("^7656119%d+$") then
						local origin     = shooter:GetAbsOrigin()
						local viewOffset = shooter:GetPropVector("localdata", "m_vecViewOffset[0]")
						Events.Publish("OnFireBullets", {
							shooterID  = shooterID,
							shooterEnt = shooter,
							shooterIdx = shooterIdx,
							eyePos     = (origin and viewOffset) and (origin + viewOffset) or nil,
							tickCount  = curTick,
						})
					end
				end
			end
		end
	end
end

callbacks.Unregister("ProcessTempEntities", "CombatEvents_FireBullets")
callbacks.Register("ProcessTempEntities", "CombatEvents_FireBullets", onProcessTempEntities)

return CombatEvents
