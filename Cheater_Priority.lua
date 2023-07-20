--[[
    Cheater Detection for Lmaobox
    Author: LNX (github.com/lnx00)
]]

---@alias PlayerData { Angle: EulerAngles[], Position: Vector3[], SimTime: number[] }


---@type boolean, lnxLib
local libLoaded, lnxLib = pcall(require, "lnxLib")
assert(libLoaded, "lnxLib not found, please install it!")
assert(lnxLib.GetVersion() >= 0.981, "lnxLib version is too old, please update it!")

local Conversion = lnxLib.Utils.Conversion
local WPlayer = lnxLib.TF2.WPlayer

local options = {
    StrikeLimit = 10,
    MaxTickDelta = 8,
    MaxAngleDelta = 17,
    AutoMark = true,
}

local prevData = nil ---@type PlayerData
local playerStrikes = {} ---@type table<number, number>

local function StrikePlayer(idx, reason, entity, player)
    if not playerStrikes[idx] then
        playerStrikes[idx] = 0
    end

    playerStrikes[idx] = playerStrikes[idx] + 1
    if playerStrikes[idx] < options.StrikeLimit then
        -- Find player with index idx
        local targetPlayer = nil
        if player ~= nil then
            if player:GetIndex() == idx then
                targetPlayer = player
                if targetPlayer ~= nil then
                    print(player:GetName() .. " stroked AC")
                    client.ChatPrintf(tostring("\x04[AC] \x01Player ".. player:GetName()..  " \x01has been striked for \x04".. reason)) --client.ChatPrintf(string.format("\x04[AC] \x01Player \x05%d \x01has been striked for \x05%s", idx, reason))
                end
            end
        end
    elseif playerStrikes[idx] >= options.StrikeLimit then
        local targetPlayer = nil
            if player ~= nil then
            if player:GetIndex() == idx then
                targetPlayer = player
                if targetPlayer ~= nil then
                    if playerlist.GetPriority(entity) ~= 10 and playerlist.GetPriority(entity) ~= -1 then
                        print(player:GetName() .. " is cheating")

                        client.ChatPrintf(tostring("\x04[AC] \x01Player ".. player:GetName()..  " \x01is cheating!"))  --client.ChatPrintf(string.format("\x04[CD] \x01Player \x05%d \x01is cheating!", idx))
                        --[[client.ChatPrintf("\x04[CD] \x01Player \x05%s \x01has been striked for \x05%s", player:GetName(), reason)
                            client.ChatPrintf("\x04[CD] \x01Player \x05%s \x01is cheating!", player:GetName())
                            ]]
                        if options.AutoMark == true then
                            playerlist.SetPriority(entity, 10)
                        end
                    end
                end
            end
        end
    end
end

-- Detects rage pitch (looking up/down too much)
local function CheckPitch(player, entity)
    local angles = player:GetEyeAngles()
    if angles.pitch >= 89 or angles.pitch <= -89 then
        StrikePlayer(player:GetIndex(), "Invalid pitch", entity, player)
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
        StrikePlayer(player:GetIndex(), "Choking packets", entity, player)
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

local function CheckFlick(player, entity)
    return
end
-- Add your custom detection functions here

local function OnCreateMove(userCmd)
    local me = WPlayer.GetLocal()
    if not me then return end

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
        isValidName(player, entity:GetName(), entity)
        CheckFlick(player, entity)


        ::continue::
    end

    prevData = currentData
end

callbacks.Register("CreateMove", OnCreateMove)
