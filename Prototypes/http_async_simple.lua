--[[
Simple http.GetAsync test - just like the API docs example.
No timeout, no complex logic, just print the result to console.
]]

local URL = "https://catfact.ninja/fact"

local function OnAsyncResponse(data)
    print("[HTTP-ASYNC-SIMPLE] Response received:")
    print(tostring(data))
    print("[HTTP-ASYNC-SIMPLE] Length: " .. #tostring(data) .. " bytes")
end

print("[HTTP-ASYNC-SIMPLE] Starting async request to: " .. URL)
http.GetAsync(URL, OnAsyncResponse)
print("[HTTP-ASYNC-SIMPLE] Request dispatched (callback will print result)")
