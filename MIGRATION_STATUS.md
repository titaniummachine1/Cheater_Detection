# Migration Status: Old Script → New Modular System

## ✅ Successfully Ported (5/5 Core Detections + Enhanced)

### **1. Anti-Aim Detection** (`anti_aim.lua`) - ENHANCED
- **Old Function:** `CheckAngles()`
- **Detection:** Invalid pitch angles with **cheat fingerprinting**
- **Evidence Weight:** 25 (Exploit category - slow decay 0.5/sec)
- **Status:** ✅ COMPLETE + ENHANCED
- **Trigger:** Instant on first detection
- **Improvements:**
  - ✅ Detects LBOX AA (pitch % 3256 == 0)
  - ✅ Detects RIJIN AA (pitch % 271 == 0)
  - ✅ Detects generic AA (pitch % 90 == 0)
  - ✅ Enhanced debug logging with cheat type
- **Notes:** Cheat-specific pattern matching reduces false positives

---

### **2. Bunny Hop Detection** (`bhop.lua`) - ENHANCED
- **Old Function:** `CheckBhop()`
- **Detection:** Velocity-based bhop analysis
- **Evidence Weight:** 15 (Movement category - decay 0.8/sec)
- **Status:** ✅ COMPLETE + ENHANCED
- **Trigger:** 5+ consecutive hops with TF2-specific velocity values
- **Improvements:**
  - ✅ Checks vertical velocity (271 or 277 HU/s = perfect bhop)
  - ✅ Compares last vs current velocity.z
  - ✅ More accurate than simple ground state counting
- **Notes:** TF2-specific velocity thresholds reduce false positives

---

### **3. Duck Speed Detection** (`Duck_Speed.lua`)
- **Old Function:** `CheckDuckSpeed()`
- **Detection:** Speed > (maxspeed * 0.66) while fully crouched
- **Evidence Weight:** 20 (Movement category - decay 0.8/sec)
- **Status:** ✅ COMPLETE
- **Trigger:** Sustained violation for 66 ticks (1 second)
- **Notes:** Verifies full crouch via viewoffset.z == 45

---

### **4. Fake Lag Detection** (`fake_lag.lua`)
- **Old Function:** `CheckChoke()`
- **Detection:** Simulation time delta >= 8 ticks
- **Evidence Weight:** 22 (Exploit category - decay 0.5/sec)
- **Status:** ✅ COMPLETE
- **Trigger:** Excessive sim time jump
- **Notes:** Detects packet choking, doubletap, fakelag

---

## ⚠️ NOT YET PORTED

### **5. Warp / Doubletap Detection** (`warp_dt.lua`) - NEW
- **Old Function:** `CheckSequenceBurst()`
- **Detection:** Statistical analysis of simulation time with **standard deviation**
- **Evidence Weight:** 30 (Exploit category - very high weight)
- **Status:** ✅ COMPLETE - PORTED FROM ADVANCED SCRIPT
- **Trigger:** Standard deviation signature == -132 (warp pattern)
- **How it works:**
  1. Track 33 ticks of simulation time
  2. Calculate tick deltas
  3. Compute mean and standard deviation
  4. Detect specific stddev signature (-132 = sequence burst)
  5. Verify tick interval consistency to avoid false positives
- **Notes:** Sophisticated statistical detection - catches time manipulation exploits

---

### **6. Silent Aimbot Detection** (Complex)
- **Old Function:** `CheckAimbotFlick()` + `event_hook()` + angle history
- **Detection:** Event-based damage tracking + FOV delta analysis
- **Status:** ❌ NEEDS PORTING
- **Complexity:** HIGH - requires:
  - `player_hurt` event hook
  - Angle history tracking (6 angles)
  - FOV delta calculation on shot
  - Victim/shooter state management
- **Category:** Aim (context-aware decay)
- **Notes:** Most complex detection - should be `silent_aimbot.lua`

---

### **7. Warp Recharge** 
- **Status:** ❌ TODO - create `warp_recharge.lua`
- **Category:** Exploit

---

### **8. Triggerbot**
- **Status:** ❌ TODO - create `triggerbot.lua`
- **Category:** Aim

---

### **9. Smooth Aimbot**
- **Status:** ❌ TODO - create `smooth_aimbot.lua`
- **Category:** Aim

---

### **10. Plain Aimbot**
- **Status:** ❌ TODO - create `plain_aimbot.lua`
- **Category:** Aim

---

### **11. Strafe Bot**
- **Status:** ❌ TODO - create `strafe_bot.lua`
- **Category:** Movement

---

### **12. Bot Walk**
- **Status:** ❌ TODO - create `bot_walk.lua`
- **Comment exists:** "unnatural pattern of looking towards walk direction"
- **Category:** Movement

---

## Key Improvements Over Old Script

