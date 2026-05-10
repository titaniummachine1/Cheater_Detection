local camera_x_position = 25
local camera_y_position = 300
local camera_width = 500
local camera_height = 300
local fullscreen_width, fullscreen_height = 0, 0

-- User configurable options
local infinite_spectate = true  -- Will only work in casual mode regardless of this setting
local hide_player_model = false -- Set this to false to disable the first-person player model invisibility

-- Cosmetic hiding settings (added from nohats.lua)
local cosmetic_settings = {
    hide_hats = true,      -- Hide all hats
    hide_misc = true,      -- Hide misc items
    hide_botkillers = true -- Hide botkiller attachments
}

-- Camera view settings
local camera_view_mode = "offset" -- "raw" or "offset"
local forward_offset = 16.5       -- How far forward to offset the camera in "offset" mode
local upward_offset = 12          -- How far upward to offset the camera in "offset" mode

-- Constants
local MAX_KILLFEED_ENTRIES = 8

-- Camera control variables
local camera_position = Vector3(0, 0, 0)
local camera_angles = EulerAngles(0, 0, 0)
local own_view_angles = EulerAngles(0, 0, 0)
local camera_speed = 10
local target_player = nil
local current_enemy_index = 1
local visited_players = {}
local first_person_mode = false
local fullscreen_mode = false
local free_camera = false
local last_key_press = 0
local key_delay = 0.2
local MOUSE_SENSITIVITY = 0.06
local last_killer = nil
local persistent_fullscreen = false
local death_time = 0
local current_wave_start = 0
local has_spawned_once = false
local is_in_game = false
local stored_class = nil
local spectate_locked = false
local current_all_player_index = 1
local friendly_player_index = 1
local is_spectating = false
local spectate_anchor_player = nil
local vanish_mode = false

local desired_engine_spectate_target = nil
local last_engine_spectate_uid = nil
local last_engine_spectate_time = 0
local last_overlay_active = false

local desired_anchor_steam = nil
local desired_anchor_name = nil
local last_anchor_reacquire_time = 0

-- Material variables
local materials_initialized = false
local windowed_texture = nil
local windowed_material = nil
local fullscreen_texture = nil
local fullscreen_material = nil
local invisibleMaterial = nil
local class_icon_materials = {}

-- NoHats variables (added from nohats.lua)
local cosmeticInvisibleMaterial = nil
local cosmeticCache = {}

-- Killfeed variables
local killfeed_deaths = {}

-- HUD fonts
local title_font = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)
local hud_font = draw.CreateFont("TF2 BUILD", 30, 800, FONTFLAG_OUTLINE)
local killfeed_font = draw.CreateFont("TF2 BUILD", 24, 800, FONTFLAG_OUTLINE)

-- Constants
local DEATH_TIME = 2.0
local TRAVEL_TIME = 0.4
local FREEZE_TIME = 4.0
local DEFAULT_WAVE_TIME = 10.0
local RESPAWN_RELOCK_THRESHOLD = 5.0
local MENU_REFRESH_COOLDOWN = 0.35
local BASE_DELAY = TRAVEL_TIME + FREEZE_TIME
local TOTAL_BASE_DELAY = DEATH_TIME + BASE_DELAY

-- Static variables
local lockedWaveTime = nil
local lastDeathTime = nil
local lastDebugTime = 0
local lastMenuRefreshTime = 0

--[[
There is a static base respawn time, which is based on a static death time of 2 seconds + the time for the freeze frame (0.4 travel time + 4.0 freeze time).
On top of this base, the non-scaled respawn wave time is added, which is 10 seconds by default, and can be changed per team by an input which happens
upon capturing a control point, which adds or subtracts from a team's base respawn wave time. Then, the game checks the time for the next respawn wave,
and compares it to the time for the base respawn time. If the base respawn time occurs after the next respawn wave, the scaled respawn wave time is added
on top of the next respawn wave to get the wave after the next, and so on until a respawn wave is found that occurs after the base respawn time.
The scaled respawn wave time is the non-scaled respawn wave time, except with the following extra logic: if the respawn wave time is above 5 seconds,
then scale it by a number between 0.25 and 1.0, linearly scaled by the number of players (1 to 8). Then this value is capped to a maximum of 5.

This logic happens during any PvP game, tournament mode or not. There are a few exceptions outside of normal PvP play, like in between rounds during Competitive Mode,
you respawn with your static base respawn time, and in pre-game for tournament mode, there are no respawn times.
]] --


local function ScaleWaveTime(waveTime, playerCount)
    if waveTime <= 5.0 then
        return waveTime
    end

    local scale = 0.25 + (math.min(playerCount, 8) - 1) * (0.75 / 7)
    return math.min(waveTime * scale, 5.0)
end

