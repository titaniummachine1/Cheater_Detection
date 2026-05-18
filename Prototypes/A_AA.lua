--[[
    Advanced Antyaim Lua for lmaobox
    Author: github.com/titaniummachine1
]]
---@alias AimTarget { entity : Entity, pos : Vector3, angles : EulerAngles, factor : number }
client.Command("clear", true)
print("[A_AA] Script loaded")


---@type boolean, lnxLib
local libLoaded, lnxLib = pcall(require, "lnxLib")
assert(pcall(require, "lnxLib"), "lnxLib not found, please install it!")
--assert(lnxLib.GetVersion() >= 0.967, "LNXlib version is too old, please update it!")

local TimMenu = require("TimMenu")

-- Menu state variables
local menuEnabled = false
local menuDebug = true

client.SetConVar("cl_vWeapon_sway_interp", 0)          -- Set cl_vWeapon_sway_interp to 0
client.SetConVar("cl_jiggle_bone_framerate_cutoff", 0) -- Set cl_jiggle_bone_framerate_cutoff to 0
client.SetConVar("cl_bobcycle", 10000)                 -- Set cl_bobcycle to 10000
client.SetConVar("sv_cheats", 1)                       -- debug fast setup
client.SetConVar("mp_disable_respawn_times", 1)
client.SetConVar("mp_respawnwavetime", -1)
client.SetConVar("mp_teams_unbalance_limit", 1000)
--client.Command('cl_interp 0', true)
--client.Command('cl_lerp 0', true)

--local mHeadShield        = menu:AddComponent(MenuLib.Checkbox("head Shield", true))

--menu:AddComponent(MenuLib.Label("                 Resolver(soon)"), ItemFlags.FullWidth)
--local BruteforceYaw       = menu:AddComponent(MenuLib.Checkbox("Bruteforce Yaw", false))
local pLocal
local pLocalOrigin
local targetAngle         = 0
local Angles_Real         = 0
local Angles_Fake         = 0
local pitchtype1          = gui.GetValue("Anti Aim - Pitch")
local players             = entities.FindByClass("CTFPlayer")
local pLocalView          = Vector3()
local closestPoint1
local HeadOffsetHorizontal
local HeadHeightOffset    = Vector3(0, 0, 0)
local Headpos             = Vector3(0, 0, 0)
local Circle_segments     = 8 -- matches NUM_SEGS (8 x 45° steps)
local LocalViewAngle      = engine.GetViewAngles()
local vheight             = Vector3(0, 0, 70)
local distance1           = 0
local gotshot             = false
local Latency             = 0
local Serversite_angle

-- Global variable to hold reload times for each attacker
local attackerReloadTimes = {}


local Math          = lnxLib.Utils.Math
local WPlayer       = lnxLib.TF2.WPlayer
local Helpers       = lnxLib.TF2.Helpers

local currentTarget = nil

local settings      = {
    MinDistance = 100,
    MaxDistance = 1000,
    MinFOV = 0,
    MaxFOV = 360,
}

--[[local function CanShoot(player)
    local pWeapon = player:GetPropEntity("m_hActiveWeapon")
    if (not pWeapon) or (pWeapon:IsMeleeWeapon()) then return false end

    local nextPrimaryAttack = pWeapon:GetPropFloat("LocalActiveWeaponData", "m_flNextPrimaryAttack")
    local nextAttack = player:GetPropFloat("bcc_localdata", "m_flNextAttack")
    if (not nextPrimaryAttack) or (not nextAttack) then return false end

    return nextPrimaryAttack, nextAttack
end]]

local targetList = {}

local function normalizeAngle(offsetNumber)
    offsetNumber = offsetNumber % 360
    if offsetNumber > 180 then
        offsetNumber = offsetNumber - 360
    elseif offsetNumber < -180 then
        offsetNumber = offsetNumber + 360
    end
    return offsetNumber
end

---@param me WPlayer
---@return AimTarget? target
local function GetBestTarget(me)
    players = entities.FindByClass("CTFPlayer")
    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer then return end

    -- Clear previous target list
    targetList = {}
    vheight = localPlayer:GetPropVector("localdata", "m_vecViewOffset[0]")

    -- Calculate target factors
    for i, player in pairs(players) do
        local classNum = player:GetPropInt("m_iClass")
        -- Target all enemy classes
        if player == localPlayer
            or player:GetTeamNumber() == localPlayer:GetTeamNumber()
            or not player:IsAlive()
            or player:IsDormant() then
            goto continue
        end

        if classNum == 8 then                                                  --if spy
            if (gui.GetValue("ignore cloaked") == 1 and player:InCond(4)) then --ignore invisible spies
                goto continue
            end
        end

        local distance = (player:GetAbsOrigin() - localPlayer:GetAbsOrigin()):Length()

        -- Distance factor
        local distanceFactor = Math.RemapValClamped(distance, settings.MinDistance, settings.MaxDistance, 1, 1)

        -- FOV factor - prefer targets closer to where you're looking
        local angles = Math.PositionAngles(pLocalOrigin + vheight, player:GetAbsOrigin() + Vector3(0, 0, 75))
        local fov = Math.AngleFov(LocalViewAngle, angles)
        local fovFactor = Math.RemapValClamped(fov, settings.MinFOV, settings.MaxFOV, 1, 0.1)

        -- Visibility factor - prefer visible targets
        local visibilityFactor = Helpers.VisPos(player, localPlayer:GetAbsOrigin() + vheight,
            player:GetAbsOrigin() + Vector3(0, 0, 75)) and 1 or 0.5

        local ThreatFactor = attackerReloadTimes[player:GetIndex()] and 1 or 0.5

        local factor = distanceFactor * fovFactor * visibilityFactor * ThreatFactor

        table.insert(targetList, { player = player, factor = factor })

        ::continue::
    end

    -- Sort target list by factor
    table.sort(targetList, function(a, b)
        return a.factor > b.factor
    end)

    local bestTarget = nil

    if #targetList > 0 then
        local player = targetList[1].player
        local aimPos = player:GetAbsOrigin() + Vector3(0, 0, 75)
        local angles = Math.PositionAngles(localPlayer:GetAbsOrigin(), aimPos)
        local fov = Math.AngleFov(LocalViewAngle, angles)

        bestTarget = { entity = player, angles = angles, factor = targetList[1].factor }
    end
    return bestTarget
end

-- Defensive Anti-Aim Settings
local defensiveAAEnabled = true
local forceFreestanding = true -- Enable to force freestanding at best target
local jitterlegEnabled = true  -- Jitterleg forces AA to update properly
local lastHitDirection = nil   -- Track which direction we got hit from
local fluctuation = 0
local jitterPattern = 0        -- Additional jitter for timing unpredictability

-- Menu setup
local windowOptions = {
    ShowAlways = false,
}

local function OnDraw_Menu()
    if TimMenu.Begin("A_AA Defensive Anti-Aim", windowOptions) then
        TimMenu.Text("Defensive Anti-Aim Controls")
        TimMenu.NextLine()
        defensiveAAEnabled = TimMenu.Checkbox("Enable Defensive AA", defensiveAAEnabled)
        menuDebug = TimMenu.Checkbox("Debug Mode", menuDebug)
        TimMenu.NextLine()
        TimMenu.Separator()
        TimMenu.NextLine()

        TimMenu.Text("Freestanding Settings")
        TimMenu.NextLine()
        forceFreestanding = TimMenu.Checkbox("Force Freestanding", forceFreestanding)
        TimMenu.NextLine()
        jitterlegEnabled = TimMenu.Checkbox("Jitterleg (fixes AA update)", jitterlegEnabled)
        TimMenu.NextLine()
        useCustomPatterns = TimMenu.Checkbox("Learn Custom Patterns", useCustomPatterns == true)
        TimMenu.NextLine()
        TimMenu.Separator()
        TimMenu.NextLine()

        TimMenu.Text("Target Selection Settings")
        TimMenu.NextLine()
        settings.MinDistance = TimMenu.Slider("Min Distance", settings.MinDistance, 50, 500, 10)
        TimMenu.NextLine()
        settings.MaxDistance = TimMenu.Slider("Max Distance", settings.MaxDistance, 500, 2000, 50)
        TimMenu.NextLine()
        settings.MinFOV = TimMenu.Slider("Min FOV", settings.MinFOV, 0, 90, 5)
        TimMenu.NextLine()
        settings.MaxFOV = TimMenu.Slider("Max FOV", settings.MaxFOV, 90, 360, 10)
        TimMenu.NextLine()
        TimMenu.Separator()
        TimMenu.NextLine()

        TimMenu.Text("Status: " .. (defensiveAAEnabled and "ENABLED" or "DISABLED"))
        TimMenu.NextLine()

        if menuDebug and currentTarget then
            TimMenu.Text("Target: " .. (currentTarget:GetName() or "Unknown"))
            if lastHitDirection then
                TimMenu.Text("Last Hit From: " .. tostring(lastHitDirection))
            end
            TimMenu.NextLine()
        end
    end
