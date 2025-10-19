# Evidence System Documentation

## Overview
Weight-based cheater detection system with **context-aware decay** for intelligent false-positive reduction.

## Architecture

### Categories
Detections are grouped into 3 categories with different decay behaviors:

#### 1. **Aim** (Context-Aware Decay)
- **Methods:** `silent_aimbot`, `plain_aimbot`, `smooth_aimbot`, `triggerbot`
- **Decay Logic:**
  - Base decay: 1.0/sec
  - +2.0/sec when looking at enemies (≤30° from enemy)
  - +1.5/sec when aiming very close (≤11° from enemy)
  - +3.0/sec when dealing damage (TODO - requires damage events)
- **Why:** Legit players constantly aim at enemies, so evidence should decay faster in combat context

#### 2. **Exploit** (Time-Based Decay)
- **Methods:** `warp_dt`, `warp_recharge`, `fake_lag`, `anti_aim`
- **Decay Logic:** Fixed 0.5/sec
- **Why:** These should never happen legitimately - slow decay to accumulate evidence

#### 3. **Movement** (Time-Based Decay)
- **Methods:** `bhop`, `strafe_bot`, `Duck_Speed`, `bot_walk`
- **Decay Logic:** Fixed 0.8/sec (medium)
- **Why:** Movement anomalies can sometimes occur naturally - medium decay rate

---

## Configuration
File: `Core/Evidence_system.lua`

```lua
Evidence.Config = {
    -- Decay rates per second
    DecayRates = {
        Aim = {
            default = 1.0,
            lookingAtEnemy = 2.0,
            hurtingEnemy = 3.0,
            closeAim = 1.5,
        },
        Exploit = { default = 0.5 },
        Movement = { default = 0.8 },
    },
    
    -- Thresholds
    MarkAsCheatThreshold = 100, -- Total score to mark as cheater
    MinWeightFloor = 0, -- Cannot decay below this
}
```

---

## API

### Adding Evidence
```lua
Evidence.AddEvidence(steamID, detectionName, weight)
```
**Parameters:**
- `steamID` (string): Player's SteamID64
- `detectionName` (string): Detection method name (e.g., "bhop", "silent_aimbot")
- `weight` (number): Evidence weight to add

**Example:**
```lua
Evidence.AddEvidence(steamID, "bhop", 15)
```

**Auto-Marking:** When `TotalScore >= 100`, player is automatically marked as cheater (priority 10).

---

### Applying Decay
```lua
Evidence.ApplyDecay()
```
Call once per tick in main loop. Internally rate-limited to once per second (66 ticks).

**Integrated in `Main.lua`:**
```lua
-- Apply evidence decay (once per second)
Evidence.ApplyDecay()
```

---

### Checking Cheater Status
```lua
local isCheater = Evidence.IsMarkedCheater(steamID)
```
Returns `true` if player is:
1. In database (known cheater lists)
2. Marked by evidence system (score >= 100)
3. Has playerlist priority 10

**Optimization:** Use this to skip detection logic on confirmed cheaters.

---

### Getting Scores
```lua
local score = Evidence.GetScore(steamID)
local details = Evidence.GetDetails(steamID)
```

**Details Structure:**
```lua
{
    TotalScore = 75,
    LastUpdateTick = 123456,
    MarkedAsCheater = false,
    Reasons = {
        ["bhop"] = {
            Weight = 45,
            Category = "Movement",
            LastAddedTick = 123400
        },
        ["silent_aimbot"] = {
            Weight = 30,
            Category = "Aim",
            LastAddedTick = 123450
        }
    }
}
```

---

## Integration Flow

### Main Loop (`Main.lua`)
```lua
-- 1. Apply decay to all players
Evidence.ApplyDecay()

-- 2. Iterate players
for _, Player in ipairs(allPlayers) do
    local steamID = Player:GetSteamID64()
    
    -- 3. Skip confirmed cheaters (OPTIMIZATION)
    if Evidence.IsMarkedCheater(steamID) then
        goto continue
    end
    
    -- 4. Run detection checks
    Detection.Check(Player)
    
    ::continue::
end
```

### Detection Method (`detection_template.lua`)
```lua
function Detection.Check(player)
    local steamID = player:GetSteamID64()
    
    -- Skip if already marked
    if Evidence.IsMarkedCheater(steamID) then
        return false
    end
    
    -- Run detection logic
    local detected = false
    -- ... detection code ...
    
    if detected then
        detectionCounter[steamID] = detectionCounter[steamID] + 1
        
        -- Add evidence after threshold
        if detectionCounter[steamID] >= MIN_DETECTIONS then
            Evidence.AddEvidence(steamID, "bhop", 15)
            detectionCounter[steamID] = 0
        end
    end
end
```

---

## Performance Optimizations

### 1. Skip Marked Cheaters
Once confirmed, detection logic is skipped entirely:
```lua
if Evidence.IsMarkedCheater(steamID) then
    goto continue
end
```

### 2. Skip Decay for Database Entries
Players in external database don't need decay calculations:
```lua
local skipDecay = G.DataBase[steamID] ~= nil
```

### 3. Rate-Limited Decay
Decay only runs once per second (not every tick):
```lua
if ticksDelta < TICKS_PER_SECOND then
    return
end
```

### 4. FastPlayers Integration
Uses cached player lists from `FastPlayers.GetAll()` and `FastPlayers.GetEnemies()`.

---

## Data Storage

Evidence is stored in `G.PlayerData[steamID].Evidence`:
```lua
{
    TotalScore = 0,
    LastUpdateTick = 0,
    MarkedAsCheater = false,
    Reasons = {
        -- Per-detection stacks
    }
}
```

---

## TODO

### Damage Event Tracking
Currently missing: extra decay when player deals damage (aim validation).

**Implementation:**
1. Hook damage events
2. Track last damage time per player
3. Add `hurtingEnemy` decay multiplier in `calculateAimDecay()`

### Configurable Thresholds
Consider exposing `MarkAsCheatThreshold` in menu for user tuning.

### Evidence Visualization
Add UI display showing:
- Current evidence score per player
- Breakdown by detection method
- Time until decay to 0

---

## Example Workflow

**Scenario:** Player bunny hopping

1. **Detection:** `bhop.lua` detects 3 consecutive perfect hops
2. **Counter:** Increments internal counter (not evidence yet)
3. **Threshold:** After 3 detections, adds weight: `Evidence.AddEvidence(steamID, "bhop", 15)`
4. **Storage:** Evidence stored in `G.PlayerData[steamID].Evidence.Reasons["bhop"] = { Weight = 15, Category = "Movement" }`
5. **Decay:** Every second, weight reduces by 0.8 (Movement category)
6. **Accumulation:** If player continues hopping, weight accumulates faster than decay
7. **Marking:** When `TotalScore >= 100`, auto-marked as cheater
8. **Optimization:** All future detections skip this player

---

## Lint Notes

The following linter warnings are **false positives** and can be ignored:
- `IsValid`, `IsAlive`, `GetAbsOrigin` on enemy objects in `calculateAimDecay()`
  - These methods exist on WrappedPlayer via metatable forwarding
- Return type mismatch in `GetDetails()` (nil is valid return for missing data)
