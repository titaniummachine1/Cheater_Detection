---@diagnostic disable: param-type-mismatch

---@alias AimTarget { entity : Entity, angles : EulerAngles, factor : number }

---@type boolean, lnxLib
local libLoaded, lnxLib = pcall(require, "lnxLib")
if not libLoaded then
	client.ChatPrintf("\x07FF0000LnxLib failed to load!")
	engine.PlaySound("common/bugreporter_failed.wav")
	return
end

assert(libLoaded, "lnxLib not found, please install it!")
assert(lnxLib.GetVersion() >= 1.00, "lnxLib version is too old, please update it!")

-- TimMenu should not be unloaded as other scripts may be using it

local menuLoaded, TimMenu = pcall(require, "TimMenu")
if not menuLoaded then
	client.ChatPrintf("\x07FF0000TimMenu failed to load!")
	engine.PlaySound("common/bugreporter_failed.wav")
	return
end

assert(menuLoaded, "TimMenu not found, please install it!")

-- Safety check for lnxLib modules
assert(lnxLib.Utils, "lnxLib.Utils not found!")
assert(lnxLib.TF2, "lnxLib.TF2 not found!")

local Math, Conversion = lnxLib.Utils.Math, lnxLib.Utils.Conversion
local WPlayer, WWeapon = lnxLib.TF2.WPlayer, lnxLib.TF2.WWeapon
local Helpers = lnxLib.TF2.Helpers
local Prediction = lnxLib.TF2.Prediction

local Menu = { -- this is the config that will be loaded every time u load the script

	currentTab = 1,
	tabs = { -- dont touch this, this is just for managing the tabs in the menu
		Main = true,
		Advanced = false,
		Visuals = false,
	},

	Main = {
		Active = true, --disable lua
		AutoWalk = true,
		AutoWarp = true,
		AutoBlink = false,
		MoveAsistance = true,
		Keybind = KEY_NONE, -- Keybind for trickstab activation
		ActivationMode = 0, -- 0=Always, 1=On Hold, 2=On Release, 3=Toggle, 4=On Click
	},

	Advanced = {
		BackstabRange = 66, -- Backstab range in hammer units
		MinBackstabPoints = 4, -- Minimum number of backstab points in simulation before allowing warp (slider: 1-30)
		MaxBackstabTime = 14, -- Maximum time (in ticks) to attempt backstab
		UseAngleSnap = true, -- Use angle snapping for movement (disable for smooth rotation - needs lbox fix)
		ColisionCheck = true, -- Enable collision checking with map geometry (stairs, walls, etc.)
		AdvancedPred = true, -- Enable advanced trace validation for range checks
		ManualDirection = false, -- Manual movement direction control
		AutoRecharge = true, -- Auto recharge warp after kill/hurt
		AntiBackstabResolver = false, -- Force cheater view angles to look at us (HvH mode)
		HelperSprint = true, -- Sprint + smooth warp when close to backstab (within 10 deg, 66 units)
		FakelagOnDirectionChange = true, -- Use fakelag when switching direction to confuse enemy
		SmoothWarp = false, -- Enable smooth warp bonus ticks (experimental)
	},

	Visuals = {
		Active = true,
		VisualizePoints = true,
		VisualizeStabPoint = true,
		VisualizeUsellesSimulations = true,
		Attack_Circle = true,
		BackLine = false,
	},
}

local pLocal = nil
local emptyVec = Vector3(0, 0, 0)

-- Game Constants (TF2 specific) - MUST be defined before use
local TF2 = {
	-- Melee combat
	BACKSTAB_RANGE = 66, -- Hammer units for knife reach
	MELEE_HIT_RANGE = 225, -- Max distance to hit with melee (for target filtering)
	BACKSTAB_ANGLE = 90, -- Degrees for valid backstab
	SWING_HULL_SIZE = 38, -- Melee swing detection hull

	-- Player dimensions
	HITBOX_RADIUS = 24, -- Player collision radius
	HITBOX_HEIGHT = 82, -- Player height
	VIEW_OFFSET_Z = 75, -- Eye level from ground

	-- Movement & physics
	MAX_SPEED = 320, -- Base movement speed
	ACCELERATION = 10, -- Ground acceleration
	GROUND_FRICTION = 4.0, -- Friction coefficient
	STOP_SPEED = 100, -- Speed at which friction stops

	-- Warp mechanics
	WARP_READY_TICKS = 23, -- Minimum ticks for warp charge
	AUTO_RECHARGE_THRESHOLD = 24, -- Ticks before auto-recharge
	TARGET_EXTENSION = 450, -- Extension distance for pathfinding

	-- Collision angles
	FORWARD_COLLISION_ANGLE = 55, -- Wall collision angle
	GROUND_ANGLE_LOW = 45, -- Ground collision low angle
	GROUND_ANGLE_HIGH = 55, -- Ground collision high angle

	-- Scoring & thresholds
	MIN_BACKSTAB_POINTS = 3, -- Minimum points for valid path
	STAIRSTAB_HEIGHT = 82, -- Height threshold for stairstabs
	ATTACK_RANGE = 225, -- Attack range plus warp distance
	MAX_SCORE_DISTANCE = 120, -- Distance for scoring calculations
	YAW_WEIGHT = 0.7, -- Weight for yaw component in scoring
	DISTANCE_WEIGHT = 0.3, -- Weight for distance component in scoring

	-- Ping & cooldowns
	MIN_PING_COOLDOWN = 7, -- Minimum ping cooldown ticks
	PING_BUFFER_TICKS = 5, -- Buffer ticks for ping cooldown

	-- Manual control
	MANUAL_THRESHOLD = 1, -- Threshold for manual direction input

	-- TF2 Classes
	SPY = 8, -- Spy class ID

	-- Speed thresholds
	STUCK_SPEED_THRESHOLD = 10, -- Speed threshold for stuck detection

	-- Command speeds
	MAX_CMD_SPEED = 400, -- Maximum command movement speed
}

-- Math constants (precomputed)
local MATH = {
	TWO_PI = 2 * math.pi,
	DEG_TO_RAD = math.pi / 180,
	RAD_TO_DEG = 180 / math.pi,
	HALF_PI = math.pi / 2,
	THREE_QUARTER_PI = 3 * math.pi / 4,
	HALF_CIRCLE = 180,
	FULL_CIRCLE = 360,
}

-- Hull dimensions (precomputed)
local HULL = {
	MIN = Vector3(-23.99, -23.99, 0),
	MAX = Vector3(23.99, 23.99, 82),
	SWING_MIN = Vector3(-19, -19, -19), -- Half of 38
	SWING_MAX = Vector3(19, 19, 19),
}

-- Client frame stages for FrameStageNotify
local E_ClientFrameStage = {
	FRAME_NET_UPDATE_END = 4, -- When network props are updated
}

-- Playerlist priority for cheaters
local CHEATER_PRIORITY = 10

-- Input button flags
local IN_ATTACK = 1
local IN_SPEED = 131072 -- Sprint button (bit 17)

-- Direction rate limiting
local DIRECTION_CHANGE_COOLDOWN = 11 -- Ticks between direction changes (10 times/sec max)
local lastDirectionChangeTick = 0
local lastDirection = nil
local lastManualSide = nil -- Track last manual direction (left/right) for blink trigger

-- Position history for lag compensation (1 second = 66 ticks at 66 tick server)
local POSITION_HISTORY_SIZE = 66
local positionHistory = {} -- Queue: index 1 = newest, index 66 = oldest

-- Enemy angle tracking for smooth resolver
local enemyAngleCache = {} -- [steamID] = {yaw, lastUpdate}

-- Smooth warp integration (extends main warp by 3 bonus ticks)
local SMOOTH_WARP = {
	BONUS_TICKS = 3, -- Max extra ticks after main warp (server kicks on 4th)
	RESERVE_TICKS = 3, -- Always reserve this many for main warp bonus
	ASSIST_ANGLE_THRESHOLD = 10, -- Use smooth warp when backstab angle within this many degrees
	NEW_COMMANDS_SIZE = 4, -- Bits for new_commands in CLC_Move
	BACKUP_COMMANDS_SIZE = 3, -- Bits for backup_commands in CLC_Move
	CLC_MOVE_TYPE = 9, -- NetMessage type for CLC_Move
}

-- Smooth warp state
local smoothWarpTicks = 0 -- Accumulated smooth warp ticks
local smoothWarpActive = false -- Currently using smooth warp for movement assist
local smoothWarpBonusActive = false -- Using 3 bonus ticks after main warp
local smoothWarpDirection = nil -- Direction for smooth warp movement
local smoothWarpDestination = nil -- Target position for smooth warp
local lastSmoothWarpRecharge = 0 -- Last tick we recharged

-- Class speed mappings
local CLASS_MAX_SPEEDS = {
	[1] = 400, -- Scout
	[2] = 300, -- Sniper
	[3] = 240, -- Soldier
	[4] = 280, -- Demoman
	[5] = 320, -- Medic
	[6] = 280, -- Heavy
	[7] = 300, -- Pyro
	[8] = 320, -- Spy
	[9] = 320, -- Engineer
}

local pLocalPos = emptyVec
local pLocalViewPos = emptyVec
local pLocalViewOffset = Vector3(0, 0, TF2.VIEW_OFFSET_Z)

local TargetPlayer = {}
local endwarps = {}
local debugCornerData = {} -- Debug info for corner visualization

-- Cache ConVars for performance (accessed frequently)
local SV_GRAVITY = client.GetConVar("sv_gravity")
local CL_INTERP = client.GetConVar("cl_interp")

-- Ensure warp works without user binding dash key
-- KEY_SCROLLLOCKTOGGLE (106) = impossible to accidentally press
if gui.GetValue("dash move key") == 0 then
	gui.SetValue("dash move key", 106)
end

-- Configure triggerbot for auto backstab: key=NONE, backstab=Rage, FOV=99
gui.SetValue("trigger key", 0)
gui.SetValue("auto backstab", 2)
gui.SetValue("auto backstab fov", 99)

-- Keybind state tracking
local previousKeyState = false
local toggleActive = false
local clickProcessed = false

-- Function to check if keybind should activate trickstab logic
local function ShouldActivateTrickstab()
	-- Mode 0: Always - always active, no keybind needed
	if Menu.Main.ActivationMode == 0 then
		return true
	end

	-- For other modes, check keybind
	if Menu.Main.Keybind == KEY_NONE then
		return true -- Fallback if no keybind set
	end

	local currentKeyState = input.IsButtonDown(Menu.Main.Keybind)
	local shouldActivate = false

	-- Mode 1: On Hold - only active while holding the key
	if Menu.Main.ActivationMode == 1 then
		shouldActivate = currentKeyState

	-- Mode 2: On Release - active when NOT holding the key (reversed from On Hold)
	elseif Menu.Main.ActivationMode == 2 then
		shouldActivate = not currentKeyState

	-- Mode 3: Toggle - toggle on/off with key press
	elseif Menu.Main.ActivationMode == 3 then
		if currentKeyState and not previousKeyState then
			toggleActive = not toggleActive
		end
		shouldActivate = toggleActive

	-- Mode 4: On Click - activate once per key press
	elseif Menu.Main.ActivationMode == 4 then
		if currentKeyState and not previousKeyState then
			clickProcessed = false
		end
		if not currentKeyState and previousKeyState then
			clickProcessed = true -- Reset for next click
		end
		shouldActivate = currentKeyState and not clickProcessed
	end

	previousKeyState = currentKeyState
	return shouldActivate
end

local Lua__fullPath = GetScriptName()
local Lua__fileName = Lua__fullPath:match("\\([^\\]-)$"):gsub("%.lua$", "")

local function CreateCFG(folder_name, table)
	local success, fullPath = filesystem.CreateDirectory(folder_name)
	local filepath = tostring(fullPath .. "/config.cfg")
	local file = io.open(filepath, "w")

	if file then
		local function serializeTable(tbl, level)
			level = level or 0
			local result = string.rep("    ", level) .. "{\n"
			for key, value in pairs(tbl) do
				result = result .. string.rep("    ", level + 1)
				if type(key) == "string" then
					result = result .. '["' .. key .. '"] = '
				else
					result = result .. "[" .. key .. "] = "
				end
				if type(value) == "table" then
					result = result .. serializeTable(value, level + 1) .. ",\n"
				elseif type(value) == "string" then
					result = result .. '"' .. value .. '",\n'
				else
					result = result .. tostring(value) .. ",\n"
				end
			end
			result = result .. string.rep("    ", level) .. "}"
			return result
		end

		local serializedConfig = serializeTable(table)
		file:write(serializedConfig)
		file:close()
		printc(255, 183, 0, 255, "[" .. os.date("%H:%M:%S") .. "] Saved Config to " .. tostring(fullPath))
	end
end

local function LoadCFG(folder_name)
	local success, fullPath = filesystem.CreateDirectory(folder_name)
	local filepath = tostring(fullPath .. "/config.cfg")
	local file = io.open(filepath, "r")

	if file then
		local content = file:read("*a")
		file:close()
		local chunk, err = load("return " .. content)
		if chunk then
			printc(0, 255, 140, 255, "[" .. os.date("%H:%M:%S") .. "] Loaded Config from " .. tostring(fullPath))
			return chunk()
		else
			CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu) --saving the config
			print("Error loading configuration:", err)
		end
	end
end

local status, loadedMenu = pcall(function()
	return assert(LoadCFG(string.format([[Lua %s]], Lua__fileName)))
end) -- Auto-load config

-- Function to check if all expected keys and structure exist in the loaded config
local function checkConfigStructure(expectedMenu, loadedMenu)
	-- First check: ensure loaded config has ONLY the expected keys (no extra keys)
	for key, _ in pairs(loadedMenu) do
		if expectedMenu[key] == nil then
			print(string.format("Unexpected key in config: %s", key))
			return false
		end
	end

	-- Second check: ensure all expected keys exist with correct types
	for key, expectedValue in pairs(expectedMenu) do
		local loadedValue = loadedMenu[key]

		-- Check if key exists
		if loadedValue == nil then
			print(string.format("Missing key in config: %s", key))
			return false
		end

		-- Check if type matches
		if type(loadedValue) ~= type(expectedValue) then
			print(
				string.format(
					"Type mismatch for key %s: expected %s, got %s",
					key,
					type(expectedValue),
					type(loadedValue)
				)
			)
			return false
		end

		-- Recursively check nested tables
		if type(expectedValue) == "table" and type(loadedValue) == "table" then
			if not checkConfigStructure(expectedValue, loadedValue) then
				return false
			end
		end
	end

	return true
end

-- Execute this block only if loading the config was successful
if status then
	-- Simple validation: check if loaded config has expected structure
	if checkConfigStructure(Menu, loadedMenu) and not input.IsButtonDown(KEY_LSHIFT) then
		Menu = loadedMenu
		print("Config loaded successfully")
		print(string.format("DEBUG CONFIG: ManualDirection loaded as: %s", tostring(Menu.Advanced.ManualDirection)))
	else
		print("Config is invalid or outdated. Creating a new config.")
		CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu) -- Save the config
	end
else
	print("Failed to load config. Creating a new config.")
	CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu) -- Save the config
end

-- Normalizes a vector to a unit vector
-- ultimate Normalize a vector
local function Normalize(vec)
	return vec / vec:Length()
end

-- Normalize angle to [-180, 180] range
local function NormalizeYaw(yaw)
	yaw = yaw % MATH.FULL_CIRCLE
	if yaw > MATH.HALF_CIRCLE then
		yaw = yaw - MATH.FULL_CIRCLE
	elseif yaw < -MATH.HALF_CIRCLE then
		yaw = yaw + MATH.FULL_CIRCLE
	end
	return yaw
end

local function PositionYaw(source, dest)
	local delta = Normalize(source - dest)
	return math.deg(math.atan(delta.y, delta.x))
end

-- Calculate angles from source to target
local function PositionAngles(source, dest)
	local delta = dest - source
	local dist = math.sqrt(delta.x * delta.x + delta.y * delta.y)
	local pitch = math.deg(math.atan(-delta.z, dist))
	local yaw = math.deg(math.atan(delta.y, delta.x))
	return { pitch = pitch, yaw = yaw }
end

