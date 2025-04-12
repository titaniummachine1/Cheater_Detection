# Lmaobox Lua Documentation

## Home



# Home


The Lmaobox Lua API enables players and developers to enhance and expand their game by implementing their own ideas, features, visuals, and customizations.


## Community


If you want to contribute, share suggestions, report a problem, or report a bug, feel free to join the discussion on our
 Discord and Telegram group 


You can share and download Lua scripts on our Forum 


## IDE


We recommend using Visual Studio Code with those extensions:


- 
Lmaobox Lua Annotations - static code analysis, type checking and autocompletion.

- 
Lmaobox LUA snippets addon - autocompletion addon.


If you are using Open AI you can access API via http://lmaobox.net/lua/sitemap.xml


## Learning Lua


You can start learning Lua by following the friendly tutorial made by Garry's Mod developers: 


- Garry's Mod Lua Tutorial

Or any of the following guides for example:


- Lua.org Tutorial
- Tutorialspoint Tutorial

## How to start


1. 
Make sure you have Lmaobox loaded

2. 
Create example.lua file in your %localappdata% folder and save your code there

3. 
Execute the script ingame using console command:
lua_load example.lua

Note it is also possible to execute lua code directly using:
lua print( "Hello World" )



## Interaction overview diagram





## Top Examples


FPS Counter - by x6h```
local consolas = draw.CreateFont("Consolas", 17, 500)
local current_fps = 0

local function watermark()
  draw.SetFont(consolas)
  draw.Color(255, 255, 255, 255)

  -- update fps every 100 frames
  if globals.FrameCount() % 100 == 0 then
    current_fps = math.floor(1 / globals.FrameTime())
  end

  draw.Text(5, 5, "[lmaobox | fps: " .. current_fps .. "]")
end

callbacks.Register("Draw", "draw", watermark)
-- https://github.com/x6h

```

Damage logger - by @RC```
local function damageLogger(event)

    if (event:GetName() == 'player_hurt' ) then

        local localPlayer = entities.GetLocalPlayer();
        local victim = entities.GetByUserID(event:GetInt("userid"))
        local health = event:GetInt("health")
        local attacker = entities.GetByUserID(event:GetInt("attacker"))
        local damage = event:GetInt("damageamount")

        if (attacker == nil or localPlayer:GetIndex() ~= attacker:GetIndex()) then
            return
        end

        print("You hit " ..  victim:GetName() .. " or ID " .. victim:GetIndex() .. " for " .. damage .. "HP they now have " .. health .. "HP left")
    end

end

callbacks.Register("FireGameEvent", "exampledamageLogger", damageLogger)
-- Made by @RC

```

Basic player ESP```
local myfont = draw.CreateFont( "Verdana", 16, 800 )

local function doDraw()
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then
        return
    end

    local players = entities.FindByClass("CTFPlayer")

    for i, p in ipairs( players ) do
        if p:IsAlive() and not p:IsDormant() then

            local screenPos = client.WorldToScreen( p:GetAbsOrigin() )
            if screenPos ~= nil then
                draw.SetFont( myfont )
                draw.Color( 255, 255, 255, 255 )
                draw.Text( screenPos[1], screenPos[2], p:GetName() )
            end
        end
    end
end

callbacks.Register("Draw", "mydraw", doDraw) 

```


## API Changelog



# API Changelog


All notable changes to LUA API will be documented in this file.


## [15th Jan 2025]


- Fixed entity.ShouldDraw() incorrectly requiring int parameter
- Fixed item.SetAttribute to correctly accept string attribute such as item name

## [17th Dec 2024]


- Fixed DoPostSpaceScreenEffects callback not being called back
- Fixed render.DepthRange to take floats, not ints
- Fixed OnFakeUncrate callback, it now expect you to return loopTable, either the original one modified or your own, see new example in https://lmaobox.net/lua/Lua_Callbacks/

## [4th Dec 2024]


- entity:SetAbsAngles(Vector)
- entity:GetAbsAngles()
- DrawModelContext:SetColorModulation(r,g,b) - modulate via renderview for non studio models
- DrawModelContext:SetAlphaModulation(a) - modulate via renderview, for non studio models
- DrawModelContext::Execute() - render model in place with current overrides
- Testing performance improvements for Lua object creation, may or may not crash randomly for no reason let us know if that happens
- Fixed static props color modulation not working
- added callback RenderViewModel( ViewSetup:view ) -> Change viewsetup to change how viewmodel is rendered, nothing else is affected
- FrameStageNotify(stage) callback, extending PostPropUpdate callback which is now legacy only.
- fixed ent:SetAbsAngles()
- entity:GetVAngles() / SetVAngles() - set 3rd person view angles for player
- E_ClientFrameStage for FSN callback
- entity:GetInvisibility() / SetInvisibility() - set player invisibility level from 0 to 1
- render.DrawScreenSpaceQuad()
- render.Viewport( x:integer, y:integer, w:integer, h:integer)
- render.GetViewport()
- render.GetDepthRange()
- render.DepthRange( zNear:number, zFar:number)
- render.GetRenderTarget()
- render.SetRenderTarget(texture)
- render.ClearColor3ub
- render.ClearBuffer
- render.ClearColor4ub
- render.OverrideAlphaWriteEnable()
- render.OverrideDepthEnable
- render.PushRenderTargetAndViewport()
- render.SetStencilEnable( enable:boolean )
- render.PopRenderTargetAndViewport()
- render.SetStencilFailOperation( failOp:integer )
- render.SetStencilZFailOperation( zFailOp:integer )
- render.SetStencilPassOperation( passOp:integer )
- render.SetStencilCompareFunction( compareFunc:integer )
- render.SetStencilTestMask( mask:integer )
- render.SetStencilReferenceValue( comparationValue:integer )
- render.SetStencilWriteMask( mask:integer )
- E_StencilOperation and E_StencilComparisonFunction enums
- render.ForcedMaterialOverride( material )
- render.GetBlend()
- render.SetBlend()
- render.GetColorModulation()
- render.SetColorModulation()
- render.ClearStencilBufferRectangle( xmin:integer, ymin:integer, xmax:integer, ymax:integer, value:integer)
- New DoPostScreenSpaceEffects() callback, which is called when the game expects all screen effects to be drawn. Useful for custom glow
- DrawModel callback now resets color and alpha modulation along with depth range
- entity:GetMoveChild() - returns child entity attachment
- entity:GetMovePeer() - returns peer entity to the child
- materials.FindTexture()
- entity:ShouldDraw()
- Updated tf2 props page on Lua website
- dmc:IsDrawingBackTrack()
- dmc:IsDrawingAntiAim()
- dmc:IsDrawingGlow()
- http.Get(url)
- aimbot.GetAimbotTarget()
- gui.IsMenuOpen()
- engine.IsChatOpen()
- entity:DrawModel(flags) - trigger DrawModelExecute to draw a model right now
- Fixed typo in -  render.SetColorModulation(..)


## Lua Callbacks



# Lua Callbacks


Callbacks are the functions that are called when certain events happen. They are usually the most key parts of your scripts, and include functions like Draw(), which is called every frame - and as such is useful for drawing. Different callbacks are called in different situations, and you can use them to add custom functionality to your scripts.


## Callbacks


### Draw()


Called every frame. It is called after the screen is rendered, and can be used to draw text or objects on the screen.


### DrawModel( DrawModelContext:ctx )


Called every time a model is just about to be drawn on the screen. You can use this to change the material used to draw the model or do some other effects.\


### DrawStaticProps( StaticPropRenderInfo:info )


Called every time static props are just about to be drawn on the screen. You can use this to change colors, materials, or do some other effects.


### CreateMove( UserCmd:cmd )


Called every input update (66 times/sec), allows to modify viewangles, buttons, packet sending, etc. Useful for changing player movement or inputs.


### FireGameEvent( GameEvent:event )


Called for all available game events. Game events are small packets of information that are sent from the server to the client, data about a situation that has happened.


### DispatchUserMessage( UserMessage:msg )


Called on every user message of type UserMessage. User messages are small packets of information that are sent from the server to the client, data about a situation that has happened.


### SendStringCmd( StringCmd:cmd )


Called when console command is sent to server, ex. chat command "say".


### FrameStageNotify( stage:integer )


Called multiple times per frame for each stage of the frame, such as rendering start, end, network update start, end, etc. You can do some actions here better than anywhere else. Make sure to check the E_ClientFrameStage constant.
This used to be PostPropUpdate if you only updates on NETWORK_UPDATE_START. PostPropUpdate is now deprecated, please do not use it.


### RenderView( ViewSetup:view )


Called before the players view of type ViewSetup is rendered. You can use this to change the view, such as changing the view angles, fov, or origin.


### PostRenderView( ViewSetup:view )


Called after a players view of type ViewSetup is rendered. This is an ideal place to draw custom views (such as camera views) on the screen, as the primary view has already been rendered.


### RenderViewModel( ViewSetup:vmview )


Called before the players viewmodel view of type ViewSetup is rendered. You can use this to change the rendering of the viewmodel, such as changing the viewmodel angles, fov, or origin.


### ServerCmdKeyValues( StringCmd:keyvalues )


Called when the client sends a keyvalues message to the server. Keyvalues are a way of sending data to the server, and are used for many things, such as sending MVM Upgrades, using items, and more.


### OnFakeUncrate( Item:crate, Table:crateLootList )


Called when a fake crate is to be uncrated. This is called before the crate is actually uncrated. You can return a table of items that will be shown as uncrated. The loot list is useful as a reference for what items can be uncrated in this crate, but you can create any items you want.


### OnLobbyUpdated( GameServerLobby:lobby )


Called when a lobby is found or updated. This can also be called before the lobby is joined, so you can use this to decide whether or not to join the game (abandon), or to do something with the list of players in the lobby if youre in the game.


### SetRichPresence( String:key, String:value )


Called when the rich presence is updated. Key is the name of the rich presence, and value is the value of the rich presence. Return the value you want to set this key to, or nil to not change it.


### GCSendMessage( typeID:integer, data:StringCmd)


Called when a message is being sent to the GC. You can use this to intercept messages sent to the GC, and modify them or not send them at all.


### GCRetrieveMessage( typeID:integer, data:StringCmd)


Called when a message is being received from the GC. You can use this to intercept messages received from the GC, and modify them or not process them at all. Return E_GCResults.k_EGCResultOK to process the message, or E_GCResults.k_EGCResultNoMessage to not process it.


### SendNetMsg( NetMessage:msg, reliable:boolean, voice:boolean )


Called when a message of type NetMessage is being sent to the server. You can use this to intercept messages sent to the server, and modify them or not send them at all. Return true to send the message, or false to not send it.


### DoPostScreenSpaceEffects()


This is called after the screen space effects are rendered. You can use this to draw custom screen space effects, such as a custom bloom effect, or a custom blur effect, etc.


### Unload()


Callback called when the script file which registered it is unloaded. This is called before the script is unloaded, so you can still use your script variables.


## Examples


Intercepting GC messages```
-- Protobuf messages
callbacks.Register("GCSendMessage", function(typeID, data)

  print("GCSendMessage: " .. typeID .. " dataLength: " .. #data)

  return E_GCResults.k_EGCResultOK
end)

callbacks.Register("GCRetrieveMessage", function(typeID, data)

  print("GCRetrieveMessage: " .. typeID .. " dataLength: " .. #data)

  if typeID == 26 then
    return E_GCResults.k_EGCResultNoMessage
  end

  return E_GCResults.k_EGCResultOK
end)

```

Basic player ESP```
local myfont = draw.CreateFont( "Verdana", 16, 800 )

local function doDraw()
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then
        return
    end

    local players = entities.FindByClass("CTFPlayer")

    for i, p in ipairs( players ) do
        if p:IsAlive() and not p:IsDormant() then

            local screenPos = client.WorldToScreen( p:GetAbsOrigin() )
            if screenPos ~= nil then
                draw.SetFont( myfont )
                draw.Color( 255, 255, 255, 255 )
                draw.Text( screenPos[1], screenPos[2], p:GetName() )
            end
        end
    end
end

callbacks.Register("Draw", "mydraw", doDraw) 

```

Damage logger - by @RC```
local function damageLogger(event)

    if (event:GetName() == 'player_hurt' ) then

        local localPlayer = entities.GetLocalPlayer();
        local victim = entities.GetByUserID(event:GetInt("userid"))
        local health = event:GetInt("health")
        local attacker = entities.GetByUserID(event:GetInt("attacker"))
        local damage = event:GetInt("damageamount")

        if (attacker == nil or localPlayer:GetIndex() ~= attacker:GetIndex()) then
            return
        end

        print("You hit " ..  victim:GetName() .. " or ID " .. victim:GetIndex() .. " for " .. damage .. "HP they now have " .. health .. "HP left")
    end

end

callbacks.Register("FireGameEvent", "exampledamageLogger", damageLogger)
-- Made by @RC: https://github.com/racistcop/lmaobox-luas/blob/main/example-damagelogger.lua

```

OnFakeUncrate callback```
--- OnFakeUncrate gets called when user is unboxing a fake crate with a fake key, 
--- both could be created by our skinchanger and via CreateFakeItem method
callbacks.Register( "OnFakeUncrate", "abcd", function( itemCrate, lootTable )
    print( "OnFakeUncrate" )
    print( "itemCrate Name: " .. itemCrate:GetName() )

    for i = 1, #lootTable do
        print( "lootTable[" .. i .. "] Name: " .. lootTable[i]:GetName() )
    end

    return lootTable
end )

--- modify unboxing to always unbox rainbow flamethrower (15090)
callbacks.Register( "OnFakeUncrate", "abcd", function( itemCrate, lootTable )
    print( "OnFakeUncrate crate: " .. itemCrate:GetName() )

    local myLootTable = {}
    myLootTable[1] = itemschema.GetItemDefinitionByID(15090)

    return myLootTable
end )

```


## Predefined constants



# Predefined constants


The following constants are built in and always available. You can use them in your code as substitutions for the values they represent. 


