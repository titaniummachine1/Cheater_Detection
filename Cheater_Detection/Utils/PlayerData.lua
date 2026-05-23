--[[ PlayerData.lua
     Compatibility shim. The lazy-fetch metatable system has been removed.
     pdata is now a plain table populated in-place by PlayerCache.SyncTick.
     Only PlayerData.GetEntity() is called externally (duck_speed.lua).
]]

local PlayerData = {}

--- Returns the live entity for a pdata shim table.
--- pdata._index is set by PlayerCache.SyncTick each tick.
--- Called by duck_speed.lua to get the entity for m_flMaxspeed.
---@param data table
---@return Entity|nil
function PlayerData.GetEntity(data)
    if not data then return nil end
    local index = data._index
    if not index then return nil end
    local ent = entities.GetByIndex(index)
    if not ent or not ent:IsValid() then return nil end
    return ent
end

--- No-op stub — pdata is now allocated by PlayerCache.SyncTick.
--- Kept so any stale require()+call sites do not error at load.
function PlayerData.ForEntity(_ent)
    return nil
end

return PlayerData
