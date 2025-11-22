# Codebase Audit - Technical Debt & Liabilities

## Critical Issues

### 1. ❌ **Deprecated G.PlayerData Usage**

**What:** `G.PlayerData` is now an alias for `PlayerState.ActivePlayers` (line 14 in PlayerState.lua), but old code accesses deprecated fields directly.

**Problem Files:**

#### **Utils/Common.lua (lines 152-153)**

```lua
-- DEPRECATED - accesses non-existent fields
local strikes = G.PlayerData[steamId] and G.PlayerData[steamId].info.Strikes or 0
local isMarkedCheater = G.PlayerData[steamId] and G.PlayerData[steamId].info.isCheater
```

**Fix:** Use Evidence.IsMarkedCheater() instead

```lua
local isMarkedCheater = Evidence.IsMarkedCheater(steamId)
```

**Impact:** `Common.IsCheater()` relies on deprecated fields that don't exist, making the function unreliable.

---

#### **Misc/ChatPrefix.lua (lines 101-102)**

```lua
-- DEPRECATED - direct access to Evidence
if G.PlayerData[steamID] and G.PlayerData[steamID].Evidence then
    local evidence = G.PlayerData[steamID].Evidence
```

**Fix:** Use Evidence.GetEvidence()

```lua
local evidence = Evidence.GetEvidence(steamID)
if evidence and evidence.TotalScore and evidence.TotalScore > 0 then
```

---

#### **Detection Methods/detection_template.lua (lines 48-78)**

```lua
-- ENTIRE FILE USES OLD PATTERN - COMPLETELY DEPRECATED
if not G.PlayerData[steamID] then
    G.PlayerData[steamID] = {}
end

if not G.PlayerData[steamID].detections then
    G.PlayerData[steamID].detections = {}
end
```

**Status:** Template file not actively used, but misleading for new detection methods.

**Fix:** Delete or rewrite to use Evidence.AddEvidence() directly with proper thresholding.

---

### 2. ❌ **Redundant Callback Registrations (Not Using EventManager)**

**Problem:** 11 modules still use old `callbacks.Register()` pattern instead of EventManager.

**Modules to Migrate:**

| File                      | Callbacks                                      | Priority |
| ------------------------- | ---------------------------------------------- | -------- |
| **JoinNotifications.lua** | FireGameEvent, CreateMove                      | Medium   |
| **Vote_Revel.lua**        | DispatchUserMessage, FireGameEvent, Draw       | Low      |
| **Auto_Vote.lua**         | CreateMove, DispatchUserMessage, FireGameEvent | Low      |
| **SteamHistory.lua**      | FireGameEvent, CreateMove                      | Low      |
| **ChatPrefix.lua**        | DispatchUserMessage                            | Low      |
| **Menu.lua**              | Draw                                           | Low      |
| **Visuals.lua**           | Draw                                           | Low      |
| **TickProfiler.lua**      | Draw                                           | Low      |
| **Config.lua**            | Unload                                         | Low      |
| **Common.lua**            | Unload                                         | Low      |
| **Database.lua**          | Unload                                         | Low      |

**Reason:** These work fine, but not worth touching unless adding features. EventManager is primarily beneficial for consolidating multiple handlers per event type (like Main.lua had).

**Action:** Keep as-is for now. Only migrate if adding new event handlers.

---

### 3. ⚠️ **Common.IsCheater() Function Issues**

**Location:** `Utils/Common.lua` lines 109-158

**Problems:**