Predefined constants```
-- Writeup by @Jesse
-- Bit Fields

E_UserCmd = {
    IN_ATTACK = (1 << 0),
    IN_JUMP = (1 << 1),
    IN_DUCK = (1 << 2),
    IN_FORWARD = (1 << 3),
    IN_BACK = (1 << 4),
    IN_USE = (1 << 5),
    IN_CANCEL = (1 << 6),
    IN_LEFT = (1 << 7),
    IN_RIGHT = (1 << 8),
    IN_MOVELEFT = (1 << 9),
    IN_MOVERIGHT = (1 << 10),
    IN_ATTACK2 = (1 << 11),
    IN_RUN = (1 << 12),
    IN_RELOAD = (1 << 13),
    IN_ALT1 = (1 << 14),
    IN_ALT2 = (1 << 15),
    IN_SCORE = (1 << 16),
    IN_SPEED = (1 << 17),
    IN_WALK = (1 << 18),
    IN_ZOOM = (1 << 19),
    IN_WEAPON1 = (1 << 20),
    IN_WEAPON2 = (1 << 21),
    IN_BULLRUSH = (1 << 22),
    IN_GRENADE2 = (1 << 24),
    IN_ATTACK3 = (1 << 25),
}

E_ButtonCode = {
    BUTTON_CODE_INVALID = -1,
    BUTTON_CODE_NONE = 0,
    KEY_FIRST = 0,
    KEY_NONE = KEY_FIRST,
    KEY_0 = 1,
    KEY_1 = 2,
    KEY_2 = 3,
    KEY_3 = 4,
    KEY_4 = 5,
    KEY_5 = 6,
    KEY_6 = 7,
    KEY_7 = 8,
    KEY_8 = 9,
    KEY_9 = 10,
    KEY_A = 11,
    KEY_B = 12,
    KEY_C = 13,
    KEY_D = 14,
    KEY_E = 15,
    KEY_F = 16,
    KEY_G = 17,
    KEY_H = 18,
    KEY_I = 19,
    KEY_J = 20,
    KEY_K = 21,
    KEY_L = 22,
    KEY_M = 23,
    KEY_N = 24,
    KEY_O = 25,
    KEY_P = 26,
    KEY_Q = 27,
    KEY_R = 28,
    KEY_S = 29,
    KEY_T = 30,
    KEY_U = 31,
    KEY_V = 32,
    KEY_W = 33,
    KEY_X = 34,
    KEY_Y = 35,
    KEY_Z = 36,
    KEY_PAD_0 = 37,
    KEY_PAD_1 = 38,
    KEY_PAD_2 = 39,
    KEY_PAD_3 = 40,
    KEY_PAD_4 = 41,
    KEY_PAD_5 = 42,
    KEY_PAD_6 = 43,
    KEY_PAD_7 = 44,
    KEY_PAD_8 = 45,
    KEY_PAD_9 = 46,
    KEY_PAD_DIVIDE = 47,
    KEY_PAD_MULTIPLY = 48,
    KEY_PAD_MINUS = 49,
    KEY_PAD_PLUS = 50,
    KEY_PAD_ENTER = 51,
    KEY_PAD_DECIMAL = 52,
    KEY_LBRACKET = 53,
    KEY_RBRACKET = 54,
    KEY_SEMICOLON = 55,
    KEY_APOSTROPHE = 56,
    KEY_BACKQUOTE = 57,
    KEY_COMMA = 58,
    KEY_PERIOD = 59,
    KEY_SLASH = 60,
    KEY_BACKSLASH = 61,
    KEY_MINUS = 62,
    KEY_EQUAL = 63,
    KEY_ENTER = 64,
    KEY_SPACE = 65,
    KEY_BACKSPACE = 66,
    KEY_TAB = 67,
    KEY_CAPSLOCK = 68,
    KEY_NUMLOCK = 69,
    KEY_ESCAPE = 70,
    KEY_SCROLLLOCK = 71,
    KEY_INSERT = 72,
    KEY_DELETE = 73,
    KEY_HOME = 74,
    KEY_END = 75,
    KEY_PAGEUP = 76,
    KEY_PAGEDOWN = 77,
    KEY_BREAK = 78,
    KEY_LSHIFT = 79,
    KEY_RSHIFT = 80,
    KEY_LALT = 81,
    KEY_RALT = 82,
    KEY_LCONTROL = 83,
    KEY_RCONTROL = 84,
    KEY_LWIN = 85,
    KEY_RWIN = 86,
    KEY_APP = 87,
    KEY_UP = 88,
    KEY_LEFT = 89,
    KEY_DOWN = 90,
    KEY_RIGHT = 91,
    KEY_F1 = 92,
    KEY_F2 = 93,
    KEY_F3 = 94,
    KEY_F4 = 95,
    KEY_F5 = 96,
    KEY_F6 = 97,
    KEY_F7 = 98,
    KEY_F8 = 99,
    KEY_F9 = 100,
    KEY_F10 = 101,
    KEY_F11 = 102,
    KEY_F12 = 103,
    KEY_CAPSLOCKTOGGLE = 104,
    KEY_NUMLOCKTOGGLE = 105,
    KEY_SCROLLLOCKTOGGLE = 106,
    KEY_LAST = KEY_SCROLLLOCKTOGGLE,
    KEY_COUNT = KEY_LAST - KEY_FIRST + 1,
    MOUSE_FIRST = KEY_LAST + 1,
    MOUSE_LEFT = MOUSE_FIRST,
    MOUSE_RIGHT = MOUSE_FIRST + 1,
    MOUSE_MIDDLE = MOUSE_FIRST + 2,
    MOUSE_4 = MOUSE_FIRST + 3,
    MOUSE_5 = MOUSE_FIRST + 4,
    MOUSE_WHEEL_UP = MOUSE_FIRST + 5,
    MOUSE_WHEEL_DOWN = MOUSE_FIRST + 6,
}

E_LifeState = {
    LIFE_ALIVE = 0,
    LIFE_DYING = 1,
    LIFE_DEAD = 2,
    LIFE_RESPAWNABLE = 3,
    LIFE_DISCARDAIM_BODY = 4,
}

E_UserMessage = {
    Geiger = 0,
    Train = 1,
    HudText = 2,
    SayText = 3,
    SayText2 = 4,
    TextMsg = 5,
    ResetHUD = 6,
    GameTitle = 7,
    ItemPickup = 8,
    ShowMenu = 9,
    Shake = 10,
    Fade = 11,
    VGUIMenu = 12,
    Rumble = 13,
    CloseCaption = 14,
    SendAudio = 15,
    VoiceMask = 16,
    RequestState = 17,
    Damage = 18,
    HintText = 19,
    KeyHintText = 20,
    HudMsg = 21,
    AmmoDenied = 22,
    AchievementEvent = 23,
    UpdateRadar = 24,
    VoiceSubtitle = 25,
    HudNotify = 26,
    HudNotifyCustom = 27,
    PlayerStatsUpdate = 28,
    MapStatsUpdate = 29,
    PlayerIgnited = 30,
    PlayerIgnitedInv = 31,
    HudArenaNotify = 32,
    UpdateAchievement = 33,
    TrainingMsg = 34,
    TrainingObjective = 35,
    DamageDodged = 36,
    PlayerJarated = 37,
    PlayerExtinguished = 38,
    PlayerJaratedFade = 39,
    PlayerShieldBlocked = 40,
    BreakModel = 41,
    CheapBreakModel = 42,
    BreakModel_Pumpkin = 43,
    BreakModelRocketDud = 44,
    CallVoteFailed = 45,
    VoteStart = 46,
    VotePass = 47,
    VoteFailed = 48,
    VoteSetup = 49,
    PlayerBonusPoints = 50,
    RDTeamPointsChanged = 51,
    SpawnFlyingBird = 52,
    PlayerGodRayEffect = 53,
    PlayerTeleportHomeEffect = 54,
    MVMStatsReset = 55,
    MVMPlayerEvent = 56,
    MVMResetPlayerStats = 57,
    MVMWaveFailed = 58,
    MVMAnnouncement = 59,
    MVMPlayerUpgradedEvent = 60,
    MVMVictory = 61,
    MVMWaveChange = 62,
    MVMLocalPlayerUpgradesClear = 63,
    MVMLocalPlayerUpgradesValue = 64,
    MVMResetPlayerWaveSpendingStats = 65,
    MVMLocalPlayerWaveSpendingValue = 66,
    MVMResetPlayerUpgradeSpending = 67,
    MVMServerKickTimeUpdate = 68,
    PlayerLoadoutUpdated = 69,
    PlayerTauntSoundLoopStart = 70,
    PlayerTauntSoundLoopEnd = 71,
    ForcePlayerViewAngles = 72,
    BonusDucks = 73,
    EOTLDuckEvent = 74,
    PlayerPickupWeapon = 75,
    QuestObjectiveCompleted = 76,
    SPHapWeapEvent = 77,
    HapDmg = 78,
    HapPunch = 79,
    HapSetDrag = 80,
    HapSetConst = 81,
    HapMeleeContact = 82,
}

E_WeaponBaseID = {
    TF_WEAPON_NONE = 0,
    TF_WEAPON_BAT = 1,
    TF_WEAPON_BAT_WOOD = 2,
    TF_WEAPON_BOTTLE = 3,
    TF_WEAPON_FIREAXE = 4,
    TF_WEAPON_CLUB = 5,
    TF_WEAPON_CROWBAR = 6,
    TF_WEAPON_KNIFE = 7,
    TF_WEAPON_FISTS = 8,
    TF_WEAPON_SHOVEL = 9,
    TF_WEAPON_WRENCH = 10,
    TF_WEAPON_BONESAW = 11,
    TF_WEAPON_SHOTGUN_PRIMARY = 12,
    TF_WEAPON_SHOTGUN_SOLDIER = 13,
    TF_WEAPON_SHOTGUN_HWG = 14,
    TF_WEAPON_SHOTGUN_PYRO = 15,
    TF_WEAPON_SCATTERGUN = 16,
    TF_WEAPON_SNIPERRIFLE = 17,
    TF_WEAPON_MINIGUN = 18,
    TF_WEAPON_SMG = 19,
    TF_WEAPON_SYRINGEGUN_MEDIC = 20,
    TF_WEAPON_TRANQ = 21,
    TF_WEAPON_ROCKETLAUNCHER = 22,
    TF_WEAPON_GRENADELAUNCHER = 23,
    TF_WEAPON_PIPEBOMBLAUNCHER = 24,
    TF_WEAPON_FLAMETHROWER = 25,
    TF_WEAPON_GRENADE_NORMAL = 26,
    TF_WEAPON_GRENADE_CONCUSSION = 27,
    TF_WEAPON_GRENADE_NAIL = 28,
    TF_WEAPON_GRENADE_MIRV = 29,
    TF_WEAPON_GRENADE_MIRV_DEMOMAN = 30,
    TF_WEAPON_GRENADE_NAPALM = 31,
    TF_WEAPON_GRENADE_GAS = 32,
    TF_WEAPON_GRENADE_EMP = 33,
    TF_WEAPON_GRENADE_CALTROP = 34,
    TF_WEAPON_GRENADE_PIPEBOMB = 35,
    TF_WEAPON_GRENADE_SMOKE_BOMB = 36,
    TF_WEAPON_GRENADE_HEAL = 37,
    TF_WEAPON_GRENADE_STUNBALL = 38,
    TF_WEAPON_GRENADE_JAR = 39,
    TF_WEAPON_GRENADE_JAR_MILK = 40,
    TF_WEAPON_PISTOL = 41,
    TF_WEAPON_PISTOL_SCOUT = 42,
    TF_WEAPON_REVOLVER = 43,
    TF_WEAPON_NAILGUN = 44,
    TF_WEAPON_PDA = 45,
    TF_WEAPON_PDA_ENGINEER_BUILD = 46,
    TF_WEAPON_PDA_ENGINEER_DESTROY = 47,
    TF_WEAPON_PDA_SPY = 48,
    TF_WEAPON_BUILDER = 49,
    TF_WEAPON_MEDIGUN = 50,
    TF_WEAPON_GRENADE_MIRVBOMB = 51,
    TF_WEAPON_FLAMETHROWER_ROCKET = 52,
    TF_WEAPON_GRENADE_DEMOMAN = 53,
    TF_WEAPON_SENTRY_BULLET = 54,
    TF_WEAPON_SENTRY_ROCKET = 55,
    TF_WEAPON_DISPENSER = 56,
    TF_WEAPON_INVIS = 57,
    TF_WEAPON_FLAREGUN = 58,
    TF_WEAPON_LUNCHBOX = 59,
    TF_WEAPON_JAR = 60,
    TF_WEAPON_COMPOUND_BOW = 61,
    TF_WEAPON_BUFF_ITEM = 62,
    TF_WEAPON_PUMPKIN_BOMB = 63,
    TF_WEAPON_SWORD = 64,
    TF_WEAPON_DIRECTHIT = 65,
    TF_WEAPON_LIFELINE = 66,
    TF_WEAPON_LASER_POINTER = 67,
    TF_WEAPON_DISPENSER_GUN = 68,
    TF_WEAPON_SENTRY_REVENGE = 69,
    TF_WEAPON_JAR_MILK = 70,
    TF_WEAPON_HANDGUN_SCOUT_PRIMARY = 71,
    TF_WEAPON_BAT_FISH = 72,
    TF_WEAPON_CROSSBOW = 73,
    TF_WEAPON_STICKBOMB = 74,
    TF_WEAPON_HANDGUN_SCOUT_SEC = 75,
    TF_WEAPON_SODA_POPPER = 76,
    TF_WEAPON_SNIPERRIFLE_DECAP = 77,
    TF_WEAPON_RAYGUN = 78,
    TF_WEAPON_PARTICLE_CANNON = 79,
    TF_WEAPON_MECHANICAL_ARM = 80,
    TF_WEAPON_DRG_POMSON = 81,
    TF_WEAPON_BAT_GIFTWRAP = 82,
    TF_WEAPON_GRENADE_ORNAMENT = 83,
    TF_WEAPON_RAYGUN_REVENGE = 84,
    TF_WEAPON_PEP_BRAWLER_BLASTER = 85,
    TF_WEAPON_CLEAVER = 86,
    TF_WEAPON_GRENADE_CLEAVER = 87,
    TF_WEAPON_STICKY_BALL_LAUNCHER = 88,
    TF_WEAPON_GRENADE_STICKY_BALL = 89,
    TF_WEAPON_SHOTGUN_BUILDING_RESCUE = 90,
    TF_WEAPON_CANNON = 91,
    TF_WEAPON_THROWABLE = 92,
    TF_WEAPON_GRENADE_THROWABLE = 93,
    TF_WEAPON_PDA_SPY_BUILD = 94,
    TF_WEAPON_GRENADE_WATERBALLOON = 95,
    TF_WEAPON_HARVESTER_SAW = 96,
    TF_WEAPON_SPELLBOOK = 97,
    TF_WEAPON_SPELLBOOK_PROJECTILE = 98,
    TF_WEAPON_SNIPERRIFLE_CLASSIC = 99,
    TF_WEAPON_PARACHUTE = 100,
    TF_WEAPON_GRAPPLINGHOOK = 101,
    TF_WEAPON_PASSTIME_GUN = 102,
    TF_WEAPON_CHARGED_SMG = 103,
    TF_WEAPON_BREAKABLE_SIGN = 104,
    TF_WEAPON_ROCKETPACK = 105,
    TF_WEAPON_SLAP = 106,
    TF_WEAPON_JAR_GAS = 107,
    TF_WEAPON_GRENADE_JAR_GAS = 108,
    TF_WEAPON_FLAME_BALL = 109,
}

E_TFCOND = {
    TFCond_Slowed = 0,
    TFCond_Zoomed = 1,
    TFCond_Disguising = 2,
    TFCond_Disguised = 3,
    TFCond_Cloaked = 4,
    TFCond_Ubercharged = 5,
    TFCond_TeleportedGlow = 6,
    TFCond_Taunting = 7,
    TFCond_UberchargeFading = 8,
    TFCond_Unknown1 = 9,
    TFCond_CloakFlicker = 9,
    TFCond_Teleporting = 10,
    TFCond_Kritzkrieged = 11,
    TFCond_Unknown2 = 12,
    TFCond_TmpDamageBonus = 12,
    TFCond_DeadRingered = 13,
    TFCond_Bonked = 14,
    TFCond_Dazed = 15,
    TFCond_Buffed = 16,
    TFCond_Charging = 17,
    TFCond_DemoBuff = 18,
    TFCond_CritCola = 19,
    TFCond_InHealRadius = 20,
    TFCond_Healing = 21,
    TFCond_OnFire = 22,
    TFCond_Overhealed = 23,
    TFCond_Jarated = 24,
    TFCond_Bleeding = 25,
    TFCond_DefenseBuffed = 26,
    TFCond_Milked = 27,
    TFCond_MegaHeal = 28,
    TFCond_RegenBuffed = 29,
    TFCond_MarkedForDeath = 30,
    TFCond_NoHealingDamageBuff = 31,
    TFCond_SpeedBuffAlly = 32,
    TFCond_HalloweenCritCandy = 33,
    TFCond_CritCanteen = 34,
    TFCond_CritDemoCharge = 35,
    TFCond_CritHype = 36,
    TFCond_CritOnFirstBlood = 37,
    TFCond_CritOnWin = 38,
    TFCond_CritOnFlagCapture = 39,
    TFCond_CritOnKill = 40,
    TFCond_RestrictToMelee = 41,
    TFCond_DefenseBuffNoCritBlock = 42,
    TFCond_Reprogrammed = 43,
    TFCond_CritMmmph = 44,
    TFCond_DefenseBuffMmmph = 45,
    TFCond_FocusBuff = 46,
    TFCond_DisguiseRemoved = 47,
    TFCond_MarkedForDeathSilent = 48,
    TFCond_DisguisedAsDispenser = 49,
    TFCond_Sapped = 50,
    TFCond_UberchargedHidden = 51,
    TFCond_UberchargedCanteen = 52,
    TFCond_HalloweenBombHead = 53,
    TFCond_HalloweenThriller = 54,
    TFCond_RadiusHealOnDamage = 55,
    TFCond_CritOnDamage = 56,
    TFCond_UberchargedOnTakeDamage = 57,
    TFCond_UberBulletResist = 58,
    TFCond_UberBlastResist = 59,
    TFCond_UberFireResist = 60,
    TFCond_SmallBulletResist = 61,
    TFCond_SmallBlastResist = 62,
    TFCond_SmallFireResist = 63,
    TFCond_Stealthed = 64,
    TFCond_MedigunDebuff = 65,
    TFCond_StealthedUserBuffFade = 66,
    TFCond_BulletImmune = 67,
    TFCond_BlastImmune = 68,
    TFCond_FireImmune = 69,
    TFCond_PreventDeath = 70,
    TFCond_MVMBotRadiowave = 71,
    TFCond_HalloweenSpeedBoost = 72,
    TFCond_HalloweenQuickHeal = 73,
    TFCond_HalloweenGiant = 74,
    TFCond_HalloweenTiny = 75,
    TFCond_HalloweenInHell = 76,
    TFCond_HalloweenGhostMode = 77,
    TFCond_MiniCritOnKill = 78,
    TFCond_DodgeChance = 79,
    TFCond_ObscuredSmoke = 79,
    TFCond_Parachute = 80,
    TFCond_BlastJumping = 81,
    TFCond_HalloweenKart = 82,
    TFCond_HalloweenKartDash = 83,
    TFCond_BalloonHead = 84,
    TFCond_MeleeOnly = 85,
    TFCond_SwimmingCurse = 86,
    TFCond_HalloweenKartNoTurn = 87,
    TFCond_FreezeInput = 87,
    TFCond_HalloweenKartCage = 88,
    TFCond_HasRune = 89,
    TFCond_RuneStrength = 90,
    TFCond_RuneHaste = 91,
    TFCond_RuneRegen = 92,
    TFCond_RuneResist = 93,
    TFCond_RuneVampire = 94,
    TFCond_RuneWarlock = 95,
    TFCond_RunePrecision = 96,
    TFCond_RuneAgility = 97,
    TFCond_GrapplingHook = 98,
    TFCond_GrapplingHookSafeFall = 99,
    TFCond_GrapplingHookLatched = 100,
    TFCond_GrapplingHookBleeding = 101,
    TFCond_AfterburnImmune = 102,
    TFCond_RuneKnockout = 103,
    TFCond_RuneImbalance = 104,
    TFCond_CritRuneTemp = 105,
    TFCond_PasstimeInterception = 106,
    TFCond_SwimmingNoEffects = 107,
    TFCond_EyeaductUnderworld = 108,
    TFCond_KingRune = 109,
    TFCond_PlagueRune = 110,
    TFCond_SupernovaRune = 111,
    TFCond_Plague = 112,
    TFCond_KingAura = 113,
    TFCond_SpawnOutline = 114,
    TFCond_KnockedIntoAir = 115,
    TFCond_CompetitiveWinner = 116,
    TFCond_CompetitiveLoser = 117,
    TFCond_NoTaunting_DEPRECATED = 118,
    TFCond_HealingDebuff = 118,
    TFCond_PasstimePenaltyDebuff = 119,
    TFCond_GrappledToPlayer = 120,
    TFCond_GrappledByPlayer = 121,
    TFCond_ParachuteDeployed = 122,
    TFCond_Gas = 123,
    TFCond_BurningPyro = 124,
    TFCond_RocketPack = 125,
    TFCond_LostFooting = 126,
    TFCond_AirCurrent = 127,
}

E_SignonState = {
    SIGNONSTATE_NONE = 0,
    SIGNONSTATE_CHALLENGE = 1,
    SIGNONSTATE_CONNECTED = 2,
    SIGNONSTATE_NEW = 3,
    SIGNONSTATE_PRESPAWN = 4,
    SIGNONSTATE_SPAWN = 5,
    SIGNONSTATE_FULL = 6,
    SIGNONSTATE_CHANGELEVEL = 7,
}

E_KillEffect = {
    TF_CUSTOM_AIM_HEADSHOT = 1,
    TF_CUSTOM_BACKSTAB = 2,
    TF_CUSTOM_BURNING = 3,
    TF_CUSTOM_WRENCH_FIX = 4,
    TF_CUSTOM_MINIGUN = 5,
    TF_CUSTOM_SUICIDE = 6,
    TF_CUSTOM_TAUNT_HADOUKEN = 7,
    TF_CUSTOM_BURNING_FLARE = 8,
    TF_CUSTOM_TAUNT_HIGH_NOON = 9,
    TF_CUSTOM_TAUNT_GRAND_SLAM = 10,
    TF_CUSTOM_PENETRATE_MY_TEAM = 11,
    TF_CUSTOM_PENETRATE_ALL_PLAYERS = 12,
    TF_CUSTOM_TAUNT_FENCING = 13,
    TF_CUSTOM_PENETRATE_AIM_HEADSHOT = 14,
    TF_CUSTOM_TAUNT_ARROW_STAB = 15,
    TF_CUSTOM_TELEFRAG = 16,
    TF_CUSTOM_BURNING_ARROW = 17,
    TF_CUSTOM_FLYINGBURN = 18,
    TF_CUSTOM_PUMPKIN_BOMB = 19,
    TF_CUSTOM_DECAPITATION = 20,
    TF_CUSTOM_TAUNT_GRENADE = 21,
    TF_CUSTOM_BASEBALL = 22,
    TF_CUSTOM_CHARGE_IMPACT = 23,
    TF_CUSTOM_TAUNT_BARBARIAN_SWING = 24,
    TF_CUSTOM_AIR_STICKY_BURST = 25,
    TF_CUSTOM_DEFENSIVE_STICKY = 26,
    TF_CUSTOM_PICKAXE = 27,
    TF_CUSTOM_ROCKET_DIRECTHIT = 28,
    TF_CUSTOM_TAUNT_UBERSLICE = 29,
    TF_CUSTOM_PLAYER_SENTRY = 30,
    TF_CUSTOM_STANDARD_STICKY = 31,
    TF_CUSTOM_SHOTGUN_REVENGE_CRIT = 32,
    TF_CUSTOM_TAUNT_ENGINEER_SMASH = 33,
    TF_CUSTOM_BLEEDING = 34,
    TF_CUSTOM_GOLD_WRENCH = 35,
    TF_CUSTOM_CARRIED_BUILDING = 36,
    TF_CUSTOM_COMBO_PUNCH = 37,
    TF_CUSTOM_TAUNT_ENGINEER_ARM = 38,
    TF_CUSTOM_FISH_KILL = 39,
    TF_CUSTOM_TRIGGER_HURT = 40,
    TF_CUSTOM_DECAPITATION_BOSS = 41,
    TF_CUSTOM_STICKBOMB_EXPLOSION = 42,
    TF_CUSTOM_AEGIS_ROUND = 43,
    TF_CUSTOM_FLARE_EXPLOSION = 44,
    TF_CUSTOM_BOOTS_STOMP = 45,
    TF_CUSTOM_PLASMA = 46,
    TF_CUSTOM_PLASMA_CHARGED = 47,
    TF_CUSTOM_PLASMA_GIB = 48,
    TF_CUSTOM_PRACTICE_STICKY = 49,
    TF_CUSTOM_EYEBALL_ROCKET = 50,
    TF_CUSTOM_AIM_HEADSHOT_DECAPITATION = 51,
    TF_CUSTOM_TAUNT_ARMAGEDDON = 52,
    TF_CUSTOM_FLARE_PELLET = 53,
    TF_CUSTOM_CLEAVER = 54,
    TF_CUSTOM_CLEAVER_CRIT = 55,
    TF_CUSTOM_SAPPER_RECORDER_DEATH = 56,
    TF_CUSTOM_MERASMUS_PLAYER_BOMB = 57,
    TF_CUSTOM_MERASMUS_GRENADE = 58,
    TF_CUSTOM_MERASMUS_ZAP = 59,
    TF_CUSTOM_MERASMUS_DECAPITATION = 60,
    TF_CUSTOM_CANNONBALL_PUSH = 61,
}

E_Character = {
    TF2_Scout = 1,
    TF2_Soldier = 3,
    TF2_Pyro = 7,
    TF2_Demoman = 4,
    TF2_Heavy = 6,
    TF2_Engineer = 9,
    TF2_Medic = 5,
    TF2_Sniper = 2,
    TF2_Spy = 8,
}

E_TraceLine = {
    CONTENTS_EMPTY = 0,
    CONTENTS_SOLID = 0x1,
    CONTENTS_WINDOW = 0x2,
    CONTENTS_AUX = 0x4,
    CONTENTS_GRATE = 0x8,
    CONTENTS_SLIME = 0x10,
    CONTENTS_WATER = 0x20,
    CONTENTS_BLOCKLOS = 0x40,
    CONTENTS_OPAQUE = 0x80,
    CONTENTS_TESTFOGVOLUME = 0x100,
    CONTENTS_UNUSED = 0x200,
    CONTENTS_BLOCKLIGHT = 0x400,
    CONTENTS_TEAM1 = 0x800,
    CONTENTS_TEAM2 = 0x1000,
    CONTENTS_IGNORE_NODRAW_OPAQUE = 0x2000,
    CONTENTS_MOVEABLE = 0x4000,
    CONTENTS_AREAPORTAL = 0x8000,
    CONTENTS_PLAYERCLIP = 0x10000,
    CONTENTS_MONSTERCLIP = 0x20000,
    CONTENTS_CURRENT_0 = 0x40000,
    CONTENTS_CURRENT_90 = 0x80000,
    CONTENTS_CURRENT_180 = 0x100000,
    CONTENTS_CURRENT_270 = 0x200000,
    CONTENTS_CURRENT_UP = 0x400000,
    CONTENTS_CURRENT_DOWN = 0x800000,
    CONTENTS_ORIGIN = 0x1000000,
    CONTENTS_MONSTER = 0x2000000,
    CONTENTS_DEBRIS = 0x4000000,
    CONTENTS_DETAIL = 0x8000000,
    CONTENTS_TRANSLUCENT = 0x10000000,
    CONTENTS_LADDER = 0x20000000,
    CONTENTS_HITBOX = 0x40000000,
    SURF_LIGHT = 0x0001,
    SURF_SKY2D = 0x0002,
    SURF_SKY = 0x0004,
    SURF_WARP = 0x0008,
    SURF_TRANS = 0x0010,
    SURF_NOPORTAL = 0x0020,
    SURF_TRIGGER = 0x0040,
    SURF_NODRAW = 0x0080,
    SURF_HINT = 0x0100,
    SURF_SKIP = 0x0200,
    SURF_NOLIGHT = 0x0400,
    SURF_BUMPLIGHT = 0x0800,
    SURF_NOSHADOWS = 0x1000,
    SURF_NODECALS = 0x2000,
    SURF_NOPAINT = SURF_NODECALS,
    SURF_NOCHOP = 0x4000,
    SURF_HITBOX = 0x8000,
    MASK_ALL = (0xFFFFFFFF),
    MASK_SOLID = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_WINDOW|CONTENTS_MONSTER|CONTENTS_GRATE),
    MASK_PLAYERSOLID = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_PLAYERCLIP|CONTENTS_WINDOW|CONTENTS_MONSTER|CONTENTS_GRATE),
    MASK_NPCSOLID = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_MONSTERCLIP|CONTENTS_WINDOW|CONTENTS_MONSTER|CONTENTS_GRATE),
    MASK_NPCFLUID = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_MONSTERCLIP|CONTENTS_WINDOW|CONTENTS_MONSTER),
    MASK_WATER = (CONTENTS_WATER|CONTENTS_MOVEABLE|CONTENTS_SLIME),
    MASK_OPAQUE = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_OPAQUE),
    MASK_OPAQUE_AND_NPCS = (MASK_OPAQUE|CONTENTS_MONSTER),
    MASK_BLOCKLOS = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_BLOCKLOS),
    MASK_BLOCKLOS_AND_NPCS = (MASK_BLOCKLOS|CONTENTS_MONSTER),
    MASK_VISIBLE = (MASK_OPAQUE|CONTENTS_IGNORE_NODRAW_OPAQUE),
    MASK_VISIBLE_AND_NPCS = (MASK_OPAQUE_AND_NPCS|CONTENTS_IGNORE_NODRAW_OPAQUE),
    MASK_SHOT = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_MONSTER|CONTENTS_WINDOW|CONTENTS_DEBRIS|CONTENTS_HITBOX),
    MASK_SHOT_BRUSHONLY = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_WINDOW|CONTENTS_DEBRIS),
    MASK_SHOT_HULL = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_MONSTER|CONTENTS_WINDOW|CONTENTS_DEBRIS|CONTENTS_GRATE),
    MASK_SHOT_PORTAL = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_WINDOW|CONTENTS_MONSTER),
    MASK_SOLID_BRUSHONLY = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_WINDOW|CONTENTS_GRATE),
    MASK_PLAYERSOLID_BRUSHONLY = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_WINDOW|CONTENTS_PLAYERCLIP|CONTENTS_GRATE),
    MASK_NPCSOLID_BRUSHONLY = (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_WINDOW|CONTENTS_MONSTERCLIP|CONTENTS_GRATE),
    MASK_NPCWORLDSTATIC = (CONTENTS_SOLID|CONTENTS_WINDOW|CONTENTS_MONSTERCLIP|CONTENTS_GRATE),
    MASK_NPCWORLDSTATIC_FLUID = (CONTENTS_SOLID|CONTENTS_WINDOW|CONTENTS_MONSTERCLIP),
    MASK_SPLITAREAPORTAL = (CONTENTS_WATER|CONTENTS_SLIME),
    MASK_CURRENT = (CONTENTS_CURRENT_0|CONTENTS_CURRENT_90|CONTENTS_CURRENT_180|CONTENTS_CURRENT_270|CONTENTS_CURRENT_UP|CONTENTS_CURRENT_DOWN),
    MASK_DEADSOLID = (CONTENTS_SOLID|CONTENTS_PLAYERCLIP|CONTENTS_WINDOW|CONTENTS_GRATE),
    MAX_COORD_INTEGER = (16384),
    COORD_EXTENT = (2*MAX_COORD_INTEGER),
    MAX_TRACE_LENGTH = (1.732050807569*COORD_EXTENT),
}

E_MaterialFlag = {
    MATERIAL_VAR_DEBUG = (1 << 0),
    MATERIAL_VAR_NO_DEBUG_OVERRIDE = (1 << 1),
    MATERIAL_VAR_NO_DRAW = (1 << 2),
    MATERIAL_VAR_USE_IN_FILLRATE_MODE = (1 << 3),
    MATERIAL_VAR_VERTEXCOLOR = (1 << 4),
    MATERIAL_VAR_VERTEXALPHA = (1 << 5),
    MATERIAL_VAR_SELFILLUM = (1 << 6),
    MATERIAL_VAR_ADDITIVE = (1 << 7),
    MATERIAL_VAR_ALPHATEST = (1 << 8),
    MATERIAL_VAR_ZNEARER = (1 << 10),
    MATERIAL_VAR_MODEL = (1 << 11),
    MATERIAL_VAR_FLAT = (1 << 12),
    MATERIAL_VAR_NOCULL = (1 << 13),
    MATERIAL_VAR_NOFOG = (1 << 14),
    MATERIAL_VAR_IGNOREZ = (1 << 15),
    MATERIAL_VAR_DECAL = (1 << 16),
    MATERIAL_VAR_ENVMAPSPHERE = (1 << 17),
    MATERIAL_VAR_ENVMAPCAMERASPACE = (1 << 19),
    MATERIAL_VAR_BASEALPHAENVMAPMASK = (1 << 20),
    MATERIAL_VAR_TRANSLUCENT = (1 << 21),
    MATERIAL_VAR_NORMALMAPALPHAENVMAPMASK = (1 << 22),
    MATERIAL_VAR_NEEDS_SOFTWARE_SKINNING = (1 << 23),
    MATERIAL_VAR_OPAQUETEXTURE = (1 << 24),
    MATERIAL_VAR_ENVMAPMODE = (1 << 25),
    MATERIAL_VAR_SUPPRESS_DECALS = (1 << 26),
    MATERIAL_VAR_HALFLAMBERT = (1 << 27),
    MATERIAL_VAR_WIREFRAME = (1 << 28),
    MATERIAL_VAR_ALLOWALPHATOCOVERAGE = (1 << 29),
    MATERIAL_VAR_ALPHA_MODIFIED_BY_PROXY = (1 << 30),
    MATERIAL_VAR_VERTEXFOG = (1 << 31),
}

E_LoadoutSlot = {
    LOADOUT_POSITION_PRIMARY = 0,
    LOADOUT_POSITION_SECONDARY = 1,
    LOADOUT_POSITION_MELEE = 2,
    LOADOUT_POSITION_UTILITY = 3,
    LOADOUT_POSITION_BUILDING = 4,
    LOADOUT_POSITION_PDA = 5,
    LOADOUT_POSITION_PDA2 = 6,
    LOADOUT_POSITION_HEAD = 7,
    LOADOUT_POSITION_MISC = 8,
    LOADOUT_POSITION_ACTION = 9,
    LOADOUT_POSITION_MISC2 = 10,
    LOADOUT_POSITION_TAUNT = 11,
    LOADOUT_POSITION_TAUNT2 = 12,
    LOADOUT_POSITION_TAUNT3 = 13,
    LOADOUT_POSITION_TAUNT4 = 14,
    LOADOUT_POSITION_TAUNT5 = 15,
    LOADOUT_POSITION_TAUNT6 = 16,
    LOADOUT_POSITION_TAUNT7 = 17,
    LOADOUT_POSITION_TAUNT8 = 18,
}

E_RoundState = {
    ROUND_INIT = 0,
    ROUND_PREGAME = 1,
    ROUND_STARTGAME = 2,
    ROUND_PREROUND = 3,
    ROUND_RUNNING = 4,
    ROUND_TEAMWIN = 5,
    ROUND_RESTART = 6,
    ROUND_STALEMATE = 7,
    ROUND_GAMEOVER = 8,
    ROUND_BONUS = 9,
    ROUND_BETWEEN_ROUNDS = 10,
}

E_PlayerFlag = {
    FL_ONGROUND = (1 << 0),
    FL_DUCKING = (1 << 1),
    FL_WATERJUMP = (1 << 2),
    FL_ONTRAIN = (1 << 3),
    FL_INRAIN = (1 << 4),
    FL_FROZEN = (1 << 5),
    FL_ATCONTROLS = (1 << 6),
    FL_CLIENT = (1 << 7),
    FL_FAKECLIENT = (1 << 8),
    FL_INWATER = (1 << 9),
}

E_FontFlag = {
    FONTFLAG_NONE = 0,
    FONTFLAG_ITALIC = 0x001,
    FONTFLAG_UNDERLINE = 0x002,
    FONTFLAG_STRIKEOUT = 0x004,
    FONTFLAG_SYMBOL = 0x008,
    FONTFLAG_ANTIALIAS = 0x010,
    FONTFLAG_GAUSSIANBLUR = 0x020,
    FONTFLAG_ROTARY = 0x040,
    FONTFLAG_DROPSHADOW = 0x080,
    FONTFLAG_ADDITIVE = 0x100,
    FONTFLAG_OUTLINE = 0x200,
    FONTFLAG_CUSTOM = 0x400,
    FONTFLAG_BITMAP = 0x800,
}

E_MatchAbandonStatus = {
    MATCHABANDON_SAFE = 0,
    MATCHABANDON_NOPENALTY = 1,
    MATCHABANDON_PENTALTY = 2,
}

--- Purposed

E_FileAttribute = {
    FILE_ATTRIBUTE_READONLY = 0x1,
    FILE_ATTRIBUTE_HIDDEN = 0x2,
    FILE_ATTRIBUTE_SYSTEM = 0x4,
    FILE_ATTRIBUTE_DIRECTORY = 0x10,
    FILE_ATTRIBUTE_ARCHIVE = 0x20,
    FILE_ATTRIBUTE_DEVICE = 0x40,
    FILE_ATTRIBUTE_NORMAL = 0x80,
    FILE_ATTRIBUTE_TEMPORARY = 0x100,
    FILE_ATTRIBUTE_SPARSE_FILE = 0x200,
    FILE_ATTRIBUTE_REPARSE_POINT = 0x400,
    FILE_ATTRIBUTE_COMPRESSED = 0x800,
    FILE_ATTRIBUTE_OFFLINE = 0x1000,
    FILE_ATTRIBUTE_NOT_CONTENT_INDEXED = 0x2000,
    FILE_ATTRIBUTE_ENCRYPTED = 0x4000,
    FILE_ATTRIBUTE_INTEGRITY_STREAM = 0x8000,
    FILE_ATTRIBUTE_VIRTUAL = 0x10000,
    FILE_ATTRIBUTE_NO_SCRUB_DATA = 0x20000,
    FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x40000,
    FILE_ATTRIBUTE_PINNED = 0x80000,
    FILE_ATTRIBUTE_UNPINNED = 0x100000,
    FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x400000,
    INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF,
}

E_TeamNumber = {
    TEAM_UNASSIGNED = 0,
    TEAM_SPECTATOR  = 1,
    TEAM_BLU        = 2,
    TEAM_RED        = 3,
}

E_RuneType = {
    RUNETYPE_TEMP_NONE = 0,
    RUNETYPE_TEMP_CRIT = 1,
    RUNETYPE_TEMP_UBER = 2,
}

E_ProjectileType = {
    TF_PROJECTILE_NONE = 0,
    TF_PROJECTILE_BULLET = 1,
    TF_PROJECTILE_ROCKET = 2,
    TF_PROJECTILE_PIPEBOMB = 3,
    TF_PROJECTILE_PIPEBOMB_REMOTE = 4,
    TF_PROJECTILE_SYRINGE = 5,
    TF_PROJECTILE_FLARE = 6,
    TF_PROJECTILE_JAR = 7,
    TF_PROJECTILE_ARROW = 8,
    TF_PROJECTILE_FLAME_ROCKET = 9,
    TF_PROJECTILE_JAR_MILK = 10,
    TF_PROJECTILE_HEALING_BOLT = 11,
    TF_PROJECTILE_ENERGY_BALL = 12,
    TF_PROJECTILE_ENERGY_RING = 13,
    TF_PROJECTILE_PIPEBOMB_PRACTICE = 14,
    TF_PROJECTILE_CLEAVER = 15,
    TF_PROJECTILE_STICKY_BALL = 16,
    TF_PROJECTILE_CANNONBALL = 17,
    TF_PROJECTILE_BUILDING_REPAIR_BOLT = 18,
    TF_PROJECTILE_FESTIVE_ARROW = 19,
    TF_PROJECTILE_THROWABLE = 20,
    TF_PROJECTILE_SPELL = 21,
    TF_PROJECTILE_FESTIVE_JAR = 22,
    TF_PROJECTILE_FESTIVE_HEALING_BOLT = 23,
    TF_PROJECTILE_BREADMONSTER_JARATE = 24,
    TF_PROJECTILE_BREADMONSTER_MADMILK = 25,
    TF_PROJECTILE_GRAPPLINGHOOK = 26,
    TF_PROJECTILE_SENTRY_ROCKET = 27,
    TF_PROJECTILE_BREAD_MONSTER = 28,
}

E_MoveType = {
    MOVETYPE_NONE = 0,
    MOVETYPE_ISOMETRIC = 1,
    MOVETYPE_WALK = 2,
    MOVETYPE_STEP = 3,
    MOVETYPE_FLY = 4,
    MOVETYPE_FLYGRAVITY = 5,
    MOVETYPE_VPHYSICS = 6,
    MOVETYPE_PUSH = 7,
    MOVETYPE_NOCLIP = 8,
    MOVETYPE_LADDER = 9,
    MOVETYPE_OBSERVER = 10,
    MOVETYPE_CUSTOM = 11,
}

E_Hitbox = {
    HITBOX_HEAD = 0,
    HITBOX_PELVIS = 1,
    HITBOX_SPINE_0 = 2,
    HITBOX_SPINE_1 = 3,
    HITBOX_SPINE_2 = 4,
    HITBOX_SPINE_3 = 5,
    HITBOX_UPPERARM_L = 6,
    HITBOX_LOWERARM_L = 7,
    HITBOX_HAND_L = 8,
    HITBOX_UPPERARM_R = 9,
    HITBOX_LOWERARM_R = 10,
    HITBOX_HAND_R = 11,
    HITBOX_HIP_L = 12,
    HITBOX_KNEE_L = 13,
    HITBOX_FOOT_L = 14,
    HITBOX_HIP_R = 15,
    HITBOX_KNEE_R = 16,
    HITBOX_FOOT_R = 17,
}

E_BoneMask = {
    BONE_USED_BY_ANYTHING = 0x0007FF00,
    BONE_USED_BY_HITBOX = 0x00000100,
    BONE_USED_BY_ATTACHMENT = 0x00000200,
    BONE_USED_BY_VERTEX_MASK = 0x0003FC00,
    BONE_USED_BY_VERTEX_LOD0 = 0x00000400,
    BONE_USED_BY_VERTEX_LOD1 = 0x00000800,
    BONE_USED_BY_VERTEX_LOD2 = 0x00001000,
    BONE_USED_BY_VERTEX_LOD3 = 0x00002000,
    BONE_USED_BY_VERTEX_LOD4 = 0x00004000,
    BONE_USED_BY_VERTEX_LOD5 = 0x00008000,
    BONE_USED_BY_VERTEX_LOD6 = 0x00010000,
    BONE_USED_BY_VERTEX_LOD7 = 0x00020000,
    BONE_USED_BY_BONE_MERGE = 0x00040000,
}

E_GCResults = {
    k_EGCResultOK = 0,
    k_EGCResultNoMessage = 1,
    k_EGCResultBufferTooSmall = 2,
    k_EGCResultNotLoggedOn = 3,
    k_EGCResultInvalidMessage = 4,
}

E_ClearFlags = {
    VIEW_CLEAR_COLOR = 0x1,
    VIEW_CLEAR_DEPTH = 0x2,
    VIEW_CLEAR_FULL_TARGET = 0x4,
    VIEW_NO_DRAW = 0x8,
    VIEW_CLEAR_OBEY_STENCIL = 0x10,
    VIEW_CLEAR_STENCIL = 0x20,
}

E_Flows = {
    FLOW_OUTGOING = 0,
    FLOW_INCOMING = 1,
    MAX_FLOWS = 2,
}

E_ClientFrameStage = {
    FRAME_UNDEFINED = -1,
    FRAME_START = 0,
    FRAME_NET_UPDATE_START = 1,
    FRAME_NET_UPDATE_POSTDATAUPDATE_START = 2,
    FRAME_NET_UPDATE_POSTDATAUPDATE_END = 3,
    FRAME_NET_UPDATE_END = 4,
    FRAME_RENDER_START = 5,
    FRAME_RENDER_END = 6,
};

```


## Lua Globals



# Lua Globals


This page describes the Lua globals that are available.


## Functions


### print( msg:any, ... )


Prints message to console. Each argument is printed on a new line.


### printc( r:integer, g:integer, b:integer, a:integer, msg:any, ... )


Prints a colored message to console. Each argument is printed on a new line.


### LoadScript( scriptFile )


Loads a Lua script from given file.


### UnloadScript( scriptFile )


Unloads a Lua script from given file.


### GetScriptName()


Returns current script's file name.



## Entity Props



# Entity Props


