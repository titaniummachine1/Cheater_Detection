--[[
Minimal HTTP docs smoke test.

Purpose:
- run one blocking http.Get call
- run one non-blocking http.GetAsync call
- print both responses and optionally echo async response to chat
]]

local URL = "https://catfact.ninja/fact"
local ECHO_ASYNC_TO_CHAT = true

local function PrintResponse(prefix, data)
    local text = tostring(data)
    print(string.format("[HTTP-DOCS] %s len=%d", prefix, #text))
    print(text)
end

local function OnAsyncResponse(data)
    PrintResponse("async", data)

    if ECHO_ASYNC_TO_CHAT and type(client) == "table" and type(client.ChatSay) == "function" then
        client.ChatSay(tostring(data))
    end
end

local function RunSyncExample()
    local ok, responseOrError = pcall(http.Get, URL)
    if not ok then
        print(string.format("[HTTP-DOCS] sync error: %s", tostring(responseOrError)))
        return
    end

    PrintResponse("sync", responseOrError)
end

local function RunAsyncExample()
    local ok, err = pcall(http.GetAsync, URL, OnAsyncResponse)
    if not ok then
        print(string.format("[HTTP-DOCS] async dispatch error: %s", tostring(err)))
        return
    end

    print("[HTTP-DOCS] async request dispatched")
end

RunSyncExample()
RunAsyncExample()
