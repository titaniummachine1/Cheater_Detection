--credit to https://github.com/daily3014/lbox/blob/main/resolver.lua
--script have been fixed to auto cycle the angles and uses only 3 main ones offsets from direct direction at you
---@type boolean, LNXlib
local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
assert(Lib.GetVersion() >= 1, "LNXlib version is too old, please update it!")

-- Import utility functions
Math = Lib.Utils.Math
Conversion = Lib.Utils.Conversion
Input = Lib.Utils.Input
Commands = Lib.Utils.Commands
Timer = Lib.Utils.Timer
Conversion = Lib.Utils.Conversion

local config = {
    onlyHeadshots = true,
    maxMisses = 0,
    minPriority = 0,
    cycleYawFOV = 360, -- FOV to use when cycling the yaw through keybind

    yawCycle = {
        "default", -- raw network angle unchanged
        -90,       -- 'left'  (head appears on left side of target)
        90,        -- 'right' (head appears on right side of target)
        "invert",  -- raw network angle + 180
        0,         -- 'forward' (head toward us)
        180,       -- 'back'    (head away from us)
    }
}

local lastHits = {}
local usesAntiAim = {}
local lastConsecutiveShots = {}
local customAngleData = {}
local awaitingConfirmation = {}
local misses = {}
local headshotWeapons = { [17] = true, [43] = true }
local cycleKeyState = false
local plocal = entities.GetLocalPlayer()

local M_RADPI = 180 / math.pi

local function isNaN(x) return x ~= x end

local function getBool(event, name)
    local bool = event:GetInt(name)
    return bool == 1
end

local function getSteamID(player)
    local playerInfo = client.GetPlayerInfo(player:GetIndex())
    return playerInfo.SteamID
end

local function getMinimumLatency(trueLatency)
    local latency = clientstate.GetLatencyIn() + clientstate.GetLatencyOut()
    if trueLatency == true then return latency end
    return latency <= 0.1 and 0.1 or latency
end

local function setupPlayerAngleData(player)
    local steamID = getSteamID(player)

    if customAngleData[steamID] then
        return
    end

    customAngleData[steamID] = {
        plr = player,
        yawCycleIndex = 1,
        lastYaw = 0,
    }
end

local function isLmaoboxKeybindDown(name)
    if gui.GetValue(name) == 0 then
        return false
    end
    return input.IsButtonDown(gui.GetValue(name))
end

local function resolvePitch(pitch)
    if pitch % 90 == 0 then -- lmaobox fake pitch (up & down)
        return -pitch
    end

    if pitch % 3256 == 0 then -- lmaobox fake pitch (center)
        return 0
    end

    if pitch % 271 == 0 then -- rijin fake pitch? (no idea)
        return pitch / 271 * 89
    end

    return pitch
end

local function isUsingAntiAim(pitch)
    if pitch > 89.4 or pitch < -89.4 then
        return true
    end

    return false
end

local function normalizeAngle(offsetNumber)
    offsetNumber = offsetNumber % 360
    if offsetNumber > 180 then
        offsetNumber = offsetNumber - 360
    elseif offsetNumber < -180 then
        offsetNumber = offsetNumber + 360
    end
    return offsetNumber
end

local function lookAt(from, to, offset)
    offset = offset or 0
    if not from or not to then return end

    local delta = vector.Subtract(to, from)
    local yaw = math.atan(delta.y, delta.x) * 180 / math.pi

    yaw = yaw + offset
    yaw = normalizeAngle(yaw)

    if isNaN(yaw) then yaw = 0 end

    return yaw
end

local function getYaw(currentYaw, data)
    local entry = config.yawCycle[math.floor(data.yawCycleIndex)]
    if type(entry) == "string" then
        if entry == "invert" then return normalizeAngle(currentYaw + 180) end
        return currentYaw -- "default"
    end
    local enemyPosition = data.plr:GetAbsOrigin()
    local localPlayerPosition = entities.GetLocalPlayer():GetAbsOrigin()
    return lookAt(enemyPosition, localPlayerPosition, entry)
end

local yawLabels = {
    [-90] = "Left",  -- left = -90
    [90]  = "Right", -- right = 90
    [0]   = "Forward",
    [180] = "Back",
}

local function getYawText(data)
    local entry = config.yawCycle[math.floor(data.yawCycleIndex)]
    if not entry then return "" end
    if type(entry) == "string" then return entry end
    return yawLabels[entry] or (entry .. "°")
end