Entity props and tables```
"TF2EntProps"
{
    "DT_TFWearableLevelableItem"
    {
        "m_unLevel"     "Int"
    }
    "DT_TFWearableCampaignItem"
    {
        "m_nState"      "Int"
    }
    "DT_TFBaseRocket"
    {
        "m_vInitialVelocity"        "Vector"
        "m_vecOrigin"       "Vector"
        "m_angRotation"     "Vector"
        "m_iDeflected"      "Int"
        "m_hLauncher"       "Int"
    }
    "DT_TFWeaponBaseGrenadeProj"
    {
        "m_vInitialVelocity"        "Vector"
        "m_bCritical"       "Int"
        "m_iDeflected"      "Int"
        "m_vecOrigin"       "Vector"
        "m_angRotation"     "Vector"
        "m_hDeflectOwner"       "Int"
    }
    "DT_TFWeaponBase"
    {
        "m_bLowered"        "Int"
        "m_iReloadMode"     "Int"
        "m_bResetParity"        "Int"
        "m_bReloadedThroughAnimEvent"       "Int"
        "m_bDisguiseWeapon"     "Int"
        "LocalActiveTFWeaponData"
        {
            "m_flLastCritCheckTime"     "Float"
            "m_flReloadPriorNextFire"       "Float"
            "m_flLastFireTime"      "Float"
            "m_flEffectBarRegenTime"        "Float"
            "m_flObservedCritChance"        "Float"
        }
        "NonLocalTFWeaponData"      "DataTable"
        "m_flEnergy"        "Float"
        "m_hExtraWearable"      "Int"
        "m_hExtraWearableViewModel"     "Int"
        "m_bBeingRepurposedForTaunt"        "Int"
        "m_nKillComboClass"     "Int"
        "m_nKillComboCount"     "Int"
        "m_flInspectAnimEndTime"        "Float"
        "m_nInspectStage"       "Int"
        "m_iConsecutiveShots"       "Int"
    }
    "DT_TFWeaponRobotArm"
    {
        "m_hRobotArm"       "Int"
    }
    "DT_TFWeaponThrowable"
    {
        "m_flChargeBeginTime"       "Float"
    }
    "DT_TFWeaponKatana"
    {
        "m_bIsBloody"       "Int"
    }
    "DT_SniperDot"
    {
        "m_flChargeStartTime"       "Float"
    }
    "DT_TFSniperRifleClassic"
    {
        "m_bCharging"       "Int"
    }
    "DT_TFSniperRifle"
    {
        "SniperRifleLocalData"
        {
            "m_flChargedDamage"     "Float"
        }
    }
    "DT_WeaponChargedSMG"
    {
        "m_flMinicritCharge"        "Float"
    }
    "DT_TFWeaponSlap"
    {
        "m_bFirstHit"       "Int"
        "m_nNumKills"       "Int"
    }
    "DT_TFWeaponRocketPack"
    {
        "m_flInitLaunchTime"        "Float"
        "m_flLaunchTime"        "Float"
        "m_flToggleEndTime"     "Float"
        "m_bEnabled"        "Int"
    }
    "DT_Crossbow"
    {
        "m_flRegenerateDuration"        "Float"
        "m_flLastUsedTimestamp"     "Float"
    }
    "DT_WeaponRaygun"
    {
        "m_bUseNewProjectileCode"       "Int"
    }
    "DT_WeaponPipebombLauncher"
    {
        "PipebombLauncherLocalData"
        {
            "m_iPipebombCount"      "Int"
            "m_flChargeBeginTime"       "Float"
        }
    }
    "DT_ParticleCannon"
    {
        "m_flChargeBeginTime"       "Float"
        "m_iChargeEffect"       "Int"
    }
    "DT_WeaponMinigun"
    {
        "m_iWeaponState"        "Int"
        "m_bCritShot"       "Int"
    }
    "DT_WeaponMedigun"
    {
        "m_hHealingTarget"      "Int"
        "m_bHealing"        "Int"
        "m_bAttacking"      "Int"
        "m_bChargeRelease"      "Int"
        "m_bHolstered"      "Int"
        "m_nChargeResistType"       "Int"
        "m_hLastHealingTarget"      "Int"
        "LocalTFWeaponMedigunData"
        {
            "m_flChargeLevel"       "Float"
        }
        "NonLocalTFWeaponMedigunData"
        {
            "m_flChargeLevel"       "Float"
        }
    }
    "DT_WeaponLunchBox"
    {
        "m_bBroken"     "Int"
    }
    "DT_TFWeaponKnife"
    {
        "m_bReadyToBackstab"        "Int"
        "m_bKnifeExists"        "Int"
        "m_flKnifeRegenerateDuration"       "Float"
        "m_flKnifeMeltTimestamp"        "Float"
    }
    "DT_WeaponGrenadeLauncher"
    {
        "m_flDetonateTime"      "Float"
        "m_iCurrentTube"        "Int"
        "m_iGoalTube"       "Int"
    }
    "DT_TFProjectile_Pipebomb"
    {
        "m_bTouched"        "Int"
        "m_iType"       "Int"
        "m_hLauncher"       "Int"
        "m_bDefensiveBomb"      "Int"
    }
    "DT_GrapplingHook"
    {
        "m_hProjectile"     "Int"
    }
    "DT_WeaponFlareGun_Revenge"
    {
        "m_fLastExtinguishTime"     "Float"
    }
    "DT_WeaponFlareGun"
    {
        "m_flChargeBeginTime"       "Float"
    }
    "DT_WeaponFlameThrower"
    {
        "m_iWeaponState"        "Int"
        "m_bCritFire"       "Int"
        "m_bHitTarget"      "Int"
        "m_flChargeBeginTime"       "Float"
        "LocalFlameThrowerData"
        {
            "m_iActiveFlames"       "Int"
            "m_iDamagingFlames"     "Int"
            "m_hFlameManager"       "Int"
            "m_bHasHalloweenSpell"      "Int"
        }
    }
    "DT_WeaponFlameBall"
    {
        "m_flRechargeScale"     "Float"
    }
    "DT_WeaponCompoundBow"
    {
        "m_bArrowAlight"        "Int"
        "m_bNoFire"     "Int"
    }
    "DT_TFWeaponStickBomb"
    {
        "m_iDetonated"      "Int"
    }
    "DT_TFWeaponBreakableMelee"
    {
        "m_bBroken"     "Int"
    }
    "DT_TFDroppedWeapon"
    {
        "m_Item"
        {
            "m_iItemDefinitionIndex"        "Int"
            "m_iEntityLevel"        "Int"
            "m_iItemIDHigh"     "Int"
            "m_iItemIDLow"      "Int"
            "m_iAccountID"      "Int"
            "m_iEntityQuality"      "Int"
            "m_bInitialized"        "Int"
            "m_bOnlyIterateItemViewAttributes"      "Int"
            "m_AttributeList"
            {
                "m_Attributes"
                {
                    "lengthproxy"
                    {
                        "lengthprop20"      "Int"
                    }
                }
            }
            "m_iTeamNumber"     "Int"
            "m_NetworkedDynamicAttributesForDemos"
            {
                "m_Attributes"
                {
                    "lengthproxy"
                    {
                        "lengthprop20"      "Int"
                    }
                }
            }
        }
        "m_flChargeLevel"       "Float"
    }
    "DT_TFWeaponSapper"
    {
        "m_flChargeBeginTime"       "Float"
    }
    "DT_TFWeaponBuilder"
    {
        "m_iBuildState"     "Int"
        "BuilderLocalData"
        {
            "m_iObjectType"     "Int"
            "m_hObjectBeingBuilt"       "Int"
            "m_aBuildableObjectTypes"       "DataTable"
        }
        "m_iObjectMode"     "Int"
        "m_flWheatleyTalkingUntil"      "Float"
    }
    "DT_TFWeaponBuilder"
    {
        "m_iBuildState"     "Int"
        "BuilderLocalData"
        {
            "m_iObjectType"     "Int"
            "m_hObjectBeingBuilt"       "Int"
            "m_aBuildableObjectTypes"       "DataTable"
        }
        "m_iObjectMode"     "Int"
        "m_flWheatleyTalkingUntil"      "Float"
    }
    "DT_TFProjectile_Rocket"
    {
        "m_bCritical"       "Int"
    }
    "DT_TFProjectile_Flare"
    {
        "m_bCritical"       "Int"
    }
    "DT_TFProjectile_EnergyBall"
    {
        "m_bChargedShot"        "Int"
        "m_vColor1"     "Vector"
        "m_vColor2"     "Vector"
    }
    "DT_TFProjectile_Arrow"
    {
        "m_bArrowAlight"        "Int"
        "m_bCritical"       "Int"
        "m_iProjectileType"     "Int"
    }
    "DT_MannVsMachineStats"
    {
        "m_iCurrentWaveIdx"     "Int"
        "m_iServerWaveID"       "Int"
        "m_runningTotalWaveStats"
        {
            "nCreditsDropped"       "Int"
            "nCreditsAcquired"      "Int"
            "nCreditsBonus"     "Int"
            "nPlayerDeaths"     "Int"
            "nBuyBacks"     "Int"
        }
        "m_previousWaveStats"
        {
            "nCreditsDropped"       "Int"
            "nCreditsAcquired"      "Int"
            "nCreditsBonus"     "Int"
            "nPlayerDeaths"     "Int"
            "nBuyBacks"     "Int"
        }
        "m_currentWaveStats"
        {
            "nCreditsDropped"       "Int"
            "nCreditsAcquired"      "Int"
            "nCreditsBonus"     "Int"
            "nPlayerDeaths"     "Int"
            "nBuyBacks"     "Int"
        }
        "m_iCurrencyCollectedForRespec"     "Int"
        "m_nRespecsAwardedInWave"       "Int"
    }
    "DT_TFBaseBoss"
    {
        "m_lastHealthPercentage"        "Float"
    }
    "DT_BossAlpha"
    {
        "m_isNuking"        "Int"
    }
    "DT_TFWeaponSpellBook"
    {
        "m_iSelectedSpellIndex"     "Int"
        "m_iSpellCharges"       "Int"
        "m_flTimeNextSpell"     "Float"
        "m_bFiredAttack"        "Int"
    }
    "DT_Hightower_TeleportVortex"
    {
        "m_iState"      "Int"
    }
    "DT_TeleportVortex"
    {
        "m_iState"      "Int"
    }
    "DT_Zombie"
    {
        "m_flHeadScale"     "Float"
    }
    "DT_Merasmus"
    {
        "m_bRevealed"       "Int"
        "m_bIsDoingAOEAttack"       "Int"
        "m_bStunned"        "Int"
    }
    "DT_EyeballBoss"
    {
        "m_lookAtSpot"      "Vector"
        "m_attitude"        "Int"
    }
    "DT_TFBotHintEngineerNest"
    {
        "m_bHasActiveTeleporter"        "Int"
    }
    "DT_BotNPCMinion"
    {
        "m_stunTarget"      "Int"
    }
    "DT_BotNPC"
    {
        "m_laserTarget"     "Int"
        "m_isNuking"        "Int"
    }
    "DT_PasstimeGun"
    {
        "m_eThrowState"     "Int"
        "m_fChargeBeginTime"        "Float"
    }
    "DT_TFRobotDestruction_Robot"
    {
        "m_iHealth"     "Int"
        "m_iMaxHealth"      "Int"
        "m_eType"       "Int"
    }
    "DT_TFReviveMarker"
    {
        "m_hOwner"      "Int"
        "m_iHealth"     "Int"
        "m_iMaxHealth"      "Int"
        "m_nRevives"        "Int"
    }
    "DT_TFProjectile_BallOfFire"
    {
        "m_vecInitialVelocity"      "Vector"
        "m_vecSpawnOrigin"      "Vector"
    }
    "DT_TFBaseProjectile"
    {
        "m_vInitialVelocity"        "Vector"
        "m_hLauncher"       "Int"
    }
    "DT_TFPointManager"
    {
        "m_nRandomSeed"     "Int"
        "m_unNextPointIndex"        "Int"
        "m_nSpawnTime"      "DataTable"
    }
    "DT_TFRobotDestructionLogic"
    {
        "m_nMaxPoints"      "Int"
        "m_nBlueScore"      "Int"
        "m_nRedScore"       "Int"
        "m_nBlueTargetPoints"       "Int"
        "m_nRedTargetPoints"        "Int"
        "m_flBlueTeamRespawnScale"      "Float"
        "m_flRedTeamRespawnScale"       "Float"
        "m_flBlueFinaleEndTime"     "Float"
        "m_flRedFinaleEndTime"      "Float"
        "m_flFinaleLength"      "Float"
        "m_szResFile"       "String"
        "m_eWinningMethod"      "DataTable"
        "m_flCountdownEndTime"      "Float"
    }
    "DT_TFRobotDestruction_RobotGroup"
    {
        "m_pszHudIcon"      "String"
        "m_iTeamNum"        "Int"
        "m_nGroupNumber"        "Int"
        "m_nState"      "Int"
        "m_flRespawnStartTime"      "Float"
        "m_flRespawnEndTime"        "Float"
        "m_flLastAttackedTime"      "Float"
    }
    "DT_TFPlayerDestructionLogic"
    {
        "m_hRedTeamLeader"      "Int"
        "m_hBlueTeamLeader"     "Int"
        "m_iszCountdownImage"       "String"
        "m_bUsingCountdownImage"        "Int"
    }
    "DT_TFMinigameLogic"
    {
        "m_hActiveMinigame"     "Int"
    }
    "DT_TFMinigame"
    {
        "m_nMinigameTeamScore"      "DataTable"
        "m_nMaxScoreForMiniGame"        "Int"
        "m_pszHudResFile"       "String"
        "m_eScoringType"        "Int"
    }
    "DT_TFPowerupBottle"
    {
        "m_bActive"     "Int"
        "m_usNumCharges"        "Int"
    }
    "DT_HalloweenSoulPack"
    {
        "m_hTarget"     "Int"
        "m_vecPreCurvePos"      "Vector"
        "m_vecStartCurvePos"        "Vector"
        "m_flDuration"      "Float"
    }
    "DT_BonusRoundLogic"
    {
        "m_aBonusPlayerRoll"
        {
            "lengthproxy"
            {
                "lengthprop101"     "Int"
            }
        }
        "m_hBonusWinner"        "Int"
        "m_Item"
        {
            "m_iItemDefinitionIndex"        "Int"
            "m_iEntityLevel"        "Int"
            "m_iItemIDHigh"     "Int"
            "m_iItemIDLow"      "Int"
            "m_iAccountID"      "Int"
            "m_iEntityQuality"      "Int"
            "m_bInitialized"        "Int"
            "m_bOnlyIterateItemViewAttributes"      "Int"
            "m_AttributeList"
            {
                "m_Attributes"
                {
                    "lengthproxy"
                    {
                        "lengthprop20"      "Int"
                    }
                }
            }
            "m_iTeamNumber"     "Int"
            "m_NetworkedDynamicAttributesForDemos"
            {
                "m_Attributes"
                {
                    "lengthproxy"
                    {
                        "lengthprop20"      "Int"
                    }
                }
            }
        }
    }
    "DT_TFGameRulesProxy"
    {
        "tf_gamerules_data"
        {
            "m_nGameType"       "Int"
            "m_nStopWatchState"     "Int"
            "m_pszTeamGoalStringRed"        "String"
            "m_pszTeamGoalStringBlue"       "String"
            "m_flCapturePointEnableTime"        "Float"
            "m_nHudType"        "Int"
            "m_bIsInTraining"       "Int"
            "m_bAllowTrainingAchievements"      "Int"
            "m_bIsWaitingForTrainingContinue"       "Int"
            "m_bIsTrainingHUDVisible"       "Int"
            "m_bIsInItemTestingMode"        "Int"
            "m_hBonusLogic"     "Int"
            "m_bPlayingKoth"        "Int"
            "m_bPlayingMedieval"        "Int"
            "m_bPlayingHybrid_CTF_CP"       "Int"
            "m_bPlayingSpecialDeliveryMode"     "Int"
            "m_bPlayingRobotDestructionMode"        "Int"
            "m_hRedKothTimer"       "Int"
            "m_hBlueKothTimer"      "Int"
            "m_nMapHolidayType"     "Int"
            "m_itHandle"        "Int"
            "m_bPlayingMannVsMachine"       "Int"
            "m_hBirthdayPlayer"     "Int"
            "m_nBossHealth"     "Int"
            "m_nMaxBossHealth"      "Int"
            "m_fBossNormalizedTravelDistance"       "Int"
            "m_bMannVsMachineAlarmStatus"       "Int"
            "m_bHaveMinPlayersToEnableReady"        "Int"
            "m_bBountyModeEnabled"      "Int"
            "m_nHalloweenEffect"        "Int"
            "m_fHalloweenEffectStartTime"       "Float"
            "m_fHalloweenEffectDuration"        "Float"
            "m_halloweenScenario"       "Int"
            "m_bHelltowerPlayersInHell"     "Int"
            "m_bIsUsingSpells"      "Int"
            "m_bCompetitiveMode"        "Int"
            "m_nMatchGroupType"     "Int"
            "m_bMatchEnded"     "Int"
            "m_bPowerupMode"        "Int"
            "m_pszCustomUpgradesFile"       "String"
            "m_bTruceActive"        "Int"
            "m_bShowMatchSummary"       "Int"
            "\"m_bShowCompetitiveMatchSummary\""        "Int"
            "m_bTeamsSwitched"      "Int"
            "m_bMapHasMatchSummaryStage"        "Int"
            "m_bPlayersAreOnMatchSummaryStage"      "Int"
            "m_bStopWatchWinner"        "Int"
            "m_ePlayerWantsRematch"     "DataTable"
            "m_eRematchState"       "Int"
            "m_nNextMapVoteOptions"     "DataTable"
            "m_nForceUpgrades"      "Int"
            "m_nForceEscortPushLogic"       "Int"
            "m_bRopesHolidayLightsAllowed"      "Int"
        }
    }
    "DT_TETFParticleEffect"
    {
        "m_vecOrigin[0]"        "Float"
        "m_vecOrigin[1]"        "Float"
        "m_vecOrigin[2]"        "Float"
        "m_vecStart[0]"     "Float"
        "m_vecStart[1]"     "Float"
        "m_vecStart[2]"     "Float"
        "m_vecAngles"       "Vector"
        "m_iParticleSystemIndex"        "Int"
        "entindex"      "Int"
        "m_iAttachType"     "Int"
        "m_iAttachmentPointIndex"       "Int"
        "m_bResetParticles"     "Int"
        "m_bCustomColors"       "Int"
        "m_CustomColors.m_vecColor1"        "Vector"
        "m_CustomColors.m_vecColor2"        "Vector"
        "m_bControlPoint1"      "Int"
        "m_ControlPoint1.m_eParticleAttachment"     "Int"
        "m_ControlPoint1.m_vecOffset[0]"        "Float"
        "m_ControlPoint1.m_vecOffset[1]"        "Float"
        "m_ControlPoint1.m_vecOffset[2]"        "Float"
    }
    "DT_TETFExplosion"
    {
        "m_vecOrigin[0]"        "Float"
        "m_vecOrigin[1]"        "Float"
        "m_vecOrigin[2]"        "Float"
        "m_vecNormal"       "Vector"
        "m_iWeaponID"       "Int"
        "entindex"      "Int"
        "m_nDefID"      "Int"
        "m_nSound"      "Int"
        "m_iCustomParticleIndex"        "Int"
    }
    "DT_TETFBlood"
    {
        "m_vecOrigin[0]"        "Float"
        "m_vecOrigin[1]"        "Float"
        "m_vecOrigin[2]"        "Float"
        "m_vecNormal"       "Vector"
        "entindex"      "Int"
    }
    "DT_TFFlameManager"
    {
        "m_hWeapon"     "Int"
        "m_hAttacker"       "Int"
        "m_flSpreadDegree"      "Float"
        "m_flRedirectedFlameSizeMult"       "Float"
        "m_flFlameStartSizeMult"        "Float"
        "m_flFlameEndSizeMult"      "Float"
        "m_flFlameIgnorePlayerVelocity"     "Float"
        "m_flFlameReflectionAdditionalLifeTime"     "Float"
        "m_flFlameReflectionDamageReduction"        "Float"
        "m_iMaxFlameReflectionCount"        "Int"
        "m_nShouldReflect"      "Int"
        "m_flFlameSpeed"        "Float"
        "m_flFlameLifeTime"     "Float"
        "m_flRandomLifeTimeOffset"      "Float"
        "m_flFlameGravity"      "Float"
        "m_flFlameDrag"     "Float"
        "m_flFlameUp"       "Float"
        "m_bIsFiring"       "Int"
    }
    "DT_CHalloweenGiftPickup"
    {
        "m_hTargetPlayer"       "Int"
    }
    "DT_CBonusDuckPickup"
    {
        "m_bSpecial"        "Int"
    }
    "DT_CaptureFlag"
    {
        "m_bDisabled"       "Int"
        "m_bVisibleWhenDisabled"        "Int"
        "m_nType"       "Int"
        "m_nFlagStatus"     "Int"
        "m_flResetTime"     "Float"
        "m_flNeutralTime"       "Float"
        "m_flMaxResetTime"      "Float"
        "m_hPrevOwner"      "Int"
        "m_szModel"     "String"
        "m_szHudIcon"       "String"
        "m_szPaperEffect"       "String"
        "m_szTrailEffect"       "String"
        "m_nUseTrailEffect"     "Int"
        "m_nPointValue"     "Int"
        "m_flAutoCapTime"       "Float"
        "m_bGlowEnabled"        "Int"
        "m_flTimeToSetPoisonous"        "Float"
    }
    "DT_TFTeam"
    {
        "m_nFlagCaptures"       "Int"
        "m_iRole"       "Int"
        "team_object_array_element"     "Int"
        "\"team_object_array\""     "Array"
        "m_hLeader"     "Int"
    }
    "DT_TFPlayerResource"
    {
        "m_iTotalScore"     "DataTable"
        "m_iMaxHealth"      "DataTable"
        "m_iMaxBuffedHealth"        "DataTable"
        "m_iPlayerClass"        "DataTable"
        "m_bArenaSpectator"     "DataTable"
        "m_iActiveDominations"      "DataTable"
        "m_flNextRespawnTime"       "DataTable"
        "m_iChargeLevel"        "DataTable"
        "m_iDamage"     "DataTable"
        "m_iDamageAssist"       "DataTable"
        "m_iDamageBoss"     "DataTable"
        "m_iHealing"        "DataTable"
        "m_iHealingAssist"      "DataTable"
        "m_iDamageBlocked"      "DataTable"
        "m_iCurrencyCollected"      "DataTable"
        "m_iBonusPoints"        "DataTable"
        "m_iPlayerLevel"        "DataTable"
        "m_iStreaks"        "DataTable"
        "m_iUpgradeRefundCredits"       "DataTable"
        "m_iBuybackCredits"     "DataTable"
        "m_iPartyLeaderRedTeamIndex"        "Int"
        "m_iPartyLeaderBlueTeamIndex"       "Int"
        "m_iEventTeamStatus"        "Int"
        "m_iPlayerClassWhenKilled"      "DataTable"
        "m_iConnectionState"        "DataTable"
        "m_flConnectTime"       "DataTable"
    }
    "DT_TFPlayer"
    {
        "m_bSaveMeParity"       "Int"
        "m_bIsMiniBoss"     "Int"
        "m_bIsABot"     "Int"
        "m_nBotSkill"       "Int"
        "m_nWaterLevel"     "Int"
        "m_hRagdoll"        "Int"
        "m_PlayerClass"
        {
            "m_iClass"      "Int"
            "m_iszClassIcon"        "String"
            "m_iszCustomModel"      "String"
            "m_vecCustomModelOffset"        "Vector"
            "m_angCustomModelRotation"      "Vector"
            "m_bCustomModelRotates"     "Int"
            "m_bCustomModelRotationSet"     "Int"
            "m_bCustomModelVisibleToSelf"       "Int"
            "m_bUseClassAnimations"     "Int"
            "m_iClassModelParity"       "Int"
        }
        "m_Shared"
        {
            "m_nPlayerCond"     "Int"
            "m_bJumping"        "Int"
            "m_nNumHealers"     "Int"
            "m_iCritMult"       "Int"
            "m_iAirDash"        "Int"
            "m_nAirDucked"      "Int"
            "m_flDuckTimer"     "Float"
            "m_nPlayerState"        "Int"
            "m_iDesiredPlayerClass"     "Int"
            "m_flMovementStunTime"      "Float"
            "m_iMovementStunAmount"     "Int"
            "m_iMovementStunParity"     "Int"
            "m_hStunner"        "Int"
            "m_iStunFlags"      "Int"
            "m_nArenaNumChanges"        "Int"
            "m_bArenaFirstBloodBoost"       "Int"
            "m_iWeaponKnockbackID"      "Int"
            "m_bLoadoutUnavailable"     "Int"
            "m_iItemFindBonus"      "Int"
            "m_bShieldEquipped"     "Int"
            "m_bParachuteEquipped"      "Int"
            "m_iNextMeleeCrit"      "Int"
            "m_iDecapitations"      "Int"
            "m_iRevengeCrits"       "Int"
            "m_iDisguiseBody"       "Int"
            "m_hCarriedObject"      "Int"
            "m_bCarryingObject"     "Int"
            "m_flNextNoiseMakerTime"        "Float"
            "m_iSpawnRoomTouchCount"        "Int"
            "m_iKillCountSinceLastDeploy"       "Int"
            "m_flFirstPrimaryAttack"        "Float"
            "m_flEnergyDrinkMeter"      "Float"
            "m_flHypeMeter"     "Float"
            "m_flChargeMeter"       "Float"
            "m_flInvisChangeCompleteTime"       "Float"
            "m_nDisguiseTeam"       "Int"
            "m_nDisguiseClass"      "Int"
            "m_nDisguiseSkinOverride"       "Int"
            "m_nMaskClass"      "Int"
            "m_hDisguiseTarget"     "Int"
            "m_iDisguiseHealth"     "Int"
            "m_bFeignDeathReady"        "Int"
            "m_hDisguiseWeapon"     "Int"
            "m_nTeamTeleporterUsed"     "Int"
            "m_flCloakMeter"        "Float"
            "m_flSpyTranqBuffDuration"      "Float"
            "tfsharedlocaldata"
            {
                "m_nDesiredDisguiseTeam"        "Int"
                "m_nDesiredDisguiseClass"       "Int"
                "m_flStealthNoAttackExpire"     "Float"
                "m_flStealthNextChangeTime"     "Float"
                "m_bLastDisguisedAsOwnTeam"     "Int"
                "m_flRageMeter"     "Float"
                "m_bRageDraining"       "Int"
                "m_flNextRageEarnTime"      "Float"
                "m_bInUpgradeZone"      "Int"
                "m_flItemChargeMeter"       "DataTable"
                "m_bPlayerDominated"        "DataTable"
                "m_bPlayerDominatingMe"     "DataTable"
                "m_ScoreData"
                {
                    "m_iCaptures"       "Int"
                    "m_iDefenses"       "Int"
                    "m_iKills"      "Int"
                    "m_iDeaths"     "Int"
                    "m_iSuicides"       "Int"
                    "m_iDominations"        "Int"
                    "m_iRevenge"        "Int"
                    "m_iBuildingsBuilt"     "Int"
                    "m_iBuildingsDestroyed"     "Int"
                    "m_iHeadshots"      "Int"
                    "m_iBackstabs"      "Int"
                    "m_iHealPoints"     "Int"
                    "m_iInvulns"        "Int"
                    "m_iTeleports"      "Int"
                    "m_iResupplyPoints"     "Int"
                    "m_iKillAssists"        "Int"
                    "m_iPoints"     "Int"
                    "m_iBonusPoints"        "Int"
                    "m_iDamageDone"     "Int"
                    "m_iCrits"      "Int"
                }
                "m_RoundScoreData"
                {
                    "m_iCaptures"       "Int"
                    "m_iDefenses"       "Int"
                    "m_iKills"      "Int"
                    "m_iDeaths"     "Int"
                    "m_iSuicides"       "Int"
                    "m_iDominations"        "Int"
                    "m_iRevenge"        "Int"
                    "m_iBuildingsBuilt"     "Int"
                    "m_iBuildingsDestroyed"     "Int"
                    "m_iHeadshots"      "Int"
                    "m_iBackstabs"      "Int"
                    "m_iHealPoints"     "Int"
                    "m_iInvulns"        "Int"
                    "m_iTeleports"      "Int"
                    "m_iResupplyPoints"     "Int"
                    "m_iKillAssists"        "Int"
                    "m_iPoints"     "Int"
                    "m_iBonusPoints"        "Int"
                    "m_iDamageDone"     "Int"
                    "m_iCrits"      "Int"
                }
            }
            "m_ConditionList"
            {
                "_condition_bits"       "Int"
            }
            "m_iTauntIndex"     "Int"
            "m_iTauntConcept"       "Int"
            "m_nPlayerCondEx"       "Int"
            "m_iStunIndex"      "Int"
            "m_nHalloweenBombHeadStage"     "Int"
            "m_nPlayerCondEx2"      "Int"
            "m_nPlayerCondEx3"      "Int"
            "m_nStreaks"        "DataTable"
            "m_unTauntSourceItemID_Low"     "Int"
            "m_unTauntSourceItemID_High"        "Int"
            "m_flRuneCharge"        "Float"
            "m_bHasPasstimeBall"        "Int"
            "m_bIsTargetedForPasstimePass"      "Int"
            "m_hPasstimePassTarget"     "Int"
            "m_askForBallTime"      "Float"
            "m_bKingRuneBuffActive"     "Int"
            "m_ConditionData"
            {
                "lengthproxy"
                {
                    "lengthprop131"     "Int"
                }
            }
            "m_nPlayerCondEx4"      "Int"
            "m_flHolsterAnimTime"       "Float"
            "m_hSwitchTo"       "Int"
        }
        "m_hItem"       "Int"
        "tflocaldata"
        {
            "m_vecOrigin"       "VectorXY"
            "m_vecOrigin[2]"        "Float"
            "player_object_array_element"       "Int"
            "\"player_object_array\""       "Array"
            "m_angEyeAngles[0]"     "Float"
            "m_angEyeAngles[1]"     "Float"
            "m_bIsCoaching"     "Int"
            "m_hCoach"      "Int"
            "m_hStudent"        "Int"
            "m_nCurrency"       "Int"
            "m_nExperienceLevel"        "Int"
            "m_nExperienceLevelProgress"        "Int"
            "m_bMatchSafeToLeave"       "Int"
        }
        "tfnonlocaldata"
        {
            "m_vecOrigin"       "VectorXY"
            "m_vecOrigin[2]"        "Float"
            "m_angEyeAngles[0]"     "Float"
            "m_angEyeAngles[1]"     "Float"
        }
        "m_bAllowMoveDuringTaunt"       "Int"
        "m_bIsReadyToHighFive"      "Int"
        "m_hHighFivePartner"        "Int"
        "m_nForceTauntCam"      "Int"
        "m_flTauntYaw"      "Float"
        "m_nActiveTauntSlot"        "Int"
        "m_iTauntItemDefIndex"      "Int"
        "m_flCurrentTauntMoveSpeed"     "Float"
        "m_flVehicleReverseTime"        "Float"
        "m_flMvMLastDamageTime"     "Float"
        "\"m_flLastDamageTime\""        "Float"
        "m_bInPowerPlay"        "Int"
        "m_iSpawnCounter"       "Int"
        "m_bArenaSpectator"     "Int"
        "m_AttributeManager"
        {
            "m_hOuter"      "Int"
            "m_ProviderType"        "Int"
            "m_iReapplyProvisionParity"     "Int"
        }
        "m_flHeadScale"     "Float"
        "m_flTorsoScale"        "Float"
        "m_flHandScale"     "Float"
        "m_bUseBossHealthBar"       "Int"
        "m_bUsingVRHeadset"     "Int"
        "m_bForcedSkin"     "Int"
        "m_nForcedSkin"     "Int"
        "m_bGlowEnabled"        "Int"
        "TFSendHealersDataTable"
        {
            "m_nActiveWpnClip"      "Int"
        }
        "m_flKartNextAvailableBoost"        "Float"
        "m_iKartHealth"     "Int"
        "m_iKartState"      "Int"
        "m_hGrapplingHookTarget"        "Int"
        "m_hSecondaryLastWeapon"        "Int"
        "m_bUsingActionSlot"        "Int"
        "m_flInspectTime"       "Float"
        "m_flHelpmeButtonPressTime"     "Float"
        "m_iCampaignMedals"     "Int"
        "m_iPlayerSkinOverride"     "Int"
        "m_bViewingCYOAPDA"     "Int"
        "m_bRegenerating"       "Int"
    }
    "DT_TFRagdoll"
    {
        "m_vecRagdollOrigin"        "Vector"
        "m_hPlayer"     "Int"
        "m_vecForce"        "Vector"
        "m_vecRagdollVelocity"      "Vector"
        "m_nForceBone"      "Int"
        "m_bGib"        "Int"
        "m_bBurning"        "Int"
        "m_bElectrocuted"       "Int"
        "m_bFeignDeath"     "Int"
        "m_bWasDisguised"       "Int"
        "m_bOnGround"       "Int"
        "m_bCloaked"        "Int"
        "m_bBecomeAsh"      "Int"
        "m_iDamageCustom"       "Int"
        "m_iTeam"       "Int"
        "m_iClass"      "Int"
        "m_hRagWearables"
        {
            "lengthproxy"
            {
                "lengthprop8"       "Int"
            }
        }
        "m_bGoldRagdoll"        "Int"
        "m_bIceRagdoll"     "Int"
        "m_bCritOnHardHit"      "Int"
        "m_flHeadScale"     "Float"
        "m_flTorsoScale"        "Float"
        "m_flHandScale"     "Float"
    }
    "DT_TEPlayerAnimEvent"
    {
        "m_hPlayer"     "Int"
        "m_iEvent"      "Int"
        "m_nData"       "Int"
    }
    "DT_TFPasstimeLogic"
    {
        "m_hBall"       "Int"
        "m_trackPoints[0]"      "Vector"
        "m_trackPoints"     "Array"
        "m_iNumSections"        "Int"
        "m_iCurrentSection"     "Int"
        "m_flMaxPassRange"      "Float"
        "m_iBallPower"      "Int"
        "m_flPackSpeed"     "Float"
        "m_bPlayerIsPackMember"     "DataTable"
    }
    "DT_PasstimeBall"
    {
        "m_iCollisionCount"     "Int"
        "m_hHomingTarget"       "Int"
        "m_hCarrier"        "Int"
        "m_hPrevCarrier"        "Int"
    }
    "DT_TFObjectiveResource"
    {
        "m_nMannVsMachineMaxWaveCount"      "Int"
        "m_nMannVsMachineWaveCount"     "Int"
        "m_nMannVsMachineWaveEnemyCount"        "Int"
        "m_nMvMWorldMoney"      "Int"
        "m_flMannVsMachineNextWaveTime"     "Float"
        "m_bMannVsMachineBetweenWaves"      "Int"
        "m_nFlagCarrierUpgradeLevel"        "Int"
        "m_flMvMBaseBombUpgradeTime"        "Float"
        "m_flMvMNextBombUpgradeTime"        "Float"
        "m_iszMvMPopfileName"       "String"
        "m_iChallengeIndex"     "Int"
        "m_nMvMEventPopfileType"        "Int"
        "m_nMannVsMachineWaveClassCounts"       "DataTable"
        "m_iszMannVsMachineWaveClassNames[0]"       "String"
        "m_iszMannVsMachineWaveClassNames"      "Array"
        "m_nMannVsMachineWaveClassFlags"        "DataTable"
        "m_nMannVsMachineWaveClassCounts2"      "DataTable"
        "m_iszMannVsMachineWaveClassNames2[0]"      "String"
        "m_iszMannVsMachineWaveClassNames2"     "Array"
        "m_nMannVsMachineWaveClassFlags2"       "DataTable"
        "m_bMannVsMachineWaveClassActive"       "DataTable"
        "m_bMannVsMachineWaveClassActive2"      "DataTable"
    }
    "DT_TFGlow"
    {
        "m_iMode"       "Int"
        "m_glowColor"       "Int"
        "m_bDisabled"       "Int"
        "m_hTarget"     "Int"
    }
    "DT_TEFireBullets"
    {
        "m_vecOrigin"       "Vector"
        "m_vecAngles[0]"        "Float"
        "m_vecAngles[1]"        "Float"
        "m_iWeaponID"       "Int"
        "m_iMode"       "Int"
        "m_iSeed"       "Int"
        "m_iPlayer"     "Int"
        "m_flSpread"        "Float"
        "m_bCritical"       "Int"
    }
    "DT_AmmoPack"
    {
        "m_vecInitialVelocity"      "Vector"
        "m_angRotation[0]"      "Float"
        "m_angRotation[1]"      "Float"
        "m_angRotation[2]"      "Float"
    }
    "DT_ObjectTeleporter"
    {
        "m_iState"      "Int"
        "m_flRechargeTime"      "Float"
        "m_flCurrentRechargeDuration"       "Float"
        "m_iTimesUsed"      "Int"
        "m_flYawToExit"     "Float"
        "m_bMatchBuilding"      "Int"
    }
    "DT_ObjectSentrygun"
    {
        "m_iAmmoShells"     "Int"
        "m_iAmmoRockets"        "Int"
        "m_iState"      "Int"
        "m_bPlayerControlled"       "Int"
        "m_nShieldLevel"        "Int"
        "m_bShielded"       "Int"
        "m_hEnemy"      "Int"
        "m_hAutoAimTarget"      "Int"
        "SentrygunLocalData"
        {
            "m_iKills"      "Int"
            "m_iAssists"        "Int"
        }
    }
    "DT_ObjectDispenser"
    {
        "m_iState"      "Int"
        "m_iAmmoMetal"      "Int"
        "m_iMiniBombCounter"        "Int"
        "healing_array_element"     "Int"
        "\"healing_array\""     "Array"
    }
    "DT_MonsterResource"
    {
        "m_iBossHealthPercentageByte"       "Int"
        "m_iBossStunPercentageByte"     "Int"
        "m_iSkillShotCompleteCount"     "Int"
        "m_fSkillShotComboEndTime"      "Float"
        "m_iBossState"      "Int"
    }
    "DT_FuncPasstimeGoal"
    {
        "m_bTriggerDisabled"        "Int"
        "m_iGoalType"       "Int"
    }
    "DT_CaptureZone"
    {
        "m_bDisabled"       "Int"
    }
    "DT_CurrencyPack"
    {
        "m_bDistributed"        "Int"
    }
    "DT_BaseObject"
    {
        "m_iHealth"     "Int"
        "m_iMaxHealth"      "Int"
        "m_bHasSapper"      "Int"
        "m_iObjectType"     "Int"
        "m_bBuilding"       "Int"
        "m_bPlacing"        "Int"
        "m_bCarried"        "Int"
        "m_bCarryDeploy"        "Int"
        "m_bMiniBuilding"       "Int"
        "m_flPercentageConstructed"     "Float"
        "m_fObjectFlags"        "Int"
        "m_hBuiltOnEntity"      "Int"
        "m_bDisabled"       "Int"
        "m_hBuilder"        "Int"
        "m_vecBuildMaxs"        "Vector"
        "m_vecBuildMins"        "Vector"
        "m_iDesiredBuildRotations"      "Int"
        "m_bServerOverridePlacement"        "Int"
        "m_iUpgradeLevel"       "Int"
        "m_iUpgradeMetal"       "Int"
        "m_iUpgradeMetalRequired"       "Int"
        "m_iHighestUpgradeLevel"        "Int"
        "m_iObjectMode"     "Int"
        "m_bDisposableBuilding"     "Int"
        "m_bWasMapPlaced"       "Int"
        "m_bPlasmaDisable"      "Int"
    }
    "DT_TestTraceline"
    {
        "m_clrRender"       "Int"
        "m_vecOrigin"       "Vector"
        "m_angRotation[0]"      "Float"
        "m_angRotation[1]"      "Float"
        "m_angRotation[2]"      "Float"
        "moveparent"        "Int"
    }
    "DT_TEWorldDecal"
    {
        "m_vecOrigin"       "Vector"
        "m_nIndex"      "Int"
    }
    "DT_TESpriteSpray"
    {
        "m_vecOrigin"       "Vector"
        "m_vecDirection"        "Vector"
        "m_nModelIndex"     "Int"
        "m_fNoise"      "Float"
        "m_nCount"      "Int"
        "m_nSpeed"      "Int"
    }
    "DT_TESprite"
    {
        "m_vecOrigin"       "Vector"
        "m_nModelIndex"     "Int"
        "m_fScale"      "Float"
        "m_nBrightness"     "Int"
    }
    "DT_TESparks"
    {
        "m_nMagnitude"      "Int"
        "m_nTrailLength"        "Int"
        "m_vecDir"      "Vector"
    }
    "DT_TESmoke"
    {
        "m_vecOrigin"       "Vector"
        "m_nModelIndex"     "Int"
        "m_fScale"      "Float"
        "m_nFrameRate"      "Int"
    }
    "DT_TEShowLine"
    {
        "m_vecEnd"      "Vector"
    }
    "DT_TEProjectedDecal"
    {
        "m_vecOrigin"       "Vector"
        "m_angRotation"     "Vector"
        "m_flDistance"      "Float"
        "m_nIndex"      "Int"
    }
    "DT_TEPlayerDecal"
    {
        "m_vecOrigin"       "Vector"
        "m_nEntity"     "Int"
        "m_nPlayer"     "Int"
    }
    "DT_TEPhysicsProp"
    {
        "m_vecOrigin"       "Vector"
        "m_angRotation[0]"      "Float"
        "m_angRotation[1]"      "Float"
        "m_angRotation[2]"      "Float"
        "m_vecVelocity"     "Vector"
        "m_nModelIndex"     "Int"
        "m_nFlags"      "Int"
        "m_nSkin"       "Int"
        "m_nEffects"        "Int"
    }
    "DT_TEParticleSystem"
    {
        "m_vecOrigin[0]"        "Float"
        "m_vecOrigin[1]"        "Float"
        "m_vecOrigin[2]"        "Float"
    }
    "DT_TEMuzzleFlash"
    {
        "m_vecOrigin"       "Vector"
        "m_vecAngles"       "Vector"
        "m_flScale"     "Float"
        "m_nType"       "Int"
    }
    "DT_TELargeFunnel"
    {
        "m_nModelIndex"     "Int"
        "m_nReversed"       "Int"
    }
    "DT_TEKillPlayerAttachments"
    {
        "m_nPlayer"     "Int"
    }
    "DT_TEImpact"
    {
        "m_vecOrigin"       "Vector"
        "m_vecNormal"       "Vector"
        "m_iType"       "Int"
        "m_ucFlags"     "Int"
    }
    "DT_TEGlowSprite"
    {
        "m_vecOrigin"       "Vector"
        "m_nModelIndex"     "Int"
        "m_fScale"      "Float"
        "m_fLife"       "Float"
        "m_nBrightness"     "Int"
    }
    "DT_TEShatterSurface"
    {
        "m_vecOrigin"       "Vector"
        "m_vecAngles"       "Vector"
        "m_vecForce"        "Vector"
        "m_vecForcePos"     "Vector"
        "m_flWidth"     "Float"
        "m_flHeight"        "Float"
        "m_flShardSize"     "Float"
        "m_nSurfaceType"        "Int"
        "m_uchFrontColor[0]"        "Int"
        "m_uchFrontColor[1]"        "Int"
        "m_uchFrontColor[2]"        "Int"
        "m_uchBackColor[0]"     "Int"
        "m_uchBackColor[1]"     "Int"
        "m_uchBackColor[2]"     "Int"
    }
    "DT_TEFootprintDecal"
    {
        "m_vecOrigin"       "Vector"
        "m_vecDirection"        "Vector"
        "m_nEntity"     "Int"
        "m_nIndex"      "Int"
        "m_chMaterialType"      "Int"
    }
    "DT_TEFizz"
    {
        "m_nEntity"     "Int"
        "m_nModelIndex"     "Int"
        "m_nDensity"        "Int"
        "m_nCurrent"        "Int"
    }
    "DT_TEExplosion"
    {
        "m_nModelIndex"     "Int"
        "m_fScale"      "Float"
        "m_nFrameRate"      "Int"
        "m_nFlags"      "Int"
        "m_vecNormal"       "Vector"
        "m_chMaterialType"      "Int"
        "m_nRadius"     "Int"
        "m_nMagnitude"      "Int"
    }
    "DT_TEEnergySplash"
    {
        "m_vecPos"      "Vector"
        "m_vecDir"      "Vector"
        "m_bExplosive"      "Int"
    }
    "DT_TEEffectDispatch"
    {
        "m_EffectData"
        {
            "m_vOrigin[0]"      "Float"
            "m_vOrigin[1]"      "Float"
            "m_vOrigin[2]"      "Float"
            "m_vStart[0]"       "Float"
            "m_vStart[1]"       "Float"
            "m_vStart[2]"       "Float"
            "m_vAngles"     "Vector"
            "m_vNormal"     "Vector"
            "m_fFlags"      "Int"
            "m_flMagnitude"     "Float"
            "m_flScale"     "Float"
            "m_nAttachmentIndex"        "Int"
            "m_nSurfaceProp"        "Int"
            "m_iEffectName"     "Int"
            "m_nMaterial"       "Int"
            "m_nDamageType"     "Int"
            "m_nHitBox"     "Int"
            "entindex"      "Int"
            "m_nColor"      "Int"
            "m_flRadius"        "Float"
            "m_bCustomColors"       "Int"
            "m_CustomColors.m_vecColor1"        "Vector"
            "m_CustomColors.m_vecColor2"        "Vector"
            "m_bControlPoint1"      "Int"
            "m_ControlPoint1.m_eParticleAttachment"     "Int"
            "m_ControlPoint1.m_vecOffset[0]"        "Float"
            "m_ControlPoint1.m_vecOffset[1]"        "Float"
            "m_ControlPoint1.m_vecOffset[2]"        "Float"
        }
    }
    "DT_TEDynamicLight"
    {
        "m_vecOrigin"       "Vector"
        "r"     "Int"
        "g"     "Int"
        "B"     "Int"
        "exponent"      "Int"
        "m_fRadius"     "Float"
        "m_fTime"       "Float"
        "m_fDecay"      "Float"
    }
    "DT_TEDecal"
    {
        "m_vecOrigin"       "Vector"
        "m_vecStart"        "Vector"
        "m_nEntity"     "Int"
        "m_nHitBox"     "Int"
        "m_nIndex"      "Int"
    }
    "DT_TEClientProjectile"
    {
        "m_vecOrigin"       "Vector"
        "m_vecVelocity"     "Vector"
        "m_nModelIndex"     "Int"
        "m_nLifeTime"       "Int"
        "m_hOwner"      "Int"
    }
    "DT_TEBubbleTrail"
    {
        "m_vecMins"     "Vector"
        "m_vecMaxs"     "Vector"
        "m_nModelIndex"     "Int"
        "m_flWaterZ"        "Float"
        "m_nCount"      "Int"
        "m_fSpeed"      "Float"
    }
    "DT_TEBubbles"
    {
        "m_vecMins"     "Vector"
        "m_vecMaxs"     "Vector"
        "m_nModelIndex"     "Int"
        "m_fHeight"     "Float"
        "m_nCount"      "Int"
        "m_fSpeed"      "Float"
    }
    "DT_TEBSPDecal"
    {
        "m_vecOrigin"       "Vector"
        "m_nEntity"     "Int"
        "m_nIndex"      "Int"
    }
    "DT_TEBreakModel"
    {
        "m_vecOrigin"       "Vector"
        "m_angRotation[0]"      "Float"
        "m_angRotation[1]"      "Float"
        "m_angRotation[2]"      "Float"
        "m_vecSize"     "Vector"
        "m_vecVelocity"     "Vector"
        "m_nModelIndex"     "Int"
        "m_nRandomization"      "Int"
        "m_nCount"      "Int"
        "m_fTime"       "Float"
        "m_nFlags"      "Int"
    }
    "DT_TEBloodStream"
    {
        "m_vecDirection"        "Vector"
        "r"     "Int"
        "g"     "Int"
        "B"     "Int"
        "a"     "Int"
        "m_nAmount"     "Int"
    }
    "DT_TEBloodSprite"
    {
        "m_vecOrigin"       "Vector"
        "m_vecDirection"        "Vector"
        "r"     "Int"
        "g"     "Int"
        "B"     "Int"
        "a"     "Int"
        "m_nSprayModel"     "Int"
        "m_nDropModel"      "Int"
        "m_nSize"       "Int"
    }
    "DT_TEBeamSpline"
    {
        "m_nPoints"     "Int"
        "m_vecPoints[0]"        "Vector"
        "m_vecPoints"       "Array"
    }
    "DT_TEBeamRingPoint"
    {
        "m_vecCenter"       "Vector"
        "m_flStartRadius"       "Float"
        "m_flEndRadius"     "Float"
    }
    "DT_TEBeamRing"
    {
        "m_nStartEntity"        "Int"
        "m_nEndEntity"      "Int"
    }
    "DT_TEBeamPoints"
    {
        "m_vecStartPoint"       "Vector"
        "m_vecEndPoint"     "Vector"
    }
    "DT_TEBeamLaser"
    {
        "m_nStartEntity"        "Int"
        "m_nEndEntity"      "Int"
    }
    "DT_TEBeamFollow"
    {
        "m_iEntIndex"       "Int"
    }
    "DT_TEBeamEnts"
    {
        "m_nStartEntity"        "Int"
        "m_nEndEntity"      "Int"
    }
    "DT_TEBeamEntPoint"
    {
        "m_nStartEntity"        "Int"
        "m_nEndEntity"      "Int"
        "m_vecStartPoint"       "Vector"
        "m_vecEndPoint"     "Vector"
    }
    "DT_BaseBeam"
    {
        "m_nModelIndex"     "Int"
        "m_nHaloIndex"      "Int"
        "m_nStartFrame"     "Int"
        "m_nFrameRate"      "Int"
        "m_fLife"       "Float"
        "m_fWidth"      "Float"
        "m_fEndWidth"       "Float"
        "m_nFadeLength"     "Int"
        "m_fAmplitude"      "Float"
        "m_nSpeed"      "Int"
        "r"     "Int"
        "g"     "Int"
        "B"     "Int"
        "a"     "Int"
        "m_nFlags"      "Int"
    }
    "DT_TEMetalSparks"
    {
        "m_vecPos"      "Vector"
        "m_vecDir"      "Vector"
    }
    "DT_SteamJet"
    {
        "m_SpreadSpeed"     "Float"
        "m_Speed"       "Float"
        "m_StartSize"       "Float"
        "m_EndSize"     "Float"
        "m_Rate"        "Float"
        "m_JetLength"       "Float"
        "m_bEmit"       "Int"
        "m_bFaceLeft"       "Int"
        "m_nType"       "Int"
        "m_spawnflags"      "Int"
        "m_flRollSpeed"     "Float"
    }
    "DT_SmokeStack"
    {
        "m_SpreadSpeed"     "Float"
        "m_Speed"       "Float"
        "m_StartSize"       "Float"
        "m_EndSize"     "Float"
        "m_Rate"        "Float"
        "m_JetLength"       "Float"
        "m_bEmit"       "Int"
        "m_flBaseSpread"        "Float"
        "m_flTwist"     "Float"
        "m_flRollSpeed"     "Float"
        "m_iMaterialModel"      "Int"
        "m_AmbientLight.m_vPos"     "Vector"
        "m_AmbientLight.m_vColor"       "Vector"
        "m_AmbientLight.m_flIntensity"      "Float"
        "m_DirLight.m_vPos"     "Vector"
        "m_DirLight.m_vColor"       "Vector"
        "m_DirLight.m_flIntensity"      "Float"
        "m_vWind"       "Vector"
    }
    "DT_DustTrail"
    {
        "m_SpawnRate"       "Float"
        "m_Color"       "Vector"
        "m_ParticleLifetime"        "Float"
        "m_StopEmitTime"        "Float"
        "m_MinSpeed"        "Float"
        "m_MaxSpeed"        "Float"
        "m_MinDirectedSpeed"        "Float"
        "m_MaxDirectedSpeed"        "Float"
        "m_StartSize"       "Float"
        "m_EndSize"     "Float"
        "m_SpawnRadius"     "Float"
        "m_bEmit"       "Int"
        "m_Opacity"     "Float"
    }
    "DT_FireTrail"
    {
        "m_nAttachment"     "Int"
        "m_flLifetime"      "Float"
    }
    "DT_SporeTrail"
    {
        "m_flSpawnRate"     "Float"
        "m_vecEndColor"     "Vector"
        "m_flParticleLifetime"      "Float"
        "m_flStartSize"     "Float"
        "m_flEndSize"       "Float"
        "m_flSpawnRadius"       "Float"
        "m_bEmit"       "Int"
    }
    "DT_SporeExplosion"
    {
        "m_flSpawnRate"     "Float"
        "m_flParticleLifetime"      "Float"
        "m_flStartSize"     "Float"
        "m_flEndSize"       "Float"
        "m_flSpawnRadius"       "Float"
        "m_bEmit"       "Int"
        "m_bDontRemove"     "Int"
    }
    "DT_RocketTrail"
    {
        "m_SpawnRate"       "Float"
        "m_StartColor"      "Vector"
        "m_EndColor"        "Vector"
        "m_ParticleLifetime"        "Float"
        "m_StopEmitTime"        "Float"
        "m_MinSpeed"        "Float"
        "m_MaxSpeed"        "Float"
        "m_StartSize"       "Float"
        "m_EndSize"     "Float"
        "m_SpawnRadius"     "Float"
        "m_bEmit"       "Int"
        "m_nAttachment"     "Int"
        "m_Opacity"     "Float"
        "m_bDamaged"        "Int"
        "m_flFlareScale"        "Float"
    }
    "DT_SmokeTrail"
    {
        "m_SpawnRate"       "Float"
        "m_StartColor"      "Vector"
        "m_EndColor"        "Vector"
        "m_ParticleLifetime"        "Float"
        "m_StopEmitTime"        "Float"
        "m_MinSpeed"        "Float"
        "m_MaxSpeed"        "Float"
        "m_MinDirectedSpeed"        "Float"
        "m_MaxDirectedSpeed"        "Float"
        "m_StartSize"       "Float"
        "m_EndSize"     "Float"
        "m_SpawnRadius"     "Float"
        "m_bEmit"       "Int"
        "m_nAttachment"     "Int"
        "m_Opacity"     "Float"
    }
    "DT_PropVehicleDriveable"
    {
        "m_hPlayer"     "Int"
        "m_nSpeed"      "Int"
        "m_nRPM"        "Int"
        "m_flThrottle"      "Float"
        "m_nBoostTimeLeft"      "Int"
        "m_nHasBoost"       "Int"
        "m_nScannerDisabledWeapons"     "Int"
        "m_nScannerDisabledVehicle"     "Int"
        "m_bEnterAnimOn"        "Int"
        "m_bExitAnimOn"     "Int"
        "m_bUnableToFire"       "Int"
        "m_vecEyeExitEndpoint"      "Vector"
        "m_bHasGun"     "Int"
        "m_vecGunCrosshair"     "Vector"
    }
    "DT_ParticleSmokeGrenade"
    {
        "m_flSpawnTime"     "Float"
        "m_FadeStartTime"       "Float"
        "m_FadeEndTime"     "Float"
        "m_CurrentStage"        "Int"
    }
    "DT_ParticleFire"
    {
        "m_vOrigin"     "Vector"
        "m_vDirection"      "Vector"
    }
    "DT_TEGaussExplosion"
    {
        "m_nType"       "Int"
        "m_vecDirection"        "Vector"
    }
    "DT_QuadraticBeam"
    {
        "m_targetPosition"      "Vector"
        "m_controlPosition"     "Vector"
        "m_scrollRate"      "Float"
        "m_flWidth"     "Float"
    }
    "DT_Embers"
    {
        "m_nDensity"        "Int"
        "m_nLifeTime"       "Int"
        "m_nSpeed"      "Int"
        "m_bEmit"       "Int"
    }
    "DT_EnvWind"
    {
        "m_EnvWindShared"
        {
            "m_iMinWind"        "Int"
            "m_iMaxWind"        "Int"
            "m_iMinGust"        "Int"
            "m_iMaxGust"        "Int"
            "m_flMinGustDelay"      "Float"
            "m_flMaxGustDelay"      "Float"
            "m_iGustDirChange"      "Int"
            "m_iWindSeed"       "Int"
            "m_iInitialWindDir"     "Int"
            "m_flInitialWindSpeed"      "Float"
            "m_flStartTime"     "Float"
            "m_flGustDuration"      "Float"
        }
    }
    "DT_Precipitation"
    {
        "m_nPrecipType"     "Int"
    }
    "DT_WeaponIFMBaseCamera"
    {
        "m_flRenderAspectRatio"     "Float"
        "m_flRenderFOV"     "Float"
        "m_flRenderArmLength"       "Float"
        "m_vecRenderPosition"       "Vector"
        "m_angRenderAngles"     "Vector"
    }
    "DT_TFWearable"
    {
        "m_bDisguiseWearable"       "Int"
        "m_hWeaponAssociatedWith"       "Int"
    }
    "DT_BaseAttributableItem"
    {
        "m_AttributeManager"
        {
            "m_hOuter"      "Int"
            "m_ProviderType"        "Int"
            "m_iReapplyProvisionParity"     "Int"
            "m_Item"
            {
                "m_iItemDefinitionIndex"        "Int"
                "m_iEntityLevel"        "Int"
                "m_iItemIDHigh"     "Int"
                "m_iItemIDLow"      "Int"
                "m_iAccountID"      "Int"
                "m_iEntityQuality"      "Int"
                "m_bInitialized"        "Int"
                "m_bOnlyIterateItemViewAttributes"      "Int"
                "m_AttributeList"
                {
                    "m_Attributes"
                    {
                        "lengthproxy"
                        {
                            "lengthprop20"      "Int"
                        }
                    }
                }
                "m_iTeamNumber"     "Int"
                "m_NetworkedDynamicAttributesForDemos"
                {
                    "m_Attributes"
                    {
                        "lengthproxy"
                        {
                            "lengthprop20"      "Int"
                        }
                    }
                }
            }
        }
    }
    "DT_EconEntity"
    {
        "m_AttributeManager"
        {
            "m_hOuter"      "Int"
            "m_ProviderType"        "Int"
            "m_iReapplyProvisionParity"     "Int"
            "m_Item"
            {
                "m_iItemDefinitionIndex"        "Int"
                "m_iEntityLevel"        "Int"
                "m_iItemIDHigh"     "Int"
                "m_iItemIDLow"      "Int"
                "m_iAccountID"      "Int"
                "m_iEntityQuality"      "Int"
                "m_bInitialized"        "Int"
                "m_bOnlyIterateItemViewAttributes"      "Int"
                "m_AttributeList"
                {
                    "m_Attributes"
                    {
                        "lengthproxy"
                        {
                            "lengthprop20"      "Int"
                        }
                    }
                }
                "m_iTeamNumber"     "Int"
                "m_NetworkedDynamicAttributesForDemos"
                {
                    "m_Attributes"
                    {
                        "lengthproxy"
                        {
                            "lengthprop20"      "Int"
                        }
                    }
                }
            }
        }
        "m_bValidatedAttachedEntity"        "Int"
    }
    "DT_HandleTest"
    {
        "m_Handle"      "Int"
        "m_bSendHandle"     "Int"
    }
    "DT_TeamplayRoundBasedRulesProxy"
    {
        "teamplayroundbased_gamerules_data"
        {
            "m_iRoundState"     "Int"
            "m_bInWaitingForPlayers"        "Int"
            "m_iWinningTeam"        "Int"
            "m_bInOvertime"     "Int"
            "m_bInSetup"        "Int"
            "m_bSwitchedTeamsThisRound"     "Int"
            "m_bAwaitingReadyRestart"       "Int"
            "m_flRestartRoundTime"      "Float"
            "m_flMapResetTime"      "Float"
            "m_nRoundsPlayed"       "Int"
            "m_flNextRespawnWave"       "DataTable"
            "m_TeamRespawnWaveTimes"        "DataTable"
            "m_bTeamReady"      "DataTable"
            "m_bStopWatch"      "Int"
            "m_bMultipleTrains"     "Int"
            "m_bPlayerReady"        "DataTable"
            "m_bCheatsEnabledDuringLevel"       "Int"
            "m_flCountdownTime"     "Float"
            "m_flStateTransitionTime"       "Float"
        }
    }
    "DT_TeamRoundTimer"
    {
        "m_bTimerPaused"        "Int"
        "m_flTimeRemaining"     "Float"
        "m_flTimerEndTime"      "Float"
        "m_nTimerMaxLength"     "Int"
        "m_bIsDisabled"     "Int"
        "m_bShowInHUD"      "Int"
        "m_nTimerLength"        "Int"
        "m_nTimerInitialLength"     "Int"
        "m_bAutoCountdown"      "Int"
        "m_nSetupTimeLength"        "Int"
        "m_nState"      "Int"
        "m_bStartPaused"        "Int"
        "m_bShowTimeRemaining"      "Int"
        "m_bInCaptureWatchState"        "Int"
        "m_bStopWatchTimer"     "Int"
        "m_flTotalTime"     "Float"
    }
    "DT_SpriteTrail"
    {
        "m_flLifetime"      "Float"
        "m_flStartWidth"        "Float"
        "m_flEndWidth"      "Float"
        "m_flStartWidthVariance"        "Float"
        "m_flTextureRes"        "Float"
        "m_flMinFadeLength"     "Float"
        "m_vecSkyboxOrigin"     "Vector"
        "m_flSkyboxScale"       "Float"
    }
    "DT_Sprite"
    {
        "m_hAttachedToEntity"       "Int"
        "m_nAttachment"     "Int"
        "m_flScaleTime"     "Float"
        "m_flSpriteScale"       "Float"
        "m_flSpriteFramerate"       "Float"
        "m_flGlowProxySize"     "Float"
        "m_flHDRColorScale"     "Float"
        "m_flFrame"     "Float"
        "m_flBrightnessTime"        "Float"
        "m_nBrightness"     "Int"
        "m_bWorldSpaceScale"        "Int"
    }
    "DT_Ragdoll_Attached"
    {
        "m_boneIndexAttached"       "Int"
        "m_ragdollAttachedObjectIndex"      "Int"
        "m_attachmentPointBoneSpace"        "Vector"
        "m_attachmentPointRagdollSpace"     "Vector"
    }
    "DT_Ragdoll"
    {
        "m_ragAngles[0]"        "Vector"
        "m_ragAngles"       "Array"
        "m_ragPos[0]"       "Vector"
        "m_ragPos"      "Array"
        "m_hUnragdoll"      "Int"
        "m_flBlendWeight"       "Float"
        "m_nOverlaySequence"        "Int"
    }
    "DT_PoseController"
    {
        "m_hProps"      "DataTable"
        "m_chPoseIndex"     "DataTable"
        "m_bPoseValueParity"        "Int"
        "m_fPoseValue"      "Float"
        "m_fInterpolationTime"      "Float"
        "m_bInterpolationWrap"      "Int"
        "m_fCycleFrequency"     "Float"
        "m_nFModType"       "Int"
        "m_fFModTimeOffset"     "Float"
        "m_fFModRate"       "Float"
        "m_fFModAmplitude"      "Float"
    }
    "DT_FuncLadder"
    {
        "m_vecPlayerMountPositionTop"       "Vector"
        "m_vecPlayerMountPositionBottom"        "Vector"
        "m_vecLadderDir"        "Vector"
        "m_bFakeLadder"     "Int"
    }
    "DT_DetailController"
    {
        "m_flFadeStartDist"     "Float"
        "m_flFadeEndDist"       "Float"
    }
    "DT_World"
    {
        "m_flWaveHeight"        "Float"
        "m_WorldMins"       "Vector"
        "m_WorldMaxs"       "Vector"
        "m_bStartDark"      "Int"
        "m_flMaxOccludeeArea"       "Float"
        "m_flMinOccluderArea"       "Float"
        "m_flMaxPropScreenSpaceWidth"       "Float"
        "m_flMinPropScreenSpaceWidth"       "Float"
        "m_iszDetailSpriteMaterial"     "String"
        "m_bColdWorld"      "Int"
    }
    "DT_WaterLODControl"
    {
        "m_flCheapWaterStartDistance"       "Float"
        "m_flCheapWaterEndDistance"     "Float"
    }
    "DT_VoteController"
    {
        "m_iActiveIssueIndex"       "Int"
        "m_nVoteIdx"        "Int"
        "m_iOnlyTeamToVote"     "Int"
        "m_nVoteOptionCount"        "DataTable"
        "m_nPotentialVotes"     "Int"
        "m_bIsYesNoVote"        "Int"
    }
    "DT_VGuiScreen"
    {
        "m_flWidth"     "Float"
        "m_flHeight"        "Float"
        "m_fScreenFlags"        "Int"
        "m_nPanelName"      "Int"
        "m_nAttachmentIndex"        "Int"
        "m_nOverlayMaterial"        "Int"
        "m_hPlayerOwner"        "Int"
    }
    "DT_PropJeep"
    {
        "m_bHeadlightIsOn"      "Int"
    }
    "DT_PropVehicleChoreoGeneric"
    {
        "m_hPlayer"     "Int"
        "m_bEnterAnimOn"        "Int"
        "m_bExitAnimOn"     "Int"
        "m_vecEyeExitEndpoint"      "Vector"
        "m_vehicleView.bClampEyeAngles"     "Int"
        "m_vehicleView.flPitchCurveZero"        "Float"
        "m_vehicleView.flPitchCurveLinear"      "Float"
        "m_vehicleView.flRollCurveZero"     "Float"
        "m_vehicleView.flRollCurveLinear"       "Float"
        "m_vehicleView.flFOV"       "Float"
        "m_vehicleView.flYawMin"        "Float"
        "m_vehicleView.flYawMax"        "Float"
        "m_vehicleView.flPitchMin"      "Float"
        "m_vehicleView.flPitchMax"      "Float"
    }
    "DT_ProxyToggle"
    {
        "blah"
        {
            "m_WithProxy"       "Int"
        }
    }
    "DT_Tesla"
    {
        "m_SoundName"       "String"
        "m_iszSpriteName"       "String"
    }
    "DT_TeamTrainWatcher"
    {
        "m_flTotalProgress"     "Float"
        "m_iTrainSpeedLevel"        "Int"
        "m_flRecedeTime"        "Float"
        "m_nNumCappers"     "Int"
        "m_hGlowEnt"        "Int"
    }
    "DT_BaseTeamObjectiveResource"
    {
        "m_iTimerToShowInHUD"       "Int"
        "m_iStopWatchTimer"     "Int"
        "m_iNumControlPoints"       "Int"
        "m_bPlayingMiniRounds"      "Int"
        "m_bControlPointsReset"     "Int"
        "m_iUpdateCapHudParity"     "Int"
        "m_vCPPositions[0]"     "Vector"
        "m_vCPPositions"        "Array"
        "m_bCPIsVisible"        "DataTable"
        "m_flLazyCapPerc"       "DataTable"
        "m_iTeamIcons"      "DataTable"
        "m_iTeamOverlays"       "DataTable"
        "m_iTeamReqCappers"     "DataTable"
        "m_flTeamCapTime"       "DataTable"
        "m_iPreviousPoints"     "DataTable"
        "m_bTeamCanCap"     "DataTable"
        "m_iTeamBaseIcons"      "DataTable"
        "m_iBaseControlPoints"      "DataTable"
        "m_bInMiniRound"        "DataTable"
        "m_iWarnOnCap"      "DataTable"
        "m_iszWarnSound[0]"     "String"
        "m_iszWarnSound"        "Array"
        "m_flPathDistance"      "DataTable"
        "m_iCPGroup"        "DataTable"
        "m_bCPLocked"       "DataTable"
        "m_nNumNodeHillData"        "DataTable"
        "m_flNodeHillData"      "DataTable"
        "m_bTrackAlarm"     "DataTable"
        "m_flUnlockTimes"       "DataTable"
        "m_bHillIsDownhill"     "DataTable"
        "m_flCPTimerTimes"      "DataTable"
        "m_iNumTeamMembers"     "DataTable"
        "m_iCappingTeam"        "DataTable"
        "m_iTeamInZone"     "DataTable"
        "m_bBlocked"        "DataTable"
        "m_iOwner"      "DataTable"
        "m_bCPCapRateScalesWithPlayers"     "DataTable"
        "m_pszCapLayoutInHUD"       "String"
        "m_flCustomPositionX"       "Float"
        "m_flCustomPositionY"       "Float"
    }
    "DT_Team"
    {
        "m_iTeamNum"        "Int"
        "m_iScore"      "Int"
        "m_iRoundsWon"      "Int"
        "m_szTeamname"      "String"
        "player_array_element"      "Int"
        "\"player_array\""      "Array"
    }
    "DT_Sun"
    {
        "m_clrRender"       "Int"
        "m_clrOverlay"      "Int"
        "m_vDirection"      "Vector"
        "m_bOn"     "Int"
        "m_nSize"       "Int"
        "m_nOverlaySize"        "Int"
        "m_nMaterial"       "Int"
        "m_nOverlayMaterial"        "Int"
        "HDRColorScale"     "Float"
    }
    "DT_ParticlePerformanceMonitor"
    {
        "m_bMeasurePerf"        "Int"
        "m_bDisplayPerf"        "Int"
    }
    "DT_SpotlightEnd"
    {
        "m_flLightScale"        "Float"
        "m_Radius"      "Float"
    }
    "DT_SlideshowDisplay"
    {
        "m_bEnabled"        "Int"
        "m_szDisplayText"       "String"
        "m_szSlideshowDirectory"        "String"
        "m_chCurrentSlideLists"     "DataTable"
        "m_fMinSlideTime"       "Float"
        "m_fMaxSlideTime"       "Float"
        "m_iCycleType"      "Int"
        "m_bNoListRepeats"      "Int"
    }
    "DT_ShadowControl"
    {
        "m_shadowDirection"     "Vector"
        "m_shadowColor"     "Int"
        "m_flShadowMaxDist"     "Float"
        "m_bDisableShadows"     "Int"
    }
    "DT_SceneEntity"
    {
        "m_nSceneStringIndex"       "Int"
        "m_bIsPlayingBack"      "Int"
        "m_bPaused"     "Int"
        "m_bMultiplayer"        "Int"
        "m_flForceClientTime"       "Float"
        "m_hActorList"
        {
            "lengthproxy"
            {
                "lengthprop16"      "Int"
            }
        }
    }
    "DT_RopeKeyframe"
    {
        "m_iRopeMaterialModelIndex"     "Int"
        "m_hStartPoint"     "Int"
        "m_hEndPoint"       "Int"
        "m_iStartAttachment"        "Int"
        "m_iEndAttachment"      "Int"
        "m_fLockedPoints"       "Int"
        "m_Slack"       "Int"
        "m_RopeLength"      "Int"
        "m_RopeFlags"       "Int"
        "m_TextureScale"        "Float"
        "m_nSegments"       "Int"
        "m_bConstrainBetweenEndpoints"      "Int"
        "m_Subdiv"      "Int"
        "m_Width"       "Float"
        "m_flScrollSpeed"       "Float"
        "m_vecOrigin"       "Vector"
        "moveparent"        "Int"
        "m_iParentAttachment"       "Int"
    }
    "DT_RagdollManager"
    {
        "m_iCurrentMaxRagdollCount"     "Int"
    }
    "DT_PhysicsPropMultiplayer"
    {
        "m_iPhysicsMode"        "Int"
        "m_fMass"       "Float"
        "m_collisionMins"       "Vector"
        "m_collisionMaxs"       "Vector"
    }
    "DT_PhysBoxMultiplayer"
    {
        "m_iPhysicsMode"        "Int"
        "m_fMass"       "Float"
    }
    "DT_DynamicProp"
    {
        "m_bUseHitboxesForRenderBox"        "Int"
    }
    "DT_PointWorldText"
    {
        "m_szText"      "String"
        "m_flTextSize"      "Float"
        "m_flTextSpacingX"      "Float"
        "m_flTextSpacingY"      "Float"
        "m_colTextColor"        "Int"
        "m_nOrientation"        "Int"
        "m_nFont"       "Int"
        "m_bRainbow"        "Int"
    }
    "DT_PointCommentaryNode"
    {
        "m_bActive"     "Int"
        "m_flStartTime"     "Float"
        "m_iszCommentaryFile"       "String"
        "m_iszCommentaryFileNoHDR"      "String"
        "m_iszSpeakers"     "String"
        "m_iNodeNumber"     "Int"
        "m_iNodeNumberMax"      "Int"
        "m_hViewPosition"       "Int"
    }
    "DT_PointCamera"
    {
        "m_FOV"     "Float"
        "m_Resolution"      "Float"
        "m_bFogEnable"      "Int"
        "m_FogColor"        "Int"
        "m_flFogStart"      "Float"
        "m_flFogEnd"        "Float"
        "m_flFogMaxDensity"     "Float"
        "m_bActive"     "Int"
        "m_bUseScreenAspectRatio"       "Int"
    }
    "DT_PlayerResource"
    {
        "m_iPing"       "DataTable"
        "m_iScore"      "DataTable"
        "m_iDeaths"     "DataTable"
        "m_bConnected"      "DataTable"
        "m_iTeam"       "DataTable"
        "m_bAlive"      "DataTable"
        "m_iHealth"     "DataTable"
        "m_iAccountID"      "DataTable"
        "m_bValid"      "DataTable"
        "m_iUserID"     "DataTable"
    }
    "DT_Plasma"
    {
        "m_flStartScale"        "Float"
        "m_flScale"     "Float"
        "m_flScaleTime"     "Float"
        "m_nFlags"      "Int"
        "m_nPlasmaModelIndex"       "Int"
        "m_nPlasmaModelIndex2"      "Int"
        "m_nGlowModelIndex"     "Int"
    }
    "DT_PhysicsProp"
    {
        "m_bAwake"      "Int"
    }
    "DT_PhysBox"
    {
        "m_mass"        "Float"
    }
    "DT_ParticleSystem"
    {
        "m_vecOrigin"       "Vector"
        "m_hOwnerEntity"        "Int"
        "moveparent"        "Int"
        "m_iParentAttachment"       "Int"
        "m_angRotation"     "Vector"
        "m_iEffectIndex"        "Int"
        "m_bActive"     "Int"
        "m_flStartTime"     "Float"
        "m_hControlPointEnts"       "DataTable"
        "m_iControlPointParents"        "DataTable"
        "m_bWeatherEffect"      "Int"
    }
    "DT_MaterialModifyControl"
    {
        "m_szMaterialName"      "String"
        "m_szMaterialVar"       "String"
        "m_szMaterialVarValue"      "String"
        "m_iFrameStart"     "Int"
        "m_iFrameEnd"       "Int"
        "m_bWrap"       "Int"
        "m_flFramerate"     "Float"
        "m_bNewAnimCommandsSemaphore"       "Int"
        "m_flFloatLerpStartValue"       "Float"
        "m_flFloatLerpEndValue"     "Float"
        "m_flFloatLerpTransitionTime"       "Float"
        "m_bFloatLerpWrap"      "Int"
        "m_nModifyMode"     "Int"
    }
    "DT_LightGlow"
    {
        "m_clrRender"       "Int"
        "m_nHorizontalSize"     "Int"
        "m_nVerticalSize"       "Int"
        "m_nMinDist"        "Int"
        "m_nMaxDist"        "Int"
        "m_nOuterMaxDist"       "Int"
        "m_spawnflags"      "Int"
        "m_vecOrigin"       "Vector"
        "m_angRotation"     "Vector"
        "moveparent"        "Int"
        "m_flGlowProxySize"     "Float"
        "HDRColorScale"     "Float"
    }
    "DT_InfoOverlayAccessor"
    {
        "m_iTextureFrameIndex"      "Int"
        "m_iOverlayID"      "Int"
    }
    "DT_FuncSmokeVolume"
    {
        "m_Color1"      "Int"
        "m_Color2"      "Int"
        "m_MaterialName"        "String"
        "m_ParticleDrawWidth"       "Float"
        "m_ParticleSpacingDistance"     "Float"
        "m_DensityRampSpeed"        "Float"
        "m_RotationSpeed"       "Float"
        "m_MovementSpeed"       "Float"
        "m_Density"     "Float"
        "m_spawnflags"      "Int"
        "m_Collision"
        {
            "m_vecMinsPreScaled"        "Vector"
            "m_vecMaxsPreScaled"        "Vector"
            "m_vecMins"     "Vector"
            "m_vecMaxs"     "Vector"
            "m_nSolidType"      "Int"
            "m_usSolidFlags"        "Int"
            "m_nSurroundType"       "Int"
            "m_triggerBloat"        "Int"
            "m_bUniformTriggerBloat"        "Int"
            "m_vecSpecifiedSurroundingMinsPreScaled"        "Vector"
            "m_vecSpecifiedSurroundingMaxsPreScaled"        "Vector"
            "m_vecSpecifiedSurroundingMins"     "Vector"
            "m_vecSpecifiedSurroundingMaxs"     "Vector"
        }
    }
    "DT_FuncRotating"
    {
        "m_vecOrigin"       "Vector"
        "m_angRotation[0]"      "Float"
        "m_angRotation[1]"      "Float"
        "m_angRotation[2]"      "Float"
        "m_flSimulationTime"        "Int"
    }
    "DT_FuncOccluder"
    {
        "m_bActive"     "Int"
        "m_nOccluderIndex"      "Int"
    }
    "DT_Func_LOD"
    {
        "m_fDisappearDist"      "Float"
    }
    "DT_TEDust"
    {
        "m_flSize"      "Float"
        "m_flSpeed"     "Float"
        "m_vecDirection"        "Vector"
    }
    "DT_Func_Dust"
    {
        "m_Color"       "Int"
        "m_SpawnRate"       "Int"
        "m_flSizeMin"       "Float"
        "m_flSizeMax"       "Float"
        "m_LifetimeMin"     "Int"
        "m_LifetimeMax"     "Int"
        "m_DustFlags"       "Int"
        "m_SpeedMax"        "Int"
        "m_DistMax"     "Int"
        "m_nModelIndex"     "Int"
        "m_FallSpeed"       "Float"
        "m_Collision"
        {
            "m_vecMinsPreScaled"        "Vector"
            "m_vecMaxsPreScaled"        "Vector"
            "m_vecMins"     "Vector"
            "m_vecMaxs"     "Vector"
            "m_nSolidType"      "Int"
            "m_usSolidFlags"        "Int"
            "m_nSurroundType"       "Int"
            "m_triggerBloat"        "Int"
            "m_bUniformTriggerBloat"        "Int"
            "m_vecSpecifiedSurroundingMinsPreScaled"        "Vector"
            "m_vecSpecifiedSurroundingMaxsPreScaled"        "Vector"
            "m_vecSpecifiedSurroundingMins"     "Vector"
            "m_vecSpecifiedSurroundingMaxs"     "Vector"
        }
    }
    "DT_FuncConveyor"
    {
        "m_flConveyorSpeed"     "Float"
    }
    "DT_BreakableSurface"
    {
        "m_nNumWide"        "Int"
        "m_nNumHigh"        "Int"
        "m_flPanelWidth"        "Float"
        "m_flPanelHeight"       "Float"
        "m_vNormal"     "Vector"
        "m_vCorner"     "Vector"
        "m_bIsBroken"       "Int"
        "m_nSurfaceType"        "Int"
        "m_RawPanelBitVec"      "DataTable"
    }
    "DT_FuncAreaPortalWindow"
    {
        "m_flFadeStartDist"     "Float"
        "m_flFadeDist"      "Float"
        "m_flTranslucencyLimit"     "Float"
        "m_iBackgroundModelIndex"       "Int"
    }
    "DT_CFish"
    {
        "m_poolOrigin"      "Vector"
        "m_x"       "Float"
        "m_y"       "Float"
        "m_z"       "Float"
        "m_angle"       "Float"
        "m_nModelIndex"     "Int"
        "m_lifeState"       "Int"
        "m_waterLevel"      "Float"
    }
    "DT_EntityFlame"
    {
        "m_hEntAttached"        "Int"
    }
    "DT_FireSmoke"
    {
        "m_flStartScale"        "Float"
        "m_flScale"     "Float"
        "m_flScaleTime"     "Float"
        "m_nFlags"      "Int"
        "m_nFlameModelIndex"        "Int"
        "m_nFlameFromAboveModelIndex"       "Int"
    }
    "DT_EnvTonemapController"
    {
        "m_bUseCustomAutoExposureMin"       "Int"
        "m_bUseCustomAutoExposureMax"       "Int"
        "m_bUseCustomBloomScale"        "Int"
        "m_flCustomAutoExposureMin"     "Float"
        "m_flCustomAutoExposureMax"     "Float"
        "m_flCustomBloomScale"      "Float"
        "m_flCustomBloomScaleMinimum"       "Float"
    }
    "DT_EnvScreenEffect"
    {
        "m_flDuration"      "Float"
        "m_nType"       "Int"
    }
    "DT_EnvScreenOverlay"
    {
        "m_iszOverlayNames[0]"      "String"
        "m_iszOverlayNames"     "Array"
        "m_flOverlayTimes[0]"       "Float"
        "m_flOverlayTimes"      "Array"
        "m_flStartTime"     "Float"
        "m_iDesiredOverlay"     "Int"
        "m_bIsActive"       "Int"
    }
    "DT_EnvProjectedTexture"
    {
        "m_hTargetEntity"       "Int"
        "m_bState"      "Int"
        "m_flLightFOV"      "Float"
        "m_bEnableShadows"      "Int"
        "m_bLightOnlyTarget"        "Int"
        "m_bLightWorld"     "Int"
        "m_bCameraSpace"        "Int"
        "m_LinearFloatLightColor"       "Vector"
        "m_flAmbient"       "Float"
        "m_SpotlightTextureName"        "String"
        "m_nSpotlightTextureFrame"      "Int"
        "m_flNearZ"     "Float"
        "m_flFarZ"      "Float"
        "m_nShadowQuality"      "Int"
    }
    "DT_EnvParticleScript"
    {
        "m_flSequenceScale"     "Float"
    }
    "DT_FogController"
    {
        "m_fog.enable"      "Int"
        "m_fog.blend"       "Int"
        "m_fog.dirPrimary"      "Vector"
        "m_fog.colorPrimary"        "Int"
        "m_fog.colorSecondary"      "Int"
        "m_fog.start"       "Float"
        "m_fog.end"     "Float"
        "m_fog.farz"        "Float"
        "m_fog.maxdensity"      "Float"
        "m_fog.colorPrimaryLerpTo"      "Int"
        "m_fog.colorSecondaryLerpTo"        "Int"
        "m_fog.startLerpTo"     "Float"
        "m_fog.endLerpTo"       "Float"
        "m_fog.lerptime"        "Float"
        "m_fog.duration"        "Float"
    }
    "DT_EntityParticleTrail"
    {
        "m_iMaterialName"       "Int"
        "m_Info"
        {
            "m_flLifetime"      "Float"
            "m_flStartSize"     "Float"
            "m_flEndSize"       "Float"
        }
        "m_hConstraintEntity"       "Int"
    }
    "DT_EntityDissolve"
    {
        "m_flStartTime"     "Float"
        "m_flFadeOutStart"      "Float"
        "m_flFadeOutLength"     "Float"
        "m_flFadeOutModelStart"     "Float"
        "m_flFadeOutModelLength"        "Float"
        "m_flFadeInStart"       "Float"
        "m_flFadeInLength"      "Float"
        "m_nDissolveType"       "Int"
        "m_vDissolverOrigin"        "Vector"
        "m_nMagnitude"      "Int"
    }
    "DT_DynamicLight"
    {
        "m_Flags"       "Int"
        "m_LightStyle"      "Int"
        "m_Radius"      "Float"
        "m_Exponent"        "Int"
        "m_InnerAngle"      "Float"
        "m_OuterAngle"      "Float"
        "m_SpotRadius"      "Float"
    }
    "DT_ColorCorrectionVolume"
    {
        "m_Weight"      "Float"
        "m_lookupFilename"      "String"
    }
    "DT_ColorCorrection"
    {
        "m_vecOrigin"       "Vector"
        "m_minFalloff"      "Float"
        "m_maxFalloff"      "Float"
        "m_flCurWeight"     "Float"
        "m_netLookupFilename"       "String"
        "m_bEnabled"        "Int"
    }
    "DT_BasePlayer"
    {
        "localdata"
        {
            "m_Local"
            {
                "m_chAreaBits"      "DataTable"
                "m_chAreaPortalBits"        "DataTable"
                "m_iHideHUD"        "Int"
                "m_flFOVRate"       "Float"
                "m_bDucked"     "Int"
                "m_bDucking"        "Int"
                "m_bInDuckJump"     "Int"
                "m_flDucktime"      "Float"
                "m_flDuckJumpTime"      "Float"
                "m_flJumpTime"      "Float"
                "m_flFallVelocity"      "Float"
                "m_vecPunchAngle"       "Vector"
                "m_vecPunchAngleVel"        "Vector"
                "m_bDrawViewmodel"      "Int"
                "m_bWearingSuit"        "Int"
                "m_bPoisoned"       "Int"
                "m_bForceLocalPlayerDraw"       "Int"
                "m_flStepSize"      "Float"
                "m_bAllowAutoMovement"      "Int"
                "m_skybox3d.scale"      "Int"
                "m_skybox3d.origin"     "Vector"
                "m_skybox3d.area"       "Int"
                "m_skybox3d.fog.enable"     "Int"
                "m_skybox3d.fog.blend"      "Int"
                "m_skybox3d.fog.dirPrimary"     "Vector"
                "m_skybox3d.fog.colorPrimary"       "Int"
                "m_skybox3d.fog.colorSecondary"     "Int"
                "m_skybox3d.fog.start"      "Float"
                "m_skybox3d.fog.end"        "Float"
                "m_skybox3d.fog.maxdensity"     "Float"
                "m_PlayerFog.m_hCtrl"       "Int"
                "m_audio.localSound[0]"     "Vector"
                "m_audio.localSound[1]"     "Vector"
                "m_audio.localSound[2]"     "Vector"
                "m_audio.localSound[3]"     "Vector"
                "m_audio.localSound[4]"     "Vector"
                "m_audio.localSound[5]"     "Vector"
                "m_audio.localSound[6]"     "Vector"
                "m_audio.localSound[7]"     "Vector"
                "m_audio.soundscapeIndex"       "Int"
                "m_audio.localBits"     "Int"
                "m_audio.entIndex"      "Int"
                "m_szScriptOverlayMaterial"     "String"
            }
            "m_vecViewOffset[0]"        "Float"
            "m_vecViewOffset[1]"        "Float"
            "m_vecViewOffset[2]"        "Float"
            "m_flFriction"      "Float"
            "m_iAmmo"       "DataTable"
            "m_fOnTarget"       "Int"
            "m_nTickBase"       "Int"
            "m_nNextThinkTick"      "Int"
            "m_hLastWeapon"     "Int"
            "m_hGroundEntity"       "Int"
            "m_vecVelocity[0]"      "Float"
            "m_vecVelocity[1]"      "Float"
            "m_vecVelocity[2]"      "Float"
            "m_vecBaseVelocity"     "Vector"
            "m_hConstraintEntity"       "Int"
            "m_vecConstraintCenter"     "Vector"
            "m_flConstraintRadius"      "Float"
            "m_flConstraintWidth"       "Float"
            "m_flConstraintSpeedFactor"     "Float"
            "m_flDeathTime"     "Float"
            "m_nWaterLevel"     "Int"
            "m_flLaggedMovementValue"       "Float"
        }
        "m_AttributeList"
        {
            "m_Attributes"
            {
                "lengthproxy"
                {
                    "lengthprop20"      "Int"
                }
            }
        }
        "pl"
        {
            "deadflag"      "Int"
        }
        "m_iFOV"        "Int"
        "m_iFOVStart"       "Int"
        "m_flFOVTime"       "Float"
        "m_iDefaultFOV"     "Int"
        "m_hZoomOwner"      "Int"
        "m_hVehicle"        "Int"
        "m_hUseEntity"      "Int"
        "m_iHealth"     "Int"
        "m_lifeState"       "Int"
        "m_iBonusProgress"      "Int"
        "m_iBonusChallenge"     "Int"
        "m_flMaxspeed"      "Float"
        "m_fFlags"      "Int"
        "m_iObserverMode"       "Int"
        "m_hObserverTarget"     "Int"
        "m_hViewModel[0]"       "Int"
        "m_hViewModel"      "Array"
        "m_szLastPlaceName"     "String"
        "m_hMyWearables"
        {
            "lengthproxy"
            {
                "lengthprop8"       "Int"
            }
        }
    }
    "DT_BaseFlex"
    {
        "m_flexWeight"      "DataTable"
        "m_blinktoggle"     "Int"
        "m_viewtarget"      "Vector"
    }
    "DT_BaseEntity"
    {
        "AnimTimeMustBeFirst"
        {
            "m_flAnimTime"      "Int"
        }
        "m_flSimulationTime"        "Int"
        "m_ubInterpolationFrame"        "Int"
        "m_vecOrigin"       "Vector"
        "m_angRotation"     "Vector"
        "m_nModelIndex"     "Int"
        "m_fEffects"        "Int"
        "m_nRenderMode"     "Int"
        "m_nRenderFX"       "Int"
        "m_clrRender"       "Int"
        "m_iTeamNum"        "Int"
        "m_CollisionGroup"      "Int"
        "m_flElasticity"        "Float"
        "m_flShadowCastDistance"        "Float"
        "m_hOwnerEntity"        "Int"
        "m_hEffectEntity"       "Int"
        "moveparent"        "Int"
        "m_iParentAttachment"       "Int"
        "movetype"      "Int"
        "movecollide"       "Int"
        "m_Collision"
        {
            "m_vecMinsPreScaled"        "Vector"
            "m_vecMaxsPreScaled"        "Vector"
            "m_vecMins"     "Vector"
            "m_vecMaxs"     "Vector"
            "m_nSolidType"      "Int"
            "m_usSolidFlags"        "Int"
            "m_nSurroundType"       "Int"
            "m_triggerBloat"        "Int"
            "m_bUniformTriggerBloat"        "Int"
            "m_vecSpecifiedSurroundingMinsPreScaled"        "Vector"
            "m_vecSpecifiedSurroundingMaxsPreScaled"        "Vector"
            "m_vecSpecifiedSurroundingMins"     "Vector"
            "m_vecSpecifiedSurroundingMaxs"     "Vector"
        }
        "m_iTextureFrameIndex"      "Int"
        "predictable_id"
        {
            "m_PredictableID"       "Int"
            "m_bIsPlayerSimulated"      "Int"
        }
        "m_bSimulatedEveryTick"     "Int"
        "m_bAnimatedEveryTick"      "Int"
        "m_bAlternateSorting"       "Int"
        "m_nModelIndexOverrides"        "DataTable"
    }
    "DT_BaseDoor"
    {
        "m_flWaveHeight"        "Float"
    }
    "DT_BaseCombatCharacter"
    {
        "bcc_localdata"
        {
            "m_flNextAttack"        "Float"
        }
        "m_hActiveWeapon"       "Int"
        "m_hMyWeapons"      "DataTable"
        "m_bGlowEnabled"        "Int"
    }
    "DT_BaseAnimatingOverlay"
    {
        "overlay_vars"
        {
            "m_AnimOverlay"
            {
                "lengthproxy"
                {
                    "lengthprop15"      "Int"
                }
            }
        }
    }
    "DT_BoneFollower"
    {
        "m_modelIndex"      "Int"
        "m_solidIndex"      "Int"
    }
    "DT_BaseAnimating"
    {
        "m_nSequence"       "Int"
        "m_nForceBone"      "Int"
        "m_vecForce"        "Vector"
        "m_nSkin"       "Int"
        "m_nBody"       "Int"
        "m_nHitboxSet"      "Int"
        "m_flModelScale"        "Float"
        "m_flModelWidthScale"       "Float"
        "m_flPoseParameter"     "DataTable"
        "m_flPlaybackRate"      "Float"
        "m_flEncodedController"     "DataTable"
        "m_bClientSideAnimation"        "Int"
        "m_bClientSideFrameReset"       "Int"
        "m_nNewSequenceParity"      "Int"
        "m_nResetEventsParity"      "Int"
        "m_nMuzzleFlashParity"      "Int"
        "m_hLightingOrigin"     "Int"
        "m_hLightingOriginRelative"     "Int"
        "serveranimdata"
        {
            "m_flCycle"     "Float"
        }
        "m_fadeMinDist"     "Float"
        "m_fadeMaxDist"     "Float"
        "m_flFadeScale"     "Float"
    }
    "DT_InfoLightingRelative"
    {
        "m_hLightingLandmark"       "Int"
    }
    "DT_AI_BaseNPC"
    {
        "m_lifeState"       "Int"
        "m_bPerformAvoidance"       "Int"
        "m_bIsMoving"       "Int"
        "m_bFadeCorpse"     "Int"
        "m_iDeathPose"      "Int"
        "m_iDeathFrame"     "Int"
        "m_iSpeedModRadius"     "Int"
        "m_iSpeedModSpeed"      "Int"
        "m_bSpeedModActive"     "Int"
        "m_bImportanRagdoll"        "Int"
        "m_flTimePingEffect"        "Float"
    }
    "DT_Beam"
    {
        "m_nBeamType"       "Int"
        "m_nBeamFlags"      "Int"
        "m_nNumBeamEnts"        "Int"
        "m_hAttachEntity"       "DataTable"
        "m_nAttachIndex"        "DataTable"
        "m_nHaloIndex"      "Int"
        "m_fHaloScale"      "Float"
        "m_fWidth"      "Float"
        "m_fEndWidth"       "Float"
        "m_fFadeLength"     "Float"
        "m_fAmplitude"      "Float"
        "m_fStartFrame"     "Float"
        "m_fSpeed"      "Float"
        "m_flFramerate"     "Float"
        "m_flHDRColorScale"     "Float"
        "m_clrRender"       "Int"
        "m_nRenderFX"       "Int"
        "m_nRenderMode"     "Int"
        "m_flFrame"     "Float"
        "m_vecEndPos"       "Vector"
        "m_nModelIndex"     "Int"
        "m_nMinDXLevel"     "Int"
        "m_vecOrigin"       "Vector"
        "moveparent"        "Int"
        "beampredictable_id"
        {
            "m_PredictableID"       "Int"
            "m_bIsPlayerSimulated"      "Int"
        }
    }
    "DT_BaseViewModel"
    {
        "m_nModelIndex"     "Int"
        "m_nSkin"       "Int"
        "m_nBody"       "Int"
        "m_nSequence"       "Int"
        "m_nViewModelIndex"     "Int"
        "m_flPlaybackRate"      "Float"
        "m_fEffects"        "Int"
        "m_nAnimationParity"        "Int"
        "m_hWeapon"     "Int"
        "m_hOwner"      "Int"
        "m_nNewSequenceParity"      "Int"
        "m_nResetEventsParity"      "Int"
        "m_nMuzzleFlashParity"      "Int"
        "m_flPoseParameter[0]"      "Float"
        "m_flPoseParameter"     "Array"
    }
    "DT_BaseProjectile"
    {
        "m_hOriginalLauncher"       "Int"
    }
    "DT_BaseGrenade"
    {
        "m_flDamage"        "Float"
        "m_DmgRadius"       "Float"
        "m_bIsLive"     "Int"
        "m_hThrower"        "Int"
        "m_vecVelocity"     "Vector"
        "m_fFlags"      "Int"
    }
    "DT_BaseCombatWeapon"
    {
        "LocalWeaponData"
        {
            "m_iClip1"      "Int"
            "m_iClip2"      "Int"
            "m_iPrimaryAmmoType"        "Int"
            "m_iSecondaryAmmoType"      "Int"
            "m_nViewModelIndex"     "Int"
            "m_nCustomViewmodelModelIndex"      "Int"
            "m_bFlipViewModel"      "Int"
        }
        "LocalActiveWeaponData"
        {
            "m_flNextPrimaryAttack"     "Float"
            "m_flNextSecondaryAttack"       "Float"
            "m_nNextThinkTick"      "Int"
            "m_flTimeWeaponIdle"        "Float"
        }
        "m_iViewModelIndex"     "Int"
        "m_iWorldModelIndex"        "Int"
        "m_iState"      "Int"
        "m_hOwner"      "Int"
    }
}

```


