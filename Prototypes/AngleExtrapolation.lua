-- Angle Extrapolation Prototype
-- Pure quaternion math + EMA smoothing for circular motion prediction
-- 60 tick history, weighted velocity averaging for responsiveness

local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

-- ============================================================================
-- Quaternion Math (all rotation math done here, never on Euler directly)
-- ============================================================================

local Quat = {}

function Quat.new(w, x, y, z)
	return { w = w or 1, x = x or 0, y = y or 0, z = z or 0 }
end

function Quat.identity()
	return Quat.new(1, 0, 0, 0)
end

function Quat.fromEuler(pitch, yaw, roll)
	local hp = math.rad(-pitch) * 0.5
	local hy = math.rad(yaw) * 0.5
	local hr = math.rad(roll) * 0.5
	local cy, sy = math.cos(hy), math.sin(hy)
	local cp, sp = math.cos(hp), math.sin(hp)
	local cr, sr = math.cos(hr), math.sin(hr)
	return Quat.new(
		cr * cp * cy + sr * sp * sy,
		sr * cp * cy - cr * sp * sy,
		cr * sp * cy + sr * cp * sy,
		cr * cp * sy - sr * sp * cy
	)
end

function Quat.toEuler(q)
	local len = math.sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z)
	if len < 1e-6 then
		return 0, 0, 0
	end
	local w, x, y, z = q.w / len, q.x / len, q.y / len, q.z / len
	local sinp = 2 * (w * y - z * x)
	local pitch = math.abs(sinp) >= 1 and (math.pi / 2 * (sinp < 0 and -1 or 1)) or math.asin(sinp)
	local yaw = math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
	local roll = math.atan(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
	return -math.deg(pitch), math.deg(yaw), math.deg(roll)
end

function Quat.normalize(q)
	local len = math.sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z)
	if len < 1e-6 then
		return Quat.identity()
	end
	return Quat.new(q.w / len, q.x / len, q.y / len, q.z / len)
end

function Quat.conjugate(q)
	return Quat.new(q.w, -q.x, -q.y, -q.z)
end

function Quat.multiply(a, b)
	return Quat.new(
		a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
		a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
	)
end

-- q2 * conj(q1) = rotation from q1 to q2
function Quat.delta(q1, q2)
	return Quat.normalize(Quat.multiply(q2, Quat.conjugate(q1)))
end

-- Quaternion power for fractional/multiple rotations
function Quat.pow(q, t)
	q = Quat.normalize(q)
	local len = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
	if len < 1e-6 then
		return Quat.identity()
	end
	local angle = 2 * math.atan(len, q.w)
	local newAngle = angle * t
	local s = math.sin(newAngle * 0.5) / len
	return Quat.new(math.cos(newAngle * 0.5), q.x * s, q.y * s, q.z * s)
end

-- Scale quaternion rotation (for averaging)
function Quat.scale(q, s)
	return Quat.pow(q, s)
end

-- Add two quaternion rotations (compose)
function Quat.add(a, b)
	return Quat.multiply(b, a)
end

-- SLERP interpolation
function Quat.slerp(q1, q2, t)
	local dot = q1.w * q2.w + q1.x * q2.x + q1.y * q2.y + q1.z * q2.z
	local q2c = { w = q2.w, x = q2.x, y = q2.y, z = q2.z }
	if dot < 0 then
		q2c.w, q2c.x, q2c.y, q2c.z = -q2c.w, -q2c.x, -q2c.y, -q2c.z
		dot = -dot
	end
	if dot > 0.9995 then
		return Quat.normalize(
			Quat.new(
				q1.w + t * (q2c.w - q1.w),
				q1.x + t * (q2c.x - q1.x),
				q1.y + t * (q2c.y - q1.y),
				q1.z + t * (q2c.z - q1.z)
			)
		)
	end
	local theta = math.acos(math.max(-1, math.min(1, dot)))
	local sinT = math.sin(theta)
	local w1 = math.sin((1 - t) * theta) / sinT
	local w2 = math.sin(t * theta) / sinT
	return Quat.new(q1.w * w1 + q2c.w * w2, q1.x * w1 + q2c.x * w2, q1.y * w1 + q2c.y * w2, q1.z * w1 + q2c.z * w2)
