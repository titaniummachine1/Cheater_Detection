--[[ PlayerData.lua
     Lazy player data container - NEVER stores entity references.
     
     Design principles:
     1. Only stores entity INDEX (number), never the entity object
     2. All data is cached per-tick with automatic staleness detection
     3. Data is marked "dirty" when underlying properties might have changed
     4. Reading stale data returns nil (safe failure) - caller must handle
     
     This prevents crashes from stale entity pointers - we treat entities
     as radioactive C++ pointers that will crash if touched from wrong tick.
]]

local PlayerData = {}

local TICKCOUNT = globals.TickCount
local currentTick = -1

-- Forward declaration
local ensureFresh

-- Cache line: stores data with tick timestamp
-- { value = any, tick = number, dirty = boolean }
local cacheMeta = {
    __index = function(t, k)
        local entry = rawget(t, k)
        if not entry then return nil end
        
        -- Check if entry is from current tick
        if entry.tick ~= currentTick then
            -- Data is stale - mark as dirty and return nil
            entry.dirty = true
            return nil
        end
        
        return entry.value
    end,
    
    __newindex = function(t, k, v)
        -- Always store with current tick
        rawset(t, k, { value = v, tick = currentTick, dirty = false })
    end
}

-- Per-player data container
local PlayerDataMT = {}

