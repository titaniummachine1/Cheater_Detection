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
local tick_count          = 0
local pitch               = 0
local targetAngle         = 0
local yaw_real            = nil
local yaw_Fake            = nil
local offset              = 0
local Angles_Real         = 0
local Angles_Fake         = 0
local pitchtype1          = gui.GetValue("Anti Aim - Pitch")
local players             = entities.FindByClass("CTFPlayer")
local pLocalView          = Vector3()
local closestPoint1
local HeadOffsetHorizontal
local HeadHeightOffset    = Vector3(0, 0, 0)
local Headpos             = Vector3(0, 0, 0)
local Circle_segments     = 4
local LocalViewAngle      = engine.GetViewAngles()
local vheight             = Vector3(0, 0, 70)
local distance1           = 0
local gotshot             = false
local Latency             = 0
local timershootdelay
local tickRate            = client.GetConVar("sv_maxcmdrate")
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
local lastHitDirection = nil   -- Track which direction we got hit from
local fluctuation = 0

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
            gui.SetValue("Anti Aim - Custom Yaw (Real)", math.floor(defRealOffset))
            gui.SetValue("Anti Aim - Custom Yaw (Fake)", math.floor(defFakeOffset))
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

        -- Fake angle - 180 offset from target
        local fakeYaw = localTargetAngle + 180
        if fakeYaw > 180 then fakeYaw = fakeYaw - 360 end
        if fakeYaw < -180 then fakeYaw = fakeYaw + 360 end
        fakeYaw = math.floor(fakeYaw)
        gui.SetValue("Anti Aim - Custom Yaw (Fake)", fakeYaw)

        -- Real angle - points at target
        local realYaw = localTargetAngle
        if realYaw > 180 then realYaw = realYaw - 360 end
        if realYaw < -180 then realYaw = realYaw + 360 end
        realYaw = math.floor(realYaw)
        gui.SetValue("Anti Aim - Custom Yaw (Real)", realYaw)
        return
    end

    if fluctuation == 0 then
        fluctuation = 180
    else
        fluctuation = 0
    end

    -- Calculate the real yaw based on target angle, offset and local yaw
    local realYaw = (targetAngle - LocalYaw) + Real_offset + fluctuation

    realYaw = math.floor(realYaw)
    -- Normalize real yaw
    realYaw = normalizeAngle(realYaw)
    --todo add second dirction to negative check

    -- Update the GUI value for real yaw
    gui.SetValue("Anti Aim - Custom Yaw (Real)", realYaw)

    -- Calculate the fake yaw based on target angle, offset and local yaw
    local fakeYaw = (targetAngle - LocalYaw) + Fake_offset + fluctuation
    fakeYaw = math.floor(fakeYaw)

    -- Normalize fake yaw
    fakeYaw = normalizeAngle(fakeYaw)

    -- Update the GUI value for fake yaw
    gui.SetValue("Anti Aim - Custom Yaw (Fake)", fakeYaw)
end

local sniperdotspoitions = {}

local function UpdateSniperDots()
    local SniperDots = entities.FindByClass("CTFSniperDot")
    sniperdotspoitions = {} -- Clear previous positions

    for key, SniperDot in pairs(SniperDots) do
        local position = SniperDot:GetAbsOrigin()
        local owner = SniperDot:GetPropEntity("m_hOwnerEntity"):GetName() -- Replace with correct function if this is not it
        sniperdotspoitions[key] = { Position = position, Owner = owner }
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

local function event_hook(ev)
    if ev:GetName() ~= "player_hurt" then return end
    if not currentTarget then return end

    local victim_entity = entities.GetByUserID(ev:GetInt("userid"))
    local attacker = entities.GetByUserID(ev:GetInt("attacker"))
    local localplayer = entities.GetLocalPlayer()
    local damage = ev:GetInt("damageamount")

    if victim_entity ~= localplayer then return end
    gotshot = true

    local attackerIndex = attacker:GetIndex()

    addNewAttackerByIndex(attackerIndex)


    if damage > 50 then
        gotheadshot = true

        -- Track hit direction based on our current angles
        if Angles_Real ~= 0 then
            if Angles_Real < -45 then
                lastHitDirection = "left"
            elseif Angles_Real > 45 then
                lastHitDirection = "right"
            elseif math.abs(Angles_Real) > 135 then
                lastHitDirection = "back"
            else
                lastHitDirection = "default"
            end
            print("[Defensive AA] Hit from direction: " .. lastHitDirection .. " (Real angle: " .. Angles_Real .. ")")
        end
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
    for i, v in pairs(queue) do
        local alpha = floor(v.alpha)
        local text = v.string
        local y_pos = floor(y / 2) + (i * 20)
        players = entities.FindByClass("CTFPlayer")
        --for players
        --local enemypos =
        draw.Color(255, 255, 255, alpha)
        draw.Text(700, y_pos - 100, text)
    end
