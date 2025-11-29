-- Bundled by luabundle {"version":"1.7.0"}
local __bundle_require, __bundle_loaded, __bundle_register, __bundle_modules = (function(superRequire)
	local loadingPlaceholder = { [{}] = true }

	local register
	local modules = {}

	local require
	local loaded = {}

	register = function(name, body)
		if not modules[name] then
			modules[name] = body
		end
	end

	require = function(name)
		local loadedModule = loaded[name]

		if loadedModule then
			if loadedModule == loadingPlaceholder then
				return nil
			end
		else
			if not modules[name] then
				if not superRequire then
					local identifier = type(name) == "string" and '"' .. name .. '"' or tostring(name)
					error("Tried to require " .. identifier .. ", but no such module has been registered")
				else
					return superRequire(name)
				end
			end

			loaded[name] = loadingPlaceholder
			loadedModule = modules[name](require, loaded, register, modules)
			loaded[name] = loadedModule
		end

		return loadedModule
	end

	return require, loaded, register, modules
end)(require)
__bundle_register("__root", function(require, _LOADED, __bundle_register, __bundle_modules)
	local multipoint = require("multipoint")
	--- made by navet

	local config = {
		fov = 30.0,
		key = E_ButtonCode.KEY_LSHIFT,
		aim_sentry = true,
		aim_dispenser = true,
		aim_teleporter = true,
		max_distance = 3000,
		min_accuracy = 5,
		max_accuracy = 15,
		path_time = 2.0,
	}

	--local SimulatePlayer = require("playersim")
	local GetProjectileInfo = require("projectile_info")
	local SimulatePlayer = require("sim")
	local SimulateProj = require("projectilesim")

	local utils = {}
	utils.math = require("utils.math")
	utils.weapon = require("utils.weapon_utils")

	---@class State
	---@field target Entity?
	---@field angle EulerAngles?
	---@field path Vector3[]?
	---@field storedpath {removetime: number, path: Vector3[]?, projpath: Vector3[]?, projtimetable: number[]?, timetable: number[]?}
	---@field charge number
	---@field charges boolean
	---@field silent boolean
	---@field secondaryfire boolean
	----@field accuracy number?
	local state = {
		target = nil,
		angle = nil,
		path = nil,
		--accuracy = nil, --- ()
		storedpath = { removetime = 0.0, path = nil, projpath = nil, projtimetable = nil, timetable = nil },
		charge = 0,
		charges = false,
		silent = true,
		secondaryfire = false,
	}

	local noSilentTbl = {
		[E_WeaponBaseID.TF_WEAPON_CLEAVER] = true,
		[E_WeaponBaseID.TF_WEAPON_BAT_WOOD] = true,
		[E_WeaponBaseID.TF_WEAPON_BAT_GIFTWRAP] = true,
		[E_WeaponBaseID.TF_WEAPON_LUNCHBOX] = true,
		[E_WeaponBaseID.TF_WEAPON_JAR] = true,
		[E_WeaponBaseID.TF_WEAPON_JAR_MILK] = true,
		[E_WeaponBaseID.TF_WEAPON_JAR_GAS] = true,
		[E_WeaponBaseID.TF_WEAPON_FLAME_BALL] = true,
	}

	local doSecondaryFiretbl = {
		[E_WeaponBaseID.TF_WEAPON_BAT_GIFTWRAP] = true,
		[E_WeaponBaseID.TF_WEAPON_LUNCHBOX] = true,
		[E_WeaponBaseID.TF_WEAPON_BAT_WOOD] = true,
	}

	---@param localPos Vector3
	---@param className string
	---@param enemyTeam integer
	---@param outTable table
	local function ProcessClass(localPos, className, enemyTeam, outTable)
		local isPlayer = false

		for _, entity in pairs(entities.FindByClass(className)) do
			isPlayer = entity:IsPlayer()
			if
				(isPlayer == true and entity:IsAlive() or (isPlayer == false and entity:GetHealth() > 0))
				and not entity:IsDormant()
				and entity:GetTeamNumber() == enemyTeam
				and not entity:InCond(E_TFCOND.TFCond_Cloaked)
				and (localPos - entity:GetAbsOrigin()):Length() <= config.max_distance
			then
				--print(string.format("Is alive: %s, Health: %d", entity:IsAlive(), entity:GetHealth()))
				outTable[#outTable + 1] = entity
			end
		end
	end

	---@param tbl Vector3[]
	local function DrawPath(tbl)
		if #tbl >= 2 then
			local prev = client.WorldToScreen(tbl[1])
			if prev then
				draw.Color(255, 255, 255, 255)
				for i = 2, #tbl do
					local curr = client.WorldToScreen(tbl[i])
					if curr and prev then
						draw.Line(prev[1], prev[2], curr[1], curr[2])
						prev = curr
					else
						break
					end
				end
			end
		end
	end

	local function CleanTimeTable(pathtbl, timetbl)
		if not pathtbl or not timetbl or #pathtbl ~= #timetbl or #pathtbl < 2 then
			return nil, nil
		end

		local curtime = globals.CurTime()
		local newpath = {}
		local newtime = {}

		for i = 1, #timetbl do
			if timetbl[i] >= curtime then
				newpath[#newpath + 1] = pathtbl[i]
				newtime[#newtime + 1] = timetbl[i]
			end
		end

		-- Return nil if we filtered everything out
		if #newpath == 0 then
			return nil, nil
		end

		return newpath, newtime
	end

	local function OnDraw()
		--- Reset our state table
		state.angle = nil
		state.path = nil
		state.target = nil
		state.charge = 0
		state.charges = false

		local netchannel = clientstate.GetNetChannel()

		if netchannel == nil then
			return
		end

		if clientstate.GetClientSignonState() <= E_SignonState.SIGNONSTATE_SPAWN then
			return
		end

		if state.storedpath.path and state.storedpath.timetable then
			local cleanedpath, cleanedtime = CleanTimeTable(state.storedpath.path, state.storedpath.timetable)
			state.storedpath.path = cleanedpath
			state.storedpath.timetable = cleanedtime
		end

		if state.storedpath.projpath and state.storedpath.projtimetable then
			local cleanedprojpath, cleanedprojtime =
				CleanTimeTable(state.storedpath.projpath, state.storedpath.projtimetable)
			state.storedpath.projpath = cleanedprojpath
			state.storedpath.projtimetable = cleanedprojtime
		end

		--- TODO: Use a polygon instead!
		local storedpath = state.storedpath.path
		if storedpath then
			DrawPath(storedpath)
		end

		local storedprojpath = state.storedpath.projpath
		if storedprojpath then
			DrawPath(storedprojpath)
		end

		if input.IsButtonDown(config.key) == false then
			return
		end

		if utils.weapon.CanShoot() == false then
			return
		end

		local plocal = entities.GetLocalPlayer()
		if plocal == nil then
			return
		end

		local weapon = plocal:GetPropEntity("m_hActiveWeapon")
		if weapon == nil then
			return
		end

		local info = GetProjectileInfo(weapon:GetPropInt("m_iItemDefinitionIndex"))
		if info == nil then
			return
		end

		local enemyTeam = plocal:GetTeamNumber() == 2 and 3 or 2
		local localPos = plocal:GetAbsOrigin()

		---@type Entity[]
		local entitylist = {}
		ProcessClass(localPos, "CTFPlayer", enemyTeam, entitylist)

		if config.aim_sentry then
			ProcessClass(localPos, "CObjectSentrygun", enemyTeam, entitylist)
		end

		if config.aim_dispenser then
			ProcessClass(localPos, "CObjectDispenser", enemyTeam, entitylist)
		end

		if config.aim_teleporter then
			ProcessClass(localPos, "CObjectTeleporter", enemyTeam, entitylist)
		end

		if #entitylist == 0 then
			return
		end

		local eyePos = localPos + plocal:GetPropVector("localdata", "m_vecViewOffset[0]")
		local viewangle = engine.GetViewAngles()

		local angle, bestFov, bestEnt = nil, config.fov, nil
		for _, entity in ipairs(entitylist) do
			local center = entity:GetAbsOrigin() + (entity:GetMins() + entity:GetMaxs()) * 0.5
			angle = utils.math.PositionAngles(eyePos, center)
			if angle then
				local fov = utils.math.AngleFov(viewangle, angle)
				if fov < bestFov then
					bestFov = fov
					bestEnt = entity
				end
			end
		end

		if bestEnt == nil then
			return
		end

		local charge = info.m_bCharges and weapon:GetCurrentCharge() or 0.0 --weapon:GetChargeBeginTime() or 0.0
		local speed = info:GetVelocity(charge):Length2D()

		local distance = (localPos - bestEnt:GetAbsOrigin() + (bestEnt:GetMins() + bestEnt:GetMaxs()) * 0.5):Length()
		local time = (distance / speed)
			+ (netchannel:GetLatency(E_Flows.FLOW_INCOMING) + netchannel:GetLatency(E_Flows.FLOW_OUTGOING))

		--local minAccuracy, maxAccuracy = config.min_accuracy, config.max_accuracy
		--local maxDistance = config.max_distance
		--local accuracy = minAccuracy + (maxAccuracy - minAccuracy) * (math.min(distance/maxDistance, 1.0)^1.5)
		local path, lastPos, timetable = SimulatePlayer(bestEnt, time)

		local _, sv_gravity = client.GetConVar("sv_gravity")
		local gravity = sv_gravity * 0.5 * info:GetGravity(charge)

		local _, multipointPos = multipoint.Run(bestEnt, weapon, info, eyePos, lastPos)
		if multipointPos then
			lastPos = multipointPos
		end

		angle = utils.math.SolveBallisticArc(eyePos, lastPos, speed, gravity)
		if angle == nil then
			return
		end

		local firePos = info:GetFirePosition(plocal, eyePos, angle, weapon:IsViewModelFlipped())
		local projpath = {}
		local hit = nil
		local projtimetable = {}

		local translatedAngle = utils.math.SolveBallisticArc(firePos, lastPos, speed, gravity)
		if translatedAngle then
			projpath, hit, projtimetable =
				SimulateProj(bestEnt, lastPos, firePos, translatedAngle, info, plocal:GetTeamNumber(), time, charge)
			if not hit then
				return
			end
		end

		local weaponID = weapon:GetWeaponID()
		local secondaryFire = doSecondaryFiretbl[weaponID]
		local noSilent = noSilentTbl[weaponID]

		state.target = bestEnt
		state.path = path
		state.angle = angle
		state.storedpath.path = path
		state.storedpath.projpath = projpath
		state.storedpath.timetable = timetable
		state.storedpath.projtimetable = projtimetable
		state.storedpath.removetime = globals.CurTime() + config.path_time
		state.charge = charge
		state.charges = info.m_bCharges
		state.secondaryfire = secondaryFire
		state.silent = not noSilent --- janky ahh stuff
	end

	---@param cmd UserCmd
	local function OnCreateMove(cmd)
		if utils.weapon.CanShoot() == false then
			return
		end

		if input.IsButtonDown(config.key) == false then
			return
		end

		if not state.angle then
			return
		end

		if state.charge > 1.0 then
			state.charge = 0
		end

		if state.charges and state.charge < 0.05 then
			cmd.buttons = cmd.buttons | IN_ATTACK
			return
		end

		if state.charges then
			cmd.buttons = cmd.buttons & ~IN_ATTACK
		else
			if state.secondaryfire then
				cmd.buttons = cmd.buttons | IN_ATTACK2
			else
				cmd.buttons = cmd.buttons | IN_ATTACK
			end
		end

		if state.silent then
			cmd.sendpacket = false
		end

		cmd.viewangles = Vector3(state.angle:Unpack())
	end

	callbacks.Register("Draw", OnDraw)
	callbacks.Register("CreateMove", OnCreateMove)
end)
__bundle_register("utils.weapon_utils", function(require, _LOADED, __bundle_register, __bundle_modules)
	local wep_utils = {}

	local old_weapon, lastFire, nextAttack = nil, 0, 0

	local function GetLastFireTime(weapon)
		return weapon:GetPropFloat("LocalActiveTFWeaponData", "m_flLastFireTime")
	end

	local function GetNextPrimaryAttack(weapon)
		return weapon:GetPropFloat("LocalActiveWeaponData", "m_flNextPrimaryAttack")
	end

	--- https://www.unknowncheats.me/forum/team-fortress-2-a/273821-canshoot-function.html
	function wep_utils.CanShoot()
		local player = entities:GetLocalPlayer()
		if not player then
			return false
		end

		local weapon = player:GetPropEntity("m_hActiveWeapon")
		if not weapon or not weapon:IsValid() then
			return false
		end

		if weapon:GetPropInt("LocalWeaponData", "m_iClip1") == 0 then
			return false
		end

		local lastfiretime = GetLastFireTime(weapon)
		if lastFire ~= lastfiretime or weapon ~= old_weapon then
			lastFire = lastfiretime
			nextAttack = GetNextPrimaryAttack(weapon)
		end

		old_weapon = weapon
		return nextAttack <= globals.CurTime()
	end

	return wep_utils
end)
__bundle_register("utils.math", function(require, _LOADED, __bundle_register, __bundle_modules)
	local Math = {}

	--- Pasted from Lnx00's LnxLib
	local function isNaN(x)
		return x ~= x
	end

	local M_RADPI = 180 / math.pi --- rad to deg

	-- Calculates the angle between two vectors
	---@param source Vector3
	---@param dest Vector3
	---@return EulerAngles angles
	function Math.PositionAngles(source, dest)
		local delta = source - dest

		local pitch = math.atan(delta.z / delta:Length2D()) * M_RADPI
		local yaw = math.atan(delta.y / delta.x) * M_RADPI

		if delta.x >= 0 then
			yaw = yaw + 180
		end

		if isNaN(pitch) then
			pitch = 0
		end
		if isNaN(yaw) then
			yaw = 0
		end

		return EulerAngles(pitch, yaw, 0)
	end

	-- Calculates the FOV between two angles
	---@param vFrom EulerAngles
	---@param vTo EulerAngles
	---@return number fov
	function Math.AngleFov(vFrom, vTo)
		local vSrc = vFrom:Forward()
		local vDst = vTo:Forward()

		local fov = M_RADPI * math.acos(vDst:Dot(vSrc) / vDst:LengthSqr())
		if isNaN(fov) then
			fov = 0
		end

		return fov
	end

	local function NormalizeVector(vec)
		return vec / vec:Length()
	end

	---@param p0 Vector3 -- start position
	---@param p1 Vector3 -- target position
	---@param speed number -- projectile speed
	---@param gravity number -- gravity constant
	---@return EulerAngles?, number? -- Euler angles (pitch, yaw, 0)
	function Math.SolveBallisticArc(p0, p1, speed, gravity)
		local diff = p1 - p0
		local dx = diff:Length2D()
		local dy = diff.z
		local speed2 = speed * speed
		local g = gravity

		local root = speed2 * speed2 - g * (g * dx * dx + 2 * dy * speed2)
		if root < 0 then
			return nil -- no solution
		end

		local sqrt_root = math.sqrt(root)
		local angle = math.atan((speed2 - sqrt_root) / (g * dx)) -- low arc

		-- Get horizontal direction (yaw)
		local yaw = (math.atan(diff.y, diff.x)) * M_RADPI

		-- Convert pitch from angle
		local pitch = -angle * M_RADPI -- negative because upward is negative pitch in most engines

		return EulerAngles(pitch, yaw, 0)
	end

	-- Returns both low and high arc EulerAngles when gravity > 0
	---@param p0 Vector3
	---@param p1 Vector3
	---@param speed number
	---@param gravity number
	---@return EulerAngles|nil lowArc, EulerAngles|nil highArc
	function Math.SolveBallisticArcBoth(p0, p1, speed, gravity)
		local diff = p1 - p0
		local dx = math.sqrt(diff.x * diff.x + diff.y * diff.y)
		if dx == 0 then
			return nil, nil
		end

		local dy = diff.z
		local g = gravity
		local speed2 = speed * speed

		local root = speed2 * speed2 - g * (g * dx * dx + 2 * dy * speed2)
		if root < 0 then
			return nil, nil
		end

		local sqrt_root = math.sqrt(root)
		local theta_low = math.atan((speed2 - sqrt_root) / (g * dx))
		local theta_high = math.atan((speed2 + sqrt_root) / (g * dx))

		local yaw = math.atan(diff.y, diff.x) * M_RADPI

		local pitch_low = -theta_low * M_RADPI
		local pitch_high = -theta_high * M_RADPI

		local low = EulerAngles(pitch_low, yaw, 0)
		local high = EulerAngles(pitch_high, yaw, 0)
		return low, high
	end

	---@param shootPos Vector3
	---@param targetPos Vector3
	---@param speed number
	---@return number
	function Math.EstimateTravelTime(shootPos, targetPos, speed)
		local distance = (targetPos - shootPos):Length2D()
		return distance / speed
	end

	---@param val number
	---@param min number
	---@param max number
	function Math.clamp(val, min, max)
		return math.max(min, math.min(val, max))
	end

	function Math.GetBallisticFlightTime(p0, p1, speed, gravity)
		local diff = p1 - p0
		local dx = math.sqrt(diff.x ^ 2 + diff.y ^ 2)
		local dy = diff.z
		local speed2 = speed * speed
		local g = gravity

		local discriminant = speed2 * speed2 - g * (g * dx * dx + 2 * dy * speed2)
		if discriminant < 0 then
			return nil
		end

		local sqrt_discriminant = math.sqrt(discriminant)
		local angle = math.atan((speed2 - sqrt_discriminant) / (g * dx))

		-- Flight time calculation
		local vz = speed * math.sin(angle)
		local flight_time = (vz + math.sqrt(vz * vz + 2 * g * dy)) / g

		return flight_time
	end

	function Math.DirectionToAngles(direction)
		local pitch = math.asin(-direction.z) * M_RADPI
		local yaw = math.atan(direction.y, direction.x) * M_RADPI
		return Vector3(pitch, yaw, 0)
	end

	---@param offset Vector3
	---@param direction Vector3
	function Math.RotateOffsetAlongDirection(offset, direction)
		local forward = NormalizeVector(direction)
		local up = Vector3(0, 0, 1)
		local right = NormalizeVector(forward:Cross(up))
		up = NormalizeVector(right:Cross(forward))

		return forward * offset.x + right * offset.y + up * offset.z
	end

	Math.NormalizeVector = NormalizeVector
	return Math
end)
__bundle_register("projectilesim", function(require, _LOADED, __bundle_register, __bundle_modules)
	local projectiles = {}

	local env = physics.CreateEnvironment()
	env:SetAirDensity(2.0)
	env:SetGravity(Vector3(0, 0, -800))
	env:SetSimulationTimestep(globals.TickInterval())

	---@return PhysicsObject
	local function GetPhysicsProjectile(info)
		local modelName = info.m_sModelName
		if projectiles[modelName] then
			return projectiles[modelName]
		end

		local solid, collision = physics.ParseModelByName(info.m_sModelName)
		if solid == nil or collision == nil then
			error("Solid/collision is nil! Model name: " .. info.m_sModelName)
			return {}
		end

		local projectile = env:CreatePolyObject(collision, solid:GetSurfacePropName(), solid:GetObjectParameters())
		projectiles[modelName] = projectile

		return projectiles[modelName]
	end

	--- source: https://developer.mozilla.org/en-US/docs/Games/Techniques/3D_collision_detection
	---@param currentPos Vector3
	---@param vecTargetPredictedPos Vector3
	---@param weaponInfo WeaponInfo
	---@param vecTargetMaxs Vector3
	---@param vecTargetMins Vector3
	local function IsIntersectingBB(currentPos, vecTargetPredictedPos, weaponInfo, vecTargetMaxs, vecTargetMins)
		local vecProjMins = weaponInfo.m_vecMins + currentPos
		local vecProjMaxs = weaponInfo.m_vecMaxs + currentPos

		local targetMins = vecTargetMins + vecTargetPredictedPos
		local targetMaxs = vecTargetMaxs + vecTargetPredictedPos

		-- check overlap on X, Y, and Z
		if vecProjMaxs.x < targetMins.x or vecProjMins.x > targetMaxs.x then
			return false
		end
		if vecProjMaxs.y < targetMins.y or vecProjMins.y > targetMaxs.y then
			return false
		end
		if vecProjMaxs.z < targetMins.z or vecProjMins.z > targetMaxs.z then
			return false
		end

		return true -- all axis overlap
	end

	---@param target Entity
	---@param targetPredictedPos Vector3
	---@param startPos Vector3
	---@param angle EulerAngles
	---@param info WeaponInfo
	---@param time_seconds number
	---@param localTeam integer
	---@param charge number
	---@return Vector3[], boolean?, number[]
	local function SimulateProjectile(
		target,
		targetPredictedPos,
		startPos,
		angle,
		info,
		localTeam,
		time_seconds,
		charge
	)
		local projectile = GetPhysicsProjectile(info)
		if projectile == nil then
			return {}, nil, {}
		end

		projectile:Wake()

		local angForward = angle:Forward()

		local timeEnd = env:GetSimulationTime() + time_seconds
		local tickInterval = globals.TickInterval() * 3.0

		local velocityVector = info:GetVelocity(charge)
		local startVelocity = (angForward * velocityVector:Length2D()) + (Vector3(0, 0, velocityVector.z))
		projectile:SetPosition(startPos, angle:Forward(), true)
		projectile:SetVelocity(startVelocity, info:GetAngularVelocity(charge))

		local mins, maxs = info.m_vecMins, info.m_vecMaxs
		local path = {}
		local hit = false
		local timetable = {}
		local curtime = globals.CurTime()

		while env:GetSimulationTime() < timeEnd do
			local vStart = projectile:GetPosition()
			env:Simulate(tickInterval)
			local vEnd = projectile:GetPosition()

			local trace = engine.TraceHull(vStart, vEnd, mins, maxs, info.m_iTraceMask, function(ent, contentsMask)
				if ent:GetIndex() == target:GetIndex() then
					return true
				end

				if ent:GetTeamNumber() ~= localTeam and info.m_bStopOnHittingEnemy then
					return true
				end

				if
					ent:GetTeamNumber() == localTeam
					and env:GetSimulationTime() > info.m_flCollideWithTeammatesDelay
				then
					return true
				end

				return false
			end)

			if IsIntersectingBB(vEnd, targetPredictedPos, info, target:GetMaxs(), target:GetMins()) then
				hit = true
				break
			end

			if trace.fraction < 1.0 then
				break
			end

			path[#path + 1] = Vector3(vEnd:Unpack())
			timetable[#timetable + 1] = curtime + env:GetSimulationTime()
		end

		projectile:Sleep()
		env:ResetSimulationClock()
		return path, hit, timetable
	end

	---@param target Entity
	---@param targetPredictedPos Vector3
	---@param startPos Vector3
	---@param angle EulerAngles
	---@param info WeaponInfo
	---@param time_seconds number
	---@param localTeam integer
	---@return Vector3[], boolean?, number[]
	local function SimulatePseudoProjectile(
		target,
		targetPredictedPos,
		startPos,
		angle,
		info,
		localTeam,
		time_seconds,
		charge
	)
		local angForward = angle:Forward()
		local tickInterval = globals.TickInterval() * 3.0

		local velocityVector = info:GetVelocity(charge)
		local startVelocity = (angForward * velocityVector:Length2D()) + Vector3(0, 0, velocityVector.z)

		local mins, maxs = info.m_vecMins, info.m_vecMaxs
		local path = {}
		local timeTable = {}
		local hit = false
		local time = 0.0
		local curtime = globals.CurTime()

		-- Get gravity from info
		local _, sv_gravity = client.GetConVar("sv_gravity")
		local gravity = sv_gravity * info:GetGravity(charge)

		local currentPos = startPos
		local currentVel = startVelocity

		while time < time_seconds do
			local vStart = currentPos

			-- Apply gravity to velocity
			currentVel = currentVel + Vector3(0, 0, -gravity * tickInterval)

			local vEnd = currentPos + currentVel * tickInterval

			local trace = engine.TraceHull(
				vStart,
				vEnd,
				mins,
				maxs,
				info.m_iTraceMask or MASK_SHOT_HULL,
				function(ent, contentsMask)
					-- Ignore invalid entities
					if not ent or ent:GetIndex() == 0 then
						return false
					end

					-- Check if we hit our target
					if ent:GetIndex() == target:GetIndex() then
						hit = true
						return true
					end

					-- Check enemy collision
					if ent:GetTeamNumber() ~= localTeam and info.m_bStopOnHittingEnemy then
						return true
					end

					-- Check teammate collision after delay
					if ent:GetTeamNumber() == localTeam and time > info.m_flCollideWithTeammatesDelay then
						return true
					end

					return false
				end
			)

			-- Add current position to path before checking collision
			path[#path + 1] = Vector3(vEnd:Unpack())
			timeTable[#timeTable + 1] = curtime + time

			if IsIntersectingBB(vEnd, targetPredictedPos, info, target:GetMaxs(), target:GetMins()) then
				hit = true
				break
			end

			if trace.fraction < 1.0 then
				break
			end

			currentPos = vEnd
			time = time + tickInterval
		end

		return path, hit, timeTable
	end

	---@param target Entity
	---@param targetPredictedPos Vector3
	---@param startPos Vector3
	---@param angle EulerAngles
	---@param info WeaponInfo
	---@param time_seconds number
	---@param localTeam integer
	---@param charge number
	---@return Vector3[], boolean?, number[]
	local function Run(target, targetPredictedPos, startPos, angle, info, localTeam, time_seconds, charge)
		local projpath = {}
		local hit = nil
		local timetable = {}

		if info.m_sModelName and info.m_sModelName ~= "" then
			projpath, hit, timetable =
				SimulateProjectile(target, targetPredictedPos, startPos, angle, info, localTeam, time_seconds, charge)
		else
			projpath, hit, timetable = SimulatePseudoProjectile(
				target,
				targetPredictedPos,
				startPos,
				angle,
				info,
				localTeam,
				time_seconds,
				charge
			)
		end

		return projpath, hit, timetable
	end

	local function OnUnload()
		for _, obj in pairs(projectiles) do
			env:DestroyObject(obj)
		end

		physics.DestroyEnvironment(env)

		print("Physics environment destroyed!")
	end

	callbacks.Register("Unload", OnUnload)
	return Run
end)
__bundle_register("sim", function(require, _LOADED, __bundle_register, __bundle_modules)
	--- Why is this not in the lua docs?
	local RuneTypes_t = {
		RUNE_NONE = -1,
		RUNE_STRENGTH = 0,
		RUNE_HASTE = 1,
		RUNE_REGEN = 2,
		RUNE_RESIST = 3,
		RUNE_VAMPIRE = 4,
		RUNE_REFLECT = 5,
		RUNE_PRECISION = 6,
		RUNE_AGILITY = 7,
		RUNE_KNOCKOUT = 8,
		RUNE_KING = 9,
		RUNE_PLAGUE = 10,
		RUNE_SUPERNOVA = 11,
	}

	---@param velocity Vector3
	---@param wishdir Vector3
	---@param wishspeed number
	---@param accel number
	---@param frametime number
	local function Accelerate(velocity, wishdir, wishspeed, accel, frametime)
		local addspeed, accelspeed, currentspeed

		currentspeed = velocity:Dot(wishdir)
		addspeed = wishspeed - currentspeed

		if addspeed <= 0 then
			return
		end

		accelspeed = accel * frametime * wishspeed
		if accelspeed > addspeed then
			accelspeed = addspeed
		end

		velocity.x = velocity.x + wishdir.x * accelspeed
		velocity.y = velocity.y + wishdir.y * accelspeed
		velocity.z = velocity.z + wishdir.z * accelspeed
	end

	---@param target Entity
	---@return number
	local function GetAirSpeedCap(target)
		local m_hGrapplingHookTarget = target:GetPropEntity("m_hGrapplingHookTarget")
		if m_hGrapplingHookTarget then
			if target:GetCarryingRuneType() == RuneTypes_t.RUNE_AGILITY then
				local m_iClass = target:GetPropInt("m_iClass")
				return (m_iClass == E_Character.TF2_Soldier or E_Character.TF2_Heavy) and 850 or 950
			end
			local _, tf_grapplinghook_move_speed = client.GetConVar("tf_grapplinghook_move_speed")
			return tf_grapplinghook_move_speed
		elseif target:InCond(E_TFCOND.TFCond_Charging) then
			local _, tf_max_charge_speed = client.GetConVar("tf_max_charge_speed")
			return tf_max_charge_speed
		else
			local flCap = 30.0
			if target:InCond(E_TFCOND.TFCond_ParachuteDeployed) then
				local _, tf_parachute_aircontrol = client.GetConVar("tf_parachute_aircontrol")
				flCap = flCap * tf_parachute_aircontrol
			end
			if target:InCond(E_TFCOND.TFCond_HalloweenKart) then
				if target:InCond(E_TFCOND.TFCond_HalloweenKartDash) then
					local _, tf_halloween_kart_dash_speed = client.GetConVar("tf_halloween_kart_dash_speed")
					return tf_halloween_kart_dash_speed
				end
				local _, tf_hallowen_kart_aircontrol = client.GetConVar("tf_hallowen_kart_aircontrol")
				flCap = flCap * tf_hallowen_kart_aircontrol
			end
			return flCap * target:AttributeHookFloat("mod_air_control")
		end
	end

	---@param v Vector3 Velocity
	---@param wishdir Vector3
	---@param wishspeed number
	---@param accel number
	---@param dt number globals.TickInterval()
	---@param surf number Is currently surfing?
	---@param target Entity
	local function AirAccelerate(v, wishdir, wishspeed, accel, dt, surf, target)
		wishspeed = math.min(wishspeed, GetAirSpeedCap(target))
		local currentspeed = v:Dot(wishdir)
		local addspeed = wishspeed - currentspeed
		if addspeed <= 0 then
			return
		end

		local accelspeed = math.min(accel * wishspeed * dt * surf, addspeed)
		v.x = v.x + accelspeed * wishdir.x
		v.y = v.y + accelspeed * wishdir.y
		v.z = v.z + accelspeed * wishdir.z
	end

	local function CheckIsOnGround(origin, mins, maxs, index)
		local down = Vector3(origin.x, origin.y, origin.z - 18)
		local trace = engine.TraceHull(origin, down, mins, maxs, MASK_PLAYERSOLID, function(ent, contentsMask)
			return ent:GetIndex() ~= index
		end)

		return trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7
	end

	---@param index integer
	local function StayOnGround(origin, mins, maxs, step_size, index)
		local vstart = Vector3(origin.x, origin.y, origin.z + 2)
		local vend = Vector3(origin.x, origin.y, origin.z - step_size)

		local trace = engine.TraceHull(vstart, vend, mins, maxs, MASK_PLAYERSOLID, function(ent, contentsMask)
			return ent:GetIndex() ~= index
		end)

		if trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7 then
			local delta = math.abs(origin.z - trace.endpos.z)
			if delta > 0.5 then
				origin.x = trace.endpos.x
				origin.y = trace.endpos.y
				origin.z = trace.endpos.z
				return true
			end
		end

		return false
	end

	---@param velocity Vector3
	---@param is_on_ground boolean
	---@param frametime number
	local function Friction(velocity, is_on_ground, frametime)
		local speed, newspeed, control, friction, drop
		speed = velocity:LengthSqr()
		if speed < 0.01 then
			return
		end

		local _, sv_stopspeed = client.GetConVar("sv_stopspeed")
		drop = 0

		if is_on_ground then
			local _, sv_friction = client.GetConVar("sv_friction")
			friction = sv_friction

			control = speed < sv_stopspeed and sv_stopspeed or speed
			drop = drop + control * friction * frametime
		end

		newspeed = speed - drop
		if newspeed ~= speed then
			newspeed = newspeed / speed
			velocity.x = velocity.x * newspeed
			velocity.y = velocity.y * newspeed
			velocity.z = velocity.z * newspeed
		end
	end

	-- Clip velocity along a plane normal
	local function ClipVelocity(velocity, normal, overbounce)
		local backoff = velocity:Dot(normal) * overbounce

		velocity.x = velocity.x - normal.x * backoff
		velocity.y = velocity.y - normal.y * backoff
		velocity.z = velocity.z - normal.z * backoff

		-- Zero out small components
		if math.abs(velocity.x) < 0.01 then
			velocity.x = 0
		end
		if math.abs(velocity.y) < 0.01 then
			velocity.y = 0
		end
		if math.abs(velocity.z) < 0.01 then
			velocity.z = 0
		end
	end

	-- Perform collision-aware movement
	local function TryPlayerMove(origin, velocity, mins, maxs, index, tickinterval)
		local MAX_CLIP_PLANES = 5
		local time_left = tickinterval
		local planes = {}
		local numplanes = 0
		local original_velocity = Vector3(velocity.x, velocity.y, velocity.z)
		local new_velocity = Vector3(velocity.x, velocity.y, velocity.z)

		-- Try moving up to 4 times (with bumps)
		for bumpcount = 0, 3 do
			if time_left <= 0 then
				break
			end

			-- Calculate end position
			local end_pos = Vector3(
				origin.x + velocity.x * time_left,
				origin.y + velocity.y * time_left,
				origin.z + velocity.z * time_left
			)

			-- Trace from current position to desired position
			local trace = engine.TraceHull(origin, end_pos, mins, maxs, MASK_PLAYERSOLID, function(ent, contentsMask)
				return ent:GetIndex() ~= index
			end)

			-- If we made it all the way, we're done
			if trace.fraction > 0 then
				origin.x = trace.endpos.x
				origin.y = trace.endpos.y
				origin.z = trace.endpos.z
				numplanes = 0
			end

			if trace.fraction == 1 then
				break
			end

			-- Update time remaining
			time_left = time_left - time_left * trace.fraction

			-- Record this plane
			if trace.plane and numplanes < MAX_CLIP_PLANES then
				planes[numplanes] = trace.plane
				numplanes = numplanes + 1
			end

			-- Modify velocity to slide along the plane
			if trace.plane then
				-- If we hit the ground and going down, stop vertical movement
				if trace.plane.z > 0.7 and velocity.z < 0 then
					velocity.z = 0
				end

				-- Clip velocity against all planes we've hit
				local i = 0
				while i < numplanes do
					ClipVelocity(velocity, planes[i], 1.0)

					-- Check if velocity is still going into any plane
					local j = 0
					while j < numplanes do
						if j ~= i then
							local dot = velocity:Dot(planes[j])
							if dot < 0 then
								break
							end
						end
						j = j + 1
					end

					if j == numplanes then
						break
					end

					i = i + 1
				end

				-- If we're going into all planes, stop
				if i == numplanes then
					if numplanes >= 2 then
						-- Slide along the crease between planes
						local dir = Vector3(
							planes[0].y * planes[1].z - planes[0].z * planes[1].y,
							planes[0].z * planes[1].x - planes[0].x * planes[1].z,
							planes[0].x * planes[1].y - planes[0].y * planes[1].x
						)

						local d = dir:Dot(velocity)
						velocity.x = dir.x * d
						velocity.y = dir.y * d
						velocity.z = dir.z * d
					end

					-- Still going into a plane, stop all movement
					local dot = velocity:Dot(planes[0])
					if dot < 0 then
						velocity.x = 0
						velocity.y = 0
						velocity.z = 0
						break
					end
				end
			else
				-- No plane, just stop
				break
			end
		end

		return origin
	end

	---@param player Entity
	---@param time_seconds number
	---@return Vector3[], Vector3, number[]
	local function Run(player, time_seconds)
		local path = {}
		local velocity = player:GetPropVector("localdata", "m_vecVelocity[0]") or Vector3()
		local origin = player:GetAbsOrigin() + Vector3(0, 0, 1)

		if velocity:Length() <= 0.01 then
			path[1] = origin
			return path, origin, { globals.CurTime() }
		end

		local maxspeed = player:GetPropFloat("m_flMaxspeed") or 450
		local clock = 0.0
		local tickinterval = globals.TickInterval()
		local wishdir = velocity / velocity:Length()
		local mins, maxs = player:GetMins(), player:GetMaxs()

		local _, sv_airaccelerate = client.GetConVar("sv_airaccelerate")
		local _, sv_accelerate = client.GetConVar("sv_accelerate")

		local index = player:GetIndex()
		local curtime = globals.CurTime()
		local timetable = {}

		while clock < time_seconds do
			local is_on_ground = CheckIsOnGround(origin, mins, maxs, index)

			Friction(velocity, is_on_ground, tickinterval)

			if is_on_ground then
				Accelerate(velocity, wishdir, maxspeed, sv_accelerate, tickinterval)
				velocity.z = 0
			else
				AirAccelerate(velocity, wishdir, maxspeed, sv_airaccelerate, tickinterval, 0, player)
				velocity.z = velocity.z - 800 * tickinterval
			end

			-- Perform collision-aware movement
			origin = TryPlayerMove(origin, velocity, mins, maxs, index, tickinterval)

			-- If on ground, stick to it
			if is_on_ground then
				StayOnGround(origin, mins, maxs, 18, index)
			end

			path[#path + 1] = Vector3(origin:Unpack())
			timetable[#timetable + 1] = curtime + clock
			clock = clock + tickinterval
		end

		return path, path[#path], timetable
	end

	return Run
end)
__bundle_register("projectile_info", function(require, _LOADED, __bundle_register, __bundle_modules)
	--[[
    This is a port of the GetProjectileInformation function
    from GoodEvening's Visualize Arc Trajectories

    His Github: https://github.com/GoodEveningFellOff
    Source: https://github.com/GoodEveningFellOff/Lmaobox-Scripts/blob/main/Visualize%20Arc%20Trajectories/dev.lua
--]]

	local TRACE_HULL = engine.TraceHull
	local CLAMP = function(a, b, c)
		return (a < b) and b or (a > c) and c or a
	end
	local VEC_ROT = function(a, b)
		return (b:Forward() * a.x) + (b:Right() * a.y) + (b:Up() * a.z)
	end

	local aProjectileInfo = {}
	local aItemDefinitions = {}

	local PROJECTILE_TYPE_BASIC = 0
	local PROJECTILE_TYPE_PSEUDO = 1
	local PROJECTILE_TYPE_SIMUL = 2

	local COLLISION_NORMAL = 0
	local COLLISION_HEAL_TEAMMATES = 1
	local COLLISION_HEAL_BUILDINGS = 2
	local COLLISION_HEAL_HURT = 3
	local COLLISION_NONE = 4

	local function AppendItemDefinitions(iType, ...)
		for _, i in pairs({ ... }) do
			aItemDefinitions[i] = iType
		end
	end

	---@return WeaponInfo
	function GetProjectileInformation(itemDefinitionIndex)
		return aProjectileInfo[aItemDefinitions[itemDefinitionIndex or 0]]
	end

	---@return WeaponInfo?
	local function DefineProjectileDefinition(tbl)
		return {
			m_iType = PROJECTILE_TYPE_BASIC,
			m_vecOffset = tbl.vecOffset or Vector3(0, 0, 0),
			m_vecAbsoluteOffset = tbl.vecAbsoluteOffset or Vector3(0, 0, 0),
			m_vecAngleOffset = tbl.vecAngleOffset or Vector3(0, 0, 0),
			m_vecVelocity = tbl.vecVelocity or Vector3(0, 0, 0),
			m_vecAngularVelocity = tbl.vecAngularVelocity or Vector3(0, 0, 0),
			m_vecMins = tbl.vecMins or (not tbl.vecMaxs) and Vector3(0, 0, 0) or -tbl.vecMaxs,
			m_vecMaxs = tbl.vecMaxs or (not tbl.vecMins) and Vector3(0, 0, 0) or -tbl.vecMins,
			m_flGravity = tbl.flGravity or 0.001,
			m_flDrag = tbl.flDrag or 0,
			m_flElasticity = tbl.flElasticity or 0,
			m_iAlignDistance = tbl.iAlignDistance or 0,
			m_iTraceMask = tbl.iTraceMask or 33570827, -- MASK_SOLID
			m_iCollisionType = tbl.iCollisionType or COLLISION_NORMAL,
			m_flCollideWithTeammatesDelay = tbl.flCollideWithTeammatesDelay or 0.25,
			m_flLifetime = tbl.flLifetime or 99999,
			m_flDamageRadius = tbl.flDamageRadius or 0,
			m_bStopOnHittingEnemy = tbl.bStopOnHittingEnemy ~= false,
			m_bCharges = tbl.bCharges or false,
			m_sModelName = tbl.sModelName or "",
			m_bHasGravity = tbl.bGravity == nil and true or tbl.bGravity,

			GetOffset = not tbl.GetOffset
					and function(self, bDucking, bIsFlipped)
						return bIsFlipped and Vector3(self.m_vecOffset.x, -self.m_vecOffset.y, self.m_vecOffset.z)
							or self.m_vecOffset
					end
				or tbl.GetOffset, -- self, bDucking, bIsFlipped

			GetAngleOffset = (not tbl.GetAngleOffset) and function(self, flChargeBeginTime)
				return self.m_vecAngleOffset
			end or tbl.GetAngleOffset, -- self, flChargeBeginTime

			GetFirePosition = tbl.GetFirePosition
				or function(self, pLocalPlayer, vecLocalView, vecViewAngles, bIsFlipped)
					local resultTrace = TRACE_HULL(
						vecLocalView,
						vecLocalView
							+ VEC_ROT(
								self:GetOffset((pLocalPlayer:GetPropInt("m_fFlags") & FL_DUCKING) ~= 0, bIsFlipped),
								vecViewAngles
							),
						-Vector3(8, 8, 8),
						Vector3(8, 8, 8),
						MASK_SHOT_HULL
					) -- MASK_SHOT_HULL

					return (not resultTrace.startsolid) and resultTrace.endpos or nil
				end,

			GetVelocity = (not tbl.GetVelocity) and function(self, ...)
				return self.m_vecVelocity
			end or tbl.GetVelocity, -- self, flChargeBeginTime

			GetAngularVelocity = (not tbl.GetAngularVelocity) and function(self, ...)
				return self.m_vecAngularVelocity
			end or tbl.GetAngularVelocity, -- self, flChargeBeginTime

			GetGravity = (not tbl.GetGravity) and function(self, ...)
				return self.m_flGravity
			end or tbl.GetGravity, -- self, flChargeBeginTime

			GetLifetime = (not tbl.GetLifetime) and function(self, ...)
				return self.m_flLifetime
			end or tbl.GetLifetime, -- self, flChargeBeginTime

			HasGravity = (not tbl.HasGravity) and function(self, ...)
				return self.m_bHasGravity
			end or tbl.HasGravity,
		}
	end

	local function DefineBasicProjectileDefinition(tbl)
		local stReturned = DefineProjectileDefinition(tbl)
		stReturned.m_iType = PROJECTILE_TYPE_BASIC

		return stReturned
	end

	local function DefinePseudoProjectileDefinition(tbl)
		local stReturned = DefineProjectileDefinition(tbl)
		stReturned.m_iType = PROJECTILE_TYPE_PSEUDO

		return stReturned
	end

	local function DefineSimulProjectileDefinition(tbl)
		local stReturned = DefineProjectileDefinition(tbl)
		stReturned.m_iType = PROJECTILE_TYPE_SIMUL

		return stReturned
	end

	local function DefineDerivedProjectileDefinition(def, tbl)
		local stReturned = {}
		for k, v in pairs(def) do
			stReturned[k] = v
		end
		for k, v in pairs(tbl) do
			stReturned[((type(v) ~= "function") and "m_" or "") .. k] = v
		end

		if not tbl.GetOffset and tbl.vecOffset then
			stReturned.GetOffset = function(self, bDucking, bIsFlipped)
				return bIsFlipped and Vector3(self.m_vecOffset.x, -self.m_vecOffset.y, self.m_vecOffset.z)
					or self.m_vecOffset
			end
		end

		if not tbl.GetAngleOffset and tbl.vecAngleOffset then
			stReturned.GetAngleOffset = function(self, flChargeBeginTime)
				return self.m_vecAngleOffset
			end
		end

		if not tbl.GetVelocity and tbl.vecVelocity then
			stReturned.GetVelocity = function(self, ...)
				return self.m_vecVelocity
			end
		end

		if not tbl.GetAngularVelocity and tbl.vecAngularVelocity then
			stReturned.GetAngularVelocity = function(self, ...)
				return self.m_vecAngularVelocity
			end
		end

		if not tbl.GetGravity and tbl.flGravity then
			stReturned.GetGravity = function(self, ...)
				return self.m_flGravity
			end
		end

		if not tbl.GetLifetime and tbl.flLifetime then
			stReturned.GetLifetime = function(self, ...)
				return self.m_flLifetime
			end
		end

		return stReturned
	end

	AppendItemDefinitions(
		1,
		18, -- Rocket Launcher
		205, -- Rocket Launcher (Renamed/Strange)
		228, -- The Black Box
		658, -- Festive Rocket Launcher
		800, -- Silver Botkiller Rocket Launcher Mk.I
		809, -- Gold Botkiller Rocket Launcher Mk.I
		889, -- Rust Botkiller Rocket Launcher Mk.I
		898, -- Blood Botkiller Rocket Launcher Mk.I
		907, -- Carbonado Botkiller Rocket Launcher Mk.I
		916, -- Diamond Botkiller Rocket Launcher Mk.I
		965, -- Silver Botkiller Rocket Launcher Mk.II
		974, -- Gold Botkiller Rocket Launcher Mk.II
		1085, -- Festive Black Box
		15006, -- Woodland Warrior
		15014, -- Sand Cannon
		15028, -- American Pastoral
		15043, -- Smalltown Bringdown
		15052, -- Shell Shocker
		15057, -- Aqua Marine
		15081, -- Autumn
		15104, -- Blue Mew
		15105, -- Brain Candy
		15129, -- Coffin Nail
		15130, -- High Roller's
		15150 -- Warhawk
	)
	aProjectileInfo[1] = DefineBasicProjectileDefinition({
		vecVelocity = Vector3(1100, 0, 0),
		vecMaxs = Vector3(0, 0, 0),
		iAlignDistance = 2000,
		flDamageRadius = 146,
		bGravity = false,

		GetOffset = function(self, bDucking, bIsFlipped)
			return Vector3(23.5, 12 * (bIsFlipped and -1 or 1), bDucking and 8 or -3)
		end,
	})

	AppendItemDefinitions(
		2,
		237 -- Rocket Jumper
	)
	aProjectileInfo[2] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
		iCollisionType = COLLISION_NONE,
		bGravity = false,
	})

	AppendItemDefinitions(
		3,
		730 -- The Beggar's Bazooka
	)
	aProjectileInfo[3] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
		flDamageRadius = 116.8,
		bGravity = false,
	})

	AppendItemDefinitions(
		4,
		1104 -- The Air Strike
	)
	aProjectileInfo[4] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
		flDamageRadius = 131.4,
	})

	AppendItemDefinitions(
		5,
		127 -- The Direct Hit
	)
	aProjectileInfo[5] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
		vecVelocity = Vector3(2000, 0, 0),
		flDamageRadius = 44,
		bGravity = false,
	})

	AppendItemDefinitions(
		6,
		414 -- The Liberty Launcher
	)
	aProjectileInfo[6] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
		vecVelocity = Vector3(1550, 0, 0),
		bGravity = false,
	})

	AppendItemDefinitions(
		7,
		513 -- The Original
	)
	aProjectileInfo[7] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
		bGravity = false,
		GetOffset = function(self, bDucking)
			return Vector3(23.5, 0, bDucking and 8 or -3)
		end,
	})

	-- https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/shared/tf/tf_weapon_dragons_fury.cpp
	AppendItemDefinitions(
		8,
		1178 -- Dragon's Fury
	)
	aProjectileInfo[8] = DefineBasicProjectileDefinition({
		vecVelocity = Vector3(1600, 0, 0), --Vector3(600, 0, 0),
		vecMaxs = Vector3(1, 1, 1),
		bGravity = false,

		GetOffset = function(self, bDucking, bIsFlipped)
			return Vector3(3, 7, -9)
		end,
	})

	AppendItemDefinitions(
		9,
		442 -- The Righteous Bison
	)
	aProjectileInfo[9] = DefineBasicProjectileDefinition({
		vecVelocity = Vector3(1200, 0, 0),
		vecMaxs = Vector3(1, 1, 1),
		iAlignDistance = 2000,
		bGravity = false,

		GetOffset = function(self, bDucking, bIsFlipped)
			return Vector3(23.5, -8 * (bIsFlipped and -1 or 1), bDucking and 8 or -3)
		end,
	})

	AppendItemDefinitions(
		10,
		20, -- Stickybomb Launcher
		207, -- Stickybomb Launcher (Renamed/Strange)
		661, -- Festive Stickybomb Launcher
		797, -- Silver Botkiller Stickybomb Launcher Mk.I
		806, -- Gold Botkiller Stickybomb Launcher Mk.I
		886, -- Rust Botkiller Stickybomb Launcher Mk.I
		895, -- Blood Botkiller Stickybomb Launcher Mk.I
		904, -- Carbonado Botkiller Stickybomb Launcher Mk.I
		913, -- Diamond Botkiller Stickybomb Launcher Mk.I
		962, -- Silver Botkiller Stickybomb Launcher Mk.II
		971, -- Gold Botkiller Stickybomb Launcher Mk.II
		15009, -- Sudden Flurry
		15012, -- Carpet Bomber
		15024, -- Blasted Bombardier
		15038, -- Rooftop Wrangler
		15045, -- Liquid Asset
		15048, -- Pink Elephant
		15082, -- Autumn
		15083, -- Pumpkin Patch
		15084, -- Macabre Web
		15113, -- Sweet Dreams
		15137, -- Coffin Nail
		15138, -- Dressed to Kill
		15155 -- Blitzkrieg
	)
	aProjectileInfo[10] = DefineSimulProjectileDefinition({
		vecOffset = Vector3(16, 8, -6),
		vecAngularVelocity = Vector3(600, 0, 0),
		vecMaxs = Vector3(3.5, 3.5, 3.5),
		bCharges = true,
		flDamageRadius = 150,
		sModelName = "models/weapons/w_models/w_stickybomb.mdl",
		flGravity = 0.25,

		GetVelocity = function(self, flChargeBeginTime)
			return Vector3(900 + CLAMP(flChargeBeginTime / 4, 0, 1) * 1500, 0, 200)
		end,
	})

	AppendItemDefinitions(
		11,
		1150 -- The Quickiebomb Launcher
	)
	aProjectileInfo[11] = DefineDerivedProjectileDefinition(aProjectileInfo[10], {
		sModelName = "models/workshop/weapons/c_models/c_kingmaker_sticky/w_kingmaker_stickybomb.mdl",
		flGravity = 0.25,
		GetVelocity = function(self, flChargeBeginTime)
			return Vector3(900 + CLAMP(flChargeBeginTime / 1.2, 0, 1) * 1500, 0, 200)
		end,
	})

	AppendItemDefinitions(
		12,
		130 -- The Scottish Resistance
	)
	aProjectileInfo[12] = DefineDerivedProjectileDefinition(aProjectileInfo[10], {
		sModelName = "models/weapons/w_models/w_stickybomb_d.mdl",
		flGravity = 0.25,
	})

	AppendItemDefinitions(
		13,
		265 -- Sticky Jumper
	)
	aProjectileInfo[13] = DefineDerivedProjectileDefinition(aProjectileInfo[12], {
		iCollisionType = COLLISION_NONE,
		flGravity = 0.25,
	})

	AppendItemDefinitions(
		14,
		19, -- Grenade Launcher
		206, -- Grenade Launcher (Renamed/Strange)
		1007, -- Festive Grenade Launcher
		15077, -- Autumn
		15079, -- Macabre Web
		15091, -- Rainbow
		15092, -- Sweet Dreams
		15116, -- Coffin Nail
		15117, -- Top Shelf
		15142, -- Warhawk
		15158 -- Butcher Bird
	)
	aProjectileInfo[14] = DefineSimulProjectileDefinition({
		vecOffset = Vector3(16, 8, -6),
		vecVelocity = Vector3(1200, 0, 200),
		vecAngularVelocity = Vector3(600, 0, 0),
		flGravity = 0.25,
		vecMaxs = Vector3(2, 2, 2),
		flElasticity = 0.45,
		flLifetime = 2.175,
		flDamageRadius = 146,
		sModelName = "models/weapons/w_models/w_grenade_grenadelauncher.mdl",
	})

	AppendItemDefinitions(
		15,
		1151 -- The Iron Bomber
	)
	aProjectileInfo[15] = DefineDerivedProjectileDefinition(aProjectileInfo[14], {
		flElasticity = 0.09,
		flLifetime = 1.6,
		flDamageRadius = 124,
	})

	AppendItemDefinitions(
		16,
		308 -- The Loch-n-Load
	)
	aProjectileInfo[16] = DefineDerivedProjectileDefinition(aProjectileInfo[14], {
		iType = PROJECTILE_TYPE_PSEUDO,
		vecVelocity = Vector3(1500, 0, 200),
		flDrag = 0.225,
		flGravity = 1,
		flLifetime = 2.3,
		flDamageRadius = 0,
	})

	AppendItemDefinitions(
		17,
		996 -- The Loose Cannon
	)
	aProjectileInfo[17] = DefineDerivedProjectileDefinition(aProjectileInfo[14], {
		vecVelocity = Vector3(1440, 0, 200),
		vecMaxs = Vector3(6, 6, 6),
		bStopOnHittingEnemy = false,
		bCharges = true,
		sModelName = "models/weapons/w_models/w_cannonball.mdl",

		GetLifetime = function(self, flChargeBeginTime)
			return 1 * flChargeBeginTime
		end,
	})

	AppendItemDefinitions(
		18,
		56, -- The Huntsman
		1005, -- Festive Huntsman
		1092 -- The Fortified Compound
	)
	aProjectileInfo[18] = DefinePseudoProjectileDefinition({
		vecOffset = Vector3(23.5, -8, -3),
		vecMaxs = Vector3(0, 0, 0),
		iAlignDistance = 2000,
		bCharges = true,

		GetVelocity = function(self, flChargeBeginTime)
			return Vector3(1800 + CLAMP(flChargeBeginTime, 0, 1) * 800, 0, 0)
		end,

		GetGravity = function(self, flChargeBeginTime)
			return 0.5 - CLAMP(flChargeBeginTime, 0, 1) * 0.4
		end,
	})

	AppendItemDefinitions(
		19,
		39, -- The Flare Gun
		351, -- The Detonator
		595, -- The Manmelter
		1081 -- Festive Flare Gun
	)
	aProjectileInfo[19] = DefinePseudoProjectileDefinition({
		vecVelocity = Vector3(2000, 0, 0),
		vecMaxs = Vector3(0, 0, 0),
		flGravity = 0.3,
		flDrag = 0.5,
		iAlignDistance = 2000,
		flCollideWithTeammatesDelay = 0.25,

		GetOffset = function(self, bDucking, bIsFlipped)
			return Vector3(23.5, 12 * (bIsFlipped and -1 or 1), bDucking and 8 or -3)
		end,
	})

	AppendItemDefinitions(
		20,
		740 -- The Scorch Shot
	)
	aProjectileInfo[20] = DefineDerivedProjectileDefinition(aProjectileInfo[19], {
		flDamageRadius = 110,
	})

	AppendItemDefinitions(
		21,
		305, -- Crusader's Crossbow
		1079 -- Festive Crusader's Crossbow
	)
	aProjectileInfo[21] = DefinePseudoProjectileDefinition({
		vecOffset = Vector3(23.5, -8, -3),
		vecVelocity = Vector3(2400, 0, 0),
		vecMaxs = Vector3(3, 3, 3),
		flGravity = 0.2,
		iAlignDistance = 2000,
		iCollisionType = COLLISION_HEAL_TEAMMATES,
	})

	AppendItemDefinitions(
		22,
		997 -- The Rescue Ranger
	)
	aProjectileInfo[22] = DefineDerivedProjectileDefinition(aProjectileInfo[21], {
		vecMaxs = Vector3(1, 1, 1),
		iCollisionType = COLLISION_HEAL_BUILDINGS,
	})

	AppendItemDefinitions(
		23,
		17, -- Syringe Gun
		36, -- The Blutsauger
		204, -- Syringe Gun (Renamed/Strange)
		412 -- The Overdose
	)
	aProjectileInfo[23] = DefinePseudoProjectileDefinition({
		vecOffset = Vector3(16, 6, -8),
		vecVelocity = Vector3(1000, 0, 0),
		vecMaxs = Vector3(1, 1, 1),
		flGravity = 0.3,
		flCollideWithTeammatesDelay = 0,
	})

	AppendItemDefinitions(
		24,
		58, -- Jarate
		222, -- Mad Milk
		1083, -- Festive Jarate
		1105, -- The Self-Aware Beauty Mark
		1121 -- Mutated Milk
	)
	aProjectileInfo[24] = DefinePseudoProjectileDefinition({
		vecOffset = Vector3(16, 8, -6),
		vecVelocity = Vector3(1000, 0, 200),
		vecMaxs = Vector3(8, 8, 8),
		flGravity = 1.125,
		flDamageRadius = 200,
	})

	AppendItemDefinitions(
		25,
		812, -- The Flying Guillotine
		833 -- The Flying Guillotine (Genuine)
	)
	aProjectileInfo[25] = DefinePseudoProjectileDefinition({
		vecOffset = Vector3(23.5, 8, -3),
		vecVelocity = Vector3(3000, 0, 300),
		vecMaxs = Vector3(2, 2, 2),
		flGravity = 2.25,
		flDrag = 1.3,
	})

	AppendItemDefinitions(
		26,
		44 -- The Sandman
	)
	aProjectileInfo[26] = DefineSimulProjectileDefinition({
		vecVelocity = Vector3(2985.1118164063, 0, 298.51116943359),
		vecAngularVelocity = Vector3(0, 50, 0),
		vecMaxs = Vector3(4.25, 4.25, 4.25),
		flElasticity = 0.45,
		sModelName = "models/weapons/w_models/w_baseball.mdl",

		GetFirePosition = function(self, pLocalPlayer, vecLocalView, vecViewAngles, bIsFlipped)
			--https://github.com/ValveSoftware/source-sdk-2013/blob/0565403b153dfcde602f6f58d8f4d13483696a13/src/game/shared/tf/tf_weapon_bat.cpp#L232
			local vecFirePos = pLocalPlayer:GetAbsOrigin()
				+ ((Vector3(0, 0, 50) + (vecViewAngles:Forward() * 32)) * pLocalPlayer:GetPropFloat("m_flModelScale"))

			local resultTrace =
				TRACE_HULL(vecLocalView, vecFirePos, -Vector3(8, 8, 8), Vector3(8, 8, 8), MASK_SHOT_HULL) -- MASK_SOLID_BRUSHONLY

			return (resultTrace.fraction == 1) and resultTrace.endpos or nil
		end,
	})

	AppendItemDefinitions(
		27,
		648 -- The Wrap Assassin
	)
	aProjectileInfo[27] = DefineDerivedProjectileDefinition(aProjectileInfo[26], {
		vecMins = Vector3(-2.990180015564, -2.5989532470703, -2.483987569809),
		vecMaxs = Vector3(2.6593606472015, 2.5989530086517, 2.4839873313904),
		flElasticity = 0,
		flDamageRadius = 50,
		sModelName = "models/weapons/c_models/c_xms_festive_ornament.mdl",
	})

	AppendItemDefinitions(
		28,
		441 -- The Cow Mangler 5000
	)
	aProjectileInfo[28] = DefineDerivedProjectileDefinition(aProjectileInfo[1], {
		bGravity = false,
		GetOffset = function(self, bDucking, bIsFlipped)
			return Vector3(23.5, 8 * (bIsFlipped and 1 or -1), bDucking and 8 or -3)
		end,
	})

	--https://github.com/ValveSoftware/source-sdk-2013/blob/0565403b153dfcde602f6f58d8f4d13483696a13/src/game/shared/tf/tf_weapon_raygun.cpp#L249
	AppendItemDefinitions(
		29,
		588 -- The Pomson 6000
	)
	aProjectileInfo[29] = DefineDerivedProjectileDefinition(aProjectileInfo[9], {
		vecAbsoluteOffset = Vector3(0, 0, -13),
		flCollideWithTeammatesDelay = 0,
		bGravity = false,
	})

	AppendItemDefinitions(
		30,
		1180 -- Gas Passer
	)
	aProjectileInfo[30] = DefinePseudoProjectileDefinition({
		vecOffset = Vector3(16, 8, -6),
		vecVelocity = Vector3(2000, 0, 200),
		vecMaxs = Vector3(8, 8, 8),
		flGravity = 1,
		flDrag = 1.32,
		flDamageRadius = 200,
	})

	AppendItemDefinitions(
		31,
		528 -- The Short Circuit
	)
	aProjectileInfo[31] = DefineBasicProjectileDefinition({
		vecOffset = Vector3(40, 15, -10),
		vecVelocity = Vector3(700, 0, 0),
		vecMaxs = Vector3(1, 1, 1),
		flCollideWithTeammatesDelay = 99999,
		flLifetime = 1.25,
		bGravity = false,
	})

	AppendItemDefinitions(
		32,
		42, -- Sandvich
		159, -- The Dalokohs Bar
		311, -- The Buffalo Steak Sandvich
		433, -- Fishcake
		863, -- Robo-Sandvich
		1002, -- Festive Sandvich
		1190 -- Second Banana
	)
	aProjectileInfo[32] = DefinePseudoProjectileDefinition({
		vecOffset = Vector3(0, 0, -8),
		vecAngleOffset = Vector3(-10, 0, 0),
		vecVelocity = Vector3(500, 0, 0),
		vecMaxs = Vector3(17, 17, 10),
		flGravity = 1.02,
		iTraceMask = MASK_SHOT_HULL, -- MASK_SHOT_HULL
		iCollisionType = COLLISION_HEAL_HURT,
	})

	return GetProjectileInformation
