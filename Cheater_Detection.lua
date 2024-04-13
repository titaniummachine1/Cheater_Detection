--[[
    Cheater Detection for Lmaobox
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credits:
    LNX (github.com/lnx00) for base scriptd
    Muqa for visuals and design assistance
    Alchemist for testing and party callout
]]

---@alias PlayerData { Angle: EulerAngles[], Position: Vector3[], SimTime: number[] }


---@type boolean, lnxLib
local libLoaded, lnxLib = pcall(require, "lnxLib")
assert(libLoaded, "lnxLib not found, please install it!")
assert(lnxLib.GetVersion() >= 0.981, "lnxLib version is too old, please update it!")

local TF2 = lnxLib.TF2
local Math, Conversion = lnxLib.Utils.Math, lnxLib.Utils.Conversion
local WPlayer, WPR = TF2.WPlayer, TF2.WPlayerResource
local Helpers = lnxLib.TF2.Helpers
local Fonts = lnxLib.UI.Fonts

---@type boolean, ImMenu
local menuLoaded, ImMenu = pcall(require, "ImMenu")
assert(menuLoaded, "ImMenu not found, please install it!")
assert(ImMenu.GetVersion() >= 0.66, "ImMenu version is too old, please update it!")

local players = entities.FindByClass("CTFPlayer")

local pLocal = entities.GetLocalPlayer()
local WLocal = pLocal
local latin, latout = 0, 0

local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

if pLocal then
    playerlist.SetPriority(pLocal, 0)
end

local Menu = {
    StrikeLimit = 5,
    MaxTickDelta = 8,
    Aimbotfov = 3,
    AutoMark = true,
    BhopTimes = 5,
    debug = false,
    tags = true,
    partyCallaut = true
}


local Lua__fullPath = GetScriptName()
local Lua__fileName = Lua__fullPath:match("\\([^\\]-)$"):gsub("%.lua$", "")

local function CreateCFG(folder_name, table)
    local success, fullPath = filesystem.CreateDirectory(folder_name)
    local filepath = tostring(fullPath .. "/config.cfg")
    local file = io.open(filepath, "w")
    
    if file then
        local function serializeTable(tbl, level)
            level = level or 0
            local result = string.rep("    ", level) .. "{\n"
            for key, value in pairs(tbl) do
                result = result .. string.rep("    ", level + 1)
                if type(key) == "string" then
                    result = result .. '["' .. key .. '"] = '
                else
                    result = result .. "[" .. key .. "] = "
                end
                if type(value) == "table" then
                    result = result .. serializeTable(value, level + 1) .. ",\n"
                elseif type(value) == "string" then
                    result = result .. '"' .. value .. '",\n'
                else
                    result = result .. tostring(value) .. ",\n"
                end
            end
            result = result .. string.rep("    ", level) .. "}"
            return result
        end
        
        local serializedConfig = serializeTable(table)
        file:write(serializedConfig)
        file:close()
        printc( 255, 183, 0, 255, "["..os.date("%H:%M:%S").."] Saved Config to ".. tostring(fullPath))
    end
end

local function LoadCFG(folder_name)
    local success, fullPath = filesystem.CreateDirectory(folder_name)
    local filepath = tostring(fullPath .. "/config.cfg")
    local file = io.open(filepath, "r")

    if file then
        local content = file:read("*a")
        file:close()
        local chunk, err = load("return " .. content)
        if chunk then
            printc( 0, 255, 140, 255, "["..os.date("%H:%M:%S").."] Loaded Config from ".. tostring(fullPath))
            return chunk()
        else
            CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu) --saving the config
            print("Error loading configuration:", err)
        end
    end
end

local status, loadedMenu = pcall(function() 
    return assert(LoadCFG(string.format([[Lua %s]], Lua__fileName))) 
end) -- Auto-load config

-- Function to check if all expected functions exist in the loaded config
local function checkAllFunctionsExist(expectedMenu)
    for key, value in pairs(loadedMenu) do
        -- If the key from the loaded menu does not exist in the expected menu, return false
        if expectedMenu[key] == nil then
            return false
        end
    end
    return true
end

-- Execute this block only if loading the config was successful
if status then
    if checkAllFunctionsExist(Menu) and not input.IsButtonDown(KEY_LSHIFT) then
        Menu = loadedMenu
    else
        print("Config is outdated or invalid. Creating a new config.")
        CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu) -- Save the config
    end
else
    print("Failed to load config. Creating a new config.")
    CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu) -- Save the config
end


local prevData = {
    SimTime = {},
    pBhop = {}
} ---@type PlayerData

