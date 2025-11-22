-- Angle Extrapolation Prototype
-- Tracks view angles over history and extrapolates future direction using quaternions
-- Now with angular acceleration tracking for circular motion prediction

-- ============================================================================
-- Quaternion Math Module
-- ============================================================================

local Quaternion = {}

local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

-- Create a new quaternion
function Quaternion.new(w, x, y, z)
	return { w = w or 1, x = x or 0, y = y or 0, z = z or 0 }
end

-- Convert Euler angles (pitch, yaw, roll) to Quaternion
-- Angles are in degrees
function Quaternion.fromEuler(pitch, yaw, roll)
	-- Convert to radians
	-- Negate pitch to match Source engine conventions
	local p = math.rad(-pitch) * 0.5
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
-- Note: atan2 is deprecated in lmaobox lua, use atan instead
function Quaternion.toEuler(q)
	-- Normalize first
	local len = math.sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z)
	if len < 0.0001 then
		return 0, 0, 0
	end

	local w, x, y, z = q.w / len, q.x / len, q.y / len, q.z / len

	-- Roll (x-axis rotation)
	local sinr_cosp = 2 * (w * x + y * z)
	local cosr_cosp = 1 - 2 * (x * x + y * y)
	local roll = math.atan(sinr_cosp, cosr_cosp)

	-- Pitch (y-axis rotation)
	local sinp = 2 * (w * y - z * x)
	local pitch
	if math.abs(sinp) >= 1 then
		pitch = math.pi / 2 * (sinp < 0 and -1 or 1)
	else
		pitch = math.asin(sinp)
	end

	-- Yaw (z-axis rotation)
	local siny_cosp = 2 * (w * z + x * y)
	local cosy_cosp = 1 - 2 * (y * y + z * z)
	local yaw = math.atan(siny_cosp, cosy_cosp)

	-- Negate pitch to match Source engine conventions
	return -math.deg(pitch), math.deg(yaw), math.deg(roll)
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

	local q2_copy = { w = q2.w, x = q2.x, y = q2.y, z = q2.z }
	if dot < 0 then
		q2_copy.w = -q2_copy.w
		q2_copy.x = -q2_copy.x
		q2_copy.y = -q2_copy.y
		q2_copy.z = -q2_copy.z
		dot = -dot
	end

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
-- History Tracking
-- ============================================================================

local angleHistory = {}
local maxHistorySize = 4
local currentTick = 0

local function addToHistory(pitch, yaw, roll, tick)
	local quat = Quaternion.fromEuler(pitch, yaw, roll)
	table.insert(angleHistory, { quat = quat, tick = tick, pitch = pitch, yaw = yaw, roll = roll })
	while #angleHistory > maxHistorySize do
		table.remove(angleHistory, 1)
	end
end

-- ============================================================================
-- Extrapolation Logic with Angular Acceleration
-- ============================================================================

local function quaternionDelta(q1, q2)
	local conj_q1 = { w = q1.w, x = -q1.x, y = -q1.y, z = -q1.z }
	return Quaternion.multiply(q2, conj_q1)
end

local function extrapolateAngles(ticksAhead)
	if #angleHistory < 3 then
		return nil -- Need at least 3 points for stable velocity
	end

	-- Get the last 3 quaternions for velocity estimation
	local q3 = angleHistory[#angleHistory].quat -- Most recent
	local q2 = angleHistory[#angleHistory - 1].quat -- One tick ago
	local q1 = angleHistory[#angleHistory - 2].quat -- Two ticks ago

	-- Calculate velocity quaternions (rotation between frames)
	local vel1 = quaternionDelta(q1, q2)
	local vel2 = quaternionDelta(q2, q3)

	-- Average the velocities for smoother prediction (no acceleration)
	local avgVel = Quaternion.slerp(vel1, vel2, 0.5)

	-- Extrapolate tick by tick using constant velocity
	local result = q3
	for i = 1, ticksAhead do
		result = Quaternion.multiply(avgVel, result)
		result = Quaternion.normalize(result)
	end

	return result
end

-- ============================================================================
-- Visualization
-- ============================================================================

local function drawExtrapolation()
	local view = client.GetPlayerView()
	if not view then
		return
	end

	local camOrigin = view.origin
	local camAngles = view.angles

	-- Current direction (white)
	local currentForward = camAngles:Forward()
	local currentWorldPos = camOrigin + currentForward * 100
	local currentScreen = client.WorldToScreen(currentWorldPos)

	if currentScreen then
		draw.Color(255, 255, 255, 255)
		draw.FilledRect(currentScreen[1] - 3, currentScreen[2] - 3, currentScreen[1] + 3, currentScreen[2] + 3)
	end

	-- Draw trajectory for 7 ticks ahead
	if #angleHistory >= 3 then
		local prevScreen = currentScreen

		for tick = 1, 7 do
			local extrapolatedQuat = extrapolateAngles(tick)
			if extrapolatedQuat then
				local pitch, yaw, roll = Quaternion.toEuler(extrapolatedQuat)
				local extrapolatedAngles = EulerAngles(pitch, yaw, roll)
				local extrapolatedForward = extrapolatedAngles:Forward()
				local extrapolatedWorldPos = camOrigin + extrapolatedForward * 100
				local extrapolatedScreen = client.WorldToScreen(extrapolatedWorldPos)

				if extrapolatedScreen and prevScreen then
					-- Color gradient from red (near) to yellow (far)
					local t = tick / 7
					local r = 255
					local g = math.floor(t * 255)
					local b = 0

					draw.Color(r, g, b, 255)
					draw.Line(prevScreen[1], prevScreen[2], extrapolatedScreen[1], extrapolatedScreen[2])

					-- Draw dot at this point
					draw.FilledRect(
						extrapolatedScreen[1] - 2,
						extrapolatedScreen[2] - 2,
						extrapolatedScreen[1] + 2,
						extrapolatedScreen[2] + 2
					)
				end

				prevScreen = extrapolatedScreen
			end
		end
	end
end

-- ============================================================================
-- Callbacks
-- ============================================================================

local function onCreateMove(cmd)
	currentTick = currentTick + 1
	local me = entities.GetLocalPlayer()
	if not me then
		return
	end

	local view = client.GetPlayerView()
	if not view then
		return
	end

	local angles = view.angles
	addToHistory(angles.pitch, angles.yaw, angles.roll, currentTick)
end

local function onDraw()
	draw.SetFont(tahoma_bold)
	drawExtrapolation()

	draw.Color(255, 255, 255, 255)
	draw.Text(10, 10, "Angle Extrapolation Prototype")
	draw.Text(10, 30, "History: " .. #angleHistory .. "/4 (need 3+ for velocity)")
	draw.Text(10, 50, "White = Current | Red->Yellow = 7 tick trajectory")

	if #angleHistory < 3 then
		draw.Color(255, 255, 0, 255)
		draw.Text(10, 70, "Warming up... move your view")
	end
end

callbacks.Register("CreateMove", "AngleExtrapolation_CreateMove", onCreateMove)
callbacks.Register("Draw", "AngleExtrapolation_Draw", onDraw)

print("[AngleExtrapolation] Loaded - Stable velocity-based prediction!")
print("[AngleExtrapolation] Predicting 7 ticks ahead with trajectory visualization")
