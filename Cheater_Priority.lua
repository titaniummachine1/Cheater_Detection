--[[
    Cheater Detection for Lmaobox
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credit for examples:
    LNX (github.com/lnx00)
    Muqa for chat pritn help
]]

---@alias PlayerData { Angle: EulerAngles[], Position: Vector3[], SimTime: number[] }


---@type boolean, lnxLib
local libLoaded, lnxLib = pcall(require, "lnxLib")
assert(libLoaded, "lnxLib not found, please install it!")
assert(lnxLib.GetVersion() >= 0.981, "lnxLib version is too old, please update it!")


local TF2 = lnxLib.TF2
local Math, Conversion = lnxLib.Utils.Math, lnxLib.Utils.Conversion
local WPlayer = TF2.WPlayer
local Helpers = lnxLib.TF2.Helpers

local players = entities.FindByClass("CTFPlayer")

local pLocal = entities.GetLocalPlayer()
playerlist.SetPriority(pLocal, 0) -- debug

local options = {
    StrikeLimit = 4,
    MaxTickDelta = 20,
    Aimbotfov = 7,
    AutoMark = true,
    debug = false,
}

local BOTPATTERNS = {
    "braaaap %d+", -- Escape special characters with %
    "swonk bot %d+",
    "S.* bit%.ly/2UnS5z8",
    "(%d+)Morpheus Bot Removal Service", -- Group captures with ()
    "(%d+)/id/heinrichderpro",
    "(%d+)\\[VALVE\\]Twilight Sparkle(%n)?", -- Use %n for newline
    "S.* bit\\.ly\\/2UnS5z8",
    "(\\(\\d\\))?Morpheus Bot Removal Service",
    "\\[VALVE\\]N[i00ed]\\w[g]+\\w+[i00ed]\\w[l]+[e\\d]r",
    "(\\(\\d+\\))?\\/id\\/heinrichderpro",
    "(\\(\\d+\\))?\\[VALVE\\]Twilight Sparkle(\n)?",
    "(\\(\\d+\\))?shoppy\\.gg\\/@d3fc0n6",
    "(\\(\\d+\\))?youtube\\.com/d3fc0n6",
    "(\\(\\d+\\))?Festive Hitman",
    "(\\(\\d+\\))?blu ((red)|(me))",
    "(\\(\\d+\\))?YOU'VE BEEN LOVE ROLLED!!!",
    "(\\(\\d+\\))?Bottle Goon",
    "(\\(\\d+\\))?Osama bin laden",
    "(\\(\\d+\\))?YOU'VE BEEN MARIO KARTED",
    "(\\(\\d+\\))\\[VALVE\\]N.ggerk.ller",
    "(\\(\\d+\\))?Twilight Sparkle is cute",
    "(\\(\\d+\\))?CUMBOT.TF",
    "(\\(\\d+\\))?vcaps bots",
    "(\\(\\d+\\))?Youtube\\/HamGames",
    "(\\(\\d+\\))?DoesHotter",
    "(\\(\\d+\\))?www\\.titsassesandicks\\.com",
    "(\\(\\d+\\))?Neil banging the tunes",
    "(\\(\\d+\\))?your medical license v2",
    "(\\(\\d+\\))?kurumimink",
    "(\\(\\d+\\))?[VALVE]WhiteKiller",
    "(\\(\\d+\\))?discord\\.gg\\/9Ukuw9V",
    "(\\(\\d+\\))?haunted\\.church",
    "(\\(\\d+\\))?\\[VAC\\] OneTrick",
    "(\\(\\d+\\))?Richard\\sStallman(\\s)?",
    "(\\(\\d+\\))?\\w+ gaming \\(not a bot\\)",
    "(\\(\\d+\\))?vk\\.com/warcrimer",
    "(\\(\\d+\\))?(http\\:\\/\\/)?meowhook\\.club()?",
    "(\\(\\d+\\))?vk.com/thenosok",
    "(\\(\\d+\\))?O.?M.?E.?G.?A.?T.?R.?O.?N.?I.?C.?",
    "omegatronic",
    "OMEGATRONIC",
    "braaaap god",
    "Níggerkiller as",
    -- And so on for other patterns
    -- Use \\ to escape literals
    "\\n", "\\r\\n", "\\r",
    -- Hex encode unicode
    "\226\128\159", -- \u0e49
    "\226\128\144", -- \u0e4a
    -- Unicode patterns need to be in a string
    [[\u0274\u026a\u0262\u0262\u1d07\u0280]], 

    -- Other valid patterns
    "omegatronic",
    "OMEGATRONIC",
    "Hexatronic"
}