end

-- Defensive Anti-Aim: Simple offset based on hit direction
local function applyDefensiveAA(attacker)
    if not defensiveAAEnabled or not attacker then return nil, nil end

    -- Simple offset selection based on hit direction
    local offset = 0
    if lastHitDirection == "left" then
        offset = 90  -- Go right if hit from left
    elseif lastHitDirection == "right" then
        offset = -90 -- Go left if hit from right
    elseif lastHitDirection == "back" then
        offset = 0   -- Go forward if hit from back
    else
        offset = 90  -- Default to right
    end

    print("[Defensive AA] Hit from: " .. tostring(lastHitDirection) .. ", Using offset: " .. offset)

    -- Calculate the desired world space yaw angle
    local desiredYaw = targetAngle + offset
    desiredYaw = normalizeAngle(desiredYaw)

    -- Convert to GUI offset format
    local LocalYaw = LocalViewAngle.yaw
    local currentFluctuation = (fluctuation == 0 and 180 or 0)
    local guiOffset = desiredYaw - (targetAngle - LocalYaw) - currentFluctuation
    guiOffset = normalizeAngle(guiOffset)

    print("[Defensive AA] desiredYaw: " ..
        desiredYaw .. " guiOffset: " .. guiOffset .. " targetAngle: " .. targetAngle .. " LocalYaw: " .. LocalYaw)

    -- Disable fake angle (set to same as real)
    return guiOffset, guiOffset
end

-- Fake points straight at target (pure forward) — best result from angle tester data
local function getDynamicFakeBias()
    return 0
end

local function updateYaw(Real_offset, Fake_offset, userCmd, attacker)
    -- Get local player and local yaw
    local localPlayer = entities.GetLocalPlayer()
    local LocalYaw = LocalViewAngle.yaw

    assert(localPlayer, "updateYaw: localPlayer is nil")
    assert(LocalYaw, "updateYaw: LocalYaw is nil")

    -- Apply defensive AA if enabled - this overrides everything else
    -- But not if forceFreestanding is enabled
    if defensiveAAEnabled and attacker and not forceFreestanding then
        local defRealOffset, defFakeOffset = applyDefensiveAA(attacker)
        if defRealOffset and defFakeOffset then
            -- Directly set GUI values from defensive AA
            -- Fake = toward target, Real = actual hidden hitbox (forward + offset)
            gui.SetValue("Anti Aim - Custom Yaw (Fake)", math.floor(defRealOffset))
            gui.SetValue("Anti Aim - Custom Yaw (Real)", normalizeAngle(math.floor(defRealOffset) + 180))
            return -- Skip normal calculation
        end
    end

    -- Force freestanding at best target
    if forceFreestanding and currentTarget then
        local targetPos = currentTarget:GetAbsOrigin()
        local playerPos = localPlayer:GetAbsOrigin()
        local forwardVec = engine.GetViewAngles():Forward()

        assert(targetPos, "updateYaw: targetPos is nil")
        assert(playerPos, "updateYaw: playerPos is nil")
        assert(forwardVec, "updateYaw: forwardVec is nil")

        -- Calculate world space angle to target
        local worldTargetAngle = math.deg(math.atan(targetPos.y - playerPos.y, targetPos.x - playerPos.x))
        local viewAngle = math.deg(math.atan(forwardVec.y, forwardVec.x))
        local localTargetAngle = math.floor(worldTargetAngle - viewAngle)

        -- Real angle - points at target
        local realYaw = localTargetAngle
        if realYaw > 180 then realYaw = realYaw - 360 end
        if realYaw < -180 then realYaw = realYaw + 360 end
        realYaw = math.floor(realYaw)
        -- Fake = toward target + dynamic bias (unpredictable for resolver)
        gui.SetValue("Anti Aim - Custom Yaw (Fake)", realYaw + getDynamicFakeBias())

        -- Real = use counter offset (0° = center/forward, ±90° = sides)
        local realOffset = Fake_offset
        gui.SetValue("Anti Aim - Custom Yaw (Real)", normalizeAngle(realYaw + realOffset))
        return
    end

    -- Enhanced fluctuation with multiple patterns for timing unpredictability
    local tickCount = globals.TickCount()
    local pattern = tickCount % 8

    if pattern < 2 then
        fluctuation = 180
    elseif pattern < 4 then
        fluctuation = 90
    elseif pattern < 6 then
        fluctuation = -90
    else
        fluctuation = 0
    end

    -- Add micro-jitter for even more unpredictability
    jitterPattern = (jitterPattern + 1) % 3
    if jitterPattern == 0 then
        fluctuation = fluctuation + math.random(-5, 5)
    end

    -- Calculate the real yaw based on target angle, offset and local yaw
    local realYaw = (targetAngle - LocalYaw) + Real_offset + fluctuation

    realYaw = math.floor(realYaw)
    -- Normalize real yaw
    realYaw = normalizeAngle(realYaw)
    --todo add second dirction to negative check

    -- Fake = toward target + dynamic bias (unpredictable for resolver)
    gui.SetValue("Anti Aim - Custom Yaw (Fake)", realYaw + getDynamicFakeBias())

    -- Real = actual hidden hitbox, left or right of target direction
    local realHitboxYaw = normalizeAngle(realYaw + Fake_offset)
    gui.SetValue("Anti Aim - Custom Yaw (Real)", realHitboxYaw)
end

local sniperdotspoitions = {}

local function UpdateSniperDots()
    local SniperDots = entities.FindByClass("CTFSniperDot")
    sniperdotspoitions = {} -- Clear previous positions

    for key, SniperDot in pairs(SniperDots) do
        local position = SniperDot:GetAbsOrigin()
        local ownerEnt = SniperDot:GetPropEntity("m_hOwnerEntity")
        local ownerIndex = ownerEnt and ownerEnt:GetIndex() or nil
        sniperdotspoitions[key] = {
            Position = position,
            Owner = ownerEnt and ownerEnt:GetName() or "?",
            OwnerIndex =
                ownerIndex
        }
        --print(SniperDot:GetPropEntity("m_hOwnerEntity"):GetName())
        --table.insert( SniperDot:GetPropEntity("m_hOwnerEntity"), {Laser = SniperDot:GetAbsOrigin()})
    end
end

-- Function to update reload times
local function updateReloadTimes()
    for attackerIndex, ticks in pairs(attackerReloadTimes) do
        if ticks > Latency then
            attackerReloadTimes[attackerIndex] = ticks - 1
        else
            attackerReloadTimes[attackerIndex] = nil -- Remove the attacker from the table when reload time reaches 0
        end
    end
end

-- Function to add a new attacker to the table by index
local function addNewAttackerByIndex(attackerIndex)
    attackerReloadTimes[attackerIndex] = 99 -- Initialize reload time to 106 ticks
end

local queue = {}
local floor = math.floor
local x, y = draw.GetScreenSize()
local font_calibri = draw.CreateFont("Calibri", 18, 18)
local offsetNumber_right = 400
local offsetNumber_left = 480
local offsetNumber_back = 730
local offsetNumber_forward = 630

