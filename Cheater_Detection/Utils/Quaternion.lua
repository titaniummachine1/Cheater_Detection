--[[
    Quaternion Math Utilities
    For angle extrapolation and aimbot detection
    Refactored for zero-allocation performance.
]]

local Quaternion = {}

-- ============================================================================
-- Core Quaternion Functions
-- ============================================================================

-- Convert Euler angles (pitch, yaw, roll) to Quaternion
-- Angles are in degrees
function Quaternion.fromEuler(pitch, yaw, roll)
	local p = math.rad(pitch or 0) * 0.5
	local y = math.rad(yaw or 0) * 0.5
	local r = math.rad(roll or 0) * 0.5

	local cy = math.cos(y)
	local sy = math.sin(y)
	local cp = math.cos(p)
	local sp = math.sin(p)
	local cr = math.cos(r)
	local sr = math.sin(r)

	local qw = cr * cp * cy + sr * sp * sy
	local qx = sr * cp * cy - cr * sp * sy
	local qy = cr * sp * cy + sr * cp * sy
	local qz = cr * cp * sy - sr * sp * cy
	
	return qw, qx, qy, qz
end

-- Convert Quaternion components to Euler angles (pitch, yaw, roll)
-- Returns angles in degrees
function Quaternion.toEuler(qw, qx, qy, qz)
	local lenSq = qw * qw + qx * qx + qy * qy + qz * qz
	if lenSq < 0.0001 then
		return 0, 0, 0
	end

	local f = 1.0 / math.sqrt(lenSq)
	local w, x, y, z = qw * f, qx * f, qy * f, qz * f

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

	return math.deg(pitch), math.deg(yaw), math.deg(roll)
end

-- Normalize quaternion components
function Quaternion.normalize(w, x, y, z)
	local lenSq = w * w + x * x + y * y + z * z
	if lenSq < 0.0001 then
		return 1, 0, 0, 0
	end
	local f = 1.0 / math.sqrt(lenSq)
	return w * f, x * f, y * f, z * f
end

-- Multiply two quaternions
function Quaternion.multiply(w1, x1, y1, z1, w2, x2, y2, z2)
	local rw = w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2
	local rx = w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2
	local ry = w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2
	local rz = w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2
	return rw, rx, ry, rz
end

-- Spherical Linear Interpolation (SLERP)
function Quaternion.slerp(w1, x1, y1, z1, w2, x2, y2, z2, t)
	local dot = w1 * w2 + x1 * x2 + y1 * y2 + z1 * z2

	-- Take shorter path
	if dot < 0 then
		w2, x2, y2, z2 = -w2, -x2, -y2, -z2
		dot = -dot
	end

	-- Use linear interpolation for very close quaternions
	if dot > 0.9995 then
		return Quaternion.normalize(
			w1 + t * (w2 - w1),
			x1 + t * (x2 - x1),
			y1 + t * (y2 - y1),
			z1 + t * (z2 - z1)
		)
	end

	dot = math.max(-1, math.min(1, dot))
	local theta = math.acos(dot)
	local sinTheta = math.sin(theta)
	local sc1 = math.sin((1 - t) * theta) / sinTheta
	local sc2 = math.sin(t * theta) / sinTheta

	return w1 * sc1 + w2 * sc2,
		x1 * sc1 + x2 * sc2,
		y1 * sc1 + y2 * sc2,
		z1 * sc1 + z2 * sc2
end

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Calculate quaternion delta (rotation from q1 to q2)
local function quaternionDelta(w1, x1, y1, z1, w2, x2, y2, z2)
	-- conj(q1) = (w1, -x1, -y1, -z1)
	return Quaternion.multiply(w2, x2, y2, z2, w1, -x1, -y1, -z1)
end

-- ============================================================================
-- Angle Extrapolation
-- ============================================================================

-- Extrapolate angles based on history
-- history: any table with [idx] containing .pitch, .yaw, .roll fields
-- count: current number of items in history
-- ticksAhead: prediction distance
-- Returns: pitch, yaw, roll (predicted)
function Quaternion.extrapolate(history, count, ticksAhead)
	if count < 3 then
		return nil
	end

	-- Access history (assuming standard array access or HistoryManager wrap)
	local a3 = history[count]
	local a2 = history[count - 1]
	local a1 = history[count - 2]
	
	if not (a1 and a2 and a3) then return nil end

	-- To Quaternions
	local w3, x3, y3, z3 = Quaternion.fromEuler(a3.pitch, a3.yaw, a3.roll)
	local w2, x2, y2, z2 = Quaternion.fromEuler(a2.pitch, a2.yaw, a2.roll)
	local w1, x1, y1, z1 = Quaternion.fromEuler(a1.pitch, a1.yaw, a1.roll)

	-- Rotation Velocities
	local vw1, vx1, vy1, vz1 = quaternionDelta(w1, x1, y1, z1, w2, x2, y2, z2)
	local vw2, vx2, vy2, vz2 = quaternionDelta(w2, x2, y2, z2, w3, x3, y3, z3)

	-- Avg Velocity (SLERP)
	local vaw, vax, vay, vaz = Quaternion.slerp(vw1, vx1, vy1, vz1, vw2, vx2, vy2, vz2, 0.5)

	-- Extrapolate
	local rw, rx, ry, rz = w3, x3, y3, z3
	for i = 1, ticksAhead or 1 do
		rw, rx, ry, rz = Quaternion.multiply(rw, rx, ry, rz, vaw, vax, vay, vaz)
		rw, rx, ry, rz = Quaternion.normalize(rw, rx, ry, rz)
	end

	-- Back to Euler
	return Quaternion.toEuler(rw, rx, ry, rz)
end

return Quaternion