end

-- Get angular velocity magnitude (radians)
function Quat.angularMagnitude(q)
	q = Quat.normalize(q)
	local len = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
	return 2 * math.atan(len, q.w)
end

-- ============================================================================
-- Exponential Moving Average for Quaternion Smoothing (faster than Kalman)
-- ============================================================================

local EMA = {
	velocity = Quat.identity(),
	alpha = 0.6, -- Higher = more responsive (0.6 = 60% new, 40% old)
}

function EMA.update(measuredVelocity)
	EMA.velocity = Quat.slerp(EMA.velocity, measuredVelocity, EMA.alpha)
end

function EMA.reset()
	EMA.velocity = Quat.identity()
end

-- ============================================================================
-- History & Pattern Detection
-- ============================================================================

local HISTORY_SIZE = 60 -- 60 ticks = 1 second at 66 tick
local MIN_HISTORY = 10 -- Need at least this many for pattern detection

local history = {} -- Array of { quat, tick }
local velocityHistory = {} -- Array of delta quaternions
local currentTick = 0

-- Simple state: moving or stationary
local isMoving = false
local avgVelocityMag = 0

local function addSample(pitch, yaw, roll, tick)
	local q = Quat.fromEuler(pitch, yaw, roll)
	table.insert(history, { quat = q, tick = tick })
	while #history > HISTORY_SIZE do
		table.remove(history, 1)
	end

	-- Compute velocity (delta from previous)
	if #history >= 2 then
		local prev = history[#history - 1].quat
		local curr = history[#history].quat
		local vel = Quat.delta(prev, curr)
		table.insert(velocityHistory, vel)
		while #velocityHistory > HISTORY_SIZE - 1 do
			table.remove(velocityHistory, 1)
		end
	end
end

-- Compute average angular velocity over last N samples (weighted towards recent)
local function computeWeightedVelocity(n)
	if #velocityHistory < n then
		n = #velocityHistory
	end
	if n < 1 then
		return Quat.identity()
	end

	-- Weighted average - more recent samples have higher weight
	local result = Quat.identity()
	local startIdx = #velocityHistory - n + 1
	local totalWeight = 0

	for i = startIdx, #velocityHistory do
		local age = i - startIdx + 1 -- 1 to n
		local weight = age / n -- Linear ramp: older=low, newer=high
		totalWeight = totalWeight + weight
	end

	for i = startIdx, #velocityHistory do
		local age = i - startIdx + 1
		local weight = (age / n) / totalWeight
		local scaled = Quat.scale(velocityHistory[i], weight)
		result = Quat.add(result, scaled)
	end
	return Quat.normalize(result)
end

-- Update moving state
local function updateMovingState()
	if #velocityHistory < MIN_HISTORY then
		isMoving = false
		avgVelocityMag = 0
		return
	end

	-- Compute average velocity magnitude
	local sum = 0
	local count = math.min(20, #velocityHistory)
	for i = #velocityHistory - count + 1, #velocityHistory do
		sum = sum + Quat.angularMagnitude(velocityHistory[i])
	end
	avgVelocityMag = sum / count

	isMoving = avgVelocityMag > 0.001
end

-- ============================================================================
-- Extrapolation - Simple circular (repeat velocity)
-- ============================================================================

local function extrapolate(ticksAhead)
	if #history < 2 then
		return nil
	end
	if #velocityHistory < 1 then
		return nil
	end

	local current = history[#history].quat

	-- Stationary = no prediction
	if not isMoving then
		return current
	end

	-- Use RAW latest velocity - no smoothing for maximum responsiveness
	local vel = velocityHistory[#velocityHistory]

	-- Apply velocity repeatedly for circular arcd
	-- RIGHT multiply (local space rotation) for consistent circular motion
	local result = current
	for i = 1, ticksAhead do
		result = Quat.multiply(result, vel) -- RIGHT multiply, not left
	end
	return Quat.normalize(result)
end

-- ============================================================================
-- Drawing
-- ============================================================================

local function drawTrajectory()
	local view = client.GetPlayerView()
	if not view then
		return
	end

	local origin = view.origin
	local angles = view.angles

	-- Current position (white dot)
	local fwd = angles:Forward()
	local worldPos = origin + fwd * 100
	local screen = client.WorldToScreen(worldPos)
	if screen then
		draw.Color(255, 255, 255, 255)
		draw.FilledRect(screen[1] - 4, screen[2] - 4, screen[1] + 4, screen[2] + 4)
	end

	-- Extrapolated trajectory (60 ticks for more visible curve)
	if #history >= MIN_HISTORY then
		local prevScreen = screen
		local TICKS_AHEAD = 60

		for t = 1, TICKS_AHEAD do
			local predicted = extrapolate(t)
			if predicted then
				local p, y, r = Quat.toEuler(predicted)
				local predAngles = EulerAngles(p, y, r)
				local predFwd = predAngles:Forward()
				local predWorld = origin + predFwd * 100
				local predScreen = client.WorldToScreen(predWorld)

				if predScreen and prevScreen then
					-- Green when moving, gray when stationary
					local red, green, blue = 100, 255, 100
					if not isMoving then
						red, green, blue = 150, 150, 150
					end

					-- Fade with distance
					local alpha = math.floor(255 * (1 - t / TICKS_AHEAD))
					draw.Color(red, green, blue, alpha)
					draw.Line(prevScreen[1], prevScreen[2], predScreen[1], predScreen[2])

					if t % 3 == 0 then
						draw.FilledRect(predScreen[1] - 2, predScreen[2] - 2, predScreen[1] + 2, predScreen[2] + 2)
					end
				end
				prevScreen = predScreen
			end
		end
	end
end

local function drawDebugInfo()
	draw.SetFont(tahoma_bold)
	draw.Color(255, 255, 255, 255)
	draw.Text(10, 10, "Angle Extrapolation - Quaternion + EMA Smoothing")
	draw.Text(10, 30, string.format("History: %d/%d (need %d)", #history, HISTORY_SIZE, MIN_HISTORY))

	-- State
	if isMoving then
		draw.Color(100, 255, 100, 255)
		draw.Text(10, 50, "State: MOVING (circular prediction)")
	else
		draw.Color(150, 150, 150, 255)
		draw.Text(10, 50, "State: STATIONARY")
	end

	-- Velocity info
	local velMag = Quat.angularMagnitude(EMA.velocity)
	draw.Color(200, 200, 200, 255)
	draw.Text(10, 70, string.format("Velocity: %.4f rad/tick (raw avg: %.4f)", velMag, avgVelocityMag))
	draw.Text(10, 90, string.format("EMA alpha: %.2f (higher = more responsive)", EMA.alpha))
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
	addSample(angles.pitch, angles.yaw, angles.roll, currentTick)

	-- Update EMA with instantaneous velocity (most recent delta)
	if #velocityHistory >= 1 then
		local instantVel = velocityHistory[#velocityHistory] -- Use raw latest velocity
		EMA.update(instantVel)
	end

	-- Update moving state
	updateMovingState()
end

local function onDraw()
	drawTrajectory()
	drawDebugInfo()
end

callbacks.Register("CreateMove", "AngleExtrapolation_CreateMove", onCreateMove)
callbacks.Register("Draw", "AngleExtrapolation_Draw", onDraw)

print("[AngleExtrapolation] Loaded - Quaternion + EMA (circular motion)")
print("[AngleExtrapolation] 60 tick history, weighted velocity averaging")
print("[AngleExtrapolation] Move in circles to see green prediction curve!")