local function announceResolve(data, label)
    local name = client.GetPlayerInfo(data.plr:GetIndex()).Name
    local yaw = getYawText(data)
    if yaw == "" then return end
    local msg = label or ("Cycling to " .. yaw)

    data.lastYaw = yaw
    client.ChatPrintf(string.format("\x073475c9[Resolver] \x01%s \x073475c9'%s'\x01 → \x07f22929%s",
        msg, name, yaw))
    print(string.format("[Resolver] %s '%s' → %s", msg, name, yaw))
end

local function announceMiss(player)
    local name, steamID = client.GetPlayerInfo(player:GetIndex()).Name, getSteamID(player)
    client.ChatPrintf(string.format(
        "\x073475c9[Resolver] \x01Missed player \x073475c9'%s'\x01. Shots remaining: \x07f22929%s", name,
        4 - (misses[steamID] or 1)))
end

local function cycleYaw(data, step, label)
    data.yawCycleIndex = data.yawCycleIndex + (step or 1)

    if data.yawCycleIndex > #config.yawCycle then
        data.yawCycleIndex = 1
    elseif data.yawCycleIndex < 1 then
        data.yawCycleIndex = #config.yawCycle
    end

    announceResolve(data, label)
end

local LastAttackTick = 0
local AttackHappened = false

function GetLastAttackTime(cmd, weapon)
    local TickCount = globals.TickCount()
    local NextAttackTime = Conversion.Time_to_Ticks(weapon:GetPropFloat("m_flLastFireTime") or 0)
    --return (nextPrimaryAttack <= G.CurTime()) and (nextAttack <= G.CurTime())
    if AttackHappened == false and NextAttackTime >= TickCount then
        LastAttackTick = TickCount
        --print(LastAttackTick)
        AttackHappened = true
        return LastAttackTick, AttackHappened
    elseif NextAttackTime < TickCount and AttackHappened == true then
        AttackHappened = false
    end
    return LastAttackTick, false
end

--[[local lastAmmoCount = 0
local hasAttacked = false
local attackCounter = 0

-- Check if the local player has fired their weapon
local function hasLocalPlayerFired(cmd)
	local weapon = plocal:GetPropEntity("m_hActiveWeapon")
	local ammoTable = plocal:GetPropDataTableInt("localdata", "m_iAmmo")
	local lastAttackTick, attacked = GetLastAttackTime(cmd, weapon)

	if lastAttackTick == tick_count then
		-- Check if ammo has decreased
		local currentAmmo = ammoTable[2]
		if currentAmmo < lastAmmoCount then
			hasAttacked = true
		else
			hasAttacked = false
		end

		-- Check if attack button was pressed
		if cmd:GetButtons() & IN_ATTACK == 1 then
			hasAttacked = true
		end

		-- Check if player has attacked
		if hasAttacked and attackCounter >= 66 then
			attackCounter = 0  -- Reset the counter
			return true
		end
	end

	lastAmmoCount = currentAmmo
	attackCounter = attackCounter + 1  -- Increment the counter
end]]

local pendingShot = false
local lastShotTime = nil
local shotCount = 0

local function hasLocalPlayerFired(cmd)
    if pendingShot then
        pendingShot = false
        return "muzzle"
    end
    return false
end

-- Check if the player is trying to shoot
local function isTryingToShoot(cmd)
    if gui.GetValue("aim position") == "body" then
        return false
    end

    if gui.GetValue("aim bot") then
        local keyMode = gui.GetValue("aim key mode")

        if keyMode == "press-to-toggle" then
            return true
        elseif keyMode == "hold-to-use" then
            local aimKeyDown = input.IsButtonDown(gui.GetValue("aim key"))
            if aimKeyDown then
                return true
            end
        else
            return true -- automatic aim mode
        end
    end

    return false
end

local function isValidWeapon(weapon)
    if not weapon then return false end
    if not weapon:IsWeapon() then return false end
    if not weapon:IsShootingWeapon() then return false end

    return true
end

local function getHitboxPos(entity, hitboxID)
    local hitbox = entity:GetHitboxes()[hitboxID]
    if not hitbox then return nil end

    return (hitbox[1] + hitbox[2]) * 0.5
end

local function positionAngles(source, dest)
    local delta = source - dest

    local pitch = math.atan(delta.z / delta:Length2D()) * M_RADPI
    local yaw = math.atan(delta.y / delta.x) * M_RADPI

    if delta.x >= 0 then
        yaw = (yaw + 180) % 360
    end

    if isNaN(pitch) then pitch = 0 end
    if isNaN(yaw) then yaw = 0 end

    return EulerAngles(pitch, yaw, 0)