end

local function anim()
    for i, v in pairs(queue) do
        if globals.RealTime() < v.delay then                             --checks if delay is over or not
            v.alpha = math.min(v.alpha + 1, 255)                         --fade in animation
        else
            v.string = string.sub(v.string, 1, string.len(v.string) - 1) --removes last character
            if 0 >= string.len(v.string) then
                table.remove(queue, i)                                   --if theres no text left, remove the table
            end
        end
    end
end
callbacks.Register("FireGameEvent", "unique_event_hook", event_hook)

local reloadTicks = 0
-- OnTickUpdate
local function OnCreateMove(userCmd)
    local me = WPlayer.GetLocal()
    local pLocal = entities.GetLocalPlayer()
    if not pLocal or not pLocal:IsAlive() or not me then return end
    if gui.GetValue("Anti Aim") == 0 then
        --gui.SetValue("Anti Aim", 1)
    end
    updateReloadTimes()
    UpdateSniperDots()                                                                      --refreshes lsit of sniper dots

    pLocalOrigin = pLocal:GetAbsOrigin() + vheight; LocalViewAngle = engine.GetViewAngles() --update local viewnangle
    --local LocalViewAngles = pLocal:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")

    -- Constants for yaw settings
    local Real_Yaw = 0
    local Fake_Yaw = 0

    local vVelocity = pLocal:EstimateAbsVelocity()
    -- Jitterleg disabled - causing bot movement issues
    --[[if (userCmd.sidemove == 0) then             -- Check if we not currently moving
        if userCmd.command_number % 2 == 0 then -- Check if the command number is even. (Potentially inconsistent, but it works).
            userCmd:SetSideMove(33)
        else
            userCmd:SetSideMove(-33)
        end
    elseif (userCmd.forwardmove == 0) then
        if userCmd.command_number % 2 == 0 then -- Check if the command number is even. (Potentially inconsistent, but it works).
            userCmd:SetForwardMove(3)
        else
            userCmd:SetForwardMove(-3)
        end
    end]]

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
    --Angles_Real = Real_Yaw; Angles_Fake = Fake_Yaw
    updateYaw(Angles_Real, Angles_Fake, userCmd, currentTarget) -- update yaw at enemy with selected offset

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

    print("[Debug] Headpos: " ..
        tostring(Headpos) ..
        " HeadOffsetHorizontal: " .. HeadOffsetHorizontal .. " HeadHeightOffset: " .. tostring(HeadHeightOffset))

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
    if engine.IsGameUIVisible() or engine.Con_IsVisible() then
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
        draw.Text(0, 0, tostring(offsetNumber)) --debug

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

        local col = colors[math.min(rank, #colors)]
        draw.Color(col[1], col[2], col[3], col[4])

        local verts = {}
        for j = 1, Circle_segments do
            local angle = math.rad(j * (360 / Circle_segments) + enemyYawOffset)
            local dir = Vector3(math.cos(angle), math.sin(angle), 0)
            verts[j] = client.WorldToScreen(circleCenter + dir * circleRadius)
        end

        for j = 1, Circle_segments do
            local k = (j % Circle_segments) + 1
            if verts[j] and verts[k] then
                draw.Line(verts[j][1], verts[j][2], verts[k][1], verts[k][2])
            end
        end

        -- Calculate which segment this enemy is targeting on our circle
        local enemyViewAngles = player:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
        if enemyViewAngles then
            local enemyForward = enemyViewAngles:Forward()
            local closestSegment = nil
            local closestAngleDiff = math.huge

            for j = 1, Circle_segments do
                local angle = math.rad(j * (360 / Circle_segments) + enemyYawOffset)
                local dir = Vector3(math.cos(angle), math.sin(angle), 0)
                local point = circleCenter + dir * circleRadius
                local pointAngle = Math.PositionAngles(enemyViewPos, point)
                local angleDiff = Math.AngleFov(enemyForward, pointAngle)
                if angleDiff < closestAngleDiff then
                    closestSegment = j
                    closestAngleDiff = angleDiff
                end
            end

            if closestSegment then
                print(string.format("[Circle] Rank %d %s: Segment %d (diff %.2f)",
                    rank, player:GetName() or "?", closestSegment, closestAngleDiff))
            end
        end

        ::next_entry::
    end

    --[viewlines]
    --draw assumed head pos
    if closestPoint1 then
        screenPos = client.WorldToScreen(closestPoint1)
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
