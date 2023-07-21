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

local options = {
    StrikeLimit = 10,
    MaxTickDelta = 8,
    AimbotSensetivity = 0.4,
    AutoMark = true,
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
    if angles.pitch >= 89 or angles.pitch <= -89 then
        StrikePlayer(player:GetIndex(), "Invalid pitch", entity)
    end
end

-- Check if a player is choking packets (Fakelag, Doubletap)
local function CheckChoke(player, entity)
    entity = entity
    local simTime = player:GetSimulationTime()
    local oldSimTime = prevData.SimTime[player:GetIndex()]
    if not oldSimTime then return end

    local delta = simTime - oldSimTime
    local deltaTicks = Conversion.Time_to_Ticks(delta)
    if deltaTicks > options.MaxTickDelta then
        StrikePlayer(player:GetIndex(), "Choking packets", entity)
    end
end

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
  }
  
local function isValidName(player, name, entity)
    
    for i, pattern in ipairs(BOTPATTERNS) do
      if string.find(name, pattern) then
        StrikePlayer(player:GetIndex(), "Bot Name", entity, player)
      end
    end
end

local function GetLeastFovTarget(shooter)
    -- Find closest target
    local closestFov = 360
    local closestTarget
    local closestAngle
  
    for i, player in ipairs(players) do
        if player:IsDormant() or shooter == nil then goto continue end
        if shooter == player then goto continue end
        if not player:IsAlive() then goto continue end
        if player:GetTeamNumber() == shooter:GetTeamNumber() then -- Skip local player and teammates
            goto continue
        end
  
    -- Get pLocal eye level and set vector at our eye level to ensure we check distance from eyes
        player = WPlayer.FromEntity(player)
        shooter = WPlayer.FromEntity(shooter)
        
        --local viewOffset = shooter:GetPropVector("localdata", "m_vecViewOffset[0]") -- Vector3(0, 0, 70)
        local shooterOrigin = shooter:GetEyePos() --(shooter:GetAbsOrigin() + viewOffset)

        --viewOffset = player:GetPropVector("localdata", "m_vecViewOffset[0]") -- Vector3(0, 0, 70)
        local playerOrigin = player:GetHitboxPos(1) --(player:GetAbsOrigin() + viewOffset)
        
        local viewAngles = shooter:GetEyeAngles()--:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]"):Forward()
        --if not Helpers.VisPos(shooterOrigin, playerOrigin) then goto continue end
  
        local angles = Math.PositionAngles(shooterOrigin, playerOrigin)
        local fov = Math.AngleFov(angles, viewAngles)
        if fov < closestFov then
            closestAngle = angles
            closestFov = fov
            closestTarget = player
        end
  
        ::continue::
    end
  
    -- Check if aiming at head
    local aimingAtHead = false
    if closestFov < options.AimbotSensetivity then
        aimingAtHead = true
    end
    return closestTarget, aimingAtHead
end

local flickCounter = 0
local function CheckAimbot(shooter)
    local Target, HeadAim = GetLeastFovTarget(shooter)
    if HeadAim == true then
        flickCounter = flickCounter + 1
            StrikePlayer(shooter:GetIndex(), "Silent Aimbot", shooter)
        if flickCounter > 2 then
            flickCounter = 0
            StrikePlayer(shooter:GetIndex(), "AimLock", shooter) 
        end
    else
        flickCounter = 0
    end
end

-- Add your custom detection functions here

local function OnCreateMove(userCmd)
    local me = WPlayer.GetLocal()
    if not me then return end

    players = entities.FindByClass("CTFPlayer")

    -- Get current data
    local currentData = {
        Angle = {},
        Position = {},
        SimTime = {},
    }
    local players = entities.FindByClass("CTFPlayer")
    for idx, entity in pairs(players) do
        if idx == me:GetIndex() then
            goto continue
        end
        if entity:IsDormant() or not entity:IsAlive() then
            goto continue
        end

        local player = WPlayer.FromEntity(entity)
        currentData.Angle[idx] = player:GetEyeAngles()
        currentData.Position[idx] = player:GetAbsOrigin()
        currentData.SimTime[idx] = player:GetSimulationTime()

        CheckPitch(player, entity) --detects all bots as they all use anty aim
        if prevData then
            CheckChoke(player, entity) --detects majority of rage cheaters
        end
        isValidName(player, entity:GetName(), entity) --detect bot names

        CheckAimbot(entity) --detect aimbot users


        ::continue::
    end

    prevData = currentData
end

callbacks.Register("CreateMove", OnCreateMove)
