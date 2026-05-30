--[[ FireTickTracker.lua
     Shot timing for detectors (DoubleTap, SilentAim).

     Sources (A_AA.lua pattern):
       • weapon_fire  — reliable for all shooters including local (cheats often skip temp ents)
       • CTEFireBullets via ProcessTempEntities — eye pos + angles when present
]]

local Events = require("Cheater_Detection.Core.Events")
local Common = require("Cheater_Detection.Utils.Common")

local FireTickTracker = {}

local STALE_TICKS = 8

local lastFireBySteamID = {}
local fireSourceCounts  = { weapon_fire = 0, fire_bullets = 0 }

-- ── helpers ─────────────────────────────────────────────────────────────────

local function isUsableVector(v)
	return v and type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number"
end

local function buildEyePos(shooter)
	local origin = shooter:GetAbsOrigin()
	local viewOffset = shooter:GetPropVector("localdata", "m_vecViewOffset[0]")
	if not isUsableVector(origin) or not isUsableVector(viewOffset) then
		return nil
	end
	return origin + viewOffset
end

local function shouldTrackShooter(shooter)
	if not shooter or not shooter.IsValid or not shooter:IsValid() then
		return false
	end
	if not shooter:IsAlive() then
		return false
	end

	local localPlayer = entities.GetLocalPlayer()
	local localIdx = localPlayer and localPlayer:GetIndex() or -1
	if shooter:GetIndex() == localIdx and not Common.IsDebugEnabled() then
		return false
	end

	return true
end

local function publishFireSnapshot(shooter, source)
	if not shouldTrackShooter(shooter) then
		return false
	end

	local sid = Common.GetSteamID64(shooter)
	if not sid then
		return false
	end
	local shooterID = tostring(sid)
	if not Common.IsTrackablePlayerID(shooterID) then
		return false
	end

	local curTick = globals.TickCount()
	local existing = lastFireBySteamID[shooterID]
	if existing and existing.tick == curTick then
		return false
	end

	local pitch = shooter:GetPropFloat("tfnonlocaldata", "m_angEyeAngles[0]")
	local yaw   = shooter:GetPropFloat("tfnonlocaldata", "m_angEyeAngles[1]")
	if type(pitch) ~= "number" then pitch = nil end
	if type(yaw) ~= "number" then yaw = nil end

	local snapshot = {
		shooterID   = shooterID,
		entityIndex = shooter:GetIndex(),
		tick        = curTick,
		pitch       = pitch,
		yaw         = yaw,
		eyePos      = buildEyePos(shooter),
		source      = source,
	}
	lastFireBySteamID[shooterID] = snapshot
	if fireSourceCounts[source] then
		fireSourceCounts[source] = fireSourceCounts[source] + 1
	end
	Events.Publish("OnPlayerFired", snapshot)
	return true
end

-- ── weapon_fire (primary — see Prototypes/A_AA.lua event_hook) ───────────────

local function onWeaponFire(event)
	local shooter = entities.GetByUserID(event:GetInt("userid"))
	publishFireSnapshot(shooter, "weapon_fire")
end

-- ── CTEFireBullets (secondary — eye data; A_AA.lua ShotDetect pass 2) ────────

local function onProcessTempEntities(entEvtTable)
	if type(entEvtTable) ~= "table" then
		return
	end

	for ent in pairs(entEvtTable) do
		if ent:GetNetworkName() ~= "CTEFireBullets" then
			goto continue
		end

		local shooterIdx = ent:GetPropInt("m_iPlayer") + 1
		if shooterIdx <= 1 then
			goto continue
		end

		local shooter = entities.GetByIndex(shooterIdx)
		publishFireSnapshot(shooter, "fire_bullets")

		::continue::
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

function FireTickTracker.GetRecentFire(steamID, maxAgeTicks)
	if not steamID then return nil end
	local snap = lastFireBySteamID[tostring(steamID)]
	if not snap then return nil end
	if globals.TickCount() - snap.tick > (maxAgeTicks or STALE_TICKS) then
		return nil
	end
	return snap
end

function FireTickTracker.DidFireThisTick(steamID)
	local snap = lastFireBySteamID[tostring(steamID)]
	return snap and snap.tick == globals.TickCount()
end

function FireTickTracker.ClearPlayer(steamID)
	if not steamID then return end
	lastFireBySteamID[tostring(steamID)] = nil
end

function FireTickTracker.GetSourceCounts()
	return {
		weapon_fire  = fireSourceCounts.weapon_fire,
		fire_bullets = fireSourceCounts.fire_bullets,
	}
end

-- ── cleanup / registration ──────────────────────────────────────────────────

local function onPlayerGone(id)
	FireTickTracker.ClearPlayer(id)
end

Events.Subscribe("OnPlayerDisconnect", onPlayerGone)
Events.Subscribe("OnPlayerRemoved", onPlayerGone)

Events.Register("FireGameEvent", "FireTickTracker_WeaponFire", onWeaponFire, "weapon_fire")

callbacks.Unregister("ProcessTempEntities", "FireTickTracker_FireBullets")
callbacks.Register("ProcessTempEntities", "FireTickTracker_FireBullets", onProcessTempEntities)

return FireTickTracker