local playerData = {
    {
        entity = nil,
        strikes = 0,
        detected = false
    }
}

local function StrikePlayer(reason, player)
    local idx = player:GetIndex()

    -- Initialize strikes if needed
    if not playerData[idx] or playerData[idx].entity == nil then
        playerData[idx] = {
            entity = player,
            strikes = 0,
            detected = false
        }
    end

    if reason == "Invalid pitch" then -- isnta detect when anty aiming(Invalid Pitch)
        playerData[idx].strikes = Menu.StrikeLimit
    end

    -- Increment strikes
    playerData[idx].strikes = playerData[idx].strikes + 1

    -- Handle strike limit
    if playerData[idx].strikes < Menu.StrikeLimit then
        -- Print message
        if player and playerData[idx].strikes == math.floor(Menu.StrikeLimit / 2) then -- only call the player sus if hes has been flagged half of the total amount
            client.ChatPrintf(tostring("\x04[CD] \x03" .. player:GetName() .. "\x01 is \x07ffd500Suspicious \x01(\x04" .. reason.. "\x01)"))
            
            if Menu.AutoMark and player ~= pLocal then
                LastStrike = globals.TickInterval()
            end
        end
    else
            -- Print cheating message if player is detected and wanst noted before
        if player and not playerData[idx].detected then
            print(tostring("[CD] ".. player:GetName() .. " is cheating"))
                client.ChatPrintf(tostring("\x04[CD] \x03" .. player:GetName() .. " \x01is\x07ff0019 Cheating\x01! \x01(\x04" .. reason.. "\x01)"))
            if Menu.partyCallaut == true then
                client.Command("say_party ".. player:GetName() .." is Cheating " .. "(".. reason.. ")",true);
            end

            -- Set player as detected
            playerData[idx].detected = true

            -- Auto mark
            if Menu.AutoMark and player ~= pLocal then
                playerlist.SetPriority(player, 10)
            end
        end
    end
end

-- Detects rage pitch (looking up/down too much)
local function CheckAngles(player, entity)
    local angles = player:GetEyeAngles()
    if angles.pitch == 89.000 or angles.pitch == -89.000
    or angles.pitch >= 90 or angles.pitch <= -90 then
        StrikePlayer("Invalid pitch", entity)
        return true
    end
    return false
end


local tick_count = 0
-- Detects rage pitch (looking up/down too much)
local function CheckDuckSpeed(player, entity)
    local angles = player:GetEyeAngles()
    local flags = player:GetPropInt("m_fFlags")
    local OnGround = flags & FL_ONGROUND == 1
    local DUCKING = flags & FL_DUCKING == 2
    if OnGround
    and DUCKING then -- detects fake up/down/up/fakedown pitch settigns {lbox]
        local MaxDuckSpeed = entity:GetPropFloat("m_flMaxspeed") * 0.66 -- Update MaxSpeed based on the player's current state

        if entity:EstimateAbsVelocity():Length() >= MaxDuckSpeed then
        --and clientstate:GetChokedCommands() > 12 then
            local m_vecViewOffset = math.floor(pLocal:GetPropVector("m_vecViewOffset[0]").z) ; --check if fully crounched
           
            if m_vecViewOffset == 45 then
                tick_count = tick_count + 1
                if tick_count >= 66 then
                    StrikePlayer("Duck Speed", entity)
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


local function CheckBhop(pEntity, mData, entity)
    if not mData[pEntity] then
        mData[pEntity] = { pBhop = { 0, 0 }, iPlayerSuspicion = 0 }
    end

    local flags = pEntity:GetPropInt("m_fFlags")
    local bOnGround = flags & FL_ONGROUND == 1

    if bOnGround then
        mData[pEntity].pBhop[1] = 0 -- Reset the bhop count if the player is on the ground
    else
        mData[pEntity].pBhop[1] = mData[pEntity].pBhop[1] + 1 -- Increment the bhop count if the player is in the air
    end

    if mData[pEntity].pBhop[1] >= Menu.BhopTimes then
        mData[pEntity].iPlayerSuspicion = mData[pEntity].iPlayerSuspicion + 1 -- Increment the suspicion if the player consistently bhops
        mData[pEntity].pBhop[1] = 0 -- Reset the bhop count
        StrikePlayer("Bunny Hop", entity) --return true, mData[pEntity].pBhop[1] -- Return true if the suspicion threshold is reached
        return true
    end
    return false
end

