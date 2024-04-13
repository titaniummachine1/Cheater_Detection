--[[ Annotations ]]
---@alias PlayerData { Angle: EulerAngles[], Position: Vector3[], SimTime: number[] }


--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local G = require("Cheater_Detection.Globals")

local Lib = Common.Lib

local TF2 = Lib.TF2
local Math, Conversion = Lib.Utils.Math, Lib.Utils.Conversion
local WPlayer, WPR = TF2.WPlayer, TF2.WPlayerResource
local Helpers = Lib.TF2.Helpers

--[[ Variables ]]
local Detections = {}

--[[functions ]]

local LastStrike = 0
function Detections.StrikePlayer(reason, player)
    if not player or not reason then
        Log:Warn("Invalid parameters to StrikePlayer")
        return
    end

    local steamId = Common.GetSteamID(player)
    if not steamId then
        Log:Warn("Failed to get SteamID for player %s", player:GetName() or "nil")
        return
    end

    if not DataBase then
        Log:Warn("Database is nil")
        DataBase = {} -- Initialize DataBase if it's nil
    end

    -- Initialize the player's record if it doesn't exist
    local record = G.PlayerData[steamId] or { strikes = 0, isCheater = false }

    -- Check if the player is already detected as a cheater
    if record.isCheater == true then
        print("Player %s is already detected as a cheater", player:GetName())
        return -- Don't strike a player that's already detected
    end

    record.strikes = record.strikes + 1 -- Increment strikes 

    -- Handle strikes threshold
    if record.strikes < G.Menu.Main.StrikeLimit then
        -- If less than 132 ticks have passed since the last strike, return immediately
        if LastStrike and globals.TickCount() - (LastStrike or 0) < 132 then
            Log:Warn("Less than 66 ticks have passed since the last strike for player %s", player:GetName())
            return
        end

        -- Print message
        if player and record.strikes == math.floor(G.Menu.Main.StrikeLimit / 2) then -- only call the player sus if hes has been flagged half of the total amount
            client.ChatPrintf(tostring("\x04[CD] \x03" .. player:GetName() .. "\x01 is \x07ffd500Suspicious \x01(\x04" .. reason.. "\x01)"))

            if G.Menu.Visuals.AutoMark and player ~= pLocal then
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
            if G.Menu.Visuals.partyCallaut == true then
                client.Command("say_party ".. player:GetName() .." is Cheating " .. "(".. reason.. ")",true);
            end

            -- Set player as detected
            record.Name = player:GetName()
            record.cause = reason
            record.date = os.date("%Y-%m-%d %H:%M:%S")

            -- Auto mark
            if G.Menu.Visuals.AutoMark and player ~= pLocal then
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
function Detections.CheckAngles(player, entity)
    if G.Menu.Main.AntyAimDetection == false then return end

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
function Detections.CheckDuckSpeed(player, entity)
    if G.Menu.Main.DuckSpeedDetection == false then return end

    local angles = player:GetEyeAngles()
    local flags = player:GetPropInt("m_fFlags")
    local OnGround = flags & FL_ONGROUND == 1
    local DUCKING = flags & FL_DUCKING == 2
    if OnGround
    and DUCKING then -- detects fake up/down/up/fakedown pitch settigns {lbox]

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

function Detections.CheckBunnyHop(pEntity, entity)
    if not Menu.Main.BhopDetection.Enable then
        return -- Early return if bhop detection is disabled or SteamID retrieval failed
    end

    local steamId = Common.GetSteamID(pEntity)
    if not steamId then
        Log:Warn("Failed to get SteamID for player %s", pEntity:GetName() or "nil")
        return
    end

    -- Create a record for the player if it doesn't exist
    if not PlayerData[steamId] then
        PlayerData[steamId] = DefaultPlayerData
    end

    local record = PlayerData[steamId]
    local flags = pEntity:GetPropInt("m_fFlags")
    local onGround = flags & FL_ONGROUND == 1
    local vel = pEntity:EstimateAbsVelocity() -- Assuming this function returns a Vector3 of the player's velocity

    -- Check if the player was able to jump in the previous iteration
    if record.CanJump then
        if onGround then
            record.Bhops = 0 -- Reset counter when player lands
            record.CanJump = false
        elseif record.LastZVelocity < vel.z and (vel.z == 271 or vel.z == 277) then
            -- Player has performed a jump without the server registering as touching the ground
            record.Bhops = record.Bhops + 1
            if record.Bhops >= Menu.Main.BhopDetection.MaxBhop then
                -- Detected bunny hopping
                Detections.StrikePlayer("Bunny Hop", entity)
                record.Bhops = 0 -- Reset counter after detection
            end
        end
    else
        record.CanJump = onGround
    end

    -- Store the last on-ground state and vertical velocity for the next check
    record.LastZVelocity = vel.z