local prevData = nil ---@type PlayerData
local playerStrikes = {} ---@type table<number, number>
local detectedPlayers = {} -- Table to store detected players

local function StrikePlayer(idx, reason, player)
    -- Initialize strikes if needed
    if not playerStrikes[idx] then
        playerStrikes[idx] = 0
    end

    -- Increment strikes
    playerStrikes[idx] = playerStrikes[idx] + 1

    -- Get the target player
    local targetPlayer
    if player and player:GetIndex() == idx then
        targetPlayer = player
    end

    -- Handle strike limit
    if playerStrikes[idx] < options.StrikeLimit then
        -- Print message
        if targetPlayer and playerlist.GetPriority(player) > -1 then
            print(targetPlayer:GetName() .. " stroked AC")
            client.ChatPrintf(tostring("\x04[CD] \x01Player \x03" .. player:GetName() .. " \x01has stroke CD With \x04" .. reason))
        end
    else
        -- Print cheating message if player is not detected
        if targetPlayer and playerlist.GetPriority(player) > -1 and not detectedPlayers[player:GetIndex()] then
            print(targetPlayer:GetName() .. " is cheating")
            client.ChatPrintf(tostring("\x04[CD] \x01Player \x03" .. player:GetName() .. " \x01is cheating! Reason: \x04".. reason))

            -- Add player to detectedPlayers table
            detectedPlayers[player:GetIndex()] = true

            -- Auto mark
            if options.AutoMark then
                playerlist.SetPriority(player, 10)
            end
        end
    end
end

-- Detects rage pitch (looking up/down too much)
local function CheckAngles(player, entity)
    local angles = player:GetEyeAngles()
    if angles.pitch == 89.00 or angles.pitch == -89.00 -- detects fake up/down/up/fakedown pitch settigns {lbox]
    or angles.pitch >= 90 or angles.pitch <= -90 then -- detects custom pitch and other cheats
        StrikePlayer(player:GetIndex(), "Invalid pitch", entity)
    end
end

-- Check if a player is choking packets (Fakelag, Doubletap)
local function CheckChoke(player, entity)
    local simTime = player:GetSimulationTime()
    local oldSimTime = prevData.SimTime[player:GetIndex()]
    if not oldSimTime then return end -- no simTime
    local delta = simTime - oldSimTime --get difference between current and previous simtime
    if delta == 0 then return end --its local player revinding time
    local deltaTicks = Conversion.Time_to_Ticks(delta)
    if deltaTicks > options.MaxTickDelta then
        StrikePlayer(player:GetIndex(), "Choking packets", entity)
    end
end

local function isValidName(player, name, entity)
    
    for i, pattern in ipairs(BOTPATTERNS) do
      if string.find(name, pattern) then
        StrikePlayer(player:GetIndex(), "Bot Name", entity, player)
      end
    end
end

--[[local viewAngleMap = {} -- Table to store the view angles for each player by index
local lastAngle = {} -- Table to store the last view angles for each player by index
local allAngles = {} -- Table to store all previous view angles for each player by index
local maxAngles = 24 -- Maximum number of previous angles to store

local function CheckAimbot(player, idx)
    local viewAngles = player:GetEyeAngles()
    if lastAngle[idx] then
        viewAngleMap[idx] = lastAngle[idx]
    end
    if not allAngles[idx] then
        allAngles[idx] = {}
    end
    table.insert(allAngles[idx], viewAngles)
    while #allAngles[idx] > maxAngles do
        table.remove(allAngles[idx], 1)
    end
    lastAngle[idx] = viewAngles
end]]


-- Table to store the previous tick's FOV for each player by index
local lastFov = {}

-- Table to store suspicious players
local suspicious = {}

