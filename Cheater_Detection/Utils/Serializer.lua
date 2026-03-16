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
-- Optimized to prevent trailing commas and correctly escape strings.
-- ----------------------------------------------------------------------
local function serializeTable(tbl, level, visited)
    level = level or 0
    visited = visited or {}
    local indent = string.rep("    ", level)
    local innerIndent = indent .. "    "
    local entries = {}

    for k, v in pairs(tbl) do
        local entry_chunks = {}

        -- Key representation
        local keyRepr = (type(k) == "string") and string.format('["%s"]', k) or string.format('[%s]', k)
        table.insert(entry_chunks, innerIndent .. keyRepr .. " = ")

        -- Value representation
        if type(v) == "table" then
            if visited[v] then
                table.insert(entry_chunks, '"--[[cycle]]"')
            else
                visited[v] = true
                table.insert(entry_chunks, serializeTable(v, level + 1, visited))
            end
        elseif type(v) == "string" then
            -- Sanitize string and escape characters
            local sanitized = v:gsub('[^%z\32-\126]', ''):sub(1, 128)
            sanitized = sanitized:gsub('\\', '\\\\'):gsub('"', '\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
            table.insert(entry_chunks, '"' .. sanitized .. '"')
        else
            table.insert(entry_chunks, tostring(v))
        end
        table.insert(entries, table.concat(entry_chunks))
    end

    if #entries == 0 then
        return "{}"
    end

    return "{\n" .. table.concat(entries, ",\n") .. "\n" .. indent .. "}"
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
Serializer.deepCopy       = deepCopy
Serializer.serializeTable = serializeTable
Serializer.keysMatch      = keysMatch
Serializer.writeFile      = writeFile
Serializer.readFile       = readFile

return Serializer