end

local function angleFov(vFrom, vTo)
    local vSrc = vFrom:Forward()
    local vDst = vTo:Forward()

    local fov = math.deg(math.acos(vDst:Dot(vSrc) / vDst:LengthSqr()))
    if isNaN(fov) then fov = 0 end

    return fov
end

local function getEyePos(player)
    return player:GetAbsOrigin() + player:GetPropVector("localdata", "m_vecViewOffset[0]")
end

local function getEyeAngles(player)
    local angles = player:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
    return EulerAngles(angles.x, angles.y, angles.z)
end

local function checkForFakePitch(player, steamID)
    local angles = getEyeAngles(player)

    if isUsingAntiAim(angles.pitch) then
        if not usesAntiAim[steamID] then
            usesAntiAim[steamID] = true
        end

        setupPlayerAngleData(player)
    end
end

local function getBestTarget(customFOV)
    local localPlayer = entities.GetLocalPlayer()
    local players = entities.FindByClass("CTFPlayer")
    local target = nil
    local lastFov = math.huge

    for _, entity in pairs(players) do
        if not entity then goto continue end
        if not entity:IsAlive() then goto continue end
        if entity:GetTeamNumber() == localPlayer:GetTeamNumber() then goto continue end

        local player = entity
        local aimPos = getHitboxPos(player, 1)
        local angles = positionAngles(getEyePos(localPlayer), aimPos)
        local fov = angleFov(angles, engine.GetViewAngles())
        if fov > (customFOV or gui.GetValue("aim fov")) then goto continue end

        if fov < lastFov then
            lastFov = fov
            target = { entity = entity, pos = aimPos, angles = angles, factor = fov }
        end

        ::continue::
    end

    return target
end

-- Returns method string ("ammo", "button", "consecutive") or false
local function playerShot(cmd, player)
    if not player then player = entities.GetLocalPlayer() end

    local weapon = player:GetPropEntity("m_hActiveWeapon")
    if not isValidWeapon(weapon) then return false end

    local method = hasLocalPlayerFired(cmd)
    if method then
        return method
    end

    if not isTryingToShoot(cmd) then return false end

    local id = weapon:GetWeaponID()
    if config.onlyHeadshots and not headshotWeapons[id] then return false end

    local shots = weapon:GetPropInt("m_iConsecutiveShots")

    if not lastConsecutiveShots[id] then
        lastConsecutiveShots[id] = shots
    end

    if shots ~= 0 then
        if lastConsecutiveShots[id] < shots then
            local oldShots = lastConsecutiveShots[id]
            lastConsecutiveShots[id] = shots
            print(string.format("[Resolver DEBUG] Shot detected via: consecutiveShots (%d -> %d)",
                oldShots, shots))
            return "consecutive"
        end

        return false
    else
        lastConsecutiveShots[id] = 0
    end

    return false
end

local playerSniperDots = {}

local function UpdateSniperDots()
    local SniperDots = entities.FindByClass("CSniperDot")
    playerSniperDots = {} -- Clear previous data

    for _, SniperDot in pairs(SniperDots) do
        local position = SniperDot:GetAbsOrigin()
        local ownerIndex = SniperDot:GetPropEntity("m_hOwnerEntity"):GetIndex()

        -- Store the sniper dot position for each player
        playerSniperDots[ownerIndex] = SniperDot
    end
end

-- Function to check if a player has a sniper dot
local function HasSniperDot(playerIndex)
    return playerSniperDots[playerIndex] ~= nil
end