end)
__bundle_register("multipoint", function(require, _LOADED, __bundle_register, __bundle_modules)
	local multipoint = {}

	--- relative to Maxs().z
	local z_offsets = { 0.5, 0.7, 0.9, 0.4, 0.2 }

	--- inverse of z_offsets
	local huntsman_z_offsets = { 0.9, 0.7, 0.5, 0.4, 0.2 }

	local splash_offsets = { 0.2, 0.4, 0.5, 0.7, 0.9 }

	---@param vHeadPos Vector3
	---@param pTarget Entity
	---@param vecPredictedPos Vector3
	---@param pWeapon Entity
	---@param weaponInfo WeaponInfo
	---@return boolean, Vector3?  -- visible, final predicted hit position (or nil)
	function multipoint.Run(pTarget, pWeapon, weaponInfo, vHeadPos, vecPredictedPos)
		local proj_type = pWeapon:GetWeaponProjectileType()
		local bExplosive = weaponInfo.m_flDamageRadius > 0 and proj_type == E_ProjectileType.TF_PROJECTILE_ROCKET
			or proj_type == E_ProjectileType.TF_PROJECTILE_PIPEBOMB
			or proj_type == E_ProjectileType.TF_PROJECTILE_PIPEBOMB_REMOTE
			or proj_type == E_ProjectileType.TF_PROJECTILE_STICKY_BALL
			or proj_type == E_ProjectileType.TF_PROJECTILE_CANNONBALL
			or proj_type == E_ProjectileType.TF_PROJECTILE_PIPEBOMB_PRACTICE

		local bSplashWeapon = proj_type == E_ProjectileType.TF_PROJECTILE_ROCKET
			or proj_type == E_ProjectileType.TF_PROJECTILE_PIPEBOMB_REMOTE
			or proj_type == E_ProjectileType.TF_PROJECTILE_PIPEBOMB_PRACTICE
			or proj_type == E_ProjectileType.TF_PROJECTILE_CANNONBALL
			or proj_type == E_ProjectileType.TF_PROJECTILE_PIPEBOMB
			or proj_type == E_ProjectileType.TF_PROJECTILE_STICKY_BALL
			or proj_type == E_ProjectileType.TF_PROJECTILE_FLAME_ROCKET

		local bHuntsman = pWeapon:GetWeaponID() == E_WeaponBaseID.TF_WEAPON_COMPOUND_BOW
		local chosen_offsets = bHuntsman and huntsman_z_offsets
			or (bSplashWeapon or bExplosive) and splash_offsets
			or z_offsets

		local trace = nil
		local horizontalDist = (vecPredictedPos - vHeadPos):Length2D()
		local charge = weaponInfo.m_bCharges and pWeapon:GetChargeBeginTime() or globals.CurTime()

		local gravity = 400 * weaponInfo:GetGravity(charge)
		local projSpeed = weaponInfo:GetVelocity(charge):Length()
		local maxsZ = pTarget:GetMaxs().z
		local t = horizontalDist / projSpeed
		local drop = 0.5 * gravity * t * t

		for i = 1, #chosen_offsets do
			local offset = chosen_offsets[i]
			local baseZ = (maxsZ * offset)

			local zOffset = baseZ + drop
			local origin = vecPredictedPos + Vector3(0, 0, zOffset)

			trace = engine.TraceHull(
				vHeadPos,
				origin,
				weaponInfo.m_vecMins,
				weaponInfo.m_vecMaxs,
				weaponInfo.m_iTraceMask,
				function(ent, contentsMask)
					return false
				end
			)

			if trace and trace.fraction >= 1 then
				-- build a new Vector3 for the visible hit point
				local finalPos = Vector3(vecPredictedPos:Unpack())
				finalPos.z = origin.z
				return true, finalPos
			end
		end

		-- nothing visible among multipoints
		return false, nil
	end

	return multipoint
end)
return __bundle_require("__root")
