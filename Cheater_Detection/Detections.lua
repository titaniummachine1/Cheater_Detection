--[[ Annotations ]]
---@alias PlayerData { Angle: EulerAngles[], Position: Vector3[], SimTime: number[] }


--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local Config = require("Cheater_Detection.Config")
local Visuals = require("Cheater_Detection.Visuals")

local Lib = Common.Lib

local TF2 = Lib.TF2
local Math, Conversion = Lib.Utils.Math, Lib.Utils.Conversion
local WPlayer, WPR = TF2.WPlayer, TF2.WPlayerResource
local Helpers = Lib.TF2.Helpers

-- Unload package for debugging
Lib.Utils.UnloadPackages("Cheater_Detection")

local Notify, FS, Fonts, Commands, Timer = Lib.UI.Notify, Lib.Utils.FileSystem, Lib.UI.Fonts, Lib.Utils.Commands, Lib.Utils.Timer
local Log = Lib.Utils.Logger.new("Detections")
Log.Level = 0

--[[ Variables ]]
local Detections = {}
-- Declare global variables
local Menu = nil
local DataBase = {}
local players = {}
local pLocal = nil
local WLocal = nil
local latin = nil
local latout = nil
local connectionState = nil
local packetloss = nil

--[[functions ]]

function Detections.GetSteamID(Player)
    if Player then
        local playerInfo = client.GetPlayerInfo(Player:GetIndex())
        if playerInfo then
            return playerInfo.SteamID
        end
    end

    return nil
end

local defaultRecord = {
    Name = "NN",
    isCheater = false,
    cause = "None",
    date = os.date("%Y-%m-%d %H:%M:%S"),
    strikes = 0,
    EntityData = {
        SimTimes = {},
        StdDevList = {},
        AngleHistory = {},
        Bhops = 0, -- Counter for consecutive jumps
        LastOnGround = true, -- Last known ground status
        LastZVelocity = 0, -- Last known vertical velocity
        CanJump = false, -- Whether the player was able to jump in the previous iteration
        -- Add other fields here
    }
}

function Detections.UpdateData()
    -- update every tick
    Menu = Visuals.GetMenu()
    Visuals.SetRuntimeData(DataBaseInput)
    DataBase = Config.GetDatabase()
    players = entities.FindByClass("CTFPlayer")
    pLocal = entities.GetLocalPlayer()
    WLocal = WPlayer.FromEntity(pLocal)
    latin, latout = clientstate.GetLatencyIn() * 1000, clientstate.GetLatencyOut() * 1000 -- Convert to ms
    connectionState = entities.GetPlayerResources():GetPropDataTableInt("m_iConnectionState")[WLocal:GetIndex()]

    -- Return all the necessary values
    return Menu, DataBase, players, pLocal, WLocal, latin, latout, connectionState
end

local LastStrike = 0
function Detections.StrikePlayer(reason, player)
    if not player or not reason then
        Log:Warn("Invalid parameters to StrikePlayer")
        return
    end

    local steamId = Detections.GetSteamID(player)
    if not steamId then
        Log:Warn("Failed to get SteamID for player %s", player:GetName() or "nil")
        return
    end

    if not DataBase then
        Log:Warn("Database is nil")
        DataBase = {} -- Initialize DataBase if it's nil
    end

    -- Initialize the player's record if it doesn't exist
    local record = DataBase[steamId] or { strikes = 0, isCheater = false }

    -- Check if the player is already detected as a cheater
    if record.isCheater == true then
        Log:info("Player %s is already detected as a cheater", player:GetName())
        return -- Don't strike a player that's already detected
    end

    record.strikes = record.strikes + 1 -- Increment strikes 

    -- Handle strikes threshold
    if record.strikes < Menu.Main.StrikeLimit then
        -- If less than 132 ticks have passed since the last strike, return immediately
        if LastStrike and globals.TickCount() - (LastStrike or 0) < 132 then
            Log:Warn("Less than 66 ticks have passed since the last strike for player %s", player:GetName())
            return
        end

        -- Print message
        if player and record.strikes == math.floor(Menu.Main.StrikeLimit / 2) then -- only call the player sus if hes has been flagged half of the total amount
            client.ChatPrintf(tostring("\x04[CD] \x03" .. player:GetName() .. "\x01 is \x07ffd500Suspicious \x01(\x04" .. reason.. "\x01)"))

            if Menu.Visuals.AutoMark and player ~= pLocal then
                playerlist.SetPriority(player, 5)
            end
        end

        -- Update LastStrike
        LastStrike = globals.TickCount()
    else
        -- Print cheating message if player is detected and wasn't noted before
        if player and not record.isCheater then
            print(tostring("[CD] ".. player:GetName() .. " is cheating"))
            client.ChatPrintf(tostring("\x04[CD] \x03" .. player:GetName() .. " \x01is\x07ff0019 Cheating\x01! \x01(\x04" .. reason.. "\x01)"))
            if Menu.Visuals.partyCallaut == true then
                client.Command("say_party ".. player:GetName() .." is Cheating " .. "(".. reason.. ")",true);
            end

            -- Set player as detected
            record.Name = player:GetName()
            record.isCheater = true
            record.cause = reason
            record.date = os.date("%Y-%m-%d %H:%M:%S")

            -- Auto mark
            if Menu.Visuals.AutoMark and player ~= pLocal then
                playerlist.SetPriority(player, 10)
            end
        else
            Log:info("Player %s is already marked as cheater", player:GetName())
        end
    end

    -- Save the record
    Config.PushSuspect(steamId, record)

    -- Add the record to the in-memory database
    DataBase[steamId] = record
    LastStrike = globals.TickCount()

    return true