local function propUpdate()
    local localPlayer = entities.GetLocalPlayer()
    local players = entities.FindByClass("CTFPlayer")
    UpdateSniperDots()

    for idx, player in pairs(players) do
        if idx == localPlayer:GetIndex() then goto continue end
        if player:IsDormant() or not player:IsAlive() then goto continue end

        if playerlist.GetPriority(player) >= config.minPriority then
            setupPlayerAngleData(player)
        end

        local steamID = getSteamID(player)
        local networkAngle = player:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
        local customAngle = Vector3(networkAngle.x, networkAngle.y, networkAngle.z)

        if isUsingAntiAim(networkAngle.x) then
            if not usesAntiAim[steamID] then
                usesAntiAim[steamID] = true
            end

            setupPlayerAngleData(player)
        end

        if customAngleData[steamID] and networkAngle and networkAngle.y then
            customAngle.y = getYaw(networkAngle.y, customAngleData[steamID])
            customAngle.x = resolvePitch(networkAngle.x)

            player:SetPropVector(customAngle, "tfnonlocaldata", "m_angEyeAngles[0]");
        end

        if HasSniperDot(idx) == true then
            local Dot = playerSniperDots[idx]
            local DotPosition = Dot:GetAbsOrigin()
            local viewpos = getEyePos(player)

            local DotAngle = positionAngles(viewpos, DotPosition)
            player:SetPropVector(Vector3(DotAngle.pitch, DotAngle.yaw, 0), "tfnonlocaldata", "m_angEyeAngles[0]");
        end

        ::continue::
    end
end

-- Returns if the weapon can shoot
---@param weapon Entity
---@return boolean
local function CanShoot(weapon)
    local lPlayer = entities.GetLocalPlayer()
    if not lPlayer or weapon:IsMeleeWeapon() then return false end

    local nextPrimaryAttack = weapon:GetPropFloat("LocalActiveWeaponData", "m_flNextPrimaryAttack")
    local nextAttack = lPlayer:GetPropFloat("bcc_localdata", "m_flNextAttack")
    if (not nextPrimaryAttack) or (not nextAttack) then return false end

    return (nextPrimaryAttack <= globals.CurTime()) and (nextAttack <= globals.CurTime())
end

local lastCanShoot = true
local lastScoped = false
local lastsequence

local function hasPendingConfirmation()
    for _ in pairs(awaitingConfirmation) do
        return true
    end
    return false
end

local function checkForCycleYawKeybind()
    if hasPendingConfirmation() then
        return -- auto resolver is handling a shot, don't interfere
    end

    local keyDown = isLmaoboxKeybindDown("toggle yaw key")
    plocal = entities.GetLocalPlayer()
    if not plocal then return end

    local weapon = plocal:GetPropEntity("m_hActiveWeapon")
    if not weapon then return end

    local canShoot = CanShoot(weapon)
    local scoping = plocal:InCond(1)
    local currentSequence = plocal:GetPropInt("m_nSequence")

    -- Check if the keybind is pressed or if there's a transition from being able to shoot to not being able to shoot
    -- And ensure that scoping state did not change simultaneously
    if (cycleKeyState ~= keyDown and keyDown == true) or (lastCanShoot and not canShoot and lastScoped == scoping and scoping == true) then
        local victimInfo = getBestTarget(config.cycleYawFOV)

        if victimInfo then
            local victim = victimInfo.entity
            if not customAngleData[getSteamID(victim)] then
                setupPlayerAngleData(victim)
            end

            engine.PlaySound("ui/panel_close.wav")
            cycleYaw(customAngleData[getSteamID(victim)], 1)
        end
    end

    cycleKeyState = keyDown
    lastCanShoot = canShoot
    lastScoped = scoping
end




local function processConfirmation(steamID, data)
    if data.wasHit then
        awaitingConfirmation[steamID] = nil
        return
    end

    if data.cycled then
        -- Already cycled on timeout; give crit event extra time to arrive, then cleanup
        if globals.TickCount() >= data.cleanupTick then
            awaitingConfirmation[steamID] = nil
        end
        return
    end

    if globals.TickCount() >= data.hitTick then
        if not customAngleData[steamID] then
            setupPlayerAngleData(data.enemy)
        end
        data.preCycleYaw = customAngleData[steamID].yawCycleIndex
        cycleYaw(customAngleData[steamID], 1, "Cycling (no hit)")
        data.cycled = true
        data.cleanupTick = globals.TickCount() + 66
    end
end

local function handlePlayerShooting(cmd)
    if not cmd then return end
    if hasPendingConfirmation() then
        print("[Resolver DEBUG] Shot ignored — already awaiting confirmation")
        return
    end

    local method = playerShot(cmd)
    if method then
        local now = globals.RealTime()
        local gap = lastShotTime and string.format("%.3fs since last", now - lastShotTime) or "first shot"
        shotCount = shotCount + 1
        lastShotTime = now
        print(string.format("[Resolver DEBUG] Shot #%d via '%s' | %s | tick %d",
            shotCount, method, gap, globals.TickCount()))

        local victimInfo = getBestTarget()

        if victimInfo then
            local victim = victimInfo.entity
            local steamID = getSteamID(victim)
            local name = client.GetPlayerInfo(victim:GetIndex()).Name

            if not customAngleData[steamID] then
                setupPlayerAngleData(victim)
            end

            print(string.format("[Resolver DEBUG] Awaiting hit confirm for '%s' (tick deadline %d)",
                name, globals.TickCount() + 33))

            awaitingConfirmation[steamID] = {
                enemy = victim,
                wasHit = false,
                hitTick = globals.TickCount() + 33,
                cycled = false,
                preCycleYaw = nil,
                cleanupTick = nil,
            }
        else
            print("[Resolver DEBUG] Shot fired but no target in FOV")
        end
    end
