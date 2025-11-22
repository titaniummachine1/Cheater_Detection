# Event Manager - Centralized Event Handling

## Overview

`EventManager` consolidates all game event callbacks into a single dispatcher system, eliminating redundant callback registrations and providing clean event filtering.

---

## Problem Before

**Main.lua had 2 separate FireGameEvent callbacks:**

```lua
-- Callback 1
callbacks.Register("FireGameEvent", "CD_MapChange", function(event)
    if event:GetName() == "game_newmap" or ... then
        OnMapChange()
    end
end)

-- Callback 2 (REDUNDANT!)
callbacks.Register("FireGameEvent", "CD_PlayerDisconnect", function(event)
    local eventName = event:GetName()
    if eventName == "player_disconnect" then ...
    elseif eventName == "player_death" then ...
    elseif eventName == "teamplay_round_win" then ...
    -- ... 8 separate event checks!
end)
```

**Result:**

- Lmaobox calls BOTH callbacks on every game event
- Each callback re-checks `event:GetName()` for filtering
- Duplicate work, scattered code, hard to track

---

## Solution: EventManager

**Single callback per event type, centralized dispatch:**

```lua
-- Main.lua now uses EventManager
EventManager.Register("FireGameEvent", "Main_MapChange_NewMap", OnMapChange, "game_newmap")
EventManager.Register("FireGameEvent", "Main_PlayerDeath", onPlayerDeath, "player_death")
EventManager.Register("FireGameEvent", "Main_RoundWin", onRoundEnd, "teamplay_round_win")
-- ... all handlers registered separately
```

**Behind the scenes:**

- EventManager registers **1 callback** for FireGameEvent
- Dispatches to all handlers matching the event name
- Efficient filtering, no duplicate work

---

## API

### EventManager.Register(eventType, handlerName, callback, filter)

**Parameters:**

- `eventType` (string): "CreateMove", "Draw", "FireGameEvent", "DispatchUserMessage", "Unload"
- `handlerName` (string): Unique name (e.g., "Main_PlayerDeath")
- `callback` (function): Handler function
- `filter` (string?): **FireGameEvent only** - event name to filter (e.g., "player_death")

**Returns:** `boolean` - Success

**Example:**

```lua
-- Map change handler
EventManager.Register("FireGameEvent", "Main_MapChange", OnMapChange, "game_newmap")

-- Round end handler (same event type, different filter)
EventManager.Register("FireGameEvent", "Main_RoundWin", onRoundEnd, "teamplay_round_win")

-- Generic CreateMove (no filter)
EventManager.Register("CreateMove", "Main_Detection", OnCreateMove)
```

---

### EventManager.Unregister(eventType, handlerName)

Remove a handler.

```lua
EventManager.Unregister("FireGameEvent", "Main_PlayerDeath")
```

---

### EventManager.GetHandlerCount(eventType?)

Get registered handler counts for debugging.

```lua
-- All event types
local counts = EventManager.GetHandlerCount()
-- { FireGameEvent = 10, CreateMove = 3, Draw = 5 }

-- Specific event type
local count = EventManager.GetHandlerCount("FireGameEvent")
-- 10
```

---

## Main.lua Refactoring

### Before:

- 2 separate `FireGameEvent` callbacks
- Nested if/elseif chains
- 30+ lines of event checking logic

### After:

- 1 callback (via EventManager)
- 10 clear, named handlers
- Each handler registered with specific event filter
- Easy to add/remove handlers

### Event Handlers Registered:

**CreateMove:**

- `Main_Detection` - Main detection loop

**FireGameEvent (Map Change):**

- `Main_MapChange_NewMap` - game_newmap
- `Main_MapChange_RoundStart` - teamplay_round_start
- `Main_MapChange_CSRoundStart` - cs_round_start

**FireGameEvent (Player):**

- `Main_PlayerDisconnect` - player_disconnect (cleanup)
- `Main_PlayerDeath` - player_death (auto-save)

**FireGameEvent (Round/Match End - Auto-save):**

- `Main_RoundWin` - teamplay_round_win
- `Main_RoundStalemate` - teamplay_round_stalemate
- `Main_GameOver` - teamplay_game_over
- `Main_TFGameOver` - tf_game_over
- `Main_ArenaRoundStart` - arena_round_start

---

## Benefits

### ✅ No Redundant Work

- Single callback per event type
- No duplicate event name checks
- Efficient dispatch

### ✅ Clean Code

- Named handlers (not anonymous functions)
- Each handler does one thing
- Easy to understand data flow

### ✅ Easy to Extend

```lua
-- Add new handler in 1 line
EventManager.Register("FireGameEvent", "Main_NewFeature", onNewFeature, "some_event")
```

### ✅ Centralized Management

- All event hooks go through EventManager
- Easy to audit what's registered
- GetHandlerCount() for debugging

### ✅ Error Isolation

- Handlers run in pcall
- One handler error doesn't break others
- Errors logged with handler context

---

## Implementation Details

**Handler Storage:**

```lua
local handlers = {
    CreateMove = {},
    Draw = {},
    FireGameEvent = {},
    DispatchUserMessage = {},
    Unload = {},
}
```

**Dispatcher (FireGameEvent):**

```lua
local function dispatchFireGameEvent(event)
    local eventName = event:GetName()
    for _, handler in pairs(handlers.FireGameEvent) do
        if not handler.filter or handler.filter == eventName then
            pcall(handler.callback, event)
        end
    end
end
```

**Registration:**

- First handler registers actual callback
- Subsequent handlers just add to dispatch list
- No duplicate callback overhead

---

## Other Modules

**Not yet refactored (use old callbacks):**

- JoinNotifications.lua
- Vote_Revel.lua
- Auto_Vote.lua
- SteamHistory.lua
- ChatPrefix.lua
- Menu.lua
- Visuals.lua
- TickProfiler.lua

**Reason:** These work fine, not worth touching unless adding features

**Future:** Migrate if adding new event handlers to those modules

---

## Files Modified

1. **Utils/EventManager.lua** - New centralized event dispatcher (121 lines)
2. **Main.lua** - Refactored to use EventManager
   - Removed 2 callbacks.Register calls
   - Added EventManager import
   - Created named handler functions
   - Registered 10 handlers via EventManager

**Result:**

- Cleaner code
- No redundant work
- Easy to extend
- Better error handling
