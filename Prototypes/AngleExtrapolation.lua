-- Angle Extrapolation Prototype
-- Tests the shared Quaternion.extrapolateAngle() used by silent aimbot detection
-- Draws predicted trajectory as green line from your crosshair

local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

local Quaternion = require("Quaternion")

local HISTORY_SIZE = 60
local MIN_HISTORY = 3

local angleHistory = {}
local currentTick = 0

local function addSample(pitch, yaw, roll, tick)
	angleHistory[#angleHistory + 1] = { pitch = pitch, yaw = yaw, roll = roll, tick = tick }
	while #angleHistory > HISTORY_SIZE do
		table.remove(angleHistory, 1)
	end
end

local function drawTrajectory()
	local view = client.GetPlayerView()
	if not view then
		return
	end

	local origin = view.origin
	local angles = view.angles

	local fwd = angles:Forward()
	local worldPos = origin + fwd * 100
	local screen = client.WorldToScreen(worldPos)
	if screen then
		draw.Color(255, 255, 255, 255)
		draw.FilledRect(screen[1] - 4, screen[2] - 4, screen[1] + 4, screen[2] + 4)
	end

	if #angleHistory >= MIN_HISTORY then
		local prevScreen = screen
		local TICKS_AHEAD = 60

		for t = 1, TICKS_AHEAD do
			local predicted = Quaternion.extrapolateAngle(angleHistory, t)
			if predicted then
				local predAngles = EulerAngles(predicted.pitch, predicted.yaw, predicted.roll)
				local predFwd = predAngles:Forward()
				local predWorld = origin + predFwd * 100
				local predScreen = client.WorldToScreen(predWorld)

				if predScreen and prevScreen then
					local alpha = math.floor(255 * (1 - t / TICKS_AHEAD))
					draw.Color(100, 255, 100, alpha)
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
	draw.Text(10, 10, "Angle Extrapolation - Shared Quaternion.extrapolateAngle()")
	draw.Text(10, 30, string.format("History: %d/%d (need %d)", #angleHistory, HISTORY_SIZE, MIN_HISTORY))

	if #angleHistory >= MIN_HISTORY then
		local predicted1 = Quaternion.extrapolateAngle(angleHistory, 1)
		local predicted2 = Quaternion.extrapolateAngle(angleHistory, 2)
		local latest = angleHistory[#angleHistory]

		draw.Color(100, 255, 100, 255)
		draw.Text(10, 50, string.format("Current: pitch=%.1f yaw=%.1f", latest.pitch, latest.yaw))

		if predicted1 then
			draw.Color(200, 255, 100, 255)
			draw.Text(10, 70, string.format("+1 tick: pitch=%.1f yaw=%.1f", predicted1.pitch, predicted1.yaw))
		end
		if predicted2 then
			draw.Color(255, 255, 100, 255)
			draw.Text(10, 90, string.format("+2 tick: pitch=%.1f yaw=%.1f", predicted2.pitch, predicted2.yaw))
		end
	else
		draw.Color(150, 150, 150, 255)
		draw.Text(10, 50, "Collecting samples...")
	end
end

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
end

local function onDraw()
	drawTrajectory()
	drawDebugInfo()
end

callbacks.Register("CreateMove", "AngleExtrapolation_CreateMove", onCreateMove)
callbacks.Register("Draw", "AngleExtrapolation_Draw", onDraw)

print("[AngleExtrapolation] Loaded - Testing Quaternion.extrapolateAngle()")
print("[AngleExtrapolation] Green line = predicted trajectory from your crosshair")
print("[AngleExtrapolation] Move mouse to see prediction, look up/down to test pitch")
