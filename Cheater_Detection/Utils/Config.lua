--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Common = require("Cheater_Detection.Utils.Common")
local Default_Config = require("Cheater_Detection.Utils.DefaultConfig")

local Config = {}

--[[ Constants ]]
local Lua__fullPath = GetScriptName()
local Lua__fileName = Lua__fullPath:match("([^/\\]+)%.lua$"):gsub("%.lua$", "")
local folder_name = string.format([[Lua %s]], Lua__fileName)

--[[ Config Path Helper ]]
-- Build full path once from script name
local function GetConfigPath()
	local _, fullPath = filesystem.CreateDirectory(folder_name) -- succeeds even if already exists
	local sep = package.config:sub(1, 1) -- Get OS path separator
	return fullPath .. sep .. "config.cfg"
end

--[[ Serialize a Lua table (readable output, ordered by iteration) ]]
local function serializeTable(tbl, level)
	level = level or 0
	local indent = string.rep("    ", level)
	local out = indent .. "{\n"
	for k, v in pairs(tbl) do
		local keyRepr = (type(k) == "string") and string.format('["%s"]', k) or string.format("[%s]", k)
		out = out .. indent .. "    " .. keyRepr .. " = "
		if type(v) == "table" then
			out = out .. serializeTable(v, level + 1) .. ",\n"
		elseif type(v) == "string" then
			out = out .. string.format('"%s",\n', v)
		else
			out = out .. tostring(v) .. ",\n"
		end
	end
	out = out .. indent .. "}"
	return out
end

--[[ Recursive key presence check (ensures loaded config has all required keys) ]]
local function keysMatch(template, loaded)
	for k, v in pairs(template) do
		if loaded[k] == nil then
			return false
		end
		if type(v) == "table" and type(loaded[k]) == "table" then
			if not keysMatch(v, loaded[k]) then
				return false
			end
		end
	end
	return true
end

--[[ Deep copy table (for default initialization) ]]
local function deepCopy(orig)
	if type(orig) ~= "table" then
		return orig
	end
	local copy = {}
	for k, v in pairs(orig) do
		copy[k] = deepCopy(v)
	end
	return copy
end

--[[ Ensure all Menu settings have defaults (handles partial configs) ]]
local function SafeInitMenu()
	if not G.Menu then
		G.Menu = deepCopy(Default_Config)
		return
	end

	-- Helper to ensure a field exists with default value
	local function ensureField(parent, key, default)
		if parent[key] == nil then
			parent[key] = deepCopy(default)
		elseif type(default) == "table" and type(parent[key]) == "table" then
			-- Recursively ensure nested tables
			for k, v in pairs(default) do
				ensureField(parent[key], k, v)
			end
		end
	end

	-- Ensure all top-level and nested fields exist
	for key, value in pairs(Default_Config) do
		ensureField(G.Menu, key, value)
	end
end

--[[ Save config to file ]]
function Config.CreateCFG(cfgTable)
	cfgTable = cfgTable or G.Menu or Default_Config
	local path = GetConfigPath()

	local file = io.open(path, "w")
	if not file then
		printc(255, 0, 0, 255, "[Config] Failed to write: " .. path)
		return false
	end

	file:write(serializeTable(cfgTable))
	file:close()
	printc(100, 183, 0, 255, "[Config] Saved: " .. path)
	return true
end

--[[ Load config; regenerate if invalid/outdated/SHIFT bypass ]]
function Config.LoadCFG()
	local path = GetConfigPath()
	local file = io.open(path, "r")

	if not file then
		-- First run – make directory & default cfg
		printc(255, 200, 100, 255, "[Config] No config found, creating default...")
		G.Menu = deepCopy(Default_Config)
		Config.CreateCFG(G.Menu)
		SafeInitMenu()
		return G.Menu
	end

	local content = file:read("*a")
	file:close()

	-- Parse as Lua table
	local chunk, err = load("return " .. content)
	if not chunk then
		printc(255, 100, 100, 255, "[Config] Compile error, regenerating: " .. tostring(err))
		G.Menu = deepCopy(Default_Config)
		Config.CreateCFG(G.Menu)
		SafeInitMenu()
		return G.Menu
	end

	local ok, cfg = pcall(chunk)

	-- Validate: Must be table, keys must match, SHIFT bypass for reset
	local shiftHeld = input.IsButtonDown(KEY_LSHIFT)
	if not ok or type(cfg) ~= "table" or not keysMatch(Default_Config, cfg) or shiftHeld then
		if shiftHeld then
			printc(255, 200, 100, 255, "[Config] SHIFT held – regenerating config...")
		else
			printc(255, 100, 100, 255, "[Config] Invalid or outdated config – regenerating...")
		end
		G.Menu = deepCopy(Default_Config)
		Config.CreateCFG(G.Menu)
		SafeInitMenu()
		return G.Menu
	end

	-- Success
	printc(0, 255, 140, 255, "[Config] Loaded: " .. path)
	G.Menu = cfg
	SafeInitMenu() -- Ensure any new fields from Default_Config are added
	return G.Menu
end

--[[ Get filepath (public API) ]]
function Config.GetFilePath()
	return GetConfigPath()
end

--[[ Auto-load config on require ]]
Config.LoadCFG()

-- Set G.Config with key settings for other modules
G.Config = G.Config or {}
G.Config.AutoFetch = G.Menu and G.Menu.Main and G.Menu.Main.AutoFetch or true

--[[ Save configuration automatically when the script unloads ]]
local function ConfigAutoSaveOnUnload()
	print("[CONFIG] Unloading script, saving configuration...")

	-- Safety check
	if not G or not G.Menu then
		print("[CONFIG] Warning: G.Menu is nil, cannot save config")
		return
	end

	-- Use the same serializer (it's self-contained, no GC issues)
	local success, result = pcall(function()
		local path = GetConfigPath()
		local file = io.open(path, "w")
		if file then
			file:write(serializeTable(G.Menu))
			file:close()
			print("[CONFIG] Config saved successfully to: " .. path)
			return true
		else
			print("[CONFIG] ERROR: Cannot open file for writing: " .. tostring(path))
			return false
		end
	end)

	if not success then
		print("[CONFIG] ERROR during save: " .. tostring(result))
	end
end

callbacks.Register("Unload", "ConfigAutoSaveOnUnload", ConfigAutoSaveOnUnload)

return Config
