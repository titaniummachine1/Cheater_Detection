--[[
    Quaternion Math Utilities
    For angle extrapolation and aimbot detection
]]

local Quaternion = {}

-- ============================================================================
-- Core Quaternion Functions
-- ============================================================================

-- Create a new quaternion
function Quaternion.new(w, x, y, z)
	return { w = w or 1, x = x or 0, y = y or 0, z = z or 0 }
end

-- Convert Euler angles (pitch, yaw, roll) to Quaternion
-- Angles are in degrees
-- NOTE: Negates pitch to match Source engine conventions
function Quaternion.fromEuler(pitch, yaw, roll)
	local p = math.rad(-pitch) * 0.5 -- Negate for Source engine
	local y = math.rad(yaw) * 0.5
	local r = math.rad(roll) * 0.5

	local cy = math.cos(y)
	local sy = math.sin(y)
	local cp = math.cos(p)
	local sp = math.sin(p)
	local cr = math.cos(r)
	local sr = math.sin(r)

	return Quaternion.new(
		cr * cp * cy + sr * sp * sy, -- w
		sr * cp * cy - cr * sp * sy, -- x
		cr * sp * cy + sr * cp * sy, -- y
		cr * cp * sy - sr * sp * cy -- z
	)
end

-- Convert Quaternion to Euler angles (pitch, yaw, roll)
-- Returns angles in degrees
-- NOTE: Negates pitch to match Source engine conventions
function Quaternion.toEuler(q)
	local len = math.sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z)
	if len < 0.0001 then
		return 0, 0, 0
	end

	local w, x, y, z = q.w / len, q.x / len, q.y / len, q.z / len

	-- Roll
	local sinr_cosp = 2 * (w * x + y * z)
	local cosr_cosp = 1 - 2 * (x * x + y * y)
	local roll = math.atan(sinr_cosp, cosr_cosp)

	-- Pitch
	local sinp = 2 * (w * y - z * x)
	local pitch
	if math.abs(sinp) >= 1 then
		pitch = math.pi / 2 * (sinp < 0 and -1 or 1)
	else
		pitch = math.asin(sinp)
	end

	-- Yaw
	local siny_cosp = 2 * (w * z + x * y)
	local cosy_cosp = 1 - 2 * (y * y + z * z)
	local yaw = math.atan(siny_cosp, cosy_cosp)

	return -math.deg(pitch), math.deg(yaw), math.deg(roll) -- Negate pitch
end

-- Normalize a quaternion
function Quaternion.normalize(q)
	local len = math.sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z)
	if len < 0.0001 then
		return Quaternion.new(1, 0, 0, 0)
	end
	return Quaternion.new(q.w / len, q.x / len, q.y / len, q.z / len)
end

-- Multiply two quaternions
function Quaternion.multiply(q1, q2)
	return Quaternion.new(
		q1.w * q2.w - q1.x * q2.x - q1.y * q2.y - q1.z * q2.z,
		q1.w * q2.x + q1.x * q2.w + q1.y * q2.z - q1.z * q2.y,
		q1.w * q2.y - q1.x * q2.z + q1.y * q2.w + q1.z * q2.x,
		q1.w * q2.z + q1.x * q2.y - q1.y * q2.x + q1.z * q2.w
	)
end

-- Spherical Linear Interpolation (SLERP)
function Quaternion.slerp(q1, q2, t)
	local dot = q1.w * q2.w + q1.x * q2.x + q1.y * q2.y + q1.z * q2.z

	-- Take shorter path
	local q2_copy = { w = q2.w, x = q2.x, y = q2.y, z = q2.z }
	if dot < 0 then
		q2_copy.w = -q2_copy.w
		q2_copy.x = -q2_copy.x
		q2_copy.y = -q2_copy.y
		q2_copy.z = -q2_copy.z
		dot = -dot
	end

	-- Use linear interpolation for very close quaternions
	if dot > 0.9995 then
		return Quaternion.normalize(
			Quaternion.new(
				q1.w + t * (q2_copy.w - q1.w),
				q1.x + t * (q2_copy.x - q1.x),
				q1.y + t * (q2_copy.y - q1.y),
				q1.z + t * (q2_copy.z - q1.z)
			)
		)
	end

	dot = math.max(-1, math.min(1, dot))
	local theta = math.acos(dot)
	local sinTheta = math.sin(theta)
	local w1 = math.sin((1 - t) * theta) / sinTheta
	local w2 = math.sin(t * theta) / sinTheta

	return Quaternion.new(
		q1.w * w1 + q2_copy.w * w2,
		q1.x * w1 + q2_copy.x * w2,
		q1.y * w1 + q2_copy.y * w2,
		q1.z * w1 + q2_copy.z * w2
	)
end

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Calculate quaternion delta (rotation from q1 to q2)
local function quaternionDelta(q1, q2)
	local conj_q1 = { w = q1.w, x = -q1.x, y = -q1.y, z = -q1.z }
	return Quaternion.multiply(q2, conj_q1)
end

-- ============================================================================
-- Angle Extrapolation
-- ============================================================================

-- Extrapolate angles based on history
-- angleHistory: array of {pitch, yaw, roll} tables (at least 3 required)
-- ticksAhead: how many ticks to predict (default 1)
-- Returns: predicted {pitch, yaw, roll} or nil
function Quaternion.extrapolateAngle(angleHistory, ticksAhead)
	ticksAhead = ticksAhead or 1

	if #angleHistory < 3 then
		return nil -- Need at least 3 points
	end

	-- Convert last 3 Euler angles to quaternions
	local q3 = Quaternion.fromEuler(
		angleHistory[#angleHistory].pitch,
		angleHistory[#angleHistory].yaw,
		angleHistory[#angleHistory].roll or 0
	)
	local q2 = Quaternion.fromEuler(
		angleHistory[#angleHistory - 1].pitch,
		angleHistory[#angleHistory - 1].yaw,
		angleHistory[#angleHistory - 1].roll or 0
	)
	local q1 = Quaternion.fromEuler(
		angleHistory[#angleHistory - 2].pitch,
		angleHistory[#angleHistory - 2].yaw,
		angleHistory[#angleHistory - 2].roll or 0
	)

	-- Calculate velocity quaternions
	local vel1 = quaternionDelta(q1, q2)
	local vel2 = quaternionDelta(q2, q3)

	-- Average velocities for smoother prediction
	local avgVel = Quaternion.slerp(vel1, vel2, 0.5)

	-- Extrapolate tick by tick
	local result = q3
	for i = 1, ticksAhead do
		result = Quaternion.multiply(avgVel, result)
		result = Quaternion.normalize(result)
	end

	-- Convert back to Euler
	local pitch, yaw, roll = Quaternion.toEuler(result)
	return { pitch = pitch, yaw = yaw, roll = roll }
end

return Quaternion