-- Check if a player is choking packets (Fakelag, Doubletap)
local function CheckChoke(player, entity)
    local simTime = player:GetSimulationTime()
    local oldSimTime = prevData.SimTime[player:GetIndex()]

    if not oldSimTime then
        return false -- no previous
    end

    local delta = simTime - oldSimTime -- get difference between current and previous simtime

    if Menu.debug and delta == 0 then
        return false -- it's the local player rewinding time
    end

    local deltaTicks = Conversion.Time_to_Ticks(delta)
    if deltaTicks >= Menu.MaxTickDelta then
        StrikePlayer("Choking Packets", player)
        return true -- player is choking packets
    else
        return false --is not choking packets
    end
end


--[[local function isValidName(player, name, entity)

    for i, pattern in ipairs(BOTPATTERNS) do
      if string.find(name, pattern) then
        StrikePlayer("Bot Name", entity, player)
      end
    end
end]]

local HurtVictim = nil
local shooter = nil

-- Event hook function
local function event_hook(ev)
    -- Return if the event is not a player hurt event
    if ev:GetName() ~= "player_hurt" then
        return
    end

    -- Get the entities involved in the event
    local attacker = entities.GetByUserID(ev:GetInt("attacker"))
    if attacker ~= nil and playerData[attacker:GetIndex()] ~= nil
    and playerData[attacker:GetIndex()].detected == true then return end --skip detected players
    local Victim = entities.GetByUserID(ev:GetInt("userid"))
        if attacker == nil or Victim == nil then return end
        if Menu.debug == false and attacker == pLocal then return end
        if Menu.debug == false and TF2.IsFriend(attacker:GetIndex(), true) then return end
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
end

local lastTwoAngles = {}
local predictedAngles = {}

-- Function to predict the eye angle two ticks ahead
local function PredictEyeAngleTwoTicksAhead(idx, currentAngle)
    if lastTwoAngles[idx] == nil then
        lastTwoAngles[idx] = {}
    end

    -- If we don't have enough data, return nil
    if #lastTwoAngles[idx] < 2 then
        return nil
    end

    -- Calculate the average change in eye angles
    local averageChange = (lastTwoAngles[idx][2] - lastTwoAngles[idx][1]) / 2

    -- Predict the future eye angle
    predictedAngles[idx] = currentAngle + averageChange * 2
    if predictedAngles[idx] == nil then print("nil prediction") end
    return predictedAngles[idx]
end

local lastAngles = {}
local currentAngles = {}
local AimbotStage = 0

-- Function to check for aimbot
local function CheckAimbot()
    if HurtVictim == nil or shooter == nil then return false end

    local idx = shooter:GetIndex()
    local Wshooter = WPlayer.FromEntity(shooter)
    local shootAngles = Wshooter:GetEyeAngles()

    if lastAngles[idx] == nil then
        lastAngles[idx] = shootAngles
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
    if AimbotStage == 0 then
        local FovDelta = Math.AngleFov(AimbotAngle, lastAngles[idx])
        if Menu.debug == true then print(shooter:GetName(), "Stage 0: Fov Delta ", FovDelta) end

        if FovDelta > Menu.Aimbotfov then
            AimbotStage = 1
        else
            AimbotStage = 0
            return false
        end
    elseif AimbotStage == 1 then
        -- Predict future eye angle two ticks ahead
        local futureAngle = PredictEyeAngleTwoTicksAhead(idx, shootAngles)

        local FovDelta = Math.AngleFov(shootAngles, lastAngles[idx])
        if Menu.debug == true then print(shooter:GetName(), "Stage 1: Fov Delta ", FovDelta) end

        if FovDelta >= 0.2 then
            if Menu.debug == true then print(futureAngle) end
            --if futureAngle and Math.AngleFov(shootAngles, futureAngle) < 0.4 then
                StrikePlayer("Aimbot", shooter)
            --end
        end

        AimbotStage = 0
        lastAngles[idx] = shootAngles -- Update the last angle for this player
        return true
    end

    lastAngles[idx] = shootAngles -- Update the last angle for this player
    return true
end


