--[[ FireTickTracker.lua
     Observes CTEFireBullets temp entities once per frame batch.
     Does not retain temp-entity handles — only per-shooter fire snapshots
     (tick, aim angles, eye position) for detectors that care who fired when.
]]

local Events = require("Cheater_Detection.Core.Events")
local Common = require("Cheater_Detection.Utils.Common")

local FireTickTracker = {}

local STALE_TICKS       = 8
local lastFireBySteamID = {}

local function reuseVec(dst, src)
	if not src then
		return nil
	end
	if type(dst) ~= "table" then
		dst = {}
	end
	dst.x = src.x
	dst.y = src.y
	dst.z = src.z
	return dst
end

local function readFireAngles(teEnt)
	local pitch = teEnt:GetPropFloat("m_vecAngles[0]")
	local yaw   = teEnt:GetPropFloat("m_vecAngles[1]")
	if type(pitch) ~= "number" or type(yaw) ~= "number" then
		return nil, nil
	end
	return pitch, yaw
end

local function buildEyePos(shooter)
	local origin = shooter:GetAbsOrigin()
	local viewOffset = shooter:GetPropVector("localdata", "m_vecViewOffset[0]")
	if origin and viewOffset then
		return origin + viewOffset
	end
	return nil
end

local function onProcessTempEntities(teTable)
	if type(teTable) ~= "table" then
		return
	end

	local curTick     = globals.TickCount()
	local localPlayer = entities.GetLocalPlayer()
	local localIdx    = localPlayer and localPlayer:GetIndex() or -1

	for ent in pairs(teTable) do
		if ent:GetNetworkName() ~= "CTEFireBullets" then
			goto continue
		end

		local shooterIdx = ent:GetPropInt("m_iPlayer") + 1
		if shooterIdx <= 1 or shooterIdx == localIdx then
			goto continue
		end

		local shooter = entities.GetByIndex(shooterIdx)
		if not shooter or not shooter:IsValid() or not shooter:IsAlive() or shooter:IsDormant() then
			goto continue
		end

		local shooterID = tostring(Common.GetSteamID64(shooter))
		if not shooterID or not shooterID:match("^7656119%d+$") then
			goto continue
		end

		local pitch, yaw = readFireAngles(ent)
		if not pitch then
			goto continue
		end

		local prev = lastFireBySteamID[shooterID]
		local eyePos = buildEyePos(shooter)
		local snapshot = {
			shooterID   = shooterID,
			entityIndex = shooterIdx,
			tick        = curTick,
			pitch       = pitch,
			yaw         = yaw,
			eyePos      = reuseVec(prev and prev.eyePos, eyePos),
		}
		lastFireBySteamID[shooterID] = snapshot

		Events.Publish("OnPlayerFired", snapshot)

		::continue::
	end
end

function FireTickTracker.GetRecentFire(steamID, maxAgeTicks)
	if not steamID then
		return nil
	end
	local snap = lastFireBySteamID[tostring(steamID)]
	if not snap then
		return nil
	end
	local age = globals.TickCount() - snap.tick
	if age > (maxAgeTicks or STALE_TICKS) then
		return nil
	end
	return snap
end

function FireTickTracker.DidFireThisTick(steamID)
	local snap = lastFireBySteamID[tostring(steamID)]
	return snap ~= nil and snap.tick == globals.TickCount()
end

function FireTickTracker.ClearPlayer(steamID)
	if steamID then
		lastFireBySteamID[tostring(steamID)] = nil
	end
end

Events.Subscribe("OnPlayerDisconnect", function(id)
	FireTickTracker.ClearPlayer(id)
end)

Events.Subscribe("OnPlayerRemoved", function(id)
	FireTickTracker.ClearPlayer(id)
end)

callbacks.Unregister("ProcessTempEntities", "FireTickTracker_FireBullets")
callbacks.Register("ProcessTempEntities", "FireTickTracker_FireBullets", onProcessTempEntities)

return FireTickTracker