local offsetNumber = offsetNumber_back --274 -- 74 is forwrds offset 274 for back
local gotheadshot = false

-- Get sniper dot aim direction for attacker (eye pos -> dot pos = real aim)
local function getSniperDotForward(attackerIndex, attackerEyePos)
    for _, dot in pairs(sniperdotspoitions) do
        if dot.OwnerIndex == attackerIndex and dot.Position then
            local dir = dot.Position - attackerEyePos
            local len = dir:Length()
            if len > 1 then
                return dir * (1 / len)
            end
        end
    end
    return nil
end

-- Per-enemy eye angle history: track last N ticks to find lowest-pitch (most horizontal) aim
local eyeAngleHistory = {} -- [playerIndex] = { {x, y, tick}, ... }
local EYE_HISTORY_TICKS = 10

local function updateEyeHistory(playerIndex, eyeAngles)
    if not eyeAngleHistory[playerIndex] then
        eyeAngleHistory[playerIndex] = {}
    end
    table.insert(eyeAngleHistory[playerIndex], {
        x = eyeAngles.x, -- pitch
        y = eyeAngles.y, -- yaw
        tick = globals.TickCount()
    })
    if #eyeAngleHistory[playerIndex] > EYE_HISTORY_TICKS then
        table.remove(eyeAngleHistory[playerIndex], 1)
    end
end

local function getBestAimYaw(playerIndex)
    local history = eyeAngleHistory[playerIndex]
    if not history or #history == 0 then return nil end
    local best = history[1]
    for _, entry in ipairs(history) do
        local absCur  = math.abs(entry.x)
        local absBest = math.abs(best.x)
        if absCur < absBest then
            best = entry
        end
    end
    return best.y
end

-- ============================================================
-- 8-Segment Resolver: 45° steps, forward-only cycle tracking
-- ============================================================
-- Segments at 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°
-- relative to attacker→us direction (0° = directly toward us)
-- Fake is at FAKE_BIAS (45°), so:
--   seg 0  = forward  (real angle 0°)
--   seg 1  = fake     (45°, our FAKE_BIAS)
--   seg 2  = left     (90°)
--   seg 3  = far-left (135°)
--   seg 4  = back     (180°)
--   seg 5  = invert   (225°, invert of fake)
--   seg 6  = right    (270° = -90°)
--   seg 7  = far-right(315° = -45°)

