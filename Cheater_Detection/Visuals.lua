--[[ Imports ]]
local Common = require("Cheater_Detection.Common")
local Config = require("Cheater_Detection.Config")
local Visuals = {}

local Log = Common.Log
local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

---@type boolean, ImMenu
local menuLoaded, ImMenu = pcall(require, "ImMenu")
assert(menuLoaded, "ImMenu not found, please install it!")
assert(ImMenu.GetVersion() >= 0.66, "ImMenu version is too old, please update it!")

local lastToggleTime = 0
local Lbox_Menu_Open = true
local toggleCooldown = 0.1  -- 200 milliseconds

function Visuals.toggleMenu()
    local currentTime = globals.RealTime()
    if currentTime - lastToggleTime >= toggleCooldown then
        Lbox_Menu_Open = not Lbox_Menu_Open  -- Toggle the state
        lastToggleTime = currentTime  -- Reset the last toggle time
    end
end

local Menu = Config.LoadCFG()

--[[ Functions ]]

local RuntimeData = {}
function Visuals.SetRuntimeData(DataBase)
    RuntimeData = DataBase
end

function Visuals.GetMenu()
    return Menu
end

local function doDraw()
    draw.SetFont(Fonts.Verdana)
    draw.Color(255, 255, 255, 255)
    local Main = Menu.Main

        if Menu.tags and not engine.Con_IsVisible() and not engine.IsGameUIVisible() then
            if Menu.debug then
                draw.Color(255, 0, 0, 255)
                draw.Text(20, 120, "Debug Mode!!! Some Features Might malfunction")
            end
            draw.Color(255, 255, 255, 255)
            draw.SetFont(tahoma_bold)

            if RuntimeData then
                for steamId, data in pairs(RuntimeData) do
                    local entity = data.EntityData.entity
                    local strikes = data.strikes
                    local detected = data.isCheater

                    if not entity or not entity:IsValid() or entity:IsDormant() or not entity:IsAlive() then goto continue end
                    if strikes >= math.floor(Menu.StrikeLimit / 2) then
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
             -- Tabs for different sections
            ImMenu.BeginFrame(1)
                if ImMenu.Button("Main") then
                    Menu.Tabs.Main = true
                    Menu.Tabs.Visuals = false
                    Menu.Tabs.PlayerList = false
                end
                if ImMenu.Button("Visuals") then
                    Menu.Tabs.Main = false
                    Menu.Tabs.Visuals = true
                    Menu.Tabs.PlayerList = false
                end
                if ImMenu.Button("PlayerList") then
                    Menu.Tabs.Main = false
                    Menu.Tabs.Visuals = false
                    Menu.Tabs.PlayerList = true
                end
            ImMenu.EndFrame()

            -- Main Section
            if Menu.Tabs.Main then
                -- Strike Limit Slider
                ImMenu.BeginFrame(1)
                    Main.StrikeLimit = ImMenu.Slider("Strikes Limit", Main.StrikeLimit, 4, 17)
                ImMenu.EndFrame()

                -- Aimbot FOV Slider
                ImMenu.BeginFrame(1)
                    Main.AimbotDetection.Enable = ImMenu.Checkbox("aimbot ", Main.AimbotDetection.Enable)
                    if Main.AimbotDetection.Enable == true then
                        Main.AimbotDetection.MAXfov = ImMenu.Slider("Aimbot Fov", Main.AimbotDetection.MAXfov, 1, 180)
                    end
                ImMenu.EndFrame()

                -- Max Tick Delta Slider
                ImMenu.BeginFrame(1)
                    Main.ChokeDetection.Enable = ImMenu.Checkbox("Choke  ", Main.ChokeDetection.Enable)
                    if Main.ChokeDetection.Enable == true then
                        Main.ChokeDetection.MaxChoke = ImMenu.Slider("Max Packet Choke", Main.ChokeDetection.MaxChoke, 0.4, 10, 0.1)
                    end
                ImMenu.EndFrame()

                -- Enable_bhopcheck
                ImMenu.BeginFrame(1)
                    Main.BhopDetection.Enable = ImMenu.Checkbox("bhop    ", Main.BhopDetection.Enable)
                    if Main.BhopDetection.Enable == true then
                        Main.BhopDetection.MaxBhop = ImMenu.Slider("Max Bhops", Main.BhopDetection.MaxBhop, 4, 15)
                    end
                ImMenu.EndFrame()

                -- Menu
                ImMenu.BeginFrame(1)
                    Main.AntyAimDetection = ImMenu.Checkbox("Anty-Aim ", Main.AntyAimDetection)
                    Main.DuckSpeedDetection = ImMenu.Checkbox("Duck-Speed ", Main.DuckSpeedDetection)
                ImMenu.EndFrame()

                -- Menu
                ImMenu.BeginFrame(1)
                    Main.debug = ImMenu.Checkbox("Debug", Main.debug)
                ImMenu.EndFrame()
            end

            -- Visuals Section
            if Menu.Tabs.Visuals then
                ImMenu.BeginFrame(1)
                    Menu.Visuals.Cheater_Tags = ImMenu.Checkbox("Draw Tags", Menu.Visuals.Cheater_Tags)
                    Menu.Visuals.Chat_Prefix = ImMenu.Checkbox("Chat_Prefix", Menu.Visuals.Chat_Prefix)
                ImMenu.EndFrame()

                ImMenu.BeginFrame(1)
                    Menu.Visuals.partyCallaut = ImMenu.Checkbox("Party Callout", Menu.Visuals.partyCallaut)
                    Menu.Visuals.AutoMark = ImMenu.Checkbox("Auto Mark", Menu.Visuals.AutoMark)
                ImMenu.EndFrame()
            end

            --[[PlayerList Section
            if Menu.Tabs.PlayerList then
                ImMenu.Text("Name: [Player Name] | SteamID: [Steam ID] | Strikes: [Number of Strikes] | Cause: [Cause] | Date: [Date]")
                local maxCheatersToDisplay = 24
                local cheatersDisplayed = 0

                if RuntimeData then
                    for steamId, data in pairs(RuntimeData) do
                        if cheatersDisplayed >= maxCheatersToDisplay then
                            break
                        end

                        local entity = data.EntityData.entity
                        if entity and entity:IsValid() and Config.IsKnownCheater(steamId) then
                            ImMenu.BeginFrame(1)  -- Begin a new frame for each player

                            -- Display player information in a single row
                            local playerName = entity:GetName() or "N/A"
                            local strikes = Config.GetStrikes(steamId) or "N/A"
                            local cause = Config.GetCause(steamId) or "N/A"
                            local date = Config.GetDate(steamId) or "N/A"
                            ImMenu.Text(string.format("Name: %s | SteamID: %s | Strikes: %s | Cause: %s | Date: %s", playerName, steamId, strikes, cause, date))

                            -- Button to remove the player from the list
                            if ImMenu.Button("Remove " .. playerName .. "###" .. steamId) then
                                Config.RemovePlayer(steamId)
                            end

                            ImMenu.EndFrame(1)  -- End the frame for the current player
                            cheatersDisplayed = cheatersDisplayed + 1
                        end
                    end
                end
            end]]
            ImMenu.End()
        end
    end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw")                                   -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", doDraw)                              -- Register the "Draw" callback 

return Visuals