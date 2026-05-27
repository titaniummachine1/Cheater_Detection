-- Benchmark: SetupBones vs GetHitboxes
-- Uses fixed time window + iteration count (accurate for fast ops)
-- Run: dofile("Cheater_Detection/Prototypes/hitbox_benchmark.lua")

--Benchmarking calls per 1.0s...

--GetHitboxes: 24747 calls/sec (24747)
--SetupBones:  5486 calls/sec (5486)
--Speedup: 4.5x


local p = entities.GetLocalPlayer()
if not p or not p:IsValid() then
    print("No local player")
    return
end

local DURATION = 1

local function benchGetHitboxes()
    local n, t0 = 0, os.clock()
    while os.clock() - t0 < DURATION do
        local hb = p:GetHitboxes()
        if hb and hb[1] then local pos = (hb[1][1] + hb[1][2]) * 0.5 end
        n = n + 1
    end
    return n
end

local function benchSetupBones()
    local n, t0 = 0, os.clock()
    while os.clock() - t0 < DURATION do
        local b = p:SetupBones()
        if b and b[1] then local pos = Vector3(b[1][1][4], b[1][2][4], b[1][3][4]) end
        n = n + 1
    end
    return n
end

print(string.format("Benchmarking calls per %.1fs...", DURATION))

local c1, c2 = benchGetHitboxes(), benchSetupBones()

print(string.format("\nGetHitboxes: %d calls/sec (%.0f)", c1, c1 / DURATION))
print(string.format("SetupBones:  %d calls/sec (%.0f)", c2, c2 / DURATION))
if c2 > 0 then print(string.format("Speedup: %.1fx", c1 / c2)) end