end

-- Detects rage pitch (looking up/down too much)
local function CheckAngles(player, entity)
    if Menu.Main.AntyAimDetection == false then return end

    local angles = player:GetEyeAngles()
    if angles.pitch > 89.4 or angles.pitch < -89.4 then --imposible angles
        --print(angles.pitch)
        -- Detects specific cheats based on unique pitch patterns (rage pitch, lbox, etc.)
        if angles.pitch % 3256 == 0 then
            return Detections.StrikePlayer("LBOX AA(Center)", entity)
        elseif angles.pitch % 271 == 0 then
            return Detections.StrikePlayer("RIJIN AA?", entity)
        elseif angles.pitch % 90 == 0 then
            return Detections.StrikePlayer("Anty Aim(Up/Down)", entity)
        else
            return Detections.StrikePlayer("Anty Aim", entity)
        end
    end
    return false
end

local tick_count = 0
-- Detects rage pitch (looking up/down too much)
local function CheckDuckSpeed(player, entity)
    if Menu.Main.DuckSpeedDetection == false then return end

    local angles = player:GetEyeAngles()
    local flags = player:GetPropInt("m_fFlags")
    local OnGround = flags & FL_ONGROUND == 1
    local DUCKING = flags & FL_DUCKING == 2
    if OnGround
    and DUCKING then -- detects fake up/down/up/fakedown pitch settigns {lbox]
        local MaxDuckSpeed = {
            [1] = 400,
            [2] = 300,
            [3] = 240,
            [4] = 262,
            [5] = 320,
            [6] = 77,
            [7] = 300,
            [8] = 320,
            [9] = 300
        }

        if entity:EstimateAbsVelocity():Length() >= MaxDuckSpeed[entity:GetPropInt("m_iClass")] then
        --and clientstate:GetChokedCommands() > 12 then
            local m_vecViewOffset = math.floor(pLocal:GetPropVector("m_vecViewOffset[0]").z) ; --check if fully crounched

            if m_vecViewOffset == 45 then
                tick_count = tick_count + 1
                if tick_count >= 8 then
                    Detections.StrikePlayer("Duck Speed", entity)
                    tick_count = 0
                    return true
                end
                return true
            end
        end
        return false
    end
    return false
end

local function CheckBunnyHop(pEntity, entity)
    local steamId = Detections.GetSteamID(pEntity)
    if not Menu.Main.BhopDetection.Enable or not steamId or not DataBase[steamId] then
        return -- Early return if bhop detection is disabled, the player isn't found in the database, or SteamID retrieval failed
    end

    local playerRecord = DataBase[steamId]
    local flags = pEntity:GetPropInt("m_fFlags")
    local onGround = flags & FL_ONGROUND == 1
    local vel = pEntity:EstimateAbsVelocity() -- Assuming this function returns a Vector3 of the player's velocity

    -- Check if the player was able to jump in the previous iteration
    if playerRecord.EntityData.CanJump then
        if onGround then
            playerRecord.EntityData.Bhops = 0 -- Reset counter when player lands
            playerRecord.EntityData.CanJump = false
        elseif playerRecord.EntityData.LastZVelocity < vel.z and (vel.z == 271 or vel.z == 277) then
            -- Player has performed a jump without the server registering as touching the ground
            playerRecord.EntityData.Bhops = playerRecord.EntityData.Bhops + 1
            if playerRecord.EntityData.Bhops >= Menu.Main.BhopDetection.MaxBhop then
                -- Detected bunny hopping
                Detections.StrikePlayer("Bunny Hop", entity)
                playerRecord.EntityData.Bhops = 0 -- Reset counter after detection
            end
        end
    else
        playerRecord.EntityData.CanJump = onGround
    end

    -- Store the last on-ground state and vertical velocity for the next check
    playerRecord.EntityData.LastZVelocity = vel.z