local function OnCreateMove(userCmd)
    pLocal = entities.GetLocalPlayer()
    if pLocal == nil then return end -- Skip if local player is nil

    WLocal = WPlayer.FromEntity(pLocal)
    players = entities.FindByClass("CTFPlayer")

    latin, latout = clientstate.GetLatencyIn() * 1000, clientstate.GetLatencyOut() * 1000 -- Convert to ms

    local connectionState = entities.GetPlayerResources():GetPropDataTableInt("m_iConnectionState")[WLocal:GetIndex()]

    -- Get current data
    local currentData = {
        SimTime = {},
        pBhop = {}
    }

    local packetloss = false
    if (latin + latout) < 200 and prevData then
        local localSimTime = WLocal:GetSimulationTime()
        local localOldSimTime = prevData.SimTime[WLocal:GetIndex()]
        if localOldSimTime then
            local localDelta = localSimTime - localOldSimTime
            local localDeltaTicks = Conversion.Time_to_Ticks(localDelta)
            if localDeltaTicks >= Menu.MaxTickDelta or clientstate:GetChokedCommands() >= Menu.MaxTickDelta then
                packetloss = true
            end
        end
    end

    if CheckAimbot() == true then goto Aimbot end  --detect silent aimbot users

    for i = 1, #players do
        local entity = players[i]
        if entity == nil then goto continue end -- Skip if player is nil
        local idx = entity:GetIndex()
        --print(predictViewAngle(idx, 2))
        if playerData[idx] and playerData[idx].detected == true --dont check detected players
        or entity:IsDormant()
        or Menu.debug == false and attacker == pLocal
        or not entity:IsAlive()
        or Menu.debug == false and TF2.IsFriend(entity:GetIndex(), true)
        then goto continue end -- Skip if player is nil, dormant or dead

        if playerlist.GetPriority(entity) == 10 then
            -- Set player as detected
            if playerData[idx] then
                playerData[idx].detected = true
            else
                -- Initialize strikes if needed
                playerData[idx] = {
                    entity = entity,
                    strikes = Menu.StrikeLimit,
                    detected = true
                }
            end
            goto continue
        end -- Skip local player

        if Menu.debug == false and TF2.IsFriend(idx, true) then goto continue end -- dont detect friends

        local player = WPlayer.FromEntity(entity)
        currentData.SimTime[idx] = player:GetSimulationTime() --store simulation time of target players

        if HurtVictim ~= nil then goto continue end --skip aimbot check if someone gets killed or damaged

        lastAngles[idx] = player:GetEyeAngles() --store viewangles of target players

        --if isValidName(player, entity:GetName(), entity) == true then break end --detect bot names

        if CheckAngles(player, entity) == true then break end --detects rage cheaters and bots

        if CheckDuckSpeed(player, entity) == true then break end --detects DuckSpeed

        if CheckBhop(player, currentData, entity) == true then break end --detects rage Bhop

        --local XconnectionState = entities.GetPlayerResources():GetPropDataTableInt("m_iConnectionState")[idx]
        if prevData then
            if not packetloss and connectionState == 1 or Menu.debug == true then
                if CheckChoke(player, entity) == true then break end --detects rage Fakelag
            end
        end

        if not lastTwoAngles or lastTwoAngles[idx] == nil then
            lastTwoAngles[idx] = {}
        end

        lastAngles[idx] = player:GetEyeAngles() --aimbot angle save for later

        table.insert(lastTwoAngles[idx], currentAngle)

        -- Keep only the last two angles
        if #lastTwoAngles[idx] > 2 then
            table.remove(lastTwoAngles[idx], 1)
        end

        ::continue::
    end
    prevData = currentData

    ::Aimbot::
    --update globals
    if AimbotStage == 0 then
        HurtVictim = nil
        shooter = nil
    end
end


local lastToggleTime = 0
local Lbox_Menu_Open = true
local toggleCooldown = 0.2  -- 200 milliseconds

local function toggleMenu()
    local currentTime = globals.RealTime()
    if currentTime - lastToggleTime >= toggleCooldown then
        Lbox_Menu_Open = not Lbox_Menu_Open  -- Toggle the state
        lastToggleTime = currentTime  -- Reset the last toggle time
    end
end

