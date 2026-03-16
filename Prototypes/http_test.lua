-- Advanced Source HTTP Test for Lmaobox - USERDATA VERSION
-- 'http' is userdata, meaning we can't iterate it, but we can call it.

local urls = {
    "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
    "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.rgl-gg.json",
}

print("\n--- [HTTP USERDATA TEST START] ---")
print("http type: " .. type(http))

for i, url in ipairs(urls) do
    print(string.format("\n[%d] TARGET: %s", i, url))
    
    -- Test http.Get (Common pattern for userdata libraries)
    print("  -> Attempting pcall(http.Get, url)...")
    local ok, content = pcall(function() return http.Get(url) end)
    if ok and content then
        print(string.format("     [Get] SUCCESS! Length: %d", #content))
    else
        print("     [Get] FAILED: " .. tostring(content))
    end

    -- Test http.GetAsync
    print("  -> Attempting pcall(http.GetAsync, url, cb)...")
    local okAsync, errAsync = pcall(function() 
        http.GetAsync(url, function(content)
            if content then
                print(string.format("     [Async][%d] SUCCESS! Length: %d", i, #content))
            else
                print(string.format("     [Async][%d] FAILED: Nil content", i))
            end
        end)
    end)
    
    if not okAsync then
        print("     [Async] FAILED to call: " .. tostring(errAsync))
    end
end

print("\n--- [HTTP USERDATA TEST END] ---")
