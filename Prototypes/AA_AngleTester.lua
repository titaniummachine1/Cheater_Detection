--[[
    AA Angle Lookup Table Tester
    Author: github.com/titaniummachine1

    F key -> cycle EXPECTED target shoot angle (6 resolver cycle positions)
    R key -> cycle OUR real head offset        (8 x 45 deg positions)
    G key -> print current lookup table to console
    H key -> reset lookup table

    Records hit/miss/headshot outcomes per (expectedAngle, headOffset) combination
    to build a full 6x8 lookup table for resolver avoidance.
]]
client.Command("clear", true)
assert(pcall(require, "lnxLib"), "lnxLib not found, please install it!")
---@type boolean, lnxLib
local _, lnxLib         = pcall(require, "lnxLib")

local Math              = lnxLib.Utils.Math

-- ============================================================
-- F KEY: expected angle the TARGET will shoot at us from
-- 6 positions matching the known resolver cycle.
-- Offsets are relative to the attacker->us direction (0 = straight at us).
-- ============================================================
local EXPECTED_NAMES    = { "default(0)", "left(-90)", "right(90)", "invert(180)", "forward(0)", "back(180)" }
local EXPECTED_OFFSETS  = { 0, -90, 90, 180, 0, 180 }
local expectedIdx       = 1

-- ============================================================
-- R KEY: where WE put our real head hitbox
-- 8 segments x 45 deg, relative to the direction toward the target.
-- 0   = head pointing toward target  (most dangerous)
-- 90  = head to our right
-- 180 = head pointing away
-- 270 = head to our left
-- ============================================================
local REAL_HEAD_NAMES   = {
    "toward(0)", "+45(45)", "right(90)", "+135(135)",
    "away(180)", "-135(225)", "left(270)", "-45(315)"
}
local REAL_HEAD_OFFSETS = { 0, 45, 90, 135, 180, 225, 270, 315 }
local realHeadIdx       = 3 -- default: right(90)

-- ============================================================
-- Lookup table: results[expectedIdx][realHeadIdx] = { miss, body, head }
-- ============================================================
local results           = {}
for e = 1, #EXPECTED_NAMES do
    results[e] = {}
    for r = 1, #REAL_HEAD_NAMES do
        results[e][r] = { miss = 0, body = 0, head = 0 }
    end
end

-- ============================================================
-- Shot tracking: one slot per shooter
-- CTEFireBullets sets the slot; player_hurt resolves it; flush = miss
-- ============================================================
local MISS_WINDOW      = 0.5 -- seconds before an unresolved shot is counted as miss
local recentShots      = {}  -- [shooterIndex] = { time, capturedExp, capturedHead }
local lastHitTime      = {}  -- [shooterIndex] = time of last resolved hit (blocks ghost slots)

-- ============================================================
-- Key state
-- ============================================================
local prevDown_F       = false
local prevDown_R       = false
local prevDown_G       = false
local prevDown_H       = false

local jitterlegEnabled = true