function PlayerDataMT.__index(self, key)
    -- Check if we have cached data
    local cache = rawget(self, "_cache")
    if not cache then
        cache = setmetatable({}, cacheMeta)
        rawset(self, "_cache", cache)
    end
    
    local cached = cache[key]
    if cached ~= nil then
        return cached
    end
    
    -- No cached data - need to fetch from entity
    local index = rawget(self, "_index")
    if not index then
        return nil
    end
    
    -- Validate we're on current tick before touching entity
    local dataTick = rawget(self, "_tick")
    if dataTick ~= currentTick then
        -- This PlayerData is from a previous tick - radioactive!
        -- Return nil and force caller to get fresh data
        return nil
    end
    
    -- Fetch from entity (safe because we're on current tick)
    local ent = entities.GetByIndex(index)
    if not ent or not ent:IsValid() then
        return nil
    end
    
    -- Call the fetcher if defined
    local fetchers = rawget(self, "_fetchers")
    if fetchers and fetchers[key] then
        local ok, result = pcall(fetchers[key], ent)
        if ok then
            cache[key] = result
            return result
        end
        return nil
    end
    
    return nil
end

function PlayerDataMT.__newindex(self, key, value)
    local cache = rawget(self, "_cache")
    if not cache then
        cache = setmetatable({}, cacheMeta)
        rawset(self, "_cache", cache)
    end
    cache[key] = value
    
    -- Mark as dirty for this tick
    local dirtyFlags = rawget(self, "_dirty") or {}
    dirtyFlags[key] = true
    rawset(self, "_dirty", dirtyFlags)
end

-- Property fetchers - these are the ONLY places that touch entity APIs
local defaultFetchers = {
    -- Position/velocity (expensive, cache these)
    origin = function(ent)
        return ent:GetAbsOrigin()
    end,
    
    velocity = function(ent)
        return ent:EstimateAbsVelocity()
    end,
    
    eyePos = function(ent)
        local origin = ent:GetAbsOrigin()
        local viewOffset = ent:GetPropVector("localdata", "m_vecViewOffset[0]")
        if origin and viewOffset then
            return origin + viewOffset
        end
        return nil
    end,
    
    eyeAngles = function(ent)
        if ent:GetIndex() == client.GetLocalPlayerIndex() then
            return engine.GetViewAngles()
        end
        local ang = ent:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
        if ang then
            return EulerAngles(ang.x, ang.y, ang.z)
        end
        ang = ent:GetPropVector("m_angEyeAngles[0]")
        if ang then
            return EulerAngles(ang.x, ang.y, ang.z)
        end
        return nil
    end,
    
    isAlive = function(ent)
        return ent:IsAlive()
    end,
    
    isDormant = function(ent)
        return ent:IsDormant()
    end,
    
    team = function(ent)
        return ent:GetTeamNumber()
    end,
    
    health = function(ent)
        return ent:GetHealth()
    end,
    
    class = function(ent)
        return ent:GetClass()
    end,
    
    flags = function(ent)
        return ent:GetPropInt("m_fFlags")
    end,
    
    onGround = function(ent)
        local flags = ent:GetPropInt("m_fFlags")
        return (flags & 1) ~= 0  -- FL_ONGROUND
    end,
    
    simTime = function(ent)
        return ent:GetPropFloat("m_flSimulationTime")
    end,
    
    weapon = function(ent)
        return ent:GetPropEntity("m_hActiveWeapon")
    end,
    
    -- SteamID (never changes, fetch once and cache permanently)
    steamID = function(ent)
        local info = client.GetPlayerInfo(ent:GetIndex())
        if not info then return nil end
        
        if info.IsBot or info.IsHLTV or info.SteamID == "[U:1:0]" then
            return "BOT_" .. tostring(info.UserID or ent:GetIndex())
        end
        
        -- Convert to SteamID64
        local steamID = info.SteamID
        if not steamID then return nil end
        
        -- Already SteamID64 format
        local steam64 = steamID:match("^(765%d+)$")
        if steam64 and #steam64 >= 17 then
            return steam64
        end
        
        -- [U:1:XXXX] format
        local accountID = steamID:match("^%[U:1:(%d+)%]$")
        if accountID then
            local numeric = tonumber(accountID)
            if numeric then
                return tostring(76561197960265728 + numeric)
            end
        end
        
        -- Try steam.ToSteamID64 if available
        if steam and steam.ToSteamID64 then
            local converted = steam.ToSteamID64(steamID)
            if converted then
                return tostring(converted)
            end
        end
        
        return nil
    end,
    
    name = function(ent)
        local info = client.GetPlayerInfo(ent:GetIndex())
        return info and info.Name
    end,
}

-- Create PlayerData for current tick
function PlayerData.ForEntity(ent)
    if not ent or not ent:IsValid() then
        return nil
    end
    
    local index = ent:GetIndex()
    if not index then
        return nil
    end
    
    -- Update current tick
    currentTick = TICKCOUNT()
    
    local data = setmetatable({}, PlayerDataMT)
    rawset(data, "_index", index)
    rawset(data, "_tick", currentTick)
    rawset(data, "_cache", setmetatable({}, cacheMeta))
    rawset(data, "_fetchers", defaultFetchers)
    rawset(data, "_dirty", {})
    
    -- Pre-fetch steamID (it's permanent)
    local steamID = defaultFetchers.steamID(ent)
    if steamID then
        rawset(data, "_steamID", steamID)
        -- Store steamID in cache permanently
        local cache = rawget(data, "_cache")
        cache.steamID = steamID
        -- Override tick to make it permanent
        rawset(cache, "steamID", { value = steamID, tick = math.huge, dirty = false })
    end
    
    return data
end

-- Create PlayerData from index (only if entity is valid this tick)
function PlayerData.ForIndex(index)
    if type(index) ~= "number" then
        return nil
    end
    
    currentTick = TICKCOUNT()
    
    local ent = entities.GetByIndex(index)
    if not ent or not ent:IsValid() then
        return nil
    end
    
    return PlayerData.ForEntity(ent)
end

-- Get steamID without creating full PlayerData
function PlayerData.GetSteamID(index)
    local ent = entities.GetByIndex(index)
    if not ent or not ent:IsValid() then
        return nil
    end
    return defaultFetchers.steamID(ent)
end

-- Get entity safely - only if on current tick and valid
function PlayerData.GetEntity(data)
    if not data then return nil end
    
    local dataTick = rawget(data, "_tick")
    if dataTick ~= TICKCOUNT() then
        return nil -- Stale data - entity would be radioactive
    end
    
    local index = rawget(data, "_index")
    if not index then
        return nil
    end
    
    local ent = entities.GetByIndex(index)
    if not ent or not ent:IsValid() then
        return nil
    end
    
    return ent
end

-- Check if PlayerData is still valid for current tick
function PlayerData.IsValid(data)
    if not data then return false end
    
    local dataTick = rawget(data, "_tick")
    if dataTick ~= TICKCOUNT() then
        return false
    end
    
    local index = rawget(data, "_index")
    if not index then
        return false
    end
    
    -- Entity must still be valid
    local ent = entities.GetByIndex(index)
    return ent and ent:IsValid()
end

-- Force refresh of a specific key
function PlayerData.Refresh(data, key)
    if not PlayerData.IsValid(data) then
        return nil
    end
    
    local index = rawget(data, "_index")
    local ent = entities.GetByIndex(index)
    if not ent then
        return nil
    end
    
    local fetchers = rawget(data, "_fetchers")
    if fetchers and fetchers[key] then
        local ok, result = pcall(fetchers[key], ent)
        if ok then
            local cache = rawget(data, "_cache")
            cache[key] = result
            return result
        end
    end
    return nil
end

-- Check if data is dirty (was modified this tick)
function PlayerData.IsDirty(data, key)
    local dirtyFlags = rawget(data, "_dirty")
    if not dirtyFlags then return false end
    return dirtyFlags[key] == true
end

-- Clear dirty flag
function PlayerData.ClearDirty(data, key)
    local dirtyFlags = rawget(data, "_dirty")
    if dirtyFlags then
        dirtyFlags[key] = nil
    end
end

-- Get raw index (for advanced use only)
function PlayerData.GetIndex(data)
    return rawget(data, "_index")
end

return PlayerData
