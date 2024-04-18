local Detections = {}

--[[ Annotations ]]
---@alias PlayerData { Angle: EulerAngles[], Position: Vector3[], SimTime: number[] }

--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local Config = require("Cheater_Detection.Config")
local G = require("Cheater_Detection.Globals")

local Lib = Common.Lib

local TF2 = Common.TF2
local Math, Conversion = Common.Math, Common.Conversion
local WPlayer, PR = TF2.WPlayer, TF2.PlayerResource
local Helpers = Common.Helpers
local Log = Common.Log
Log.Level = 0

--[[functions ]]

function Detections.StrikePlayer(reason, player)
    -- Validate parameters
    if not player or not reason then
        Log:Warn("Invalid parameters to StrikePlayer")
        return
    end

    -- Get the player's SteamID
    local steamId = Common.GetSteamID64(player)
    if not steamId then
        local errormsg = ("Failed to get SteamID for player: " ..  (player:GetName() or "nil"))
        error(errormsg)
        return
    end

    -- Initialize the database if it's nil
    if not G.PlayerData[steamId]
    or G.PlayerData[steamId] == nil then
        G.PlayerData[steamId] = G.DefaultPlayerData
    end

    -- Increment the player's strikes
    G.PlayerData[steamId].info.Strikes = G.PlayerData[steamId].info.Strikes + 1

    -- If the player has reached the strike limit, mark them as a cheater
    if G.PlayerData[steamId].info.Strikes >= G.Menu.Main.StrikeLimit then
        -- If the player is not already marked as a cheater, print a cheating message
        if G.PlayerData[steamId].info.isCheater and Common.IsCheater(steamId) and G.DataBase[steamId] then
            print(string.format("Player %s is already marked as cheater", player:GetName()))
        else
            print(string.format("[CD] %s is cheating", player:GetName()))
            client.ChatPrintf(string.format("\x04[CD] \x03%s \x01is\x07ff0019 Cheating\x01! \x01(\x04%s\x01)", player:GetName(), reason))
            if G.Menu.Visuals.partyCallaut then
                client.Command(string.format("say_party %s is Cheating (%s)", player:GetName(), reason), true)
            end

            -- Update the player's record
            G.PlayerData[steamId].info.Name = player:GetName()
            G.PlayerData[steamId].info.Cause = reason
            G.PlayerData[steamId].info.Date = os.date("%Y-%m-%d %H:%M:%S")
            G.PlayerData[steamId].info.LastDetectionTime = globals.TickCount()
            G.PlayerData[steamId].info.isCheater = true

            G.DataBase[steamId] = G.defaultRecord
            G.DataBase[steamId].Name = player:GetName()
            G.DataBase[steamId].Cause = reason
            G.DataBase[steamId].Date = os.date("%Y-%m-%d %H:%M:%S")

            -- Save the database to a file
            Config.SaveDatabase(G.DataBase)

            -- Auto mark
            if G.Menu.Visuals.AutoMark and player ~= pLocal then
                playerlist.SetPriority(player, 10)
            end
        end
    elseif G.PlayerData[steamId].info.Strikes == math.floor(G.Menu.Main.StrikeLimit / 2) then
        -- If less than 66 ticks have passed since the last strike, return immediately
        if G.PlayerData[steamId].info.LastStrike and (globals.TickCount() - G.PlayerData[steamId].info.LastStrike) < 66 then
            Log:Warn(string.format("player %s triggered AC too fast", player:GetName()))
            return
        end

        -- If the player has reached half the strike limit, print a suspicious message
        client.ChatPrintf(string.format("\x04[CD] \x03%s\x01 is \x07ffd500Suspicious \x01(\x04%s\x01)", player:GetName(), reason))

        -- Auto mark
        if G.Menu.Visuals.AutoMark and player ~= pLocal then
            playerlist.SetPriority(player, 5)
        end
    end

    -- Update LastStrike
    G.PlayerData[steamId].info.LastStrike = globals.TickCount()
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
        local MaxDuckSpeed = entity:GetPropFloat("m_flMaxspeed") * 0.66 -- Update MaxSpeed based on the player's current state

        if entity:EstimateAbsVelocity():Length() > MaxDuckSpeed then
        --and clientstate:GetChokedCommands() > 12 then
            local m_vecViewOffset = math.floor(player:GetViewOffset().z) --check if fully crounched

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