local function doDraw()
    draw.SetFont(Fonts.Verdana)
    draw.Color(255, 255, 255, 255)

    -- Inside your OnCreateMove or similar function where you check for input
    if input.IsButtonDown(KEY_INSERT) then  -- Replace 72 with the actual key code for the button you want to use
        toggleMenu()
    end
        if Menu.tags and not engine.Con_IsVisible() and not engine.IsGameUIVisible() then
            if Menu.debug then
                draw.Color(255, 0, 0, 255)
                draw.Text(20, 120, "Debug Mode!!! Some Featheres Might malfunction")
            end
            draw.Color(255, 255, 255, 255)
            draw.SetFont(tahoma_bold)
            if playerData then
                for idx, data in pairs(playerData) do
                    local entity = data.entity
                    local strikes = data.strikes
                    local detected = data.detected

                    if not entity or not entity:IsValid() or entity:IsDormant() or not entity:IsAlive() then goto continue end
                        if playerData[idx].strikes >= math.floor(Menu.StrikeLimit / 2) then
                            local tagText, tagColor
                            local padding = Vector3(0, 0, 7)
                            local headPos = (entity:GetAbsOrigin() + entity:GetPropVector("localdata", "m_vecViewOffset[0]")) + padding
                            if gui.GetValue("CLASS") == "icon" and gui.GetValue("AIM RESOLVER") == 0 then
                                    headPos = headPos + Vector3(0, 0, 17)
                            end
                            local feetPos = entity:GetAbsOrigin() - padding
                            local headScreenPos = client.WorldToScreen(headPos)
                            local feetScreenPos = client.WorldToScreen(feetPos)
                            if headScreenPos ~= nil and feetScreenPos ~= nil then
                                local height = math.abs(headScreenPos[2] - feetScreenPos[2])
                                local width = height * 0.6
                                local x = math.floor(headScreenPos[1] - width * 0.5)
                                local y = math.floor(headScreenPos[2])
                                local w = math.floor(width)
                                local h = math.floor(height)
                                if detected then
                                    tagText = "CHEATER"
                                    tagColor = {255,0,0,255}
                                else
                                    tagText = "SUSPICIOUS"
                                    tagColor = {255,255,0,255}
                                end
                                draw.Color(table.unpack(tagColor))
                                local tagWidth, tagHeight = draw.GetTextSize(tagText)
                                if gui.GetValue("AIM RESOLVER") == 1 then --fix bug when arrow of resolver clips with tag
                                    y = y - 20
                                end
                                draw.Text(math.floor(x + w / 2 - (tagWidth / 2)), y - 30, tagText)
                            end
                        end
                    ::continue::
                end
            end
        end

        if Lbox_Menu_Open == true and ImMenu.Begin("Cheater Detection", true) then

            -- Strike Limit Slider
            ImMenu.BeginFrame(1)
            Menu.StrikeLimit = ImMenu.Slider("Strikes Limit", Menu.StrikeLimit, 4, 17)
            ImMenu.EndFrame()

            -- Max Tick Delta Slider
            ImMenu.BeginFrame(1)
            Menu.MaxTickDelta = ImMenu.Slider("Max Packet Choke", Menu.MaxTickDelta, 8, 22)
            ImMenu.EndFrame()
            
            -- Max Tick Delta Slider
            ImMenu.BeginFrame(1)
            Menu.BhopTimes = ImMenu.Slider("Max Bhops", Menu.BhopTimes, 4, 15)
            ImMenu.EndFrame()

            -- Aimbot FOV Slider
            ImMenu.BeginFrame(1)
            Menu.Aimbotfov = ImMenu.Slider("Aimbot Fov", Menu.Aimbotfov, 1, 180)
            ImMenu.EndFrame()

            -- Menu
            ImMenu.BeginFrame(1)
            Menu.AutoMark = ImMenu.Checkbox("Auto Mark", Menu.AutoMark)
            Menu.tags = ImMenu.Checkbox("Draw Tags", Menu.tags)
            ImMenu.EndFrame()

            -- Menu
            ImMenu.BeginFrame(1)
            Menu.partyCallaut = ImMenu.Checkbox("Party Callout", Menu.partyCallaut)
            Menu.debug = ImMenu.Checkbox("Debug", Menu.debug)
            ImMenu.EndFrame()

            ImMenu.End()
        end
    end

--[[ Remove the menu when unloaded ]]--
local function OnUnload()                                -- Called when the script is unloaded
    UnloadLib() --unloading lualib
    CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu) --saving the config
    client.Command('play "ui/buttonclickrelease"', true) -- Play the "buttonclickrelease" sound
end

--[[ Unregister previous callbacks ]]--
callbacks.Unregister("CreateMove", "Cheater_detection")                     -- unregister the "CreateMove" callback
callbacks.Unregister("FireGameEvent", "unique_event_hook")                 -- unregister the "FireGameEvent" callback
callbacks.Unregister("Unload", "MCT_Unload")                                -- unregister the "Unload" callback
callbacks.Unregister("Draw", "MCT_Draw")                                   -- unregister the "Draw" callback

--[[ Register callbacks ]]--
callbacks.Register("CreateMove", "Cheater_detection", OnCreateMove)        -- register the "CreateMove" callback
callbacks.Register("FireGameEvent", "unique_event_hook", event_hook)         -- register the "FireGameEvent" callback
callbacks.Register("Unload", "MCT_Unload", OnUnload)                         -- Register the "Unload" callback
callbacks.Register("Draw", "MCT_Draw", doDraw)                              -- Register the "Draw" callback 

--[[ Play sound when loaded ]]--
client.Command('play "ui/buttonclick"', true) -- Play the "buttonclick" sound when the script is loaded