-- Apply ground friction to velocity
local function ApplyFriction(velocity, onGround)
	if not velocity or not onGround then
		return velocity or Vector3(0, 0, 0)
	end

	local speed = velocity:Length()
	if speed < TF2.STOP_SPEED then
		return Vector3(0, 0, 0)
	end

	local friction = TF2.GROUND_FRICTION * globals.TickInterval()
	local control = (speed < TF2.STOP_SPEED) and TF2.STOP_SPEED or speed
	local drop = control * friction

	local newspeed = speed - drop
	if newspeed < 0 then
		newspeed = 0
	end

	if newspeed < speed then
		local scale = newspeed / speed
		return velocity * scale
	end

	return velocity
end

-- Walk in a specific direction relative to view angles
-- Two methods: angle snapping (works now) or smooth rotation (needs lbox fix)
-- forceNoSnap: force disable angle snap (for MoveAsistance without stab points)
local function WalkInDirection(cmd, direction, forceNoSnap)
	local dx, dy = direction.x, direction.y

	-- Default to angle snap if not set (unless forced off)
	local useAngleSnap = Menu.Advanced.UseAngleSnap
	if useAngleSnap == nil then
		useAngleSnap = true
	end

	-- Disable snap if forced (e.g., MoveAsistance without stab points)
	if forceNoSnap then
		useAngleSnap = false
	end

	if useAngleSnap then
		-- METHOD 1: Angle snap - Account for player's current input and rotate view
		-- So that their input direction results in the optimal walk direction

		-- Get player's current input (may be forward, backward, diagonal, etc)
		local forwardMove = cmd:GetForwardMove()
		local sideMove = cmd:GetSideMove()

		-- Calculate desired world direction (radians)
		local targetYaw = math.atan(dy, dx)

		-- If player has input, calculate angle relative to view forward
		-- Otherwise assume walking forward
		local inputAngle = 0
		if math.abs(forwardMove) > 0.1 or math.abs(sideMove) > 0.1 then
			-- TF2: sideMove is NEGATIVE for right, POSITIVE for left
			-- atan2(y, x) gives angle from x-axis (forward)
			-- Negate sideMove to get correct angle direction
			inputAngle = math.atan(-sideMove, forwardMove)
		end

		-- Calculate what view angle makes the input go in target direction
		-- Current movement direction = viewYaw + inputAngle
		-- We want: viewYaw + inputAngle = targetYaw
		-- So: viewYaw = targetYaw - inputAngle
		local desiredViewYaw = targetYaw - inputAngle

		-- Convert to degrees and normalize
		desiredViewYaw = desiredViewYaw * MATH.RAD_TO_DEG
		desiredViewYaw = NormalizeYaw(desiredViewYaw)

		-- Get current view angles
		local viewAngles = engine.GetViewAngles()

		-- Set absolute yaw that makes player input go in optimal direction
		local newAngles = EulerAngles(viewAngles.x, desiredViewYaw, 0)
		engine.SetViewAngles(newAngles)

		-- Keep player's input unchanged (they might be walking backward/diagonal)
		-- The view rotation will make their input go in the right direction!
	else
		-- Calculate target yaw from direction vector
		local targetYaw = (math.atan(dy, dx) + MATH.TWO_PI) % MATH.TWO_PI

		-- Get current view yaw
		local _, currentYaw = cmd:GetViewAngles()
		currentYaw = currentYaw * MATH.DEG_TO_RAD

		-- Calculate angle difference
		local yawDiff = (targetYaw - currentYaw + math.pi) % MATH.TWO_PI - math.pi

		-- Calculate movement input
		local forward = math.cos(yawDiff) * TF2.MAX_CMD_SPEED
		local side = math.sin(-yawDiff) * TF2.MAX_CMD_SPEED

		cmd:SetForwardMove(forward)
		cmd:SetSideMove(side)
	end
end

local BackstabPos = emptyVec

-- Function to check if the weapon can attack right now
local function IsReadyToAttack(cmd, weapon)
	local TickCount = globals.TickCount()
	local NextAttackTick = Conversion.Time_to_Ticks(weapon:GetPropFloat("m_flNextPrimaryAttack") or 0)
	return NextAttackTick <= TickCount
end

local positions = {}
local pathHitWall = {} -- Track which paths hit walls (for red color visualization)
local smoothWarpPositions = {} -- Store 3 bonus smooth warp tick positions (magenta visualization)
-- Function to update the cache for the local player and loadout slot
local function UpdateLocalPlayerCache()
	pLocal = entities.GetLocalPlayer()
	if
		not pLocal
		or pLocal:GetPropInt("m_iClass") ~= TF2.SPY
		or not pLocal:IsAlive()
		or pLocal:InCond(TFCond_Cloaked)
		or pLocal:InCond(TFCond_CloakFlicker)
		or pLocal:GetPropInt("m_bFeignDeathReady") == 1
	then
		return false
	end

	--cachedLoadoutSlot2 = pLocal and pLocal:GetEntityForLoadoutSlot(2) or nil
	pLocalViewOffset = pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")
	pLocalPos = pLocal:GetAbsOrigin()
	pLocalViewPos = pLocal and (pLocal:GetAbsOrigin() + pLocalViewOffset) or pLocalPos or emptyVec

	endwarps = {}
	positions = {}
	TargetPlayer = {}

	return pLocal
end

