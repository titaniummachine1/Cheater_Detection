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


local Math, Conversion = lnxLib.Utils.Math, lnxLib.Utils.Conversion
local WPlayer = lnxLib.TF2.WPlayer
local Helpers = lnxLib.TF2.Helpers

local players = entities.FindByClass("CTFPlayer")
local pLocal = entities.GetLocalPlayer()
local options = {
    StrikeLimit = 7,
    MaxTickDelta = 20,
    Aimbotfov = 7,
    AutoMark = true,
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
            client.ChatPrintf(tostring("\x04[AC] \x01Player \x03" .. player:GetName() .. " \x01has triggered AC With \x04" .. reason))
        end
    else
        -- Print cheating message if player is not detected
        if targetPlayer and playerlist.GetPriority(player) > -1 and not detectedPlayers[player:GetIndex()] then
            print(targetPlayer:GetName() .. " is cheating")
            client.ChatPrintf(tostring("\x04[AC] \x01Player \x03" .. player:GetName() .. " \x01is cheating! Reason: \x04".. reason))

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
local function CheckPitch(player, entity)
    local angles = player:GetEyeAngles()
    if angles.pitch == 89.00 or angles.pitch == -89.00 -- aa pitch when normaly only 89.29 max = hard to reproduce when legit
    or angles.pitch >= 89.30 or angles.pitch <= -89.30 then -- aa pitch but broken with exploits
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


local lastFov = {} -- Table to store the previous tick's FOV for each player by index
local aimPosMap = {} -- Table to store the AimPos value for each player by index

local function CheckAimbot(shooter)
    if not shooter or shooter:IsDormant() or not shooter:IsAlive() then
        return nil
    end

    local shooter_class = shooter:GetPropInt("m_iClass") -- check if shooter is TF2_Sniper
    if shooter_class ~= 2 and shooter_class ~= 8 and shooter_class ~= 1 and shooter_class ~= 9 then
        return nil
    end

    local shooterIndex = shooter:GetIndex()
    local shooterTeam = shooter:GetTeamNumber()
    local closestFov = options.Aimbotfov + 5
    local closestTarget

    shooter = WPlayer.FromEntity(shooter)
    local shooterOrigin = shooter:GetEyePos()
    local viewAngles = shooter:GetEyeAngles()

    local aimPos = aimPosMap[shooterIndex] or 1 -- Use the stored AimPos for this shooter, default to 1 if not set

    for _, player in ipairs(players) do
        if player == shooter or player:IsDormant() or not player:IsAlive() or player:GetTeamNumber() == shooterTeam then
            -- Skip shooters, dormant players, dead players, and players from the same team.
            goto continue
        end

        player = WPlayer.FromEntity(player)
        local playerOrigin = player:GetHitboxPos(aimPos)

        if not Helpers.VisPos(player, playerOrigin, shooterOrigin) then
            -- Exclude invisible players as aimbot will not target them.
            goto continue
        end

        local fov = Math.AngleFov(Math.PositionAngles(shooterOrigin, playerOrigin), viewAngles)

        if fov < closestFov then
            closestFov = fov
            closestTarget = player
        end

        ::continue::
    end

    lastFov[shooterIndex] = closestFov
    return closestTarget
end

local function event_hook(ev)
    if ev:GetName() ~= "player_hurt" then
        return
    end

    -- Get the entities involved in the event
    local victim = entities.GetByUserID(ev:GetInt("userid"))
    local attacker = entities.GetByUserID(ev:GetInt("attacker"))

    if attacker == pLocal then
        return
    end

    local shooter = WPlayer.FromEntity(attacker)
    local shooterClass = attacker:GetPropInt("m_iClass")

    -- Check if the attacker is a sniper class (TF2_Sniper, TF2_Spy, TF2_Scout, or TF2_Engineer)
    if shooterClass ~= 2 and shooterClass ~= 8 and shooterClass ~= 1 and shooterClass ~= 9 then
        return
    end

    local shooterOrigin = shooter:GetEyePos()
    local viewAngles = shooter:GetEyeAngles()
    local player = WPlayer.FromEntity(victim)

    local aimPos = aimPosMap[shooter:GetIndex()] or 1 -- Use the stored AimPos for this shooter, default to 1 if not set
    local playerOrigin = player:GetHitboxPos(aimPos)

    local fov = Math.AngleFov(Math.PositionAngles(shooterOrigin, playerOrigin), viewAngles)
    local fovDiff = fov - (lastFov[shooter:GetIndex()] or 0)

    if fovDiff > options.Aimbotfov then
        -- Perform detection action here, such as striking the player for aimbot.
        StrikePlayer(shooter:GetIndex(), "Silent Aimbot", attacker)
    end

    lastFov[shooter:GetIndex()] = fov -- Update lastFov with the new FOV value
end




local function OnCreateMove(userCmd)
    pLocal = entities.GetLocalPlayer()
    players = entities.FindByClass("CTFPlayer")
    if pLocal == nil then goto continue end -- Skip if local player is nil
    local latin, latout = clientstate.GetLatencyIn() * 1000, clientstate.GetLatencyOut() * 1000 -- Convert to ms
    
    -- Get current data
    local currentData = {
        Angle = {},
        Position = {},
        SimTime = {},
    }

    for idx, entity in pairs(players) do
        if idx == pLocal:GetIndex()
        or playerlist.GetPriority(entity) == 10
        or playerlist.GetPriority(entity) == -1
        or entity:IsDormant()
        or not entity:IsAlive() then
            goto continue
        end

        local player = WPlayer.FromEntity(entity)
        --currentData.Angle[idx] = player:GetEyeAngles()
        --currentData.Position[idx] = player:GetAbsOrigin()
        currentData.SimTime[idx] = player:GetSimulationTime()

        isValidName(player, entity:GetName(), entity) --detect bot names

        CheckPitch(player, entity) --detects all bots as they all use anty aim

        if prevData then
            if (latin + latout) < 200 then
                CheckChoke(player, entity) --detects majority of rage cheaters
            end
        end

        CheckAimbot(entity) --detect aimbot users

        ::continue::
    end

    prevData = currentData
    ::continue::
end

callbacks.Register("CreateMove", OnCreateMove)
callbacks.Register("FireGameEvent", "unique_event_hook", event_hook)