## AttributeDefinition



# AttributeDefinition


The AttributeDefinition object contains information about an attribute in TF2.


## Methods


### GetName()


Returns the name of the attribute.


### GetID()


Returns the ID of the attribute.


### IsStoredAsInteger()


Returns true if the attribute is stored as an integer. For numeric attibutes, false means it is stored as a float.


## Examples


Enumerate all attributes```
itemschema.EnumerateAttributes( function( attrDef )
    print( attrDef:GetName() .. ": " .. tostring( attrDef:GetID() ) )
end )

```


## BitBuffer



# BitBuffer


The BitBuffer object is used to read and write data that is usually sent over the network, compressed into a bitstream.


## Constructor


## BitBuffer( )


Creates a new BitBuffer object with an empty buffer. You can write to it using methods below or have some other functions write to it for you, such as NetMessage::WriteToBitBuffer .


## Methods


### GetDataBitsLength()


Returns the length of the buffer in bits


### GetDataBytesLength()


Returns the length of the buffer in bytes


### Reset()


Resets the read position to the beginning of the buffer. This is useful if you want to read the buffer multiple times, but it is not necessary. 


### ReadByte()


Reads one byte from the buffer. Returns the byte read as first return value, and current bit position as second return value.


### ReadBit()


Reads a single bit from the buffer. Returns the bit read as first return value, and current bit position as second return value.


