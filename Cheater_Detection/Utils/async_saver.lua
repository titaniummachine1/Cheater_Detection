--[[
    AsyncSaver.lua
    Simulates asynchronous disk I/O by chunking data operations across frames.
    Prevents game stutters when saving large databases.
]]

--[[ Imports ]]
local G = require("Cheater_Detection.Utils.Globals")
local Json = require("Cheater_Detection.Libs.Json")

--[[ Module Declaration ]]
local AsyncSaver = {
    State = {
        pendingTasks = {},
        currentTask = nil,
    },
    Settings = {
        CHUNK_SIZE = 120 -- Number of table entries to process per tick
    }
}

--[[ Internal Helpers ]]

local function ProcessTask(task)
    if not task then return end

    -- State 1: Initialization
    if task.state == "INIT" then
        if task.type == "APPEND" then
            task.state = "WRITE"
        else
            task.state = "CLEANING"
            task.cleanedData = {}
            task.last_k = nil
        end
    end

    -- State 2: Chunked Table Cleaning/Optimization
    if task.state == "CLEANING" then
        local count = 0
        local k, v
        
        while count < AsyncSaver.Settings.CHUNK_SIZE do
            k, v = next(task.data, task.last_k)
            if k == nil then -- End of table
                task.state = "ENCODING_INIT"
                break
            end

            task.last_k = k
            
            -- Only save essential fields to optimize disk space and speed
            local clean = {}
            if type(v) == "table" then
                if v.Name and v.Name ~= "Unknown" then clean.Name = v.Name end
                if v.Reason and v.Reason ~= "Unknown Source" then clean.Reason = v.Reason end
                if v.Static then clean.Static = v.Static end
                if v.Flags and v.Flags ~= 0 then clean.Flags = v.Flags end
                if v.Score and v.Score ~= 0 then clean.Score = v.Score end
                task.cleanedData[k] = clean
            end
            
            count = count + 1
        end
        return -- Continue cleaning next tick
    end

    -- State 3: Encoding Initialization
    if task.state == "ENCODING_INIT" then
        task.state = "ENCODING"
        task.encodedChunks = {}
        task.last_k = nil
        task.isFirstChunk = true
        table.insert(task.encodedChunks, "{")
    end

    -- State 4: Chunked Encoding
    if task.state == "ENCODING" then
        local count = 0
        local k, v
        
        while count < AsyncSaver.Settings.CHUNK_SIZE do
            k, v = next(task.cleanedData, task.last_k)
            if k == nil then
                task.state = "ENCODING_DONE"
                break
            end

            task.last_k = k
            
            local success, encoded = pcall(Json.encode, v)
            if success then
                local prefix = task.isFirstChunk and "" or ","
                table.insert(task.encodedChunks, string.format('%s"%s":%s', prefix, tostring(k), encoded))
                task.isFirstChunk = false
            end
            
            count = count + 1
        end
        return
    end

    -- State 5: Finalize & Write
    if task.state == "ENCODING_DONE" then
        table.insert(task.encodedChunks, "}")
        task.fullContent = table.concat(task.encodedChunks)
        task.state = "WRITE"
    end

    -- State 6: Engine File Write
    if task.state == "WRITE" then
        local success = false
        local err = "Unknown"

        if task.type == "APPEND" then
            -- Note: filesystem.Write doesn't have an append mode usually,
            -- so we use io.open for append as it's more standard for logging.
            local f = io.open(task.path, "a")
            if f then
                f:write(tostring(task.data) .. "\n")
                f:close()
                success = true
            else
                err = "io.open failed for append"
            end
        else
            -- Use filesystem.Write for the full database save
            success = filesystem.Write(task.path, task.fullContent)
            if not success then err = "filesystem.Write failed" end
        end

        if success then
            task.state = "FINISHED"
        else
            task.state = "ERROR"
            task.error = err
        end
    end
end

--[[ Public API ]]

-- Saves the entire database asynchronously with chunked cleaning
function AsyncSaver.Save(path, data, callback)
    local task = {
        type = "SAVE",
        path = path,
        data = data,
        callback = callback,
        state = "INIT"
    }
    table.insert(AsyncSaver.State.pendingTasks, task)
end

-- Appends a single entry to a file (queued but fast)
function AsyncSaver.Append(path, content, callback)
    local task = {
        type = "APPEND",
        path = path,
        data = content, -- raw string
        fullContent = content,
        callback = callback,
        state = "INIT"
    }
    table.insert(AsyncSaver.State.pendingTasks, task)
end

function AsyncSaver.Tick()
    if #AsyncSaver.State.pendingTasks == 0 and not AsyncSaver.State.currentTask then
        return
    end

    if not AsyncSaver.State.currentTask then
        AsyncSaver.State.currentTask = table.remove(AsyncSaver.State.pendingTasks, 1)
    end

    local task = AsyncSaver.State.currentTask
    ProcessTask(task)

    if task.state == "FINISHED" or task.state == "ERROR" then
        if task.callback then
            pcall(task.callback, task.state == "FINISHED", task.error)
        end
        AsyncSaver.State.currentTask = nil
    end
end

return AsyncSaver