local function normAngle(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

local NUM_SEGS = 8
local SEG_STEP = 360 / NUM_SEGS -- 45°

-- Index 0..7, angle = index * 45°
local SEG_NAMES = {
    [0] = "forward",
    [1] = "fake",
    [2] = "left",
    [3] = "far-left",
    [4] = "back",
    [5] = "invert",
    [6] = "right",
    [7] = "far-right",
}

-- Map aimRelYaw (degrees, relative to attacker→us) to segment index 0..7
-- Enemy cycle only goes forward (+1 per shot), so we track index precisely.
local function aimYawToSegIndex(aimRelYaw)
    -- Normalize to [0, 360)
    local a = aimRelYaw % 360
    if a < 0 then a = a + 360 end
    -- Round to nearest 45° step
    local idx = math.floor((a / SEG_STEP) + 0.5) % NUM_SEGS
    return idx
end

local function segIndexToAngle(idx)
    return (idx % NUM_SEGS) * SEG_STEP
end

-- Extreme head protection: continuous random positions
-- Resolver can't predict if we never use predictable patterns
local SAFE_HEAD_OPTIONS = {
    -165, -150, -135, -120, -105, -90, -75, -60, -45, -30, -15, 0, 15, 30, 45, 60, 75, 90, 105, 120, 135, 150, 165
}

-- Dynamic head randomization to break resolver patterns
local function getRandomHeadPosition(currentSegIdx, isHeadshot)
    -- If we just got headshot, pick a completely random position far from current
    if isHeadshot then
        local baseAngles = { -165, -150, -135, -120, -105, -90, -75, -60, -45, -30, -15, 0, 15, 30, 45, 60, 75, 90, 105, 120, 135, 150, 165 }
        return baseAngles[math.random(#baseAngles)]
    end

    -- For body shots, still randomize but less aggressively
    local currentAngle = segIndexToAngle(currentSegIdx)
    local offset = math.random(-60, 60)
    return normalizeAngle(currentAngle + offset)
end

local useCustomPatterns = false
local MAX_HISTORY = 30
local resolverState = {} -- [playerIndex] = { segIndex, hits[], lastCounterHead, observedStep }

-- Classify aimRelYaw into segment index 0..7
local function classifySegment(aimRelYaw)
    return aimYawToSegIndex(aimRelYaw)
end

-- Angular distance between two angles (degrees), returns 0..180
local function angDist(a, b)
    return math.abs(normAngle(a - b))
end

-- Resolver cycle: 6 positions lmaobox cycles through, forward-only
-- index 0=default, 1=left, 2=right, 3=invert, 4=forward, 5=back
local RESOLVER_CYCLE      = { "default", "left", "right", "invert", "forward", "back" }
local RESOLVER_CYCLE_SIZE = 6
local resolverCyclePos    = {} -- [attackerIndex] = 0..5

-- Safe head offset per resolver cycle position, derived from angle tester findings.
-- Priority: pure miss > body > avoid HS. All angles relative to target direction.
-- Lookup: SAFE_HEAD_BY_CYCLE[cyclePos] = head offset degrees
-- default(0):  away(180)=miss, +135=miss, -135=miss  → pick away(180)
-- left(-90):   right(90)=miss, +135=miss, away=miss  → pick right(90) (consistent across positions)
-- right(90):   toward(0)=miss, +45=miss, -45=miss    → toward(0) is risky for others, pick +45(45)
-- invert(180): no miss, right arc = body             → right(90) best available
-- forward(0):  +135=miss, away=miss, -135=miss       → pick away(180)
-- back(180):   no miss, right arc = body             → right(90) best available
local SAFE_HEAD_BY_CYCLE  = {
    [0] = 180, -- default:  away is pure miss
    [1] = 90,  -- left:     right(90) is pure miss
    [2] = 45,  -- right:    +45 is pure miss (toward risky elsewhere)
    [3] = 90,  -- invert:   right(90) is body-only (best available, no miss exists)
    [4] = 180, -- forward:  away is pure miss
    [5] = 90,  -- back:     right(90) is body-only (best available, no miss exists)
}

local function pickSafeHead(currentSegIdx, isMiss, step)
    -- currentSegIdx here is the resolver CYCLE position (0..5), not circle segment
    local pos = currentSegIdx % RESOLVER_CYCLE_SIZE
    return SAFE_HEAD_BY_CYCLE[pos] or 90
end

-- Record a shot event and update state
-- aimRelYaw: angle enemy aimed at, relative to attacker→us (0° = straight at us)
-- damage: damage dealt (>50 = headshot for sniper rifle)
local function recordResolverHit(attackerIndex, damage, aimRelYaw)
    if not resolverState[attackerIndex] then
        resolverState[attackerIndex] = { segIndex = 0, hits = {}, lastCounterHead = 90, isLocked = false }
    end
    local state      = resolverState[attackerIndex]

    local segIdx     = classifySegment(aimRelYaw or 0)
    local segName    = SEG_NAMES[segIdx] or tostring(segIdx)

    local isHeadshot = damage > 50

    -- CRITICAL: Resolver STOPS cycling on headshot, continues on miss/bodyshot
    if isHeadshot then
        state.isLocked = true -- Resolver locked at this position
        state.segIndex = segIdx
    else
        state.isLocked = false -- Resolver will cycle on next miss
        state.segIndex = segIdx
    end

    -- Pick head position based on current resolver position
    local counterHead = pickSafeHead(segIdx, not isHeadshot, 1)
    state.lastCounterHead = counterHead

    table.insert(state.hits, {
        aimRelYaw  = aimRelYaw,
        segIndex   = segIdx,
        segName    = segName,
        damage     = damage,
        isHeadshot = isHeadshot,
        timestamp  = globals.RealTime(),
    })
    if #state.hits > MAX_HISTORY then
        table.remove(state.hits, 1)
    end

    return segIdx, segName
end

-- Advance resolver cycle on miss: lmaobox cycles forward through 6 positions
local function advanceCycleOnMiss(attackerIndex)
    if not resolverState[attackerIndex] then
        resolverState[attackerIndex] = { segIndex = 0, hits = {}, lastCounterHead = 90 }
    end
    if not resolverCyclePos[attackerIndex] then
        resolverCyclePos[attackerIndex] = 0
    end
    local state                     = resolverState[attackerIndex]
    resolverCyclePos[attackerIndex] = (resolverCyclePos[attackerIndex] + 1) % RESOLVER_CYCLE_SIZE
    state.segIndex                  = resolverCyclePos[attackerIndex]
    state.lastCounterHead           = pickSafeHead(state.segIndex, true, 1)
end

-- Get the current best counter head offset for an attacker
-- Returns degrees relative to target direction (positive = left, negative = right)
local function getCounterOffset(attackerIndex)
    local state = resolverState[attackerIndex]
    if not state then return 90 end
    return state.lastCounterHead or 90
end

-- Get predicted next segment name for logging
local function getPredictedNextName(attackerIndex)
    local state = resolverState[attackerIndex]
    if not state then return "unknown" end
    local nextIdx = (state.segIndex + 1) % NUM_SEGS
    return SEG_NAMES[nextIdx] or tostring(nextIdx)
end

local recentShots = {}       -- [playerIndex] = { time, hit }
local MISS_WINDOW = 0.25     -- seconds after shot to wait for player_hurt
local lastBulletImpacts = {} -- [playerIndex] = { muzzlePos, impactPos, time } (current shot, may not have impactPos yet)
local prevBulletImpacts = {} -- [playerIndex] = { muzzlePos, impactPos, time } (previous completed shot)
local headshotFlashTime = 0  -- timestamp of last headshot, for ring flash

local function event_hook(ev)
    local eventName = ev:GetName()

    -- Detect when anyone shoots
    if eventName == "weapon_fire" then
        local shooter = entities.GetByUserID(ev:GetInt("userid"))
        local localplayer = entities.GetLocalPlayer()

        if not shooter or not localplayer or shooter == localplayer then return end
        if not shooter:IsAlive() or shooter:IsDormant() then return end

        -- Get shooter's view angles
        local shooterViewAngles = shooter:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
        if not shooterViewAngles then return end

        local shooterForward = shooterViewAngles:Forward()
        if not shooterForward then return end

        -- Calculate circle parameters for local player
        local pLocalOrigin = localplayer:GetAbsOrigin()
        local vheight = localplayer:GetPropVector("localdata", "m_vecViewOffset[0]")
        local pLocalView = pLocalOrigin + vheight

        -- Get head position for circle
        local hitboxes = localplayer:GetHitboxes(globals.CurTime())
        local Headpos
        if hitboxes then
            local headBox = hitboxes[0] or hitboxes[1]
            if headBox and headBox[1] and headBox[2] then
                Headpos = (headBox[1] + headBox[2]) * 0.5
            end
        end

        if not Headpos then return end

        -- Calculate center at head height
        local centerHorizontal = pLocalOrigin
        local HeadHeightOffset = Vector3(0, 0, Headpos.z - centerHorizontal.z)

        -- Calculate head offset
        local headOffsetX = Headpos.x - centerHorizontal.x
        local headOffsetY = Headpos.y - centerHorizontal.y
        local HeadOffsetHorizontal = math.sqrt(headOffsetX * headOffsetX + headOffsetY * headOffsetY)

        -- Check for valid head offset
        if not HeadOffsetHorizontal or HeadOffsetHorizontal <= 0 then return end

        -- Circle parameters
        local radius = HeadOffsetHorizontal / 2
        local center = pLocalOrigin + HeadHeightOffset

        -- Calculate angle to shooter (for circle rotation)
        local shooterViewPos = shooter:GetAbsOrigin() +
            (shooter:GetPropVector("localdata", "m_vecViewOffset[0]") or Vector3(0, 0, 0))
        if not shooterViewPos then return end
        local angleToShooter = Math.PositionAngles(pLocalView, shooterViewPos)
        if not angleToShooter then return end
        local yawOffset = angleToShooter.yaw

        -- Find which circle segment the shooter is aiming at
        local closestSegment = nil
        local closestAngleDiff = math.huge

        for j = 1, Circle_segments do
            local angle = math.rad(j * (360 / Circle_segments) + (yawOffset or 0))
            local dir = Vector3(math.cos(angle), math.sin(angle), 0)
            if not dir then goto continue end
            local point = center + dir * radius
            if not point then goto continue end
            local pointAngle = Math.PositionAngles(shooterViewPos, point)
            if not pointAngle then goto continue end
            local angleDiff = Math.AngleFov(shooterForward, pointAngle)
            if not angleDiff then goto continue end

            if angleDiff < closestAngleDiff then
                closestSegment = j
                closestAngleDiff = angleDiff
            end

            ::continue::
        end

        if closestSegment then
            print(string.format("[SHOOT DETECT] %s shot at circle segment %d (aim diff: %.2f°)",
                shooter:GetName() or "?", closestSegment, closestAngleDiff))
        end
    end

    if eventName ~= "player_hurt" then return end
    if not currentTarget then return end

    local victim_entity = entities.GetByUserID(ev:GetInt("userid"))
    local attacker = entities.GetByUserID(ev:GetInt("attacker"))
    local localplayer = entities.GetLocalPlayer()
    local damage = ev:GetInt("damageamount")

    if victim_entity ~= localplayer then return end
    if not attacker then return end
    gotshot = true

    local attackerIndex = attacker:GetIndex()

    addNewAttackerByIndex(attackerIndex)

    -- Calculate which circle segment the attacker was aiming at
    local attackerViewAngles = attacker:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
    if attackerViewAngles then
        local attackerEyePos = attacker:GetAbsOrigin() +
            (attacker:GetPropVector("localdata", "m_vecViewOffset[0]") or Vector3(0, 0, 0))
        -- Prefer sniper dot (ground truth aim), fall back to best-pitch history, then current frame
        local dotForward = getSniperDotForward(attackerIndex, attackerEyePos)
        local attackerForward
        if dotForward then
            attackerForward = dotForward
        else
            local bestYaw = getBestAimYaw(attackerIndex) or attackerViewAngles.y
            attackerForward = Vector3(0, bestYaw, 0):Forward()
        end

        -- Calculate circle parameters for local player
        local pLocalOrigin = localplayer:GetAbsOrigin()
        local vheight = localplayer:GetPropVector("localdata", "m_vecViewOffset[0]")
        local pLocalView = pLocalOrigin + vheight

        -- Get head position for circle
        local hitboxes = localplayer:GetHitboxes(globals.CurTime())
        local Headpos
        if hitboxes then
            local headBox = hitboxes[0] or hitboxes[1]
            if headBox and headBox[1] and headBox[2] then
                Headpos = (headBox[1] + headBox[2]) * 0.5
            end
        end

        if Headpos then
            local attackerViewPos = attacker:GetAbsOrigin() +
                (attacker:GetPropVector("localdata", "m_vecViewOffset[0]") or Vector3(0, 0, 0))

            -- Shot trajectory: use PREVIOUS completed shot data (current shot's
            -- WorldDecal hasn't arrived yet since player_hurt fires before ProcessTempEntities)
            -- eyePos = attacker's actual view position captured at shot time
            -- impactPos = where the bullet hit (CTEDecal/CTEWorldDecal)
            local impactData = prevBulletImpacts[attackerIndex]
            local shotOrigin = attackerViewPos
            local shotEnd = nil
            if impactData and (globals.CurTime() - impactData.time) < 1.0 then
                if impactData.eyePos then shotOrigin = impactData.eyePos end
                if impactData.impactPos then shotEnd = impactData.impactPos end
            end

            -- Our current fake/real yaw offsets from GUI
            local fakeOff = gui.GetValue("Anti Aim - Custom Yaw (Fake)")
            local realOff = gui.GetValue("Anti Aim - Custom Yaw (Real)")

            -- Yaw from our center toward attacker (world space)
            local attackerYaw = math.deg(math.atan(shotOrigin.y - pLocalOrigin.y, shotOrigin.x - pLocalOrigin.x))

            -- Build circle at head height, 0° aligned with fake direction
            -- fakeOff is relative to view, so fake world yaw = viewYaw + fakeOff
            -- But on circle, 0° = toward attacker. So we offset by fakeOff + FAKE_BIAS
            local center = pLocalOrigin + Vector3(0, 0, Headpos.z - pLocalOrigin.z)
            local headDx = Headpos.x - pLocalOrigin.x
            local headDy = Headpos.y - pLocalOrigin.y
            local radius = math.sqrt(headDx * headDx + headDy * headDy)
            if radius < 1 then radius = 5 end

            local aimRelYaw
            if shotEnd then
                -- Shot direction vector
                local shotDirX = shotEnd.x - shotOrigin.x
                local shotDirY = shotEnd.y - shotOrigin.y
                local shotDirZ = shotEnd.z - shotOrigin.z
                local shotLen = math.sqrt(shotDirX * shotDirX + shotDirY * shotDirY + shotDirZ * shotDirZ)
                if shotLen > 0 then
                    shotDirX = shotDirX / shotLen
                    shotDirY = shotDirY / shotLen
                    shotDirZ = shotDirZ / shotLen
                end

                -- Find closest circle segment to the shot line
                local bestDist = math.huge
                local bestAngle = 0
                local numSegs = 32
                for j = 0, numSegs - 1 do
                    local segWorldYaw = math.rad(j * (360 / numSegs) + attackerYaw)
                    local segPoint = center + Vector3(math.cos(segWorldYaw), math.sin(segWorldYaw), 0) * radius
                    -- Point-to-line distance: |cross(shotDir, shotOrigin - segPoint)| / |shotDir|
                    local dx = shotOrigin.x - segPoint.x
                    local dy = shotOrigin.y - segPoint.y
                    local dz = shotOrigin.z - segPoint.z
                    local cx = shotDirY * dz - shotDirZ * dy
                    local cy = shotDirZ * dx - shotDirX * dz
                    local cz = shotDirX * dy - shotDirY * dx
                    local dist = math.sqrt(cx * cx + cy * cy + cz * cz)
                    if dist < bestDist then
                        bestDist = dist
                        -- Relative angle: segment angle relative to attacker direction
                        bestAngle = normAngle(j * (360 / numSegs))
                    end
                end
                aimRelYaw = bestAngle
            else
                -- Fallback: use head position relative to attacker
                local headYaw = math.deg(math.atan(Headpos.y - pLocalOrigin.y, Headpos.x - pLocalOrigin.x))
                aimRelYaw = normAngle(headYaw - attackerYaw)
            end

            -- Mark this attacker's last shot as a hit
            if recentShots[attackerIndex] then recentShots[attackerIndex].hit = true end

            local isHeadshot = damage > 50

            if isHeadshot then
                headshotFlashTime = globals.RealTime()
            end

            local segIdx, segName = recordResolverHit(attackerIndex, damage, aimRelYaw)
            local st              = resolverState[attackerIndex]
            local counter         = getCounterOffset(attackerIndex)
            local nextSeg         = getPredictedNextName(attackerIndex)

            if isHeadshot then
                print(string.format(
                    "[HS] %s aimRel %.1f° dmg %d | seg[%d]:%s → moving head to %d° (next pred: %s)",
                    attacker:GetName() or "?", aimRelYaw, damage,
                    segIdx, segName, counter, nextSeg))
            else
                print(string.format(
                    "[BODY] %s aimRel %.1f° dmg %d | seg[%d]:%s → head stays %d° (cycle+1→%s)",
                    attacker:GetName() or "?", aimRelYaw, damage,
                    segIdx, segName, counter, nextSeg))
            end
        end
    end

    if damage > 50 then
        gotheadshot = true
    end
    --gui.SetValue("Anti Aim", 0) --force aa update

    --insert table
    table.insert(queue, {
        string = string.format("Hit for %d damage (%d yaw offset)", damage, offsetNumber, iscrit),
        delay = globals.RealTime() + 5.5,
        alpha = 0,
    })

    printc(100, 255, 100, 255,
        string.format("[LMAOBOX] Hit for %d damage (%d yaw offset) ", damage, offsetNumber, iscrit))
end

local function paint_logs()
    draw.SetFont(font_calibri)
    local sw, sh = draw.GetScreenSize()
    local lineH = 20
    local count = 0
    for i, v in pairs(queue) do
        count = count + 1
    end
    local idx = 0
    for i, v in pairs(queue) do
        local text = v.string
        local by = sh - 10 - (count - idx) * lineH
        draw.Color(255, 255, 255, 255)
        draw.Text(10, by, text)
        idx = idx + 1
    end
end

local function anim()
    for i, v in pairs(queue) do
        if globals.RealTime() < v.delay then                             --checks if delay is over or not
            v.alpha = math.min(v.alpha + 1, 255)                         --fade in animation
        else
            v.string = string.sub(v.string, 1, string.len(v.string) - 1) --removes last character
            local remaining = string.len(v.string)
            if remaining <= 0 then
                table.remove(queue, i) --if theres no text left, remove the table
            end
        end
    end
end
callbacks.Unregister("FireGameEvent", "unique_event_hook")
callbacks.Register("FireGameEvent", "unique_event_hook", event_hook)

callbacks.Unregister("ProcessTempEntities", "ShotDetect")
callbacks.Register("ProcessTempEntities", "ShotDetect", function(entEvtTable)
    local localplayer = entities.GetLocalPlayer()
    if not localplayer then return end

    local now = globals.CurTime()
    local lastShooterIndex = nil

    -- Helper: find the most recent shooter who fired within 0.5s
    local function findRecentShooter()
        if lastShooterIndex and lastBulletImpacts[lastShooterIndex] then return lastShooterIndex end
        local bestIdx, bestTime = nil, 0
        for idx, imp in pairs(lastBulletImpacts) do
            if (now - imp.time) < 0.5 and imp.time > bestTime then
                bestIdx = idx
                bestTime = imp.time
            end
        end
        return bestIdx
    end

    -- Pass 1: collect impact positions and attach to existing shooter entries FIRST
    for ent, _ in pairs(entEvtTable) do
        local netName = ent:GetNetworkName()
        if netName == "CTEImpact" or netName == "CTEWorldDecal" or netName == "CTEDecal" then
            local pos = ent:GetPropVector("m_vecOrigin")
            if pos then
                local shooter = findRecentShooter()
                if shooter and lastBulletImpacts[shooter] then
                    lastBulletImpacts[shooter].impactPos = pos
                end
            end
        end
    end

    -- Pass 2: process new shots (promote now-complete current→prev, create fresh entry)
    for ent, _ in pairs(entEvtTable) do
        local netName = ent:GetNetworkName()
        if netName == "CTEFireBullets" then
            local shooterIndex = ent:GetPropInt("m_iPlayer") + 1
            if shooterIndex > 1 and shooterIndex ~= localplayer:GetIndex() then
                local shooter = entities.GetByIndex(shooterIndex)
                if shooter and shooter:IsAlive() then
                    -- Capture attacker's actual eye position RIGHT NOW (true shot origin)
                    local viewOffset = shooter:GetPropVector("localdata", "m_vecViewOffset[0]") or Vector3(0, 0, 68)
                    local eyePos = shooter:GetAbsOrigin() + viewOffset
                    -- Promote current to prev (now has impactPos from pass 1 or previous batch)
                    if lastBulletImpacts[shooterIndex] then
                        prevBulletImpacts[shooterIndex] = lastBulletImpacts[shooterIndex]
                    end
                    lastBulletImpacts[shooterIndex] = { eyePos = eyePos, time = now }
                    lastShooterIndex = shooterIndex
                    -- Only create new miss-tracking if previous wasn't a recent hit
                    local prev = recentShots[shooterIndex]
                    if not prev or not prev.hit or (now - prev.time) > 0.3 then
                        recentShots[shooterIndex] = { time = now, hit = false }
                    end
                end
            end
        end
    end
end)

-- Periodically flush expired shots as misses — advance enemy resolver cycle
local function flushMissedShots()
    local now = globals.CurTime()
    for idx, shot in pairs(recentShots) do
        if not shot.hit and (now - shot.time) > MISS_WINDOW then
            local shooter = entities.GetByIndex(idx)
            local name    = shooter and shooter:GetName() or "?"

            -- Enemy missed: advance their cycle by 1 step and pick new safe head
            advanceCycleOnMiss(idx)
            local st      = resolverState[idx]
            local segIdx  = st and st.segIndex or 0
            local counter = getCounterOffset(idx)
            local nextSeg = getPredictedNextName(idx)
            print(string.format("[MISS] %s → cycle now seg[%d]:%s → head %d° (next pred: %s)",
                name, segIdx, SEG_NAMES[segIdx] or "?", counter, nextSeg))
            recentShots[idx] = nil
        end
    end
end

local reloadTicks = 0
-- OnTickUpdate
local function OnCreateMove(userCmd)
    local me = WPlayer.GetLocal()
    local pLocal = entities.GetLocalPlayer()
    if not pLocal or not pLocal:IsAlive() or not me then return end
    if gui.GetValue("Anti Aim") == 0 then
        --gui.SetValue("Anti Aim", 1)
    end
    flushMissedShots()
    updateReloadTimes()
    UpdateSniperDots()                                                                      --refreshes lsit of sniper dots

    pLocalOrigin = pLocal:GetAbsOrigin() + vheight; LocalViewAngle = engine.GetViewAngles() --update local viewnangle
    --local LocalViewAngles = pLocal:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")

    -- Constants for yaw settings
    local Real_Yaw = 0
    local Fake_Yaw = 0

    local vVelocity = pLocal:EstimateAbsVelocity()
    if jitterlegEnabled then
        if (userCmd.sidemove == 0) then
            if userCmd.command_number % 2 == 0 then
                userCmd:SetSideMove(33)
            else
                userCmd:SetSideMove(-33)
            end
        elseif (userCmd.forwardmove == 0) then
            if userCmd.command_number % 2 == 0 then
                userCmd:SetForwardMove(3)
            else
                userCmd:SetForwardMove(-3)
            end
        end
    end

    -- Update eye angle history for all visible enemies
    for _, entry in ipairs(targetList) do
        local ep = entry.player
        if ep and not ep:IsDormant() then
            local ea = ep:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
            if ea then updateEyeHistory(ep:GetIndex(), ea) end
        end
    end

    currentTarget = GetBestTarget(me)                                                    --GetClosestTarget(me, me:GetAbsOrigin()) -- Get the best target
    if currentTarget == nil then goto continue end; currentTarget = currentTarget.entity --Check if we have target

    -- Get player and weapon info
    local class = pLocal:GetPropInt("m_iClass"); local pWeapon = me:GetPropEntity("m_hActiveWeapon")
    local currentTargetOrigin = currentTarget:GetAbsOrigin()
    distance1 = (pLocal:GetAbsOrigin() - currentTargetOrigin):Length()

    -- Calculate view information
    pLocalView = pLocal:GetAbsOrigin() + vheight
    local PViewPos = currentTargetOrigin + currentTarget:GetPropVector("localdata", "m_vecViewOffset[0]")
    --print(currentTarget:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]"))
    local viewAngles = currentTarget:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]"):Forward()
    local destination = PViewPos + viewAngles * distance1

    -- Calculate angles and FOV
    local angles = Math.PositionAngles(pLocalView, PViewPos); targetAngle = angles.yaw

    --[--adjust yaw at enemy--]
    local counterOffset = getCounterOffset(currentTarget:GetIndex())
    updateYaw(Angles_Real, counterOffset, userCmd, currentTarget)

    --print(viewAngles.pitch)
    -- Get head position using WPlayer for reliable results across all classes
    Headpos = me:GetHitboxPos(0) -- HITBOX_HEAD = 0
    if not Headpos then
        goto skip_circle
    end

    -- Calculate center at head height
    local centerHorizontal = pLocal:GetAbsOrigin()
    HeadHeightOffset = Vector3(0, 0, Headpos.z - centerHorizontal.z)

    -- Calculate separate x and y offsets from center to head
    local headOffsetX = Headpos.x - centerHorizontal.x
    local headOffsetY = Headpos.y - centerHorizontal.y
    HeadOffsetHorizontal = math.sqrt(headOffsetX * headOffsetX + headOffsetY * headOffsetY)


    -- Circle parameters
    local radius = HeadOffsetHorizontal / 2                 -- Diameter = HeadOffsetHorizontal, so radius = half
    local center = pLocal:GetAbsOrigin() + HeadHeightOffset -- Center at head height

    -- Initialize variables for the closest point
    local closestPoint = nil
    local closestAngleDiff = math.huge

    -- Generate circle vertices
    local vertices = {}
    local yaw_offset = targetAngle -- Replace this with the yaw offset you want to apply, in degrees

    -- process the lasrdots
    Serversite_angle = nil
    for key, dotInfo in pairs(sniperdotspoitions) do
        if dotInfo.Owner == currentTarget:GetName() then
            Serversite_angle = Math.PositionAngles(PViewPos, dotInfo.Position)
            print(Serversite_angle)
        end

        -- dotInfo.Position contains the position
        -- dotInfo.Owner contains the owner's name
        -- Do something with these, for example:
        -- Draw3DBox(9, dotInfo.Position)
        -- print("Owner: " .. dotInfo.Owner)
    end

    if viewAngles.x > 89 or viewAngles.x < -89 then goto continue end -- detect not shooting at us

    --if not gotshot then goto continue end
    local fov = math.abs(Math.AngleFov(viewAngles, angles))
    if fov > 30 then goto continue end                                  --check if aimed at us

    if attackerReloadTimes[currentTarget] ~= nil then goto continue end --skip if target is reloading

    for i = 1, Circle_segments do
        local angle = math.rad(i * (360 / Circle_segments) + yaw_offset)
        local direction = Vector3(math.cos(angle), math.sin(angle), 0)
        local endpos = center + direction * radius
        vertices[i] = { pos = endpos, offset = angle }
    end

    -- Find the closest point on the circle to the enemy's FOV
    for i = 1, Circle_segments do
        local pointInfo = vertices[i]
        local point = pointInfo.pos
        local Pointoffset = pointInfo.offset
        local pointAngle = Math.PositionAngles(PViewPos, point)
        local angleDiff = Math.AngleFov(viewAngles, pointAngle)

        if angleDiff < closestAngleDiff then
            closestPoint = { pos = point, Pointoffset = Pointoffset }
            closestAngleDiff = angleDiff
        end
    end

    if not closestPoint then goto continue end

    local shootingAngle = closestPoint.Pointoffset -- The shooting angle in radians

    -- Convert the angles to degrees for easier manipulation
    --shootingAngle = math.deg(shootingAngle)
    if not shootingAngle then goto continue end

    gotheadshot = false
    updateYaw(Angles_Real, Angles_Fake, userCmd, currentTarget) -- update yaw at enemy with selected offset

    closestPoint1 =
        Headpos --sets the point at headpos to avoid nil errors when not aiming at us
    closestPoint1 = closestPoint.pos
    closestPoint = closestPoint.pos

    ::skip_circle::
    ::continue::
end

-------------------------------VISUALS----------------------------------------------
local corners1
local function Draw3DBox(size, pos)
    local halfSize = size / 2
    if not corners then
        corners1 = {
            Vector3(-halfSize, -halfSize, -halfSize),
            Vector3(halfSize, -halfSize, -halfSize),
            Vector3(halfSize, halfSize, -halfSize),
            Vector3(-halfSize, halfSize, -halfSize),
            Vector3(-halfSize, -halfSize, halfSize),
            Vector3(halfSize, -halfSize, halfSize),
            Vector3(halfSize, halfSize, halfSize),
            Vector3(-halfSize, halfSize, halfSize)
        }
    end

    local linesToDraw = {
        { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
        { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
        { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 }
    }

    local screenPositions = {}
    for _, cornerPos in ipairs(corners1) do
        local worldPos = pos + cornerPos
        local screenPos = client.WorldToScreen(worldPos)
        if screenPos then
            table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
        end
    end

    -- Set color for 3D box
    draw.Color(255, 0, 255, 255) -- Magenta for 3D boxes

    for _, line in ipairs(linesToDraw) do
        local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
        if p1 and p2 then
            draw.Line(p1.x, p1.y, p2.x, p2.y)
        end
    end
end

local myfont = draw.CreateFont("Verdana", 16, 800) -- Create a font for doDraw
local direction = Vector3(0, 0, 0)
local directionReal = Vector3(0, 0, 0)
local function OnDraw()
    paint_logs()
    anim()
    draw.SetFont(myfont)
    draw.Color(255, 255, 255, 255)
    local gameUIVisible = engine.IsGameUIVisible()
    local consoleVisible = engine.Con_IsVisible()
    if gameUIVisible or consoleVisible then
        return
    end


    -- Ensure pLocal is valid and update pLocalView
    pLocal = entities.GetLocalPlayer()
    if not pLocal or not pLocal:IsAlive() then return end

    -- Update pLocalView in OnDraw since it may not be set yet
    pLocalView = pLocal:GetAbsOrigin() + (vheight or Vector3(0, 0, 70))

    -- Recalculate head offset every frame for real-time updates
    -- Use Entity:GetHitboxes() directly since WPlayer.GetLocal() fails in OnDraw
    if not pLocal:IsDormant() then
        local hitboxes = pLocal:GetHitboxes(globals.CurTime())
        if hitboxes then
            -- Probe index 0 first (head on some classes), fall back to 1
            local headBox = hitboxes[0] or hitboxes[1]
            if headBox and headBox[1] and headBox[2] then
                Headpos = (headBox[1] + headBox[2]) * 0.5

                -- Calculate center at head height
                local centerHorizontal = pLocal:GetAbsOrigin()
                HeadHeightOffset = Vector3(0, 0, Headpos.z - centerHorizontal.z)

                -- Calculate separate x and y offsets from center to head
                local headOffsetX = Headpos.x - centerHorizontal.x
                local headOffsetY = Headpos.y - centerHorizontal.y
                HeadOffsetHorizontal = math.sqrt(headOffsetX * headOffsetX + headOffsetY * headOffsetY)
            else
                -- Try to find any valid hitbox as fallback
                for index, hbox in pairs(hitboxes) do
                    if hbox and hbox[1] and hbox[2] then
                        Headpos = (hbox[1] + hbox[2]) * 0.5
                        local centerHorizontal = pLocal:GetAbsOrigin()
                        HeadHeightOffset = Vector3(0, 0, Headpos.z - centerHorizontal.z)
                        local headOffsetX = Headpos.x - centerHorizontal.x
                        local headOffsetY = Headpos.y - centerHorizontal.y
                        HeadOffsetHorizontal = math.sqrt(headOffsetX * headOffsetX + headOffsetY * headOffsetY)
                        break
                    end
                end
            end
        end
    end

    local yaw

    if targetAngle ~= nil then
        yaw = targetAngle + Angles_Real + fluctuation

        if targetAngle then
            direction = Vector3(math.cos(math.rad(yaw)), math.sin(math.rad(yaw)), 0)
        end
    else
        yaw = gui.GetValue("Anti Aim - Custom Yaw (Real)")

        if targetAngle then
            direction = Vector3(math.cos(math.rad(yaw)), math.sin(math.rad(yaw)), 0)
        end
    end

    -- Use head position for line drawing instead of feet
    local center = pLocal:GetAbsOrigin() + (HeadHeightOffset or Vector3(0, 0, 0))
    local range = 50 --mmIndicator:GetValue()     -- Adjust the range of the line as needed

    -- Get yaw for real angle
    if targetAngle ~= nil then
        yaw = targetAngle + Angles_Real + fluctuation
    else
        yaw = gui.GetValue("Anti Aim - Custom Yaw (Real)")
    end

    -- Real
    -- Change color when defensive AA is active
    if defensiveAAEnabled then
        draw.Color(255, 255, 0, 255) -- Yellow for defensive AA
    else
        draw.Color(81, 255, 54, 255) -- Green for normal AA
    end
    local screenPos = client.WorldToScreen(center)
    if screenPos ~= nil then
        direction = Vector3(math.cos(math.rad(yaw)), math.sin(math.rad(yaw)), 0)
        directionReal = direction
        local endPoint = center + direction * range
        local screenPos1 = client.WorldToScreen(endPoint)
        if screenPos1 ~= nil then
            draw.Line(screenPos[1], screenPos[2], screenPos1[1], screenPos1[2])
        end
    end

    -- Get yaw for fake angle
    if targetAngle ~= nil then
        yaw = targetAngle + Angles_Fake + fluctuation
    else
        yaw = gui.GetValue("Anti Aim - Custom Yaw (Fake)")
    end

    -- fake
    draw.Color(255, 0, 0, 255)
    screenPos = client.WorldToScreen(center)
    if screenPos ~= nil then
        direction = Vector3(math.cos(math.rad(yaw)), math.sin(math.rad(yaw)), 0)
        local endPoint = center + direction * range
        local screenPos1 = client.WorldToScreen(endPoint)
        if screenPos1 ~= nil then
            draw.Line(screenPos[1], screenPos[2], screenPos1[1], screenPos1[2])
        end
    end

    local circleRadius = HeadOffsetHorizontal or 10
    local circleCenter = pLocal:GetAbsOrigin() + (HeadHeightOffset or Vector3(0, 0, 0))

    local colors = {
        { 255, 0,   255, 255 }, -- Magenta: best target
        { 0,   255, 255, 255 }, -- Cyan: 2nd
        { 255, 255, 0,   255 }, -- Yellow: 3rd
        { 0,   255, 0,   255 }, -- Green: 4th
        { 255, 128, 0,   255 }, -- Orange: 5th+
    }

    -- Check if any of the 4 circle segment points can see the enemy's view pos
    -- Uses pattern like Helpers.VisPos: trace.entity == target or trace.fraction > 0.99
    local function isVisibleViaCircle(enemy, enemyViewPos, yawOffset)
        for j = 1, Circle_segments do
            local angle = math.rad(j * (360 / Circle_segments) + yawOffset)
            local dir = Vector3(math.cos(angle), math.sin(angle), 0)
            local point = circleCenter + dir * circleRadius
            local trace = engine.TraceLine(point, enemyViewPos, MASK_SHOT | CONTENTS_GRATE, function(ent, _)
                if not ent then return false end
                if ent == pLocal then return false end
                if ent == enemy then return true end
                return false
            end)
            if trace.entity == enemy or trace.fraction > 0.99 then
                return true
            end
        end
        return false
    end

    for rank, entry in ipairs(targetList) do
        local player = entry.player
        if not player or not player:IsValid() then goto next_entry end
        if player:IsDormant() then goto next_entry end

        local playerViewOffset = player:GetPropVector("localdata", "m_vecViewOffset[0]")
        local enemyViewPos = player:GetAbsOrigin() + (playerViewOffset or Vector3(0, 0, 75))

        -- Angle to enemy's view position (anchor)
        local angleToEnemy = Math.PositionAngles(pLocalView, enemyViewPos)
        local enemyYawOffset = angleToEnemy.yaw

        -- Always draw best target (rank 1); others only if visible via circle points
        local visible = (rank == 1) or isVisibleViaCircle(player, enemyViewPos, enemyYawOffset)
        if not visible then goto next_entry end

        local col          = colors[math.min(rank, #colors)] or { 255, 255, 255, 255 }

        -- Resolver state for this enemy (to color danger/safe segments)
        local pIdx         = player:GetIndex()
        local rState       = resolverState[pIdx]
        local dangerSeg    = rState and rState.segIndex or -1        -- last segment enemy aimed at
        local safeHead     = rState and rState.lastCounterHead or 90 -- our chosen head offset (relative to us)

        -- Convert our head offset (relative to attacker direction) to segment index
        -- safeHead is degrees relative to target direction; enemyYawOffset is world yaw toward enemy
        -- So our head world yaw = enemyYawOffset + 180 + safeHead (we face enemy, +180 = away from enemy)
        -- Segment index = round((safeHead % 360) / 45)
        local safeHeadNorm = safeHead % 360
        local safeSegIdx   = math.floor(safeHeadNorm / SEG_STEP + 0.5) % NUM_SEGS

        local verts        = {}
        for j = 0, NUM_SEGS - 1 do
            -- Segment j is at angle: enemyYawOffset (toward enemy from us) + j*45°
            -- j=0 = segment pointing toward enemy (forward/dangerous)
            local angle = math.rad(enemyYawOffset + j * SEG_STEP)
            local dir   = Vector3(math.cos(angle), math.sin(angle), 0)
            verts[j]    = client.WorldToScreen(circleCenter + dir * circleRadius)
        end

        -- Draw polygon edges: flash red for 1s after headshot, else base target color
        local hsAge = globals.RealTime() - headshotFlashTime
        if hsAge < 1.0 then
            local fade = math.floor(255 * (1.0 - hsAge))
            draw.Color(255, 0, 0, fade)
        else
            draw.Color(col[1] or 255, col[2] or 255, col[3] or 255, col[4] or 255)
        end
        for j = 0, NUM_SEGS - 1 do
            local k = (j + 1) % NUM_SEGS
            if verts[j] and verts[k] then
                draw.Line(verts[j][1], verts[j][2], verts[k][1], verts[k][2])
            end
        end

        -- Prediction dots: current seg + next 3 steps the enemy will cycle through
        -- Red=current, Orange=+1(likely next), Yellow=+2(skip), DimOrange=+3(far)
        local predColors = {
            [0] = { 255, 50, 50, 255 }, -- red:        current danger
            [1] = { 255, 140, 0, 255 }, -- orange:     +1 (normal advance)
            [2] = { 255, 220, 0, 220 }, -- yellow:     +2 (skip)
            [3] = { 180, 100, 0, 160 }, -- dim orange: +3 (double skip)
        }
        local predSegs = {}
        if dangerSeg >= 0 then
            for step = 0, 3 do
                predSegs[(dangerSeg + step) % NUM_SEGS] = step
            end
        end

        local DOT_SIZE = 4
        for j = 0, NUM_SEGS - 1 do
            local v = verts[j]
            if v then
                local step = predSegs[j]
                if step ~= nil then
                    local pc = predColors[step]
                    draw.Color(pc[1], pc[2], pc[3], pc[4])
                elseif j == safeSegIdx then
                    draw.Color(50, 255, 50, 255)   -- green: our safe head
                else
                    draw.Color(200, 200, 200, 180) -- grey: neutral
                end
                draw.FilledRect(v[1] - DOT_SIZE, v[2] - DOT_SIZE, v[1] + DOT_SIZE, v[2] + DOT_SIZE)
            end
        end

        -- Label predicted segs at their circle corner positions
        if menuDebug and rState then
            draw.SetFont(font_calibri)
            draw.Color(255, 255, 255, 255) -- Ensure color is set after font change
            for j = 0, NUM_SEGS - 1 do
                local v = verts[j]
                if v then
                    local step = predSegs[j]
                    if step ~= nil then
                        local pc    = predColors[step]
                        local label = (step == 0 and "!" or "+" .. step) .. (SEG_NAMES[j] or "?")
                        draw.Color(pc[1], pc[2], pc[3], 255)
                        draw.Text(v[1] + 6, v[2] - 7, label)
                    elseif j == safeSegIdx then
                        draw.Color(50, 255, 50, 255)
                        draw.Text(v[1] + 6, v[2] - 7, "safe")
                    end
                end
            end
        end

        ::next_entry::
    end

    --[viewlines]
    --draw assumed head pos
    if closestPoint1 then
        screenPos = client.WorldToScreen(closestPoint1)
        draw.Color(255, 0, 255, 255)
        Draw3DBox(9, closestPoint1)
    end

    for key, Dot in pairs(sniperdotspoitions) do
        Draw3DBox(9, Dot.Position)

        -- Draw 2D square on screen at sniper dot position
        local dotScreenPos = client.WorldToScreen(Dot.Position)
        if dotScreenPos then
            local size = 10
            draw.Color(255, 0, 255, 255) -- Magenta
            draw.Line(dotScreenPos[1] - size, dotScreenPos[2] - size, dotScreenPos[1] + size, dotScreenPos[2] - size)
            draw.Line(dotScreenPos[1] + size, dotScreenPos[2] - size, dotScreenPos[1] + size, dotScreenPos[2] + size)
            draw.Line(dotScreenPos[1] + size, dotScreenPos[2] + size, dotScreenPos[1] - size, dotScreenPos[2] + size)
            draw.Line(dotScreenPos[1] - size, dotScreenPos[2] + size, dotScreenPos[1] - size, dotScreenPos[2] - size)
        end
    end

    --[[if screenPos ~= nil then
                 draw.Line( screenPos[1] + 10, screenPos[2], screenPos[1] - 10, screenPos[2])
                 draw.Line( screenPos[1], screenPos[2] - 10, screenPos[1], screenPos[2] + 10)
             end]]

    --local rockets = entities.FindByClass("CTFProjectile_Rocket") -- Find all rockets

    if not currentTarget or not currentTarget:IsAlive() or currentTarget:IsDormant() or pLocal:GetIndex() == currentTarget:GetIndex() then goto continue end

    local PViewPos = currentTarget:GetAbsOrigin() + currentTarget:GetPropVector("localdata", "m_vecViewOffset[0]")
    local viewAngles = currentTarget:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]"):Forward()
    if Serversite_angle then
        viewAngles = Serversite_angle:Forward()
        print(viewAngles)
    end

    if viewAngles and PViewPos then
        local destination = PViewPos + viewAngles * distance1

        local startScreenPos = client.WorldToScreen(PViewPos)
        local endScreenPos = client.WorldToScreen(destination)

        if startScreenPos ~= nil and endScreenPos ~= nil then
            draw.Color(255, 255, 255, 255)
            draw.Line(startScreenPos[1], startScreenPos[2], endScreenPos[1], endScreenPos[2])
        end
    end

    ::continue::
end

--[[ Remove the menu when unloaded ]]
--
local function OnUnload()                                -- Called when the script is unloaded
    client.Command('play "ui/buttonclickrelease"', true) -- Play the "buttonclickrelease" sound
end

callbacks.Unregister("CreateMove", "CreateMoveAA")
callbacks.Unregister("Unload", "UnloadAA") -- Unregister the "Unload" callback
callbacks.Unregister("Draw", "DrawAA")
callbacks.Unregister("Draw", "MenuAA")

callbacks.Register("CreateMove", "CreateMoveAA", OnCreateMove)
callbacks.Register("Unload", "UnloadAA", OnUnload) -- Register the "Unload" callback
callbacks.Register("Draw", "DrawAA", OnDraw)
callbacks.Register("Draw", "MenuAA", OnDraw_Menu)

client.Command('play "ui/buttonclickrelease"', true) -- Play the "buttonclickrelease" sound
