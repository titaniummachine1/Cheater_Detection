--[[ FireTickTracker.lua — CTEFireBullets → per-shooter fire snapshot (no temp-ent storage). ]]

local Events = require("Cheater_Detection.Core.Events")
local Common = require("Cheater_Detection.Utils.Common")

local FireTickTracker = {}

local STALE_TICKS       = 8
local lastFireBySteamID = {}

local function copyEyePos(prev, src)
	if not src then return prev end
	local t = type(prev) == "table" and prev or {}
	t.x, t.y, t.z = src.x, src.y, src.z
	return t
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

		local shooterID = tostring(Common.GetSteamID64(shooter))
		if not shooterID:match("^7656119%d+$") then goto continue end

		local pitch = ent:GetPropFloat("m_vecAngles[0]")
		local yaw   = ent:GetPropFloat("m_vecAngles[1]")
		if not pitch or not yaw then goto continue end

		local prev = lastFireBySteamID[shooterID]
		local origin = shooter:GetAbsOrigin()
		local viewOffset = shooter:GetPropVector("localdata", "m_vecViewOffset[0]")
		local eyePos = (origin and viewOffset) and (origin + viewOffset) or nil

		local snapshot = {
			shooterID   = shooterID,
			entityIndex = shooterIdx,
			tick        = curTick,
			pitch       = pitch,
			yaw         = yaw,
			eyePos      = copyEyePos(prev and prev.eyePos, eyePos),
		}
		lastFireBySteamID[shooterID] = snapshot
		Events.Publish("OnPlayerFired", snapshot)

		::continue::
	end
end

function FireTickTracker.GetRecentFire(steamID, maxAgeTicks)
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