end

local function fireGameEvent(event)
    if event:GetName() == 'player_hurt' then
        local victim = entities.GetByUserID(event:GetInt("userid"))
        local attacker = entities.GetByUserID(event:GetInt("attacker"))
        local headshot = getBool(event, "crit")
        local damage = event:GetInt("damageamount")

        if (attacker ~= nil and plocal:GetName() ~= attacker:GetName()) then
            local attackerSteamID = getSteamID(attacker)
            checkForFakePitch(attacker, attackerSteamID)
        end

        if not victim or not customAngleData then goto eventEnd end
        local steamID = getSteamID(victim)

        if awaitingConfirmation[steamID] then
            local name = client.GetPlayerInfo(victim:GetIndex()).Name
            print(string.format("[Resolver DEBUG] player_hurt '%s' | crit=%s dmg=%d | wasHit=%s cycled=%s",
                name, tostring(headshot), damage,
                tostring(awaitingConfirmation[steamID].wasHit),
                tostring(awaitingConfirmation[steamID].cycled)))
        end

        if awaitingConfirmation[steamID] and not awaitingConfirmation[steamID].wasHit and headshot then
            awaitingConfirmation[steamID].wasHit = true
            local name = client.GetPlayerInfo(victim:GetIndex()).Name

            if awaitingConfirmation[steamID].cycled and awaitingConfirmation[steamID].preCycleYaw and customAngleData[steamID] then
                customAngleData[steamID].yawCycleIndex = awaitingConfirmation[steamID].preCycleYaw
                announceResolve(customAngleData[steamID], "Crit confirmed, reverting to")
                print(string.format("[Resolver] Crit confirmed on '%s', reverting yaw.", name))
            else
                client.ChatPrintf(string.format(
                    "\x073475c9[Resolver] \x01Crit on \x073475c9'%s'\x01 — keeping current yaw.", name))
                print(string.format("[Resolver] Crit on '%s' — keeping current yaw.", name))
            end
        end
        ::eventEnd::
    end
end

local function createMove(cmd)
    if not gamerules.IsTruceActive() then
        handlePlayerShooting(cmd)
    end

    checkForCycleYawKeybind()

    for steamID, data in pairs(awaitingConfirmation) do
        processConfirmation(steamID, data)
    end
end

callbacks.Unregister("CreateMove", "Resolver.CreateMove")
callbacks.Unregister("FireGameEvent", "Resolver.FireGameEvent")
callbacks.Unregister("FrameStageNotify", "Resolver.FrameStageNotify")
callbacks.Unregister("ProcessTempEntities", "Resolver.ProcessTempEntities")

callbacks.Register("CreateMove", "Resolver.CreateMove", createMove)
callbacks.Register("FireGameEvent", "Resolver.FireGameEvent", fireGameEvent)
callbacks.Register("FrameStageNotify", "Resolver.FrameStageNotify", propUpdate)
callbacks.Register("ProcessTempEntities", "Resolver.ProcessTempEntities", function(entEvtTable)
    if not plocal then return end
    local localIdx = plocal:GetIndex()
    for ent, _ in pairs(entEvtTable) do
        if ent:GetNetworkName() == "CTEFireBullets" then
            local shooterIdx = ent:GetPropInt("m_iPlayer") + 1
            print(string.format("[Resolver DEBUG] CTEFireBullets: shooterIdx=%d localIdx=%d pending=%s confirm=%s",
                shooterIdx, localIdx, tostring(pendingShot), tostring(hasPendingConfirmation())))
            if shooterIdx == localIdx then
                if hasPendingConfirmation() then
                    print("[Resolver DEBUG] CTEFireBullets: blocked by pending confirmation")
                else
                    pendingShot = true
                    print("[Resolver DEBUG] CTEFireBullets: pendingShot SET")
                end
                return
            end
        end
    end
end)