### ReadFloat( [bitLength:integer] )


Reads 4 bytes from the buffer and returns it as a float. Default bitLength is 32 (4 bytes). For short, use 16, for long, use 64. Returns the float read as first return value, and current bit position as second return value.


### ReadInt( [bitLength:integer] )


Reads 4 bytes from the buffer and returns it as an integer. Default bitLength is 32 (4 bytes). For short, use 16, for long, use 64. Returns the integer read as first return value, and current bit position as second return value.


### ReadString( maxlen:integer )


Reads a string from the buffer. You must specify valid maxlen. The string will be truncated if it is longer than maxlen. Returns the string read as first return value, and current bit position as second return value.


### GetCurBit()


Returns the current bit position in the buffer.


## Writing


When writing, make sure that your curBit is correct and that you do not overflow the buffer.


### SetCurBit( bit:integer )


Sets the current bit position in the buffer.


### WriteBit( bit:integer )


Writes a single bit to the buffer.


### WriteByte( byte:integer )


Writes a single byte to the buffer.


### WriteString( str:string )


Writes given string to the buffer.


### WriteInt( int:integer, [bitLength:integer] )


Writes an integer to the buffer. Default bitLength is 32 (4 bytes). For short, use 16, for long, use 64.


### WriteFloat( value:number, [bitLength:integer] )