end

function Detections.CheckChoke(pEntity, entity)
    if Menu.Main.ChokeDetection.Enable == false then return false end
    local steamId = Common.GetSteamID(pEntity)
    if not steamId then
        Log:Warn("Failed to get SteamID for player %s", pEntity:GetName() or "nil")
        return false
    end

    if not PlayerData then
        Log:Warn("PlayerData is nil")
        PlayerData = {} -- Initialize PlayerData if it's nil
    end

    local record = PlayerData[steamId]
    if not record or not record.SimTimes or not record.StdDevList then -- Fixed logic check here
        record = DefaultPlayerData -- Proper deep copy to avoid shared reference
        PlayerData[steamId] = record
    end

    local simTime = pEntity:GetSimulationTime()
    table.insert(record.SimTimes, simTime) -- Add the current simulation time to the queue

    if #record.SimTimes > 33 then
        table.remove(record.SimTimes, 1) -- Remove the oldest simulation time if the queue is too long
    end

    local deltaTicks = {}
    for i = 2, #record.SimTimes do
        local delta = record.SimTimes[i] - record.SimTimes[i - 1]
        table.insert(deltaTicks, Conversion.Time_to_Ticks(delta))
    end

    if #deltaTicks < 30 then return false end -- Ensure there are enough delta ticks for analysis

    local meanDeltaTick = 0
    for _, deltaTick in ipairs(deltaTicks) do
        meanDeltaTick = meanDeltaTick + deltaTick
    end
    meanDeltaTick = meanDeltaTick / #deltaTicks

    local sumOfSquaredDifferences = 0
    for _, deltaTick in ipairs(deltaTicks) do
        local difference = deltaTick - meanDeltaTick
        sumOfSquaredDifferences = sumOfSquaredDifferences + difference * difference
    end

    local variance = sumOfSquaredDifferences / (#deltaTicks - 1)
    local standardDeviation = math.sqrt(variance)

    -- Clamp standard deviation to a minimum of -132 to handle specific check
    standardDeviation = math.max(-132, standardDeviation)

    -- Sequence burst detection logic using the clamped standard deviation
    if standardDeviation == -132 then
        Detections.StrikePlayer("Sequence Burst", entity)
        return true -- Player is using a sequence burst exploit
    end

    table.insert(record.StdDevList, standardDeviation) -- Update the list of standard deviations
    if #record.StdDevList > 33 then
        table.remove(record.StdDevList, 1)
    end

    local avgStdDev = 0
    for _, stdDev in ipairs(record.StdDevList) do
        avgStdDev = avgStdDev + stdDev
    end
    avgStdDev = avgStdDev / #record.StdDevList

    local maxChoke = avgStdDev + Menu.Main.ChokeDetection.MaxChoke
    if standardDeviation > maxChoke then
        Detections.StrikePlayer("Choking Packets", entity)
        return true -- Player is choking packets
    else
        return false -- Player is not choking packets
    end
end


-- Function to predict the eye angle two ticks ahead
function Detections.PredictEyeAngleTwoTicksAhead(idx, currentAngle)
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
function CheckAimbotFlick(HurtVictim, shooter)
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
        if attacker ~= nil and DataBase[Common.GetSteamID(attacker)] ~= nil
        and DataBase[Common.GetSteamID(attacker)].detected == true then return end --skip detected players
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
        --CheckAimbotFlick(HurtVictim , shooter)
    end
end

callbacks.Unregister("FireGameEvent", "unique_event_hook")                 -- unregister the "FireGameEvent" callback
callbacks.Register("FireGameEvent", "unique_event_hook", event_hook)         -- register the "FireGameEvent" callback

return Detections