-- Check if we can hit a specific enemy with melee (LOS check at MELEE_HIT_RANGE)
-- Used for target filtering - returns false if world geometry blocks the path
local function CanHitEnemy(enemyEntity, enemyPos)
	assert(pLocal, "CanHitEnemy: pLocal is nil")
	assert(enemyEntity and enemyPos, "CanHitEnemy: enemyEntity or enemyPos is nil")

	-- Calculate view position directly (don't rely on pLocalViewPos which may not be set yet)
	local myPos = pLocal:GetAbsOrigin()
	if not myPos then
		return false
	end
	local viewPos = myPos + pLocalViewOffset

	-- Direction to enemy center
	local dirToEnemy = enemyPos - viewPos
	local distToEnemy = dirToEnemy:Length()

	-- Too far = can't hit
	if distToEnemy > TF2.MELEE_HIT_RANGE then
		return false
	end

	-- Very close = can hit
	if distToEnemy < 10 then
		return true
	end

	-- Normalize direction
	local direction = dirToEnemy / distToEnemy
	local traceEnd = viewPos + direction * TF2.MELEE_HIT_RANGE

	-- Line trace first (faster)
	local lineTrace = engine.TraceLine(viewPos, traceEnd, MASK_PLAYERSOLID_BRUSHONLY)
	if lineTrace.fraction >= 0.95 or lineTrace.entity == enemyEntity then
		return true -- Clear path or hit the enemy
	end

	-- Hull trace for melee swing
	local hullTrace = engine.TraceHull(viewPos, traceEnd, HULL.SWING_MIN, HULL.SWING_MAX, MASK_PLAYERSOLID_BRUSHONLY)
	if hullTrace.fraction >= 0.95 or hullTrace.entity == enemyEntity then
		return true -- Clear path or hit the enemy
	end

	-- Both traces blocked by world = can't reach
	return false
end

local function UpdateTarget()
	assert(pLocal, "UpdateTarget: pLocal is nil")
	if not pLocal:IsValid() then
		return nil
	end

	local allPlayers = entities.FindByClass("CTFPlayer")
	if not allPlayers then
		return nil
	end

	local bestTargetDetails = nil
	local bestScore = -math.huge
	local maxAttackDistance = TF2.MELEE_HIT_RANGE -- Only target enemies within melee hit range
	local ignoreinvisible = (gui.GetValue("ignore cloaked"))

	for _, player in pairs(allPlayers) do
		-- Basic validity checks
		if not player or not player:IsValid() then
			goto continue
		end

		-- Check if player is valid target
		if not player:IsAlive() or player:IsDormant() then
			goto continue
		end

		-- Check team (not on our team)
		local playerTeam = player:GetTeamNumber()
		local localTeam = pLocal:GetTeamNumber()
		if not playerTeam or not localTeam or playerTeam == localTeam then
			goto continue
		end

		-- Cloaked player check
		if ignoreinvisible == 1 and player:InCond(TFCond_Cloaked) then
			goto continue
		end

		-- Get player position safely
		local playerPos = player:GetAbsOrigin()
		if not playerPos then
			goto continue
		end

		-- Calculate distance
		local distance = (pLocalPos - playerPos):Length()

		-- Skip if too far
		if distance >= maxAttackDistance then
			goto continue
		end

		-- Skip if we can't hit this enemy (world geometry blocks the path)
		if not CanHitEnemy(player, playerPos) then
			goto continue
		end

		-- Get view angles with nil check
		local viewAngles = player:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
		if not viewAngles then
			goto continue
		end

		-- Safe yaw extraction
		local viewYaw = 0
		local success, angles = pcall(function()
			return EulerAngles(viewAngles:Unpack())
		end)
		if success and angles and angles.yaw then
			viewYaw = angles.yaw
		else
			goto continue
		end

		-- Calculate back direction for scoring
		local backDir = Vector3(-1, 0, 0)
		local successBack, anglesBack = pcall(function()
			return EulerAngles(viewAngles:Unpack())
		end)
		if successBack and anglesBack then
			backDir = -anglesBack:Forward()
		end

		-- Calculate yaw difference from enemy's back (0 = perfect backstab angle, 180 = facing)
		local enemyBackYaw = math.deg(math.atan(backDir.y, backDir.x))
		local ourYawToEnemy = math.deg(math.atan(playerPos.y - pLocalPos.y, playerPos.x - pLocalPos.x))
		local yawDeltaFromBack = math.abs(NormalizeYaw(ourYawToEnemy - enemyBackYaw))

		-- SCORING: Higher = better target
		-- Distance score: closer = higher (max at 0, 0 at max range)
		local distanceScore = (1 - distance / maxAttackDistance) * 100 -- 0-100

		-- Angle score: smaller yaw delta from back = higher (180 = 0 score, 0 = 100 score)
		local angleScore = (1 - yawDeltaFromBack / 180) * 100 -- 0-100

		-- Combined score: 40% distance + 60% angle (prefer easier backstab over closer)
		local targetScore = distanceScore * 0.4 + angleScore * 0.6

		if targetScore > bestScore then
			bestScore = targetScore

			-- Get view offset with nil check
			local viewoffset = player:GetPropVector("localdata", "m_vecViewOffset[0]")
			if not viewoffset then
				goto continue
			end

			-- Get hitbox dimensions
			local mins, maxs = player:GetMins(), player:GetMaxs()
			if not mins or not maxs then
				goto continue
			end

			local hitboxRadius = maxs.x
			local hitboxHeight = maxs.z

			-- Get velocity safely
			local velocity = player:EstimateAbsVelocity()
			if not velocity then
				velocity = Vector3(0, 0, 0)
			end

			bestTargetDetails = {
				entity = player,
				Pos = playerPos,
				NextPos = playerPos + velocity * globals.TickInterval(),
				viewpos = playerPos + viewoffset,
				viewYaw = viewYaw,
				Back = backDir,
				hitboxRadius = hitboxRadius,
				hitboxHeight = hitboxHeight,
				mins = mins,
				maxs = maxs,
				score = targetScore, -- Store score for debug
			}
		end

		::continue::
	end

	return bestTargetDetails
end

local function CheckYawDelta(angle1, angle2)
	local difference = NormalizeYaw(angle1 - angle2)
	return (difference > 0 and difference < (TF2.BACKSTAB_ANGLE - 1))
		or (difference < 0 and difference > -(TF2.BACKSTAB_ANGLE - 1))
end

-- Check if target is in backstab range
local function IsInRange(targetPos, spherePos, sphereRadius)
	local hitbox_min = targetPos + HULL.MIN
	local hitbox_max = targetPos + HULL.MAX

	-- Find closest point on hitbox to sphere center
	local closestPoint = Vector3(
		math.max(hitbox_min.x, math.min(spherePos.x, hitbox_max.x)),
		math.max(hitbox_min.y, math.min(spherePos.y, hitbox_max.y)),
		math.max(hitbox_min.z, math.min(spherePos.z, hitbox_max.z))
	)

	-- Check if within sphere radius
	local distanceSquared = (spherePos - closestPoint):LengthSqr()
	if sphereRadius * sphereRadius > distanceSquared then
		-- Calculate direction for trace
		local dirVec = closestPoint - spherePos
		local dirLen = dirVec:Length()
		local direction = (dirLen > 0) and (dirVec / dirLen) or Vector3(1, 0, 0)
		local swingTraceEnd = spherePos + direction * sphereRadius

		if Menu.Advanced.AdvancedPred then
			local trace = engine.TraceLine(spherePos, swingTraceEnd, MASK_SHOT_HULL)
			if trace.entity == TargetPlayer.entity then
				return true, closestPoint
			else
				trace = engine.TraceHull(spherePos, swingTraceEnd, HULL.SWING_MIN, HULL.SWING_MAX, MASK_SHOT_HULL)
				return trace.entity == TargetPlayer.entity, closestPoint
			end
		end

		return true, closestPoint
	end

	return false, nil
end

-- Helper: check if entity is a teammate (blocks melee)
local function IsTeammate(ent)
	assert(pLocal, "IsTeammate: pLocal is nil")
	if not ent or not ent:IsValid() then
		return false
	end
	if ent:GetClass() ~= "CTFPlayer" then
		return false
	end
	if ent == pLocal then
		return true
	end -- Self is passthrough
	return ent:GetTeamNumber() == pLocal:GetTeamNumber()
end

-- Check if can attack from position (LOS + range)
local function CanAttackFromPos(testPoint)
	assert(TargetPlayer and TargetPlayer.Pos and TargetPlayer.entity, "CanAttackFromPos: TargetPlayer invalid")

	local viewPos = testPoint + pLocalViewOffset
	local targetPos = TargetPlayer.Pos

	-- Calculate closest point on target hitbox
	local hitbox_min = targetPos + HULL.MIN
	local hitbox_max = targetPos + HULL.MAX
	local closestPoint = Vector3(
		math.max(hitbox_min.x, math.min(viewPos.x, hitbox_max.x)),
		math.max(hitbox_min.y, math.min(viewPos.y, hitbox_max.y)),
		math.max(hitbox_min.z, math.min(viewPos.z, hitbox_max.z))
	)

	-- Check backstab range
	local distanceToHitbox = (viewPos - closestPoint):Length()
	if distanceToHitbox > TF2.BACKSTAB_RANGE then
		return false
	end

	-- Trace to target
	local dirToClosest = closestPoint - viewPos
	local dirLen = dirToClosest:Length()
	local direction = (dirLen > 0) and (dirToClosest / dirLen) or Vector3(1, 0, 0)
	local swingEnd = viewPos + direction * TF2.BACKSTAB_RANGE

	-- Line trace first
	local trace = engine.TraceLine(viewPos, swingEnd, MASK_SHOT_HULL)
	if trace.fraction < 1 then
		return trace.entity == TargetPlayer.entity
	end

	-- Hull trace for melee
	trace = engine.TraceHull(viewPos, swingEnd, HULL.SWING_MIN, HULL.SWING_MAX, MASK_SHOT_HULL)
	return trace.fraction == 1 or trace.entity == TargetPlayer.entity
end

local function CheckBackstab(testPoint)
	assert(
		TargetPlayer and TargetPlayer.viewpos and TargetPlayer.Back and TargetPlayer.Pos,
		"CheckBackstab: TargetPlayer invalid"
	)

	local viewPos = testPoint + pLocalViewOffset
	local enemyYaw = NormalizeYaw(PositionYaw(TargetPlayer.viewpos, TargetPlayer.viewpos + TargetPlayer.Back))
	local spyYaw = NormalizeYaw(PositionYaw(TargetPlayer.viewpos, viewPos))

	return CheckYawDelta(spyYaw, enemyYaw) and IsInRange(TargetPlayer.Pos, viewPos, TF2.BACKSTAB_RANGE)
end

-- Combined check: backstab possible AND attack path clear
local function CanBackstabFromPos(testPoint)
	assert(
		TargetPlayer and TargetPlayer.viewpos and TargetPlayer.Back and TargetPlayer.Pos,
		"CanBackstabFromPos: TargetPlayer invalid"
	)

	-- Check backstab geometry first (cheaper than LOS trace)
	local viewPos = testPoint + pLocalViewOffset
	local enemyYaw = NormalizeYaw(PositionYaw(TargetPlayer.viewpos, TargetPlayer.viewpos + TargetPlayer.Back))
	local spyYaw = NormalizeYaw(PositionYaw(TargetPlayer.viewpos, viewPos))

	if not (CheckYawDelta(spyYaw, enemyYaw) and IsInRange(TargetPlayer.Pos, viewPos, TF2.BACKSTAB_RANGE)) then
		return false
	end

	-- LOS check last (most expensive)
	return CanAttackFromPos(testPoint)
end

-- Handle forward collision with walls
local function HandleForwardCollision(vel, wallTrace)
	local normal = wallTrace.plane
	local angle = math.deg(math.acos(normal:Dot(Vector3(0, 0, 1))))

	-- Steep wall: reflect velocity
	if angle > TF2.FORWARD_COLLISION_ANGLE then
		local dot = vel:Dot(normal)
		vel = vel - normal * dot
	end

	return wallTrace.endpos.x, wallTrace.endpos.y
end

-- Handle ground collision
local function HandleGroundCollision(vel, groundTrace, vUp)
	local normal = groundTrace.plane
	local angle = math.deg(math.acos(normal:Dot(vUp)))
	local onGround = false

	if angle < TF2.GROUND_ANGLE_LOW then
		onGround = true
	elseif angle < TF2.GROUND_ANGLE_HIGH then
		vel.x, vel.y, vel.z = 0, 0, 0
	else
		local dot = vel:Dot(normal)
		vel = vel - normal * dot
		onGround = true
	end

	if onGround then
		vel.z = 0
	end
	return groundTrace.endpos, onGround
end

-- Simulation cache with defaults
local simulationCache = {
	tickInterval = globals.TickInterval(),
	gravity = SV_GRAVITY or 800,
	stepSize = 18, -- TF2 default
	flags = 0,
}

-- Update simulation cache from current game state
local function UpdateSimulationCache()
	simulationCache.tickInterval = globals.TickInterval()
	simulationCache.gravity = SV_GRAVITY or 800
	local step = pLocal and pLocal:GetPropFloat("localdata", "m_flStepSize")
	simulationCache.stepSize = (step and step > 0) and step or 18
	simulationCache.flags = pLocal and pLocal:GetPropInt("m_fFlags") or 0
end

local function shouldHitEntityFun(entity, player)
	if not entity then
		return false
	end

	-- Ignore dropped items early (cheap check)
	local entClass = entity:GetClass()
	if entClass == "CTFAmmoPack" or entClass == "CTFDroppedWeapon" then
		return false
	end

	-- Most common: player collision (check first for speed)
	if entity:IsPlayer() then
		-- Ignore self and teammates early
		if entity:GetIndex() == player:GetIndex() or entity:GetTeamNumber() == player:GetTeamNumber() then
			return false
		end
		-- Hit enemy players
		return true
	end

	-- World geometry (stairs, ramps, brushes)
	local pos = entity:GetAbsOrigin()
	if pos and engine.GetPointContents(pos + Vector3(0, 0, 1)) ~= 0 then
		return true
	end

	return true
end

-- Simulate warp in a specific direction
-- Uses current velocity and accelerates toward optimal direction
-- When standing still, assumes optimal input to show meaningful path
local function SimulateDash(targetDirection, ticks)
	assert(pLocal, "SimulateDash: pLocal is nil - UpdateLocalPlayerCache must be called first")
	local tick_interval = globals.TickInterval()
	local playerClass = pLocal:GetPropInt("m_iClass")
	local maxSpeed = CLASS_MAX_SPEEDS[playerClass] or 320

	-- Normalize the direction we want to warp toward
	local wishdir = Normalize(targetDirection)

	-- Get current velocity
	local currentVel = pLocal:EstimateAbsVelocity()
	local currentSpeed = math.sqrt(currentVel.x * currentVel.x + currentVel.y * currentVel.y)
	local lastP = pLocal:GetAbsOrigin() -- Initialize position

	-- When standing still or moving slowly, assume we'd immediately start moving in optimal direction
	-- This shows where we WOULD end up if we applied optimal input NOW
	local lastV
	if currentSpeed < 50 then
		-- Standing still / very slow - start with initial acceleration in wishdir
		-- Simulate as if we already applied 1 tick of acceleration
		local initialAccel = TF2.ACCELERATION * maxSpeed * tick_interval
		lastV = wishdir * initialAccel
	else
		-- Moving - use actual velocity
		lastV = Vector3(currentVel.x, currentVel.y, currentVel.z)
	end

	-- Set gravity and step size from cache
	local gravity = (simulationCache.gravity or 800) * tick_interval
	local stepSize = simulationCache.stepSize or 18
	local vUp = Vector3(0, 0, 1)
	local vStep = Vector3(0, 0, stepSize)

	-- Helper to determine if an entity should be hit
	local shouldHitEntity = function(entity)
		return shouldHitEntityFun(entity, pLocal)
	end

	-- Check ground state from flags
	local flags = simulationCache.flags
	local lastG = (flags & 1 == 1)

	-- Track the closest backstab opportunity
	local closestBackstabPos = nil
	local minWarpTicks = ticks + 1 -- Initialize to a high value outside of tick range

	-- LOCAL arrays for THIS simulation only (not global!)
	local simPositions = {}
	local simEndwarps = {}

	for i = 1, ticks do
		-- Apply friction first (ground movement)
		local vel = ApplyFriction(lastV, lastG)

		-- Accelerate toward max speed in desired direction
		if lastG then
			local currentSpeed = vel:Dot(wishdir)
			local addSpeed = maxSpeed - currentSpeed
			if addSpeed > 0 then
				local accelSpeed = math.min(TF2.ACCELERATION * maxSpeed * tick_interval, addSpeed)
				vel = vel + wishdir * accelSpeed
			end

			-- Cap speed to effective max
			local horizSpeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
			if horizSpeed > maxSpeed then
				local scale = maxSpeed / horizSpeed
				vel = Vector3(vel.x * scale, vel.y * scale, vel.z)
			end
		end

		-- Calculate the new position based on the velocity
		local pos = lastP + vel * tick_interval

		-- Collision and movement logic
		if Menu.Advanced.ColisionCheck then
			local wallTrace =
				engine.TraceHull(lastP + vStep, pos + vStep, HULL.MIN, HULL.MAX, MASK_PLAYERSOLID, shouldHitEntity)
			if wallTrace.fraction < 1 then
				if wallTrace.entity and wallTrace.entity:GetClass() == "CTFPlayer" then
					break
				end
				pos.x, pos.y = HandleForwardCollision(vel, wallTrace)
			end

			local downStep = onGround and vStep or Vector3(0, 0, 0)
			local groundTrace =
				engine.TraceHull(pos + vStep, pos - downStep, HULL.MIN, HULL.MAX, MASK_PLAYERSOLID, shouldHitEntity)
			if groundTrace.fraction < 1 then
				pos, onGround = HandleGroundCollision(vel, groundTrace, vUp)
			end
		end

		-- Apply gravity if not on the ground
		if not onGround then
			vel.z = vel.z - gravity
		end

		-- Store position first (cheaper than backstab check)
		simPositions[i] = pos

		-- Check for backstab possibility at the current position (with LOS check)
		local isBackstab = CanBackstabFromPos(pos)
		simEndwarps[i] = { pos, isBackstab, i } -- Include tick number for scoring

		-- Track EARLIEST backstab tick (for fallback)
		if isBackstab and i < minWarpTicks then
			minWarpTicks = i
			closestBackstabPos = pos
		end

		-- Update simulation state
		lastP, lastV, lastG = pos, vel, onGround
	end

	-- Return: final pos, min ticks (for info), LOCAL path arrays (includes ALL backstabs)
	-- Don't return single backstab pos - let caller score all of them
	return lastP, minWarpTicks, simPositions, simEndwarps, lastV -- Also return final velocity for bonus ticks
end

-- Simulate bonus ticks after main warp - each tick recalculates optimal wishdir
-- Uses same physics as main warp but with dynamic direction
local function SimulateBonusTicks(startPos, startVel, enemyPos, enemyBack, baseTick, myRadius, enemyRadius)
	if not Menu.Advanced.SmoothWarp then
		return {}, {}
	end
	assert(pLocal, "SimulateBonusTicks: pLocal is nil")

	local tick_interval = globals.TickInterval()
	local playerClass = pLocal:GetPropInt("m_iClass")
	local maxSpeed = CLASS_MAX_SPEEDS[playerClass] or 320

	local lastP = Vector3(startPos.x, startPos.y, startPos.z)
	local lastV = Vector3(startVel.x, startVel.y, startVel.z)
	local lastG = true -- Assume on ground

	local bonusPositions = {}
	local bonusEndwarps = {}

	-- Target: enemy back position
	local combinedRadius = myRadius + enemyRadius

	for i = 1, SMOOTH_WARP.BONUS_TICKS do
		-- 1. Calculate optimal wishdir toward enemy back from CURRENT position
		local targetPos = enemyPos + enemyBack * combinedRadius
		local toTarget = targetPos - lastP
		local toTargetLen = toTarget:Length()
		local wishdir = toTargetLen > 1 and (toTarget / toTargetLen) or Vector3(1, 0, 0)

		-- 2. Apply friction
		local vel = ApplyFriction(lastV, lastG)

		-- 3. Accelerate toward optimal wishdir (with sharp turn momentum cancellation)
		if lastG then
			local currentSpeed = vel:Dot(wishdir)
			local addSpeed = maxSpeed - currentSpeed
			if addSpeed > 0 then
				local accelSpeed = math.min(TF2.ACCELERATION * maxSpeed * tick_interval, addSpeed)
				vel = vel + wishdir * accelSpeed
			end

			-- Cap speed
			local horizSpeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
			if horizSpeed > maxSpeed then
				local scale = maxSpeed / horizSpeed
				vel = Vector3(vel.x * scale, vel.y * scale, vel.z)
			end
		end

		-- 4. Move position
		local pos = lastP + vel * tick_interval

		-- 5. Store and check backstab
		bonusPositions[i] = pos
		local isBackstab = CanBackstabFromPos(pos)
		bonusEndwarps[i] = { pos, isBackstab, baseTick + i } -- Tick number continues from main warp

		-- Update state
		lastP, lastV = pos, vel
	end

	return bonusPositions, bonusEndwarps
end

-- Corner positions for direction mapping (preserves existing logic)
local function GetDynamicCorners(cornerDistance)
	if not cornerDistance or cornerDistance <= 0 then
		cornerDistance = TF2.HITBOX_RADIUS * 2 -- Fallback to default
	end
	return {
		Vector3(-cornerDistance, cornerDistance, 0.0), -- top left
		Vector3(cornerDistance, cornerDistance, 0.0), -- top right
		Vector3(-cornerDistance, -cornerDistance, 0.0), -- bottom left
		Vector3(cornerDistance, -cornerDistance, 0.0), -- bottom right
	}
end

local center = Vector3(0, 0, 0)

-- Direction mapping for corner selection (preserves existing logic)
local function GetDirectionToCorners(corners)
	return {
		[-1] = {
			[-1] = { center, corners[4], corners[1] }, -- Top-left
			[0] = { center, corners[4], corners[2] }, -- Left
			[1] = { center, corners[3], corners[2] }, -- Top-left to bottom-right
		},
		[0] = {
			[-1] = { center, corners[2], corners[1] }, -- BACK: top corners
			[0] = { center }, -- Center
			[1] = { center, corners[3], corners[4] }, -- FRONT: bottom corners
		},
		[1] = {
			[-1] = { center, corners[2], corners[3] }, -- Top-right to bottom-left
			[0] = { center, corners[1], corners[3] }, -- Right
			[1] = { center, corners[1], corners[4] }, -- Bottom-right
		},
	}
end

local function determine_direction(my_pos, enemy_pos, hitbox_size, vertical_range)
	-- Assert inputs to prevent nil errors
	assert(my_pos and my_pos.x and my_pos.y and my_pos.z, "determine_direction: my_pos is invalid")
	assert(enemy_pos and enemy_pos.x and enemy_pos.y and enemy_pos.z, "determine_direction: enemy_pos is invalid")
	assert(hitbox_size and hitbox_size > 0, "determine_direction: hitbox_size is invalid")
	assert(vertical_range and vertical_range > 0, "determine_direction: vertical_range is invalid")

	local dx = enemy_pos.x - my_pos.x
	local dy = enemy_pos.y - my_pos.y
	local dz = enemy_pos.z - my_pos.z
	local buffor = 1

	local out_of_vertical_range = (math.abs(dz) > vertical_range) and 1 or 0

	local direction_x = ((dx > hitbox_size - buffor) and 1 or 0) - ((dx < -hitbox_size + buffor) and 1 or 0)
	local direction_y = ((dy > hitbox_size - buffor) and 1 or 0) - ((dy < -hitbox_size + buffor) and 1 or 0)

	local final_dir = { (direction_x * (1 - out_of_vertical_range)), (direction_y * (1 - out_of_vertical_range)) }
	return final_dir
end

local function get_best_corners_or_origin(my_pos, enemy_pos, hitbox_size, vertical_range)
	local direction = determine_direction(my_pos, enemy_pos, hitbox_size, vertical_range)
	local corners = GetDynamicCorners(hitbox_size)
	local directionMap = GetDirectionToCorners(corners)
	local bestcorners = directionMap[direction[1]] and directionMap[direction[1]][direction[2]]

	if not bestcorners then
		return { center }
	end

	return bestcorners
end

-- UNIFIED CORNER SELECTION: Returns sorted optimal corners (optimal, secondary, center)
local function GetOptimalBackstabCorners(my_pos, enemy_pos, hitbox_size, vertical_range)
	-- Assert inputs to prevent nil errors (zero-trust)
	assert(my_pos and my_pos.x and my_pos.y and my_pos.z, "GetOptimalBackstabCorners: my_pos is invalid")
	assert(enemy_pos and enemy_pos.x and enemy_pos.y and enemy_pos.z, "GetOptimalBackstabCorners: enemy_pos is invalid")

	-- Ensure hitbox_size is valid
	if not hitbox_size or hitbox_size <= 0 then
		hitbox_size = TF2.HITBOX_RADIUS
	end

	-- Ensure vertical_range is valid
	if not vertical_range or vertical_range <= 0 then
		vertical_range = TF2.HITBOX_HEIGHT
	end

	-- Get the 2 best corners from optimized lookup
	local all_positions = get_best_corners_or_origin(my_pos, enemy_pos, hitbox_size, vertical_range)

	-- Find optimal corner based on smallest yaw difference to enemy's back
	local optimalCorner = nil
	local secondaryCorner = nil
	local centerCorner = nil
	local bestYawDelta = math.huge
	local enemy_back_yaw = PositionYaw(enemy_pos, enemy_pos + TargetPlayer.Back)

	-- Sort corners: optimal (closest to back), secondary, center
	local sortedCorners = {}

	for _, pos in ipairs(all_positions) do
		if pos == center then
			centerCorner = pos
		else
			-- Calculate yaw delta relative to enemy's back
			local test_yaw = PositionYaw(enemy_pos, enemy_pos + pos)
			local yaw_diff = math.abs(NormalizeYaw(test_yaw - enemy_back_yaw))

			if yaw_diff < bestYawDelta then
				-- Previous optimal becomes secondary
				if optimalCorner then
					secondaryCorner = optimalCorner
				end
				bestYawDelta = yaw_diff
				optimalCorner = pos
			else
				-- This becomes secondary
				secondaryCorner = pos
			end
		end
	end

	-- Build sorted array: optimal, secondary, center (always last)
	if optimalCorner then
		table.insert(sortedCorners, optimalCorner)
	end
	if secondaryCorner then
		table.insert(sortedCorners, secondaryCorner)
	end
	if centerCorner then
		table.insert(sortedCorners, centerCorner)
	end

	return sortedCorners, optimalCorner, secondaryCorner, centerCorner
end

-- Scale corner vector to distance (preserves AABB shape)
local function ScaleCorner(corner, distance)
	return Vector3(
		corner.x ~= 0 and (corner.x > 0 and distance or -distance) or 0,
		corner.y ~= 0 and (corner.y > 0 and distance or -distance) or 0,
		0
	)
end

-- PASS 1: Project where we'd end up if we coast without input
-- Returns the optimal wishdir accounting for coasting AND recalculated best position
local function CalculateOptimalWishdir(
	startPos,
	startVel,
	offsetFromEnemy,
	enemyPos,
	ticks,
	maxSpeed,
	hitbox_size,
	vertical_range
)
	local tick_interval = globals.TickInterval()

	-- STEP 1: Get direction from START position to target
	-- Then extend target 450 units further so we don't stop at corner
	local baseTarget = enemyPos + offsetFromEnemy
	local dirFromStart = baseTarget - startPos
	local dirFromStartNorm = Normalize(dirFromStart)

	-- Extended target: target extension units past the corner in same direction
	local extendedTarget = baseTarget + dirFromStartNorm * TF2.TARGET_EXTENSION

	-- STEP 2: Simulate coasting WITHOUT input
	local pos = Vector3(startPos.x, startPos.y, startPos.z)
	local vel = Vector3(startVel.x, startVel.y, startVel.z)

	for i = 1, ticks do
		-- Just move with current velocity (no acceleration)
		pos = pos + vel * tick_interval

		-- Apply friction
		local speed = vel:Length()
		if speed > 0 then
			local drop = speed * TF2.GROUND_FRICTION * tick_interval
			local newspeed = math.max(speed - drop, 0)
			if speed > 0 then
				vel = vel * (newspeed / speed)
			end
		end
	end

	-- STEP 3: Direction from coasted position to EXTENDED target
	-- This ensures we keep full speed toward/past the corner
	local directionToTarget = extendedTarget - pos

	-- Always return normalized direction (full-length wishdir)
	return Normalize(directionToTarget)
end

local function CalculateTrickstab(cmd)
	assert(TargetPlayer and TargetPlayer.Pos, "CalculateTrickstab: TargetPlayer or TargetPlayer.Pos is nil")
	local my_pos = pLocalPos
	local enemy_pos = TargetPlayer.Pos

	-- Lag compensation: Predict enemy position ahead by half our ping
	-- This accounts for the time it takes for our warp to reach the server
	local netChan = clientstate.GetNetChannel()
	if netChan and TargetPlayer.entity then
		local latOut = netChan:GetLatency(0) -- FLOW_OUTGOING
		local latIn = netChan:GetLatency(1) -- FLOW_INCOMING
		local totalLatency = latOut + latIn
		local halfPing = totalLatency / 2 -- Time for server to receive our position

		-- Convert to ticks for simulation consistency
		local tick_interval = globals.TickInterval()
		local predictionTicks = math.floor(halfPing / tick_interval)
		local predictionTime = predictionTicks * tick_interval

		-- Predict where enemy will be when server processes our warp
		local enemyVelocity = TargetPlayer.entity:EstimateAbsVelocity()
		if enemyVelocity then
			enemy_pos = enemy_pos + enemyVelocity * predictionTime
		end
	end

	-- Get actual collision hulls from game (used in simulation)
	local myMins, myMaxs = pLocal:GetMins(), pLocal:GetMaxs()
	assert(myMins and myMaxs, "CalculateTrickstab: pLocal:GetMins()/GetMaxs() returned nil")
	local myRadius = (myMaxs and myMaxs.x) or TF2.HITBOX_RADIUS -- Player's actual collision radius
	local enemyMins = TargetPlayer.mins or HULL.MIN
	local enemyMaxs = TargetPlayer.maxs or HULL.MAX
	local enemyRadius = TargetPlayer.hitboxRadius or TF2.HITBOX_RADIUS

	-- Combined hitbox size (exact collision boundary, NO buffer)
	local combinedHitbox = myRadius + enemyRadius

	-- Direction detection uses EXACT combined hitbox (NO buffer)
	-- Buffer would cause "center" detection when actually on a side
	local hitbox_size = combinedHitbox or TF2.HITBOX_RADIUS
	local vertical_range = TargetPlayer.hitboxHeight or TF2.HITBOX_HEIGHT -- For vertical checks

	-- Ensure hitbox_size is valid
	if not hitbox_size or hitbox_size <= 0 then
		hitbox_size = TF2.HITBOX_RADIUS
	end
	local playerClass = pLocal:GetPropInt("m_iClass")
	assert(playerClass, "CalculateTrickstab: pLocal:GetPropInt('m_iClass') returned nil")
	local maxSpeed = (playerClass and CLASS_MAX_SPEEDS[playerClass]) or TF2.MAX_SPEED
	local currentVel = pLocal:EstimateAbsVelocity()
	-- Always simulate with at least WARP_READY_TICKS for visualization (even if not charged)
	local chargedTicks = warp.GetChargedTicks()
	local warpTicks = (chargedTicks and chargedTicks > 0) and chargedTicks or TF2.WARP_READY_TICKS

	-- Use UNIFIED corner selection algorithm (consistent across codebase)
	local sortedCorners, optimalCorner, secondaryCorner, centerCorner =
		GetOptimalBackstabCorners(my_pos, enemy_pos, hitbox_size, vertical_range)
	local dynamicCorners = GetDynamicCorners(hitbox_size)

	-- For debug classification - map the sorted positions to directions
	local cornerDirections = {}
	for i, pos in ipairs(sortedCorners) do
		if pos == center then
			cornerDirections[i] = "CENTER"
		elseif pos.y > 0 then
			cornerDirections[i] = "RIGHT"
		elseif pos.y < 0 then
			cornerDirections[i] = "LEFT"
		else
			cornerDirections[i] = "UNKNOWN"
		end
	end

	-- Calculate yaw differences for debug display (relative to enemy's back)
	local left_yaw_diff, right_yaw_diff, center_yaw_diff = math.huge, math.huge, math.huge
	local enemy_back_yaw = PositionYaw(enemy_pos, enemy_pos + TargetPlayer.Back)

	for _, pos in ipairs(sortedCorners) do
		local test_yaw = PositionYaw(enemy_pos, enemy_pos + pos)
		local yaw_diff = math.abs(NormalizeYaw(test_yaw - enemy_back_yaw))

		if pos.y > 0 then
			right_yaw_diff = math.min(right_yaw_diff, yaw_diff)
		elseif pos.y < 0 then
			left_yaw_diff = math.min(left_yaw_diff, yaw_diff)
		elseif pos == center then
			center_yaw_diff = yaw_diff
		end
	end

	-- Determine best side for debug
	local userSideMove = cmd:GetSideMove()

	local best_side
	if Menu.Advanced.ManualDirection and math.abs(userSideMove) >= TF2.MANUAL_THRESHOLD then
		best_side = (userSideMove > 0) and "left" or (userSideMove < 0) and "right"
	else
		best_side = (left_yaw_diff <= right_yaw_diff) and "left" or "right"
	end

	-- Use the unified corner selection results
	local optimalSidePos = optimalCorner
	local optimalSideIndex = 1 -- Always first in sorted array
	local otherSidePos = secondaryCorner
	local otherSideIndex = 2 -- Always second in sorted array

	-- MANUAL DIRECTION OVERRIDE: Force optimal corner to match manual direction
	if Menu.Advanced.ManualDirection and math.abs(userSideMove) >= TF2.MANUAL_THRESHOLD then
		local manualSide = (userSideMove > 0) and "left" or (userSideMove < 0) and "right"

		-- Find which corner matches the manual direction
		local manualCorner = nil
		local otherCorner = nil

		for i, pos in ipairs(sortedCorners) do
			if pos ~= center then
				local cornerDir = cornerDirections[i] or "UNKNOWN"
				if cornerDir:upper() == manualSide:upper() then
					manualCorner = pos
					manualCornerIndex = i
				else
					otherCorner = pos
					otherCornerIndex = i
				end
			end
		end

		-- Override optimal side to be the manual direction corner
		if manualCorner then
			optimalSidePos = manualCorner
			optimalSideIndex = manualCornerIndex
			otherSidePos = otherCorner
			otherSideIndex = otherCornerIndex
			print("DEBUG: Manual direction override -", manualSide, "corner forced as optimal")
		end
	end

	-- Initialize best_positions table
	local best_positions = {}

	-- Calculate player's direction indices relative to enemy (-1, 0, 1)
	local dx = enemy_pos.x - my_pos.x
	local dy = enemy_pos.y - my_pos.y
	local dz = enemy_pos.z - my_pos.z
	local buffer = 5

	local out_of_vertical_range = (math.abs(dz) > vertical_range) and 1 or 0

	local direction_x = ((dx > hitbox_size - buffer) and 1 or 0) - ((dx < -hitbox_size + buffer) and 1 or 0)
	local direction_y = ((dy > hitbox_size - buffer) and 1 or 0) - ((dy < -hitbox_size + buffer) and 1 or 0)

	-- Store for debug visualization (using unified sorted corners)
	debugCornerData = {
		corners = dynamicCorners,
		allPositions = sortedCorners, -- Use sorted corners from unified function
		cornerDirections = cornerDirections,
		optimalIndex = optimalSideIndex, -- Updated by manual direction override
		otherIndex = otherSideIndex, -- Updated by manual direction override
		bestSide = best_side,
		leftYaw = left_yaw_diff,
		rightYaw = right_yaw_diff,
		playerDirX = direction_x, -- -1, 0, or 1
		playerDirY = direction_y, -- -1, 0, or 1
		outOfVertRange = out_of_vertical_range,
	}

	-- DEBUG: Update debug data after manual direction override
	if Menu.Advanced.ManualDirection and math.abs(userSideMove) >= TF2.MANUAL_THRESHOLD then
		debugCornerData.optimalIndex = optimalSideIndex
		debugCornerData.otherIndex = otherSideIndex
		print("DEBUG: Updated debugCornerData - optimalIndex:", optimalSideIndex, "otherIndex:", otherSideIndex)
	end

	-- Fallback if no optimal side found (should not happen with unified function)
	if not optimalSidePos then
		optimalSidePos = secondaryCorner or centerCorner or center
	end

	-- ALWAYS add positions in sorted order from unified function
	-- Position 1: Optimal corner (for green line)
	if optimalSidePos then
		table.insert(best_positions, optimalSidePos)
	else
		print("ERROR: No optimal side position found!")
	end

	-- Position 2: Secondary corner (for blue line) - if available
	if secondaryCorner and secondaryCorner ~= optimalSidePos then
		table.insert(best_positions, secondaryCorner)
	end

	-- Position 3: Center/back (always last for cyan line)
	if centerCorner then
		table.insert(best_positions, centerCorner)
	end

	-- Track the optimal backstab position based on scoring
	local optimalBackstabPos = nil
	local bestScore = -1
	local minWarpTicks = math.huge
	local allPaths = {} -- Store ALL simulation paths for visualization
	local allEndwarps = {} -- Store ALL endwarp data
	local allHitWall = {} -- Track which paths hit walls (for red visualization)
	local bestDirection = nil
	local totalBackstabPoints = 0 -- Count total backstab positions found

	-- Simulate paths using UNIFIED corner order (optimal, secondary, center)
	local simulationTargets = {}

	-- Add corners in unified sorted order (consistent with debug visualization)
	if optimalCorner then
		table.insert(simulationTargets, { name = "optimal_side", offset = optimalCorner }) -- Position 1: Green
	end
	if secondaryCorner then
		table.insert(simulationTargets, { name = "secondary_side", offset = secondaryCorner }) -- Position 2: Blue
	end
	if centerCorner and (withinBackAngle or isStairstab) then
		table.insert(simulationTargets, { name = "center", offset = centerCorner }) -- Position 3: Yellow (only if valid)
	end

	-- Track if manual direction was forced
	local manualDirectionForced = Menu.Advanced.ManualDirection and math.abs(userSideMove) >= TF2.MANUAL_THRESHOLD

	-- Calculate if we're within back angle (needed for manual direction logic)
	local withinBackAngle = false
	if TargetPlayer and TargetPlayer.Back and enemy_pos and my_pos then
		local enemyBackYaw = NormalizeYaw(PositionYaw(enemy_pos, enemy_pos + TargetPlayer.Back))
		local ourYawToEnemy = NormalizeYaw(PositionYaw(enemy_pos, my_pos))
		local ourYawDeltaFromBack = math.abs(NormalizeYaw(ourYawToEnemy - enemyBackYaw))
		withinBackAngle = ourYawDeltaFromBack <= 90 -- Within 90 degrees of back
	end

	-- Helper to simulate a single path and check wall hit (uses hull trace for walkability)
	local function SimulatePath(simTarget)
		local optimalWishdir = CalculateOptimalWishdir(
			my_pos,
			currentVel,
			simTarget.offset,
			enemy_pos,
			warpTicks,
			maxSpeed,
			hitbox_size,
			vertical_range
		)
		assert(optimalWishdir, "SimulatePath: CalculateOptimalWishdir returned nil")
		local targetDirection = optimalWishdir * 100
		local final_pos, minTicks, simPath, simEndwarps, finalVel = SimulateDash(targetDirection, warpTicks)
		assert(
			final_pos and minTicks and simPath and simEndwarps and finalVel,
			"SimulatePath: SimulateDash returned invalid data"
		)

		-- Simulate bonus ticks after main warp (each with optimal wishdir)
		local bonusPath, bonusEndwarps = SimulateBonusTicks(
			final_pos,
			finalVel or Vector3(0, 0, 0),
			enemy_pos,
			TargetPlayer.Back,
			warpTicks, -- baseTick for bonus tick numbering
			myRadius,
			enemyRadius
		)
		assert(bonusPath and bonusEndwarps, "SimulatePath: SimulateBonusTicks returned invalid data")

		-- Append bonus positions and endwarps to main path
		for i, pos in ipairs(bonusPath) do
			simPath[#simPath + 1] = pos
		end
		for i, ew in ipairs(bonusEndwarps) do
			simEndwarps[#simEndwarps + 1] = ew
		end

		-- Simple wall check: hull trace from start to end of path
		local hitWall = false
		if simPath and #simPath > 0 then
			local lastPos = simPath[#simPath]
			local traceStart = my_pos + Vector3(0, 0, 18)
			local traceEnd = lastPos + Vector3(0, 0, 18)
			local wallTrace = engine.TraceHull(traceStart, traceEnd, HULL.MIN, HULL.MAX, MASK_PLAYERSOLID_BRUSHONLY)

			-- Hit something that's NOT an enemy = wall
			if wallTrace.fraction < 0.8 then
				if not (wallTrace.entity and wallTrace.entity:IsPlayer()) then
					hitWall = true
				end
			end
		end

		return simPath, simEndwarps, optimalWishdir, hitWall
	end

	-- Helper to score endwarps and update best backstab position
	local function ScoreEndwarps(simEndwarps, targetDirection)
		if not simEndwarps then
			return
		end
		for tick, warpData in ipairs(simEndwarps) do
			local backstab_pos = warpData[1]
			local isBackstab = warpData[2]
			local tickNum = warpData[3] or tick

			if isBackstab and backstab_pos then
				totalBackstabPoints = totalBackstabPoints + 1

				local spyYaw = PositionYaw(enemy_pos, backstab_pos)
				local enemyYaw = TargetPlayer.viewYaw
				local isWithinBackstabYaw = CheckYawDelta(spyYaw, enemyYaw)

				if isWithinBackstabYaw then
					local yawDiff = math.abs(NormalizeYaw(spyYaw - enemyYaw))
					local yawComponent = math.max(0, 1 - yawDiff / TF2.BACKSTAB_ANGLE)
					local distance = (backstab_pos - enemy_pos):Length()
					local distanceComponent = math.max(0, 1 - distance / TF2.MAX_SCORE_DISTANCE)
					local score = TF2.YAW_WEIGHT * yawComponent + TF2.DISTANCE_WEIGHT * distanceComponent

					if score > bestScore or (score == bestScore and tickNum < minWarpTicks) then
						bestScore = score
						optimalBackstabPos = backstab_pos
						minWarpTicks = tickNum
						bestDirection = targetDirection
					end
				end
			end
		end
	end

	-- STAIRSTAB: Only simulate center path (skip left/right entirely)
	if isStairstab then
		-- Add center as the only target
		table.insert(simulationTargets, { name = "center", offset = center })

		-- Simulate the center path
		local centerPath, centerEndwarps, centerWishdir, centerHitWall = SimulatePath(simulationTargets[1])
		assert(
			centerPath and centerEndwarps and centerWishdir and centerHitWall ~= nil,
			"CalculateTrickstab: SimulatePath(center) returned invalid data"
		)
		table.insert(allPaths, centerPath)
		table.insert(allEndwarps, centerEndwarps)
		table.insert(allHitWall, centerHitWall)
		ScoreEndwarps(centerEndwarps, centerWishdir * 100)
	elseif manualDirectionForced then
		-- MANUAL DIRECTION: Only simulate forced direction + center (if within backstab angle)
		-- Don't question the manual decision - just do 1 sim
		if optimalSidePos then
			table.insert(simulationTargets, { name = "manual_side", offset = optimalSidePos })
		end

		-- Simulate the manual side
		local manualPath, manualEndwarps, manualWishdir, manualHitWall
		if #simulationTargets > 0 then
			manualPath, manualEndwarps, manualWishdir, manualHitWall = SimulatePath(simulationTargets[1])
			assert(
				manualPath and manualEndwarps and manualWishdir and manualHitWall ~= nil,
				"CalculateTrickstab: SimulatePath(manual) returned invalid data"
			)
			table.insert(allPaths, manualPath)
			table.insert(allEndwarps, manualEndwarps)
			table.insert(allHitWall, manualHitWall)
			ScoreEndwarps(manualEndwarps, manualWishdir * 100)

			-- MANUAL DIRECTION OVERRIDE: Force bestDirection to manual path
			-- Don't let optimal scoring override manual decision
			if manualWishdir then
				bestDirection = manualWishdir * 100
				assert(
					bestDirection and bestDirection.x ~= nil,
					"CalculateTrickstab: manual bestDirection override failed"
				)
			end
		end

		-- Add center ONLY if within backstab angle (physically able to backstab)
		if withinBackAngle then
			table.insert(simulationTargets, { name = "center", offset = center })
			local centerPath, centerEndwarps, centerWishdir, centerHitWall =
				SimulatePath(simulationTargets[#simulationTargets])
			assert(
				centerPath and centerEndwarps and centerWishdir and centerHitWall ~= nil,
				"CalculateTrickstab: SimulatePath(center2) returned invalid data"
			)
			table.insert(allPaths, centerPath)
			table.insert(allEndwarps, centerEndwarps)
			table.insert(allHitWall, centerHitWall)
			ScoreEndwarps(centerEndwarps, centerWishdir * 100)
		end
	else
		-- AUTO MODE: Simulate optimal side first, only try other if it hits a WORLD wall
		local optimalPath, optimalEndwarps, optimalWishdir, optimalHitWall
		local optimalFoundStabPoints = false

		-- Path 1: Optimal side
		if optimalSidePos then
			table.insert(simulationTargets, { name = "optimal_side", offset = optimalSidePos })
			optimalPath, optimalEndwarps, optimalWishdir, optimalHitWall = SimulatePath(simulationTargets[1])
			assert(
				optimalPath and optimalEndwarps and optimalWishdir and optimalHitWall ~= nil,
				"CalculateTrickstab: SimulatePath(optimal) returned invalid data"
			)
			table.insert(allPaths, optimalPath)
			table.insert(allEndwarps, optimalEndwarps)
			table.insert(allHitWall, optimalHitWall)

			-- Check if we found any stab points on optimal path
			local stabPointsBefore = totalBackstabPoints
			ScoreEndwarps(optimalEndwarps, optimalWishdir * 100)
			optimalFoundStabPoints = totalBackstabPoints > stabPointsBefore
		end

		-- Path 2: Other side - if optimal hit wall AND didn't find stab points
		-- This becomes the new "best" direction
		if otherSidePos and optimalHitWall and not optimalFoundStabPoints then
			table.insert(simulationTargets, { name = "other_side", offset = otherSidePos })
			local otherPath, otherEndwarps, otherWishdir, otherHitWall =
				SimulatePath(simulationTargets[#simulationTargets])
			assert(
				otherPath and otherEndwarps and otherWishdir and otherHitWall ~= nil,
				"CalculateTrickstab: SimulatePath(other) returned invalid data"
			)
			table.insert(allPaths, otherPath)
			table.insert(allEndwarps, otherEndwarps)
			table.insert(allHitWall, otherHitWall)
			ScoreEndwarps(otherEndwarps, otherWishdir * 100)
		end

		-- Path 3: Center/back - ONLY if within BACKSTAB angle (physically able to backstab)
		if withinBackAngle then
			table.insert(simulationTargets, { name = "center", offset = center })
			local centerPath, centerEndwarps, centerWishdir, centerHitWall =
				SimulatePath(simulationTargets[#simulationTargets])
			assert(
				centerPath and centerEndwarps and centerWishdir and centerHitWall ~= nil,
				"CalculateTrickstab: SimulatePath(center3) returned invalid data"
			)
			table.insert(allPaths, centerPath)
			table.insert(allEndwarps, centerEndwarps)
			table.insert(allHitWall, centerHitWall)
			ScoreEndwarps(centerEndwarps, centerWishdir * 100)
		end
	end

	-- Set global visualization data to show ALL paths (not just best one)
	positions = allPaths
	endwarps = allEndwarps
	pathHitWall = allHitWall

	-- Extract bonus tick positions from best path for separate visualization (magenta)
	-- Bonus ticks are already simulated and appended in SimulatePath
	smoothWarpPositions = {}
	if Menu.Advanced.SmoothWarp and #allPaths > 0 then
		local bestPath = allPaths[1] -- First path is optimal
		if bestPath and #bestPath > warpTicks then
			-- Last 3 positions are the bonus ticks
			for i = 1, SMOOTH_WARP.BONUS_TICKS do
				local idx = warpTicks + i
				if idx <= #bestPath then
					smoothWarpPositions[i] = bestPath[idx]
				end
			end
		end
	end

	-- ALWAYS calculate bestDirection to optimal corner (needed for MoveAssistance without stab points)
	if not bestDirection then
		-- Assert required data exists
		assert(enemy_pos and enemy_pos.x, "CalculateTrickstab: enemy_pos is invalid")
		assert(my_pos and my_pos.x, "CalculateTrickstab: my_pos is invalid")

		if optimalSidePos and not manualDirectionForced then
			assert(optimalSidePos.x ~= nil, "CalculateTrickstab: optimalSidePos is invalid")

			-- Direction from player to optimal corner position
			local targetPos = enemy_pos + optimalSidePos
			local dirToTarget = targetPos - my_pos

			-- Normalize and extend 48 units (combined hitbox size)
			if dirToTarget:Length() > 0 then
				bestDirection = Normalize(dirToTarget) * 48
			else
				bestDirection = dirToTarget
			end

			assert(bestDirection and bestDirection.x ~= nil, "CalculateTrickstab: bestDirection calculation failed")
		elseif isStairstab then
			assert(TargetPlayer.Back and TargetPlayer.Back.x ~= nil, "CalculateTrickstab: TargetPlayer.Back is invalid")

			-- Stairstab: fallback to center/back direction
			bestDirection = enemy_pos + TargetPlayer.Back * (myRadius + enemyRadius) - my_pos

			assert(bestDirection and bestDirection.x ~= nil, "CalculateTrickstab: stairstab bestDirection failed")
		end
	end

	-- Final assertion: bestDirection must be valid for AutoWalk
	assert(
		bestDirection == nil or (bestDirection.x ~= nil and bestDirection.y ~= nil),
		"CalculateTrickstab: final bestDirection is corrupt"
	)

	-- Debug: Path count validation
	-- if #allPaths ~= 2 then
	-- 	print("WARNING: Expected 2 paths, got " .. #allPaths)
	-- end

	-- Ensure all return values are valid (never nil)
	local finalPos = optimalBackstabPos or emptyVec
	local finalScore = bestScore or 0
	local finalTicks = minWarpTicks or TF2.WARP_READY_TICKS
	local finalDirection = bestDirection or Vector3(0, 0, 0)
	local finalPoints = totalBackstabPoints or 0

	return finalPos, finalScore, finalTicks, finalDirection, finalPoints
end

-- Recharge state tracking
local warpExecutedTick = 0
local warpConfirmed = false -- Kill or hurt confirmed
local lastAttackedTarget = nil
local LastWarpTime = 0 -- Last time warp was executed

-- Get max server ticks for smooth warp (forward declaration for damageLogger)
local function GetSmoothWarpMaxTicks()
	local sv_max = client.GetConVar("sv_maxusrcmdprocessticks")
	if sv_max and sv_max > 0 then
		return sv_max
	end
	return 24
end

local function damageLogger(event)
	local eventName = event:GetName()

	if eventName == "player_death" then
		local localPlayer = entities.GetLocalPlayer()
		if not localPlayer then
			return
		end

		local attacker = entities.GetByUserID(event:GetInt("attacker"))
		local victim = entities.GetByUserID(event:GetInt("userid"))

		-- We got a kill - allow recharge for both main warp and smooth warp
		if attacker and attacker:IsValid() and localPlayer:GetIndex() == attacker:GetIndex() then
			warpConfirmed = true
			lastAttackedTarget = nil
			-- Also recharge smooth warp to max
			smoothWarpTicks = GetSmoothWarpMaxTicks()
		end
	elseif eventName == "player_hurt" then
		local localPlayer = entities.GetLocalPlayer()
		if not localPlayer then
			return
		end

		local attacker = entities.GetByUserID(event:GetInt("attacker"))

		-- We hurt someone - allow recharge for both main warp and smooth warp
		if attacker and attacker:IsValid() and localPlayer:GetIndex() == attacker:GetIndex() then
			warpConfirmed = true
			-- Also recharge smooth warp to max
			smoothWarpTicks = GetSmoothWarpMaxTicks()
		end
	end
end

--[[ Custom Blink Module - One-shot juke on direction change ]]
-- Blink = appear to stand still for 21 ticks while actually moving
-- Resets fresh on each direction change (stops old blink, starts new)
local BLINK_DURATION = 21 -- Ticks to appear stationary (21 is server limit)
local blinkTicksRemaining = 0 -- Countdown from 21 to 0
local blinkShooting = false
local blinkStartPos = nil -- Position where blink started (where enemy sees us)

-- Texture for circle drawing
local blinkTexture = draw.CreateTextureRGBA(
	string.char(0xff, 0xff, 0xff, 255, 0xff, 0xff, 0xff, 255, 0xff, 0xff, 0xff, 255, 0xff, 0xff, 0xff, 255),
	2,
	2
)

-- Generate circle vertices for world-space ground circle
local function GenerateGroundCircleVertices(centerPos, radius, numSegments)
	local vertices = {}
	numSegments = numSegments or 16
	local angleStep = (2 * math.pi) / numSegments

	for i = 0, numSegments do
		local theta = i * angleStep
		-- Circle on XY plane at ground level (Z = centerPos.z)
		local worldX = centerPos.x + radius * math.cos(theta)
		local worldY = centerPos.y + radius * math.sin(theta)
		local worldZ = centerPos.z

		-- Convert to screen space
		local screenPos = client.WorldToScreen(Vector3(worldX, worldY, worldZ))
		if screenPos then
			table.insert(vertices, { math.floor(screenPos[1]), math.floor(screenPos[2]), 0, 0 })
		end
	end

	return vertices
end

-- Reset blink to fresh 21 ticks (called on direction change)
local function TriggerBlink()
	if Menu.Main.AutoBlink then
		blinkTicksRemaining = BLINK_DURATION -- Fresh blink
		-- Store current position as where enemy sees us
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() then
			local pos = pLocal:GetAbsOrigin()
			blinkStartPos = pos and Vector3(pos.x, pos.y, pos.z) or nil
		end
	end
end

-- Custom blink using m_flAnimTime (hides position from enemy)
local function UpdateBlink(cmd)
	if not Menu.Main.AutoBlink then
		blinkTicksRemaining = 0
		blinkStartPos = nil
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		blinkTicksRemaining = 0
		blinkStartPos = nil
		return
	end

	-- Check if we're shooting this tick
	blinkShooting = (cmd:GetButtons() & IN_ATTACK) ~= 0

	-- Blink active if we have ticks remaining
	if blinkTicksRemaining > 0 then
		-- Manipulate AnimTime to hide position (appear to stand still)
		pLocal:SetPropFloat(globals.CurTime() + 1, "m_flAnimTime")

		-- Choke packet if not shooting
		if not blinkShooting then
			cmd.sendpacket = false
			blinkTicksRemaining = blinkTicksRemaining - 1
		else
			-- Shooting ends blink early (need to send attack)
			blinkTicksRemaining = 0
			blinkStartPos = nil
		end
	else
		-- Blink ended, clear position
		blinkStartPos = nil
	end
end

-- Check if blink is active
local function IsBlinkActive()
	return blinkTicksRemaining > 0 and blinkStartPos ~= nil
end

-- Get blink start position (where enemy sees us)
local function GetBlinkPosition()
	return blinkStartPos
end

--[[ Smooth Warp Integration - Extends main warp with bonus ticks ]]

-- Create CLC_Move packet with specified command count
local function CreateSmoothWarpPacket(numCommands)
	numCommands = numCommands or 2
	local buffer = BitBuffer()
	buffer:WriteInt(numCommands, SMOOTH_WARP.NEW_COMMANDS_SIZE)
	buffer:WriteInt(1, SMOOTH_WARP.BACKUP_COMMANDS_SIZE) -- 1 backup for safety
	buffer:Reset()
	return buffer
end

-- Simulate 1 tick of coasting (no input) from position
local function SimulateCoasting(fromPos, velocity)
	if not fromPos or not velocity then
		return fromPos
	end

	local tickInterval = globals.TickInterval() or (1 / 66)
	local gravity = SV_GRAVITY or 800

	-- Simple physics: pos += vel * dt, vel.z -= gravity * dt (if airborne)
	local newVel = Vector3(velocity.x, velocity.y, velocity.z - gravity * tickInterval)
	local newPos = fromPos + velocity * tickInterval

	-- Ground check (simple)
	local groundTrace =
		engine.TraceHull(fromPos + Vector3(0, 0, 1), newPos, HULL.MIN, HULL.MAX, MASK_PLAYERSOLID_BRUSHONLY)
	if groundTrace.fraction < 1.0 then
		newPos = groundTrace.endpos
	end

	return newPos, newVel
end

-- Calculate direction from coasting position to destination
local function GetSmoothWarpDirection(currentPos, currentVel, destination)
	-- First simulate 1 tick of coasting
	local coastPos = SimulateCoasting(currentPos, currentVel)
	if not coastPos or not destination then
		return nil
	end

	-- Direction from coasting position to destination
	local dir = destination - coastPos
	local len = dir:Length()
	if len < 1 then
		return nil
	end

	return dir
end

-- Check if we can use smooth warp (not choking, have ticks)
local function CanSmoothWarp()
	local choked = clientstate.GetChokedCommands()
	return choked == 0 and smoothWarpTicks > 0
end

-- Recharge smooth warp ticks passively
local function RechargeSmoothWarp()
	local maxTicks = GetSmoothWarpMaxTicks()
	local tickCount = globals.TickCount()

	-- Passive recharge when standing still or slowly (every few ticks)
	if tickCount > lastSmoothWarpRecharge + 3 then
		if smoothWarpTicks < maxTicks then
			smoothWarpTicks = smoothWarpTicks + 1
			lastSmoothWarpRecharge = tickCount
		end
	end
end

-- Check if backstab angle is close (within threshold)
local function IsBackstabAngleClose(angleDiff)
	return angleDiff and angleDiff <= SMOOTH_WARP.ASSIST_ANGLE_THRESHOLD
end

-- Track remaining bonus ticks to send (1 per packet to avoid kick)
local smoothWarpBonusRemaining = 0

-- Handle smooth warp packet modification (called from SendNetMsg)
-- IMPORTANT: Server kicks on 4th extra command in a row, so we send 1 extra per packet (2 total)
local function HandleSmoothWarpPacket(msg)
	if msg:GetType() ~= SMOOTH_WARP.CLC_MOVE_TYPE then
		return
	end

	-- Check if we can modify (not choking)
	local choked = clientstate.GetChokedCommands()
	if choked > 0 then
		return
	end

	-- Bonus warp after main warp - send 1 extra tick per packet (2 commands)
	-- This fires over 3 consecutive packets to get all 3 bonus ticks
	if smoothWarpBonusRemaining > 0 and smoothWarpTicks > 0 then
		-- Update movement direction for this bonus tick based on current position
		if smoothWarpDirection and TargetPlayer and TargetPlayer.Pos and pLocal then
			local currentPos = pLocal:GetAbsOrigin()
			local currentVel = pLocal:EstimateAbsVelocity()
			local enemyPos = TargetPlayer.Pos
			local enemyBack = TargetPlayer.Back

			if currentPos and currentVel and enemyPos and enemyBack then
				-- Calculate optimal wishdir for THIS tick (dynamic)
				local toTarget = enemyPos + enemyBack * TF2.BACKSTAB_RANGE - currentPos
				local toTargetLen = toTarget:Length()
				if toTargetLen > 1 then
					smoothWarpDirection = toTarget / toTargetLen
				end
			end
		end

		local buffer = CreateSmoothWarpPacket(2) -- 2 commands = 1 extra tick (safe)
		msg:ReadFromBitBuffer(buffer)
		buffer:Delete()
		smoothWarpTicks = smoothWarpTicks - 1
		smoothWarpBonusRemaining = smoothWarpBonusRemaining - 1
		if smoothWarpBonusRemaining <= 0 then
			smoothWarpBonusActive = false
		end
		return
	end

	-- Movement assist smooth warp (1 tick at a time)
	if smoothWarpActive and smoothWarpTicks > SMOOTH_WARP.RESERVE_TICKS then
		-- Update movement direction for this tick based on current position
		if smoothWarpDestination and TargetPlayer and TargetPlayer.Pos and pLocal then
			local currentPos = pLocal:GetAbsOrigin()
			local currentVel = pLocal:EstimateAbsVelocity()

			if currentPos and currentVel and smoothWarpDestination then
				-- Calculate optimal wishdir for THIS tick (dynamic)
				local toTarget = smoothWarpDestination - currentPos
				local toTargetLen = toTarget:Length()
				if toTargetLen > 1 then
					smoothWarpDirection = toTarget / toTargetLen
				end
			end
		end

		local buffer = CreateSmoothWarpPacket(2) -- 2 commands = 1 extra tick
		msg:ReadFromBitBuffer(buffer)
		buffer:Delete()
		smoothWarpTicks = smoothWarpTicks - 1
		return
	end
end

-- Activate smooth warp bonus ticks after main warp (uses available ticks, capped at 3)
local function ActivateSmoothWarpBonus(destination, direction)
	if not Menu.Advanced.SmoothWarp then
		return
	end
	-- Use available smooth warp ticks, but cap at 3 (max we can send without kick)
	local availableTicks = math.min(smoothWarpTicks, SMOOTH_WARP.BONUS_TICKS)
	if availableTicks > 0 then
		smoothWarpBonusActive = true
		smoothWarpBonusRemaining = availableTicks -- Use actual available ticks
		smoothWarpDestination = destination
		smoothWarpDirection = direction
	end
end

-- Activate smooth warp for movement assist (when close to backstab)
local function ActivateSmoothWarpAssist(destination)
	-- Only if enabled and we have ticks beyond reserve
	if not Menu.Advanced.SmoothWarp then
		return
	end
	if smoothWarpTicks > SMOOTH_WARP.RESERVE_TICKS then
		smoothWarpActive = true
		smoothWarpDestination = destination
	else
		smoothWarpActive = false
	end
end

-- Deactivate smooth warp assist
local function DeactivateSmoothWarpAssist()
	smoothWarpActive = false
	smoothWarpDestination = nil
end

-- Function to handle controlled warp using pre-calculated optimal direction
-- IMPORTANT: Warp copies our current movement inputs and repeats them for entire warp duration
-- We CANNOT control the player during warp - only set inputs BEFORE triggering warp
-- This simulates "time compression" - same physics applied rapidly
local function PerformControlledWarp(cmd, optimalDirection, warpTicks)
	-- Use the direction that was already calculated and tested in simulation
	-- DO NOT recalculate - that would invalidate the simulation results!

	-- CRITICAL: Set movement input FIRST before configuring warp
	WalkInDirection(cmd, optimalDirection)

	-- Configure warp ticks
	client.RemoveConVarProtection("sv_maxusrcmdprocessticks")
	client.SetConVar("sv_maxusrcmdprocessticks", warpTicks, true)

	-- Execute the warp - inputs from cmd are now locked and will repeat
	-- The input we just set with WalkInDirection will be used
	warp.TriggerWarp()

	-- Track warp time for auto recharge cooldown
	LastWarpTime = globals.RealTime() or 0

	-- Reset
	client.SetConVar("sv_maxusrcmdprocessticks", 24, true)
end

-- On kill recharge - instant recharge on successful kill
local function OnKillRecharge(event)
	if not Menu.Advanced.AutoRecharge then
		return
	end
	if event:GetName() ~= "player_death" then
		return
	end

	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer then
		return
	end

	local attackerIdx = event:GetInt("attacker")
	local victimIdx = event:GetInt("userid")

	-- Check if we are the attacker
	local attackerEntity = entities.GetByUserID(attackerIdx)
	if attackerEntity and attackerEntity:GetIndex() == localPlayer:GetIndex() then
		-- We got a kill - instant recharge for main warp and smooth warp
		warp.TriggerCharge()
		LastWarpTime = 0
		smoothWarpTicks = GetSmoothWarpMaxTicks()
	end
end

-- Modified AutoWarp to use minWarpTicks from CalculateTrickstab
local function AutoWarp(cmd, hasUserInput)
	assert(pLocal, "AutoWarp: pLocal is nil - UpdateLocalPlayerCache must be called first")
	local playerClass = pLocal:GetPropInt("m_iClass")

	-- Calculate the optimal backstab position and direction
	local bestDirection
	local totalBackstabPoints
	BackstabPos, bestScore, minWarpTicks, bestDirection, totalBackstabPoints = CalculateTrickstab(cmd)
	assert(
		BackstabPos and bestScore and minWarpTicks and bestDirection and totalBackstabPoints,
		"AutoWarp: CalculateTrickstab returned invalid data"
	)

	-- NOTE: Angle snap is the ONLY functional method currently.
	-- We cannot override cmd packets during warp ticks - if user holds forward we can't change it.
	-- Non-angle-snap mode is broken until lbox fixes cmd override during warp.

	-- Direction to walk - use bestDirection from simulation (already calculated correctly)
	local dir = bestDirection
	-- bestDirection should always be valid if simulation found backstab points
	-- No fallback needed - simulation handles direction calculation

	-- Rate limit direction changes (max 10 times/sec = every 11 ticks)
	local currentTickCount = globals.TickCount()
	if dir then
		local dirChanged = false
		if lastDirection then
			-- Check if direction changed significantly (>45 degrees)
			local lastLen = lastDirection:Length()
			local curLen = dir:Length()
			if lastLen > 0 and curLen > 0 then
				local dot = lastDirection:Dot(dir) / (lastLen * curLen)
				dirChanged = dot < 0.7 -- ~45 degree change
			end
		else
			dirChanged = true -- First direction
		end

		if dirChanged then
			-- Check cooldown
			if currentTickCount - lastDirectionChangeTick < DIRECTION_CHANGE_COOLDOWN then
				-- Can't change yet - use last direction
				if lastDirection then
					dir = lastDirection
				end
			else
				-- Allow change and update tracking
				lastDirectionChangeTick = currentTickCount
				lastDirection = Vector3(dir.x, dir.y, dir.z) -- Copy

				-- Trigger blink on direction change to confuse enemy anti-aim
				if Menu.Advanced.FakelagOnDirectionChange then
					TriggerBlink()
				end
			end
		end
	end
	-- Fallback: walk to LEFT or RIGHT side (NOT center/back when in front!)
	if not dir and TargetPlayer and TargetPlayer.Pos and TargetPlayer.Back then
		local enemy_pos = TargetPlayer.Pos
		local my_pos = pLocalPos

		-- Manual direction blink trigger (runs regardless of position)
		local userSideMove = cmd:GetSideMove()
		local forcedSide = nil
		if Menu.Advanced.ManualDirection and math.abs(userSideMove) >= TF2.MANUAL_THRESHOLD then
			forcedSide = (userSideMove > 0) and "right" or "left"

			-- Trigger blink when manual direction changes
			if forcedSide ~= lastManualSide then
				lastManualSide = forcedSide
				if Menu.Advanced.FakelagOnDirectionChange then
					TriggerBlink()
				end
			end
		else
			lastManualSide = nil -- Reset when not using manual
		end

		-- Check if we're within back angle (only then go center)
		local enemyBackYaw = NormalizeYaw(PositionYaw(enemy_pos, enemy_pos + TargetPlayer.Back))
		local ourYawToEnemy = NormalizeYaw(PositionYaw(enemy_pos, my_pos))
		local ourYawDeltaFromBack = math.abs(NormalizeYaw(ourYawToEnemy - enemyBackYaw))
		local withinBackAngle = ourYawDeltaFromBack <= 90 -- Within 90 degrees of back

		local myMins, myMaxs = pLocal:GetMins(), pLocal:GetMaxs()
		local myRadius = myMaxs and myMaxs.x or 24
		local enemyRadius = TargetPlayer.hitboxRadius or TF2.HITBOX_RADIUS
		local combinedHitbox = myRadius + enemyRadius

		if withinBackAngle then
			-- Behind enemy - go toward back (center)
			local backDir = Normalize(TargetPlayer.Back)
			local targetPos = enemy_pos + backDir * (combinedHitbox + 10)
			dir = targetPos - my_pos
		else
			-- In front/side - go LEFT or RIGHT
			local toEnemy = Normalize(enemy_pos - my_pos)
			local leftDir = Vector3(-toEnemy.y, toEnemy.x, 0)
			local rightDir = Vector3(toEnemy.y, -toEnemy.x, 0)
			local backDir = Normalize(TargetPlayer.Back)

			-- Pick primary side: manual override > better alignment to back
			local primarySide, alternateSide
			if forcedSide then
				primarySide = (forcedSide == "right") and rightDir or leftDir
				alternateSide = (forcedSide == "right") and leftDir or rightDir
			else
				-- Auto: pick side closer to enemy's back
				local leftDot = leftDir:Dot(backDir)
				local rightDot = rightDir:Dot(backDir)
				if rightDot >= leftDot then
					primarySide, alternateSide = rightDir, leftDir
				else
					primarySide, alternateSide = leftDir, rightDir
				end
			end

			-- Check if primary direction hits a wall (short trace)
			local testDist = combinedHitbox + 50
			local testEnd = my_pos + primarySide * testDist
			local wallTrace = engine.TraceLine(my_pos, testEnd, MASK_PLAYERSOLID_BRUSHONLY)

			local sideDir
			if wallTrace.fraction < 0.5 then
				-- Primary blocked, use alternate
				sideDir = alternateSide
			else
				sideDir = primarySide
			end

			-- Blend: 70% side + 30% toward enemy
			dir = Normalize(sideDir * 0.7 + toEnemy * 0.3)
		end
	end

	-- Check if we can CURRENTLY backstab
	local canCurrentlyBackstab = CanBackstabFromPos(pLocalPos)

	-- Backstab point tracking
	local backstabPointCount = totalBackstabPoints or 0
	local hasStabPoints = backstabPointCount > 0
	local minPointsThreshold = Menu.Advanced.MinBackstabPoints or TF2.MIN_BACKSTAB_POINTS
	local hasEnoughBackstabPoints = backstabPointCount >= minPointsThreshold

	-- Check if warp is ready
	local warpReady = warp.CanWarp() and warp.GetChargedTicks() >= TF2.WARP_READY_TICKS and not warp.IsWarping()
	local warpWouldBackstab = BackstabPos ~= emptyVec and CanBackstabFromPos(BackstabPos)

	-- AutoWalk: walks if MoveAssistance enabled (no stab point requirement) OR AutoWalk with stab points
	local autoWalkActive = (Menu.Main.MoveAsistance or (Menu.Main.AutoWalk and hasStabPoints))
		and not canCurrentlyBackstab

	-- Pure AutoWalk mode (for angle snap - excludes MoveAssistance)
	local isAutoWalkMode = Menu.Main.AutoWalk and hasStabPoints and not canCurrentlyBackstab

	-- Check for manual direction input (bypasses angle snap user input requirement)
	local userSideMove = cmd:GetSideMove()
	local hasManualDirection = Menu.Advanced.ManualDirection and math.abs(userSideMove) >= TF2.MANUAL_THRESHOLD

	-- DEBUG: Print manual direction status (always print to see what's happening)
	print(
		string.format(
			"DEBUG MANUAL: ManualDirection=%s, userSideMove=%.2f, threshold=%.2f, hasManualDirection=%s",
			tostring(Menu.Advanced.ManualDirection),
			userSideMove,
			TF2.MANUAL_THRESHOLD,
			tostring(hasManualDirection)
		)
	)

	-- Skip walking when angle snap enabled but no user input (still simulate for visuals)
	-- Manual direction counts as user input and bypasses this restriction
	local canWalk = not Menu.Advanced.UseAngleSnap or hasUserInput or hasManualDirection

	-- Calculate how close we are to backstab angle (for smooth warp assist)
	local backstabAngleDiff = nil
	if TargetPlayer and TargetPlayer.Back and pLocalPos then
		local enemyPos = TargetPlayer.Pos
		local enemyBack = TargetPlayer.Back
		if enemyPos and enemyBack then
			-- Calculate angle between our position relative to enemy and their back direction
			local toUs = pLocalPos - enemyPos
			local toUsLen = toUs:Length()
			local backLen = enemyBack:Length()
			if toUsLen > 0 and backLen > 0 then
				local dot = toUs:Dot(enemyBack) / (toUsLen * backLen)
				backstabAngleDiff = math.deg(math.acos(math.max(-1, math.min(1, dot))))
			end
		end
	end

	-- Check if we're close to backstab angle (within threshold)
	local closeToBackstab = backstabAngleDiff and backstabAngleDiff <= SMOOTH_WARP.ASSIST_ANGLE_THRESHOLD

	-- Check distance to target for HelperSprint
	local distanceToTarget = nil
	if TargetPlayer and TargetPlayer.Pos and pLocalPos then
		distanceToTarget = (TargetPlayer.Pos - pLocalPos):Length()
	end
	local withinBackstabRange = distanceToTarget and distanceToTarget <= TF2.BACKSTAB_RANGE

	-- Passive smooth warp recharge
	RechargeSmoothWarp()

	-- Calculate smooth warp target: use BackstabPos if valid, otherwise enemy back
	local smoothWarpTarget = BackstabPos
	if
		(not smoothWarpTarget or smoothWarpTarget == emptyVec)
		and TargetPlayer
		and TargetPlayer.Pos
		and TargetPlayer.Back
	then
		-- Fallback to enemy back position
		smoothWarpTarget = TargetPlayer.Pos + TargetPlayer.Back * TF2.BACKSTAB_RANGE
	end

	-- HelperSprint: Sprint + smooth warp when close to backstab (within 10 deg, 66 units)
	local helperSprintActive = false
	if Menu.Advanced.HelperSprint and closeToBackstab and withinBackstabRange and not canCurrentlyBackstab then
		-- Enable sprint
		local buttons = cmd:GetButtons()
		cmd:SetButtons(buttons | IN_SPEED)
		helperSprintActive = true

		-- Use smooth warp to close the gap faster
		if smoothWarpTarget and smoothWarpTarget ~= emptyVec then
			ActivateSmoothWarpAssist(smoothWarpTarget)
		end
	end

	-- AutoWalk: walks toward optimal corner (angle snap + warp only if enough stab points)
	if autoWalkActive and bestDirection and canWalk then
		-- Snap view angles ONLY in pure AutoWalk mode (excludes MoveAssistance)
		if Menu.Advanced.UseAngleSnap and isAutoWalkMode and BackstabPos ~= emptyVec then
			local lookAngles = PositionAngles(pLocalPos, BackstabPos)
			if lookAngles then
				cmd:SetViewAngles(lookAngles.pitch, lookAngles.yaw, 0)
				engine.SetViewAngles(EulerAngles(lookAngles.pitch, lookAngles.yaw, 0))
			end
		end

		-- Walk toward the optimal direction (angle snap only when AutoWalk is active)
		WalkInDirection(cmd, bestDirection, not (Menu.Advanced.UseAngleSnap and autoWalkActive))

		-- Use smooth warp to speed up when close to backstab angle
		if closeToBackstab and smoothWarpTarget and smoothWarpTarget ~= emptyVec then
			ActivateSmoothWarpAssist(smoothWarpTarget)
		else
			DeactivateSmoothWarpAssist()
		end
	end

	-- PRIORITY 2: Auto Warp - Only warp when ENOUGH points to pick best position
	if
		Menu.Main.AutoWarp
		and warpWouldBackstab
		and warpReady
		and not canCurrentlyBackstab
		and hasEnoughBackstabPoints
		and bestDirection
	then
		PerformControlledWarp(cmd, bestDirection, minWarpTicks)
		return
	end

	-- Blink is triggered by direction change, no need for legacy fakelag here
end

local Latency = 0
local lerp = 0
-- Main function to control the create move process and use AutoWarp and SimulateAttack effectively
local function OnCreateMove(cmd)
	-- ALWAYS clear visuals at start of EVERY tick (before any early returns)
	positions = {}
	endwarps = {}
	pathHitWall = {}
	smoothWarpPositions = {} -- Clear smooth warp bonus positions

	if not Menu.Main.Active then
		return
	end

	-- Check activation mode (Always, On Hold, On Release, Toggle, On Click)
	if not ShouldActivateTrickstab() then
		return
	end

	-- Track if user has movement input (for angle snap mode)
	local fwd = cmd:GetForwardMove()
	local side = cmd:GetSideMove()
	local hasUserInput = (fwd ~= 0 or side ~= 0)

	-- Use NetChannel for latency (not deprecated)
	local netChan = clientstate.GetNetChannel()
	if netChan then
		local latOut = netChan:GetLatency(0) -- FLOW_OUTGOING = 0
		local latIn = netChan:GetLatency(1) -- FLOW_INCOMING = 1
		local latency = latOut + latIn
		lerp = (CL_INTERP + latency) or 0
		Latency = Conversion.Time_to_Ticks(latency + lerp)
	else
		Latency = 0
	end

	-- Track when warp was executed
	if warp.IsWarping() and warpExecutedTick == 0 then
		warpExecutedTick = globals.TickCount()
		warpConfirmed = false
	end

	-- Auto recharge logic: Recharge when kill/hurt confirmed or ping-based cooldown after warp
	if
		Menu.Advanced.AutoRecharge
		and not warp.IsWarping()
		and warp.GetChargedTicks() < TF2.AUTO_RECHARGE_THRESHOLD
		and not warp.CanWarp()
	then
		local shouldRecharge = false

		-- Check 1: Got kill/hurt confirmation (immediate recharge)
		if warpConfirmed then
			shouldRecharge = true
		end

		-- Check 2: Ping-based cooldown after warp (latency + buffer in ticks)
		if warpExecutedTick > 0 then
			local currentTick = globals.TickCount()
			local ticksSinceWarp = currentTick - warpExecutedTick
			-- Use latency-based cooldown: Latency in ticks + buffer
			local pingCooldown = math.max(TF2.MIN_PING_COOLDOWN, (Latency or 0) + TF2.PING_BUFFER_TICKS)
			if ticksSinceWarp >= pingCooldown then
				shouldRecharge = true
			end
		end

		-- Trigger recharge and reset state
		if shouldRecharge then
			warp.TriggerCharge()
			warpExecutedTick = 0
			warpConfirmed = false
		end
	end

	if UpdateLocalPlayerCache() == false or not pLocal then
		return
	end

	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	if not pWeapon then
		return
	end
	if pLocal:InCond(4) then
		return
	end
	if not IsReadyToAttack(cmd, pWeapon) then
		return
	end

	TargetPlayer = UpdateTarget()
	-- UpdateTarget returns nil when no valid target found (valid case)
	if not TargetPlayer or not TargetPlayer.entity then
		-- No valid target - update cache for next tick
		positions = {}
		endwarps = {}
		UpdateSimulationCache()
		-- Blink auto-ends when ticks run out, no need to disable
	else
		-- Valid target - run trickstab logic
		UpdateSimulationCache() -- Keep cache fresh

		-- Calculate optimal direction first (needed for both AutoWalk and MoveAssistance)
		local bestDirection = nil
		local totalBackstabPoints = 0
		BackstabPos, bestScore, minWarpTicks, bestDirection, totalBackstabPoints = CalculateTrickstab(cmd)

		-- Now run AutoWarp with the calculated direction
		AutoWarp(cmd, hasUserInput)

		-- Check if main warp just finished (ticks = 0) and activate smooth warp immediately
		if not warp.IsWarping() and warpExecutedTick > 0 and not smoothWarpBonusActive then
			local currentChargedTicks = warp.GetChargedTicks()
			if currentChargedTicks == 0 and BackstabPos and BackstabPos ~= emptyVec then
				-- Main warp just finished - activate smooth warp extension immediately
				-- Use the same bestDirection from simulation for consistency
				local optimalDirection = bestDirection
				if optimalDirection and optimalDirection:Length() > 0 then
					optimalDirection = optimalDirection:Normalize()
				else
					-- Fallback: calculate direction to backstab position
					optimalDirection = BackstabPos - pLocalPos
					if optimalDirection:Length() > 0 then
						optimalDirection = optimalDirection:Normalize()
					end
				end
				ActivateSmoothWarpBonus(BackstabPos, optimalDirection)
			end
		end
	end

	-- Smooth warp movement: apply optimal direction for bonus/assist ticks
	if smoothWarpDirection and (smoothWarpBonusActive or smoothWarpActive) then
		-- Apply movement in the smooth warp direction (same logic as WalkInDirection)
		local dx = smoothWarpDirection.x
		local dy = smoothWarpDirection.y

		-- Calculate target yaw from direction vector
		local targetYaw = (math.atan(dy, dx) + MATH.TWO_PI) % MATH.TWO_PI

		-- Get current view yaw from cmd (not engine - for smooth warp we need cmd angles)
		local _, currentYaw = cmd:GetViewAngles()
		currentYaw = currentYaw * MATH.DEG_TO_RAD

		-- Calculate angle difference
		local yawDiff = (targetYaw - currentYaw + math.pi) % MATH.TWO_PI - math.pi

		-- Calculate movement input
		local forward = math.cos(yawDiff) * TF2.MAX_CMD_SPEED
		local side = math.sin(-yawDiff) * TF2.MAX_CMD_SPEED

		cmd:SetForwardMove(forward)
		cmd:SetSideMove(side)
	end

	-- Update custom blink (m_flAnimTime manipulation)
	UpdateBlink(cmd)
end

local consolas = draw.CreateFont("Consolas", 17, 500)
local current_fps = 0
local function doDraw()
	draw.SetFont(consolas)
	draw.Color(255, 255, 255, 255)
	pLocal = entities.GetLocalPlayer()

	-- Update FPS every 100 frames
	if globals.FrameCount() % 100 == 0 then
		current_fps = math.floor(1 / globals.FrameTime())
	end

	-- Draw fading ground circle where enemy sees us during blink
	if IsBlinkActive() then
		local blinkPos = GetBlinkPosition()
		if blinkPos then
			-- Calculate alpha based on remaining ticks (fades as blink ends)
			local alpha = math.floor((blinkTicksRemaining / BLINK_DURATION) * 255)
			alpha = math.max(50, math.min(255, alpha)) -- Clamp between 50-255

			-- 24 unit diameter = 12 unit radius
			local radius = 12
			local vertices = GenerateGroundCircleVertices(blinkPos, radius, 16)

			-- Only draw if we have enough vertices for a polygon
			if #vertices >= 3 then
				draw.Color(255, 255, 255, alpha)
				draw.TexturedPolygon(blinkTexture, vertices, true)
			end
		end
	end

	if Menu.Visuals.Active and TargetPlayer and TargetPlayer.Pos then
		-- DEBUG: Draw corner selection visualization (only if debug enabled)
		if Menu.Visuals.DebugCorners and debugCornerData and debugCornerData.allPositions then
			local enemy_pos = TargetPlayer.Pos
			for i, pos in ipairs(debugCornerData.allPositions) do
				local cornerPos = enemy_pos + pos
				local screenPos = client.WorldToScreen(cornerPos)
				if screenPos then
					local direction = debugCornerData.cornerDirections[i] or "?"

					-- Color by corner selection (as requested)
					if i == debugCornerData.optimalIndex then
						draw.Color(0, 255, 0, 255) -- Green for optimal corner
					elseif i == debugCornerData.otherIndex then
						draw.Color(0, 0, 255, 200) -- Blue for other corner
					elseif direction == "CENTER" then
						draw.Color(255, 255, 0, 200) -- Yellow for center
					else
						draw.Color(0, 0, 0, 200) -- Black for other corners
					end

					-- Draw corner marker (larger)
					local sx, sy = math.floor(screenPos[1]), math.floor(screenPos[2])
					draw.FilledRect(sx - 5, sy - 5, sx + 5, sy + 5)

					-- Draw corner index and direction with background for visibility
					draw.SetFont(consolas)

					-- Index number in large text
					draw.Color(0, 0, 0, 200) -- Black background
					draw.FilledRect(sx + 8, sy - 15, sx + 35, sy + 5)
					draw.Color(255, 255, 255, 255) -- White text
					draw.Text(sx + 10, sy - 12, "IDX:" .. tostring(i))

					-- Direction label
					draw.Color(0, 0, 0, 200) -- Black background
					draw.FilledRect(sx + 8, sy + 5, sx + 65, sy + 20)

					-- Color text by direction for clarity
					if direction == "LEFT" then
						draw.Color(100, 150, 255, 255)
					elseif direction == "RIGHT" then
						draw.Color(255, 150, 100, 255)
					elseif direction == "CENTER" then
						draw.Color(255, 255, 0, 255)
					else
						draw.Color(255, 255, 255, 255)
					end
					draw.Text(sx + 10, sy + 8, direction)

					-- Show X,Y coordinates for debugging direction mapping
					draw.Color(0, 0, 0, 200) -- Black background
					draw.FilledRect(sx + 8, sy + 22, sx + 90, sy + 37)
					draw.Color(255, 255, 255, 255) -- White text
					draw.Text(sx + 10, sy + 25, string.format("X:%.0f Y:%.0f", pos.x, pos.y))
				end
			end

			-- Draw best side and player direction text
			draw.SetFont(consolas)
			draw.Color(255, 255, 0, 255)
			draw.Text(
				10,
				150,
				string.format(
					"Best Side: %s (L:%.1f R:%.1f)",
					debugCornerData.bestSide,
					debugCornerData.leftYaw,
					debugCornerData.rightYaw
				)
			)

			-- Draw player direction indices relative to enemy
			draw.Color(0, 255, 255, 255) -- Cyan
			draw.Text(
				10,
				165,
				string.format(
					"Player Dir: [%d, %d] (VertRange: %d)",
					debugCornerData.playerDirX or 0,
					debugCornerData.playerDirY or 0,
					debugCornerData.outOfVertRange or 0
				)
			)

			-- Draw movement direction line under player's feet
			if pLocal and smoothWarpDirection then
				local localPos = pLocal:GetAbsOrigin()
				if localPos then
					-- Start position (under feet)
					local startPos = localPos + Vector3(0, 0, 5)
					-- End position (direction line)
					local endPos = startPos + smoothWarpDirection * 100

					local startScreen = client.WorldToScreen(startPos)
					local endScreen = client.WorldToScreen(endPos)

					if startScreen and endScreen then
						-- Purple line for movement direction
						draw.Color(255, 0, 255, 255)
						draw.Line(
							math.floor(startScreen[1]),
							math.floor(startScreen[2]),
							math.floor(endScreen[1]),
							math.floor(endScreen[2])
						)

						-- Arrow at the end
						draw.Color(255, 0, 255, 255)
						draw.FilledRect(
							math.floor(endScreen[1]) - 3,
							math.floor(endScreen[2]) - 3,
							math.floor(endScreen[1]) + 3,
							math.floor(endScreen[2]) + 3
						)
					end
				end
			end
		end

		-- Draw red square around final backstab position
		if BackstabPos and BackstabPos ~= emptyVec then
			local screenPos = client.WorldToScreen(BackstabPos)
			if screenPos then
				local sx, sy = math.floor(screenPos[1]), math.floor(screenPos[2])
				draw.Color(255, 0, 0, 255) -- Red
				draw.OutlinedRect(sx - 8, sy - 8, sx + 8, sy + 8)
				draw.OutlinedRect(sx - 9, sy - 9, sx + 9, sy + 9) -- Thicker outline
			end
		end

		-- Visualize ALL Warp Simulation Paths with gradient lines
		-- Each path is drawn SEPARATELY to avoid connecting them
		if Menu.Visuals.VisualizePoints and positions then
			for pathIdx, path in ipairs(positions) do
				-- Skip invalid paths
				if not path or type(path) ~= "table" or #path < 2 then
					goto continue_path
				end

				-- Check if this path hit a wall (RED = failed, others = normal colors)
				local hitWall = pathHitWall and pathHitWall[pathIdx]

				-- Path colors: RED if hit wall, otherwise: Path 1 = Green, Path 2 = Orange, Path 3 = Cyan
				local baseR, baseG, baseB
				if hitWall then
					baseR, baseG, baseB = 255, 0, 0 -- RED for failed paths (hit wall)
				elseif pathIdx == 1 then
					baseR, baseG, baseB = 0, 255, 0 -- Green for optimal side
				elseif pathIdx == 2 then
					baseR, baseG, baseB = 255, 150, 0 -- Orange for other side
				else
					baseR, baseG, baseB = 0, 200, 255 -- Cyan for center
				end

				-- Draw gradient lines ONLY within THIS path (not connecting to other paths)
				for i = 1, #path - 1 do
					local point = path[i]
					local nextPoint = path[i + 1]

					-- Validate points
					if not point or not nextPoint then
						goto continue_segment
					end

					local screenPos = client.WorldToScreen(Vector3(point.x, point.y, point.z))
					local nextScreenPos = client.WorldToScreen(Vector3(nextPoint.x, nextPoint.y, nextPoint.z))

					if screenPos and nextScreenPos then
						-- Gradient alpha: fade out toward end of path
						local alpha = math.floor(255 * (1 - i / #path))
						draw.Color(baseR, baseG, baseB, math.max(alpha, 100))
						-- Ensure integer coordinates
						draw.Line(
							math.floor(screenPos[1]),
							math.floor(screenPos[2]),
							math.floor(nextScreenPos[1]),
							math.floor(nextScreenPos[2])
						)
					end

					::continue_segment::
				end

				::continue_path::
			end
		end

		-- Visualize smooth warp bonus positions (3 extra ticks in MAGENTA)
		-- These show direction change at end of warp toward backstab position
		if Menu.Visuals.VisualizePoints and smoothWarpPositions and #smoothWarpPositions > 0 then
			-- Get end of best path to connect from
			local startPos = nil
			if positions and positions[1] and #positions[1] > 0 then
				startPos = positions[1][#positions[1]]
			end

			-- Draw magenta lines for smooth warp bonus ticks
			local prevPos = startPos
			for i, pos in ipairs(smoothWarpPositions) do
				if prevPos and pos then
					local prevScreen = client.WorldToScreen(Vector3(prevPos.x, prevPos.y, prevPos.z))
					local curScreen = client.WorldToScreen(Vector3(pos.x, pos.y, pos.z))

					if prevScreen and curScreen then
						-- Magenta color for smooth warp bonus (255, 0, 255)
						draw.Color(255, 0, 255, 200)
						draw.Line(
							math.floor(prevScreen[1]),
							math.floor(prevScreen[2]),
							math.floor(curScreen[1]),
							math.floor(curScreen[2])
						)
					end

					-- Draw small magenta dot at each bonus tick position
					local curDot = client.WorldToScreen(Vector3(pos.x, pos.y, pos.z))
					if curDot then
						local dx, dy = math.floor(curDot[1]), math.floor(curDot[2])
						draw.Color(255, 0, 255, 255)
						draw.FilledRect(dx - 3, dy - 3, dx + 3, dy + 3)
					end
				end
				prevPos = pos
			end
		end

		-- Visualize backstab points ONLY (red dots where we CAN backstab)
		if Menu.Visuals.VisualizeStabPoint and endwarps then
			for pathIdx, warpDataArray in ipairs(endwarps) do
				if not warpDataArray then
					goto continue_stab
				end

				for tick, warpData in ipairs(warpDataArray) do
					local pos, isBackstab = warpData[1], warpData[2]

					-- ONLY draw if this is a backstab position
					if isBackstab then
						local screenPos = client.WorldToScreen(Vector3(pos.x, pos.y, pos.z))
						if screenPos then
							-- Red square for backstab points
							local sx = math.floor(screenPos[1])
							local sy = math.floor(screenPos[2])
							draw.Color(255, 0, 0, 255)
							draw.FilledRect(sx - 4, sy - 4, sx + 4, sy + 4)
							-- White outline
							draw.Color(255, 255, 255, 255)
							draw.OutlinedRect(sx - 4, sy - 4, sx + 4, sy + 4)
						end
					end
				end

				::continue_stab::
			end
		end

		-- Draw GREEN marker at the OPTIMAL backstab position (best score)
		if Menu.Visuals.VisualizeStabPoint and BackstabPos and BackstabPos ~= emptyVec then
			local screenPos = client.WorldToScreen(Vector3(BackstabPos.x, BackstabPos.y, BackstabPos.z))
			if screenPos then
				-- Green circle for optimal stab point
				draw.Color(0, 255, 0, 255)
				for i = 0, 360, 30 do
					local rad = math.rad(i)
					local nextRad = math.rad(i + 30)
					local x1 = math.floor(screenPos[1] + math.cos(rad) * TF2.HITBOX_RADIUS / 3)
					local y1 = math.floor(screenPos[2] + math.sin(rad) * TF2.HITBOX_RADIUS / 3)
					local x2 = math.floor(screenPos[1] + math.cos(nextRad) * TF2.HITBOX_RADIUS / 3)
					local y2 = math.floor(screenPos[2] + math.sin(nextRad) * TF2.HITBOX_RADIUS / 3)
					draw.Line(x1, y1, x2, y2)
				end
				-- Center dot
				local cx = math.floor(screenPos[1])
				local cy = math.floor(screenPos[2])
				draw.FilledRect(cx - 2, cy - 2, cx + 2, cy + 2)
			end
		end

		-- Visualize Attack Circle based on activation state
		if Menu.Visuals.Attack_Circle and pLocal then
			local shouldShowCircle = false

			-- Determine if circle should be shown based on activation mode
			if Menu.Main.ActivationMode == 0 then
				-- Always mode: always show
				shouldShowCircle = true
			elseif Menu.Main.ActivationMode == 1 then
				-- On Hold: show while holding
				shouldShowCircle = Menu.Main.Keybind ~= KEY_NONE and input.IsButtonDown(Menu.Main.Keybind)
			elseif Menu.Main.ActivationMode == 2 then
				-- On Release: show when not holding
				shouldShowCircle = TargetPlayer ~= nil -- Only show when in range
			elseif Menu.Main.ActivationMode == 3 then
				-- Toggle: show when toggled on
				shouldShowCircle = toggleActive
			elseif Menu.Main.ActivationMode == 4 then
				-- On Click: show when clicked
				shouldShowCircle = Menu.Main.Keybind ~= KEY_NONE and input.IsButtonDown(Menu.Main.Keybind)
			end

			if shouldShowCircle then
				local centerPOS = pLocal:GetAbsOrigin() -- Center of the circle at the player's feet
				local viewPos = pLocalViewPos -- View position to shoot traces from
				local radius = TF2.ATTACK_RANGE - 5 -- Slightly less than attack range
				local segments = 32 -- Number of segments to draw the circle
				local angleStep = MATH.TWO_PI / segments

				-- Set the drawing color based on TargetPlayer's presence
				local circleColor = TargetPlayer and { 0, 255, 0, 255 } or { 255, 255, 255, 255 } -- Green if TargetPlayer exists, otherwise white
				draw.Color(table.unpack(circleColor))

				local vertices = {} -- Table to store adjusted vertices

				-- Calculate vertices and adjust based on trace results
				for i = 1, segments do
					local angle = angleStep * i
					local circlePoint = centerPOS + Vector3(math.cos(angle), math.sin(angle), 0) * radius
					local trace = engine.TraceLine(viewPos, circlePoint, MASK_SHOT_HULL)
					local endPoint = trace.fraction < 1.0 and trace.endpos or circlePoint
					vertices[i] = client.WorldToScreen(endPoint)
				end

				-- Draw the circle using adjusted vertices
				for i = 1, segments do
					local j = (i % segments) + 1 -- Wrap around to the first vertex after the last one
					if vertices[i] and vertices[j] then
						draw.Line(vertices[i][1], vertices[i][2], vertices[j][1], vertices[j][2])
					end
				end
			end
		end

		-- Visualize Forward Line for backstab direction
		if Menu.Visuals.BackLine and TargetPlayer then
			local Back = TargetPlayer.Back
			local hitboxPos = TargetPlayer.viewpos

			-- Calculate end point of the line in the backward direction
			local lineLength = TF2.HITBOX_RADIUS * 2 -- Length based on player size
			local endPoint = hitboxPos + (Back * lineLength) -- Move in the backward direction

			-- Convert 3D points to screen space
			local screenStart = client.WorldToScreen(hitboxPos)
			local screenEnd = client.WorldToScreen(endPoint)

			-- Draw the backstab line
			if screenStart and screenEnd then
				draw.Color(0, 255, 255, 255) -- Cyan color for the backstab line
				draw.Line(screenStart[1], screenStart[2], screenEnd[1], screenEnd[2])
			end
		end
	end

	-----------------------------------------------------------------------------------------------------
	--Menu
	if TimMenu and TimMenu.Begin("Auto Trickstab", gui.IsMenuOpen()) then
		local tabs = { "Main", "Advanced", "Visuals" }
		Menu.currentTab = TimMenu.TabControl("tabs", tabs, Menu.currentTab)
		TimMenu.NextLine()

		if Menu.currentTab == 1 then
			TimMenu.Text("Please Use Lbox Auto Backstab")
			TimMenu.NextLine()

			Menu.Main.Active = TimMenu.Checkbox("Active", Menu.Main.Active)
			TimMenu.NextLine()

			TimMenu.Separator("Movement")
			Menu.Main.AutoWalk = TimMenu.Checkbox("Auto Walk", Menu.Main.AutoWalk)
			TimMenu.NextLine()
			Menu.Main.AutoWarp = TimMenu.Checkbox("Auto Warp", Menu.Main.AutoWarp)
			TimMenu.NextLine()

			Menu.Main.AutoBlink = TimMenu.Checkbox("Auto Blink", Menu.Main.AutoBlink)
			TimMenu.NextLine()
			Menu.Main.MoveAsistance = TimMenu.Checkbox("Move Asistance", Menu.Main.MoveAsistance)
			TimMenu.NextLine()

			TimMenu.Separator("Activation Settings")
			local activationModes = { "Always", "On Hold", "On Release", "Toggle", "On Click" }
			-- TimMenu.Dropdown returns 1-based index, convert to 0-based for our logic
			local dropdownValue = TimMenu.Dropdown("Activation Mode", Menu.Main.ActivationMode + 1, activationModes)
			Menu.Main.ActivationMode = dropdownValue - 1 -- Convert back to 0-based
			TimMenu.NextLine()

			-- Only show keybind widget if not in Always mode (mode 0)
			if Menu.Main.ActivationMode ~= 0 then
				Menu.Main.Keybind = TimMenu.Keybind("Activation Key", Menu.Main.Keybind)
				TimMenu.NextLine()
			end
		end

		if Menu.currentTab == 2 then
			Menu.Advanced.ManualDirection = TimMenu.Checkbox("Manual Direction", Menu.Advanced.ManualDirection)
			TimMenu.NextLine()
			Menu.Advanced.AutoRecharge = TimMenu.Checkbox("Auto Recharge", Menu.Advanced.AutoRecharge)
			TimMenu.NextLine()

			Menu.Advanced.MinBackstabPoints =
				TimMenu.Slider("Min Stab Points", Menu.Advanced.MinBackstabPoints, 1, 30, 1)
			TimMenu.NextLine()

			-- Default to true if not set
			if Menu.Advanced.UseAngleSnap == nil then
				Menu.Advanced.UseAngleSnap = true
			end
			Menu.Advanced.UseAngleSnap = TimMenu.Checkbox("Use Angle Snap", Menu.Advanced.UseAngleSnap)
			-- Note: Angle snap fixes warp direction. Disable for smooth rotation (needs lbox to fix warp OnCreateMove callback)
			TimMenu.NextLine()

			Menu.Advanced.ColisionCheck = TimMenu.Checkbox("Colision Check", Menu.Advanced.ColisionCheck)
			TimMenu.NextLine()
			Menu.Advanced.AdvancedPred = TimMenu.Checkbox("Advanced Pred", Menu.Advanced.AdvancedPred)
			TimMenu.NextLine()
			Menu.Advanced.AntiBackstabResolver =
				TimMenu.Checkbox("Anti-Backstab Resolver (HvH)", Menu.Advanced.AntiBackstabResolver)
			TimMenu.NextLine()
			Menu.Advanced.SmoothWarp = TimMenu.Checkbox("Smooth Warp (Experimental)", Menu.Advanced.SmoothWarp)
			TimMenu.NextLine()
		end

		if Menu.currentTab == 3 then
			Menu.Visuals.Active = TimMenu.Checkbox("Active", Menu.Visuals.Active)
			TimMenu.NextLine()

			Menu.Visuals.VisualizePoints = TimMenu.Checkbox("Simulations", Menu.Visuals.VisualizePoints)
			TimMenu.NextLine()
			Menu.Visuals.VisualizeStabPoint = TimMenu.Checkbox("Stab Points", Menu.Visuals.VisualizeStabPoint)
			TimMenu.NextLine()

			Menu.Visuals.Attack_Circle = TimMenu.Checkbox("Attack Circle", Menu.Visuals.Attack_Circle)
			TimMenu.NextLine()
			Menu.Visuals.BackLine = TimMenu.Checkbox("Forward Line", Menu.Visuals.BackLine)
			TimMenu.NextLine()

			-- Debug option for corner visualization
			Menu.Visuals.DebugCorners = TimMenu.Checkbox("Debug Corners", Menu.Visuals.DebugCorners or false)
			TimMenu.NextLine()
		end
	end
end

--[[ Anti-Backstab Resolver - Force cheaters to look at us with ping compensation ]]
--
-- Resolve fake pitch from anti-aim (clamp to valid range)
local function ResolvePitch(pitch)
	if pitch > 89 then
		return 89
	elseif pitch < -89 then
		return -89
	end
	return pitch
end

-- Calculate yaw to look from one position to another
local function LookAtYaw(fromPos, toPos)
	local delta = toPos - fromPos
	return math.deg(math.atan(delta.y, delta.x))
end

-- Get real ping using NetChannel (more accurate than reported ping)
local function GetRealPing()
	local netChannel = clientstate.GetNetChannel()
	if not netChannel then
		return 0.05 -- Default 50ms if unavailable
	end

	-- Get average latency from netchannel (incoming + outgoing)
	-- E_Flows: FLOW_OUTGOING = 0, FLOW_INCOMING = 1
	local incoming = netChannel:GetAvgLatency(1) or 0 -- FLOW_INCOMING
	local outgoing = netChannel:GetAvgLatency(0) or 0 -- FLOW_OUTGOING
	local avgLatency = (incoming + outgoing) / 2

	-- Add 1 tick safety margin (15ms at 66 tick)
	local safetyMargin = 1 / 66

	-- Clamp to reasonable range (1 tick to 500ms)
	return math.max(math.min(avgLatency - safetyMargin, 0.5), safetyMargin)
end

-- Convert ping (seconds) to ticks
local function PingToTicks(pingSeconds)
	local tickInterval = globals.TickInterval() or (1 / 66)
	return math.max(1, math.ceil(pingSeconds / tickInterval))
end

-- Clear position history (call on module off/unload)
local function ClearPositionHistory()
	positionHistory = {}
end

-- Record local player position for history (queue: newest at index 1)
local function RecordPositionHistory(pos)
	-- Push to front (index 1 = newest)
	table.insert(positionHistory, 1, Vector3(pos.x, pos.y, pos.z))

	-- Remove entries beyond 66 ticks (trim from end)
	while #positionHistory > POSITION_HISTORY_SIZE do
		positionHistory[#positionHistory] = nil
	end
end

-- Get position from history based on ticks ago (index = ticks ago + 1)
local function GetPositionFromHistory(ticksAgo)
	if #positionHistory == 0 then
		return nil
	end

	-- Queue: index 1 = now, index 2 = 1 tick ago, etc.
	local index = math.min(ticksAgo + 1, #positionHistory)
	return positionHistory[index]
end

-- Smooth angle interpolation for resolver
local function LerpAngle(from, to, t)
	-- Normalize angles
	local diff = to - from
	while diff > 180 do
		diff = diff - 360
	end
	while diff < -180 do
		diff = diff + 360
	end
	return from + diff * t
end

-- FrameStageNotify callback - resolves cheater view angles with ping compensation
local function OnFrameStageNotify(stage)
	-- Only run on FRAME_NET_UPDATE_END (stage 4) - this is when props are updated
	if stage ~= E_ClientFrameStage.FRAME_NET_UPDATE_END then
		return
	end

	-- Get local player
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsAlive() then
		return
	end

	local localPos = localPlayer:GetAbsOrigin()
	if not localPos then
		return
	end

	-- Record position for history (always do this)
	RecordPositionHistory(localPos)

	-- Check if resolver feature is enabled
	if not Menu.Advanced.AntiBackstabResolver then
		return
	end

	-- Get our real ping for compensation
	local myPing = GetRealPing()
	local myPingTicks = PingToTicks(myPing)

	-- Get all players
	local allPlayers = entities.FindByClass("CTFPlayer")
	if not allPlayers then
		return
	end

	for _, player in pairs(allPlayers) do
		if not player or not player:IsValid() then
			goto continue
		end
		if player == localPlayer then
			goto continue
		end
		if not player:IsAlive() or player:IsDormant() then
			goto continue
		end
		if player:GetTeamNumber() == localPlayer:GetTeamNumber() then
			goto continue
		end

		-- Get enemy position
		local playerPos = player:GetAbsOrigin()
		if not playerPos then
			goto continue
		end

		-- Get current network angles
		local networkAngles = player:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
		if not networkAngles then
			goto continue
		end

		-- Calculate ping-compensated position they would see
		-- Enemy aimbot sees us where we were (myPingTicks) ago - instant snap, no extrapolation
		local positionTheySee = GetPositionFromHistory(myPingTicks)
		if not positionTheySee then
			positionTheySee = localPos -- Fallback to current
		end

		-- Perfect aimbot = instant snap to where they see us (no smoothing/interpolation)
		local resolvedYaw = LookAtYaw(playerPos, positionTheySee)

		-- Normalize yaw to -180 to 180
		while resolvedYaw > 180 do
			resolvedYaw = resolvedYaw - 360
		end
		while resolvedYaw < -180 do
			resolvedYaw = resolvedYaw + 360
		end

		-- Resolve the pitch (fix fake pitch from anti-aim)
		local resolvedPitch = ResolvePitch(networkAngles.x)

		-- Force their view angles - perfect aimbot snap to our lag-compensated position
		player:SetPropVector(Vector3(resolvedPitch, resolvedYaw, 0), "tfnonlocaldata", "m_angEyeAngles[0]")

		::continue::
	end
end

--[[ Remove the menu when unloaded ]]
--
local function OnUnload() -- Called when the script is unloaded
	ClearPositionHistory() -- Clear position history on unload
	UnloadLib() --unloading lualib
	CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu) --saving the config
	engine.PlaySound("hl1/fvox/deactivated.wav")
end

--[[ SendNetMsg callback for smooth warp packet modification ]]
--
local function OnSendNetMsg(msg)
	if not Menu.Main.Active then
		return
	end
	HandleSmoothWarpPacket(msg)
end

--[[ Unregister previous callbacks ]]
--
callbacks.Unregister("CreateMove", "AtSM_CreateMove") -- Unregister the "CreateMove" callback
callbacks.Unregister("Unload", "AtSM_Unload") -- Unregister the "Unload" callback
callbacks.Unregister("Draw", "AtSM_Draw") -- Unregister the "Draw" callback
callbacks.Unregister("FireGameEvent", "adaamageLogger")
callbacks.Unregister("FireGameEvent", "AtSM_KillRecharge")
callbacks.Unregister("FrameStageNotify", "AtSM_Resolver") -- Unregister resolver callback
callbacks.Unregister("SendNetMsg", "AtSM_SmoothWarp") -- Unregister smooth warp callback

--[[ Register callbacks ]]
--
callbacks.Register("CreateMove", "AtSM_CreateMove", OnCreateMove) -- Register the "CreateMove" callback
callbacks.Register("Unload", "AtSM_Unload", OnUnload) -- Register the "Unload" callback
callbacks.Register("Draw", "AtSM_Draw", doDraw) -- Register the "Draw" callback
callbacks.Register("FireGameEvent", "adaamageLogger", damageLogger)
callbacks.Register("FireGameEvent", "AtSM_KillRecharge", OnKillRecharge) -- Auto recharge on kill
callbacks.Register("FrameStageNotify", "AtSM_Resolver", OnFrameStageNotify) -- Anti-backstab resolver
callbacks.Register("SendNetMsg", "AtSM_SmoothWarp", OnSendNetMsg) -- Smooth warp packet handler

--[[ Play sound when loaded ]]
--
engine.PlaySound("hl1/fvox/activated.wav")
