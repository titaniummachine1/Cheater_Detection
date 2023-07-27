--[[
    Cheater Detection for Lmaobox
    Author: titaniummachine1 (https://github.com/titaniummachine1)
    Credit for examples:
    LNX (github.com/lnx00) for base script
    Muqa for visuals and design help
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
local latin, latout = 0, 0

local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

local options = {
    StrikeLimit = 8,
    MaxTickDelta = 20,
    Aimbotfov = 12,
    AutoMark = true,
    BhopTimes = 6,
    debug = false,
    tags = true
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
        if targetPlayer and playerlist.GetPriority(player) > -1 and playerStrikes[idx] == math.floor(options.StrikeLimit / 2) then -- only call the player sus if hes has been flagged half of the total amount
            client.ChatPrintf(tostring("\x04[CD] \x03" .. player:GetName() .. "\x01 is \x07ffd500Suspicious"))
            if options.AutoMark and player ~= pLocal then
                playerlist.SetPriority(player, 5)
            end
        end
    else
        -- Print cheating message if player is not detected
        if targetPlayer and playerlist.GetPriority(player) > -1 and not detectedPlayers[player:GetIndex()] then
            printc(255, 216, 107, 255, tostring("[CD] ".. targetPlayer:GetName() .. " is cheating"))
            client.ChatPrintf(tostring("\x04[CD] \x03" .. player:GetName() .. " \x01is\x07ff0019 Cheating\x01! \x01(\x04" .. reason.. "\x01)"))

            -- Add player to detectedPlayers table
            detectedPlayers[player:GetIndex()] = true

            -- Auto mark
            if options.AutoMark and player ~= pLocal then
                playerlist.SetPriority(player, 10)
            end
        end
    end
end

-- Detects rage pitch (looking up/down too much)
local function CheckAngles(player, entity)
    local angles = player:GetEyeAngles()
    if angles.pitch == 89.00 or angles.pitch == -89.00
    or angles.pitch >= 90 or angles.pitch <= -90 then 
        StrikePlayer(player:GetIndex(), "Invalid pitch", entity)
    end
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
            tick_count = tick_count + 1
            if tick_count >= 66 then
                StrikePlayer(player:GetIndex(), "Duck Speed", entity)
                tick_count = 0
            end
        end
    end
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

    if mData[pEntity].pBhop[1] >= options.BhopTimes then
        mData[pEntity].iPlayerSuspicion = mData[pEntity].iPlayerSuspicion + 1 -- Increment the suspicion if the player consistently bhops
        mData[pEntity].pBhop[1] = 0 -- Reset the bhop count
        StrikePlayer(pEntity:GetIndex(), "Bunny Hop", entity) --return true, mData[pEntity].pBhop[1] -- Return true if the suspicion threshold is reached
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
    local Victim = entities.GetByUserID(ev:GetInt("userid"))
        if attacker == nil or Victim == nil then return end
        if options.debug == false and attacker == pLocal then return end
        if options.debug == false and TF2.IsFriend(attacker:GetIndex(), true) then return end
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

local lastAngles = {}
-- Function to check for aimbot
local function CheckAimbot()
	if HurtVictim == nil then return end -- when noone gets killed or damaged amingot check is not needed
        local idx = shooter:GetIndex()
    if lastAngles[idx] == nil then
        lastAngles[idx] = shooter:GetEyeAngles()
    end -- when noone gets killed or damaged amingot check is not needed

    local Wshooter = WPlayer.FromEntity(shooter)
    local shootAngles = Wshooter:GetEyeAngles() --get angles of player called

    -- Initialize variables
    local shooterTeam = shooter:GetTeamNumber()

    -- Get the shooter's position and view angles
    local shooterOrigin = Wshooter:GetEyePos()

        -- Get the attacker's class and aim position
        local attackerclass = shooter:GetPropInt("m_iClass")
        local AimPos = 4
        if attackerclass == 2 or attackerclass == 8 then
            AimPos = 1
        end

        -- Get the most propable hibox aimbot will target
        local WHurtVictim = WPlayer.FromEntity(HurtVictim)
        local playerOrigin = WHurtVictim:GetHitboxPos(AimPos) -- most propable aimbot target
        local AimbotAngle = Math.PositionAngles(shooterOrigin, playerOrigin)-- most propable aimbot angle
        -- Calculate the FOV between the shooter's view angles and the player's position
        local fov = Math.AngleFov(AimbotAngle, shootAngles)
        local PrewFov = Math.AngleFov(AimbotAngle, lastAngles[idx])
        local FovDelta = PrewFov - fov

        if options.debug == true then print(shooter:GetName(), fov, PrewFov, FovDelta) end

        if FovDelta > options.Aimbotfov then
            StrikePlayer(idx, "Aimbot", shooter)
        end
end

local function OnCreateMove(userCmd)--runs 66 times/second
    pLocal = entities.GetLocalPlayer()
    local WLocal = WPlayer.FromEntity(pLocal)
    players = entities.FindByClass("CTFPlayer")
    if pLocal == nil then goto continue end -- Skip if local player is nil

    latin, latout = clientstate.GetLatencyIn() * 1000, clientstate.GetLatencyOut() * 1000 -- Convert to ms

    local connectionState = entities.GetPlayerResources():GetPropDataTableInt("m_iConnectionState")[WLocal:GetIndex()]

    -- Get current data
    local currentData = {
        SimTime = {},
        pBhop = {}
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

        CheckDuckSpeed(player, entity) --detects DuckSpeed

        CheckBhop(player, currentData, entity)

        if HurtVictim == nil then
            lastAngles[idx] = player:GetEyeAngles() --store viewangles of target player
        end

        --local XconnectionState = entities.GetPlayerResources():GetPropDataTableInt("m_iConnectionState")[idx]
        if prevData then
            if connectionState == 1 or connectionState == 0 then
                if (latin + latout) < 200 then
                    CheckChoke(player, entity) --detects rage Fakelag
                end
            end
        end
        ::continue::
    end
    CheckAimbot() --detect silent aimbot users

    --update globals
    HurtVictim = nil
    shooter = nil
    prevData = currentData
    ::continue::
end

local strikes_default = options.StrikeLimit
local exampleSliderValue = 5 -- Default value for the example slider

local function doDraw()

    draw.SetFont(Fonts.Verdana)
    draw.Color(255, 255, 255, 255)

    
        if engine.IsGameUIVisible() and ImMenu.Begin("Cheater Detection", true) then

            local menuWidth, menuHeight = 250, 300
            local x, y = ImMenu.GetCurrentWindow().X, ImMenu.GetCurrentWindow().Y

            -- Strike Limit Slider
            ImMenu.BeginFrame(1)
            options.StrikeLimit = ImMenu.Slider("Strike Limit", options.StrikeLimit, 3, 20)
            ImMenu.EndFrame()

            -- Max Tick Delta Slider
            ImMenu.BeginFrame(1)
            options.MaxTickDelta = ImMenu.Slider("Max Tick Delta", options.MaxTickDelta, 1, 22)
            ImMenu.EndFrame()
            
            -- Max Tick Delta Slider
            ImMenu.BeginFrame(1)
            options.BhopTimes = ImMenu.Slider("Max Bhops", options.BhopTimes, 4, 15)
            ImMenu.EndFrame()

            -- Aimbot FOV Slider
            ImMenu.BeginFrame(1)
            options.Aimbotfov = ImMenu.Slider("Aimbot Fov", options.Aimbotfov, 2, 180)
            ImMenu.EndFrame()

            -- Options
            ImMenu.BeginFrame(1)
            options.AutoMark = ImMenu.Checkbox("Auto Mark", options.AutoMark)
            if options.AutoMark == true then 
                options.tags = ImMenu.Checkbox("Draw Tags", options.tags)
            end
            ImMenu.EndFrame()

            -- Options
            ImMenu.BeginFrame(1)
            options.debug = ImMenu.Checkbox("Debug", options.debug)
            ImMenu.EndFrame()
            --[[ Reset Button
            ImMenu.BeginFrame(1)
            if ImMenu.Button("Reset") then
                prevData = nil ---@type PlayerData
                playerStrikes = {} ---@type table<number, number>
                detectedPlayers = {} -- Table to store detected players
                lastAngles = {}
                client.Command('play "ui/buttonclick"', true) -- Play the "buttonclick" sound when the script is loaded
            end
            ImMenu.EndFrame()]]

            ImMenu.End()
        end

        if options.tags and not engine.Con_IsVisible() and not engine.IsGameUIVisible() then
            draw.SetFont(tahoma_bold)
            for i,p in pairs(players) do
                if playerlist.GetPriority(p) >= 5 and not p:IsDormant() and p:IsAlive() then
                    local tagText, tagColor
                    local padding = Vector3(0, 0, 7)
                    local headPos = (p:GetAbsOrigin() + p:GetPropVector("localdata", "m_vecViewOffset[0]")) + padding 
                    if gui.GetValue("CLASS") == "icon" and gui.GetValue("AIM RESOLVER") == 0 then
                            headPos = headPos + Vector3(0, 0, 17)
                    end
                    local feetPos = p:GetAbsOrigin() - padding
                    local headScreenPos = client.WorldToScreen(headPos)
                    local feetScreenPos = client.WorldToScreen(feetPos)
                    if headScreenPos ~= nil and feetScreenPos ~= nil then
                        local height = math.abs(headScreenPos[2] - feetScreenPos[2])
                        local width = height * 0.6
                        local x = math.floor(headScreenPos[1] - width * 0.5)
                        local y = math.floor(headScreenPos[2])
                        local w = math.floor(width)
                        local h = math.floor(height)
                        tagText = "SUSPICIOUS"
                        tagColor = {255,255,0,255}
                        if playerlist.GetPriority(p) == 10 then 
                            tagText = "CHEATER"
                            tagColor = {255,0,0,255}
                        end
                        draw.Color(table.unpack(tagColor))
                        local tagWidth, tagHeight = draw.GetTextSize(tagText)
                        if gui.GetValue("AIM RESOLVER") == 1 then --fix bug when arrow of resolver clips with tag
                            y = y - 20
                        end
                        draw.Text(math.floor(x + w / 2 - (tagWidth / 2)), y - 30, tagText)
                    end
                end
            end
        end
    end

local function OnUnload()-- Called when the script is unloaded
    UnloadLib() --unloading lualib
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