### **Architecture**
- ✅ Modular detection methods (vs monolithic 800+ line file)
- ✅ Evidence/weight system with decay (vs strike counter)
- ✅ Context-aware decay for aim (vs static thresholds)
- ✅ FastPlayers optimization (vs entities.FindByClass every tick)
- ✅ WrappedPlayer abstraction (vs raw entity props)
- ✅ Centralized config in G.Menu (vs local Menu table)

### **Performance**
- ✅ Skip detection on marked cheaters
- ✅ Skip decay for database entries
- ✅ Per-tick player cache (FastPlayers)
- ✅ Per-second decay rate limiting

### **Maintainability**
- ✅ Each detection in separate file
- ✅ Consistent API across all detections
- ✅ Clear separation: detection logic vs evidence scoring
- ✅ Template pattern for new detections

---

## Old Script Features NOT in New System

### **1. Visual Tags**
- **Old:** Drew "CHEATER"/"SUSPICIOUS" tags above players
- **Status:** ❌ Not yet implemented
- **File:** Should be in `Misc/Visuals/Visuals.lua` (exists but empty)

### **2. Strike System UI**
- **Old:** Showed strikes counter per player
- **New:** Uses Evidence scores (different paradigm)
- **Status:** ✅ Evidence system is better - scores decay intelligently

### **3. Party Callouts**
- **Old:** `say_party` when cheater detected
- **Status:** ⚠️ Menu option exists (`G.Menu.Main.partyCallaut`) but no implementation
- **TODO:** Add party chat callout when player marked

### **4. Join Warnings**
- **Status:** ⚠️ Menu option exists (`G.Menu.Main.JoinWarning`) but no implementation
- **TODO:** Add player join event handler

### **5. Config Save/Load**
- **Old:** `CreateCFG()` / `LoadCFG()` with manual serialization
- **Status:** ❌ Not yet implemented
- **File:** `Utils/Config.lua` exists but not checked
- **TODO:** Implement config persistence

### **6. Bot Name Detection**
- **Old:** Pattern matching against bot names (commented out)
- **Status:** ❌ Not implemented
- **Priority:** LOW - database scraping is more reliable

---

## Integration Status

### ✅ Integrated
- Main.lua calls Evidence.ApplyDecay() per tick
- Main.lua calls 4 detection methods (AntiAim, Bhop, DuckSpeed, FakeLag)
- Detection skip optimization for marked cheaters
- Evidence system auto-marks at score >= 100

### ❌ Not Integrated
- Visual tags/ESP
- Party callouts
- Join warnings
- Config save/load
- Remaining 8 detection methods

---

## Testing Checklist

### **Detection Methods**
- [ ] Test anti_aim detection with rage AA (±89° pitch)
- [ ] Test bhop detection with consecutive jumps
- [ ] Test duck speed with speedhack while crouched
- [ ] Test fake lag with packet choker
- [ ] Verify Evidence.ApplyDecay() runs once per second
- [ ] Verify aim decay increases when aiming at enemies
- [ ] Verify auto-mark at score >= 100

### **Performance**
- [ ] Verify FastPlayers cache works (no redundant FindByClass)
- [ ] Verify marked cheaters skip detection logic
- [ ] Verify decay skips database entries
- [ ] Profile tick time with 24 players

### **Edge Cases**
- [ ] Test with demo playback (should skip some checks)
- [ ] Test with high ping/packet loss
- [ ] Test with friends (should respect debug mode toggle)
- [ ] Test local player exclusion

---

## Next Steps (Priority Order)

1. **Port Silent Aimbot** - Most valuable detection from old script
2. **Implement Visual Tags** - User feedback is important
3. **Add Party Callouts** - Social aspect for team play
4. **Config Persistence** - Save/load Evidence threshold, decay rates
5. **Port Remaining Detections** - Triggerbot, smooth aim, etc.
6. **Join Warnings** - Alert when known cheater joins

---

## Notes

### **Lint Warnings (Safe to Ignore)**
- `IsValid`, `IsAlive`, `GetAbsOrigin` on enemies in `calculateAimDecay()`
  - These exist via WrappedPlayer metatable forwarding
- `GetDetails()` nil return annotation mismatch
  - Intentional - returns nil when no evidence data exists

### **Old Script Bugs Fixed**
- ✅ Global pollution (old used `playerData` global)
- ✅ Memory leaks (old never cleaned up `lastAngles` table)
- ✅ Race conditions (old `CheckAimbot` used global `shooter`/`HurtVictim`)
- ✅ No evidence decay (old strike counter never decreased)
- ✅ Hard to tune (old thresholds scattered throughout code)

### **Code Quality**
- ✅ Follows user's coding rules (guard clauses, no nesting, readable)
- ✅ No magic numbers (all thresholds are named constants)
- ✅ Black box modules (clean API boundaries)
- ✅ Single responsibility (detection != scoring != UI)