local function GetRespawnTime()
    local currentTime = globals.CurTime()

    if not lastDeathTime or currentTime - lastDeathTime > 15.0 then
        lockedWaveTime = nil
        lastDeathTime = currentTime
        lastDebugTime = 0
    end

    local baseRespawnTime = lastDeathTime + TOTAL_BASE_DELAY

    local resources = entities.GetPlayerResources()
    if not resources then return 0 end

    local waveTable = resources:GetPropDataTableFloat("m_flNextRespawnTime")
    if not waveTable then return 0 end

    if lockedWaveTime and lockedWaveTime > currentTime then
        if currentTime - lastDebugTime >= 1.0 then
            print(string.format("Time to respawn: %.1f", lockedWaveTime - currentTime))
            lastDebugTime = currentTime
        end
        return lockedWaveTime - currentTime
    end

    local futureWaves = {}
    local seenWaves = {}
    for _, waveTime in pairs(waveTable) do
        local roundedTime = math.floor(waveTime * 100) / 100
        if waveTime > currentTime and waveTime ~= 0 and not seenWaves[roundedTime] then
            table.insert(futureWaves, waveTime)
            seenWaves[roundedTime] = true
        end
    end
    table.sort(futureWaves)

    print("Current time:", currentTime)
    print("Base respawn time:", baseRespawnTime)
    print("Available waves:")
    for i, wave in ipairs(futureWaves) do
        print(string.format("Wave %d: %.2f (in %.2f seconds)",
            i, wave, wave - currentTime))
    end

    if #futureWaves == 0 then
        return TOTAL_BASE_DELAY
    end

    local nextWave = futureWaves[1]

    if baseRespawnTime > nextWave then
        -- Get scaled wave time
        local playerCount = 0
        for i = 1, 32 do
            if resources:GetPropInt("m_bConnected", i) == 1 then
                playerCount = playerCount + 1
            end
        end

        local fullWaveTime = DEFAULT_WAVE_TIME
        if fullWaveTime > 5.0 then
            local scale = 0.25 + (math.min(playerCount, 8) - 1) * (0.75 / 7)
            fullWaveTime = math.min(fullWaveTime * scale, 5.0)
        end

        -- Calculate where we should be after adding the wave time
        local targetTime = nextWave + fullWaveTime

        -- Find the next wave after this point
        local targetWave = nil
        for _, wave in ipairs(futureWaves) do
            if wave > targetTime then
                targetWave = wave
                break
            end
        end

        -- If we didn't find a suitable wave, add another wave time
        if not targetWave then
            targetWave = futureWaves[#futureWaves] + fullWaveTime
        end

        lockedWaveTime = targetWave
    else
        -- Base respawn is before next wave, use next available wave
        lockedWaveTime = nextWave
    end

    print(string.format("Selected wave: %.2f (in %.2f seconds)",
        lockedWaveTime, lockedWaveTime - currentTime))
    lastDebugTime = currentTime
    return lockedWaveTime - currentTime
end

-- Check if current match is casual
local function IsCasualMatch()
    return gamerules.IsMatchTypeCasual()
end

-- Initialize invisible material for cosmetics (from nohats.lua)
local function InitCosmeticMaterial()
    if not cosmeticInvisibleMaterial then
        cosmeticInvisibleMaterial = materials.Create("invisible_cosmetics", [[
            VertexLitGeneric
            {
                $basetexture    "vgui/white"
                $no_draw        1
            }
        ]])
    end
end

-- Check if entity is a cosmetic item (from nohats.lua)
local function IsCosmetic(entity)
    if not entity then return false end

    -- Check cache first
    local entIndex = entity:GetIndex()
    if cosmeticCache[entIndex] ~= nil then
        return cosmeticCache[entIndex]
    end

    local class = entity:GetClass()
    if not class then
        cosmeticCache[entIndex] = false
        return false
    end

    -- Check for hat/misc classes
    if class == "CTFWearable" then
        cosmeticCache[entIndex] = true
        return true
    end

    -- Check for botkiller attachments
    if cosmetic_settings.hide_botkillers and class == "CTFWearableDemoShield" then
        cosmeticCache[entIndex] = true
        return true
    end

    cosmeticCache[entIndex] = false
    return false
end

-- Clear cosmetic cache periodically
local function ClearCosmeticCache()
    -- Clear cache every 10 seconds to prevent it from growing too large
    -- and to handle entity reuse
    cosmeticCache = {}
end

-- Cleanup state
local function CleanupState()
    is_spectating = false
    killfeed_deaths = {}
    camera_position = Vector3(0, 0, 0)
    camera_angles = EulerAngles(0, 0, 0)
    own_view_angles = EulerAngles(0, 0, 0)
    target_player = nil
    current_enemy_index = 1
    visited_players = {}
    first_person_mode = false
    free_camera = false
    fullscreen_mode = persistent_fullscreen
    last_killer = nil
    death_time = 0
    current_wave_start = 0
end

-- Clean up function for materials and textures
local function CleanupMaterials()
    if windowed_texture then
        windowed_texture = nil
    end
    if fullscreen_texture then
        fullscreen_texture = nil
    end

    windowed_material = nil
    fullscreen_material = nil
    invisibleMaterial = nil
    cosmeticInvisibleMaterial = nil
    class_icon_materials = {}
    materials_initialized = false
end

local function InitializeAllMaterials()
    -- Clean up any existing materials first
    CleanupMaterials()

    fullscreen_width, fullscreen_height = draw.GetScreenSize()

    -- Create windowed mode materials
    local windowed_texture_name = "camTexture_windowed"
    windowed_texture = materials.CreateTextureRenderTarget(windowed_texture_name, camera_width, camera_height)
    if not windowed_texture then
        print("Failed to create windowed texture")
        return false
    end

    windowed_material = materials.Create("camMaterial_windowed", string.format([[
        UnlitGeneric
        {
            $basetexture    "%s"
            $ignorez        1
            $nofog         1
        }
    ]], windowed_texture_name))

    -- Create fullscreen mode materials
    local fullscreen_texture_name = "camTexture_fullscreen"
    fullscreen_texture = materials.CreateTextureRenderTarget(fullscreen_texture_name, fullscreen_width, fullscreen_height)
    if not fullscreen_texture then
        print("Failed to create fullscreen texture")
        return false
    end

    fullscreen_material = materials.Create("camMaterial_fullscreen", string.format([[
        UnlitGeneric
        {
            $basetexture    "%s"
            $ignorez        1
            $nofog         1
        }
    ]], fullscreen_texture_name))

    invisibleMaterial = materials.Create("invisible_material", [[
        VertexLitGeneric
        {
            $basetexture    "vgui/white"
            $no_draw        1
        }
    ]])

    -- Initialize invisible material for cosmetics
    InitCosmeticMaterial()

    -- Initialize class icons
    local class_icons = {
        [1] = "hud/leaderboard_class_scout",
        [2] = "hud/leaderboard_class_sniper",
        [3] = "hud/leaderboard_class_soldier",
        [4] = "hud/leaderboard_class_demo",
        [5] = "hud/leaderboard_class_medic",
        [6] = "hud/leaderboard_class_heavy",
        [7] = "hud/leaderboard_class_pyro",
        [8] = "hud/leaderboard_class_spy",
        [9] = "hud/leaderboard_class_engineer"
    }

    for class_id, icon_path in pairs(class_icons) do
        local material_name = string.format("class_icon_material_%d", class_id)
        class_icon_materials[class_id] = materials.Create(material_name, string.format([[
            UnlitGeneric
            {
                $basetexture "%s"
                $translucent 1
                $ignorez 1
                $nofog 1
            }
        ]], icon_path))

        if not class_icon_materials[class_id] then
            print(string.format("Failed to create material for class %d", class_id))
            return false
        end
    end

    materials_initialized = true
    return true
end

local function draw_crosshair(x, y, r, g, b, a)
    local size = 6
    draw.Color(r, g, b, a)
    draw.Line(x, y - size / 2 - 10, x, y + size / 2 - 10)
    draw.Line(x - size / 2 - 10, y, x + size / 2 - 10, y)
    draw.Line(x + size / 2 + 10, y, x - size / 2 + 10, y)
    draw.Line(x, y + size / 2 + 10, x, y - size / 2 + 10)
end

local function IsAttachedToTargetPlayer(entity)
    if not target_player or not entity then return false end

    local moveChild = target_player:GetMoveChild()
    while moveChild do
        if moveChild == entity then return true end
        moveChild = moveChild:GetMovePeer()
    end

    return false
end

local function IsValidAlivePlayer(player)
    return player and player:IsValid() and player:IsAlive() and not player:IsDormant()
end

local function IsEnemyToLocalPlayer(player)
    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer or not IsValidAlivePlayer(player) then
        return false
    end

    return player:GetTeamNumber() ~= localPlayer:GetTeamNumber()
end

local function FindClosestTeammateToReference(referencePlayer)
    if not IsValidAlivePlayer(referencePlayer) then
        return nil
    end

    local referenceOrigin = referencePlayer:GetAbsOrigin()
    local referenceTeam = referencePlayer:GetTeamNumber()

    local bestTeam = nil
    local bestTeamDist = math.huge

    local players = entities.FindByClass("CTFPlayer")
    for _, player in pairs(players) do
        if IsValidAlivePlayer(player) and player ~= referencePlayer then
            local distance = (player:GetAbsOrigin() - referenceOrigin):Length()

            if player:GetTeamNumber() == referenceTeam and distance < bestTeamDist then
                bestTeamDist = distance
                bestTeam = player
            end
        end
    end

    return bestTeam
end

local function FindClosestAnyToReference(referencePlayer)
    if not IsValidAlivePlayer(referencePlayer) then
        return nil
    end

    local referenceOrigin = referencePlayer:GetAbsOrigin()
    local bestAny = nil
    local bestAnyDist = math.huge

    local players = entities.FindByClass("CTFPlayer")
    for _, player in pairs(players) do
        if IsValidAlivePlayer(player) and player ~= referencePlayer then
            local distance = (player:GetAbsOrigin() - referenceOrigin):Length()
            if distance < bestAnyDist then
                bestAnyDist = distance
                bestAny = player
            end
        end
    end

    return bestAny
end

local function isOverlayActive()
    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer then
        return false
    end
    if localPlayer:IsAlive() then
        return false
    end
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then
        return false
    end
    return is_spectating
end

local function getUserIDForEntity(ent)
    if not ent or not ent:IsValid() then
        return nil
    end
    local idx = ent:GetIndex()
    if not idx then
        return nil
    end
    local info = client.GetPlayerInfo(idx)
    if not info or not info.UserID then
        return nil
    end
    return tonumber(info.UserID)
end

local function getSteamIDForEntity(ent)
    if not ent or not ent:IsValid() then
        return nil
    end
    local idx = ent:GetIndex()
    if not idx then
        return nil
    end
    local info = client.GetPlayerInfo(idx)
    if not info or not info.SteamID then
        return nil
    end
    return tostring(info.SteamID)
end

local function getNameForEntity(ent)
    if not ent or not ent:IsValid() then
        return nil
    end
    local idx = ent:GetIndex()
    if not idx then
        return nil
    end
    local info = client.GetPlayerInfo(idx)
    if info and info.Name then
        return tostring(info.Name)
    end
    return ent:GetName()
end

local function setDesiredAnchor(ent)
    desired_anchor_steam = getSteamIDForEntity(ent)
    desired_anchor_name = getNameForEntity(ent)
end

local function findAlivePlayerBySteamID(steamID)
    if not steamID then
        return nil
    end
    local players = entities.FindByClass("CTFPlayer")
    for _, player in pairs(players) do
        if IsValidAlivePlayer(player) then
            local sid = getSteamIDForEntity(player)
            if sid == steamID then
                return player
            end
        end
    end
    return nil
end

local function setEngineSpectateTarget(ent, forceFirstPerson)
    if not ent or not ent:IsValid() then
        return false
    end

    local uid = getUserIDForEntity(ent)
    if not uid or uid <= 0 then
        return false
    end

    local now = globals.RealTime()
    if last_engine_spectate_uid == uid and (now - last_engine_spectate_time) < 0.75 then
        return true
    end

    last_engine_spectate_uid = uid
    last_engine_spectate_time = now
    if forceFirstPerson then
        client.Command("spec_mode 4", true)
    end
    client.Command("spec_player " .. tostring(uid), true)
    return true
end

local function disableSpectateLock()
    if not spectate_locked then
        return
    end

    if stored_class then
        client.Command("join_class " .. stored_class, true)
    end
    spectate_locked = false
end

local function ApplySpectateTargetFromAnchor()
    local now = globals.RealTime()
    if (not IsValidAlivePlayer(spectate_anchor_player)) and desired_anchor_steam and (now - last_anchor_reacquire_time) >= 0.25 then
        last_anchor_reacquire_time = now
        local reacquired = findAlivePlayerBySteamID(desired_anchor_steam)
        if reacquired then
            spectate_anchor_player = reacquired
        end
    end

    if not IsValidAlivePlayer(spectate_anchor_player) then
        target_player = nil
        desired_engine_spectate_target = nil
        return false
    end

    if not vanish_mode then
        target_player = spectate_anchor_player
        desired_engine_spectate_target = target_player
        return true
    end

    local localPlayer = entities.GetLocalPlayer()
    local localTeam = localPlayer and localPlayer:GetTeamNumber() or nil
    local anchorTeam = spectate_anchor_player:GetTeamNumber()
    local anchorIsFriendlyToLocal = (localTeam ~= nil and anchorTeam == localTeam)

    local proxyPlayer = FindClosestTeammateToReference(spectate_anchor_player)
    if proxyPlayer then
        target_player = proxyPlayer
    else
        if anchorIsFriendlyToLocal then
            target_player = spectate_anchor_player
        else
            target_player = FindClosestAnyToReference(spectate_anchor_player) or spectate_anchor_player
        end
    end

    desired_engine_spectate_target = target_player
    return true
end

local function GetEnemyPlayers()
    local enemy_players = {}
    local local_player = entities.GetLocalPlayer()
    if not local_player then return enemy_players end

    local players = entities.FindByClass("CTFPlayer")
    for _, player in pairs(players) do
        if player and player:IsValid() and player:IsAlive() and
            not player:IsDormant() and
            player:GetTeamNumber() ~= local_player:GetTeamNumber() then
            table.insert(enemy_players, player)
        end
    end

    return enemy_players
end

local function CycleNextEnemy()
    local enemies = GetEnemyPlayers()
    if #enemies == 0 then
        spectate_anchor_player = nil
        target_player = nil
        desired_anchor_steam = nil
        desired_anchor_name = nil
        first_person_mode = false
        free_camera = false
        visited_players = {}
        return
    end

    local available_enemies = {}
    for _, player in ipairs(enemies) do
        local already_visited = false
        for _, visited in ipairs(visited_players) do
            if visited == player then
                already_visited = true
                break
            end
        end

        if not already_visited then
            table.insert(available_enemies, player)
        end
    end

    if #available_enemies == 0 then
        visited_players = {}
        available_enemies = enemies
    end

    for _, player in ipairs(available_enemies) do
        if IsValidAlivePlayer(player) then
            spectate_anchor_player = player
            setDesiredAnchor(player)
            ApplySpectateTargetFromAnchor()
            table.insert(visited_players, player)
            break
        end
    end

    if IsValidAlivePlayer(spectate_anchor_player) then
        local anchorName = spectate_anchor_player:GetName() or "Unknown"
        local targetName = target_player and target_player:GetName() or "Unknown"
        if vanish_mode and target_player ~= spectate_anchor_player then
            print("Now tracking enemy: " ..
                anchorName .. " via " .. targetName .. " (" .. #visited_players .. "/" .. #enemies .. " visited)")
        else
            print("Now spectating enemy: " .. anchorName .. " (" .. #visited_players .. "/" .. #enemies .. " visited)")
        end
    end
end

-- Function to get all alive players
local function GetAllPlayers()
    local all_players = {}
    local players = entities.FindByClass("CTFPlayer")
    for _, player in pairs(players) do
        if player and player:IsValid() and player:IsAlive() and not player:IsDormant() then
            table.insert(all_players, player)
        end
    end
    return all_players
end

-- Function to get friendly players
local function GetFriendlyPlayers()
    local friendly_players = {}
    local local_player = entities.GetLocalPlayer()
    if not local_player then return friendly_players end

    local players = entities.FindByClass("CTFPlayer")
    for _, player in pairs(players) do
        if player and player:IsValid() and player:IsAlive() and
            not player:IsDormant() and
            player:GetTeamNumber() == local_player:GetTeamNumber() then
            table.insert(friendly_players, player)
        end
    end

    return friendly_players
end

-- Function to cycle through all players
local function CycleAllPlayers(forward)
    local all_players = GetAllPlayers()
    if #all_players == 0 then
        spectate_anchor_player = nil
        target_player = nil
        desired_anchor_steam = nil
        desired_anchor_name = nil
        first_person_mode = false
        free_camera = false
        return
    end

    if forward then
        current_all_player_index = current_all_player_index + 1
        if current_all_player_index > #all_players then
            current_all_player_index = 1
        end
    else
        current_all_player_index = current_all_player_index - 1
        if current_all_player_index < 1 then
            current_all_player_index = #all_players
        end
    end

    spectate_anchor_player = all_players[current_all_player_index]
    setDesiredAnchor(spectate_anchor_player)
    ApplySpectateTargetFromAnchor()
    if spectate_anchor_player then
        local anchorName = spectate_anchor_player:GetName() or "Unknown"
        local targetName = target_player and target_player:GetName() or "Unknown"
        if vanish_mode and target_player ~= spectate_anchor_player then
            print("Now tracking: " .. anchorName .. " via " .. targetName)
        else
            print("Now spectating: " .. anchorName)
        end
    end
end

-- Function to cycle through friendly players
local function CycleFriendlyPlayers()
    local friendly_players = GetFriendlyPlayers()
    if #friendly_players == 0 then
        spectate_anchor_player = nil
        target_player = nil
        desired_anchor_steam = nil
        desired_anchor_name = nil
        first_person_mode = false
        free_camera = false
        return
    end

    friendly_player_index = friendly_player_index + 1
    if friendly_player_index > #friendly_players then
        friendly_player_index = 1
    end

    spectate_anchor_player = friendly_players[friendly_player_index]
    setDesiredAnchor(spectate_anchor_player)
    ApplySpectateTargetFromAnchor()
    if spectate_anchor_player then
        local anchorName = spectate_anchor_player:GetName() or "Unknown"
        local targetName = target_player and target_player:GetName() or "Unknown"
        if vanish_mode and target_player ~= spectate_anchor_player then
            print("Now tracking teammate: " .. anchorName .. " via " .. targetName)
        else
            print("Now spectating friendly: " .. anchorName)
        end
    end
end

-- Function to store current class
local function StoreCurrentClass()
    local local_player = entities.GetLocalPlayer()
    if local_player then
        stored_class = local_player:GetPropInt("m_iClass")
    end
end

-- Function to toggle spectate lock (only works in casual)
local function ToggleSpectateLock()
    -- Check if we're in a casual match
    if not IsCasualMatch() then
        print("Infinite spectate only works in Casual matches.")
        return
    end

    -- Only allow toggle if the infinite_spectate feature is enabled
    if not infinite_spectate then
        print("Infinite spectate feature is disabled. Set infinite_spectate = true in the script to enable it.")
        return
    end

    if not spectate_locked then
        if not isOverlayActive() then
            print("Infinite spectate requires the spectator overlay to be visible.")
            return
        end
        StoreCurrentClass()
        client.Command("menuopen", true)
        spectate_locked = true
        print("Infinite spectate: ENABLED (Casual Mode)")
    else
        if stored_class then
            client.Command("join_class " .. stored_class, true)
        end
        spectate_locked = false
        print("Infinite spectate: DISABLED")
    end
end

-- Function to toggle hide player model setting
local function ToggleHidePlayerModel()
    hide_player_model = not hide_player_model
    print("Hide player model in first person: " .. (hide_player_model and "ENABLED" or "DISABLED"))
end

local function ToggleVanishMode()
    vanish_mode = not vanish_mode
    ApplySpectateTargetFromAnchor()
    print("Vanish mode: " .. (vanish_mode and "ENABLED" or "DISABLED"))
end

local function RefreshInfiniteSpectateLock()
    if not spectate_locked then
        return
    end

    if not isOverlayActive() then
        return
    end

    if not IsCasualMatch() then
        return
    end

    local respawnTime = GetRespawnTime()
    if respawnTime <= 0 or respawnTime > RESPAWN_RELOCK_THRESHOLD then
        return
    end

    local now = globals.RealTime()
    if now - lastMenuRefreshTime < MENU_REFRESH_COOLDOWN then
        return
    end

    client.Command("menuopen", true)
    lastMenuRefreshTime = now
end

local function HandleMovement()
    local forward = Vector3(0, 0, 0)
    local right = Vector3(0, 0, 0)
    local up = Vector3(0, 0, 0)

    if input.IsButtonDown(KEY_W) then
        forward = forward + camera_angles:Forward() * camera_speed
    end
    if input.IsButtonDown(KEY_S) then
        forward = forward - camera_angles:Forward() * camera_speed
    end
    if input.IsButtonDown(KEY_D) then
        right = right + camera_angles:Right() * camera_speed
    end
    if input.IsButtonDown(KEY_A) then
        right = right - camera_angles:Right() * camera_speed
    end
    if input.IsButtonDown(KEY_Q) then
        up.z = up.z + camera_speed
    end
    if input.IsButtonDown(KEY_E) then
        up.z = up.z - camera_speed
    end

    return forward + right + up
end

local function SafeGetTextSize(text)
    if not text or text == "" then
        return 0, 0
    end
    return draw.GetTextSize(text)
end

local function HandleKillfeedEvent(event)
    if event:GetName() == "player_death" then
        local victim = entities.GetByUserID(event:GetInt("userid"))
        local attacker_id = event:GetInt("attacker")
        local attacker = nil

        if attacker_id and attacker_id > 0 then
            attacker = entities.GetByUserID(attacker_id)
        end

        local assister = nil
        local assister_id = event:GetInt("assister")
        if assister_id and assister_id > 0 then
            assister = entities.GetByUserID(assister_id)
        end

        local local_player = entities.GetLocalPlayer()

        if victim and local_player and victim:GetIndex() == local_player:GetIndex() and attacker then
            last_killer = attacker
        end

        if not victim then return end

        local current_tick = globals.TickCount()
        local hud_deathnotice_time = client.GetConVar("hud_deathnotice_time")

        killfeed_deaths[#killfeed_deaths + 1] = {
            victim = victim,
            attacker = attacker,
            assister = assister,
            tick_to_disappear = current_tick + (hud_deathnotice_time * 66 * 2)
        }

        while #killfeed_deaths > MAX_KILLFEED_ENTRIES do
            table.remove(killfeed_deaths, 1)
        end
    elseif event:GetName() == "game_newmap" then
        -- Reset state on map change
        has_spawned_once = false
        is_in_game = false
        CleanupState()
    elseif event:GetName() == "teamplay_round_start" then
        is_in_game = true
    elseif event:GetName() == "teamplay_game_over" or
        event:GetName() == "tf_game_over" then
        is_in_game = false
    elseif event:GetName() == "team_control_point_captured" then
        -- Reset our target wave when a point is captured
        lockedWaveTime = nil
        current_wave_start = globals.CurTime()
    end
end

local function DrawKillfeed()
    if not fullscreen_mode then return end

    local current_tick = globals.TickCount()

    for i = #killfeed_deaths, 1, -1 do
        if killfeed_deaths[i].tick_to_disappear <= current_tick then
            table.remove(killfeed_deaths, i)
        end
    end

    local lastHeight = 5
    local local_player = entities.GetLocalPlayer()

    local team_colors = {
        [2] = { 255, 64, 64, 255 },
        [3] = { 153, 204, 255, 255 }
    }

    local function GetColoredPlayerText(player)
        if not player or not player:IsValid() then
            return { text = "Unknown", color = { 255, 255, 255, 255 } }
        end

        local name = player:GetName()
        if not name or name == "" then
            return { text = "Unknown", color = { 255, 255, 255, 255 } }
        end

        if (local_player and player:GetIndex() == local_player:GetIndex()) or
            (target_player and player:GetIndex() == target_player:GetIndex()) then
            return { text = name, color = { 255, 255, 255, 255 } }
        else
            local team_color = team_colors[player:GetTeamNumber()] or { 255, 255, 255, 255 }
            return { text = name, color = team_color }
        end
    end

    for pos, death in ipairs(killfeed_deaths) do
        if not death.victim then goto continue end

        local victim_info = GetColoredPlayerText(death.victim)
        local died_alone = death.attacker == death.victim
        local map_death = not death.attacker or not death.attacker:IsValid()

        draw.SetFont(killfeed_font)
        local full_text
        local components = {}

        if map_death or died_alone then
            full_text = string.format("%s died a horrible death :(", victim_info.text)
            components = { { text = full_text, color = victim_info.color } }
        else
            local attacker_info = GetColoredPlayerText(death.attacker)
            components = {
                { text = attacker_info.text, color = attacker_info.color }
            }

            if death.assister and death.assister:IsValid() and death.assister:GetName() then
                local assister_info = GetColoredPlayerText(death.assister)
                table.insert(components, { text = " + ", color = { 255, 255, 255, 255 } })
                table.insert(components, { text = assister_info.text, color = assister_info.color })
            end

            table.insert(components, { text = " → ", color = { 255, 255, 255, 255 } })
            table.insert(components, { text = victim_info.text, color = victim_info.color })

            full_text = ""
            for _, component in ipairs(components) do
                full_text = full_text .. component.text
            end
        end

        local textwidth, textheight = SafeGetTextSize(full_text)
        if textwidth == 0 or textheight == 0 then goto continue end

        local x1 = fullscreen_width - textwidth - 30
        local y = lastHeight + textheight

        local current_x = x1
        for _, component in ipairs(components) do
            draw.Color(component.color[1], component.color[2], component.color[3], component.color[4])
            draw.TextShadow(current_x, y, component.text)
            current_x = current_x + SafeGetTextSize(component.text)
        end

        lastHeight = lastHeight + textheight + 10

        ::continue::
    end
end

-- Make sure to set death_time when player dies
local function OnLocalPlayerDeathEvent(event)
    if event:GetName() == "player_death" then
        local localPlayer = entities.GetLocalPlayer()
        if not localPlayer then return end

        local victim = entities.GetByUserID(event:GetInt("userid"))
        if victim and localPlayer:GetIndex() == victim:GetIndex() then
            death_time = globals.CurTime()
            current_wave_start = 0 -- Reset current wave
        end
    end
end

-- Track when points are captured to reset wave timing
local function OnGameEvent(event)
    if event:GetName() == "team_control_point_captured" then
        -- Reset our target wave when a point is captured
        lockedWaveTime = nil
        current_wave_start = globals.CurTime()
    end
end

-- Update DrawSpectatorHUD
local function DrawSpectatorHUD()
    if not fullscreen_mode then return end

    -- Draw respawn timer or infinite spectate text
    draw.SetFont(hud_font)
    draw.Color(255, 255, 255, 255)

    local topText
    if spectate_locked then
        topText = "Infinite Spectate (Casual Mode)"
    else
        local time = GetRespawnTime()
        if time > 0 then
            topText = string.format("Respawning in: %.1f", time)
        end
    end

    if topText then
        local textW, textH = draw.GetTextSize(topText)
        -- Draw semi-transparent background
        draw.Color(0, 0, 0, 150)
        draw.FilledRectFade(
            math.floor(fullscreen_width / 2 - textW / 2 - 20),
            35,
            math.floor(fullscreen_width / 2 + textW / 2 + 20),
            45 + textH,
            100,
            50,
            true
        )
        -- Draw text
        draw.Color(255, 255, 255, 255)
        draw.TextShadow(
            math.floor(fullscreen_width / 2 - textW / 2),
            40,
            topText
        )
    end

    local haveAnyTarget = (target_player ~= nil and not free_camera)
    if not haveAnyTarget then
        local wantName = desired_anchor_name or "No Target"
        draw.SetFont(hud_font)
        local textW, textH = draw.GetTextSize(wantName)
        local nameY = math.floor(fullscreen_height - 140)
        draw.Color(0, 0, 0, 130)
        draw.FilledRectFade(
            math.floor(fullscreen_width / 2 - textW / 2 - 60),
            nameY - 5,
            math.floor(fullscreen_width / 2 + textW / 2 + 60),
            nameY + textH + 5,
            100,
            50,
            true
        )
        draw.Color(255, 255, 255, 120)
        draw.TextShadow(math.floor(fullscreen_width / 2 - textW / 2), nameY, wantName)
        draw.SetFont(title_font)
        draw.Color(255, 255, 255, 200)
        draw.TextShadow(math.floor(fullscreen_width / 2 - textW / 2 - 50), nameY + 4, "< MOUSE2")
        draw.TextShadow(math.floor(fullscreen_width / 2 + textW / 2 + 10), nameY + 4, "MOUSE1 >")
        return
    end

    local health = target_player:GetHealth()
    if not health then return end
    local maxHealth = target_player:GetMaxHealth()
    if not maxHealth then return end
    local actualName = target_player:GetName()
    if not actualName then return end
    local desiredName = desired_anchor_name or actualName
    local anchorName = spectate_anchor_player and spectate_anchor_player:IsValid() and spectate_anchor_player:GetName() or
        desiredName
    local isProxying = (spectate_anchor_player and target_player and target_player ~= spectate_anchor_player)

    local healthColor = {
        r = math.floor(255 * (1 - (health / maxHealth))),
        g = math.floor(255 * (health / maxHealth)),
        b = 0
    }

    local crosshairColor = {
        r = 0,
        g = 255,
        b = 0
    }

    -- Get team colors
    local team_colors = {
        [2] = { r = 255, g = 64, b = 64 },  -- RED
        [3] = { r = 153, g = 204, b = 255 } -- BLU
    }
    local teamEntity = spectate_anchor_player and spectate_anchor_player:IsValid() and spectate_anchor_player or
        target_player
    local team_color = team_colors[teamEntity:GetTeamNumber()] or { r = 255, g = 255, b = 255 }

    draw.SetFont(hud_font)

    local nameAlpha = isProxying and 50 or 255
    local nameW, textH = draw.GetTextSize(desiredName)
    local nameBgPadding = 20
    local iconSize = 32
    local nameY = math.floor(fullscreen_height - 140)
    local totalWidth = nameW + iconSize + 10 -- 10 pixels padding between icon and name

    -- Draw semi-transparent team-colored background (extended for icon)
    draw.Color(team_color.r, team_color.g, team_color.b, 100)
    draw.FilledRectFade(
        math.floor(fullscreen_width / 2 - totalWidth / 2 - nameBgPadding),
        nameY - 5,
        math.floor(fullscreen_width / 2 + totalWidth / 2 + nameBgPadding),
        nameY + math.max(textH, iconSize) + 5,
        100,
        50,
        true
    )

    -- Draw name text (shifted right to make room for icon)
    draw.Color(255, 255, 255, nameAlpha)
    draw.TextShadow(
        math.floor(fullscreen_width / 2 - totalWidth / 2 + iconSize + 10),
        nameY,
        desiredName
    )

    draw.SetFont(title_font)
    draw.Color(255, 255, 255, 200)
    draw.TextShadow(math.floor(fullscreen_width / 2 - totalWidth / 2 - 50), nameY + 4, "< MOUSE2")
    draw.TextShadow(math.floor(fullscreen_width / 2 + totalWidth / 2 + 10), nameY + 4, "MOUSE1 >")

    if isProxying then
        local proxyText = actualName
        local proxyW, proxyH = draw.GetTextSize(proxyText)
        draw.Color(255, 255, 255, 255)
        draw.TextShadow(math.floor(fullscreen_width / 2 - proxyW / 2), nameY - proxyH - 8, proxyText)
    end

    -- Draw class icon using our custom materials
    local playerClass = teamEntity:GetPropInt("m_iClass")
    local classIcon = class_icon_materials[playerClass]
    if classIcon then
        draw.Color(255, 255, 255, 255)
        local iconX = math.floor(fullscreen_width / 2 - totalWidth / 2)
        local iconY = math.floor(nameY + textH / 2 - iconSize / 2)
        render.DrawScreenSpaceRectangle(
            classIcon,
            iconX,
            iconY,
            math.floor(iconSize),
            math.floor(iconSize),
            0, 0,
            32, 32,
            32, 32
        )
    end

    -- Draw health with darker background
    local healthText = string.format("%d HP", health)
    local healthW, healthH = draw.GetTextSize(healthText)
    local healthY = math.floor(fullscreen_height - 100)

    -- Draw semi-transparent background for health
    draw.Color(0, 0, 0, 150)
    draw.FilledRectFade(
        math.floor(fullscreen_width / 2 - healthW / 2 - nameBgPadding),
        healthY - 5,
        math.floor(fullscreen_width / 2 + healthW / 2 + nameBgPadding),
        healthY + healthH + 5,
        100,
        50,
        true
    )

    -- Draw health text
    draw.Color(healthColor.r, healthColor.g, healthColor.b, 255)
    draw.TextShadow(math.floor(fullscreen_width / 2 - healthW / 2), healthY, healthText)

    if first_person_mode then
        draw_crosshair(fullscreen_width / 2, fullscreen_height / 2, crosshairColor.r, crosshairColor.g, crosshairColor.b,
            255)
    end
end

local function HandleCameraControls()
    local current_time = globals.RealTime()

    -- Add Caps Lock check for cycling friendly players
    if input.IsButtonPressed(KEY_CAPSLOCK) and current_time - last_key_press > key_delay then
        CycleFriendlyPlayers()
        last_key_press = current_time
        free_camera = false
    end

    -- Add Mouse1 and Mouse2 checks for cycling all players
    if input.IsButtonPressed(MOUSE_LEFT) and current_time - last_key_press > key_delay then
        CycleAllPlayers(true)
        last_key_press = current_time
        free_camera = false
    end

    if input.IsButtonPressed(MOUSE_RIGHT) and current_time - last_key_press > key_delay then
        CycleAllPlayers(false)
        last_key_press = current_time
        free_camera = false
    end

    -- Add Shift check for spectate lock (only in casual)
    if input.IsButtonPressed(KEY_LSHIFT) and current_time - last_key_press > key_delay then
        ToggleSpectateLock()
        last_key_press = current_time
    end

    if (input.IsButtonPressed(KEY_LCONTROL) or input.IsButtonPressed(KEY_RCONTROL) or input.IsButtonPressed(KEY_F11)) and current_time - last_key_press > key_delay then
        persistent_fullscreen = not persistent_fullscreen
        fullscreen_mode = persistent_fullscreen
        print("Fullscreen: " .. (fullscreen_mode and "ON" or "OFF"))
        last_key_press = current_time
    end

    if input.IsButtonPressed(KEY_V) and current_time - last_key_press > key_delay then
        ToggleVanishMode()
        last_key_press = current_time
    end

    if input.IsButtonPressed(KEY_TAB) and current_time - last_key_press > key_delay then
        if not target_player or not target_player:IsValid() or not target_player:IsAlive() or target_player:IsDormant() then
            visited_players = {}
        end
        CycleNextEnemy()
        last_key_press = current_time
        free_camera = false
    end

    if input.IsButtonPressed(KEY_SPACE) and target_player and current_time - last_key_press > key_delay then
        first_person_mode = not first_person_mode
        free_camera = false
        last_key_press = current_time
    end

    if not target_player then
        camera_angles = own_view_angles
        camera_position = camera_position + HandleMovement()
    else
        if not first_person_mode then
            local moving = input.IsButtonDown(KEY_W) or input.IsButtonDown(KEY_A) or
                input.IsButtonDown(KEY_S) or input.IsButtonDown(KEY_D) or
                input.IsButtonDown(KEY_Q) or input.IsButtonDown(KEY_E)

            if moving and not free_camera then
                free_camera = true
                own_view_angles = camera_angles
            end
        end

        if first_person_mode then
            free_camera = false
            camera_position = target_player:GetAbsOrigin() +
                target_player:GetPropVector("localdata", "m_vecViewOffset[0]")
            local pitch = target_player:GetPropFloat("tfnonlocaldata", "m_angEyeAngles[0]") or 0
            local yaw = target_player:GetPropFloat("tfnonlocaldata", "m_angEyeAngles[1]") or 0
            camera_angles = EulerAngles(pitch, yaw, 0)

            -- Apply offset if configured to use offset mode
            if camera_view_mode == "offset" then
                -- Apply forward offset
                local forward_vector = camera_angles:Forward()

                -- Increase forward offset when player is looking down to prevent camera clipping
                local pitch_factor = 1.0
                if pitch > 60 then                                 -- Adjust when looking down significantly
                    pitch_factor = 1.0 + ((pitch - 60) / 30) * 7.5 -- Gradually increase offset
                end

                camera_position = camera_position + forward_vector * (forward_offset * pitch_factor)

                -- Apply upward offset
                camera_position = camera_position + Vector3(0, 0, upward_offset)
            end
        else
            camera_angles = own_view_angles
            if free_camera then
                camera_position = camera_position + HandleMovement()
            else
                camera_position = target_player:GetAbsOrigin() + Vector3(0, 0, 64) - camera_angles:Forward() * 100
            end
        end
    end
end

local function SyncFullscreenCameraOrigin()
    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer then
        return
    end

    if localPlayer:IsAlive() then
        return
    end

    if not persistent_fullscreen then
        return
    end

    if camera_position == Vector3(0, 0, 0) then
        return
    end

    localPlayer:SetPropVector(camera_position, "tfnonlocaldata", "m_vecOrigin")

    local pitch, yaw, _ = camera_angles:Unpack()
    localPlayer:SetPropFloat(pitch, "tfnonlocaldata", "m_angEyeAngles[0]")
    localPlayer:SetPropFloat(yaw, "tfnonlocaldata", "m_angEyeAngles[1]")
end

-- Modified DrawModel callback to hide cosmetics in first-person mode
local function OnDrawModel(ctx)
    -- Skip all processing if not spectating
    if not is_spectating then return end

    -- First, handle player model invisibility for first-person mode
    if target_player and first_person_mode and invisibleMaterial and hide_player_model then
        local ent = ctx:GetEntity()
        if not ent then return end

        if ent == target_player or IsAttachedToTargetPlayer(ent) then
            ctx:ForcedMaterialOverride(invisibleMaterial)
            return -- Skip further processing for the player model
        end
    end

    -- Second, handle cosmetic hiding in first-person mode
    if target_player and first_person_mode and cosmetic_settings.hide_hats and cosmeticInvisibleMaterial then
        local ent = ctx:GetEntity()
        if not ent then return end

        -- Check if the entity is a cosmetic
        if IsCosmetic(ent) then
            ctx:ForcedMaterialOverride(cosmeticInvisibleMaterial)
        end
    end
end

local function OnCreateMove(cmd)
    local overlayActive = isOverlayActive()
    if last_overlay_active and not overlayActive then
        disableSpectateLock()
    end
    last_overlay_active = overlayActive

    local localPlayer = entities.GetLocalPlayer()
    if localPlayer and localPlayer:IsAlive() then
        has_spawned_once = true
    end

    if first_person_mode then return end

    -- Allow mouse movement in free cam or when in third person with target
    if free_camera or (target_player and not first_person_mode) then
        local mouse_x = -cmd.mousedx * MOUSE_SENSITIVITY
        local mouse_y = cmd.mousedy * MOUSE_SENSITIVITY

        own_view_angles.y = own_view_angles.y + mouse_x
        own_view_angles.x = math.max(-89, math.min(89, own_view_angles.x + mouse_y))
    end

    if overlayActive then
        engine.SetViewAngles(own_view_angles)
    end
end

local function OnPostRenderView(view)
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then
        return
    end

    fullscreen_width, fullscreen_height = draw.GetScreenSize()

    if not materials_initialized or not windowed_material or not fullscreen_material then
        if not InitializeAllMaterials() then
            return
        end
    end

    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer then return end

    if localPlayer:IsAlive() then
        has_spawned_once = true
        is_in_game = true
        camera_position = Vector3(0, 0, 0)
        is_spectating = false -- Reset spectating flag when alive
        CleanupState()
        return
    end

    -- Set spectating flag only if we're actually spectating
    is_spectating = has_spawned_once and is_in_game

    -- Only show spectator window if we've spawned before and are actually in-game
    if not has_spawned_once or not is_in_game then return end

    local active_fullscreen = persistent_fullscreen
    fullscreen_mode = active_fullscreen

    local current_texture = active_fullscreen and fullscreen_texture or windowed_texture
    local current_material = active_fullscreen and fullscreen_material or windowed_material

    if not current_texture or not current_material then return end

    if camera_position == Vector3(0, 0, 0) then
        camera_position = localPlayer:GetAbsOrigin() + Vector3(0, 0, 64)
        own_view_angles = engine.GetViewAngles()

        if last_killer and last_killer:IsValid() and last_killer:IsAlive() and not last_killer:IsDormant() then
            spectate_anchor_player = last_killer
            setDesiredAnchor(last_killer)
            ApplySpectateTargetFromAnchor()
            first_person_mode = true
            free_camera = false
        else
            CycleNextEnemy()
            first_person_mode = true
            free_camera = false
        end

        last_killer = nil
        fullscreen_mode = persistent_fullscreen
    end

    ApplySpectateTargetFromAnchor()

    HandleCameraControls()
    RefreshInfiniteSpectateLock()

    if isOverlayActive() then
        if desired_engine_spectate_target and desired_engine_spectate_target:IsValid() then
            local forceFP = first_person_mode and not vanish_mode
            setEngineSpectateTarget(desired_engine_spectate_target, forceFP)
        end
    end

    local customView = view
    customView.origin = camera_position
    customView.angles = camera_angles

    local desiredFov = 90
    local fovRaw = client.GetConVar("fov_desired")
    if type(fovRaw) == "number" then
        desiredFov = fovRaw
    elseif type(fovRaw) == "string" then
        local n = tonumber(fovRaw)
        if n then
            desiredFov = n
        end
    end
    local fov = desiredFov
    if first_person_mode then
        if target_player and target_player:IsValid() then
            local isZoomed = target_player:GetPropBool("m_bZoomed")
            if isZoomed then
                fov = 20
            end
        end
    end
    customView.fov = fov

    render.Push3DView(customView, E_ClearFlags.VIEW_CLEAR_COLOR | E_ClearFlags.VIEW_CLEAR_DEPTH, current_texture)
    render.ViewDrawScene(true, true, customView)
    render.PopView()

    local render_x = active_fullscreen and 0 or camera_x_position
    local render_y = active_fullscreen and 0 or camera_y_position
    local render_width = active_fullscreen and fullscreen_width or camera_width
    local render_height = active_fullscreen and fullscreen_height or camera_height

    render.DrawScreenSpaceRectangle(
        current_material,
        render_x, render_y,
        render_width, render_height,
        0, 0,
        render_width, render_height,
        render_width, render_height
    )
end

local function OnDraw()
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then
        return
    end

    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer or not has_spawned_once or not is_in_game then return end

    -- Clear cosmetic cache periodically
    if globals.TickCount() % (66 * 10) == 0 then -- Assuming 66 ticks per second
        ClearCosmeticCache()
    end

    if not localPlayer:IsAlive() then
        if fullscreen_mode then
            DrawSpectatorHUD()
            DrawKillfeed()

            -- Keep essential controls visible in fullscreen so you can recover state.
            draw.SetFont(title_font)
            draw.Color(0, 0, 0, 140)
            draw.FilledRect(10, 10, 430, 120)
            draw.Color(255, 255, 255, 230)
            draw.Text(20, 20, "Spectate Controls")
            draw.Text(20, 35, "Ctrl / F11 - Toggle fullscreen")
            draw.Text(20, 50, "Space - First/Third person")
            draw.Text(20, 65, "Tab - Next enemy | CapsLock - Next friendly")
            draw.Text(20, 80, "Mouse1/Mouse2 - Cycle players | WASD + E/Q - Move")
            draw.Text(20, 95, "V - Toggle vanish mode | Shift - Infinite spectate")

            return
        end

        -- Only draw borders and controls in windowed mode
        draw.Color(235, 64, 52, 255)
        draw.OutlinedRect(
            math.floor(camera_x_position),
            math.floor(camera_y_position),
            math.floor(camera_x_position + camera_width),
            math.floor(camera_y_position + camera_height)
        )

        draw.OutlinedRect(
            math.floor(camera_x_position),
            math.floor(camera_y_position - 20),
            math.floor(camera_x_position + camera_width),
            math.floor(camera_y_position)
        )
        draw.Color(130, 26, 17, 255)
        draw.FilledRect(
            math.floor(camera_x_position + 1),
            math.floor(camera_y_position - 19),
            math.floor(camera_x_position + camera_width - 1),
            math.floor(camera_y_position - 1)
        )

        draw.SetFont(title_font)
        draw.Color(255, 255, 255, 255)
        local text = "Enemy Spectator"
        if target_player then
            local playerName = target_player:GetName()
            if playerName then
                text = text .. " - " .. playerName
                if first_person_mode then
                    text = text .. " (First Person)"
                elseif free_camera then
                    text = text .. " (Free Camera)"
                end
            end
        end

        local textW, textH = draw.GetTextSize(text)
        draw.Text(
            math.floor(camera_x_position + camera_width * 0.5 - textW * 0.5),
            math.floor(camera_y_position - 16),
            text
        )

        draw.Color(255, 255, 255, 200)
        local controls = {
            "Controls:",
            "Move Mouse - Look around",
            "Mouse1/Mouse2 - Cycle all players",
            "WASD - Move camera",
            "E/Q - Up/Down",
            "Space - Toggle perspective",
            "Tab - Cycle enemy players",
            "CapsLock - Cycle friendly players"
        }

        -- Add infinite spectate control info based on game mode
        if IsCasualMatch() then
            table.insert(controls, "Shift - Toggle infinite spectate (Casual only)")
        else
            table.insert(controls, "Infinite spectate only works in Casual mode")
        end

        table.insert(controls, "Ctrl - Toggle fullscreen")
        table.insert(controls, "V - Toggle vanish mode")

        for i, text in ipairs(controls) do
            draw.Text(
                math.floor(camera_x_position + 5),
                math.floor(camera_y_position + camera_height + 5 + (i - 1) * 15),
                text
            )
        end

        -- Draw camera mode info
        local mode_text = "Camera mode: " .. camera_view_mode
        local hide_text = "Hide player model: " .. (hide_player_model and "ON" or "OFF")
        local nohats_text = "Hide cosmetics: " .. (first_person_mode and cosmetic_settings.hide_hats and "ON" or "OFF")
        local vanish_text = "Vanish mode: " .. (vanish_mode and "ON" or "OFF")
        local game_mode_text = "Game mode: " .. (IsCasualMatch() and "Casual" or "Non-Casual")
        local offset_info_y = math.floor(camera_y_position + camera_height + 5 + (#controls * 15))

        draw.Text(math.floor(camera_x_position + 5), offset_info_y, mode_text)
        draw.Text(math.floor(camera_x_position + 5), offset_info_y + 15, hide_text)
        draw.Text(math.floor(camera_x_position + 5), offset_info_y + 30, nohats_text)
        draw.Text(math.floor(camera_x_position + 5), offset_info_y + 45, vanish_text)
        draw.Text(math.floor(camera_x_position + 5), offset_info_y + 60, game_mode_text)
    end
end

local function OnUnload()
    CleanupMaterials()
    CleanupState()
end

pcall(callbacks.Unregister, "FireGameEvent", "Spectate_LocalDeath")
pcall(callbacks.Unregister, "FireGameEvent", "point_capture_hook")
pcall(callbacks.Unregister, "FireGameEvent", "Spectate_Killfeed")
pcall(callbacks.Unregister, "DrawModel", "Spectate_DrawModel")
pcall(callbacks.Unregister, "CreateMove", "Spectate_CreateMove")
pcall(callbacks.Unregister, "PostRenderView", "Spectate_PostRenderView")
pcall(callbacks.Unregister, "Draw", "Spectate_Draw")
pcall(callbacks.Unregister, "PostPropUpdate", "Spectate_FullscreenCameraSync")
pcall(callbacks.Unregister, "Unload", "Spectate_Unload")

callbacks.Register("FireGameEvent", "Spectate_LocalDeath", OnLocalPlayerDeathEvent)
callbacks.Register("FireGameEvent", "point_capture_hook", OnGameEvent)
callbacks.Register("FireGameEvent", "Spectate_Killfeed", HandleKillfeedEvent)
callbacks.Register("DrawModel", "Spectate_DrawModel", OnDrawModel)
callbacks.Register("CreateMove", "Spectate_CreateMove", OnCreateMove)
callbacks.Register("PostRenderView", "Spectate_PostRenderView", OnPostRenderView)
callbacks.Register("Draw", "Spectate_Draw", OnDraw)
callbacks.Register("PostPropUpdate", "Spectate_FullscreenCameraSync", SyncFullscreenCameraOrigin)
callbacks.Register("Unload", "Spectate_Unload", OnUnload)

-- Print script initialization message
print("Spectate script loaded")
print("Camera mode: " .. camera_view_mode)
print("Hide player model: " .. (hide_player_model and "ENABLED" or "DISABLED"))
print("Hide cosmetics in first-person: " .. (cosmetic_settings.hide_hats and "ENABLED" or "DISABLED"))
print("Infinite spectate: " .. (infinite_spectate and "ENABLED (Casual mode only)" or "DISABLED"))
