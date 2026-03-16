-- Config.lua 
-- Configuration handling module – now uses Serializer for all I/O. 
-- Place this file alongside the other Utils modules 
-- (e.g. Cheater_Detection/Utils/Config.lua). 
 
local G               = require("Cheater_Detection.Utils.Globals") 
local Default_Config   = require("Cheater_Detection.Utils.DefaultConfig") 
local Serializer       = require("Cheater_Detection.Utils.Serializer") -- adjust path if needed 
 
local Config = {} 
 
-- ---------------------------------------------------------------------- 
-- Path helpers (unchanged from the original script) 
-- ---------------------------------------------------------------------- 
local Lua__fullPath = GetScriptName() 
local Lua__fileName = Lua__fullPath:match("([^/\\]+)%.lua$"):gsub("%.lua$", "") 
local folder_name   = string.format([[Lua %s]], Lua__fileName) 
 
local function GetConfigPath() 
    local _, fullPath = filesystem.CreateDirectory(folder_name) -- succeeds even if already exists 
    local sep = package.config:sub(1, 1) -- OS path separator 
    return fullPath .. sep .. "config.cfg" 
end 
 
-- ---------------------------------------------------------------------- 
-- Ensure every expected key exists (handles partial configs) 
-- ---------------------------------------------------------------------- 
local function SafeInitMenu() 
    if not G.Menu then 
        G.Menu = Serializer.deepCopy(Default_Config) 
        return 
    end 
 
    local function ensureField(parent, key, default) 
        if parent[key] == nil then 
            parent[key] = Serializer.deepCopy(default) 
        elseif type(default) == "table" and type(parent[key]) == "table" then 
            for k, v in pairs(default) do 
                ensureField(parent[key], k, v) 
            end 
        end 
    end 
 
    for key, value in pairs(Default_Config) do 
        ensureField(G.Menu, key, value) 
    end 
end 
 
-- ---------------------------------------------------------------------- 
-- Public API: write a config file 
-- ---------------------------------------------------------------------- 
function Config.CreateCFG(cfgTable) 
    cfgTable = cfgTable or G.Menu or Default_Config 
    local path = GetConfigPath() 
    local success = Serializer.writeFile(path, Serializer.serializeTable(cfgTable)) 
    if not success then 
        printc(255, 0, 0, 255, "[Config] Failed to write: " .. path) 
        return false 
    end 
    printc(100, 183, 0, 255, "[Config] Saved: " .. path) 
    return true 
end 
 
-- ---------------------------------------------------------------------- 
-- Public API: load a config file (regenerate on error or SHIFT held) 
-- ---------------------------------------------------------------------- 
function Config.LoadCFG() 
    local path = GetConfigPath() 
    local content = Serializer.readFile(path) 
 
    if not content then 
        -- First run – create default config 
        printc(255, 200, 100, 255, "[Config] No config found, creating default...") 
        G.Menu = Serializer.deepCopy(Default_Config) 
        Config.CreateCFG(G.Menu) 
        SafeInitMenu() 
        return G.Menu 
    end 
 
    local chunk, err = load("return " .. content) 
    if not chunk then 
        printc(255, 100, 100, 255, "[Config] Compile error, regenerating: " .. tostring(err)) 
        G.Menu = Serializer.deepCopy(Default_Config) 
        Config.CreateCFG(G.Menu) 
        SafeInitMenu() 
        return G.Menu 
    end 
 
    local ok, cfg = pcall(chunk) 
    local shiftHeld = input.IsButtonDown(KEY_LSHIFT) 
 
    if not ok or type(cfg) ~= "table" or not Serializer.keysMatch(Default_Config, cfg) or shiftHeld then 
        if shiftHeld then 
            printc(255, 200, 100, 255, "[Config] SHIFT held – regenerating config...") 
        else 
            printc(255, 100, 100, 255, "[Config] Invalid or outdated config – regenerating...") 
        end 
        G.Menu = Serializer.deepCopy(Default_Config) 
        Config.CreateCFG(G.Menu) 
        SafeInitMenu() 
        return G.Menu 
    end 
 
    printc(0, 255, 140, 255, "[Config] Loaded: " .. path) 
    G.Menu = cfg 
    SafeInitMenu() 
    return G.Menu 
end 
 
-- ---------------------------------------------------------------------- 
-- Public API: expose the config file path 
-- ---------------------------------------------------------------------- 
function Config.GetFilePath() 
    return GetConfigPath() 
end 
 
-- Auto‑load on require (keeps original behaviour) 
Config.LoadCFG() 
 
return Config 