Writes a float to the buffer. Default bitLength is 32 (4 bytes). For short, use 16, for long, use 64.


## Examples


Write and print with a BitBuffer```
local bitBuffer = BitBuffer()

bitBuffer:WriteString("Hello world!")
bitBuffer:WriteInt(1234567890)
bitBuffer:WriteByte(254)
bitBuffer:WriteBit(1)

bitBuffer:SetCurBit(0)
local str = bitBuffer:ReadString(256)
local int = bitBuffer:ReadInt(32)
local byte = bitBuffer:ReadByte()
local bit = bitBuffer:ReadBit()
print(str, int, byte, bit)

bitBuffer:Delete()

```

```lua title="Write and print with a NetMessage"



## DrawModelContext



# DrawModelContext


Represents the context in which a model is being drawn in the DrawModel callback.


## Methods


### GetEntity()


Returns entity linked to the drawn model, can be nil.


### GetModelName()


Returns the name of the model being drawn.


### ForcedMaterialOverride( mat:Material )


Replace material used to draw the model. Material can be found or created via materials. API


### DrawExtraPass()


Redraws the model. Can be used to achieve various effects with different materials.


### StudioSetColorModulation( color:Color )


Sets the color modulation of the model via StudioRender. Only works for models rendered using STUDIO_RENDER flag.


### StudioSetAlphaModulation( alpha:number )


Sets the alpha modulation of the model via StudioRender. Only works for models rendered using STUDIO_RENDER flag.


### SetColorModulation( color:Color )


Sets the color modulation of the model via RenderView.


### SetAlphaModulation( alpha:number )


Sets the alpha modulation of the model via RenderView.


### DepthRange( start:number, end:number )


Sets the depth range of the scene. Useful for drawing models in the background or other various effects. Should be reset to the default (0,1) when done.


### SuppressEngineLighting( bool:boolean )


Suppresses the engine lighting when drawing the model.


### Execute()


Draw the model immediately in the current state. Can be called multiple times. A model will be always drawn even without calling Execute, so calling it 1 time will result in 2 Execute calls, calling this 0 times will result in 1 Execute call. The use case for this is stacking material force overrides for example.


### IsDrawingAntiAim()


Returns true if anti aim indicator model is being drawn.


### IsDrawingBackTrack()


Returns true if backtrack indicator model is being drawn.


### IsDrawingGlow()


Returns true if glow model is being drawn.


## Examples


Draw all player models using AmmoBox material```
local ammoboxMaterial = materials.Find( "models/items/ammo_box2" )

local function onDrawModel( drawModelContext )
    local entity = drawModelContext:GetEntity()

    if entity:GetClass() == "CTFPlayer" then
        drawModelContext:ForcedMaterialOverride( ammoboxMaterial )
    end
end

callbacks.Register("DrawModel", "hook123", onDrawModel) 

```


## Entity



# Entity


Represents an entity in the game world. Make sure to not store entities long term, they can become invalid over time - their methods will return nil in that case.


## Methods


### IsValid()


Returns whether the entity is valid. This is done automatically and all other functions will return nil if the entity is invalid.


### GetName()


Returns the name string of the entity if its a player


### GetClass()


Returns the class string of the entity i.e. CTFPlayer


### GetIndex()


Returns entity index


### GetTeamNumber()


Returns the team number of the entity


### GetAbsOrigin()


Returns the absolute position of the entity


### SetAbsOrigin(origin:Vector)


Sets the absolute position of the entity


### GetAbsAngles()


Returns the absolute angles of the entity


### SetAbsAngles(angles:Vector)


Sets the absolute angles of the entity


### GetMins()


Returns mins of the entity, must be combined with origin


### GetMaxs()


Returns maxs of the entity, must be combined with origin


### GetHealth()


Returns the health of the entity


### GetMaxHealth()


Returns the max health of the entity


### GetMoveChild()


Returns the Entity, which is a move child of this entity. This is a start of a peer list of attachments usually.


### GetMovePeer()


Return the Entity, which is a move peer of this entity. This is a next entity in a peer list of attachments usually.


### IsPlayer()


Returns true if the entity is a player


### IsWeapon()


Returns true if the entity is a weapon


### IsAlive()


Returns true if the entity is alive


### EstimateAbsVelocity()


Returns the estimated absolute velocity of the entity as Vector3


### GetMoveType()


Returns the move type of the entity (the netvar propr does not work)


### HitboxSurroundingBox()


Returns the hitbox surrounding box of the entity as table of Vector3 mins and maxs


### EntitySpaceHitboxSurroundingBox()


Returns the hitbox surrounding box of the entity in entity space as table of Vector3 mins and maxs


### SetupBones( [boneMask:integer], [currentTime:number] )


Sets up the bones of the entity, boneMask is optional, by default 0x7FF00, and can be changed if you want to only setup certain bones. The currentTime argument is optional, by default 0, and can be changed if you want the transform to be based on a different time. Returns a table of at most 128 entries of a 3x4 matrix (table) of float numbers, representing the bone transforms.


### GetHitboxes( [currentTime:number] )


Returns world-transformed hitboxes of the entity as table of tables, each containing 2 entries of Vector3: mins and maxs positions of each hitbox.
The currentTime argument is optional, by default 0, and can be changed if you want the transform to be based on a different time.
Example returned table:





Hitbox Index
Mins&Maxs table




`1`
1: Vector3(1,2,3) 2: Vector3(4,5,6)


`2`
1: Vector3(7,8,9) 2: Vector3(0,1,2)



### SetModel( modelPath:string )


Sets the model of the entity, returns true if successful


### GetModel()


Returns the model of the entity


### ShouldDraw()


Retruns true if this entity should be drawn right now


### DrawModel( drawFlags:integer )


Draws the model of the entity


### Release()


Releases the entity, making it invalid. Calling this for networkable entities will kick you from the server. This is only useful for non-networkable entities created with entities.CreateEntityByName


### IsDormant()


Returns true if the entity is dormant (not being updated). Dormant entities are not drawn and shouldn't be interacted with.


### ToInventoryItem()


If the entity is an item that can be in player's inventory, such as a wearable or a weapon, returns the inventory item as Item


## Attributes


In order to get the attributes of an entity, you can use the following methods. The attribute hooking methods will multiply the default value by the attribute value, returning the result. For list of attributes see the Wiki


### AttributeHookFloat( name:string, [defaultValue:number] )


Returns the number value of the attribute present on the entity, defaultValue is by default 1.0


### AttributeHookInt( name:string, [defaultValue:integer] )


Returns the integer value of the attribute present on the entity,defaultValue is by default 1


## Entity netvars/props


You can either input just the netvar name, or the table path to it


### GetPropFloat( propName, ... )


Returns the float value of the given netvar


### GetPropInt( propName, ... )


Returns the int value of the given netvar


### GetPropBool( propName, ... )


Returns the bool value of the given netvar


### GetPropString( propName, ... )


Returns the string value of the given netvar


### GetPropVector( propName, ... )


Returns the vector value of the given netvar


### GetPropEntity( propName, ... )


For entity handle props (m_hXXXXX)


### SetPropFloat( value:number, propName, ... )


Sets the float value of the given netvar.


### SetPropInt( value:integer, propName, ... )


Sets the int value of the given netvar.


### SetPropBool( value:bool, propName, ... )


Sets the bool value of the given netvar.


### SetPropEntity( value:Entity, propName, ... )


Set the entity value of the given netvar.


### SetPropVector( value:Vector3, propName, ... )


Set the vector value of the given netvar.


## Prop Data Tables


They return a Lua Table containing the entries, you can index them with integers


### GetPropDataTableFloat( propName, ... )


Returns a table of floats, index them with integers based on context of the netvar


### GetPropDataTableBool( propName, ... )


Returns a table of bools, index them with integers based on context of the netvar


### GetPropDataTableInt( propName, ... )


Returns a table of ints, index them with integers based on context of the netvar


### GetPropDataTableEntity( propName, ... )


Returns a table of entities, index them with integers based on context of the netvar


### SetPropDataTableFloat( value:number, index:integer, propName, ... )


Sets the number value of the given netvar at the given index.


### SetPropDataTableBool( value:integer, index:integer, propName, ... )


Sets the bool value of the given netvar at the given index.


### SetPropDataTableInt( value:integer, index:integer, propName, ... )


Sets the integer value of the given netvar at the given index.


### SetPropDataTableEntity( value:Entity, index:integer, propName, ... )


Sets the Entity value of the given netvar at the given index.


## Player entity methods


These methods are only available if the entity is a player


### InCond( condition:integer )


Returns whether the player is in the specified condition. List of conditions in TF2 can be found


### AddCond( condition:integer, [duration:number] )


Adds the specified condition to the player, duration is optional (defaults to -1, which means infinite)


### RemoveCond( condition:integer )


Removes the specified condition from the player


### IsCritBoosted()


Whether the player is currently crit boosted by an external source


### GetCritMult()


Returns the current crit multiplier of the player. See TF2 Crit Wiki for more info


### GetCarryingRuneType()


For game mode where players can carry runes, returns the type of rune the player is carrying


### GetMaxBuffedHealth()


Returns the max health of the player, including any buffs from items or medics


### GetEntityForLoadoutSlot( slot:integer )


Returns the entity for the specified loadout slot. This can be used to get the hat entity for the slot, or the weapon entity for the slot


### IsInFreezecam()


Whether the player is currently in a freezecam after death


## GetVAngles()


Returns the third person view angles of the player, as a Vector3


## SetVAngles( vecAngles:Vector3 )


Sets the third person view angles of the player, only really effective on the localplayer


## Weapon entity methods


These methods are only available if the entity is a weapon, some methods have closer specifications on weapon type, and will return nil if the entity is not required weapon type.


### IsShootingWeapon()


Returns whether the weapon is a weapon that can shoot projectiles or hitscan.


### IsMeleeWeapon()


Returns whether the weapon is a melee weapon.


### IsMedigun()


Returns whether the weapon is a medigun, supports all types of mediguns.


### CanRandomCrit()


Returns whether the weapon can randomly crit in general, not in it's current state.


### GetLoadoutSlot()


Returns the loadout slot ID of the weapon.


### GetWeaponID()


Returns the weapon ID of the weapon.


### IsViewModelFlipped()


Returns whether the weapon's view model is flipped.


## Weapon shooting gun methods


Weapon "gun" methods are only available if the weapon is a shooting weapon, i.e. with projectiles.


### GetProjectileFireSetup( player:entity, vecOffset:Vector3, bHitTeammates:bool, flEndDist:number )


Returns vecSrc as Vector3 and angForward as Vector3. vecSrc is the starting position of the projectile, angForward is the direction of the projectile. vecOffset is the offset of the projectile from the player's eye position. bHitTeammates is whether the projectile can hit teammates. flEndDist is the distance the projectile can travel before it disappears.


### GetWeaponProjectileType()


Returns the projectile type of the weapon, returns nil if the weapon is not a projectile weapon.


### GetWeaponSpread()


Returns the spread of the weapon, returns nil if the weapon is not a gun weapon.


### GetProjectileSpeed()


Returns the projectile speed of the weapon, returns nil if the weapon is not a projectile weapon. Can return 0 if the weapon has the speed hardcoded somewhere else. In that case its up to you to figure out the speed.


### GetProjectileGravity()


Returns the projectile gravity of the weapon, returns nil if the weapon is not a projectile weapon. Can return 0 if the weapon has the gravity hardcoded somewhere else. In that case its up to you to figure out the gravity.


### GetProjectileSpread()


Returns the projectile spread of the weapon, returns nil if the weapon is not a projectile weapon.


## ChargeUpWeapon methods


These methods are only available if the weapon is a charge up weapon, i.e. a weapon that can be charged up before firing.


### CanCharge()


Returns whether the weapon can be charged up.


### GetChargeBeginTime()


Returns the time the weapon started charging up, returns nil if the weapon is not a charge up weapon.


### GetChargeMaxTime()


Returns the max charge time of the weapon, returns nil if the weapon is not a charge up weapon.


### GetCurrentCharge()


Returns the current charge of the weapon, returns nil if the weapon is not a charge up weapon.


## Melee Weapon Methods


### GetSwingRange()


Returns the swing range of the weapon, returns nil if the weapon is not a melee weapon.


### DoSwingTrace()


Returns the Trace object result of the weapon's swing. In simple terms, it simulates what would weapon hit if it was swung.


### Medigun methods


### GetMedigunHealRate()


Returns the heal rate of the medigun, returns nil if the weapon is not a medigun.


### GetMedigunHealingStickRange()


Returns the healing stick range of the medigun, returns nil if the weapon is not a medigun.


### GetMedigunHealingRange()


Returns the healing range of the medigun, returns nil if the weapon is not a medigun.


### IsMedigunAllowedToHealTarget( target:Entity )


Returns whether the medigun is allowed to heal the target, returns nil if the weapon is not a medigun.


## Weapon Crit Methods


The following methods have close ties to random crits in TF2. You most likely do not need to use these methods. Feel free to use them though, I'm not here to stop you.


### GetCritTokenBucket()


Returns the current crit token bucket value.


### GetCritCheckCount()


Returns the current crit check count.


### GetCritSeedRequestCount()


Returns the current crit seed request count.


### GetCurrentCritSeed()


Returns the current crit seed.


### GetRapidFireCritTime()


Returns the time until the current rapid fire crit is over.


### GetLastRapidFireCritCheckTime()


Returns the time of the last rapid fire crit check.


### GetWeaponBaseDamage()


Returns the base damage of the weapon.


### GetCritChance()


Returns the weapon's current crit chance as a number from 0 to 1. This crit chance changes during gameplay based on player's recently dealt damage.


### GetCritCost( tokenBucket:number, critSeedRequestCount:number, critCheckCount:number )


Calculates the cost of a crit based on the given crit parameters. You can either use the GetCritTokenBucket(), GetCritCheckCount(), and GetCritSeedRequestCount() methods to get the current crit parameters, or you can pass your own if you are simulating crits.


### CalcObservedCritChance()


This function estimates the observed crit chance. The observed crit chance is calculated on the server from the damage you deal across a game round. It is only rarely sent to the client, but is important for crit calculations.


### IsAttackCritical( commandNumber:integer )


Returns whether the given command number would result in a crit.


### GetWeaponDamageStats()


Returns the current damage stats as a following table:





Type
Damage




`total`
1234


`critical`
250


`melee`
90



## Examples


Calculate needed crit hack damage```
local myfont = draw.CreateFont( "Verdana", 16, 800 )

callbacks.Register( "Draw", function ()
    draw.Color(255, 255, 255, 255)
    draw.SetFont( myfont )

    local player = entities.GetLocalPlayer()
    local wpn = player:GetPropEntity("m_hActiveWeapon")

    if wpn ~= nil then
        local critChance = wpn:GetCritChance()
        local dmgStats = wpn:GetWeaponDamageStats()
        local totalDmg = dmgStats["total"]
        local criticalDmg = dmgStats["critical"]

        -- (the + 0.1 is always added to the comparsion)
        local cmpCritChance = critChance + 0.1

        -- If we are allowed to crit
        if cmpCritChance > wpn:CalcObservedCritChance() then
            draw.Text( 200, 510, "We can crit just fine!")
        else --Figure out how much damage we need
            local requiredTotalDamage = (criticalDmg * (2.0 * cmpCritChance + 1.0)) / cmpCritChance / 3.0
            local requiredDamage = requiredTotalDamage - totalDmg

            draw.Text( 200, 510, "Damage needed to crit: " .. math.floor(requiredDamage))
        end
    end
end )

```

Basic player ESP```
local myfont = draw.CreateFont( "Verdana", 16, 800 )

local function doDraw()
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then
        return
    end

    local players = entities.FindByClass("CTFPlayer")

    for i, p in ipairs( players ) do
        if p:IsAlive() and not p:IsDormant() then

            local screenPos = client.WorldToScreen( p:GetAbsOrigin() )
            if screenPos ~= nil then
                draw.SetFont( myfont )
                draw.Color( 255, 255, 255, 255 )
                draw.Text( screenPos[1], screenPos[2], p:GetName() )
            end
        end
    end
end

callbacks.Register("Draw", "mydraw", doDraw) 

```

Draw local player hitboxes```
callbacks.Register( "Draw", function ()
    local player = entities.GetLocalPlayer()
    local hitboxes = player:GetHitboxes()

    for i = 1, #hitboxes do
        local hitbox = hitboxes[i]
        local min = hitbox[1]
        local max = hitbox[2]

        -- to screen space
        min = client.WorldToScreen( min )
        max = client.WorldToScreen( max )

        if (min ~= nil and max ~= nil) then
            -- draw hitbox
            draw.Color(255, 255, 255, 255)
            draw.Line( min[1], min[2], max[1], min[2] )
            draw.Line( max[1], min[2], max[1], max[2] )
            draw.Line( max[1], max[2], min[1], max[2] )
            draw.Line( min[1], max[2], min[1], min[2] )
        end
    end
end )

```

Clip size attribute on player```
local me = entities.GetLocalPlayer()

local myClipSizeMultiplier = me:AttributeHookFloat( "mult_clipsize" )

```

Clip size attribute on weapon```
local me = entities.GetLocalPlayer()

local primaryWeapon = me:GetEntityForLoadoutSlot( LOADOUT_POSITION_PRIMARY )
local weaponClipSizeMultiplier = primaryWeapon:AttributeHookFloat( "mult_clipsize" )

```

Is player taunting```
local me = entities.GetLocalPlayer()

local isTaunting = me:InCond( TFCond_Taunting )

```

Get rage meter value```
local me = entities.GetLocalPlayer()

local rageMeter = me:GetPropFloat( "m_flRageMeter" )

```

Create custom entity sentry```
local myEnt = nil

callbacks.Unregister( "CreateMove", "mycreate" )
callbacks.Register( "CreateMove", "mycreate", function( cmd )
    local pLocal = entities.GetLocalPlayer()

    if pLocal == nil then
        return
    end

    if myEnt ~= nil then
        if globals.TickCount() % 2 == 0 then
            if engine.RandomInt( 1, 100 ) > 32 then
                myEnt:SetModel( "models/buildables/sentry1.mdl" )
            elseif engine.RandomInt( 1, 100 ) > 64 then
                myEnt:SetModel( "models/buildables/sentry2.mdl" )
            else
                myEnt:SetModel( "models/buildables/sentry3.mdl" )
            end
        end

        if input.IsButtonDown( KEY_R ) then
            local source = pLocal:GetAbsOrigin() + pLocal:GetPropVector( "localdata", "m_vecViewOffset[0]" );
            local destination = source + engine.GetViewAngles():Forward() * 1000;
            local trace = engine.TraceLine( source, destination, MASK_SHOT_HULL );
            local pos = trace.endpos + Vector3( 0, 0, 10 )
            myEnt:SetAbsOrigin( pos )
            return
        end

        if input.IsButtonDown( KEY_T ) then
            myEnt:Release()
            myEnt = nil
            return
        end
    else
        myEnt = entities.CreateEntityByName( "grenade" )
        myEnt:SetModel( "models/buildables/sentry1.mdl" )
        client.ChatPrintf( "Created entity at " .. tostring( pos ) )

    end
end )

```


## EulerAngles



# EulerAngles


A class that represents a set of Euler angles.


## Constructor


### EulerAngles( pitch, yaw, roll)


Creates a new instace of EulerAngles.


## Fields


Fields are modifiable directly.


### x / pitch


number


### y / yaw


number


### z / roll


number


## Methods


### Unpack()


Returns the X, Y, and Z coordinates as a separate variables.


### Clear()


Clears the angles to 0, 0, 0


### Normalize()


Clamps the angles to standard ranges.


### Forward()


Returns the forward vector of the angles.


### Right()


Returns the right vector of the angles.


### Up()


Returns the up vector of the angles.


### Vectors()


Returns the forward, right, and up vectors as 3 return values.


## Examples


Getting view angles```
local me = entities.GetLocalPlayer()
local viewAngles = me:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")

```

Unpack example```
local myAngles = EulerAngles( 30, 60, 0 )
local pitch, yaw, roll = myAngles:Unpack()

```


## GameEvent



# GameEvent


Represents a game event that was sent from the server. For a list of game events for Source games and TF2 see the GameEvent List.


## Methods


### GetName()


Returns the name of the event.


### GetString( fieldName:string )


Returns the string value of the given field.


### GetInt( fieldName:string )


Returns the int value of the given field.


### GetFloat( fieldName:string )


Returns the float value of the given field.


### SetString( fieldName:string, value:string )


Sets the string value of the given field.


### SetInt( fieldName:string, value:int )


Sets the int value of the given field.


### SetFloat( fieldName:string, value:float )


Sets the float value of the given field.


### SetBool( fieldName:string, value:bool )


Sets the bool value of the given field.


## Examples


Damage logger - by @RC```
local function damageLogger(event)

    if (event:GetName() == 'player_hurt' ) then

        local localPlayer = entities.GetLocalPlayer();
        local victim = entities.GetByUserID(event:GetInt("userid"))
        local health = event:GetInt("health")
        local attacker = entities.GetByUserID(event:GetInt("attacker"))
        local damage = event:GetInt("damageamount")

        if (attacker == nil or localPlayer:GetIndex() ~= attacker:GetIndex()) then
            return
        end

        print("You hit " ..  victim:GetName() .. " or ID " .. victim:GetIndex() .. " for " .. damage .. "HP they now have " .. health .. "HP left")
    end

end

callbacks.Register("FireGameEvent", "exampledamageLogger", damageLogger)
-- Made by @RC: https://github.com/racistcop/lmaobox-luas/blob/main/example-damagelogger.lua

```


## GameServerLobby



# GameServerLobby


The GameServerLobby library provides information about the current match made game.


## Methods


### GetGroupID()


Returns the group ID of the current lobby.


### GetMembers()


Returns a table of LobbyPlayer objects representing the players in the lobby.


## Examples


Print the steam IDs of all players in the lobby```
local lobby = gamecoordinator.GetGameServerLobby()

if lobby then
    for _, player in pairs( lobby:GetMembers() ) do
        print( player:GetSteamID() )
    end
end

```


## Item



# Item


Represents an item in player's inventory.


## Methods


### IsValid()


Returns true if the item is valid. There are instances where an item in the inventory is not valid and you should account for them. Otherwise, methods will return nil.


### GetName()


Returns the name of the item. This is the name that is displayed in the inventory and can be custom.


### GetDefIndex()


Returns the item's definition index. Can be used to get the item's definition.


### GetItemDefinition()


Returns the item's definition as the ItemDefinition object.


### GetLevel()


Returns the item's level.


### GetItemID()


Returns the item's ID. This is a unique 64bit ID for the item that identifies it across the economy.


### GetInventoryPosition()


Returns the item's position in the inventory.


### IsEquippedForClass( classid:integer )


Returns true if the item is equipped for the given class.


### GetImageTextureID()


Returns the item's backpack image texture ID. Some items may not have it, in which case, result is -1.


### GetAttributes()


Returns the item's attributes as a table where keys are AttributeDefinition objects and values are the values of the attributes.


### SetAttribute( attrDef:AttributeDefinition, value:any )


Sets the value of the given attribute by it's definition. The value must be the correct type for the given attribute definition.


### SetAttribute( attrName:string, value:any )


Sets the value of the given attribute by it's name. The value must be the correct type for the given attribute definition.


### RemoveAttribute( attrDef:AttributeDefinition )


Removes the given attribute by it's definition.


### RemoveAttribute( attrName:string )


Removes the given attribute by it's name.


## Examples


Set unusual effect and name of item```
local nameAttr = itemschema.GetAttributeDefinitionByName( "custom name attr" )

local firstItem = inventory.GetItemByPosition( 1 )

firstItem:SetAttribute( "attach particle effect", 33 ) -- Set the unusual effect to rotating flames
firstItem:SetAttribute( nameAttr, "Dumb dumb item" ) -- Set the custom name to "Dumb dumb item"

```

Print all attributes of an item```
local item = inventory.GetItemByPosition( 1 )

for def, v in pairs( item:GetAttributes() ) do
    print( def:GetName() .. " : " .. tostring( v ) )
end

```


## ItemDefinition



# ItemDefinition


The ItemDefinition object contains static information about an item. Static information refers to information that is not changed during the course of the game.


## Methods


### GetName()


Returns the name of the item.


### GetID()


Returns the definition ID of the item.


### GetClass()


Returns the class of the item.


### GetLoadoutSlot()


Returns the loadout slot that the item should be placed in.


### IsHidden()


Returns true if the item is hidden.


### IsTool()


Returns true if the item is a tool, such as a key.


### IsBaseItem()


Returns true if the item is a base item, such as a stock weapon.


### IsWearable()


Returns true if the item is a wearable.


### GetNameTranslated()


Returns the name of the item in the language of the current player.


### GetTypeName()


Returns the type name of the item.


### GetDescription()


Returns the description of the item.


### GetIconName()


Returns the icon name of the item.


### GetBaseItemName()


Returns the base item name of the item.


### GetAttributes()


Returns the static item attributes as a table where keys are AttributeDefinition objects and values are the values of the attributes.


## Examples


Get the name of active weapon```
local me = entities.GetLocalPlayer()
local activeWeapon = me:GetPropEntity( "m_hActiveWeapon" )

if activeWeapon ~= nil then
    local itemDefinitionIndex = activeWeapon:GetPropInt( "m_iItemDefinitionIndex" )
    local itemDefinition = itemschema.GetItemDefinitionByID( itemDefinitionIndex )
    local weaponName = itemDefinition:GetName()
    print( weaponName )
end

```

Print all static active weapon attributes```
local me = entities.GetLocalPlayer()
local activeWeapon = me:GetPropEntity( "m_hActiveWeapon" )
local itemDef = itemschema.GetItemDefinitionByID( activeWeapon:GetPropInt( "m_iItemDefinitionIndex" ) )
local attributes = itemDef:GetAttributes()

for attrDef, value in pairs( attributes ) do
    print( attrDef:GetName() .. ": " .. tostring( value ) )
end

```


## LobbyPlayer



# LobbyPlayer


The LobbyPlayer class is used to provide information about a player in a Game Server lobby.


## Methods


### GetSteamID()


Returns the SteamID of the player as a string.


### GetTeam()


Returns the GC assigned team of the player.


### GetPlayerType()


Returns the GC assigned player type of this player.


### GetName()


Returns the steam name of the player.


### GetLastConnectTime()


Returns the last time the player connected to the server as a unix timestamp.


### GetNormalizedRating()


Returns the normalized rating of the player - a measure of the player's skill?


### GetNormalizedUncertainty()


Returns the normalized uncertainty of the player - a measure of how confident the GC is in the player's rating.


### GetRank()


Returns the rank of the player. Integer representing the player's rank.


### IsChatSuspended()


Returns true if the player is chat suspended.


## Examples


Print the steam IDs and teams of all players in a found lobby```
callbacks.Register( "OnLobbyUpdated", "mylobby", function( lobby )
    for _, player in pairs( lobby:GetMembers() ) do
        print( player:GetSteamID(), player:GetTeam() )
    end
end )

```


## MatchGroup



# MatchGroup


The MatchGroup object describes a single type of queue in TF2 matchmaking.


## Methods


### GetID()


Returns the ID of the match group.


### GetName()


Returns the name of the match group.


### IsCompetitiveMode()


Returns whether the match group is a competitive mode. Can return false if you are using a competitive bypass feature.



## MatchMapDefinition



# MatchMapDefinition


Represents a map that is playable in a matchmaking match.


## Methods


### GetName()


Returns the name of the map.


### GetID()


Returns the ID of the map.


### GetNameLocKey()


Returns the map name localization key.



## Material



# Material


Represents a material in source engine. For more information about materials see the Material page.


## Methods


### GetName()


Returns the material name


### GetTextureGroupName


Returns group the material is part of


### AlphaModulate( alpha:number )


Modulate transparency of material by given alpha value


### ColorModulate( red:number, green:number, blue:number )


Modulate color of material by given RGB values


### SetMaterialVarFlag( flag:integer, set:bool )


Change a material variable flag, see MaterialVarFlags for a list of flags.
The flag is the integer value of the flag enum, not the string name.


### SetShaderParam( param:string, value:any )


Set a shader parameter, see ShaderParameters for a list of parameters.
Supported values are integer, number, Vector3, string.


## Examples


Create a material, and change ignorez to false```
kv = [["VertexLitGeneric"
{
    "$basetexture"  "vgui/white_additive"
    "$ignorez" "1"
}
]]

myMaterial = materials.Create( "myMaterial", kv )
myMaterial:SetMaterialVarFlag( MATERIAL_VAR_IGNOREZ, false )

```


## Model



# Model


The Model object represents a 3D model, such as a player, a health pack, etc. It doesnt contain any information in an of itself, but you can get more information about a model via the models library.



## NetChannel



# NetChannel


The NetChannel object is used to get information about the network channel.


## Methods


### GetName()


Returns the name of the channel.


### GetAddress()


Returns the IP address of the server.


### GetConnectTime()


Returns the time the client connected to the server.


### GetTimeSinceLastReceived()


Returns the time since the last tick was received.


### GetLatency( flow:integer )


Returns the latency of the specified flow. Use E_Flows contants.


### GetAvgLatency( flow:integer )


Returns the average latency of the specified flow. Use E_Flows contants.


### GetAvgChoke( flow:integer )


Returns the average choke of the specified flow. Use E_Flows contants.


### GetAvgLoss( flow:integer )


Returns the average loss of the specified flow. Use E_Flows contants.


### GetAvgData( flow:integer )


Returns the average data of the specified flow. Use E_Flows contants.


### GetTime()


Returns the current net time.


### GetTimeConnected()


Returns the time when channel connected to the server.


### GetBufferSize()


Returns the size of the buffer.


### GetDataRate()


Returns the current data rate.


### IsLoopback()


Returns true if the channel is loopback.


### IsTimingOut()


Returns true if the channel is timing out.


### IsPlayback()


Returns true if the channel is a demo playback.


### SetDataRate( rate:number )


Sets the data rate.


### SetTimeout( seconds:number )


Sets the channel timeout time.


### SetChallengeNr( challenge:number )


Sets the challenge number.


### SendNetMsg( msg:NetMessage, forceReliable:boolean, voice:boolean )


Sends a network message, msg is of type NetMessage.


### SendData( data:BitBuffer, reliable:boolean )


Sends data, data is of type BitBuffer.


### GetSequenceData()


Gets the sequence data. Returns 3 values: outSequenceNr, inSequenceNr, outSequenceNrAck.


### SetSequenceData( outSequenceNr:integer, inSequenceNr:integer, outSequenceNrAck:integer )


Sets the sequence data.


### SetInterpolationAmount( interp:number )


Sets the interpolation amount.


### GetChallengeNr()


Returns the challenge number.


## Examples


Set sequence data to +1```
local netChannel = clientstate.GetNetChannel()

