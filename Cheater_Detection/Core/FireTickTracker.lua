--[[ FireTickTracker.lua — CTEFireBullets → per-shooter fire snapshot (no temp-ent storage). ]]

local Events = require("Cheater_Detection.Core.Events")
local Common = require("Cheater_Detection.Utils.Common")

local FireTickTracker = {}

local STALE_TICKS       = 8
local lastFireBySteamID = {}

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

local function onProcessTempEntities(teTable)
	if type(teTable) ~= "table" then return end

	local curTick = globals.TickCount()
	local localPlayer = entities.GetLocalPlayer()
	local localIdx = localPlayer and localPlayer:GetIndex() or -1

	for ent in pairs(teTable) do
		if ent:GetNetworkName() ~= "CTEFireBullets" then goto continue end

		local shooterIdx = ent:GetPropInt("m_iPlayer") + 1
		if shooterIdx <= 1 or shooterIdx == localIdx then goto continue end

		local shooter = entities.GetByIndex(shooterIdx)
		if not shooter or not shooter:IsValid() or not shooter:IsAlive() or shooter:IsDormant() then
			goto continue
		end

		local sid = Common.GetSteamID64(shooter)
		if not sid then goto continue end
		local shooterID = tostring(sid)
		if not shooterID:match("^7656119%d+$") then goto continue end

		local pitch = ent:GetPropFloat("m_vecAngles[0]")
		local yaw   = ent:GetPropFloat("m_vecAngles[1]")
		if type(pitch) ~= "number" or type(yaw) ~= "number" then goto continue end

		local eyePos = buildEyePos(shooter)

		local snapshot = {
			shooterID   = shooterID,
			entityIndex = shooterIdx,
			tick        = curTick,
			pitch       = pitch,
			yaw         = yaw,
			eyePos      = eyePos,
		}
		lastFireBySteamID[shooterID] = snapshot
		Events.Publish("OnPlayerFired", snapshot)

		::continue::
	end
end

function FireTickTracker.GetRecentFire(steamID, maxAgeTicks)
	if not steamID then return nil end
	local snap = lastFireBySteamID[tostring(steamID)]
	if not snap then return nil end
	if globals.TickCount() - snap.tick > (maxAgeTicks or STALE_TICKS) then return nil end
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

local function onPlayerGone(id)
	FireTickTracker.ClearPlayer(id)
end

Events.Subscribe("OnPlayerDisconnect", onPlayerGone)
Events.Subscribe("OnPlayerRemoved", onPlayerGone)

callbacks.Unregister("ProcessTempEntities", "FireTickTracker_FireBullets")
callbacks.Register("ProcessTempEntities", "FireTickTracker_FireBullets", onProcessTempEntities)

return FireTickTracker