1. Accesses deprecated `G.PlayerData[steamId].info.Strikes` (doesn't exist)
2. Accesses deprecated `G.PlayerData[steamId].info.isCheater` (use Evidence instead)
3. Redundant with `Evidence.IsMarkedCheater()`

**Current Code:**

```lua
function Common.IsCheater(playerInfo)
    -- ... steamID extraction ...

    -- DEPRECATED: These fields don't exist in new architecture
    local strikes = G.PlayerData[steamId] and G.PlayerData[steamId].info.Strikes or 0
    local isMarkedCheater = G.PlayerData[steamId] and G.PlayerData[steamId].info.isCheater

    local inDatabase = G.DataBase[steamId] ~= nil
    local priorityCheater = playerlist.GetPriority(steamId) == 10

    return isMarkedCheater or inDatabase or priorityCheater
end
```

**Fix:**

```lua
function Common.IsCheater(playerInfo)
    -- ... steamID extraction ...

    -- Use Evidence system instead of deprecated fields
    local isMarkedCheater = Evidence.IsMarkedCheater(steamId)
    local inDatabase = G.DataBase[steamId] ~= nil
    local priorityCheater = playerlist.GetPriority(steamId) == 10

    return isMarkedCheater or inDatabase or priorityCheater
end
```

**Impact:** Function currently broken but may not be widely used. Need to check call sites.

---

### 4. 🗑️ **Dead/Template Files**

#### **Detection Methods/detection_template.lua**

- **Status:** Template file, not actively used
- **Problem:** Uses completely deprecated G.PlayerData pattern
- **Action:** Delete or rewrite with modern Evidence.AddEvidence() pattern

**Recommendation:** Delete. Current detection methods are good examples for new detections.

---

### 5. 📝 **TODOs & Unfinished Work**

#### **Main.lua (line 144)**

```lua
-- TODO: Implement remaining detection methods
--warp_recharge_check(Player)
--triggerbot_check(Player)
--smooth_aimbot_check(Player)
```

**Action:** Either implement or remove comment. If not planning to add these, clean up.

---

#### **EVIDENCE_SYSTEM.md**

```markdown
## TODO

### Damage Event Tracking

Currently missing: extra decay when player deals damage (aim validation).
```

**Action:** Keep or implement damage event tracking for aim decay validation.

---

### 6. 🔧 **Globals.lua - Redundant Initialization**

**Location:** `Utils/Globals.lua` line 14

```lua
G.PlayerData = {}
```

**Problem:** This is immediately overwritten by PlayerState.lua line 14:

```lua
G.PlayerData = ActivePlayers -- Maintain backwards compatibility
```

**Fix:** Remove from Globals.lua - it's owned by PlayerState now.

---

## Summary Table

| Issue                               | Severity    | Files Affected             | Action Required           |
| ----------------------------------- | ----------- | -------------------------- | ------------------------- |
| Deprecated G.PlayerData.info fields | 🔴 Critical | Common.lua, ChatPrefix.lua | Fix immediately           |
| detection_template.lua outdated     | 🟡 Medium   | 1 file                     | Delete or rewrite         |
| Common.IsCheater() broken           | 🔴 Critical | Common.lua                 | Fix immediately           |
| Globals.lua redundant init          | 🟡 Medium   | Globals.lua                | Remove line 14            |
| Old callback patterns               | 🟢 Low      | 11 files                   | Migrate opportunistically |
| TODOs                               | 🟢 Low      | Main.lua, docs             | Clean up or implement     |

---

## Recommended Action Plan

### Phase 1: Critical Fixes COMPLETED

1. Fix `Common.IsCheater()` to use Evidence.IsMarkedCheater()
   - Removed deprecated G.PlayerData.info.Strikes and .isCheater access
   - Now uses Evidence.IsMarkedCheater() API
2. Fix `ChatPrefix.lua` to use Evidence.GetEvidence()
   - Removed direct G.PlayerData access
   - Now uses Evidence.GetEvidence() API
3. Remove `G.PlayerData = {}` from Globals.lua
   - Replaced with comment explaining ownership by PlayerState.lua

### Phase 2: Cleanup COMPLETED

4. Delete `detection_template.lua` - Removed misleading template file
5. Remove TODO comments - Cleaned up Main.lua

### Phase 3: Opportunistic (Do When Touching Files)

6. Migrate old callbacks to EventManager only when adding new handlers
7. Consider implementing damage event tracking if needed

---

## Code Smell: Print Statements

**Found 36 print() calls across 25 files.**

**Recommendation:** Most are fine (debug/info messages), but should use Logger instead for consistency:

**Bad:**

```lua
print("[Evidence] MARKED player as cheater")
```

**Good:**

```lua
Logger.Info("Evidence", "MARKED player as cheater")
```

**Action:** Migrate opportunistically when touching files. Not critical.

---

## Architecture Notes

### ✅ Good Patterns (Keep Using)

- Evidence.AddEvidence() for all detections
- EventManager for new event handlers in Main.lua
- Logger for all output (replacing raw print)
- Database.UpsertCheater() for persistence
- PlayerState.AttachWrappedPlayer() for player data

### ❌ Deprecated Patterns (Stop Using)

- Direct G.PlayerData[steamID] = {} initialization
- G.PlayerData[steamID].info.Strikes / .isCheater access
- G.PlayerData[steamID].detections counter pattern
- Raw print() instead of Logger
- Multiple callbacks.Register for same event type

---

## Files That Need Immediate Attention

1. **Utils/Common.lua** - Fix IsCheater() function
2. **Misc/ChatPrefix.lua** - Fix Evidence access
3. **Utils/Globals.lua** - Remove redundant G.PlayerData init
4. **Detection Methods/detection_template.lua** - Delete or rewrite
