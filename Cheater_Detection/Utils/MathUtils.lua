local MathUtils = {}

local vectorDivide = vector.Divide
local vectorLength = vector.Length
local vectorDistance = vector.Distance

local abs = math.abs
local sqrt = math.sqrt
local deg = math.deg
local asin = math.asin
local atan = math.atan

local Vec3 = Vector3

function MathUtils.clamp(value, minVal, maxVal)
	return math.max(minVal, math.min(maxVal, value))
end

function MathUtils.cross2D(a, b, c)
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end

function MathUtils.vecRot(localVec, angles)
	return (angles:Forward() * localVec.x) + (angles:Right() * localVec.y) + (angles:Up() * localVec.z)
end

function MathUtils.wrapAngle(degrees)
	return (degrees + 180) % 360 - 180
end

function MathUtils.angularDist(p1, y1, p2, y2)
	local dp = abs(MathUtils.wrapAngle(p1 - p2))
	local dy = abs(MathUtils.wrapAngle(y1 - y2))
	return sqrt(dp * dp + dy * dy)
end

function MathUtils.angleToPos(sourcePos, targetPos)
	local dx = targetPos.x - sourcePos.x
	local dy = targetPos.y - sourcePos.y
	local dz = targetPos.z - sourcePos.z
	local dist = sqrt(dx * dx + dy * dy)
	local pitch = -deg(atan(dz, dist))
	local yaw = deg(atan(dy, dx))
	return pitch, yaw
end

function MathUtils.angleToXYZ(sourcePos, tx, ty, tz)
	local dx = tx - sourcePos.x
	local dy = ty - sourcePos.y
	local dz = tz - sourcePos.z
	local dist = sqrt(dx * dx + dy * dy)
	local pitch = -deg(atan(dz, dist))
	local yaw = deg(atan(dy, dx))
	return pitch, yaw
end

function MathUtils.lerpAngle(a, b, t)
	local diff = (b - a + 180) % 360 - 180
	return a + diff * t
end

function MathUtils.lerpVector(startVector, endVector, interpolationFactor)
	return startVector + (endVector - startVector) * interpolationFactor
end

function MathUtils.velocityToAngles(vel)
	local speed = vel:Length()
	if speed < 0.001 then
		return EulerAngles(0, 0, 0)
	end

	local pitch = -deg(asin(vel.z / speed))
	local yaw = deg(atan(vel.y, vel.x))
	return EulerAngles(pitch, yaw, 0)
end

function MathUtils.velocityToAnglesRobust(vel)
	local speed = vel:Length()
	if speed < 0.001 then
		return EulerAngles(0, 0, 0)
	end

	local pitch = deg(atan(vel.z, sqrt(vel.x * vel.x + vel.y * vel.y)))
	local yaw = deg(atan(vel.y, vel.x))
	return EulerAngles(pitch, yaw, 0)
end

function MathUtils.surfaceFacesDown(plane, threshold)
	return plane.z < -threshold
end

function MathUtils.normalize(vec)
	local len = vectorLength(vec)
	if type(len) ~= "number" or len < 0.0001 then
		return Vec3(0, 0, 0)
	end
	return vectorDivide(vec, len)
end

function MathUtils.dot(a, b)
	return a:Dot(b)
end

function MathUtils.cross(a, b)
	return a:Cross(b)
end

function MathUtils.length2D(vec)
	return vec:Length2D()
end

function MathUtils.distance2D(a, b)
	return (a - b):Length2D()
end

function MathUtils.distance3D(a, b)
	return vectorDistance(a, b)
end

function MathUtils.anglesFromVector(vec)
	return vec:Angles()
end

return MathUtils