-- ============================================================
-- Helpers
-- ============================================================
local function normalizeAngle(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

local function printStatus()
    local expName  = EXPECTED_NAMES[expectedIdx]
    local headName = REAL_HEAD_NAMES[realHeadIdx]
    printc(100, 220, 255, 255,
        string.format("[AA-Tester] Expected: %-14s | Head: %s", expName, headName))
end

local function printLookupTable()
    printc(255, 220, 50, 255, "===== AA LOOKUP TABLE (miss/body/HEAD) =====")
    -- Header
    local header = string.format("%-14s", "head\\exp")
    for e = 1, #EXPECTED_NAMES do
        header = header .. string.format(" | %-13s", EXPECTED_NAMES[e])
    end
    header = header .. " | survive%"
    printc(200, 200, 200, 255, header)
    printc(200, 200, 200, 255, string.rep("-", #header))
    for r = 1, #REAL_HEAD_NAMES do
        local row   = string.format("%-14s", REAL_HEAD_NAMES[r])
        local total = 0
        local safe  = 0
        for e = 1, #EXPECTED_NAMES do
            local cell  = results[e][r]
            local shots = cell.miss + cell.body + cell.head
            total       = total + shots
            safe        = safe + cell.miss + cell.body
            row         = row .. string.format(" | %dM %dB %dH   ", cell.miss, cell.body, cell.head)
        end
        local pct
        if total > 0 then pct = math.floor(safe / total * 100) else pct = 0 end
        local r_c = math.floor((100 - pct) * 2.55)
        local g_c = math.floor(pct * 2.55)
        row       = row .. string.format("| %3d%%", pct)
        printc(r_c, g_c, 50, 255, row)
    end
    printc(255, 220, 50, 255, string.rep("-", 100))
    -- Raw JSON-style dump for easy copy
    printc(200, 200, 200, 255, "-- RAW DUMP (copy below) --")
    for r = 1, #REAL_HEAD_NAMES do
        for e = 1, #EXPECTED_NAMES do
            local c = results[e][r]
            if c.miss + c.body + c.head > 0 then
                printc(200, 200, 200, 255, string.format(
                    "  [exp=%s][head=%s] M=%d B=%d H=%d",
                    EXPECTED_NAMES[e], REAL_HEAD_NAMES[r], c.miss, c.body, c.head))
            end
        end
    end
    printc(255, 220, 50, 255, "============================================")
end

local function resetLookupTable()
    for e = 1, #EXPECTED_NAMES do
        for r = 1, #REAL_HEAD_NAMES do
            results[e][r] = { miss = 0, body = 0, head = 0 }
        end
    end
    printc(255, 100, 100, 255, "[AA-Tester] Lookup table RESET")
end

-- ============================================================
-- Apply yaw to lmaobox AA GUI
-- GUI "Custom Yaw" values are offsets relative to our view forward.
-- Derive view yaw from Forward() vector (matches A_AA.lua forceFreestanding).
-- targetWorldYaw : world-space yaw from us toward target (degrees)
-- realHeadOffset : how far our real head is rotated from target direction
-- ============================================================
local function applyYaw(realHeadOffset, targetWorldYaw)
    local fwd     = engine.GetViewAngles():Forward()
    local viewYaw = math.deg(math.atan(fwd.y, fwd.x))

    local fakeGui = normalizeAngle(targetWorldYaw - viewYaw)
    local realGui = normalizeAngle(targetWorldYaw + realHeadOffset - viewYaw)

    gui.SetValue("Anti Aim - Custom Yaw (Fake)", math.floor(fakeGui))
    gui.SetValue("Anti Aim - Custom Yaw (Real)", math.floor(realGui))
end

-- ============================================================
-- Record outcome into lookup table and log it
-- ============================================================
local function recordOutcome(capturedExp, capturedHead, damage, shotterName)
    if capturedExp < 1 or capturedHead < 1 then return end
    local cell = results[capturedExp][capturedHead]
    local outcome
    if damage == 0 then
        cell.miss = cell.miss + 1
        outcome   = "MISS"
    elseif damage > 50 then
        cell.head = cell.head + 1
        outcome   = "HEADSHOT"
    else
        cell.body = cell.body + 1
        outcome   = "body"
    end

    local expName  = EXPECTED_NAMES[capturedExp]
    local headName = REAL_HEAD_NAMES[capturedHead]
    local cell2    = results[capturedExp][capturedHead]
    local r_c      = outcome == "MISS" and 100 or (outcome == "HEADSHOT" and 255 or 200)
    local g_c      = outcome == "MISS" and 220 or (outcome == "body" and 200 or 80)
    printc(r_c, g_c, 100, 255,
        string.format("[AA-Tester] %s | exp=%-14s head=%-12s dmg=%d  [M:%d B:%d H:%d]",
            outcome, expName, headName, damage, cell2.miss, cell2.body, cell2.head))
end


-- ============================================================
-- FireGameEvent: player_hurt resolves the pending shot slot
-- ============================================================
local function OnGameEvent(ev)
    if ev:GetName() ~= "player_hurt" then return end
    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer then return end

    local victim   = entities.GetByUserID(ev:GetInt("userid"))
    local attacker = entities.GetByUserID(ev:GetInt("attacker"))
    if victim ~= localPlayer then return end
    if not attacker or attacker == localPlayer then return end

    local idx  = attacker:GetIndex()
    local dmg  = ev:GetInt("damageamount")
    local slot = recentShots[idx]
    if slot and (globals.CurTime() - slot.time) <= MISS_WINDOW then
        recordOutcome(slot.capturedExp, slot.capturedHead, dmg, attacker:GetName() or "?")
    else
        recordOutcome(expectedIdx, realHeadIdx, dmg, attacker:GetName() or "?")
    end
    recentShots[idx] = nil
    lastHitTime[idx] = globals.CurTime()
end

-- ============================================================
-- ProcessTempEntities: CTEFireBullets creates/refreshes the shot slot
-- ============================================================
local function OnProcessTempEntities(entEvtTable)
    local localPlayer = entities.GetLocalPlayer()
    if not localPlayer then return end
    local now = globals.CurTime()

    for ent, _ in pairs(entEvtTable) do
        if ent:GetNetworkName() == "CTEFireBullets" then
            local shooterIndex = ent:GetPropInt("m_iPlayer") + 1
            if shooterIndex > 1 and shooterIndex ~= localPlayer:GetIndex() then
                local shooter = entities.GetByIndex(shooterIndex)
                if shooter and shooter:IsAlive()
                    and shooter:GetTeamNumber() ~= localPlayer:GetTeamNumber() then
                    local lastHit = lastHitTime[shooterIndex]
                    if lastHit and (now - lastHit) < MISS_WINDOW then
                        -- shot was just resolved as a hit; ignore duplicate CTEFireBullets
                    else
                        local existing = recentShots[shooterIndex]
                        if not existing or (now - existing.time) > 0.05 then
                            recentShots[shooterIndex] = {
                                time         = now,
                                capturedExp  = expectedIdx,
                                capturedHead = realHeadIdx,
                            }
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- Flush expired unresolved shots as MISS
-- ============================================================
local function flushMissedShots()
    local now = globals.CurTime()
    for idx, slot in pairs(recentShots) do
        if (now - slot.time) > MISS_WINDOW then
            local shooter = entities.GetByIndex(idx)
            recordOutcome(slot.capturedExp, slot.capturedHead, 0, shooter and shooter:GetName() or "?")
            recentShots[idx] = nil
        end
    end
end

-- ============================================================
-- CreateMove
-- ============================================================
local function OnCreateMove(userCmd)
    local pLocal = entities.GetLocalPlayer()
    if not pLocal or not pLocal:IsAlive() then return end

    flushMissedShots()

    -- Jitterleg runs unconditionally so AA angles always update each tick
    if userCmd.sidemove == 0 then
        userCmd:SetSideMove(userCmd.command_number % 2 == 0 and 33 or -33)
    elseif userCmd.forwardmove == 0 then
        userCmd:SetForwardMove(userCmd.command_number % 2 == 0 and 3 or -3)
    end

    -- Key F: cycle expected target angle (rising edge)
    local downF = input.IsButtonDown(KEY_F)
    if downF and not prevDown_F then
        expectedIdx = (expectedIdx % #EXPECTED_NAMES) + 1
        recentShots = {} -- discard queued shots from previous combo
        printStatus()
    end
    prevDown_F = downF

    -- Key R: cycle our real head offset (rising edge)
    local downR = input.IsButtonDown(KEY_R)
    if downR and not prevDown_R then
        realHeadIdx = (realHeadIdx % #REAL_HEAD_NAMES) + 1
        recentShots = {} -- discard queued shots from previous combo
        printStatus()
    end
    prevDown_R = downR

    -- Key G: print lookup table (rising edge)
    local downG = input.IsButtonDown(KEY_G)
    if downG and not prevDown_G then
        printLookupTable()
    end
    prevDown_G = downG

    -- Key H: reset lookup table (rising edge)
    local downH = input.IsButtonDown(KEY_H)
    if downH and not prevDown_H then
        resetLookupTable()
    end
    prevDown_H        = downH

    -- Find best enemy target (closest to crosshair)
    local localOrigin = pLocal:GetAbsOrigin()
    local viewOffset  = pLocal:GetPropVector("localdata", "m_vecViewOffset[0]") or Vector3(0, 0, 70)
    local localEye    = localOrigin + viewOffset
    local viewAngles  = engine.GetViewAngles()

    local bestTarget  = nil
    local bestFov     = math.huge

    for _, player in pairs(entities.FindByClass("CTFPlayer")) do
        if player == pLocal then goto skip end
        if player:GetTeamNumber() == pLocal:GetTeamNumber() then goto skip end
        if not player:IsAlive() then goto skip end
        if player:IsDormant() then goto skip end

        local enemyPos = player:GetAbsOrigin() + Vector3(0, 0, 75)
        local toEnemy  = Math.PositionAngles(localEye, enemyPos)
        local fov      = Math.AngleFov(viewAngles, toEnemy)
        if fov < bestFov then
            bestFov    = fov
            bestTarget = player
        end

        ::skip::
    end

    if not bestTarget then return end

    local targetOrigin   = bestTarget:GetAbsOrigin()
    local targetWorldYaw = math.deg(math.atan(targetOrigin.y - localOrigin.y, targetOrigin.x - localOrigin.x))

    applyYaw(REAL_HEAD_OFFSETS[realHeadIdx], targetWorldYaw)
end

-- ============================================================
-- Draw: HUD overlay — current state + compact lookup grid
-- ============================================================
local font_hud   = draw.CreateFont("Verdana", 13, 800)
local font_small = draw.CreateFont("Verdana", 11, 400)

local function OnDraw()
    local pLocal = entities.GetLocalPlayer()
    if not pLocal or not pLocal:IsAlive() then return end
    local gameUIVisible  = engine.IsGameUIVisible()
    local consoleVisible = engine.Con_IsVisible()
    if gameUIVisible or consoleVisible then return end

    local sw, sh = draw.GetScreenSize()

    -- ── Status panel (bottom-left) ──
    draw.SetFont(font_hud)
    local sx, sy   = 10, sh - 96

    local expName  = EXPECTED_NAMES[expectedIdx]
    local headName = REAL_HEAD_NAMES[realHeadIdx]

    draw.Color(0, 0, 0, 170)
    draw.FilledRect(sx - 4, sy - 4, sx + 370, sy + 76)

    draw.Color(100, 220, 255, 255)
    draw.Text(sx, sy, "[AA-Tester]  F=expected  R=head  G=print  H=reset")
    draw.Color(255, 255, 100, 255)
    draw.Text(sx, sy + 16, "  Expected resolver : " .. expName)
    draw.Color(100, 255, 100, 255)
    draw.Text(sx, sy + 32, "  Our head offset   : " .. headName)

    -- Totals for current combination
    local cell = results[expectedIdx][realHeadIdx]
    local tot  = cell.miss + cell.body + cell.head
    local surv = cell.miss + cell.body
    local pct
    if tot > 0 then pct = math.floor(surv / tot * 100) else pct = 0 end
    local rc = math.floor((100 - pct) * 2.55)
    local gc = math.floor(pct * 2.55)
    draw.Color(rc, gc, 80, 255)
    draw.Text(sx, sy + 48,
        string.format("  This combo: M=%d B=%d HS=%d  survive=%d%%  (tot=%d)",
            cell.miss, cell.body, cell.head, pct, tot))

    -- ── Compact lookup grid (fixed left, below status panel) ──
    draw.SetFont(font_small)
    local COL_W = 62
    local ROW_H = 14
    local gx    = 10
    local gy    = sh - 110 - (#REAL_HEAD_NAMES + 1) * ROW_H

    -- Header row (expected angle names)
    draw.Color(0, 0, 0, 170)
    draw.FilledRect(gx - 2, gy - 2,
        gx + 80 + #EXPECTED_NAMES * COL_W + 4,
        gy + (#REAL_HEAD_NAMES + 1) * ROW_H + 6)

    local LABEL_W = 80
    draw.Color(100, 220, 255, 255)
    draw.Text(gx, gy, "head\\exp")
    for e = 1, #EXPECTED_NAMES do
        local label = EXPECTED_NAMES[e]:match("^(%a+)") or EXPECTED_NAMES[e]
        if e == expectedIdx then
            draw.Color(255, 255, 0, 255)
        else
            draw.Color(180, 180, 180, 255)
        end
        draw.Text(gx + LABEL_W + (e - 1) * COL_W, gy, label)
    end

    for r = 1, #REAL_HEAD_NAMES do
        local ry     = gy + r * ROW_H
        local rlabel = REAL_HEAD_NAMES[r]:match("^([^(]+)") or REAL_HEAD_NAMES[r]
        if r == realHeadIdx then
            draw.Color(100, 255, 100, 255)
        else
            draw.Color(180, 180, 180, 255)
        end
        draw.Text(gx, ry, rlabel)

        for e = 1, #EXPECTED_NAMES do
            local c = results[e][r]
            local t = c.miss + c.body + c.head
            local sp
            if t > 0 then sp = math.floor((c.miss + c.body) / t * 100) else sp = -1 end
            local rc2, gc2
            if sp < 0 then
                rc2 = 150; gc2 = 150
            else
                rc2 = math.floor((100 - sp) * 2.55); gc2 = math.floor(sp * 2.55)
            end

            local cx = gx + LABEL_W + (e - 1) * COL_W
            if e == expectedIdx and r == realHeadIdx then
                draw.Color(0, 0, 0, 200)
                draw.FilledRect(cx - 1, ry - 1, cx + COL_W - 2, ry + ROW_H - 1)
                draw.Color(255, 255, 0, 255)
            else
                draw.Color(rc2, gc2, 80, 255)
            end

            local cellStr
            if t == 0 then
                cellStr = "  - "
            else
                cellStr = string.format("%dM%dB%dH", c.miss, c.body, c.head)
            end
            draw.Text(cx, ry, cellStr)
        end
    end
end

-- ============================================================
-- Register / unregister cleanly
-- ============================================================
callbacks.Unregister("CreateMove", "AATester_CM")
callbacks.Unregister("Draw", "AATester_Draw")
callbacks.Unregister("FireGameEvent", "AATester_Events")
callbacks.Unregister("ProcessTempEntities", "AATester_PTE")

callbacks.Register("CreateMove", "AATester_CM", OnCreateMove)
callbacks.Register("Draw", "AATester_Draw", OnDraw)
callbacks.Register("FireGameEvent", "AATester_Events", OnGameEvent)
callbacks.Register("ProcessTempEntities", "AATester_PTE", OnProcessTempEntities)

printc(100, 220, 255, 255, "[AA-Tester] Loaded  |  F=expected  R=head  G=print table  H=reset")
printc(200, 200, 200, 255, "[AA-Tester] All player view angles on load:")
for _, player in pairs(entities.FindByClass("CTFPlayer")) do
    local angles = player:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
    if angles then
        local name = player:GetName() or "?"
        local idx  = player:GetIndex()
        printc(200, 200, 200, 255,
            string.format("  [%d] %s: yaw=%.2f pitch=%.2f", idx, name, angles.y, angles.x))
    end
end
printStatus()