end

local function CheckChoke(pEntity, entity)
    if Menu.Main.ChokeDetection.Enable == false then return false end
    local steamId = Detections.GetSteamID(pEntity)
    if not steamId then
        Log:Warn("Failed to get SteamID for player %s", pEntity:GetName() or "nil")
        return false
    end

    if not DataBase then
        Log:Warn("Database is nil")
        DataBase = {} -- Initialize DataBase if it's nil
    end

    local record = DataBase[steamId]
    if not record then
        record = defaultRecord
        DataBase[steamId] = defaultRecord -- Add the new record to the database
    end

    local EntityData = record.EntityData or {}
    EntityData.SimTimes = EntityData.SimTimes or {} -- Initialize SimTimes as an empty queue

    local simTime = pEntity:GetSimulationTime()

    -- Add the current simulation time to the queue
    table.insert(EntityData.SimTimes, simTime)

    -- If the queue has more than 33 elements, remove the oldest one
    if #EntityData.SimTimes > 33 then
        table.remove(EntityData.SimTimes, 1)
    end

    -- Calculate the delta ticks for each pair of consecutive simulation times
    local deltaTicks = {}
    for i = 2, #EntityData.SimTimes do
        local delta = EntityData.SimTimes[i] - EntityData.SimTimes[i - 1]
        table.insert(deltaTicks, Conversion.Time_to_Ticks(delta))
    end

    -- Calculate the mean delta tick
    local totalDeltaTime = 0
    for i = 1, #deltaTicks do
        totalDeltaTime = totalDeltaTime + deltaTicks[i]
    end
    local meanDeltaTick = totalDeltaTime / #deltaTicks

    -- Calculate the standard deviation of the delta ticks
    local sumOfSquaredDifferences = 0
    for i = 1, #deltaTicks do
        local difference = deltaTicks[i] - meanDeltaTick
        sumOfSquaredDifferences = sumOfSquaredDifferences + difference * difference
    end
    local variance = sumOfSquaredDifferences / (#deltaTicks - 1)
    local standardDeviation = math.sqrt(variance)

    -- Update the list of the last 33 standard deviations for this player
    EntityData.StdDevList = EntityData.StdDevList or {}
    table.insert(EntityData.StdDevList, 1, standardDeviation)
    if #EntityData.StdDevList > 33 then
        table.remove(EntityData.StdDevList)
    end

    -- Calculate the average of the last 33 standard deviations
    local sum = 0
    for i = 1, #EntityData.StdDevList do
        sum = sum + EntityData.StdDevList[i]
    end
    local avgStdDev = sum / #EntityData.StdDevList

    -- Ensure standard deviation is within the range [-132, 132]
    standardDeviation = math.max(-132, standardDeviation)
    standardDeviation = math.min(132, standardDeviation)

    -- Check if the standard deviation of the delta ticks is less than or equal to 0
    if standardDeviation < 0 then
        Detections.StrikePlayer("Sequence Burst", entity)
        return true -- player is bursting packets
    end

    record.EntityData = EntityData
    DataBase[steamId] = record
    -- Check if the standard deviation of the delta ticks exceeds the maximum choke limit
    local minChoke = avgStdDev
    local maxChoke = minChoke + Menu.Main.ChokeDetection.MaxChoke
    if standardDeviation > maxChoke then
        Detections.StrikePlayer("Choking Packets", entity)
        return true -- player is choking packets
    else
        return false -- player is not choking packets
    end
end


-- Function to predict the eye angle two ticks ahead
local function PredictEyeAngleTwoTicksAhead(idx, currentAngle)
    if DataBase[idx].AngleHistory == nil or #DataBase[idx].AngleHistory < 2 then
        return nil
    end

    -- Calculate the average change in eye angles
    local averageChange = (DataBase[idx].AngleHistory[#DataBase[idx].AngleHistory] - DataBase[idx].AngleHistory[#DataBase[idx].AngleHistory - 1]) / 2

    -- Predict the future eye angle
    DataBase[idx].PredictedAngle = currentAngle + averageChange * 2
    return DataBase[idx].PredictedAngle
end

-- Function to check for aimbot
local function CheckAimbotFlick(HurtVictim, shooter)
    if HurtVictim == nil or shooter == nil then return false end

    local idx = shooter:GetIndex()
    local Wshooter = WPlayer.FromEntity(shooter)
    local shootAngles = Wshooter:GetEyeAngles()

    if DataBase[idx].AngleHistory == nil or #DataBase[idx].AngleHistory < 6 then
        DataBase[idx].AngleHistory = {shootAngles}
        return false
    end

    local shooterEyePos = Wshooter:GetEyePos()

    local attackerclass = shooter:GetPropInt("m_iClass")
    local AimPos = 4
    if attackerclass == 2 or attackerclass == 8 then
        AimPos = 1
    end

    local WHurtVictim = WPlayer.FromEntity(HurtVictim)
    local WictimEyePos = WHurtVictim:GetHitboxPos(AimPos)

    local AimbotAngle = Math.PositionAngles(shooterEyePos, WictimEyePos)
    local fov = Math.AngleFov(AimbotAngle, shootAngles)
    print("realFov: "..fov)

    local FovDelta = Math.AngleFov(AimbotAngle, DataBase[idx].AngleHistory[#DataBase[idx].AngleHistory])
    if Menu.Main.debug == true then print(shooter:GetName(), "Fov Delta ", FovDelta) end

    if FovDelta > Menu.Aimbotfov then
        Detections.StrikePlayer("Aimbot", shooter)
    end

    return true
end

-- Event hook function
local function event_hook(ev)
    -- Return if the event is not a player hurt event
    if ev:GetName() ~= "player_hurt" then
        -- Get the entities involved in the event
        local attacker = entities.GetByUserID(ev:GetInt("attacker"))
        if attacker ~= nil and DataBase[Detections.GetSteamID(attacker)] ~= nil
        and DataBase[Detections.GetSteamID(attacker)].detected == true then return end --skip detected players
        local Victim = entities.GetByUserID(ev:GetInt("userid"))
            if attacker == nil or Victim == nil then return end
            if Menu.Main.debug == false and attacker == pLocal then return end
            if Menu.Main.debug == false and TF2.IsFriend(attacker:GetIndex(), true) then return end
            if playerlist.GetPriority(attacker) == 10 then return end
            if attacker:IsDormant() then return end
            if Victim:IsDormant() then return end
            if not attacker:IsAlive() then return end
            local pWeapon = attacker:GetPropEntity("m_hActiveWeapon")
            if pWeapon:GetWeaponProjectileType() ~= 1 then return end --skip projectile weapons
        --print("pass")
        --update lastattacker and lastHurtVictim
        shooter = attacker
        HurtVictim = Victim
        CheckAimbotFlick(HurtVictim , shooter)
    end
end

function Detections.CheckForCheaters()
    local DebugMode = Menu.Main.debug
    -- Check if the DataBase is not nil
    if not DataBase then
        Log:Warn("Database is nil")
        return
    end

    for _, entity in ipairs(players) do
        local steamid = Detections.GetSteamID(entity)

        -- Skip if entity is nil, dormant, dead, or a friend (in non-debug mode)
        if not entity or entity:IsDormant() or not entity:IsAlive() or (not DebugMode and TF2.IsFriend(entity:GetIndex(), true)) then
            goto continue
        end

        -- Get the record for the player
        local Record = Config.GetRecord(steamid)
        -- If the record doesn't exist or doesn't have EntityData, initialize it with defaultRecord
        if not Record then
            DataBase[steamid] = defaultRecord -- Assuming defaultRecord structure
            Record = DataBase[steamid]
        elseif not Record.EntityData then
            Record.EntityData = {}
        end

        --Skip if player is detected as a cheater
        if Config.IsKnownCheater(steamid) then
            --print(Record.Name .. " or ".. entity:GetName() .. " is detected as a cheater")
            goto continue
        end

        local player = WPlayer.FromEntity(entity)
        local ViewAngles = player:GetEyeAngles()

        -- Initialize the AngleHistory table if it doesn't exist
        Record.EntityData.AngleHistory = Record.EntityData.AngleHistory or {}

        -- Store the player's view angle history
        table.insert(Record.EntityData.AngleHistory, ViewAngles)
        if #Record.EntityData.AngleHistory > 6 then
            table.remove(Record.EntityData.AngleHistory, 1)
        end

        -- Perform checks on the player
        if CheckAngles(player, entity) or
            CheckDuckSpeed(player, entity) or
            CheckBunnyHop(player, entity) or
            CheckChoke(player, entity) then
            break -- Assuming you want to stop checking after finding a cheater, otherwise remove this
        end

        ::continue::
    end

    -- Update globals
    Config.UpdateDataBase(DataBase)
end

callbacks.Unregister("FireGameEvent", "unique_event_hook")                 -- unregister the "FireGameEvent" callback
callbacks.Register("FireGameEvent", "unique_event_hook", event_hook)         -- register the "FireGameEvent" callback

return Detections