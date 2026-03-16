-- Serializer.lua 
-- Utility module for table handling and file I/O. 
-- Place this file in the same folder as the other Utils modules 
-- (e.g. Cheater_Detection/Utils/Serializer.lua). 
 
local Serializer = {} 
 
-- ---------------------------------------------------------------------- 
-- Deep copy (handles nested tables, ignores metatables) 
-- ---------------------------------------------------------------------- 
local function deepCopy(orig) 
    if type(orig) ~= "table" then return orig end 
    local copy = {} 
    for k, v in pairs(orig) do 
        copy[k] = deepCopy(v) 
    end 
    return copy 
end 
 
-- ---------------------------------------------------------------------- 
-- Serialize a Lua table to a readable string. 
-- Uses a visited table to avoid infinite loops on self‑references. 
-- ---------------------------------------------------------------------- 
local function serializeTable(tbl, level, visited) 
    level = level or 0 
    visited = visited or {} 
    local indent = string.rep("    ", level) 
    local out = indent .. "{\n" 
    for k, v in pairs(tbl) do 
        local keyRepr = (type(k) == "string") and string.format('["%s"]', k) or string.format("[%s]", k) 
        out = out .. indent .. "    " .. keyRepr .. " = " 
        if type(v) == "table" then 
            if visited[v] then 
                out = out .. "--[[cycle]]" 
            else 
                visited[v] = true 
                out = out .. serializeTable(v, level + 1, visited) 
            end 
            out = out .. ",\n" 
        elseif type(v) == "string" then 
            out = out .. string.format('"%s",\n', v) 
        else 
            out = out .. tostring(v) .. ",\n" 
        end 
    end 
    out = out .. indent .. "}" 
    return out 
end 
 
-- ---------------------------------------------------------------------- 
-- Verify that all keys from a template table exist in a loaded table. 
-- ---------------------------------------------------------------------- 
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
 
-- ---------------------------------------------------------------------- 
-- Simple file helpers – read whole file, write whole file. 
-- ---------------------------------------------------------------------- 
local function writeFile(path, data) 
    local file = io.open(path, "w") 
    if not file then return false end 
    file:write(data) 
    file:close() 
    return true 
end 
 
local function readFile(path) 
    local file = io.open(path, "r") 
    if not file then return nil end 
    local content = file:read("*a") 
    file:close() 
    return content 
end 
 
-- Exported API 
Serializer.deepCopy      = deepCopy 
Serializer.serializeTable = serializeTable 
Serializer.keysMatch      = keysMatch 
Serializer.writeFile      = writeFile 
Serializer.readFile       = readFile 
 
return Serializer 
