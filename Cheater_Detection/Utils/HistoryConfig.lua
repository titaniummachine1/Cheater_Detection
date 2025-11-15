--[[ HistoryConfig.lua
     Central place to declare history retention requirements for detection modules.
     Each detection specifies how many ticks of history it needs and which fields
     should be captured so the HistoryManager can keep memory tight.
]]

local HistoryManager = require("Cheater_Detection.Utils.HistoryManager")

local HistoryConfig = {}

local F = HistoryManager.Fields

local function register(name, retention, fields)
	HistoryManager.RegisterConsumer(name, {
		retentionTicks = retention,
		fields = fields,
	})
end

local function list(...)
	return { ... }
end

-- Aim-centric detections typically need angles + head/body positions for a few ticks
register("anti_aim", 12, list(F.Angles, F.HeadHitbox, F.BodyHitbox))
register("silent_aimbot", 18, list(F.Angles, F.HeadHitbox, F.BodyHitbox, F.EyePosition))
register("plain_aimbot", 18, list(F.Angles, F.HeadHitbox, F.BodyHitbox, F.EyePosition))
register("smooth_aimbot", 30, list(F.Angles, F.HeadHitbox, F.BodyHitbox, F.EyePosition))
register("triggerbot", 12, list(F.Angles, F.HeadHitbox, F.BodyHitbox))

-- Movement checks rely on velocity/on-ground state and view offsets
register("bhop", 22, list(F.Velocity, F.OnGround, F.ViewOffset))
register("strafe_bot", 30, list(F.Velocity, F.OnGround, F.ViewOffset))
register("bot_walk", 30, list(F.Velocity, F.OnGround))
register("Duck_Speed", 40, list(F.Velocity, F.OnGround, F.ViewOffset))

-- Exploit / timing based detections need simulation time samples
register("fake_lag", 40, list(F.SimulationTime))
register("warp_dt", 66, list(F.SimulationTime))
register("warp_recharge", 66, list(F.SimulationTime))

-- Misc / manual detections with generic needs
register("manual_priority", 6, list(F.Angles))

-- Once every detection is registered, drop the legacy fallback consumer
HistoryManager.RemoveLegacyConsumer()

return HistoryConfig