if netChannel then
    local outSequenceNr, inSequenceNr, outSequenceNrAck = netChannel:GetSequenceData()
    netChannel:SetSequenceData(outSequenceNr + 1, inSequenceNr, outSequenceNrAck)
end

```


## NetMessage



# NetMessage


The NetMessage class represents a network message. It is used to read and write data to the network stream.


## Methods


### GetGroup()


Returns the message group.


### GetNetChannel()


Returns the NetChannel object that the message belongs to.


### IsReliable()


Returns true if the message is reliable.


### SetReliable( reliable:boolean )


Sets the message to be reliable or unreliable.


### GetType()


Returns the message type.


### GetName()


Returns the message name.


### ToString()


Returns the message as a human readable string with the contents of the message.


### WriteToBitBuffer( bitBuffer:BitBuffer )


Writes the message content to a BitBuffer, useful for reading its variables via the bit buffer. Make sure that current bit position is correct and that you do not overflow the buffer.


### ReadFromBitBuffer( bitBuffer:BitBuffer )


Reads the message content from a BitBuffer and applies it to the message. If done in SendNetMsg callback, the sent message will be changed. Make sure that current bit position is correct.


## Examples


Read & Write a net_tick message```
-- Create a new bitbuffer
local bf = BitBuffer()

callbacks.Register( "SendNetMsg", function( msg, reliable, voice )

  if msg:GetType() == 3 then -- net_tick
    bf:Reset()
    msg:WriteToBitBuffer(bf)

    bf:SetCurBit(0)
    local type = bf:ReadInt(6) -- 6 bits of NETMSG_TYPE_BITS
    local tick = bf:ReadInt(32)

    print("tick: " .. tick .. " type: " .. type)

    -- Write a new tick if we want (but dotn do it, you will get kicked)
    bf:SetCurBit(0)
    bf:WriteInt( tick, 32 ) 
    bf:SetCurBit(0)

    -- Write the new tick to the message
    msg:ReadFromBitBuffer(bf)

    print("msg: " .. msg:ToString()) -- See the result
  end

  return true
end )

callbacks.Register("Unload", function()
  bf:Delete() -- delete the bitbuffer
end)

```


## PartyMemberActivity



# PartyMemberActivity


The PartyMemberActivity class is used to provide information about a party member.


## Methods


### GetLobbyID()


Returns the lobby ID of the party member. This can be used to find out whether the party member is currently in a matchmade game.


### IsOnline()


Returns whether the party member is currently online.


### IsMultiqueueBlocked()


Returns whether the party member is currently blocked from joining a matchmade game.


### GetClientVersion()


Returns the client version of the party member.



## PhysicsCollisionModel



# PhysicsCollisionModel


Represents a collision model for a physics object.


## Methods


### GetMassCenter()


Returns the mass center of the collision model as a Vector3.



## PhysicsEnvironment



# PhysicsEnvironment


PhysicsEnvironment is a class that represents a physics environment. It has its own gravity, air resistance, and collision rules. It contains physics objects that can be simulated in time.


## Methods


### SetGravity( gravity:Vector3 )


Sets the gravity of the physics environment.


### GetGravity()


Returns the gravity of the physics environment as a Vector3.


### SetAirDensity( airDensity:float )


Sets the air density of the physics environment.


### GetAirDensity()


Returns the air density of the physics environment.


### Simulate( deltaTime:float )


Simulates the physics environment in time by the given delta time.


### IsInSimulation()


Returns whether the physics environment is currently simulating.


### GetSimulationTime()


Returns the current simulation time of the physics environment.


### GetSimulationTimestep()


Returns the current simulation timestep of the physics environment.


### SetSimulationTimestep( timestep:float )


Sets the simulation timestep of the physics environment.


### GetActiveObjects()


Returns a table of all active physics objects in the physics environment, as PhysicsObject objects.


### ResetSimulationClock()


Resets the simulation clock of the physics environment.


### CreatePolyObject( collisionModel:PhysicsCollisionModel, surfacePropertyName:string, objectParams:PhysicsObjectParameters )


Creates a physics object from a collision model, surface property name, and physics object parameters. Returns a PhysicsObject object. Objects is created asleep, and must be woken up before simulation by calling PhysicsObject:Wake().


### DestroyObject( object:PhysicsObject )


Destroys a physics object.



## PhysicsObject



# PhysicsObject


PhysicsObject is a class that represents a physics object. It has a position, angle, velocity, angular velocity, and is affected by gravity and air resistance. It can be simulated in time. Other parameters include class PhysicsObjectParameters.


## Methods


### Wake()


Wakes up the physics object. It will become active in the physics environment and will be simulated in time if the physics environment is simulating.


### Sleep()


Puts the physics object to sleep. It will become inactive in the physics environment and will not be simulated.


### GetPosition()


Returns the position of the physics object as a Vector3 and the angle as a Vector3 second return value.


### SetPosition( position:Vector3, angle:Vector3, isTeleport:bool )


Sets the position and angle of the physics object. If isTeleport is true, the physics object will be teleported to the new position and angle.


### GetVelocity()


Returns the velocity of the physics object as a Vector3 and the angular velocity as a Vector3 second return value.


### SetVelocity( velocity:Vector3, angularVelocity:Vector3 )


Sets the velocity and angular velocity of the physics object.


### AddVelocity( velocity:Vector3, angularVelocity:Vector3 )


Adds the velocity and angular velocity to the physics object.


### OutputDebugInfo()


Outputs debug information about the physics object to the console.



## PhysicsObjectParameters



# PhysicsObjectParameters


This is a class that contains parameters for a physics object. You can use this to set the mass, drag, and other parameters of a physics object.


## Fields


### mass


number 


The mass of the physics object.


### inertia


number


The inertia of the physics object.


### damping


number


The damping of the physics object.


### rotdamping


number


The rotational damping of the physics object.


### rotInertiaLimit


number


The rotational inertia limit of the physics object.


### volume


number


The volume of the physics object.


### dragCoefficient


number


The drag coefficient of the physics object.


### enableCollisions


boolean


Whether or not the physics object should collide with other physics objects.



## PhysicsSolid



# PhysicsSolid


PhysicsSolid is a class that represents a solid of a given model. It is used to create a physics object.


## Methods


### GetName()


Returns the name of the solid.


### GetSurfacePropName()


Returns the surface property name of the solid.


### GetObjectParameters()


Returns the PhysicsObjectParameters object of the solid.



## StaticPropRenderInfo



# StaticPropRenderInfo


Represents the context of a static prop being drawn.


## Methods


### ForcedMaterialOverride( mat:Material )


Replace material used to draw the models. Material can be found or created via materials. API


### DrawExtraPass()


Redraws the models. Can be used to achieve various effects with different materials.


### StudioSetColorModulation( color:Color )


Sets the color modulation of the models via StudioRender.


### StudioSetAlphaModulation( alpha:number )


Sets the alpha modulation of the models via StudioRender.


## Examples


Draw all player models using AmmoBox material```
local ammoboxMaterial = materials.Find( "models/items/ammo_box2" )

local function onStaticProps( info )

    info:StudioSetColorModulation( 0.5, 0, 0 )
    info:StudioSetAlphaModulation( 0.7 )
    info:ForcedMaterialOverride( ammoboxMaterial )

end

callbacks.Register("DrawStaticProps", "hook123", onStaticProps) 

```


## StringCmd



# StringCmd


Represents a string command.


## Methods


### Get()


Used to get the command string itself.


### Set( string:command )


Set the command string.


## Examples


Prevent user from using 'status'```
local function onStringCmd( stringCmd )

    if stringCmd:Get() == "status" then
        stringCmd:Set( "echo No status for you!" )
    end
end

callbacks.Register( "SendStringCmd", "hook", onStringCmd )

```


## StudioBBox



# StudioBBox


The StudioBBox object contains information about a studio models bounding box.


## Methods


### GetName()


Returns the name of the bounding box.


### GetBone()


Returns the bone index of the bounding box. This is useful to index the bone matrix to properly transform the bounding box.


### GetGroup()


Returns the group index of the bounding box.


### GetBBMin()


Returns the minimum point of the bounding box as a Vector3.


### GetBBMax()


Returns the maximum point of the bounding box as a Vector3.


## Examples



## StudioHitboxSet



# StudioHitboxSet


The StudioHitboxSet object contains information about a studio models hitboxes.


## Methods


### GetName()


Returns the name of the hitbox set.


### GetHitboxes()


Returns a table of StudioBBox objects for the hitbox set.


## Examples



## StudioModelHeader



# StudioModelHeader


The StudioModelHeader object contains information about a studio models hitbox sets and bones.


## Methods


### GetName()


Returns the name of the model.


### GetHitboxSet( index:integer )


Returns a StudioHitboxSet object by the entities hitbox set index. This can be retrieved from m_nHitBoxSet netvar.


### GetAllHitboxSets()


Returns a table of all StudioHitboxSet objects for the model.


## Examples


Enumerate all hitboxes```


```


## Texture



# Texture


The Texture object is used to interact with textures loaded from files or created dynamically.


## Methods


### GetName()


Returns the name of the texture.


### GetActualHeight()


Returns the actual height of the texture in pixels.


### GetActualWidth()


Returns the actual width of the texture in pixels.



## Trace



# Trace


Return value of engine.TraceLine and engine.TraceHull funcs


## Fields


Fields are non-modifiable.


### fraction


number


Fraction of the trace that was completed.


### entity


Entity


The entity that was hit.


### plane


Vector3


Plane normal of the surface hit.


### contents


integer


Contents of the surface hit.


### hitbox


integer


Hitbox that was hit.


### hitgroup


integer


Hitgroup that was hit.


### allsolid


boolean


Whether the trace completed in all solid.


### startsolid


boolean


Whether the trace started in a solid.


### startpos


Vector3


The start position of the trace.


### endpos


Vector3


The end position of the trace.


## Extra


More information can be found at  Valve Wiki


## Examples


What am I looking at?```
local me = entities.GetLocalPlayer();
local source = me:GetAbsOrigin() + me:GetPropVector( "localdata", "m_vecViewOffset[0]" );
local destination = source + engine.GetViewAngles():Forward() * 1000;

local trace = engine.TraceLine( source, destination, MASK_SHOT_HULL );

if (trace.entity ~= nil) then
    print( "I am looking at " .. trace.entity:GetClass() );
    print( "Distance to entity: " .. trace.fraction * 1000 );
end

```


## UserCmd



# UserCmd


Represents a user (movement) command about to be sent to the server. For more in depth insight see the UserCmd page.


## Fields


Fields are modifiable directly.


### command_number


integer


The number of the command.


### tick_count


integer


The current tick count.


### viewangles


EulerAngles


The view angles of the player.


### forwardmove


number


The forward movement of the player.


### sidemove


number


The sideways movement of the player.


### upmove


number


The upward movement of the player.


### buttons


integer (bits)


The buttons that are pressed. Masked with bits from IN_* enum


### impulse


integer


The impulse command that was issued.


### weaponselect


integer


The weapon id that is selected.


### weaponsubtype


integer


The subtype of the weapon.


### random_seed


integer


The random seed of the command.


### mousedx


integer


The mouse delta in the x direction.


### mousedy


integer


The mouse delta in the y direction.


### hasbeenpredicted


boolean


Whether the command has been predicted.


### sendpacket


boolean


Whether the command should be sent to the server or choked.


## Methods


### SetViewAngles( pitch, yaw, roll )


Sets the view angles of the player.


### GetViewAngles()


returns: pitch, yaw, roll


### SetSendPacket( sendpacket )


Sets whether the command should be sent to the server or choked.


### GetSendPacket()


returns: sendpacket


### SetButtons( buttons )


Sets the buttons that are pressed.


### GetButtons()


returns: buttons


### SetForwardMove( float factor )


Sets the forward movement of the player.


### GetForwardMove()


returns: forwardmove


### SetSideMove( float factor )


Sets the sideways movement of the player.


### GetSideMove()


returns: sidemove


### SetUpMove( float factor )


Sets the upward movement of the player.


### GetUpMove()


returns: upmove


## Examples


Simple Bunny hop```
local function doBunnyHop( cmd )
    local player = entities.GetLocalPlayer( );

    if (player ~= nil or not player:IsAlive()) then
    end

    if input.IsButtonDown( KEY_SPACE ) then

        local flags = player:GetPropInt( "m_fFlags" );

        if flags & FL_ONGROUND == 1 then
            cmd:SetButtons(cmd.buttons | IN_JUMP)
        else 
            cmd:SetButtons(cmd.buttons & (~IN_JUMP))
        end
    end
end

callbacks.Register("CreateMove", "myBhop", doBunnyHop)

```


## UserMessage



# UserMessage


Received as the only argument in DispatchUserMessage callback.


## Reading


Reading starts at the beginning of the message (curBit = 0). Each call to Read*() advances the read cursor by the number of bits read. Reading past the end of the message will cause an error.


### GetID()


Returns the ID of the message. You can get the list here: TF2 User Messages.


### GetBitBuffer()


Returns the BitBuffer object that contains the message data.


## Example


Print chat messages from players```
local function myCoolMessageHook(msg)

    if msg:GetID() == SayText2 then 
        local bf = msg:GetBitBuffer()

        bf:SetCurBit(8)-- skip 1 byte of not useful data

        local chatType = bf:ReadString(256)
        local playerName = bf:ReadString(256)
        local message = bf:ReadString(256)

        print("Player " .. playerName .. " said " .. message)
    end

end

callbacks.Register("DispatchUserMessage", myCoolMessageHook)

```


## ViewSetup



# ViewSetup


The ViewSetup object is used to get information about the the origin, angles, fov, zNear, zFar, and aspect ratio of the player's view.


## Fields


Fields are modifiable directly.


### x


integer


Left side of view window


### unscaledX


integer


Left side of view window without HUD scaling


### y


integer


Top side of view window


### unscaledY


integer


Top side of view window without HUD scaling


### width


integer


Width of view window


### unscaledWidth


integer


Width of view window without HUD scaling


### height


integer


Height of view window


### unscaledHeight


integer


Height of view window without HUD scaling


### ortho


bool


Whether the view is orthographic


### orthoLeft


number


Left side of orthographic view


### orthoTop


number


Top side of orthographic view


### orthoRight


number


Right side of orthographic view


### orthoBottom


number


Bottom side of orthographic view


### fov


number


Field of view


### fovViewmodel


number


Field of view of the viewmodel


### origin


Vector3


Origin of the view


### angles


EulerAngles


Angles of the view


### zNear


number


Near clipping plane


### zFar


number


Far clipping plane


### aspectRatio


number


Aspect ratio of the view


## Examples


Print the player's view origin```
local view = client.GetViewSetup()
print( "View origin: " .. view.origin )

```


## WeaponData



# WeaponData


Contains variables related to specifications of a weapon, such as firing speed, number of projectiles, etc.
Some of them may not be used, or may be wrong.


## Fields


Fields are read only


### damage


integer


### bulletsPerShot


integer


### range


number


### spread


number


### punchAngle


number


### timeFireDelay


number


### timeIdle


number


### timeIdleEmpty


number


### timeReloadStart


number


### timeReload


number


### drawCrosshair


number


### projectile


integer


Represents projectile id


### ammoPerShot


integer


### projectileSpeed


number


### smackDelay


number


### useRapidFireCrits


boolean


## Examples


Example usage```
local function onCreateMove( cmd )
    local me = entities.GetLocalPlayer()
    if (me ~= nil) then
        local wpn = me:GetPropEntity( "m_hActiveWeapon" )
        if (wpn  ~= nil) then
            local wdt = wpn:GetWeaponData()
            print( "timeReload: " .. tostring(wdt.timeReload) )
        end
    end
end

callbacks.Register("CreateMove", onCreateMove)

```


## Vector3



# Vector3


Represents a point in 3D space. X and Y are the horizontal coordinates, Z is the vertical coordinate.


## Constructor


## Vector3( x, y, z )


## Fields


Fields are modifiable directly.


### x


number


The X coordinate.


### y


number


The Y coordinate.


### z


number


The Z coordinate.


## Methods


### Unpack()


Returns the X, Y, and Z coordinates as a separate variables.


### Length()


The length of the vector.


### LengthSqr()


The squared length of the vector.


### Length2D()


The length of the vector in 2D.


### Length2DSqr()


The squared length of the vector in 2D.


### Dot( Vector3 )


The dot product of the vector and the given vector.


### Cross( Vector3 )


The cross product of the vector and the given vector.


### Clear()


Clears the vector to 0,0,0


### Normalize()


Normalizes the vector.


### Right()


Returns the right vector of the vector.


### Up()


Returns the up vector of the vector.


### Angles()


Returns the angles of the vector.


### Vectors()


Returns the forward, right, and up vectors as 3 return values.


## Examples


Unpack example```
local myVector = Vector3( 1, 2, 3 )
local x, y, z = myVector:Unpack()

```

Length example```
local myVector = Vector3( 1, 2, 3 )
local length = myVector:Length()

```


## aimbot



# aimbot


This library can be used for interacting with aimbot feature.


## Functions


### GetAimbotTarget()


Returns index of the player or entity aimbot is currenly targetting


## Examples


```
local targetID = aimbot.GetAimbotTarget()
local target = entities.GetByIndex(targetID)

```


## callbacks



# callbacks


## Functions


Callbacks are functions that are called when a certain event occurs. Yiu can use them to add custom functionality to your scripts. To see the list of available callbacks, see the callbacks page.


### Register( id, function )


Registers a callback function to be called when the event with the given id occurs.


### Register( id, unique, function )


Registers a callback function to be called when the event with the given id occurs. If the callback function is already registered, it will not be registered again.


### Unregister( id, unique )


Unregisters a callback function from the event with the given id.


## Examples



## client



# client


The client library is used to get information about the client.


## Functions


### GetExtraInventorySlots()


Returns the number of extra inventory slots the user has.


### IsFreeTrialAccount()


Returns whether the user is a free trial account.


### HasCompetitiveAccess()


Returns whether the user has competitive access.


### IsInCoachesList()


Returns whether the user is in the coaches list.


### WorldToScreen( worldPos:Vector3, [view:ViewSetup] )


Translate world position into screen position (x,y). view is optional, and of type ViewSetup


### Command( command:string, unrestrict:bool )


Run command in game console


### ChatSay( msg:string )


Say text on chat


### ChatTeamSay( msg:string )


Say text on team chat


### AllowListener( eventName:string )


DOES NOTHING. All events are allowed by default. This function is deprecated and it's only there to not cause errors in existing scripts.


### GetPlayerNameByIndex( index:integer )


Return player name by index


### GetPlayerNameByUserID( userID:integer )


Return player name by user id


### GetPlayerInfo( index:integer )


Returns the following table:





Variable
Value




`Name`
playername


`UserID`
number


`SteamID`
STEAM_0:?:?


`IsBot`
true/false


`IsHLTV`
true/false



### GetPlayerView()


Returns the players view setup. See ViewSetup for more information.


### GetLocalPlayerIndex()


Return local player index


### GetConVar( name:string )


Get game convar value. Returns integer, number and string if found. Returns nil if not found.


### SetConVar( name:string, value:any )


Set game convar value. Value can be integer, number, string.


### RemoveConVarProtection( name:string )


Remove convar protection. This is needed for convars that are not allowed to be changed by the server.


### ChatPrintf( msg:string )


Print text on chat, this text can be colored. Color codes are:


- \x01 - White color
- \x02 - Old color
- \x03 - Player name color
- \x04 - Location color
- \x05 - Achievement color
- \x06 - Black color
- \x07 - Custom color, read from next 6 characters as HEX
- \x08 - Custom color with alpha, read from next 8 characters as HEX

### Localize ( key:string )


Returns a localized string. The localizable strings usually start with a # character, but there are exceptions. Will return nil on failure.


## Examples


Print colored chat message```
if client.ChatPrintf( "\x06[\x07FF1122LmaoBox\x06] \x04You died!" ) then
    print( "Chat message sent" )
end

```

Get player name```
local me = entities.GetLocalPlayer()
local name = entities.GetPlayerNameByIndex(me:GetIndex())
print( name )

```

Get player steam id```
local me = entities.GetLocalPlayer()
local playerInfo = entities.GetPlayerInfo(me:GetIndex())
local steamID = playerInfo.SteamID
print( steamID )

```


## clientstate



# clientstate


The clientstate library is used to get information about the internal client state.


## Functions


### ForceFullUpdate()


Requests a full update from the server. This can lag the game a bit and should be used sparingly. It can even cause the game to crash if used incorrectly.


### GetClientSignonState()


Returns the current client signon state. This is useful for determining if the client is fully connected to the server.


### GetDeltaTick()


Returns the tick number of the last received tick.


### GetLastOutgoingCommand()


Returns the last outgoing command number.


### GetChokedCommands()


Returns the number of commands the client is currently choking.


### GetLastCommandAck()


Returns the last command acknowledged by the server.


### GetNetChannel()


Returns the NetChannel object. This can be nil if the client is not connected to a server. NetChannel first spawns when a "client_connected" event is fired.


## Examples


Print the server's IP address```
local netChannel = clientstate.GetNetChannel()

if netChannel then
    print(netChannel:GetAddress())
end

```


## draw



# draw


This library allows you to draw shapes and text on the screen. It also allows you to create textures from images and draw them.


## Functions


### Color( r, g, b, a )


Set color for drawing shapes and texts


### Line( x1, y1, x2, y2 )


Draw line from x1, y1 to x2, y2


### FilledRect( x1, y1, x2, y2 )


Draw filled rectangle with top left point at x1, y1 and bottom right point at x2, y2


### OutlinedRect( x1, y1, x2, y2 )


Draw outlined rectangle with top left point at x1, y1 and bottom right point at x2, y2


### FilledRectFade(x1:integer, y1:integer, x2:integer, y2:integer, alpha1:integer, alpha2:integer, horizontal:bool)


Draw a rectangle with a fade. The fade is horizontal by default, but can be vertical by setting horizontal to false. The alpha values are between 0 and 255.


### FilledRectFastFade(x1:integer, y1:integer, x2:integer, y2:integer, fadeStartPt:integer, fadeEndPt:integer, alpha1:integer, alpha2:integer, horizontal:bool)


Draws a fade between the fadeStartPt and fadeEndPT points. The fade is horizontal by default, but can be vertical by setting horizontal to false. The alpha values are between 0 and 255.


### ColoredCircle( centerx:integer, centery:integer, radius:number, r:integer, g:integer, b:integer, a:integer )


Draw a colored circle with center at centerx, centery and radius radius. The color is specified by r, g, b, a.


### OutlinedCircle( x:integer, y:integer, radius:number, segments:integer )


Draw an outlined circle with center at centerx, centery and radius radius. The circle is made up of segments number of lines.


### GetTextSize( string )


returns: width, height
Get text size with current font


### Text( x:integer, y:integer, text:string )


Draw text at x, y


### TextShadow( x:integer, y:integer, text:string )


Draw text with shadow at x, y


### GetScreenSize()


returns: width, height
Get game resolution settings


### CreateFont( name:string, height:integer, weight:integer, [fontFlags:integer] )


Create font by name. Font flags are optional and can be combined with bitwise OR. Default font flags are FONTFLAG_CUSTOM | FONTFLAG_ANTIALIAS


### AddFontResource( pathTTF:string )


Add font resource by path to ttf file, relative to Team Fortress 2 folder


### SetFont( font:integer )


Set current font for drawing. To be used with DrawText


## Textures


When creating textures, you should make sure each size is a valid power of 2. Otherwise, the texture will be scaled to the nearest larger power of 2 and look weird.


### CreateTexture( imagePath:string )


Create texture from image on the given path. Path is relative to %localappdata%.. But you can also specify an absolute path if you wish. Returns texture id for the newly created texture. Supported image extensions: PNG, JPG, BMP, TGA, VTF


### CreateTextureRGBA( rgbaBinaryData:string, width:integer, height:integer )


Create texture from raw rgba data in the format RGBA8888 (one byte per color). In this format you must specify the valid width and height of the texture. Returns texture id for the newly created texture.


### GetTextureSize( textureId:integer )


Returns: width, height of the texture as integers


### TexturedRect( textureId:integer, x1:integer, y1:integer, x2:integer, y2:integer)


Draw the texture by textureId as a rectangle with top left point at x1, y1 and bottom right point at x2, y2.


### TexturedPolygon( textureId:integer, vertices:table, clipVertices:bool )


Draw the texture by textureId as a polygon. The vertices table should be a list of tables, each containing 4 values: x,y of the vertex, and u,v of the tex coordinate. Example vertex = { 0,0,0.1,0.5 }. clipVertices decides whether the resulting polygon should be clipped to the screen or not. If unsure how to add vertices, refer to an example below


### DeleteTexture( textureId:integer )


Delete texture by textureId from memory. You should do this when unloading your script.


## Examples


Draw an image```
local lmaoboxTexture = draw.CreateTexture( "lmaobox.png" ) -- in %localappdata% folder

callbacks.Register("Draw", function()
    local w, h = draw.GetScreenSize()
    local tw, th = draw.GetTextureSize( lmaoboxTexture )

    draw.TexturedRect( lmaoboxTexture, w/2 - tw/2, h/2 - th/2, w/2 + tw/2, h/2 + th/2 )
end)

```

Draw an image but really skewed using polygon```
local lmaoboxTexture = draw.CreateTexture( "lmaobox.png" ) -- in %localappdata% folder

callbacks.Register("Draw", function()
    local w, h = draw.GetScreenSize()
    local tw, th = draw.GetTextureSize( lmaoboxTexture )

    draw. TexturedPolygon( lmaoboxTexture, {
        { w/2 - tw/2, h/2 - th/2, 0.0, 0.0 },
        { w/2 + tw/2, h/2 - th/2, 1.0, 0.1 },
        { w/2 + tw/2, h/2 + th/2, 1.0, 1.0 },
        { w/2 - tw/2, h/2 + th/2, 0.0, 1.0 },
    }, true )
end)

```

Add font resource```
draw.AddFontResource("Choktoff.ttf") -- In Team Fortress 2 folder
local myfont = draw.CreateFont("Choktoff", 15, 800, FONTFLAG_CUSTOM | FONTFLAG_ANTIALIAS)

```

Drawing a white square with lines```
local function doDraw()
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then
        return
    end

    draw.Color(255, 255, 255, 255)
    draw.Line(100, 100, 100, 200)
    draw.Line(100, 200, 200, 200)
    draw.Line(200, 200, 200, 100)
    draw.Line(200, 100, 100, 100)
end

callbacks.Register("Draw", "mydraw", doDraw)

```


## engine



# engine


The engine library provides access to the game's core functionality.


## Functions


### Con_IsVisible()


Whether the game console is visible.


### IsGameUIVisible()


Whether the game UI is visible.


### IsChatOpen()


Whether the game chat is open.


### IsTakingScreenshot()


Whether the game is taking a screenshot.


### TraceLine( src:Vector3, dst:Vector3, mask:integer, [shouldHitEntity(ent:Entity, contentsMask:integer):Function] )


Traces line from src to dst, returns Trace class.
The shouldHitEntity function is optional, and can be used to filter out entities that should not be hit. It should return true if the entity should be hit, and false otherwise.


### TraceHull( src:Vector3, dst:Vector3, mins:Vector3, maxs:Vector3, mask:integer, [shouldHitEntity(ent:Entity, contentsMask:integer):Function] )


Traces hull from src to dst, returns Trace class.
The shouldHitEntity function is optional, and can be used to filter out entities that should not be hit. It should return true if the entity should be hit, and false otherwise.


### GetPointContents( pos:Vector3 )


Returns 2 values: mask as integer and entity as Entity class.
The mask is the contents of the point in 3D space, and the entity is the entity present at the point, can be nil.


### GetMapName()


Returns map name


### GetServerIP()


Returns server ip


### GetViewAngles()


Returns player view angles


### SetViewAngles( angles:EulerAngles )


Sets player view angles


### PlaySound( soundPath:string )


Plays a sound at the given path, relative to the game's root folder


### GetGameDir()


Returns game install directory


### SendKeyValues( keyValues:string )


Sends key values to server, returns true if successful, this can be used to send very specific commands to the server. For example, buy MvM upgrades, trigger noise makers...


### Notification( title:string, [longText:string] )


Creates a notification in the TF2 client. If longText is not specified, the notification will be a simple popup with title text. If longText is specified, the notification will be a popup with title text, which will open a large window with longText as text.


### RandomSeed( seed:integer )


Sets the seed for the game's uniform random number generator.


### RandomFloat( min:number, [max:number = 1] )


Returns a random number between min and max (inclusive), using the game's uniform random number generator.


### RandomInt( min:integer, [max:integer = 0x7FFF] )


Returns a random integer between min and max (inclusive), using the game's uniform random number generator.


### RandomFloatExp( min:number, max:number, [exponent:number = 1] )


Returns a random number between min and max using the exponent, using the game's uniform random number generator.


## Examples


Trigger noise maker without using a charge```
local kv = [[
    "use_action_slot_item_server"
    {
    }
]]

engine.SendKeyValues( kv )

```

What am I looking at?```
local me = entities.GetLocalPlayer();
local source = me:GetAbsOrigin() + me:GetPropVector( "localdata", "m_vecViewOffset[0]" );
local destination = source + engine.GetViewAngles():Forward() * 1000;

local trace = engine.TraceLine( source, destination, MASK_SHOT_HULL );

if (trace.entity ~= nil) then
    print( "I am looking at " .. trace.entity:GetClass() );
    print( "Distance to entity: " .. trace.fraction * 1000 );
end

```

TraceLine with custom trace filter```
local trace = engine.TraceLine( source, destination, MASK_SHOT_HULL, function ( entity, contentsMask )
        if ( entity:GetClass() == "CTFPlayer" ) then
            return true;
        end

        print("Entity: " .. entity:GetClass() .. " is not a player")
        return false;
    end );

```


## entities



# entities


The entities library provides a way to find entities by their name, or by their class.


## Functions


### FindByClass( className:string )


Find and put into table all entities with given class name


### GetLocalPlayer()


Return local player entity


### GetByIndex( index:integer )


Return entity by index


### GetHighestEntityIndex()


Return highest entity index


### GetByUserID( userID:integer )


Return entity by user id


### GetPlayerResources()


Return player resources entity


### CreateEntityByName( className:string )


Creates a non-networkable entity by class name, returns entity. Keep in mind that YOU are responsible for its entire lifecycle and for releasing the entity later by calling entity.Release. 


## Examples


What is my name?```
local me = entities.GetLocalPlayer()
local name = me:GetName()
print( name )

```

Find all players```
local players = entities.FindByClass("CTFPlayer")

for i, player in ipairs(players) do
    print( player:GetName() )
end

```

Find all entities in the game```
for i = 1, entities.GetHighestEntityIndex() do -- index 1 is world entity
    local entity = entities.GetByIndex( i )
    if entity then
        print( i, entity:GetClass() )
    end
end