function Detections.KnownCheater(entity)
    if Common.IsCheater(Common.GetSteamID64(entity)) then
        Detections.StrikePlayer("Known Cheater", entity)
        return
    end
end

function Detections.CheckBunnyHop(pEntity, entity)
    if not G.Menu.Main.BhopDetection.Enable then
        return -- Early return if bhop detection is disabled or SteamID retrieval failed
    end

    local steamId = Common.GetSteamID64(pEntity)
    if not steamId then
        Log:Warn("Failed to get SteamID for player %s", pEntity:GetName() or "nil")
        return
    end

    -- Create a record for the player if it doesn't exist
    if not G.PlayerData[steamId] then
        G.PlayerData[steamId] = G.DefaultPlayerData
    end

    local flags = pEntity:GetPropInt("m_fFlags")
    local onGround = flags & FL_ONGROUND == 1
    local vel = pEntity:EstimateAbsVelocity() -- Assuming this function returns a Vector3 of the player's velocity

    -- Check if the player was able to jump in the previous iteration
    if G.PlayerData[steamId].info.LastOnGround then
        if onGround then
            G.PlayerData[steamId].Bhops = 0 -- Reset counter when player lands
            G.PlayerData[steamId].info.LastOnGround = true
        elseif G.PlayerData[steamId].info.LastVelocity.z < vel.z and (vel.z == 271 or vel.z == 277) then
            G.PlayerData[steamId].info.LastOnGround = false

            -- Player has performed a jump without the server registering as touching the ground
            G.PlayerData[steamId].info.bhop = G.PlayerData[steamId].info.bhop + 1
            if G.PlayerData[steamId].info.bhop >= G.Menu.Main.BhopDetection.MaxBhop then
                -- Detected bunny hopping
                Detections.StrikePlayer("Bunny Hop", entity)
                G.PlayerData[steamId].info.bhop = 0 -- Reset counter after detection
            end
        end
    else
        G.PlayerData[steamId].info.LastOnGround = true
    end

    -- Store the last on-ground state and vertical velocity for the next check
    G.PlayerData[steamId].info.LastVelocity.z = vel.z
end

function Detections.CheckPacketManipulation(pEntity, entity)
    if G.Menu.Main.ChokeDetection.Enable == false then return false end
    local steamId = Common.GetSteamID64(pEntity)

    if not G.PlayerData[steamId].History then return end
    if #G.PlayerData[steamId].History < 66 then return end

    local simTimeDiffs = {}
    for i = 2, #G.PlayerData[steamId].History do
        local diff = G.PlayerData[steamId].History[i].SimTime - G.PlayerData[steamId].History[i-1].SimTime
        local diffInTicks = Common.Conversion.Time_to_Ticks(diff)
        table.insert(simTimeDiffs, diffInTicks)
    end

    -- Get the threshold from the menu
    local threshold = G.Menu.Main.ChokeDetection.MaxChoke

    -- Check if any of the simulation time differences exceed the threshold and equal to the time it took for another anomaly to occur
    local lastAnomalyTick = 0
    for i, diffInTicks in ipairs(simTimeDiffs) do
        if diffInTicks > threshold then
            if i - lastAnomalyTick == diffInTicks then
                Detections.StrikePlayer("Packet Choke", entity)
                break
            end
            lastAnomalyTick = i
        end
    end

    -- Check if any of the simulation time differences are zero or negative and equal to the time it took for another anomaly to occur
    lastAnomalyTick = 0
    for i, diffInTicks in ipairs(simTimeDiffs) do
        if diffInTicks < 0 then
            print("anomal".. diffInTicks)
            if i - lastAnomalyTick == -diffInTicks then
                Detections.StrikePlayer("Dt/Warp", entity)
                break
            end
            lastAnomalyTick = i
        end
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
    if G.Menu.Main.debug == true then print(shooter:GetName(), "Fov Delta ", FovDelta) end

    if FovDelta > G.Menu.Aimbotfov then
        Detections.StrikePlayer("Aimbot", shooter)
    end

    return true
end

return Detections