-- Function to check for aimbot
local function CheckAimbot(shooter)
    -- Return nil if the shooter is invalid or dead
    if not shooter or shooter:IsDormant() or not shooter:IsAlive() then
        return nil
    end

    -- Return nil if the shooter is not in the suspicious table
    if not suspicious[shooter:GetIndex()] then
        return nil
    end

    -- Initialize variables
    local shooterIndex = shooter:GetIndex()
    local shooterTeam = shooter:GetTeamNumber()
    local closestFov = 360
    local closestTarget

    -- Get the shooter's position and view angles
    shooter = WPlayer.FromEntity(shooter)
    local shooterOrigin = shooter:GetEyePos()
    local viewAngles = shooter:GetEyeAngles()

    -- Loop through all players
    for _, player in ipairs(players) do
        -- Skip shooters, dormant players, dead players, and players from the same team.
        if player == shooter or player:IsDormant() or not player:IsAlive() or player:GetTeamNumber() == shooterTeam then
            goto continue
        end

        -- Get the player's position
        player = WPlayer.FromEntity(player)
        local playerOrigin = player:GetHitboxPos(1)

        -- Exclude invisible players as aimbot will not target them.
        if not Helpers.VisPos(player, playerOrigin, shooterOrigin) then
            goto continue
        end

        -- Calculate the FOV between the shooter's view angles and the player's position
        local fov = Math.AngleFov(Math.PositionAngles(shooterOrigin, playerOrigin), viewAngles)

        -- Update the closest target if the current player has a smaller FOV
        if fov < closestFov then
            closestFov = fov
            closestTarget = player
        end

        ::continue::
    end

    -- Update the last FOV value for the shooter
    lastFov[shooterIndex] = closestFov

    -- Return the closest target
    return closestTarget
end

-- Event hook function
local function event_hook(ev)
    -- Return if the event is not a player hurt event
    if ev:GetName() ~= "player_hurt" then
        return
    end

    -- Get the entities involved in the event
    local attacker = entities.GetByUserID(ev:GetInt("attacker"))
    if options.debug == false and attacker == pLocal then return end
    local victim = entities.GetByUserID(ev:GetInt("userid"))
    local damage = ev:GetInt("damageamount")

    -- Return if the attacker or victim is dormant
    if attacker:IsDormant() or victim:IsDormant() then return end

    -- Get the attacker's class and aim position
    local attackerclass = attacker:GetPropInt("m_iClass")
    local AimPos = 2
    if attackerclass == 2 or attackerclass == 8 then
        AimPos = 1
    end

    -- Get the shooter's position and the victim's position
    local shooter = WPlayer.FromEntity(attacker)
    local shooterOrigin = shooter:GetEyePos()
    victim = WPlayer.FromEntity(victim)
    local aimHitbox = 1

    -- Set the aim position to the head for sniper classes
    if attackerclass == 2 then
        aimHitbox = 2
    end
    local victimOrigin = victim:GetHitboxPos(aimHitbox)

    -- Calculate the FOV between the shooter's view angles and the victim's position
    local targetAngle = Math.PositionAngles(shooterOrigin, victimOrigin)
    local Fov = Math.AngleFov(shooter:GetEyeAngles(), targetAngle )

    -- Add the attacker to the suspicious table if the FOV is greater than the aimbot FOV
    if Fov > options.Aimbotfov then
        table.insert(suspicious, attacker:GetIndex(), attacker)
        print("suspicious")
    end

    -- Perform advanced detection if the FOV difference is greater than the aimbot FOV
    local fovDiff = Fov - (lastFov[shooter:GetIndex()] or 0)
    if fovDiff > options.Aimbotfov then
        StrikePlayer(shooter:GetIndex(), "Silent Aimbot", attacker)
    end

    -- Update the last FOV value for the shooter
    lastFov[shooter:GetIndex()] = Fov
end

local function OnCreateMove(userCmd)
    pLocal = entities.GetLocalPlayer()
    players = entities.FindByClass("CTFPlayer")
    if pLocal == nil then goto continue end -- Skip if local player is nil

    local latin, latout = clientstate.GetLatencyIn() * 1000, clientstate.GetLatencyOut() * 1000 -- Convert to ms
   --:GetPropDataTableInt("m_iConnectionState")[pLocal:GetIndex()]
    -- Get current data
    local currentData = {
        Angle = {},
        Position = {},
        SimTime = {},
    }

    for idx, entity in pairs(players) do
        if options.debug == false and entity == pLocal  -- Skip local player 
        or options.debug == false and TF2.IsFriend(idx, true)
        or playerlist.GetPriority(entity) == 10
        or playerlist.GetPriority(entity) == -1
        or entity:IsDormant()
        or not entity:IsAlive() then
            goto continue
        end

        local player = WPlayer.FromEntity(entity)

        currentData.SimTime[idx] = player:GetSimulationTime()

        isValidName(player, entity:GetName(), entity) --detect bot names

        CheckAngles(player, entity) --detects rage cheaters and bots

        CheckAimbot(entity) --detect aimbot users

        if prevData then
            if (latin + latout) < 200 then
                CheckChoke(player, entity) --detects majority of rage cheaters
            end

        end

        ::continue::
    end

    prevData = currentData
    ::continue::
end

callbacks.Register("CreateMove", OnCreateMove)
callbacks.Register("FireGameEvent", "unique_event_hook", event_hook)
