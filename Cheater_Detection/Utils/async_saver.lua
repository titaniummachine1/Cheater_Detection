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
        isProcessing = false
    },
    Settings = {
        CHUNK_SIZE = 100 -- Number of table entries to encode per tick
    }
}

--[[ Internal Helpers ]]

local function ProcessTask(task)
    if not task then return end

    -- State 1: Start Encoding
    if task.state == "INIT" then
        task.state = "ENCODING"
        task.iterator = pairs(task.data)
        task.encodedChunks = {}
        task.currentChunkCount = 0
        task.isFirstChunk = true
        table.insert(task.encodedChunks, "{")
    end

    -- State 2: Chunked Encoding
    if task.state == "ENCODING" then
        local count = 0
        local k, v
        
        while count < AsyncSaver.Settings.CHUNK_SIZE do
            k, v = task.iterator(task.data, task.last_k)
            if not k then
                task.state = "ENCODING_DONE"
                break
            end

            task.last_k = k
            
            -- Encode single entry
            local success, encoded = pcall(Json.encode, v)
            if success then
                local prefix = task.isFirstChunk and "" or ","
                table.insert(task.encodedChunks, string.format('%s"%s":%s', prefix, tostring(k), encoded))
                task.isFirstChunk = false
            end
            
            count = count + 1
        end
        return -- Continue encoding next tick
    end

    -- State 3: Finalize String & Write
    if task.state == "ENCODING_DONE" then
        table.insert(task.encodedChunks, "}")
        local fullData = table.concat(task.encodedChunks)
        
        -- The write itself is synchronous but at least encoding was staggered
        local file = io.open(task.path, "w")
        if file then
            file:write(fullData)
            file:close()
            task.state = "FINISHED"
        else
            task.state = "ERROR"
            task.error = "Could not open file: " .. tostring(task.path)
        end
    end
end

--[[ Public API ]]

function AsyncSaver.Save(path, data, callback)
    assert(path, "AsyncSaver.Save: path missing")
    assert(data, "AsyncSaver.Save: data missing")

    local task = {
        path = path,
        data = data,
        callback = callback,
        state = "INIT",
        last_k = nil
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