```


## filesystem



# filesystem


This library provides a simple interface to the filesystem.


## Functions


### CreateDirectory( string:path )


Creates a directory at the specified relative or absolute path. Returns true if the directory was created, false if unsuccessful. Returns the full path as second return value.


### EnumerateDirectory( string:path, function( filename:string, attributes:integer ) )


Enumerates the files and directories in the specified directory. The callback function receives the filename and attributes of each file or directory.
The path is relative  to the game directory or absolute. You are not allowed to enumerate outside of the game directory.


### GetFileTime( string:path )


Returns 3 return values: the creation time, the last access time, and the last write time of the file at the specified path.


### GetFileAttributes( string:path )


Returns the attributes of the file at the specified path.


### SetFileAttributes( string:path, integer:attributes )


Sets the attributes of the file at the specified path.


## Examples


Create a directory inside the 'Team Fortress 2' directory```
success, fullPath = filesystem.CreateDirectory( [[myContent]] )

```

Enumerate every file in the tf/ directory```
filesystem.EnumerateDirectory( [[tf/*]] , function( filename, attributes )
 print( filename, attributes )
end )

```


## gamecoordinator



# gamecoordinator


The gamecoordinator library provides information about the state of the matchmaking system and current match made game.


## Functions


### ConnectedToGC()


Returns true if the player is connected to the game coordinator.


### InEndOfMatch()


Returns true if the player is in the end of match phase.


### HasLiveMatch()


Returns true if the player is assigned to a live match.


### IsConnectedToMatchServer()


Returns true if the player is connected to the assigned match server.


### AbandonMatch()


Abandons the current match and forcefully disconnects the player from the match server.


### GetMatchAbandonStatus()


Returns the status of the match relative to the player connection.


### GetDataCenterPingData()


Returns the ping data for all available data centers in a table.
Table example:





DataCenter
Ping




`syd`
35



### GetNumMatchInvites()


Returns the number of match invites the player has.


### AcceptMatchInvites()


Accepts all match invites the player has. Usually it's just one, and they are automatically accepted after some time anyway so you can selectively accept them. Accepting an invite does not immediately join you into the match.


### JoinMatchmakingMatch()


Joins the match the player is currently assigned to from the previously acccepted match invite. This is usually called after accepting a match invite if the player wants to join the match. If not, call AbandonMatch() to leave the match.


### EnumerateQueueMapsHealth( function( MatchMapDefinition, number ) ) )


Enumerates the maps in the queue and calls the callback function for each map. The callback function receives the MatchMapDefinition and the health of the map represented as a number from 0 to 1. You must receive the GameCoordinator's map health update at least once to use this function (i.e. by queueing up).


### GetGameServerLobby()


Returns the GameServerLobby object for the current match or nil if the player is not in a match.


### GCSendMessage( typeID:integer, data:bytes)


Sends a message to the game coordinator. You can use this to send custom messages to the game coordinator. The typeID is the message type, and data is the message data. The data must be a string of protobuf encoded bytes.


## Examples


Select cp_dustbowl map and print all selected maps```
gamecoordinator.EnumerateQueueMapsHealth( function( map, health )

    if map:GetName() == "cp_dustbowl" then
        party.SetCasualMapSelected( map, true )
    end

    if party.IsCasualMapSelected( map ) then
        print( "Selected: " .. map:GetName() .. ": " .. tostring(health) )
    end

end )

```


## gamerules



# gamerules


The gamerules library contains functions for detecting the game rules of a TF2 match.


## Functions


### IsMatchTypeCasual()


Returns true if the match is a casual match.


### IsMatchTypeCompetitive()


Returns true if the match is a competitive match.


### IsManagedMatchEnded()


Returns true if the matchmaking match has ended.


### GetTimeLeftInMatch()


Returns the time left in the match.


### IsTruceActive()


When truce is active, players cannot attack each other.


### IsMvM()


Returns true if the current match is a MvM game.


### GetCurrentMatchGroup()


Returns the current match group.


### IsUsingGrapplingHook()


Returns true if current gamemode allows players to use the grappling hook.


### IsUsingSpells()


Returns true if current gamemode allows players to use spells.


### GetCurrentNextMapVotingState()


Returns the current next map voting state.


### GetPlayerVoteState ( playerIndex:integer )


Returns the vote state of the player with the given index.


### GetRoundState()


Returns the current state of the round as integer.





State
Meaning




`0`
ROUND_INIT


`1`
ROUND_PREGAME


`2`
ROUND_STARTGAME


`3`
ROUND_PREROUND


`4`
ROUND_RUNNING


`5`
ROUND_TEAMWIN


`6`
ROUND_RESTART


`7`
ROUND_STALEMATE


`8`
ROUND_GAMEOVER


`9`
ROUND_BONUS


`10`
ROUND_BETWEEN_ROUNDS



## Examples


Prevent player from attacking during Truce```
local function onCreateMove( cmd )
    if gamerules.IsTruceActive() then
        cmd.buttons = cmd.buttons & ~IN_ATTACK
    end
end

callbacks.Register("CreateMove", onCreateMove)

```


## globals



# globals


This library contains global source engine variables.


## Functions


### TickInterval()


Returns server tick interval


### TickCount()


Returns client tick count


### RealTime()


Returns the time since start of the game


### CurTime()


Returns the current time


### FrameCount()


Returns the frame count


### FrameTime()


Return delta time between frames


### AbsoluteFrameTime()


Return delta time between frames


### MaxClients()


Max player count of the current server


## Examples


FPS Counter - by x6h```
local consolas = draw.CreateFont("Consolas", 17, 500)
local current_fps = 0

local function watermark()
  draw.SetFont(consolas)
  draw.Color(255, 255, 255, 255)

  -- update fps every 100 frames
  if globals.FrameCount() % 100 == 0 then
    current_fps = math.floor(1 / globals.FrameTime())
  end

  draw.Text(5, 5, "[lmaobox | fps: " .. current_fps .. "]")
end

callbacks.Register("Draw", "draw", watermark)
-- https://github.com/x6h

```


## gui



# gui


## Functions


### GetValue( msg:string )


Get current value of a setting


### SetValue( msg:string, index:integer )


Set current Integer value of a setting


### SetValue( msg:string, msg:string )


Set current Text value of a setting


### IsMenuOpen()


Returns true if lmaobox menu is open.


## Examples


Set aimbot settings```
gui.SetValue("aim bot", 1);
gui.SetValue("aim method", "silent");

local aim_method = gui.GetValue("aim method");
print( aim_method ) -- prints 'silent'

```

Get current aimbot fov```
local aim_fov = gui.GetValue("aim fov");
print( aim_fov )

```

Change ESP color for blue team```
gui.SetValue("blue team color", 0xcaffffff)

```


## http

A lightweight HTTP library providing a simple get method for downloading data from the internet.

Functions
Get(url:string) : string
Returns string of the body response.

GetAsync(url:string, callback(data:string) )
Non-blocking request using callback function as second argument

Example
```lua
local response = http.Get("https://catfact.ninja/fact");
print(response) 

--- prints {"fact":"A cat's hearing is much more sensitive than humans and dogs.","length":60}
http.GetAsync("https://catfact.ninja/fact", function(data) client.ChatSay(data) end)
--- says in chat {"fact":"A cat's hearing is much more sensitive than humans and dogs.","length":60}
```


## input



# input


The input library provides an interface to the user's keyboard and mouse.


## Functions


### GetMousePos()


Returns the current mouse position as a table where index 1 is x and index 2 is y.


### IsButtonDown( button:integer )


Returns true if the specified mouse button is down. Otherwise, it returns false.


### IsButtonPressed( button:integer )


Returns true if the specified mouse button was pressed. Otherwise, it returns false.
Second return value is the tick when button was pressed.


### IsButtonReleased( button:integer )


Returns true if the specified mouse button was released. Otherwise, it returns false.
Second return value is the tick when button was released.


### IsMouseInputEnabled()


Returns whether the mouse input is currently enabled.


### SetMouseInputEnabled( enabled:bool )


Sets whether the mouse is visible on screen and has priority on the topmost panel.


### GetPollTick()


Returns the tick when buttons have last been polled.


## Examples


Attack when user presses E```
local function onCreateMove( cmd )
    if input.IsButtonDown( KEY_E ) then
        cmd.buttons = cmd.buttons | IN_ATTACK
    end
end

callbacks.Register( "CreateMove", onCreateMove )

```


## inventory



# inventory


The inventory library is used to access the player's inventory and the items in it. Every item is of type Item.


## Functions


### Enumerate( callback:function( item ) )


Callback is called for each item in the inventory. The item is passed as the first argument and is of type Item.


### GetItemByPosition( position:integer )


Returns the item at the given position in the inventory.


### GetMaxItemCount()


Returns the maximum number of items that can be in the inventory.


### GetItemByItemID( itemID:integer )


Returns the item with the given 64bit item ID.


### GetItemInLoadout( classid:integer, slot:integer )


Returns the item that is in the given slot in the given class' loadout slot.


### EquipItemInLoadout( item:Item, classid:integer, slot:integer )


Equips the item that is in the given slot in the given class' loadout slot. The item is of type Item


### CreateFakeItem( itemdef:ItemDefinition, pickupOrPosition:integer, itemID64:integer, quality:integer, origin:integer, level:integer, isNewItem:bool )


Creates a fake item with the given parameters. The item definition is of type ItemDefinition. The pickupOrPosition parameter is the pickup method, if isNewItem parameter is true, and the inventory position of the item if isNewItem parameter is false. The itemID64 is the unique 64bit item ID of the item, you can use -1 to generate a random ID. For quality and origin you can use constants. The level is the item's level.


## Examples


Create pink Cow Mangler using paint can attribute```
local definition = itemschema.GetItemDefinitionByID(441) -- id from items_game.txt
local createdItem = inventory.CreateFakeItem(definition, 0, -1, 14, 0, 100, true)
local name = itemschema.GetAttributeDefinitionByName( "custom name attr" )
createdItem:SetAttribute(name, "Pink 5000")

local color = itemschema.GetAttributeDefinitionByName( "set item tint RGB" )
createdItem:SetAttribute(color, 0xFF69B4) -- use hex value from Paint Can wiki page

print(string.format("Added %s with item ID %i to inventory slot %i.", createdItem:GetName(), createdItem:GetItemID(), createdItem:GetInventoryPosition()))

-- prints: echo Added ''Pink 5000'' with item ID 4723849120212 to inventory slot 12.

```


## itemschema



# itemschema


The itemschema library contains functions for retrieving information about items.
Items referred to in this library are of the ItemDefinition type.


## Functions


### GetItemDefinitionByID( id:integer )


Returns the item definition for the item with the given ID.


### GetItemDefinitionByName( name:string )


Returns the item definition for the item with the given name.


### Enumerate( callback:function(itemDefinition) )


Enumerates all item definitions, calling the callback for each one.


### GetAttributeDefinitionByName( name:string )


Returns the attribute definition for the item with the given name.


### EnumerateAttributes( callback:function(attributeDefinition) )


Enumerates all attribute definitions, calling the callback for each one.


## Examples


Get player's weapon name```
local activeWeapon = entities.GetLocalPlayer():GetPropEntity("m_hActiveWeapon")
local wpnId = activeWeapon:GetPropInt("m_iItemDefinitionIndex")
if wpnId ~= nil then
    local wpnName = itemschema.GetItemDefinitionByID(wpnId):GetName()
    draw.TextShadow(screenPos[1], screenPos[2], wpnName)
end

```

Find all hats and cosmetics```
local function forEveryItem( itemDefinition )
    if itemDefinition:IsWearable() then
        print( "Found: " .. itemDefinition:GetName() )
    end
end

itemschema.Enumerate( forEveryItem )

```


## materials



# materials


The materials library provides a way to create and alter materials for rendering.


## Functions


### Find( name:string )


Find a material by name


### Enumerate( callback( mat ) )


Enumerate all loaded materials and call the callback function for each one. The only argument in the callback is the Material object.


### Create( name:string, vmt:string )


Create custom material following the Valve Material Type syntax.
VMT should be a string containing the full material definition. Name should be an unique name of the material.


### CreateTextureRenderTarget( name:string, width:number, height:number )


Create a texture render target. Name should be an unique name of the material. Width and height are the dimensions of the texture. Returns a Texture object.


### FindTexture( name:string, groupName:string, complain:boolean )


Fetches a texture by name. If the texture is not found, it will be created. If complain is true, it will print an error message if the texture is not found. Returns a Texture object.


## Examples


Create white material```
kv = [["UnlitGeneric"
{
    "$basetexture"  "vgui/white_additive"
    "$ignorez" "1"
    "$model" "1"
}
]]

myMaterial = materials.Create( "myMaterial", kv )

```

Find materials that have 'wood' in name```
local function forEveryMaterial( material )
    if string.find( material:GetName(), "wood" ) then
        print( "Found material: " .. material:GetName() )
    end
end

materials.Enumerate( forEveryMaterial )

```


## models



# models


The models library provides a way to get information about models. When inputting the model:Model parameter, it must be of type Model.


## Functions


### GetModel( modelIndex:integer )


Returns a Model object by model index.


### GetModelIndex( modelName:string )


Returns a model index as an integer by a given model name.


### GetStudioModel( model:Model )


Returns a StudioModelHeader object by model.


### GetModelName( model:Model )


Returns a model name by string.


### GetModelMaterials( model:Model )


Returns a table of Material objects by model.


### GetModelRenderBounds( model:Model )


Returns two Vector3 objects, mins and maxs, by model string, representing render bounds.


### GetModelBounds( model:Model )


Returns two Vector3 objects, mins and maxs, by model string representing model space bounds.


## Examples


Draw all bone numbers in world space```
callbacks.Register( "Draw", function ()

  local me = entities.GetLocalPlayer()

  local model = me:GetModel()
  local studioHdr = models.GetStudioModel(model)

  local myHitBoxSet = me:GetPropInt("m_nHitboxSet")
  local hitboxSet = studioHdr:GetHitboxSet(myHitBoxSet)
  local hitboxes = hitboxSet:GetHitboxes()

 --boneMatrices is an array of 3x4 float matrices
  local boneMatrices = me:SetupBones()

  for i = 1, #hitboxes do
    local hitbox = hitboxes[i]
    local bone = hitbox:GetBone()

    local boneMatrix = boneMatrices[bone]

    if boneMatrix == nil then
      goto continue
    end

    local bonePos = Vector3( boneMatrix[1][4], boneMatrix[2][4], boneMatrix[3][4] )

    local screenPos = client.WorldToScreen(bonePos)

    if screenPos == nil then
      goto continue
    end

    draw.Text( screenPos[1], screenPos[2], i )

    ::continue::
  end

end)

```


## party



# party


The party library provides functions for managing the player's matchmaking party.
All functions return nil if the player is not in a party or the party client is not initialized.


## Functions


### GetLeader()


Returns the player's party leader's SteamID as string.


### GetMembers()


Returns a table containing the player's party members' SteamIDs as strings.





Key Index
Value




`1`
STEAM_0:?:?



### GetPendingMembers()


Returns a table containing the player's pending party members' SteamIDs as strings. These members are invited to party, but have not joined yet.


### GetGroupID()


Returns the player's party's group ID.


### GetQueuedMatchGroups()


Returns a table where values are the player's queued match groups as MatchGroup objects.





Key
Value




`Casual`
MatchGroup object



### GetAllMatchGroups()


Returns a table where values are all possible match groups as MatchGroup objects.





Key
Value




`Casual`
MatchGroup object



### Leave()


Leaves the current party.


### CanQueueForMatchGroup( matchGroup:MatchGroup )


Returns true if the player can queue for the given match group.
If the player can not queue for the match groups, returns a table of reasons why the player can not queue.





Key
Value




`1`
Select at least one Mission in order to queue.



### QueueUp( matchGroup:MatchGroup )


Requests to queue up for a match group.


### CancelQueue( matchGroup:MatchGroup )


Cancles the request to queue up for a match group.


### IsInStandbyQueue()


Whether the player is in the standby queue. That refers to queueing up for an ongoing match in your party.


### CanQueueForStandby()


Returns whether the player can queue up for a standby match. That refers to an ongoing match in your party.


### QueueUpStandby()


Requests to queue up for a standby match in your party. That refers to an ongoing match in your party.


### CancelQueueStandby()


Cancles the request to queue up for a standby match in your party. That refers to an ongoing match in your party.


### GetMemberActivity( index:integer )


Returns a PartyMemberActivity object for the party member at the given index. See GetMembers() for the index.


### PromoteMemberToLeader( steamid:string )


Promotes the given player to the party leader. Works only if you are the party leader.


### KickMember( steamid:string )


Kicks the given player from the party. Works only if you are the party leader.


### IsCasualMapSelected( map:MatchMapDefinition )


Returns true if the given map is selected for casual play.


### SetCasualMapSelected( map:MatchMapDefinition, selected:bool )


Sets the given map as selected for casual play.


## Examples


Queue up for casual```
local casual = party.GetAllMatchGroups()["Casual"]

local reasons = party.CanQueueForMatchGroup( casual )

if reasons == true then
    party.QueueUp( casual )
else
    for k,v in pairs( reasons ) do
        print( v )
    end
end

```

Print all party members, but not the leader```
local members = party.GetMembers()

for k, v in pairs( members ) do
    if v ~= party.GetLeader() then
        print( v )
    end
end

```

Am I in queue?```
if #party.GetQueuedMatchGroups() > 0 then
    print( "I'm in queue!" )
end

```


## physics



# physics


This is a library for physics calculations in TF2. You can use this to calculate the trajectory of projectiles, or perform any sort of physics calculations on physics objects in time, in your own environment, or in TF2's environment.


## Functions


### CreateEnvironment()


Creates a new physics environment of class PhysicsEnvironment. By default it has no gravity, and no air resistance and no collisions.


### DestroyEnvironment( environment:PhysicsEnvironment )


Destroys a physics environment.


### DefaultEnvironment()


Returns the default physics environment. This is the environment that TF2 client uses for clientside physics calculations. Wouldnt recommend using, can cause odd side effects, but im not your mom.


### BBoxToCollisionModel( mins:Vector, maxs:Vector )


Creates a collision model from a bounding box. Returns a PhysicsCollisionModel object.


### ParseModelByName( modelName:string )


Creates a PhysicsSolid and a PhysicsCollisionModel from a model name. Returns a PhysicsSolid object and a PhysicsCollisionModel object.


### DefaultObjectParameters()


Creates a PhysicsObjectParameters object with default values.


## Examples


### Projectile trajectory in time with custom values


```
-- Run only once
local grenadeModel = [[models/weapons/w_models/w_grenade_grenadelauncher.mdl]]
local env = physics.CreateEnvironment( )
env:SetGravity( Vector3( 0, 0, -800 ) )
env:SetAirDensity( 2.0 )
env:SetSimulationTimestep( globals.TickInterval() )
local solid, collisionModel = physics.ParseModelByName( grenadeModel )
local simulatedProjectile = nil

callbacks.Register( "Draw", function ()

  local me = entities.GetLocalPlayer()

  if simulatedProjectile == nil then 
    simulatedProjectile = env:CreatePolyObject(collisionModel, solid:GetSurfacePropName(), solid:GetObjectParameters())
    simulatedProjectile:Wake()
  end

  local startPos = me:GetAbsOrigin() + me:GetPropVector( "m_vecViewOffset[0]" )
  local startAngles = me:GetPropVector(  "m_angEyeAngles" )
  simulatedProjectile:SetPosition(startPos, startAngles, true)

  local velocity = Vector3(1000,600,200)
  local angularVelocity = Vector3(600,0,0) --Spin!

  simulatedProjectile:SetVelocity(velocity, angularVelocity)

  local tickInteval = globals.TickInterval()
  local simulationEnd = env:GetSimulationTime() + 2.0

  while env:GetSimulationTime() < simulationEnd do

    -- Where is it now?
    local currentPos, currentAngle = simulatedProjectile:GetPosition()

    -- draw line from startPos to currentPos
    local screenCurrentPos = client.WorldToScreen(currentPos)
    local screenStartPos = client.WorldToScreen(startPos)

    if screenCurrentPos ~= nil and screenStartPos ~= nil then
      draw.Color(255, 0, 255, 255)
      draw.Line(screenStartPos[1], screenStartPos[2], screenCurrentPos[1], screenCurrentPos[2])
    end

    startPos = currentPos

    -- Run the simulation
    env:Simulate(tickInteval)
  end

  env:ResetSimulationClock()

end)

callbacks.Register("Unload", function()
  -- Clean up afterwards
  if simulatedProjectile ~= nil then
    env:DestroyObject(simulatedProjectile)
  end

  physics.DestroyEnvironment( env )
end)

```


## playerlist



# playerlist


The playerlist library provides a way to retrieve values from, and customize the playerlist.


## Functions


### GetPriority( player:Entity )


Returns the priority of the player.


### GetPriority( userID:number )


Returns the priority of the player by user ID.


### GetPriority( steamID:string )


Returns the priority of the player by Steam ID.


### SetPriority( player:Entity, priority:number )'


Sets the priority of the player.


### SetPriority( userID:number, priority:number )


Sets the priority of the player by user ID.


### SetPriority( steamID:string, priority:number )


Sets the priority of the player by Steam ID.


### GetColor( player:Entity )


Returns the color of the player.


### GetColor( userID:number )


Returns the color of the player by user ID.


### GetColor( steamID:string )


Returns the color of the player by Steam ID.


### SetColor( player:Entity, color:number )


Sets the color of the player.


### SetColor( userID:number, color:number )


Sets the color of the player by user ID.


### SetColor( steamID:string, color:number )


Sets the color of the player by Steam ID.


## Examples


Get playerlist color by SteamID```
local color = playerlist.GetColor("STEAM_0:0:123456789");

```

Set playerlist priority by SteamID```
local priority = 1;

playerlist.SetPriority("STEAM_0:0:123456789", priority);

```


## render



# render


The render library provides a way to interact with the rendering system.


## Functions


### Push3DView( view:ViewSetup, clearFlags:integer, texture:Texture )


Push a 3D view of type ViewSetup to the render stack. Flags is a bitfield of Clear flags. Texture is a Texture object to render to. If texture is nil, the current render target is used.


### PopView()


Pop the current view from the render stack.


### ViewDrawScene( draw3Dskybox:boolean, drawSkybox:boolean, view:ViewSetup )


Draw the scene onto the texture that is currently on top of the stack - by default your whole screen. draw3Dskybox and drawSkybox are booleans that determine if the 3D skybox or 2D skybox should be drawn. View is a ViewSetup object.


### DrawScreenSpaceRectangle( material:Material, destX:integer, destY:integer, width:integer, height:integer, srcTextureX0:number, srcTextureY0:number, srcTextureX1:number, srcTextureY1:number, srcTextureWidth:integer, srcTextureHeight:integer )


Draw a screen space rectangle with a given Material. Material is a Material object. destX and destY are the coordinates of the top left corner of the rectangle. width and height are the dimensions of the rectangle. srcTextureX0, srcTextureY0, srcTextureX1, srcTextureY1 are the coordinates of the top left and bottom right corners of the rectangle on the texture. srcTextureWidth and srcTextureHeight are the dimensions of the texture.


### DrawScreenSpaceQuad( material:Material )


Draws a screen space quad by material


### GetViewport()


Returns x, y, w, h of current viewport


### Viewport( x:integer, y:integer, w:integer, h:integer)


Sets current viewport 


### DepthRange( zNear:number, zFar:number)


Sets the depth range of rendering


### GetDepthRange()


Returns the depth range of rendering as zNear, zFar


### SetRenderTarget( texture:Texture )


Sets the current render target to texture.


### GetRenderTarget()


Returns the current render target as a Texture object.


### ClearBuffers( clearColor:boolean, clearDepth:boolean, clearStencil:boolean)


Clears the current render target's buffers. clearColor, clearDepth and clearStencil are booleans that determine which buffers should be cleared.


### ClearColor3ub( r:integer, g:integer, b:integer)


Clears the current render target's color buffer with the given RGB values. r, g and b are integers between 0 and 255.


### ClearColor4ub( r:integer, g:integer, b:integer, a:integer)


Clears the current render target's color buffer with the given RGBA values. r, g, b and a are integers between 0 and 255.


### OverrideDepthEnable( enable:boolean, depthEnable:boolean )


Sets the depth override state. enable is a boolean that determines if the depth override is enabled. depthEnable is a boolean that determines if depth testing is enabled when the depth override is enabled.


### OverrideAlphaWriteEnable( enable:boolean, alphaWriteEnable:boolean )


Sets the alpha write override state. enable is a boolean that determines if the alpha write override is enabled. alphaWriteEnable is a boolean that determines if alpha writing is enabled when the alpha write override is enabled.


### PushRenderTargetAndViewport()


Push the current render target and viewport to the stack.


### PopRenderTargetAndViewport()


Pop the current render target and viewport from the stack.


### SetStencilEnable( enable:boolean )


Sets the stencil staet. enable is a boolean that determines if the stencil test is enabled.


### SetStencilFailOperation( failOp:integer )


Seets the stencil fail operation. failOp is an integer that determines the operation to perform when the stencil test fails. The possible values are of enum E_StencilOperation.


### SetStencilZFailOperation( zFailOp:integer )


Sets the stencil Z fail operation. zFailOp is an integer that determines the operation to perform when the stencil test passes but the depth test fails. The possible values are of enum E_StencilOperation.


### SetStencilPassOperation( passOp:integer )


Sets the stencil pass operation. passOp is an integer that determines the operation to perform when the stencil test passes. The possible values are of enum E_StencilOperation.


### SetStencilCompareFunction( compareFunc:integer )


Set the stencil compare function. compareFunc is an integer that determines the comparison function to use. The possible values are of enum E_StencilComparisonFunction.


### SetStencilReferenceValue( comparationValue:integer )


Ssets the stencil reference value. comparationValue is an integer that determines the reference value to use for the stencil test. The value is clamped between 0 and 255.


### SetStencilTestMask( mask:integer )


Sets the stencil test mask. mask is an integer that determines the mask to use for the stencil test. The value is clamped between 0 and 0xFFFFFFFF.


### SetStencilWriteMask( mask:integer )


Sets the stencil write mask. mask is an integer that determines the mask to use for writing to the stencil buffer. The value is clamped between 0 and 0xFFFFFFFF.


### ClearStencilBufferRectangle( xmin:integer, ymin:integer, xmax:integer, ymax:integer, value:integer)


Clears the stencil buffer rectangle. xmin, ymin, xmax and ymax are integers that determine the rectangle to clear. value is an integer that determines the value to clear the rectangle to.


### ForcedMaterialOverride( material:Material )


Sets the forced material override. material is a Material object that determines the material to use for all subsequent draw calls. Pass nil to disable the forced material override.


### SetBlend( blend:float )


Set the blend factor. blend is a float that determines the blend factor to use for all subsequent draw calls. The value is clamped between 0 and 1. This is used for alpha blending.


### GetBlend()


Reutrns the current blend factor as a float.


### SetColorModulation( r:number, g:number, b:number )


Set the color modulation. r, g and b are floats that determine the color modulation to use for all subsequent draw calls. The values are clamped between 0 and 1. This is used for color tinting.


### GetColorModulation()


Returns r,g,b - 3 floats that represent the current color modulation.


## Examples


Draw a custom camera view - spy camera```
local camW = 400
local camH = 300
local cameraTexture = materials.CreateTextureRenderTarget( "cameraTexture123", camW, camH )
local cameraMaterial = materials.Create( "cameraMaterial123", [[
    UnlitGeneric
    {
        $basetexture    "cameraTexture123"
    }
]] )

callbacks.Register("PostRenderView", function(view)
    customView = view
    customView.angles = EulerAngles(customView.angles.x, customView.angles.y + 180, customView.angles.z)

    render.Push3DView( customView, E_ClearFlags.VIEW_CLEAR_COLOR | E_ClearFlags.VIEW_CLEAR_DEPTH, cameraTexture )
    render.ViewDrawScene( true, true, customView )
    render.PopView()
    render.DrawScreenSpaceRectangle( cameraMaterial, 300, 300, camW, camH, 0, 0, camW, camH, camW, camH )
end)

```


## steam



# steam


The steam library provides access to basic Steam API functionality and data.


## Functions


### GetSteamID()


Returns SteamID  of the user as string.


### GetPlayerName( steamid:string )


Returns the player name of the player having the given SteamID.


### IsFriend( steamid:string )


Returns true if the player is a friend of the user.


### GetFriends()


Returns a table of all friends of the user.


### ToSteamID64( steamid:string )


Returns the 64bit SteamID of the player as a long integer.



## vector



# vector


The vector library provides a simple way to manipulate 3D vectors. You can use both Lua tables and Vector3 instances as arguments. The functions below showcase only the table-based option.


See definitions of Vector3 and EulerAngles


## Functions


### Add( a: Vector3, b: Vector3 ): Vector3


Add two vectors


### Subtract( a: Vector3, b: Vector3 ): Vector3


Subtract two vectors


### Multiply( vec: Vector3, scalar: number ): Vector3


Multiply vector by scalar


### Divide( vec: Vector3, scalar: number ): Vector3


Divide vector by scalar


### Length( vec: Vector3 ): number


Get vector length


### LengthSqr( vec: Vector3 ): number


Get vector squared length


### Distance( a: Vector3, b: Vector3 ): number


Get distance between two vectors


### Normalize( vec: Vector3 ): Vector3


Normalize vector


### Angles( angles: EulerAngles ): EulerAngles


Get vector angles


### AngleForward( angles: EulerAngles ): EulerAngles


Get forward vector angle


### AngleRight( angles: EulerAngles ): EulerAngles


Get right vector angle


### AngleUp( angles: EulerAngles ): EulerAngles


Get up vector angle


### AngleVectors( angles: EulerAngles ): forward: Vector3, right: Vector3, up: Vector3


Get forward, right, and up vector angles as 3 return values


### AngleNormalize( angles: EulerAngles ): EulerAngles


Normalize vector angles


## Examples


Arithmetic example```
local vec = vector.Add( Vector3( 1, 2, 3 ), {4, 5, 6} )
local vec = vector.Subtract( {10, 20, 30}}, {4, 5, 6} )

```

Angle normalise```
print(vector.AngleNormalize({30, 182, 2}))
--- prints [30.0, -178.0, 0.0]

```


## warp



# warp


This library can be used for interacting with the warp exploit feature of TF2.
How it works:


You can charge up ticks to later on send to server in a batch, which will execute them all at once, it behaves like a small speedhack, a warp.


Warping results in a small dash in the direction you are running in.


Warping while shooting results in weapons speeding up their reload times -> some weapons can shoot twice - a double tap.


## Functions


### GetChargedTicks()


Returns the amount of charged warp ticks.


### IsWarping()


Returns true if the user is currently warping.
Since the period of warping is super short, this is only really useful in CreateMove callbacks where you can use it to do your logic.


### CanWarp()


Whether we can warp or not. Does not guarantee a full charge or a double tap.


### CanDoubleTap( weapon:Entity )


Extension of CanWarp with additional checks. When this is true, you can guarentee a weapon will double tap.


### TriggerWarp()


Triggers a warp.


### TriggerDoubleTap()


Triggers a warp with double tap.


### TriggerCharge()


Triggers a charge of warp ticks.


## Examples


Play a sound when weapon can double tap```
local function onCreateMove( cmd )
    local me = entities.GetLocalPlayer()
    if e ~= nil then
        local wpn = me:GetPropEntity( "m_hActiveWeapon" )
        if wpn  ~= nil then

            local canDt = warp.CanDoubleTap(wpn)

            if oldCanDt ~= canDt and canDt == true then
                engine.PlaySound( "player/recharged.wav" )
            end

            oldCanDt = canDt
        end
    end
end

callbacks.Register("CreateMove", onCreateMove)

```


