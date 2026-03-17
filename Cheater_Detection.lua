--[[
    Cheater Detection for Lmaobox
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credits:
    LNX (github.com/lnx00) for base script
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
local Fonts = lnxLib.UI.Fonts

---@type boolean, ImMenu
local menuLoaded, ImMenu = pcall(require, "ImMenu")
assert(menuLoaded, "ImMenu not found, please install it!")
assert(ImMenu.GetVersion() >= 0.66, "ImMenu version is too old, please update it!")

local players = entities.FindByClass("CTFPlayer")

local pLocal = entities.GetLocalPlayer()
local WLocal = pLocal
local latencyIn, latencyOut = 0, 0

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
    partyCallout = true
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

-- Validate that loaded config has exactly the same keys as the default config
local function isConfigValid(loadedMenu, defaultMenu)
    for key in pairs(defaultMenu) do
        if loadedMenu[key] == nil then
            return false
        end
    end
    for key in pairs(loadedMenu) do
        if defaultMenu[key] == nil then
            return false
        end
    end
    return true
end

-- Execute this block only if loading the config was successful
if status then
    if isConfigValid(loadedMenu, Menu) and not input.IsButtonDown(KEY_LSHIFT) then
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
    SimTime = {}
} ---@type PlayerData

local playerData = {
    {
        entity = nil,
        strikes = 0,
        detected = false
    }
}

-- Persistent per-player tracking tables (indexed by entity index)
local bhopData = {}  -- airTicks counter for bhop detection
local duckData = {}  -- tick counter for duck-speed detection

local function InitPlayerData(idx, entity)
    playerData[idx] = {
        entity = entity,
        strikes = 0,
        detected = false
    }
end

local function StrikePlayer(reason, player)
    local idx = player:GetIndex()

    -- Initialize strikes if needed
    if not playerData[idx] or playerData[idx].entity == nil then
        InitPlayerData(idx, player)
    end

    -- Instant detection for anti-aim pitch (set to one below limit so the +1 below reaches the limit)
    if reason == "Invalid pitch" then
        playerData[idx].strikes = Menu.StrikeLimit - 1
    end

    -- Increment strikes
    playerData[idx].strikes = playerData[idx].strikes + 1

    -- Handle strike limit
    if playerData[idx].strikes < Menu.StrikeLimit then
        -- Print message
        if player and playerData[idx].strikes == math.floor(Menu.StrikeLimit / 2) then -- only call the player sus if they've been flagged half of the total amount
            client.ChatPrintf(tostring("\x04[CD] \x03" .. player:GetName() .. "\x01 is \x07ffd500Suspicious \x01(\x04" .. reason.. "\x01)"))

            if Menu.AutoMark and player ~= pLocal then
                playerlist.SetPriority(player, 5)
            end
        end
    else
        -- Print cheating message if player is detected and wasn't noted before
        if player and not playerData[idx].detected then
            print(tostring("[CD] ".. player:GetName() .. " is cheating"))
                client.ChatPrintf(tostring("\x04[CD] \x03" .. player:GetName() .. " \x01is\x07ff0019 Cheating\x01! \x01(\x04" .. reason.. "\x01)"))
            if Menu.partyCallout == true then
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

-- Detects anti-aim pitch (invalid up/down angle)
local function CheckAngles(player, entity)
    local angles = player:GetEyeAngles()
    if angles.pitch >= 89 or angles.pitch <= -89 then
        StrikePlayer("Invalid pitch", entity)
        return true
    end
    return false
end


-- Detects suspicious duck speed (moving too fast while crouched)
local function CheckDuckSpeed(player, entity)
    local idx = entity:GetIndex()
    local flags = player:GetPropInt("m_fFlags")
    local OnGround = flags & FL_ONGROUND == 1
    local DUCKING = flags & FL_DUCKING == 2
    if OnGround and DUCKING then
        local MaxDuckSpeed = entity:GetPropFloat("m_flMaxspeed") * 0.66

        if entity:EstimateAbsVelocity():Length() >= MaxDuckSpeed then
            local viewOffsetZ = math.floor(entity:GetPropVector("m_vecViewOffset[0]").z)

            if viewOffsetZ == 45 then
                duckData[idx] = (duckData[idx] or 0) + 1
                if duckData[idx] >= 66 then
                    StrikePlayer("Duck Speed", entity)
                    duckData[idx] = 0
                    return true
                end
                return true
            end
        end
        return false
    end
    duckData[idx] = 0
    return false
end


local function CheckBhop(entity)
    local idx = entity:GetIndex()
    if not bhopData[idx] then
        bhopData[idx] = { airTicks = 0 }
    end

    local flags = entity:GetPropInt("m_fFlags")
    local bOnGround = flags & FL_ONGROUND == 1

    if bOnGround then
        bhopData[idx].airTicks = 0
    else
        bhopData[idx].airTicks = bhopData[idx].airTicks + 1
    end

    if bhopData[idx].airTicks >= Menu.BhopTimes then
        bhopData[idx].airTicks = 0
        StrikePlayer("Bunny Hop", entity)
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
    --update lastattacker and lastHurtVictim
    shooter = attacker
    HurtVictim = Victim
end

local lastAngles = {}
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
    local victimEyePos = WHurtVictim:GetHitboxPos(AimPos)

    local AimbotAngle = Math.PositionAngles(shooterEyePos, victimEyePos)
    local fov = Math.AngleFov(AimbotAngle, shootAngles)
    if Menu.debug then print("realFov: "..fov) end
    if AimbotStage == 0 then
        local FovDelta = Math.AngleFov(AimbotAngle, lastAngles[idx])
        if Menu.debug then print(shooter:GetName(), "Stage 0: Fov Delta ", FovDelta) end

        if FovDelta > Menu.Aimbotfov then
            AimbotStage = 1
        else
            AimbotStage = 0
            return false
        end
    elseif AimbotStage == 1 then
        local FovDelta = Math.AngleFov(shootAngles, lastAngles[idx])
        if Menu.debug then print(shooter:GetName(), "Stage 1: Fov Delta ", FovDelta) end

        if FovDelta >= 0.2 then
            StrikePlayer("Aimbot", shooter)
        end

        AimbotStage = 0
        lastAngles[idx] = shootAngles
        return true
    end

    lastAngles[idx] = shootAngles
    return true
end


local function OnCreateMove(userCmd)
    pLocal = entities.GetLocalPlayer()
    if pLocal == nil then return end -- Skip if local player is nil

    WLocal = WPlayer.FromEntity(pLocal)
    players = entities.FindByClass("CTFPlayer")

    latencyIn, latencyOut = clientstate.GetLatencyIn() * 1000, clientstate.GetLatencyOut() * 1000 -- Convert to ms

    local connectionState = entities.GetPlayerResources():GetPropDataTableInt("m_iConnectionState")[WLocal:GetIndex()]

    -- Get current data
    local currentData = {
        SimTime = {}
    }

    local packetloss = false
    if (latencyIn + latencyOut) < 200 and prevData then
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
        if playerData[idx] and playerData[idx].detected == true --dont check detected players
        or entity:IsDormant()
        or Menu.debug == false and entity == pLocal
        or not entity:IsAlive()
        or Menu.debug == false and TF2.IsFriend(entity:GetIndex(), true)
        then goto continue end -- Skip if player is nil, dormant or dead

        if playerlist.GetPriority(entity) == 10 then
            -- Set player as detected
            if playerData[idx] then
                playerData[idx].detected = true
            else
                InitPlayerData(idx, entity)
                playerData[idx].strikes = Menu.StrikeLimit
                playerData[idx].detected = true
            end
            goto continue
        end -- Skip local player

        if Menu.debug == false and TF2.IsFriend(idx, true) then goto continue end -- dont detect friends

        local player = WPlayer.FromEntity(entity)
        currentData.SimTime[idx] = player:GetSimulationTime() --store simulation time of target players

        lastAngles[idx] = player:GetEyeAngles() --store viewangles for aimbot detection

        if HurtVictim ~= nil then goto continue end --skip checks if someone gets damaged

        if CheckAngles(player, entity) == true then goto continue end --detects rage cheaters and bots

        if CheckDuckSpeed(player, entity) == true then goto continue end --detects DuckSpeed

        if CheckBhop(entity) == true then goto continue end --detects rage Bhop

        if prevData then
            if not packetloss and connectionState == 1 or Menu.debug == true then
                if CheckChoke(player, entity) == true then goto continue end --detects rage Fakelag
            end
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

    if input.IsButtonDown(KEY_INSERT) then
        toggleMenu()
    end
        if Menu.tags and not engine.Con_IsVisible() and not engine.IsGameUIVisible() then
            if Menu.debug then
                draw.Color(255, 0, 0, 255)
                draw.Text(20, 120, "Debug Mode!!! Some Features Might Malfunction")
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
            
            -- Bhop Times Slider
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
            Menu.partyCallout = ImMenu.Checkbox("Party Callout", Menu.partyCallout)
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
